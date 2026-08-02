import SwiftUI
import SwiftData

@main
struct MarginApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Transaction.self, BudgetCategory.self, SavingsGoal.self, PauseItem.self, Paycheck.self])
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do { return try ModelContainer(for: schema, configurations: [configuration]) }
        catch { fatalError("Could not create Margin data store: \(error)") }
    }()

    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(sharedModelContainer)
    }
}
