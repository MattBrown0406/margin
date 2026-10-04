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
    /// `booked`, `paid`, or `cancelled`.
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
        CashFlowForecast.unpaid(jobs.filter(\.isOpen).map(\.info), entries: entries, claimed: Set(jobs.compactMap(\.paidJobID)))
    }
}

extension Transaction {
    var ledgerEntry: LedgerEntry {
        LedgerEntry(date: date, amount: amount, category: category, isIncome: isIncome, ledgerScope: ledgerScope, incomeKind: incomeKind, jobID: jobID, title: title)
    }
}

extension BudgetCategory {
    var planLine: PlanLine { PlanLine(name: name, monthlyLimit: monthlyLimit, isFlexible: isFlexible, dueDay: dueDay) }
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
        context.insert(SavingsGoal(name: "Peace Number", target: 25000, saved: 0, targetDate: Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now, icon: "shield.fill"))
        UserDefaults.standard.set(true, forKey: seededKey)
        try? context.save()
    }
}
