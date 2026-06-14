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

    func beginDrag(for event: Event) {
        guard shouldBeginDrag(for: event.id) else { return }
        isDraggingEvent = true
        longPressingEventID = nil
        dragStartFrame = cardFrames[event.id]
        dragStartCardFrames = cardFrames
        dragState = DragState(
            eventID: event.id,
            translation: .zero
        )
    }

    func updateDrag(for eventID: UUID, translation: CGSize) {
        guard var current = dragState, current.eventID == eventID else { return }
        current.translation = translation
        dragState = current
    }

    func endDrag(for event: Event, endLocation: CGPoint) {
        guard let dragState, dragState.eventID == event.id else { return }
        if deleteZoneFrame.contains(endLocation) {
            store.delete(event)
        }
        self.dragState = nil
        isDraggingEvent = false
        reorderTarget = nil
        dragStartFrame = nil
        dragStartCardFrames = [:]
    }

    func findReorderTarget(for draggedID: UUID, windowLocation: CGPoint, events: [Event]) -> ReorderTarget? {
        guard events.count > 1 else { return nil }

        // Use frozen frames from drag start to avoid feedback loops
        let frames = dragStartCardFrames.isEmpty ? cardFrames : dragStartCardFrames

        // Compute average midX for each column to determine column boundary
        var leftMidX: CGFloat = 0, rightMidX: CGFloat = 0
        var leftCount = 0, rightCount = 0
        for (i, event) in events.enumerated() {
            guard let frame = frames[event.id] else { continue }
            if i % 2 == 0 { leftMidX += frame.midX; leftCount += 1 }
            else { rightMidX += frame.midX; rightCount += 1 }
        }
        guard leftCount > 0 else { return nil }
        leftMidX /= CGFloat(leftCount)
        if rightCount > 0 { rightMidX /= CGFloat(rightCount) }

        // Determine target column from finger X position
        let boundary = rightCount > 0 ? (leftMidX + rightMidX) / 2 : leftMidX + 100
        let targetColumn = windowLocation.x < boundary ? 0 : (rightCount > 0 ? 1 : 0)

        // Get cards in the target column, excluding the dragged card
        let columnCards = events.enumerated()
            .filter { $0.offset % 2 == targetColumn && $0.element.id != draggedID }
            .map { $0.element }

        // Find insertion row based on Y midpoint comparison
        var targetRow = columnCards.count
        for (j, card) in columnCards.enumerated() {
            guard let frame = frames[card.id] else { continue }
            if windowLocation.y < frame.midY {
                targetRow = j
                break
            }
        }

        // No-op check: card would end up where it already is
        guard let currentFlatIndex = events.firstIndex(where: { $0.id == draggedID }) else { return nil }
        let currentColumn = currentFlatIndex % 2
        let currentRow = currentFlatIndex / 2
        if targetColumn == currentColumn && targetRow == currentRow {
            return nil
        }

        return ReorderTarget(column: targetColumn, row: targetRow)
    }

    func findMergeTarget(for draggedID: UUID, windowLocation: CGPoint) -> UUID? {
        for (id, frame) in cardFrames where id != draggedID {
            if frame.contains(windowLocation) {
                return id
            }
        }
        return nil
    }
}
