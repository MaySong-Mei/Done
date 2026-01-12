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
}
