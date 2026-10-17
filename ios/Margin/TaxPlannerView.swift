import SwiftUI
import SwiftData

/// Quarterly estimated taxes from the business ledger: what to set aside from each job, what's due when, and
/// whether the tax reserve keeps up. An estimate for planning, not tax advice.
struct TaxPlannerView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @Query private var categories: [BudgetCategory]
    @Query private var settingsList: [FinanceSettings]
    @Query(sort: \EstimatedTaxPayment.date, order: .reverse) private var payments: [EstimatedTaxPayment]
    @Query private var allocations: [NetAllocation]
    /// Set by "Record a payment". The sheet hangs off the Form: a sheet attached inside a Form section never presents.
    @State private var paymentDraft: TaxPaymentDraft?

    var body: some View {
        Form {
            if let settings = FinanceSettings.pick(settingsList) {
                TaxPlanSections(settings: settings, transactions: transactions, categories: categories, payments: payments, allocations: allocations, paymentDraft: $paymentDraft)
            }
        }
        .sheet(item: $paymentDraft) { RecordTaxPaymentView(reserve: $0.reserve, suggestedFederal: $0.federal, suggestedState: $0.state, year: $0.year) }
        .numberPadDone().navigationTitle("Taxes")
        .task { _ = FinanceSettings.current(in: context) }
    }
}

private struct TaxPlanSections: View {
    @Environment(\.modelContext) private var context
    @Bindable var settings: FinanceSettings
    let transactions: [Transaction]; let categories: [BudgetCategory]; let payments: [EstimatedTaxPayment]; let allocations: [NetAllocation]
    @Binding var paymentDraft: TaxPaymentDraft?

    /// The tax year being paid: last year's until its January installment is due, then this year's.
    private var year: Int { EstimatedTax.plannerYear(now: .now) }
    private var reserve: Double { TaxReserve.balance(adjustment: settings.taxReserveAdjustment, allocations: allocations, payments: payments) }
    /// Editing the reserve stores the difference from what the records say.
    private var reserveBinding: Binding<Double> {
        Binding(get: { reserve }, set: { settings.taxReserveAdjustment += $0 - reserve })
    }
    private var yearPayments: [EstimatedTaxPayment] { payments.filter { $0.taxYear == year } }
    private var plan: EstimatedTaxPlan {
        EstimatedTax.plan(report: ScheduleC.report(entries: transactions.map(\.ledgerEntry), year: year), profile: settings.taxProfile,
                          paidFederal: yearPayments.filter { !$0.isState }.reduce(0) { $0 + $1.amount },
                          paidState: yearPayments.filter(\.isState).reduce(0) { $0 + $1.amount }, reserve: reserve, now: .now)
    }
    private var taxLine: BudgetCategory? { categories.first { $0.name.caseInsensitiveCompare(settings.taxLineName) == .orderedSame } }

    var body: some View {
        let plan = plan
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("SET ASIDE FROM EACH JOB").font(.caption.bold()).foregroundStyle(.secondary)
                Text(plan.setAsideRate.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 40, weight: .bold, design: .rounded))
                Text(plan.projectedGross > 0 ? "of every Gross payment covers this year’s estimated tax on the business." : "Record job income to see your rate.").font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
            if let next = plan.next {
                LabeledContent("Q\(next.quarter) due \(next.dueDate.formatted(date: .abbreviated, time: .omitted))", value: (plan.dueNextFederal + plan.dueNextState).money).bold()
                if plan.dueNextState > 0 { Text("\(plan.dueNextFederal.money) to the IRS · \(plan.dueNextState.money) to your state").font(.caption).foregroundStyle(.secondary) }
            }
            Button { paymentDraft = TaxPaymentDraft(reserve: reserve, federal: plan.dueNextFederal, state: plan.dueNextState, year: year) } label: { Label("Record a payment", systemImage: "checkmark.circle") }
        }

        Section {
            LabeledContent("Profit so far", value: plan.ytdProfit.money)
            LabeledContent("Projected for \(String(plan.taxYear))", value: plan.projectedProfit.money)
            LabeledContent("Self-employment tax", value: plan.estimate.selfEmploymentTax.money)
            LabeledContent("Federal income tax from the business", value: plan.estimate.federalIncomeTax.money)
            if plan.estimate.stateTax > 0 { LabeledContent("State tax", value: plan.estimate.stateTax.money) }
            LabeledContent("Estimated payments to make", value: plan.recommendedFederal.money).bold()
            if plan.minimumFederal + 0.5 < plan.recommendedFederal { LabeledContent("Least that avoids a penalty", value: plan.minimumFederal.money) }
        } header: { Text("This year") } footer: { Text("Projects your profit at this year’s pace so far. Paying the estimate leaves little owed in April; the smaller figure only avoids the underpayment penalty.") }

        Section {
            ForEach(plan.installments) { installment in
                let paidThrough = plan.paidFederal + plan.paidState >= plan.installments.filter { $0.quarter <= installment.quarter }.reduce(0) { $0 + $1.federal + $1.state } - 0.5
                HStack {
                    VStack(alignment: .leading) {
                        Text("Q\(installment.quarter) · \(installment.dueDate.formatted(date: .abbreviated, time: .omitted))").font(.subheadline.bold())
                        Text(installment.state > 0 ? "\(installment.federal.money) federal + \(installment.state.money) state" : "Federal").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if paidThrough { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    Text((installment.federal + installment.state).money).bold()
                }
            }
            LabeledContent("Paid so far", value: (plan.paidFederal + plan.paidState).money)
        } header: { Text("Quarterly schedule") }

        Section {
            MoneyField(title: "In the reserve now", value: reserveBinding)
            LabeledContent("Still to set aside this year", value: plan.stillToSave.money)
            LabeledContent("That’s per month", value: plan.monthlyToSave.money).bold()
            if let line = taxLine {
                let gap = plan.monthlyToSave - line.monthlyLimit
                Label(gap > 1 ? "Your \(line.name) line plans \(line.monthlyLimit.money) a month. Raise it by \(gap.money)." : "Your \(line.name) line (\(line.monthlyLimit.money) a month) keeps up.",
                      systemImage: gap > 1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.subheadline).foregroundStyle(gap > 1 ? Color.marginCoral : .green)
                if gap > 1 { Button("Set \(line.name) to \(plan.monthlyToSave.rounded(.up).money)") { line.monthlyLimit = plan.monthlyToSave.rounded(.up); try? context.save() } }
            }
        } header: { Text("Tax reserve") } footer: { Text("Net you assign to taxes and tax set aside from job payments add to the reserve; payments come out of it.") }

        Section {
            Picker("Filing status", selection: $settings.filingStatus) { ForEach(FilingStatus.allCases) { Text($0.title).tag($0.rawValue) } }
            HStack { Text("State income tax rate"); Spacer(); TextField("0", value: $settings.stateTaxRate, format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 70); Text("%") }
            MoneyField(title: "Other household income this year", value: $settings.otherIncome)
            MoneyField(title: "…of which your own W-2 wages", value: $settings.ownWages)
            MoneyField(title: "Federal tax withheld from it", value: $settings.withholding)
            MoneyField(title: "Last year’s total federal tax", value: $settings.priorYearTax)
            Toggle("Last year’s AGI was over $150,000", isOn: $settings.priorYearHighIncome)
            Toggle("Include the 20% QBI deduction", isOn: $settings.includeQBI)
            Picker("Tax reserve budget line", selection: $settings.taxLineName) {
                ForEach(Array(Set(categories.map(\.name) + [settings.taxLineName])).sorted(), id: \.self) { Text($0).tag($0) }
            }
        } header: { Text("About you") } footer: {
            Text("Uses \(String(TaxYearTable.forYear(year).year)) federal brackets and standard deduction, 15.3% self-employment tax (Social Security up to $\(Int(TaxYearTable.forYear(year).socialSecurityWageBase).formatted())), and a flat state rate. QBI phase-outs and credits aren’t modeled. A planning estimate, not tax advice; confirm with your tax preparer.")
        }

        if !yearPayments.isEmpty {
            Section("Payments in \(String(year))") {
                ForEach(yearPayments) { payment in
                    HStack { Text(payment.date.formatted(date: .abbreviated, time: .omitted)); Text(payment.isState ? "State" : "IRS").foregroundStyle(.secondary); Spacer(); Text(payment.amount.moneyExact).bold() }
                }.onDelete { offsets in
                    for payment in offsets.map({ yearPayments[$0] }) {
                        context.delete(payment)
                    }
                    try? context.save()
                }
            }
        }
    }
}

/// What the payment sheet starts from.
struct TaxPaymentDraft: Identifiable {
    let id = UUID()
    let reserve: Double, federal: Double, state: Double, year: Int
}

private struct RecordTaxPaymentView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    let reserve: Double; let suggestedFederal: Double; let suggestedState: Double; let year: Int
    @State private var amount = ""; @State private var date = Date(); @State private var isState = false; @State private var fromReserve = true
    @State private var taxYear = 0

    var body: some View { NavigationStack { Form {
        Section {
            Picker("Paid to", selection: $isState) { Text("IRS").tag(false); Text("State").tag(true) }.pickerStyle(.segmented)
            TextField("Amount", text: $amount).keyboardType(.decimalPad)
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Picker("For tax year", selection: $taxYear) { ForEach([year - 1, year, year + 1], id: \.self) { Text(String($0)).tag($0) } }
            Toggle("Paid from the tax reserve", isOn: $fromReserve)
        } footer: { Text("A January payment is usually the last installment for the year before.") }
        Section { Button("Record payment") { save() }.bold().frame(maxWidth: .infinity).disabled(Double(moneyInput: amount) == nil) }
    }.numberPadDone().navigationTitle("Tax payment")
     .onAppear { taxYear = year; let due = isState ? suggestedState : suggestedFederal; if due > 0 { amount = String(format: "%.2f", due) } }
     .onChange(of: isState) { let due = isState ? suggestedState : suggestedFederal; amount = due > 0 ? String(format: "%.2f", due) : "" }
     .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }

    private func save() {
        guard let value = Double(moneyInput: amount) else { return }
        let used = fromReserve ? min(max(0, reserve), value) : 0
        context.insert(EstimatedTaxPayment(date: date, amount: value, taxYear: taxYear, isState: isState, reserveUsed: used))
        try? context.save(); dismiss()
    }
}
