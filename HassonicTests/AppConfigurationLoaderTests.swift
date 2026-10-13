import XCTest
@testable import Hassonic

final class DashboardConfigurationTests: XCTestCase {
    private let validYAML = """
    version: 1
    pages:
      - id: home
        title: Home
        system_icon: house
        sections:
          - title: Downstairs
            cards:
              - type: light
                entity: light.family_room
                title: Family Room
              - type: cover
                entity: cover.awning
      - id: security
        title: Security
        system_icon: shield
        sections:
          - cards:
              - type: alarm
                entity: alarm_control_panel.home
              - type: llm_vision_timeline
                title: Security History
    """

    func testParsesSupportedCardsAndPreservesOrder() throws {
        let configuration = try DashboardConfigurationParser.parse(validYAML)

        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(configuration.pages.map(\.id), ["home", "security"])
        XCTAssertEqual(configuration.pages[0].sections[0].title, "Downstairs")
        XCTAssertEqual(
            configuration.pages.flatMap(\.sections).flatMap(\.cards).map(\.typeName),
            ["light", "cover", "alarm", "llm_vision_timeline"]
        )
    }

    func testUnknownCardTypeIsPreservedWithoutRejectingDashboard() throws {
        let yaml = """
        version: 1
        pages:
          - id: home
            title: Home
            system_icon: house
            sections:
              - cards:
                  - type: future_card
                    title: Future
        """

        let configuration = try DashboardConfigurationParser.parse(yaml)

        guard case .unsupported(let card) = configuration.pages[0].sections[0].cards[0] else {
            return XCTFail("Expected unsupported card")
        }
        XCTAssertEqual(card.type, "future_card")
        XCTAssertEqual(card.title, "Future")
    }

    func testRejectsUnsupportedSchemaVersion() {
        let yaml = validYAML.replacingOccurrences(of: "version: 1", with: "version: 2")

        XCTAssertThrowsError(try DashboardConfigurationParser.parse(yaml)) { error in
            XCTAssertEqual(error as? DashboardConfigurationError, .unsupportedVersion(2))
        }
    }

    func testRejectsDuplicatePageIDs() {
        let yaml = validYAML.replacingOccurrences(of: "id: security", with: "id: home")

        XCTAssertThrowsError(try DashboardConfigurationParser.parse(yaml)) { error in
            XCTAssertEqual(error as? DashboardConfigurationError, .duplicatePageID("home"))
        }
    }

    func testRejectsEntityFromWrongDomain() {
        let yaml = validYAML.replacingOccurrences(
            of: "entity: light.family_room",
            with: "entity: switch.family_room"
        )

        XCTAssertThrowsError(try DashboardConfigurationParser.parse(yaml)) { error in
            XCTAssertEqual(
                error as? DashboardConfigurationError,
                .invalidEntity(
                    entityID: "switch.family_room",
                    cardType: "light",
                    expectedDomain: "light"
                )
            )
        }
    }

    func testReportsMissingKeyWithItsLocation() {
        let yaml = validYAML.replacingOccurrences(of: "    system_icon: shield\n", with: "")

        XCTAssertThrowsError(try DashboardConfigurationParser.parse(yaml)) { error in
            XCTAssertEqual(
                error as? DashboardConfigurationError,
                .malformedYAML("missing \"system_icon\" at pages[1]")
            )
        }
    }

    func testReportsWronglyTypedValueWithItsLocation() {
        let yaml = validYAML.replacingOccurrences(of: "version: 1", with: "version: one")

        XCTAssertThrowsError(try DashboardConfigurationParser.parse(yaml)) { error in
            XCTAssertEqual(
                error as? DashboardConfigurationError,
                .malformedYAML("version: expected Int, found a value of a different type")
            )
        }
    }

    func testReportsYAMLSyntaxErrorAtTheTopLevel() {
        XCTAssertThrowsError(try DashboardConfigurationParser.parse("not: [valid")) { error in
            guard case .malformedYAML(let description)? = error as? DashboardConfigurationError else {
                return XCTFail("Expected a malformedYAML error, got \(error)")
            }
            XCTAssertTrue(description.hasPrefix("the top level: "), description)
            XCTAssertTrue(description.contains("not valid YAML"), description)
        }
    }

    @MainActor
    func testValidCacheTakesPrecedenceOverBundledConfiguration() throws {
        let cached = validYAML.replacingOccurrences(of: "title: Home", with: "title: Cached Home")

        let initial = try AppConfigurationLoader.selectInitialConfiguration(
            cachedYAML: cached,
            bundledYAML: validYAML
        )

        XCTAssertEqual(initial.source, .cache)
        XCTAssertEqual(initial.configuration.pages[0].title, "Cached Home")
        XCTAssertNil(initial.cacheError)
    }

    @MainActor
    func testInvalidCacheFallsBackToBundledConfigurationWithError() throws {
        let initial = try AppConfigurationLoader.selectInitialConfiguration(
            cachedYAML: "not: [valid",
            bundledYAML: validYAML
        )

        XCTAssertEqual(initial.source, .bundled)
        XCTAssertEqual(initial.configuration.pages[0].title, "Home")
        XCTAssertNotNil(initial.cacheError)
    }
}

final class DashboardDecodingErrorFormatterTests: XCTestCase {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(_ name: String) {
            stringValue = name
            intValue = nil
        }

        init(_ index: Int) {
            stringValue = "Index \(index)"
            intValue = index
        }

        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(intValue) }
    }

    private func context(_ path: [Key], _ debugDescription: String = "") -> DecodingError.Context {
        DecodingError.Context(codingPath: path, debugDescription: debugDescription)
    }

    func testKeyNotFoundNamesTheKeyAndItsContainer() {
        let error = DecodingError.keyNotFound(Key("system_icon"), context([Key("pages"), Key(1)]))

        XCTAssertEqual(
            DashboardDecodingErrorFormatter.describe(error),
            "missing \"system_icon\" at pages[1]"
        )
    }

    func testKeyNotFoundAtTheTopLevel() {
        let error = DecodingError.keyNotFound(Key("version"), context([]))

        XCTAssertEqual(
            DashboardDecodingErrorFormatter.describe(error),
            "missing \"version\" at the top level"
        )
    }

    func testValueNotFoundSpellsOutTheFullPath() {
        let path = [Key("pages"), Key(0), Key("sections"), Key(1), Key("cards"), Key(2), Key("entity")]
        let error = DecodingError.valueNotFound(String.self, context(path))

        XCTAssertEqual(
            DashboardDecodingErrorFormatter.describe(error),
            "pages[0].sections[1].cards[2].entity: expected String, found nothing"
        )
    }

    func testTypeMismatchNamesTheExpectedType() {
        let error = DecodingError.typeMismatch(Int.self, context([Key("version")]))

        XCTAssertEqual(
            DashboardDecodingErrorFormatter.describe(error),
            "version: expected Int, found a value of a different type"
        )
    }

    func testDataCorruptedCarriesTheUnderlyingParseError() {
        let underlying = NSError(
            domain: "Yams",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "3:5: error: scanner: bad indentation"]
        )
        let error = DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "The given data was not valid YAML.",
                underlyingError: underlying
            )
        )

        let description = DashboardDecodingErrorFormatter.describe(error)

        XCTAssertTrue(description.hasPrefix("the top level: The given data was not valid YAML."), description)
        XCTAssertTrue(description.contains("bad indentation"), description)
    }

    /// Stands in for `Yams.Node.Mapping`, whose printed name is just "Mapping".
    private enum Node {
        struct Mapping {}
    }

    func testYamsNodeTypesAreTranslatedToPlainLanguage() {
        let error = DecodingError.typeMismatch(
            Node.Mapping.self,
            context([Key("pages"), Key(0), Key("sections")])
        )

        XCTAssertEqual(
            DashboardDecodingErrorFormatter.describe(error),
            "pages[0].sections: expected a block of keys, found a value of a different type"
        )
    }
}

@MainActor
final class DashboardCardActionRouterTests: XCTestCase {
    func testRoutesLightStateToConfiguredEntity() {
        let client = MockHAClient()

        DashboardCardActionRouter.setLight(true, entityID: "light.custom", client: client)
        DashboardCardActionRouter.setLight(false, entityID: "light.custom", client: client)

        XCTAssertEqual(client.serviceCallLog.map(\.method), ["lightTurnOn", "lightTurnOff"])
        XCTAssertEqual(client.serviceCallLog.map(\.entityId), ["light.custom", "light.custom"])
    }

    func testRoutesAllCoverActionsToConfiguredEntity() {
        let client = MockHAClient()
        let entityID = "cover.custom"

        DashboardCardActionRouter.performCoverAction(.open, entityID: entityID, client: client)
        DashboardCardActionRouter.performCoverAction(.close, entityID: entityID, client: client)
        DashboardCardActionRouter.performCoverAction(.stop, entityID: entityID, client: client)
        DashboardCardActionRouter.performCoverAction(.setPosition(42), entityID: entityID, client: client)

        XCTAssertEqual(
            client.serviceCallLog.map(\.method),
            ["coverOpen", "coverClose", "coverStop", "coverSetPosition:42"]
        )
        XCTAssertTrue(client.serviceCallLog.allSatisfy { $0.entityId == entityID })
    }

    func testRoutesAllAlarmActionsToConfiguredEntity() {
        let client = MockHAClient()
        let entityID = "alarm_control_panel.custom"

        for mode in AlarmMode.allCases {
            DashboardCardActionRouter.setAlarmMode(mode, entityID: entityID, client: client)
        }
        DashboardCardActionRouter.disarm(entityID: entityID, client: client)

        XCTAssertEqual(
            client.serviceCallLog.map(\.method),
            ["armHome", "armAway", "armNight", "armVacation", "disarmAlarm"]
        )
        XCTAssertTrue(client.serviceCallLog.allSatisfy { $0.entityId == entityID })
    }
}

private final class DashboardURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AppConfigurationLoaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var session: URLSession!

    /// Tests share the app container with the running app, so a config a
    /// developer injected with scripts/inject_config.py is sitting right where
    /// the debug override looks. Stash it for the duration rather than let it
    /// decide what these tests see — and put it back, so running tests doesn't
    /// silently undo an injection.
    private var stashedOverride: Data?

    override func setUp() {
        super.setUp()
        if let url = Self.overrideURL {
            stashedOverride = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
        }

        let suiteName = "AppConfigurationLoaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardURLProtocolStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        if let url = Self.overrideURL {
            try? FileManager.default.removeItem(at: url)
            if let stashedOverride {
                try? stashedOverride.write(to: url)
            }
        }
        stashedOverride = nil
        DashboardURLProtocolStub.handler = nil
        session.invalidateAndCancel()
        session = nil
        defaults = nil
        super.tearDown()
    }

    func testSuccessfulRefreshUsesExpectedURLAndAuthorization() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Bundled"))
        let remoteYAML = Self.yaml(title: "Remote")
        DashboardURLProtocolStub.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://example.test/\(AppConstants.configURLPath)"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data(remoteYAML.utf8))
        }
        let loader = AppConfigurationLoader(
            configuration: bundled,
            defaults: defaults,
            session: session
        )

        await loader.refresh(baseURLString: "https://example.test", accessToken: "secret")

        XCTAssertEqual(loader.configuration.pages[0].title, "Remote")
        XCTAssertEqual(loader.source, .remote)
        XCTAssertNil(loader.errorMessage)
    }

    func testInvalidRemoteYAMLPreservesLastKnownGoodConfiguration() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Last Known Good"))
        DashboardURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data("not: [valid".utf8))
        }
        let loader = AppConfigurationLoader(
            configuration: bundled,
            defaults: defaults,
            session: session
        )

        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        XCTAssertEqual(loader.configuration.pages[0].title, "Last Known Good")
        XCTAssertEqual(loader.source, .bundled)
        XCTAssertNotNil(loader.errorMessage)
    }

    func testHTMLResponseIsReportedAsAWebPageRatherThanADecodingFailure() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Last Known Good"))
        DashboardURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data("<!DOCTYPE html>\n<html><body>Starting…</body></html>".utf8))
        }
        let loader = AppConfigurationLoader(
            configuration: bundled,
            defaults: defaults,
            session: session
        )

        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        let message = try XCTUnwrap(loader.errorMessage)
        XCTAssertTrue(message.contains("returned a web page"), message)
    }

    func testTransientTLSFailureIsRetriedAndThenSucceeds() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Bundled"))
        let remoteYAML = Self.yaml(title: "Remote")
        var attempts = 0
        DashboardURLProtocolStub.handler = { request in
            attempts += 1
            if attempts == 1 { throw URLError(.secureConnectionFailed) }
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(remoteYAML.utf8))
        }
        let loader = AppConfigurationLoader(configuration: bundled, defaults: defaults, session: session)
        loader.networkRetryDelays = [.zero, .zero]

        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(loader.configuration.pages[0].title, "Remote")
        XCTAssertNil(loader.errorMessage)
    }

    func testPersistentNetworkFailureGivesUpAfterTheRetries() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Bundled"))
        var attempts = 0
        DashboardURLProtocolStub.handler = { _ in
            attempts += 1
            throw URLError(.secureConnectionFailed)
        }
        let loader = AppConfigurationLoader(configuration: bundled, defaults: defaults, session: session)
        loader.networkRetryDelays = [.zero, .zero]

        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(loader.configuration.pages[0].title, "Bundled")
        // Nothing good loaded yet, so this one does report.
        XCTAssertNotNil(loader.errorMessage)
    }

    /// A refresh that was called off (pull-to-refresh released early) isn't
    /// a failure and shouldn't leave a banner behind.
    func testCancelledRefreshReportsNothing() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Bundled"))
        DashboardURLProtocolStub.handler = { _ in throw URLError(.cancelled) }
        let loader = AppConfigurationLoader(configuration: bundled, defaults: defaults, session: session)
        loader.networkRetryDelays = [.zero, .zero]

        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        XCTAssertEqual(loader.configuration.pages[0].title, "Bundled")
        XCTAssertNil(loader.errorMessage)
    }

    /// The phone's resume-time TLS failure: the config on screen is already
    /// the good one, so a failed re-check isn't worth a banner.
    func testNetworkFailureAfterAGoodLoadKeepsQuiet() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Bundled"))
        let remoteYAML = Self.yaml(title: "Remote")
        var failing = false
        DashboardURLProtocolStub.handler = { request in
            if failing { throw URLError(.secureConnectionFailed) }
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(remoteYAML.utf8))
        }
        let loader = AppConfigurationLoader(configuration: bundled, defaults: defaults, session: session)
        loader.networkRetryDelays = [.zero]
        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        failing = true
        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        XCTAssertEqual(loader.configuration.pages[0].title, "Remote")
        XCTAssertNil(loader.errorMessage)
    }

    func testHTTPErrorIsNotRetried() async throws {
        let bundled = try AppConfigurationParser.parse(Self.yaml(title: "Bundled"))
        var attempts = 0
        DashboardURLProtocolStub.handler = { request in
            attempts += 1
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)
            )
            return (response, Data())
        }
        let loader = AppConfigurationLoader(configuration: bundled, defaults: defaults, session: session)
        loader.networkRetryDelays = [.zero, .zero]

        await loader.refresh(baseURLString: "https://example.test", accessToken: nil)

        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(loader.errorMessage)
    }

    /// Guards the contract `scripts/inject_dashboard.py` relies on: the file
    /// name and location debug builds read a dashboard from.
    func testDebugOverrideIsReadFromDocumentsDirectory() throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let overrideURL = documents.appendingPathComponent("config-override.yaml")
        // setUp has already cleared the slate, so this only has to undo itself.
        defer { try? FileManager.default.removeItem(at: overrideURL) }

        try Self.yaml(title: "Injected").write(to: overrideURL, atomically: true, encoding: .utf8)

        let overrideYAML = try XCTUnwrap(AppConfigurationLoader.debugOverrideYAML())
        XCTAssertEqual(try DashboardConfigurationParser.parse(overrideYAML).pages[0].title, "Injected")
    }

    /// Live reload. `DashboardOverrideWatcher` does nothing but call
    /// `applyDebugOverride()` on a directory event, so these cover what a save
    /// from `inject_dashboard.py --watch` does to the dashboard on screen.
    func testChangedDebugOverrideIsPickedUpWithoutRelaunching() throws {
        let loader = try overrideLoader(startingAt: "At Launch")

        try withOverride(Self.yaml(title: "Injected")) {
            XCTAssertTrue(loader.applyDebugOverride())
        }

        XCTAssertEqual(loader.configuration.pages[0].title, "Injected")
        XCTAssertEqual(loader.source, .debugOverride)
        XCTAssertNil(loader.errorMessage)
    }

    func testInvalidDebugOverrideLeavesTheLastGoodDashboardOnScreen() throws {
        let loader = try overrideLoader(startingAt: "At Launch")

        try withOverride("not: [valid") {
            XCTAssertTrue(loader.applyDebugOverride())
        }

        XCTAssertEqual(loader.configuration.pages[0].title, "At Launch")
        let message = try XCTUnwrap(loader.errorMessage)
        XCTAssertTrue(message.contains("override is invalid"), message)
    }

    /// `--clear` deletes the file while the app keeps running, so the watcher
    /// has to put the dashboard back the way a fresh launch would resolve it.
    func testClearedDebugOverrideFallsBackTheWayALaunchWould() throws {
        let loader = AppConfigurationLoader(
            configuration: try AppConfigurationParser.parse(Self.yaml(title: "At Launch")),
            defaults: defaults,
            session: session,
            usesDebugOverride: true,
            bundledYAML: Self.yaml(title: "Bundled")
        )

        try withOverride(Self.yaml(title: "Injected")) {
            XCTAssertTrue(loader.applyDebugOverride())
            XCTAssertEqual(loader.configuration.pages[0].title, "Injected")
        }

        // withOverride has removed the file on its way out, which is the state
        // --clear leaves behind.
        XCTAssertFalse(loader.applyDebugOverride())
        XCTAssertEqual(loader.configuration.pages[0].title, "Bundled")
        XCTAssertEqual(loader.source, .bundled)
    }

    private func overrideLoader(startingAt title: String) throws -> AppConfigurationLoader {
        AppConfigurationLoader(
            configuration: try AppConfigurationParser.parse(Self.yaml(title: title)),
            defaults: defaults,
            session: session,
            usesDebugOverride: true
        )
    }

    /// Puts an override in the app container for the duration of `body` and
    /// restores whatever was there — the container is shared with the
    /// simulator's app, so a developer's injected dashboard has to survive a
    /// test run.
    private static var overrideURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("config-override.yaml")
    }

    private func withOverride(_ yaml: String, _ body: () throws -> Void) throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let overrideURL = documents.appendingPathComponent("config-override.yaml")
        // setUp has already cleared the slate, so this only has to undo itself.
        defer { try? FileManager.default.removeItem(at: overrideURL) }

        try yaml.write(to: overrideURL, atomically: true, encoding: .utf8)
        try body()
    }

    private static func yaml(title: String) -> String {
        """
        version: 1
        pages:
          - id: home
            title: \(title)
            system_icon: house
            sections:
              - cards:
                  - type: light
                    entity: light.family_room
        """
    }
}
