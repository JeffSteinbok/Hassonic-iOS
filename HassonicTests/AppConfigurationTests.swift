import XCTest
@testable import Hassonic

/// One config document: dashboard pages, media accounts, speaker claim.
final class AppConfigurationTests: XCTestCase {

    private let minimalPages = """
    version: 1
    pages:
      - id: home
        title: Home
        system_icon: house.fill
        sections:
          - cards:
              - type: light
                entity: light.example
    """

    private func parse(_ yaml: String) throws -> AppConfiguration {
        try AppConfigurationParser.parse(yaml)
    }

    // MARK: - One document

    func testPagesMediaAndSpeakerClaimComeFromOneDocument() throws {
        let config = try parse(minimalPages + """

        media:
          accounts:
            - id: alex
              displayName: Alex
              entityId: media_player.alex
              speakers:
                - entityId: media_player.kitchen
                  displayName: Kitchen
                  sourceName: Kitchen Speaker
                  icon: speaker
        speakerClaim:
          deviceEntityIds: [media_player.echo]
          command: { contentType: custom, phrase: "Switch to {account}" }
          confirmation:
            timestampAttribute: last_called_timestamp
            responseAttribute: last_called_response
            matches: "in {account}"
          playback: { phrase: "Play {content} on {speaker}", fallbackContent: "Anything" }
        """)

        XCTAssertEqual(config.pages.map(\.id), ["home"])
        XCTAssertEqual(config.media.accounts.map(\.id), ["alex"])
        XCTAssertEqual(config.media.accounts[0].speakers[0].sourceName, "Kitchen Speaker")
        XCTAssertEqual(config.speakerClaim?.deviceEntityIds, ["media_player.echo"])
    }

    /// Someone may not use the music tab at all.
    func testMediaIsOptional() throws {
        let config = try parse(minimalPages)

        XCTAssertTrue(config.media.accounts.isEmpty)
        XCTAssertNil(config.speakerClaim)
    }

    // MARK: - No household's values as anyone's defaults

    /// Every claim field except timings names a vendor, a language or a
    /// preference. A partial block must fail loudly rather than quietly
    /// inherit somebody else's setup.
    func testPartialSpeakerClaimIsRejectedRatherThanDefaulted() {
        let partial = minimalPages + """

        speakerClaim:
          deviceEntityIds: [media_player.echo]
        """

        XCTAssertThrowsError(try parse(partial)) { error in
            // The message names the missing key rather than saying
            // "not in the correct format".
            XCTAssertTrue(
                "\(error.localizedDescription)".contains("command"),
                "expected the error to name the missing key, got: \(error.localizedDescription)"
            )
        }
    }

    func testMissingPlaybackPhraseIsRejected() {
        let missingPhrase = minimalPages + """

        speakerClaim:
          deviceEntityIds: [media_player.echo]
          command: { contentType: custom, phrase: "x" }
          confirmation:
            timestampAttribute: a
            responseAttribute: b
            matches: c
          playback: { fallbackContent: "Anything" }
        """

        XCTAssertThrowsError(try parse(missingPhrase))
    }

    /// Timings are the one defaulted group — measured against vendor latency,
    /// with no household in them.
    func testOnlyTimingsAreDefaulted() throws {
        let config = try parse(minimalPages + """

        speakerClaim:
          deviceEntityIds: [media_player.echo]
          command: { contentType: custom, phrase: "x" }
          confirmation:
            timestampAttribute: a
            responseAttribute: b
            matches: c
          playback: { phrase: "y", fallbackContent: "z" }
        """)

        let timings = try XCTUnwrap(config.speakerClaim?.timings)
        XCTAssertEqual(timings.replyTimeoutSeconds, 16)
        XCTAssertEqual(timings.pollIntervalMs, 500)
        XCTAssertEqual(timings.commandCooldownMs, 1500)
        XCTAssertEqual(timings.settleSeconds, 3)
        XCTAssertEqual(timings.attemptsPerDevice, 2)
    }

    func testTimingsCanBeOverriddenIndividually() throws {
        let config = try parse(minimalPages + """

        speakerClaim:
          deviceEntityIds: [media_player.echo]
          command: { contentType: custom, phrase: "x" }
          confirmation: { timestampAttribute: a, responseAttribute: b, matches: c }
          playback: { phrase: "y", fallbackContent: "z" }
          timings: { replyTimeoutSeconds: 25 }
        """)

        XCTAssertEqual(config.speakerClaim?.timings.replyTimeoutSeconds, 25)
        XCTAssertEqual(config.speakerClaim?.timings.pollIntervalMs, 500)
    }

    // MARK: - Provider naming

    func testProviderIsOptionalAndAbsentByDefault() throws {
        let config = try parse(minimalPages + """

        media:
          accounts:
            - { id: alex, displayName: Alex, entityId: media_player.alex }
        """)

        XCTAssertNil(config.media.provider, "no provider means the app names none")
    }

    func testProviderNameSchemeAndLogoAreRead() throws {
        let config = try parse(minimalPages + """

        media:
          provider: { name: Spotify, urlScheme: "spotify:", logoAsset: SpotifyLogo }
          accounts: []
        """)

        let provider = try XCTUnwrap(config.media.provider)
        XCTAssertEqual(provider.name, "Spotify")
        XCTAssertEqual(provider.appURL, URL(string: "spotify:"))
        XCTAssertEqual(provider.logoAsset, "SpotifyLogo")
    }

    /// A provider with no app to open loses the open-app affordances rather
    /// than offering a button that goes nowhere.
    func testANameOnlyProviderHasNoAppURL() throws {
        let config = try parse(minimalPages + """

        media:
          provider: { name: Sonos }
          accounts: []
        """)

        let provider = try XCTUnwrap(config.media.provider)
        XCTAssertEqual(provider.name, "Sonos")
        XCTAssertNil(provider.appURL)
        XCTAssertNil(provider.logoAsset)
    }

    // MARK: - Validation

    func testAccountNeedsAMediaPlayerEntity() {
        XCTAssertThrowsError(try parse(minimalPages + """

        media:
          accounts:
            - id: alex
              displayName: Alex
              entityId: light.not_a_player
        """))
    }

    func testDuplicateAccountIdsAreRejected() {
        XCTAssertThrowsError(try parse(minimalPages + """

        media:
          accounts:
            - { id: alex, displayName: Alex, entityId: media_player.a }
            - { id: alex, displayName: Alex Again, entityId: media_player.b }
        """))
    }

    // MARK: - Live Activity zones

    private func accountWithZones(_ liveActivityZones: String) -> String {
        minimalPages + """

        media:
          accounts:
            - id: alex
              displayName: Alex
              entityId: media_player.alex
              speakers:
                - { entityId: media_player.kitchen, displayName: Kitchen, sourceName: Kitchen, icon: speaker }
                - { entityId: media_player.den, displayName: Den, sourceName: Den, icon: speaker }
                - { entityId: media_player.attic, displayName: Attic, sourceName: Attic, icon: speaker, isEnabled: false }
                - { entityId: media_player.hall, displayName: Hall, icon: speaker }
              groups:
                - { entityId: media_player.everywhere, displayName: Everywhere, sourceName: Everywhere, icon: house }
              \(liveActivityZones)
        """
    }

    func testLiveActivityZonesAreOptional() throws {
        let config = try parse(accountWithZones(""))
        XCTAssertNil(config.media.accounts[0].liveActivityZones)
        XCTAssertNil(MusicZones.make(from: config.media)[0].liveActivityZoneIds)
    }

    func testLiveActivityZonesAreReadInOrderAndReachTheRuntimeModel() throws {
        let config = try parse(accountWithZones("liveActivityZones: [media_player.den, media_player.everywhere]"))
        XCTAssertEqual(MusicZones.make(from: config.media)[0].liveActivityZoneIds,
                       ["media_player.den", "media_player.everywhere"])
    }

    func testLiveActivityZonesMustBeCastableZonesOfTheAccount() {
        for entity in ["media_player.nowhere", "media_player.attic", "media_player.hall"] {
            XCTAssertThrowsError(try parse(accountWithZones("liveActivityZones: [\(entity)]")), entity) { error in
                XCTAssertEqual(error as? AppConfigurationError,
                               .unknownLiveActivityZone(accountID: "alex", entityID: entity))
            }
        }
    }

    func testLiveActivityZonesRejectDuplicatesAndMoreThanFour() {
        XCTAssertThrowsError(try parse(accountWithZones("liveActivityZones: [media_player.den, media_player.den]"))) { error in
            XCTAssertEqual(error as? AppConfigurationError,
                           .duplicateLiveActivityZone(accountID: "alex", entityID: "media_player.den"))
        }
        let five = "liveActivityZones: [media_player.kitchen, media_player.den, media_player.everywhere, media_player.kitchen, media_player.den]"
        XCTAssertThrowsError(try parse(accountWithZones(five))) { error in
            XCTAssertEqual(error as? AppConfigurationError, .tooManyLiveActivityZones(accountID: "alex", count: 5))
        }
    }

    // MARK: - Runtime mapping

    func testAccountsMapToTheRuntimeZoneModel() throws {
        let config = try parse(minimalPages + """

        media:
          accounts:
            - id: alex
              displayName: Alex
              entityId: media_player.alex
              favorites:
                - { displayName: Morning, icon: sunrise, contentType: playlist, contentId: "x:1" }
              speakers:
                - { entityId: media_player.kitchen, displayName: Kitchen, icon: speaker }
              groups:
                - { entityId: media_player.downstairs, displayName: Downstairs, icon: hifispeaker,
                    memberEntityIds: [media_player.kitchen] }
        """)

        let accounts = MusicZones.make(from: config.media)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].zones.map(\.kind), [.speaker, .group])
        XCTAssertEqual(accounts[0].zones.last?.memberEntityIds, ["media_player.kitchen"])
        XCTAssertEqual(accounts[0].favorites.first?.contentId, "x:1")
    }

    /// The bundled fallback must parse, and must not be anyone's real house.
    func testBundledConfigIsAValidNeutralExample() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Config", withExtension: "yaml")
            ?? Bundle.main.url(forResource: "Config", withExtension: "yaml"))
        let config = try parse(try String(contentsOf: url, encoding: .utf8))

        XCTAssertFalse(config.pages.isEmpty)
        XCTAssertTrue(config.media.accounts.isEmpty, "the bundled fallback must not ship real accounts")
        XCTAssertNil(config.speakerClaim, "the bundled fallback must not ship a real speaker claim")
    }
}
