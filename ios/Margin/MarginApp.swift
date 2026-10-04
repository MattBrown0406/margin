import SwiftUI
import SwiftData

@main
struct MarginApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(MarginStore.shared)
    }
}

enum MarginStore {
    static let schema = Schema([Transaction.self, BudgetCategory.self, SavingsGoal.self, PauseItem.self, Paycheck.self, BookedJob.self])
    /// User preference, read at launch. Both modes use the same on-device store, so switching keeps data.
    static let iCloudSyncKey = "margin.iCloudSync"
    private(set) static var isUsingCloudKit = false

    /// One container for the app and its App Intents, so Siri entries land in the same store.
    @MainActor static let shared: ModelContainer = make()

    private static func make() -> ModelContainer {
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }
        // `.automatic` syncs through the iCloud container in the app's entitlements and quietly stays
        // local when the device isn't signed in to iCloud.
        if UserDefaults.standard.object(forKey: iCloudSyncKey) as? Bool ?? true,
           let container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)]) {
            isUsingCloudKit = true
            return container
        }
        do { return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .none)]) }
        catch { fatalError("Could not create Margin data store: \(error)") }
    }
}
