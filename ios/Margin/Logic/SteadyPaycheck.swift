import Foundation

/// Turns irregular job income into a steady monthly paycheck: every Net transfer goes into an income buffer, and
/// the same amount moves from the buffer to spending each month.
struct SteadyPaycheckPlan: Equatable {
    struct BufferMonth: Equatable, Identifiable {
        var id: Date { monthStart }
        var monthStart: Date
        /// Net still expected from booked jobs in this month.
        var expectedIn: Double
        /// The paycheck taken from the buffer this month (0 for the current month, assumed already taken).
        var paycheckOut: Double
        var endBalance: Double
    }

    /// Complete months of history used (at most 12, starting from the first month with a Net transfer).
    var monthsOfHistory: Int
    var averageMonthlyNet: Double
    var lowestMonthNet: Double
    /// The trailing average rounded down to $50; 0 without history.
    var suggestedPaycheck: Double
    /// The paycheck in use: the person's own amount, or the suggestion.
    var paycheck: Double
    var plannedMonthly: Double
    /// How many months the buffer pays the paycheck with no new work; nil without a paycheck.
    var runwayMonths: Double?
    var projection: [BufferMonth]

    var coversPlan: Bool { paycheck + 0.005 >= plannedMonthly }
    /// The first projected month the buffer runs dry, counting only work already booked.
    var firstEmptyMonth: Date? { projection.first { $0.endBalance < -0.005 }?.monthStart }
}

enum SteadyPaycheck {
    static let historyMonths = 12

    /// - Parameters:
    ///   - chosenPaycheck: the person's own monthly amount, or 0 to use the suggestion.
    ///   - buffer: what's in the income buffer today, including Net already received this month.
    ///   - forecast: `CashFlowForecast.months`, whose `expectedNet` is Net still to come from booked jobs.
    static func plan(entries: [LedgerEntry], chosenPaycheck: Double, buffer: Double, plannedMonthly: Double,
                     forecast: [ForecastMonth], now: Date, calendar: Calendar = .current) -> SteadyPaycheckPlan {
        let current = calendar.startOfMonth(for: now)
        let nets = entries.filter { $0.isNet && $0.ledgerScope == "personal" && $0.date < current }
        let windowStart = calendar.date(byAdding: .month, value: -historyMonths, to: current) ?? current
        var totals: [Double] = []
        if let first = nets.map(\.date).min() {
            var month = max(calendar.startOfMonth(for: first), windowStart)
            while month < current {
                totals.append(nets.filter { calendar.isSameMonth($0.date, month) }.total)
                guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
                month = next
            }
        }
        let average = totals.isEmpty ? 0 : totals.reduce(0, +) / Double(totals.count)
        let suggested = (average / 50).rounded(.down) * 50
        let paycheck = chosenPaycheck > 0 ? chosenPaycheck : suggested

        var balance = buffer, projection: [SteadyPaycheckPlan.BufferMonth] = []
        for month in forecast where month.monthStart >= current {
            let out = month.monthStart == current ? 0 : paycheck
            balance += month.expectedNet - out
            projection.append(.init(monthStart: month.monthStart, expectedIn: month.expectedNet, paycheckOut: out, endBalance: balance))
        }
        return SteadyPaycheckPlan(monthsOfHistory: totals.count, averageMonthlyNet: average, lowestMonthNet: totals.min() ?? 0,
                                  suggestedPaycheck: max(0, suggested), paycheck: paycheck, plannedMonthly: plannedMonthly,
                                  runwayMonths: paycheck > 0 ? max(0, buffer) / paycheck : nil, projection: projection)
    }
}
