//
//  DayLayerCoordinator.swift
//  Done
//
//  Spec 07 §4a / §5 row S3 — `docs/calayer-rewrite/07-day-layer-imperative.md`.
//
//  Imperative day-layer coordinator: a UIKit class that OWNS the
//  `DayLayerHostView` subtree directly (no `UIViewRepresentable` wrapper).
//  Its setters are the channel-by-channel migration target from the
//  legacy `CalendarDayLayerView(...)` representable — every state field
//  (focus, grace, recentlyAbsorbed, creationPreviewRange, pinchHourHeight,
//  drag mirror, settings, mode, horizon — 11 channels per spec §5 row S4,
//  plus the §5 S5.8 follow-up render channels) flows through a
//  dedicated coordinator setter the page view writes to from an
//  `.onChange` or render-channels modifier.
//
//  Per-day host map (post-S5.10 rewrite, gh#57): the coordinator hosts a
//  `[Int: DayLayerHostView]` keyed by `dayOffset`, matching the spec §4a
//  sketch. Each SwiftUI pager placeholder publishes its own
//  `.global` frame via `.onGeometryChange`; the first call for an offset
//  lazy-creates that day's host pinned to its placeholder's converted
//  rect. SwiftUI's native horizontal ScrollView paging + peek therefore
//  Just Works — every visible page has its own host at its own X position.
//  No single-host gating; no horizontal-pan recognizer; no
//  `currentPageOffset` shadow.
//
//  Note: a `DayLayerCoordinator` is per-pager-page, not per-day-column. The
//  multi-day modes (3-day / week) keep using `CalendarDayLayerView` as a
//  per-column representable; the coordinator only engages in single-day
//  mode when `calendarUseImperativeDayLayer == true && rangeMode == .day`.
//

import UIKit

@MainActor
final class DayLayerCoordinator: NSObject, UIGestureRecognizerDelegate {

    // MARK: Topology

    private let container: UIView
    private let scrollView: UIScrollView
    /// `EventDragState` is `@Observable` — held weakly so the coordinator
    /// doesn't extend its lifetime past the page that owns it.
    private weak var dragState: EventDragState?

    weak var delegate: DayLayerCoordinatorDelegate?

    /// dayOffsets the coordinator has an attached host for. Mirrors the
    /// keys of `hostsByDayOffset` for unit-test introspection.
    var hostDayOffsets: Set<Int> { Set(hostsByDayOffset.keys) }

    // MARK: Cached broadcast state
    //
    // Each setter writes to one of these. Global-scope fields apply to ALL
    // active hosts; per-day fields key by `dayOffset` and apply only to
    // the matching host (if attached). Pre-host-attach setters still
    // write the cache so the first `addHost` for an offset reads the
    // correct initial Model.

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
    private(set) var dateByDayOffset: [Int: Date] = [:]
    private(set) var drawableLeadingByDayOffset: [Int: Int] = [:]
    private(set) var drawableTrailingByDayOffset: [Int: Int] = [:]
    private(set) var isFocusContextActive: Bool = false

    /// Spec 07 §2A: the 48h substrate's only band channel is `contentInset`.
    /// `setBandLeadingOpen` / `setBandTrailingOpen` flip the per-side
    /// `contentInset.top` / `.bottom` via `TimelineScrollProxy` in S5; S3
    /// just tracks the state.
    private(set) var bandLeadingOpen: Bool = false
    private(set) var bandTrailingOpen: Bool = false

    // MARK: Per-day host map (post-S5.10 rewrite)
    //
    // The coordinator owns one `DayLayerHostView` per `dayOffset` it has
    // been told about (via `addHost` or implicitly via the first
    // `setHostFrame` call for that offset). Each host's `Model` is cached
    // in `cachedModelByDayOffset` so per-frame mutations don't have to
    // rebuild from scratch. Per spec §4b point 2, hot-path callers
    // (`setHourHeight` during pinch, drag mirror) MUST update the cached
    // Model FIRST then call `host.repaintVertical(_:)` — never push a
    // stale Model on a later slow-path apply.

    private var hostsByDayOffset: [Int: DayLayerHostView] = [:]
    private var cachedModelByDayOffset: [Int: DayLayerHostView.Model] = [:]

    /// Callbacks the coordinator forwards to each host on apply. Same
    /// closures installed on every per-offset host — the host's own
    /// gesture controller fires them, and they fan out through
    /// `delegate?.dayLayer_onX(...)`. Until a delegate is installed via
    /// `setOutputDelegate`, output edges silently no-op.
    private var hostCallbacks = DayLayerHostView.Callbacks()

    /// Per-host horizontal pan recognizer for day swipe (selectedDayOffset).
    /// Each host owns its own — installed in addHost. Lives in this dict so
    /// removeHost can detach without leaking.
    private var horizontalDayPanByHost: [Int: UIPanGestureRecognizer] = [:]

    /// Page view sets this once the coordinator is constructed; the callback
    /// changes `calendarState.selectedDayOffset` by the resolved delta.
    var onHorizontalDayChange: ((Int) -> Void)?

    // MARK: Lifecycle

    init(container: UIView, scrollView: UIScrollView, dragState: EventDragState) {
        self.container = container
        self.scrollView = scrollView
        self.dragState = dragState
        super.init()
        hostCallbacks = makeHostCallbacks()
    }

    /// Install (or replace) the output delegate. Re-`apply`s every active
    /// host with the freshly-built `hostCallbacks` so they pick up the new
    /// delegate routing without waiting for the next setter-driven update.
    /// Passing `nil` detaches the delegate; subsequent host-emitted closures
    /// land on a nil delegate and silently no-op (the safe failure mode).
    func setOutputDelegate(_ delegate: DayLayerCoordinatorDelegate?) {
        self.delegate = delegate
        // Rebuild closures so they capture the (new) `self.delegate` indirectly
        // through the weak reference. The closures already read `self.delegate`
        // on each call, so a rebuild isn't strictly required — but doing so
        // keeps `hostCallbacks`'s identity in lockstep with the delegate state
        // for tests / future field additions, and the cost is one struct
        // assignment per delegate install.
        hostCallbacks = makeHostCallbacks()
        for (offset, host) in hostsByDayOffset {
            guard let model = cachedModelByDayOffset[offset] else { continue }
            host.apply(model, callbacks: hostCallbacks)
        }
    }

    /// Build the `DayLayerHostView.Callbacks` struct that fans every host
    /// output closure through the coordinator's `delegate`. The closures
    /// capture `self` weakly so the host doesn't extend the coordinator's
    /// lifetime; a nil-self capture is a defensive no-op consistent with the
    /// "output edge fires after teardown" race the adapter guards against.
    private func makeHostCallbacks() -> DayLayerHostView.Callbacks {
        DayLayerHostView.Callbacks(
            dragState: dragState,
            onEventTap: { [weak self] event, date in
                self?.delegate?.dayLayer_onEventTap(event, on: date)
            },
            onEventLongPressBegan: { [weak self] began in
                self?.delegate?.dayLayer_onLongPressBegan(began)
            },
            onEventManipulationPromotion: { [weak self] event, occID, date, mode, point, frame in
                self?.delegate?.dayLayer_onManipulationPromotion(
                    event, occurrenceID: occID, date: date,
                    mode: mode, point: point, frame: frame
                )
            },
            onEventLongPressResolved: { [weak self] resolution in
                self?.delegate?.dayLayer_onLongPressResolved(resolution)
            },
            onEventDragEnded: { [weak self] event, occID, range, offset, hourHeight in
                self?.delegate?.dayLayer_onDragEnded(
                    event, occurrenceID: occID, range: range,
                    offset: offset, hourHeight: hourHeight
                )
            },
            onEventResizeEnded: { [weak self] event, occID, range, anchor, mode, hourHeight in
                self?.delegate?.dayLayer_onResizeEnded(
                    event, occurrenceID: occID, range: range,
                    anchor: anchor, mode: mode, hourHeight: hourHeight
                )
            },
            onCreateEvent: { [weak self] range in
                // The host-emitted `onCreateEvent` is a SINGLE-day range scoped
                // to the host's `model.date`. We need to look up THAT host's
                // cached Model to recover the day; the host doesn't carry its
                // dayOffset back through the closure. Scan the cache — small N
                // (at most a few visible-window hosts) so O(n) is cheap.
                guard let self else { return }
                for (_, model) in self.cachedModelByDayOffset {
                    // Multiple hosts share the same closure instance; the host
                    // that fired this closure is the one whose Model's date
                    // matches the creation context. Without a per-host
                    // discriminator we can only fall back to the per-offset
                    // delegate writeback — but `onCreateEvent` on the host
                    // doesn't carry the host identity, so this scan reads the
                    // first non-empty cached model. For single-day usage this
                    // is offset=0; multi-host (3-day/week) is still on the
                    // SwiftUI representable so the ambiguity doesn't surface.
                    self.delegate?.dayLayer_onCreateEvent(range, on: model.date)
                    return
                }
            },
            onCreationPreviewChanged: { [weak self] day, range in
                self?.delegate?.dayLayer_onCreationPreviewChanged(day, range: range)
            },
            onNonEventTap: { [weak self] in
                self?.delegate?.dayLayer_onNonEventTap()
            },
            onHorizontalBoundaryPageRequest: { [weak self] direction in
                self?.delegate?.dayLayer_onHorizontalBoundaryPageRequest(direction: direction) ?? false
            },
            onVisibleTimelineFrameChange: { [weak self] frame in
                self?.delegate?.dayLayer_onVisibleTimelineFrameChange(frame)
            }
        )
    }

    // MARK: Topology setters

    /// Construct a `DayLayerHostView` for `dayOffset` (if not already
    /// attached), add it as a subview of `container`, and push the initial
    /// Model snapshot built from the coordinator's cached state.
    ///
    /// Initial sizing uses `frame` directly — no autoresizing mask. The
    /// placeholder's `.onGeometryChange` calls `setHostFrame` every layout
    /// pass, so the host stays pinned to its own day-column rect; an
    /// explicit-frame contract avoids container.bounds stretching the host
    /// back to fill the viewport.
    func addHost(dayOffset: Int, date: Date, frame: CGRect) {
        // Idempotent: a re-onAppear (tab switch + flag-flip) should reuse the
        // existing host rather than leak a second subview into the container.
        if hostsByDayOffset[dayOffset] != nil { return }
        let host = DayLayerHostView()
        host.backgroundColor = .clear
        // S5.10: selective hit-test on `DayLayerHostView.hitTest(_:with:)`
        // claims touches that land on a rendered event block (so tap /
        // long-press / drag reach the host's gesture controller + the
        // delegate adapter) while returning nil for empty-area touches so
        // the SwiftUI horizontal ScrollView paging + the enclosing
        // UIScrollView vertical scroll keep working.
        host.isUserInteractionEnabled = true
        host.frame = frame
        // Build the initial Model from the coordinator's cached primitives.
        // Fields outside the coordinator's setter surface (the 48h-constant
        // band coordinate hours, plus drawable hours = 0 at rest) default to
        // the imperative single-day substrate per spec §2A.
        let initial = DayLayerHostView.Model(
            date: dateByDayOffset[dayOffset] ?? date,
            occurrences: occurrencesByDayOffset[dayOffset] ?? [],
            contentWidth: contentWidthByDayOffset[dayOffset] ?? frame.width,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            eventHorizontalInset: eventHorizontalInset,
            leadingExtendedHours: 12,
            trailingExtendedHours: 12,
            drawableLeadingHours: drawableLeadingByDayOffset[dayOffset] ?? (bandLeadingOpen ? 12 : 0),
            drawableTrailingHours: drawableTrailingByDayOffset[dayOffset] ?? (bandTrailingOpen ? 12 : 0),
            useImperativeDayLayerModel: true,
            showEventText: showEventText,
            isWeekMode: (mode == .week),
            isThreeDayMode: (mode == .threeDay),
            titleFontSizeSetting: titleFontSize,
            showTimeBelowTitle: showTimeBelowTitle,
            multiTypeEnabled: multiTypeEnabled,
            nearFutureHorizonDays: horizonDays,
            isPinchActive: isPinchActive,
            frozenSlotMinutes: frozenSlotMinutes,
            dayColumnStep: 0,
            dragPreviewDayStep: dragPreviewDayStep,
            creationPreviewRange: creationPreviewRangeByDayOffset[dayOffset],
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            graceResizeEventID: graceResizeEventID,
            graceResizeOccurrenceID: graceResizeOccurrenceID,
            graceResizeHandleOpacity: graceResizeHandleOpacity,
            isFocusContextActive: isFocusContextActive,
            recentlyAbsorbedEventIDs: recentlyAbsorbedEventIDs
        )
        cachedModelByDayOffset[dayOffset] = initial
        // Insert BELOW the SwiftUI hosting view so the time-axis labels
        // (and any other SwiftUI chrome rendered in the hosting view tree)
        // stay on top, covering the host's event-block area that bleeds
        // into the axis column at X=0…36. Without this insertion order,
        // event blocks paint over the "0:00 / 1:00 / …" labels.
        let swiftUIHostingView = container.subviews.first { type(of: $0) != DayLayerHostView.self }
        if let below = swiftUIHostingView {
            container.insertSubview(host, belowSubview: below)
        } else {
            container.addSubview(host)
        }
        host.apply(initial, callbacks: hostCallbacks)
        hostsByDayOffset[dayOffset] = host

        // S5.10: with host hit-test returning self for ALL touches (so
        // empty-canvas long-press drag-to-create reaches the host), the
        // SwiftUI horizontal scroll never sees a touch and can't page.
        // Per-host pan recognizer that resolves a horizontal-dominant swipe
        // at pan-end into a selectedDayOffset delta. Cooperates with the
        // host's own long-press / tap / scroll recognizers via the
        // shouldRecognizeSimultaneouslyWith delegate.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalDayPan(_:)))
        pan.delegate = self
        host.addGestureRecognizer(pan)
        horizontalDayPanByHost[dayOffset] = pan
    }

    @objc private func handleHorizontalDayPan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        // Suppress mid-event-drag: a long-press → move-drag commit can have
        // a sizable horizontal translation that shouldn't page the day.
        if dragState?.draggingEventID != nil { return }
        guard let view = pan.view else { return }
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        // Horizontal-dominant motion. 1.5× bias keeps vertical scroll
        // cleanly winning when the user intends vertical.
        guard abs(translation.x) > abs(translation.y) * 1.5 else { return }
        // Significant translation OR significant velocity.
        guard abs(translation.x) > 50 || abs(velocity.x) > 300 else { return }
        let delta = translation.x > 0 ? -1 : 1
        onHorizontalDayChange?(delta)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Only relaxes simultaneity FROM the day-pan side — the host's own
        // gesture controller's recognizers keep their own (more restrictive)
        // simultaneity rules among themselves. The host's long-press /
        // tap / create / pan can all coexist with our day-pan; their
        // own internal exclusivity (e.g. long-press cancels tap) is
        // unaffected.
        let isOurPan = horizontalDayPanByHost.values.contains { $0 === gestureRecognizer }
            || horizontalDayPanByHost.values.contains { $0 === other }
        return isOurPan
    }

    /// Pin the host for `dayOffset` to the SwiftUI placeholder's
    /// `.global` frame, converting to `container` coords. If no host yet
    /// exists for that offset this is the lazy-create trigger — reads the
    /// cached Model populated by prior render-channel writes and applies.
    ///
    /// `globalFrame` is the SwiftUI placeholder's window-space frame. We
    /// convert it into the coordinator's `container` coordinate space so
    /// the host (a subview of `container`) gets the right local rect.
    /// Passing `from: nil` to `UIView.convert(_:from:)` interprets the
    /// rect in window coords — matching SwiftUI's `.global`.
    func setHostFrame(_ globalFrame: CGRect, for dayOffset: Int) {
        guard globalFrame.width > 0, globalFrame.height > 0 else { return }
        let frameInContainer = container.convert(globalFrame, from: nil)
        // Lazy-create: first geometry callback for this offset constructs
        // the host pinned to its own placeholder rect. Subsequent calls
        // just re-pin the existing host. The cached Model accumulated by
        // pre-attach `setOccurrences` / `setDate` / etc. is read by
        // `addHost` to build the initial apply.
        if hostsByDayOffset[dayOffset] == nil {
            let initialDate = dateByDayOffset[dayOffset]
                ?? Calendar.current.startOfDay(for: Date())
            addHost(dayOffset: dayOffset, date: initialDate, frame: frameInContainer)
            return
        }
        applyHostFrameIfChanged(frameInContainer, for: dayOffset)
    }

    /// Remove the host for `dayOffset` from the container + drop its cached
    /// state. Per-day caches are evicted so a later re-add reads from
    /// freshly-pushed data; not strictly required (the cache would be
    /// overwritten anyway) but matches the spec's "topology mutation"
    /// semantics.
    func removeHost(dayOffset: Int) {
        contentWidthByDayOffset.removeValue(forKey: dayOffset)
        creationPreviewRangeByDayOffset.removeValue(forKey: dayOffset)
        occurrencesByDayOffset.removeValue(forKey: dayOffset)
        dateByDayOffset.removeValue(forKey: dayOffset)
        drawableLeadingByDayOffset.removeValue(forKey: dayOffset)
        drawableTrailingByDayOffset.removeValue(forKey: dayOffset)
        cachedModelByDayOffset.removeValue(forKey: dayOffset)
        if let pan = horizontalDayPanByHost.removeValue(forKey: dayOffset) {
            pan.view?.removeGestureRecognizer(pan)
        }
        guard let host = hostsByDayOffset.removeValue(forKey: dayOffset) else { return }
        host.removeFromSuperview()
    }

    /// Bulk teardown: remove every attached host (flag flip OFF, scroll-view
    /// uninstall, range-mode rebuild). Lazy-create on the next geometry
    /// callback re-establishes the active set.
    func removeAllHosts() {
        for offset in Array(hostsByDayOffset.keys) {
            removeHost(dayOffset: offset)
        }
    }

    func setMode(_ mode: RangeMode) {
        self.mode = mode
        broadcastModel { m in
            m.isWeekMode = (mode == .week)
            m.isThreeDayMode = (mode == .threeDay)
        }
    }

    func setContentWidth(_ width: CGFloat, for dayOffset: Int) {
        contentWidthByDayOffset[dayOffset] = width
        updateModel(for: dayOffset) { $0.contentWidth = width }
    }

    func setDragPreviewDayStep(_ step: CGFloat) {
        dragPreviewDayStep = step
        broadcastModel { $0.dragPreviewDayStep = step }
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
    /// pinch case), so the same call covers both. Broadcast to every active
    /// host so multi-day pages stay in sync during a pinch.
    func setHourHeight(_ height: CGFloat) {
        hourHeight = height
        broadcastModel { $0.hourHeight = height }
    }

    func setPinchActive(_ active: Bool) {
        isPinchActive = active
        broadcastModel { $0.isPinchActive = active }
    }

    func setFrozenSlotMinutes(_ minutes: Int?) {
        frozenSlotMinutes = minutes
        broadcastModel { $0.frozenSlotMinutes = minutes }
    }

    // MARK: Focus / grace / drag / absorb broadcasts

    func setFocus(eventID: UUID?, occurrenceID: String?) {
        focusedEventID = eventID
        focusedOccurrenceID = occurrenceID
        broadcastModel { m in
            m.focusedEventID = eventID
            m.focusedOccurrenceID = occurrenceID
            m.isFocusContextActive = (eventID != nil)
        }
    }

    func setGraceResize(eventID: UUID?, occurrenceID: String?, opacity: Double) {
        graceResizeEventID = eventID
        graceResizeOccurrenceID = occurrenceID
        graceResizeHandleOpacity = opacity
        broadcastModel { m in
            m.graceResizeEventID = eventID
            m.graceResizeOccurrenceID = occurrenceID
            m.graceResizeHandleOpacity = opacity
        }
    }

    func setRecentlyAbsorbedEventIDs(_ ids: Set<UUID>) {
        recentlyAbsorbedEventIDs = ids
        broadcastModel { $0.recentlyAbsorbedEventIDs = ids }
    }

    func setCreationPreviewRange(_ range: Event.TimeRange?, for dayOffset: Int) {
        if let range {
            creationPreviewRangeByDayOffset[dayOffset] = range
        } else {
            creationPreviewRangeByDayOffset.removeValue(forKey: dayOffset)
        }
        updateModel(for: dayOffset) { $0.creationPreviewRange = range }
    }

    func setOccurrences(_ occs: [CalendarLayout.EventOccurrence], for dayOffset: Int) {
        occurrencesByDayOffset[dayOffset] = occs
        updateModel(for: dayOffset) { $0.occurrences = occs }
    }

    private func applyHostFrameIfChanged(_ frameInContainer: CGRect, for dayOffset: Int) {
        guard let host = hostsByDayOffset[dayOffset] else { return }
        // Only do "significant" frame changes — sub-pt floating-point jitter
        // from cold-start scroll animation should not trigger expensive
        // re-applies. ≥1pt change in any dimension counts as significant.
        let prev = host.frame
        let isSignificant = abs(prev.minX - frameInContainer.minX) >= 1
            || abs(prev.minY - frameInContainer.minY) >= 1
            || abs(prev.width - frameInContainer.width) >= 1
            || abs(prev.height - frameInContainer.height) >= 1
        guard isSignificant else {
            if prev != frameInContainer { host.frame = frameInContainer }
            return
        }
        host.frame = frameInContainer
        // Frame-vs-Model race: the initial `addHost` apply runs against the
        // placeholder's first published frame. A later layout pass (pinch,
        // rotation) shrinks or grows bounds but `apply` is never re-fired
        // against the new bounds — events would stay at stale x positions.
        // Re-apply forces a full re-layout against the now-correct bounds.
        if let model = cachedModelByDayOffset[dayOffset] {
            host.apply(model, callbacks: hostCallbacks)
        }
    }

    /// Per-day anchor date. The user pages through days; each host's date
    /// is set independently. `addHost` reads the initial date as a
    /// parameter, but subsequent changes need this setter.
    func setDate(_ date: Date, for dayOffset: Int) {
        dateByDayOffset[dayOffset] = date
        updateModel(for: dayOffset) { $0.date = date }
    }

    /// Drawable window for the band region. At rest both are 0 (band region
    /// renders empty); during a drag that crosses the substrate edge they
    /// open to 12/12 so the dragged event paints through the band area. The
    /// SwiftUI representable used to read `drawableExtensionHours` per-frame;
    /// post-S5 cord-cut this setter is the only path.
    func setDrawableHours(leading: Int, trailing: Int, for dayOffset: Int) {
        drawableLeadingByDayOffset[dayOffset] = leading
        drawableTrailingByDayOffset[dayOffset] = trailing
        updateModel(for: dayOffset) { m in
            m.drawableLeadingHours = leading
            m.drawableTrailingHours = trailing
        }
    }

    /// Focus context active flag. Distinct from `setFocus(eventID:occurrenceID:)`
    /// — the focused-event identifiers are nil-or-set; this flag is what
    /// gates sibling dimming + interaction. Driven by the page view's focus
    /// state machine.
    func setFocusContextActive(_ active: Bool) {
        isFocusContextActive = active
        broadcastModel { $0.isFocusContextActive = active }
    }

    // MARK: One-time chrome / setting writes

    func setHeaderHeight(_ h: CGFloat) {
        headerHeight = h
        broadcastModel { $0.headerHeight = h }
    }

    func setEventHorizontalInset(_ inset: CGFloat) {
        eventHorizontalInset = inset
        broadcastModel { $0.eventHorizontalInset = inset }
    }

    func setTitleFontSize(_ size: Double) {
        titleFontSize = size
        broadcastModel { $0.titleFontSizeSetting = size }
    }

    func setShowTimeBelowTitle(_ on: Bool) {
        showTimeBelowTitle = on
        broadcastModel { $0.showTimeBelowTitle = on }
    }

    func setMultiTypeEnabled(_ on: Bool) {
        multiTypeEnabled = on
        broadcastModel { $0.multiTypeEnabled = on }
    }

    func setHorizonDays(_ days: Int) {
        horizonDays = days
        broadcastModel { $0.nearFutureHorizonDays = days }
    }

    func setShowEventText(_ on: Bool) {
        showEventText = on
        broadcastModel { $0.showEventText = on }
    }

    // MARK: Cached-Model mutation helpers

    /// Mutate one offset's cached Model and re-`apply` to its host (if
    /// attached). If the offset has no cached Model yet (pre-`addHost`),
    /// seed-via-default: build a blank-ish Model so the first mutation
    /// persists and the next `addHost` reads it. Mutations to a
    /// not-yet-cached offset still want to land (per task spec: "All
    /// those pushes update `cachedModelByDayOffset` but apply to
    /// nonexistent hosts. First `setHostFrame` triggers `addHost`, which
    /// reads the cached model and applies.")
    ///
    /// Per spec §4b point 1, the host's existing `visualStateEqual`
    /// short-circuit handles the per-frame cost: only the changed field
    /// triggers a repaint, and pure visual-only field changes skip the
    /// full overlap rebuild via the cheap pinch path.
    private func updateModel(
        for dayOffset: Int,
        _ mutate: (inout DayLayerHostView.Model) -> Void
    ) {
        // No-op: pre-attach the per-day caches (occurrencesByDayOffset etc.)
        // already hold the canonical value. The first `addHost` builds the
        // initial Model from those caches directly, so we don't need to
        // synthesize a partial Model here. If a host IS attached, the
        // Model exists and we apply.
        guard var model = cachedModelByDayOffset[dayOffset] else { return }
        mutate(&model)
        guard cachedModelByDayOffset[dayOffset] != model else { return }
        cachedModelByDayOffset[dayOffset] = model
        hostsByDayOffset[dayOffset]?.apply(model, callbacks: hostCallbacks)
    }

    /// Broadcast a Model mutation to every active host. Used by global-scope
    /// setters (mode, hourHeight, focus, headerHeight, settings, ...) — every
    /// page's Model picks up the same change.
    private func broadcastModel(_ mutate: (inout DayLayerHostView.Model) -> Void) {
        for offset in cachedModelByDayOffset.keys {
            updateModel(for: offset, mutate)
        }
    }
}

// MARK: - Output delegate

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

// MARK: - Delegate adapter

/// Closure-backed conformance to `DayLayerCoordinatorDelegate`.
///
/// `CalendarPageView` is a SwiftUI `View` (a value type) so it can't itself be
/// the `AnyObject` delegate the coordinator holds weakly. This adapter is a
/// reference-typed bridge: the page view stores it in `@State`, wires each
/// closure to the existing SwiftUI-path handler (`handleTimelineEventTap`,
/// etc.), then hands the adapter to `coordinator.setOutputDelegate(_:)`.
///
/// Two closures (`onCreationPreviewChanged`, `onHorizontalBoundaryPageRequest`)
/// are owned by `TimelinePagerView` rather than `CalendarPageView` because the
/// existing handlers (`updateCreationPreviewMapping`, the inline
/// `requestHorizontalBoundaryPage` lambda) live on the pager view's state.
/// Both views write to the same adapter instance; nil-closures no-op so
/// either side may install before the other.
@MainActor
final class DayLayerCoordinatorDelegateAdapter: NSObject, DayLayerCoordinatorDelegate {
    var onEventTap: ((Event, Date) -> Void)?
    var onLongPressBegan: ((CalendarEventLongPressBegan) -> Void)?
    var onManipulationPromotion: ((Event, String?, Date, EventDragMode, CGPoint, CGRect) -> Void)?
    var onLongPressResolved: ((CalendarEventLongPressResolution) -> Void)?
    var onDragEnded: ((Event, String?, Event.TimeRange, DragOffset, CGFloat) -> Void)?
    var onResizeEnded: ((Event, String?, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)?
    var onCreateEvent: ((Date, Event.TimeRange) -> Void)?
    var onCreationPreviewChanged: ((Date, Event.TimeRange?) -> Void)?
    var onNonEventTap: (() -> Void)?
    var onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
    var onVisibleTimelineFrameChange: ((CGRect) -> Void)?

    func dayLayer_onEventTap(_ event: Event, on date: Date) {
        onEventTap?(event, date)
    }
    func dayLayer_onLongPressBegan(_ began: CalendarEventLongPressBegan) {
        onLongPressBegan?(began)
    }
    func dayLayer_onManipulationPromotion(
        _ event: Event,
        occurrenceID: String?,
        date: Date,
        mode: EventDragMode,
        point: CGPoint,
        frame: CGRect
    ) {
        onManipulationPromotion?(event, occurrenceID, date, mode, point, frame)
    }
    func dayLayer_onLongPressResolved(_ resolution: CalendarEventLongPressResolution) {
        onLongPressResolved?(resolution)
    }
    func dayLayer_onDragEnded(
        _ event: Event,
        occurrenceID: String?,
        range: Event.TimeRange,
        offset: DragOffset,
        hourHeight: CGFloat
    ) {
        onDragEnded?(event, occurrenceID, range, offset, hourHeight)
    }
    func dayLayer_onResizeEnded(
        _ event: Event,
        occurrenceID: String?,
        range: Event.TimeRange,
        anchor: Date,
        mode: EventDragMode,
        hourHeight: CGFloat
    ) {
        onResizeEnded?(event, occurrenceID, range, anchor, mode, hourHeight)
    }
    func dayLayer_onCreateEvent(_ range: Event.TimeRange, on date: Date) {
        onCreateEvent?(date, range)
    }
    func dayLayer_onCreationPreviewChanged(_ day: Date, range: Event.TimeRange?) {
        onCreationPreviewChanged?(day, range)
    }
    func dayLayer_onNonEventTap() {
        onNonEventTap?()
    }
    func dayLayer_onHorizontalBoundaryPageRequest(direction: Int) -> Bool {
        onHorizontalBoundaryPageRequest?(direction) ?? false
    }
    func dayLayer_onVisibleTimelineFrameChange(_ rect: CGRect) {
        onVisibleTimelineFrameChange?(rect)
    }
}
