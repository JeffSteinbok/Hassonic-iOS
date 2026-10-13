import OSLog

/// The app's logs, by area. Read them in Console.app (filter on the
/// subsystem) or in Xcode's debug console.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Hassonic"

    static let homeAssistant = Logger(subsystem: subsystem, category: "HomeAssistant")
    static let config = Logger(subsystem: subsystem, category: "Config")
    static let music = Logger(subsystem: subsystem, category: "Music")
    static let liveActivity = Logger(subsystem: subsystem, category: "LiveActivity")
    static let push = Logger(subsystem: subsystem, category: "Push")
    static let carPlay = Logger(subsystem: subsystem, category: "CarPlay")
}

extension Logger {
    /// Logs an already-built string. These messages hold entity ids, URLs
    /// and timings, nothing secret, so they're public: otherwise a release
    /// build shows `<private>` and the log is useless for a bug report.
    func note(_ message: String) {
        notice("\(message, privacy: .public)")
    }
}
