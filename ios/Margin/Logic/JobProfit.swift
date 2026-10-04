import Foundation

/// One intervention's economics: what the business received, what it spent on that job, and what
/// reached the personal account.
struct JobSummary: Equatable, Identifiable {
    var id: UUID { jobID }
    var jobID: UUID
    var title: String
    var date: Date
    var gross: Double
    var expenses: Double
    var transferred: Double

    var profit: Double { gross - expenses }
    var margin: Double? { gross > 0 ? profit / gross : nil }
}

enum JobProfit {
    /// Jobs (Gross receipts) dated within `range`, newest first. Business expenses count toward a job
    /// when they carry its jobID; refunds are negative expenses and reduce the total.
    static func summaries(entries: [LedgerEntry], in range: ClosedRange<Date>? = nil) -> [JobSummary] {
        entries.filter { $0.isGross && $0.jobID != nil && (range?.contains($0.date) ?? true) }
            .map { job in
                JobSummary(jobID: job.jobID!, title: job.title, date: job.date, gross: job.amount,
                           expenses: entries.filter { $0.isBusinessExpense && $0.jobID == job.jobID }.total,
                           transferred: entries.filter { $0.isNet && $0.jobID == job.jobID }.total)
            }
            .sorted { $0.date > $1.date }
    }

    struct Totals: Equatable {
        var jobs: Int
        var gross: Double
        var expenses: Double
        var profit: Double { gross - expenses }
        var averageProfit: Double { jobs > 0 ? profit / Double(jobs) : 0 }
        var best: JobSummary?
    }

    static func totals(_ summaries: [JobSummary]) -> Totals {
        Totals(jobs: summaries.count, gross: summaries.reduce(0) { $0 + $1.gross }, expenses: summaries.reduce(0) { $0 + $1.expenses },
               best: summaries.max { $0.profit < $1.profit })
    }
}

/// Business-ledger totals arranged like IRS Schedule C (Profit or Loss From Business). A starting point
/// for a tax preparer, not tax advice.
struct ScheduleCLine: Equatable {
    var line: String
    var label: String
    var amount: Double
    var note: String? = nil
}

struct ScheduleCReport: Equatable {
    var year: Int
    var grossReceipts: Double
    var lines: [ScheduleCLine]
    var totalExpenses: Double { lines.reduce(0) { $0 + $1.amount } }
    var netProfit: Double { grossReceipts - totalExpenses }
}

enum ScheduleC {
    /// Margin's business categories mapped to Schedule C expense lines. Anything unmapped is "Other expenses".
    static let lineForCategory: [String: (line: String, label: String)] = [
        "Marketing": ("8", "Advertising"),
        "Contractor": ("11", "Contract labor"),
        "Insurance": ("15", "Insurance (other than health)"),
        "Professional fees": ("17", "Legal and professional services"),
        "Travel": ("24a", "Travel"),
        "Lodging": ("24a", "Travel"),
        "Meals": ("24b", "Deductible meals"),
    ]
    static let otherLine = (line: "27a", label: "Other expenses")
    /// Business meals are generally 50% deductible.
    static let mealsDeductibleShare = 0.5

    static func report(entries: [LedgerEntry], year: Int, calendar: Calendar = .current) -> ScheduleCReport {
        let inYear = entries.filter { calendar.component(.year, from: $0.date) == year }
        var spent: [String: (label: String, amount: Double, meals: Double)] = [:]
        for expense in inYear where expense.isBusinessExpense {
            let mapped = lineForCategory[expense.category] ?? otherLine
            var row = spent[mapped.line] ?? (mapped.label, 0, 0)
            if mapped.line == "24b" { row.meals += expense.amount; row.amount += expense.amount * mealsDeductibleShare } else { row.amount += expense.amount }
            spent[mapped.line] = row
        }
        let order = ["8", "11", "15", "17", "24a", "24b", "27a"]
        let lines = spent.sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }.map { key, row in
            ScheduleCLine(line: key, label: row.label, amount: row.amount, note: key == "24b" ? "50% of \(row.meals.moneyExact) spent on meals" : nil)
        }
        return ScheduleCReport(year: year, grossReceipts: inYear.filter(\.isGross).total, lines: lines)
    }
}
