import Foundation

/// Today's spending allowance from the flexible budget. The allowance is fixed at the start of the day;
/// spending today draws it down dollar for dollar instead of being spread across the rest of the month.
struct SafeToSpend: Equatable {
    var safeToday: Double
    var dailyAllowance: Double
    var spentToday: Double
    var flexibleLeft: Double
    var flexibleLimit: Double
    var daysLeft: Int

    static func compute(entries: [LedgerEntry], lines: [PlanLine], now: Date, calendar: Calendar = .current) -> SafeToSpend {
        let flexibleNames = Set(lines.filter(\.isFlexible).map(\.name))
        let limit = lines.filter(\.isFlexible).reduce(0) { $0 + $1.monthlyLimit }
        let spending = entries.filter { $0.isPersonalExpense && flexibleNames.contains($0.category) && calendar.isSameMonth($0.date, now) }
        let today = spending.filter { calendar.isDate($0.date, inSameDayAs: now) }.total
        return make(limit: limit, spentBeforeToday: spending.total - today, spentToday: today, now: now, calendar: calendar)
    }

    static func make(limit: Double, spentBeforeToday: Double, spentToday: Double, now: Date, calendar: Calendar = .current) -> SafeToSpend {
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeft = max(1, daysInMonth - calendar.component(.day, from: now) + 1)
        let allowance = max(0, (limit - spentBeforeToday) / Double(daysLeft))
        return SafeToSpend(safeToday: max(0, allowance - spentToday), dailyAllowance: allowance, spentToday: spentToday,
                           flexibleLeft: max(0, limit - spentBeforeToday - spentToday), flexibleLimit: limit, daysLeft: daysLeft)
    }
}

/// What the app shares with the widget through the App Group. It carries the inputs rather than the
/// answer, so the widget can roll the allowance over at midnight without the app running.
struct WidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.com.mattbrown.margin"
    static let defaultsKey = "margin.widgetSnapshot"

    var monthStart: Date
    var day: Date
    var flexibleLimit: Double
    var spentBeforeToday: Double
    var spentToday: Double

    init(entries: [LedgerEntry], lines: [PlanLine], now: Date, calendar: Calendar = .current) {
        let safe = SafeToSpend.compute(entries: entries, lines: lines, now: now, calendar: calendar)
        monthStart = calendar.startOfMonth(for: now); day = calendar.startOfDay(for: now)
        flexibleLimit = safe.flexibleLimit; spentToday = safe.spentToday
        spentBeforeToday = safe.flexibleLimit - safe.flexibleLeft - safe.spentToday
    }

    /// The allowance at `now`, or nil when the snapshot is from another month (the app must refresh it).
    func safeToSpend(at now: Date, calendar: Calendar = .current) -> SafeToSpend? {
        guard calendar.isSameMonth(monthStart, now) else { return nil }
        if calendar.isDate(day, inSameDayAs: now) { return .make(limit: flexibleLimit, spentBeforeToday: spentBeforeToday, spentToday: spentToday, now: now, calendar: calendar) }
        guard now > day else { return nil }
        // A later day: everything recorded so far counts as "before today".
        return .make(limit: flexibleLimit, spentBeforeToday: spentBeforeToday + spentToday, spentToday: 0, now: now, calendar: calendar)
    }

    static func load(from defaults: UserDefaults?) -> WidgetSnapshot? {
        defaults?.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }
    func save(to defaults: UserDefaults?) {
        if let data = try? JSONEncoder().encode(self) { defaults?.set(data, forKey: Self.defaultsKey) }
    }
}
