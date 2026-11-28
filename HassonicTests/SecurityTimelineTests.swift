import XCTest
@testable import Hassonic

final class SecurityTimelineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(_ uid: String, at date: Date?) -> LLMVisionEvent {
        LLMVisionEvent(uid: uid, title: nil, description: nil,
                       start: date.map { ISO8601DateFormatter().string(from: $0) }, end: nil,
                       keyFrame: nil, cameraName: nil, category: nil, label: nil)
    }

    // MARK: Camera names

    private let friendlyNames = [
        "camera.backyard_left_fluent": "Backyard Left Fluent",
        "camera.front_door_high": "Front Door High",
        "camera.garage": "Garage",
        "camera.kids_room_clear": "Kid's Room Clear",
    ]

    private func name(_ raw: String?) -> String? {
        SecurityTimeline.cameraName(raw) { self.friendlyNames[$0] }
    }

    func testCameraNameUsesTheFriendlyNameWithoutTheStream() {
        XCTAssertEqual(name("camera.backyard_left_fluent"), "Backyard Left")
        XCTAssertEqual(name("camera.front_door_high"), "Front Door")
        XCTAssertEqual(name("camera.garage"), "Garage")
        XCTAssertEqual(name("camera.kids_room_clear"), "Kid's Room")
    }

    func testCameraNameWithoutAnEntityReadsTheId() {
        XCTAssertEqual(name("camera.driveway_snapshots_2"), "Driveway")
        XCTAssertEqual(name("camera.side_gate_2"), "Side Gate")
        XCTAssertEqual(name("camera.patio_sub"), "Patio")
    }

    func testCameraNameAlreadyFriendlyKeepsItsCapitals() {
        XCTAssertEqual(name("Front Door"), "Front Door")
        XCTAssertEqual(name("Backyard Left Fluent"), "Backyard Left")
        XCTAssertEqual(name("UniFi G4 Doorbell High"), "UniFi G4 Doorbell")
    }

    func testCameraNameNeverStripsToNothing() {
        XCTAssertEqual(name("camera.high"), "High")
        XCTAssertEqual(name("Snapshot"), "Snapshot")
    }

    func testCameraNameMissing() {
        XCTAssertNil(name(nil))
        XCTAssertNil(name("  "))
    }

    // MARK: Times

    func testEventTimeToday() {
        XCTAssertEqual(SecurityTimeline.eventTime(date(28, 17, 42), now: date(28, 20, 0), calendar: calendar, locale: locale),
                       "Today 5:42\u{202F}PM")
    }

    func testEventTimeYesterday() {
        XCTAssertEqual(SecurityTimeline.eventTime(date(27, 9, 5), now: date(28, 8, 0), calendar: calendar, locale: locale),
                       "Yesterday 9:05\u{202F}AM")
    }

    func testEventTimeEarlierShowsTheDate() {
        let text = SecurityTimeline.eventTime(date(26, 17, 42), now: date(28, 8, 0), calendar: calendar, locale: locale)
        XCTAssertTrue(text.hasPrefix("Thu, Nov 26"), text)
        XCTAssertTrue(text.hasSuffix("5:42\u{202F}PM"), text)
        XCTAssertFalse(text.contains("2026"), text)
    }

    func testEventTimeLastYearShowsTheYear() {
        let text = SecurityTimeline.eventTime(date(30, 8, 0, month: 12, year: 2025), now: date(28, 8, 0), calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("2025"), text)
    }

    // MARK: Days

    func testEventsOnADayKeepTheirOrder() {
        let events = [event("a", at: date(28, 9, 0)), event("b", at: date(27, 23, 59)),
                      event("c", at: date(28, 0, 1)), event("d", at: nil), event("e", at: date(26, 12, 0))]
        XCTAssertEqual(SecurityTimeline.events(events, on: date(28, 0, 0), calendar: calendar).map(\.uid), ["a", "c"])
        XCTAssertEqual(SecurityTimeline.events(events, on: date(27, 0, 0), calendar: calendar).map(\.uid), ["b"])
        XCTAssertEqual(SecurityTimeline.events(events, on: date(25, 0, 0), calendar: calendar).map(\.uid), [])
    }

    func testRecentDaysStartAtMidnightNewestFirst() {
        let days = DayStrip.recentDays(3, now: date(28, 15, 30), calendar: calendar)
        XCTAssertEqual(days, [date(28, 0, 0), date(27, 0, 0), date(26, 0, 0)])
    }

    func testDayLabels() {
        let now = date(28, 15, 30)
        XCTAssertEqual(DayStrip.label(for: date(28, 0, 0), now: now, calendar: calendar, locale: locale), "Today")
        XCTAssertEqual(DayStrip.label(for: date(27, 0, 0), now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(DayStrip.label(for: date(26, 0, 0), now: now, calendar: calendar, locale: locale), "Thu 26")
    }
}
