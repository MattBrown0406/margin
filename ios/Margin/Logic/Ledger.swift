import Foundation

/// A plain copy of one ledger entry. Money logic works on these instead of SwiftData models so it can be
/// unit-tested (`swift test` at the repo root) and shared with the widget extension.
struct LedgerEntry: Equatable {
    var date: Date
    var amount: Double
    var category: String
    var isIncome: Bool
    var ledgerScope: String
    var incomeKind: String? = nil
    var jobID: UUID? = nil
    var title: String = ""

    var isGross: Bool { isIncome && incomeKind == "gross" }
    var isNet: Bool { isIncome && incomeKind == "net" }
    var isPersonalExpense: Bool { !isIncome && ledgerScope == "personal" }
    var isBusinessExpense: Bool { !isIncome && ledgerScope == "business" }
}

/// One budget line as the money logic sees it.
struct PlanLine: Equatable {
    var name: String
    var monthlyLimit: Double
    var isFlexible: Bool
    var dueDay: Int? = nil
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date { dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date) }
    func isSameMonth(_ a: Date, _ b: Date) -> Bool { isDate(a, equalTo: b, toGranularity: .month) }
    /// Months from the start of `from`'s month to the start of `to`'s month (negative if earlier).
    func monthsBetween(_ from: Date, _ to: Date) -> Int { dateComponents([.month], from: startOfMonth(for: from), to: startOfMonth(for: to)).month ?? 0 }
}

extension Sequence where Element == LedgerEntry {
    var total: Double { reduce(0) { $0 + $1.amount } }
}
