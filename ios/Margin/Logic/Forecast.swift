import Foundation

/// A booked intervention that hasn't paid yet.
struct BookedJobInfo: Equatable, Identifiable {
    var id: UUID
    var title: String
    var expectedDate: Date
    var expectedGross: Double
    var expectedNet: Double
    /// Recorded payments (jobIDs) the person said are not this booking.
    var ignoredPaymentIDs: Set<UUID> = []
    /// When the booking was made; payments recorded well before that can't be its payment.
    var bookedAt: Date = .distantPast
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
    /// Short once earlier months' surplus (money already in the personal account) is counted.
    var isRunningShort: Bool { cumulative < -0.005 }
}

enum CashFlowForecast {
    /// An unpaid booking keeps counting (in the current month) for this long after its expected date.
    static let overdueGraceDays = 60

    static func months(entries: [LedgerEntry], booked: [BookedJobInfo], plannedMonthly: Double, now: Date, count: Int = 6, calendar: Calendar = .current) -> [ForecastMonth] {
        let current = calendar.startOfMonth(for: now)
        var running = 0.0
        return (0..<max(1, count)).map { offset in
            let start = calendar.date(byAdding: .month, value: offset, to: current) ?? current
            let inMonth = booked.filter { calendar.isSameMonth($0.expectedDate, start) }
            let graceStart = calendar.date(byAdding: .day, value: -overdueGraceDays, to: now) ?? .distantPast
            let overdue = offset == 0 ? booked.filter { $0.expectedDate < current && $0.expectedDate >= graceStart } : []
            let jobs = (overdue + inMonth).sorted { $0.expectedDate < $1.expectedDate }
            let received = entries.filter { $0.isNet && calendar.isSameMonth($0.date, start) }.total
            let month = ForecastMonth(monthStart: start, receivedNet: received, expectedNet: jobs.reduce(0) { $0 + $1.expectedNet },
                                      planned: plannedMonthly, jobs: jobs, overdueJobs: overdue, cumulative: 0)
            running += month.gap
            var result = month; result.cumulative = running
            return result
        }
    }

    /// The first month whose running total goes negative: booked work plus money already received can't cover
    /// the plan. The shortfall is `-cumulative`.
    static func firstShortfall(_ months: [ForecastMonth]) -> ForecastMonth? { months.first(where: \.isRunningShort) }

    /// For each open booking, a recorded payment that is probably it: a Gross with the same title or within 5% of
    /// the expected Gross, or (when the business account isn't tracked) a Net transfer not linked to any recorded
    /// Gross, matched against the expected Net. It must be dated from 30 days before to 45 days after the expected
    /// date and no earlier than 3 days before the booking was made, so a previous job's payment never closes a
    /// new booking. Each payment matches at most one booking; payments linked to a paid booking (`claimed`) or
    /// dismissed for this booking never match.
    static func likelyPayments(for booked: [BookedJobInfo], entries: [LedgerEntry], claimed: Set<UUID>, calendar: Calendar = .current) -> [UUID: LedgerEntry] {
        var taken = claimed, matches: [UUID: LedgerEntry] = [:]
        let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let grossJobIDs = Set(entries.filter(\.isGross).compactMap(\.jobID))
        let close: (Double, Double) -> Bool = { actual, expected in expected > 0 && abs(actual - expected) <= expected * 0.05 }
        for job in booked.sorted(by: { $0.expectedDate < $1.expectedDate }) {
            guard let windowStart = calendar.date(byAdding: .day, value: -30, to: job.expectedDate),
                  let to = calendar.date(byAdding: .day, value: 45, to: job.expectedDate) else { continue }
            let from = max(windowStart, calendar.date(byAdding: .day, value: -3, to: job.bookedAt) ?? .distantPast)
            let candidates = entries.filter { entry in
                guard let id = entry.jobID, !taken.contains(id), !job.ignoredPaymentIDs.contains(id), entry.date >= from, entry.date <= to else { return false }
                let sameTitle = !job.title.isEmpty && normalize(entry.title) == normalize(job.title)
                if entry.isGross { return sameTitle || close(entry.amount, job.expectedGross) }
                if entry.isNet && !grossJobIDs.contains(id) { return sameTitle || close(entry.amount, job.expectedNet) }
                return false
            }
            // Prefer a Gross receipt, then the closest date.
            if let best = candidates.min(by: { ($0.isGross ? 0 : 1, abs($0.date.timeIntervalSince(job.expectedDate))) < ($1.isGross ? 0 : 1, abs($1.date.timeIntervalSince(job.expectedDate))) }),
               let id = best.jobID {
                matches[job.id] = best; taken.insert(id)
            }
        }
        return matches
    }

    /// Open bookings that should still count as expected income: those with no likely recorded payment.
    static func unpaid(_ booked: [BookedJobInfo], entries: [LedgerEntry], claimed: Set<UUID>, calendar: Calendar = .current) -> [BookedJobInfo] {
        let paid = likelyPayments(for: booked, entries: entries, claimed: claimed, calendar: calendar)
        return booked.filter { paid[$0.id] == nil }
    }

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
