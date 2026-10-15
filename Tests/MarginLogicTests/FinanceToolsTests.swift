import Foundation
import Testing
@testable import MarginLogic

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date { utc.date(from: DateComponents(year: y, month: m, day: day, hour: h))! }
private func debt(_ name: String, _ balance: Double, apr: Double, min: Double, rank: Int = 0) -> DebtInfo {
    DebtInfo(id: UUID(), name: name, balance: balance, apr: apr, minimumPayment: min, customRank: rank)
}
private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

@Suite struct DebtPayoffTests {
    @Test func paidOffPaymentsRollIntoTheNextDebt() {
        // Budget $200 (two $100 minimums, no extra). A is gone in month 3; from month 4 B gets the whole $200.
        let a = debt("A", 300, apr: 0, min: 100), b = debt("B", 1000, apr: 0, min: 100)
        let c = DebtPayoff.compare([b, a], strategy: .snowball, extra: 0)
        #expect(c.plan.monthlyBudget == 200)
        #expect(c.plan.outcomes.map(\.name) == ["A", "B"])
        #expect(c.plan.outcomes.map(\.payoffMonth) == [3, 7])
        #expect(c.plan.months[3].payments[b.id] == 200)          // month 4: B's $100 plus A's rolled-over $100
        #expect(c.plan.months.allSatisfy { $0.payments.values.reduce(0, +) <= 200.005 })
        #expect(c.minimumsOnly.monthsToDebtFree == 10)            // B alone at $100 a month
        #expect(c.monthsSaved == 3)
        #expect(c.plan.totalPaid == 1300)
    }

    @Test func aDebtPaidOffMidMonthPassesTheRestOnTheSameMonth() {
        let a = debt("A", 50, apr: 0, min: 25), b = debt("B", 1000, apr: 0, min: 25)
        let plan = DebtPayoff.plan([a, b], strategy: .snowball, extra: 100)
        #expect(plan.outcomes.first { $0.name == "A" }?.payoffMonth == 1)
        #expect(plan.months[0].payments[b.id] == 100)             // 25 minimum + 75 left after A's last $25
        #expect(plan.months[0].focus == a.id)
    }

    @Test func strategiesOrderDebtsAsTheirNamesSay() {
        let cardA = debt("Card A", 2000, apr: 24, min: 50, rank: 2), cardB = debt("Card B", 500, apr: 18, min: 25, rank: 0), loan = debt("Loan C", 8000, apr: 6, min: 200, rank: 1)
        let all = [loan, cardA, cardB]
        #expect(PayoffStrategy.snowball.order(all).map(\.name) == ["Card B", "Card A", "Loan C"])
        #expect(PayoffStrategy.avalanche.order(all).map(\.name) == ["Card A", "Card B", "Loan C"])
        // A and C both cost $40 a month in interest: the higher rate wins the tie.
        #expect(PayoffStrategy.interestCost.order(all).map(\.name) == ["Card A", "Loan C", "Card B"])
        // Balance ÷ minimum: B 20, A 40, C 40 (tie → higher rate).
        #expect(PayoffStrategy.cashFlow.order(all).map(\.name) == ["Card B", "Card A", "Loan C"])
        #expect(PayoffStrategy.custom.order(all).map(\.name) == ["Card B", "Loan C", "Card A"])
    }

    @Test func interestAccruesMonthlyAndIsPaid() {
        // $1,000 at 12% (1% a month) with $100 payments takes 11 months.
        let one = debt("Card", 1000, apr: 12, min: 100)
        let plan = DebtPayoff.plan([one], strategy: .avalanche, extra: 0)
        #expect(plan.monthsToDebtFree == 11)
        #expect(plan.months[0].interest == 10)
        #expect(near(plan.totalPaid, 1000 + plan.totalInterest))
        #expect(plan.totalInterest > 50 && plan.totalInterest < 70)
    }

    @Test func avalanchePaysLessInterestThanSnowballWhenTheBigDebtIsExpensive() {
        let all = [debt("Small cheap", 1000, apr: 5, min: 30), debt("Big expensive", 6000, apr: 26, min: 150)]
        let snowball = DebtPayoff.plan(all, strategy: .snowball, extra: 300), avalanche = DebtPayoff.plan(all, strategy: .avalanche, extra: 300)
        #expect(avalanche.totalInterest < snowball.totalInterest)
        #expect(snowball.monthlyBudget == avalanche.monthlyBudget)
    }

    @Test func aMinimumBelowTheInterestNeverFinishesWithoutExtra() {
        let stuck = debt("Store card", 1000, apr: 24, min: 15)   // $20 interest a month
        let c = DebtPayoff.compare([stuck], strategy: .snowball, extra: 50)
        #expect(c.plan.minimumBelowInterest == ["Store card"])
        #expect(c.minimumsOnly.monthsToDebtFree == nil)
        #expect(c.plan.monthsToDebtFree != nil)
        #expect(c.interestSaved == nil)                          // the baseline never ends, so savings are open-ended
    }

    @Test func aDebtPaidOffInRealLifeKeepsItsPaymentGoingToTheOthers() {
        // The $100 card was paid off last month; its $100 keeps going to debt, so the budget stays $300 + $50 extra.
        let paid = debt("Paid card", 0, apr: 20, min: 100), car = debt("Car", 5000, apr: 0, min: 200)
        let c = DebtPayoff.compare([paid, car], strategy: .snowball, extra: 50)
        #expect(c.plan.monthlyBudget == 350)
        #expect(c.plan.months[0].payments[car.id] == 350)
        #expect(c.minimumsOnly.monthlyBudget == 200)            // the baseline is minimums only
        #expect(c.plan.outcomes.map(\.name) == ["Car"])
    }

    @Test func paymentsAlreadyMadeThisMonthArentPlannedAgain() {
        // $3,000 at 24% with $100 minimum + $200 extra: 12 months. Paying this month's $300 doesn't make it 11.
        var card = debt("Card", 3000, apr: 24, min: 100)
        let before = DebtPayoff.plan([card], strategy: .snowball, extra: 200)
        card.balance = 2700; card.paidThisMonth = 300
        let after = DebtPayoff.plan([card], strategy: .snowball, extra: 200)
        #expect(after.monthsToDebtFree == before.monthsToDebtFree)
        #expect((after.months.first?.payments.values.reduce(0, +) ?? -1) == 0)   // nothing more due this month
        // Half paid: only the rest of this month's $300 is planned.
        var half = debt("Card", 2850, apr: 24, min: 100); half.paidThisMonth = 150
        #expect(DebtPayoff.plan([half], strategy: .snowball, extra: 200).months.first?.payments[half.id] == 150)
    }

    @Test func noDebtsMeansNothingToPlan() {
        let plan = DebtPayoff.plan([debt("Paid", 0, apr: 20, min: 50)], strategy: .snowball, extra: 100)
        #expect(plan.monthsToDebtFree == 0)
        #expect(plan.months.isEmpty)
        #expect(plan.monthlyBudget == 0)
    }
}

@Suite struct SteadyPaycheckTests {
    let now = d(2026, 10, 15)
    func net(_ amount: Double, _ date: Date) -> LedgerEntry {
        LedgerEntry(date: date, amount: amount, category: "Owner transfer", isIncome: true, ledgerScope: "personal", incomeKind: "net")
    }

    @Test func averagesCompleteMonthsSinceTheFirstTransferAndProjectsTheBuffer() {
        // Jul 3,000, Aug nothing, Sep 6,000 → 3 months, average 3,000. October's Net is this month and isn't history.
        let entries = [net(3000, d(2026, 7, 10)), net(6000, d(2026, 9, 2)), net(9999, d(2026, 10, 3))]
        let booked = [BookedJobInfo(id: UUID(), title: "Nov", expectedDate: d(2026, 11, 5), expectedGross: 6000, expectedNet: 4000)]
        let forecast = CashFlowForecast.months(entries: entries, booked: booked, plannedMonthly: 2500, now: now, count: 6, calendar: utc)
        let plan = SteadyPaycheck.plan(entries: entries, chosenPaycheck: 0, buffer: 5000, plannedMonthly: 2500, forecast: forecast, now: now, calendar: utc)
        #expect(plan.monthsOfHistory == 3)
        #expect(plan.averageMonthlyNet == 3000)
        #expect(plan.lowestMonthNet == 0)
        #expect(plan.suggestedPaycheck == 3000)
        #expect(plan.coversPlan)
        #expect(near(plan.runwayMonths ?? 0, 5000.0 / 3000))
        // Oct 5,000 (paycheck already taken) → Nov +4,000 −3,000 = 6,000 → Dec 3,000 → Jan 0 → Feb −3,000.
        #expect(plan.projection.map(\.endBalance) == [5000, 6000, 3000, 0, -3000, -6000])
        #expect(plan.firstEmptyMonth.map { utc.isSameMonth($0, d(2027, 2, 1)) } == true)
    }

    @Test func aChosenPaycheckOverridesTheSuggestionAndOnlyTheLastYearCounts() {
        let entries = [net(50_000, d(2025, 1, 10)), net(2475, d(2026, 9, 2))]
        let plan = SteadyPaycheck.plan(entries: entries, chosenPaycheck: 0, buffer: 0, plannedMonthly: 3000, forecast: [], now: now, calendar: utc)
        #expect(plan.monthsOfHistory == 12)                      // Oct 2025 – Sep 2026
        #expect(near(plan.averageMonthlyNet, 2475.0 / 12))
        #expect(plan.suggestedPaycheck == 200)                   // 206.25 rounded down to $50
        #expect(!plan.coversPlan)
        let chosen = SteadyPaycheck.plan(entries: entries, chosenPaycheck: 3200, buffer: 6400, plannedMonthly: 3000, forecast: [], now: now, calendar: utc)
        #expect(chosen.paycheck == 3200 && chosen.runwayMonths == 2)
    }

    @Test func noHistoryMeansNoSuggestion() {
        let plan = SteadyPaycheck.plan(entries: [], chosenPaycheck: 0, buffer: 1000, plannedMonthly: 3000, forecast: [], now: now, calendar: utc)
        #expect(plan.monthsOfHistory == 0 && plan.suggestedPaycheck == 0 && plan.runwayMonths == nil)
    }
}

@Suite struct EstimatedTaxTests {
    let table = TaxYearTable.y2026
    func report(gross: Double, expenses: Double) -> ScheduleCReport {
        ScheduleCReport(year: 2026, grossReceipts: gross, lines: expenses > 0 ? [ScheduleCLine(line: "27a", label: "Other expenses", amount: expenses)] : [])
    }

    @Test func singleFilerOnAHundredThousandOfProfit() {
        // SE: 92,350 × 15.3% = 14,129.55. AGI 100,000 − 7,064.775 = 92,935.225; taxable 76,835.225.
        // Income tax: 1,240 + 4,560 + 22% × 26,435.225 = 11,615.75.
        let e = EstimatedTax.estimate(profit: 100_000, profile: TaxProfile(), table: table)
        #expect(near(e.selfEmploymentTax, 14_129.55))
        #expect(near(e.householdIncomeTax, 11_615.75))
        #expect(e.otherIncomeTax == 0)
        #expect(near(e.federalTotal, 25_745.30))
    }

    @Test func qbiAndStateTaxAreOptIn() {
        var profile = TaxProfile(); profile.includeQBI = true; profile.stateRate = 5
        let e = EstimatedTax.estimate(profit: 100_000, profile: profile, table: table)
        // QBI = min(20% × 92,935.225, 20% × 76,835.225) = 15,367.045 → taxable 61,468.18.
        #expect(near(e.householdIncomeTax, 1_240 + 4_560 + 0.22 * (61_468.18 - 50_400)))
        #expect(near(e.stateTax, 0.05 * 92_935.225))
    }

    @Test func otherIncomeSetsTheBracketWithholdingCoversItsShareAndOnlyOwnWagesUseUpTheWageBase() {
        var profile = TaxProfile(); profile.filingStatus = .marriedJoint; profile.otherIncome = 180_000; profile.withholding = 20_000
        let e = EstimatedTax.estimate(profit: 50_000, profile: profile, table: table)
        // A spouse's wages don't touch your Social Security wage base: full 15.3% on earnings of 46,175.
        // Wages + earnings stay under $250,000, so no Additional Medicare Tax.
        let full: Double = 0.153 * 46_175
        #expect(near(e.selfEmploymentTax, full))
        var own = profile; own.ownWages = 180_000   // your own W-2 job: only $4,500 of the wage base is left
        let social: Double = 0.124 * 4_500, medicare: Double = 0.029 * 46_175
        #expect(near(EstimatedTax.estimate(profit: 50_000, profile: own, table: table).selfEmploymentTax, social + medicare))
        #expect(e.federalIncomeTax > 0 && e.otherIncomeTax > 0)
        #expect(near(e.federalIncomeTax, e.householdIncomeTax - e.otherIncomeTax))
        let plan = EstimatedTax.plan(report: report(gross: 50_000, expenses: 0), profile: profile, paidFederal: 0, paidState: 0, reserve: 0, now: d(2027, 1, 1, 0), calendar: utc)
        #expect(near(plan.recommendedFederal, max(0, e.federalTotal - 20_000)))
    }

    @Test func noSelfEmploymentTaxUnderFourHundredOfEarnings() {
        #expect(EstimatedTax.estimate(profit: 400, profile: TaxProfile(), table: table).selfEmploymentTax == 0)
    }

    @Test func dueDatesSkipWeekends() {
        let dates = EstimatedTax.dueDates(taxYear: 2026, calendar: utc).map { utc.dateComponents([.year, .month, .day], from: $0) }
        #expect(dates.map { [$0.year!, $0.month!, $0.day!] } == [[2026, 4, 15], [2026, 6, 15], [2026, 9, 15], [2027, 1, 15]])
        // Apr 15, 2028 is a Saturday and Monday the 17th is DC Emancipation Day (observed): due Tuesday the 18th.
        #expect(EstimatedTax.dueDates(taxYear: 2028, calendar: utc).first.map { utc.component(.day, from: $0) } == 18)
        // Apr 15, 2022 was Emancipation Day observed (the 16th was a Saturday): due Monday the 18th.
        #expect(EstimatedTax.dueDates(taxYear: 2022, calendar: utc).first.map { utc.component(.day, from: $0) } == 18)
        // Jan 15, 2029 is Martin Luther King Jr. Day: the 2028 Q4 payment is due the 16th.
        #expect(EstimatedTax.dueDates(taxYear: 2028, calendar: utc).last.map { utc.component(.day, from: $0) } == 16)
    }

    @Test func planScalesYearToDateAndCountsWhatsDueByTheNextDate() {
        // July 2: half the year gone → $40k of profit projects to ~$80k.
        let now = d(2026, 7, 2, 12)
        let plan = EstimatedTax.plan(report: report(gross: 60_000, expenses: 20_000), profile: TaxProfile(), paidFederal: 1000, paidState: 0, reserve: 2000, now: now, calendar: utc)
        #expect(plan.projectedProfit > 79_000 && plan.projectedProfit < 81_000)
        #expect(plan.next?.quarter == 3)
        #expect(near(plan.dueNextFederal, plan.recommendedFederal * 3 / 4 - 1000))
        #expect(near(plan.stillToSave, plan.recommendedFederal - 1000 - 2000))
        #expect(near(plan.monthlyToSave, plan.stillToSave / 6))  // July through December
        #expect(near(plan.setAsideRate, plan.estimate.businessTotal / plan.projectedGross))
        // Safe harbor: last year's $9,000 is less than 90% of this year's tax.
        var profile = TaxProfile(); profile.priorYearTax = 9000
        #expect(EstimatedTax.plan(report: report(gross: 60_000, expenses: 20_000), profile: profile, paidFederal: 0, paidState: 0, reserve: 0, now: now, calendar: utc).minimumFederal == 9000)
        profile.priorYearHighIncome = true
        #expect(near(EstimatedTax.plan(report: report(gross: 60_000, expenses: 20_000), profile: profile, paidFederal: 0, paidState: 0, reserve: 0, now: now, calendar: utc).minimumFederal, 9900))
    }

    @Test func underAThousandOwedHasNoPenalty() {
        let plan = EstimatedTax.plan(report: report(gross: 6_000, expenses: 0), profile: TaxProfile(), paidFederal: 0, paidState: 0, reserve: 0, now: d(2027, 1, 1, 0), calendar: utc)
        #expect(plan.recommendedFederal > 0 && plan.recommendedFederal < 1000)
        #expect(plan.minimumFederal == 0)
    }

    @Test func aLossOwesNothing() {
        let plan = EstimatedTax.plan(report: report(gross: 5_000, expenses: 9_000), profile: TaxProfile(), paidFederal: 0, paidState: 0, reserve: 0, now: d(2026, 5, 1), calendar: utc)
        #expect(plan.recommendedFederal == 0 && plan.estimate.businessTotal == 0 && plan.dueNextFederal == 0)
    }
}

@Suite struct NetAllocationTests {
    let now = d(2026, 10, 10)
    let lines = [PlanLine(name: "Mortgage", monthlyLimit: 2000, isFlexible: false, dueDay: 3),
                 PlanLine(name: "Utilities", monthlyLimit: 300, isFlexible: false, dueDay: 20),
                 PlanLine(name: "Tax reserve", monthlyLimit: 800, isFlexible: false, dueDay: 25),
                 PlanLine(name: "Peace Number", monthlyLimit: 500, isFlexible: false, isFund: true),
                 PlanLine(name: "Giving", monthlyLimit: 200, isFlexible: false),
                 PlanLine(name: "Groceries", monthlyLimit: 600, isFlexible: true),
                 PlanLine(name: "Fun", monthlyLimit: 200, isFlexible: true)]

    @Test func billsDueBeforeTheNextJobComeFirstThenTaxesThenFunds() {
        let targets = NetAllocator.targets(lines: lines, taxLineName: "Tax reserve", assigned: [:])
        #expect(targets.first { $0.name == "Tax reserve" }?.kind == .tax)    // a due day doesn't make the tax line a bill
        let lines = NetAllocator.suggest(amount: 3000, targets: targets, now: now, nextIncome: d(2026, 10, 18), surplusTarget: nil, calendar: utc)
        #expect(lines.map(\.name) == ["Mortgage", "Tax reserve", "Peace Number"])
        #expect(lines.map(\.amount) == [2000, 800, 200])
        #expect(lines[0].reason == "Was due the 3rd")
    }

    @Test func everythingCoveredSendsTheRestToTheSurplusFund() {
        let targets = NetAllocator.targets(lines: lines, taxLineName: "Tax reserve", assigned: ["Mortgage": 2000])
        let result = NetAllocator.suggest(amount: 3000, targets: targets, now: now, nextIncome: d(2026, 10, 18), surplusTarget: "Peace Number", calendar: utc)
        // Tax 800, Peace 500, Utilities 300 (due after the next job), Giving 200, everyday 800, then 400 extra.
        #expect(result.map(\.name) == ["Tax reserve", "Peace Number", "Utilities", "Giving", NetAllocator.flexibleName, "Peace Number"])
        #expect(result.map(\.amount) == [800, 500, 300, 200, 800, 400])
        #expect(result.last?.kind == .extra)
        #expect(result.reduce(0) { $0 + $1.amount } == 3000)
    }

    @Test func withoutASurplusFundTheRestStaysUnassigned() {
        let targets = NetAllocator.targets(lines: lines, taxLineName: "Tax reserve", assigned: [:])
        let result = NetAllocator.suggest(amount: 10_000, targets: targets, now: now, nextIncome: nil, surplusTarget: nil, calendar: utc)
        #expect(result.reduce(0) { $0 + $1.amount } == 4600)
        // No next income this month: every bill counts as due before it.
        #expect(Array(result.map(\.name).prefix(2)) == ["Mortgage", "Utilities"])
    }

    @Test func aBillDueThe31stIsDueOnTheLastDayOfAShortMonth() {
        // Feb 20, 2027: rent "due the 31st" is due Feb 28, before the job that pays Feb 28 ends the window.
        let lines = [PlanLine(name: "Rent", monthlyLimit: 1000, isFlexible: false, dueDay: 31), PlanLine(name: "Fund", monthlyLimit: 1000, isFlexible: false, isFund: true)]
        let targets = NetAllocator.targets(lines: lines, taxLineName: "Tax reserve", assigned: [:])
        let result = NetAllocator.suggest(amount: 1000, targets: targets, now: d(2027, 2, 20), nextIncome: d(2027, 2, 28), surplusTarget: nil, calendar: utc)
        #expect(result.map(\.name) == ["Rent"])
        #expect(result.first?.reason.contains("28th") == true)
    }

    @Test func aBillAlreadyPaidSaysSo() {
        let targets = NetAllocator.targets(lines: lines, taxLineName: "Tax reserve", assigned: [:], spent: ["Mortgage": 2000])
        let result = NetAllocator.suggest(amount: 2000, targets: targets, now: now, nextIncome: d(2026, 10, 18), surplusTarget: nil, calendar: utc)
        #expect(result.first?.reason == "Paid this month; this covers it")
    }

    @Test func ordinals() { #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23].map(\.ordinalString) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd"]) }
}

@Suite struct RecurringTests {
    let now = d(2026, 10, 10)
    func charge(_ title: String, _ amount: Double, _ date: Date, category: String = "Personal") -> LedgerEntry {
        LedgerEntry(date: date, amount: amount, category: category, isIncome: false, ledgerScope: "personal", title: title)
    }

    @Test func merchantKeysIgnoreNumbersAndNoise() {
        #expect(RecurringDetector.merchantKey("NETFLIX.COM 866-579") == "netflix")
        #expect(RecurringDetector.merchantKey("Netflix") == "netflix")
        #expect(RecurringDetector.merchantKey("POS DEBIT 1234") == "")
    }

    @Test func findsMonthlyAndQuarterlyChargesAndPriceIncreases() {
        var entries = (1...8).map { charge("NETFLIX.COM 866-579", 15.49, d(2026, $0, 5)) }
        entries.append(charge("Netflix", 17.99, d(2026, 9, 5)))
        entries += [charge("City Water", 90, d(2026, 1, 15)), charge("City Water", 110, d(2026, 4, 15)), charge("City Water", 92, d(2026, 7, 15))]
        entries += [charge("Corner Cafe", 6, d(2026, 9, 1)), charge("Corner Cafe", 7, d(2026, 9, 3)), charge("Corner Cafe", 5, d(2026, 10, 9))]
        entries += (1...4).map { charge("Spotify", 11.99, d(2026, $0, 20)) }
        let found = RecurringDetector.detect(entries: entries, now: now, calendar: utc)
        let byKey = Dictionary(uniqueKeysWithValues: found.map { ($0.key, $0) })
        #expect(byKey["corner cafe"] == nil)
        let netflix = byKey["netflix"]
        #expect(netflix?.cadence == .monthly)
        #expect(netflix?.priceIncrease.map { near($0, 2.5) } == true)
        #expect(netflix?.mayHaveStopped == false)
        #expect(netflix.map { utc.isDate($0.nextDate, inSameDayAs: d(2026, 10, 5)) } == true)
        #expect(byKey["city water"]?.cadence == .quarterly)
        #expect(byKey["city water"]?.isFixedAmount == false)
        #expect(byKey["spotify"]?.mayHaveStopped == true)
        #expect(RecurringDetector.detect(entries: entries, now: now, ignoredKeys: ["netflix"], calendar: utc).allSatisfy { $0.key != "netflix" })
    }

    @Test func upcomingListsChargesAndUnpaidBillsBeforeTheNextIncomeOnce() {
        let entries = [charge("City Water", 90, d(2026, 1, 15)), charge("City Water", 90, d(2026, 4, 15)), charge("City Water", 90, d(2026, 7, 15)),
                       charge("PGE", 120, d(2026, 7, 12), category: "Utilities"), charge("PGE", 120, d(2026, 8, 12), category: "Utilities"), charge("PGE", 120, d(2026, 9, 12), category: "Utilities")]
        let recurring = RecurringDetector.detect(entries: entries, now: now, calendar: utc)
        let upcoming = RecurringDetector.upcoming(recurring: recurring,
                                                  bills: [(name: "Utilities", dueDay: 12, amount: 300, paidThisMonth: false), (name: "Mortgage", dueDay: 3, amount: 2000, paidThisMonth: false),
                                                          (name: "Car insurance", dueDay: 18, amount: 250, paidThisMonth: true)],
                                                  now: now, until: d(2026, 10, 18), calendar: utc)
        // The unpaid mortgage (due the 3rd) is overdue and comes first; PGE is the Utilities bill (listed once, as the
        // bill); insurance is paid.
        #expect(upcoming.map(\.name) == ["Mortgage", "Utilities", "City Water"])
        #expect(upcoming.map(\.amount) == [2000, 300, 90])
        #expect(upcoming.first?.isOverdue == true)
    }

    @Test func upcomingCrossesIntoNextMonthAndRepeatsWeeklyCharges() {
        let weekly = (0..<4).map { charge("Gym Pass", 5, d(2026, 9, 11 + $0 * 7)) }   // Sep 11 … Oct 2
        let monthly = (5...9).map { charge("NETFLIX", 15.49, d(2026, $0, 5)) }            // next Oct 5: 5 days late on Oct 10
        let recurring = RecurringDetector.detect(entries: weekly + monthly, now: d(2026, 10, 10), calendar: utc)
        // From Oct 10: the gym's Oct 9 charge (a day late, shown today) then every week (16, 23, 30), and the late
        // Netflix charge shown today.
        let fromTen = RecurringDetector.upcoming(recurring: recurring, bills: [], now: d(2026, 10, 10), until: d(2026, 10, 31), calendar: utc)
        #expect(fromTen.filter { $0.name == "Gym Pass" }.map { utc.component(.day, from: $0.date) } == [10, 16, 23, 30])
        #expect(fromTen.contains { $0.name == "NETFLIX" && utc.isDate($0.date, inSameDayAs: d(2026, 10, 10)) })
        // Oct 28 → Nov 5: November's mortgage is listed although October's is paid.
        let late = RecurringDetector.upcoming(recurring: [], bills: [(name: "Mortgage", dueDay: 1, amount: 2000, paidThisMonth: true)], now: d(2026, 10, 28), until: d(2026, 11, 5), calendar: utc)
        #expect(late.count == 1 && late.first.map { utc.isDate($0.date, inSameDayAs: d(2026, 11, 1)) } == true)
        // Business charges aren't in this personal list.
        let business = (0..<4).map { LedgerEntry(date: d(2026, 6 + $0, 6), amount: 420, category: "Travel", isIncome: false, ledgerScope: "business", title: "Alaska Air") }
        let businessRecurring = RecurringDetector.detect(entries: business, now: d(2026, 10, 1), calendar: utc)
        #expect(businessRecurring.count == 1)
        #expect(RecurringDetector.upcoming(recurring: businessRecurring, bills: [], now: d(2026, 10, 1), until: d(2026, 10, 31), calendar: utc).isEmpty)
        // And across the year end.
        let yearEnd = RecurringDetector.upcoming(recurring: [], bills: [(name: "Rent", dueDay: 1, amount: 1500, paidThisMonth: true)], now: d(2026, 12, 20), until: d(2027, 1, 19), calendar: utc)
        #expect(yearEnd.first.map { utc.isDate($0.date, inSameDayAs: d(2027, 1, 1)) } == true)
    }
}
