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

enum ResizeEdge {
    case top, bottom, leading, trailing
}

struct ResizeState {
    let eventID: UUID
    let edge: ResizeEdge
    let initialGridX: Int
    let initialGridY: Int
    let initialSpanColumns: Int
    let initialSpanRows: Int
    var translation: CGSize

    func snappedResult(cellSize: CGFloat, columnsCount: Int) -> (gridX: Int, gridY: Int, spanColumns: Int, spanRows: Int) {
        let minSpan = 3
        switch edge {
        case .bottom:
            let delta = max(minSpan - initialSpanRows, Int(round(translation.height / cellSize)))
            return (initialGridX, initialGridY, initialSpanColumns, initialSpanRows + delta)
        case .top:
            let raw = Int(round(translation.height / cellSize))
            let delta = max(-initialGridY, min(initialSpanRows - minSpan, raw))
            return (initialGridX, initialGridY + delta, initialSpanColumns, initialSpanRows - delta)
        case .trailing:
            let maxDelta = columnsCount - initialGridX - initialSpanColumns
            let raw = Int(round(translation.width / cellSize))
            let delta = max(minSpan - initialSpanColumns, min(maxDelta, raw))
            return (initialGridX, initialGridY, initialSpanColumns + delta, initialSpanRows)
        case .leading:
            let raw = Int(round(translation.width / cellSize))
            let delta = max(-initialGridX, min(initialSpanColumns - minSpan, raw))
            return (initialGridX + delta, initialGridY, initialSpanColumns - delta, initialSpanRows)
        }
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
