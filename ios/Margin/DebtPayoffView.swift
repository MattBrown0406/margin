import SwiftUI
import SwiftData
import Charts

/// Debt payoff: one fixed monthly amount for debt. Every debt gets its minimum, the rest goes to the debt the chosen
/// strategy puts first, and each paid-off debt's payment rolls into the next one.
struct DebtPayoffView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Debt.createdAt) private var debts: [Debt]
    @Query private var settingsList: [FinanceSettings]

    var body: some View {
        Group {
            if let settings = FinanceSettings.pick(settingsList) { DebtPayoffList(settings: settings, debts: debts) } else { ProgressView() }
        }
        .navigationTitle("Debt payoff")
        .task { _ = FinanceSettings.current(in: context) }
    }
}

/// The month a 1-based plan month falls in (month 1 is this month).
func payoffDate(_ month: Int, from now: Date = .now) -> Date {
    Calendar.current.date(byAdding: .month, value: month - 1, to: Calendar.current.startOfMonth(for: now)) ?? now
}

private struct DebtPayoffList: View {
    @Environment(\.modelContext) private var context
    @Bindable var settings: FinanceSettings
    let debts: [Debt]
    @Query private var categories: [BudgetCategory]
    @State private var editing: Debt?
    @State private var adding = false
    @State private var paying: Debt?
    @State private var showSchedule = false

    static let planLineName = "Debt payments"
    private var active: [Debt] { debts.filter { $0.balance > 0.005 } }
    /// All debts, paid-off ones included: their minimums keep rolling into the debts still owed.
    private var comparison: DebtPayoff.Comparison { DebtPayoff.compare(debts.map(\.info), strategy: settings.strategy, extra: settings.extraDebtPayment) }
    private var ordered: [Debt] {
        let byID = Dictionary(uniqueKeysWithValues: debts.map { ($0.id, $0) })
        return settings.strategy.order(active.map(\.info)).compactMap { byID[$0.id] }
    }
    private var planLine: BudgetCategory? { categories.first { $0.name == Self.planLineName } }

    var body: some View {
        let comparison = comparison, plan = comparison.plan, ordered = ordered
        List {
            if active.isEmpty {
                Section {
                    ContentUnavailableView(debts.isEmpty ? "No debts added" : "Debt free", systemImage: debts.isEmpty ? "creditcard" : "party.popper.fill",
                                           description: Text(debts.isEmpty ? "Add each card and loan with its balance, rate, and minimum payment to see your payoff date." : "Every debt in your plan is paid off."))
                }
            } else {
                summary(comparison)
                Section {
                    Picker("Pay off first", selection: Binding(get: { settings.strategy }, set: { choose($0) })) {
                        ForEach(PayoffStrategy.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.strategy.detail).font(.caption).foregroundStyle(.secondary)
                    MoneyField(title: "Extra each month", value: $settings.extraDebtPayment)
                    LabeledContent("Monthly debt payment", value: plan.monthlyBudget.money).bold()
                } header: { Text("Plan") } footer: { Text("This total stays the same every month. When a debt is paid off, its payment moves to the next debt instead of going back into your budget.") }

                Section {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, debt in
                        let outcome = plan.outcomes.first { $0.id == debt.id }
                        Button { editing = debt } label: { DebtRow(debt: debt, position: index + 1, outcome: outcome, isFocus: plan.months.first?.focus == debt.id) }
                            .buttonStyle(.plain)
                            .swipeActions { Button("Payment") { paying = debt }.tint(.marginInk) }
                    }
                    .onMove(perform: settings.strategy == .custom ? move : nil)
                } header: {
                    HStack { Text("Payoff order"); Spacer(); if settings.strategy == .custom { EditButton().font(.caption.bold()) } }
                } footer: { Text("Tap a debt to edit it; swipe to record a payment. Month 1 is this month.") }

                if !plan.minimumBelowInterest.isEmpty {
                    Section { Label("\(plan.minimumBelowInterest.joined(separator: ", ")): the minimum doesn’t cover the interest, so the balance grows unless extra money reaches it.", systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Color.marginCoral) }
                }
                chart(comparison)
                Section {
                    DisclosureGroup("Month by month", isExpanded: $showSchedule) {
                        ForEach(plan.months.prefix(36), id: \.index) { month in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(payoffDate(month.index).formatted(.dateTime.month(.abbreviated).year())).font(.subheadline.bold())
                                    Text(month.focus.flatMap { id in debts.first { $0.id == id }?.name }.map { "Extra to \($0)" } ?? "Minimums").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) { Text(month.payments.values.reduce(0, +).money).font(.subheadline.bold()); Text("\(month.remainingBalance.money) left").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if plan.months.count > 36 { Text("…and \(plan.months.count - 36) more months.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    if let line = planLine, abs(line.monthlyLimit - plan.monthlyBudget) < 0.5 {
                        Label("Your plan’s \(Self.planLineName) line matches this payment.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(planLine == nil ? "Add \(plan.monthlyBudget.money) to my monthly plan" : "Update my plan’s \(Self.planLineName) to \(plan.monthlyBudget.money)") { putInPlan(plan.monthlyBudget) }
                    }
                } footer: { Text("Keeps your budget and safe-to-spend honest about the money going to debt.") }
            }
            Section { Button { adding = true } label: { Label("Add a debt", systemImage: "plus.circle.fill") } }
            let paidOff = debts.filter { $0.balance <= 0.005 }
            if !paidOff.isEmpty {
                Section {
                    ForEach(paidOff) { debt in
                        Button { editing = debt } label: { HStack { Label(debt.name, systemImage: "checkmark.seal.fill").foregroundStyle(.green); Spacer(); Text("+\(debt.minimumPayment.money)/mo rolling").font(.caption).foregroundStyle(.secondary) } }
                    }
                } header: { Text("Paid off") } footer: { Text("A paid-off debt’s payment keeps going to the debts still owed. Delete it here to stop that.") }
            }
        }
        .sheet(isPresented: $adding) { DebtEditView(debt: nil, nextRank: (debts.map(\.customRank).max() ?? -1) + 1) }
        .sheet(item: $editing) { DebtEditView(debt: $0, nextRank: 0) }
        .sheet(item: $paying) { DebtPaymentView(debt: $0, planLine: planLine) }
    }

    @ViewBuilder private func summary(_ comparison: DebtPayoff.Comparison) -> some View {
        let plan = comparison.plan
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("DEBT FREE").font(.caption.bold()).foregroundStyle(.secondary)
                if let months = plan.monthsToDebtFree {
                    Text(payoffDate(months).formatted(.dateTime.month(.wide).year())).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("\(months) month\(months == 1 ? "" : "s") · \(plan.totalInterest.money) interest · \(active.reduce(0) { $0 + $1.balance }.money) owed today").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Not within 50 years").font(.title.bold()).foregroundStyle(Color.marginCoral)
                    Text("The monthly payment doesn’t outpace the interest. Add an extra amount each month.").font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
            if plan.monthsToDebtFree != nil {
                if let saved = comparison.interestSaved, let months = comparison.monthsSaved {
                    if saved > 0.5 || months > 0 { Label("Saves \(saved.money) in interest and \(months) month\(months == 1 ? "" : "s") versus paying only minimums.", systemImage: "arrow.down.right.circle.fill").font(.subheadline).foregroundStyle(.green) }
                } else {
                    Label("Paying only the minimums would never clear these debts.", systemImage: "arrow.down.right.circle.fill").font(.subheadline).foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder private func chart(_ comparison: DebtPayoff.Comparison) -> some View {
        let horizon = min(max(comparison.plan.months.count, 12) * 2, 360)
        let points = comparison.plan.months.prefix(horizon).map { BalancePoint(series: "This plan", month: $0.index, balance: $0.remainingBalance) }
            + comparison.minimumsOnly.months.prefix(horizon).map { BalancePoint(series: "Minimums only", month: $0.index, balance: $0.remainingBalance) }
        if points.count > 1 {
            Section("Balance over time") {
                Chart(points) { point in
                    LineMark(x: .value("Month", point.month), y: .value("Owed", point.balance)).foregroundStyle(by: .value("Plan", point.series))
                }
                .chartForegroundStyleScale(["This plan": Color.marginInk, "Minimums only": Color.marginCoral])
                .chartXAxisLabel("Months").frame(height: 180)
            }
        }
    }

    private func choose(_ strategy: PayoffStrategy) {
        // Starting a custom order from the order on screen, so nothing jumps.
        if strategy == .custom, settings.strategy != .custom { for (index, debt) in ordered.enumerated() { debt.customRank = index } }
        settings.debtStrategy = strategy.rawValue
        try? context.save()
    }
    private func move(from source: IndexSet, to destination: Int) {
        var list = ordered; list.move(fromOffsets: source, toOffset: destination)
        for (index, debt) in list.enumerated() { debt.customRank = index }
        try? context.save()
    }
    private func putInPlan(_ amount: Double) {
        if let line = planLine { line.monthlyLimit = amount }
        else { context.insert(BudgetCategory(name: Self.planLineName, icon: "creditcard.fill", monthlyLimit: amount, colorHex: "6D597A", isFlexible: false, groupName: "Debt")) }
        try? context.save()
    }
}

private struct BalancePoint: Identifiable {
    var series: String; var month: Int; var balance: Double
    var id: String { "\(series)-\(month)" }
}

private struct DebtRow: View {
    let debt: Debt; let position: Int; let outcome: DebtPayoffPlan.Outcome?; let isFocus: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(position)").font(.caption.bold()).frame(width: 24, height: 24).background(isFocus ? Color.marginLime : Color.black.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(debt.name).font(.subheadline.bold())
                Text("\(debt.apr.formatted(.number.precision(.fractionLength(0...2))))% · \(debt.minimumPayment.money) minimum\(debt.linkedAccountID != nil ? " · follows bank" : "")").font(.caption).foregroundStyle(.secondary)
                if let outcome {
                    Text(outcome.payoffMonth.map { "Paid off \(payoffDate($0).formatted(.dateTime.month(.abbreviated).year())) · \(outcome.interestPaid.money) interest" } ?? "Not paid off within 50 years")
                        .font(.caption).foregroundStyle(outcome.payoffMonth == nil ? Color.marginCoral : .secondary)
                }
                if isFocus { Text("Getting the extra money now").font(.caption2.bold()).foregroundStyle(.green) }
            }
            Spacer()
            Text(debt.balance.money).font(.subheadline.bold())
        }.contentShape(Rectangle())
    }
}

private struct DebtEditView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let debt: Debt?; let nextRank: Int
    @State private var name = ""; @State private var kind = "card"; @State private var balance = ""; @State private var apr = ""; @State private var minimum = ""
    @State private var confirmDelete = false

    /// A balance may be 0 (paid off); a rate is 0–100%; a minimum may be 0.
    private func amountOrZero(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || Double(trimmed) == 0 { return 0 }
        return Double(moneyInput: trimmed)
    }
    private var rate: Double? { let t = apr.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""); return t.isEmpty ? 0 : Double(t).flatMap { (0...100).contains($0) ? $0 : nil } }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && amountOrZero(balance) != nil && rate != nil && amountOrZero(minimum) != nil }

    var body: some View { NavigationStack { Form {
        Section {
            TextField("Name (e.g. Chase Visa)", text: $name)
            Picker("Type", selection: $kind) { Text("Credit card").tag("card"); Text("Loan").tag("loan"); Text("Other").tag("other") }
            LabeledContent("Balance") { TextField("0", text: $balance).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Interest rate (APR %)") { TextField("0", text: $apr).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Minimum payment") { TextField("0", text: $minimum).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
        } footer: { Text("Find these on your latest statement. Use the purchase APR for cards.") }
        if debt != nil { Section { Button("Delete debt", role: .destructive) { confirmDelete = true } } }
    }.navigationTitle(debt == nil ? "Add debt" : "Edit debt")
     .onAppear {
        guard let debt else { return }
        name = debt.name; kind = debt.kind; balance = String(format: "%.2f", debt.balance)
        apr = debt.apr.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)); minimum = String(format: "%.2f", debt.minimumPayment)
     }
     .confirmationDialog("Delete \(debt?.name ?? "debt")?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { if let debt { context.delete(debt); try? context.save() }; dismiss() }
     }
     .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
     } } }

    private func save() {
        guard let balanceValue = amountOrZero(balance), let rateValue = rate, let minimumValue = amountOrZero(minimum) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let debt { debt.name = trimmed; debt.kind = kind; debt.balance = balanceValue; debt.apr = rateValue; debt.minimumPayment = minimumValue }
        else { context.insert(Debt(name: trimmed, kind: kind, balance: balanceValue, apr: rateValue, minimumPayment: minimumValue, customRank: nextRank)) }
        try? context.save(); dismiss()
    }
}

private struct DebtPaymentView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let debt: Debt; let planLine: BudgetCategory?
    @State private var amount = ""; @State private var date = Date(); @State private var recordExpense = true

    var body: some View { NavigationStack { Form {
        Section {
            LabeledContent("Balance", value: debt.balance.moneyExact)
            TextField("Payment amount", text: $amount).keyboardType(.decimalPad)
            DatePicker("Date", selection: $date, displayedComponents: .date)
            if let planLine { Toggle("Also log it under \(planLine.name)", isOn: $recordExpense) }
        } footer: { Text("Lowers the balance by the payment. If interest was charged, edit the balance to match your statement instead.") }
        Section { Button("Record payment") { save() }.bold().frame(maxWidth: .infinity).disabled(Double(moneyInput: amount) == nil) }
    }.navigationTitle(debt.name)
     .onAppear { amount = String(format: "%.2f", min(debt.balance, debt.minimumPayment)) }
     .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }

    private func save() {
        guard let value = Double(moneyInput: amount) else { return }
        debt.balance = max(0, ((debt.balance - value) * 100).rounded() / 100)
        if recordExpense, let planLine { context.insert(Transaction(title: "Payment: \(debt.name)", amount: value, date: date, category: planLine.name, ledgerScope: "personal")) }
        try? context.save(); dismiss()
    }
}
