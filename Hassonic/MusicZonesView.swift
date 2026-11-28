import SwiftUI

struct MusicZonesView: View {
    @EnvironmentObject private var haClient: HAWebSocketClient
    @Environment(\.openURL) private var openURL
    @State private var showingMediaBrowser = false
    @StateObject private var transitionManager = NowPlayingTransitionManager()
    @ObservedObject private var recentStore = RecentMusicStore.shared
    /// Browse picks: their Play On sheet comes up over Browse.
    @StateObject private var browseStarter = MusicStarter()

    @EnvironmentObject private var configuration: AppConfigurationLoader

    /// Which media account (entity) the whole screen is currently scoped to.
    /// Picked from the account switcher at the top of Browse.
    // Key deliberately keeps its original spelling: renaming it would reset
    // every existing install's chosen account back to the first entry.
    // Empty default, resolved against the loaded config: accounts arrive with
    // the configuration now, so there is nothing to read at init time.
    @AppStorage(StorageKeys.selectedMediaAccount) private var selectedMediaAccountId: String = ""

    private var accounts: [MediaAccount] { configuration.mediaAccounts }

    /// Nil until a configuration with at least one account has loaded — a
    /// remote config makes "no accounts yet" reachable at launch, where the
    /// bundled file used to guarantee one.
    private var selectedAccount: MediaAccount? {
        accounts.first { $0.id == selectedMediaAccountId } ?? accounts.first
    }

    private var mediaEntity: HAEntityState? {
        selectedAccount.flatMap { haClient.entity($0.entityId) }
    }

    /// Whichever zone matches the media entity's current `source`, if any.
    private var activeZone: MusicZone? {
        guard let selectedAccount,
              let source = mediaEntity?.attributeString("source") else { return nil }
        let normalizedSource = source.normalizedZoneSourceName
        return selectedAccount.zones.first { $0.sourceName?.normalizedZoneSourceName == normalizedSource }
    }

    /// Only the speakers relevant to what's currently playing: the active
    /// group's members, the single active speaker, or none until a target
    /// has been selected.
    private var speakers: [(zone: MusicZone, entity: HAEntityState)] {
        guard let selectedAccount, let activeZone else { return [] }

        let relevantEntityIds: Set<String>
        if activeZone.kind == .group {
            relevantEntityIds = Set(activeZone.memberEntityIds)
        } else {
            relevantEntityIds = [activeZone.entityId]
        }

        return selectedAccount.zones
            .filter { $0.kind == .speaker && $0.isEnabled && relevantEntityIds.contains($0.entityId) }
            .compactMap { zone in
                guard let entity = haClient.entity(zone.entityId), entity.isAvailable else { return nil }
                return (zone, entity)
            }
    }

    private var artworkURL: URL? {
        transitionManager.committed.artworkURL
    }

    /// True when there is a current track — playing or paused with valid metadata.
    /// Idle/stopped/off states have no `media_title` attribute and are treated as empty.
    private var hasMedia: Bool {
        transitionManager.committed.hasMedia
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if hasMedia {
                    backgroundArtwork
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Now Playing")
                        if let selectedAccount {
                            NowPlayingCard(entity: mediaEntity, presentation: transitionManager.committed, mediaEntityId: selectedAccount.entityId, accountDisplayName: selectedAccount.displayName, speakerClaim: configuration.speakerClaim, zones: selectedAccount.zones)

                            let recents = recentStore.items(for: selectedAccount.entityId)
                            if !selectedAccount.favorites.isEmpty || !recents.isEmpty {
                                FavoritesBar(mediaEntityId: selectedAccount.entityId, accountDisplayName: selectedAccount.displayName, speakerClaim: configuration.speakerClaim, favorites: selectedAccount.favorites, recents: recents, zones: selectedAccount.zones, hasMedia: hasMedia)
                                    .padding(.top, 8)
                            }
                        } else {
                            card {
                                Text("No media accounts are configured.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        sectionHeader("Speaker Volume")
                            .padding(.top, 8)
                        card {
                            if speakers.isEmpty {
                                Text("No speakers for this selection")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 10) {
                                    ForEach(speakers, id: \.zone.id) { pair in
                                        SpeakerRow(zone: pair.zone, entity: pair.entity)
                                        if pair.zone.id != speakers.last?.zone.id {
                                            Divider().overlay(hasMedia ? .white.opacity(0.2) : Color(.separator))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .reloadsConfigurationOnPull()
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(hasMedia ? .dark : nil, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppMenuButton(page: .music)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        if let provider = configuration.mediaProvider,
                           let appURL = provider.appURL,
                           let logoAsset = provider.logoAsset {
                            Button {
                                openURL(appURL)
                            } label: {
                                Image(logoAsset)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("Open in \(provider.name)")
                            .accessibilityHint("Opens the current track or the \(provider.name) app")
                        }

                        if accounts.count > 1 {
                            accountSwitcher
                        }

                        Button {
                            showingMediaBrowser = true
                        } label: {
                            Text("Browse")
                                .font(.body.weight(.medium))
                                .foregroundStyle(hasMedia ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        }
                        .accessibilityHint("Opens the Home Assistant media library")
                    }
                    // Plain style + our own material, rather than the system's automatic
                    // Liquid Glass toolbar chrome — keeps this pill's opacity consistent
                    // with destinationButton/card() elsewhere instead of a third look.
                    .buttonStyle(.plain)
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .sheet(isPresented: $showingMediaBrowser) {
                if let selectedAccount {
                    MediaBrowserSheet(entityId: selectedAccount.entityId) { node in
                        guard let request = MusicStartRequest(node: node) else { return }
                        let context = MusicStartContext(
                            accountEntityId: selectedAccount.entityId,
                            accountDisplayName: selectedAccount.displayName,
                            speakerClaim: configuration.speakerClaim,
                            zones: selectedAccount.zones,
                            hasMedia: hasMedia)
                        browseStarter.start(request, context: context, client: haClient) {
                            showingMediaBrowser = false
                        }
                    }
                    .musicStartFlow(browseStarter)
                }
            }
        }
        .task {
            transitionManager.update(entity: mediaEntity, baseURLString: haClient.baseURLString)
            #if DEBUG && targetEnvironment(simulator)
            if DemoMode.openSheet == "browse" { showingMediaBrowser = true }
            #endif
        }
        // The service's own "Recently played", each time the tab opens or
        // the account or connection changes.
        .task(id: RecentsRefreshKey(account: selectedAccount?.entityId, connected: haClient.connectionState == .connected)) {
            await refreshRecents()
        }
        .onChange(of: playbackAnchorIdentity(for: mediaEntity)) { _, _ in
            transitionManager.update(entity: mediaEntity, baseURLString: haClient.baseURLString)
        }
        .onChange(of: trackIdentity(for: mediaEntity)) { _, _ in
            transitionManager.update(entity: mediaEntity, baseURLString: haClient.baseURLString)
        }
    }

    private struct RecentsRefreshKey: Equatable {
        let account: String?
        let connected: Bool
    }

    private func refreshRecents() async {
        guard let account = selectedAccount?.entityId, haClient.connectionState == .connected else { return }
        #if DEBUG && targetEnvironment(simulator)
        // Demo mode has no socket to browse with.
        if let demo = DemoMode.recents() {
            recentStore.showDemo(demo, account: account)
            return
        }
        #endif
        let client = haClient
        await recentStore.refreshFromService(account: account) { type, id in
            await client.browseMedia(entityId: account, mediaContentType: type, mediaContentId: id)
        }
        await recentStore.fillMissingArtwork(account: account) { type, id in
            await client.browseMedia(entityId: account, mediaContentType: type, mediaContentId: id)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(hasMedia ? AnyShapeStyle(.white.opacity(0.65)) : AnyShapeStyle(.secondary))
    }

    /// Switches which media account (and therefore Now Playing, playback
    /// controls, zones, and favorites) the whole screen is scoped to.
    private var accountSwitcher: some View {
        Menu {
            ForEach(accounts) { account in
                Button {
                    selectedMediaAccountId = account.id
                } label: {
                    if account.id == selectedMediaAccountId {
                        Label(account.displayName, systemImage: "checkmark")
                    } else {
                        Text(account.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(selectedAccount?.displayName ?? "No account")
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(hasMedia ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .accessibilityLabel("Media account")
        .accessibilityHint(accountSwitcherHint)
    }

    /// Names the accounts that actually exist. The old string hardcoded two
    /// people and one provider, so it was already wrong for a third account
    /// and read aloud to anyone using VoiceOver.
    private var accountSwitcherHint: String {
        let names = accounts.map(\.displayName)
        guard !names.isEmpty else { return "Switch media account" }
        let list = ListFormatter.localizedString(byJoining: names)
        if let provider = configuration.mediaProvider {
            return "Switch between the \(list) \(provider.name) accounts"
        }
        return "Switch between the \(list) accounts"
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            // Matches destinationButton's material so every floating card/pill on
            // this screen has the same opacity, rather than each picking its own.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var backgroundArtwork: some View {
        FillImage(url: artworkURL, fallback: .black)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .overlay(Color.black.opacity(0.45))
            .ignoresSafeArea()
    }
}

enum PendingPlayAction {
    case playPause
    /// `displayName` is a human-speakable name (e.g. "Taylor Swift") used to
    /// ask Alexa for the real content directly when a fresh account switch
    /// is needed, rather than forcing a generic placeholder and hoping a
    /// separate API call lands afterward — see PlayOnSheet.performSwitch.
    case playMedia(contentType: String, contentId: String, displayName: String)
}

#Preview {
    MusicZonesView()
        .environmentObject(HAWebSocketClient())
}

/// Why browsing failed. Many players only browse while something's playing,
/// so a failure while the player is idle is taken as "play something first",
/// unless the error is plainly something else (auth, the connection).
enum MediaBrowseFailure {
    static func needsPlayback(playerState: String?, error: HAResultError?) -> Bool {
        let idleStates: Set<String> = ["idle", "off", "stopped", "unavailable", "unknown"]
        guard let playerState, idleStates.contains(playerState) else { return false }
        return !isUnrelatedToPlayback(error)
    }

    static func isUnrelatedToPlayback(_ error: HAResultError?) -> Bool {
        guard let error else { return false }
        let unrelatedCodes: Set<String> = ["unauthorized", "not_allowed", "home_assistant_error", "unknown_error"]
        if case .string(let code) = error.code, unrelatedCodes.contains(code) {
            return true
        }
        let message = (error.message ?? "").lowercased()
        return message.contains("auth") || message.contains("credential") ||
               message.contains("timeout") || message.contains("connection") ||
               message.contains("decode") || message.contains("network")
    }
}
