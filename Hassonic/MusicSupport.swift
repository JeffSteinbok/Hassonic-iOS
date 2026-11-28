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

/// Sizes for the Music tab's Now Playing card.
enum NowPlayingHero {
    /// The card is square and as wide as the page, up to this (on iPad).
    static let maxSide: CGFloat = 420
    static let cornerRadius: CGFloat = 20
    /// How far the gradient reaches above the text, so the first line isn't
    /// on its clear end.
    static let scrimLead: CGFloat = 48
}

/// The Now Playing card: a square, as wide as it's offered up to
/// `NowPlayingHero.maxSide`. `artwork` fills it edge to edge (give it a view
/// that fills, like `FillImage`). `overlay` is pinned to the bottom, and the
/// darkening gradient sits only behind it, so the rest of the cover shows
/// as it is.
struct NowPlayingHeroSquare<Artwork: View, Overlay: View>: View {
    var showsScrim: Bool
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var overlay: () -> Overlay

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ZStack { artwork() } }
            .overlay(alignment: .bottom) {
                overlay()
                    .background(alignment: .bottom) {
                        if showsScrim {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.45), location: 0.3),
                                    .init(color: .black.opacity(0.75), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .padding(.top, -NowPlayingHero.scrimLead)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: NowPlayingHero.cornerRadius, style: .continuous))
            .frame(maxWidth: NowPlayingHero.maxSide)
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
    /// Shown with no art, or art that won't load: the kind's own symbol.
    var fallbackIcon: String = "music.note"
    /// An artist: a round photo, like the provider apps.
    var round: Bool = false

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
        artwork
            .frame(width: thumbnailSize, height: thumbnailSize)
            .task(id: thumbnailPath) { await load() }
            .accessibilityHidden(true)
    }

    /// An artist's photo fills a circle; anything else is the square tile.
    @ViewBuilder
    private var artwork: some View {
        if round, case .loaded(let image) = phase {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(Circle())
        } else {
            squareArtwork
        }
    }

    private var squareArtwork: some View {
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
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: round ? thumbnailSize / 2 : 6, style: .continuous)
            .fill(Color(.systemFill))
            .overlay(
                Image(systemName: fallbackIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
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

extension View {
    /// A sheet you can read: solid behind its rows, not the default glass
    /// that lets the album art behind it show through the text. Keeps the
    /// drawer's shape, and needs no Reduce Transparency special case.
    func readableSheetBackground() -> some View {
        presentationBackground(Color(.systemGroupedBackground))
    }
}
