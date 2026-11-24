import Foundation
import Testing
@testable import MarginLogic

@Suite struct PlanningTests {
    let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
    func date(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }
    func expense(_ value: Double, _ date: Date) -> LedgerEntry { .init(date: date, amount: value, category: "Food", isIncome: false, ledgerScope: "personal") }
    func plan(_ value: Double) -> [PlanLine] { [.init(name: "Food", monthlyLimit: value, isFlexible: true)] }

    @Test func delayedNetExposesFirstBillAndDeepestShortfallAcrossMonths() {
        let bills = [UpcomingCharge(name: "Rent", date: date(7, 1), amount: 500, isBudgetBill: true),
                     UpcomingCharge(name: "Phone", date: date(7, 2), amount: 50, isBudgetBill: true)]
        func scenario(_ payday: Date) -> BillCoverage {
            PaymentDelay.coverage(cash: 20, incomes: [(payday, 600)], bills: bills.reversed(), now: date(6, 25), through: date(7, 15), calendar: calendar)
        }
        #expect(scenario(date(7, 1)).buffer == 0)
        #expect(scenario(date(7, 15)).firstUncovered?.name == "Rent")
        #expect(scenario(date(7, 15)).buffer == 530)
    }

    @Test func changeExplainsBudgetPurchasesRefundsAndTheClock() {
        let yesterday = date(6, 28), now = date(6, 29)
        let prior = WidgetSnapshot(entries: [], lines: plan(300), now: yesterday, calendar: calendar)
        let result = SpendingChange.explain(entries: [expense(100, now), expense(-50, now)], lines: plan(400), previous: prior, now: now, calendar: calendar)
        #expect(result.observed)
        #expect(result.yesterday == 100 && result.today == 150)
        #expect(result.steps.map(\.amount) == [50, 50, -100, 50])
    }

    @Test func widgetAndTodayAgreeWhenScheduledPurchasesAndRefundsPost() {
        let now = date(6, 28), tomorrow = date(6, 29)
        let rows = [expense(40, tomorrow), expense(-90, tomorrow)]
        let snap = WidgetSnapshot(entries: rows, lines: plan(300), now: now, calendar: calendar)
        #expect(snap.spentBeforeToday == 40)
        for day in [now, tomorrow, date(6, 30)] {
            #expect(snap.safeToSpend(at: day, calendar: calendar) == SafeToSpend.compute(entries: rows, lines: plan(300), now: day, calendar: calendar))
        }
    }

    @Test func missingHistoryIsEstimatedAndNewMonthResetsSpending() {
        let now = date(7, 1), rows = [expense(300, date(6, 30))]
        let result = SpendingChange.explain(entries: rows, lines: plan(310), previous: nil, now: now, calendar: calendar)
        #expect(!result.observed)
        #expect(result.today == 10 && result.yesterday == 10)
        let prior = WidgetSnapshot(entries: rows, lines: plan(300), now: date(6, 30), calendar: calendar)
        let changed = SpendingChange.explain(entries: rows, lines: plan(310), previous: prior, now: now, calendar: calendar)
        #expect(changed.observed && changed.yesterday == 0)
        #expect(abs(changed.steps.map(\.amount).reduce(0,+) - 10) < 0.0001)
    }

    @Test func yesterdaySurvivesMultipleSavesAndRelaunch() throws {
        let name = "planning-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let before = WidgetSnapshot(entries: [], lines: plan(300), now: date(6, 28), calendar: calendar)
        let after = WidgetSnapshot(entries: [], lines: plan(350), now: date(6, 29), calendar: calendar)
        before.save(to: defaults); after.save(to: defaults); after.save(to: defaults)
        #expect(WidgetSnapshot.previous(from: defaults) == before)
        #expect(WidgetSnapshot.load(from: defaults) == after)
    }

    @Test func quoteCoversCostsAndTakeHomeAfterReserve() {
        let estimate = QuoteEstimate.calculate(hours: 10, hourly: 80, costs: 200, reservePercent: 20)
        #expect(QuoteEstimate.calculate(target: 800, costs: 200, reservePercent: 20)?.minimum == 1200)
        #expect(estimate?.minimum == 1200 && estimate?.reserve == 200 && estimate?.takeHome == 800)
        #expect(QuoteEstimate.calculate(hours: 1, hourly: 100, costs: 0, reservePercent: 15)?.minimum == 117.65)
        #expect(QuoteEstimate.calculate(hours: 0.01, hourly: 0.01, costs: 0, reservePercent: 0)?.minimum == 0.01)
        #expect(QuoteEstimate.calculate(hours: 10, hourly: 80, costs: 10, reservePercent: 100) == nil)
    }

    @Test func closeSeparatesOwnerTransfersAndRefunds() {
        let now = date(6, 4)
        let rows = [LedgerEntry(date: now, amount: 1000, category: "", isIncome: true, ledgerScope: "business", incomeKind: "gross"),
                    LedgerEntry(date: now, amount: 400, category: "", isIncome: true, ledgerScope: "personal", incomeKind: "net"),
                    expense(91.12, now), expense(-10.02, now)]
        let business = rows.compactMap(CloseLedger.business.movement).reduce(0,+)
        let personal = rows.compactMap(CloseLedger.personal.movement).reduce(0,+)
        #expect(business == 600)
        #expect(CloseBalance(opening: -50, ending: 268.90, movement: personal).difference == 0)
        #expect(CloseBalance(opening: 100, ending: 699.99, movement: business).difference == -0.01)
        #expect(planningNumber("-$50.75", signed: true) == -50.75)
        #expect(planningNumber("0.00") == 0 && planningNumber("") == nil && planningNumber("-3") == nil)
    }
}
