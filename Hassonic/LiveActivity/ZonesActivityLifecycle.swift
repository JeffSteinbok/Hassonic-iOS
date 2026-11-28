import Foundation

/// When the speaker Live Activity should stay and when it should go. Kept
/// free of ActivityKit so the rules can be tested directly.
///
/// Playing keeps it. Paused (or idle with a track still loaded) keeps it for
/// `pauseGrace`, so a quick pause from its own play/pause key doesn't take it
/// away, then it goes. Anything else (off, unavailable, standby, idle with
/// nothing loaded) ends it at once.
enum ZonesActivityLifecycle {
    /// How long a paused activity stays on the Lock Screen before it's dismissed.
    static let pauseGrace: TimeInterval = 2 * 60

    enum Playback: Equatable {
        case playing
        /// Not playing, but a track is loaded and play would resume it.
        case paused
        /// Nothing to resume.
        case stopped
    }

    enum Decision: Equatable {
        case keep
        /// Paused: keep it, but dismiss it at this moment if playback hasn't resumed.
        case keepUntil(Date)
        case end
    }

    static func playback(of entity: HAEntityState?) -> Playback {
        guard let entity else { return .stopped }
        switch entity.state {
        case "playing", "buffering":
            return .playing
        case "paused", "idle", "on":
            return ZonesActivityContent.hasMedia(entity) ? .paused : .stopped
        default:
            // off, standby, unavailable, unknown, stopped
            return .stopped
        }
    }

    /// When the player stopped playing: Home Assistant's `last_changed` for
    /// the state, which survives an app relaunch, else `fallback` (when this
    /// process first saw it not playing).
    static func notPlayingSince(_ entity: HAEntityState?, fallback: Date) -> Date {
        guard let stamp = entity?.lastChanged, let date = HATimestamp.parse(stamp) else { return fallback }
        // A clock skewed ahead of the phone's mustn't stretch the grace period.
        return min(date, fallback)
    }

    static func decision(_ playback: Playback, notPlayingSince: Date, now: Date) -> Decision {
        switch playback {
        case .playing:
            return .keep
        case .stopped:
            return .end
        case .paused:
            let deadline = notPlayingSince.addingTimeInterval(pauseGrace)
            return deadline > now ? .keepUntil(deadline) : .end
        }
    }
}
