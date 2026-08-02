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
    @State private var showDeleteConfirm = false

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
        _repeatEndType = State(initialValue: endTypeIsValid ? series.repeatEndType : .none)
        _repeatEndDate = State(initialValue: series.repeatEndDate ?? occurrenceDate)
        _repeatEndCount = State(initialValue: series.repeatEndCount ?? 10)
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
                    Text(L(.manageRepeatFooter))
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
        store.applyRecurringEdit(
            seriesEvent: series,
            occurrenceDate: occurrenceDate,
            scope: .all
        ) { e in
            e.repeatUnit = repeatUnit
            e.repeatInterval = max(1, repeatInterval)
            e.repeatEndType = repeatUnit == .none ? .none : repeatEndType
            e.repeatEndDate = (repeatUnit != .none && repeatEndType == .onDate) ? repeatEndDate : nil
            e.repeatEndCount = (repeatUnit != .none && repeatEndType == .afterCount) ? repeatEndCount : nil
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
