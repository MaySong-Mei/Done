//
//  CalendarSurfaceModel.swift
//  DoneMac
//
//  The calendar's observation recipient (#219 concept 1). Views read ONE
//  chunky value property (`frame`); what invalidates it is decided by the
//  delta-∩-interest code below, never by SwiftUI dependency guesswork.
//  The store stays invisible to views.
//

import SwiftUI

@MainActor
@Observable
final class CalendarSurfaceModel {
    private(set) var frame = CanvasFrame()
    private(set) var anchorDay: DayKey
    private(set) var dayCount: Int

    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let projection: CalendarProjection
    @ObservationIgnored private let clock: ClockHub
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let bill: MacWorkBill
    @ObservationIgnored private var storeToken: UUID?
    @ObservationIgnored private var clockToken: UUID?

    init(
        store: MacEventStore,
        clock: ClockHub,
        calendar: Calendar,
        bill: MacWorkBill,
        anchor: Date,
        dayCount: Int = 7
    ) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.bill = bill
        self.dayCount = max(1, dayCount)
        self.anchorDay = DayKey(date: anchor, calendar: calendar)
        self.projection = CalendarProjection(calendar: calendar, bill: bill)
    }

    /// Narrow seam for gesture hit-tests, which need the Event value to
    /// hand the DragController. Views must not use this for rendering —
    /// rendering reads `frame` only.
    var storeForGestures: MacEventStore { store }

    var windowKeys: [DayKey] {
        guard let start = anchorDay.startOfDay(calendar: calendar) else { return [anchorDay] }
        return (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
                .map { DayKey(date: $0, calendar: calendar) }
        }
    }

    // MARK: - Lifecycle

    func activate(now: Date) {
        // Idempotent: a second activate (window re-creation re-runs .task)
        // must not leak a clock registration (QA3 finding F3).
        if let clockToken { clock.unregister(clockToken) }
        frameNow = now
        projection.rebuildIndex(from: store.calendarEvents)
        registerInterest()
        clockToken = clock.register(.minute) { [weak self] tickNow in
            self?.updateNowLine(now: tickNow)
        }
        rebuildFrame(now: now)
    }

    func deactivate() {
        if let storeToken { store.removeObserver(storeToken) }
        if let clockToken { clock.unregister(clockToken) }
        storeToken = nil
        clockToken = nil
    }

    // MARK: - Window navigation

    func shift(byDays days: Int, now: Date) {
        guard days != 0, let start = anchorDay.startOfDay(calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: start) else { return }
        anchorDay = DayKey(date: moved, calendar: calendar)
        registerInterest()
        rebuildFrame(now: now)
    }

    // MARK: - Delta intake

    /// The projection hears EVERY calendarEvents delta — an interest-scoped
    /// intake starves the index for out-of-window commits and the event
    /// becomes permanently invisible on scroll (round-2 blocker, review #1
    /// / QA3 F1). Only the FRAME rebuild is window-gated.
    private func registerInterest() {
        if let storeToken { store.removeObserver(storeToken) }
        storeToken = store.addObserver(
            interest: StoreInterest(slots: [.calendarEvents], dayKeys: nil)
        ) { [weak self] delta in
            self?.consume(delta)
        }
    }

    private func consume(_ delta: CommitDelta) {
        projection.apply(delta, events: store.calendarEvents)
        let touchesWindow = delta.affectedDayKeys.map { !$0.isDisjoint(with: Set(windowKeys)) } ?? true
        guard touchesWindow else { return }
        bill.bump(.surfaceRebuilds)
        rebuildFrame(now: frameNow)
    }

    /// The now the frame was last built with — minute-bucket granularity,
    /// seeded in activate() so no derivation path ever invents its own
    /// wall-clock read (review round-2 finding 7).
    @ObservationIgnored private var frameNow = Date.distantPast

    private func updateNowLine(now: Date) {
        frameNow = now
        let line = visibleNowLine(now: now)
        guard line != frame.nowLine else { return }
        var updated = frame
        updated.nowLine = line
        frame = updated
        bill.bump(.overlayBuilds)
    }

    private func rebuildFrame(now: Date) {
        frameNow = now
        frame = CanvasFrame(
            days: projection.dayModels(for: windowKeys, events: store.calendarEvents),
            nowLine: visibleNowLine(now: now)
        )
    }

    private func visibleNowLine(now: Date) -> NowLineModel? {
        let line = projection.nowLine(now: now)
        return windowKeys.contains(line.dayKey) ? line : nil
    }
}
