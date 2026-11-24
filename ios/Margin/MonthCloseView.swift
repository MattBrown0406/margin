import SwiftUI
import SwiftData

struct MonthCloseView: View {
    @State private var month = Calendar.current.date(byAdding: .month, value: -1, to: Calendar.current.startOfMonth(for: .now)) ?? .now
    @Query(sort: \ClosedMonth.closedAt, order: .reverse) private var archive: [ClosedMonth]
    @State private var document: MarginXLSXDocument?
    @State private var exporting = false
    @State private var filename = "Stabilis-close"
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                    Spacer(); Text(month.formatted(.dateTime.month(.wide).year())).bold(); Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
                        .disabled(Calendar.current.monthsBetween(month, .now) <= 1)
                }.buttonStyle(.borderless)
            } footer: { Text("Close a completed calendar month against its statements. Draft reviews are saved on this device.") }
            let key = Calendar.current.monthKey(for: month)
            let editions = archive.filter { $0.monthKey == key }
            if !editions.isEmpty {
                Section("Saved accountant copies") {
                    ForEach(editions) { edition in
                        Button {
                            filename = "Stabilis-\(edition.monthKey)-\(edition.id.uuidString.prefix(8))"
                            document = MarginXLSXDocument(data: edition.workbook); exporting = true
                        } label: {
                            Label(edition.closedAt.formatted(date: .abbreviated, time: .standard), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            CloseReview(month: month, revised: !editions.isEmpty).id(key)
            if let exportError { Text(exportError).foregroundStyle(.red) }
        }.navigationTitle("Month-end close").numberPadDone()
        .fileExporter(isPresented: $exporting, document: document, contentType: MarginXLSXDocument.contentType, defaultFilename: filename) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription } else { exportError = nil }
        }
    }

    private func shift(_ months: Int) {
        if let date = Calendar.current.date(byAdding: .month, value: months, to: month) { month = date }
    }
}

private struct CloseDraft: Codable {
    var opening: [String: String] = [:]
    var ending: [String: String] = [:]
    var checked: [String: String] = [:]
}

private struct CloseReview: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query private var categories: [BudgetCategory]
    @AppStorage private var savedDraft: Data
    @State private var scope = CloseLedger.personal
    @State private var error: String?
    @State private var confirm = false
    let month: Date
    let revised: Bool

    init(month: Date, revised: Bool) {
        self.month = month; self.revised = revised
        _savedDraft = AppStorage(wrappedValue: Data(), "margin.closeDraft." + Calendar.current.monthKey(for: month))
    }

    private var draft: CloseDraft { (try? JSONDecoder().decode(CloseDraft.self, from: savedDraft)) ?? CloseDraft() }
    private var rows: [Transaction] { transactions.filter { Calendar.current.isSameMonth($0.date, month) } }
    private func ledgerRows(_ ledger: CloseLedger) -> [Transaction] { rows.filter { ledger.movement($0.ledgerEntry) != nil } }
    private func balance(_ ledger: CloseLedger, draft: CloseDraft) -> CloseBalance? {
        guard let opening = planningNumber(draft.opening[ledger.rawValue] ?? "", signed: true),
              let ending = planningNumber(draft.ending[ledger.rawValue] ?? "", signed: true) else { return nil }
        let movement = rows.compactMap { ledger.movement($0.ledgerEntry) }.reduce(0, +)
        return CloseBalance(opening: opening, ending: ending, movement: movement)
    }
    private func key(_ row: Transaction, _ ledger: CloseLedger) -> String { ledger.rawValue + row.id.uuidString }
    private func fingerprint(_ row: Transaction) -> String {
        "\(row.date.timeIntervalSinceReferenceDate)|\(row.amount)|\(row.ledgerScope)|\(row.isIncome)|\(row.incomeKind ?? "")|\(row.title)"
    }
    private func reviewed(_ row: Transaction, _ ledger: CloseLedger, _ draft: CloseDraft) -> Bool {
        draft.checked[key(row, ledger)] == fingerprint(row)
    }
    private func update(_ edit: (inout CloseDraft) -> Void) {
        var value = draft
        edit(&value)
        do { savedDraft = try JSONEncoder().encode(value) } catch { self.error = error.localizedDescription }
    }
    private func amountField(_ path: WritableKeyPath<CloseDraft, [String: String]>) -> Binding<String> {
        Binding(get: { draft[keyPath: path][scope.rawValue] ?? "" }, set: { text in update { $0[keyPath: path][scope.rawValue] = text } })
    }

    private func statementField(_ title: String, path: WritableKeyPath<CloseDraft, [String: String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            TextField(title, text: amountField(path)).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
        }
    }

    var body: some View {
        let current = draft
        Section {
            Picker("Ledger", selection: $scope) {
                ForEach(CloseLedger.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            statementField("Opening statement balance", path: \.opening)
            statementField("Ending statement balance", path: \.ending)
            if let result = balance(scope, draft: current) {
                LabeledContent("Ending balance from ledger", value: result.expected.moneyExact)
                LabeledContent("Unexplained difference", value: result.difference.moneyExact).bold()
            }
        } header: { Text("Statement balances") } footer: {
            Text("Combine USD accounts for this ledger and subtract card balances owed. Include each owner transfer on both statements. If a ledger has no accounts or activity, enter zero for both balances.")
        }
        Section {
            let entries = ledgerRows(scope)
            if entries.isEmpty { Text("No entries this month.").foregroundStyle(.secondary) }
            ForEach(entries) { row in
                let matched = reviewed(row, scope, current)
                Button {
                    update { $0.checked[key(row, scope)] = matched ? nil : fingerprint(row) }
                } label: {
                    HStack {
                        Image(systemName: matched ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                        }
                        Spacer(); Text((scope.movement(row.ledgerEntry) ?? 0).moneyExact)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("match-\(scope.rawValue)-\(row.id.uuidString)").accessibilityValue(matched ? "Matched" : "Unmatched")
            }
        } header: { Text("Match entries to your statement") } footer: { Text("A missing or incorrect entry can be added or edited in Activity and Add. Return here to review the difference.") }
        Section {
            ForEach(CloseLedger.allCases, id: \.self) { ledger in
                let unmatched = ledgerRows(ledger).filter { !reviewed($0, ledger, current) }.count
                let difference = balance(ledger, draft: current)?.difference
                LabeledContent(ledger.rawValue.capitalized, value: difference.map { "\(unmatched) unmatched · \($0.moneyExact) difference" } ?? "Enter balances")
            }
            Button(revised ? "Save revised accountant copy" : "Close month and save copy") { confirm = true }.disabled(!ready(current))
            if let error { Text(error).foregroundStyle(.red) }
        } footer: { Text("The dated Excel copy preserves the reconciled totals, transactions and budget as they appear at close. Later edits leave each saved edition intact.") }
        .confirmationDialog("Save this reconciled month?", isPresented: $confirm) {
            Button("Save accountant copy") { close() }
        }
    }
    private func ready(_ draft: CloseDraft) -> Bool {
        CloseLedger.allCases.allSatisfy { ledger in
            balance(ledger, draft: draft)?.difference == 0 && ledgerRows(ledger).allSatisfy { reviewed($0, ledger, draft) }
        }
    }
    private func close() {
        let current = draft
        guard ready(current), let personal = balance(.personal, draft: current), let business = balance(.business, draft: current) else { return }
        let now = Date.now
        let bytes = XLSXExporter.makeWorkbook(transactions: transactions, categories: categories, reportMonth: month,
                                             close: .init(date: now, personal: personal, business: business))
        let writer = ModelContext(context.container)
        writer.autosaveEnabled = false
        writer.insert(ClosedMonth(monthKey: Calendar.current.monthKey(for: month), closedAt: now, workbook: bytes))
        do { try writer.save(); error = nil } catch { self.error = error.localizedDescription }
    }
}
