import SwiftUI
import SwiftData
import Charts

/// Everything owned minus everything owed, with a month-by-month trend. Assets are entered by hand or come from
/// connected bank accounts; debts come from the payoff plan (and connected cards or loans not in it yet).
struct NetWorthView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.createdAt) private var assets: [Asset]
    @Query(sort: \Debt.createdAt) private var debts: [Debt]
    @Query(sort: \NetWorthSnapshot.monthStart) private var snapshots: [NetWorthSnapshot]
    @StateObject private var bank = BankSyncViewModel()
    @State private var editing: Asset?
    @State private var adding = false
    /// Set once the bank balances are known (or there are none to know), so a failed load never writes a snapshot.
    @State private var balancesKnown = false

    private static let assetTypes: Set<String> = ["depository", "investment", "brokerage"]
    private static let debtTypes: Set<String> = ["credit", "loan"]
    private var connectedAccounts: [BankAccountDTO] { bank.connections.flatMap(\.accounts) }
    private var connectedAssets: [BankAccountDTO] { connectedAccounts.filter { Self.assetTypes.contains($0.type) } }
    /// Connected cards and loans the payoff plan doesn't already follow.
    private var connectedDebts: [BankAccountDTO] {
        let linked = Set(debts.compactMap(\.linkedAccountID))
        return connectedAccounts.filter { Self.debtTypes.contains($0.type) && !linked.contains($0.id) }
    }
    private var assetsTotal: Double { assets.reduce(0) { $0 + $1.value } + connectedAssets.reduce(0) { $0 + ($1.currentBalance ?? 0) } }
    private var debtsTotal: Double { debts.reduce(0) { $0 + max(0, $1.balance) } + connectedDebts.reduce(0) { $0 + max(0, $1.currentBalance ?? 0) } }

    var body: some View {
        let assetsTotal = assetsTotal, debtsTotal = debtsTotal
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NET WORTH").font(.caption.bold()).foregroundStyle(.secondary)
                    Text((assetsTotal - debtsTotal).money).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(assetsTotal - debtsTotal < 0 ? Color.marginCoral : .primary)
                    if let change = monthChange { Text("\(change >= 0 ? "Up" : "Down") \(abs(change).money) since \(previousSnapshot?.monthStart.formatted(.dateTime.month(.wide)) ?? "last month")").font(.subheadline).foregroundStyle(change >= 0 ? Color.green : Color.marginCoral) }
                }.padding(.vertical, 4)
                HStack { ReportMetric(label: "OWN", value: assetsTotal); ReportMetric(label: "OWE", value: debtsTotal) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if snapshots.count > 1 {
                Section("Trend") {
                    Chart(snapshots.suffix(24)) { snapshot in
                        LineMark(x: .value("Month", snapshot.monthStart, unit: .month), y: .value("Net worth", snapshot.netWorth))
                        PointMark(x: .value("Month", snapshot.monthStart, unit: .month), y: .value("Net worth", snapshot.netWorth))
                    }.foregroundStyle(Color.marginInk).frame(height: 160)
                }
            }
            Section {
                ForEach(assets) { asset in
                    Button { editing = asset } label: { HStack { Label(asset.name, systemImage: Self.icon(asset.kind)); Spacer(); Text(asset.value.money).bold() } }.buttonStyle(.plain)
                }.onDelete { offsets in offsets.map { assets[$0] }.forEach(context.delete); try? context.save() }
                ForEach(connectedAssets) { account in
                    HStack { Label(account.name, systemImage: "building.columns"); Text("•••• \(account.mask)").font(.caption).foregroundStyle(.secondary); Spacer(); Text((account.currentBalance ?? 0).money).bold() }
                }
                Button { adding = true } label: { Label("Add something you own", systemImage: "plus.circle.fill") }
            } header: { Text("Own") } footer: { Text("Cash, savings, retirement, home, vehicles. Connected bank balances update when this screen opens.") }
            Section {
                ForEach(debts.filter { $0.balance > 0.005 }) { debt in
                    HStack { Label(debt.name, systemImage: debt.kind == "loan" ? "doc.text" : "creditcard"); Spacer(); Text(debt.balance.money).bold() }
                }
                ForEach(connectedDebts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Label(account.name, systemImage: "building.columns"); Spacer(); Text((account.currentBalance ?? 0).money).bold() }
                        let unlinked = debts.filter { $0.linkedAccountID == nil }
                        if unlinked.isEmpty { Button("Add to my payoff plan") { track(account) }.font(.caption.bold()) }
                        else {
                            Menu("Add to my payoff plan") {
                                // A debt already entered by hand: link it instead of counting it twice.
                                ForEach(unlinked) { debt in Button("It’s my \(debt.name)") { link(debt, to: account) } }
                                Button("Add as a new debt") { track(account) }
                            }.font(.caption.bold())
                        }
                    }
                }
                NavigationLink("Debt payoff plan") { DebtPayoffView() }
            } header: { Text("Owe") }
            if let error = bank.errorMessage { Section { Text(error).font(.caption).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Net worth")
        .task {
            await bank.load()
            // Without a working bank connection, connected balances are unknown: show what's known but don't record it
            // (unless nothing here depends on the bank).
            let loaded = bank.isConfigured && bank.errorMessage == nil
            balancesKnown = loaded || (!bank.isConfigured && debts.allSatisfy { $0.linkedAccountID == nil })
            if loaded { followBankBalances() }
            removeDuplicateSnapshots(); recordSnapshot()
        }
        .onChange(of: [assetsTotal, debtsTotal]) { recordSnapshot() }
        .sheet(isPresented: $adding) { AssetEditView(asset: nil) }
        .sheet(item: $editing) { AssetEditView(asset: $0) }
    }

    private var thisMonthKey: String { Calendar.current.monthKey(for: .now) }
    private var currentSnapshot: NetWorthSnapshot? { snapshots.last { $0.monthKey == thisMonthKey } }
    private var previousSnapshot: NetWorthSnapshot? { snapshots.last { $0.monthKey < thisMonthKey } }
    private var monthChange: Double? { previousSnapshot.map { (assetsTotal - debtsTotal) - $0.netWorth } }

    static func icon(_ kind: String) -> String {
        switch kind { case "investment": "chart.line.uptrend.xyaxis"; case "property": "house.fill"; case "vehicle": "car.fill"; case "cash": "banknote.fill"; default: "square.stack.fill" }
    }

    /// Debts that follow a connected account take its latest balance.
    private func followBankBalances() {
        let byID = Dictionary(connectedAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for debt in debts { if let id = debt.linkedAccountID, let balance = byID[id]?.currentBalance, abs(balance - debt.balance) > 0.005 { debt.balance = max(0, balance); changed = true } }
        if changed { try? context.save() }
    }
    private func link(_ debt: Debt, to account: BankAccountDTO) {
        debt.linkedAccountID = account.id
        if let balance = account.currentBalance { debt.balance = max(0, balance) }
        try? context.save()
    }
    private func track(_ account: BankAccountDTO) {
        context.insert(Debt(name: account.name, kind: account.type == "loan" ? "loan" : "card", balance: max(0, account.currentBalance ?? 0), apr: 0, minimumPayment: 0,
                            customRank: (debts.map(\.customRank).max() ?? -1) + 1, linkedAccountID: account.id))
        try? context.save()
    }
    /// Two devices can each start a month's snapshot: keep the most recently updated one per month.
    private func removeDuplicateSnapshots() {
        var changed = false
        for group in Dictionary(grouping: snapshots, by: \.monthKey).values where group.count > 1 {
            group.sorted { $0.updatedAt > $1.updatedAt }.dropFirst().forEach { context.delete($0); changed = true }
        }
        if changed { try? context.save() }
    }
    /// Keeps one snapshot for this month, updated to the latest totals.
    private func recordSnapshot() {
        let owned = assetsTotal, owed = debtsTotal
        guard balancesKnown, owned > 0 || owed > 0 else { return }
        if let snapshot = currentSnapshot {
            guard abs(snapshot.assets - owned) > 0.005 || abs(snapshot.debts - owed) > 0.005 else { return }
            snapshot.assets = owned; snapshot.debts = owed; snapshot.updatedAt = .now
        } else {
            context.insert(NetWorthSnapshot(monthStart: Calendar.current.startOfMonth(for: .now), assets: owned, debts: owed))
        }
        try? context.save()
    }
}

private struct AssetEditView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let asset: Asset?
    @State private var name = ""; @State private var kind = "cash"; @State private var value = ""

    private var amount: Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if Double(trimmed) == 0 { return 0 }
        return Double(moneyInput: trimmed)
    }
    var body: some View { NavigationStack { Form {
        TextField("Name (e.g. Savings, 401(k), Home)", text: $name)
        Picker("Type", selection: $kind) { Text("Cash & savings").tag("cash"); Text("Investments & retirement").tag("investment"); Text("Home or property").tag("property"); Text("Vehicle").tag("vehicle"); Text("Other").tag("other") }
        LabeledContent("Value") { TextField("0", text: $value).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }.navigationTitle(asset == nil ? "Add asset" : asset!.name)
     .onAppear { if let asset { name = asset.name; kind = asset.kind; value = String(format: "%.2f", asset.value) } }
     .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                guard let amount else { return }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if let asset { asset.name = trimmed; asset.kind = kind; asset.value = amount } else { context.insert(Asset(name: trimmed, kind: kind, value: amount)) }
                try? context.save(); dismiss()
            }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || amount == nil)
        }
     } } }
}
