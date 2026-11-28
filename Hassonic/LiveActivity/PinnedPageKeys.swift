import Foundation

/// The keys a pinned page's Live Activity offers, from its first TV remote:
/// the card's `lockScreen` list (which may name the TV's apps, `app.Netflix`), or else the TV's power, volume and mute and
/// play/pause on the box (on the TV when there's no box). Kept free of
/// ActivityKit so it can be tested.
enum PinnedPageKeys {
    typealias Key = PinnedPageActivityAttributes.Key
    typealias Action = PinnedPageActivityAttributes.Action
    typealias LockScreenKey = DashboardTVRemoteConfiguration.LockScreenKey

    static func keys(for page: DashboardPageConfiguration) -> [Key] {
        let remote = page.sections.lazy.flatMap(\.cards).compactMap { card -> DashboardTVRemoteConfiguration? in
            if case .tvRemote(let remote) = card { return remote } else { return nil }
        }.first
        guard let remote else { return [] }

        // Chosen keys are captioned, since two can share a symbol: a play/pause
        // for each device.
        if let names = remote.lockScreen {
            return names.compactMap(LockScreenKey.init).compactMap { lockScreenKey in
                switch lockScreenKey {
                case .open:
                    return Key(id: "open", label: "Open \(page.title)", systemImage: page.systemIcon, actions: [], caption: "Open")
                case .key(let key, let side):
                    let caption = remote.tv != nil && remote.box != nil ? remote.device(side)?.displayName : key.label
                    return self.key(key, on: side, of: remote, caption: caption)
                case .app(let name):
                    guard let app = remote.tvApp(named: name) else { return nil }
                    let actions = remote.appActions(app).compactMap(action)
                    guard !actions.isEmpty else { return nil }
                    return Key(id: "app.\(app.name)", label: "Open \(app.name)",
                               systemImage: app.systemImage(on: remote.tv?.kind ?? .samsung),
                               actions: actions, caption: app.name)
                }
            }
        }

        let volumeSide: TVRemoteSide = remote.tv != nil ? .tv : .box
        let playSide: TVRemoteSide = remote.box != nil ? .box : .tv
        return [(.power, volumeSide), (.volumeDown, volumeSide), (.mute, volumeSide), (.volumeUp, volumeSide), (.playPause, playSide)]
            .compactMap { key($0, on: $1, of: remote, caption: nil) }
    }

    private static func key(_ key: TVRemoteKey, on side: TVRemoteSide, of remote: DashboardTVRemoteConfiguration, caption: String?) -> Key? {
        let actions = remote.actions(for: key, on: side).compactMap(action)
        guard !actions.isEmpty, let device = remote.device(side) else { return nil }
        return Key(id: "\(side.rawValue).\(key)", label: "\(device.displayName) \(key.label)",
                   systemImage: key.systemImage, actions: actions, caption: caption)
    }

    static func action(_ action: TVRemoteAction) -> Action? {
        switch action {
        case .send(let remote, let command): return Action(kind: .send, entityId: remote, command: command)
        case .mediaPlayPause(let mediaPlayer): return Action(kind: .mediaPlayPause, entityId: mediaPlayer)
        case .samsungPlayPause(let remote): return Action(kind: .samsungPlayPause, entityId: remote)
        case .runScript(let script): return Action(kind: .runScript, entityId: script)
        case .sendText: return nil
        case .openApp(let mediaPlayer, let source, let powerScript):
            return Action(kind: .openApp, entityId: mediaPlayer, command: source, script: powerScript)
        }
    }

    static func remoteAction(_ action: Action) -> TVRemoteAction? {
        switch action.kind {
        case .send: return action.command.map { .send(remote: action.entityId, command: $0) }
        case .mediaPlayPause: return .mediaPlayPause(mediaPlayer: action.entityId)
        case .samsungPlayPause: return .samsungPlayPause(remote: action.entityId)
        case .runScript: return .runScript(script: action.entityId)
        case .openApp: return action.command.map { .openApp(mediaPlayer: action.entityId, source: $0, powerScript: action.script) }
        }
    }
}
