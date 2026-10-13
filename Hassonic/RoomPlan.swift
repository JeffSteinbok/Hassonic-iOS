import Foundation

/// A `room` card: a picture of a room with a button on each device, placed
/// where the device is.
///
///     - type: room
///       image: /local/main_bedroom.png
///       hotspots:
///         - { entity: light.main_bedroom_bedside_torches, x: 0.08, y: 0.08 }
///         - { entity: fan.main_bedroom_ceiling_fan, x: 0.5, y: 0.67, size: large }
///
/// `x` and `y` are the button's centre as a fraction of the image's width and
/// height, so they hold at any size the picture is drawn. One entity can have
/// several hotspots (a lamp on each nightstand driven by one light).
struct DashboardRoomCardConfiguration: Decodable, Equatable {
    struct Hotspot: Decodable, Equatable, Identifiable {
        let entity: String
        let x: Double
        let y: Double
        /// What VoiceOver reads; defaults to the entity's friendly name.
        var label: String?
        /// An SF Symbol to draw instead of the domain's default.
        var icon: String?
        var size: Size?

        enum Size: String, Decodable { case regular, large }

        /// One entity can have several hotspots, so where it sits is part of it.
        var id: String { "\(entity)@\(x),\(y)" }

        var domain: String { String(entity.split(separator: ".").first ?? "") }

        /// The domain's symbol: a bulb for a light, a fan for a fan, a
        /// speaker for a media player.
        var symbol: String {
            if let icon { return icon }
            switch domain {
            case "light": return "lightbulb.fill"
            case "fan": return "fan.fill"
            case "media_player": return "hifispeaker.fill"
            case "switch": return "power"
            case "cover": return "blinds.horizontal.closed"
            default: return "circle.fill"
            }
        }
    }

    /// A chip above the picture: a sensor's reading, "71°" or, with a
    /// label, "Air excellent".
    struct Status: Decodable, Equatable {
        let entity: String
        var label: String?
    }

    /// A button under the picture that sets several devices at once
    /// ("All off", "Bedtime"), or runs a script.
    struct Action: Decodable, Equatable {
        let name: String
        var icon: String?
        var on: [String]?
        var off: [String]?
        var script: String?
    }

    let title: String?
    /// A path on Home Assistant (`/local/…` for its www folder) or a full URL.
    let image: String
    let hotspots: [Hotspot]
    var status: [Status]?
    var actions: [Action]?

    /// Each device once, though it may have several hotspots.
    var entities: [String] {
        var seen = Set<String>()
        return hotspots.map(\.entity).filter { seen.insert($0).inserted }
    }

    func validate(cardType: String) throws {
        for hotspot in hotspots {
            guard hotspot.entity.split(separator: ".").count == 2 else {
                throw DashboardConfigurationError.invalidEntity(entityID: hotspot.entity, cardType: cardType, expectedDomain: "any")
            }
            guard (0...1).contains(hotspot.x), (0...1).contains(hotspot.y) else {
                throw DashboardConfigurationError.roomHotspotOutsideImage(entityID: hotspot.entity, cardType: cardType)
            }
        }
    }
}
