import SwiftUI

// What the Now Playing card shows, worked out from the account entity:
// whether there's media, which track it is, and how far along. Kept apart
// from the view so it can be tested.


// Returns true when `entity` carries a current track — playing or paused with
// valid metadata.  Idle/stopped/off states have no `media_title` attribute.
func nowPlayingHasMedia(_ entity: HAEntityState?) -> Bool {
    entity?.attributeString("media_title") != nil
}

/// A stable string identifying a track by its content ID, artwork URL, and title+artist.
/// Position, volume, and source changes don't alter this, so they don't trigger a transition.
func trackIdentity(for entity: HAEntityState?) -> String {
    guard let entity else { return "" }
    let contentId = entity.attributeString("media_content_id") ?? ""
    let picture = entity.attributeString("entity_picture") ?? ""
    let title = entity.attributeString("media_title") ?? ""
    let artist = entity.attributeString("media_artist") ?? ""
    return "\(contentId)|\(picture)|\(title)|\(artist)"
}

func playbackAnchorIdentity(for entity: HAEntityState?) -> String {
    guard let entity else { return "" }
    let position: String
    if case .number(let value)? = entity.attributes["media_position"] {
        position = String(value)
    } else {
        position = ""
    }
    let updatedAt = entity.attributeString("media_position_updated_at") ?? ""
    return "\(entity.state)|\(position)|\(updatedAt)"
}

func nowPlayingDestinationLabel(activeSource: String?) -> String {
    activeSource == nil ? "Choose speakers" : "Playing on"
}

/// A snapshot of all metadata and artwork needed to render the Now Playing card.
struct NowPlayingPresentation: Equatable {
    let title: String?
    let artist: String?
    let artworkURL: URL?
    let duration: Double?
    let anchorPosition: Double?
    let anchorUpdatedAt: Date?
    let state: String
    let hasMedia: Bool

    static let empty = NowPlayingPresentation(
        title: nil, artist: nil, artworkURL: nil,
        duration: nil, anchorPosition: nil, anchorUpdatedAt: nil,
        state: "idle", hasMedia: false
    )
}

/// Manages the coordinated transition between Now Playing presentations.
///
/// When a new track identity is detected, a pending presentation is staged.
/// Artwork is fetched; once it succeeds (or the fallback timeout fires), the
/// committed presentation is updated atomically so metadata and artwork always
/// change together. Position/volume/source changes that don't alter the track
/// identity update the committed presentation in-place without triggering a
/// full transition.
@MainActor
final class NowPlayingTransitionManager: ObservableObject {
    @Published private(set) var committed: NowPlayingPresentation = .empty

    private var stagedIdentity: String = ""
    private var committedIdentity: String = ""
    private var artworkTask: Task<Void, Never>?

    /// Maximum time to wait for artwork before committing the pending presentation anyway.
    var artworkTimeoutSeconds: Double = 3.0

    func update(entity: HAEntityState?, baseURLString: String) {
        let identity = trackIdentity(for: entity)
        let presentation = makePresentation(entity: entity, baseURLString: baseURLString)

        if identity != committedIdentity {
            // New track — stage it and begin artwork loading.
            stagedIdentity = identity
            artworkTask?.cancel()
            artworkTask = Task {
                await loadAndCommit(presentation: presentation, identity: identity)
            }
        } else {
            // Same track — update in-place (position, state, volume won't touch identity).
            committed = presentation
        }
    }

    private func loadAndCommit(presentation: NowPlayingPresentation, identity: String) async {
        if let url = presentation.artworkURL {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try? await URLSession.shared.data(from: url)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(self.artworkTimeoutSeconds))
                }
                await group.next()
                group.cancelAll()
            }
        }
        guard !Task.isCancelled else { return }
        commit(presentation: presentation, identity: identity)
    }

    private func commit(presentation: NowPlayingPresentation, identity: String) {
        committedIdentity = identity
        stagedIdentity = ""
        withAnimation(.easeInOut(duration: 0.35)) {
            committed = presentation
        }
    }

    private func makePresentation(entity: HAEntityState?, baseURLString: String) -> NowPlayingPresentation {
        guard let entity, nowPlayingHasMedia(entity) else { return .empty }
        let artworkURL = resolveHAImageURL(path: entity.attributeString("entity_picture"), baseURLString: baseURLString)
        let duration: Double?
        if case .number(let v)? = entity.attributes["media_duration"], v > 0 { duration = v } else { duration = nil }
        let anchorPosition: Double?
        if case .number(let v)? = entity.attributes["media_position"] { anchorPosition = v } else { anchorPosition = nil }
        let anchorDate: Date?
        if let raw = entity.attributeString("media_position_updated_at") {
            anchorDate = ISO8601DateFormatter().date(from: raw)
        } else {
            anchorDate = nil
        }
        return NowPlayingPresentation(
            title: entity.attributeString("media_title"),
            artist: entity.attributeString("media_artist"),
            artworkURL: artworkURL,
            duration: duration,
            anchorPosition: anchorPosition,
            anchorUpdatedAt: anchorDate,
            state: entity.state,
            hasMedia: true
        )
    }
}

// Returns the interpolated playback position in seconds, or nil if required data is absent.
// When `state` is "playing" and `anchorDate` is available, elapsed wall-clock time since
// the anchor is added to `anchorPosition` and clamped to [0, duration].  For any other
// state the raw anchor position is returned (clamped), freezing the display.
func playbackElapsed(
    anchorPosition: Double,
    anchorDate: Date?,
    state: String,
    duration: Double,
    now: Date
) -> Double {
    let clamped = min(max(anchorPosition, 0), duration)
    guard state == "playing", let anchorDate else { return clamped }
    return min(max(clamped + now.timeIntervalSince(anchorDate), 0), duration)
}

func advancePlaybackElapsed(
    current: Double,
    state: String,
    duration: Double,
    elapsedTime: TimeInterval
) -> Double {
    let clamped = min(max(current, 0), duration)
    guard state == "playing" else { return clamped }
    return min(max(clamped + elapsedTime, 0), duration)
}
