import Foundation

#if DEBUG && targetEnvironment(simulator)
/// Made-up devices and people for screenshots, so nobody's real home ends up
/// in them. `scripts/screenshots.py` writes the files into the app's
/// container and launches with HASSONIC_DEMO set to their folder:
///
/// - `demo-entities.json`: the entity states to show, as Home Assistant
///   sends them, instead of connecting anywhere.
/// - `demo-recents.json`: the Music tab's Recents, as `RecentMusicItem`s.
/// - `demo-history.json`: `{ "person.x": [states…] }`, what the People
///   card's history sheet reads.
///
/// The dashboard itself comes in as the usual debug override,
/// `config-override.yaml`. Debug simulator builds only.
enum DemoMode {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["HASSONIC_DEMO"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// HASSONIC_OPEN_HISTORY: a `person.*` whose history sheet opens with
    /// the People card.
    static var openHistoryFor: String? {
        ProcessInfo.processInfo.environment["HASSONIC_OPEN_HISTORY"]
    }

    /// HASSONIC_OPEN_SHEET: a sheet to open for a screenshot. `room-music`
    /// is a room's Play Music sheet; `play-on` the Music tab's Play On sheet
    /// as it asks when there's no speaker to play on; `browse` Browse;
    /// `play-something-else` the Music tab's start page, opened while playing.
    static var openSheet: String? {
        ProcessInfo.processInfo.environment["HASSONIC_OPEN_SHEET"]
    }

    /// HASSONIC_BROWSE_AT: a folder id in `demo-browse.json` for Browse to
    /// open at instead of the top.
    static var browseStart: String? {
        ProcessInfo.processInfo.environment["HASSONIC_BROWSE_AT"]
    }

    /// `demo-browse.json`: `{ "<content id>": node }`, the top under "".
    static func browse(_ contentId: String?) -> HABrowseMediaResult? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("demo-browse.json")),
              let all = try? decoder.decode([String: HABrowseMediaNode].self, from: data) else { return nil }
        return HABrowseMediaResult(success: true, result: all[contentId ?? ""], error: nil)
    }

    /// HASSONIC_DEMO_START_VOLUME: a zone whose just-started volume strip
    /// shows on the Now Playing card, and stays.
    static var startVolumeZone: String? {
        ProcessInfo.processInfo.environment["HASSONIC_DEMO_START_VOLUME"]
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func entities() -> [HAEntityState]? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("demo-entities.json")) else { return nil }
        return try? decoder.decode([HAEntityState].self, from: data)
    }

    /// `demo-recents.json`: the Music tab's Recents row.
    static func recents() -> [RecentMusicItem]? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("demo-recents.json")) else { return nil }
        return try? JSONDecoder().decode([RecentMusicItem].self, from: data)
    }

    static func history(for entityId: String) -> [HAEntityState]? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("demo-history.json")),
              let all = try? decoder.decode([String: [HAEntityState]].self, from: data) else { return nil }
        return all[entityId] ?? []
    }
}
#endif
