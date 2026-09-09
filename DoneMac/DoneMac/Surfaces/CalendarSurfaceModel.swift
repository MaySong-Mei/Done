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

    var windowKeys: [DayKey] {
        guard let start = anchorDay.startOfDay(calendar: calendar) else { return [anchorDay] }
        return (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
                .map { DayKey(date: $0, calendar: calendar) }
        }
    }

    // MARK: - Lifecycle

    func activate(now: Date) {
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

    private func registerInterest() {
        if let storeToken { store.removeObserver(storeToken) }
        storeToken = store.addObserver(
            interest: StoreInterest(slots: [.calendarEvents], dayKeys: Set(windowKeys))
        ) { [weak self] delta in
            self?.consume(delta)
        }
    }

    private func consume(_ delta: CommitDelta) {
        projection.apply(delta, events: store.calendarEvents)
        bill.bump(.surfaceRebuilds)
        rebuildFrame(now: frameNow ?? Date())
    }

    /// The now the frame was last built with — minute-bucket granularity,
    /// kept so a delta rebuild does not have to invent its own clock read.
    @ObservationIgnored private var frameNow: Date?

    private func updateNowLine(now: Date) {
        frameNow = now
        var updated = frame
        updated.nowLine = visibleNowLine(now: now)
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
