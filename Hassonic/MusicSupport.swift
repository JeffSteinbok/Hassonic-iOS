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
    if path.hasPrefix("http") || path.hasPrefix("file:") { return URL(string: path) }
    guard let base = URL(string: baseURLString) else { return nil }
    return URL(string: path, relativeTo: base)?.absoluteURL
}

/// A request for one of Home Assistant's images. The token goes only to Home
/// Assistant itself: a picture hosted elsewhere (Gravatar, a CDN) never sees
/// it.
func homeAssistantRequest(for url: URL, baseURLString: String, accessToken: String?) -> URLRequest {
    var request = URLRequest(url: url)
    if let accessToken, !accessToken.isEmpty,
       let base = URL(string: baseURLString), url.hasSameOrigin(as: base) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    return request
}

extension URL {
    /// Same scheme, host and port: the same server, as far as a token goes.
    func hasSameOrigin(as other: URL) -> Bool {
        guard let scheme = scheme?.lowercased(), scheme == other.scheme?.lowercased(),
              let host = host?.lowercased(), host == other.host?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (port ?? defaultPort) == (other.port ?? defaultPort)
    }
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

/// Album art drawn whole, never cropped or stretched. The image fits inside
/// whatever frame it's given (callers give it a square); if the cover isn't
/// square, e.g. a 16:9 video thumbnail, the bars either side are filled with a
/// blurred, dimmed copy of the same image rather than cutting the cover down.
struct LetterboxedArtwork: View {
    let image: Image

    var body: some View {
        // Both layers are overlays on a view that takes exactly the offered
        // frame. In a ZStack the overflowing fill layer would size the stack,
        // and the "fit" layer would then fit that oversized box: cropped again.
        Color.clear
            .overlay {
                image
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 18, opaque: true)
                    .overlay(Color.black.opacity(0.25))
            }
            .overlay {
                image
                    .resizable()
                    .scaledToFit()
            }
            .clipped()
    }
}

/// A square album-art tile: the whole cover, letterboxed if it isn't square,
/// with `placeholder` while it loads or when there's no art. Square from its
/// width, so give it a width (or let it fill one) rather than a height.
struct SquareArtwork<Placeholder: View>: View {
    let url: URL?
    var cornerRadius: CGFloat = 0
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            LetterboxedArtwork(image: image)
                        } else {
                            placeholder()
                        }
                    }
                } else {
                    placeholder()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private let thumbnailSize: CGFloat = 44

/// Resolves and loads a Browse-node thumbnail, with the HA token only when
/// it's on Home Assistant. Uses `URLSession` caching so repeated rows
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
                LetterboxedArtwork(image: image)
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

        let request = homeAssistantRequest(for: url, baseURLString: baseURLString, accessToken: accessToken)

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
