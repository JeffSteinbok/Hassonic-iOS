import SwiftUI

/// Browse, in its own sheet with a Close button.
struct MediaBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entityId: String
    /// A playable item was tapped. Where it plays is the caller's call
    /// (see MusicStarter): sending `play_media` blind does nothing when
    /// the provider has no active speaker.
    let onPlay: (HABrowseMediaNode) -> Void

    var body: some View {
        NavigationStack {
            MediaBrowserRoot(entityId: entityId, onPlay: onPlay)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .readableSheetBackground()
    }
}

/// The media library's top level, for pushing onto a navigation stack.
struct MediaBrowserRoot: View {
    @EnvironmentObject private var haClient: HAWebSocketClient
    @Environment(\.openURL) private var openURL
    let entityId: String
    let onPlay: (HABrowseMediaNode) -> Void

    @State private var rootNode: HABrowseMediaNode?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPlaybackGuidance = false

    @EnvironmentObject private var configuration: AppConfigurationLoader

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading media...")
            } else if showPlaybackGuidance {
                let provider = configuration.mediaProvider
                ContentUnavailableView {
                    Label(
                        provider.map { "Start \($0.name) First" } ?? "Start Playback First",
                        systemImage: "music.note"
                    )
                } description: {
                    Text(
                        provider.map {
                            "Start playing something in \($0.name), then try Media Browser again."
                        } ?? "Start playing something on this speaker, then try Media Browser again."
                    )
                } actions: {
                    Button("Retry") { Task { await loadRoot() } }
                    if let provider, let appURL = provider.appURL {
                        Button("Open \(provider.name)") { openURL(appURL) }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Browsing Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await loadRoot() } }
                }
            } else if let rootNode {
                MediaBrowserNodeList(entityId: entityId, node: rootNode, onPlay: onPlay)
            } else {
                ContentUnavailableView("No Media Available", systemImage: "music.note.list", description: Text("This player returned no browseable items."))
            }
        }
        .navigationTitle("Browse Media")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRoot() }
    }

    private func loadRoot() async {
        guard !isLoading else { return }
        isLoading = true
        showPlaybackGuidance = false
        errorMessage = nil
        defer { isLoading = false }

        var startId: String?
        #if DEBUG && targetEnvironment(simulator)
        startId = DemoMode.browseStart
        #endif
        let response = await haClient.browseMedia(entityId: entityId, mediaContentType: startId, mediaContentId: startId)
        if response.success, let node = response.result {
            rootNode = node
        } else {
            rootNode = nil
            if MediaBrowseFailure.needsPlayback(playerState: haClient.entity(entityId)?.state, error: response.error) {
                showPlaybackGuidance = true
            } else {
                errorMessage = response.error?.message ?? "This media player does not support browsing."
            }
        }
    }
}

struct MediaBrowserNodeList: View {
    let entityId: String
    let node: HABrowseMediaNode
    let onPlay: (HABrowseMediaNode) -> Void

    var body: some View {
        List {
            if node.isPlayable, node.mediaContentType != nil, node.mediaContentId != nil {
                Button {
                    lightTapHaptic()
                    onPlay(node)
                } label: {
                    Label("Play \(node.displayTitle)", systemImage: "play.fill")
                }
            }

            if let children = node.children, !children.isEmpty {
                ForEach(children) { child in
                    MediaBrowserNodeRow(entityId: entityId, node: child, onPlay: onPlay)
                }
            } else if node.canBrowseChildren {
                Text("No items in this category.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(node.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MediaBrowserNodeRow: View {
    @EnvironmentObject private var haClient: HAWebSocketClient
    let entityId: String
    let node: HABrowseMediaNode
    let onPlay: (HABrowseMediaNode) -> Void
    @State private var loadedNode: HABrowseMediaNode?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if node.canBrowseChildren {
                NavigationLink {
                    MediaBrowserDestinationView(
                        entityId: entityId,
                        initialNode: node,
                        loadedNode: $loadedNode,
                        isLoading: $isLoading,
                        errorMessage: $errorMessage,
                        onPlay: onPlay
                    )
                } label: {
                    nodeLabel(node)
                }
            } else if node.isPlayable, node.mediaContentType != nil, node.mediaContentId != nil {
                Button {
                    lightTapHaptic()
                    onPlay(node)
                } label: {
                    nodeLabel(node)
                }
            } else {
                nodeLabel(node)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nodeLabel(_ node: HABrowseMediaNode) -> some View {
        HStack(spacing: 12) {
            BrowseThumbnailImage(
                thumbnailPath: node.thumbnail,
                baseURLString: haClient.baseURLString,
                accessToken: haClient.accessToken,
                fallbackIcon: MediaIcon.symbol(for: node),
                round: MediaIcon.isArtist(node.mediaClass)
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(node.displayTitle)
                // "Directory" says nothing; the icon tells folders apart.
                if let mediaClass = node.mediaClass, !mediaClass.isEmpty, mediaClass != "directory" {
                    Text(mediaClass.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MediaBrowserDestinationView: View {
    @EnvironmentObject private var haClient: HAWebSocketClient
    let entityId: String
    let initialNode: HABrowseMediaNode
    @Binding var loadedNode: HABrowseMediaNode?
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let onPlay: (HABrowseMediaNode) -> Void

    private var activeNode: HABrowseMediaNode {
        loadedNode ?? initialNode
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else if let errorMessage {
                ContentUnavailableView("Unable to Open", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                MediaBrowserNodeList(entityId: entityId, node: activeNode, onPlay: onPlay)
            }
        }
        .task { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard loadedNode == nil else { return }
        guard let contentType = initialNode.mediaContentType, let contentId = initialNode.mediaContentId else { return }
        isLoading = true
        defer { isLoading = false }
        let response = await haClient.browseMedia(entityId: entityId, mediaContentType: contentType, mediaContentId: contentId)
        if response.success, let node = response.result {
            loadedNode = node
            errorMessage = nil
        } else {
            errorMessage = response.error?.message ?? "No content returned."
        }
    }
}
