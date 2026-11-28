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
    @StateObject private var starter = MusicStarter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !recents.isEmpty {
                sectionHeader("Recents")
                RecentsRow(items: recents, onArtwork: hasMedia) { item in
                    start(MusicStartRequest(recent: item))
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
                                start(MusicStartRequest(favorite: favorite))
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
        .musicStartFlow(starter)
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            if DemoMode.openSheet == "play-on", let favorite = favorites.first {
                starter.showDemoFallback(MusicStartRequest(favorite: favorite), context: MusicStartContext(
                    accountEntityId: mediaEntityId, accountDisplayName: accountDisplayName,
                    speakerClaim: speakerClaim, zones: zones, hasMedia: hasMedia))
            }
        }
        #endif
    }

    /// Plays in place when something's already playing; otherwise asks
    /// where, with the Play On sheet. Lands in Recents once it starts.
    private func start(_ request: MusicStartRequest) {
        let context = MusicStartContext(accountEntityId: mediaEntityId, accountDisplayName: accountDisplayName,
                                        speakerClaim: speakerClaim, zones: zones, hasMedia: hasMedia)
        starter.start(request, context: context, client: haClient)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(hasMedia ? AnyShapeStyle(.white.opacity(0.65)) : AnyShapeStyle(.secondary))
    }
}
