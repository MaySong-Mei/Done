//
//  AgentPendingDestructiveAction.swift
//  Done
//
//  gh#135 (durable slice): a destructive agent tool NEVER mutates the store
//  from the tool runner. It stages a typed pending action here; the chat UI
//  presents Confirm / Cancel; only an explicit confirmation — routed through
//  `AgentPendingActionRegistry.confirm`, the single agent-flow call site of
//  the store's delete methods — executes the mutation. Cancel, expiry and a
//  nonce mismatch all refuse without touching the store.
//

import Combine
import Foundation

/// One staged destructive request, carrying everything the confirmation card
/// needs to show the user exactly what would be destroyed.
struct AgentPendingDestructiveAction: Codable, Equatable, Identifiable {
    /// THE destructive predicate (gh#135) — the runner's staging gate
    /// derives from this init, and nothing else re-lists the destructive
    /// tools. The switch is exhaustive over `AgentTool`, so adding a tool
    /// case forces an explicit decision about which side of the gate it
    /// lives on.
    enum Kind: String, Codable {
        case deleteTodo
        case deleteCalendarEvent

        init?(tool: AgentTool) {
            switch tool {
            case .deleteTodo:
                self = .deleteTodo
            case .deleteCalendarEvent:
                self = .deleteCalendarEvent
            case .createTodo, .createCalendarEvent, .listTodos, .listCalendarEvents,
                 .updateTodo, .completeTodo, .getScheduleForDate, .getUserData:
                return nil
            }
        }
    }

    /// Short by design: a stale card must not stay armed indefinitely.
    static let defaultTimeToLive: TimeInterval = 5 * 60

    let nonce: UUID
    let kind: Kind
    let eventID: UUID
    let displayTitle: String
    /// The drawn frame, never the raw stored instant: calendar targets print
    /// `renderPrimaryTimeRange` (gh#187 family — the card must name the slot
    /// the canvas shows), todo targets print their deadline if any.
    let displayTime: String?
    /// Present when the target participates in a recurring series. A series
    /// TEMPLATE target must say the whole series dies with it.
    let recurrenceScopeNote: String?
    /// The target's shape AT STAGING (gh#135 round 2): consent was given to
    /// the card as rendered. `confirm` refuses when the live shape differs,
    /// so a plain-event card can never execute a whole-series delete the
    /// user was not shown (nor the reverse).
    let wasRecurringSeries: Bool
    let createdAt: Date
    let timeToLive: TimeInterval

    var id: UUID { nonce }

    init(
        kind: Kind,
        eventID: UUID,
        displayTitle: String,
        displayTime: String?,
        recurrenceScopeNote: String?,
        wasRecurringSeries: Bool,
        createdAt: Date = Date(),
        timeToLive: TimeInterval = AgentPendingDestructiveAction.defaultTimeToLive,
        nonce: UUID = UUID()
    ) {
        self.kind = kind
        self.eventID = eventID
        self.displayTitle = displayTitle
        self.displayTime = displayTime
        self.recurrenceScopeNote = recurrenceScopeNote
        self.wasRecurringSeries = wasRecurringSeries
        self.createdAt = createdAt
        self.timeToLive = timeToLive
        self.nonce = nonce
    }

    func isExpired(at instant: Date) -> Bool {
        instant.timeIntervalSince(createdAt) > timeToLive
    }
}

/// Holds at most one staged destructive action and owns the ONLY path from a
/// staged action to an actual store mutation. Invariant (gh#135): no other
/// agent-flow code — not the tool runner, not a chat view — may call the
/// store's delete methods directly; confirm buttons route here.
final class AgentPendingActionRegistry: ObservableObject {
    @Published private(set) var pending: AgentPendingDestructiveAction?

    /// Staging replaces any earlier pending action: one decision in front of
    /// the user at a time, and the replaced action's nonce can no longer
    /// confirm anything. Returns the action this staging replaced (nil when
    /// none was pending) so the runner's envelope can say the earlier
    /// request was voided — two destructive calls in one model turn must
    /// not both read as live stagings.
    @discardableResult
    func stage(_ action: AgentPendingDestructiveAction) -> AgentPendingDestructiveAction? {
        let replaced = pending
        pending = action
        return replaced
    }

    enum ConfirmationOutcome: Equatable {
        case deleted(title: String)
        case refused(reason: String)
    }

    /// Executes the staged deletion — the single agent-flow call site of the
    /// store's delete methods. Refuses (and never mutates) when nothing is
    /// pending, the nonce does not match, the action expired, or the target
    /// has already vanished.
    func confirm(
        nonce: UUID,
        store: EventStore,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ConfirmationOutcome {
        guard let action = pending else {
            return .refused(reason: "Nothing is awaiting confirmation.")
        }
        guard action.nonce == nonce else {
            return .refused(reason: "This confirmation no longer matches the staged deletion. Nothing was deleted.")
        }
        guard !action.isExpired(at: now) else {
            pending = nil
            return .refused(reason: "The staged deletion expired before it was confirmed. Nothing was deleted.")
        }
        pending = nil

        switch action.kind {
        case .deleteTodo:
            guard let event = store.events.first(where: { $0.id == action.eventID }) else {
                return .refused(reason: "That todo no longer exists. Nothing was deleted.")
            }
            store.delete(event)
            return .deleted(title: event.title)

        case .deleteCalendarEvent:
            guard let event = store.rawCalendarEvents.first(where: { $0.id == action.eventID }) else {
                return .refused(reason: "That calendar event no longer exists. Nothing was deleted.")
            }
            guard event.isRecurringSeries == action.wasRecurringSeries else {
                // The consent covered the card as rendered. A repeat rule
                // gained (or lost) inside the TTL changes WHAT would die —
                // refuse and make the user re-request against the new shape.
                return .refused(reason: "The event's repeat rule changed after the deletion was staged, so the card no longer describes what would be deleted. Nothing was deleted — request the deletion again.")
            }
            if event.isRecurringSeries {
                // Whole-series delete, matching the staged warning — the same
                // idiom as `CalendarEventSheets.deleteEvent`'s scope-less
                // fallback (drawn-frame occurrence seed, `.all` scope).
                store.deleteRecurringCalendarEvent(
                    seriesEvent: event,
                    occurrenceDate: event.renderPrimaryTimeRange(calendar: calendar)?.start ?? now,
                    scope: .all
                )
            } else {
                store.deleteCalendarEvent(event)
            }
            return .deleted(title: event.title)
        }
    }

    /// Discards the staged action without touching the store — returns the
    /// discarded action, or nil when the nonce names nothing current (a
    /// stale card must not discard a newer staged action).
    @discardableResult
    func cancel(nonce: UUID) -> AgentPendingDestructiveAction? {
        guard let action = pending, action.nonce == nonce else { return nil }
        pending = nil
        return action
    }
}
