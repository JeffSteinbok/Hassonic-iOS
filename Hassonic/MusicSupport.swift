import SwiftUI

extension String {
    var normalizedZoneSourceName: String {
        trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct PressFeedbackIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

func lightTapHaptic() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}

/// Resolves a Home Assistant image attribute (often a relative path like
/// "/api/media_player_proxy/...") against the configured base URL.
func resolveHAImageURL(path: String?, baseURLString: String) -> URL? {
    guard let path else { return nil }
    if path.hasPrefix("http") { return URL(string: path) }
    guard let base = URL(string: baseURLString) else { return nil }
    return URL(string: path, relativeTo: base)?.absoluteURL
}

/// A full-bleed AsyncImage that fills its container without ever inflating
/// the parent's layout size. `.frame(maxWidth: .infinity)` alone isn't
/// enough — the loaded image's native aspect ratio can still leak into the
/// ideal-size query and inflate ancestors. Resolving to a concrete pixel
/// size via GeometryReader and handing that down explicitly closes that gap.
struct FillImage: View {
    let url: URL?
    let fallback: Color

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            fallback
                        }
                    }
                } else {
                    fallback
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

private let thumbnailSize: CGFloat = 44

/// Resolves and loads a Browse-node thumbnail, injecting the HA auth header
/// only for HA-relative paths. Uses `URLSession` caching so repeated rows
/// for the same image don't re-download while scrolling.
struct BrowseThumbnailImage: View {
    let thumbnailPath: String?
    let baseURLString: String
    let accessToken: String?

    @State private var phase: Phase = .idle

    enum Phase { case idle, loading, loaded(Image), failed }

    private static let cache = URLCache(
        memoryCapacity: 20 * 1024 * 1024,
        diskCapacity: 100 * 1024 * 1024,
        diskPath: "browse_thumbnails"
    )

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private var resolvedURL: URL? {
        resolveHAImageURL(path: thumbnailPath, baseURLString: baseURLString)
    }

    var body: some View {
        ZStack {
            switch phase {
            case .loaded(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            default:
                placeholderView
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .task(id: thumbnailPath) { await load() }
        .accessibilityHidden(true)
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(.systemFill))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            )
    }

    private func load() async {
        guard let url = resolvedURL else { phase = .failed; return }
        phase = .loading

        var request = URLRequest(url: url)
        let needsAuth = thumbnailPath.map { !$0.hasPrefix("http") } ?? false
        if needsAuth, let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await Self.session.data(for: request)
            guard !Task.isCancelled else { return }
            if let uiImage = UIImage(data: data) {
                phase = .loaded(Image(uiImage: uiImage))
            } else {
                phase = .failed
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}
