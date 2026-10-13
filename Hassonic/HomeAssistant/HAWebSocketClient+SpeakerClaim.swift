import Foundation

/// Moving a speaker to a music account by voice command (Alexa Media
/// Player), driven by the config's `speakerClaim` recipe.
extension HAWebSocketClient {
    private func sendSpokenCommand(to entityId: String, phrase: String, contentType: String) {
        send(HASpokenCommandMessage(
            id: nextId(),
            target: .init(entityId: entityId),
            serviceData: .init(media: .init(mediaContentId: phrase, mediaContentType: contentType))
        ))
    }

    /// The Alexa entity's `last_called_response`, only if it's genuinely
    /// newer than `sentAt` — i.e. an actual answer to the command we just
    /// sent. Checking "is this recent" (within some fixed window) isn't
    /// enough: if an unrelated command got a response moments before we sent
    /// ours, that stale-but-recent response can look valid and get read as
    /// the answer to *our* command before Alexa has even processed it,
    /// misreporting the wrong account entirely. A small tolerance absorbs
    /// clock skew between this device and Home Assistant's server.
    private func responseSince(_ sentAt: Date, deviceEntityId: String, config: SpeakerClaimConfig) -> String? {
        guard let entity = entity(deviceEntityId) else { return nil }
        guard case .number(let ms)? = entity.attributes[config.confirmation.timestampAttribute] else { return nil }
        let calledAt = Date(timeIntervalSince1970: ms / 1000)
        guard calledAt > sentAt.addingTimeInterval(-2) else { return nil }
        return entity.attributeString(config.confirmation.responseAttribute)
    }

    private enum SingleAttemptOutcome {
        case confirmed
        case wrongAccount(response: String)
        case noResponse
    }

    private func friendlyDeviceName(_ entityId: String) -> String {
        entity(entityId)?.friendlyName ?? entityId
    }

    /// One "Switch to {account}'s account" command + poll, no retry — the
    /// caller decides what to do with wrong-account vs. no-response.
    private func attemptClaim(
        deviceEntityId: String,
        account: String,
        config: SpeakerClaimConfig
    ) async -> SingleAttemptOutcome {
        let phrase = SpeakerClaimConfig.render(config.command.phrase, account: account)
        let expected = SpeakerClaimConfig.render(config.confirmation.matches, account: account)
        let startedAt = Date()
        Log.homeAssistant.note("[claim] → \(deviceEntityId): \"\(phrase)\"")
        sendSpokenCommand(to: deviceEntityId, phrase: phrase, contentType: config.command.contentType)

        // The window has to cover a genuine round trip — command out, vendor
        // backend, spoken answer, attribute update. Measured over 11s on a
        // clean sample; too short and attempt 1 times out and fires a
        // needless, audible retry before the first answer has even arrived.
        while Date().timeIntervalSince(startedAt) < config.timings.replyTimeoutSeconds {
            try? await Task.sleep(for: .milliseconds(config.timings.pollIntervalMs))
            guard let response = responseSince(startedAt, deviceEntityId: deviceEntityId, config: config) else { continue }
            let elapsed = Date().timeIntervalSince(startedAt)
            if response.localizedCaseInsensitiveContains(expected) {
                Log.homeAssistant.note("[claim] \(deviceEntityId) confirmed in \(String(format: "%.2f", elapsed))s")
                return .confirmed
            }
            Log.homeAssistant.note("[claim] \(deviceEntityId) said \"\(response)\" after \(String(format: "%.2f", elapsed))s")
            return .wrongAccount(response: response)
        }
        Log.homeAssistant.note("[claim] \(deviceEntityId) gave no response after \(config.timings.replyTimeoutSeconds)s")
        return .noResponse
    }

    /// Binds `speaker` to `account`'s Spotify Connect session by sending
    /// Alexa voice commands directly, rather than through the HA rebinding
    /// script — that keeps timing fully in our control. Tries each device in
    /// `claimDeviceEntityIds` in order (first = primary): any failure (wrong
    /// account, or no response at all) gets one retry on the same device
    /// before moving to the next one — both can just be transient (flaky
    /// recognition, a busy backend), so a single retry is worth it before
    /// assuming the device itself is the problem. `onStatus` reports
    /// human-readable progress as this moves between devices/attempts, for
    /// driving a progress UI. `contentName`, if given, is a human-speakable
    /// name (e.g. "Taylor Swift") to force the handoff with directly instead
    /// of the generic placeholder — see the forcing-phrase comment below.
    func claimSpeaker(
        using config: SpeakerClaimConfig,
        account: String,
        speaker: String,
        contentName: String? = nil,
        onStatus: @escaping (String) -> Void = { _ in }
    ) async -> SpeakerClaimOutcome {
        guard !config.deviceEntityIds.isEmpty else {
            return .failed(reason: "No devices are configured that can claim a speaker for an account.")
        }

        for (index, deviceEntityId) in config.deviceEntityIds.enumerated() {
            let deviceName = friendlyDeviceName(deviceEntityId)
            let timeout = Int(config.timings.replyTimeoutSeconds)
            onStatus("Asking \(deviceName) to switch to \(account)'s account… (up to \(timeout)s)")

            var confirmed = false
            for attempt in 1...max(1, config.timings.attemptsPerDevice) {
                let outcome = await attemptClaim(deviceEntityId: deviceEntityId, account: account, config: config)
                if case .confirmed = outcome {
                    confirmed = true
                    break
                }
                let failureDescription: String
                switch outcome {
                case .wrongAccount(let response): failureDescription = "said \"\(response)\""
                case .noResponse: failureDescription = "didn't respond"
                case .confirmed: failureDescription = ""
                }
                onStatus(attempt < config.timings.attemptsPerDevice
                    ? "\(deviceName) \(failureDescription) — trying again… (up to \(timeout)s)"
                    : "\(deviceName) still \(failureDescription).")
            }

            if confirmed {
                onStatus("Starting playback on \(speaker)…")
                // A pause before the second command to the same device. Sent
                // immediately after the first confirms, the vendor's backend
                // drops it silently — no reply attribute update at all —
                // presumably still finishing the first.
                try? await Task.sleep(for: .milliseconds(config.timings.commandCooldownMs))
                // Real content, not a generic "play on X": confirmed by live
                // A/B test that the plain phrase doesn't force an actual
                // handoff (silent, zone never claimed) while real content
                // does. Naming the actually-requested content beats a
                // placeholder plus a correcting call afterwards — that call
                // can be dropped while the handoff settles (measured at 45s+),
                // stranding playback on the placeholder. See
                // docs/SPOTIFY_AND_ALEXA.md.
                let playPhrase = SpeakerClaimConfig.render(
                    config.playback.phrase,
                    account: account,
                    speaker: speaker,
                    content: contentName ?? config.playback.fallbackContent
                )
                Log.homeAssistant.note("[claim] → \(deviceEntityId): \"\(playPhrase)\"")
                sendSpokenCommand(to: deviceEntityId, phrase: playPhrase, contentType: config.command.contentType)
                // The play command needs a moment to take effect even once
                // the claim itself is confirmed.
                try? await Task.sleep(for: .seconds(config.timings.settleSeconds))
                return .confirmed(usedDevice: deviceName)
            }

            if index < config.deviceEntityIds.count - 1 {
                onStatus("Trying \(friendlyDeviceName(config.deviceEntityIds[index + 1])) instead…")
            }
        }
        return .failed(reason: "None of the configured devices could switch to \(account)'s account.")
    }
}
