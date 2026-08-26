import SwiftUI

/// Sheet for managing a recurring series' RULE — frequency / interval / end —
/// and its lifecycle (delete the whole series). Reached from an occurrence's
/// detail "Manage repeat…" entry, seeded with the series and the day it was
/// opened from.
///
/// Also reached from the Settings "Recurring events" list
/// (`CalendarRecurringSeriesListView`, below, seeded at the series start).
///
/// Rule changes apply to the ENTIRE series, or — from a mid-series occurrence,
/// via the "Apply to" control — to "this and following" (splitting the series).
/// Per-occurrence edits stay in the detail view (single-occurrence); days the
/// user already customized are detached exceptions a whole-series rule change
/// deliberately does not move (they carry the "Customized" badge).
struct CalendarRecurrenceRuleEditor: View {
    let series: Event
    let occurrenceDate: Date

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    @State private var repeatUnit: Event.RepeatUnit
    @State private var repeatInterval: Int
    @State private var repeatEndType: Event.RepeatEndType
    @State private var repeatEndDate: Date
    /// SCOPE-SPECIFIC afterCount state — see `ScopedEndCount` (gh#126).
    @State private var endCounts: ScopedEndCount
    @State private var applyFollowing = false
    @State private var showDeleteConfirm = false

    // The end SHAPE as first shown (degenerate ends normalized to .none); lets a
    // `.following` save leave the end alone when the user didn't change it,
    // rather than re-stamping a normalized value-less end over what applyEdit
    // produced. The COUNT is deliberately not part of this comparison — it is
    // scope-specific state now, so it needs no untouched-value exception.
    private let initialEndType: Event.RepeatEndType
    private let initialEndDate: Date

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
        _repeatEndType = State(initialValue: shownEndType)
        _repeatEndDate = State(initialValue: shownEndDate)
        _endCounts = State(initialValue: ScopedEndCount(series: series, occurrenceDate: occurrenceDate))
        initialEndType = shownEndType
        initialEndDate = shownEndDate
    }

    /// The "After N occurrences" stepper means two DIFFERENT things in this
    /// sheet, because unlike the edit sheet its scope changes live via the
    /// "Apply to" picker: under `All events` it is the whole series' total,
    /// under `This and following` it is the split-off series' remaining count
    /// (the tapped occurrence becomes that series' first). Holding one value for
    /// both meanings is what made a single stepper nudge inflate the schedule by
    /// `elapsed` (gh#126), so each scope keeps its own number and a switch of
    /// the picker never leaks one into the other.
    struct ScopedEndCount: Equatable {
        /// The whole series' total, as `.all` writes it.
        var all: Int
        /// The split-off series' count, starting at the tapped occurrence.
        var following: Int

        init(series: Event, occurrenceDate: Date, calendar: Calendar = .current) {
            // Both seeds fall back to the same 10 the sheet has always shown for
            // a series with no count (e.g. switching "Ends" to "After …").
            all = Event.scopedRepeatEndCount(
                series: series,
                occurrenceDate: occurrenceDate,
                requestedScope: Event.RecurrenceEditScope.all,
                calendar: calendar
            ) ?? 10
            following = Event.scopedRepeatEndCount(
                series: series,
                occurrenceDate: occurrenceDate,
                requestedScope: Event.RecurrenceEditScope.following,
                calendar: calendar
            ) ?? 10
        }

        func value(following applyingToFollowing: Bool) -> Int {
            applyingToFollowing ? following : all
        }

        mutating func set(_ newValue: Int, following applyingToFollowing: Bool) {
            if applyingToFollowing { following = newValue } else { all = newValue }
        }
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
                            Stepper(
                                "After \(shownEndCount) occurrences",
                                value: Binding(
                                    get: { shownEndCount },
                                    set: { endCounts.set($0, following: followingSelected) }
                                ),
                                in: 1...999
                            )
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

    /// "This and following" is offered exactly when the store would actually
    /// SPLIT — single-sourced on `Event.resolvedRecurrenceEditScope`, the same
    /// resolver `applyRecurringEdit` / `deleteRecurringCalendarEvent` run. A
    /// day-based `occurrenceDate > seriesStart` compare is NOT equivalent: the
    /// resolver is occurrence-INDEX-based, so for a date strictly between the
    /// seed and the second pattern occurrence (weekly: +1…+6 days — reachable
    /// via Manage Repeat opened from a detached exception moved off-pattern)
    /// the day compare showed "This and future" while the store silently
    /// coerced the save to `.all`, applying the rule change to the whole
    /// series with no split (the UI/domain split-brain gh#124's shared
    /// resolver exists to prevent).
    static func canApplyFollowing(series: Event, occurrenceDate: Date) -> Bool {
        series.isRecurringSeries
            && Event.resolvedRecurrenceEditScope(
                requested: .following,
                series: series,
                occurrenceDate: occurrenceDate
            ) == .following
    }

    private var canApplyFollowing: Bool {
        Self.canApplyFollowing(series: series, occurrenceDate: occurrenceDate)
    }

    private var followingSelected: Bool { canApplyFollowing && applyFollowing }

    /// The count the stepper shows right now — the meaning the current "Apply
    /// to" selection gives the field. Flipping the picker swaps which stored
    /// number is displayed; it never rewrites either one.
    private var shownEndCount: Int { endCounts.value(following: followingSelected) }

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
        store.applyRecurringEdit(
            seriesEvent: series,
            occurrenceDate: occurrenceDate,
            scope: scope,
            edit: Self.ruleEdit(
                repeatUnit: repeatUnit,
                repeatInterval: repeatInterval,
                repeatEndType: repeatEndType,
                repeatEndDate: repeatEndDate,
                endCount: shownEndCount,
                scope: scope,
                // Only the end SHAPE (type / date) rides the untouched guard.
                endShapeChanged: repeatEndType != initialEndType || repeatEndDate != initialEndDate
            )
        )
        dismiss()
    }

    /// The rule mutation a Save applies, as a pure function of the sheet's
    /// state — so the arithmetic this sheet persists is testable without
    /// driving SwiftUI.
    ///
    /// `endCount` is already the value for `scope` (the stepper's state is
    /// scope-specific), so it is written with no untouched-value exception: for
    /// `.following` it IS the split-off series' count. Only the end SHAPE keeps
    /// the guard — a `.following` save must not re-stamp a normalized
    /// value-less end over what `Event.applyEdit` produced (gh#125/#126).
    static func ruleEdit(
        repeatUnit: Event.RepeatUnit,
        repeatInterval: Int,
        repeatEndType: Event.RepeatEndType,
        repeatEndDate: Date,
        endCount: Int,
        scope: Event.RecurrenceEditScope,
        endShapeChanged: Bool
    ) -> (inout Event) -> Void {
        { e in
            e.repeatUnit = repeatUnit
            e.repeatInterval = max(1, repeatInterval)
            let writesEndShape = (scope == .all || endShapeChanged)
            if writesEndShape {
                e.repeatEndType = repeatUnit == .none ? .none : repeatEndType
                e.repeatEndDate = (repeatUnit != .none && repeatEndType == .onDate) ? repeatEndDate : nil
            }
            if repeatUnit != .none, repeatEndType == .afterCount {
                e.repeatEndCount = endCount
            } else if writesEndShape {
                e.repeatEndCount = nil
            }
        }
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
        Self.sortedSeriesList(store.rawCalendarEvents)
    }

    /// Settings-list ordering: render-frame starts, like every other display
    /// read (gh#204). Identity for everything that survives the
    /// `isRecurringSeries` filter (the predicate excludes detached
    /// instances), pinned to the projection so the list can never order by a
    /// frame the canvas doesn't draw. Static so tests bind the real wiring
    /// without driving SwiftUI.
    static func sortedSeriesList(
        _ events: [Event],
        calendar: Calendar = .current
    ) -> [Event] {
        events
            .filter(\.isRecurringSeries)
            .sorted {
                ($0.renderPrimaryTimeRange(calendar: calendar)?.start ?? .distantFuture)
                    < ($1.renderPrimaryTimeRange(calendar: calendar)?.start ?? .distantFuture)
            }
    }

    /// Occurrence seed for a series row's rule-editor sheet (rule edits are
    /// `.all`, the seed is only an anchor). Render-frame for the same reason
    /// as `sortedSeriesList` above (gh#204).
    static func editorSeedOccurrenceDate(
        for series: Event,
        calendar: Calendar = .current
    ) -> Date {
        series.renderPrimaryTimeRange(calendar: calendar)?.start ?? Date()
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
                occurrenceDate: Self.editorSeedOccurrenceDate(for: series)
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
