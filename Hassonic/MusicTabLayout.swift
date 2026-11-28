import Foundation

/// Which of the Music tab's two layouts is up.
enum MusicTabMode: Equatable {
    /// Nothing on the account: pick a speaker, resume, Recents and
    /// Favorites as a grid, Browse.
    case start
    /// Now Playing leads; starting something else is one compact row.
    case playing
}

/// The rules behind the Music tab's layout, kept apart from the views so
/// they can be tested.
enum MusicTabLayout {
    /// The layout the account's state asks for: paused still counts as
    /// playing, since the card is how you'd resume it.
    static func wanted(hasMedia: Bool) -> MusicTabMode {
        hasMedia ? .playing : .start
    }

    /// How long the account has to stay stopped before the playing layout
    /// gives way, so a track change or account handoff that reports idle
    /// for a moment doesn't flash the start layout.
    static let stopGrace: Duration = .seconds(4)

    /// The zones that are playing on their own: not the account's active
    /// zone, and not one of its members. A playing group stands for its
    /// members, so they aren't listed twice. `isPlaying` answers for one
    /// entity (playing or paused).
    static func otherPlaying(zones: [MusicZone], active: MusicZone?, isPlaying: (String) -> Bool) -> [MusicZone] {
        var taken = Set<String>()
        if let active {
            taken.insert(active.entityId)
            taken.formUnion(active.memberEntityIds)
        }
        let enabled = zones.filter(\.isEnabled)
        let groups = enabled.filter {
            $0.kind == .group && !taken.contains($0.entityId) && isPlaying($0.entityId)
                && taken.isDisjoint(with: $0.memberEntityIds)
        }
        let covered = taken.union(groups.flatMap(\.memberEntityIds))
        let speakers = enabled.filter {
            $0.kind == .speaker && !covered.contains($0.entityId) && isPlaying($0.entityId)
        }
        return groups + speakers
    }

    /// The speaker the start layout offers first: the one picked there
    /// before, else where the account last played, else none (ask).
    static func defaultTarget(zones: [MusicZone], picked: String?, rememberedSource: String?) -> MusicZone? {
        let castable = zones.filter { $0.isEnabled && $0.sourceName != nil }
        if let picked, let zone = castable.first(where: { $0.id == picked }) { return zone }
        guard let source = rememberedSource?.normalizedZoneSourceName, !source.isEmpty else { return nil }
        return castable.first { $0.sourceName?.normalizedZoneSourceName == source }
    }
}

/// Holds the layout still while someone's touching the screen, so a start
/// or stop elsewhere can't move what's under their finger. The change it
/// asked for lands when they let go.
struct MusicTabModeLatch: Equatable {
    private(set) var shown: MusicTabMode
    private(set) var pending: MusicTabMode?
    private(set) var holding = false

    init(_ mode: MusicTabMode) {
        shown = mode
    }

    /// The state asks for `mode`. True when the layout changed now.
    @discardableResult
    mutating func want(_ mode: MusicTabMode) -> Bool {
        guard !holding else {
            pending = mode == shown ? nil : mode
            return false
        }
        pending = nil
        guard mode != shown else { return false }
        shown = mode
        return true
    }

    /// Someone started or stopped touching (scrolling, a sheet up, the start
    /// page pushed). True when letting go changed the layout.
    @discardableResult
    mutating func hold(_ holding: Bool) -> Bool {
        self.holding = holding
        guard !holding, let pending else { return false }
        self.pending = nil
        guard pending != shown else { return false }
        shown = pending
        return true
    }
}
