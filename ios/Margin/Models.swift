import Foundation
import SwiftData

// Every stored property has a default value: SwiftData requires that to sync through CloudKit.

@Model final class Transaction {
    var id: UUID = UUID()
    var title: String = ""
    var amount: Double = 0
    var date: Date = Date.now
    var category: String = ""
    var isIncome: Bool = false
    var isEssential: Bool = true
    var splitCategory: String?
    var splitAmount: Double?
    var externalID: String?
    var externalAccountID: String?
    /// The bank's own description of an imported entry, kept so a category correction is learned under the name the
    /// next import will carry, however the entry was renamed.
    var externalName: String?
    var isPending: Bool = false
    /// `business` for company activity and `personal` for household activity.
    var ledgerScope: String = "personal"
    /// Intervention receipts are `gross`; transfers into the personal account are `net`.
    var incomeKind: String?
    /// Links a job's Gross receipt, its personal transfers, and the business expenses spent on it.
    var jobID: UUID?

    init(title: String, amount: Double, date: Date = .now, category: String, isIncome: Bool = false,
         isEssential: Bool = true, ledgerScope: String = "personal", incomeKind: String? = nil,
         jobID: UUID? = nil) {
        self.id = UUID(); self.title = title; self.amount = amount; self.date = date
        self.category = category; self.isIncome = isIncome; self.isEssential = isEssential
        self.splitCategory = nil; self.splitAmount = nil
        self.externalID = nil; self.externalAccountID = nil; self.isPending = false
        self.ledgerScope = ledgerScope; self.incomeKind = incomeKind; self.jobID = jobID
    }
}

@Model final class BudgetCategory {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "circle"
    var monthlyLimit: Double = 0
    var colorHex: String = "264653"
    var isFlexible: Bool = true
    var groupName: String = "Everyday"
    var dueDay: Int?
    var isFund: Bool = false
    var fundBalance: Double = 0
    var fundTarget: Double = 0
    var fundTargetDate: Date?
    /// Records that existed before this field get `distantPast`, so they win de-duplication.
    var createdAt: Date = Date.distantPast

    init(name: String, icon: String, monthlyLimit: Double, colorHex: String, isFlexible: Bool = true,
         groupName: String = "Everyday", dueDay: Int? = nil, isFund: Bool = false,
         fundBalance: Double = 0, fundTarget: Double = 0, fundTargetDate: Date? = nil) {
        self.id = UUID(); self.name = name; self.icon = icon; self.monthlyLimit = monthlyLimit
        self.colorHex = colorHex; self.isFlexible = isFlexible
        self.groupName = groupName; self.dueDay = dueDay; self.isFund = isFund
        self.fundBalance = fundBalance; self.fundTarget = fundTarget; self.fundTargetDate = fundTargetDate
        self.createdAt = .now
    }
}

@Model final class Paycheck {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var payDate: Date = Date.now
    var assignedCategoryNames: [String] = []

    init(name: String, amount: Double, payDate: Date, assignedCategoryNames: [String] = []) {
        self.id = UUID(); self.name = name; self.amount = amount; self.payDate = payDate
        self.assignedCategoryNames = assignedCategoryNames
    }
}

@Model final class SavingsGoal {
    var id: UUID = UUID()
    var name: String = ""
    var target: Double = 0
    var saved: Double = 0
    var targetDate: Date = Date.now
    var icon: String = "sparkles"
    var createdAt: Date = Date.distantPast

    init(name: String, target: Double, saved: Double = 0, targetDate: Date, icon: String = "sparkles") {
        self.id = UUID(); self.name = name; self.target = target; self.saved = saved
        self.targetDate = targetDate; self.icon = icon; self.createdAt = .now
    }
}

@Model final class PauseItem {
    var id: UUID = UUID()
    var title: String = ""
    var amount: Double = 0
    var addedAt: Date = Date.now

    init(title: String, amount: Double) {
        self.id = UUID(); self.title = title; self.amount = amount; self.addedAt = .now
    }
}

/// An intervention that's booked but hasn't paid yet. It feeds the cash-flow forecast until it is
/// marked paid (which records the real Gross receipt) or cancelled.
@Model final class BookedJob {
    var id: UUID = UUID()
    var title: String = ""
    var expectedGross: Double = 0
    var expectedNet: Double = 0
    var expectedDate: Date = Date.now
    /// `booked`, `paid` (Gross or Net recorded), `settled` (paid and done transferring), or `cancelled`.
    var status: String = "booked"
    /// The jobID of the Gross receipt recorded when it paid.
    var paidJobID: UUID?
    var createdAt: Date = Date.now
    /// Recorded payments the person said are not this booking, so they stop being suggested.
    var ignoredPaymentIDs: [UUID] = []

    init(title: String, expectedGross: Double, expectedNet: Double, expectedDate: Date) {
        self.id = UUID(); self.title = title; self.expectedGross = expectedGross; self.expectedNet = expectedNet
        self.expectedDate = expectedDate; self.status = "booked"; self.paidJobID = nil; self.createdAt = .now
    }

    var isOpen: Bool { status == "booked" }
    var info: BookedJobInfo { BookedJobInfo(id: id, title: title, expectedDate: expectedDate, expectedGross: expectedGross, expectedNet: expectedNet, ignoredPaymentIDs: Set(ignoredPaymentIDs), bookedAt: createdAt) }

    /// Open bookings that should still count as expected income: payments already recorded some other way
    /// (Add, a bank import) are matched and excluded so they aren't counted twice.
    static func expectedIncome(_ jobs: [BookedJob], entries: [LedgerEntry]) -> [BookedJobInfo] {
        CashFlowForecast.expectedNet(open: jobs.filter(\.isOpen).map(\.info),
                                     paid: jobs.filter { $0.status == "paid" }.compactMap { job in job.paidJobID.map { (job.info, $0) } },
                                     entries: entries, alsoClaimed: Set(jobs.compactMap(\.paidJobID)))
    }
}

extension Transaction {
    var ledgerEntry: LedgerEntry {
        LedgerEntry(date: date, amount: amount, category: category, isIncome: isIncome, ledgerScope: ledgerScope, incomeKind: incomeKind, jobID: jobID, title: title)
    }
}

extension BudgetCategory {
    var planLine: PlanLine { PlanLine(name: name, monthlyLimit: monthlyLimit, isFlexible: isFlexible, dueDay: dueDay, isFund: isFund) }
}

/// Categories offered for the business ledger. Personal categories come from the user's budget.
let businessCategoryNames = ["Travel", "Lodging", "Meals", "Contractor", "Marketing", "Insurance", "Professional fees", "Other business"]

extension Transaction {
    /// Personal transfers recorded against an intervention's gross receipt (there can be several).
    func netTransfers(in transactions: [Transaction]) -> [Transaction] {
        guard incomeKind == "gross", let jobID else { return [] }
        return transactions.filter { $0.isIncome && $0.incomeKind == "net" && $0.jobID == jobID }.sorted { $0.date < $1.date }
    }
}

/// The budget a new Margin starts with. Only categories and a reserve goal, never sample transactions:
/// with iCloud sync, sample entries would land in the real ledger on every device.
enum StarterBudget {
    static let seededKey = "margin.seeded"

    static func insert(into context: ModelContext) {
        let targetDate = Calendar.current.date(byAdding: .month, value: 8, to: .now)
        let seedCategories = [
            BudgetCategory(name: "Giving", icon: "heart", monthlyLimit: 300, colorHex: "72BFA0", isFlexible: false, groupName: "Giving"),
            BudgetCategory(name: "Peace Number", icon: "shield.fill", monthlyLimit: 1050, colorHex: "72BFA0", isFlexible: false, groupName: "Saving & Funds", isFund: true, fundTarget: 25000, fundTargetDate: targetDate),
            BudgetCategory(name: "Car repairs", icon: "wrench.fill", monthlyLimit: 150, colorHex: "5F8FA3", isFlexible: false, groupName: "Saving & Funds", isFund: true, fundTarget: 1800, fundTargetDate: Calendar.current.date(byAdding: .month, value: 10, to: .now)),
            BudgetCategory(name: "Mortgage", icon: "house.fill", monthlyLimit: 2650, colorHex: "264653", isFlexible: false, groupName: "Housing", dueDay: 3),
            BudgetCategory(name: "Utilities", icon: "bolt.fill", monthlyLimit: 450, colorHex: "264653", isFlexible: false, groupName: "Housing", dueDay: 12),
            BudgetCategory(name: "Groceries", icon: "cart.fill", monthlyLimit: 700, colorHex: "E9C46A", groupName: "Food"),
            BudgetCategory(name: "Dining out", icon: "fork.knife", monthlyLimit: 200, colorHex: "E9C46A", groupName: "Food"),
            BudgetCategory(name: "Fuel", icon: "fuelpump.fill", monthlyLimit: 300, colorHex: "2A9D8F", groupName: "Transportation"),
            BudgetCategory(name: "Car insurance", icon: "car.fill", monthlyLimit: 250, colorHex: "2A9D8F", isFlexible: false, groupName: "Transportation", dueDay: 18),
            BudgetCategory(name: "Personal", icon: "person.fill", monthlyLimit: 350, colorHex: "F4A261", groupName: "Personal & Life"),
            BudgetCategory(name: "Fun money", icon: "sparkles", monthlyLimit: 300, colorHex: "E76F51", groupName: "Personal & Life"),
            BudgetCategory(name: "Health", icon: "cross.case.fill", monthlyLimit: 450, colorHex: "6D597A", isFlexible: false, groupName: "Personal & Life"),
            BudgetCategory(name: "Tax reserve", icon: "percent", monthlyLimit: 850, colorHex: "6D597A", isFlexible: false, groupName: "Taxes", dueDay: 25)
        ]
        seedCategories.forEach(context.insert)
        // Same target date as the Peace Number fund above: the goal and the fund are one pot of money.
        context.insert(SavingsGoal(name: "Peace Number", target: 25000, saved: 0, targetDate: targetDate ?? .now, icon: "shield.fill"))
        UserDefaults.standard.set(true, forKey: seededKey)
        try? context.save()
    }
}

// MARK: - Money tools (steady paycheck, taxes, assigning Net, debt payoff, net worth)

/// Preferences for the money tools. One record; if iCloud delivers another device's copy, the oldest wins.
@Model final class FinanceSettings {
    var id: UUID = UUID()
    var createdAt: Date = Date.distantPast
    /// Steady paycheck: the monthly amount (0 = use the suggestion) and what's in the income buffer today.
    var monthlyPaycheck: Double = 0
    var incomeBuffer: Double = 0
    /// Estimated taxes.
    var filingStatus: String = FilingStatus.single.rawValue
    var stateTaxRate: Double = 0
    var otherIncome: Double = 0
    var ownWages: Double = 0
    var withholding: Double = 0
    var priorYearTax: Double = 0
    var priorYearHighIncome: Bool = false
    var includeQBI: Bool = false
    var taxLineName: String = "Tax reserve"
    /// Correction to the tax reserve, which is otherwise worked out from records (Net assigned to taxes minus what
    /// payments took out), so undoing or deleting either can never leave it wrong.
    var taxReserveAdjustment: Double = 0
    /// Debt payoff.
    var debtStrategy: String = PayoffStrategy.snowball.rawValue
    var extraDebtPayment: Double = 0
    /// The payoff order, fixed when the strategy was chosen or a debt was added or removed, so paying debts down
    /// (which changes balances and interest) never reshuffles which one comes first. `debtOrderKey` says what it's for.
    var debtOrderIDs: [String] = []
    var debtOrderKey: String = ""
    /// The person has set (or been given) their own order, so switching back to it keeps it.
    var hasCustomDebtOrder: Bool = false
    /// Assigning Net: where money goes once the plan is covered (a fund or goal name; empty = leave it unassigned).
    var surplusTarget: String = ""
    /// The last month ("2026-09") whose leftover flexible money was offered for a fund.
    var lastRolloverMonthKey: String = ""
    /// Merchants the person said aren't recurring.
    var ignoredRecurringKeys: [String] = []
    /// Reminders (local notifications), each off until the person turns it on.
    var remindBills: Bool = false
    var remindNet: Bool = false
    var remindTaxes: Bool = false
    /// Job payments dated before this aren't offered a tax set-aside on Today (they predate the feature, and their tax
    /// may already be in the reserve); the job card in Plan › Income still offers one.
    var taxSetAsideSince: Date?

    init() { self.id = UUID(); self.createdAt = .now }

    var taxProfile: TaxProfile {
        TaxProfile(filingStatus: FilingStatus(rawValue: filingStatus) ?? .single, stateRate: stateTaxRate, otherIncome: otherIncome, ownWages: ownWages, withholding: withholding,
                   priorYearTax: priorYearTax, priorYearHighIncome: priorYearHighIncome, includeQBI: includeQBI)
    }
    var strategy: PayoffStrategy { PayoffStrategy(rawValue: debtStrategy) ?? .snowball }

    /// The record in use: the oldest (ties by id), so every device agrees.
    static func pick(_ all: [FinanceSettings]) -> FinanceSettings? {
        all.min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }
    /// Folds a duplicate (another device's copy) into this record: anything this one still has at its default is
    /// taken from the other, and ignored merchants are combined.
    func absorb(_ other: FinanceSettings) {
        if monthlyPaycheck == 0 { monthlyPaycheck = other.monthlyPaycheck }
        if incomeBuffer == 0 { incomeBuffer = other.incomeBuffer }
        if filingStatus == FilingStatus.single.rawValue { filingStatus = other.filingStatus }
        if stateTaxRate == 0 { stateTaxRate = other.stateTaxRate }
        if otherIncome == 0 { otherIncome = other.otherIncome }
        if ownWages == 0 { ownWages = other.ownWages }
        if withholding == 0 { withholding = other.withholding }
        if priorYearTax == 0 { priorYearTax = other.priorYearTax }
        priorYearHighIncome = priorYearHighIncome || other.priorYearHighIncome
        includeQBI = includeQBI || other.includeQBI
        if taxLineName == "Tax reserve" { taxLineName = other.taxLineName }
        if taxReserveAdjustment == 0 { taxReserveAdjustment = other.taxReserveAdjustment }
        if debtStrategy == PayoffStrategy.snowball.rawValue { debtStrategy = other.debtStrategy }
        if extraDebtPayment == 0 { extraDebtPayment = other.extraDebtPayment }
        if debtOrderKey.isEmpty { debtOrderKey = other.debtOrderKey; debtOrderIDs = other.debtOrderIDs }
        hasCustomDebtOrder = hasCustomDebtOrder || other.hasCustomDebtOrder
        if surplusTarget.isEmpty { surplusTarget = other.surplusTarget }
        lastRolloverMonthKey = max(lastRolloverMonthKey, other.lastRolloverMonthKey)
        ignoredRecurringKeys = Array(Set(ignoredRecurringKeys + other.ignoredRecurringKeys)).sorted()
        remindBills = remindBills || other.remindBills; remindNet = remindNet || other.remindNet; remindTaxes = remindTaxes || other.remindTaxes
        if let theirs = other.taxSetAsideSince { taxSetAsideSince = min(taxSetAsideSince ?? theirs, theirs) }
    }

    /// The record in use, created on first need.
    @MainActor static func current(in context: ModelContext) -> FinanceSettings {
        if let existing = pick((try? context.fetch(FetchDescriptor<FinanceSettings>())) ?? []) { return existing }
        let settings = FinanceSettings(); context.insert(settings); try? context.save()
        return settings
    }
}

@Model final class Debt {
    var id: UUID = UUID()
    var name: String = ""
    /// `card`, `loan`, or `other`.
    var kind: String = "card"
    var balance: Double = 0
    var apr: Double = 0
    var minimumPayment: Double = 0
    var customRank: Int = 0
    /// A connected bank account whose balance this debt follows.
    var linkedAccountID: String?
    var createdAt: Date = Date.distantPast
    /// Payments recorded in the month `paidMonthKey` ("2026-10"), so the plan doesn't ask for them again.
    var paidMonthKey: String = ""
    var paidThisMonth: Double = 0

    init(name: String, kind: String = "card", balance: Double, apr: Double, minimumPayment: Double, customRank: Int = 0, linkedAccountID: String? = nil) {
        self.id = UUID(); self.name = name; self.kind = kind; self.balance = balance; self.apr = apr
        self.minimumPayment = minimumPayment; self.customRank = customRank; self.linkedAccountID = linkedAccountID; self.createdAt = .now
    }
    var info: DebtInfo {
        DebtInfo(id: id, name: name, balance: balance, apr: apr, minimumPayment: minimumPayment, customRank: customRank,
                 paidThisMonth: paidMonthKey == Calendar.current.monthKey(for: .now) ? paidThisMonth : 0)
    }
    /// Records a payment made on `date`: it lowers the balance and, if it's this month's, counts toward this month.
    func recordPayment(_ amount: Double, on date: Date, now: Date = .now) {
        countTowardMonth(amount, on: date, now: now)
        balance = max(0, ((balance - amount) * 100).rounded() / 100)
    }
    /// A payment on a bank-linked debt, whose balance comes from the bank: counts toward this month only.
    func countTowardMonth(_ amount: Double, on date: Date, now: Date = .now) {
        let calendar = Calendar.current
        (paidMonthKey, paidThisMonth) = DebtPayoff.tally(month: paidMonthKey, paid: paidThisMonth, adding: amount,
                                                         paymentMonth: calendar.monthKey(for: date), currentMonth: calendar.monthKey(for: now))
    }
}

@Model final class Asset {
    var id: UUID = UUID()
    var name: String = ""
    /// `cash`, `investment`, `property`, `vehicle`, or `other`.
    var kind: String = "cash"
    var value: Double = 0
    var createdAt: Date = Date.distantPast

    init(name: String, kind: String, value: Double) { self.id = UUID(); self.name = name; self.kind = kind; self.value = value; self.createdAt = .now }
}

/// Net worth as of a month, kept for the trend (one per month; the latest visit to Net worth updates it).
@Model final class NetWorthSnapshot {
    var id: UUID = UUID()
    var monthStart: Date = Date.distantPast
    /// "2026-10", the month in every time zone (`monthStart` is only for charting).
    var monthKey: String = ""
    var assets: Double = 0
    var debts: Double = 0
    var updatedAt: Date = Date.distantPast

    init(monthStart: Date, assets: Double, debts: Double) {
        self.id = UUID(); self.monthStart = monthStart; self.monthKey = Calendar.current.monthKey(for: monthStart)
        self.assets = assets; self.debts = debts; self.updatedAt = .now
    }
    var netWorth: Double { assets - debts }
}

/// Part of the month's Net assigned to a plan line. One assignment (`batchID`) can be undone as a whole.
@Model final class NetAllocation {
    var id: UUID = UUID()
    var batchID: UUID = UUID()
    var date: Date = Date.now
    var monthStart: Date = Date.distantPast
    /// "2026-10": the month this assignment belongs to, the same in every time zone.
    var monthKey: String = ""
    var target: String = ""
    /// An `AllocationTarget.Kind` raw value, or `rollover` for last month's leftover moved to a fund.
    var kind: String = ""
    var amount: Double = 0

    init(batchID: UUID, date: Date, monthStart: Date, target: String, kind: String, amount: Double) {
        self.id = UUID(); self.batchID = batchID; self.date = date; self.monthStart = monthStart; self.monthKey = Calendar.current.monthKey(for: monthStart)
        self.target = target; self.kind = kind; self.amount = amount
    }
}

/// The tax reserve, from records: Net assigned to taxes and tax set aside from jobs' Gross, minus what tax payments took
/// out of it, plus any correction.
enum TaxReserve {
    static func balance(adjustment: Double, allocations: [NetAllocation], payments: [EstimatedTaxPayment]) -> Double {
        adjustment + allocations.filter { AllocationKinds.fundsTaxReserve($0.kind) }.reduce(0) { $0 + $1.amount } - payments.reduce(0) { $0 + $1.reserveUsed }
    }
}

@Model final class EstimatedTaxPayment {
    var id: UUID = UUID()
    var date: Date = Date.now
    var amount: Double = 0
    var taxYear: Int = 0
    var isState: Bool = false
    /// How much of it came out of the tax reserve, so deleting the payment puts back exactly that.
    var reserveUsed: Double = 0

    init(date: Date, amount: Double, taxYear: Int, isState: Bool, reserveUsed: Double) {
        self.id = UUID(); self.date = date; self.amount = amount; self.taxYear = taxYear; self.isState = isState; self.reserveUsed = reserveUsed
    }
}

/// Moves money into a sinking fund or goal by name. A fund and a goal with the same name (the Peace Number) are one
/// pot, so both move together. Returns false when nothing by that name exists.
@MainActor @discardableResult
func addToFundOrGoal(_ name: String, amount: Double, categories: [BudgetCategory], goals: [SavingsGoal]) -> Bool {
    let matches: (String) -> Bool = { $0.caseInsensitiveCompare(name) == .orderedSame }
    let fund = categories.first { $0.isFund && matches($0.name) }, goal = goals.first { matches($0.name) }
    if let fund { fund.fundBalance = max(0, fund.fundBalance + amount) }
    if let goal { goal.saved = max(0, (fund?.fundBalance ?? goal.saved + amount)) }
    return fund != nil || goal != nil
}

/// "Safeway goes in Groceries": the category last chosen for a merchant in one ledger, applied to the next bank import
/// or typed expense from it. If iCloud delivers duplicates, the newest wins.
@Model final class MerchantRule {
    var id: UUID = UUID()
    var key: String = ""
    var scope: String = "personal"
    var category: String = ""
    var updatedAt: Date = Date.distantPast

    init(key: String, scope: String, category: String) { self.id = UUID(); self.key = key; self.scope = scope; self.category = category; self.updatedAt = .now }
    var info: MerchantRuleInfo { MerchantRuleInfo(key: key, scope: scope, category: category, updatedAt: updatedAt) }

    /// Remembers `category` for this merchant and ledger (nothing for a title with no usable merchant name, or one
    /// that only names a payment method like "CHECK 1001").
    @MainActor static func learn(title: String, scope: String, category: String, rules: [MerchantRule], in context: ModelContext) {
        guard let key = MerchantRules.learnableKey(title), !category.isEmpty else { return }
        let matching = rules.filter { $0.key == key && $0.scope == scope }
        if let newest = matching.max(by: { $0.updatedAt < $1.updatedAt }) {
            if newest.category != category { newest.category = category }
            newest.updatedAt = .now
            matching.filter { $0.id != newest.id }.forEach(context.delete)
        } else {
            context.insert(MerchantRule(key: key, scope: scope, category: category))
        }
    }
}
