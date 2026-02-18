//
//  EventGridInteractions.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

extension EventGridView {
    func syncZOrder(with events: [Event]) {
        let ids = events.map { $0.id }
        let existing = zOrder.filter { ids.contains($0) }
        let missing = ids.filter { !existing.contains($0) }
        zOrder = existing + missing
    }

    func bringToFront(_ eventID: UUID) {
        zOrder.removeAll { $0 == eventID }
        zOrder.append(eventID)
    }

    func zIndex(for eventID: UUID) -> Double {
        guard let index = zOrder.firstIndex(of: eventID) else { return 0 }
        return Double(index)
    }

    func shouldBeginDrag(for eventID: UUID) -> Bool {
        dragState == nil || dragState?.eventID == eventID
    }

    func beginDrag(for placed: PositionedEvent) {
        guard shouldBeginDrag(for: placed.event.id) else { return }
        isDraggingEvent = true
        longPressingEventID = nil
        dragState = DragState(
            eventID: placed.event.id,
            initialGridX: placed.gridX,
            initialGridY: placed.gridY,
            spanColumns: placed.spanColumns,
            spanRows: placed.spanRows,
            translation: .zero
        )
    }

    func updateDrag(for eventID: UUID, translation: CGSize) {
        guard var current = dragState, current.eventID == eventID else { return }
        current.translation = translation
        dragState = current
    }

    func endDrag(
        for placed: PositionedEvent,
        translation: CGSize,
        endLocation: CGPoint,
        cellSize: CGFloat
    ) {
        guard let dragState, dragState.eventID == placed.event.id else { return }
        if deleteZoneFrame.contains(endLocation) {
            store.delete(placed.event)
            self.dragState = nil
            isDraggingEvent = false
            return
        }
        let snapped = dragState.snappedPosition(translation: translation, cellSize: cellSize, columnsCount: EventGridLayout.columnsCount)
        updateEvent(placed.event, gridX: snapped.x, gridY: snapped.y)
        self.dragState = nil
        isDraggingEvent = false
    }

    func updateEvent(_ event: Event, gridX: Int, gridY: Int) {
        guard event.gridX != gridX || event.gridY != gridY else { return }
        var updated = event
        updated.gridX = gridX
        updated.gridY = gridY
        store.update(updated)
    }

    func clearFocus() {
        focusedEventID = nil
    }

    func commitResize(for placed: PositionedEvent, cellSize: CGFloat) {
        guard let rs = resizeState, rs.eventID == placed.event.id else {
            resizeState = nil
            return
        }
        let snap = rs.snappedResult(cellSize: cellSize, columnsCount: EventGridLayout.columnsCount)
        var updated = placed.event
        updated.gridX = snap.gridX
        updated.gridY = snap.gridY
        updated.gridWidth = snap.spanColumns
        updated.gridHeight = snap.spanRows
        store.update(updated)
        resizeState = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func findMergeTarget(
        for placed: PositionedEvent,
        translation: CGSize,
        cellSize: CGFloat,
        in allPlaced: [PositionedEvent]
    ) -> UUID? {
        guard let dragState else { return nil }
        let snapped = dragState.snappedPosition(
            translation: translation,
            cellSize: cellSize,
            columnsCount: EventGridLayout.columnsCount
        )
        let dragRect = EventGridLayout.Rect(
            x: snapped.x,
            y: snapped.y,
            width: placed.spanColumns,
            height: placed.spanRows
        )
        for other in allPlaced where other.event.id != placed.event.id {
            if dragRect.intersects(x: other.gridX, y: other.gridY, width: other.spanColumns, height: other.spanRows) {
                return other.event.id
            }
        }
        return nil
    }

}
