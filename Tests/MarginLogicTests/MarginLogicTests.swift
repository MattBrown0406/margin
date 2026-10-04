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

    @Test(arguments: ["", "abc", "-5", "0", "0.004", "−3", "Invoice #1042 $750.00", "3 for $10", "1e3", "50¢", "1 2", "1.234,5.6",
                      "5k", "50 cents", "Invoice 1042", "0,001"])
    func rejects(text: String) { #expect(Double(moneyInput: text, locale: Locale(identifier: "en_US")) == nil) }

    @Test(arguments: [("USD 40", 40.0), (".50", 0.5), ("1'234.50", 1234.5), ("$ 1,234,567", 1234567), ("€12", 12)])
    func acceptsCurrencyDecorations(text: String, expected: Double) { #expect(Double(moneyInput: text, locale: Locale(identifier: "en_US")) == expected) }
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

    @Test func aRefundTodayNeverShowsMoreThanIsLeft() {
        // $1,000 spent of a $900 limit, then a $200 refund today: $100 left, so safe today can't be $200.
        let safe = SafeToSpend.compute(entries: [spend(1000, "Groceries", day(2026, 9, 5)), spend(-200, "Groceries", now)], lines: lines, now: now, calendar: calendar)
        #expect(safe.flexibleLeft == 100)
        #expect(safe.safeToday == 100)
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

    @Test func longOverdueBookingsStopCounting() {
        let stale = BookedJobInfo(id: UUID(), title: "April", expectedDate: day(2026, 4, 10), expectedGross: 7000, expectedNet: 4500)
        let recent = BookedJobInfo(id: UUID(), title: "Sept", expectedDate: day(2026, 9, 15), expectedGross: 5000, expectedNet: 3000)
        let months = CashFlowForecast.months(entries: [], booked: [stale, recent], plannedMonthly: 0, now: now, count: 1, calendar: calendar)
        #expect(months[0].overdueJobs.map(\.title) == ["Sept"])
        #expect(months[0].expectedNet == 3000)
    }

    @Test func surplusCarriesIntoLaterMonthsBeforeWarningShort() {
        // October brings in $9,000 against a $4,000 plan; nothing booked for November.
        let months = CashFlowForecast.months(entries: [net(9000, day(2026, 10, 2))], booked: [], plannedMonthly: 4000, now: now, count: 3, calendar: calendar)
        #expect(months[1].isShort)                       // November on its own is short…
        #expect(months[1].cumulative == 1000)            // …but October's surplus covers it.
        #expect(CashFlowForecast.firstShortfall(months)?.monthStart == day(2026, 12, 1, 0))
    }

    @Test func recordedPaymentsMatchBookingsOnceAndRespectDismissals() {
        let paidByBank = UUID(), other = UUID(), claimed = UUID()
        let bend = BookedJobInfo(id: UUID(), title: "Bend intervention", expectedDate: day(2026, 10, 15), expectedGross: 7500, expectedNet: 4500)
        let eugene = BookedJobInfo(id: UUID(), title: "Eugene", expectedDate: day(2026, 10, 20), expectedGross: 6000, expectedNet: 3600)
        let entries = [gross(7400, day(2026, 10, 14), job: paidByBank, title: "BEND INTERVENTION"), gross(6000, day(2026, 10, 21), job: claimed),
                       gross(6100, day(2026, 12, 30), job: other)]
        let matches = CashFlowForecast.likelyPayments(for: [bend, eugene], entries: entries, claimed: [claimed], calendar: calendar)
        #expect(matches[bend.id]?.jobID == paidByBank)
        #expect(matches[eugene.id] == nil)                // its only candidate is claimed or out of range
        #expect(CashFlowForecast.unpaid([bend, eugene], entries: entries, claimed: [claimed], calendar: calendar).map(\.title) == ["Eugene"])
        var dismissed = bend; dismissed.ignoredPaymentIDs = [paidByBank]
        #expect(CashFlowForecast.likelyPayments(for: [dismissed], entries: entries, claimed: [], calendar: calendar).isEmpty)
    }

    @Test func aPreviousJobsPaymentNeverClosesANewBooking() {
        // A $7,500 job paid Sep 25; on Oct 4 a new $7,500 job is booked for Oct 20.
        let earlier = gross(7500, day(2026, 9, 25), job: UUID(), title: "Bend")
        let eugene = BookedJobInfo(id: UUID(), title: "Eugene", expectedDate: day(2026, 10, 20), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 10, 4))
        #expect(CashFlowForecast.likelyPayments(for: [eugene], entries: [earlier], claimed: [], calendar: calendar).isEmpty)
    }

    @Test func aPaymentAsLateAsTheOverdueGraceStillClosesTheBooking() {
        // Expected Aug 8, paid Oct 2 (55 days late); the booking still counts in October until matched.
        let job = UUID()
        let bend = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 8, 8), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 7, 20))
        let paid = [gross(7500, day(2026, 10, 2), job: job, title: "Bend"), net(4500, day(2026, 10, 2), job: job)]
        #expect(CashFlowForecast.unpaid([bend], entries: paid, claimed: [], calendar: calendar).isEmpty)
        let months = CashFlowForecast.months(entries: paid, booked: CashFlowForecast.unpaid([bend], entries: paid, claimed: [], calendar: calendar),
                                             plannedMonthly: 5000, now: now, count: 1, calendar: calendar)
        #expect(months[0].gap == -500)
    }

    @Test func aStaleUnpaidBookingNeverTakesANewerJobsPayment() {
        // "Bend" A was expected Aug 1 and never paid; "Bend" B was expected Sep 25 and paid Sep 28.
        let job = UUID()
        let a = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 8, 1), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 7, 1))
        let b = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 9, 25), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 9, 1))
        let paid = [gross(7500, day(2026, 9, 28), job: job, title: "Bend"), net(4500, day(2026, 9, 29), job: job)]
        let matches = CashFlowForecast.likelyPayments(for: [a, b], entries: paid, claimed: [], calendar: calendar)
        #expect(matches[b.id]?.jobID == job)
        #expect(matches[a.id] == nil)
        let months = CashFlowForecast.months(entries: paid, booked: CashFlowForecast.unpaid([a, b], entries: paid, claimed: [], calendar: calendar),
                                             plannedMonthly: 0, now: now, count: 1, calendar: calendar)
        #expect(months[0].expectedNet == 0)   // A is past the grace period; B is paid
    }

    @Test func aSameTitleBookingBeatsAnAmountOnlyMatch() {
        let smith = BookedJobInfo(id: UUID(), title: "Smith", expectedDate: day(2026, 9, 28), expectedGross: 5000, expectedNet: 3000, bookedAt: day(2026, 9, 1))
        let jones = BookedJobInfo(id: UUID(), title: "Jones", expectedDate: day(2026, 11, 3), expectedGross: 5100, expectedNet: 3060, bookedAt: day(2026, 9, 1))
        let pay = UUID(), entries = [gross(5100, day(2026, 10, 5), job: pay, title: "Jones")]
        let matches = CashFlowForecast.likelyPayments(for: [smith, jones], entries: entries, claimed: [], calendar: calendar)
        #expect(matches[jones.id]?.jobID == pay)
        #expect(matches[smith.id] == nil)
    }

    @Test func aTrackedJobsOwnTransferNeverClosesTheNextBooking() {
        // October's Gross is recorded; its transfer was imported "Not linked". November's booking stays expected.
        let oct = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 10, 1), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 9, 1))
        let nov = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 11, 1), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 9, 1))
        let entries = [gross(7500, day(2026, 10, 1), job: UUID(), title: "Bend"), net(4500, day(2026, 10, 3), job: UUID())]
        let matches = CashFlowForecast.likelyPayments(for: [oct, nov], entries: entries, claimed: [], calendar: calendar)
        #expect(matches[oct.id]?.isGross == true)
        #expect(matches[nov.id] == nil)
        let paidOct = UUID()
        let afterConfirm = [gross(7500, day(2026, 10, 1), job: paidOct, title: "Bend"), net(4500, day(2026, 10, 3), job: UUID())]
        #expect(CashFlowForecast.likelyPayments(for: [nov], entries: afterConfirm, claimed: [paidOct], calendar: calendar).isEmpty)
    }

    @Test func netStaysExpectedUntilTheTransferAfterTheGrossArrives() {
        let bend = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 10, 10), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 9, 1))
        let job = UUID()
        let grossOnly = [gross(7500, day(2026, 10, 3), job: job, title: "Bend")]
        let open = CashFlowForecast.months(entries: grossOnly, booked: CashFlowForecast.expectedNet(open: [bend], paid: [], entries: grossOnly, calendar: calendar),
                                           plannedMonthly: 4500, now: now, count: 1, calendar: calendar)
        #expect(open[0].gap == 0)                               // Gross in, Net still expected
        // The same once confirmed paid ("That's it"), until the linked transfer is recorded.
        #expect(CashFlowForecast.expectedNet(open: [], paid: [(bend, job)], entries: grossOnly, calendar: calendar).count == 1)
        let transferred = grossOnly + [net(4500, day(2026, 10, 4), job: job)]
        #expect(CashFlowForecast.expectedNet(open: [], paid: [(bend, job)], entries: transferred, calendar: calendar).isEmpty)
        #expect(CashFlowForecast.expectedNet(open: [bend], paid: [], entries: transferred, calendar: calendar).isEmpty)
    }

    @Test func anUnlinkedNetTransferCanCloseABooking() {
        // Only the personal account is connected: the $4,500 owner transfer arrives without a recorded Gross.
        let transfer = net(4500, day(2026, 10, 18), job: UUID())
        let bend = BookedJobInfo(id: UUID(), title: "Bend", expectedDate: day(2026, 10, 15), expectedGross: 7500, expectedNet: 4500, bookedAt: day(2026, 10, 1))
        #expect(CashFlowForecast.unpaid([bend], entries: [transfer], claimed: [], calendar: calendar).isEmpty)
        // A Net already linked to a recorded Gross is that job's transfer, not this booking's.
        let linkedJob = UUID()
        let linked = [gross(9000, day(2026, 9, 1), job: linkedJob), net(4500, day(2026, 10, 18), job: linkedJob)]
        #expect(CashFlowForecast.unpaid([bend], entries: linked, claimed: [], calendar: calendar).count == 1)
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

    @Test func neverComfortableWhileThisMonthsPlanIsUnfunded() {
        let v = Affordability.evaluate(amount: 100, in: now, now: now, safe: safe, forecast: forecast(received: 0), calendar: calendar)
        #expect(v.level == .tight)
        #expect(v.details.contains { $0.contains("short of funded") })
    }

    @Test func bookedButUnreceivedNetIsNeverComfortable() {
        let booked = [BookedJobInfo(id: UUID(), title: "Late Oct", expectedDate: day(2026, 10, 28), expectedGross: 12000, expectedNet: 9000)]
        let v = Affordability.evaluate(amount: 100, in: now, now: now, safe: safe, forecast: forecast(received: 0, booked: booked), calendar: calendar)
        #expect(v.level == .tight)
        #expect(v.details.contains { $0.contains("assumes") })
    }

    @Test func notThisMonthNeverPointsBackAtThisMonth() {
        let overdue = BookedJobInfo(id: UUID(), title: "Late", expectedDate: day(2026, 9, 25), expectedGross: 5000, expectedNet: 3000)
        let v = Affordability.evaluate(amount: 700, in: now, now: now, safe: .make(limit: 900, spentBeforeToday: 400, spentToday: 0, now: now, calendar: calendar),
                                       forecast: forecast(booked: [overdue]), calendar: calendar)
        #expect(v.level == .notYet)
        #expect(v.fitsInMonth.map { !calendar.isSameMonth($0, now) } ?? true)
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
        // The plan is $8,000 short by December, so the set-aside covers that deficit plus the purchase.
        #expect(no.suggestedMonthlySetAside == (1200 + 8000) / 3.0)
    }
}

private func acmeGross(_ a: Double, _ date: Date, _ job: UUID, _ title: String = "Acme") -> LedgerEntry {
    LedgerEntry(date: date, amount: a, category: "Intervention income", isIncome: true, ledgerScope: "business", incomeKind: "gross", jobID: job, title: title)
}
private func acmeNet(_ a: Double, _ date: Date, _ job: UUID, _ title: String = "Acme") -> LedgerEntry {
    LedgerEntry(date: date, amount: a, category: "Owner transfer", isIncome: true, ledgerScope: "personal", incomeKind: "net", jobID: job, title: title)
}

/// Regression tests for booking↔payment edge cases found by audit round 6.
@Suite struct BookingEdgeCaseTests {
    let now = day(2026, 10, 22)

    // 1. Net installments: first partial transfer erases the whole remaining expected Net.
    @Test func installmentDropsRemainingNet() {
        let booking = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 12), expectedGross: 10000, expectedNet: 6000, bookedAt: day(2026, 9, 1))
        let job = UUID()
        let entries = [acmeGross(10000, day(2026, 10, 10), job), acmeNet(1000, day(2026, 10, 15), job)]
        // open + matched
        let open = CashFlowForecast.expectedNet(open: [booking], paid: [], entries: entries, calendar: calendar)
        // confirmed paid
        let paid = CashFlowForecast.expectedNet(open: [], paid: [(booking, job)], entries: entries, calendar: calendar)
        let m = CashFlowForecast.months(entries: entries, booked: open, plannedMonthly: 6000, now: now, count: 1, calendar: calendar)
        #expect(m[0].receivedNet + m[0].expectedNet == 6000)   // truth: 1000 in + 5000 still to transfer
    }

    // Round 7: the estimate is rarely exact; a transfer close to it finishes the job, a small first one doesn't.
    @Test func aTransferNearTheEstimateFinishesTheJobButAnInstalmentDoesNot() {
        let booking = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 12), expectedGross: 10000, expectedNet: 6000, bookedAt: day(2026, 9, 1))
        let job = UUID()
        let nearEstimate = [acmeGross(10000, day(2026, 10, 10), job), acmeNet(5000, day(2026, 10, 15), job)]
        #expect(CashFlowForecast.expectedNet(open: [], paid: [(booking, job)], entries: nearEstimate, calendar: calendar).isEmpty)
        let instalment = [acmeGross(10000, day(2026, 10, 10), job), acmeNet(1000, day(2026, 10, 15), job)]
        #expect(CashFlowForecast.expectedNet(open: [], paid: [(booking, job)], entries: instalment, calendar: calendar).first?.expectedNet == 5000)
    }

    @Test func aSettledBookingsPaymentNeverMatchesAnotherBooking() {
        let settledPayment = UUID()
        let next = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 20), expectedGross: 10000, expectedNet: 6000, bookedAt: day(2026, 10, 1))
        let entries = [acmeGross(10000, day(2026, 10, 18), settledPayment)]
        #expect(CashFlowForecast.expectedNet(open: [next], paid: [], entries: entries, alsoClaimed: [settledPayment], calendar: calendar).first?.expectedNet == 6000)
    }

    @Test func aConfirmedNetOnlyPaymentIsNeverReusedAsAnotherJobsTransfer() {
        // Booking A was confirmed paid by linking a Net with no Gross; booking B's Gross arrived and awaits its Net.
        let a = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 5), expectedGross: 10000, expectedNet: 6000, bookedAt: day(2026, 9, 1))
        let b = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 8), expectedGross: 10000, expectedNet: 6000, bookedAt: day(2026, 9, 1))
        let aPayment = UUID(), bJob = UUID()
        let entries = [acmeNet(6000, day(2026, 10, 9), aPayment), acmeGross(10000, day(2026, 10, 8), bJob)]
        #expect(CashFlowForecast.expectedNet(open: [], paid: [(a, aPayment), (b, bJob)], entries: entries, calendar: calendar).first?.expectedNet == 6000)
    }

    // 2. Gross tracker imports the Net transfer unlinked (BankSync default "Not linked").
    @Test func unlinkedNetAfterMatchedGrossDoubleCounts() {
        let booking = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 12), expectedGross: 10000, expectedNet: 6000, bookedAt: day(2026, 9, 1))
        let entries = [acmeGross(10000, day(2026, 10, 10), UUID()), acmeNet(6000, day(2026, 10, 15), UUID(), "ONLINE TRANSFER FROM CHK 1234")]
        let open = CashFlowForecast.expectedNet(open: [booking], paid: [], entries: entries, calendar: calendar)
        let m = CashFlowForecast.months(entries: entries, booked: open, plannedMonthly: 10000, now: now, count: 1, calendar: calendar)
        #expect(m[0].receivedNet + m[0].expectedNet == 6000)
    }

    // 3a. Recurring client, two bookings in a month: amount ignored among same-title matches.
    @Test func sameTitleIgnoresAmount() {
        let a = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 5), expectedGross: 5000, expectedNet: 3000, bookedAt: day(2026, 9, 1))
        let b = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 20), expectedGross: 3000, expectedNet: 1800, bookedAt: day(2026, 9, 1))
        let job = UUID()
        let entries = [acmeGross(3000, day(2026, 10, 6), job), acmeNet(1800, day(2026, 10, 8), job)]
        let likely = CashFlowForecast.likelyPayments(for: [a, b], entries: entries, claimed: [], calendar: calendar)
        let exp = CashFlowForecast.expectedNet(open: [a, b], paid: [], entries: entries, calendar: calendar)
        let m = CashFlowForecast.months(entries: entries, booked: exp, plannedMonthly: 0, now: now, count: 1, calendar: calendar)
        #expect(likely[b.id]?.jobID == job)
    }

    // 3b. A's exact-amount Gross arrives late, closer to B's date.
    @Test func lateExactAmountGoesToOtherBooking() {
        let a = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 5), expectedGross: 5000, expectedNet: 3000, bookedAt: day(2026, 9, 1))
        let b = BookedJobInfo(id: UUID(), title: "Acme", expectedDate: day(2026, 10, 20), expectedGross: 3000, expectedNet: 1800, bookedAt: day(2026, 9, 1))
        let job = UUID()
        let likely = CashFlowForecast.likelyPayments(for: [a, b], entries: [acmeGross(5000, day(2026, 10, 14), job)], claimed: [], calendar: calendar)
        #expect(likely[a.id]?.jobID == job)
    }

    // 4. Future purchase drains surplus a later booked month needs.
    @Test func futurePurchaseCreatesLaterShortfall() {
        let nov = BookedJobInfo(id: UUID(), title: "Nov", expectedDate: day(2026, 11, 5), expectedGross: 13000, expectedNet: 9000)
        let dec = BookedJobInfo(id: UUID(), title: "Dec", expectedDate: day(2026, 12, 5), expectedGross: 2000, expectedNet: 1000)
        let f = CashFlowForecast.months(entries: [acmeNet(4000, day(2026, 10, 2), UUID())], booked: [nov, dec], plannedMonthly: 4000, now: now, count: 3, calendar: calendar)
        let safe = SafeToSpend.make(limit: 900, spentBeforeToday: 400, spentToday: 0, now: now, calendar: calendar)
        let v = Affordability.evaluate(amount: 3000, in: day(2026, 11, 15), now: now, safe: safe, forecast: f, calendar: calendar)
        #expect(v.level == .notYet)
    }
}
