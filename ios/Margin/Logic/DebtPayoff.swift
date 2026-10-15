import Foundation

/// One debt as the payoff planner sees it.
struct DebtInfo: Equatable, Identifiable {
    var id: UUID
    var name: String
    var balance: Double
    /// Annual percentage rate, as a percent (22.9 means 22.9%).
    var apr: Double
    var minimumPayment: Double
    /// Position in the person's own order (used by `.custom`).
    var customRank: Int = 0
    /// Already paid on it this month (recorded payments), so month 1 only plans what's left of this month's payment.
    var paidThisMonth: Double = 0

    var monthlyInterest: Double { balance * apr / 100 / 12 }
}

/// Which debt gets the extra money (and every rolled-over payment) first.
enum PayoffStrategy: String, CaseIterable, Identifiable {
    case snowball, avalanche, interestCost, cashFlow, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .snowball: "Smallest balance first"
        case .avalanche: "Highest interest rate first"
        case .interestCost: "Highest interest cost first"
        case .cashFlow: "Free up cash flow first"
        case .custom: "My own order"
        }
    }
    var detail: String {
        switch self {
        case .snowball: "Quick wins: each paid-off debt frees its payment for the next one sooner. Also called the debt snowball."
        case .avalanche: "Usually pays the least interest overall. Also called the debt avalanche."
        case .interestCost: "Targets the debt costing the most dollars of interest each month."
        case .cashFlow: "Pays off the debt with the lowest balance relative to its minimum payment first, freeing monthly cash fastest."
        case .custom: "You choose the order. Drag debts in the list to change it."
        }
    }

    /// The order debts are targeted, set from today's numbers (it doesn't reshuffle as balances change).
    /// Ties fall back to the higher rate, then the smaller balance, then the name, so the order is stable.
    func order(_ debts: [DebtInfo]) -> [DebtInfo] {
        let tieBreak: (DebtInfo, DebtInfo) -> Bool = { a, b in
            if a.apr != b.apr { return a.apr > b.apr }
            if a.balance != b.balance { return a.balance < b.balance }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func by<T: Comparable>(_ key: (DebtInfo) -> T, descending: Bool = false) -> [DebtInfo] {
            debts.sorted { a, b in
                let ka = key(a), kb = key(b)
                if ka != kb { return descending ? ka > kb : ka < kb }
                return tieBreak(a, b)
            }
        }
        switch self {
        case .snowball: return by(\.balance)
        case .avalanche: return by(\.apr, descending: true)
        case .interestCost: return by(\.monthlyInterest, descending: true)
        case .cashFlow: return by { $0.minimumPayment > 0 ? $0.balance / $0.minimumPayment : .greatestFiniteMagnitude }
        case .custom: return by(\.customRank)
        }
    }
}

struct DebtPayoffPlan: Equatable {
    struct Outcome: Equatable, Identifiable {
        var id: UUID
        var name: String
        /// 1-based month (from the first month of the plan) in which it reaches zero; nil if never within the horizon.
        var payoffMonth: Int?
        var interestPaid: Double
    }
    struct Month: Equatable {
        var index: Int
        var payments: [UUID: Double]
        var interest: Double
        var remainingBalance: Double
        /// The debt receiving the money above minimums this month (nil when everything goes to minimums).
        var focus: UUID?
    }

    /// Fixed every month: every debt's minimum (paid-off debts' included) plus the extra. Paid-off debts' payments roll into the rest.
    var monthlyBudget: Double
    /// Debts in the order they are targeted.
    var outcomes: [Outcome]
    var months: [Month]
    var totalInterest: Double
    var totalPaid: Double
    /// Months until every debt is paid; nil when the plan never finishes within `DebtPayoff.horizonMonths`.
    var monthsToDebtFree: Int?
    /// Debts whose minimum payment doesn't cover the interest they accrue.
    var minimumBelowInterest: [String]
}

enum DebtPayoff {
    /// Plans are simulated for at most 50 years.
    static let horizonMonths = 600

    private static func cents(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Simulates paying the debts month by month. Each month interest accrues (APR ÷ 12 on the balance), every debt
    /// gets its minimum (or what's left of it), and with `rollover` everything else in the fixed monthly budget goes
    /// to the first unpaid debt in the strategy's order — so when a debt is paid off, its payment moves to the next
    /// one instead of leaving the budget. Without `rollover` (the comparison baseline) each debt only ever gets its
    /// own minimum and `extra` is ignored.
    /// Debts already paid off in real life keep their minimum in the budget (it rolls into the rest), so paying a
    /// debt off never shrinks the monthly debt payment.
    static func plan(_ debts: [DebtInfo], strategy: PayoffStrategy, extra: Double, rollover: Bool = true) -> DebtPayoffPlan {
        let active = strategy.order(debts.filter { $0.balance > 0.005 })
        let paidOffMinimums = debts.filter { $0.balance <= 0.005 }.reduce(0) { $0 + max(0, $1.minimumPayment) }
        let budget = active.isEmpty ? 0 : cents(active.reduce(0) { $0 + max(0, $1.minimumPayment) } + (rollover ? max(0, extra) + paidOffMinimums : 0))
        // This month's payments already made (on any debt, including one just paid off) come out of month 1.
        let paidAlready = cents(debts.reduce(0) { $0 + max(0, $1.paidThisMonth) })
        var balance = Dictionary(uniqueKeysWithValues: active.map { ($0.id, cents($0.balance)) })
        var interestPaid = [UUID: Double](), payoffMonth = [UUID: Int]()
        var months: [DebtPayoffPlan.Month] = [], totalInterest = 0.0, totalPaid = 0.0, finished: Int? = active.isEmpty ? 0 : nil

        for index in 1...horizonMonths where finished == nil {
            var monthInterest = 0.0, payments = [UUID: Double]()
            for debt in active where balance[debt.id, default: 0] > 0 {
                let interest = cents(balance[debt.id, default: 0] * debt.apr / 100 / 12)
                balance[debt.id, default: 0] += interest; interestPaid[debt.id, default: 0] += interest; monthInterest += interest
            }
            // Month 1 leaves out what's already been paid this month — but never less than the minimums still owed,
            // however big a payment elsewhere was.
            let minimumsLeft = active.reduce(0) { $0 + min(balance[$1.id, default: 0], max(0, $1.minimumPayment - (index == 1 ? $1.paidThisMonth : 0))) }
            var available = index == 1 ? max(cents(budget - paidAlready), cents(minimumsLeft)) : budget
            for debt in active where balance[debt.id, default: 0] > 0 {
                let minimum = index == 1 ? max(0, debt.minimumPayment - debt.paidThisMonth) : debt.minimumPayment
                let pay = cents(min(max(0, minimum), balance[debt.id, default: 0], available))
                balance[debt.id, default: 0] = cents(balance[debt.id, default: 0] - pay); available = cents(available - pay); payments[debt.id, default: 0] += pay
            }
            var focus: UUID?
            if rollover {
                for debt in active where balance[debt.id, default: 0] > 0 && available > 0 {
                    focus = focus ?? debt.id
                    let pay = min(balance[debt.id, default: 0], available)
                    balance[debt.id, default: 0] = cents(balance[debt.id, default: 0] - pay); available = cents(available - pay); payments[debt.id, default: 0] += pay
                }
            }
            for debt in active where payoffMonth[debt.id] == nil && balance[debt.id, default: 0] <= 0 { payoffMonth[debt.id] = index }
            let remaining = cents(balance.values.reduce(0, +))
            totalInterest += monthInterest; totalPaid += payments.values.reduce(0, +)
            months.append(.init(index: index, payments: payments, interest: cents(monthInterest), remainingBalance: remaining, focus: focus))
            if remaining <= 0 { finished = index }
        }
        return DebtPayoffPlan(monthlyBudget: budget,
                              outcomes: active.map { .init(id: $0.id, name: $0.name, payoffMonth: payoffMonth[$0.id], interestPaid: cents(interestPaid[$0.id, default: 0])) },
                              months: months, totalInterest: cents(totalInterest), totalPaid: cents(totalPaid), monthsToDebtFree: finished,
                              minimumBelowInterest: active.filter { $0.minimumPayment < cents($0.monthlyInterest) + 0.005 && $0.apr > 0 }.map(\.name))
    }

    /// What the strategy and extra save compared with paying only each debt's minimum.
    struct Comparison: Equatable {
        var plan: DebtPayoffPlan
        var minimumsOnly: DebtPayoffPlan
        /// Nil when the minimums-only baseline never finishes (savings are then open-ended).
        var interestSaved: Double? {
            minimumsOnly.monthsToDebtFree == nil ? nil : max(0, minimumsOnly.totalInterest - plan.totalInterest)
        }
        var monthsSaved: Int? {
            guard let base = minimumsOnly.monthsToDebtFree, let fast = plan.monthsToDebtFree else { return nil }
            return max(0, base - fast)
        }
    }

    /// This month's running total of payments on a debt after one more payment: a payment dated in another month
    /// doesn't count toward this month (and doesn't wipe it); a total from an earlier month starts over.
    static func tally(month: String, paid: Double, adding amount: Double, paymentMonth: String, currentMonth: String) -> (month: String, paid: Double) {
        let base = month == currentMonth ? paid : 0
        return (currentMonth, base + (paymentMonth == currentMonth ? max(0, amount) : 0))
    }

    static func compare(_ debts: [DebtInfo], strategy: PayoffStrategy, extra: Double) -> Comparison {
        Comparison(plan: plan(debts, strategy: strategy, extra: extra), minimumsOnly: plan(debts, strategy: strategy, extra: 0, rollover: false))
    }
}
