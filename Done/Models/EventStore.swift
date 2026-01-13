//
//  EventStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation
import Combine

@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [Event] = []

    private let storageKey = "events"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            events = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([Event].self, from: data)
            events = decoded
            assignMissingGridPositions()
        } catch {
            events = []
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(events)
            defaults.set(data, forKey: storageKey)
        } catch {
            defaults.removeObject(forKey: storageKey)
        }
    }

    func add(_ event: Event) {
        events.append(event)
        save()
    }

    func addWithAutoPlacement(_ event: Event) {
        var event = event
        if !event.type.isEmpty {
            event.gridHeight += 1
        }
        if event.gridX == nil || event.gridY == nil {
            let position = EventGridLayout.nextAvailablePosition(for: event, in: events)
            event.gridX = position.x
            event.gridY = position.y
        }
        add(event)
    }

    func update(_ event: Event) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
            save()
        }
    }

    func delete(_ event: Event) {
        events.removeAll { $0.id == event.id }
        save()
    }

    func replaceAll(_ newEvents: [Event]) {
        events = newEvents
        save()
    }

    private func assignMissingGridPositions() {
        var occupied: [EventGridLayout.Rect] = []
        var updated = false

        for index in events.indices {
            let event = events[index]
            let spanColumns = EventGridLayout.spanColumns(for: event)
            let spanRows = EventGridLayout.spanRows(for: event)

            if let x = event.gridX, let y = event.gridY {
                occupied.append(
                    EventGridLayout.Rect(x: x, y: y, width: spanColumns, height: spanRows)
                )
                continue
            }

            let position = EventGridLayout.nextAvailablePosition(
                spanColumns: spanColumns,
                spanRows: spanRows,
                occupied: occupied
            )

            events[index].gridX = position.x
            events[index].gridY = position.y
            occupied.append(
                EventGridLayout.Rect(
                    x: position.x,
                    y: position.y,
                    width: spanColumns,
                    height: spanRows
                )
            )
            updated = true
        }

        if updated {
            save()
        }
    }
}
