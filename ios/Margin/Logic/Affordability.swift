import Foundation

/// The app's own answer to "Can I afford this?", computed from the plan. The assistant only explains it.
struct AffordabilityVerdict: Equatable, Codable {
    enum Level: String, Codable { case comfortable, tight, notYet }
    var level: Level
    var headline: String
    var details: [String]
    /// Daily allowance for the rest of the month after buying it (current month only).
    var newDailyAllowance: Double?
    /// Earliest forecast month whose running surplus covers the amount.
    var fitsInMonth: Date?
    /// Monthly amount to set aside from now to have it by the requested month.
    var suggestedMonthlySetAside: Double?
}

enum Affordability {
    static func evaluate(amount: Double, in month: Date, now: Date, safe: SafeToSpend, forecast: [ForecastMonth], calendar: Calendar = .current) -> AffordabilityVerdict {
        let monthName = month.formatted(.dateTime.month(.wide))
        let monthsAway = calendar.monthsBetween(now, month)
        let target = forecast.first { calendar.isSameMonth($0.monthStart, month) }
        let fits = forecast.first { $0.monthStart >= calendar.startOfMonth(for: month) && $0.cumulative >= amount }?.monthStart
        let setAside = amount / Double(max(1, monthsAway + 1))

        if monthsAway <= 0 {
            if amount <= safe.flexibleLeft {
                let left = safe.flexibleLeft - amount, daily = left / Double(max(1, safe.daysLeft))
                let comfortable = amount <= safe.flexibleLeft * 0.5
                return AffordabilityVerdict(level: comfortable ? .comfortable : .tight,
                                            headline: comfortable ? "Yes, it fits in this month’s flexible money." : "Yes, but it makes the rest of the month tight.",
                                            details: ["Leaves \(left.money) flexible for the next \(safe.daysLeft) days, about \(daily.money) a day."],
                                            newDailyAllowance: daily, fitsInMonth: nil, suggestedMonthlySetAside: nil)
            }
            let shortfall = amount - safe.flexibleLeft
            let unassignedReceived = max(0, (target?.receivedNet ?? 0) - (target?.planned ?? 0))
            if unassignedReceived >= shortfall {
                return AffordabilityVerdict(level: .tight, headline: "Only if you use income you haven’t assigned yet.",
                                            details: ["It’s \(shortfall.money) more than your flexible money left.", "You have \(unassignedReceived.money) of this month’s Net not assigned to the plan."],
                                            newDailyAllowance: 0, fitsInMonth: nil, suggestedMonthlySetAside: nil)
            }
            return AffordabilityVerdict(level: .notYet, headline: "Not this month.",
                                        details: ["It’s \(shortfall.money) more than your flexible money left."] + (fits.map { ["Booked work covers it by \($0.formatted(.dateTime.month(.wide).year()))."] } ?? []),
                                        newDailyAllowance: nil, fitsInMonth: fits, suggestedMonthlySetAside: nil)
        }

        let surplus = max(0, target?.cumulative ?? 0)
        if surplus >= amount {
            return AffordabilityVerdict(level: surplus >= amount * 1.5 ? .comfortable : .tight,
                                        headline: "Yes, if booked work pays as expected.",
                                        details: ["Booked jobs leave about \(surplus.money) beyond your plan by \(monthName)."],
                                        newDailyAllowance: nil, fitsInMonth: target?.monthStart, suggestedMonthlySetAside: nil)
        }
        return AffordabilityVerdict(level: .notYet, headline: "Not on what’s booked so far.",
                                    details: ["Booked work leaves \(surplus.money) beyond your plan by \(monthName)." ,
                                              "Setting aside \(setAside.money) a month from now would cover it."],
                                    newDailyAllowance: nil, fitsInMonth: fits, suggestedMonthlySetAside: setAside)
    }
}
