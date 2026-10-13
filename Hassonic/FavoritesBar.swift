import SwiftUI

struct NowPlayingPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Choose something to play")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No media playing. Choose something to play.")
    }
}

struct FavoritesBar: View {
    let mediaEntityId: String
    let accountDisplayName: String
    let speakerClaim: SpeakerClaimConfig?
    let favorites: [MusicFavorite]
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
    /// Keyed per-account (see init) — see NowPlayingCard's matching property
    /// for why this can't be a single shared key.
    @AppStorage("lastPlayOnSourceName") private var lastPlayOnSourceName: String = ""
    @State private var playOnZonePicked = false
    @State private var showFavoritesSheet = false
    @State private var zoneSwitchedAccount = false

    init(mediaEntityId: String, accountDisplayName: String, speakerClaim: SpeakerClaimConfig?, favorites: [MusicFavorite], zones: [MusicZone], hasMedia: Bool) {
        self.mediaEntityId = mediaEntityId
        self.accountDisplayName = accountDisplayName
        self.speakerClaim = speakerClaim
        self.favorites = favorites
        self.zones = zones
        self.hasMedia = hasMedia
        self._lastPlayOnSourceName = AppStorage(wrappedValue: "", StorageKeys.lastPlayOnSource(account: mediaEntityId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(favorites) { favorite in
                        Button {
                            lightTapHaptic()
                            if hasMedia, effectiveActiveSource != nil {
                                // Already playing somewhere — just swap the track
                                // in place, no need to ask where to play it again.
                                haClient.playMedia(mediaEntityId, contentType: favorite.contentType, contentId: favorite.contentId)
                            } else if favoriteRouter.requestPlay(.playMedia(
                                contentType: favorite.contentType,
                                contentId: favorite.contentId,
                                displayName: favorite.displayName
                            )) {
                                showFavoritesSheet = true
                            }
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
        }
        .accessibilityIdentifier("favorites-bar")
        .sheet(isPresented: $showFavoritesSheet, onDismiss: {
            favoriteRouter.sheetDismissed(picked: playOnZonePicked) { action in
                if case .playMedia(let contentType, let contentId, _) = action {
                    // Backup/precision correction only now — when a switch was
                    // needed, PlayOnSheet already asks Alexa for this exact
                    // content by name directly (see desiredContentName), so
                    // Kitchen shouldn't be stuck on a generic placeholder
                    // anymore. This still resends the precise API-driven
                    // request over a longer window in case Alexa's own
                    // interpretation differs slightly or the API call gets
                    // dropped by a still-settling handoff — harmless if an
                    // earlier attempt already worked (just restarts the same
                    // content). Skipped entirely when no switch was needed.
                    let delays = zoneSwitchedAccount ? [0.0, 5.0, 12.0, 25.0, 45.0, 70.0] : [0.0]
                    for delay in delays {
                        Task {
                            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                            haClient.playMedia(mediaEntityId, contentType: contentType, contentId: contentId)
                        }
                    }
                }
            }
            playOnZonePicked = false
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

    private var effectiveActiveSource: String? {
        lastPlayOnSourceName.isEmpty ? nil : lastPlayOnSourceName
    }

    /// The human-speakable name of the favorite currently queued to play, if
    /// any — passed to PlayOnSheet so a fresh account switch can ask Alexa
    /// for this exact content directly rather than a generic placeholder.
    private var pendingContentDisplayName: String? {
        if case .playMedia(_, _, let displayName) = favoriteRouter.pendingAction {
            return displayName
        }
        return nil
    }
}
