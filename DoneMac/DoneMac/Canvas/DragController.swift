//
//  DragController.swift
//  DoneMac
//
//  Live drag/resize/create for the canvas. During a gesture ONLY the
//  overlay value changes — truth, projection and day caches are untouched
//  (budget assertion 4: zero commits mid-drag, exactly one commit at
//  drop). Drop writes are seeded from renderTimeRanges, never raw stored
//  instants (the Event.swift write-side rule), and all ranges shift
//  uniformly — the same contract domino and the iOS move drag follow.
//
//  Snapping: 15-minute grid via the shared calendarPreviewOffsetSeconds,
//  which refuses a snap that would cross a day boundary the finger didn't.
//

import SwiftUI

@MainActor
@Observable
final class DragController {
    struct Overlay: Equatable {
        var dayKey: DayKey
        var yFraction: CGFloat
        var heightFraction: CGFloat
        var title: String
        var isCreate: Bool
    }

    private enum Session {
        case move(event: Event, seedRanges: [Event.TimeRange], grabFraction: CGFloat)
        case resizeBottom(event: Event, seedRanges: [Event.TimeRange])
        case create(anchorDay: DayKey, anchorFraction: CGFloat)
    }

    private(set) var overlay: Overlay?
    private var session: Session?
    private let store: MacEventStore
    private let calendar: Calendar
    static let snapSeconds: TimeInterval = 15 * 60
    static let minimumEventSeconds: TimeInterval = 15 * 60

    /// Set when a drop just created an event the UI should open for
    /// naming (data-preservation rule: the record exists BEFORE the
    /// composer asks anything).
    var pendingComposerEventID: UUID?

    init(store: MacEventStore, calendar: Calendar) {
        self.store = store
        self.calendar = calendar
    }

    var isDragging: Bool { session != nil }

    // MARK: - Move

    /// grabFraction: where inside the block (0..1 of the day) the pointer
    /// grabbed, so the block doesn't jump to the pointer.
    func beginMove(event: Event, grabFraction: CGFloat) {
        let seeds = event.renderTimeRanges(calendar: calendar)
        guard let first = seeds.first else { return }
        session = .move(event: event, seedRanges: seeds, grabFraction: grabFraction)
        overlay = overlayFor(range: first, title: event.title, isCreate: false)
    }

    func updateMove(pointerDay: DayKey, pointerFraction: CGFloat) {
        guard case .move(let event, let seeds, let grab) = session,
              let first = seeds.first else { return }
        let offset = moveOffsetSeconds(
            first: first, pointerDay: pointerDay,
            pointerFraction: pointerFraction, grabFraction: grab
        )
        let previewStart = first.start.addingTimeInterval(offset)
        let previewRange = Event.TimeRange(
            start: previewStart,
            end: previewStart.addingTimeInterval(first.end.timeIntervalSince(first.start))
        )
        overlay = overlayFor(range: previewRange, title: event.title, isCreate: false)
    }

    func endMove(pointerDay: DayKey, pointerFraction: CGFloat, now: Date) {
        guard case .move(let event, let seeds, let grab) = session,
              let first = seeds.first else { clear(); return }
        let offset = moveOffsetSeconds(
            first: first, pointerDay: pointerDay,
            pointerFraction: pointerFraction, grabFraction: grab
        )
        clear()
        guard offset != 0 else { return }
        var updated = event
        // Seeded + uniform shift across every range.
        updated.timeRanges = seeds.map { range in
            Event.TimeRange(
                start: range.start.addingTimeInterval(offset),
                end: range.end.addingTimeInterval(offset)
            )
        }
        store.replaceCalendarEvent(updated, now: now)
    }

    private func moveOffsetSeconds(
        first: Event.TimeRange,
        pointerDay: DayKey,
        pointerFraction: CGFloat,
        grabFraction: CGFloat
    ) -> TimeInterval {
        guard let pointerDayStart = pointerDay.startOfDay(calendar: calendar) else { return 0 }
        let targetStart = pointerDayStart
            .addingTimeInterval(TimeInterval(max(0, pointerFraction - grabFraction)) * 86_400)
        let raw = targetStart.timeIntervalSince(first.start)
        return calendarPreviewOffsetSeconds(
            rawOffsetSeconds: raw,
            range: first,
            snapIntervalSeconds: Self.snapSeconds,
            calendar: calendar
        )
    }

    // MARK: - Resize (bottom edge)

    func beginResizeBottom(event: Event) {
        let seeds = event.renderTimeRanges(calendar: calendar)
        guard let first = seeds.first else { return }
        session = .resizeBottom(event: event, seedRanges: seeds)
        overlay = overlayFor(range: first, title: event.title, isCreate: false)
    }

    func updateResizeBottom(pointerFraction: CGFloat) {
        guard case .resizeBottom(let event, let seeds) = session,
              let first = seeds.first else { return }
        overlay = overlayFor(
            range: resizedRange(first: first, pointerFraction: pointerFraction),
            title: event.title, isCreate: false
        )
    }

    func endResizeBottom(pointerFraction: CGFloat, now: Date) {
        guard case .resizeBottom(let event, let seeds) = session,
              let first = seeds.first else { clear(); return }
        let resized = resizedRange(first: first, pointerFraction: pointerFraction)
        clear()
        guard resized != first else { return }
        var updated = event
        var ranges = seeds
        ranges[0] = resized
        updated.timeRanges = ranges
        store.replaceCalendarEvent(updated, now: now)
    }

    private func resizedRange(first: Event.TimeRange, pointerFraction: CGFloat) -> Event.TimeRange {
        let dayStart = calendar.startOfDay(for: first.start)
        let rawEnd = dayStart.addingTimeInterval(TimeInterval(pointerFraction) * 86_400)
        let snapped = snapToGrid(rawEnd)
        let minimumEnd = first.start.addingTimeInterval(Self.minimumEventSeconds)
        return Event.TimeRange(start: first.start, end: max(snapped, minimumEnd))
    }

    // MARK: - Drag-create

    func beginCreate(day: DayKey, fraction: CGFloat) {
        session = .create(anchorDay: day, anchorFraction: fraction)
        updateCreate(pointerFraction: fraction)
    }

    func updateCreate(pointerFraction: CGFloat) {
        guard case .create(let day, let anchor) = session,
              let range = createRange(day: day, anchor: anchor, pointer: pointerFraction) else { return }
        overlay = overlayFor(range: range, title: "New event", isCreate: true)
    }

    func endCreate(pointerFraction: CGFloat, now: Date) {
        guard case .create(let day, let anchor) = session,
              let range = createRange(day: day, anchor: anchor, pointer: pointerFraction) else {
            clear(); return
        }
        clear()
        // Data preservation: the record lands FIRST, with a placeholder
        // title; the composer opens on it and may refine, never gatekeep.
        let event = Event(
            id: UUID(), title: "",
            timeRanges: [range],
            kind: .event
        )
        store.addCalendarEvent(event, now: now)
        pendingComposerEventID = event.id
    }

    private func createRange(day: DayKey, anchor: CGFloat, pointer: CGFloat) -> Event.TimeRange? {
        guard let dayStart = day.startOfDay(calendar: calendar) else { return nil }
        let a = snapToGrid(dayStart.addingTimeInterval(TimeInterval(min(anchor, pointer)) * 86_400))
        let b = snapToGrid(dayStart.addingTimeInterval(TimeInterval(max(anchor, pointer)) * 86_400))
        let end = max(b, a.addingTimeInterval(Self.minimumEventSeconds))
        return Event.TimeRange(start: a, end: end)
    }

    // MARK: - Shared bits

    func cancel() {
        clear()
    }

    private func clear() {
        session = nil
        overlay = nil
    }

    private func snapToGrid(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / Self.snapSeconds).rounded() * Self.snapSeconds)
    }

    private func overlayFor(range: Event.TimeRange, title: String, isCreate: Bool) -> Overlay {
        let key = DayKey(date: range.start, calendar: calendar)
        let dayStart = key.startOfDay(calendar: calendar) ?? calendar.startOfDay(for: range.start)
        return Overlay(
            dayKey: key,
            yFraction: calendarTimelineYFraction(for: range.start, containing: dayStart, calendar: calendar),
            heightFraction: calendarTimelineDurationFraction(seconds: range.end.timeIntervalSince(range.start)),
            title: title,
            isCreate: isCreate
        )
    }
}
