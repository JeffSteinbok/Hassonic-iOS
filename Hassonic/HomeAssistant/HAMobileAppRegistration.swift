import Foundation
import UIKit

/// The body of `POST /api/mobile_app/registrations`. Home Assistant drops
/// keys it doesn't know, so the push fields go in `app_data`, and the stable
/// `device_id` keeps it to one device per phone.
struct HAMobileAppRegistrationRequest: Encodable {
    struct AppData: Encodable, Equatable {
        let pushToken: String
        let pushUrl: String
    }

    let appId: String
    let appName: String
    let appVersion: String
    let deviceId: String
    let deviceName: String
    let manufacturer: String
    let model: String
    let osName: String
    let osVersion: String
    let supportsEncryption = false
    let appData: AppData
}

enum HAMobileAppRegistrationError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case failed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Unable to build Home Assistant mobile_app registration endpoint."
        case .invalidResponse:
            return "Home Assistant mobile_app registration returned an invalid response."
        case .failed(let code, let message):
            if let message, !message.isEmpty {
                return "Home Assistant mobile_app registration failed (\(code)): \(message)"
            }
            return "Home Assistant mobile_app registration failed (\(code))."
        }
    }
}

@MainActor
final class HAMobileAppRegistrar {
    private let session: URLSession
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func register(baseURL: URL, accessToken: String, pushToken: String, pushURL: String) async throws {
        guard let endpoint = Self.registrationEndpoint(from: baseURL) else {
            throw HAMobileAppRegistrationError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let payload = HAMobileAppRegistrationRequest(
            appId: Bundle.main.bundleIdentifier ?? "Hassonic",
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hassonic",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? UIDevice.current.name,
            deviceName: UIDevice.current.name,
            manufacturer: "Apple",
            model: UIDevice.current.model,
            osName: UIDevice.current.systemName,
            osVersion: UIDevice.current.systemVersion,
            appData: .init(pushToken: pushToken, pushUrl: pushURL)
        )
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HAMobileAppRegistrationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw HAMobileAppRegistrationError.failed(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private static func registrationEndpoint(from baseURL: URL) -> URL? {
        URL(string: "/api/mobile_app/registrations", relativeTo: baseURL)
    }
}
