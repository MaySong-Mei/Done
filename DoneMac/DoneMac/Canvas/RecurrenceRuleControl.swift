//
//  RecurrenceRuleControl.swift
//  DoneMac
//
//  The shared repeat-rule editor: unit / interval / end. Bound to plain
//  fields so both the create composer (A1a) and the series rule editor
//  (A1b) drive it. It only edits the rule shape; who it applies to (all vs
//  this-and-following) is the caller's scope decision, never this control's.
//

import SwiftUI

struct RecurrenceRuleControl: View {
    @Binding var unit: Event.RepeatUnit
    @Binding var interval: Int
    @Binding var endType: Event.RepeatEndType
    @Binding var endDate: Date?
    @Binding var endCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Repeat", selection: $unit) {
                Text("Never").tag(Event.RepeatUnit.none)
                Text("Daily").tag(Event.RepeatUnit.day)
                Text("Weekly").tag(Event.RepeatUnit.week)
                Text("Monthly").tag(Event.RepeatUnit.month)
                Text("Yearly").tag(Event.RepeatUnit.year)
            }

            if unit != .none {
                Stepper(value: $interval, in: 1...99) {
                    Text("Every \(interval) \(Self.unitNoun(unit, plural: interval != 1))")
                        .font(.callout)
                }

                Picker("Ends", selection: $endType) {
                    Text("Never").tag(Event.RepeatEndType.none)
                    Text("On date").tag(Event.RepeatEndType.onDate)
                    Text("After…").tag(Event.RepeatEndType.afterCount)
                }
                .pickerStyle(.segmented)

                switch endType {
                case .onDate:
                    DatePicker("End date", selection: Binding(
                        get: { endDate ?? Self.defaultEndDate() },
                        set: { endDate = $0 }
                    ), displayedComponents: .date)
                case .afterCount:
                    Stepper(value: Binding(
                        get: { endCount ?? 1 },
                        set: { endCount = $0 }
                    ), in: 1...999) {
                        Text("After \(endCount ?? 1) occurrence\((endCount ?? 1) == 1 ? "" : "s")")
                            .font(.callout)
                    }
                case .none:
                    EmptyView()
                }
            }
        }
        // Seed the model the instant the segment flips, so what the pickers
        // DISPLAY (their get-side defaults) is also what's persisted — an
        // `.onDate` left untouched must not save a nil date, which the render
        // gate would collapse to a single occurrence (review #1).
        .onChange(of: endType) { _, newValue in
            if newValue == .onDate, endDate == nil { endDate = Self.defaultEndDate() }
            if newValue == .afterCount, endCount == nil { endCount = 1 }
        }
    }

    private static func unitNoun(_ unit: Event.RepeatUnit, plural: Bool) -> String {
        let base: String
        switch unit {
        case .none: base = ""
        case .day: base = "day"
        case .week: base = "week"
        case .month: base = "month"
        case .year: base = "year"
        }
        return plural ? base + "s" : base
    }

    /// A sensible default end when the user first picks "On date" — a month
    /// out. A view-side `Date()` is fine (this isn't the store's `now`).
    private static func defaultEndDate() -> Date {
        Date().addingTimeInterval(30 * 86_400)
    }
}
