//
//  AwaitingNameStore.swift
//  Done
//
//  Events waiting for a name: "name later" picked on the watch. The event
//  itself is an ordinary one titled after its type — nothing reads blank,
//  and nothing is lost if it is never named — and this phone remembers, on
//  its own, that the user meant to name it. Not synced and not a field of
//  `Event`: another device just sees the type-titled event.
//
//  A mark holds the title the event had when it was marked, and an event is
//  waiting only while its title is still exactly that. So a rename from
//  anywhere — the detail page's prompt, the edit sheet, another device
//  through sync — ends the wait without any of those paths knowing about
//  marks. Keeping the type as the name has to be said: the prompt's "keep"
//  clears the mark. A mark also ends when its event is gone or after
//  `lifetime`; `prune` drops those, and runs on every calendar change once
//  attached.
//

import Combine
import Foundation

@MainActor
final class AwaitingNameStore: ObservableObject {
    static let shared = AwaitingNameStore()

    static let defaultsKey = "awaitingName.marks"
    /// How long an unnamed event keeps asking.
    static let lifetime: TimeInterval = 30 * 86_400

    struct Mark: Codable, Equatable {
        /// The event's title when marked: the wait ends when it changes.
        var title: String
        var markedAt: Date
    }

    @Published private(set) var marks: [UUID: Mark]

    private let defaults: UserDefaults
    var now: () -> Date
    private var subscription: AnyCancellable?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let data = defaults.data(forKey: Self.defaultsKey)
        marks = data.flatMap { try? JSONDecoder().decode([UUID: Mark].self, from: $0) } ?? [:]
    }

    /// The single test every surface uses: marked, not expired, and still
    /// titled as when marked.
    static func isAwaiting(_ event: Event, titles: [UUID: String]) -> Bool {
        titles[event.id] == event.title
    }

    /// The live marks as the timeline takes them: event id → marked title.
    var titles: [UUID: String] {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        var result: [UUID: String] = [:]
        for (id, mark) in marks where mark.markedAt > cutoff {
            result[id] = mark.title
        }
        return result
    }

    func isAwaiting(_ event: Event) -> Bool {
        Self.isAwaiting(event, titles: titles)
    }

    func mark(_ eventID: UUID, title: String) {
        var next = marks
        next[eventID] = Mark(title: title, markedAt: now())
        save(next)
    }

    func clear(_ eventID: UUID) {
        guard marks[eventID] != nil else { return }
        var next = marks
        next[eventID] = nil
        save(next)
    }

    /// The detail page's prompt answered: `name` is what was typed — the
    /// same text as the current title counts too, it was said on purpose —
    /// or nil to keep the current title. Either way the event stops waiting.
    func answer(_ eventID: UUID, name: String?, in store: EventStore) {
        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty, var event = store.findCalendarEvent(id: eventID), event.title != typed {
            event.title = typed
            store.updateCalendarEvent(event)
        }
        clear(eventID)
    }

    /// Drops every mark that no longer asks: expired, its event gone, or
    /// the event renamed since.
    func prune(events: (UUID) -> Event?) {
        let live = titles
        let next = marks.filter { id, mark in
            guard live[id] != nil, let event = events(id) else { return false }
            return event.title == mark.title
        }
        if next != marks { save(next) }
    }

    /// Prunes against `store` now and after each calendar change.
    func attach(to store: EventStore) {
        prune(events: { store.findCalendarEvent(id: $0) })
        subscription = store.$rawCalendarEvents
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store, !self.marks.isEmpty else { return }
                self.prune(events: { store.findCalendarEvent(id: $0) })
            }
    }

    private func save(_ next: [UUID: Mark]) {
        marks = next
        if next.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
