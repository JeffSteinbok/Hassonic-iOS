import Foundation

/// How to claim a speaker for a media account — bind it so that account can
/// cast to it.
///
/// This exists because Spotify Connect offers no service to rebind a speaker
/// to a different account, so the app fakes a spoken command to a voice
/// assistant and reads the spoken reply back. That is a recipe, not an
/// architecture: send a payload to an entity, poll an attribute for a reply,
/// match it, retry. Nothing about it is specific to any one assistant, so all
/// of it is config.
///
/// It matters that the phrases and the matcher are data. The success test is
/// a substring match against an assistant's *spoken English* — if the vendor
/// rewords their reply, the feature breaks with no change on our side, and it
/// fails audibly in the kitchen. As config that is an edit, not a release.
/// It also makes non-English households possible at all.
///
/// ## Why so little is defaulted
///
/// Only `timings` has defaults. Those were measured against vendor latency
/// rather than chosen, and contain nothing about any particular household.
///
/// Everything else names a vendor, a language, or a preference — which
/// assistant answers, what to say to it, what its reply sounds like, what to
/// play when nothing was asked for. Defaulting those would ship one
/// household's setup as every household's fallback, and a missing field would
/// silently inherit it rather than saying so. They are required whenever
/// `speakerClaim` is present; omit the whole block to disable the feature.
struct SpeakerClaimConfig: Decodable, Equatable {

    /// The request sent to the device. `contentType` is the provider's
    /// convention for "speak this as a command" — `custom` for Alexa Media
    /// Player — carried on a stock `media_player.play_media` call.
    struct Command: Decodable, Equatable {
        let contentType: String
        let phrase: String
    }

    /// How to tell whether it worked. The device answers out loud and the
    /// integration surfaces that reply as entity attributes.
    struct Confirmation: Decodable, Equatable {
        let timestampAttribute: String
        let responseAttribute: String
        let matches: String
    }

    /// The follow-up that actually forces the handoff. A generic "play on X"
    /// doesn't — it goes silent and the zone is never claimed — so this has
    /// to name real content. See docs/SPOTIFY_AND_ALEXA.md.
    struct Playback: Decodable, Equatable {
        let phrase: String
        let fallbackContent: String
    }

    /// The only defaulted group. Derived from live measurement, not chosen —
    /// a genuine round trip has been seen to take over 11s, and the second
    /// command needs a pause or the assistant's backend drops it silently.
    struct Timings: Decodable, Equatable {
        var replyTimeoutSeconds: Double = 16
        var pollIntervalMs: Int = 500
        var commandCooldownMs: Int = 1500
        var settleSeconds: Double = 3
        var attemptsPerDevice: Int = 2

        private enum CodingKeys: String, CodingKey {
            case replyTimeoutSeconds, pollIntervalMs, commandCooldownMs, settleSeconds, attemptsPerDevice
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let v = try c.decodeIfPresent(Double.self, forKey: .replyTimeoutSeconds) { replyTimeoutSeconds = v }
            if let v = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMs) { pollIntervalMs = v }
            if let v = try c.decodeIfPresent(Int.self, forKey: .commandCooldownMs) { commandCooldownMs = v }
            if let v = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) { settleSeconds = v }
            if let v = try c.decodeIfPresent(Int.self, forKey: .attemptsPerDevice) { attemptsPerDevice = v }
        }
    }

    /// Devices that can issue the request, in priority order. Not every device
    /// answers custom commands — some only take standard playback controls —
    /// so this is the ones confirmed to respond, not every device in the house.
    let deviceEntityIds: [String]
    let command: Command
    let confirmation: Confirmation
    let playback: Playback
    var timings = Timings()

    private enum CodingKeys: String, CodingKey {
        case deviceEntityIds, command, confirmation, playback, timings
    }

    init(
        deviceEntityIds: [String],
        command: Command,
        confirmation: Confirmation,
        playback: Playback,
        timings: Timings = Timings()
    ) {
        self.deviceEntityIds = deviceEntityIds
        self.command = command
        self.confirmation = confirmation
        self.playback = playback
        self.timings = timings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceEntityIds = try c.decode([String].self, forKey: .deviceEntityIds)
        command = try c.decode(Command.self, forKey: .command)
        confirmation = try c.decode(Confirmation.self, forKey: .confirmation)
        playback = try c.decode(Playback.self, forKey: .playback)
        if let v = try c.decodeIfPresent(Timings.self, forKey: .timings) { timings = v }
    }

    /// Substitutes `{account}`, `{speaker}` and `{content}` into a template.
    static func render(
        _ template: String,
        account: String,
        speaker: String = "",
        content: String = ""
    ) -> String {
        template
            .replacingOccurrences(of: "{account}", with: account)
            .replacingOccurrences(of: "{speaker}", with: speaker)
            .replacingOccurrences(of: "{content}", with: content)
    }
}
