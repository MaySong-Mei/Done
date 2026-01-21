//
//  EventGridView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventGridView: View {
    let events: [Event]
    @EnvironmentObject var store: EventStore
    @State var dragState: DragState?
    @State private var selectedEvent: Event?
    @State private var addToCalendarEvent: Event?
    @State var zOrder: [UUID] = []
    @State var longPressingEventID: UUID?
    @State private var shakeTriggers: [UUID: CGFloat] = [:]
    @Binding var isDraggingEvent: Bool
    @Binding var deleteZoneFrame: CGRect

    var body: some View {
        EventGridContentView(
            events: events,
            dragState: $dragState,
            selectedEvent: $selectedEvent,
            addToCalendarEvent: $addToCalendarEvent,
            longPressingEventID: $longPressingEventID,
            shakeTriggers: $shakeTriggers,
            isDraggingEvent: $isDraggingEvent,
            shouldBeginDrag: { shouldBeginDrag(for: $0) },
            bringToFront: bringToFront,
            beginDrag: beginDrag,
            updateDrag: updateDrag,
            endDrag: { placed, translation, endLocation, cellSize in
                endDrag(
                    for: placed,
                    translation: translation,
                    endLocation: endLocation,
                    cellSize: cellSize
                )
            },
            zIndex: zIndex
        )
        .sheet(item: $selectedEvent) { event in
            EditEventView(event: event)
        }
        .sheet(item: $addToCalendarEvent) { event in
            AddToCalendarView(event: event)
        }
        .onAppear {
            syncZOrder(with: events)
        }
        .onChange(of: events) { updatedEvents in
            syncZOrder(with: updatedEvents)
        }
    }
}
