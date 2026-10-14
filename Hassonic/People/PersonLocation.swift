import CoreLocation
import Foundation

/// A Home Assistant `person.*` entity reduced to what the People card needs:
/// who they are, the zone label HA reports as the entity state, and a
/// coordinate to drop a pin on.
struct PersonLocation: Equatable, Identifiable {
    let entityId: String
    let name: String
    /// Display form of the HA state — "Home", "Away", or a zone's own name.
    let locationLabel: String
    let latitude: Double?
    let longitude: Double?
    /// The person's Home Assistant profile picture, already resolved against
    /// the server's base URL. Nil when they haven't got one.
    let pictureURL: URL?
    /// The companion app's geocoded address, line by line as it reports it —
    /// street first, then locality, region, country.
    let addressLines: [String]
    /// When they entered the zone they're in now.
    let zoneEnteredAt: Date?
    /// The companion app's motion activity for their phone: "Automotive",
    /// "Walking", "Stationary", … Nil when it reports nothing useful.
    var activity: String? = nil

    var isDriving: Bool { activity == "Automotive" }

    var id: String { entityId }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    var isHome: Bool { locationLabel == "Home" }

    /// In a zone of HA's other than home, e.g. "Work", rather than just away.
    var isInNamedZone: Bool { !["Home", "Away", "Unknown"].contains(locationLabel) }

    /// "88 Maple Rd" — the part the surrounding map can't tell you.
    var street: String? { addressLines.first }

    /// "Springfield IL 62702" — the town line only. The sensor also reports a
    /// country, which would truncate the useful part away.
    var locality: String? {
        addressLines.dropFirst().first
    }

    /// "40 Oak Ave, Springfield IL 62702" — street and town on one line.
    var streetAndLocality: String? {
        let parts = [street, locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }


    /// First word of the name, or the whole thing if it's a single word. A
    /// household shares a surname more often than not, so the given name is
    /// what identifies someone in a short label.
    var givenName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

/// Builds the people list out of a raw Home Assistant entity snapshot.
enum PersonLocationDirectory {
    /// Every `person.*` entity, name-sorted, with a coordinate resolved from
    /// the person's own GPS attributes or — for people tracked by something
    /// without GPS, e.g. a router-based device tracker — from the HA zone
    /// their state names.
    ///
    /// `excludingUserId` drops the person tied to the signed-in HA account:
    /// you know where you are.
    static func people(
        from entities: [HAEntityState],
        baseURLString: String = "",
        excludingUserId: String? = nil
    ) -> [PersonLocation] {
        let zones = zoneCoordinates(from: entities)

        return entities
            .filter { $0.entityId.hasPrefix("person.") }
            .filter { entity in
                guard let excludingUserId, !excludingUserId.isEmpty else { return true }
                return entity.attributeString("user_id") != excludingUserId
            }
            .map { entity in
                let fallback = zones[zoneKey(for: entity.state)]
                return PersonLocation(
                    entityId: entity.entityId,
                    name: entity.friendlyName,
                    locationLabel: locationLabel(for: entity.state),
                    latitude: entity.attributeDouble("latitude") ?? fallback?.latitude,
                    longitude: entity.attributeDouble("longitude") ?? fallback?.longitude,
                    pictureURL: resolveHAImageURL(
                        path: entity.attributeString("entity_picture"),
                        baseURLString: baseURLString
                    ),
                    addressLines: addressLines(for: entity, in: entities),
                    zoneEnteredAt: entity.lastChanged.flatMap(HATimestamp.parse),
                    activity: activity(for: entity, in: entities)
                )
            }
            .sorted {
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byName == .orderedSame ? $0.entityId < $1.entityId : byName == .orderedAscending
            }
    }

    /// Everyone a card or screen should show, in order: an explicit list is
    /// honoured as given (so a config can put the household in a deliberate
    /// order), an omitted one means every `person.*` entity, name-sorted.
    static func people(
        from entities: [HAEntityState],
        matching entityIds: [String]?,
        baseURLString: String = "",
        excludingUserId: String? = nil
    ) -> [PersonLocation] {
        let all = people(from: entities, baseURLString: baseURLString, excludingUserId: excludingUserId)
        guard let entityIds else { return all }
        return entityIds.compactMap { id in all.first { $0.entityId == id } }
    }


    /// The Home Assistant companion app publishes a reverse-geocoded address
    /// for each device as `sensor.<device>_geocoded_location`, so there's no
    /// need to geocode the coordinate ourselves.
    static func addressLines(for person: HAEntityState, in entities: [HAEntityState]) -> [String] {
        for sensor in companionSensors(for: person, named: "geocoded_location", in: entities) {
            let lines = normalizedAddressLines(sensor.state)
            if !lines.isEmpty { return lines }
        }
        return []
    }

    /// `sensor.<device>_activity`, the phone's motion activity. "Unknown" and
    /// an unavailable sensor say nothing, so they're nil.
    static func activity(for person: HAEntityState, in entities: [HAEntityState]) -> String? {
        companionSensors(for: person, named: "activity", in: entities)
            .map(\.state)
            .first { !["unknown", "unavailable", ""].contains($0.lowercased()) }
    }

    /// A companion-app sensor for each of the person's device trackers, the
    /// primary (`source`) first. The sensor usually shares the tracker's
    /// object id, but not always — a re-added phone's tracker gets a suffix
    /// (`rileys_iphone_17`) its sensors don't — so fall back to the sensor
    /// named after the tracker's friendly name ("Riley’s iPhone Activity").
    static func companionSensors(
        for person: HAEntityState,
        named suffix: String,
        in entities: [HAEntityState]
    ) -> [HAEntityState] {
        let trackers = [person.attributeString("source")].compactMap { $0 }
            + (person.attributeStringArray("device_trackers") ?? [])
        let suffixName = suffix.split(separator: "_").map { $0.capitalized }.joined(separator: " ")

        return trackers.compactMap { tracker in
            let objectId = tracker.contains(".") ? String(tracker.split(separator: ".", maxSplits: 1)[1]) : tracker
            if let sensor = entities.first(where: { $0.entityId == "sensor.\(objectId)_\(suffix)" }) {
                return sensor
            }
            guard let trackerName = entities.first(where: { $0.entityId == tracker })?.friendlyName else { return nil }
            return entities.first {
                $0.entityId.hasPrefix("sensor.") && $0.friendlyName == "\(trackerName) \(suffixName)"
            }
        }
    }

    /// The sensor reports a full postal address across several lines; they're
    /// kept separate so the street and the town can be shown on their own.
    static func normalizedAddressLines(_ state: String) -> [String] {
        let lines = state
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first,
              !["unknown", "unavailable", "none"].contains(first.lowercased()) else { return [] }
        return lines
    }

    /// HA reports a person's state as `home`, `not_home`, or the friendly name
    /// of the zone they're in.
    static func locationLabel(for state: String) -> String {
        switch state.lowercased() {
        case "home": return "Home"
        case "not_home": return "Away"
        case "", "unknown", "unavailable": return "Unknown"
        default: return state
        }
    }

    /// `zone.home`'s centre, which the People card pins the house on and
    /// measures distances from.
    static func homeCoordinate(from entities: [HAEntityState]) -> CLLocationCoordinate2D? {
        guard let zone = entities.first(where: { $0.entityId == "zone.home" }),
              let latitude = zone.attributeDouble("latitude"),
              let longitude = zone.attributeDouble("longitude") else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Zones are matched to a person's state by friendly name, which is what
    /// HA puts in the state, and by entity-id suffix so `home` finds
    /// `zone.home` even if the zone has been renamed.
    private static func zoneCoordinates(from entities: [HAEntityState]) -> [String: (latitude: Double, longitude: Double)] {
        var coordinates: [String: (latitude: Double, longitude: Double)] = [:]
        for entity in entities where entity.entityId.hasPrefix("zone.") {
            guard let latitude = entity.attributeDouble("latitude"),
                  let longitude = entity.attributeDouble("longitude") else { continue }
            let suffix = String(entity.entityId.dropFirst("zone.".count))
            coordinates[zoneKey(for: suffix)] = (latitude, longitude)
            coordinates[zoneKey(for: entity.friendlyName)] = (latitude, longitude)
        }
        return coordinates
    }

    private static func zoneKey(for value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}

extension PersonLocationDirectory {
    /// "JS" for "Jamie Sterling": the first letters of the first two words,
    /// for someone with no picture. "?" when there are no letters at all.
    static func initials(for name: String) -> String {
        let letters = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .compactMap { $0.first(where: \.isLetter) }
            .prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
