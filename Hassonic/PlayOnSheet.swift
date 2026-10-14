import SwiftUI

struct PlayOnSheet: View {
    let mediaEntityId: String
    let accountDisplayName: String
    let speakerClaim: SpeakerClaimConfig?
    let zones: [MusicZone]
    let activeSource: String?
    @Binding var lastPlayOnSourceName: String
    @Binding var zonePicked: Bool
    /// Set when this pick required an actual Alexa account switch, as opposed
    /// to the zone already being on this account — callers use this to decide
    /// whether the just-picked content needs the drop-resistant resend (see
    /// FavoritesBar's onDismiss).
    @Binding var zoneSwitchedAccount: Bool
    /// Human-speakable name of the specific content being requested (e.g.
    /// "Taylor Swift"), if this pick came from a favorite — when set, a
    /// fresh account switch asks Alexa for this exact content directly
    /// instead of a generic placeholder, so the zone doesn't get stranded on
    /// unrelated forcing content while a follow-up API call settles. `nil`
    /// for switches with no specific content in mind (e.g. just changing
    /// which zone is active).
    let desiredContentName: String?
    @EnvironmentObject private var haClient: HAWebSocketClient
    @Environment(\.dismiss) private var dismiss

    @State private var switchError: String? = nil
    @State private var activeSwitchZone: MusicZone? = nil
    /// Drives the status overlay's message — updated live as performSwitch
    /// moves through steps/devices, so the user sees exactly what's happening
    /// (which device is being asked, retries, fallbacks) rather than one
    /// generic "moving…" message for the whole multi-step process.
    @State private var statusText: String = ""
    /// A rough visual estimate, not tied to actual completion — each phase
    /// animates toward a checkpoint over its typical duration, but the
    /// moment a phase actually finishes (faster or slower than typical) this
    /// snaps quickly to the next checkpoint rather than waiting out the
    /// animation, so success never feels stuck behind a slow progress bar.
    @State private var switchProgress: Double = 0

    private func castableZones(kind: MusicZone.Kind) -> [MusicZone] {
        zones
            .filter { $0.kind == kind && $0.sourceName != nil && $0.isEnabled }
            .filter { zone in haClient.entity(zone.entityId)?.isAvailable == true }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = switchError {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                Section("Groups") {
                    ForEach(castableZones(kind: .group)) { zone in row(zone) }
                }
                Section("Individual Speakers") {
                    ForEach(castableZones(kind: .speaker)) { zone in row(zone) }
                }
            }
            .navigationTitle("Play On")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        // Mid-switch the sheet stays up: closing it would let the switch
        // finish behind it and leave the zone marked as picked.
        .interactiveDismissDisabled(activeSwitchZone != nil)
        .overlay {
            if activeSwitchZone != nil {
                statusOverlay
            }
        }
    }

    private var statusOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: switchProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .animation(nil, value: statusText)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(40)
        }
    }

    /// Animates toward `value` over `duration` — used when entering a phase,
    /// paced to that phase's typical duration.
    private func animateProgress(to value: Double, over duration: Double) {
        withAnimation(.linear(duration: duration)) { switchProgress = value }
    }

    /// Snaps quickly to `value` — used the moment a phase actually resolves,
    /// so the bar catches up instantly instead of visibly lagging behind.
    private func snapProgress(to value: Double) {
        withAnimation(.easeOut(duration: 0.25)) { switchProgress = value }
    }

    /// `castableZones` only ever passes zones with a non-nil `sourceName`,
    /// but this guards it directly rather than trusting that invariant at the call site.
    @ViewBuilder
    private func row(_ zone: MusicZone) -> some View {
        if let source = zone.sourceName {
            let isMovingThis = activeSwitchZone?.id == zone.id
            let isAnyPending = activeSwitchZone != nil

            Button {
                guard !isAnyPending else { return }
                switchError = nil
                Task {
                    await performSwitch(source: source, zone: zone)
                }
            } label: {
                HStack {
                    Image(systemName: zone.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text(zone.displayName)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isMovingThis {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if source == activeSource && !isAnyPending {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .disabled(isAnyPending)
        }
    }

    /// 1. Try select_source directly — the common case where the zone's
    ///    already on this account.
    /// 2. select_source "succeeds" with no error even when the zone isn't
    ///    reachable, so a confirmed timeout is the only signal that it
    ///    isn't — infer "not bound" from that rather than pre-checking
    ///    source_list (which lags real state by up to ~90s).
    /// 3. Claim the zone for this account via Alexa (tries each configured
    ///    device in order, with its own wrong-account retry / no-response
    ///    fallback — see HAWebSocketClient.claimSpeaker).
    /// 4. Try select_source again now that it should be bound.
    private func performSwitch(source: String, zone: MusicZone) async {
        activeSwitchZone = zone
        statusText = "Switching to \(zone.displayName)…"
        switchProgress = 0
        zoneSwitchedAccount = false
        animateProgress(to: 0.15, over: 4)

        Log.music.note("PlayOnSheet: [try] select_source \(mediaEntityId) → \(source)")
        var result = await haClient.selectSourceConfirmed(mediaEntityId, source: source)
        Log.music.note("PlayOnSheet: [try] result=\(result)")

        if case .timeout = result {
            Log.music.note("PlayOnSheet: [detect] no change for \(zone.displayName) — not on \(accountDisplayName)'s account")
            snapProgress(to: 0.2)
            statusText = "\(zone.displayName) isn't on \(accountDisplayName)'s account yet…"
            animateProgress(to: 0.85, over: 12)

            guard let speakerClaim else {
                // Nothing configured can claim a speaker, so this zone simply
                // isn't on this account and we can't change that. Say so
                // rather than failing at a step that was never available.
                switchError = "\(zone.displayName) isn't on \(accountDisplayName)'s account, "
                    + "and no device is configured that can switch it."
                activeSwitchZone = nil
                snapProgress(to: 0)
                return
            }

            let outcome = await haClient.claimSpeaker(
                using: speakerClaim,
                account: accountDisplayName,
                speaker: zone.displayName,
                contentName: desiredContentName,
                onStatus: { status in statusText = status }
            )
            Log.music.note("PlayOnSheet: [move] outcome=\(outcome)")

            guard case .confirmed = outcome else {
                if case .failed(let reason) = outcome {
                    switchError = reason
                }
                activeSwitchZone = nil
                snapProgress(to: 0)
                return
            }
            zoneSwitchedAccount = true

            snapProgress(to: 0.85)
            statusText = "Confirming \(zone.displayName)… (up to 15s)"
            animateProgress(to: 1.0, over: 15)
            Log.music.note("PlayOnSheet: [retry] select_source \(mediaEntityId) → \(source)")
            // Longer than the default probe timeout: this is confirming a
            // handoff that Alexa just forced live, and HA's polled `source`
            // attribute measurably lags that by 10s+ in practice — see
            // selectSourceConfirmed's timeout: param doc.
            result = await haClient.selectSourceConfirmed(mediaEntityId, source: source, timeout: .seconds(15))
            Log.music.note("PlayOnSheet: [retry] result=\(result)")
            if case .timeout = result {
                // Alexa already confirmed the switch and forced a real,
                // audible Connect handoff — that's solid evidence the zone
                // really is bound now. HA's polled `source` attribute can
                // lag behind that longer than we're willing to block the UI
                // for (observed live: still catching up past 15s). Treating
                // this as a hard failure stranded the user on the forcing
                // "Play U2..." track instead of ever sending the content
                // they actually asked for — proceed instead.
                Log.music.note("PlayOnSheet: [retry] timed out waiting on source, but Alexa already confirmed — proceeding anyway")
                result = .confirmed
            }
        }

        switch result {
        case .alreadyActive, .confirmed:
            snapProgress(to: 1.0)
            // Brief pause so the bar visibly reaches 100% rather than
            // vanishing the instant it gets there.
            try? await Task.sleep(for: .milliseconds(200))
            activeSwitchZone = nil
            lastPlayOnSourceName = source
            zonePicked = true
            dismiss()
        case .timeout:
            activeSwitchZone = nil
            switchError = "Couldn't confirm \(zone.displayName), even after moving it. Try again."
        case .error(let message):
            activeSwitchZone = nil
            switchError = "Could not switch to \(zone.displayName): \(message)"
        }
    }
}
