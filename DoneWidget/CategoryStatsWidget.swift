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

/// What the widget's percents are of.
enum CategoryStatsBasisOption: String, AppEnum {
    case logged
    case elapsed

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Share Basis")
    static let caseDisplayRepresentations: [CategoryStatsBasisOption: DisplayRepresentation] = [
        .logged: DisplayRepresentation(title: "Share of logged time"),
        .elapsed: DisplayRepresentation(title: "Share of elapsed time"),
    ]

    var statsBasis: CategoryStatsBasis {
        switch self {
        case .logged: return .logged
        case .elapsed: return .elapsed
        }
    }
}

/// A widget configuration that reads into the category-stats options: what
/// `CategoryStatsProvider` needs of it.
protocol CategoryStatsWidgetIntent: WidgetConfigurationIntent {
    var options: CategoryStatsOptions { get }
}

struct CategoryStatsConfigurationIntent: CategoryStatsWidgetIntent {
    static let title: LocalizedStringResource = "Time by Category"
    static let description = IntentDescription("Choose the span the widget adds up.")

    @Parameter(title: "Period", default: .week)
    var period: CategoryStatsPeriodOption

    @Parameter(title: "Show as", default: .logged)
    var basis: CategoryStatsBasisOption

    /// Off unless the user turns it on: the list it reads is the Me tab's,
    /// set in the app, and the widget cannot show it.
    @Parameter(title: "Exclude background categories",
               description: "Leaves out the categories selected under Me › Edit profile › Hide from Me tab.",
               default: false)
    var excludesBackground: Bool

    /// The exclusion is offered only where it applies: the elapsed basis's
    /// bar is the whole span, background included.
    static var parameterSummary: some ParameterSummary {
        When(\CategoryStatsConfigurationIntent.$basis, .equalTo, CategoryStatsBasisOption.logged) {
            Summary {
                \.$period
                \.$basis
                \.$excludesBackground
            }
        } otherwise: {
            Summary {
                \.$period
                \.$basis
            }
        }
    }

    var options: CategoryStatsOptions {
        CategoryStatsOptions(period: period.statsPeriod, basis: basis.statsBasis, excludesBackground: excludesBackground)
    }
}

// MARK: - Timeline

struct CategoryStatsEntry<Configuration: CategoryStatsWidgetIntent>: TimelineEntry {
    let date: Date
    let summary: CategoryStatsSummary
    /// The widget's own settings, for a face that draws by them.
    let configuration: Configuration
}

/// Entries on the schedule every widget here shares
/// (`WidgetTimelineSchedule.entryDates`: event boundaries, 15-minute ticks,
/// the day rollover, then `.atEnd`), each one the payload read at its own
/// instant — the elapsed-clamp moves with the entry, so time still being
/// spent keeps counting without a refresh. Every widget on these options
/// shares it, each with its own configuration intent.
struct CategoryStatsProvider<Configuration: CategoryStatsWidgetIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CategoryStatsEntry<Configuration> {
        CategoryStatsEntry(date: .now, summary: Self.sample(CategoryStatsOptions(), family: context.family), configuration: Configuration())
    }

    func snapshot(for configuration: Configuration, in context: Context) async -> CategoryStatsEntry<Configuration> {
        let options = configuration.options
        if context.isPreview {
            return CategoryStatsEntry(date: .now, summary: Self.sample(options, family: context.family), configuration: configuration)
        }
        return Self.entry(at: .now, payload: SharedWidgetData.readCategoryStats(), options: options,
                          configuration: configuration)
    }

    func timeline(for configuration: Configuration, in context: Context) async -> Timeline<CategoryStatsEntry<Configuration>> {
        let payload = SharedWidgetData.readCategoryStats()
        let options = configuration.options
        // The payload's own calendar, so the rollover entry lands on the
        // day boundary the payload's days were cut at.
        let calendar = payload?.resolvedCalendar() ?? .current
        let entries = WidgetTimelineSchedule.entryDates(events: SharedWidgetData.read(), now: .now, calendar: calendar)
            .map { date in Self.entry(at: date, payload: payload, options: options, configuration: configuration) }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private static func entry(
        at date: Date, payload: CategoryStatsPayload?, options: CategoryStatsOptions, configuration: Configuration
    ) -> CategoryStatsEntry<Configuration> {
        CategoryStatsEntry(date: date, summary: CategoryStats.summary(of: payload, options: options, asOf: date),
                           configuration: configuration)
    }

    private static func sample(_ options: CategoryStatsOptions, family: WidgetFamily) -> CategoryStatsSummary {
        CategoryStatsLayout.sample(options.period, basis: options.basis, chinese: AppLanguage.current == .chinese,
                                   extended: family == .systemLarge)
    }
}

// MARK: - Widget

struct CategoryStatsEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: CategoryStatsEntry<CategoryStatsConfigurationIntent>

    var body: some View {
        // Colour is lost on a tinted home screen and on the lock screen; the
        // faces switch to gaps and an opacity ladder there.
        let accented = renderingMode != .fullColor
        let face = CategoryStatsFace(family: family)
        if face == .circular {
            ZStack {
                AccessoryWidgetBackground()
                CategoryStatsWidgetView(summary: entry.summary, face: face, accented: accented)
            }
        } else {
            CategoryStatsWidgetView(summary: entry.summary, face: face, accented: accented)
        }
    }
}

struct CategoryStatsWidget: Widget {
    let kind = "DoneCategoryStatsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CategoryStatsConfigurationIntent.self,
                               provider: CategoryStatsProvider<CategoryStatsConfigurationIntent>()) { entry in
            CategoryStatsEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.categoryStats))
        .description(LFormat.categoryStatsDescription())
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}
