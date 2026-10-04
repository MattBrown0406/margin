import Foundation

/// A booked intervention that hasn't paid yet.
struct BookedJobInfo: Equatable, Identifiable {
    var id: UUID
    var title: String
    var expectedDate: Date
    var expectedGross: Double
    var expectedNet: Double
}

/// One month of the cash-flow calendar: personal Net already received plus Net expected from booked
/// jobs, against the monthly plan.
struct ForecastMonth: Equatable, Identifiable {
    var id: Date { monthStart }
    var monthStart: Date
    var receivedNet: Double
    var expectedNet: Double
    var planned: Double
    var jobs: [BookedJobInfo]
    /// Booked jobs whose expected date has already passed; they are counted in the current month.
    var overdueJobs: [BookedJobInfo]
    /// Running total of `gap` from the current month through this one.
    var cumulative: Double

    var gap: Double { receivedNet + expectedNet - planned }
    var isShort: Bool { gap < -0.005 }
}

enum CashFlowForecast {
    static func months(entries: [LedgerEntry], booked: [BookedJobInfo], plannedMonthly: Double, now: Date, count: Int = 6, calendar: Calendar = .current) -> [ForecastMonth] {
        let current = calendar.startOfMonth(for: now)
        var running = 0.0
        return (0..<max(1, count)).map { offset in
            let start = calendar.date(byAdding: .month, value: offset, to: current) ?? current
            let inMonth = booked.filter { calendar.isSameMonth($0.expectedDate, start) }
            let overdue = offset == 0 ? booked.filter { $0.expectedDate < current } : []
            let jobs = (overdue + inMonth).sorted { $0.expectedDate < $1.expectedDate }
            let received = entries.filter { $0.isNet && calendar.isSameMonth($0.date, start) }.total
            let month = ForecastMonth(monthStart: start, receivedNet: received, expectedNet: jobs.reduce(0) { $0 + $1.expectedNet },
                                      planned: plannedMonthly, jobs: jobs, overdueJobs: overdue, cumulative: 0)
            running += month.gap
            var result = month; result.cumulative = running
            return result
        }
    }

    /// The first month that booked work doesn't cover.
    static func firstShortfall(_ months: [ForecastMonth]) -> ForecastMonth? { months.first(where: \.isShort) }

    /// Share of Gross that has historically reached the personal account, from the last 12 months of jobs
    /// that recorded at least one transfer. Used to pre-fill a booked job's expected Net.
    static func historicalNetRate(entries: [LedgerEntry], now: Date, calendar: Calendar = .current) -> Double? {
        let cutoff = calendar.date(byAdding: .month, value: -12, to: now) ?? .distantPast
        let jobs = entries.filter { $0.isGross && $0.jobID != nil && $0.date >= cutoff }
        var gross = 0.0, net = 0.0
        for job in jobs {
            let transferred = entries.filter { $0.isNet && $0.jobID == job.jobID }.total
            guard transferred > 0 else { continue }
            gross += job.amount; net += transferred
        }
        guard gross > 0 else { return nil }
        return min(1, net / gross)
    }
}
