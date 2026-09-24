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
import Combine

/// The phone's day/threeDay/week switcher, on Mac. Month is deliberately
/// out of this phase — it's a grid, not a timeline.
enum CalendarRangeMode: String, CaseIterable, Sendable {
    case day, threeDay, week

    var dayCount: Int {
        switch self {
        case .day: return 1
        case .threeDay: return 3
        case .week: return 7
        }
    }

    var label: String {
        switch self {
        case .day: return "Day"
        case .threeDay: return "3 Days"
        case .week: return "Week"
        }
    }
}

@MainActor
@Observable
final class CalendarSurfaceModel {
    private(set) var frame = CanvasFrame()
    private(set) var anchorDay: DayKey
    private(set) var dayCount: Int
    private(set) var rangeMode: CalendarRangeMode

    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let projection: CalendarProjection
    @ObservationIgnored private let clock: ClockHub
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let bill: MacWorkBill
    @ObservationIgnored private var storeToken: UUID?
    @ObservationIgnored private var clockToken: UUID?
    /// A type recolor/rename fires this; the surface drops the projection's
    /// color-baked cache and rebuilds (A2 review #1). Injectable so a test
    /// can drive it without touching the process-wide catalog.
    @ObservationIgnored private let catalogChanges: AnyPublisher<Void, Never>
    @ObservationIgnored private var catalogCancellable: AnyCancellable?

    init(
        store: MacEventStore,
        clock: ClockHub,
        calendar: Calendar,
        bill: MacWorkBill,
        anchor: Date,
        rangeMode: CalendarRangeMode = .week,
        catalogChanges: AnyPublisher<Void, Never> = EventTypeCatalog.shared.changes.eraseToAnyPublisher()
    ) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.bill = bill
        self.rangeMode = rangeMode
        self.dayCount = rangeMode.dayCount
        self.anchorDay = Self.anchor(for: rangeMode, containing: anchor, calendar: calendar)
        self.projection = CalendarProjection(calendar: calendar, bill: bill)
        self.catalogChanges = catalogChanges
    }

    /// Week mode snaps the anchor to the week's first day so columns line
    /// up Sun–Sat (or the locale's first weekday); day/3-day anchor on the
    /// day itself.
    private static func anchor(
        for mode: CalendarRangeMode, containing date: Date, calendar: Calendar
    ) -> DayKey {
        switch mode {
        case .day, .threeDay:
            return DayKey(date: date, calendar: calendar)
        case .week:
            let comps = calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: date
            )
            let start = calendar.date(from: comps) ?? calendar.startOfDay(for: date)
            return DayKey(date: start, calendar: calendar)
        }
    }

    /// Switch view mode, keeping the currently-anchored day visible.
    func setRangeMode(_ mode: CalendarRangeMode, now: Date) {
        guard mode != rangeMode else { return }
        let pivot = anchorDay.startOfDay(calendar: calendar) ?? now
        rangeMode = mode
        dayCount = mode.dayCount
        anchorDay = Self.anchor(for: mode, containing: pivot, calendar: calendar)
        registerInterest()
        rebuildFrame(now: frameNowOrNow(now))
    }

    private func frameNowOrNow(_ fallback: Date) -> Date {
        frameNow == .distantPast ? fallback : frameNow
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
        catalogCancellable = catalogChanges.sink { [weak self] in
            self?.handleCatalogChange()
        }
        rebuildFrame(now: now)
    }

    func deactivate() {
        if let storeToken { store.removeObserver(storeToken) }
        if let clockToken { clock.unregister(clockToken) }
        storeToken = nil
        clockToken = nil
        catalogCancellable = nil
    }

    /// A type's color/name changed: drop the color-baked day cache regardless
    /// of visibility (so a deferred re-appear rebuild also gets fresh colors),
    /// and rebuild now if visible — otherwise the visibility clause's
    /// needsRefresh handles it on re-appear.
    private func handleCatalogChange() {
        projection.invalidateColors()
        guard isVisible else { needsRefresh = true; return }
        bill.bump(.surfaceRebuilds)
        rebuildFrame(now: frameNowOrNow(Date()))
    }

    // MARK: - Visibility (the plan's third clause: delta ∩ interest ∧ visible)

    /// While hidden the surface only marks itself stale; one rebuild runs
    /// on re-appearance. Wired from NSWindow occlusion (Phase 6 — the
    /// round-2 review called the missing clause out as shipped debt).
    private(set) var isVisible = true
    @ObservationIgnored private var needsRefresh = false

    func setVisible(_ visible: Bool, now: Date) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible && needsRefresh {
            needsRefresh = false
            bill.bump(.surfaceRebuilds)
            rebuildFrame(now: now)
        }
    }

    // MARK: - Window navigation

    /// Page by a whole window (prev/next arrows in the toolbar).
    func stepWindow(_ direction: Int, now: Date) {
        shift(byDays: direction * dayCount, now: now)
    }

    /// Jump so today is in the window (week mode snaps to today's week).
    func goToToday(now: Date) {
        let target = Self.anchor(for: rangeMode, containing: now, calendar: calendar)
        guard target != anchorDay, let start = anchorDay.startOfDay(calendar: calendar),
              let targetStart = target.startOfDay(calendar: calendar) else { return }
        let days = calendar.dateComponents([.day], from: start, to: targetStart).day ?? 0
        shift(byDays: days, now: now)
    }

    /// Human-readable range for the toolbar title.
    var rangeTitle: String {
        let keys = windowKeys
        guard let first = keys.first?.startOfDay(calendar: calendar) else { return "" }
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = .current
        if rangeMode == .day {
            df.dateFormat = "EEEE, MMM d"
            return df.string(from: first)
        }
        guard let last = keys.last?.startOfDay(calendar: calendar) else { return "" }
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        df.dateFormat = "MMM d"
        let firstStr = df.string(from: first)
        df.dateFormat = sameMonth ? "d" : "MMM d"
        return "\(firstStr) – \(df.string(from: last))"
    }

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
        guard isVisible else {
            // The projection stayed current above; only the FRAME work is
            // deferred — one rebuild on re-appearance, however many deltas
            // arrived while hidden.
            needsRefresh = true
            return
        }
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
