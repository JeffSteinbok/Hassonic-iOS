import ActivityKit
import BackgroundTasks
import Foundation
import UIKit

/// Owns the speaker Live Activity: starts it when the selected account starts
/// playing, keeps it in step with Home Assistant while the app is running,
/// and carries out its button taps (which iOS delivers to this process, even
/// launching it in the background to do so).
///
/// Ending it is the hard part, because nothing runs while the app is
/// suspended. See `ZonesActivityLifecycle` for when it should go; this class
/// makes that happen:
/// - while running, `sync` ends it, re-checking when a pause's grace runs out;
/// - before suspending (`willSuspend`), a paused one is ended with a dismissal
///   date, which iOS honours without the app;
/// - a playing one is left with a stale date, and a background refresh
///   (`refreshInBackground`) checks on it when iOS allows;
/// - at launch, any left stale by a killed app are cleared (`cleanUpStale`).
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
    private static let optimisticPlayingWindow: TimeInterval = 5

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
    /// Play/pause as just tapped, until Home Assistant reports it or the
    /// window passes, so the button doesn't flick back meanwhile.
    private var optimisticPlaying: (isPlaying: Bool, at: Date)?
    /// When this process first saw the account stop playing, for when Home
    /// Assistant doesn't say (`last_changed`).
    private var notPlayingSince: Date?
    /// The last account `sync` was given, for the grace-period re-check.
    private var lastAccount: MediaAccount?
    private var recheckDeadline: Date?
    private var recheckTask: Task<Void, Never>?

    /// The app's background refresh task, listed in Info.plist's
    /// BGTaskSchedulerPermittedIdentifiers.
    nonisolated static var refreshTaskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "Hassonic") + ".liveActivityRefresh"
    }

    /// Nil for the shared client. (A `.shared` default argument would be
    /// evaluated off the main actor.)
    init(client: HAWebSocketClient? = nil) {
        self.client = client ?? .shared
    }

    private var activities: [ZonesActivity] { ZonesActivity.activities }

    /// Still on screen and still updatable. A stale activity counts: it's
    /// the same one, just overdue an update.
    private var liveActivities: [ZonesActivity] {
        activities.filter { ($0.activityState == .active || $0.activityState == .stale) && !endingIds.contains($0.id) }
    }

    // MARK: - Keeping in step with Home Assistant

    /// Called whenever entity state, the config or the selected account
    /// changes. Cheap when nothing relevant moved: it only talks to ActivityKit
    /// when the content would actually differ.
    func sync(account: MediaAccount?) {
        lastAccount = account
        for activity in activities where activity.attributes.accountEntityId != account?.entityId {
            end(activity)
        }
        guard let account else { return }
        // No states yet (launching, or signed out) says nothing about
        // playback, so leave the activity be rather than end it.
        guard client.connectionState == .connected, !client.entities.isEmpty else { return }

        let accountEntity = client.entity(account.entityId)
        let now = Date()
        let playback = playbackHonouringTap(ZonesActivityLifecycle.playback(of: accountEntity), now: now)
        let decision = ZonesActivityLifecycle.decision(
            playback, notPlayingSince: notPlayingSince(accountEntity, playback: playback, now: now), now: now
        )
        scheduleRecheck(decision)
        if decision == .end {
            dismissedByUser = false
            activities.forEach { end($0) }
            return
        }

        var state = ZonesActivityContent.state(
            accountEntity: accountEntity,
            zones: ZonesActivityContent.zones(for: account),
            entity: entityWithOptimisticVolume
        )
        if let held = optimisticPlaying {
            if held.isPlaying == state.isPlaying || Date().timeIntervalSince(held.at) > Self.optimisticPlayingWindow {
                optimisticPlaying = nil
            } else {
                state.isPlaying = held.isPlaying
            }
        }

        if let current = liveActivities.first {
            // One left over from before a relaunch still needs watching, or
            // swiping it away wouldn't stick.
            observe(current)
            guard !busyIds.contains(current.id) else { return }
            let isDue = Date().timeIntervalSince(lastUpdate[current.id] ?? .distantPast) > Self.refreshInterval
            // Keep a tap's error on screen until something actually changes.
            var comparable = current.content.state
            comparable.message = nil
            guard comparable != state || isDue else { return }
            Task { await update(current, to: state) }
        } else {
            guard !dismissedByUser,
                  playback == .playing,
                  UIApplication.shared.applicationState == .active else { return }
            start(ZonesActivityAttributes(
                accountEntityId: account.entityId,
                accountName: account.displayName,
                quickZones: ZonesActivityContent.quickZones(for: account) { client.entity($0)?.isAvailable == true }
            ), state: state)
        }
    }

    private func start(_ attributes: ZonesActivityAttributes, state: ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // One ended before suspending may still be on screen; it can't be
        // updated, so it makes way for the new one.
        for leftover in activities where !liveActivities.contains(where: { $0.id == leftover.id }) {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            let activity = try ZonesActivity.request(attributes: attributes, content: content(state), pushType: nil)
            lastUpdate[activity.id] = Date()
            observe(activity)
        } catch {
            Log.liveActivity.note("start failed — \(error.localizedDescription)")
        }
    }

    /// A play/pause tap is trusted over Home Assistant until it catches up.
    private func playbackHonouringTap(_ playback: ZonesActivityLifecycle.Playback, now: Date) -> ZonesActivityLifecycle.Playback {
        guard let held = optimisticPlaying,
              now.timeIntervalSince(held.at) <= Self.optimisticPlayingWindow else { return playback }
        if held.isPlaying { return .playing }
        return playback == .stopped ? .stopped : .paused
    }

    /// When the pause's grace period started.
    private func notPlayingSince(_ entity: HAEntityState?, playback: ZonesActivityLifecycle.Playback, now: Date) -> Date {
        guard playback != .playing else {
            notPlayingSince = nil
            return now
        }
        if notPlayingSince == nil { notPlayingSince = now }
        // A pause just tapped: Home Assistant's last_changed is still the
        // moment it started playing.
        if let held = optimisticPlaying, !held.isPlaying,
           now.timeIntervalSince(held.at) <= Self.optimisticPlayingWindow {
            return held.at
        }
        guard ZonesActivityLifecycle.playback(of: entity) != .playing else { return notPlayingSince ?? now }
        return ZonesActivityLifecycle.notPlayingSince(entity, fallback: notPlayingSince ?? now)
    }

    /// A paused player sends no further updates, so nothing would call
    /// `sync` when its grace period runs out; this does.
    private func scheduleRecheck(_ decision: ZonesActivityLifecycle.Decision) {
        guard case .keepUntil(let deadline) = decision else {
            recheckTask?.cancel()
            recheckTask = nil
            recheckDeadline = nil
            return
        }
        guard deadline != recheckDeadline else { return }
        recheckTask?.cancel()
        recheckDeadline = deadline
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled, let self else { return }
            self.recheckDeadline = nil
            self.recheckTask = nil
            self.sync(account: self.lastAccount)
        }
    }

    // MARK: - While the app isn't running

    /// Call when the app is about to stop running: gone to the background, or
    /// a button tap handled while it's there. Nothing watches Home Assistant
    /// until it's next woken, so a paused activity is ended now with its
    /// grace period as the dismissal date, which iOS carries out on its own.
    /// A playing one stays, with a background refresh booked to check on it.
    func willSuspend() {
        let now = Date()
        var anyPlaying = false
        for activity in liveActivities {
            let state = activity.content.state
            if state.isPlaying {
                anyPlaying = true
                continue
            }
            let entity = client.entity(activity.attributes.accountEntityId)
            let since = notPlayingSince(entity, playback: .paused, now: now)
            let policy: ActivityUIDismissalPolicy
            switch ZonesActivityLifecycle.decision(.paused, notPlayingSince: since, now: now) {
            case .keepUntil(let deadline): policy = .after(deadline)
            case .keep, .end: policy = .immediate
            }
            end(activity, finalState: state, dismissalPolicy: policy)
        }
        if anyPlaying { scheduleBackgroundRefresh() }
    }

    /// Ends what a killed app left behind: activities nobody has updated
    /// since their stale date, and any beyond the first. If the music is
    /// still going, `sync` starts a fresh one once connected. For a launch
    /// into the foreground only — a background launch is iOS delivering a tap
    /// on that very activity, or a refresh that checks on it properly.
    func cleanUpStale(now: Date = Date()) {
        var kept = false
        for activity in liveActivities {
            let isStale = activity.activityState == .stale || (activity.content.staleDate.map { $0 <= now } ?? false)
            if isStale || kept {
                end(activity)
            } else {
                kept = true
            }
        }
    }

    /// A background refresh: asks Home Assistant whether the activity is
    /// still playing and ends it if not. If Home Assistant can't be reached
    /// and the activity has already gone stale, it ends too — it can no
    /// longer be kept accurate.
    func refreshInBackground() async {
        guard let activity = liveActivities.first else { return }
        let accountEntityId = activity.attributes.accountEntityId
        let now = Date()
        guard await ensureConnected(accountEntityId: accountEntityId) else {
            if activity.activityState == .stale || (activity.content.staleDate.map { $0 <= now } ?? false) {
                end(activity)
            } else {
                scheduleBackgroundRefresh()
            }
            return
        }
        let entity = client.entity(accountEntityId)
        let playback = ZonesActivityLifecycle.playback(of: entity)
        let decision = ZonesActivityLifecycle.decision(
            playback, notPlayingSince: notPlayingSince(entity, playback: playback, now: now), now: now
        )
        guard decision != .end else {
            dismissedByUser = false
            end(activity)
            return
        }
        var state = activity.content.state
        state.isPlaying = playback == .playing
        state.message = nil
        await update(activity, to: state)
        willSuspend()
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(Self.staleAfter)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.liveActivity.note("refresh not scheduled — \(error.localizedDescription)")
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

    private func end(_ activity: ZonesActivity, finalState: ContentState? = nil, dismissalPolicy: ActivityUIDismissalPolicy = .immediate) {
        guard endingIds.insert(activity.id).inserted else { return }
        let finalContent = finalState.map(content)
        Task { await activity.end(finalContent, dismissalPolicy: dismissalPolicy) }
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

    /// Shows the new state at once; Home Assistant's own update follows.
    ///
    /// A pause tapped from the Lock Screen keeps the activity up for the
    /// grace period. If the app is in the background, `willSuspend` hands that
    /// to iOS by ending the activity with a dismissal date; play tapped on it
    /// within that time starts a fresh one in its place.
    func togglePlayback(activityId: String) async {
        guard let activity = activities.first(where: { $0.id == activityId }) else { return }
        let accountEntityId = activity.attributes.accountEntityId
        let isLive = liveActivities.contains { $0.id == activityId }

        var state = activity.content.state
        guard await ensureConnected(accountEntityId: accountEntityId) else {
            state.message = "Couldn't reach Home Assistant"
            if isLive { await update(activity, to: state) }
            return
        }
        client.mediaPlayPause(accountEntityId)
        state.isPlaying.toggle()
        optimisticPlaying = (state.isPlaying, Date())
        state.message = nil
        if isLive {
            await update(activity, to: state)
        } else if state.isPlaying {
            // Ended at its last pause, so it can't change; a LiveActivityIntent
            // may start its replacement even from the background.
            dismissedByUser = false
            start(activity.attributes, state: state)
        }
        if UIApplication.shared.applicationState != .active {
            willSuspend()
        }
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

    private func ensureConnected(accountEntityId: String) async -> Bool {
        await HAConnectionBootstrapper.connectAndWait(client: client, for: accountEntityId)
    }
}
