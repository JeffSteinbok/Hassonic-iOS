import XCTest
@testable import Hassonic

/// The `people` card: which people a config selects, and in what order.
final class PeopleCardConfigurationTests: XCTestCase {

    private func person(_ entityId: String, name: String, userId: String? = nil) -> HAEntityState {
        var attributes: [String: JSONValue] = [
            "friendly_name": .string(name),
            "latitude": .number(47.6),
            "longitude": .number(-122.3)
        ]
        if let userId { attributes["user_id"] = .string(userId) }
        return HAEntityState(entityId: entityId, state: "home", attributes: attributes)
    }

    private lazy var household = [
        person("person.zoe", name: "Zoe"),
        person("person.alex", name: "Alex", userId: "user-alex"),
        person("person.mel", name: "Mel")
    ]

    private func card(_ yaml: String) throws -> DashboardPeopleCardConfiguration {
        let config = try AppConfigurationParser.parse("""
        version: 1
        pages:
          - id: people
            title: People
            system_icon: person.2.fill
            sections:
              - cards:
        \(yaml)
        """)
        guard case .people(let people) = config.pages[0].sections[0].cards[0] else {
            throw XCTSkip("expected a people card")
        }
        return people
    }

    // MARK: - Config

    func testBareCardDefaultsToEveryoneButTheSignedInUser() throws {
        let card = try card("          - type: people")

        XCTAssertNil(card.entities)
        XCTAssertTrue(card.excludeSignedInUser)
    }

    func testAnExplicitListAndTitleAreRead() throws {
        let card = try card("""
                  - type: people
                    title: Where everyone is
                    entities: [person.mel, person.zoe]
                    excludeSignedInUser: false
        """)

        XCTAssertEqual(card.title, "Where everyone is")
        XCTAssertEqual(card.entities, ["person.mel", "person.zoe"])
        XCTAssertFalse(card.excludeSignedInUser)
    }

    func testANonPersonEntityIsRejected() {
        XCTAssertThrowsError(try card("""
                  - type: people
                    entities: [light.kitchen]
        """))
    }

    // MARK: - Selection

    func testOmittedListMeansEveryoneNameSorted() {
        let people = PersonLocationDirectory.people(from: household, matching: nil)

        XCTAssertEqual(people.map(\.name), ["Alex", "Mel", "Zoe"])
    }

    /// An explicit list is a deliberate order, not a filter over the sorted
    /// set — a household can put itself in the order it thinks in.
    func testAnExplicitListKeepsItsOwnOrder() {
        let people = PersonLocationDirectory.people(
            from: household,
            matching: ["person.zoe", "person.alex"]
        )

        XCTAssertEqual(people.map(\.name), ["Zoe", "Alex"])
    }

    func testAnEntityThatIsNotPresentIsSkippedRatherThanFatal() {
        let people = PersonLocationDirectory.people(
            from: household,
            matching: ["person.zoe", "person.nobody"]
        )

        XCTAssertEqual(people.map(\.name), ["Zoe"])
    }

    func testExcludingTheSignedInUserAppliesToAnExplicitListToo() {
        let people = PersonLocationDirectory.people(
            from: household,
            matching: ["person.alex", "person.mel"],
            excludingUserId: "user-alex"
        )

        XCTAssertEqual(people.map(\.name), ["Mel"])
    }

    /// The phone card has no head unit dictating row heights, so unlike
    /// CarPlay it isn't capped.
    func testThePhoneCardIsNotCappedAtTheCarPlayLimit() {
        let many = (0..<10).map { person("person.p\($0)", name: "Person \($0)") }

        XCTAssertEqual(PersonLocationDirectory.people(from: many, matching: nil).count, 10)
        XCTAssertEqual(PersonLocationDirectory.mappablePeople(from: many).count, 6)
    }
}
