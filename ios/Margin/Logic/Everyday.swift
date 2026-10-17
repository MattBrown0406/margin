import Foundation

/// A remembered "this merchant goes in that category" choice for one ledger.
struct MerchantRuleInfo: Equatable {
    var key: String
    var scope: String
    var category: String
    var updatedAt: Date
}

enum MerchantRules {
    /// Bank descriptions that name a payment method, not a payee ("CHECK 1001", "Zelle", "ATM WITHDRAWAL"): one
    /// category can't fit everything paid that way, so nothing is learned or suggested for them.
    static let genericWords: Set<String> = ["check", "chk", "venmo", "zelle", "cash", "atm", "withdrawal", "deposit", "transfer", "xfer", "wire", "payment", "online", "mobile", "ach", "debit", "credit"]

    /// The merchant key to learn under, or nil when the title has no usable merchant name.
    static func learnableKey(_ title: String) -> String? {
        let key = RecurringDetector.merchantKey(title)
        guard !key.isEmpty, !key.split(separator: " ").allSatisfy({ genericWords.contains(String($0)) }) else { return nil }
        return key
    }

    /// The category last chosen for this merchant in this ledger, if it's still one of `options`.
    static func category(for title: String, scope: String, rules: [MerchantRuleInfo], options: [String]) -> String? {
        guard let key = learnableKey(title) else { return nil }
        return rules.filter { $0.key == key && $0.scope == scope && options.contains($0.category) }.max { $0.updatedAt < $1.updatedAt }?.category
    }
}

/// How much of a job's Gross to set aside for taxes.
enum TaxSetAside {
    /// Rounded to whole dollars: it's a transfer the person makes by hand.
    static func amount(gross: Double, rate: Double) -> Double { max(0, (gross * min(max(rate, 0), 1)).rounded()) }
}

/// A local notification to schedule.
struct ReminderPlan: Equatable {
    var id: String
    var date: Date
    var title: String
    var body: String
}

enum ReminderSchedule {
    /// Reminders go out at this hour, local time.
    static let hour = 9
    /// How far ahead bill reminders are scheduled (the app reschedules every time it's opened or closed).
    static let horizonDays = 40

    private static func at9(_ day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// - Bills: two days before each due day (a due day past a short month's end is its last day), at 9 AM, for this
    ///   month's unpaid bills and the coming months' within the horizon. Reminders already in the past are skipped.
    /// - Net: if Net is waiting to be assigned, tomorrow at 9 AM.
    /// - Taxes: a week before the next estimated-tax due date, at 9 AM, with what's due.
    /// - Parameters:
    ///   - paidRecently: bills with a payment in the last week; a due date within the next 10 days counts as covered
    ///     (rent due the 1st, paid on the 29th).
    ///   - netArrived: when the newest unassigned Net came in; the reminder is the morning after, or the next 9 AM if
    ///     that's already gone.
    static func plan(bills: [(name: String, dueDay: Int, amount: Double, paidThisMonth: Bool)], paidRecently: Set<String> = [],
                     leftToAssign: Double, netArrived: Date? = nil,
                     nextTaxDue: (date: Date, amount: Double, quarter: Int)?, includeBills: Bool, includeNet: Bool, includeTaxes: Bool,
                     now: Date, calendar: Calendar = .current) -> [ReminderPlan] {
        var plans: [ReminderPlan] = []
        if includeBills, let until = calendar.date(byAdding: .day, value: horizonDays, to: now) {
            var month = calendar.startOfMonth(for: now)
            while month <= until {
                let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
                let isThisMonth = calendar.isSameMonth(month, now)
                for bill in bills where !(isThisMonth && bill.paidThisMonth) {
                    guard let due = calendar.date(byAdding: .day, value: min(max(1, bill.dueDay), days) - 1, to: month),
                          let remindDay = calendar.date(byAdding: .day, value: -2, to: due) else { continue }
                    let fire = at9(remindDay, calendar: calendar)
                    guard fire > now, fire <= until else { continue }
                    if paidRecently.contains(bill.name), let soon = calendar.date(byAdding: .day, value: 10, to: now), due <= soon { continue }
                    plans.append(ReminderPlan(id: "bill|\(bill.name)|\(calendar.monthKey(for: due))", date: fire, title: "\(bill.name) is due \(due.formatted(.dateTime.weekday(.wide)))",
                                              body: "\(bill.amount.money) is planned for it, due the \(calendar.component(.day, from: due).ordinalString)."))
                }
                guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
                month = next
            }
        }
        if includeNet, leftToAssign >= 1, let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            // The morning after the Net arrived; if that's gone, the next 9 AM (today's, if it's still ahead).
            var fire = netArrived.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }.map { at9($0, calendar: calendar) } ?? at9(tomorrow, calendar: calendar)
            if fire <= now { fire = at9(now, calendar: calendar) > now ? at9(now, calendar: calendar) : at9(tomorrow, calendar: calendar) }
            plans.append(ReminderPlan(id: "net", date: fire, title: "\(leftToAssign.money) of Net to assign",
                                      body: "Give it a job before it gets spent: bills first, then taxes and funds."))
        }
        if includeTaxes, let due = nextTaxDue, due.amount >= 1, let weekBefore = calendar.date(byAdding: .day, value: -7, to: due.date) {
            let fire = at9(weekBefore, calendar: calendar)
            if fire > now {
                plans.append(ReminderPlan(id: "tax|\(calendar.monthKey(for: due.date))", date: fire, title: "Q\(due.quarter) estimated tax due \(due.date.formatted(.dateTime.month(.abbreviated).day()))",
                                          body: "About \(due.amount.money) is due. Record the payment in Margin once it's made."))
            }
        }
        return plans.sorted { $0.date < $1.date }
    }
}

/// What each kind of allocation record means.
enum AllocationKinds {
    /// Last month's leftover moved to a fund.
    static let rollover = "rollover"
    /// Tax set aside from a job's Gross; `target` is the job's id. Funds the tax reserve, not taken from Net.
    static let grossTax = "grossTax"
    /// The person chose not to set tax aside from this job's Gross (amount 0), so it isn't offered again.
    static let grossTaxSkipped = "grossTaxSkipped"

    /// Kinds that come out of this month's Net (Assign Net).
    static func isFromNet(_ kind: String) -> Bool { ![rollover, grossTax, grossTaxSkipped].contains(kind) }
    /// Kinds that put money in the tax reserve.
    static func fundsTaxReserve(_ kind: String) -> Bool { kind == AllocationTarget.Kind.tax.rawValue || kind == grossTax }
}
