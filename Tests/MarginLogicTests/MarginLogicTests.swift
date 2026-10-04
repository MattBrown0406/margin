import Foundation
import Testing
@testable import MarginLogic

private let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
private func spend(_ amount: Double, _ category: String, _ date: Date, scope: String = "personal", job: UUID? = nil) -> LedgerEntry {
    LedgerEntry(date: date, amount: amount, category: category, isIncome: false, ledgerScope: scope, jobID: job)
}
private func gross(_ amount: Double, _ date: Date, job: UUID, title: String = "Job") -> LedgerEntry {
    LedgerEntry(date: date, amount: amount, category: "Intervention income", isIncome: true, ledgerScope: "business", incomeKind: "gross", jobID: job, title: title)
}
private func net(_ amount: Double, _ date: Date, job: UUID? = nil) -> LedgerEntry {
    LedgerEntry(date: date, amount: amount, category: "Owner transfer", isIncome: true, ledgerScope: "personal", incomeKind: "net", jobID: job)
}
private let lines = [PlanLine(name: "Groceries", monthlyLimit: 600, isFlexible: true), PlanLine(name: "Fun", monthlyLimit: 300, isFlexible: true),
                     PlanLine(name: "Mortgage", monthlyLimit: 2000, isFlexible: false)]

@Suite struct MoneyInputTests {
    @Test(arguments: [("12.50", "en_US", 12.5), ("$1,234.56", "en_US", 1234.56), ("1,234", "en_US", 1234), ("12,50", "de_DE", 12.5),
                      ("1.234,56", "de_DE", 1234.56), ("1.234", "de_DE", 1234), ("12.50", "fr_FR", 12.5), ("1 234,56", "fr_FR", 1234.56)])
    func parses(text: String, locale: String, expected: Double) { #expect(Double(moneyInput: text, locale: Locale(identifier: locale)) == expected) }

    @Test(arguments: ["", "abc", "-5", "0", "0.004", "−3"])
    func rejects(text: String) { #expect(Double(moneyInput: text, locale: Locale(identifier: "en_US")) == nil) }
}

@Suite struct SafeToSpendTests {
    // Sept 2026 has 30 days; on the 21st there are 10 days left.
    let now = day(2026, 9, 21)

    @Test func spendingTodayDrawsDownTheAllowanceDollarForDollar() {
        let entries = [spend(400, "Groceries", day(2026, 9, 5)), spend(30, "Fun", now), spend(999, "Mortgage", day(2026, 9, 2)), spend(500, "Groceries", day(2026, 8, 30))]
        let safe = SafeToSpend.compute(entries: entries, lines: lines, now: now, calendar: calendar)
        #expect(safe.daysLeft == 10)
        #expect(safe.dailyAllowance == 50)      // (900 - 400) / 10
        #expect(safe.safeToday == 20)           // 50 - 30
        #expect(safe.flexibleLeft == 470)
    }

    @Test func businessSpendingNeverCounts() {
        let safe = SafeToSpend.compute(entries: [spend(800, "Groceries", now, scope: "business")], lines: lines, now: now, calendar: calendar)
        #expect(safe.safeToday == 90)
    }

    @Test func widgetSnapshotRollsOverAtMidnightAndExpiresAtMonthEnd() {
        let snapshot = WidgetSnapshot(entries: [spend(400, "Groceries", day(2026, 9, 5)), spend(30, "Fun", now)], lines: lines, now: now, calendar: calendar)
        #expect(snapshot.safeToSpend(at: now, calendar: calendar)?.safeToday == 20)
        let tomorrow = snapshot.safeToSpend(at: day(2026, 9, 22, 8), calendar: calendar)
        #expect(tomorrow?.spentToday == 0)
        #expect(tomorrow?.dailyAllowance == 470.0 / 9)
        #expect(snapshot.safeToSpend(at: day(2026, 10, 1), calendar: calendar) == nil)
        #expect(snapshot.safeToSpend(at: day(2026, 9, 20), calendar: calendar) == nil)
    }
}

@Suite struct ForecastTests {
    let now = day(2026, 10, 4)

    @Test func combinesReceivedAndBookedNetAndCarriesOverdueJobsIntoThisMonth() {
        let booked = [BookedJobInfo(id: UUID(), title: "Overdue", expectedDate: day(2026, 9, 20), expectedGross: 5000, expectedNet: 3000),
                      BookedJobInfo(id: UUID(), title: "Nov job", expectedDate: day(2026, 11, 10), expectedGross: 8000, expectedNet: 5000)]
        let months = CashFlowForecast.months(entries: [net(2000, day(2026, 10, 2)), net(9999, day(2026, 9, 2))], booked: booked, plannedMonthly: 4000, now: now, count: 3, calendar: calendar)
        #expect(months.count == 3)
        #expect(months[0].receivedNet == 2000)
        #expect(months[0].expectedNet == 3000)
        #expect(months[0].overdueJobs.map(\.title) == ["Overdue"])
        #expect(months[0].gap == 1000)
        #expect(months[1].gap == 1000)          // 5000 - 4000
        #expect(months[2].gap == -4000)
        #expect(months[2].cumulative == -2000)
        #expect(CashFlowForecast.firstShortfall(months)?.monthStart == day(2026, 12, 1, 0))
    }

    @Test func netRateComesFromJobsWithTransfers() {
        let a = UUID(), b = UUID()
        let entries = [gross(10000, day(2026, 8, 1), job: a), net(6000, day(2026, 8, 3), job: a), net(1000, day(2026, 8, 20), job: a), gross(5000, day(2026, 9, 1), job: b)]
        #expect(CashFlowForecast.historicalNetRate(entries: entries, now: now, calendar: calendar) == 0.7)
        #expect(CashFlowForecast.historicalNetRate(entries: [], now: now, calendar: calendar) == nil)
    }
}

@Suite struct JobProfitTests {
    @Test func profitCountsOnlyThatJobsBusinessExpensesIncludingRefunds() {
        let a = UUID(), b = UUID()
        let entries = [gross(7500, day(2026, 9, 1), job: a, title: "Bend"), spend(875, "Travel", day(2026, 8, 30), scope: "business", job: a),
                       spend(-75, "Travel", day(2026, 9, 3), scope: "business", job: a), spend(50, "Groceries", day(2026, 9, 2), job: a),
                       net(4000, day(2026, 9, 2), job: a), gross(5000, day(2026, 9, 10), job: b, title: "Eugene")]
        let jobs = JobProfit.summaries(entries: entries)
        #expect(jobs.map(\.title) == ["Eugene", "Bend"])
        #expect(jobs[1].expenses == 800)
        #expect(jobs[1].profit == 6700)
        #expect(jobs[1].transferred == 4000)
        let totals = JobProfit.totals(jobs)
        #expect(totals.profit == 11700)
        #expect(totals.averageProfit == 5850)
        #expect(totals.best?.title == "Bend")
    }

    @Test func scheduleCMapsCategoriesAndHalvesMeals() {
        let entries = [gross(20000, day(2026, 3, 1), job: UUID()), gross(9999, day(2025, 12, 31), job: UUID()),
                       spend(1000, "Travel", day(2026, 3, 2), scope: "business"), spend(400, "Lodging", day(2026, 3, 3), scope: "business"),
                       spend(200, "Meals", day(2026, 3, 3), scope: "business"), spend(300, "Software", day(2026, 4, 1), scope: "business"),
                       spend(500, "Groceries", day(2026, 4, 1))]
        let report = ScheduleC.report(entries: entries, year: 2026, calendar: calendar)
        #expect(report.grossReceipts == 20000)
        #expect(report.lines.map(\.line) == ["24a", "24b", "27a"])
        #expect(report.lines[0].amount == 1400)
        #expect(report.lines[1].amount == 100)
        #expect(report.totalExpenses == 1800)
        #expect(report.netProfit == 18200)
    }
}

@Suite struct AffordabilityTests {
    let now = day(2026, 10, 22)   // 10 days left in October
    var safe: SafeToSpend { .make(limit: 900, spentBeforeToday: 400, spentToday: 0, now: now, calendar: calendar) }

    func forecast(received: Double = 4000, booked: [BookedJobInfo] = []) -> [ForecastMonth] {
        CashFlowForecast.months(entries: [net(received, day(2026, 10, 2))], booked: booked, plannedMonthly: 4000, now: now, count: 4, calendar: calendar)
    }

    @Test func smallPurchaseIsComfortable() {
        let v = Affordability.evaluate(amount: 100, in: now, now: now, safe: safe, forecast: forecast(), calendar: calendar)
        #expect(v.level == .comfortable)
        #expect(v.newDailyAllowance == 40)
    }

    @Test func purchaseUsingMostOfTheMonthIsTight() {
        #expect(Affordability.evaluate(amount: 450, in: now, now: now, safe: safe, forecast: forecast(), calendar: calendar).level == .tight)
    }

    @Test func overspendIsTightOnlyWhenUnassignedIncomeCoversIt() {
        #expect(Affordability.evaluate(amount: 700, in: now, now: now, safe: safe, forecast: forecast(received: 4300), calendar: calendar).level == .tight)
        let v = Affordability.evaluate(amount: 700, in: now, now: now, safe: safe, forecast: forecast(), calendar: calendar)
        #expect(v.level == .notYet)
    }

    @Test func futurePurchaseUsesBookedSurplusOrSuggestsASetAside() {
        // November has to be covered too, or December's job only fills November's hole.
        let booked = [BookedJobInfo(id: UUID(), title: "Nov", expectedDate: day(2026, 11, 5), expectedGross: 6000, expectedNet: 4000),
                      BookedJobInfo(id: UUID(), title: "Dec", expectedDate: day(2026, 12, 5), expectedGross: 9000, expectedNet: 6000)]
        let december = day(2026, 12, 15)
        let yes = Affordability.evaluate(amount: 1200, in: december, now: now, safe: safe, forecast: forecast(booked: booked), calendar: calendar)
        #expect(yes.level == .comfortable)      // 2,000 surplus ≥ 1.5 × 1,200
        let decOnly = Affordability.evaluate(amount: 1200, in: december, now: now, safe: safe, forecast: forecast(booked: [booked[1]]), calendar: calendar)
        #expect(decOnly.level == .notYet)
        let no = Affordability.evaluate(amount: 1200, in: december, now: now, safe: safe, forecast: forecast(), calendar: calendar)
        #expect(no.level == .notYet)
        #expect(no.suggestedMonthlySetAside == 400)
    }
}
