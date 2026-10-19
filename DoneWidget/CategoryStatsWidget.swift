import AppIntents
import WidgetKit
import SwiftUI

// MARK: - Configuration

/// The span a "Time by Category" widget adds up, as the Edit Widget sheet
/// offers it.
///
/// The display strings here are App Intents metadata: extracted at build time
/// from these literals and looked up in this target's String Catalog
/// (`Localizable.xcstrings`), so they follow the SYSTEM language. Everything
/// the widget draws goes through `L(...)` and follows the in-app language
/// instead (gh#239 F5) — the two can differ, and that is the platform's
/// split, not a missing translation.
enum CategoryStatsPeriodOption: String, AppEnum {
    case today
    case week
    case month

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Period")
    static let caseDisplayRepresentations: [CategoryStatsPeriodOption: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today"),
        .week: DisplayRepresentation(title: "This Week"),
        .month: DisplayRepresentation(title: "This Month"),
    ]

    var statsPeriod: CategoryStatsPeriod {
        switch self {
        case .today: return .today
        case .week: return .week
        case .month: return .month
        }
    }
}

struct CategoryStatsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Time by Category"
    static let description = IntentDescription("Choose the span the widget adds up.")

    @Parameter(title: "Period", default: .week)
    var period: CategoryStatsPeriodOption
}

// MARK: - Timeline

struct CategoryStatsEntry: TimelineEntry {
    let date: Date
    let summary: CategoryStatsSummary
}

/// Entries on the schedule every widget here shares
/// (`WidgetTimelineSchedule.entryDates`: event boundaries, 15-minute ticks,
/// the day rollover, then `.atEnd`), each one the payload read at its own
/// instant — the elapsed-clamp moves with the entry, so time still being
/// spent keeps counting without a refresh.
struct CategoryStatsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CategoryStatsEntry {
        CategoryStatsEntry(date: .now, summary: Self.sample(.week))
    }

    func snapshot(for configuration: CategoryStatsConfigurationIntent, in context: Context) async -> CategoryStatsEntry {
        let period = configuration.period.statsPeriod
        if context.isPreview {
            return CategoryStatsEntry(date: .now, summary: Self.sample(period))
        }
        return Self.entry(at: .now, payload: SharedWidgetData.readCategoryStats(), period: period)
    }

    func timeline(for configuration: CategoryStatsConfigurationIntent, in context: Context) async -> Timeline<CategoryStatsEntry> {
        let payload = SharedWidgetData.readCategoryStats()
        let period = configuration.period.statsPeriod
        // The payload's own calendar, so the rollover entry lands on the
        // day boundary the payload's days were cut at.
        let calendar = payload?.resolvedCalendar() ?? .current
        let entries = WidgetTimelineSchedule.entryDates(events: SharedWidgetData.read(), now: .now, calendar: calendar)
            .map { date in Self.entry(at: date, payload: payload, period: period) }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private static func entry(
        at date: Date, payload: CategoryStatsPayload?, period: CategoryStatsPeriod
    ) -> CategoryStatsEntry {
        CategoryStatsEntry(date: date, summary: CategoryStats.summary(of: payload, period: period, asOf: date))
    }

    private static func sample(_ period: CategoryStatsPeriod) -> CategoryStatsSummary {
        CategoryStatsLayout.sample(period, chinese: AppLanguage.current == .chinese)
    }
}

// MARK: - Widget

struct CategoryStatsEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: CategoryStatsEntry

    var body: some View {
        // Colour is lost on a tinted home screen and on the lock screen; the
        // faces switch to gaps and an opacity ladder there.
        let accented = renderingMode != .fullColor
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                CategoryStatsWidgetView(summary: entry.summary, face: .circular, accented: accented)
            }
        case .accessoryRectangular:
            CategoryStatsWidgetView(summary: entry.summary, face: .rectangular, accented: accented)
        case .systemMedium:
            CategoryStatsWidgetView(summary: entry.summary, face: .medium, accented: accented)
        default:
            CategoryStatsWidgetView(summary: entry.summary, face: .small, accented: accented)
        }
    }
}

struct CategoryStatsWidget: Widget {
    let kind = "DoneCategoryStatsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CategoryStatsConfigurationIntent.self,
                               provider: CategoryStatsProvider()) { entry in
            CategoryStatsEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.categoryStats))
        .description(L(.categoryStatsDesc))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
