import Foundation
import Security

/// Where the Margin service lives, from the MARGIN_API_BASE_URL build setting via Info.plist.
enum MarginService {
    static var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MARGIN_API_BASE_URL") as? String,
              !value.isEmpty, value != "https://api.example.com", !value.hasPrefix("$("),
              let url = URL(string: value), let host = url.host else { return nil }
        // HTTPS only, except a local development server.
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) ? url : nil
    }
}

struct MarginAPIError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// The signed Margin session (from Sign in with Apple) and the Apple user it belongs to, in the Keychain.
final class SessionTokenStore {
    private let service = "com.mattbrown.margin.api"

    func read() -> String? { string(for: "session") }
    func save(_ token: String) { set(token, for: "session") }
    func delete() { remove("session"); remove("appleUserID") }
    func appleUserID() -> String? { string(for: "appleUserID") }
    func saveAppleUserID(_ id: String) { set(id, for: "appleUserID") }

    /// The session token, unless it is missing or its `exp` claim has passed.
    func validToken(now: Date = .now) -> String? {
        guard let token = read() else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) > now else { return nil }
        return token
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func string(for account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func set(_ value: String, for account: String) {
        remove(account)
        var q = query(account); q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    private func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

struct MarginAPI {
    let baseURL: URL
    /// Nil only for the sign-in call itself.
    let sessionToken: String?
    private let decoder = JSONDecoder()

    init(baseURL: URL, sessionToken: String?) { self.baseURL = baseURL; self.sessionToken = sessionToken }

    /// A client for the signed-in user, or nil when the service isn't configured or nobody is signed in.
    static func signedIn() -> MarginAPI? {
        guard let url = MarginService.baseURL, let token = SessionTokenStore().validToken() else { return nil }
        return MarginAPI(baseURL: url, sessionToken: token)
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, as: T.Type) async throws -> T {
        // Appending (not resolving) keeps a path prefix on the base URL, e.g. https://host/margin/v1/...
        var request = URLRequest(url: baseURL.appending(path: path)); request.httpMethod = method
        if let sessionToken { request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarginAPIError(message: "No response from Margin’s service") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, sessionToken != nil {
                SessionTokenStore().delete()
                throw MarginAPIError(message: "Your session ended. Sign in again in Settings.", status: 401)
            }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MarginAPIError(message: message ?? "Margin’s service returned \(http.statusCode)", status: http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }
}
