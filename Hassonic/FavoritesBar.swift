import SwiftUI

struct FavoritesBar: View {
    let mediaEntityId: String
    let accountDisplayName: String
    let speakerClaim: SpeakerClaimConfig?
    let favorites: [MusicFavorite]
    /// Recently played, newest first (see RecentMusicStore).
    let recents: [RecentMusicItem]
    let zones: [MusicZone]
    /// Whether something is actually playing/paused right now — as opposed to
    /// `lastPlayOnSourceName` merely remembering a zone from some past
    /// session. Without this, once any zone had ever been picked, every
    /// later favorite tap would wrongly take the "already playing, just
    /// swap track" shortcut — including with nothing currently playing —
    /// and silently no-op, since that shortcut's `playMedia` call doesn't
    /// specify a target zone/device at all.
    let hasMedia: Bool

    @EnvironmentObject private var haClient: HAWebSocketClient
    @StateObject private var favoriteRouter = FavoritePlaybackRouter()
    private let recentStore = RecentMusicStore.shared
    /// What a tap waiting on the Play On sheet will add to Recents once a
    /// speaker is picked.
    @State private var pendingRecent: RecentMusicItem?
    /// Keyed per-account (see init) — see NowPlayingCard's matching property
    /// for why this can't be a single shared key.
    @AppStorage("lastPlayOnSourceName") private var lastPlayOnSourceName: String = ""
    @State private var playOnZonePicked = false
    @State private var showFavoritesSheet = false
    @State private var zoneSwitchedAccount = false
    /// Resends of the last favorite after an account switch; a newer tap
    /// cancels them so they can't switch back to the old one.
    @State private var resendTask: Task<Void, Never>?

    init(mediaEntityId: String, accountDisplayName: String, speakerClaim: SpeakerClaimConfig?, favorites: [MusicFavorite], recents: [RecentMusicItem], zones: [MusicZone], hasMedia: Bool) {
        self.mediaEntityId = mediaEntityId
        self.accountDisplayName = accountDisplayName
        self.speakerClaim = speakerClaim
        self.favorites = favorites
        self.recents = recents
        self.zones = zones
        self.hasMedia = hasMedia
        self._lastPlayOnSourceName = AppStorage(wrappedValue: "", StorageKeys.lastPlayOnSource(account: mediaEntityId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !recents.isEmpty {
                sectionHeader("Recents")
                RecentsRow(items: recents, onArtwork: hasMedia) { item in
                    start(contentType: item.contentType, contentId: item.contentId,
                          displayName: item.title, recent: item)
                }
            }
            if !favorites.isEmpty {
                sectionHeader("Favorites")
                    .padding(.top, recents.isEmpty ? 0 : 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(favorites) { favorite in
                            Button {
                                lightTapHaptic()
                                start(contentType: favorite.contentType, contentId: favorite.contentId,
                                      displayName: favorite.displayName, recent: RecentMusic.item(from: favorite))
                            } label: {
                                Label(favorite.displayName, systemImage: favorite.icon)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(PressFeedbackIconButtonStyle())
                        }
                    }
                }
                .accessibilityIdentifier("favorites-bar")
            }
        }
        .sheet(isPresented: $showFavoritesSheet, onDismiss: {
            favoriteRouter.sheetDismissed(picked: playOnZonePicked) { action in
                if case .playMedia(let contentType, let contentId, _) = action {
                    if let pendingRecent { remember(pendingRecent) }
                    // When a switch was needed, PlayOnSheet already asked the
                    // voice assistant for this content by name (see
                    // desiredContentName). This resends the exact request over
                    // a longer window in case the assistant's interpretation
                    // differs or a still-settling handoff drops the call;
                    // harmless if an earlier attempt worked (it restarts the
                    // same content). Sent once when no switch was needed.
                    let delays = zoneSwitchedAccount ? [0.0, 5.0, 7.0, 13.0, 20.0, 25.0] : [0.0]
                    resendTask?.cancel()
                    resendTask = Task {
                        for delay in delays {
                            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                            guard !Task.isCancelled else { return }
                            haClient.playMedia(mediaEntityId, contentType: contentType, contentId: contentId)
                        }
                    }
                }
            }
            playOnZonePicked = false
            pendingRecent = nil
        }) {
            PlayOnSheet(
                mediaEntityId: mediaEntityId,
                accountDisplayName: accountDisplayName,
                speakerClaim: speakerClaim,
                zones: zones,
                activeSource: effectiveActiveSource,
                lastPlayOnSourceName: $lastPlayOnSourceName,
                zonePicked: $playOnZonePicked,
                zoneSwitchedAccount: $zoneSwitchedAccount,
                desiredContentName: pendingContentDisplayName
            )
        }
    }

    /// Plays in place when something's already playing; otherwise asks
    /// where, with the Play On sheet. Either way it lands in Recents.
    private func start(contentType: String, contentId: String, displayName: String, recent: RecentMusicItem) {
        resendTask?.cancel()
        if hasMedia, effectiveActiveSource != nil {
            // Already playing somewhere — just swap the track
            // in place, no need to ask where to play it again.
            haClient.playMedia(mediaEntityId, contentType: contentType, contentId: contentId)
            remember(recent)
        } else if favoriteRouter.requestPlay(.playMedia(
            contentType: contentType,
            contentId: contentId,
            displayName: displayName
        )) {
            pendingRecent = recent
            showFavoritesSheet = true
        }
    }

    private func remember(_ item: RecentMusicItem) {
        var item = item
        item.playedAt = Date()
        let account = mediaEntityId
        recentStore.record(item, account: account)
        guard item.thumbnail == nil else { return }
        let client = haClient
        Task {
            await recentStore.fillArtwork(for: item.id, account: account) { type, id in
                await client.browseMedia(entityId: account, mediaContentType: type, mediaContentId: id)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(hasMedia ? AnyShapeStyle(.white.opacity(0.65)) : AnyShapeStyle(.secondary))
    }

    private var effectiveActiveSource: String? {
        lastPlayOnSourceName.isEmpty ? nil : lastPlayOnSourceName
    }

    /// The human-speakable name of the favorite currently queued to play, if
    /// any — passed to PlayOnSheet so a fresh account switch can ask the voice
    /// assistant for this exact content directly rather than a generic placeholder.
    private var pendingContentDisplayName: String? {
        if case .playMedia(_, _, let displayName) = favoriteRouter.pendingAction {
            return displayName
        }
        return nil
    }
}
