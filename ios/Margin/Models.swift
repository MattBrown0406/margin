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

    init(title: String, expectedGross: Double, expectedNet: Double, expectedDate: Date) {
        self.id = UUID(); self.title = title; self.expectedGross = expectedGross; self.expectedNet = expectedNet
        self.expectedDate = expectedDate; self.status = "booked"; self.paidJobID = nil; self.createdAt = .now
    }

    var isOpen: Bool { status == "booked" }
    var info: BookedJobInfo { BookedJobInfo(id: id, title: title, expectedDate: expectedDate, expectedGross: expectedGross, expectedNet: expectedNet) }
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
