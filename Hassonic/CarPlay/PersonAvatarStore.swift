import UIKit

/// Fetches and caches Home Assistant profile pictures for the CarPlay pins.
///
/// Profile pictures are served from the HA instance and need the same bearer
/// token as everything else. They change rarely, so once fetched an avatar is
/// kept for the life of the CarPlay session — a person moving between zones
/// re-renders the map many times over and must not re-download on each one.
@MainActor
final class PersonAvatarStore {
    /// Called when a fetch completes, so the caller can re-render with the
    /// newly available picture.
    var onAvatarLoaded: (() -> Void)?

    private var avatars: [URL: UIImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: Set<URL> = []
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func avatar(for url: URL) -> UIImage? { avatars[url] }

    /// Starts a fetch if this URL hasn't been tried yet. A failure is
    /// remembered so a broken picture doesn't retry on every state change;
    /// the initials pin stands in for it.
    func loadIfNeeded(url: URL, accessToken: String?) {
        guard avatars[url] == nil, !failed.contains(url), !inFlight.contains(url) else { return }
        inFlight.insert(url)

        Task { [weak self] in
            guard let self else { return }
            let image = await Self.fetch(url: url, accessToken: accessToken, session: session)
            inFlight.remove(url)
            guard let image else {
                failed.insert(url)
                return
            }
            avatars[url] = image
            onAvatarLoaded?()
        }
    }

    private static func fetch(url: URL, accessToken: String?, session: URLSession) async -> UIImage? {
        var request = URLRequest(url: url)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return UIImage(data: data)
    }
}
