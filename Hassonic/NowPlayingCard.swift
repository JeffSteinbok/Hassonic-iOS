import SwiftUI

struct NowPlayingCard: View {
    let entity: HAEntityState?
    let presentation: NowPlayingPresentation
    let mediaEntityId: String
    let accountDisplayName: String
    let speakerClaim: SpeakerClaimConfig?
    let zones: [MusicZone]
    @EnvironmentObject private var haClient: HAWebSocketClient
    @EnvironmentObject private var router: AppRouter

    @State private var showingPlayOnSheet = false
    /// Unused here — NowPlayingCard's PlayOnSheet only ever queues `.playPause`,
    /// which has no drop-risk-on-fresh-switch content to resend. Required
    /// because PlayOnSheet's init needs the binding regardless.
    @State private var zoneSwitchedAccount = false
    /// Home Assistant only reports `source` while actively streaming, so this
    /// remembers the last target picked in the Play On sheet as a fallback
    /// for when playback is idle/paused and HA omits the attribute entirely.
    /// Keyed per-account (see init) — without that, switching accounts would
    /// leak one account's last-picked zone into the other's "active source"
    /// check, making it look like something's already playing when it isn't.
    @AppStorage("lastPlayOnSourceName") private var lastPlayOnSourceName: String = ""
    /// Deferred action to fire once the user picks a zone when none was active.
    @State private var pendingPlayAction: PendingPlayAction?
    @State private var playOnZonePicked = false

    init(entity: HAEntityState?, presentation: NowPlayingPresentation, mediaEntityId: String, accountDisplayName: String, speakerClaim: SpeakerClaimConfig?, zones: [MusicZone]) {
        self.entity = entity
        self.presentation = presentation
        self.mediaEntityId = mediaEntityId
        self.accountDisplayName = accountDisplayName
        self.speakerClaim = speakerClaim
        self.zones = zones
        self._lastPlayOnSourceName = AppStorage(wrappedValue: "", StorageKeys.lastPlayOnSource(account: mediaEntityId))
    }

    /// Set immediately on tap so the play/pause icon flips without waiting on
    /// Home Assistant's round trip; cleared once the real entity state confirms
    /// it, or after `optimisticPlayingTimeout` in case the command never lands.
    @State private var optimisticIsPlaying: Bool?
    @State private var optimisticPlayingTask: Task<Void, Never>?
    /// Greys out play/pause while waiting on `optimisticIsPlaying` to be confirmed.
    @State private var isPlayPausePending = false
    /// Home Assistant rarely confirms a skip fast enough to feel connected to the
    /// tap, so these just grey the button briefly to acknowledge it was sent, then
    /// reset on a short timer regardless of whether HA has actually caught up —
    /// waiting for real confirmation would make the button look stuck.
    @State private var isPreviousPending = false
    @State private var isNextPending = false
    @State private var previousPendingTask: Task<Void, Never>?
    @State private var nextPendingTask: Task<Void, Never>?

    private var hasMedia: Bool { presentation.hasMedia }
    private var isPlaying: Bool { optimisticIsPlaying ?? (entity?.state == "playing") }

    private var effectiveActiveSource: String? {
        entity?.attributeString("source") ?? (lastPlayOnSourceName.isEmpty ? nil : lastPlayOnSourceName)
    }

    private var activeZoneName: String {
        guard let effectiveActiveSource else { return "Choose speakers" }
        return zones.first { $0.sourceName == effectiveActiveSource }?.displayName ?? effectiveActiveSource
    }

    private var primaryForeground: AnyShapeStyle {
        hasMedia ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
    }

    private var secondaryForeground: AnyShapeStyle {
        hasMedia ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary)
    }

    private var controlForeground: AnyShapeStyle {
        hasMedia ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                if hasMedia {
                    FillImage(url: presentation.artworkURL, fallback: .gray.opacity(0.3))
                    // Bottom scrim: starts above centre so controls, progress, and
                    // title/artist are always readable regardless of artwork brightness.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.20),
                            .init(color: .black.opacity(0.92), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // Top scrim protects controls when artwork is bright near the top.
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.45), location: 0.0),
                            .init(color: .clear, location: 0.30)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color(.systemBackground)
                    NowPlayingPlaceholderView()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(presentation.title ?? "Nothing Playing")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(primaryForeground)
                        .lineLimit(2)
                        .shadow(color: hasMedia ? .black.opacity(0.6) : .clear, radius: 4, x: 0, y: 1)

                    if let artist = presentation.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(secondaryForeground)
                            .shadow(color: hasMedia ? .black.opacity(0.6) : .clear, radius: 4, x: 0, y: 1)
                    }

                    PlaybackProgressView(presentation: presentation)

                    HStack(spacing: 28) {
                        Button {
                            lightTapHaptic()
                            triggerPreviousPending()
                            haClient.mediaPreviousTrack(mediaEntityId)
                        } label: {
                            Image(systemName: "backward.fill")
                        }
                        .disabled(isPreviousPending)
                        .opacity(isPreviousPending ? 0.4 : 1)
                        Button {
                            lightTapHaptic()
                            if effectiveActiveSource != nil {
                                setOptimisticPlaying(!isPlaying)
                                haClient.mediaPlayPause(mediaEntityId)
                            } else {
                                pendingPlayAction = .playPause
                                showingPlayOnSheet = true
                            }
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .disabled(isPlayPausePending)
                        .opacity(isPlayPausePending ? 0.4 : 1)
                        Button {
                            lightTapHaptic()
                            triggerNextPending()
                            haClient.mediaNextTrack(mediaEntityId)
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .disabled(isNextPending)
                        .opacity(isNextPending ? 0.4 : 1)
                    }
                    .font(.title2)
                    .foregroundStyle(controlForeground)
                    .buttonStyle(PressFeedbackIconButtonStyle())
                    .shadow(color: hasMedia ? .black.opacity(0.5) : .clear, radius: 3, x: 0, y: 1)
                    // Nothing to control when nothing's playing — hidden but
                    // still reserves its layout space so the card doesn't
                    // jump when playback starts/stops.
                    .opacity(hasMedia ? 1 : 0)
                    .allowsHitTesting(hasMedia)
                }
                .padding()
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityIdentifier("now-playing-artwork-card")

            destinationButton
                .opacity(hasMedia ? 1 : 0)
                .allowsHitTesting(hasMedia)
        }
        .sheet(isPresented: $showingPlayOnSheet, onDismiss: {
            router.musicShowPlayOn = false
            if playOnZonePicked, let action = pendingPlayAction {
                pendingPlayAction = nil
                playOnZonePicked = false
                switch action {
                case .playPause:
                    setOptimisticPlaying(!isPlaying)
                    haClient.mediaPlayPause(mediaEntityId)
                case .playMedia:
                    break
                }
            } else {
                pendingPlayAction = nil
                playOnZonePicked = false
            }
        }) {
            PlayOnSheet(mediaEntityId: mediaEntityId, accountDisplayName: accountDisplayName, speakerClaim: speakerClaim, zones: zones, activeSource: effectiveActiveSource, lastPlayOnSourceName: $lastPlayOnSourceName, zonePicked: $playOnZonePicked, zoneSwitchedAccount: $zoneSwitchedAccount, desiredContentName: nil)
        }
        .onChange(of: router.musicShowPlayOn) { _, newValue in
            if newValue { showingPlayOnSheet = true }
        }
        .onChange(of: entity?.state) { _, newState in
            confirmOptimisticPlaying(against: newState)
        }
    }

    /// Flips the play/pause icon immediately and greys it out until Home
    /// Assistant's state confirms the change (or the timeout below fires).
    private func setOptimisticPlaying(_ playing: Bool) {
        optimisticPlayingTask?.cancel()
        optimisticIsPlaying = playing
        isPlayPausePending = true
        optimisticPlayingTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            optimisticIsPlaying = nil
            isPlayPausePending = false
        }
    }

    private func confirmOptimisticPlaying(against newState: String?) {
        guard let optimisticIsPlaying, (newState == "playing") == optimisticIsPlaying else { return }
        optimisticPlayingTask?.cancel()
        optimisticPlayingTask = nil
        self.optimisticIsPlaying = nil
        isPlayPausePending = false
    }

    private func triggerPreviousPending() {
        previousPendingTask?.cancel()
        isPreviousPending = true
        previousPendingTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isPreviousPending = false
        }
    }

    private func triggerNextPending() {
        nextPendingTask?.cancel()
        isNextPending = true
        nextPendingTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isNextPending = false
        }
    }

    private var destinationButton: some View {
        Button {
            showingPlayOnSheet = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(nowPlayingDestinationLabel(activeSource: effectiveActiveSource))
                if effectiveActiveSource != nil {
                    Text(activeZoneName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("now-playing-destination-control")
    }
}

struct PlaybackProgressView: View {
    let presentation: NowPlayingPresentation
    @State private var elapsed: Double = 0

    private var clockIdentity: String {
        let position = presentation.anchorPosition.map { String($0) } ?? ""
        let updatedAt = presentation.anchorUpdatedAt?.timeIntervalSinceReferenceDate.description ?? ""
        let duration = presentation.duration.map { String($0) } ?? ""
        return "\(presentation.state)|\(position)|\(updatedAt)|\(duration)"
    }

    var body: some View {
        if let duration = presentation.duration, let anchorPosition = presentation.anchorPosition {
            VStack(spacing: 6) {
                ProgressView(value: elapsed, total: duration)
                    .tint(presentation.hasMedia ? .white.opacity(0.9) : .accentColor)
                HStack {
                    Text(formatTime(elapsed))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(presentation.hasMedia ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .task(id: clockIdentity) {
                elapsed = playbackElapsed(
                    anchorPosition: anchorPosition,
                    anchorDate: presentation.anchorUpdatedAt,
                    state: presentation.state,
                    duration: duration,
                    now: Date()
                )
                guard presentation.state == "playing" else { return }

                var previousTick = Date()
                while !Task.isCancelled && elapsed < duration {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }

                    let currentTick = Date()
                    elapsed = advancePlaybackElapsed(
                        current: elapsed,
                        state: presentation.state,
                        duration: duration,
                        elapsedTime: currentTick.timeIntervalSince(previousTick)
                    )
                    previousTick = currentTick
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.towardZero)))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
