import XCTest
@testable import Hassonic

/// A day of someone's history, as Home Assistant records it, turned into the
/// stays the history sheet lists and the path it draws.
final class PersonHistoryTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private let dayStart = ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z")!
    private let dayEnd = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!

    /// One recorded state: `changed` when the place last changed, `updated`
    /// when anything (a GPS fix) last did.
    private func record(_ state: String, changed: String, updated: String? = nil, _ latitude: Double? = nil, _ longitude: Double? = nil) -> HAEntityState {
        var attributes: [String: JSONValue] = [:]
        if let latitude, let longitude {
            attributes["latitude"] = .number(latitude)
            attributes["longitude"] = .number(longitude)
        }
        return HAEntityState(entityId: "person.alex", state: state, attributes: attributes,
                             lastChanged: changed, lastUpdated: updated ?? changed)
    }

    func testPlacesBecomeStaysNewestFirst() {
        let history = PersonHistory.build(from: [
            record("home", changed: "2026-10-12T00:00:00+00:00", 1, 1),
            record("not_home", changed: "2026-10-12T08:30:00+00:00", 1.1, 1.1),
            record("Work", changed: "2026-10-12T09:00:00+00:00", 2, 2),
            record("home", changed: "2026-10-12T17:45:00+00:00", 1, 1),
        ], start: dayStart, end: dayEnd, now: date("2026-10-13T09:00:00Z"))

        XCTAssertEqual(history.stays.map(\.place), ["Home", "Work", "Away", "Home"])
        XCTAssertEqual(history.stays[1].start, date("2026-10-12T09:00:00Z"))
        XCTAssertEqual(history.stays[1].end, date("2026-10-12T17:45:00Z"))
        // A past day ends at midnight, not "still there".
        XCTAssertEqual(history.stays[0].end, dayEnd)
    }

    func testGPSUpdatesInOnePlaceAreOneStayButAllOnThePath() {
        let history = PersonHistory.build(from: [
            record("not_home", changed: "2026-10-12T10:00:00+00:00", 1, 1),
            record("not_home", changed: "2026-10-12T10:00:00+00:00", updated: "2026-10-12T10:05:00+00:00", 1.01, 1.01),
            record("not_home", changed: "2026-10-12T10:00:00+00:00", updated: "2026-10-12T10:10:00+00:00", 1.02, 1.02),
            // The same fix twice draws no extra point.
            record("not_home", changed: "2026-10-12T10:00:00+00:00", updated: "2026-10-12T10:11:00+00:00", 1.02, 1.02),
        ], start: dayStart, end: dayEnd, now: date("2026-10-13T09:00:00Z"))

        XCTAssertEqual(history.stays.map(\.place), ["Away"])
        XCTAssertEqual(history.path.count, 3)
    }

    func testTodaysLastStayIsStillOpen() {
        let history = PersonHistory.build(from: [
            record("home", changed: "2026-10-12T07:00:00+00:00"),
        ], start: dayStart, end: dayEnd, now: date("2026-10-12T12:00:00Z"))

        XCTAssertNil(history.stays[0].end)
    }

    /// Home Assistant starts the period with the state it was already in,
    /// stamped when it began, which may be days earlier.
    func testAStayBegunTheDayBeforeStartsAtMidnight() {
        let history = PersonHistory.build(from: [
            record("home", changed: "2026-10-11T18:00:00+00:00"),
        ], start: dayStart, end: dayEnd, now: date("2026-10-13T09:00:00Z"))

        XCTAssertEqual(history.stays[0].start, dayStart)
    }

    func testAPhoneDroppingOffDoesNotSplitAStay() {
        let history = PersonHistory.build(from: [
            record("Work", changed: "2026-10-12T09:00:00+00:00"),
            record("unavailable", changed: "2026-10-12T11:00:00+00:00"),
            record("Work", changed: "2026-10-12T11:20:00+00:00"),
        ], start: dayStart, end: dayEnd, now: date("2026-10-13T09:00:00Z"))

        XCTAssertEqual(history.stays.map(\.place), ["Work"])
        XCTAssertEqual(history.stays[0].start, date("2026-10-12T09:00:00Z"))
    }

    func testAStayTakesItsFirstKnownPosition() {
        let history = PersonHistory.build(from: [
            record("Work", changed: "2026-10-12T09:00:00+00:00"),
            record("Work", changed: "2026-10-12T09:00:00+00:00", updated: "2026-10-12T09:03:00+00:00", 2, 3),
        ], start: dayStart, end: dayEnd, now: date("2026-10-13T09:00:00Z"))

        XCTAssertEqual(history.stays[0].latitude, 2)
        XCTAssertEqual(history.stays[0].longitude, 3)
    }

    func testDurationsRead() {
        let start = date("2026-10-12T09:00:00Z")
        XCTAssertEqual(PersonHistory.duration(from: start, to: start.addingTimeInterval(20)), "under a minute")
        XCTAssertEqual(PersonHistory.duration(from: start, to: start.addingTimeInterval(45 * 60)), "45m")
        XCTAssertEqual(PersonHistory.duration(from: start, to: start.addingTimeInterval(3 * 3600)), "3h")
        XCTAssertEqual(PersonHistory.duration(from: start, to: start.addingTimeInterval(6 * 3600 + 28 * 60)), "6h 28m")
    }

    func testTheRequestAsksForEveryUpdateInTheDay() throws {
        let url = try XCTUnwrap(PersonHistoryLoader.url(
            baseURL: URL(string: "https://ha.example")!,
            entityId: "person.alex",
            start: dayStart,
            end: dayEnd
        ))
        XCTAssertEqual(url.path, "/api/history/period/2026-10-12T00:00:00Z")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "filter_entity_id", value: "person.alex")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "end_time", value: "2026-10-13T00:00:00Z")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "significant_changes_only", value: "0")))
    }

    /// The shape Home Assistant answers with: one list per entity.
    func testDecodesHomeAssistantsResponse() throws {
        let json = """
        [[{"entity_id":"person.alex","state":"home","attributes":{"latitude":1.5,"longitude":2.5},
           "last_changed":"2026-10-12T00:00:00+00:00","last_updated":"2026-10-12T00:00:00+00:00"},
          {"entity_id":"person.alex","state":"Work","attributes":{},
           "last_changed":"2026-10-12T09:00:00.123456+00:00","last_updated":"2026-10-12T09:00:00.123456+00:00"}]]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let states = try XCTUnwrap(decoder.decode([[HAEntityState]].self, from: Data(json.utf8)).first)
        let history = PersonHistory.build(from: states, start: dayStart, end: dayEnd, now: date("2026-10-13T09:00:00Z"))
        XCTAssertEqual(history.stays.map(\.place), ["Work", "Home"])
        XCTAssertEqual(history.stays[1].latitude, 1.5)
    }
}
