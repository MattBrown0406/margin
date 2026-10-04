import SwiftUI
import AuthenticationServices
import CryptoKit

private struct SessionResponse: Decodable { let sessionToken: String; let expiresAt: String; let userId: String }
private struct DeletedResponse: Decodable { let deleted: Bool }
private struct SignedOutResponse: Decodable { let signedOut: Bool }

@MainActor final class AccountModel: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published var isWorking = false
    @Published var message: String?
    private let tokens = SessionTokenStore()
    /// The raw nonce for the sign-in in flight; Apple signs its SHA-256 into the identity token.
    private var nonce: String?

    init() { refresh() }
    var serviceConfigured: Bool { MarginService.baseURL != nil }
    func refresh() { isSignedIn = tokens.validToken() != nil }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let raw = Self.randomNonce()
        nonce = raw
        request.requestedScopes = []      // Margin needs no name or email
        request.nonce = Self.sha256(raw)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        defer { nonce = nil }
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let identityToken = String(data: tokenData, encoding: .utf8),
                  let nonce, let url = MarginService.baseURL else { message = "Apple didn’t return a usable sign-in. Try again."; return }
            isWorking = true; defer { isWorking = false }
            // The one-time authorization code lets the service revoke Apple's tokens if the account is deleted.
            var body: [String: Any] = ["identityToken": identityToken, "nonce": nonce]
            if let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) { body["authorizationCode"] = code }
            do {
                let session = try await MarginAPI(baseURL: url, sessionToken: nil)
                    .request("/v1/auth/apple", method: "POST", body: body, as: SessionResponse.self)
                tokens.save(session.sessionToken); tokens.saveAppleUserID(credential.user)
                message = nil
            } catch { message = error.localizedDescription }
            refresh()
        }
    }

    /// Signs out of this device only; other devices stay signed in.
    func signOut() { clearSession() }

    /// Ends every session on the service (best effort), e.g. after losing a device.
    func signOutEverywhere() async {
        if let api = MarginAPI.signedIn() {
            isWorking = true; defer { isWorking = false }
            _ = try? await api.request("/v1/session", method: "DELETE", as: SignedOutResponse.self)
        }
        clearSession()
        message = "Signed out on all your devices."
    }
    private func clearSession() { tokens.delete(); refresh() }

    func deleteAccount() async {
        guard let api = MarginAPI.signedIn() else { clearSession(); message = "Your session ended. Sign in again to delete your account."; return }
        isWorking = true; defer { isWorking = false }
        do {
            _ = try await api.request("/v1/account", method: "DELETE", as: DeletedResponse.self)
            clearSession()
            message = "Your Margin account and bank connections were deleted. Your budget stays on your devices."
        } catch {
            refresh()   // a 401 clears the session; show the signed-out state rather than a dead Delete button
            message = isSignedIn ? error.localizedDescription : "Your session ended. Sign in again to delete your account."
        }
    }

    /// Signs out if the person revoked Margin in Settings › Apple ID › Sign in with Apple.
    func checkAppleCredential() async {
        guard let id = tokens.appleUserID() else { return }
        if let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: id), state == .revoked || state == .notFound { clearSession() }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString + UUID().uuidString }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func sha256(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct AccountView: View {
    @StateObject private var account = AccountModel()
    @AppStorage(MarginStore.iCloudSyncKey) private var iCloudSync = true
    @State private var confirmDelete = false

    private var iCloudStatus: String {
        if !MarginStore.isUsingCloudKit { return iCloudSync ? "Starts next launch" : "Off" }
        return "On when signed in to iCloud"
    }

    var body: some View {
        Form {
            Section {
                if account.isSignedIn {
                    Label("Signed in with Apple", systemImage: "person.crop.circle.badge.checkmark")
                    Button("Sign out") { account.signOut() }.disabled(account.isWorking)
                    Button("Sign out on all devices") { Task { await account.signOutEverywhere() } }.disabled(account.isWorking)
                    Button("Delete account", role: .destructive) { confirmDelete = true }.disabled(account.isWorking)
                } else if account.serviceConfigured {
                    SignInWithAppleButton(.signIn) { account.prepare($0) } onCompletion: { result in Task { await account.complete(result) } }
                        .frame(height: 48).disabled(account.isWorking)
                } else {
                    Text("Margin’s secure service isn’t set up in this build yet, so sign-in is unavailable. Everything else works on your device.").font(.subheadline).foregroundStyle(.secondary)
                }
                if account.isWorking { ProgressView() }
                if let message = account.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            } header: { Text("Account") } footer: {
                Text("Signing in unlocks bank connections and Ask Margin. Your budget itself stays on your devices and in your iCloud.")
            }
            Section {
                Toggle("Sync with iCloud", isOn: $iCloudSync)
                LabeledContent("Status", value: iCloudStatus)
            } header: { Text("Backup & sync") } footer: {
                Text("Keeps your budget backed up and in sync across your iPhone and iPad. Changes take effect the next time you open Margin.")
            }
        }
        .navigationTitle("Settings")
        .task { await account.checkAppleCredential() }
        .confirmationDialog("Delete your Margin account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await account.deleteAccount() } }
        } message: { Text("This disconnects every bank and deletes what Margin’s service stores about you. Your budget on this device isn’t affected.") }
    }
}
