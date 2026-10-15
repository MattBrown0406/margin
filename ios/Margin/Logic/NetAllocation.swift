import Foundation

/// A plan line Net can be assigned to this month.
struct AllocationTarget: Equatable {
    enum Kind: String, Equatable { case bill, tax, fund, planned, flexible, extra }
    var name: String
    var kind: Kind
    var monthlyAmount: Double
    var dueDay: Int? = nil
    /// Already assigned to it this month.
    var assigned: Double = 0
    /// Already spent in it this month (a bill that's been paid).
    var spent: Double = 0
    var stillNeeded: Double { max(0, monthlyAmount - assigned) }
}

/// One suggested slice of a Net transfer.
struct AllocationLine: Equatable, Identifiable {
    var id: String { "\(kind.rawValue):\(name)" }
    var name: String
    var kind: AllocationTarget.Kind
    var amount: Double
    var reason: String
}

enum NetAllocator {
    /// The name every flexible line is assigned under, as one pot of everyday money.
    static let flexibleName = "Everyday spending"

    /// This month's targets from the plan: bills (lines with a due day), the tax line, sinking funds, other planned
    /// lines, and flexible lines combined into one everyday pot. `assigned` is what's already assigned this month, by name.
    static func targets(lines: [PlanLine], taxLineName: String, assigned: [String: Double], spent: [String: Double] = [:]) -> [AllocationTarget] {
        var targets: [AllocationTarget] = []
        for line in lines where !line.isFlexible && line.monthlyLimit > 0 {
            let kind: AllocationTarget.Kind = line.name.caseInsensitiveCompare(taxLineName) == .orderedSame ? .tax
                : line.isFund ? .fund : line.dueDay != nil ? .bill : .planned
            targets.append(AllocationTarget(name: line.name, kind: kind, monthlyAmount: line.monthlyLimit, dueDay: line.dueDay, assigned: assigned[line.name] ?? 0, spent: spent[line.name] ?? 0))
        }
        let flexible = lines.filter(\.isFlexible).reduce(0) { $0 + max(0, $1.monthlyLimit) }
        if flexible > 0 { targets.append(AllocationTarget(name: flexibleName, kind: .flexible, monthlyAmount: flexible, assigned: assigned[flexibleName] ?? 0)) }
        return targets
    }

    /// Splits `amount` across what this month's plan still needs, in this order:
    /// 1. bills due by the next expected income (or by month end), earliest first — overdue ones come first;
    /// 2. the tax set-aside; 3. sinking funds; 4. everything else planned, including later bills;
    /// 5. everyday (flexible) money; 6. anything left over goes to `surplusTarget` (a fund), if one is chosen.
    /// What can't be placed stays unassigned (the lines then add up to less than `amount`).
    static func suggest(amount: Double, targets: [AllocationTarget], now: Date, nextIncome: Date?, surplusTarget: String?,
                        calendar: Calendar = .current) -> [AllocationLine] {
        let today = calendar.component(.day, from: now)
        let nextIncomeDay = nextIncome.flatMap { calendar.isSameMonth($0, now) && $0 > now ? calendar.component(.day, from: $0) : nil }
        // A bill due the 31st is due on the last day of a shorter month.
        let monthDays = calendar.range(of: .day, in: .month, for: now)?.count ?? 31
        let due: (AllocationTarget) -> Int = { min($0.dueDay ?? monthDays, monthDays) }
        let cutoff = nextIncomeDay ?? monthDays
        let dueSoon = targets.filter { $0.kind == .bill && due($0) <= cutoff }.sorted { (due($0), $0.name) < (due($1), $1.name) }
        let restOrder: (AllocationTarget) -> Int = { target in target.dueDay == nil ? 99 : due(target) }
        let rest = targets.filter { $0.kind == .planned || ($0.kind == .bill && due($0) > cutoff) }.sorted { (restOrder($0), $0.name) < (restOrder($1), $1.name) }
        let ordered = dueSoon + targets.filter { $0.kind == .tax } + targets.filter { $0.kind == .fund }.sorted { $0.name < $1.name } + rest + targets.filter { $0.kind == .flexible }

        var left = (max(0, amount) * 100).rounded() / 100, lines: [AllocationLine] = []
        for target in ordered where left > 0.005 {
            let slice = min(left, (target.stillNeeded * 100).rounded() / 100)
            guard slice > 0.005 else { continue }
            left = ((left - slice) * 100).rounded() / 100
            var shown = target; shown.dueDay = target.dueDay.map { min($0, monthDays) }
            lines.append(AllocationLine(name: target.name, kind: target.kind, amount: slice, reason: reason(for: shown, today: today, nextIncome: nextIncomeDay.flatMap { _ in nextIncome })))
        }
        if left > 0.005, let surplus = surplusTarget, !surplus.isEmpty {
            lines.append(AllocationLine(name: surplus, kind: .extra, amount: left, reason: "Everything in the plan is covered; the rest goes to \(surplus)."))
        }
        return lines
    }

    private static func reason(for target: AllocationTarget, today: Int, nextIncome: Date?) -> String {
        switch target.kind {
        case .bill:
            guard let day = target.dueDay else { return "Bill" }
            if target.spent >= target.monthlyAmount - 0.005 { return "Paid this month; this covers it" }
            if day < today { return "Was due the \(day.ordinalString)" }
            if let nextIncome { return "Due the \(day.ordinalString), before your next expected job pays (\(nextIncome.formatted(.dateTime.month(.abbreviated).day())))" }
            return "Due the \(day.ordinalString)"
        case .tax: return "This month’s tax set-aside"
        case .fund: return "This month’s contribution"
        case .planned: return "Planned this month"
        case .flexible: return "Everyday spending for the month"
        case .extra: return "Extra"
        }
    }
}

extension Int {
    /// "1st", "22nd"… (English; used in money-logic messages that also run in tests).
    var ordinalString: String {
        let tens = self % 100, ones = self % 10
        let suffix = (11...13).contains(tens) ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th"
        return "\(self)\(suffix)"
    }
}
