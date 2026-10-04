import SwiftUI
import SwiftData
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

@MainActor final class BankSyncViewModel: ObservableObject {
    @Published var connections: [BankConnectionDTO] = []
    @Published var reviewTransactions: [ImportedBankTransaction] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var linkToken: String?

    private var api: MarginAPI? { MarginAPI.signedIn() }
    var isConfigured: Bool { api != nil }

    /// Set while Plaid Link runs in update mode to repair an existing connection's login.
    private var repairingItemID: String?

    func load() async {
        objectWillChange.send()   // sign-in state may have changed while this screen was hidden
        guard let api else { return }
        await work { self.connections = try await api.request("/v1/plaid/accounts", as: ConnectionsResponse.self).connections }
    }
    func beginLink(repairing connection: BankConnectionDTO? = nil) async {
        guard let api else { errorMessage = "Sign in with Apple in Settings before connecting a bank."; return }
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
    /// The job each review item is tied to. An explicit "Not linked" is stored as `.some(nil)`.
    @State private var reviewJobs: [String: UUID?] = [:]
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
                if MarginService.baseURL == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Secure service setup needed", systemImage: "lock.shield.fill").font(.headline)
                        Text("The app is ready for Plaid, but the MARGIN_API_BASE_URL build setting must point at your HTTPS service before a real bank login can open.").font(.subheadline).foregroundStyle(.secondary)
                    }.marginCard()
                } else if !model.isConfigured {
                    NavigationLink { AccountView() } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Sign in to connect a bank", systemImage: "person.crop.circle.badge.plus").font(.headline)
                            Text("Sign in with Apple in Settings. Your budget stays on your devices; only bank connections use Margin’s service.").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).marginCard()
                    }.buttonStyle(.plain)
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
                            if let match = possibleDuplicate(of: tx) {
                                Label("Possible duplicate of “\(match.title)” on \(match.date.formatted(date: .abbreviated, time: .omitted))", systemImage: "doc.on.doc").font(.caption.bold()).foregroundStyle(.orange)
                            }
                            if tx.amount > 0, ["TRANSFER_OUT", "LOAN_PAYMENTS"].contains(tx.category) {
                                Label("Looks like a transfer or card payment. Skip it if the purchases are already counted.", systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary)
                            }
                            if tx.amount < 0, ["TRANSFER_IN", "LOAN_PAYMENTS"].contains(tx.category) {
                                Label("Looks like a transfer between your own accounts or a card payment. Skip it unless a job paid you.", systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary)
                            }
                            if tx.amount < 0 {
                                Picker("Credit type", selection: Binding(get: { reviewIncomeKind(tx) }, set: { reviewIncomeKinds[tx.id] = $0 })) {
                                    Text("Gross → Business").tag("gross"); Text("Net → Personal").tag("net"); Text("Refund").tag("refund")
                                }.pickerStyle(.segmented)
                                if reviewIncomeKind(tx) == "net", !linkableJobs.isEmpty {
                                    Picker("For job", selection: Binding(get: { netJob(for: tx) }, set: { reviewJobs[tx.id] = .some($0) })) {
                                        Text("Not linked").tag(UUID?.none)
                                        ForEach(linkableJobs) { job in Text("\(job.title) · \(job.date.formatted(date: .abbreviated, time: .omitted))").tag(job.jobID) }
                                    }
                                }
                            }
                            if tx.amount > 0 || reviewIncomeKind(tx) == "refund" {
                                Picker("Ledger", selection: Binding(get: { reviewScope(tx) }, set: { reviewScopes[tx.id] = $0; reviewCategories[tx.id] = nil })) {
                                    Text("Personal").tag("personal"); Text("Business").tag("business")
                                }.pickerStyle(.segmented)
                                Picker("Category", selection: Binding(get: { reviewCategory(tx) }, set: { reviewCategories[tx.id] = $0 })) {
                                    ForEach(categoryOptions(for: reviewScope(tx)), id: \.self) { Text($0).tag($0) }
                                }
                                if reviewScope(tx) == "business", !linkableJobs.isEmpty {
                                    Picker("For job", selection: Binding(get: { reviewJobs[tx.id] ?? nil }, set: { reviewJobs[tx.id] = .some($0) })) {
                                        Text("Not tied to a job").tag(UUID?.none)
                                        ForEach(linkableJobs) { job in Text("\(job.title) · \(job.date.formatted(date: .abbreviated, time: .omitted))").tag(job.jobID) }
                                    }
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
    /// Recent intervention receipts an imported Net transfer can be attached to.
    private var linkableJobs: [Transaction] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        return existing.filter { $0.isIncome && $0.incomeKind == "gross" && $0.jobID != nil && $0.date >= cutoff }.sorted { $0.date > $1.date }
    }
    /// The job an imported Net transfer belongs to: the person's choice, else the recent job still waiting for a
    /// transfer whose Gross arrived closest before it. Leaving it unlinked would count that job's Net twice.
    private func netJob(for tx: ImportedBankTransaction) -> UUID? {
        if let chosen = reviewJobs[tx.id] { return chosen }
        guard let date = ISO8601DateFormatter.marginDate.date(from: tx.date) else { return nil }
        let transferred = Set(existing.filter { $0.isIncome && $0.incomeKind == "net" }.compactMap(\.jobID))
        return linkableJobs.filter { job in job.jobID.map { !transferred.contains($0) } == true && job.date <= date.addingTimeInterval(3 * 86_400) }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.jobID
    }

    /// Plaid ids change when a bank is reconnected, and manual entries have none, so also look for an
    /// existing entry with the same amount within three days.
    private func possibleDuplicate(of tx: ImportedBankTransaction) -> Transaction? {
        guard let date = ISO8601DateFormatter.marginDate.date(from: tx.date) else { return nil }
        return existing.first { $0.externalID != tx.id && abs(abs($0.amount) - abs(tx.amount)) < 0.005 && abs($0.date.timeIntervalSince(date)) <= 3 * 86_400 }
    }
    private var skippedIDs: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(skippedJSON.utf8))) ?? []) }
    private func skip(_ tx: ImportedBankTransaction) {
        if let data = try? JSONEncoder().encode(Array(skippedIDs.union([tx.id])).sorted()), let value = String(data: data, encoding: .utf8) { skippedJSON = value }
    }
    private func importTransaction(_ imported: ImportedBankTransaction) {
        guard !imported.pending, !existing.contains(where: { $0.externalID == imported.id }) else { return }
        let creditKind = imported.amount < 0 ? reviewIncomeKind(imported) : nil
        let date = ISO8601DateFormatter.marginDate.date(from: imported.date) ?? .now
        let tx: Transaction
        if let kind = creditKind, kind != "refund" {
            let jobID = kind == "net" ? (netJob(for: imported) ?? UUID()) : UUID()
            tx = Transaction(title: imported.name, amount: abs(imported.amount), date: date, category: kind == "gross" ? "Intervention income" : "Owner transfer", isIncome: true, ledgerScope: kind == "gross" ? "business" : "personal", incomeKind: kind, jobID: jobID)
        } else {
            // A refund is stored as a negative expense so it reduces spending in its category.
            let scope = reviewScope(imported)
            tx = Transaction(title: imported.name, amount: creditKind == "refund" ? -abs(imported.amount) : imported.amount, date: date, category: reviewCategory(imported), ledgerScope: scope,
                             jobID: scope == "business" ? (reviewJobs[imported.id] ?? nil) : nil)
        }
        tx.externalID = imported.id; tx.externalAccountID = imported.accountId; tx.isPending = false
        context.insert(tx); try? context.save()
    }

    private var accountScopes: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(accountScopesJSON.utf8))) ?? [:]
    }
    /// Plaid account ids change when a bank is reconnected, so the ledger choice is also remembered by mask.
    private func maskKey(_ accountID: String) -> String? {
        model.connections.flatMap(\.accounts).first { $0.id == accountID }.flatMap { $0.mask.isEmpty ? nil : "mask:\($0.mask)" }
    }
    private func accountScope(_ accountID: String) -> String { accountScopes[accountID] ?? maskKey(accountID).flatMap { accountScopes[$0] } ?? "personal" }
    private func setAccountScope(_ accountID: String, _ scope: String) {
        var values = accountScopes; values[accountID] = scope
        if let key = maskKey(accountID) { values[key] = scope }
        if let data = try? JSONEncoder().encode(values), let value = String(data: data, encoding: .utf8) { accountScopesJSON = value }
    }
    private func reviewScope(_ transaction: ImportedBankTransaction) -> String { reviewScopes[transaction.id] ?? accountScope(transaction.accountId) }
    /// Deposits Plaid marks as income or transfers default to Gross/Net by account; any other credit is a refund.
    private func reviewIncomeKind(_ transaction: ImportedBankTransaction) -> String {
        if let chosen = reviewIncomeKinds[transaction.id] { return chosen }
        guard ["INCOME", "TRANSFER_IN"].contains(transaction.category) else { return "refund" }
        return accountScope(transaction.accountId) == "business" ? "gross" : "net"
    }
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
