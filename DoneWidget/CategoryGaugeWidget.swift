import WidgetKit
import SwiftUI

/// "Category Gauge": the "Time by Category" split as a textless arc. Same
/// options, provider and entries as `CategoryStatsWidget`; only the face
/// differs.
struct CategoryGaugeEntryView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: CategoryStatsEntry

    var body: some View {
        CategoryGaugeWidgetView(summary: entry.summary, accented: renderingMode != .fullColor)
    }
}

struct CategoryGaugeWidget: Widget {
    let kind = "DoneCategoryGaugeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CategoryStatsConfigurationIntent.self,
                               provider: CategoryStatsProvider()) { entry in
            CategoryGaugeEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.categoryGauge))
        .description(L(.categoryGaugeDescription))
        .supportedFamilies([.systemSmall])
    }
}
