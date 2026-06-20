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
    private(set) var dateByDayOffset: [Int: Date] = [:]
    private(set) var drawableLeadingByDayOffset: [Int: Int] = [:]
    private(set) var drawableTrailingByDayOffset: [Int: Int] = [:]
    /// Per-offset window-coord frame of the SwiftUI placeholder. Every page's
    /// `.onGeometryChange` writes here regardless of `currentPageOffset`; only
    /// the current page's frame actually pins the host. On `setCurrentPageOffset`
    /// the host is re-pinned from this cache so it doesn't wait for the new
    /// page's next geometry callback.
    private(set) var hostFrameByDayOffset: [Int: CGRect] = [:]
    private(set) var isFocusContextActive: Bool = false

    /// Which page offset is currently visible in the pager. The single
    /// `dayHost` always renders THIS offset's cached state. Spec 07 §5 S5
    /// took a shortcut of assuming a fixed offset=0 host — that breaks
    /// when the user pages to a different day. setSetters cache per-offset
    /// but only push to the host when `dayOffset == currentPageOffset`.
    /// CalendarPageView wires this to `calendarState.selectedDayOffset`.
    private(set) var currentPageOffset: Int = 0

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
    /// `addHost` (S5.6) so every host-emitted gesture/output closure routes
    /// through `delegate?.dayLayer_onX(...)` — the page view's adapter then
    /// dispatches to the existing SwiftUI-path handlers. Until a delegate is
    /// installed via `setOutputDelegate`, output edges are no-ops.
    private var hostCallbacks = DayLayerHostView.Callbacks()

    // MARK: Lifecycle

    init(container: UIView, scrollView: UIScrollView, dragState: EventDragState) {
        self.container = container
        self.scrollView = scrollView
        self.dragState = dragState
        super.init()
        hostCallbacks = makeHostCallbacks()
    }

    /// Install (or replace) the output delegate. Re-`apply`s the host with the
    /// freshly-built `hostCallbacks` so an existing host picks up the new
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
        guard let model = cachedModel, let host = dayHost else { return }
        host.apply(model, callbacks: hostCallbacks)
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
                // to the host's `model.date`. The legacy SwiftUI representable
                // path wrapped this with the day-column's date (see
                // `buildLegacyDayLayerView`); we read it back off the cached
                // Model so the delegate signature matches.
                guard let self, let model = self.cachedModel else { return }
                self.delegate?.dayLayer_onCreateEvent(range, on: model.date)
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

    // MARK: Topology setters (S5 wires)

    /// Construct the `DayLayerHostView` for `dayOffset`, add it as a subview
    /// of `container`, and push the initial Model snapshot built from the
    /// coordinator's cached state. Single-day only at S5 (dayOffset 0).
    ///
    /// Initial sizing uses `frame` + autoresizing mask; subsequent layout
    /// changes (rotation, contentSize from a pinch) flow through the
    /// container's bounds. The autoresizing mask matches the historic
    /// `CalendarDayLayerView` representable's behavior — the SwiftUI tree
    /// stretched the day-layer to its parent and the host's
    /// `layoutSubviews` re-renders accordingly. A later slice may switch
    /// to explicit Auto Layout constraints; the autoresizing mask gets us
    /// to behavioral parity without over-fitting the geometry contract.
    func addHost(dayOffset: Int, date: Date, frame: CGRect) {
        guard dayOffset == 0 else {
            // Multi-day mode still uses the SwiftUI representable — coordinator
            // only owns the single-day host. Defensive no-op if a caller asks
            // for a non-zero offset on this slice.
            hostDayOffsets.insert(dayOffset)
            return
        }
        // Idempotent: a re-onAppear (tab switch + flag-flip) should reuse the
        // existing host rather than leak a second subview into the container.
        if dayHost != nil {
            hostDayOffsets.insert(dayOffset)
            return
        }
        let host = DayLayerHostView()
        // 🩹 S5.9 debug visualization: tint host background so we can see
        // EXACTLY where it is on screen — if user sees a faint tinted rect
        // covering the day-column slot, host is visible + correctly framed
        // and the bug is inside `apply`'s event-block render. If they see
        // nothing → host is covered / clipped / detached despite logs.
        host.backgroundColor = UIColor.systemPink.withAlphaComponent(0.10)
        host.frame = frame
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
            isWeekMode: false,
            isThreeDayMode: false,
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
        cachedModel = initial
        container.addSubview(host)
        host.apply(initial, callbacks: hostCallbacks)
        dayHost = host
        hostDayOffsets.insert(dayOffset)
        let containerSubviewCount = container.subviews.count
        let hostIdx = container.subviews.firstIndex(of: host) ?? -1
        print("🩹[s5.8] coord.addHost offset=\(dayOffset) date=\(initial.date) occCount=\(initial.occurrences.count) frame=\(frame) hostBg=\(String(describing: host.backgroundColor)) hostInHier=\(host.window != nil) hostHidden=\(host.isHidden) hostAlpha=\(host.alpha) container=\(type(of: container)) containerSubviewCount=\(containerSubviewCount) hostIdx=\(hostIdx)")
    }

    /// Spec 07 §5 S5.7: pin the host's frame to the SwiftUI day-column's
    /// rect. The SwiftUI tree has an axis column (26pt left) + an all-day
    /// pill row above the day column; until this is called the host fills
    /// `container.bounds` (post-S5.9a `container` is the UIScrollView, so
    /// pre-pin the host stretches over the full viewport) which paints
    /// events ON TOP of the axis. The page view's placeholder publishes
    /// its frame in `.global` (window) coords via GeometryReader; we
    /// convert to container coords here so a viewport pan or rotation
    /// pushes a fresh frame through the same path. Multi-day still uses
    /// the SwiftUI representable so no per-column pinning is needed for
    /// it.
    ///
    /// Container-coord note (S5.9a): `container` is the `UIScrollView`
    /// itself, so `container.convert(_, from: nil)` returns scroll-view-
    /// local coords (which include `contentOffset`-derived bounds.origin).
    /// The placeholder's `.global` frame changes on every scroll tick, but
    /// the converted scroll-content rect stays constant — the
    /// `host.frame != frameInContainer` guard short-circuits the write so
    /// the per-scroll cost is just the conversion math.
    ///
    /// `globalFrame` is the SwiftUI placeholder's window-space frame. We
    /// convert it into the coordinator's `container` coordinate space so the
    /// host (a subview of `container`) gets the right local rect. Passing
    /// `from: nil` to `UIView.convert(_:from:)` interprets the rect in
    /// window coords — matching SwiftUI's `.global`.
    ///
    /// Switching off autoresizing here so the explicit frame sticks: with
    /// the mask on, a subsequent `container.bounds` change (rotation,
    /// pinch-driven contentSize) would stretch the host BACK to fill
    /// `container`, defeating the purpose. The placeholder's GeometryReader
    /// re-publishes on those same events, so explicit-frame ownership keeps
    /// the host in sync.
    func setHostFrame(_ globalFrame: CGRect, for dayOffset: Int) {
        // Cache every offset's latest frame so a re-page can re-pin to a known
        // value without waiting for that page's next geometry callback.
        hostFrameByDayOffset[dayOffset] = globalFrame
        // S5.8 follow-up Bug 3: every TabView-preloaded page fires this
        // simultaneously. Only the CURRENTLY-VISIBLE page's frame is the
        // right rect for the single host — the others report off-screen
        // values that would yank the host out of view if applied. Without
        // this guard, an arbitrary scheduling order between concurrent
        // placeholder `.onGeometryChange` callbacks can leave the host
        // pinned to an off-screen offset (no events / background visible,
        // even though the Model has them).
        guard dayOffset == currentPageOffset else { return }
        applyHostFrameIfChanged(globalFrame)
    }

    func removeHost(dayOffset: Int) {
        hostDayOffsets.remove(dayOffset)
        contentWidthByDayOffset.removeValue(forKey: dayOffset)
        creationPreviewRangeByDayOffset.removeValue(forKey: dayOffset)
        occurrencesByDayOffset.removeValue(forKey: dayOffset)
        dateByDayOffset.removeValue(forKey: dayOffset)
        drawableLeadingByDayOffset.removeValue(forKey: dayOffset)
        drawableTrailingByDayOffset.removeValue(forKey: dayOffset)
        guard dayOffset == 0, let host = dayHost else { return }
        host.removeFromSuperview()
        dayHost = nil
        cachedModel = nil
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
        guard dayOffset == currentPageOffset else { return }
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
        guard dayOffset == currentPageOffset else { return }
        updateModel { $0.creationPreviewRange = range }
    }

    func setOccurrences(_ occs: [CalendarLayout.EventOccurrence], for dayOffset: Int) {
        let occDetails = occs.map { "\($0.range.start)→\($0.range.end)" }.joined(separator: " | ")
        print("🩹[s5.8] coord.setOccurrences offset=\(dayOffset) count=\(occs.count) cur=\(currentPageOffset) push=\(dayOffset == currentPageOffset) ranges=[\(occDetails)]")
        occurrencesByDayOffset[dayOffset] = occs
        guard dayOffset == currentPageOffset else { return }
        updateModel { $0.occurrences = occs }
    }

    // MARK: Channels missed by spec §5 S4 (S5.8 follow-up)

    /// Switch which page offset the single host renders. The pager mounts
    /// many pages (TabView preload window); the host always reflects
    /// `currentPageOffset`'s cached state. Called from CalendarPageView's
    /// `.onChange(of: calendarState.selectedDayOffset)` whenever the user
    /// pages. Also fires the initial sync once the coordinator-aware
    /// modifier first publishes for a new offset.
    func setCurrentPageOffset(_ offset: Int) {
        currentPageOffset = offset
        updateModel { m in
            m.date = dateByDayOffset[offset] ?? m.date
            m.occurrences = occurrencesByDayOffset[offset] ?? []
            m.creationPreviewRange = creationPreviewRangeByDayOffset[offset]
            m.drawableLeadingHours = drawableLeadingByDayOffset[offset]
                ?? (bandLeadingOpen ? 12 : 0)
            m.drawableTrailingHours = drawableTrailingByDayOffset[offset]
                ?? (bandTrailingOpen ? 12 : 0)
            if let w = contentWidthByDayOffset[offset] { m.contentWidth = w }
        }
        // Re-pin host frame to the new offset's last-known placeholder rect
        // so the host doesn't sit at the previous offset's (now off-screen)
        // location for the gap between this call and the new page's next
        // `.onGeometryChange` tick.
        if let cachedFrame = hostFrameByDayOffset[offset] {
            applyHostFrameIfChanged(cachedFrame)
        }
        print("🩹[s5.8] coord.setCurrentPageOffset offset=\(offset) hasHost=\(dayHost != nil) cachedOccCount=\(occurrencesByDayOffset[offset]?.count ?? -1) cachedFrame=\(hostFrameByDayOffset[offset].map { String(describing: $0) } ?? "nil")")
    }

    private func applyHostFrameIfChanged(_ globalFrame: CGRect) {
        guard let host = dayHost else { return }
        guard globalFrame.width > 0, globalFrame.height > 0 else { return }
        let frameInContainer = container.convert(globalFrame, from: nil)
        if host.autoresizingMask != [] {
            host.autoresizingMask = []
        }
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
        print("🩹[s5.8] applyHostFrame globalFrame=\(globalFrame) → frameInContainer=\(frameInContainer) prevFrame=\(prev) inHier=\(host.window != nil)")
        host.frame = frameInContainer
        // S5.9 frame-vs-Model race: the initial `addHost` apply happens with
        // host.bounds = scrollView.bounds (e.g. 402×874); the sublayers are
        // positioned for that coord space. Later `setHostFrame` shrinks
        // bounds to the day-column (e.g. 364×1340) but `apply` was never
        // re-fired against the new bounds — so events painted at stale
        // x positions (off-canvas) or invisible. Re-apply forces a full
        // re-layout against the now-correct bounds.
        if let model = cachedModel {
            host.apply(model, callbacks: hostCallbacks)
            print("🩹[s5.8] applyHostFrame re-applied Model in new bounds=\(host.bounds) sublayers=\(host.layer.sublayers?.count ?? 0)")
        }
    }

    /// Per-day anchor date. The user pages through days; the date in the
    /// cached Model must follow. `addHost` reads the initial date as a
    /// parameter, but subsequent changes need this setter.
    func setDate(_ date: Date, for dayOffset: Int) {
        dateByDayOffset[dayOffset] = date
        guard dayOffset == currentPageOffset else { return }
        updateModel { $0.date = date }
    }

    /// Drawable window for the band region. At rest both are 0 (band region
    /// renders empty); during a drag that crosses the substrate edge they
    /// open to 12/12 so the dragged event paints through the band area. The
    /// SwiftUI representable used to read `drawableExtensionHours` per-frame;
    /// post-S5 cord-cut this setter is the only path.
    func setDrawableHours(leading: Int, trailing: Int, for dayOffset: Int) {
        drawableLeadingByDayOffset[dayOffset] = leading
        drawableTrailingByDayOffset[dayOffset] = trailing
        guard dayOffset == currentPageOffset else { return }
        updateModel { m in
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
        updateModel { $0.isFocusContextActive = active }
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
        guard var model = cachedModel else {
            print("🩹[s5.8] updateModel SKIPPED — cachedModel is nil (addHost not fired yet)")
            return
        }
        mutate(&model)
        guard cachedModel != model else { return }
        cachedModel = model
        dayHost?.apply(model, callbacks: hostCallbacks)
        if let h = dayHost {
            print("🩹[s5.8] updateModel applied occCount=\(model.occurrences.count) date=\(model.date) hostFrame=\(h.frame) inHier=\(h.window != nil) hidden=\(h.isHidden) alpha=\(h.alpha) opacity=\(h.layer.opacity) sublayers=\(h.layer.sublayers?.count ?? 0)")
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
