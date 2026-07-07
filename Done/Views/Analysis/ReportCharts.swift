//
//  ReportCharts.swift
//  Done
//
//  Deterministic charts for the report detail page, rendered straight from a
//  report's frozen `ReportStats` snapshot — zero language-model involvement, so
//  every past report gains them retroactively without regeneration.
//
//  The palette is never invented here: category colors come from
//  `EventTypeTemplateStore.color(for:)`, the same static source the calendar and
//  the Analysis charts read, so a category's color is identical everywhere.  The
//  look serves the editorial layout: quiet fills, caption-level labels,
//  `.secondary` supporting text, no legends and no animation.
//

import SwiftUI
import Charts

// MARK: - Section

/// The two report charts stacked above the prose.  Returns `EmptyView` whenever
/// the snapshot has no recorded day or no category time, so the detail page
/// never opens a blank slot between the masthead rule and the essay.
struct ReportChartsSection: View {
    let stats: ReportStats

    /// Highest-time categories first, capped so the horizontal bars stay legible.
    private var topTypes: [ReportTypeHours] {
        Array(
            stats.perTypeHours
                .filter { $0.hours > 0 }
                .sorted { $0.hours > $1.hours }
                .prefix(6)
        )
    }

    private var hasData: Bool {
        stats.window.recordedDayCount > 0 && !topTypes.isEmpty
    }

    var body: some View {
        if hasData {
            VStack(alignment: .leading, spacing: 24) {
                if !stats.dailyTotals.isEmpty {
                    ReportDailyRhythmChart(totals: stats.dailyTotals)
                }
                ReportCategoryHoursChart(types: topTypes)
            }
        }
    }
}

// MARK: - Daily rhythm

/// One quiet bar per calendar day in the window, height = scheduled hours.
/// Weekday-abbreviation ticks thin out as the window widens (every day for a
/// week, weekly for a month) so a ~30-bar month stays readable and a single-day
/// window still draws a centered, fixed-width bar rather than one full-bleed slab.
private struct ReportDailyRhythmChart: View {
    let totals: [ReportDailyTotal]

    /// Sparse windows keep every weekday tick; dense ones step by a week.
    private var tickStride: Int { totals.count > 10 ? 7 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(.reportChartDailyRhythm))
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart(totals, id: \.date) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Hours", day.hours),
                    // A fixed slim width keeps a one-bar window from spanning the
                    // whole plot; wider windows compress it toward the day step.
                    width: .fixed(totals.count == 1 ? 28 : 6)
                )
                .foregroundStyle(Color.secondary.opacity(0.5))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: tickStride)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(Self.weekdayLabel(date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text("\(Int(hours))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 120)
        }
    }

    /// Narrow weekday abbreviation from the app's active locale (e.g. 周一 / Mon).
    private static func weekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

// MARK: - Category hours

/// Horizontal bars for the top categories, colored with each category's own
/// calendar color.  The row label carries the category name and its hours; when
/// a previous-window baseline exists the row tails a tiny delta in `.secondary`.
private struct ReportCategoryHoursChart: View {
    let types: [ReportTypeHours]

    private var maxHours: Double {
        max(types.map(\.hours).max() ?? 0, 0.0001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(.reportChartByCategory))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(types, id: \.type) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: ReportTypeHours) -> some View {
        let color = EventTypeTemplateStore.color(for: entry.type)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.type)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(String(format: "%.1fh", entry.hours))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if entry.previousHours > 0 {
                    Text(deltaLabel(entry.deltaHours))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * (entry.hours / maxHours)))
            }
            .frame(height: 6)
        }
    }

    /// Signed one-decimal delta against the previous equal-length window.
    private func deltaLabel(_ delta: Double) -> String {
        String(format: "%+.1fh", delta)
    }
}
