import SwiftUI

/// The Recents row on the Music tab: covers of what was played lately, each
/// one tap from playing again.
struct RecentsRow: View {
    let items: [RecentMusicItem]
    /// Over the blurred artwork while something plays, so text goes white.
    let onArtwork: Bool
    let play: (RecentMusicItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    Button {
                        lightTapHaptic()
                        play(item)
                    } label: {
                        RecentTile(item: item, onArtwork: onArtwork)
                    }
                    .buttonStyle(PressFeedbackIconButtonStyle())
                    .accessibilityLabel("Play \(item.title)")
                    .accessibilityHint(item.subtitle ?? "")
                }
            }
        }
        .accessibilityIdentifier("recents-row")
    }
}

private struct RecentTile: View {
    let item: RecentMusicItem
    let onArtwork: Bool

    static let side: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecentArtwork(thumbnail: item.thumbnail, icon: MediaIcon.symbol(for: item))
                .frame(width: Self.side, height: Self.side)
            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(onArtwork ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(onArtwork ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: Self.side, alignment: .leading)
    }
}

/// A cover shown whole: fitted inside the square, never cropped. Album art
/// is square and fills it; a wide or tall picture (an artist photo, a
/// station logo) is letterboxed rather than cut.
struct RecentArtwork: View {
    let thumbnail: String?
    let icon: String

    @EnvironmentObject private var haClient: HAWebSocketClient
    @State private var image: UIImage?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024,
                                   diskPath: "recent_artwork")
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    var body: some View {
        ZStack {
            // Solid, not material: over the blurred artwork a material tile
            // and its grey icon all but vanished.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .task(id: thumbnail) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let url = resolveHAImageURL(path: thumbnail, baseURLString: haClient.baseURLString) else {
            image = nil
            return
        }
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
            return
        }
        let request = homeAssistantRequest(for: url, baseURLString: haClient.baseURLString, accessToken: haClient.accessToken)
        guard let (data, response) = try? await Self.session.data(for: request), !Task.isCancelled else { return }
        // An error page isn't a picture: the icon stays.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        image = UIImage(data: data)
    }
}
