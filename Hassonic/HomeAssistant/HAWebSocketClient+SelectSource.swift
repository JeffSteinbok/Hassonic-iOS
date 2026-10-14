import Foundation

/// `select_source` with confirmation: waits for the account entity's
/// `source` to change, since the service call itself reports success even
/// when nothing happened.
extension HAWebSocketClient {
    func selectSourceConfirmed(_ entityId: String, source: String) async -> SelectSourceResult {
        await selectSourceConfirmed(entityId, source: source, timeout: selectSourceTimeout)
    }

    /// `timeout` matters: a fresh Connect handoff (e.g. right after
    /// claimSpeaker forces one via Alexa) can take noticeably
    /// longer than the default 5s probe window for HA's polled `source`
    /// attribute to catch up — measured live at 10s+. Using the short
    /// default there stranded playback on the forcing "Play U2..." track:
    /// the retry gave up before `source` caught up, so PlayOnSheet reported
    /// failure and never sent the actually-requested content.
    func selectSourceConfirmed(_ entityId: String, source: String, timeout: Duration) async -> SelectSourceResult {
        let currentSource = entity(entityId)?.attributeString("source")
        let normalizedCurrent = currentSource?.normalizedZoneSourceName
        let normalizedTarget = source.normalizedZoneSourceName
        if normalizedCurrent == normalizedTarget {
            return .alreadyActive
        }

        let messageId = nextId()
        let startedAt = Date()
        return await withCheckedContinuation { continuation in
            pendingSelectSources[messageId] = PendingSelectSource(
                messageId: messageId,
                expectedSource: source,
                entityId: entityId,
                continuation: continuation,
                startedAt: startedAt
            )
            send(HASelectSourceMessage(id: messageId, target: .init(entityId: entityId), serviceData: .init(source: source)))
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: timeout)
                if let pending = self.pendingSelectSources.removeValue(forKey: messageId) {
                    let elapsed = Date().timeIntervalSince(pending.startedAt)
                    Log.homeAssistant.note("selectSource timeout after \(String(format: "%.2f", elapsed))s for \(entityId) → \(source)")
                    pending.continuation.resume(returning: .timeout)
                }
            }
        }
    }
}
