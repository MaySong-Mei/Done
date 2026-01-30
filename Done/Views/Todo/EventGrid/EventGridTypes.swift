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

    func snappedPosition(translation: CGSize, cellSize: CGFloat, columnsCount: Int) -> (x: Int, y: Int) {
        let deltaColumns = Int(round(translation.width / cellSize))
        let deltaRows = Int(round(translation.height / cellSize))
        let maxX = max(0, columnsCount - spanColumns)
        let snappedX = min(max(0, initialGridX + deltaColumns), maxX)
        let snappedY = max(0, initialGridY + deltaRows)
        return (x: snappedX, y: snappedY)
    }
}

struct PositionedEvent: Identifiable {
    let event: Event
    let gridX: Int
    let gridY: Int
    let spanColumns: Int
    let spanRows: Int

    var id: UUID { event.id }

    static func from(_ events: [Event]) -> [PositionedEvent] {
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
}
