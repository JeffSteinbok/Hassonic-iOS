import Foundation

/// Pure mapping from the media config and live Home Assistant state to what
/// the speaker Live Activity shows. Kept free of ActivityKit calls so it can
/// be tested directly.
enum ZonesActivityContent {
    static let maxQuickZones = MediaAccountConfiguration.maxLiveActivityZones

    /// Every zone of `account` the activity can cast to, groups first — the
    /// same castable set the Play On sheet offers.
    static func zones(for account: MediaAccount) -> [ZonesActivityAttributes.Zone] {
        let castable = account.zones.filter { $0.isEnabled && $0.sourceName != nil }
        let ordered = castable.filter { $0.kind == .group } + castable.filter { $0.kind == .speaker }
        return ordered.compactMap { zone(for: $0, in: account) }
    }

    /// The buttons: the account's `liveActivityZones` in the order given, or
    /// else the first castable zones, groups first — either way only those
    /// Home Assistant currently reports as available, capped at `maxQuickZones`.
    /// An unavailable configured zone is left out rather than backfilled, so
    /// the row never shows a zone nobody picked.
    static func quickZones(for account: MediaAccount, isAvailable: (String) -> Bool) -> [ZonesActivityAttributes.Zone] {
        let castable = zones(for: account)
        let candidates = account.liveActivityZoneIds.map { ids in
            ids.compactMap { id in castable.first { $0.id == id } }
        } ?? castable
        return Array(candidates.filter { isAvailable($0.id) }.prefix(maxQuickZones))
    }

    static func zone(for zone: MusicZone, in account: MediaAccount) -> ZonesActivityAttributes.Zone? {
        guard let sourceName = zone.sourceName else { return nil }
        return ZonesActivityAttributes.Zone(
            id: zone.entityId,
            name: zone.displayName,
            icon: zone.icon,
            sourceName: sourceName,
            volumeEntityIds: volumeEntityIds(for: zone, in: account)
        )
    }

    /// Mirrors SpeakerRow: a group's volume is its members', each speaker's
    /// volume lives on its proxy if it has one, and a speaker pinned at a
    /// fixed level with no proxy isn't adjustable at all.
    static func volumeEntityIds(for zone: MusicZone, in account: MediaAccount) -> [String] {
        let memberIds = zone.kind == .group ? zone.memberEntityIds : [zone.entityId]
        return memberIds.compactMap { memberId in
            guard let speaker = account.zones.first(where: { $0.kind == .speaker && $0.entityId == memberId }) else {
                return memberId
            }
            guard speaker.isEnabled else { return nil }
            if let proxy = speaker.proxy { return proxy.entityId }
            return speaker.defaultVolume == nil ? speaker.entityId : nil
        }
    }

    /// Same test the Now Playing card uses: a current track, playing or paused.
    static func hasMedia(_ accountEntity: HAEntityState?) -> Bool {
        nowPlayingHasMedia(accountEntity)
    }

    /// `zones` is every zone the account could be playing on; the active one
    /// is whichever matches the account entity's `source`.
    static func state(
        accountEntity: HAEntityState?,
        zones: [ZonesActivityAttributes.Zone],
        entity: (String) -> HAEntityState?
    ) -> ZonesActivityAttributes.ContentState {
        let activeZone = accountEntity?.attributeString("source").flatMap { source in
            zones.first { $0.sourceName.normalizedZoneSourceName == source.normalizedZoneSourceName }
        }
        return ZonesActivityAttributes.ContentState(
            activeZone: activeZone,
            volume: activeZone.flatMap { volume(of: $0, entity: entity) },
            isPlaying: accountEntity?.state == "playing",
            pendingZoneId: nil,
            message: nil
        )
    }

    static func volume(of zone: ZonesActivityAttributes.Zone, entity: (String) -> HAEntityState?) -> Double? {
        let levels = zone.volumeEntityIds.compactMap { entity($0)?.attributeDouble("volume_level") }
        guard !levels.isEmpty else { return nil }
        return levels.reduce(0, +) / Double(levels.count)
    }

    /// Where each adjustable speaker should land so the zone's average reaches
    /// `level`. Every speaker moves by the same amount, so a group keeps its
    /// balance (a quieter room stays quieter). Speakers that don't report a
    /// level are left alone rather than guessed at — unless none do, in which
    /// case they all go straight to `level`.
    static func volumes(
        of zone: ZonesActivityAttributes.Zone,
        settingTo level: Double,
        entity: (String) -> HAEntityState?
    ) -> [(entityId: String, level: Double)] {
        func clamped(_ value: Double) -> Double { (min(max(value, 0), 1) * 100).rounded() / 100 }
        let current = zone.volumeEntityIds.map { ($0, entity($0)?.attributeDouble("volume_level")) }
        let known = current.compactMap(\.1)
        guard !known.isEmpty else {
            return zone.volumeEntityIds.map { ($0, clamped(level)) }
        }
        let shift = level - known.reduce(0, +) / Double(known.count)
        return current.compactMap { entityId, volume in
            volume.map { (entityId, clamped($0 + shift)) }
        }
    }
}
