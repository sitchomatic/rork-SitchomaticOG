import WidgetKit
import SwiftUI

nonisolated struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entries = [SimpleEntry(date: .now)]
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

nonisolated struct SimpleEntry: TimelineEntry {
    let date: Date
}

struct WidgetView: View {
    var entry: Provider.Entry

    var body: some View {
        Text(entry.date, style: .time)
    }
}

struct SitchomaticWidget: Widget {
    let kind: String = "SitchomaticWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SitchomaticWidget")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
