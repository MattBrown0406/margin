import SwiftUI
import SwiftData

struct JobQuoteView: View {
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @State private var references = Set<UUID>()
    @State private var perHour = true
    @State private var target = ""
    @State private var hours = ""
    @State private var rate = ""
    @State private var reserve = "0"
    @State private var travel = ""
    @State private var contractors = ""
    @State private var other = ""
    @State private var editingHours: Transaction?

    private var receipts: [Transaction] {
        transactions.filter { $0.isIncome && $0.incomeKind == "gross" && $0.jobID != nil && $0.date < Calendar.current.endOfDay(for: .now) }
    }

    var body: some View {
        let selected = receipts.filter { references.contains($0.id) }
        let ids = Set(selected.compactMap(\.jobID))
        let expenses = transactions.filter { !$0.isIncome && $0.ledgerScope == "business" && $0.jobID.map(ids.contains) == true && $0.date < Calendar.current.endOfDay(for: .now) }
        let history = QuoteHistory(receipts: selected, expenses: expenses)
        Form {
            Section {
                if receipts.isEmpty { Text("With no paid jobs yet, enter your own hours and costs below.").foregroundStyle(.secondary) }
                ForEach(receipts) { job in
                    Button {
                        if references.contains(job.id) { references.remove(job.id) } else { references.insert(job.id) }
                    } label: {
                        HStack {
                            Image(systemName: references.contains(job.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) { Text(job.title); Text(job.date.formatted(date: .abbreviated, time: .omitted)).font(.caption) }
                            Spacer(); Text(job.amount.moneyExact)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(references.contains(job.id) ? "Selected" : "Unselected")
                    if references.contains(job.id) {
                        Button(job.workHours.map { "Edit actual hours (\($0.formatted()))" } ?? "Add actual hours") { editingHours = job }
                    }
                }
            } header: { Text("Choose similar paid jobs") }
            if !selected.isEmpty {
                Section("Historical averages per job") {
                    LabeledContent("Gross", value: history.gross.moneyExact)
                    LabeledContent("Tagged job costs", value: (history.travel + history.contractors + history.other).moneyExact)
                    LabeledContent("Realized profit before tax", value: history.profit.moneyExact)
                    if let actual = history.profitPerLoggedHour { LabeledContent("Profit per logged hour", value: actual.moneyExact) }
                    if let average = history.hours { LabeledContent("Hours from \(history.countWithHours) logged jobs", value: average.formatted()) }
                }
            }
            Section {
                Picker("Set target", selection: $perHour) { Text("Per hour").tag(true); Text("Per job").tag(false) }.pickerStyle(.segmented)
                if perHour {
                    field("Expected hours", $hours, fallback: history.hours)
                    field("Take-home per hour ($)", $rate, fallback: history.hourlyTarget(reserve: reserve))
                } else {
                    field("Target take-home ($)", $target)
                }
                field("Profit to set aside (%)", $reserve)
            } header: { Text("Target take-home") }
            Section {
                field("Travel and lodging ($)", $travel, fallback: history.suggested(history.travel))
                field("Contractors ($)", $contractors, fallback: history.suggested(history.contractors))
                field("Other job costs ($)", $other, fallback: history.suggested(history.other))
            } header: { Text("Expected costs") } footer: { Text("Blank cost fields use the selected jobs’ averages. Enter a value to override an average.") }
            Section("Minimum quote") {
                if let estimate = estimate(history) {
                    LabeledContent("Take-home after reserve", value: estimate.takeHome.moneyExact)
                    LabeledContent("Reserve from profit", value: estimate.reserve.moneyExact)
                    LabeledContent("Quote at least", value: estimate.minimum.moneyExact).bold()
                } else { Text("Enter a positive pay target, nonnegative costs and a reserve below 100%. Hourly targets also require hours.").foregroundStyle(.secondary) }
            }
        }.numberPadDone().navigationTitle("Quote a job")
        .sheet(item: $editingHours) { JobHoursEditor(job: $0) }
    }

    private func field(_ name: String, _ value: Binding<String>, fallback: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline)
            TextField(name, text: value, prompt: Text(fallback?.formatted(.number.precision(.fractionLength(0...2))) ?? "Enter"))
                .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel(name)
        }
    }

    private func estimate(_ history: QuoteHistory) -> QuoteEstimate? {
        func number(_ text: String, fallback: Double?) -> Double? { text.isEmpty ? fallback : planningNumber(text) }
        guard let percent = planningNumber(reserve),
              let travel = number(travel, fallback: history.suggested(history.travel)), let contractor = number(contractors, fallback: history.suggested(history.contractors)),
              let other = number(other, fallback: history.suggested(history.other)) else { return nil }
        let costs = ((travel + contractor + other) * 100).rounded() / 100
        if perHour {
            guard let hours = number(hours, fallback: history.hours), let hourly = number(rate, fallback: history.hourlyTarget(reserve: reserve)) else { return nil }
            return QuoteEstimate.calculate(hours: hours, hourly: hourly, costs: costs, reservePercent: percent)
        }
        guard let target = planningNumber(target) else { return nil }
        return QuoteEstimate.calculate(target: target, costs: costs, reservePercent: percent)
    }
}

private struct QuoteHistory {
    let gross: Double, travel: Double, contractors: Double, other: Double
    let hours: Double?
    let countWithHours: Int
    let profitPerLoggedHour: Double?
    func hourlyTarget(reserve: String) -> Double? {
        guard let profitPerLoggedHour, profitPerLoggedHour > 0, let percent = planningNumber(reserve), percent < 100 else { return nil }
        return suggested(profitPerLoggedHour * (1 - percent / 100))
    }
    func suggested(_ average: Double) -> Double { (max(0, average) * 100).rounded() / 100 }
    var profit: Double { gross - travel - contractors - other }
    init(receipts: [Transaction], expenses: [Transaction]) {
        let count = Double(max(1, receipts.count))
        gross = receipts.reduce(0) { $0 + $1.amount } / count
        travel = expenses.filter { ["Travel", "Lodging"].contains($0.category) }.reduce(0) { $0 + $1.amount } / count
        contractors = expenses.filter { $0.category == "Contractor" }.reduce(0) { $0 + $1.amount } / count
        other = expenses.filter { !["Travel", "Lodging", "Contractor"].contains($0.category) }.reduce(0) { $0 + $1.amount } / count
        let known = receipts.compactMap(\.workHours).filter { $0 > 0 }
        let timedJobs = receipts.filter { ($0.workHours ?? 0) > 0 }
        let timedIDs = Set(timedJobs.compactMap(\.jobID))
        let timedCosts = expenses.filter { $0.jobID.map(timedIDs.contains) == true }.reduce(0) { $0 + $1.amount }
        profitPerLoggedHour = known.isEmpty ? nil : (timedJobs.reduce(0) { $0 + $1.amount } - timedCosts) / known.reduce(0, +)
        countWithHours = known.count
        hours = known.isEmpty ? nil : (known.reduce(0, +) * 100 / Double(known.count)).rounded() / 100
    }
}

private struct JobHoursEditor: View {
    let job: Transaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?
    init(job: Transaction) {
        self.job = job
        _text = State(initialValue: job.workHours.map { $0.formatted(.number.grouping(.never)) } ?? "")
    }
    var body: some View {
        NavigationStack { Form {
            Text(job.title)
            TextField("Actual hours worked", text: $text).keyboardType(.decimalPad)
            if let error { Text(error).foregroundStyle(.red) }
            Button("Save hours") {
                let original = job.workHours
                job.workHours = text.isEmpty ? nil : Double(moneyInput: text)
                do { try context.save(); dismiss() } catch { job.workHours = original; self.error = error.localizedDescription }
            }.disabled(!text.isEmpty && Double(moneyInput: text) == nil)
        }.numberPadDone().navigationTitle("Job hours").toolbar { Button("Cancel") { dismiss() } } }
    }
}
