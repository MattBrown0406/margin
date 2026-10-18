import SwiftUI
import SwiftData

/// Plan › Bills: what's due before the next job pays, and the subscriptions and bills Margin found repeating.
struct RecurringChargesSection: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FinanceSettings]
    let transactions: [Transaction]; let categories: [BudgetCategory]; let bookedJobs: [BookedJob]

    private var settings: FinanceSettings? { FinanceSettings.pick(settingsList) }
    private var recurring: [RecurringCharge] {
        RecurringDetector.detect(entries: transactions.map(\.ledgerEntry), now: .now, ignoredKeys: Set(settings?.ignoredRecurringKeys ?? []))
    }

    var body: some View {
        let recurring = recurring, facts = MoneyFacts(transactions: transactions, categories: categories, bookedJobs: bookedJobs)
        let until = facts.nextIncome ?? Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        let month = transactions.filter { !$0.isIncome && $0.ledgerScope == "personal" && Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) }
        let taxLine = settings?.taxLineName ?? "Tax reserve"
        // Bills only: the tax line and sinking funds are set-asides (Assign Net covers them), not payments that leave.
        let bills = categories.compactMap { c -> (name: String, dueDay: Int, amount: Double, paidThisMonth: Bool)? in
            guard let day = c.dueDay, !c.isFund, c.name.caseInsensitiveCompare(taxLine) != .orderedSame else { return nil }
            return (c.name, day, c.monthlyLimit, month.filter { $0.category == c.name }.reduce(0) { $0 + $1.amount } > 0.005)
        }
        let upcoming = RecurringDetector.upcoming(recurring: recurring, bills: bills, now: .now, until: until)
        let active = recurring.filter { !$0.mayHaveStopped }

        VStack(alignment: .leading, spacing: 12) {
            Text(facts.nextIncome.map { "Due before your next job pays (\($0.formatted(.dateTime.month(.abbreviated).day())))" } ?? "Due in the next 30 days").font(.title3.bold())
            Text("Personal bills and recurring charges.").font(.subheadline).foregroundStyle(.secondary)
            if upcoming.isEmpty { Text("Nothing else is due before then.").font(.subheadline).foregroundStyle(.secondary) }
            else {
                VStack(spacing: 8) {
                    ForEach(upcoming) { item in
                        HStack {
                            Text(item.isOverdue ? "Overdue" : item.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption.bold())
                                .foregroundStyle(item.isOverdue ? Color.marginCoral : .primary).frame(width: 58, alignment: .leading)
                            Text(item.name).font(.subheadline); if !item.isBudgetBill { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                            Spacer(); Text(item.amount.money).font(.subheadline.bold())
                        }
                    }
                    Divider()
                    HStack { Text("Total").bold(); Spacer(); Text(upcoming.reduce(0) { $0 + $1.amount }.money).bold() }
                }.marginCard()
            }

            HStack { Text("Recurring charges").font(.title3.bold()); Spacer(); Text("\(active.reduce(0) { $0 + $1.monthlyCost }.money)/mo").font(.subheadline.bold()) }
            Text("Found in your transactions. Check for ones you no longer use.").font(.subheadline).foregroundStyle(.secondary)
            if recurring.isEmpty { Text("Nothing repeating yet. Bedrock needs a few months of transactions (bank imports help).").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(recurring) { charge in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(charge.name).font(.headline)
                            Text("\(charge.cadence.title) · \(charge.ledgerScope.capitalized) · \(charge.category)\(charge.isFixedAmount ? "" : " · varies")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) { Text(charge.lastAmount.moneyExact).bold(); Text("≈ \(charge.monthlyCost.money)/mo").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let increase = charge.priceIncrease, let previous = charge.previousAmount {
                        Label("Went up \(increase.moneyExact) (was \(previous.moneyExact))", systemImage: "arrow.up.right").font(.caption.bold()).foregroundStyle(Color.marginCoral)
                    }
                    Text(charge.mayHaveStopped ? "No charge since \(charge.lastDate.formatted(date: .abbreviated, time: .omitted)); it may have stopped."
                         : charge.nextDate < Calendar.current.startOfDay(for: .now) ? "Expected around \(charge.nextDate.formatted(date: .abbreviated, time: .omitted)); not charged yet"
                         : "Next around \(charge.nextDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Not recurring") { ignore(charge.key) }.font(.caption.bold()).tint(.marginInk)
                }.marginCard()
            }
        }
        .task { _ = FinanceSettings.current(in: context) }
    }

    private func ignore(_ key: String) {
        let settings = FinanceSettings.current(in: context)
        if !settings.ignoredRecurringKeys.contains(key) { settings.ignoredRecurringKeys.append(key); try? context.save() }
    }
}
