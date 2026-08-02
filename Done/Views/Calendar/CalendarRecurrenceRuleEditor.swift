import SwiftUI

/// Sheet for managing a recurring series' RULE — frequency / interval / end —
/// and its lifecycle (delete the whole series). Reached from an occurrence's
/// detail "Manage repeat…" entry, seeded with the series and the day it was
/// opened from.
///
/// Rule changes here apply to the ENTIRE series (`applyRecurringEdit(.all)`).
/// Per-occurrence edits stay in the detail view (single-occurrence), and days
/// the user already customized on the calendar are detached exceptions that a
/// rule change deliberately does not move (they carry the "Customized" badge).
///
/// Deliberately NOT in this slice: "this and following" (its occurrence-
/// boundary + afterCount interaction wants its own design) and the Settings
/// series list — both are follow-up slices.
struct CalendarRecurrenceRuleEditor: View {
    let series: Event
    let occurrenceDate: Date

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    @State private var repeatUnit: Event.RepeatUnit
    @State private var repeatInterval: Int
    @State private var repeatEndType: Event.RepeatEndType
    @State private var repeatEndDate: Date
    @State private var repeatEndCount: Int
    @State private var applyFollowing = false
    @State private var showDeleteConfirm = false

    // The end as first shown (degenerate ends normalized to .none); lets a
    // `.following` save avoid overriding applyEdit's afterCount decrement when
    // the user didn't actually change the end.
    private let initialEndType: Event.RepeatEndType
    private let initialEndDate: Date
    private let initialEndCount: Int

    init(series: Event, occurrenceDate: Date) {
        self.series = series
        self.occurrenceDate = occurrenceDate
        _repeatUnit = State(initialValue: series.repeatUnit == .none ? .day : series.repeatUnit)
        _repeatInterval = State(initialValue: max(1, series.repeatInterval))
        // A typed-but-value-less end (endType .onDate/.afterCount with a nil
        // date/count) renders forever; show it as "Never" so a no-op Save keeps
        // it unbounded instead of fabricating occurrenceDate / 10 and silently
        // truncating the series.
        let endTypeIsValid = (series.repeatEndType == .onDate && series.repeatEndDate != nil)
            || (series.repeatEndType == .afterCount && series.repeatEndCount != nil)
        let shownEndType: Event.RepeatEndType = endTypeIsValid ? series.repeatEndType : .none
        let shownEndDate = series.repeatEndDate ?? occurrenceDate
        let shownEndCount = series.repeatEndCount ?? 10
        _repeatEndType = State(initialValue: shownEndType)
        _repeatEndDate = State(initialValue: shownEndDate)
        _repeatEndCount = State(initialValue: shownEndCount)
        initialEndType = shownEndType
        initialEndDate = shownEndDate
        initialEndCount = shownEndCount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // No "Never" here: a recurring series' rule editor edits the
                    // rule, not its absence. To stop repeating, set an end date
                    // or delete the series — this also avoids collapsing to a
                    // plain event that would double-render on an excepted seed day.
                    Picker(L(.repeatLabel), selection: $repeatUnit) {
                        Text(L(.daily)).tag(Event.RepeatUnit.day)
                        Text(L(.weekly)).tag(Event.RepeatUnit.week)
                        Text(L(.monthly)).tag(Event.RepeatUnit.month)
                        Text(L(.yearly)).tag(Event.RepeatUnit.year)
                    }
                    if repeatUnit != .none {
                        Stepper("Every \(repeatInterval) \(unitNoun)", value: $repeatInterval, in: 1...99)
                        Picker(L(.ends), selection: $repeatEndType) {
                            Text(L(.never)).tag(Event.RepeatEndType.none)
                            Text(L(.onDate)).tag(Event.RepeatEndType.onDate)
                            Text(L(.afterCount)).tag(Event.RepeatEndType.afterCount)
                        }
                        if repeatEndType == .onDate {
                            DatePicker(L(.endDate), selection: $repeatEndDate, displayedComponents: .date)
                        }
                        if repeatEndType == .afterCount {
                            Stepper("After \(repeatEndCount) occurrences", value: $repeatEndCount, in: 1...999)
                        }
                    }
                } footer: {
                    Text(followingSelected ? L(.manageRepeatFollowingFooter) : L(.manageRepeatFooter))
                }

                if canApplyFollowing {
                    Section {
                        Picker(L(.applyTo), selection: $applyFollowing) {
                            Text(L(.allEvents)).tag(false)
                            Text(L(.thisAndFuture)).tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text(L(.deleteEntireSeries))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(L(.manageRepeat))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.save)) { save() }
                }
            }
            .confirmationDialog(
                L(.deleteRecurringEvent),
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(L(.deleteEntireSeries), role: .destructive) { deleteSeries() }
                Button(L(.cancel), role: .cancel) { }
            } message: {
                Text(L(.deleteConfirmAllSeries))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// "This and following" only makes sense from a mid-series occurrence — not
    /// from the series' own start day (that would just replace the whole series)
    /// nor from the Settings list (which seeds occurrenceDate = series start).
    private var canApplyFollowing: Bool {
        guard let start = series.primaryTimeRange?.start else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: occurrenceDate) > calendar.startOfDay(for: start)
    }

    private var followingSelected: Bool { canApplyFollowing && applyFollowing }

    private var unitNoun: String {
        switch repeatUnit {
        case .none: return ""
        case .day: return "day(s)"
        case .week: return "week(s)"
        case .month: return "month(s)"
        case .year: return "year(s)"
        }
    }

    private func save() {
        let scope: Event.RecurrenceEditScope = followingSelected ? .following : .all
        let endChanged = repeatEndType != initialEndType
            || repeatEndDate != initialEndDate
            || repeatEndCount != initialEndCount
        store.applyRecurringEdit(
            seriesEvent: series,
            occurrenceDate: occurrenceDate,
            scope: scope
        ) { e in
            e.repeatUnit = repeatUnit
            e.repeatInterval = max(1, repeatInterval)
            // For a `.following` save with an untouched end, leave the end as
            // applyEdit set it — which for an `.afterCount` series is the
            // DECREMENTED remaining count (Step 3a), so the split-off series
            // doesn't inflate back to the full N.
            if scope == .all || endChanged {
                e.repeatEndType = repeatUnit == .none ? .none : repeatEndType
                e.repeatEndDate = (repeatUnit != .none && repeatEndType == .onDate) ? repeatEndDate : nil
                e.repeatEndCount = (repeatUnit != .none && repeatEndType == .afterCount) ? repeatEndCount : nil
            }
        }
        dismiss()
    }

    private func deleteSeries() {
        store.deleteRecurringCalendarEvent(
            seriesEvent: series,
            occurrenceDate: occurrenceDate,
            scope: .all
        )
        dismiss()
    }
}

/// Settings screen listing every recurring series so their rules can be managed
/// away from the calendar. Tapping a series opens the same
/// `CalendarRecurrenceRuleEditor` sheet the detail "Manage repeat…" entry uses,
/// seeded with the series' start (rule edits are `.all`, so no occurrence anchor
/// is needed here).
struct CalendarRecurringSeriesListView: View {
    @EnvironmentObject private var store: EventStore
    @State private var editingSeries: Event?

    private var seriesList: [Event] {
        store.rawCalendarEvents
            .filter(\.isRecurringSeries)
            .sorted {
                ($0.primaryTimeRange?.start ?? .distantFuture)
                    < ($1.primaryTimeRange?.start ?? .distantFuture)
            }
    }

    var body: some View {
        settingsPage(L(.recurringEventsTitle)) {
            if seriesList.isEmpty {
                settingsHintCard(L(.noRecurringSeries))
            } else {
                settingsCard {
                    ForEach(Array(seriesList.enumerated()), id: \.element.id) { index, series in
                        if index > 0 { Divider() }
                        Button {
                            editingSeries = series
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(CalendarLayout.eventColor(for: series))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(series.title.isEmpty ? L(.calendarEventFallback) : series.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(ruleSummary(series))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $editingSeries) { series in
            CalendarRecurrenceRuleEditor(
                series: series,
                occurrenceDate: series.primaryTimeRange?.start ?? Date()
            )
            .environmentObject(store)
        }
    }

    private func ruleSummary(_ series: Event) -> String {
        let base: String
        switch series.repeatUnit {
        case .none: base = ""
        case .day: base = L(.daily)
        case .week: base = L(.weekly)
        case .month: base = L(.monthly)
        case .year: base = L(.yearly)
        }
        var summary = series.repeatInterval > 1 ? "\(base) · ×\(series.repeatInterval)" : base
        switch series.repeatEndType {
        case .onDate:
            if let end = series.repeatEndDate {
                summary += " · \(Self.summaryDateFormatter().string(from: end))"
            }
        case .afterCount:
            if let count = series.repeatEndCount {
                summary += " · \(count)×"
            }
        case .none:
            break
        }
        return summary
    }

    private static func summaryDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = AppLanguage.current.locale
        return f
    }
}
