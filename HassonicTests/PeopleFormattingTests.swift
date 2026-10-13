import CoreLocation
import XCTest
@testable import Hassonic

/// What the People card says under each person: distance from home, since
/// when, and who's home together.
final class PeopleFormattingTests: XCTestCase {

    private let us = Locale(identifier: "en_US")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func person(state: String, latitude: Double? = nil, longitude: Double? = nil) -> PersonLocation {
        PersonLocation(
            entityId: "person.alex",
            name: "Alex Kay",
            locationLabel: PersonLocationDirectory.locationLabel(for: state),
            latitude: latitude,
            longitude: longitude,
            pictureURL: nil,
            addressLines: [],
            zoneEnteredAt: nil
        )
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: Home and zones

    func testHomeCoordinateComesFromZoneHome() {
        let entities = [
            HAEntityState(entityId: "zone.work", state: "0", attributes: ["latitude": .number(1), "longitude": .number(2)]),
            HAEntityState(entityId: "zone.home", state: "2", attributes: ["latitude": .number(40.0), "longitude": .number(-105.27)]),
        ]
        let home = PersonLocationDirectory.homeCoordinate(from: entities)
        XCTAssertEqual(home?.latitude, 40.0)
        XCTAssertEqual(home?.longitude, -105.27)
        XCTAssertNil(PersonLocationDirectory.homeCoordinate(from: []))
    }

    func testNamedZonesAreNeitherHomeNorAway() {
        XCTAssertTrue(person(state: "home").isHome)
        XCTAssertFalse(person(state: "home").isInNamedZone)
        XCTAssertFalse(person(state: "not_home").isInNamedZone)
        XCTAssertFalse(person(state: "unknown").isInNamedZone)
        XCTAssertTrue(person(state: "Work").isInNamedZone)
    }

    // MARK: Distance

    func testDistanceIsInMilesForUSAndKilometresForMetric() {
        let home = CLLocationCoordinate2D(latitude: 40.0, longitude: -105.27)
        // 0.05° of latitude is about 5.55 km / 3.45 mi.
        let away = person(state: "not_home", latitude: 40.05, longitude: -105.27)
        XCTAssertEqual(PeopleFormatting.distanceFromHome(of: away, home: home, locale: us), "3.4 mi")
        XCTAssertEqual(PeopleFormatting.distanceFromHome(of: away, home: home, locale: Locale(identifier: "en_GB_u_ms_metric")), "5.6 km")
    }

    func testNoDistanceForSomeoneHomeOrWithoutACoordinate() {
        let home = CLLocationCoordinate2D(latitude: 40.0, longitude: -105.27)
        XCTAssertNil(PeopleFormatting.distanceFromHome(of: person(state: "home", latitude: 40.0, longitude: -105.27), home: home))
        XCTAssertNil(PeopleFormatting.distanceFromHome(of: person(state: "not_home"), home: home))
        XCTAssertNil(PeopleFormatting.distanceFromHome(of: person(state: "not_home", latitude: 40.05, longitude: -105.27), home: nil))
    }

    // MARK: Activity

    func testActivityComesFromTheTrackersSensorEvenWhenTheNamesDiffer() {
        let person = HAEntityState(entityId: "person.riley", state: "not_home", attributes: [
            "friendly_name": .string("Riley"),
            "source": .string("device_tracker.rileys_iphone_17"),
            "device_trackers": .array([.string("device_tracker.rileys_iphone_17")]),
        ])
        let entities = [
            person,
            HAEntityState(entityId: "device_tracker.rileys_iphone_17", state: "not_home", attributes: ["friendly_name": .string("Riley’s iPhone")]),
            HAEntityState(entityId: "sensor.rileys_iphone_activity", state: "Automotive", attributes: ["friendly_name": .string("Riley’s iPhone Activity")]),
            HAEntityState(entityId: "sensor.rileys_iphone_geocoded_location", state: "40 Oak Ave\nSpringfield IL 62702", attributes: ["friendly_name": .string("Riley’s iPhone Geocoded Location")]),
        ]
        let riley = PersonLocationDirectory.people(from: entities)[0]
        XCTAssertTrue(riley.isDriving)
        XCTAssertEqual(riley.street, "40 Oak Ave")
    }

    func testUnknownActivityIsNil() {
        let person = HAEntityState(entityId: "person.sam", state: "home", attributes: [
            "source": .string("device_tracker.sams_iphone"),
        ])
        let entities = [person, HAEntityState(entityId: "sensor.sams_iphone_activity", state: "Unknown", attributes: [:])]
        XCTAssertNil(PersonLocationDirectory.activity(for: person, in: entities))
    }

    // MARK: Since

    func testSinceIsATimeTodayThenADayThenADate() {
        let now = date("2026-10-12T22:00:00Z")
        XCTAssertEqual(PeopleFormatting.since(date("2026-10-12T15:15:00Z"), now: now, calendar: utc, locale: us).replacingOccurrences(of: "\u{202F}", with: " "), "since 3:15 PM")
        XCTAssertEqual(PeopleFormatting.since(date("2026-10-11T23:00:00Z"), now: now, calendar: utc, locale: us), "since yesterday")
        XCTAssertEqual(PeopleFormatting.since(date("2026-10-08T09:00:00Z"), now: now, calendar: utc, locale: us), "since Thu")
        XCTAssertEqual(PeopleFormatting.since(date("2026-09-30T09:00:00Z"), now: now, calendar: utc, locale: us), "since Sep 30")
    }

    // MARK: Names

    func testNamesJoinWithAnAmpersand() {
        XCTAssertEqual(PeopleFormatting.names(["Sam"]), "Sam")
        XCTAssertEqual(PeopleFormatting.names(["Sam", "Morgan"]), "Sam & Morgan")
        XCTAssertEqual(PeopleFormatting.names(["Sam", "Morgan", "Kai"]), "Sam, Morgan & Kai")
        XCTAssertEqual(PeopleFormatting.names([]), "")
    }
}
