import Foundation

/// Signed statement balances and nonnegative planning inputs also accept an explicit zero.
func planningNumber(_ text: String, signed: Bool = false) -> Double? {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = signed && (raw.hasPrefix("-") || raw.hasPrefix("−"))
    let digits = negative ? String(raw.dropFirst()) : raw
    guard let number = Double(moneyInput: digits, allowZero: true) else { return nil }
    return negative ? -number : number
}

struct BillCoverage {
    var firstUncovered: UpcomingCharge?
    var buffer: Double
}

enum PaymentDelay {
    /// Starting cash includes all activity through today. Same-day expected deposits precede bills.
    static func coverage(cash: Double, incomes: [(date: Date, amount: Double)], bills: [UpcomingCharge],
                         now: Date, through end: Date, calendar: Calendar = .current) -> BillCoverage {
        let today = calendar.startOfDay(for: now)
        let lastDay = calendar.startOfDay(for: end)
        let deposits = incomes.map { (max(today, calendar.startOfDay(for: $0.date)), $0.amount) }.sorted { $0.0 < $1.0 }
        let ordered = bills.sorted { ($0.date, $0.name) < ($1.date, $1.name) }
        var index = 0, balance = cash, buffer = 0.0
        var first: UpcomingCharge?
        for bill in ordered {
            let day = calendar.startOfDay(for: bill.date)
            guard day >= today, day <= lastDay else { continue }
            while index < deposits.count && deposits[index].0 <= day {
                balance += deposits[index].1
                index += 1
            }
            balance -= bill.amount
            if balance < -0.005 {
                if first == nil { first = bill }
                buffer = max(buffer, -balance)
            }
        }
        return BillCoverage(firstUncovered: first, buffer: (buffer * 100).rounded() / 100)
    }
}

struct SpendingChange {
    struct Step: Identifiable {
        let label: String
        let amount: Double
        var id: String { label }
    }
    let yesterday: Double
    let today: Double
    let steps: [Step]
    let observed: Bool
    // Successive counterfactuals preserve the floor at zero and the cap at remaining flexible money.
    static func explain(entries: [LedgerEntry], lines: [PlanLine], previous: WidgetSnapshot?, now: Date,
                        calendar: Calendar = .current) -> SpendingChange {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let old = previous.flatMap { calendar.isDate($0.day, inSameDayAs: yesterday) ? $0 : nil }
        let past = old ?? WidgetSnapshot(entries: entries.filter { $0.date < calendar.startOfDay(for: now) },
                                         lines: lines, now: yesterday, calendar: calendar)
        let current = WidgetSnapshot(entries: entries, lines: lines, now: now, calendar: calendar)
        let start = past.safeToSpend(at: yesterday, calendar: calendar)?.safeToday ?? 0
        var last = (start * 100).rounded()
        var steps: [Step] = []
        func step(_ label: String, _ limit: Double, _ before: Double, _ spent: Double) {
            let safe = SafeToSpend.make(limit: limit, spentBeforeToday: before, spentToday: spent, now: now, calendar: calendar)
            let cents = (safe.safeToday * 100).rounded()
            if last != cents { steps.append(.init(label: label, amount: (cents - last) / 100)) }
            last = cents
        }
        let rollover = !calendar.isSameMonth(now, yesterday)
        let carried = rollover ? 0 : past.spentBeforeToday + past.spentToday
        step(rollover ? "New budget month" : "One fewer day to fund", past.flexibleLimit, carried, 0)
        step("Flexible budget edits", current.flexibleLimit, carried, 0)
        step("Earlier, scheduled or reclassified spending", current.flexibleLimit, current.spentBeforeToday, 0)
        let names = Set(lines.filter(\.isFlexible).map(\.name))
        let purchases = entries.filter { $0.isPersonalExpense && names.contains($0.category) && $0.amount > 0 && calendar.isDate($0.date, inSameDayAs: now) }.total
        step("Today’s purchases", current.flexibleLimit, current.spentBeforeToday, purchases)
        step("Today’s refunds", current.flexibleLimit, current.spentBeforeToday, current.spentToday)
        return SpendingChange(yesterday: (start * 100).rounded() / 100, today: last / 100, steps: steps, observed: old != nil)
    }
}

struct QuoteEstimate {
    let takeHome: Double
    let reserve: Double
    let minimum: Double
    private static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func calculate(hours: Double, hourly: Double, costs: Double, reservePercent: Double) -> QuoteEstimate? {
        guard let hours = decimal(hours), let hourly = decimal(hourly), hours > 0, hourly > 0 else { return nil }
        return price(takeHome: hours * hourly, costs: costs, reservePercent: reservePercent)
    }

    static func calculate(target: Double, costs: Double, reservePercent: Double) -> QuoteEstimate? {
        guard let target = decimal(target) else { return nil }
        return price(takeHome: target, costs: costs, reservePercent: reservePercent)
    }

    private static func price(takeHome: Decimal, costs: Double, reservePercent: Double) -> QuoteEstimate? {
        guard takeHome > 0, costs >= 0, (0..<100).contains(reservePercent),
              let expenses = decimal(costs), let percent = decimal(reservePercent) else { return nil }
        var raw = expenses + takeHome / (1 - percent / 100)
        guard !raw.isNaN, raw < 45_035_996_273_704 else { return nil }
        var price = Decimal()
        NSDecimalRound(&price, &raw, 2, .up)
        return .init(takeHome: NSDecimalNumber(decimal: takeHome).doubleValue,
                     reserve: NSDecimalNumber(decimal: price - expenses - takeHome).doubleValue,
                     minimum: NSDecimalNumber(decimal: price).doubleValue)
    }
}

enum CloseLedger: String, CaseIterable, Codable {
    case personal, business
    func movement(_ row: LedgerEntry) -> Double? {
        if row.isNet { return self == .personal ? row.amount : -row.amount }
        guard row.ledgerScope == rawValue else { return nil }
        return row.isIncome ? row.amount : -row.amount
    }
}
struct CloseBalance {
    let opening: Double
    let ending: Double
    let movement: Double
    var expected: Double { ((opening + movement) * 100).rounded() / 100 }
    var difference: Double { ((ending - expected) * 100).rounded() / 100 }
}
