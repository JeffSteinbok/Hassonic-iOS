import Foundation

/// A JSON value of unknown shape, used for Home Assistant entity attributes
/// (which vary per entity type and aren't worth modeling individually here).
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct HAEntityState: Decodable, Identifiable {
    let entityId: String
    let state: String
    let attributes: [String: JSONValue]
    /// When HA last saw this entity's *state* change, as the ISO-8601 string
    /// it sends. For a `person` that's the moment they entered the zone they
    /// are in now — attribute-only updates (a GPS nudge) don't move it.
    let lastChanged: String?

    /// Spelled out so `lastChanged` can default, leaving the 20-odd existing
    /// call sites that predate it untouched.
    init(entityId: String, state: String, attributes: [String: JSONValue], lastChanged: String? = nil) {
        self.entityId = entityId
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
    }

    var id: String { entityId }

    var friendlyName: String {
        if case .string(let name)? = attributes["friendly_name"] {
            return name
        }
        return entityId
    }

    func attributeString(_ key: String) -> String? {
        if case .string(let value)? = attributes[key] { return value }
        return nil
    }

    /// Numeric attributes (GPS coordinates, accuracy) normally arrive as JSON
    /// numbers, but some integrations report them as strings.
    func attributeDouble(_ key: String) -> Double? {
        switch attributes[key] {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    func attributeStringArray(_ key: String) -> [String]? {
        guard case .array(let values)? = attributes[key] else { return nil }
        return values.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
    }

    var isAvailable: Bool {
        if state == "unavailable" { return false }
        if case .bool(false)? = attributes["available"] { return false }
        return true
    }
}

// MARK: - Outgoing messages

struct HAAuthMessage: Encodable {
    let type = "auth"
    let accessToken: String
}

struct HAGetStatesMessage: Encodable {
    let id: Int
    let type = "get_states"
}

/// Asks HA who the access token belongs to. Used to tell "me" apart from the
/// rest of the household — a `person` entity carries the `user_id` of the HA
/// account it's tied to, and matching it against this is the only reliable
/// way to do that (names aren't unique or stable).
struct HACurrentUserMessage: Encodable {
    let id: Int
    let type = "auth/current_user"
}

struct HASubscribeEventsMessage: Encodable {
    let id: Int
    let type = "subscribe_events"
    let eventType = "state_changed"
}

struct HACallServiceTarget: Encodable {
    let entityId: String
}

struct HACallServiceMessage: Encodable {
    let id: Int
    let type = "call_service"
    let domain: String
    let service: String
    let target: HACallServiceTarget
}

struct HAVolumeSetMessage: Encodable {
    struct ServiceData: Encodable {
        let volumeLevel: Double
    }
    let id: Int
    let type = "call_service"
    let domain = "media_player"
    let service = "volume_set"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

struct HASelectSourceMessage: Encodable {
    struct ServiceData: Encodable {
        let source: String
    }
    let id: Int
    let type = "call_service"
    let domain = "media_player"
    let service = "select_source"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

struct HAPlayMediaMessage: Encodable {
    struct ServiceData: Encodable {
        let mediaContentId: String
        let mediaContentType: String
    }
    let id: Int
    let type = "call_service"
    let domain = "media_player"
    let service = "play_media"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

/// Sends arbitrary text to a media_player entity as a spoken command.
///
/// A stock `media_player.play_media` call; what makes it a *command* rather
/// than media is the content type, which is the voice integration's own
/// convention (`custom` for Alexa Media Player). Both the text and the
/// content type come from `SpeakerClaimConfig`, so nothing here is tied to a
/// particular assistant.
///
/// This exists because the streaming provider offers no service to bind a
/// speaker to a different account — asking out loud is the only route.
struct HASpokenCommandMessage: Encodable {
    struct MediaPayload: Encodable {
        let mediaContentId: String
        let mediaContentType: String
        let metadata: [String: String] = [:]
    }
    struct ServiceData: Encodable {
        let media: MediaPayload
    }
    let id: Int
    let type = "call_service"
    let domain = "media_player"
    let service = "play_media"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

struct HABrowseMediaMessage: Encodable {
    let id: Int
    let type = "media_player/browse_media"
    let entityId: String
    let mediaContentType: String?
    let mediaContentId: String?
}

struct HAVolumeMuteMessage: Encodable {
    struct ServiceData: Encodable {
        let isVolumeMuted: Bool
    }
    let id: Int
    let type = "call_service"
    let domain = "media_player"
    let service = "volume_mute"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

struct HACoverSetPositionMessage: Encodable {
    struct ServiceData: Encodable {
        let position: Int
    }
    let id: Int
    let type = "call_service"
    let domain = "cover"
    let service = "set_cover_position"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

/// `climate.set_temperature`: either `temperature` (heat or cool) or the
/// low/high pair (heat_cool). Nil fields are left out.
struct HAClimateSetTemperatureMessage: Encodable {
    struct ServiceData: Encodable {
        var temperature: Double?
        var targetTempLow: Double?
        var targetTempHigh: Double?
    }
    let id: Int
    let type = "call_service"
    let domain = "climate"
    let service = "set_temperature"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

/// `climate.set_hvac_mode`, e.g. "heat" or "heat_cool".
struct HAClimateSetHvacModeMessage: Encodable {
    struct ServiceData: Encodable {
        let hvacMode: String
    }
    let id: Int
    let type = "call_service"
    let domain = "climate"
    let service = "set_hvac_mode"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

/// `remote.send_command` with a single command, e.g. "guide" or "702".
struct HARemoteSendCommandMessage: Encodable {
    struct ServiceData: Encodable {
        let command: String
    }
    let id: Int
    let type = "call_service"
    let domain = "remote"
    let service = "send_command"
    let target: HACallServiceTarget
    let serviceData: ServiceData
}

// MARK: - Incoming messages

struct HAEnvelope: Decodable {
    let type: String
    let id: Int?
}

struct HACurrentUserResult: Decodable {
    struct User: Decodable {
        let id: String
        let name: String?
    }
    let success: Bool
    let result: User?
}

struct HAStatesResult: Decodable {
    let success: Bool
    let result: [HAEntityState]?
}

struct HAStateChangedEvent: Decodable {
    struct EventPayload: Decodable {
        struct StateChangeData: Decodable {
            let newState: HAEntityState?
        }
        let data: StateChangeData
    }
    let event: EventPayload
}

struct HABrowseMediaResult: Decodable {
    let success: Bool
    let result: HABrowseMediaNode?
    let error: HAResultError?
}

struct HAResultError: Decodable {
    let code: JSONValue?
    let message: String?
}

struct HAServiceCallResult: Decodable {
    let success: Bool
    let error: HAResultError?
}

struct HABrowseMediaNode: Decodable, Identifiable {
    let title: String?
    let mediaClass: String?
    let mediaContentType: String?
    let mediaContentId: String?
    let canPlay: Bool?
    let canExpand: Bool?
    let thumbnail: String?
    let childrenMediaClass: String?
    let children: [HABrowseMediaNode]?
    let extra: [String: JSONValue]?

    var id: String {
        if let mediaContentId, !mediaContentId.isEmpty { return mediaContentId }
        return title ?? UUID().uuidString
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let mediaClass, !mediaClass.isEmpty { return mediaClass.capitalized }
        return "Untitled"
    }

    var isPlayable: Bool { canPlay == true && mediaContentType != nil && mediaContentId != nil }
    var canBrowseChildren: Bool { canExpand == true }
}

/// Any `call_service` that carries data, for the controls that don't
/// warrant a message type of their own (a fan's speed, a light's brightness).
struct HAServiceDataMessage: Encodable {
    let id: Int
    let type = "call_service"
    let domain: String
    let service: String
    let target: HACallServiceTarget
    let serviceData: [String: JSONValue]
}
