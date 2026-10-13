import Foundation
import AuthenticationServices
import UIKit

/// Handles the HA OAuth2 / IndieAuth login flow using `ASWebAuthenticationSession`.
///
/// The static HTML page at `clientId` (docs/index.html, served by GitHub Pages)
/// contains:
///   `<link rel="redirect_uri" href="hassonic://auth-callback">`
/// which satisfies HA's IndieAuth client verification before it issues an auth code.
/// The URL comes from `HA_OAUTH_CLIENT_ID` in Config/Base.xcconfig, so a fork
/// can point at its own copy of the page.
@MainActor
final class HAOAuthClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    static let clientId = Bundle.main.object(forInfoDictionaryKey: "HAOAuthClientID") as? String ?? ""
    static let redirectURIString = "hassonic://auth-callback"
    static let callbackScheme = "hassonic"

    private var authSession: ASWebAuthenticationSession?

    struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
    }

    private struct RawTokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
    }

    // MARK: - Public API

    /// Opens HA's login page in an `ASWebAuthenticationSession`, exchanges the
    /// returned auth code for tokens, and returns them.  Returns `nil` on
    /// cancellation or any error.
    func login(baseURL: URL) async -> TokenResponse? {
        guard let authURL = authorizeURL(for: baseURL) else { return nil }

        let callbackURL: URL? = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { url, _ in
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }
        authSession = nil

        guard let callbackURL,
              let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value else { return nil }

        return await exchangeCode(baseURL: baseURL, code: code)
    }

    /// Attempts a silent token refresh.  Returns a new access token or `nil`
    /// if the refresh token is expired / invalid.
    func refresh(baseURL: URL, refreshToken: String) async -> String? {
        var request = tokenRequest(baseURL: baseURL)
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": Self.clientId,
            "refresh_token": refreshToken,
        ])
        return await performTokenRequest(request)?.access_token
    }

    // MARK: - Private helpers

    private func authorizeURL(for baseURL: URL) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/auth/authorize"
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURIString),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        return components?.url
    }

    private func exchangeCode(baseURL: URL, code: String) async -> TokenResponse? {
        var request = tokenRequest(baseURL: baseURL)
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "client_id": Self.clientId,
            "redirect_uri": Self.redirectURIString,
            "code": code,
        ])
        guard let raw = await performTokenRequest(request) else { return nil }
        return TokenResponse(accessToken: raw.access_token, refreshToken: raw.refresh_token)
    }

    private func tokenRequest(baseURL: URL) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/auth/token"
        var request = URLRequest(url: components!.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func formBody(_ params: [String: String]) -> Data? {
        params
            .map { k, v in
                let key = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
                let val = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
                return "\(key)=\(val)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private func performTokenRequest(_ request: URLRequest) async -> RawTokenResponse? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RawTokenResponse.self, from: data)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    /// Every fallback here is scene-bound. A bare `UIWindow()` belongs to no
    /// scene, so it has nowhere to present — which is why iOS 26 deprecated
    /// that initialiser, and why the last resort is a window attached to
    /// whatever scene exists rather than a detached one.
    ///
    /// The foreground-active preference matters on iPad, where a second
    /// window in the background would otherwise be as good a match as the one
    /// the user is actually looking at.
    // Deprecated deliberately, and only so the last-resort branch below can
    // build without a warning. `initWithWindowScene:` is the sole
    // non-deprecated UIWindow initialiser on iOS 26, so a window for an app
    // with no window scene cannot be constructed any other way — and the
    // method must return one. Nothing in this codebase calls it;
    // ASWebAuthenticationSession does, while presenting, which is precisely
    // when a scene is guaranteed to exist.
    @available(iOS, deprecated: 26.0, message: "Internal: scoping the scene-less UIWindow fallback.")
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let preferredScenes = scenes.filter { $0.activationState == .foregroundActive }
            let candidates = preferredScenes.isEmpty ? scenes : preferredScenes

            if let keyWindow = candidates.flatMap(\.windows).first(where: \.isKeyWindow) {
                return keyWindow
            }
            if let anyWindow = candidates.flatMap(\.windows).first {
                return anyWindow
            }
            // No window anywhere. The user can only reach login from a visible
            // one, so this is unreachable in practice — but it has to return
            // something, and a scene-bound window is the only kind that could
            // ever present.
            guard let scene = candidates.first else {
                return ASPresentationAnchor(frame: .zero)
            }
            return ASPresentationAnchor(windowScene: scene)
        }
    }

}
