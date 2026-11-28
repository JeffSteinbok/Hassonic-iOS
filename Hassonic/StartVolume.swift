import SwiftUI
import UIKit

// Speaker volume when music starts.
//
// Handing playback to a speaker (select_source, or the voice assistant's
// "play … on X" when a speaker is claimed) lets the music service push its own
// remembered level onto it. For a group that one level lands on every
// member, so a speaker can come up far quieter than it was left. Nothing in
// the app asked for that. This takes each speaker's level just before the
// start, waits for the handoff to settle, and puts back whatever went down,
// then raises anything still under a floor. It never turns a speaker down; a
// speaker pinned at a fixed level (a line-out into a receiver) is reset to
// its pin.
//
// Two calls make the whole feature, so it can be swapped or removed in one
// place: `StartVolumeGuard.prepare` just before a start, `protect` once it
// has been sent. The rules are in `StartVolume`, apart from any timing.

/// The rules, kept apart from timing and Home Assistant so they can be tested.
enum StartVolume {
    /// A speaker the start lands on.
    struct Target: Equatable {
        let entityId: String
        /// The speaker's fixed level from the config (`defaultVolume`), if
        /// any. A pinned speaker is reset to this rather than restored.
        let pin: Double?
    }

    /// Below this a change isn't worth a service call: the speakers report
    /// levels in steps of about 0.01.
    static let tolerance = 0.02

    /// The zone's own speakers: a group's members, or the speaker itself. A
    /// member the config turned off is left alone. A speaker's proxy (a
    /// receiver it plays into) never is a target: the service doesn't touch
    /// it, and it's the volume the household actually sets by hand.
    static func targets(for zone: MusicZone, zones: [MusicZone]) -> [Target] {
        let memberIds = zone.kind == .group ? zone.memberEntityIds : [zone.entityId]
        var seen = Set<String>()
        return memberIds.compactMap { memberId in
            guard seen.insert(memberId).inserted else { return nil }
            let speaker = zones.first { $0.kind == .speaker && $0.entityId == memberId }
            if speaker?.isEnabled == false { return nil }
            return Target(entityId: memberId, pin: speaker?.defaultVolume)
        }
    }

    /// Each target's level now, where it reports one.
    static func snapshot(_ targets: [Target], level: (String) -> Double?) -> [String: Double] {
        targets.reduce(into: [:]) { levels, target in
            if let value = level(target.entityId) { levels[target.entityId] = value }
        }
    }

    /// What to set once the start has settled. A pinned speaker goes to its
    /// pin. Any other goes back to its level from `before` if it dropped,
    /// then up to `floor` if it's still under it. Nothing comes out lower
    /// than it is now, and a speaker that doesn't report a level is left
    /// alone.
    static func corrections(
        for targets: [Target],
        before: [String: Double],
        level: (String) -> Double?,
        settings: StartVolumeConfiguration
    ) -> [(entityId: String, level: Double)] {
        targets.compactMap { target in
            guard let current = level(target.entityId) else { return nil }
            if let pin = target.pin {
                return abs(current - pin) > tolerance ? (target.entityId, rounded(pin)) : nil
            }
            var wanted = current
            if settings.restore, let earlier = before[target.entityId], earlier - current > tolerance {
                wanted = earlier
            }
            if settings.floor > 0, wanted < settings.floor {
                wanted = settings.floor
            }
            return wanted - current > tolerance ? (target.entityId, rounded(wanted)) : nil
        }
    }

    /// Whether the account is now playing on the zone.
    static func hasLanded(on zone: MusicZone, account: HAEntityState?) -> Bool {
        guard let account, account.state == "playing", let source = zone.sourceName,
              let current = account.attributeString("source") else { return false }
        return current.normalizedZoneSourceName == source.normalizedZoneSourceName
    }

    private static func rounded(_ value: Double) -> Double {
        (min(max(value, 0), 1) * 100).rounded() / 100
    }
}

/// Runs the rules around a real start: the snapshot, the wait for the
/// handoff, the corrections. Also says when a start has just landed, for the
/// Now Playing card's volume strip.
@MainActor
final class StartVolumeGuard: ObservableObject {
    static let shared = StartVolumeGuard()

    /// What `prepare` took, for `protect`.
    struct Pending {
        let accountEntityId: String
        let zone: MusicZone
        let zones: [MusicZone]
        let targets: [StartVolume.Target]
        let before: [String: Double]
    }

    /// A start that has landed: which zone, and when.
    struct Landed: Equatable {
        let accountEntityId: String
        let zoneId: String
        let at: Date
    }

    struct Timings {
        /// How long the handoff gets to show up as playing on the zone
        /// before the corrections go out anyway. A claimed speaker can take
        /// 25 s.
        var landTimeout: Duration = .seconds(40)
        var pollInterval: Duration = .milliseconds(500)
        /// After it lands: the service sends its level a moment after
        /// playback starts, so the first pass waits for that.
        var settle: Duration = .seconds(3)
        /// A second pass, for a level that arrives late.
        var recheck: Duration = .seconds(4)
    }

    @Published private(set) var landed: Landed?

    var timings = Timings()
    /// Read at each start, so a config change applies to the next one.
    var settings: () -> StartVolumeConfiguration = {
        AppConfigurationLoader.launchConfiguration()?.media.startVolume ?? StartVolumeConfiguration()
    }

    private var task: Task<Void, Never>?

    /// Takes each of the zone's speakers' levels. Call just before the start
    /// is sent, before anything has moved.
    func prepare(zone: MusicZone, zones: [MusicZone], accountEntityId: String, client: any HAClientProtocol) -> Pending {
        let targets = StartVolume.targets(for: zone, zones: zones)
        let before = StartVolume.snapshot(targets) { client.entity($0)?.attributeDouble("volume_level") }
        return Pending(accountEntityId: accountEntityId, zone: zone, zones: zones, targets: targets, before: before)
    }

    /// Once the start has been sent: waits for it to land, then corrects the
    /// levels twice. A newer start replaces this one.
    func protect(_ pending: Pending, client: any HAClientProtocol) {
        task?.cancel()
        let settings = settings()
        let timings = timings
        task = Task { [weak self] in
            let background = UIApplication.shared.beginBackgroundTask(withName: "Start volume")
            defer { UIApplication.shared.endBackgroundTask(background) }
            await Self.waitUntilLanded(pending, client: client, timings: timings)
            guard !Task.isCancelled else { return }
            self?.landed = Landed(accountEntityId: pending.accountEntityId, zoneId: pending.zone.id, at: Date())
            for delay in [timings.settle, timings.recheck] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                Self.correct(pending, client: client, settings: settings)
            }
        }
    }

    /// Someone moved a volume by hand: what they set stands.
    func userChangedVolume() {
        task?.cancel()
        task = nil
    }

    /// Waits for the corrections to finish. For tests.
    func waitForCorrections() async {
        await task?.value
    }

    private static func waitUntilLanded(_ pending: Pending, client: any HAClientProtocol, timings: Timings) async {
        let deadline = ContinuousClock.now + timings.landTimeout
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if StartVolume.hasLanded(on: pending.zone, account: client.entity(pending.accountEntityId)) { return }
            try? await Task.sleep(for: timings.pollInterval)
        }
    }

    private static func correct(_ pending: Pending, client: any HAClientProtocol, settings: StartVolumeConfiguration) {
        let changes = StartVolume.corrections(
            for: pending.targets, before: pending.before,
            level: { client.entity($0)?.attributeDouble("volume_level") }, settings: settings)
        for change in changes {
            Log.music.note("Start volume: \(change.entityId) → \(change.level)")
            client.setVolume(change.entityId, level: change.level)
        }
    }
}

/// A volume slider that shows on the Now Playing card for a few seconds after
/// music starts, so turning it up or down doesn't mean scrolling to the
/// speaker list. A group moves all its speakers by the same amount, as the
/// Live Activity's bar does.
struct StartVolumeStrip: View {
    let accountEntityId: String
    let zones: [MusicZone]

    @EnvironmentObject private var haClient: HAWebSocketClient
    @ObservedObject private var volumeGuard = StartVolumeGuard.shared
    @State private var visibleZone: MusicZone?
    @State private var level: Double = 0
    @State private var isDragging = false
    @State private var hideTask: Task<Void, Never>?

    /// How long it stays up after the start, or after the last touch.
    static let visibleFor: Duration = .seconds(10)

    private var volumeEntityIds: [String] {
        visibleZone.map { ZonesActivityContent.volumeEntityIds(for: $0, zones: zones) } ?? []
    }

    private var remoteLevel: Double? {
        ZonesActivityContent.volume(of: volumeEntityIds) { haClient.entity($0) }
    }

    var body: some View {
        // A stack, not a Group: an empty Group has no view for onAppear and
        // onChange to hang on, so they'd never fire.
        VStack(spacing: 0) {
            if let zone = visibleZone, remoteLevel != nil {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                    Text(zone.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Slider(value: $level, in: 0...1, onEditingChanged: { editing in
                        isDragging = editing
                        volumeGuard.userChangedVolume()
                        scheduleHide()
                        if !editing { apply() }
                    })
                    .accessibilityLabel("\(zone.displayName) volume")
                    Text(level, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("start-volume-strip")
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visibleZone?.id)
        .onChange(of: volumeGuard.landed) { _, landed in show(landed) }
        .onChange(of: remoteLevel) { _, newValue in
            if !isDragging, let newValue { level = newValue }
        }
        .onAppear {
            show(volumeGuard.landed)
            #if DEBUG && targetEnvironment(simulator)
            if let demoZone = DemoMode.startVolumeZone, let zone = zones.first(where: { $0.id == demoZone }) {
                visibleZone = zone
                level = remoteLevel ?? 0
            }
            #endif
        }
    }

    private func show(_ landed: StartVolumeGuard.Landed?) {
        guard let landed, landed.accountEntityId == accountEntityId,
              Date().timeIntervalSince(landed.at) < 10,
              let zone = zones.first(where: { $0.id == landed.zoneId }) else { return }
        visibleZone = zone
        level = remoteLevel ?? 0
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, !isDragging else { return }
            visibleZone = nil
        }
    }

    private func apply() {
        for target in ZonesActivityContent.volumes(of: volumeEntityIds, settingTo: level, entity: { haClient.entity($0) }) {
            haClient.setVolume(target.entityId, level: target.level)
        }
    }
}
