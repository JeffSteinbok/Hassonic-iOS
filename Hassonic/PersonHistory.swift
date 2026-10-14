import CoreLocation
import Foundation

/// Where someone was on one day, from Home Assistant's history of their
/// `person` entity: the places they stayed, and the GPS path between them.
struct PersonHistory: Equatable {
    /// A stretch in one place: a zone ("Home", "Work") or "Away".
    struct Stay: Identifiable, Equatable {
        let place: String
        let start: Date
        /// Nil while they're still there.
        let end: Date?
        /// Where they were when they arrived, if the phone reported it.
        let latitude: Double?
        let longitude: Double?

        var id: Date { start }

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct Point: Equatable {
        let latitude: Double
        let longitude: Double
    }

    /// Newest first, as the timeline lists them.
    let stays: [Stay]
    /// Oldest first, as the line on the map is drawn.
    let path: [Point]

    static let empty = PersonHistory(stays: [], path: [])

    /// Turns the entity's recorded states for `start..<end` into stays and a
    /// path. Consecutive records in the same place are one stay, however many
    /// GPS updates they carry; "unknown" and "unavailable" (a phone that
    /// dropped off) don't interrupt one. A stay begun before `start` is
    /// clipped to it. The last stay is open if `end` hasn't come yet.
    static func build(from states: [HAEntityState], start: Date, end: Date, now: Date) -> PersonHistory {
        let records = states
            .compactMap { state -> (date: Date, state: HAEntityState)? in
                guard let stamp = state.lastUpdated ?? state.lastChanged,
                      let date = PersonLocationDirectory.parseTimestamp(stamp) else { return nil }
                return (date, state)
            }
            .sorted { $0.date < $1.date }

        var arrivals: [(place: String, start: Date, latitude: Double?, longitude: Double?)] = []
        var path: [Point] = []

        for record in records {
            let latitude = record.state.attributeDouble("latitude")
            let longitude = record.state.attributeDouble("longitude")
            if let latitude, let longitude {
                let point = Point(latitude: latitude, longitude: longitude)
                if path.last != point { path.append(point) }
            }

            guard !["", "unknown", "unavailable"].contains(record.state.state.lowercased()) else { continue }
            let place = PersonLocationDirectory.locationLabel(for: record.state.state)
            if arrivals.last?.place == place {
                // Still there: fill in a position the arrival didn't have.
                if arrivals[arrivals.count - 1].latitude == nil, let latitude, let longitude {
                    arrivals[arrivals.count - 1].latitude = latitude
                    arrivals[arrivals.count - 1].longitude = longitude
                }
                continue
            }
            arrivals.append((place, max(record.date, start), latitude, longitude))
        }

        let openEnd: Date? = now < end ? nil : end
        let stays = arrivals.enumerated().map { index, arrival in
            Stay(
                place: arrival.place,
                start: arrival.start,
                end: index + 1 < arrivals.count ? arrivals[index + 1].start : openEnd,
                latitude: arrival.latitude,
                longitude: arrival.longitude
            )
        }
        return PersonHistory(stays: stays.reversed(), path: path)
    }

    /// "6h 28m", "45m", "under a minute".
    static func duration(from start: Date, to end: Date) -> String {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        if minutes < 1 { return "under a minute" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// Reads one day of a person's history from Home Assistant's REST API.
enum PersonHistoryLoader {
    enum Failure: Error { case badResponse(Int), notSignedIn }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// The day `day` falls in, midnight to midnight in `calendar`'s time zone.
    static func dayRange(containing day: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: day)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// `/api/history/period/<start>?filter_entity_id=…&end_time=…`, with every
    /// attribute change (each GPS update), not just changes of place.
    static func url(baseURL: URL, entityId: String, start: Date, end: Date) -> URL? {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/history/period/\(stamp.string(from: start))"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filter_entity_id", value: entityId),
            URLQueryItem(name: "end_time", value: stamp.string(from: end)),
            URLQueryItem(name: "significant_changes_only", value: "0"),
        ]
        return components?.url
    }

    static func load(
        entityId: String,
        day: Date,
        baseURLString: String?,
        accessToken: String?,
        now: Date = .now,
        calendar: Calendar = .current,
        urlSession: URLSessionProtocol = URLSession.shared
    ) async throws -> PersonHistory {
        let (start, end) = dayRange(containing: day, calendar: calendar)
        #if DEBUG && targetEnvironment(simulator)
        if let demo = DemoMode.history(for: entityId) {
            return PersonHistory.build(from: demo.filter {
                ($0.lastUpdated ?? $0.lastChanged).flatMap(PersonLocationDirectory.parseTimestamp).map { $0 < end } ?? false
            }, start: start, end: end, now: now)
        }
        #endif
        guard let baseURLString, let baseURL = URL(string: baseURLString), let accessToken else { throw Failure.notSignedIn }
        guard let url = url(baseURL: baseURL, entityId: entityId, start: start, end: min(end, now)) else { throw Failure.notSignedIn }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.badResponse(status) }

        // One list per entity asked for; none at all if nothing was recorded.
        let states = try decoder.decode([[HAEntityState]].self, from: data).first ?? []
        return PersonHistory.build(from: states, start: start, end: end, now: now)
    }
}
