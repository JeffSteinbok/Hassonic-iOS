import ActivityKit
import Foundation
import UIKit

/// Owns the speaker Live Activity: starts it when the selected account starts
/// playing, keeps it in step with Home Assistant while the app is running,
/// and carries out its button taps (which iOS delivers to this process, even
/// launching it in the background to do so).
@MainActor
final class ZonesLiveActivityController {
    static let shared = ZonesLiveActivityController()

    private typealias ZonesActivity = Activity<ZonesActivityAttributes>
    private typealias ContentState = ZonesActivityAttributes.ContentState

    /// Nothing refreshes the activity while the app is suspended, so after this
    /// long without an update the lock screen is told it may be out of date.
    static let staleAfter: TimeInterval = 15 * 60
    /// Re-sent this often even when nothing changed, so an accurate activity
    /// doesn't get marked stale just because the app had nothing new to say.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// How long a volume tap's level is trusted over Home Assistant's, which
    /// lags the service call — without this a quick second tap starts from the
    /// old level.
    private static let optimisticVolumeWindow: TimeInterval = 3

    private let client: HAWebSocketClient

    /// Set when the person swipes the activity away, so it isn't recreated
    /// for the same playback. Cleared once playback stops.
    private var dismissedByUser = false
    /// Activities this controller ended, so their ending isn't read as a swipe.
    private var endingIds: Set<String> = []
    /// Activities with a zone tap in flight; live state would otherwise wipe
    /// the pending indicator before Home Assistant confirms.
    private var busyIds: Set<String> = []
    private var observedIds: Set<String> = []
    private var lastUpdate: [String: Date] = [:]
    private var optimisticVolumes: [String: (level: Double, at: Date)] = [:]

    /// Nil for the shared client. (A `.shared` default argument would be
    /// evaluated off the main actor.)
    init(client: HAWebSocketClient? = nil) {
        self.client = client ?? .shared
    }

    private var activities: [ZonesActivity] { ZonesActivity.activities }

    // MARK: - Keeping in step with Home Assistant

    /// Called whenever entity state, the config or the selected account
    /// changes. Cheap when nothing relevant moved: it only talks to ActivityKit
    /// when the content would actually differ.
    func sync(account: MediaAccount?) {
        for activity in activities where activity.attributes.accountEntityId != account?.entityId {
            end(activity)
        }
        guard let account else { return }

        let accountEntity = client.entity(account.entityId)
        guard ZonesActivityContent.hasMedia(accountEntity) else {
            dismissedByUser = false
            activities.forEach(end)
            return
        }

        let state = ZonesActivityContent.state(
            accountEntity: accountEntity,
            zones: ZonesActivityContent.zones(for: account),
            entity: entityWithOptimisticVolume
        )

        if let current = activities.first(where: { $0.activityState == .active && !endingIds.contains($0.id) }) {
            guard !busyIds.contains(current.id) else { return }
            let isDue = Date().timeIntervalSince(lastUpdate[current.id] ?? .distantPast) > Self.refreshInterval
            // Keep a tap's error on screen until something actually changes.
            var comparable = current.content.state
            comparable.message = nil
            guard comparable != state || isDue else { return }
            Task { await update(current, to: state) }
        } else {
            guard !dismissedByUser,
                  accountEntity?.state == "playing",
                  UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            start(account: account, state: state)
        }
    }

    private func start(account: MediaAccount, state: ContentState) {
        let attributes = ZonesActivityAttributes(
            accountEntityId: account.entityId,
            accountName: account.displayName,
            quickZones: ZonesActivityContent.quickZones(for: account) { client.entity($0)?.isAvailable == true }
        )
        do {
            let activity = try ZonesActivity.request(attributes: attributes, content: content(state), pushType: nil)
            lastUpdate[activity.id] = Date()
            observe(activity)
        } catch {
            Log.liveActivity.note("start failed — \(error.localizedDescription)")
        }
    }

    private func observe(_ activity: ZonesActivity) {
        guard observedIds.insert(activity.id).inserted else { return }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                guard let self else { return }
                if !self.endingIds.contains(activity.id) {
                    self.dismissedByUser = true
                }
                self.forget(activity.id)
                return
            }
        }
    }

    private func end(_ activity: ZonesActivity) {
        guard endingIds.insert(activity.id).inserted else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func forget(_ id: String) {
        endingIds.remove(id)
        observedIds.remove(id)
        busyIds.remove(id)
        lastUpdate[id] = nil
    }

    // MARK: - Button taps

    func selectZone(_ zoneId: String, activityId: String) async {
        guard let activity = activities.first(where: { $0.id == activityId }),
              let zone = activity.attributes.quickZones.first(where: { $0.id == zoneId }) else { return }
        let accountEntityId = activity.attributes.accountEntityId

        busyIds.insert(activityId)
        defer { busyIds.remove(activityId) }

        var state = activity.content.state
        state.pendingZoneId = zone.id
        state.message = nil
        await update(activity, to: state)

        guard await ensureConnected(accountEntityId: accountEntityId) else {
            state.pendingZoneId = nil
            state.message = "Couldn't reach Home Assistant"
            await update(activity, to: state)
            return
        }

        let result = await client.selectSourceConfirmed(accountEntityId, source: zone.sourceName)
        state = activity.content.state
        state.pendingZoneId = nil
        switch result {
        case .alreadyActive, .confirmed:
            // The Now Playing card's fallback for when HA omits `source`
            // while paused — keep it agreeing with what was just picked.
            UserDefaults.standard.set(zone.sourceName, forKey: StorageKeys.lastPlayOnSource(account: accountEntityId))
            state.activeZone = zone
            state.volume = ZonesActivityContent.volume(of: zone, entity: entityWithOptimisticVolume)
            state.message = nil
        case .timeout:
            // Claiming a speaker for another account is a long voice-assistant
            // round trip with its own progress UI; it stays in the app.
            state.message = "\(zone.name) isn't on \(activity.attributes.accountName)'s account. Open the app to move it."
        case .error(let message):
            state.message = "Couldn't switch to \(zone.name): \(message)"
        }
        await update(activity, to: state)
    }

    func setVolume(to level: Double, activityId: String) async {
        guard let activity = activities.first(where: { $0.id == activityId }),
              let zone = activity.content.state.activeZone else { return }

        var state = activity.content.state
        guard await ensureConnected(accountEntityId: activity.attributes.accountEntityId) else {
            state.message = "Couldn't reach Home Assistant"
            await update(activity, to: state)
            return
        }

        let targets = ZonesActivityContent.volumes(of: zone, settingTo: level, entity: entityWithOptimisticVolume)
        guard !targets.isEmpty else { return }
        let now = Date()
        for target in targets {
            client.setVolume(target.entityId, level: target.level)
            optimisticVolumes[target.entityId] = (target.level, now)
        }
        state.volume = targets.map(\.level).reduce(0, +) / Double(targets.count)
        state.message = nil
        await update(activity, to: state)
    }

    // MARK: - Helpers

    /// Stamps the current icon on every update, so a change in Settings
    /// reaches a running activity the next time it updates.
    private func content(_ state: ContentState) -> ActivityContent<ContentState> {
        var state = state
        state.appMark = ZonesActivityAttributes.appMark(forAlternateIcon: UIApplication.shared.alternateIconName)
        return ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }

    private func update(_ activity: ZonesActivity, to state: ContentState) async {
        lastUpdate[activity.id] = Date()
        await activity.update(content(state))
    }

    private func entityWithOptimisticVolume(_ entityId: String) -> HAEntityState? {
        guard let entity = client.entity(entityId) else { return nil }
        guard let optimistic = optimisticVolumes[entityId],
              Date().timeIntervalSince(optimistic.at) < Self.optimisticVolumeWindow else {
            optimisticVolumes[entityId] = nil
            return entity
        }
        var attributes = entity.attributes
        attributes["volume_level"] = .number(optimistic.level)
        return HAEntityState(entityId: entity.entityId, state: entity.state, attributes: attributes, lastChanged: entity.lastChanged)
    }

    /// A tap can arrive with the app freshly launched in the background, with
    /// no socket and no entities yet. Connects from the saved credentials and
    /// waits until the account's entity has loaded.
    private func ensureConnected(accountEntityId: String) async -> Bool {
        func ready() -> Bool { client.connectionState == .connected && client.entity(accountEntityId) != nil }
        if ready() { return true }

        if client.tokenRefresher == nil {
            let oauthClient = HAOAuthClient()
            client.tokenRefresher = { baseURL in
                guard let refreshToken = KeychainStore.loadRefreshToken() else { return nil }
                return await oauthClient.refresh(baseURL: baseURL, refreshToken: refreshToken)
            }
        }
        await HAConnectionBootstrapper.connectUsingSavedCredentials(client: client)

        for _ in 0..<100 {
            if ready() { return true }
            if case .failed = client.connectionState { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
