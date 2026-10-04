import AppIntents
import SwiftData
import WidgetKit

/// Publishes the latest safe-to-spend inputs to the widget through the shared App Group.
enum WidgetBridge {
    static func publish(_ snapshot: WidgetSnapshot) {
        snapshot.save(to: UserDefaults(suiteName: WidgetSnapshot.appGroup))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Recomputes from the store (used by intents, which run without the app's views), publishes, and
    /// returns today's numbers.
    @MainActor @discardableResult
    static func publish(from context: ModelContext, now: Date = .now) throws -> SafeToSpend {
        let entries = try context.fetch(FetchDescriptor<Transaction>()).map(\.ledgerEntry)
        let lines = try context.fetch(FetchDescriptor<BudgetCategory>()).map(\.planLine)
        publish(WidgetSnapshot(entries: entries, lines: lines, now: now))
        return SafeToSpend.compute(entries: entries, lines: lines, now: now)
    }
}

/// "Log $12 coffee in Margin": records a personal expense without opening the app.
struct LogExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log an Expense"
    static let description = IntentDescription("Records a personal expense in Margin and tells you what’s left to spend today.")

    @Parameter(title: "Amount") var amount: Double
    @Parameter(title: "What was it?") var merchant: String
    @Parameter(title: "Category") var category: String?

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$amount) for \(\.$merchant)") { \.$category } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cents = (amount * 100).rounded() / 100
        guard cents > 0, cents.isFinite else { throw $amount.needsValueError("How much was it?") }
        let context = MarginStore.shared.mainContext
        let chosen = Self.resolveCategory(category, in: try context.fetch(FetchDescriptor<BudgetCategory>()))
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(Transaction(title: name.isEmpty ? chosen : name, amount: cents, category: chosen, ledgerScope: "personal"))
        try context.save()
        let safe = try WidgetBridge.publish(from: context)
        return .result(dialog: "Logged \(cents.moneyExact) in \(chosen). You can still spend \(safe.safeToday.money) today.")
    }

    /// The spoken category if it matches one (case-insensitive), else "Personal", else the first flexible category.
    static func resolveCategory(_ spoken: String?, in categories: [BudgetCategory]) -> String {
        let names = categories.sorted { $0.name < $1.name }
        if let spoken = spoken?.trimmingCharacters(in: .whitespaces), !spoken.isEmpty,
           let match = names.first(where: { $0.name.caseInsensitiveCompare(spoken) == .orderedSame }) { return match.name }
        return names.first { $0.name == "Personal" }?.name ?? names.first(where: \.isFlexible)?.name ?? "Personal"
    }
}

/// "What can I spend today in Margin?"
struct SafeToSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Safe to Spend Today"
    static let description = IntentDescription("Tells you how much you can safely spend today.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let safe = try WidgetBridge.publish(from: MarginStore.shared.mainContext)
        return .result(dialog: "You can safely spend \(safe.safeToday.money) today, with \(safe.flexibleLeft.money) flexible left for the next \(safe.daysLeft) days.")
    }
}

struct MarginShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogExpenseIntent(), phrases: ["Log an expense in \(.applicationName)", "Add spending to \(.applicationName)"],
                    shortTitle: "Log Expense", systemImageName: "plus.circle")
        AppShortcut(intent: SafeToSpendIntent(), phrases: ["What can I spend today in \(.applicationName)", "Check \(.applicationName)"],
                    shortTitle: "Safe to Spend", systemImageName: "sun.max")
    }
}
