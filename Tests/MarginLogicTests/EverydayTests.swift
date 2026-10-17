import Foundation
import Testing
@testable import MarginLogic

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date { utc.date(from: DateComponents(year: y, month: m, day: day, hour: h))! }

@Suite struct MerchantRuleTests {
    let rules = [MerchantRuleInfo(key: "safeway", scope: "personal", category: "Groceries", updatedAt: d(2026, 1, 1)),
                 MerchantRuleInfo(key: "safeway", scope: "personal", category: "Personal", updatedAt: d(2026, 3, 1)),
                 MerchantRuleInfo(key: "safeway", scope: "business", category: "Meals", updatedAt: d(2026, 5, 1))]

    @Test func newestChoiceForTheSameMerchantAndLedgerWins() {
        #expect(MerchantRules.category(for: "SAFEWAY #1234", scope: "personal", rules: rules, options: ["Groceries", "Personal"]) == "Personal")
        #expect(MerchantRules.category(for: "Safeway", scope: "business", rules: rules, options: ["Meals", "Travel"]) == "Meals")
    }

    @Test func aCategoryThatNoLongerExistsIsIgnored() {
        #expect(MerchantRules.category(for: "Safeway", scope: "personal", rules: rules, options: ["Groceries"]) == "Groceries")
        #expect(MerchantRules.category(for: "Safeway", scope: "personal", rules: rules, options: ["Fuel"]) == nil)
    }

    @Test func unknownOrUnnamedMerchantsHaveNoRule() {
        #expect(MerchantRules.category(for: "Costco", scope: "personal", rules: rules, options: ["Groceries"]) == nil)
        #expect(MerchantRules.category(for: "POS 1234", scope: "personal", rules: rules, options: ["Groceries"]) == nil)
    }
}

@Suite struct TaxSetAsideTests {
    @Test func roundsToWholeDollarsAndClampsTheRate() {
        #expect(TaxSetAside.amount(gross: 9000, rate: 0.2834) == 2551)
        #expect(TaxSetAside.amount(gross: 9000, rate: 1.4) == 9000)
        #expect(TaxSetAside.amount(gross: 9000, rate: -0.1) == 0)
    }

    @Test func grossTaxFundsTheReserveButIsNotNetSpending() {
        #expect(!AllocationKinds.isFromNet(AllocationKinds.grossTax))
        #expect(!AllocationKinds.isFromNet(AllocationKinds.grossTaxSkipped))
        #expect(!AllocationKinds.isFromNet(AllocationKinds.rollover))
        #expect(AllocationKinds.isFromNet("tax") && AllocationKinds.isFromNet("bill"))
        #expect(AllocationKinds.fundsTaxReserve("tax") && AllocationKinds.fundsTaxReserve(AllocationKinds.grossTax))
        #expect(!AllocationKinds.fundsTaxReserve(AllocationKinds.grossTaxSkipped))
    }
}

@Suite struct ReminderScheduleTests {
    let now = d(2026, 10, 16, 15)
    let bills: [(name: String, dueDay: Int, amount: Double, paidThisMonth: Bool)] = [
        (name: "Mortgage", dueDay: 3, amount: 2650, paidThisMonth: true),
        (name: "Car insurance", dueDay: 18, amount: 250, paidThisMonth: false),
        (name: "Rent", dueDay: 31, amount: 1500, paidThisMonth: false)]

    @Test func billsTwoDaysBeforeAt9SkippingPaidAndPast() {
        let plans = ReminderSchedule.plan(bills: bills, leftToAssign: 0, nextTaxDue: nil, includeBills: true, includeNet: true, includeTaxes: true, now: now, calendar: utc)
        // Car insurance Oct 18 → reminder Oct 16 9 AM, already past at 3 PM: skipped. Rent Oct 31 → Oct 29.
        // November: Mortgage Nov 3 → Nov 1, insurance Nov 18 → Nov 16; rent's Nov 28 reminder is past the 40-day horizon (Nov 25).
        #expect(plans.map(\.id) == ["bill|Rent|2026-10", "bill|Mortgage|2026-11", "bill|Car insurance|2026-11"])
        #expect(plans.first.map { utc.dateComponents([.month, .day, .hour], from: $0.date) } == DateComponents(month: 10, day: 29, hour: 9))
        #expect(plans.allSatisfy { $0.date > now })
        // February: rent "due the 31st" is due the 28th, so its reminder is the 26th.
        let feb = ReminderSchedule.plan(bills: [(name: "Rent", dueDay: 31, amount: 1500, paidThisMonth: false)], leftToAssign: 0, nextTaxDue: nil,
                                        includeBills: true, includeNet: false, includeTaxes: false, now: d(2027, 2, 10), calendar: utc)
        #expect(feb.first.map { utc.dateComponents([.month, .day], from: $0.date) } == DateComponents(month: 2, day: 26))
    }

    @Test func netTomorrowMorningOnlyWhenSomethingIsWaiting() {
        let waiting = ReminderSchedule.plan(bills: [], leftToAssign: 4300, nextTaxDue: nil, includeBills: true, includeNet: true, includeTaxes: true, now: now, calendar: utc)
        #expect(waiting.map(\.id) == ["net"])
        #expect(waiting.first.map { utc.dateComponents([.day, .hour], from: $0.date) } == DateComponents(day: 17, hour: 9))
        #expect(ReminderSchedule.plan(bills: [], leftToAssign: 0.5, nextTaxDue: nil, includeBills: true, includeNet: true, includeTaxes: true, now: now, calendar: utc).isEmpty)
    }

    @Test func taxesAWeekBeforeTheDueDate() {
        let due = (date: d(2027, 1, 15, 0), amount: 3200.0, quarter: 4)
        let plans = ReminderSchedule.plan(bills: [], leftToAssign: 0, nextTaxDue: due, includeBills: false, includeNet: false, includeTaxes: true, now: now, calendar: utc)
        #expect(plans.map(\.id) == ["tax|2027-01"])
        #expect(plans.first.map { utc.dateComponents([.month, .day, .hour], from: $0.date) } == DateComponents(month: 1, day: 8, hour: 9))
        // Within the last week, or nothing due: no reminder.
        #expect(ReminderSchedule.plan(bills: [], leftToAssign: 0, nextTaxDue: (d(2026, 10, 20), 3200, 4), includeBills: false, includeNet: false, includeTaxes: true, now: now, calendar: utc).isEmpty)
        #expect(ReminderSchedule.plan(bills: [], leftToAssign: 0, nextTaxDue: (d(2027, 1, 15), 0, 4), includeBills: false, includeNet: false, includeTaxes: true, now: now, calendar: utc).isEmpty)
    }

    @Test func switchedOffKindsAreLeftOut() {
        let plans = ReminderSchedule.plan(bills: bills, leftToAssign: 4300, nextTaxDue: (d(2027, 1, 15), 3200, 4), includeBills: false, includeNet: false, includeTaxes: false, now: now, calendar: utc)
        #expect(plans.isEmpty)
    }
}

@Suite struct PlannerYearTests {
    @Test func lastYearUntilItsJanuaryPaymentIsDue() {
        #expect(EstimatedTax.plannerYear(now: d(2027, 1, 15), calendar: utc) == 2026)   // due Jan 15, 2027
        #expect(EstimatedTax.plannerYear(now: d(2027, 1, 16), calendar: utc) == 2027)
        #expect(EstimatedTax.plannerYear(now: d(2029, 1, 16), calendar: utc) == 2028)   // Jan 15, 2029 is MLK Day: due the 16th
        #expect(EstimatedTax.plannerYear(now: d(2026, 10, 16), calendar: utc) == 2026)
    }
}
