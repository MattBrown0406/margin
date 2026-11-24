import SwiftUI

struct SpendingExplanationView: View {
    let transactions: [Transaction]
    let categories: [BudgetCategory]

    var body: some View {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroup)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        let previous = [WidgetSnapshot.load(from: defaults), WidgetSnapshot.previous(from: defaults)]
            .compactMap { $0 }.first { Calendar.current.isDate($0.day, inSameDayAs: yesterday) }
        let change = SpendingChange.explain(entries: transactions.map(\.ledgerEntry), lines: categories.map(\.planLine), previous: previous, now: .now)
        List {
            Section {
                LabeledContent("Yesterday", value: change.yesterday.moneyExact)
                ForEach(change.steps) { step in
                    LabeledContent(step.label, value: (step.amount > 0 ? "+" : "") + step.amount.moneyExact)
                }
                if change.steps.isEmpty { Text("Your daily amount is unchanged.").foregroundStyle(.secondary) }
                LabeledContent("Today", value: change.today.moneyExact).bold()
            } header: { Text("Change since yesterday") } footer: {
                Text(change.observed ? "Yesterday uses the last amount recorded on this device. Each line shows its effect on today’s available amount."
                     : "Yesterday is an estimate using your current plan and dated entries. Budget edits before this device recorded a daily amount cannot be measured.")
            }
        }.navigationTitle("Safe to Spend")
    }
}

struct PaymentDelayView: View {
    let jobs: [BookedJobInfo]
    let followingMonthJobs: [BookedJobInfo]
    let entries: [LedgerEntry]
    let lines: [PlanLine]
    let taxLine: String
    let ignoredMerchants: Set<String>
    @State private var selection: UUID?
    @State private var weeks = 2
    @State private var cash = ""

    var body: some View {
        Form {
            if jobs.isEmpty {
                ContentUnavailableView("No expected payments", systemImage: "calendar", description: Text("Book a job with expected personal Net in Forecast to test a delay."))
            } else {
                let job = jobs.first { $0.id == selection } ?? jobs[0]
                Section("Payment") {
                    Picker("Job", selection: Binding(get: { job.id }, set: { selection = $0 })) {
                        ForEach(jobs) { Text($0.title).tag($0.id) }
                    }
                    LabeledContent("Expected personal Net", value: job.expectedNet.moneyExact)
                    Picker("Delay", selection: $weeks) { Text("2 weeks").tag(2); Text("4 weeks").tag(4) }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cash available for bills today").font(.subheadline)
                        TextField("USD", text: $cash).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Cash available for bills today")
                    }
                }
                if let opening = planningNumber(cash, signed: true) {
                    result(job: job, cash: opening)
                } else { Text("Enter the cash already available for bills. Enter 0 to start with an empty account.").font(.footnote) }
            }
        }.numberPadDone().navigationTitle("Late payment test")
    }

    @ViewBuilder private func result(job: BookedJobInfo, cash: Double) -> some View {
        let calendar = Calendar.current, now = Date.now
        let today = calendar.startOfDay(for: now)
        let original = max(today, calendar.startOfDay(for: job.expectedDate))
        let delayed = calendar.date(byAdding: .day, value: 7 * weeks, to: original) ?? original
        let threshold = calendar.endOfDay(for: now)
        let spent = entries.personalSpendingThisMonth(through: now, calendar: calendar)
        let bills = lines.compactMap { line -> (name: String, dueDay: Int, amount: Double, paidThisMonth: Bool)? in
            guard let due = line.dueDay, !line.isFund, line.name.caseInsensitiveCompare(taxLine) != .orderedSame else { return nil }
            let paid = spent[line.name, default: 0]
            return (line.name, due, line.monthlyLimit, paid >= line.monthlyLimit - 0.005)
        }
        let recurring = RecurringDetector.detect(entries: entries, now: now, ignoredKeys: ignoredMerchants)
        let charges = RecurringDetector.upcoming(recurring: recurring, bills: bills, now: now, until: delayed).map { charge in
            var bill = charge
            if bill.isBudgetBill && calendar.isSameMonth(bill.date, now) {
                bill.amount = max(0, bill.amount - max(0, spent[bill.name, default: 0]))
            }
            return bill
        }
        let scheduled = entries.filter { $0.isNet && $0.date >= threshold }.map { (date: $0.date, amount: $0.amount) }
        let other = (jobs + followingMonthJobs).filter { $0.id != job.id }.map { (date: $0.expectedDate, amount: $0.expectedNet) } + scheduled
        let baseline = PaymentDelay.coverage(cash: cash, incomes: other + [(original, job.expectedNet)], bills: charges, now: now, through: delayed)
        let scenario = PaymentDelay.coverage(cash: cash, incomes: other + [(delayed, job.expectedNet)], bills: charges, now: now, through: delayed)
        Section("If the payment is late") {
            LabeledContent("On time", value: original.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Delayed until", value: delayed.formatted(date: .abbreviated, time: .omitted))
            if let bill = scenario.firstUncovered {
                LabeledContent("First bill at risk", value: bill.name)
                LabeledContent("Due", value: bill.date.formatted(date: .abbreviated, time: .omitted))
            } else { Text("All projected bills are covered through the delayed payment date.") }
            LabeledContent("Extra cash needed on time", value: baseline.buffer.moneyExact)
            LabeledContent("Extra cash needed with delay", value: scenario.buffer.moneyExact).bold()
        }
        Section { Text("Uses personal bills and detected recurring charges through the delayed date. Expected Net arrives before bills on the same day. Overdue income is assumed to arrive today in the on-time case. Everyday purchases are excluded. Your booking stays at its original date.").font(.footnote) }
    }
}
