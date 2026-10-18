import Foundation

// A `tv_remote` card drives up to two devices, a TV and a box plugged into it,
// each from its own panel that is always on screen. How a device spells each
// key is its `kind`, below.

/// A brand the remote knows how to speak to. Each is one Home Assistant
/// integration's `remote.send_command` vocabulary.
enum TVRemoteDeviceKind: String, Decodable, Equatable {
    /// SamsungTV Smart (HACS) or HA's built-in Samsung Smart TV integration;
    /// both take the same key codes.
    case samsung
    /// The `xfinity_remote` custom integration.
    case xfinity

    var displayName: String {
        switch self {
        case .samsung: return "Samsung TV"
        case .xfinity: return "Xfinity"
        }
    }

    /// Sources that are an input rather than an app. The TV's media player
    /// lists both in `source_list`, and Samsung reports any HDMI port, the
    /// tuner and AirPlay all as `TV/HDMI`.
    func isInput(_ source: String) -> Bool {
        switch self {
        case .samsung:
            return ["TV", "HDMI", "TV/HDMI"].contains(source) || source.hasPrefix("HDMI")
        case .xfinity:
            return false
        }
    }
}

/// Which of the card's two panels.
enum TVRemoteSide: String, Equatable {
    case tv, box
}

/// The keys the panels draw.
enum TVRemoteKey: CaseIterable {
    case power
    case volumeUp, volumeDown, mute
    case up, down, left, right, ok
    case back, home, exit, info, guide, menu
    case pageUp, pageDown
    case channelUp, channelDown
    case rewind, playPause, fastForward, record
    case keyA, keyB, keyC, keyD
    /// On the number pad: the previous channel, and confirm.
    case lastChannel, enter

    init(_ direction: RemoteDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .ok: self = .ok
        }
    }

    /// Its name in the config: the case name, e.g. `playPause`.
    init?(name: String) {
        guard let key = Self.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = key
    }

    /// The symbol it's drawn with where the card doesn't draw it specially,
    /// e.g. on the Lock Screen.
    var systemImage: String {
        switch self {
        case .power: return "power"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .ok, .enter: return "circle"
        case .back, .lastChannel: return "arrow.uturn.backward"
        case .home: return "house"
        case .exit: return "xmark"
        case .info: return "info"
        case .guide: return "list.bullet.rectangle"
        case .menu: return "line.3.horizontal"
        case .pageUp: return "chevron.up.2"
        case .pageDown: return "chevron.down.2"
        case .channelUp: return "plus"
        case .channelDown: return "minus"
        case .rewind: return "backward.fill"
        case .playPause: return "playpause.fill"
        case .fastForward: return "forward.fill"
        case .record: return "record.circle"
        case .keyA: return "a.circle"
        case .keyB: return "b.circle"
        case .keyC: return "c.circle"
        case .keyD: return "d.circle"
        }
    }

    /// The command for this key on `kind`, or nil if it has none. Samsung
    /// play/pause is nil too: it has no single key code (see
    /// `TVRemoteAction.samsungPlayPause`).
    func command(on kind: TVRemoteDeviceKind) -> String? {
        switch kind {
        case .xfinity:
            switch self {
            // Xfinity's TV keys go over HDMI-CEC, which not every TV honours.
            case .power: return "tv_power_off"
            case .volumeUp: return "volume_up"
            case .volumeDown: return "volume_down"
            case .mute: return "tv_mute"
            case .up: return "up"
            case .down: return "down"
            case .left: return "left"
            case .right: return "right"
            case .ok, .enter: return "ok"
            // X1 has no separate Back: `last` (PREV) is both.
            case .back, .lastChannel: return "last"
            // The "xfinity" button opens the main menu.
            case .home, .menu: return "menu"
            case .exit: return "exit"
            case .info: return "info"
            case .guide: return "guide"
            case .pageUp: return "page_up"
            case .pageDown: return "page_down"
            case .channelUp: return "channel_up"
            case .channelDown: return "channel_down"
            case .rewind: return "rewind"
            case .playPause: return "play_pause"
            case .fastForward: return "fast_forward"
            case .record: return "record"
            case .keyA: return "key_a"
            case .keyB: return "key_b"
            case .keyC: return "key_c"
            case .keyD: return "key_d"
            }
        case .samsung:
            switch self {
            case .power: return "KEY_POWER"
            case .volumeUp: return "KEY_VOLUP"
            case .volumeDown: return "KEY_VOLDOWN"
            case .mute: return "KEY_MUTE"
            case .up: return "KEY_UP"
            case .down: return "KEY_DOWN"
            case .left: return "KEY_LEFT"
            case .right: return "KEY_RIGHT"
            case .ok, .enter: return "KEY_ENTER"
            case .back: return "KEY_RETURN"
            case .home: return "KEY_HOME"
            case .menu: return "KEY_MENU"
            case .exit: return "KEY_EXIT"
            case .info: return "KEY_INFO"
            case .guide: return "KEY_GUIDE"
            case .lastChannel: return "KEY_PRECH"
            case .pageUp, .pageDown: return nil
            case .channelUp: return "KEY_CHUP"
            case .channelDown: return "KEY_CHDOWN"
            case .rewind: return "KEY_REWIND"
            case .playPause: return nil
            case .fastForward: return "KEY_FF"
            case .record: return "KEY_REC"
            case .keyA: return "KEY_RED"
            case .keyB: return "KEY_GREEN"
            case .keyC: return "KEY_YELLOW"
            case .keyD: return "KEY_CYAN"
            }
        }
    }

    /// A number key's command on `kind`.
    static func digit(_ digit: Int, on kind: TVRemoteDeviceKind) -> String {
        switch kind {
        case .xfinity: return "number_\(digit)"
        case .samsung: return "KEY_\(digit)"
        }
    }

    var label: String {
        switch self {
        case .power: return "Power"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .ok: return "OK"
        case .back: return "Back"
        case .home: return "Home"
        case .exit: return "Exit"
        case .info: return "Info"
        case .guide: return "Guide"
        case .menu: return "Menu"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .channelUp: return "Channel Up"
        case .channelDown: return "Channel Down"
        case .rewind: return "Rewind"
        case .playPause: return "Play/Pause"
        case .fastForward: return "Fast Forward"
        case .record: return "Record"
        case .keyA: return "A"
        case .keyB: return "B"
        case .keyC: return "C"
        case .keyD: return "D"
        case .lastChannel: return "Last Channel"
        case .enter: return "Enter"
        }
    }
}

/// One thing to ask Home Assistant for.
enum TVRemoteAction: Equatable {
    case send(remote: String, command: String)
    case mediaPlayPause(mediaPlayer: String)
    /// Samsung with no media player: alternate KEY_PAUSE and KEY_PLAY.
    case samsungPlayPause(remote: String)
    case runScript(script: String)
    /// What you'd say into the box's voice remote, as text ("watch ESPN").
    case sendText(remote: String, text: String)
}

/// The `tv_remote` card.
///
///     - type: tv_remote
///       title: Family Room
///       tv:  { kind: samsung, remote: remote.tv, mediaPlayer: media_player.tv }
///       box: { kind: xfinity, remote: remote.xfinity }
///       lockScreen: [open, tv.playPause, box.playPause]
struct DashboardTVRemoteConfiguration: Decodable, Equatable {
    struct Device: Decodable, Equatable {
        let kind: TVRemoteDeviceKind
        /// The integration's `remote.*` entity.
        let remote: String
        /// The TV's `media_player.*`, which gives Samsung a real play/pause
        /// toggle.
        var mediaPlayer: String?
        /// The panel's label; defaults to the kind's name.
        var name: String?
        /// A `script.*` the power key runs instead of sending the kind's
        /// power command, e.g. one that blasts IR to turn on a TV whose
        /// network remote is asleep while it's off.
        var power: String?
        /// Saved spoken commands for a box that takes them, offered by its
        /// favorites key: `{ name: ESPN, say: "watch ESPN" }`.
        var favorites: [VoiceFavorite]?

        var displayName: String { name ?? kind.displayName }
    }

    /// A command you'd otherwise say, saved under a short name.
    struct VoiceFavorite: Decodable, Equatable, Identifiable {
        let name: String
        /// Sent as if spoken into the voice remote.
        let say: String
        /// An SF Symbol beside the name in the menu.
        var icon: String?

        var id: String { name }
    }

    /// A key on the page's pinned Lock Screen activity: `open` for the page
    /// itself, or a side and key, e.g. `box.playPause`.
    enum LockScreenKey: Equatable {
        case open
        case key(TVRemoteKey, TVRemoteSide)

        init?(_ name: String) {
            if name == "open" {
                self = .open
                return
            }
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let side = TVRemoteSide(rawValue: parts[0]),
                  let key = TVRemoteKey(name: parts[1]) else { return nil }
            self = .key(key, side)
        }
    }

    let title: String?
    var tv: Device?
    var box: Device?
    /// The keys the page's pinned Lock Screen activity shows, in order. Nil
    /// means the TV's power, volume and mute and the box's play/pause.
    var lockScreen: [String]?

    init(title: String? = nil, tv: Device? = nil, box: Device? = nil, lockScreen: [String]? = nil) {
        self.title = title
        self.tv = tv
        self.box = box
        self.lockScreen = lockScreen
    }

    func device(_ side: TVRemoteSide) -> Device? {
        side == .tv ? tv : box
    }

    /// Whether the box takes spoken commands: an Xfinity box does, through
    /// its integration's `send_text`.
    var boxTakesVoice: Bool { box?.kind == .xfinity }

    /// The saved commands the favorites key offers; none for a box that
    /// can't take them.
    var voiceFavorites: [VoiceFavorite] {
        boxTakesVoice ? (box?.favorites ?? []).filter { !$0.name.isEmpty && !$0.say.isEmpty } : []
    }

    /// A spoken command for the box, sent as the words themselves.
    func voiceActions(_ text: String) -> [TVRemoteAction] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard boxTakesVoice, let box, !text.isEmpty else { return [] }
        return [.sendText(remote: box.remote, text: text)]
    }

    /// Whether the TV is certainly off, from its media player's state. Not
    /// when it's unavailable or there's no media player: then the keys
    /// stay usable, since it may well be on.
    func tvIsOff(mediaPlayerState state: String?) -> Bool {
        tv?.mediaPlayer != nil && ["off", "standby"].contains(state)
    }

    /// The app the TV is certainly showing, from its media player's `source`
    /// and `source_list`: a listed source that isn't an input. Nil when it's
    /// on an input (the box, AirPlay, …) or unknown.
    func runningApp(source: String?, sourceList: [String]) -> String? {
        guard let tv, let source, !source.isEmpty,
              sourceList.contains(source), !tv.kind.isInput(source) else { return nil }
        return source
    }

    func actions(for key: TVRemoteKey, on side: TVRemoteSide) -> [TVRemoteAction] {
        guard let device = device(side) else { return [] }
        if key == .power, let power = device.power {
            return [.runScript(script: power)]
        }
        if let command = key.command(on: device.kind) {
            return [.send(remote: device.remote, command: command)]
        }
        guard key == .playPause else { return [] }
        if let mediaPlayer = device.mediaPlayer {
            return [.mediaPlayPause(mediaPlayer: mediaPlayer)]
        }
        return [.samsungPlayPause(remote: device.remote)]
    }

    func digitActions(_ digit: Int, on side: TVRemoteSide) -> [TVRemoteAction] {
        guard (0...9).contains(digit), let device = device(side) else { return [] }
        return [.send(remote: device.remote, command: TVRemoteKey.digit(digit, on: device.kind))]
    }

    /// Thrown as `DashboardConfigurationError`s by the card validator.
    func validate(cardType: String) throws {
        guard tv != nil || box != nil else {
            throw DashboardConfigurationError.tvRemoteNeedsADevice(cardType: cardType)
        }
        for name in lockScreen ?? [] {
            switch LockScreenKey(name) {
            case .open: continue
            case .key(_, let side) where device(side) != nil: continue
            default: throw DashboardConfigurationError.unknownLockScreenKey(name, cardType: cardType)
            }
        }
    }
}

/// The arrows and center button of a remote's pad.
enum RemoteDirection: CaseIterable {
    case up, down, left, right, ok

    var systemImage: String {
        switch self {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .ok: return "circle"
        }
    }

    var label: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .ok: return "OK"
        }
    }
}
