import SwiftUI

/// The Music tab's "start something" layout: which speaker, the last thing
/// played one tap from resuming, Recents and Favorites as a grid, Browse.
/// It's the whole tab while nothing's playing, and the page "Play something
/// else" opens while something is.
struct MusicStartPage: View {
    let account: MediaAccount
    let speakerClaim: SpeakerClaimConfig?
    let recents: [RecentMusicItem]
    /// Something is playing or paused on the account.
    let hasMedia: Bool
    /// Where the account is playing now, if it is.
    let activeZone: MusicZone?
    let providerName: String?
    @ObservedObject var starter: MusicStarter
    /// Opened from "Play something else": the tab's own layout is behind it.
    var isPushed = false
    let browse: () -> Void
    /// Once something has started (the pushed page goes back).
    var onStarted: () -> Void = {}

    @EnvironmentObject private var haClient: HAWebSocketClient
    @State private var showsAllRecents = false
    /// Picked on this page; until then, where it's playing or was last
    /// picked.
    @State private var chosenZoneId: String?

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    private static let recentsShown = 6

    private var pickedKey: String { StorageKeys.musicStartTarget(account: account.entityId) }
    private var rememberedSource: String? {
        let value = UserDefaults.standard.string(forKey: StorageKeys.lastPlayOnSource(account: account.entityId)) ?? ""
        return value.isEmpty ? nil : value
    }

    private var castable: [MusicZone] { account.zones.filter { $0.isEnabled && $0.sourceName != nil } }

    private var target: MusicZone? {
        if let chosenZoneId, let zone = castable.first(where: { $0.id == chosenZoneId }) { return zone }
        if let activeZone, hasMedia { return activeZone }
        return MusicTabLayout.defaultTarget(zones: account.zones, picked: UserDefaults.standard.string(forKey: pickedKey),
                                            rememberedSource: rememberedSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if castable.count > 1 {
                MusicSectionHeader(title: "Play On")
                zonePicker
            }

            if !isPushed, let last = recents.first {
                resumeCard(last)
                    .padding(.top, 4)
            }

            let gridRecents = isPushed ? recents : Array(recents.dropFirst())
            if !gridRecents.isEmpty {
                HStack {
                    MusicSectionHeader(title: "Recents")
                    Spacer()
                    if gridRecents.count > Self.recentsShown {
                        Button(showsAllRecents ? "Show Less" : "Show All") {
                            withAnimation(.easeInOut(duration: 0.25)) { showsAllRecents.toggle() }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(.top, 8)
                LazyVGrid(columns: Self.columns, spacing: 14) {
                    ForEach(showsAllRecents ? gridRecents : Array(gridRecents.prefix(Self.recentsShown))) { item in
                        tile(title: item.title, subtitle: item.subtitle) {
                            RecentArtwork(thumbnail: item.thumbnail, icon: MediaIcon.symbol(for: item))
                        } action: {
                            start(MusicStartRequest(recent: item))
                        }
                    }
                }
                .accessibilityIdentifier("recents-grid")
            }

            if !account.favorites.isEmpty {
                MusicSectionHeader(title: "Favorites")
                    .padding(.top, 8)
                LazyVGrid(columns: Self.columns, spacing: 14) {
                    ForEach(account.favorites) { favorite in
                        tile(title: favorite.displayName, subtitle: nil) {
                            RecentArtwork(thumbnail: nil, icon: favorite.icon)
                        } action: {
                            start(MusicStartRequest(favorite: favorite))
                        }
                    }
                }
                .accessibilityIdentifier("favorites-grid")
            }

            browseRow
                .padding(.top, 8)
        }
    }

    // MARK: Speaker picker

    private var zonePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(castable) { zone in
                    let selected = zone.id == target?.id
                    Button {
                        lightTapHaptic()
                        chosenZoneId = zone.id
                        UserDefaults.standard.set(zone.id, forKey: pickedKey)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: zone.icon)
                            Text(zone.displayName)
                            if isPlaying(zone) {
                                Image(systemName: "waveform")
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                    .font(.caption)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background {
                            Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemBackground)))
                        }
                    }
                    .buttonStyle(PressFeedbackIconButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(isPlaying(zone) ? "Playing now" : "")
                }
            }
        }
        .accessibilityIdentifier("start-zone-picker")
    }

    private func isPlaying(_ zone: MusicZone) -> Bool {
        ["playing", "paused"].contains(haClient.entity(zone.entityId)?.state ?? "")
    }

    // MARK: Resume

    private func resumeCard(_ item: RecentMusicItem) -> some View {
        Button {
            lightTapHaptic()
            start(MusicStartRequest(recent: item))
        } label: {
            HStack(spacing: 14) {
                RecentArtwork(thumbnail: item.thumbnail, icon: MediaIcon.symbol(for: item))
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resume")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(target.map { "on \($0.displayName)" } ?? "Pick a speaker")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(.primary)
        }
        .buttonStyle(PressFeedbackIconButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resume \(item.title)" + (target.map { " on \($0.displayName)" } ?? ""))
        .accessibilityIdentifier("resume-card")
    }

    // MARK: Grid

    private func tile<Art: View>(title: String, subtitle: String?, @ViewBuilder art: () -> Art,
                                 action: @escaping () -> Void) -> some View {
        Button {
            lightTapHaptic()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                art()
                    .aspectRatio(1, contentMode: .fit)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PressFeedbackIconButtonStyle())
        .accessibilityLabel("Play \(title)")
        .accessibilityHint(subtitle ?? "")
    }

    private var browseRow: some View {
        Button {
            lightTapHaptic()
            browse()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(Color.accentColor)
                Text("Browse \(providerName ?? "Media")")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("start-browse")
    }

    // MARK: Starting

    private func context(target: MusicZone?) -> MusicStartContext {
        MusicStartContext(accountEntityId: account.entityId, accountDisplayName: account.displayName,
                          speakerClaim: speakerClaim, zones: account.zones, hasMedia: hasMedia, target: target)
    }

    private func start(_ request: MusicStartRequest) {
        starter.start(request, context: context(target: target), client: haClient, onStarted: onStarted)
    }
}

/// A section title on the Music tab; white over the playing layout's
/// blurred artwork.
struct MusicSectionHeader: View {
    let title: String
    var onArtwork = false

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(onArtwork ? AnyShapeStyle(.white.opacity(0.65)) : AnyShapeStyle(.secondary))
    }
}

/// A zone playing on its own while the account plays elsewhere (or not at
/// all): small, with its own play/pause.
struct OtherZoneRow: View {
    let zone: MusicZone
    let onArtwork: Bool

    @EnvironmentObject private var haClient: HAWebSocketClient

    private var entity: HAEntityState? { haClient.entity(zone.entityId) }
    private var isPlaying: Bool { entity?.state == "playing" }

    private var detail: String {
        let title = entity?.attributeString("media_title")
        let artist = entity?.attributeString("media_artist")
        let what = [title, artist].compactMap { $0 }.joined(separator: " · ")
        if !what.isEmpty { return what }
        return isPlaying ? "Playing" : "Paused"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: zone.icon)
                .frame(width: 24)
                .foregroundStyle(onArtwork ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(zone.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                lightTapHaptic()
                haClient.mediaPlayPause(zone.entityId)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackIconButtonStyle())
            .accessibilityLabel(isPlaying ? "Pause \(zone.displayName)" : "Play \(zone.displayName)")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// "Play something else", the playing layout's one way into the start
/// page: a few recent covers as a hint of what's behind it.
struct PlaySomethingElseRow: View {
    let recents: [RecentMusicItem]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .foregroundStyle(Color.accentColor)
            Text("Play Something Else")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            HStack(spacing: -10) {
                ForEach(recents.filter { $0.thumbnail != nil }.prefix(3)) { item in
                    RecentArtwork(thumbnail: item.thumbnail, icon: MediaIcon.symbol(for: item))
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.background, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("play-something-else")
    }
}
