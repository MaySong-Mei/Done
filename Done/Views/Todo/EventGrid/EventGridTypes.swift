//
//  EventGridTypes.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct DragState {
    let eventID: UUID
    let initialGridX: Int
    let initialGridY: Int
    let spanColumns: Int
    let spanRows: Int
    var translation: CGSize
}

struct PositionedEvent: Identifiable {
    let event: Event
    let gridX: Int
    let gridY: Int
    let spanColumns: Int
    let spanRows: Int

    var id: UUID { event.id }
}

func positionedEvents(from events: [Event]) -> [PositionedEvent] {
    events.compactMap { event in
        guard let x = event.gridX, let y = event.gridY else { return nil }
        return PositionedEvent(
            event: event,
            gridX: x,
            gridY: y,
            spanColumns: EventGridLayout.spanColumns(for: event),
            spanRows: EventGridLayout.spanRows(for: event)
        )
    }
}
