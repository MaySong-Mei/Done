//
//  DragController.swift
//  DoneMac
//
//  Live drag/resize/create for the canvas. During a gesture ONLY the
//  overlay value changes — truth, projection and day caches are untouched
//  (budget assertion 4: zero commits mid-drag, exactly one commit at
//  a move/resize drop; a create drop commits nothing — the form does). Round-4 contracts (QA/review round 3):
//  - The GRABBED range anchors offset/preview/resize — never seeds.first
//    (review F1: a second-range grab must not re-anchor the whole event).
//  - A drop re-reads the row by id and mutates ONLY timeRanges, shifting
//    the FRESH renderTimeRanges seeds — a commit landing mid-drag (domino,
//    sync) is never clobbered (review F3), and the write-side seeding rule
//    holds at write time, not gesture-begin time.
//  - An end* for a different session type is a NO-OP, never a clear —
//    the view layer fans one release into all three enders (QA F1).
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
        /// The previewed range — a create draft's, for the time row and the
        /// live overlap reflow.
        var range: Event.TimeRange
    }

    private enum Session {
        case move(eventID: UUID, grabbedIndex: Int, grabbed: Event.TimeRange,
                  title: String, grabFraction: CGFloat)
        case resizeBottom(eventID: UUID, grabbedIndex: Int, grabbed: Event.TimeRange,
                          title: String)
        case resizeTop(eventID: UUID, grabbedIndex: Int, grabbed: Event.TimeRange,
                       title: String)
        case create(anchorDay: DayKey, anchorFraction: CGFloat)
    }

    private(set) var overlay: Overlay?
    private var session: Session?
    private let store: MacEventStore
    private let calendar: Calendar
    static let snapSeconds: TimeInterval = 15 * 60
    static let minimumEventSeconds: TimeInterval = 15 * 60

    /// The range a drag-create released on, waiting for the create form —
    /// the phone's `pendingCreateTimeRange`. Nothing is written until the
    /// form's Done; the overlay stays up as the phone's form-open ghost
    /// until `finishPendingCreate()`. A form session that ends any other
    /// way leaves its content in the shared create-draft slot.
    private(set) var pendingCreate: Event.TimeRange?

    /// Whether the last drop actually COMMITTED a change — so the canvas fires
    /// the drop haptic only on a real edit, not on a drop-in-place or an
    /// empty-space drag that created nothing (code-review F7). Reset by
    /// `clear()` at each drop, set by each end* that writes.
    private(set) var didCommitLastDrop = false

    init(store: MacEventStore, calendar: Calendar) {
        self.store = store
        self.calendar = calendar
    }

    var isDragging: Bool { session != nil }

    /// The create form closed (saved or not): drop the ghost.
    func finishPendingCreate() {
        pendingCreate = nil
        if session == nil { overlay = nil }
    }

    // MARK: - Move

    /// `grabbedRange` is the occurrence range whose block the pointer hit;
    /// `grabFraction` is where inside the day the pointer sat relative to
    /// the block top, so the block doesn't jump to the pointer.
    func beginMove(event: Event, grabbedRange: Event.TimeRange, grabFraction: CGFloat) {
        let seeds = event.renderTimeRanges(calendar: calendar)
        guard !seeds.isEmpty else { return }
        let index = seeds.firstIndex(of: grabbedRange) ?? 0
        session = .move(eventID: event.id, grabbedIndex: index, grabbed: seeds[index],
                        title: event.title, grabFraction: grabFraction)
        overlay = overlayFor(range: seeds[index], title: event.title, isCreate: false)
    }

    func updateMove(pointerDay: DayKey, pointerFraction: CGFloat) {
        guard case .move(_, _, let grabbed, let title, let grab) = session else { return }
        let offset = moveOffsetSeconds(
            grabbed: grabbed, pointerDay: pointerDay,
            pointerFraction: pointerFraction, grabFraction: grab
        )
        let previewStart = grabbed.start.addingTimeInterval(offset)
        let previewRange = Event.TimeRange(
            start: previewStart,
            end: previewStart.addingTimeInterval(grabbed.end.timeIntervalSince(grabbed.start))
        )
        overlay = overlayFor(range: previewRange, title: title, isCreate: false)
    }

    func endMove(pointerDay: DayKey, pointerFraction: CGFloat, now: Date) {
        guard case .move(let eventID, let index, let grabbed, _, let grab) = session else { return }
        let offset = moveOffsetSeconds(
            grabbed: grabbed, pointerDay: pointerDay,
            pointerFraction: pointerFraction, grabFraction: grab
        )
        clear()
        guard offset != 0 else { return }
        // Fresh row, fresh seeds: land the grabbed range at the pointer's
        // intent even if the row moved underneath during the gesture.
        guard var updated = store.calendarEvents.first(where: { $0.id == eventID }) else { return }
        let freshSeeds = updated.renderTimeRanges(calendar: calendar)
        guard !freshSeeds.isEmpty else { return }
        let anchorIndex = min(index, freshSeeds.count - 1)
        let target = grabbed.start.addingTimeInterval(offset)
        let freshOffset = target.timeIntervalSince(freshSeeds[anchorIndex].start)
        guard freshOffset != 0 else { return }
        updated.timeRanges = freshSeeds.map { range in
            Event.TimeRange(
                start: range.start.addingTimeInterval(freshOffset),
                end: range.end.addingTimeInterval(freshOffset)
            )
        }
        didCommitLastDrop = true
        store.replaceCalendarEvent(updated, now: now)
    }

    private func moveOffsetSeconds(
        grabbed: Event.TimeRange,
        pointerDay: DayKey,
        pointerFraction: CGFloat,
        grabFraction: CGFloat
    ) -> TimeInterval {
        guard let pointerDayStart = pointerDay.startOfDay(calendar: calendar) else { return 0 }
        let targetStart = pointerDayStart
            .addingTimeInterval(TimeInterval(max(0, pointerFraction - grabFraction)) * 86_400)
        let raw = targetStart.timeIntervalSince(grabbed.start)
        return calendarPreviewOffsetSeconds(
            rawOffsetSeconds: raw,
            range: grabbed,
            snapIntervalSeconds: Self.snapSeconds,
            calendar: calendar
        )
    }

    // MARK: - Resize (bottom edge)

    func beginResizeBottom(event: Event, grabbedRange: Event.TimeRange) {
        let seeds = event.renderTimeRanges(calendar: calendar)
        guard !seeds.isEmpty else { return }
        let index = seeds.firstIndex(of: grabbedRange) ?? 0
        session = .resizeBottom(eventID: event.id, grabbedIndex: index,
                                grabbed: seeds[index], title: event.title)
        overlay = overlayFor(range: seeds[index], title: event.title, isCreate: false)
    }

    func updateResizeBottom(pointerDay: DayKey, pointerFraction: CGFloat) {
        guard case .resizeBottom(_, _, let grabbed, let title) = session else { return }
        overlay = overlayFor(
            range: resizedRange(grabbed: grabbed, pointerDay: pointerDay, pointerFraction: pointerFraction),
            title: title, isCreate: false
        )
    }

    func endResizeBottom(pointerDay: DayKey, pointerFraction: CGFloat, now: Date) {
        guard case .resizeBottom(let eventID, let index, let grabbed, _) = session else { return }
        let resized = resizedRange(grabbed: grabbed, pointerDay: pointerDay, pointerFraction: pointerFraction)
        clear()
        guard resized != grabbed else { return }
        guard var updated = store.calendarEvents.first(where: { $0.id == eventID }) else { return }
        var freshSeeds = updated.renderTimeRanges(calendar: calendar)
        guard !freshSeeds.isEmpty else { return }
        let anchorIndex = min(index, freshSeeds.count - 1)
        freshSeeds[anchorIndex] = Event.TimeRange(
            start: freshSeeds[anchorIndex].start,
            end: max(resized.end, freshSeeds[anchorIndex].start.addingTimeInterval(Self.minimumEventSeconds))
        )
        updated.timeRanges = freshSeeds
        didCommitLastDrop = true
        store.replaceCalendarEvent(updated, now: now)
    }

    /// The pointer's DAY anchors the end instant (review F12: a straddling
    /// range gripped on its second day must resolve fractions in THAT
    /// day's frame, or a 5-hour event collapses to the minimum).
    private func resizedRange(
        grabbed: Event.TimeRange, pointerDay: DayKey, pointerFraction: CGFloat
    ) -> Event.TimeRange {
        let dayStart = pointerDay.startOfDay(calendar: calendar)
            ?? calendar.startOfDay(for: grabbed.start)
        let rawEnd = dayStart.addingTimeInterval(TimeInterval(pointerFraction) * 86_400)
        let snapped = snapToGrid(rawEnd)
        let minimumEnd = grabbed.start.addingTimeInterval(Self.minimumEventSeconds)
        return Event.TimeRange(start: grabbed.start, end: max(snapped, minimumEnd))
    }

    // MARK: - Resize (top edge — moves the START, keeps the END)

    func beginResizeTop(event: Event, grabbedRange: Event.TimeRange) {
        let seeds = event.renderTimeRanges(calendar: calendar)
        guard !seeds.isEmpty else { return }
        let index = seeds.firstIndex(of: grabbedRange) ?? 0
        session = .resizeTop(eventID: event.id, grabbedIndex: index,
                             grabbed: seeds[index], title: event.title)
        overlay = overlayFor(range: seeds[index], title: event.title, isCreate: false)
    }

    func updateResizeTop(pointerDay: DayKey, pointerFraction: CGFloat) {
        guard case .resizeTop(_, _, let grabbed, let title) = session else { return }
        overlay = overlayFor(
            range: resizedRangeTop(grabbed: grabbed, pointerDay: pointerDay, pointerFraction: pointerFraction),
            title: title, isCreate: false
        )
    }

    func endResizeTop(pointerDay: DayKey, pointerFraction: CGFloat, now: Date) {
        guard case .resizeTop(let eventID, let index, let grabbed, _) = session else { return }
        let resized = resizedRangeTop(grabbed: grabbed, pointerDay: pointerDay, pointerFraction: pointerFraction)
        clear()
        guard resized != grabbed else { return }
        guard var updated = store.calendarEvents.first(where: { $0.id == eventID }) else { return }
        var freshSeeds = updated.renderTimeRanges(calendar: calendar)
        guard !freshSeeds.isEmpty else { return }
        let anchorIndex = min(index, freshSeeds.count - 1)
        // Fresh row's END is authoritative (the row may have moved under a
        // sync/domino write); clamp the new start so the event never inverts
        // or drops below the 15-min floor.
        let freshEnd = freshSeeds[anchorIndex].end
        freshSeeds[anchorIndex] = Event.TimeRange(
            start: min(resized.start, freshEnd.addingTimeInterval(-Self.minimumEventSeconds)),
            end: freshEnd
        )
        updated.timeRanges = freshSeeds
        didCommitLastDrop = true
        store.replaceCalendarEvent(updated, now: now)
    }

    /// Top-edge twin of `resizedRange`: the pointer's DAY anchors the new
    /// START; the END stays put, and the start is clamped so the event keeps
    /// at least the 15-min minimum (never inverts).
    private func resizedRangeTop(
        grabbed: Event.TimeRange, pointerDay: DayKey, pointerFraction: CGFloat
    ) -> Event.TimeRange {
        let dayStart = pointerDay.startOfDay(calendar: calendar)
            ?? calendar.startOfDay(for: grabbed.start)
        let rawStart = dayStart.addingTimeInterval(TimeInterval(pointerFraction) * 86_400)
        let snapped = snapToGrid(rawStart)
        let maximumStart = grabbed.end.addingTimeInterval(-Self.minimumEventSeconds)
        return Event.TimeRange(start: min(snapped, maximumStart), end: grabbed.end)
    }

    // MARK: - Drag-create

    func beginCreate(day: DayKey, fraction: CGFloat) {
        session = .create(anchorDay: day, anchorFraction: fraction)
        updateCreate(pointerFraction: fraction)
    }

    func updateCreate(pointerFraction: CGFloat) {
        guard case .create(let day, let anchor) = session,
              let range = createRange(day: day, anchor: anchor, pointer: pointerFraction) else { return }
        overlay = overlayFor(range: range, title: L(.newEvent), isCreate: true)
    }

    func endCreate(pointerFraction: CGFloat, now: Date) {
        guard case .create(let day, let anchor) = session else { return }
        let range = createRange(day: day, anchor: anchor, pointer: pointerFraction)
        clear()
        guard let range else { return }
        // The phone's flow: the release opens the create form on this range
        // and the draft stays drawn under it; the form's Done adds the event.
        overlay = overlayFor(range: range, title: L(.newEvent), isCreate: true)
        pendingCreate = range
        // The drop haptic marks the release that opens the form.
        didCommitLastDrop = true
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
        didCommitLastDrop = false
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
            isCreate: isCreate,
            range: range
        )
    }
}
