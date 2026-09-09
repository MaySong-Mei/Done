//
//  TodoSurfaceModel.swift
//  DoneMac
//
//  The todo-stack recipient. Membership is the shared Event.isStackTodo
//  predicate — the same single-source rule the iOS drawer uses. Dateless
//  events produce empty affectedDayKeys, so this surface's interest is
//  day-unscoped; it filters by changedIDs relevance instead.
//

import SwiftUI

struct TodoRowModel: Equatable, Identifiable {
    let id: UUID
    let title: String
    let deadline: Date?
}

@MainActor
@Observable
final class TodoSurfaceModel {
    private(set) var rows: [TodoRowModel] = []

    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let bill: MacWorkBill
    @ObservationIgnored private var storeToken: UUID?

    init(store: MacEventStore, bill: MacWorkBill) {
        self.store = store
        self.bill = bill
    }

    func activate() {
        if let storeToken { store.removeObserver(storeToken) }
        storeToken = store.addObserver(
            interest: StoreInterest(slots: [.calendarEvents], dayKeys: nil)
        ) { [weak self] delta in
            self?.consume(delta)
        }
        rebuild()
    }

    func deactivate() {
        if let storeToken { store.removeObserver(storeToken) }
        storeToken = nil
    }

    func addTodo(title: String, now: Date) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Data preservation: an empty title still lands as a record.
        let event = Event(id: UUID(), title: trimmed, timeRanges: [], kind: .todo)
        store.addCalendarEvent(event, now: now)
    }

    private func consume(_ delta: CommitDelta) {
        // Cheap relevance gate: a delta that touches no current row and
        // whose changed events are not stack todos can't change the list.
        let changedIsRelevant = delta.affectedDayKeys == nil
            || delta.changedIDs.contains { id in
                rows.contains { $0.id == id }
                    || store.calendarEvents.first { $0.id == id }?.isStackTodo == true
            }
        guard changedIsRelevant else { return }
        bill.bump(.todoSurfaceRebuilds)
        rebuild()
    }

    private func rebuild() {
        let next = store.calendarEvents
            .filter(\.isStackTodo)
            .map { TodoRowModel(id: $0.id, title: $0.title, deadline: $0.deadline) }
        guard next != rows else { return }
        rows = next
    }
}
