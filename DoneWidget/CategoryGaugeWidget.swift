import AppIntents
import WidgetKit
import SwiftUI

/// The gauge's Edit Widget sheet: the "Time by Category" options, with the
/// same defaults and the same exclusion shown only in the logged basis, and
/// whether the segments are set apart by gaps — off unless the user turns it
/// on, a seamless ring being the one the user preferred. Its own intent, so
/// the list widget's sheet never shows a setting it has no use for.
struct CategoryGaugeConfigurationIntent: CategoryStatsWidgetIntent {
    static let title: LocalizedStringResource = "Category Gauge"
    static let description = IntentDescription("Choose the span the gauge adds up and how it looks.")

    @Parameter(title: "Period", default: .week)
    var period: CategoryStatsPeriodOption

    @Parameter(title: "Show as", default: .logged)
    var basis: CategoryStatsBasisOption

    @Parameter(title: "Exclude background categories",
               description: "Leaves out the categories selected under Me › Edit profile › Hide from Me tab.",
               default: false)
    var excludesBackground: Bool

    @Parameter(title: "Gaps between segments", default: false)
    var showsGaps: Bool

    static var parameterSummary: some ParameterSummary {
        When(\CategoryGaugeConfigurationIntent.$basis, .equalTo, CategoryStatsBasisOption.logged) {
            Summary {
                \.$period
                \.$basis
                \.$excludesBackground
                \.$showsGaps
            }
        } otherwise: {
            Summary {
                \.$period
                \.$basis
                \.$showsGaps
            }
        }
    }

    var options: CategoryStatsOptions {
        CategoryStatsOptions(period: period.statsPeriod, basis: basis.statsBasis, excludesBackground: excludesBackground)
    }
}

/// "Category Gauge": the "Time by Category" split as an arc with the hours
/// in its middle, on the same provider and entries as `CategoryStatsWidget`.
struct CategoryGaugeEntryView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: CategoryStatsEntry<CategoryGaugeConfigurationIntent>

    var body: some View {
        CategoryGaugeWidgetView(summary: entry.summary, accented: renderingMode != .fullColor,
                                showsGaps: entry.configuration.showsGaps)
    }
}

struct CategoryGaugeWidget: Widget {
    let kind = "DoneCategoryGaugeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CategoryGaugeConfigurationIntent.self,
                               provider: CategoryStatsProvider<CategoryGaugeConfigurationIntent>()) { entry in
            CategoryGaugeEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.categoryGauge))
        .description(L(.categoryGaugeDescription))
        .supportedFamilies([.systemSmall])
    }
}
