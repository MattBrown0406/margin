import WidgetKit
import SwiftUI

private extension Color {
    static let widgetInk = Color(red: 0.08, green: 0.12, blue: 0.14)
    static let widgetLime = Color(red: 0.75, green: 0.88, blue: 0.35)
}

struct SafeToSpendEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has published this month's numbers.
    let safe: SafeToSpend?
}

struct SafeToSpendProvider: TimelineProvider {
    func placeholder(in context: Context) -> SafeToSpendEntry {
        SafeToSpendEntry(date: .now, safe: .make(limit: 1850, spentBeforeToday: 600, spentToday: 0, now: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SafeToSpendEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: .now))
    }

    /// One entry now and one just after midnight, when the allowance rolls over without the app running.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SafeToSpendEntry>) -> Void) {
        let calendar = Calendar.current, now = Date.now
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let rollover = midnight.addingTimeInterval(60)
        completion(Timeline(entries: [entry(at: now), entry(at: rollover)], policy: .after(rollover)))
    }

    private func entry(at date: Date) -> SafeToSpendEntry {
        SafeToSpendEntry(date: date, safe: WidgetSnapshot.load(from: UserDefaults(suiteName: WidgetSnapshot.appGroup))?.safeToSpend(at: date))
    }
}

struct SafeToSpendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SafeToSpendEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.safe.map { "Safe today \($0.safeToday.money)" } ?? "Open Margin")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("SAFE TODAY").font(.caption2.bold())
                Text(entry.safe?.safeToday.money ?? "—").font(.title2.bold()).widgetAccentable()
                Text(entry.safe.map { "\($0.flexibleLeft.money) left · \($0.daysLeft)d" } ?? "Open Margin to update").font(.caption2)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("SAFE TO SPEND TODAY").font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                if let safe = entry.safe {
                    Text(safe.safeToday.money).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(1)
                    Text("\(safe.flexibleLeft.money) flexible · \(safe.daysLeft) days").font(.caption2).foregroundStyle(Color.widgetLime)
                } else {
                    Text("Open Margin to update this month").font(.subheadline.bold()).foregroundStyle(.white)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct SafeToSpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MarginSafeToSpend", provider: SafeToSpendProvider()) { entry in
            SafeToSpendWidgetView(entry: entry).containerBackground(for: .widget) { Color.widgetInk }
        }
        .configurationDisplayName("Safe to Spend")
        .description("What you can spend today and still hit your plan.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct MarginWidgetBundle: WidgetBundle {
    var body: some Widget { SafeToSpendWidget() }
}
