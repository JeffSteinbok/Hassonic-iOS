import Foundation

#if DEBUG && targetEnvironment(simulator)
/// Made-up devices and people for screenshots, so nobody's real home ends up
/// in them. `scripts/screenshots.py` writes the files into the app's
/// container and launches with HASSONIC_DEMO set to their folder:
///
/// - `demo-entities.json`: the entity states to show, as Home Assistant
///   sends them, instead of connecting anywhere.
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

    static func history(for entityId: String) -> [HAEntityState]? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("demo-history.json")),
              let all = try? decoder.decode([String: [HAEntityState]].self, from: data) else { return nil }
        return all[entityId] ?? []
    }
}
#endif
