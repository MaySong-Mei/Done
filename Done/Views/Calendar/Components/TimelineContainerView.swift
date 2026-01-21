//
//  TimelineContainerView.swift
//  Done
//
//  Switchboard for timeline rendering. Picks edit/preview variants and
//  (future) day/3-day/week layouts based on config.
//

import SwiftUI

struct TimelineContainerView: View {
    enum Mode {
        case preview
        case edit
    }

    enum Range {
        case day
        case threeDay
        case week
    }

    let events: [Event]
    let mode: Mode
    let range: Range

    var body: some View {
        switch (mode, range) {
        case (.edit, .day):
            TimelineEditView(events: events)
        case (.preview, .day):
            TimelineView(events: events)
        case (.edit, .threeDay), (.preview, .threeDay),
             (.edit, .week), (.preview, .week):
            // Fallback to day until these layouts are implemented.
            TimelineView(events: events)
        }
    }
}
