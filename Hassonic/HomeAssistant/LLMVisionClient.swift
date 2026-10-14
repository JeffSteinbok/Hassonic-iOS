import Foundation

protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

struct LLMVisionClient {
    private let baseURL: URL
    private let accessToken: String
    private let urlSession: URLSessionProtocol

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(baseURL: URL, accessToken: String, urlSession: URLSessionProtocol = URLSession.shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.urlSession = urlSession
    }

    func fetchTimelineEvents(limit: Int = 50, hours: Int = 24) async -> Result<[LLMVisionEvent], LLMVisionError> {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/llmvision/timeline/events"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "hours", value: "\(hours)"),
            // The API defaults to excluding "no activity" summaries — without this,
            // a quiet stretch (or a camera that's currently only detecting nothing)
            // makes the timeline look completely empty/broken instead of idle.
            URLQueryItem(name: "include_no_activity", value: "true")
        ]
        guard let url = components.url else {
            return .failure(.networkError("Invalid URL"))
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.networkError("Unexpected response"))
            }
            if http.statusCode == 404 {
                return .failure(.integrationUnavailable)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.authenticationFailed)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.networkError("HTTP \(http.statusCode)"))
            }
            do {
                let response = try Self.decoder.decode(LLMVisionTimelineResponse.self, from: data)
                let sorted = response.events
                    .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
                let deduped = deduplicated(sorted)
                return .success(deduped)
            } catch {
                return .failure(.decodingError)
            }
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    func imageRequest(for path: String) -> URLRequest? {
        guard !path.isEmpty, let url = URL(string: Self.resolveMediaPath(path), relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        // An absolute key frame elsewhere doesn't get the token.
        if url.absoluteURL.hasSameOrigin(as: baseURL) {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// LLM Vision's `key_frame` values are filesystem-style paths under Home
    /// Assistant's local media directory (e.g. "/media/llmvision/snapshots/x.jpg"),
    /// but HA's actual web route for local media requires a "local" path segment
    /// ("/media/local/llmvision/snapshots/x.jpg") — without it the request 404s.
    /// Absolute URLs and already-correct paths pass through unchanged.
    static func resolveMediaPath(_ path: String) -> String {
        guard path.hasPrefix("/media/"), !path.hasPrefix("/media/local/") else { return path }
        let remainder = path.dropFirst("/media/".count)
        return "/media/local/\(remainder)"
    }

    private func deduplicated(_ events: [LLMVisionEvent]) -> [LLMVisionEvent] {
        var seen = Set<String>()
        return events.filter { seen.insert($0.uid).inserted }
    }
}
