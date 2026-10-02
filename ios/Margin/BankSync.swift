import SwiftUI
import SwiftData
import Security
#if canImport(LinkKit)
import LinkKit
#endif

struct BankAccountDTO: Codable, Identifiable {
    let id: String
    let name: String
    let officialName: String?
    let type: String
    let subtype: String?
    let mask: String
    let currentBalance: Double?
    let availableBalance: Double?
    let currency: String
}
struct BankConnectionDTO: Codable, Identifiable {
    var id: String { itemId }
    let itemId: String
    let institutionName: String
    let accounts: [BankAccountDTO]
    let linkedAt: String
    let lastSyncedAt: String?
    let requiresAttention: Bool
}
struct ImportedBankTransaction: Codable, Identifiable {
    let id: String
    let accountId: String
    let name: String
    let amount: Double
    let date: String
    let pending: Bool
    let category: String
}
private struct ConnectionsResponse: Codable { let connections: [BankConnectionDTO] }
private struct LinkTokenResponse: Codable { let linkToken: String; let expiration: String }
private struct ExchangeResponse: Codable { let itemId: String; let institutionName: String; let accounts: [BankAccountDTO] }
private struct SyncResponse: Codable { let added: Int; let modified: Int; let removed: Int; let transactions: [ImportedBankTransaction] }

struct BankAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SessionTokenStore {
    private let service = "com.mattbrown.margin.api"
    func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session", kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
        SecItemDelete(base as CFDictionary)
        var value = base; value[kSecValueData as String] = Data(token.utf8); value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(value as CFDictionary, nil)
    }
}

struct BankAPI {
    let baseURL: URL
    let sessionToken: String
    private let decoder = JSONDecoder()

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, as: T.Type) async throws -> T {
        // Appending (not resolving) keeps a path prefix on the base URL, e.g. https://host/margin/v1/...
        var request = URLRequest(url: baseURL.appending(path: path)); request.httpMethod = method
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BankAPIError(message: "No response from bank service") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw BankAPIError(message: message ?? "Bank service returned \(http.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }
}

@MainActor final class BankSyncViewModel: ObservableObject {
    @Published var connections: [BankConnectionDTO] = []
    @Published var reviewTransactions: [ImportedBankTransaction] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var linkToken: String?

    private let tokenStore = SessionTokenStore()
    private var api: BankAPI? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MARGIN_API_BASE_URL") as? String,
              value != "https://api.example.com", let url = URL(string: value), let token = tokenStore.read() else { return nil }
        return BankAPI(baseURL: url, sessionToken: token)
    }
    var isConfigured: Bool { api != nil }

    /// Set while Plaid Link runs in update mode to repair an existing connection's login.
    private var repairingItemID: String?

    func load() async {
        guard let api else { return }
        await work { self.connections = try await api.request("/v1/plaid/accounts", as: ConnectionsResponse.self).connections }
    }
    func beginLink(repairing connection: BankConnectionDTO? = nil) async {
        guard let api else { errorMessage = "Secure bank service setup is required before connecting a real account."; return }
        repairingItemID = connection?.itemId
        let body: [String: Any] = connection.map { ["itemId": $0.itemId] } ?? [:]
        await work { self.linkToken = try await api.request("/v1/plaid/link-token", method: "POST", body: body, as: LinkTokenResponse.self).linkToken }
    }
    func cancelLink() { linkToken = nil; repairingItemID = nil }
    /// Called when Plaid Link succeeds. Update mode repairs an existing Item, so there is nothing to exchange.
    func completeLink(publicToken: String, institutionName: String) async {
        linkToken = nil
        if let itemID = repairingItemID, let connection = connections.first(where: { $0.itemId == itemID }) { repairingItemID = nil; await sync(connection); return }
        repairingItemID = nil
        guard let api else { return }
        await work {
            _ = try await api.request("/v1/plaid/exchange", method: "POST", body: ["publicToken": publicToken, "institutionName": institutionName], as: ExchangeResponse.self)
            self.connections = try await api.request("/v1/plaid/accounts", as: ConnectionsResponse.self).connections
        }
    }
    func sync(_ connection: BankConnectionDTO) async {
        guard let api else { return }
        await work {
            let synced = try await api.request("/v1/plaid/sync", method: "POST", body: ["itemId": connection.itemId], as: SyncResponse.self).transactions
            // Keep other connections' items waiting in review; replace only this connection's.
            let accountIDs = Set(connection.accounts.map(\.id)).union(synced.map(\.accountId))
            self.reviewTransactions = self.reviewTransactions.filter { !accountIDs.contains($0.accountId) } + synced
        }
        // Refresh either way: balances change after a sync, and a failed sync may have flagged the login.
        if let fresh = try? await api.request("/v1/plaid/accounts", as: ConnectionsResponse.self).connections { connections = fresh }
    }
    func disconnect(_ connection: BankConnectionDTO) async {
        guard let api else { return }
        struct Result: Codable { let disconnected: Bool }
        await work {
            _ = try await api.request("/v1/plaid/connections/\(connection.itemId)", method: "DELETE", as: Result.self)
            let accountIDs = Set(connection.accounts.map(\.id))
            self.connections.removeAll { $0.id == connection.id }; self.reviewTransactions.removeAll { accountIDs.contains($0.accountId) }
        }
    }
    private func work(_ action: @escaping () async throws -> Void) async {
        isWorking = true; errorMessage = nil
        do { try await action() } catch { errorMessage = error.localizedDescription }
        isWorking = false
    }
}

struct BankAccountsView: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @Query private var existing: [Transaction]
    @StateObject private var model = BankSyncViewModel()
    @Query private var categories: [BudgetCategory]
    @AppStorage("margin.bankAccountScopes") private var accountScopesJSON = "{}"
    @AppStorage("margin.bankSkippedTransactionIDs") private var skippedJSON = "[]"
    @State private var reviewScopes: [String: String] = [:]
    @State private var reviewIncomeKinds: [String: String] = [:]
    @State private var reviewCategories: [String: String] = [:]
    @State private var pendingDisconnect: BankConnectionDTO?

    /// Only transactions that still need a decision: not yet imported and not skipped.
    private var awaitingReview: [ImportedBankTransaction] {
        let imported = Set(existing.compactMap(\.externalID)), skipped = skippedIDs
        return model.reviewTransactions.filter { !imported.contains($0.id) && !skipped.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bank accounts").font(.largeTitle.bold())
                Text("Read-only connections. Margin never receives your bank password and cannot move money.").foregroundStyle(.secondary)
                if !model.isConfigured {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Secure service setup needed", systemImage: "lock.shield.fill").font(.headline)
                        Text("The app is ready for Plaid, but its HTTPS API URL and signed user session must be configured before a real Bank of America login can open.").font(.subheadline).foregroundStyle(.secondary)
                    }.marginCard()
                }
                ForEach(model.connections) { connection in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Image(systemName: "building.columns.fill"); Text(connection.institutionName).font(.headline); Spacer(); Menu { Button("Disconnect", role: .destructive) { pendingDisconnect = connection } } label: { Image(systemName: "ellipsis") } }
                        if connection.requiresAttention {
                            HStack { Label("Bank login needs attention", systemImage: "exclamationmark.triangle.fill").font(.subheadline.bold()).foregroundStyle(.orange); Spacer(); Button("Reconnect") { Task { await model.beginLink(repairing: connection) } }.buttonStyle(.bordered).disabled(model.isWorking) }
                        }
                        ForEach(connection.accounts) { account in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { VStack(alignment: .leading) { Text(account.name).bold(); Text("•••• \(account.mask) · \(account.subtype ?? account.type)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text((account.currentBalance ?? 0).money).bold() }
                                Picker("Ledger", selection: Binding(get: { accountScope(account.id) }, set: { setAccountScope(account.id, $0) })) {
                                    Text("Personal").tag("personal"); Text("Business").tag("business")
                                }.pickerStyle(.segmented)
                            }
                        }
                        Button { Task { await model.sync(connection) } } label: { Label("Sync transactions", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.marginInk).disabled(model.isWorking)
                    }.marginCard()
                }
                Button { Task { await model.beginLink() } } label: { Label(model.connections.isEmpty ? "Connect Bank of America" : "Connect another account", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.marginInk).disabled(model.isWorking || !model.isConfigured)

                if !awaitingReview.isEmpty {
                    Text("Review before importing").font(.title2.bold())
                    Text("Pending transactions stay out of your budget until they post.").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(awaitingReview) { tx in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                VStack(alignment: .leading) { Text(tx.name).bold(); Text("\(tx.date)\(tx.pending ? " · Pending" : "")").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Text((tx.amount < 0 ? "+" : "") + abs(tx.amount).moneyExact).bold()
                            }
                            if tx.amount < 0 {
                                Picker("Income type", selection: Binding(get: { reviewIncomeKind(tx) }, set: { reviewIncomeKinds[tx.id] = $0 })) {
                                    Text("Gross → Business").tag("gross"); Text("Net → Personal").tag("net")
                                }.pickerStyle(.segmented)
                            } else {
                                Picker("Ledger", selection: Binding(get: { reviewScope(tx) }, set: { reviewScopes[tx.id] = $0; reviewCategories[tx.id] = nil })) {
                                    Text("Personal").tag("personal"); Text("Business").tag("business")
                                }.pickerStyle(.segmented)
                                Picker("Category", selection: Binding(get: { reviewCategory(tx) }, set: { reviewCategories[tx.id] = $0 })) {
                                    ForEach(categoryOptions(for: reviewScope(tx)), id: \.self) { Text($0).tag($0) }
                                }
                            }
                            HStack {
                                Button("Skip") { skip(tx) }.buttonStyle(.bordered)
                                Spacer()
                                Button("Import") { importTransaction(tx) }.buttonStyle(.borderedProminent).tint(.marginInk).disabled(tx.pending)
                            }
                        }.marginCard()
                    }
                }
                if let error = model.errorMessage { Text(error).font(.subheadline).foregroundStyle(.red).marginCard() }
                if model.isWorking { ProgressView().frame(maxWidth: .infinity) }
            }.padding()
        }.background(Color.marginCream.ignoresSafeArea()).task { await model.load() }
        #if canImport(LinkKit)
        .sheet(isPresented: Binding(get: { model.linkToken != nil }, set: { if !$0 { model.cancelLink() } })) {
            if let token = model.linkToken { PlaidLinkPresenter(linkToken: token) { publicToken, institution in Task { await model.completeLink(publicToken: publicToken, institutionName: institution) } } onExit: { message in model.cancelLink(); if let message { model.errorMessage = message } } }
        }
        #endif
        .confirmationDialog("Disconnect \(pendingDisconnect?.institutionName ?? "bank")?", isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { if let connection = pendingDisconnect { Task { await model.disconnect(connection) } } }
        } message: { Text("Margin stops syncing this bank. Transactions you already imported stay in your ledger.") }
    }

    private func categoryOptions(for scope: String) -> [String] {
        scope == "business" ? businessCategoryNames : categories.sorted { ($0.groupName, $0.name) < ($1.groupName, $1.name) }.map(\.name)
    }
    /// Maps Plaid's primary category onto one of the user's categories for the chosen ledger.
    private func suggestedCategory(_ plaidCategory: String, scope: String) -> String {
        let options = categoryOptions(for: scope)
        let guess: String
        if scope == "business" {
            switch plaidCategory { case "TRAVEL", "TRANSPORTATION": guess = "Travel"; case "FOOD_AND_DRINK": guess = "Meals"; case "GENERAL_SERVICES": guess = "Professional fees"; default: guess = "Other business" }
        } else {
            switch plaidCategory { case "FOOD_AND_DRINK": guess = "Groceries"; case "TRANSPORTATION": guess = "Fuel"; case "RENT_AND_UTILITIES": guess = "Utilities"; case "MEDICAL": guess = "Health"; case "ENTERTAINMENT": guess = "Fun money"; default: guess = "Personal" }
        }
        return options.contains(guess) ? guess : (options.first ?? guess)
    }
    private func reviewCategory(_ tx: ImportedBankTransaction) -> String {
        let scope = reviewScope(tx)
        if let chosen = reviewCategories[tx.id], categoryOptions(for: scope).contains(chosen) { return chosen }
        return suggestedCategory(tx.category, scope: scope)
    }
    private var skippedIDs: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(skippedJSON.utf8))) ?? []) }
    private func skip(_ tx: ImportedBankTransaction) {
        if let data = try? JSONEncoder().encode(Array(skippedIDs.union([tx.id])).sorted()), let value = String(data: data, encoding: .utf8) { skippedJSON = value }
    }
    private func importTransaction(_ imported: ImportedBankTransaction) {
        guard !imported.pending, !existing.contains(where: { $0.externalID == imported.id }) else { return }
        let isIncome = imported.amount < 0
        let kind = isIncome ? reviewIncomeKind(imported) : nil
        let scope = isIncome ? (kind == "gross" ? "business" : "personal") : reviewScope(imported)
        let category = isIncome ? (kind == "gross" ? "Intervention income" : "Owner transfer") : reviewCategory(imported)
        let tx = Transaction(title: imported.name, amount: abs(imported.amount), date: ISO8601DateFormatter.marginDate.date(from: imported.date) ?? .now, category: category, isIncome: isIncome, ledgerScope: scope, incomeKind: kind, jobID: isIncome ? UUID() : nil)
        tx.externalID = imported.id; tx.externalAccountID = imported.accountId; tx.isPending = false
        context.insert(tx); try? context.save()
    }

    private var accountScopes: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(accountScopesJSON.utf8))) ?? [:]
    }
    private func accountScope(_ accountID: String) -> String { accountScopes[accountID] ?? "personal" }
    private func setAccountScope(_ accountID: String, _ scope: String) {
        var values = accountScopes; values[accountID] = scope
        if let data = try? JSONEncoder().encode(values), let value = String(data: data, encoding: .utf8) { accountScopesJSON = value }
    }
    private func reviewScope(_ transaction: ImportedBankTransaction) -> String { reviewScopes[transaction.id] ?? accountScope(transaction.accountId) }
    private func reviewIncomeKind(_ transaction: ImportedBankTransaction) -> String { reviewIncomeKinds[transaction.id] ?? (accountScope(transaction.accountId) == "business" ? "gross" : "net") }
}

extension ISO8601DateFormatter {
    static let marginDate: DateFormatter = { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter }()
}

#if canImport(LinkKit)
struct PlaidLinkPresenter: UIViewControllerRepresentable {
    let linkToken: String
    let onSuccess: (String, String) -> Void
    let onExit: (String?) -> Void
    final class Coordinator { var session: PlaidLinkSession? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        DispatchQueue.main.async {
            let configuration = LinkTokenConfiguration(
                token: linkToken,
                onSuccess: { success in onSuccess(success.publicToken, success.metadata.institution.name) },
                onExit: { exit in onExit(exit.error?.localizedDescription) },
                onEvent: { _ in },
                onLoad: {}
            )
            do {
                let session = try Plaid.createPlaidLinkSession(configuration: configuration)
                context.coordinator.session = session
                session.open(using: .viewController(controller))
            } catch { onExit(error.localizedDescription) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif
