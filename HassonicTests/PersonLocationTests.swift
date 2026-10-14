import CoreLocation
import UIKit
import XCTest
@testable import Hassonic

@MainActor
final class PersonLocationTests: XCTestCase {

    // MARK: - Helpers

    private func person(
        _ entityId: String,
        name: String,
        state: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        picture: String? = nil,
        userId: String? = nil
    ) -> HAEntityState {
        var attributes: [String: JSONValue] = ["friendly_name": .string(name)]
        if let latitude { attributes["latitude"] = .number(latitude) }
        if let longitude { attributes["longitude"] = .number(longitude) }
        if let picture { attributes["entity_picture"] = .string(picture) }
        if let userId { attributes["user_id"] = .string(userId) }
        return HAEntityState(entityId: entityId, state: state, attributes: attributes)
    }

    private func zone(_ entityId: String, name: String, latitude: Double, longitude: Double) -> HAEntityState {
        HAEntityState(
            entityId: entityId,
            state: "zoning",
            attributes: [
                "friendly_name": .string(name),
                "latitude": .number(latitude),
                "longitude": .number(longitude)
            ]
        )
    }

    // MARK: - Location labels

    func testHomeAndAwayStatesGetFriendlyLabels() {
        XCTAssertEqual(PersonLocationDirectory.locationLabel(for: "home"), "Home")
        XCTAssertEqual(PersonLocationDirectory.locationLabel(for: "not_home"), "Away")
    }

    func testZoneStateIsUsedVerbatimAsTheLabel() {
        XCTAssertEqual(PersonLocationDirectory.locationLabel(for: "Grocery Store"), "Grocery Store")
    }

    func testUnknownStatesAreLabelledUnknown() {
        XCTAssertEqual(PersonLocationDirectory.locationLabel(for: "unknown"), "Unknown")
        XCTAssertEqual(PersonLocationDirectory.locationLabel(for: "unavailable"), "Unknown")
        XCTAssertEqual(PersonLocationDirectory.locationLabel(for: ""), "Unknown")
    }

    // MARK: - Building the people list

    func testOnlyPersonEntitiesAreIncluded() {
        let entities = [
            person("person.alex", name: "Alex", state: "home", latitude: 47.6, longitude: -122.3),
            HAEntityState(entityId: "device_tracker.alex_phone", state: "home", attributes: [:]),
            HAEntityState(entityId: "light.kitchen", state: "on", attributes: [:])
        ]

        let people = PersonLocationDirectory.people(from: entities)

        XCTAssertEqual(people.map(\.entityId), ["person.alex"])
    }

    func testPeopleAreSortedByName() {
        let entities = [
            person("person.zoe", name: "Zoe", state: "home", latitude: 1, longitude: 1),
            person("person.alex", name: "alex", state: "home", latitude: 2, longitude: 2),
            person("person.mel", name: "Mel", state: "home", latitude: 3, longitude: 3)
        ]

        XCTAssertEqual(
            PersonLocationDirectory.people(from: entities).map(\.name),
            ["alex", "Mel", "Zoe"]
        )
    }

    func testPersonGPSAttributesBecomeTheCoordinate() {
        let people = PersonLocationDirectory.people(from: [
            person("person.alex", name: "Alex", state: "Work", latitude: 47.6062, longitude: -122.3321)
        ])

        XCTAssertEqual(people.first?.latitude, 47.6062)
        XCTAssertEqual(people.first?.longitude, -122.3321)
        XCTAssertEqual(people.first?.locationLabel, "Work")
    }

    func testStringCoordinatesAreParsed() {
        let entity = HAEntityState(
            entityId: "person.alex",
            state: "home",
            attributes: [
                "friendly_name": .string("Alex"),
                "latitude": .string("47.6062"),
                "longitude": .string("-122.3321")
            ]
        )

        XCTAssertEqual(PersonLocationDirectory.people(from: [entity]).first?.latitude, 47.6062)
    }

    // MARK: - Zone fallback for people without GPS

    func testPersonWithoutGPSFallsBackToTheHomeZone() {
        let people = PersonLocationDirectory.people(from: [
            person("person.alex", name: "Alex", state: "home"),
            zone("zone.home", name: "Home", latitude: 47.6, longitude: -122.3)
        ])

        XCTAssertEqual(people.first?.latitude, 47.6)
        XCTAssertEqual(people.first?.longitude, -122.3)
    }

    func testPersonWithoutGPSFallsBackToTheNamedZone() {
        let people = PersonLocationDirectory.people(from: [
            person("person.alex", name: "Alex", state: "Grocery Store"),
            zone("zone.grocery_store", name: "Grocery Store", latitude: 47.5, longitude: -122.1)
        ])

        XCTAssertEqual(people.first?.latitude, 47.5)
    }

    func testPersonGPSWinsOverTheZoneFallback() {
        let people = PersonLocationDirectory.people(from: [
            person("person.alex", name: "Alex", state: "home", latitude: 47.61, longitude: -122.31),
            zone("zone.home", name: "Home", latitude: 47.6, longitude: -122.3)
        ])

        XCTAssertEqual(people.first?.latitude, 47.61)
    }

    func testAwayWithoutGPSHasNoCoordinate() {
        let people = PersonLocationDirectory.people(from: [
            person("person.alex", name: "Alex", state: "not_home"),
            zone("zone.home", name: "Home", latitude: 47.6, longitude: -122.3)
        ])

        XCTAssertEqual(people.first?.locationLabel, "Away")
        XCTAssertFalse(people[0].hasCoordinate)
    }


    // MARK: - Profile pictures

    func testRelativeEntityPictureResolvesAgainstTheServerURL() {
        let people = PersonLocationDirectory.people(
            from: [person("person.alex", name: "Alex", state: "home", picture: "/api/image/serve/abc/512x512")],
            baseURLString: "https://ha.example.com"
        )

        XCTAssertEqual(
            people.first?.pictureURL?.absoluteString,
            "https://ha.example.com/api/image/serve/abc/512x512"
        )
    }

    func testAbsoluteEntityPictureIsUsedAsIs() {
        let people = PersonLocationDirectory.people(
            from: [person("person.alex", name: "Alex", state: "home", picture: "https://cdn.example.com/alex.png")],
            baseURLString: "https://ha.example.com"
        )

        XCTAssertEqual(people.first?.pictureURL?.absoluteString, "https://cdn.example.com/alex.png")
    }

    func testPersonWithoutAPictureHasNoPictureURL() {
        let people = PersonLocationDirectory.people(
            from: [person("person.alex", name: "Alex", state: "home")],
            baseURLString: "https://ha.example.com"
        )

        XCTAssertNil(people.first?.pictureURL)
    }

    // MARK: - Initials

    func testInitialsUseTheFirstTwoWords() {
        XCTAssertEqual(PersonLocationDirectory.initials(for: "Jamie Sterling"), "JS")
        XCTAssertEqual(PersonLocationDirectory.initials(for: "alex"), "A")
        XCTAssertEqual(PersonLocationDirectory.initials(for: "Mary Jane Watson"), "MJ")
    }

    func testInitialsFallBackWhenThereAreNoLetters() {
        XCTAssertEqual(PersonLocationDirectory.initials(for: "123"), "?")
        XCTAssertEqual(PersonLocationDirectory.initials(for: ""), "?")
    }





    // MARK: - Excluding whoever is signed in

    func testSignedInUserIsLeftOffTheList() {
        let entities = [
            person("person.jamie", name: "Jamie", state: "home", latitude: 1, longitude: 1, userId: "user-jamie"),
            person("person.morgan", name: "Morgan", state: "home", latitude: 2, longitude: 2, userId: "user-morgan")
        ]

        let people = PersonLocationDirectory.people(from: entities, excludingUserId: "user-jamie")

        XCTAssertEqual(people.map(\.name), ["Morgan"])
    }

    func testEveryoneIsKeptWhenTheCurrentUserIsUnknown() {
        let entities = [
            person("person.jamie", name: "Jamie", state: "home", latitude: 1, longitude: 1, userId: "user-jamie"),
            person("person.morgan", name: "Morgan", state: "home", latitude: 2, longitude: 2, userId: "user-morgan")
        ]

        XCTAssertEqual(PersonLocationDirectory.people(from: entities).count, 2)
        XCTAssertEqual(PersonLocationDirectory.people(from: entities, excludingUserId: "").count, 2)
    }

    func testPeopleWithoutAUserAccountAreNeverExcluded() {
        let entities = [
            person("person.guest", name: "Guest", state: "home", latitude: 1, longitude: 1),
            person("person.jamie", name: "Jamie", state: "home", latitude: 2, longitude: 2, userId: "user-jamie")
        ]

        XCTAssertEqual(
            PersonLocationDirectory.people(from: entities, excludingUserId: "user-jamie").map(\.name),
            ["Guest"]
        )
    }


    // MARK: - How a person reads

    func testGivenNameIsTheFirstWord() {
        let people = PersonLocationDirectory.people(from: [
            person("person.jamie", name: "Jamie Sterling", state: "home", latitude: 1, longitude: 1),
            person("person.alex", name: "Alex", state: "home", latitude: 2, longitude: 2)
        ])

        XCTAssertEqual(people.map(\.givenName), ["Alex", "Jamie"])
    }

    func testStreetAndLocalitySplitAcrossTheSubtitleAndSummary() {
        let entities = [
            personWithTracker("person.avery", name: "Avery Sterling", source: "device_tracker.averys_iphone"),
            geocodedSensor("averys_iphone", address: "40 Oak Ave\nSpringfield, IL 62702\nUnited States")
        ]

        let person = PersonLocationDirectory.people(from: entities).first

        XCTAssertEqual(person?.street, "40 Oak Ave")
        // The country line is dropped — it only truncates the town away.
        XCTAssertEqual(person?.locality, "Springfield, IL 62702")
    }

    func testStreetAndLocalityJoinForTheExpandedCard() {
        let entities = [
            personWithTracker("person.avery", name: "Avery Sterling", source: "device_tracker.averys_iphone"),
            geocodedSensor("averys_iphone", address: "40 Oak Ave\nSpringfield IL 62702\nUnited States")
        ]

        XCTAssertEqual(
            PersonLocationDirectory.people(from: entities).first?.streetAndLocality,
            "40 Oak Ave, Springfield IL 62702"
        )
    }

    func testNoLocalityWhenTheAddressIsASingleLine() {
        let entities = [
            personWithTracker("person.avery", name: "Avery", source: "device_tracker.averys_iphone"),
            geocodedSensor("averys_iphone", address: "40 Oak Ave")
        ]

        let person = PersonLocationDirectory.people(from: entities).first

        XCTAssertEqual(person?.street, "40 Oak Ave")
        XCTAssertNil(person?.locality)
    }

    func testNoStreetWhenTheDevicePublishesNoAddress() {
        let people = PersonLocationDirectory.people(from: [
            person("person.alex", name: "Alex", state: "home", latitude: 1, longitude: 1)
        ])

        XCTAssertNil(people.first?.street)
        XCTAssertNil(people.first?.locality)
        XCTAssertNil(people.first?.streetAndLocality)
    }

    // MARK: - Addresses

    private func geocodedSensor(_ objectId: String, address: String) -> HAEntityState {
        HAEntityState(entityId: "sensor.\(objectId)_geocoded_location", state: address, attributes: [:])
    }

    private func personWithTracker(_ entityId: String, name: String, source: String) -> HAEntityState {
        HAEntityState(
            entityId: entityId,
            state: "not_home",
            attributes: [
                "friendly_name": .string(name),
                "latitude": .number(40.0063),
                "longitude": .number(-105.2658),
                "source": .string(source)
            ]
        )
    }

    func testAddressComesFromTheCompanionAppGeocodedSensor() {
        let entities = [
            personWithTracker("person.jamie", name: "Jamie", source: "device_tracker.jamies_iphone"),
            geocodedSensor("jamies_iphone", address: "12 Elm St\nSpringfield IL 62701\nUnited States")
        ]

        XCTAssertEqual(
            PersonLocationDirectory.people(from: entities).first?.addressLines,
            ["12 Elm St", "Springfield IL 62701", "United States"]
        )
    }

    func testDeviceTrackersListIsUsedWhenThereIsNoActiveSource() {
        let person = HAEntityState(
            entityId: "person.jamie",
            state: "not_home",
            attributes: [
                "friendly_name": .string("Jamie"),
                "latitude": .number(40.0063),
                "longitude": .number(-105.2658),
                "device_trackers": .array([.string("device_tracker.jamies_ipad")])
            ]
        )

        let people = PersonLocationDirectory.people(from: [
            person,
            geocodedSensor("jamies_ipad", address: "12 Elm St")
        ])

        XCTAssertEqual(people.first?.street, "12 Elm St")
    }

    func testNoAddressWhenTheDevicePublishesNone() {
        let people = PersonLocationDirectory.people(from: [
            personWithTracker("person.jamie", name: "Jamie", source: "device_tracker.jamies_iphone")
        ])

        XCTAssertTrue(people.first?.addressLines.isEmpty == true)
    }

    func testPlaceholderSensorStatesAreNotTreatedAsAddresses() {
        XCTAssertTrue(PersonLocationDirectory.normalizedAddressLines("unknown").isEmpty)
        XCTAssertTrue(PersonLocationDirectory.normalizedAddressLines("unavailable").isEmpty)
        XCTAssertTrue(PersonLocationDirectory.normalizedAddressLines("   ").isEmpty)
        XCTAssertEqual(
            PersonLocationDirectory.normalizedAddressLines("88 Maple Rd\nVictoria BC V8W 1A1\nCanada"),
            ["88 Maple Rd", "Victoria BC V8W 1A1", "Canada"]
        )
    }

    // MARK: - How long they've been there



    func testHomeAssistantTimestampsParse() {
        // Six fractional digits, as HA actually sends.
        let withFraction = HATimestamp.parse("2026-09-11T21:30:00.123456+00:00")
        let plain = HATimestamp.parse("2026-09-11T21:30:00+00:00")

        XCTAssertNotNil(withFraction)
        XCTAssertNotNil(plain)
        XCTAssertEqual(withFraction!.timeIntervalSince1970, plain!.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(HATimestamp.parse("not a date"))
    }

    func testZoneEntryComesFromTheEntityLastChanged() {
        let entity = HAEntityState(
            entityId: "person.avery",
            state: "home",
            attributes: [
                "friendly_name": .string("Avery"),
                "latitude": .number(1),
                "longitude": .number(1)
            ],
            lastChanged: "2026-09-11T21:30:00.123456+00:00"
        )

        XCTAssertEqual(
            PersonLocationDirectory.people(from: [entity]).first?.zoneEnteredAt,
            HATimestamp.parse("2026-09-11T21:30:00.123456+00:00")
        )
    }
}
