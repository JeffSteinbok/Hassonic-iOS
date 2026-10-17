import CryptoKit
import Foundation
import Security

enum OpenClawError: LocalizedError, Equatable {
    case invalidSetupCode
    case insecureURL
    case expiredSetupCode
    case keychain
    case disconnected
    case timeout
    case invalidResponse
    case unsupportedGateway
    case unsafeCredential
    case agentUnavailable
    case rpc(code: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .invalidSetupCode: return "Paste a valid OpenClaw setup code."
        case .insecureURL: return "The gateway needs a secure wss:// address with a trusted certificate."
        case .expiredSetupCode: return "That setup code has expired. Generate a new limited setup code."
        case .keychain: return "Couldn't access the Assistant's credentials in Keychain. Try again after unlocking your device."
        case .disconnected: return "The connection to the assistant was interrupted."
        case .timeout: return "The gateway didn't respond in time."
        case .invalidResponse: return "The gateway sent an unexpected response."
        case .unsupportedGateway: return "This Assistant needs an OpenClaw gateway with protocol v4 and mobile device pairing."
        case .unsafeCredential: return "Use a limited setup code with chat access and without administrator or pairing access."
        case .agentUnavailable: return "The hassonic agent isn't configured on the gateway. Ask the gateway owner to add it."
        case .rpc(let code, let detail):
            if code == "NOT_PAIRED" || detail == "PAIRING_REQUIRED" { return "Waiting for device approval on the gateway…" }
            if requiresPairing { return "The gateway rejected this credential. Forget the gateway and pair with a new limited setup code." }
            if code == "FORBIDDEN" { return "This device doesn't have permission to send directives. Ask the gateway owner to check its access." }
            if code == "INVALID_REQUEST" { return "The gateway rejected this directive. Check that the hassonic agent and session are available." }
            return "The gateway couldn't complete the request (\(code))."
        }
    }

    var isPendingApproval: Bool {
        if case .rpc(let code, let detail) = self {
            return code == "NOT_PAIRED" || code == "PAIRING_REQUIRED" || detail == "PAIRING_REQUIRED"
        }
        return false
    }

    /// An explicit rejection is different from a lost acknowledgement.
    var isRequestRejected: Bool {
        if self == .agentUnavailable { return true }
        guard case .rpc(let code, _) = self else { return false }
        return ["INVALID_REQUEST", "UNAUTHORIZED", "FORBIDDEN", "NOT_PAIRED", "PAIRING_REQUIRED"].contains(code)
    }

    var requiresPairing: Bool {
        guard case .rpc(let code, let detail) = self else { return false }
        return code == "UNAUTHORIZED" || ["AUTH_TOKEN_MISMATCH", "AUTH_DEVICE_TOKEN_MISMATCH", "AUTH_SCOPE_MISMATCH", "AUTH_BOOTSTRAP_TOKEN_INVALID", "AUTH_TOKEN_EXPIRED", "DEVICE_AUTH_INVALID"].contains(detail ?? code)
    }
}

struct OpenClawSetupCode {
    let url: URL
    let bootstrapToken: String
    let expiresAt: Date?

    static func parse(_ input: String, now: Date = Date()) throws -> Self {
        var code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.lowercased().hasPrefix("oc-pair://") { code = String(code.dropFirst(10)) }
        guard code.count <= 16_384,
              code.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let data = Data(base64URL: code),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = object["url"] as? String,
              let token = object["bootstrapToken"] as? String,
              !token.isEmpty, token.count <= 8192 else { throw OpenClawError.invalidSetupCode }
        let url = try validatedURL(rawURL)
        var expiresAt: Date?
        if let value = object["expiresAtMs"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue.rounded() == number.doubleValue else { throw OpenClawError.invalidSetupCode }
            expiresAt = Date(timeIntervalSince1970: number.doubleValue / 1000)
            guard expiresAt! > now else { throw OpenClawError.expiredSetupCode }
        }
        return Self(url: url, bootstrapToken: token, expiresAt: expiresAt)
    }

    static func validatedURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "wss",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw OpenClawError.insecureURL
        }
        return url
    }
}

struct OpenClawIdentity {
    let privateKey: Curve25519.Signing.PrivateKey

    init(rawRepresentation: Data? = nil) throws {
        if let rawRepresentation {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
        }
    }

    var deviceID: String {
        SHA256.hash(data: privateKey.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }

    /// OpenClaw's v2 compatibility payload. Field order is part of the signed protocol.
    /// https://github.com/openclaw/openclaw/blob/main/apps/shared/OpenClawKit/Sources/OpenClawKit/DeviceAuthPayload.swift
    func signedDevice(role: String, scopes: [String], token: String, nonce: String, signedAt: Int64) throws -> [String: Any] {
        let payload = Self.signaturePayload(deviceID: deviceID, role: role, scopes: scopes, token: token, nonce: nonce, signedAt: signedAt)
        return [
            "id": deviceID,
            "publicKey": privateKey.publicKey.rawRepresentation.base64URL,
            "signature": try privateKey.signature(for: Data(payload.utf8)).base64URL,
            "signedAt": signedAt,
            "nonce": nonce
        ]
    }

    static func signaturePayload(deviceID: String, role: String, scopes: [String], token: String, nonce: String, signedAt: Int64) -> String {
        ["v2", deviceID, "openclaw-ios", role == "node" ? "node" : "ui", role,
         scopes.joined(separator: ","), String(signedAt), token, nonce].joined(separator: "|")
    }
}

struct OpenClawCredential: Codable, Equatable {
    let gatewayURL: String
    let token: String
    let scopes: [String]

    static let chatScopes = ["operator.read", "operator.write"]
    // OpenClaw propagates these scopes to the run. Its plugin approval
    // request/wait methods require approvals even when review goes to Discord.
    static let connectionScopes = chatScopes + ["operator.approvals"]

    func validated() throws -> Self {
        _ = try OpenClawSetupCode.validatedURL(gatewayURL)
        let allowed: Set<String> = ["operator.read", "operator.write", "operator.approvals", "operator.questions", "operator.talk.secrets"]
        guard !token.isEmpty, token.count <= 8192,
              Set(scopes).isSubset(of: allowed),
              Set(Self.chatScopes).isSubset(of: Set(scopes)) else { throw OpenClawError.unsafeCredential }
        return self
    }

    static func from(hello: [String: Any], url: URL, bootstrap: Bool) throws -> Self {
        guard let auth = hello["auth"] as? [String: Any] else { throw OpenClawError.invalidResponse }
        let entry: [String: Any]
        if bootstrap {
            guard let tokens = auth["deviceTokens"] as? [[String: Any]],
                  let operatorToken = tokens.first(where: { $0["role"] as? String == "operator" }) else {
                throw OpenClawError.unsupportedGateway
            }
            entry = operatorToken
        } else {
            guard auth["role"] as? String == "operator" else { throw OpenClawError.invalidResponse }
            entry = auth
        }
        guard let token = entry["deviceToken"] as? String, let scopes = entry["scopes"] as? [String] else {
            throw OpenClawError.invalidResponse
        }
        return try Self(gatewayURL: url.absoluteString, token: token, scopes: scopes).validated()
    }
}

@MainActor
protocol OpenClawCredentialStoring {
    func identity() throws -> OpenClawIdentity
    func credential() throws -> OpenClawCredential?
    func save(_ credential: OpenClawCredential) throws
    func forget() throws
}

/// A separate service from HA credentials; no sync, backup migration or plaintext defaults.
@MainActor
final class OpenClawCredentialStore: OpenClawCredentialStoring {
    private let service = "\(Bundle.main.bundleIdentifier ?? "Hassonic").openclaw"

    func identity() throws -> OpenClawIdentity {
        if let data = try read("identity") { return try OpenClawIdentity(rawRepresentation: data) }
        let identity = try OpenClawIdentity()
        try write(identity.privateKey.rawRepresentation, account: "identity")
        return identity
    }

    func credential() throws -> OpenClawCredential? {
        guard let data = try read("credential") else { return nil }
        return try JSONDecoder().decode(OpenClawCredential.self, from: data).validated()
    }

    func save(_ credential: OpenClawCredential) throws {
        try write(JSONEncoder().encode(credential.validated()), account: "credential")
    }

    func forget() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenClawError.keychain }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    private func read(_ account: String) throws -> Data? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw OpenClawError.keychain }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(values) { _, new in new }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw OpenClawError.keychain }
        } else if status != errSecSuccess { throw OpenClawError.keychain }
    }
}

extension Data {
    fileprivate var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    fileprivate init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}
