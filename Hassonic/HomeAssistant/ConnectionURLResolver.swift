import Foundation
import NetworkExtension

/// Picks between the internal (home network) and external (remote/Nabu Casa)
/// Home Assistant URL the way the official app does: by matching the
/// current Wi-Fi SSID against a trusted one. That's an instant decision with
/// no network round-trip, but it needs a starting point — so the first time
/// (or any time the SSID is unknown/unmatched) this falls back to actually
/// probing the internal URL, and if that succeeds, remembers the current
/// SSID as trusted for next time. This also self-heals if the home network
/// is renamed: the stale SSID just stops matching and gets relearned.
enum ConnectionURLResolver {
    /// `trustedSSID`, `probe`, and `currentSSID` all have real defaults but
    /// are injectable so this logic can be tested without touching the
    /// network, Wi-Fi hardware, or Keychain.
    static func resolve(
        externalURLString: String,
        internalURLString: String,
        trustedSSID: String? = KeychainStore.loadTrustedSSID(),
        probe: (URL) async -> Bool = defaultProbe,
        currentSSID: () async -> String? = defaultCurrentSSID,
        onLearnTrustedSSID: (String) -> Void = KeychainStore.saveTrustedSSID
    ) async -> String {
        guard !internalURLString.isEmpty, let internalURL = URL(string: internalURLString) else {
            return externalURLString
        }

        let ssid = await currentSSID()
        if let ssid, ssid == trustedSSID {
            return internalURLString
        }

        guard await probe(internalURL) else { return externalURLString }

        if let ssid, ssid != trustedSSID {
            onLearnTrustedSSID(ssid)
        }
        return internalURLString
    }

    /// Any HTTP response at all — even 401 unauthenticated — means the
    /// server answered, which is all that matters here (auth happens later).
    private static func defaultProbe(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    /// Requires the "Access WiFi Information" entitlement; returns nil
    /// without it (or off Wi-Fi entirely), which just routes back to probing.
    private static func defaultCurrentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}
