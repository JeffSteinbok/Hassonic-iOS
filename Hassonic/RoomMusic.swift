import SwiftUI

/// Which speaker a room plays music on, and from which account.
enum RoomMusic {
    struct Target {
        let account: MediaAccount
        let zone: MusicZone
    }

    /// The first castable speaker among the room's devices, on the account
    /// picked on the Music tab if it has one there, else on the first
    /// account that does. A group is used only when no single speaker is in
    /// the room.
    static func target(roomEntities: [String], accounts: [MediaAccount], selectedAccountId: String?) -> Target? {
        let inRoom = Set(roomEntities)
        let ordered = accounts.filter { $0.id == selectedAccountId } + accounts.filter { $0.id != selectedAccountId }
        for kind in [MusicZone.Kind.speaker, .group] {
            for account in ordered {
                if let zone = account.zones.first(where: {
                    $0.kind == kind && $0.isEnabled && $0.sourceName != nil && inRoom.contains($0.entityId)
                }) {
                    return Target(account: account, zone: zone)
                }
            }
        }
        return nil
    }
}

/// "Play Music": picks something (Recents, Favorites, Browse) and plays it
/// on the room's own speaker.
struct RoomMusicButton: View {
    let card: DashboardRoomCardConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient
    @EnvironmentObject private var configuration: AppConfigurationLoader
    @AppStorage(StorageKeys.selectedMediaAccount) private var selectedAccountId: String = ""
    @State private var showing = false

    private var target: RoomMusic.Target? {
        RoomMusic.target(roomEntities: card.entities, accounts: configuration.mediaAccounts,
                         selectedAccountId: selectedAccountId.isEmpty ? nil : selectedAccountId)
    }

    var body: some View {
        if let target {
            let playing = ["playing", "paused"].contains(haClient.entity(target.zone.entityId)?.state ?? "")
            Button {
                lightTapHaptic()
                showing = true
            } label: {
                Label(playing ? "Play Something Else" : "Play Music Here", systemImage: "music.note.list")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Pick something to play on \(target.zone.displayName)")
            .sheet(isPresented: $showing) {
                RoomMusicSheet(roomName: card.title ?? target.zone.displayName, target: target,
                               speakerClaim: configuration.speakerClaim)
            }
            #if DEBUG && targetEnvironment(simulator)
            .onAppear { if DemoMode.openSheet == "room-music" { showing = true } }
            #endif
        }
    }
}

/// Recents, Favorites and Browse for one room: whatever's picked plays on
/// the room's speaker, moving the account there first if it has to.
struct RoomMusicSheet: View {
    let roomName: String
    let target: RoomMusic.Target
    let speakerClaim: SpeakerClaimConfig?

    @EnvironmentObject private var haClient: HAWebSocketClient
    @EnvironmentObject private var configuration: AppConfigurationLoader
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recentStore = RecentMusicStore.shared
    @StateObject private var starter = MusicStarter()

    private var account: MediaAccount { target.account }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plays on \(target.zone.displayName)")
                            Text("\(account.displayName)'s account")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: target.zone.icon)
                    }
                }

                let recents = recentStore.items(for: account.entityId)
                if !recents.isEmpty {
                    Section("Recents") {
                        RecentsRow(items: recents, onArtwork: false) { item in
                            start(MusicStartRequest(recent: item))
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 0))
                    }
                }

                if !account.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(account.favorites) { favorite in
                            Button {
                                lightTapHaptic()
                                start(MusicStartRequest(favorite: favorite))
                            } label: {
                                Label(favorite.displayName, systemImage: favorite.icon)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        MediaBrowserRoot(entityId: account.entityId) { node in
                            if let request = MusicStartRequest(node: node) { start(request) }
                        }
                    } label: {
                        Label("Browse \(configuration.mediaProvider?.name ?? "Media")", systemImage: "square.grid.2x2")
                    }
                }
            }
            .navigationTitle("Play in \(roomName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .readableSheetBackground()
        .musicStartFlow(starter)
        .task(id: haClient.connectionState == .connected) { await refreshRecents() }
    }

    private func start(_ request: MusicStartRequest) {
        let entity = haClient.entity(account.entityId)
        let hasMedia = ["playing", "paused"].contains(entity?.state ?? "") && entity?.attributeString("media_title") != nil
        let context = MusicStartContext(accountEntityId: account.entityId, accountDisplayName: account.displayName,
                                        speakerClaim: speakerClaim, zones: account.zones, hasMedia: hasMedia,
                                        target: target.zone)
        starter.start(request, context: context, client: haClient) { dismiss() }
    }

    /// The Music tab fetches the service's history when it opens; the room
    /// can be opened first.
    private func refreshRecents() async {
        guard haClient.connectionState == .connected else { return }
        let accountId = account.entityId
        #if DEBUG && targetEnvironment(simulator)
        if let demo = DemoMode.recents() {
            recentStore.showDemo(demo, account: accountId)
            return
        }
        #endif
        let client = haClient
        await recentStore.refreshFromService(account: accountId) { type, id in
            await client.browseMedia(entityId: accountId, mediaContentType: type, mediaContentId: id)
        }
        await recentStore.fillMissingArtwork(account: accountId) { type, id in
            await client.browseMedia(entityId: accountId, mediaContentType: type, mediaContentId: id)
        }
    }
}
