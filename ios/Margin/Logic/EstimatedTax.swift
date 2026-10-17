import Foundation

enum FilingStatus: String, CaseIterable, Identifiable {
    case single, marriedJoint, headOfHousehold
    var id: String { rawValue }
    var title: String {
        switch self { case .single: "Single"; case .marriedJoint: "Married filing jointly"; case .headOfHousehold: "Head of household" }
    }
}

/// What the planner needs to know beyond the business ledger. Amounts are annual.
struct TaxProfile: Equatable {
    var filingStatus: FilingStatus = .single
    /// Flat state income-tax rate on business profit, as a percent (0 for no state income tax).
    var stateRate: Double = 0
    /// Other taxable income for the year (for example a spouse's wages), which sets the bracket the profit lands in.
    var otherIncome: Double = 0
    /// Your own W-2 wages this year (not a spouse's). Only these count against your Social Security wage base.
    var ownWages: Double = 0
    /// Federal income tax withheld from that other income.
    var withholding: Double = 0
    /// Last year's total federal tax (0 if unknown); paying 100% of it (110% for higher earners) avoids a penalty.
    var priorYearTax: Double = 0
    /// Last year's AGI was over $150,000 ($75,000 married filing separately), raising the safe harbor to 110%.
    var priorYearHighIncome: Bool = false
    /// Apply the simplified 20% qualified business income deduction (phase-outs are not modeled).
    var includeQBI: Bool = false
}

/// Federal figures for one tax year (IRS Rev. Proc. 2025-32 and the SSA's 2026 wage base).
struct TaxYearTable {
    var year: Int
    var standardDeduction: [FilingStatus: Double]
    /// (upper bound of the bracket, rate) in order; the last bound is infinity.
    var brackets: [FilingStatus: [(Double, Double)]]
    var socialSecurityWageBase: Double

    static let y2026 = TaxYearTable(
        year: 2026,
        standardDeduction: [.single: 16_100, .marriedJoint: 32_200, .headOfHousehold: 24_150],
        brackets: [
            .single: [(12_400, 0.10), (50_400, 0.12), (105_700, 0.22), (201_775, 0.24), (256_225, 0.32), (640_600, 0.35), (.infinity, 0.37)],
            .marriedJoint: [(24_800, 0.10), (100_800, 0.12), (211_400, 0.22), (403_550, 0.24), (512_450, 0.32), (768_700, 0.35), (.infinity, 0.37)],
            .headOfHousehold: [(17_700, 0.10), (67_450, 0.12), (105_700, 0.22), (201_750, 0.24), (256_200, 0.32), (640_600, 0.35), (.infinity, 0.37)],
        ],
        socialSecurityWageBase: 184_500)

    /// The newest table at or before `year`; later years reuse it until it is updated (amounts drift with inflation).
    static func forYear(_ year: Int) -> TaxYearTable { y2026 }

    func incomeTax(_ taxable: Double, status: FilingStatus) -> Double {
        var tax = 0.0, lower = 0.0
        for (upper, rate) in brackets[status] ?? [] {
            guard taxable > lower else { break }
            tax += (min(taxable, upper) - lower) * rate
            lower = upper
        }
        return tax
    }
}

struct TaxEstimate: Equatable {
    var businessProfit: Double
    var selfEmploymentTax: Double
    /// The household's federal income tax with the business profit included.
    var householdIncomeTax: Double
    /// What the other income alone would owe (covered by its withholding, ideally).
    var otherIncomeTax: Double
    var stateTax: Double
    /// The income tax the business profit adds on top of the other income's.
    var federalIncomeTax: Double { max(0, householdIncomeTax - otherIncomeTax) }
    /// Federal tax caused by the business: self-employment tax plus the income tax it adds.
    var federalOnBusiness: Double { selfEmploymentTax + federalIncomeTax }
    /// All federal tax for the year (before withholding).
    var federalTotal: Double { selfEmploymentTax + householdIncomeTax }
    var businessTotal: Double { federalOnBusiness + stateTax }
}

struct EstimatedTaxPlan: Equatable {
    struct Installment: Equatable, Identifiable {
        var id: Int { quarter }
        var quarter: Int
        var dueDate: Date
        var federal: Double
        var state: Double
    }

    var taxYear: Int
    var ytdGross: Double
    var ytdProfit: Double
    /// YTD profit scaled to a full year at today's pace.
    var projectedProfit: Double
    var projectedGross: Double
    var estimate: TaxEstimate
    /// Federal estimated payments that leave little or nothing owed in April (after withholding).
    var recommendedFederal: Double
    /// The least that avoids an underpayment penalty: 90% of this year's tax or the prior-year safe harbor.
    var minimumFederal: Double
    var installments: [Installment]
    var paidFederal: Double
    var paidState: Double
    /// The next installment not yet past due; nil after the last one.
    var next: Installment?
    /// Owed by the next due date: installments through it, less what's been paid.
    var dueNextFederal: Double
    var dueNextState: Double
    /// Share of each job's Gross to set aside to cover this year's federal and state tax.
    var setAsideRate: Double
    /// Still to set aside this year, beyond payments made and what's already in the reserve.
    var stillToSave: Double
    /// `stillToSave` spread over the months left in the year, this one included.
    var monthlyToSave: Double
}

enum EstimatedTax {
    static let selfEmploymentEarningsShare = 0.9235
    static let socialSecurityRate = 0.124, medicareRate = 0.029, additionalMedicareRate = 0.009

    static func additionalMedicareThreshold(_ status: FilingStatus) -> Double { status == .marriedJoint ? 250_000 : 200_000 }

    /// Annual tax for a year's business profit, given the rest of the household's income.
    static func estimate(profit: Double, profile: TaxProfile, table: TaxYearTable) -> TaxEstimate {
        // otherIncome (the household's) sets the brackets and the Additional Medicare threshold; the Social Security
        // wage base is per person, so only your own wages use it up.
        let profit = max(0, profit), wages = max(0, profile.otherIncome), ownWages = min(max(0, profile.ownWages), wages)
        let earnings = profit * selfEmploymentEarningsShare
        var social = 0.0, medicare = 0.0, additional = 0.0
        if earnings >= 400 {   // below $400 of net earnings there is no self-employment tax
            social = socialSecurityRate * min(earnings, max(0, table.socialSecurityWageBase - ownWages))
            medicare = medicareRate * earnings
            additional = additionalMedicareRate * min(earnings, max(0, earnings + wages - additionalMedicareThreshold(profile.filingStatus)))
        }
        let halfSE = (social + medicare) / 2
        let deduction = table.standardDeduction[profile.filingStatus] ?? 0
        func federal(businessIncome: Double, halfSE: Double) -> Double {
            let beforeQBI = max(0, businessIncome - halfSE + wages - deduction)
            let qbi = profile.includeQBI ? min(0.2 * max(0, businessIncome - halfSE), 0.2 * beforeQBI) : 0
            return table.incomeTax(max(0, beforeQBI - qbi), status: profile.filingStatus)
        }
        return TaxEstimate(businessProfit: profit, selfEmploymentTax: social + medicare + additional,
                           householdIncomeTax: federal(businessIncome: profit, halfSE: halfSE), otherIncomeTax: federal(businessIncome: 0, halfSE: 0),
                           stateTax: max(0, profile.stateRate) / 100 * max(0, profit - halfSE))
    }

    /// Estimated-tax due dates for a tax year (Apr 15, Jun 15, Sep 15, Jan 15), moved past weekends and the legal
    /// holidays that can land on them: DC Emancipation Day (Apr 16, observed on a weekday) and Martin Luther King Jr. Day.
    static func dueDates(taxYear: Int, calendar: Calendar = .current) -> [Date] {
        [(taxYear, 4), (taxYear, 6), (taxYear, 9), (taxYear + 1, 1)].compactMap { year, month in
            guard var date = calendar.date(from: DateComponents(year: year, month: month, day: 15)) else { return nil }
            while calendar.isDateInWeekend(date) || isDeadlineHoliday(date, calendar: calendar) { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            return date
        }
    }

    /// The tax year being paid on `now`: last year's until its January installment is due, then this year's.
    static func plannerYear(now: Date, calendar: Calendar = .current) -> Int {
        let year = calendar.component(.year, from: now)
        let lastQ4 = dueDates(taxYear: year - 1, calendar: calendar).last ?? .distantPast
        return calendar.startOfDay(for: now) <= lastQ4 ? year - 1 : year
    }

    static func isDeadlineHoliday(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }
        if month == 1 { return parts.weekday == 2 && (15...21).contains(day) }   // third Monday of January
        if month == 4, let april16 = calendar.date(from: DateComponents(year: year, month: 4, day: 16)) {
            // Observed on Friday the 15th when the 16th is a Saturday, and on Monday the 17th when it's a Sunday.
            let weekday = calendar.component(.weekday, from: april16)
            let observed = weekday == 7 ? 15 : weekday == 1 ? 17 : 16
            return day == observed
        }
        return false
    }

    static func plan(report: ScheduleCReport, profile: TaxProfile, paidFederal: Double, paidState: Double, reserve: Double,
                     now: Date, calendar: Calendar = .current) -> EstimatedTaxPlan {
        let table = TaxYearTable.forYear(report.year)
        // Share of the tax year elapsed (at least one month, so early-January numbers aren't wildly scaled up).
        let yearStart = calendar.date(from: DateComponents(year: report.year, month: 1, day: 1)) ?? now
        let yearEnd = calendar.date(byAdding: .year, value: 1, to: yearStart) ?? now
        let elapsed = min(1, max(1.0 / 12, now.timeIntervalSince(yearStart) / yearEnd.timeIntervalSince(yearStart)))
        let projectedProfit = max(0, report.netProfit) / elapsed, projectedGross = max(0, report.grossReceipts) / elapsed
        let estimate = estimate(profit: projectedProfit, profile: profile, table: table)

        let withholding = max(0, profile.withholding)
        // Withholding counts against the household's whole federal tax, not just the business's share.
        let recommended = max(0, estimate.federalTotal - withholding)
        let priorHarbor = profile.priorYearTax > 0 ? profile.priorYearTax * (profile.priorYearHighIncome ? 1.1 : 1.0) : Double.infinity
        // No underpayment penalty when less than $1,000 is owed after withholding.
        let minimum = estimate.federalTotal - withholding < 1000 ? 0 : max(0, min(0.9 * estimate.federalTotal, priorHarbor) - withholding)

        let dates = dueDates(taxYear: report.year, calendar: calendar)
        let installments = dates.enumerated().map { EstimatedTaxPlan.Installment(quarter: $0.offset + 1, dueDate: $0.element, federal: recommended / 4, state: estimate.stateTax / 4) }
        let today = calendar.startOfDay(for: now)
        let next = installments.first { $0.dueDate >= today }
        let throughNext = installments.filter { $0.dueDate <= (next?.dueDate ?? .distantFuture) }
        let dueFederal = max(0, throughNext.reduce(0) { $0 + $1.federal } - paidFederal)
        let dueState = max(0, throughNext.reduce(0) { $0 + $1.state } - paidState)

        let stillToSave = max(0, recommended + estimate.stateTax - paidFederal - paidState - max(0, reserve))
        let month = calendar.component(.year, from: now) == report.year ? calendar.component(.month, from: now) : 12
        return EstimatedTaxPlan(taxYear: report.year, ytdGross: report.grossReceipts, ytdProfit: report.netProfit,
                                projectedProfit: projectedProfit, projectedGross: projectedGross, estimate: estimate,
                                recommendedFederal: recommended, minimumFederal: minimum, installments: installments,
                                paidFederal: paidFederal, paidState: paidState, next: next,
                                dueNextFederal: next == nil ? 0 : dueFederal, dueNextState: next == nil ? 0 : dueState,
                                setAsideRate: projectedGross > 0 ? min(1, estimate.businessTotal / projectedGross) : 0,
                                stillToSave: stillToSave, monthlyToSave: stillToSave / Double(max(1, 12 - month + 1)))
    }
}
