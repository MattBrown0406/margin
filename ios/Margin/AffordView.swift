import SwiftUI

/// The budget summary sent to Ask Margin: totals and category names only, never transactions or merchants.
struct AskContext: Encodable {
    struct Category: Encodable { let name: String; let planned: Double; let spentThisMonth: Double }
    struct Bill: Encodable { let name: String; let amount: Double; let dueDay: Int }
    struct Month: Encodable { let month: String; let receivedNet: Double; let expectedNet: Double; let planned: Double; let gap: Double; let runningTotal: Double }
    struct Reserve: Encodable { let saved: Double; let target: Double }
    struct Purchase: Encodable { let description: String; let amount: Double; let month: String }

    let today: String
    let safeToSpendToday: Double
    let dailyAllowance: Double
    let flexibleLeftThisMonth: Double
    let daysLeftInMonth: Int
    let monthlyPlan: Double
    let flexibleCategories: [Category]
    let bills: [Bill]
    let forecast: [Month]
    let peaceNumber: Reserve?
    let purchase: Purchase
    let verdict: AffordabilityVerdict
}

private struct AskResponse: Decodable { let answer: String }

struct AffordView: View {
    @Environment(\.dismiss) private var dismiss
    let transactions: [Transaction]
    let categories: [BudgetCategory]
    let bookedJobs: [BookedJob]
    let goals: [SavingsGoal]

    @State private var what = ""
    @State private var amount = ""
    @State private var monthOffset = 0
    @State private var answer: String?
    @State private var asking = false
    @State private var askError: String?

    private var now: Date { .now }
    private var targetMonth: Date { Calendar.current.date(byAdding: .month, value: monthOffset, to: Calendar.current.startOfMonth(for: now)) ?? now }
    private var entries: [LedgerEntry] { transactions.map(\.ledgerEntry) }
    private var safe: SafeToSpend { .compute(entries: entries, lines: categories.map(\.planLine), now: now) }
    private var forecast: [ForecastMonth] {
        CashFlowForecast.months(entries: entries, booked: BookedJob.expectedIncome(bookedJobs, entries: entries), plannedMonthly: categories.reduce(0) { $0 + $1.monthlyLimit }, now: now)
    }
    private var verdict: AffordabilityVerdict? {
        Double(moneyInput: amount).map { Affordability.evaluate(amount: $0, in: targetMonth, now: now, safe: safe, forecast: forecast) }
    }

    var body: some View { NavigationStack { Form {
        Section("What is it?") {
            TextField("Flight to Denver, new tires…", text: $what)
            TextField("Amount", text: $amount).keyboardType(.decimalPad)
            Picker("When", selection: $monthOffset) {
                ForEach(0..<6, id: \.self) { offset in
                    Text(offset == 0 ? "This month" : (Calendar.current.date(byAdding: .month, value: offset, to: now) ?? now).formatted(.dateTime.month(.wide).year())).tag(offset)
                }
            }
        }
        if let verdict {
            Section {
                Label(verdict.headline, systemImage: icon(verdict.level)).font(.headline).foregroundStyle(color(verdict.level))
                ForEach(verdict.details, id: \.self) { Text($0).font(.subheadline) }
            } header: { Text("Margin’s answer") } footer: { Text("Based on your flexible budget and the jobs you’ve booked. Your Peace Number is never counted as spendable.") }
            Section {
                if let answer { Text(answer).font(.subheadline) }
                if let askError { Text(askError).font(.subheadline).foregroundStyle(.red) }
                if MarginAPI.signedIn() != nil {
                    Button { Task { await ask(verdict) } } label: { Label(answer == nil ? "Ask Margin for a plan" : "Ask again", systemImage: "sparkles") }.disabled(asking)
                    if asking { ProgressView() }
                } else {
                    NavigationLink("Sign in to get a personal plan") { AccountView() }
                }
            } header: { Text("Ask Margin") } footer: { Text("Sends a summary of your budget totals, never your transactions, to Margin’s assistant.") }
        }
    }.navigationTitle("Can I afford it?")
     .onChange(of: amount) { answer = nil; askError = nil }.onChange(of: monthOffset) { answer = nil; askError = nil }
     .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } } }

    private func icon(_ level: AffordabilityVerdict.Level) -> String { switch level { case .comfortable: "checkmark.circle.fill"; case .tight: "exclamationmark.circle.fill"; case .notYet: "clock.fill" } }
    private func color(_ level: AffordabilityVerdict.Level) -> Color { switch level { case .comfortable: .green; case .tight: .orange; case .notYet: .marginCoral } }

    private func ask(_ verdict: AffordabilityVerdict) async {
        guard let api = MarginAPI.signedIn(), let value = Double(moneyInput: amount) else { return }
        asking = true; askError = nil; defer { asking = false }
        let askedAmount = amount, askedMonth = monthOffset
        let description = String(what.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let monthLabel = monthOffset == 0 ? "this month" : targetMonth.formatted(.dateTime.month(.wide).year())
        let question = "Can I afford \(description.isEmpty ? "this" : description) for \(value.moneyExact) \(monthOffset == 0 ? "this month" : "in \(monthLabel)")?"
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(context(verdict: verdict, description: description.isEmpty ? "Unnamed purchase" : description, amount: value))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let reply = try await api.request("/v1/ask", method: "POST", body: ["question": question, "context": json], as: AskResponse.self).answer
            // Ignore a reply for a purchase the person has since changed.
            guard amount == askedAmount, monthOffset == askedMonth else { return }
            answer = reply
        } catch { if amount == askedAmount, monthOffset == askedMonth { askError = error.localizedDescription } }
    }

    private func context(verdict: AffordabilityVerdict, description: String, amount: Double) -> AskContext {
        let calendar = Calendar.current, iso = Date.ISO8601FormatStyle().year().month().day()
        let monthSpend = entries.filter { $0.isPersonalExpense && calendar.isSameMonth($0.date, now) }
        let goal = goals.first { $0.name.localizedCaseInsensitiveContains("peace") } ?? goals.first
        return AskContext(
            today: now.formatted(iso), safeToSpendToday: safe.safeToday, dailyAllowance: safe.dailyAllowance,
            flexibleLeftThisMonth: safe.flexibleLeft, daysLeftInMonth: safe.daysLeft, monthlyPlan: categories.reduce(0) { $0 + $1.monthlyLimit },
            flexibleCategories: categories.filter(\.isFlexible).sorted { $0.name < $1.name }.map { c in .init(name: c.name, planned: c.monthlyLimit, spentThisMonth: monthSpend.filter { $0.category == c.name }.total) },
            bills: categories.compactMap { c in c.dueDay.map { .init(name: c.name, amount: c.monthlyLimit, dueDay: $0) } }.sorted { $0.dueDay < $1.dueDay },
            forecast: forecast.map { .init(month: $0.monthStart.formatted(.dateTime.year().month(.twoDigits)), receivedNet: $0.receivedNet, expectedNet: $0.expectedNet, planned: $0.planned, gap: $0.gap, runningTotal: $0.cumulative) },
            peaceNumber: goal.map { .init(saved: $0.saved, target: $0.target) },
            purchase: .init(description: description, amount: amount, month: targetMonth.formatted(.dateTime.year().month(.twoDigits))),
            verdict: verdict)
    }
}
