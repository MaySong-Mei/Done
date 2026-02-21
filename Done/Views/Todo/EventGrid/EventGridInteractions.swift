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
    }

    func findMergeTarget(for draggedID: UUID, windowLocation: CGPoint) -> UUID? {
        for (id, frame) in cardFrames where id != draggedID {
            if frame.contains(windowLocation) {
                return id
            }
        }
        return nil
    }

    func clearFocus() {
        focusedEventID = nil
    }
}
