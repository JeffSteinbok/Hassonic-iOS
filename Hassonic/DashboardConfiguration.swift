import Foundation
import Yams

struct DashboardConfiguration: Decodable, Equatable {
    let version: Int
    let pages: [DashboardPageConfiguration]

    func validated() throws -> DashboardConfiguration {
        guard version == 1 else {
            throw DashboardConfigurationError.unsupportedVersion(version)
        }
        guard !pages.isEmpty else {
            throw DashboardConfigurationError.noPages
        }

        var pageIDs = Set<String>()
        for page in pages {
            guard !page.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DashboardConfigurationError.missingPageID
            }
            guard pageIDs.insert(page.id).inserted else {
                throw DashboardConfigurationError.duplicatePageID(page.id)
            }
            guard !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DashboardConfigurationError.missingPageTitle(page.id)
            }
            guard !page.systemIcon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DashboardConfigurationError.missingPageIcon(page.id)
            }

            for section in page.sections {
                for card in section.cards {
                    try card.validate()
                }
            }
        }
        return self
    }
}

struct DashboardPageConfiguration: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let systemIcon: String
    let sections: [DashboardSectionConfiguration]
    /// A room lives in the Rooms strip on the first page, not in the tab bar.
    var isRoom: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case systemIcon = "system_icon"
        case sections
        case isRoom = "room"
    }

    init(id: String, title: String, systemIcon: String, sections: [DashboardSectionConfiguration], isRoom: Bool = false) {
        self.id = id
        self.title = title
        self.systemIcon = systemIcon
        self.sections = sections
        self.isRoom = isRoom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        systemIcon = try container.decode(String.self, forKey: .systemIcon)
        sections = try container.decode([DashboardSectionConfiguration].self, forKey: .sections)
        isRoom = try container.decodeIfPresent(Bool.self, forKey: .isRoom) ?? false
    }

    /// The room card on a room page, for its tile on the first page.
    var roomCard: DashboardRoomCardConfiguration? {
        for section in sections {
            for card in section.cards {
                if case .room(let room) = card { return room }
            }
        }
        return nil
    }
}

struct DashboardSectionConfiguration: Decodable, Equatable {
    let title: String?
    let cards: [DashboardCardConfiguration]
}

struct DashboardEntityCardConfiguration: Decodable, Equatable {
    let entity: String
    let title: String?
    /// An SF Symbol, or one of the app's own like `torchiere`, for a
    /// `light` card's row instead of the bulb.
    var icon: String? = nil
}

struct DashboardTitledCardConfiguration: Decodable, Equatable {
    let title: String?
}

/// Who to show on a `people` card.
///
/// Both knobs are optional. By default: every `person.*` entity Home
/// Assistant knows, minus whoever is signed in — you know where you are. Name `entities` to pin an explicit set instead.
struct DashboardPeopleCardConfiguration: Decodable, Equatable {
    let title: String?
    /// Explicit person entity ids, in the order given. Omit for every
    /// `person.*` entity, name-sorted.
    var entities: [String]?
    /// Whether to drop the person tied to the signed-in HA account.
    var excludeSignedInUser: Bool = true

    private enum CodingKeys: String, CodingKey {
        case title, entities, excludeSignedInUser
    }

    init(title: String? = nil, entities: [String]? = nil, excludeSignedInUser: Bool = true) {
        self.title = title
        self.entities = entities
        self.excludeSignedInUser = excludeSignedInUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        entities = try c.decodeIfPresent([String].self, forKey: .entities)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .excludeSignedInUser) { excludeSignedInUser = v }
    }
}

struct UnsupportedDashboardCardConfiguration: Equatable {
    let type: String
    let title: String?
}

enum DashboardCardConfiguration: Decodable, Equatable {
    case light(DashboardEntityCardConfiguration)
    case cover(DashboardEntityCardConfiguration)
    case alarm(DashboardEntityCardConfiguration)
    case llmVisionTimeline(DashboardTitledCardConfiguration)
    case people(DashboardPeopleCardConfiguration)
    case tvRemote(DashboardTVRemoteConfiguration)
    case thermostat(DashboardThermostatConfiguration)
    case room(DashboardRoomCardConfiguration)
    case unsupported(UnsupportedDashboardCardConfiguration)

    private enum CodingKeys: String, CodingKey {
        case type
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "light":
            self = .light(try DashboardEntityCardConfiguration(from: decoder))
        case "cover":
            self = .cover(try DashboardEntityCardConfiguration(from: decoder))
        case "alarm":
            self = .alarm(try DashboardEntityCardConfiguration(from: decoder))
        case "llm_vision_timeline":
            self = .llmVisionTimeline(try DashboardTitledCardConfiguration(from: decoder))
        case "people":
            self = .people(try DashboardPeopleCardConfiguration(from: decoder))
        case "tv_remote":
            self = .tvRemote(try DashboardTVRemoteConfiguration(from: decoder))
        case "thermostat":
            self = .thermostat(try DashboardThermostatConfiguration(from: decoder))
        case "room":
            self = .room(try DashboardRoomCardConfiguration(from: decoder))
        default:
            self = .unsupported(
                UnsupportedDashboardCardConfiguration(
                    type: type,
                    title: try container.decodeIfPresent(String.self, forKey: .title)
                )
            )
        }
    }

    var typeName: String {
        switch self {
        case .light: return "light"
        case .cover: return "cover"
        case .alarm: return "alarm"
        case .llmVisionTimeline: return "llm_vision_timeline"
        case .people: return "people"
        case .tvRemote: return "tv_remote"
        case .thermostat: return "thermostat"
        case .room: return "room"
        case .unsupported(let configuration): return configuration.type
        }
    }

    fileprivate func validate() throws {
        switch self {
        case .light(let configuration):
            try Self.validateEntity(configuration.entity, domain: "light", cardType: typeName)
        case .cover(let configuration):
            try Self.validateEntity(configuration.entity, domain: "cover", cardType: typeName)
        case .alarm(let configuration):
            try Self.validateEntity(configuration.entity, domain: "alarm_control_panel", cardType: typeName)
        case .thermostat(let configuration):
            try Self.validateEntity(configuration.entity, domain: "climate", cardType: typeName)
            if let outside = configuration.outside,
               (try? Self.validateEntity(outside, domain: "weather", cardType: typeName)) == nil {
                do {
                    try Self.validateEntity(outside, domain: "sensor", cardType: typeName)
                } catch {
                    throw DashboardConfigurationError.invalidEntity(entityID: outside, cardType: typeName, expectedDomain: "weather or sensor")
                }
            }
        case .tvRemote(let configuration):
            for device in [configuration.tv, configuration.box].compactMap({ $0 }) {
                try Self.validateEntity(device.remote, domain: "remote", cardType: typeName)
                if let mediaPlayer = device.mediaPlayer {
                    try Self.validateEntity(mediaPlayer, domain: "media_player", cardType: typeName)
                }
                if let power = device.power {
                    try Self.validateEntity(power, domain: "script", cardType: typeName)
                }
            }
            try configuration.validate(cardType: typeName)
        case .people(let configuration):
            // An explicit list is checked; an omitted one means "every
            // person.* entity", which can't be wrong here.
            for entity in configuration.entities ?? [] {
                try Self.validateEntity(entity, domain: "person", cardType: typeName)
            }
        case .room(let configuration):
            try configuration.validate(cardType: typeName)
        case .llmVisionTimeline, .unsupported:
            break
        }
    }

    private static func validateEntity(_ entityID: String, domain: String, cardType: String) throws {
        let components = entityID.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Substring(domain), !components[1].isEmpty else {
            throw DashboardConfigurationError.invalidEntity(
                entityID: entityID,
                cardType: cardType,
                expectedDomain: domain
            )
        }
    }
}

enum DashboardConfigurationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case noPages
    case missingPageID
    case duplicatePageID(String)
    case missingPageTitle(String)
    case missingPageIcon(String)
    case invalidEntity(entityID: String, cardType: String, expectedDomain: String)
    case tvRemoteNeedsADevice(cardType: String)
    case roomHotspotOutsideImage(entityID: String, cardType: String)
    /// Already-formatted description of a `DecodingError`, which on its own
    /// only ever says "the data isn't in the correct format".
    case malformedYAML(String)

    var errorDescription: String? {
        switch self {
        case .malformedYAML(let description):
            return description
        case .unsupportedVersion(let version):
            return "Dashboard configuration version \(version) is not supported."
        case .noPages:
            return "Dashboard configuration must contain at least one page."
        case .missingPageID:
            return "Every dashboard page must have a non-empty id."
        case .duplicatePageID(let id):
            return "Dashboard page id '\(id)' is duplicated."
        case .missingPageTitle(let id):
            return "Dashboard page '\(id)' must have a title."
        case .missingPageIcon(let id):
            return "Dashboard page '\(id)' must have a system_icon."
        case .invalidEntity(let entityID, let cardType, let expectedDomain):
            return "Card '\(cardType)' requires a \(expectedDomain).* entity, not '\(entityID)'."
        case .tvRemoteNeedsADevice(let cardType):
            return "Card '\(cardType)' needs a tv, a box, or both."
        case .roomHotspotOutsideImage(let entityID, let cardType):
            return "Card '\(cardType)' places \(entityID) outside its image: x and y go from 0 to 1."
        }
    }
}

/// Turns `DecodingError` into a message that names the offending key. The
/// stock `localizedDescription` only says the data is in the wrong format,
/// which is useless for hand-edited YAML.
enum DashboardDecodingErrorFormatter {
    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\" at \(path(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "\(path(context.codingPath)): expected \(name(of: type)), found nothing"
        case .typeMismatch(let type, let context):
            return "\(path(context.codingPath)): expected \(name(of: type)), found a value of a different type"
        case .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)\(underlying(context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Yams asks for its own node types when the YAML shape is wrong, and
    /// "expected Mapping" means nothing to someone editing a dashboard file.
    private static func name(of type: Any.Type) -> String {
        switch String(describing: type) {
        case "Scalar": return "a single value"
        case "Mapping": return "a block of keys"
        case "Sequence": return "a list"
        case let name: return name
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the top level" }

        return codingPath.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }

    /// Yams reports the failing line and column on the underlying error, not
    /// in the debug description, so it is worth carrying through.
    private static func underlying(_ context: DecodingError.Context) -> String {
        guard let error = context.underlyingError else { return "" }
        return " (\(error))"
    }
}

enum DashboardConfigurationParser {
    static func parse(_ yaml: String) throws -> DashboardConfiguration {
        do {
            return try YAMLDecoder().decode(DashboardConfiguration.self, from: yaml).validated()
        } catch let error as DecodingError {
            throw DashboardConfigurationError.malformedYAML(
                DashboardDecodingErrorFormatter.describe(error)
            )
        }
    }
}
