import Foundation

/// A charge that repeats on a schedule: a subscription, a utility, a membership.
struct RecurringCharge: Equatable, Identifiable {
    enum Cadence: String, Equatable, CaseIterable {
        case weekly, biweekly, monthly, quarterly, annual
        /// Typical gap in days and the tolerance either side.
        var days: (typical: Double, tolerance: Double) {
            switch self {
            case .weekly: (7, 1.5); case .biweekly: (14, 2.5); case .monthly: (30.4, 4); case .quarterly: (91, 8); case .annual: (365, 12)
            }
        }
        var perMonth: Double {
            switch self { case .weekly: 52.0 / 12; case .biweekly: 26.0 / 12; case .monthly: 1; case .quarterly: 1.0 / 3; case .annual: 1.0 / 12 }
        }
        var title: String { rawValue.capitalized }
        /// Fewer occurrences are enough to trust a long cadence.
        var minimumCharges: Int { self == .quarterly || self == .annual ? 2 : 3 }
    }

    /// Normalized merchant name; also the key used to dismiss it.
    var id: String { key }
    var key: String
    var name: String
    var ledgerScope: String
    var category: String
    var cadence: Cadence
    var lastDate: Date
    var lastAmount: Double
    var typicalAmount: Double
    var nextDate: Date
    var count: Int
    /// Set when the latest charge is higher than the one before it.
    var previousAmount: Double?
    /// The amount barely varies, so it's likely a subscription rather than a metered bill.
    var isFixedAmount: Bool
    /// Overdue by more than half a cycle: it may have been cancelled.
    var mayHaveStopped: Bool

    var monthlyCost: Double { typicalAmount * cadence.perMonth }
    var priceIncrease: Double? { previousAmount.map { lastAmount - $0 } }
}

/// Something due between now and the next expected income.
struct UpcomingCharge: Equatable, Identifiable {
    var id: String { "\(name)|\(date.timeIntervalSince1970)" }
    var name: String
    var date: Date
    var amount: Double
    var isBudgetBill: Bool
    /// A bill whose due day has passed this month without a payment.
    var isOverdue: Bool = false
}

enum RecurringDetector {
    /// History older than this is ignored.
    static let lookbackDays = 400
    private static let noise: Set<String> = ["pos", "debit", "purchase", "ach", "recurring", "payment", "online", "www", "com", "inc", "llc", "co", "the", "card", "autopay", "bill", "pmt", "sq", "tst", "paypal"]

    /// "NETFLIX.COM 866-579" and "Netflix" share a key; digits, punctuation, and payment noise are dropped.
    static func merchantKey(_ title: String) -> String {
        let letters = String(title.lowercased().map { (c: Character) -> Character in c.isLetter ? c : " " })
        let words = letters.split(separator: " ").map(String.init)
        return words.filter { $0.count > 1 && !noise.contains($0) }.prefix(3).joined(separator: " ")
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func detect(entries: [LedgerEntry], now: Date, ignoredKeys: Set<String> = [], calendar: Calendar = .current) -> [RecurringCharge] {
        let since = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? .distantPast
        let expenses = entries.filter { !$0.isIncome && $0.amount > 0 && $0.date >= since && $0.date <= now }
        var found: [RecurringCharge] = []
        for (key, group) in Dictionary(grouping: expenses, by: { merchantKey($0.title) }) where !key.isEmpty && !ignoredKeys.contains(key) {
            // One charge per day (a same-day split or duplicate isn't a new cycle).
            let byDay: [(day: Date, amount: Double, item: LedgerEntry)] = Dictionary(grouping: group) { calendar.startOfDay(for: $0.date) }
                .map { (day: $0.key, amount: $0.value.total, item: $0.value[0]) }.sorted { $0.day < $1.day }
            guard byDay.count >= 2 else { continue }
            let gaps = zip(byDay, byDay.dropFirst()).map { $1.day.timeIntervalSince($0.day) / 86_400 }
            let gap = median(gaps)
            guard let cadence = RecurringCharge.Cadence.allCases.first(where: { abs(gap - $0.days.typical) <= $0.days.tolerance }),
                  byDay.count >= cadence.minimumCharges,
                  // Most gaps must fit the cadence, so a few random visits to the same shop don't count.
                  Double(gaps.filter { abs($0 - cadence.days.typical) <= cadence.days.tolerance }.count) >= (Double(gaps.count) * 0.75).rounded(.down)
            else { continue }
            let amounts = byDay.map(\.amount), typical = median(amounts)
            guard typical > 0, let last = byDay.last else { continue }
            let previous = byDay.count >= 2 ? byDay[byDay.count - 2].amount : nil
            let next = advance(last.day, by: cadence, calendar: calendar) ?? last.day
            let overdueDays = now.timeIntervalSince(next) / 86_400
            let increased = previous.map { last.amount - $0 > max(1, $0 * 0.02) } ?? false
            found.append(RecurringCharge(key: key, name: last.item.title.trimmingCharacters(in: .whitespacesAndNewlines), ledgerScope: last.item.ledgerScope,
                                         category: last.item.category, cadence: cadence, lastDate: last.day, lastAmount: last.amount, typicalAmount: typical,
                                         nextDate: next, count: byDay.count, previousAmount: increased ? previous : nil,
                                         isFixedAmount: amounts.allSatisfy { abs($0 - typical) <= max(0.5, typical * 0.05) },
                                         mayHaveStopped: overdueDays > cadence.days.typical / 2))
        }
        return found.sorted { $0.monthlyCost > $1.monthlyCost }
    }

    /// The occurrence after `date` for a cadence.
    static func advance(_ date: Date, by cadence: RecurringCharge.Cadence, calendar: Calendar) -> Date? {
        switch cadence {
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly: calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: calendar.date(byAdding: .month, value: 3, to: date)
        case .annual: calendar.date(byAdding: .year, value: 1, to: date)
        }
    }

    /// Everything due from today through `until`:
    /// - plan bills on their due day in each month of the window (this month's only if not paid yet; unpaid ones whose
    ///   day has passed come first, as overdue), a due day past the end of a short month falling on its last day;
    /// - every occurrence of each active personal recurring charge, a charge that's a little late (not stopped) shown today.
    /// A recurring charge in a listed bill's own category (the power company under Utilities) is that bill, so one
    /// such occurrence per listed bill and month is left out rather than counted twice.
    static func upcoming(recurring: [RecurringCharge], bills: [(name: String, dueDay: Int, amount: Double, paidThisMonth: Bool)],
                         now: Date, until: Date, calendar: Calendar = .current) -> [UpcomingCharge] {
        let today = calendar.startOfDay(for: now)
        guard until >= today else { return [] }
        var items: [UpcomingCharge] = [], listedBills: [String: Int] = [:]
        let monthKey: (Date) -> String = { let p = calendar.dateComponents([.year, .month], from: $0); return "\(p.year ?? 0)-\(p.month ?? 0)" }
        var month = calendar.startOfMonth(for: now)
        while month <= until {
            let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
            let isThisMonth = calendar.isSameMonth(month, now)
            for bill in bills where !(bill.paidThisMonth && isThisMonth) {
                guard let due = calendar.date(byAdding: .day, value: min(max(1, bill.dueDay), days) - 1, to: month), due <= until else { continue }
                // Unpaid and already past its day this month: still owed, so it's listed (first) as overdue.
                let overdue = due < today
                guard !overdue || isThisMonth else { continue }
                items.append(UpcomingCharge(name: bill.name, date: overdue ? today : due, amount: bill.amount, isBudgetBill: true, isOverdue: overdue))
                listedBills["\(bill.name.lowercased())|\(monthKey(due))", default: 0] += 1
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        // Business charges come out of the business account, not the money this list is about.
        for charge in recurring where !charge.mayHaveStopped && charge.ledgerScope == "personal" {
            var occurrence: Date? = charge.nextDate, first = true, guardCount = 0
            while let date = occurrence, date <= until, guardCount < 400 {
                guardCount += 1
                let shown: Date? = date >= today ? date : (first ? today : nil)
                first = false
                occurrence = advance(date, by: charge.cadence, calendar: calendar)
                guard let shown else { continue }
                let key = "\(charge.category.lowercased())|\(monthKey(shown))"
                if let count = listedBills[key], count > 0 { listedBills[key] = count - 1; continue }
                items.append(UpcomingCharge(name: charge.name, date: shown, amount: charge.typicalAmount, isBudgetBill: false))
            }
        }
        return items.sorted { ($0.isOverdue ? 0 : 1, $0.date, $0.name) < ($1.isOverdue ? 0 : 1, $1.date, $1.name) }
    }
}
