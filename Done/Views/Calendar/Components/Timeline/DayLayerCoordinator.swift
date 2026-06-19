//
//  DayLayerCoordinator.swift
//  Done
//
//  Spec 07 §4a / §5 row S3 — `docs/calayer-rewrite/07-day-layer-imperative.md`.
//
//  Scaffolding for the imperative day-layer coordinator: a UIKit class that
//  will OWN the `DayLayerHostView` subtree directly (no `UIViewRepresentable`
//  wrapper) once S5 cuts the SwiftUI representable cord. Its setters are the
//  channel-by-channel migration target for S4 — every state field currently
//  fed into the day layer via the `CalendarDayLayerView(...)` struct (focus,
//  grace, recentlyAbsorbed, creationPreviewRange, pinchHourHeight, drag
//  mirror, settings, mode, horizon — 11 channels per spec §5 row S4) gets a
//  dedicated coordinator setter the page view writes to from an `.onChange`.
//
//  S3 deliverables: constructible + unit-testable, NO view-tree wiring.
//  `CalendarPageView` does NOT yet construct one — that's S5. Until then the
//  SwiftUI representable (`CalendarDayLayerView`) remains the single source
//  of truth for the day layer's Model; this coordinator's setters cache
//  state for later but do not push to a real host. Tests can exercise the
//  cached state to lock in the channel contract before S4 migration.
//
//  Note: a `DayLayerCoordinator` is per-pager-page, not per-day-column. The
//  multi-day modes (3-day / week) keep using `CalendarDayLayerView` as a
//  per-column representable; the coordinator only engages in single-day
//  mode when `calendarUseImperativeDayLayer == true && rangeMode == .day`.
//

import UIKit

@MainActor
final class DayLayerCoordinator: NSObject {

    // MARK: Topology

    private let container: UIView
    private let scrollView: UIScrollView
    /// `EventDragState` is `@Observable` — held weakly so the coordinator
    /// doesn't extend its lifetime past the page that owns it.
    private weak var dragState: EventDragState?

    weak var delegate: DayLayerCoordinatorDelegate?

    /// dayOffsets the coordinator has been told to host. S5 attaches the
    /// actual subviews; S3 just records the topology so unit tests can
    /// verify add/remove sequencing.
    private(set) var hostDayOffsets: Set<Int> = []

    // MARK: Cached broadcast state
    //
    // Each setter writes to one of these. S4 migrations replace the existing
    // SwiftUI struct field with an `.onChange` that routes through here, and
    // then this coordinator pushes the value into the host's Model (S5). For
    // now the writes are inert — the cache exists so tests can assert the
    // channel contract end-to-end without a host attached.

    private(set) var mode: RangeMode = .day
    private(set) var hourHeight: CGFloat = 0
    private(set) var isPinchActive: Bool = false
    private(set) var frozenSlotMinutes: Int? = nil
    private(set) var headerHeight: CGFloat = 0
    private(set) var eventHorizontalInset: CGFloat = 0
    private(set) var titleFontSize: Double = 14
    private(set) var showTimeBelowTitle: Bool = true
    private(set) var multiTypeEnabled: Bool = false
    private(set) var horizonDays: Int = 0
    private(set) var showEventText: Bool = true
    private(set) var dragPreviewDayStep: CGFloat = 0
    private(set) var focusedEventID: UUID? = nil
    private(set) var focusedOccurrenceID: String? = nil
    private(set) var graceResizeEventID: UUID? = nil
    private(set) var graceResizeOccurrenceID: String? = nil
    private(set) var graceResizeHandleOpacity: Double = 1
    private(set) var recentlyAbsorbedEventIDs: Set<UUID> = []
    private(set) var contentWidthByDayOffset: [Int: CGFloat] = [:]
    private(set) var creationPreviewRangeByDayOffset: [Int: Event.TimeRange] = [:]
    private(set) var occurrencesByDayOffset: [Int: [CalendarLayout.EventOccurrence]] = [:]

    /// Spec 07 §2A: the 48h substrate's only band channel is `contentInset`.
    /// `setBandLeadingOpen` / `setBandTrailingOpen` flip the per-side
    /// `contentInset.top` / `.bottom` via `TimelineScrollProxy` in S5; S3
    /// just tracks the state.
    private(set) var bandLeadingOpen: Bool = false
    private(set) var bandTrailingOpen: Bool = false

    // MARK: Host attachment + cached Model (S5.2)
    //
    // The coordinator OWNS a single `DayLayerHostView` instance in single-day
    // mode (3-day/week stays on the SwiftUI representable for now). The host
    // is created by `addHost(...)` in S5.3 and apply-pushed every time a
    // coordinator setter mutates the cached Model. Until then both slots
    // are nil and every setter is push-inert — only the `private(set) var`
    // cache above is updated, identical to S3/S4 behavior.
    //
    // Why a CACHED Model rather than rebuilding on each push: per spec §4b
    // point 2, hot-path callers (`setHourHeight` during pinch, drag mirror)
    // MUST update the cached Model FIRST then call `host.repaintVertical(_:)`
    // — never push a stale Model on a later slow-path apply. The cached
    // Model is the source of truth.

    /// Active host for `dayOffset == 0` (single-day). Multi-host topologies
    /// (3-day / week) will key by dayOffset in a later slice.
    private var dayHost: DayLayerHostView?

    /// Latest Model snapshot pushed to (or about to be pushed to) the host.
    /// `nil` until `addHost(...)` constructs the host. After that, every
    /// setter mutates the corresponding field here and re-`apply`s.
    private var cachedModel: DayLayerHostView.Model?

    /// Callbacks the coordinator forwards to the host on each push. Wired in
    /// S5.3 from the page view (delegate-style); for now an empty struct so
    /// the apply signature compiles. Output edges go through `delegate`.
    private var hostCallbacks = DayLayerHostView.Callbacks()

    // MARK: Lifecycle

    init(container: UIView, scrollView: UIScrollView, dragState: EventDragState) {
        self.container = container
        self.scrollView = scrollView
        self.dragState = dragState
        super.init()
        hostCallbacks.dragState = dragState
    }

    // MARK: Topology setters (S5 wires)

    func addHost(dayOffset: Int, date: Date, frame: CGRect) {
        // S5: construct a DayLayerHostView, addSubview to `container`, apply
        // a Model snapshot constructed from the cached state above.
        hostDayOffsets.insert(dayOffset)
        _ = (date, frame)
    }

    func removeHost(dayOffset: Int) {
        // S5: removeFromSuperview + drop any per-host cache entries.
        hostDayOffsets.remove(dayOffset)
        contentWidthByDayOffset.removeValue(forKey: dayOffset)
        creationPreviewRangeByDayOffset.removeValue(forKey: dayOffset)
        occurrencesByDayOffset.removeValue(forKey: dayOffset)
    }

    func setMode(_ mode: RangeMode) {
        self.mode = mode
        updateModel { m in
            m.isWeekMode = (mode == .week)
            m.isThreeDayMode = (mode == .threeDay)
        }
    }

    func setContentWidth(_ width: CGFloat, for dayOffset: Int) {
        contentWidthByDayOffset[dayOffset] = width
        guard dayOffset == 0 else { return }
        updateModel { $0.contentWidth = width }
    }

    func setDragPreviewDayStep(_ step: CGFloat) {
        dragPreviewDayStep = step
        updateModel { $0.dragPreviewDayStep = step }
    }

    // MARK: Band-inset writes — the 48h model's only band channel

    func setBandLeadingOpen(_ open: Bool) {
        bandLeadingOpen = open
    }

    func setBandTrailingOpen(_ open: Bool) {
        bandTrailingOpen = open
    }

    // MARK: Hot-path sync writes (60-120 Hz during pinch)

    /// Pinch hot path. Spec §4b point 2: cached `Model` MUST be updated FIRST
    /// then the host's fast `repaintVertical(_:)` path may run — never the
    /// reverse, or a later non-hot-path `apply` reads a stale `Model` and
    /// reverts the geometry the fast path painted. The `apply(_:callbacks:)`
    /// call below is the slow path; `repaintVertical` is reached transitively
    /// through `layoutSubviews` when the StructureKey is unchanged (the
    /// pinch case), so the same call covers both.
    func setHourHeight(_ height: CGFloat) {
        hourHeight = height
        updateModel { $0.hourHeight = height }
    }

    func setPinchActive(_ active: Bool) {
        isPinchActive = active
        updateModel { $0.isPinchActive = active }
    }

    func setFrozenSlotMinutes(_ minutes: Int?) {
        frozenSlotMinutes = minutes
        updateModel { $0.frozenSlotMinutes = minutes }
    }

    // MARK: Focus / grace / drag / absorb broadcasts

    func setFocus(eventID: UUID?, occurrenceID: String?) {
        focusedEventID = eventID
        focusedOccurrenceID = occurrenceID
        updateModel { m in
            m.focusedEventID = eventID
            m.focusedOccurrenceID = occurrenceID
            m.isFocusContextActive = (eventID != nil)
        }
    }

    func setGraceResize(eventID: UUID?, occurrenceID: String?, opacity: Double) {
        graceResizeEventID = eventID
        graceResizeOccurrenceID = occurrenceID
        graceResizeHandleOpacity = opacity
        updateModel { m in
            m.graceResizeEventID = eventID
            m.graceResizeOccurrenceID = occurrenceID
            m.graceResizeHandleOpacity = opacity
        }
    }

    func setRecentlyAbsorbedEventIDs(_ ids: Set<UUID>) {
        recentlyAbsorbedEventIDs = ids
        updateModel { $0.recentlyAbsorbedEventIDs = ids }
    }

    func setCreationPreviewRange(_ range: Event.TimeRange?, for dayOffset: Int) {
        if let range {
            creationPreviewRangeByDayOffset[dayOffset] = range
        } else {
            creationPreviewRangeByDayOffset.removeValue(forKey: dayOffset)
        }
        guard dayOffset == 0 else { return }
        updateModel { $0.creationPreviewRange = range }
    }

    func setOccurrences(_ occs: [CalendarLayout.EventOccurrence], for dayOffset: Int) {
        occurrencesByDayOffset[dayOffset] = occs
        guard dayOffset == 0 else { return }
        updateModel { $0.occurrences = occs }
    }

    // MARK: One-time chrome / setting writes

    func setHeaderHeight(_ h: CGFloat) {
        headerHeight = h
        updateModel { $0.headerHeight = h }
    }

    func setEventHorizontalInset(_ inset: CGFloat) {
        eventHorizontalInset = inset
        updateModel { $0.eventHorizontalInset = inset }
    }

    func setTitleFontSize(_ size: Double) {
        titleFontSize = size
        updateModel { $0.titleFontSizeSetting = size }
    }

    func setShowTimeBelowTitle(_ on: Bool) {
        showTimeBelowTitle = on
        updateModel { $0.showTimeBelowTitle = on }
    }

    func setMultiTypeEnabled(_ on: Bool) {
        multiTypeEnabled = on
        updateModel { $0.multiTypeEnabled = on }
    }

    func setHorizonDays(_ days: Int) {
        horizonDays = days
        updateModel { $0.nearFutureHorizonDays = days }
    }

    func setShowEventText(_ on: Bool) {
        showEventText = on
        updateModel { $0.showEventText = on }
    }

    // MARK: Cached-Model mutation helper (S5.2)

    /// Mutate the cached Model in-place and re-`apply` to the live host.
    /// If either is nil (no host attached yet — S5.3 hasn't fired addHost,
    /// or coordinator is in single-day-off mode), the mutator is a no-op.
    ///
    /// Per spec §4b point 1, the host's existing `visualStateEqual`
    /// short-circuit handles the per-frame cost: only the changed field
    /// triggers a repaint, and pure visual-only field changes skip the
    /// full overlap rebuild via the cheap pinch path.
    private func updateModel(_ mutate: (inout DayLayerHostView.Model) -> Void) {
        guard var model = cachedModel else { return }
        mutate(&model)
        guard cachedModel != model else { return }
        cachedModel = model
        dayHost?.apply(model, callbacks: hostCallbacks)
    }
}

/// Output channel back to the page view. Mirrors the closure callbacks
/// currently passed to `CalendarDayLayerView` via the representable's
/// initializer — the SwiftUI Bindings become coordinator-issued delegate
/// calls + writeback.
@MainActor
protocol DayLayerCoordinatorDelegate: AnyObject {
    func dayLayer_onEventTap(_ event: Event, on date: Date)
    func dayLayer_onLongPressBegan(_ began: CalendarEventLongPressBegan)
    func dayLayer_onManipulationPromotion(
        _ event: Event,
        occurrenceID: String?,
        date: Date,
        mode: EventDragMode,
        point: CGPoint,
        frame: CGRect
    )
    func dayLayer_onLongPressResolved(_ resolution: CalendarEventLongPressResolution)
    func dayLayer_onDragEnded(
        _ event: Event,
        occurrenceID: String?,
        range: Event.TimeRange,
        offset: DragOffset,
        hourHeight: CGFloat
    )
    func dayLayer_onResizeEnded(
        _ event: Event,
        occurrenceID: String?,
        range: Event.TimeRange,
        anchor: Date,
        mode: EventDragMode,
        hourHeight: CGFloat
    )
    func dayLayer_onCreateEvent(_ range: Event.TimeRange, on date: Date)
    func dayLayer_onCreationPreviewChanged(_ day: Date, range: Event.TimeRange?)
    func dayLayer_onNonEventTap()
    func dayLayer_onHorizontalBoundaryPageRequest(direction: Int) -> Bool
    func dayLayer_onVisibleTimelineFrameChange(_ rect: CGRect)
}
