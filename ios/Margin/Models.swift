import Foundation
import SwiftData

@Model final class Transaction {
    var id: UUID
    var title: String
    var amount: Double
    var date: Date
    var category: String
    var isIncome: Bool
    var isEssential: Bool
    var splitCategory: String?
    var splitAmount: Double?
    var externalID: String?
    var externalAccountID: String?
    var isPending: Bool
    /// `business` for company activity and `personal` for household activity.
    var ledgerScope: String = "personal"
    /// Intervention receipts are `gross`; transfers into the personal account are `net`.
    var incomeKind: String?
    /// Links the gross receipt and its later personal transfer without counting either twice.
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
    var id: UUID
    var name: String
    var icon: String
    var monthlyLimit: Double
    var colorHex: String
    var isFlexible: Bool
    var groupName: String
    var dueDay: Int?
    var isFund: Bool
    var fundBalance: Double
    var fundTarget: Double
    var fundTargetDate: Date?

    init(name: String, icon: String, monthlyLimit: Double, colorHex: String, isFlexible: Bool = true,
         groupName: String = "Everyday", dueDay: Int? = nil, isFund: Bool = false,
         fundBalance: Double = 0, fundTarget: Double = 0, fundTargetDate: Date? = nil) {
        self.id = UUID(); self.name = name; self.icon = icon; self.monthlyLimit = monthlyLimit
        self.colorHex = colorHex; self.isFlexible = isFlexible
        self.groupName = groupName; self.dueDay = dueDay; self.isFund = isFund
        self.fundBalance = fundBalance; self.fundTarget = fundTarget; self.fundTargetDate = fundTargetDate
    }
}

@Model final class Paycheck {
    var id: UUID
    var name: String
    var amount: Double
    var payDate: Date
    var assignedCategoryNames: [String]

    init(name: String, amount: Double, payDate: Date, assignedCategoryNames: [String] = []) {
        self.id = UUID(); self.name = name; self.amount = amount; self.payDate = payDate
        self.assignedCategoryNames = assignedCategoryNames
    }
}

@Model final class SavingsGoal {
    var id: UUID
    var name: String
    var target: Double
    var saved: Double
    var targetDate: Date
    var icon: String

    init(name: String, target: Double, saved: Double = 0, targetDate: Date, icon: String = "sparkles") {
        self.id = UUID(); self.name = name; self.target = target; self.saved = saved
        self.targetDate = targetDate; self.icon = icon
    }
}

@Model final class PauseItem {
    var id: UUID
    var title: String
    var amount: Double
    var addedAt: Date

    init(title: String, amount: Double) {
        self.id = UUID(); self.title = title; self.amount = amount; self.addedAt = .now
    }
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
