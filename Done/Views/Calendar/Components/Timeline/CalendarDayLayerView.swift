//
//  CalendarDayLayerView.swift
//  Done
//
//  CALayer rewrite — slice S1 (full event visual fidelity).
//
//  A flag-gated (`AppSettingsKeys.useCALayerTimeline`, default OFF)
//  UIViewRepresentable that STATICALLY renders one day column's events as
//  CALayers at FULL visual parity with the SwiftUI `EventBlock`:
//  background fill + centered stroke border + title/subtitle/time text gates
//  + todo border + diagonal hatch + agentic shimmer/spinner/failed badge +
//  multi-type corner triangle + effort left-bar + resize-handle capsules +
//  compound interrupt cutout silhouette + stack-peek cover text-fit + opacity
//  states. No gestures (S4), no animations (S5), no pinch repaint (S3).
//
//  Geometry / topology are NOT reimplemented: vertical placement reuses the
//  spec-03 fraction mapping, horizontal placement reuses
//  `CalendarLayout.overlapLayout` (now in stack-peek mode), and the compound
//  interrupt silhouette reuses `CalendarInterruptParentCompoundShape` (which
//  itself routes through `calendarRoundedClosedPolygonPath`). Text fitting
//  reuses `calendarEventTextLayout` / `calendarInterruptParentTextLayout`.
//
//  Layer-vs-mask boundary (spec 01 §0): the `bg` fill, hatch, agentic
//  gradient, multi-type triangle, and text are CLIPPED by the silhouette mask
//  (they live under `maskedContent`, which carries the mask). The border,
//  todo border, effort bar, resize handles, and spinner are applied AFTER the
//  mask and are NOT clipped (they are direct children of `container`).
//

import SwiftUI

// MARK: - UIViewRepresentable boundary

/// S1 boundary: renders one day column's events at full `EventBlock` visual
/// fidelity via a persistent `DayLayerHostView`. Mirrors the per-day inputs
/// that the SwiftUI `TimelineDayView` receives at the pager injection point.
struct CalendarDayLayerView: UIViewRepresentable {
    /// The day this column represents (start-of-day anchor used by the
    /// vertical-mapping + overlap functions).
    let date: Date
    /// Layout-ready occurrences for this day offset (already filtered /
    /// recurring-expanded / absorbed-removed upstream by the host cache and
    /// `CalendarLayout.timelineVisibleOccurrences`).
    let occurrences: [CalendarLayout.EventOccurrence]
    /// This day column's content width (== the per-column `dayWidth`).
    let contentWidth: CGFloat
    /// Empty headroom above 00:00 (`calendarTimelineTopInset(hourHeight:)`).
    let headerHeight: CGFloat
    /// Points-per-hour vertical scale.
    let hourHeight: CGFloat
    /// L/R inset of the event area inside a day column (8 single-day, 4 multi-day).
    let eventHorizontalInset: CGFloat
    /// Leading / trailing boundary-extension hours (0 in the static S1 case).
    let leadingExtendedHours: Int
    let trailingExtendedHours: Int
    /// Whether to draw title text (mirrors `showEventText`).
    let showEventText: Bool
    /// True in week mode — drives compact text insets + week-mode time font ratio.
    let isWeekMode: Bool
    let isThreeDayMode: Bool
    /// User title font size setting (clamped [9,16] downstream). Mirrors
    /// `EventBlock.resolvedTitleFontSize`'s source.
    let titleFontSizeSetting: Double
    /// User "show time below title" setting (default ON). Mirrors
    /// `EventBlock.showTimeBelowTitleSetting`.
    let showTimeBelowTitle: Bool
    /// Whether the experimental multi-type indicator feature is enabled.
    let multiTypeEnabled: Bool
    /// HORIZON span in days (mirrors `TimelineDayView`'s
    /// `nearFutureHorizonDays` `@AppStorage`). Drives the future-zone tint +
    /// horizon line; the actual horizon `Date` is recomputed from `Date()` at
    /// render time (S2 chrome §future-zone) so it is NOT stored in the Model.
    let nearFutureHorizonDays: Int
    /// True while a range-pinch gesture is live (mirrors the host's
    /// `isRangePinchActive`). Drives the cheap vertical-only repaint path (S3)
    /// and the frozen-slot grid behaviour.
    let isPinchActive: Bool
    /// Slot density captured at pinch start (mirrors the host's
    /// `rangePinchFrozenSlotMinutes`). `nil` outside pinch. When non-nil the
    /// grid's `slotHeight` / `slotCount` use this frozen value while line
    /// density (`isSubHourLine`) still uses the LIVE `slotMinutes` (spec 03 §9).
    let frozenSlotMinutes: Int?

    // MARK: Gesture inputs (S4)

    /// Per-day horizontal step in points. In multi-day modes this is the
    /// column step (`width + daySpacing`) and move drag follows the finger
    /// across columns; single-day mode passes `0` (boundary paging instead).
    var dayColumnStep: CGFloat = 0
    /// The day-step used for the live cross-day preview projection AND for
    /// single-day boundary paging. Mirrors `EventBlock.dragPreviewDayStep`.
    var dragPreviewDayStep: CGFloat = 0
    /// Live drag preview for this day during drag-to-create (already clipped
    /// to this day by the host's `creationPreviewByDay` mapping) OR the
    /// post-release pending-create ghost.
    var creationPreviewRange: Event.TimeRange? = nil
    /// Focus highlight (focused block scale/handles; siblings dim to 0.28).
    var focusedEventID: UUID? = nil
    var focusedOccurrenceID: String? = nil
    /// Post-commit resize-grace handles that fade out.
    var graceResizeEventID: UUID? = nil
    var graceResizeOccurrenceID: String? = nil
    var graceResizeHandleOpacity: Double = 1
    /// True while any event has focus (siblings dim, interaction gated).
    var isFocusContextActive: Bool = false
    /// Event ids the host considers recently-absorbed-into (drives the §4
    /// absorption pulse). Mirror of `TimelineView.recentlyAbsorbedParents`.
    var recentlyAbsorbedEventIDs: Set<UUID> = []
    /// Shared @Observable scratchpad. Coarse fields mirror back here; the
    /// live per-frame offset stays in plain UIKit state (spec 05 section 7).
    var dragState: EventDragState? = nil

    // Outputs (spec 05 section 2). Same closures the SwiftUI path fires.
    var onEventTap: ((Event, Date) -> Void)? = nil
    var onEventLongPressBegan: ((CalendarEventLongPressBegan) -> Void)? = nil
    var onEventManipulationPromotion: ((Event, String?, Date, EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onEventLongPressResolved: ((CalendarEventLongPressResolution) -> Void)? = nil
    var onEventDragEnded: ((Event, String?, Event.TimeRange, DragOffset, CGFloat) -> Void)? = nil
    var onEventResizeEnded: ((Event, String?, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)? = nil
    var onCreateEvent: ((Event.TimeRange) -> Void)? = nil
    var onCreationPreviewChanged: ((Date, Event.TimeRange?) -> Void)? = nil
    var onNonEventTap: (() -> Void)? = nil
    var onHorizontalBoundaryPageRequest: ((Int) -> Bool)? = nil
    var onVisibleTimelineFrameChange: ((CGRect) -> Void)? = nil

    func makeUIView(context: Context) -> DayLayerHostView {
        let view = DayLayerHostView()
        view.backgroundColor = .clear
        view.apply(makeModel(), callbacks: makeCallbacks())
        return view
    }

    func updateUIView(_ uiView: DayLayerHostView, context: Context) {
        uiView.apply(makeModel(), callbacks: makeCallbacks())
    }

    private func makeCallbacks() -> DayLayerHostView.Callbacks {
        DayLayerHostView.Callbacks(
            dragState: dragState,
            onEventTap: onEventTap,
            onEventLongPressBegan: onEventLongPressBegan,
            onEventManipulationPromotion: onEventManipulationPromotion,
            onEventLongPressResolved: onEventLongPressResolved,
            onEventDragEnded: onEventDragEnded,
            onEventResizeEnded: onEventResizeEnded,
            onCreateEvent: onCreateEvent,
            onCreationPreviewChanged: onCreationPreviewChanged,
            onNonEventTap: onNonEventTap,
            onHorizontalBoundaryPageRequest: onHorizontalBoundaryPageRequest,
            onVisibleTimelineFrameChange: onVisibleTimelineFrameChange
        )
    }

    private func makeModel() -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: date,
            occurrences: occurrences,
            contentWidth: contentWidth,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            eventHorizontalInset: eventHorizontalInset,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours,
            showEventText: showEventText,
            isWeekMode: isWeekMode,
            isThreeDayMode: isThreeDayMode,
            titleFontSizeSetting: titleFontSizeSetting,
            showTimeBelowTitle: showTimeBelowTitle,
            multiTypeEnabled: multiTypeEnabled,
            nearFutureHorizonDays: nearFutureHorizonDays,
            isPinchActive: isPinchActive,
            frozenSlotMinutes: frozenSlotMinutes,
            dayColumnStep: dayColumnStep,
            dragPreviewDayStep: dragPreviewDayStep,
            creationPreviewRange: creationPreviewRange,
            focusedEventID: focusedEventID,
            focusedOccurrenceID: focusedOccurrenceID,
            graceResizeEventID: graceResizeEventID,
            graceResizeOccurrenceID: graceResizeOccurrenceID,
            graceResizeHandleOpacity: graceResizeHandleOpacity,
            isFocusContextActive: isFocusContextActive,
            recentlyAbsorbedEventIDs: recentlyAbsorbedEventIDs
        )
    }
}

// MARK: - Persistent host UIView

/// Persistent per-day `UIView` that owns a root CALayer plus a pool of
/// per-occurrence layer subtrees. Persistence (vs a fresh view each rebuild)
/// is the foundation later slices build on: gesture/coordinator state and a
/// single transaction owner per day live here (spec 06).
final class DayLayerHostView: UIView {

    /// Immutable per-render inputs. `Equatable` so a no-op `updateUIView` can
    /// short-circuit without touching the layer tree.
    struct Model: Equatable {
        let date: Date
        let occurrences: [CalendarLayout.EventOccurrence]
        let contentWidth: CGFloat
        let headerHeight: CGFloat
        let hourHeight: CGFloat
        let eventHorizontalInset: CGFloat
        let leadingExtendedHours: Int
        let trailingExtendedHours: Int
        let showEventText: Bool
        let isWeekMode: Bool
        let isThreeDayMode: Bool
        let titleFontSizeSetting: Double
        let showTimeBelowTitle: Bool
        let multiTypeEnabled: Bool
        let nearFutureHorizonDays: Int
        let isPinchActive: Bool
        let frozenSlotMinutes: Int?
        // S4 gesture / live-state fields. These do NOT participate in the
        // StructureKey (they don't change overlap topology), but changing
        // them must still re-render (focus dim, drag preview, grace handles).
        var dayColumnStep: CGFloat = 0
        var dragPreviewDayStep: CGFloat = 0
        var creationPreviewRange: Event.TimeRange? = nil
        var focusedEventID: UUID? = nil
        var focusedOccurrenceID: String? = nil
        var graceResizeEventID: UUID? = nil
        var graceResizeOccurrenceID: String? = nil
        var graceResizeHandleOpacity: Double = 1
        var isFocusContextActive: Bool = false
        /// Event ids the host currently considers "recently absorbed into"
        /// (mirror of `TimelineView.recentlyAbsorbedParents`, fed per-block to
        /// `EventBlock.isRecentlyAbsorbedInto`). A NEW id entering this set is
        /// the §4 absorption-pulse trigger; the day view detects the edge and
        /// fires the pulse on that occurrence's container (spec 04 §4).
        var recentlyAbsorbedEventIDs: Set<UUID> = []

        /// True when two Models share the same non-structural VISUAL state
        /// (focus, grace, creation preview). Used to keep the S3 cheap-pinch
        /// path: a pinch frame changes only `hourHeight` (not in StructureKey,
        /// not here), so this stays true and the cheap repaint runs; a focus
        /// or grace toggle flips it false and forces a full visual refresh.
        static func visualStateEqual(_ a: Model, _ b: Model) -> Bool {
            a.focusedEventID == b.focusedEventID
                && a.focusedOccurrenceID == b.focusedOccurrenceID
                && a.graceResizeEventID == b.graceResizeEventID
                && a.graceResizeOccurrenceID == b.graceResizeOccurrenceID
                && a.graceResizeHandleOpacity == b.graceResizeHandleOpacity
                && a.isFocusContextActive == b.isFocusContextActive
                && a.creationPreviewRange == b.creationPreviewRange
                && a.dayColumnStep == b.dayColumnStep
                && a.dragPreviewDayStep == b.dragPreviewDayStep
                && a.recentlyAbsorbedEventIDs == b.recentlyAbsorbedEventIDs
        }

        /// Structural identity of everything that affects overlap topology +
        /// horizontal placement + which layers exist + text CONTENT (but NOT
        /// the vertical scale). When this is unchanged between two Models, the
        /// only thing that moved is the vertical geometry (hourHeight + derived
        /// header/contentHeight/scroll), so the layer tree can be repainted
        /// CHEAPLY: reuse the cached overlap result + horizontal placement and
        /// touch only each event's vertical frame, the grid, the now-line, and
        /// the future-zone / horizon Y. Overlap topology depends only on
        /// time-overlap — not on hourHeight — so a per-frame recompute during a
        /// pinch is pure waste (S3 perf milestone).
        struct StructureKey: Equatable {
            let occurrenceIDs: [String]
            let occurrenceStamps: [String]   // per-occurrence range + identity stamp
            let contentWidth: CGFloat
            let eventHorizontalInset: CGFloat
            let leadingExtendedHours: Int
            let trailingExtendedHours: Int
            let showEventText: Bool
            let isWeekMode: Bool
            let isThreeDayMode: Bool
            let titleFontSizeSetting: Double
            let showTimeBelowTitle: Bool
            let multiTypeEnabled: Bool
            let date: Date
        }

        var structureKey: StructureKey {
            StructureKey(
                occurrenceIDs: occurrences.map(\.id),
                occurrenceStamps: occurrences.map { occ in
                    // Identity + time range + visual-gate-affecting fields. Any
                    // change here means the layer content (not just its Y/height)
                    // must be rebuilt, so we fall back to a full render.
                    let e = occ.event
                    return [
                        occ.id,
                        String(occ.range.start.timeIntervalSinceReferenceDate),
                        String(occ.range.end.timeIntervalSinceReferenceDate),
                        e.title,
                        String(e.colorDepth),
                        e.kind.rawValue,
                        e.isDone ? "1" : "0",
                        e.isInterrupt ? "1" : "0",
                        e.interruptRelation.map { "\($0.parentEventID):\($0.state.rawValue)" } ?? "",
                        e.timerStartedAt != nil ? "1" : "0",
                        e.agenticIntake?.processingPhase.rawValue ?? "",
                        e.deadline.map { String($0.timeIntervalSinceReferenceDate) } ?? ""
                    ].joined(separator: "|")
                },
                contentWidth: contentWidth,
                eventHorizontalInset: eventHorizontalInset,
                leadingExtendedHours: leadingExtendedHours,
                trailingExtendedHours: trailingExtendedHours,
                showEventText: showEventText,
                isWeekMode: isWeekMode,
                isThreeDayMode: isThreeDayMode,
                titleFontSizeSetting: titleFontSizeSetting,
                showTimeBelowTitle: showTimeBelowTitle,
                multiTypeEnabled: multiTypeEnabled,
                date: date
            )
        }
    }

    // MARK: Layer pool

    /// One reusable subtree per occurrence id.
    ///
    /// Mask boundary (spec 01 §0): `maskedContent` carries the silhouette mask
    /// and holds everything that must be clipped to the block shape (bg fill,
    /// hatch, agentic gradient, multi-type triangle, text). The border / todo
    /// border / effort bar / resize handles / spinner are direct children of
    /// `container` so they are applied AFTER the mask and NOT clipped.
    private final class EventLayers {
        let container = CALayer()           // post-mask composite (shadow + dim live here)
        let maskedContent = CALayer()       // everything clipped by `silhouetteMask`
        let silhouetteMask = CAShapeLayer() // white-fill alpha clip
        let bg = CAShapeLayer()             // background fill (under mask)
        let hatch = CAShapeLayer()          // diagonal hatch (timer active)
        let agenticGradient = CAGradientLayer() // agentic shimmer (static)
        let triangle = CAShapeLayer()       // multi-type corner triangle
        let title = CATextLayer()
        let subtitle = CATextLayer()        // multi-type subtitle
        let time = CATextLayer()
        let border = CAShapeLayer()         // centered stroke (post-mask)
        let effortBar = CAShapeLayer()      // left effort bar (post-mask, own clip)
        let todoBorder = CAShapeLayer()     // inset stroke (post-mask)
        let dropTargetRing = CAShapeLayer() // §5 accent INSET stroke (post-mask)
        let topHandle = CAShapeLayer()
        let bottomHandle = CAShapeLayer()
        let spinnerBacking = CAShapeLayer() // ultraThinMaterial-ish circle
        let spinner = CAShapeLayer()        // circular indeterminate ring (static)

        // MARK: Animation transition memory (S5)
        // Per-occurrence "last applied" state so `applyInteractionState` (which
        // runs every render frame, including pinch / drag frames) can detect a
        // STATE TRANSITION and fire a scoped CA animation only on the edge —
        // never per frame. Mirrors how SwiftUI's `withAnimation`/`.animation(
        // value:)` fire only when the keyed value flips.
        var hasAppliedAnimState = false
        var lastInDragState = false          // §3 shadow + focus-dim easeInOut 0.15
        var lastDropTarget = false           // §5 drop-target highlight easeInOut 0.15
        var lastResizing = false             // §13 resize emphasis easeOut 0.2
        var lastRecentlyAbsorbed = false     // §4 absorption-pulse edge trigger
        var lastDoneFade: Float = 1          // done/deferred fade easeInOut 0.4 edge
        // §13 DEFERRED done-fade (EventBlock `displayedDoneState`): the visible
        // fade lags the real `event.isDone` until the block (re)appears. `nil`
        // until the first sync (mirrors EventBlock's `@State displayedDoneState:
        // Bool?`); thereafter holds the done value we've actually SHOWN. The
        // opacity (`lastDoneFade`) is derived from THIS, not `event.isDone`
        // directly, so a todo flipped done while the block is parked off-screen
        // (e.g. behind a detail sheet) fades on RE-APPEARANCE, not silently.
        var displayedDoneState: Bool? = nil
        // True when this subtree was just (re)acquired (fresh alloc OR pulled
        // from the free pool) and has not yet had `applyInteractionState` run.
        // Mirrors EventBlock's `.onAppear`: the first `applyInteractionState`
        // after an (re)appear SYNCS `displayedDoneState` to the real `isDone`,
        // animating the fade if it had drifted while parked. Cleared after that
        // first apply so subsequent in-place renders don't re-trigger an appear.
        var didJustAppear = true
        var lastGraceFadeArmed = false       // §14 grace-handle linear 0.35 (delayed)
        var lastBlockX: CGFloat = .nan       // §1 overlap reflow spring
        var lastBlockY: CGFloat = .nan
        var lastBlockW: CGFloat = .nan
        var lastBlockH: CGFloat = .nan
        /// Composed drop-target scale factor currently presented (1.0 or 1.03).
        /// Multiplied into the single `transform.scale` alongside the pulse.
        var dropTargetScale: CGFloat = 1.0
        /// Pulse scale currently presented (1.0 normally, transient 1.08→1.0).
        var pulseScale: CGFloat = 1.0
        /// Pending pulse settle work item (the 0.12s-delayed spring-back leg).
        var pulseSettleWork: DispatchWorkItem?

        // MARK: Text-layout memoization (issue #14 perf)
        //
        // The expensive part of `configureText` is the text WRAPPING /
        // line-count / `boundingRect` measurement, which depends ONLY on the
        // block's WIDTH, the title string, the font size, the style
        // (showTimeRange / showTimeBelowTitle), and the mode (week / 3-day /
        // multiType subtitle) — NOT on the block's rendered HEIGHT. During a
        // pinch only `hourHeight` (and thus the block's height) changes, so
        // these inputs are constant frame-to-frame and the measurement is pure
        // waste. We cache the inputs in `lastTextLayoutKey`; when an incoming
        // `configureText` carries the same key we reuse `cachedNaturalTitleHeight`
        // (the unbounded wrapped title height) and skip the measurement. The
        // HEIGHT-dependent visibility GATES (needsCenter / titleLineLimit /
        // showsTimeRange / contentRect.height) are recomputed every frame —
        // they are O(1) comparisons, not measurements — so the exact same text
        // is shown at the exact same heights as before.
        struct TextLayoutKey: Equatable {
            let title: String
            let contentWidth: CGFloat        // block width feeding the text fit
            let titleFontSize: CGFloat
            let styleShowTimeRange: Bool
            let showTimeBelowTitle: Bool
            let isWeekMode: Bool
            let isThreeDayMode: Bool
            let showsMultiType: Bool
            let subtitleText: String
        }
        var lastTextLayoutKey: TextLayoutKey?
        /// The unbounded natural wrapped title height for the cached key
        /// (height-independent). Reused while the key is unchanged.
        var cachedNaturalTitleHeight: CGFloat = 0

        init() {
            // Order under the mask (bottom → top, spec 01 §0 steps 3-6 + text):
            maskedContent.addSublayer(bg)
            maskedContent.addSublayer(hatch)
            maskedContent.addSublayer(agenticGradient)
            maskedContent.addSublayer(triangle)
            maskedContent.addSublayer(title)
            maskedContent.addSublayer(subtitle)
            maskedContent.addSublayer(time)
            maskedContent.mask = silhouetteMask

            // Post-mask order (bottom → top, spec 01 §0 steps 8-11):
            container.addSublayer(maskedContent)
            container.addSublayer(border)      // §2 + §10 effort bar lives in border overlay
            container.addSublayer(effortBar)
            container.addSublayer(todoBorder)  // §4
            container.addSublayer(dropTargetRing) // §5 (above borders)
            container.addSublayer(topHandle)   // §11
            container.addSublayer(bottomHandle)
            container.addSublayer(spinnerBacking) // §7b
            container.addSublayer(spinner)
            dropTargetRing.isHidden = true

            for shape in [bg, hatch, triangle, border, effortBar, todoBorder, dropTargetRing,
                          topHandle, bottomHandle, spinnerBacking, spinner, silhouetteMask] {
                shape.fillColor = UIColor.clear.cgColor
                // CAShapeLayer defaults to contentsScale 1.0 → vector paths
                // (esp. the rounded corners + the silhouette clip) rasterize at
                // 1x and look jagged/burred on retina. Render at screen scale.
                shape.contentsScale = UIScreen.main.scale
            }
            // The mask + its host composite must also be at screen scale, else
            // the clip edge re-aliases the crisp sublayers.
            maskedContent.contentsScale = UIScreen.main.scale
            container.contentsScale = UIScreen.main.scale
            agenticGradient.contentsScale = UIScreen.main.scale
            silhouetteMask.fillColor = UIColor.white.cgColor

            for text in [title, subtitle, time] {
                text.contentsScale = UIScreen.main.scale
                text.isWrapped = true
                text.truncationMode = .end
                text.alignmentMode = .left
            }
        }

        /// Reset all S5 animation transition memory + presented transform so a
        /// recycled subtree re-entering the viewport (S6) appears INSTANTLY at
        /// its target state instead of spuriously firing entry tweens (it is
        /// not "newly absorbed" / "newly dragged" — just scrolled back into
        /// view). `hasAppliedAnimState = false` makes the next
        /// `applyInteractionState` treat it as a `firstApply` (write targets,
        /// no animation); the `last*` flags are zeroed so no edge appears to
        /// have flipped, and the live transform / scale state is cleared so a
        /// stale pulse / drop-target scale doesn't carry over to a new id.
        func resetAnimationState() {
            pulseSettleWork?.cancel()
            pulseSettleWork = nil
            container.removeAllAnimations()
            maskedContent.removeAllAnimations()
            border.removeAllAnimations()
            topHandle.removeAllAnimations()
            bottomHandle.removeAllAnimations()
            hasAppliedAnimState = false
            lastInDragState = false
            lastDropTarget = false
            lastResizing = false
            lastRecentlyAbsorbed = false
            lastDoneFade = 1
            // DEFERRED done-fade: a recycle→re-acquire (scroll/zoom back into
            // the buffer, or a re-attach) is an APPEAR. We deliberately do NOT
            // clear `displayedDoneState` here — preserving the last-shown done
            // value lets the next `applyInteractionState` detect whether
            // `event.isDone` drifted while the subtree was parked and animate
            // the fade on re-appearance (the EventBlock `displayedDoneState`
            // contract), while a no-drift re-entry stays a silent snap (no
            // spurious fade pop on plain scroll-back).
            didJustAppear = true
            lastGraceFadeArmed = false
            lastBlockX = .nan
            lastBlockY = .nan
            lastBlockW = .nan
            lastBlockH = .nan
            dropTargetScale = 1.0
            pulseScale = 1.0
            container.transform = CATransform3DIdentity
            // A recycled subtree re-renders a (possibly) different occurrence;
            // drop the text-measure memo so the new title re-measures once. (The
            // key already includes the title, so a stale key would miss anyway —
            // this just makes the invalidation explicit on re-acquire.)
            lastTextLayoutKey = nil
            cachedNaturalTitleHeight = 0
        }
    }

    private var pool: [String: EventLayers] = [:]
    private var currentModel: Model?

    /// Agentic-spinner blur backings (spec 01 §7b). A `CALayer` cannot blur, so
    /// the ultraThinMaterial backing behind each analyzing event's spinner is a
    /// real `UIVisualEffectView` hosted as a subview, keyed by occurrence id.
    /// Created lazily only for analyzing events (transient) and torn down when
    /// the event stops analyzing / is recycled, so the common case adds no
    /// UIView overhead. Positioned in the host's coordinate space to sit behind
    /// the spinner ring (which stays a `CAShapeLayer`).
    private var spinnerBlurViews: [String: UIVisualEffectView] = [:]

    /// FIX 1: occurrence ids of the embedded interrupt children whose PARENT is
    /// the actively-dragged occurrence. Single source of truth, recomputed once
    /// per `render(_:)` (where the `InterruptContext` is available) and read by
    /// the source-day overlap filter and by `applyInteractionState`
    /// (`chipHidesSource`) — those run AFTER `render` populates this, so the
    /// children leave the parent's overlap AND hide with the parent for the drag
    /// duration. Empty when the dragged event is not an interrupt parent.
    private var draggedInterruptChildIDs: Set<String> = []

    // MARK: Gestures (S4)

    /// Closures + shared scratchpad the gesture layer fires/mirrors into.
    /// Re-supplied on every `apply` (matching `EventBlock`'s coordinator
    /// re-injection in `updateUIView`). `dragState` mirror is COARSE-field
    /// only (spec 05 section 7).
    struct Callbacks {
        var dragState: EventDragState?
        var onEventTap: ((Event, Date) -> Void)?
        var onEventLongPressBegan: ((CalendarEventLongPressBegan) -> Void)?
        var onEventManipulationPromotion: ((Event, String?, Date, EventDragMode, CGPoint, CGRect) -> Void)?
        var onEventLongPressResolved: ((CalendarEventLongPressResolution) -> Void)?
        var onEventDragEnded: ((Event, String?, Event.TimeRange, DragOffset, CGFloat) -> Void)?
        var onEventResizeEnded: ((Event, String?, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void)?
        var onCreateEvent: ((Event.TimeRange) -> Void)?
        var onCreationPreviewChanged: ((Date, Event.TimeRange?) -> Void)?
        var onNonEventTap: (() -> Void)?
        var onHorizontalBoundaryPageRequest: ((Int) -> Bool)?
        var onVisibleTimelineFrameChange: ((CGRect) -> Void)?
    }

    /// Owns the move/resize + drag-to-create state machines. Plain UIKit
    /// object whose lifetime is the host view's — survives content rebuilds
    /// natively (spec 06 G-79..81; this is WHY the day view is persistent).
    private(set) lazy var gestureController = CalendarDayGestureController(host: self)

    /// Live drag preview block (separate from the pooled event layers so the
    /// dragged occurrence's own layer can be hidden while this floats). Sits
    /// above events, below the now-line. Reused for drag-to-create too.
    private let creationPreviewLayer = CAShapeLayer()
    private let creationPreviewBorder = CAShapeLayer()
    private let creationPreviewText = CATextLayer()
    private lazy var previewLayersInstalled: Bool = {
        creationPreviewLayer.zPosition = 90
        creationPreviewBorder.zPosition = 90
        creationPreviewText.zPosition = 91
        creationPreviewLayer.fillColor = UIColor.clear.cgColor
        creationPreviewBorder.fillColor = UIColor.clear.cgColor
        creationPreviewLayer.contentsScale = UIScreen.main.scale
        creationPreviewBorder.contentsScale = UIScreen.main.scale
        creationPreviewText.contentsScale = UIScreen.main.scale
        creationPreviewText.alignmentMode = .left
        creationPreviewText.isWrapped = false
        creationPreviewText.truncationMode = .end
        layer.addSublayer(creationPreviewLayer)
        layer.addSublayer(creationPreviewBorder)
        layer.addSublayer(creationPreviewText)
        for l in [creationPreviewLayer, creationPreviewBorder] { l.isHidden = true }
        creationPreviewText.isHidden = true
        return true
    }()

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        gestureController.installGestures(on: self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        gestureController.installGestures(on: self)
    }

    deinit {
        nowLineTimer?.invalidate()
        detachScrollObserver()
    }

    // MARK: Viewport virtualization (S6)
    //
    // Per-frame render cost is made ∝ ON-SCREEN event count (not total events
    // in the day) by only instantiating / updating `EventLayers` for
    // occurrences whose vertical frame intersects the visible scroll rect plus
    // a ~1-viewport buffer above/below. Occurrences fully outside the buffer
    // have their pooled subtree removed and parked in a reuse pool (`freePool`)
    // so a later re-entry reuses an allocated subtree instead of building one.
    //
    // ZERO visual change: an occurrence on (or near) screen renders byte-for-
    // byte as before — culling only drops layers that are off-screen and
    // therefore invisible. The chrome (grid / now-line / future-zone / horizon)
    // is cheap and NOT per-event, so it always renders full-height.

    /// The enclosing vertical scroll view (walked up the superview chain, like
    /// the gesture controller's `findScrollTargets`). Weak — the scroll view
    /// owns us, not the reverse. KVO on its `contentOffset` / `bounds` triggers
    /// a re-cull as the user scrolls.
    private weak var observedScrollView: UIScrollView?
    private var scrollOffsetObservation: NSKeyValueObservation?
    private var scrollBoundsObservation: NSKeyValueObservation?
    /// The buffered visible rect (this view's coordinate space) used by the
    /// last cull pass. Tracked so a scroll that doesn't move the rect enough to
    /// change the visible set can early-out without a relayout.
    private var lastCullVisibleRect: CGRect = .null
    /// Reuse pool of detached `EventLayers` subtrees (parked off-superlayer)
    /// keyed by the occurrence id they last rendered. Re-entry reuses by id
    /// when possible (keeps text/decoration warm), else any free subtree.
    private var freePool: [String: EventLayers] = [:]
    /// Hard cap on parked subtrees so a huge day doesn't retain an unbounded
    /// number of recycled layer trees.
    private let freePoolCapacity = 24

    /// Re-attach a KVO observer to the current enclosing vertical scroll view.
    /// Idempotent: re-resolves the scroll view (it can change as the view moves
    /// between windows / pager rebuilds) and only rewires if it differs.
    private func attachScrollObserverIfNeeded() {
        let resolved = enclosingVerticalScrollView()
        guard resolved !== observedScrollView else { return }
        detachScrollObserver()
        observedScrollView = resolved
        guard let sv = resolved else { return }
        // `.contentOffset` fires every scroll frame; recompute the buffered
        // visible rect and re-cull only if the visible SET would change. This
        // is the least-invasive scroll hook — it neither installs a delegate
        // (which the pager/pinch coordinator may own) nor a display link, and
        // KVO callbacks land on the main thread for a main-thread scroll view.
        scrollOffsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.cullViewportIfChanged()
        }
        // Bounds size changes (rotation / split-view) also move the visible rect.
        scrollBoundsObservation = sv.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.cullViewportIfChanged()
        }
    }

    private func detachScrollObserver() {
        scrollOffsetObservation = nil
        scrollBoundsObservation = nil
        observedScrollView = nil
    }

    /// Walk the superview chain for the nearest vertically-scrollable
    /// `UIScrollView` (mirrors `CalendarDayGestureController.findScrollTargets`'s
    /// vertical leg). The CALayer day view sits inside the timeline's vertical
    /// `ScrollView`.
    private func enclosingVerticalScrollView() -> UIScrollView? {
        var current: UIView? = superview
        while let candidate = current {
            if let sv = candidate as? UIScrollView,
               sv.contentSize.height - sv.bounds.height > 1 {
                return sv
            }
            current = candidate.superview
        }
        return nil
    }

    /// The buffered visible rect in THIS view's coordinate space: the scroll
    /// view's visible bounds converted into our coordinates, then expanded by
    /// one viewport height above and below so an event just off-screen is kept
    /// alive for smooth scrolling (no pop-in). Returns `nil` (= "show all", the
    /// pre-S6 behavior) when no scroll view is found yet (e.g. before the view
    /// is in the hierarchy, or in a non-scrolling test harness) so correctness
    /// never depends on culling having a viewport.
    private func bufferedVisibleRect() -> CGRect? {
        guard let sv = observedScrollView ?? enclosingVerticalScrollView() else { return nil }
        // Until the scroll view has a real height — e.g. the first render after a
        // view-mode switch (day↔3-day↔week), before its layout settles — a
        // degenerate `bounds.height` (~0) would make `buffer` ~0 and collapse the
        // visible rect to a thin sliver, culling every event (chrome still renders
        // since it isn't culled → "grid shows, events don't"). Fall back to "show
        // all" until it's sized; the bounds/offset KVO re-culls once it settles.
        guard sv.bounds.height > 1 else { return nil }
        // The scroll view's currently-visible content region, in its own coords,
        // converted into ours. `bounds` already reflects `contentOffset`.
        //
        // S6 is a VERTICAL-only optimization: we cull events whose Y range is
        // outside the scrolled viewport (plus a buffer above/below). We must NOT
        // let the X axis participate — `sv.convert(_:to:)` carries the column's
        // HORIZONTAL offset inside the scroll view, so in multi-day (week / 3-day)
        // mode the converted rect's `minX` is the column's distance from the
        // scroll origin (e.g. −556 for a column 556pt to the right), which does
        // NOT overlap the column-local event X (≈ [4, columnWidth]). A 2D
        // `intersects` then culls every event on the first render (chrome still
        // renders since it isn't culled → "grid shows, events don't"); a later
        // scroll re-culls with the same broken X and only appears to fix it once
        // layout settles. Day view escapes only because its single column sits at
        // x≈0 so the converted X happens to overlap. We keep the rect's Y here and
        // let `isWithinViewport` test the Y axis ONLY, so the bogus X is ignored.
        let visibleInSelf = sv.convert(sv.bounds, to: self)
        let buffer = sv.bounds.height
        return visibleInSelf.insetBy(dx: 0, dy: -buffer)
    }

    /// True iff `frame` (this view's coords) should keep a live layer subtree:
    /// its VERTICAL range overlaps the buffered visible rect. A `nil` rect
    /// ("show all") keeps everything (pre-S6 parity / no-viewport fallback).
    ///
    /// S6 is a vertical-only optimization, so we deliberately test only the Y
    /// axis. The buffered rect comes from `sv.convert(sv.bounds, to: self)`,
    /// whose X carries the column's horizontal offset inside the scroll view; in
    /// multi-day (week / 3-day) mode that X never overlaps the column-local event
    /// X, so a 2D `intersects` would cull every event (the missing-blocks bug).
    /// Testing Y overlap only is both the correct culling axis and immune to the
    /// column's horizontal placement.
    private func isWithinViewport(_ frame: CGRect, visibleRect: CGRect?) -> Bool {
        guard let visibleRect else { return true }
        return frame.maxY > visibleRect.minY && frame.minY < visibleRect.maxY
    }

    /// Called on every scroll frame (via KVO). Recomputes the buffered visible
    /// rect; if the visible SET could have changed (the rect moved beyond a
    /// small threshold), re-runs the cull. Cheap when nothing changed.
    private func cullViewportIfChanged() {
        guard currentModel != nil else { return }
        guard let newRect = bufferedVisibleRect() else { return }
        // Skip if the rect barely moved — the visible set only changes once the
        // rect crosses an event edge, and the buffer absorbs sub-pixel jitter.
        // A 1pt threshold keeps the common scroll frame a no-op while still
        // re-culling well before a buffered-but-hidden event reaches the screen.
        if !lastCullVisibleRect.isNull,
           abs(newRect.minY - lastCullVisibleRect.minY) < 1,
           abs(newRect.maxY - lastCullVisibleRect.maxY) < 1 {
            return
        }
        cullViewport(visibleRect: newRect)
    }

    /// MARK: Now-line periodic refresh (S5 §12)

    /// 1-second repeating timer that re-derives the now-line / dot / horizon Y
    /// and repaints chrome — the discrete 1s-cadence reposition the SwiftUI
    /// `TimelineView(.periodic(by: 1))` produces. NOT a tween (each tick is an
    /// instant jump inside `setDisableActions(true)`); a 1s timer matches the
    /// cadence without the per-frame waste of a CADisplayLink (spec 04 §12).
    private var nowLineTimer: Timer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startNowLineTimerIfNeeded()
            // The enclosing scroll view is only resolvable once we're in the
            // hierarchy; (re)attach the scroll observer that drives S6 re-cull.
            attachScrollObserverIfNeeded()
        } else {
            nowLineTimer?.invalidate()
            nowLineTimer = nil
            detachScrollObserver()
            // Tear down any hosted agentic-spinner blur backings (FIX 4):
            // `removeSpinnerBlur` is called on stop-analyzing and on recycle,
            // but a window-detach (column parked by the pager) doesn't recycle
            // its in-viewport subtrees — so without this a parked column would
            // retain live `UIVisualEffectView` subviews. Recreated on re-attach
            // by the next render of a still-analyzing event (lazy in
            // `spinnerBlurView(for:)`), consistent with the timer/link teardown.
            removeAllSpinnerBlurViews()
            // Stop both gesture-controller display links (auto-scroll + creation
            // auto-scroll) and cleanly cancel any in-flight drag/creation. The
            // links retain the controller as their `target:`; if the pager
            // recycles this column or SwiftUI detaches us mid-drag, an
            // unstopped link would keep the controller — and transitively this
            // host — alive forever, so `deinit` would never run. Tearing them
            // down on window-detach closes that leak (the now-line timer + KVO
            // were already torn down above). Idempotent: safe if no drag is live.
            gestureController.cancelActiveInteractionsOnDetach()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        // The pager can re-parent the day column; re-resolve the scroll view so
        // S6 culling keeps tracking the correct viewport.
        if window != nil { attachScrollObserverIfNeeded() }
    }

    private func startNowLineTimerIfNeeded() {
        guard nowLineTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let model = self.currentModel else { return }
            // Only the today column owns a live now-line; skip the work
            // otherwise (the horizon line is also time-derived but moves at a
            // day cadence, so a 1s refresh harmlessly keeps it exact too).
            guard Calendar.current.isDateInToday(model.date)
                || EventZone.horizonDate(
                    from: model.nearFutureHorizonDays, now: Date(), calendar: .current
                ) >= Calendar.current.startOfDay(for: model.date) else { return }
            let contentHeight = calendarTimelineContentHeight(
                hourHeight: model.hourHeight,
                leadingExtendedHours: model.leadingExtendedHours,
                trailingExtendedHours: model.trailingExtendedHours
            )
            let visibleStart = calendarTimelineVisibleStart(
                containing: model.date, leadingExtendedHours: model.leadingExtendedHours
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.renderChrome(model: model, contentHeight: contentHeight, visibleStart: visibleStart)
            CATransaction.commit()
        }
        // Tolerance lets the OS coalesce the tick (battery; cadence parity is
        // ~1s, not exact-frame).
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        nowLineTimer = timer
    }

    /// Latest full-render snapshot the gesture controller reads to hit-test
    /// (move/resize mode resolution, absorption spatial test). Rebuilt each
    /// full `render`; the cheap vertical path refreshes only the Y/height.
    struct RenderedEventFrame {
        let occurrence: CalendarLayout.EventOccurrence
        var frame: CGRect            // event-area-local (this view's coords)
        let slot: CalendarLayout.EventOverlapSlot
        let isEmbeddedChild: Bool
    }
    private(set) var renderedFrames: [String: RenderedEventFrame] = [:]

    // MARK: Cheap-repaint cache (S3)

    /// Per-occurrence placement that is INVARIANT under a vertical-scale change
    /// (hourHeight). Cached during a full `render` and reused by the cheap
    /// vertical-only repaint path so a pinch frame never recomputes overlap
    /// topology or horizontal columns (the entire point of S3).
    private struct CachedPlacement {
        /// Horizontal frame (X + width) — depends only on overlap topology +
        /// content width, never on hourHeight.
        let blockX: CGFloat
        let blockWidth: CGFloat
        let zPosition: CGFloat
        /// Inputs the cheap path still needs to recompute the vertical frame +
        /// re-fit text + redraw the (height-dependent) silhouette / decorations.
        let occurrence: CalendarLayout.EventOccurrence
        let slot: CalendarLayout.EventOverlapSlot
        let isEmbeddedChild: Bool
    }

    /// The structure key of the last FULL render. When the incoming Model's
    /// key matches this, only vertical geometry changed → cheap repaint.
    private var cachedStructureKey: Model.StructureKey?
    /// Per-occurrence invariant placement from the last full render, keyed by id.
    private var cachedPlacements: [String: CachedPlacement] = [:]

    // MARK: Y-sorted cull index (issue #14 — sub-linear visible-set lookup)

    /// One entry per occurrence, sorted ascending by `start`. Built once per
    /// full `render` (when the occurrence set changes) and reused by every
    /// per-scroll / per-pinch cull so the visible-set DECISION is O(log N +
    /// visibleCount) instead of an O(N) scan of all occurrences.
    private struct CullIndexEntry {
        let id: String
        let start: Date
        let end: Date
    }
    /// Occurrences sorted by `start`. `start` ascending is the search axis.
    private var cullIndex: [CullIndexEntry] = []
    #if DEBUG
    /// TEST-ONLY: number of candidates the last cull DECISION examined (the
    /// binary-searched slice size, or the full count on the fallback path).
    /// Lets the benchmark assert the decision is sub-linear in total-N.
    private(set) var lastCullCandidateCount: Int = 0

    /// TEST-ONLY: directly invoke one cull pass against the current buffered
    /// rect (the same work a scroll-frame KVO would do), so a benchmark can
    /// time the cull DECISION in isolation from UIKit's `setContentOffset`
    /// bookkeeping. Returns false if there is nothing to cull against.
    @discardableResult
    func debugRunCullPass() -> Bool {
        guard let rect = bufferedVisibleRect() else { return false }
        cullViewport(visibleRect: rect)
        return true
    }

    /// TEST-ONLY: time only the candidate-DECISION (binary search + slice
    /// iteration) without the surrounding CATransaction, so the benchmark can
    /// attribute cost. Returns the decision time in ms.
    func debugTimeCullDecisionOnly() -> Double {
        guard let model = currentModel,
              let visibleRect = bufferedVisibleRect(),
              cachedStructureKey == model.structureKey else { return 0 }
        let contentHeight = calendarTimelineContentHeight(
            hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date, leadingExtendedHours: model.leadingExtendedHours
        )
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: model.date, trailingExtendedHours: model.trailingExtendedHours
        )
        let t0 = CACurrentMediaTime()
        let slice = cullCandidateSlice(
            visibleRect: visibleRect, model: model,
            contentHeight: contentHeight, visibleStart: visibleStart, visibleEnd: visibleEnd
        )
        var hits = 0
        if let slice {
            for entry in slice {
                guard let placement = cachedPlacements[entry.id] else { continue }
                let v = verticalFrame(for: placement.occurrence, model: model,
                                      contentHeight: contentHeight,
                                      visibleStart: visibleStart, visibleEnd: visibleEnd)
                let frame = CGRect(x: placement.blockX, y: v.y, width: placement.blockWidth, height: v.height)
                if isWithinViewport(frame, visibleRect: visibleRect) { hits += 1 }
            }
        }
        let t1 = CACurrentMediaTime()
        _ = hits
        return (t1 - t0) * 1000.0
    }
    #endif
    /// The longest occurrence duration in the day (seconds). Used to expand the
    /// lower search bound so a long event that STARTS before the viewport but
    /// EXTENDS into it is never missed by a start-keyed binary search.
    private var maxEventDurationSeconds: TimeInterval = 0

    /// Build the Y-sorted cull index + max-duration from the current occurrence
    /// set. Called from the full `render` (the only place the occurrence set can
    /// change). Sorting here makes the host self-sufficient — it does not rely on
    /// the producer's ordering — and the index is keyed on `start`, monotonic
    /// with each block's `frame.minY`.
    private func rebuildCullIndex(_ occurrences: [CalendarLayout.EventOccurrence]) {
        var maxDur: TimeInterval = 0
        var entries: [CullIndexEntry] = []
        entries.reserveCapacity(occurrences.count)
        for occ in occurrences {
            entries.append(CullIndexEntry(id: occ.id, start: occ.range.start, end: occ.range.end))
            maxDur = max(maxDur, occ.range.end.timeIntervalSince(occ.range.start))
        }
        entries.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
        cullIndex = entries
        maxEventDurationSeconds = maxDur
    }

    /// The candidate id-set whose blocks COULD overlap `visibleRect` (this
    /// view's coords), found via binary search on the start-sorted `cullIndex`
    /// in O(log N + candidateCount). Returns `nil` to mean "no index / show all"
    /// (the caller then falls back to scanning every occurrence — pre-issue-#14
    /// behavior / correctness fallback).
    ///
    /// Correctness (no overlapping/long event dropped):
    ///  • UPPER bound — a block whose `start` maps to a Y at/after `visibleRect.maxY`
    ///    cannot overlap (minY monotonic in start). We map `visibleRect.maxY`
    ///    back to a time and take all entries with `start < that time`, plus a
    ///    one-entry safety margin.
    ///  • LOWER bound — a long event can start well before the window yet extend
    ///    into it. We map `visibleRect.minY` back to a time, subtract
    ///    `maxEventDurationSeconds`, and binary-search that LOWERED time: any
    ///    event starting before it ends before the window even at max duration.
    ///  • The returned slice is a SUPERSET of the true visible set; the caller
    ///    still applies the EXACT `verticalFrame` + `isWithinViewport` predicate,
    ///    so the final culling result is byte-for-byte identical to the O(N) scan.
    private func cullCandidateIDs(
        visibleRect: CGRect,
        model: Model,
        contentHeight: CGFloat,
        visibleStart: Date,
        visibleEnd: Date
    ) -> Set<String>? {
        guard !cullIndex.isEmpty else { return nil }
        // Map the viewport Y window back to time. `dateFromYPosition` inverts the
        // same fraction mapping `verticalFrame` uses for `blockY`. A generous
        // ±1 entry / buffer is added below so rounding never clips an edge block.
        func timeAtY(_ y: CGFloat) -> Date {
            calendarTimelineDateFromYPosition(
                y,
                containing: model.date,
                headerHeight: model.headerHeight,
                hourHeight: model.hourHeight,
                leadingExtendedHours: model.leadingExtendedHours,
                trailingExtendedHours: model.trailingExtendedHours,
                snapMinutes: 0
            )
        }
        let windowTopTime = timeAtY(visibleRect.minY)
        let windowBottomTime = timeAtY(visibleRect.maxY)

        // LOWER bound: first entry that could still reach the window. Any event
        // starting before (windowTop − maxDuration) ends before windowTop.
        let lowerTime = windowTopTime.addingTimeInterval(-maxEventDurationSeconds)
        var lo = lowerBoundByStart(lowerTime)
        // Safety margin: step back one so a boundary-equal start is included.
        if lo > 0 { lo -= 1 }

        // UPPER bound: first entry whose start maps at/after the window bottom.
        // upperBoundByStart returns the count of entries with start <= windowBottom;
        // include one extra for rounding safety.
        var hi = upperBoundByStart(windowBottomTime)
        if hi < cullIndex.count { hi += 1 }

        guard lo < hi else { return [] }
        var ids = Set<String>()
        ids.reserveCapacity(hi - lo)
        for i in lo..<hi { ids.insert(cullIndex[i].id) }
        return ids
    }

    /// The candidate occurrence ids (a contiguous slice of the start-sorted
    /// index) whose blocks COULD overlap `visibleRect`. Same binary-search
    /// bounds as `cullCandidateIDs` but returns the ORDERED slice so the cull
    /// loop can iterate just the candidates — O(log N + candidateCount) — rather
    /// than scanning all N. `nil` → no index → caller scans all (fallback).
    private func cullCandidateSlice(
        visibleRect: CGRect,
        model: Model,
        contentHeight: CGFloat,
        visibleStart: Date,
        visibleEnd: Date
    ) -> ArraySlice<CullIndexEntry>? {
        guard !cullIndex.isEmpty else { return nil }
        func timeAtY(_ y: CGFloat) -> Date {
            calendarTimelineDateFromYPosition(
                y,
                containing: model.date,
                headerHeight: model.headerHeight,
                hourHeight: model.hourHeight,
                leadingExtendedHours: model.leadingExtendedHours,
                trailingExtendedHours: model.trailingExtendedHours,
                snapMinutes: 0
            )
        }
        let windowTopTime = timeAtY(visibleRect.minY)
        let windowBottomTime = timeAtY(visibleRect.maxY)
        let lowerTime = windowTopTime.addingTimeInterval(-maxEventDurationSeconds)
        var lo = lowerBoundByStart(lowerTime)
        if lo > 0 { lo -= 1 }
        var hi = upperBoundByStart(windowBottomTime)
        if hi < cullIndex.count { hi += 1 }
        guard lo < hi else { return cullIndex[0..<0] }
        return cullIndex[lo..<hi]
    }

    /// Index of the first `cullIndex` entry with `start >= time` (lower_bound).
    private func lowerBoundByStart(_ time: Date) -> Int {
        var lo = 0, hi = cullIndex.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cullIndex[mid].start < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Count of `cullIndex` entries with `start <= time` (upper_bound).
    private func upperBoundByStart(_ time: Date) -> Int {
        var lo = 0, hi = cullIndex.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cullIndex[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    /// Stack-peek strip width / interrupt context from the last full render,
    /// reused by the cheap path (both are hourHeight-independent).
    private var cachedInterrupt: InterruptContext?
    private var cachedStackPeekStripWidth: CGFloat = 8

    // MARK: Background chrome (S2)

    /// Per-day background chrome, drawn at fixed z-positions so it interleaves
    /// correctly with the per-event containers (which carry `zPosition >= 1`
    /// from their overlap slot). Mirrors the SwiftUI `TimelineDayView` body
    /// z-order: future-zone tint → grid → horizon line → events → now-line.
    private final class ChromeLayers {
        /// Future-zone wash (orange 0.04). Full-column or partial sub-rect.
        let futureTint = CALayer()                  // zPosition -3 (behind all)
        /// Solid hour lines (1px fill, single compound path).
        let hourGrid = CAShapeLayer()               // zPosition -2
        /// Dashed half-hour lines ([3,4], 1.5pt), only when slotMinutes==30.
        let halfHourGrid = CAShapeLayer()           // zPosition -2
        /// Orange 0.45 horizon boundary line (1.5pt) on the horizon day.
        let horizonLine = CALayer()                 // zPosition -1 (above grid)
        /// Now-line line + dot (today only). Above events.
        let nowLine = CALayer()                     // zPosition 100
        let nowDot = CAShapeLayer()                 // child of nowLine
        let nowLineFill = CALayer()                 // child of nowLine

        init() {
            futureTint.zPosition = -3
            hourGrid.zPosition = -2
            halfHourGrid.zPosition = -2
            horizonLine.zPosition = -1
            nowLine.zPosition = 100

            hourGrid.fillColor = UIColor.clear.cgColor
            hourGrid.strokeColor = UIColor.clear.cgColor
            halfHourGrid.fillColor = UIColor.clear.cgColor

            nowLine.addSublayer(nowLineFill)
            nowLine.addSublayer(nowDot)
            nowDot.fillColor = UIColor.clear.cgColor

            for l in [futureTint, hourGrid, halfHourGrid, horizonLine, nowLine] {
                l.isHidden = true
            }
            // Render thin grid lines / now-line / dot at screen scale so they
            // aren't aliased (the burr fix, applied to chrome too). Separate
            // from the isHidden loop — these children's visibility is driven by
            // their parent nowLine.
            for l in [futureTint, hourGrid, halfHourGrid, horizonLine, nowLine, nowDot, nowLineFill] {
                l.contentsScale = UIScreen.main.scale
            }
        }
    }

    private lazy var chrome: ChromeLayers = {
        let c = ChromeLayers()
        // Add directly to the root layer; z-positions handle interleaving with
        // the per-event containers (also direct root children).
        layer.addSublayer(c.futureTint)
        layer.addSublayer(c.hourGrid)
        layer.addSublayer(c.halfHourGrid)
        layer.addSublayer(c.horizonLine)
        layer.addSublayer(c.nowLine)
        return c
    }()

    // MARK: Apply

    // `callbacks` defaults to empty so render-only harnesses (the benchmark)
    // can drive the layer tree without wiring the full S4 closure set.
    func apply(_ model: Model, callbacks: Callbacks = Callbacks()) {
        gestureController.callbacks = callbacks
        guard currentModel != model else { return }
        let previous = currentModel
        currentModel = model
        // The live drag offset lives in plain UIKit state on the gesture
        // controller (spec 05): a SwiftUI-driven re-`apply` (e.g. dragState
        // coarse-field mirror, focus change) must not stomp the in-flight
        // drag preview, so the render path reads the controller's live
        // session. We mark the structure dirty so a visual-only field change
        // (focus / grace / creation preview) still repaints even though the
        // StructureKey is unchanged.
        if let previous,
           previous.structureKey == model.structureKey,
           !Model.visualStateEqual(previous, model) {
            // A focus / grace / creation-preview field changed but the
            // structural identity and the vertical scale did NOT — force the
            // full path so the affected layers refresh. (Pinch frames only
            // change hourHeight, leaving visualStateEqual true, so the cheap
            // S3 path is preserved.)
            cachedStructureKey = nil
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let model = currentModel else { return }
        // Cheap-repaint decision (S3): if the structural identity is unchanged
        // since the last FULL render, the only thing that moved is the vertical
        // scale (hourHeight + derived header / contentHeight). Reuse the cached
        // overlap result + horizontal placement and touch ONLY vertical
        // geometry + chrome — no overlap recompute, no layer rebuild. This is
        // the per-pinch-frame fast path; outside pinch a structural change
        // (occurrences / width / mode) falls through to the full render.
        if let cachedKey = cachedStructureKey,
           cachedKey == model.structureKey,
           !cachedPlacements.isEmpty || model.occurrences.isEmpty {
            repaintVertical(model)
        } else {
            render(model)
        }
    }

    // MARK: Render (static)

    private func render(_ model: Model) {
        // No implicit animations for the static S1 path: layer frame / path
        // changes must be instantaneous (animations are slice S5).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Horizontal placement via the EXISTING overlap topology, now in
        // STACK-PEEK mode (spec 01 §1 item 1): peek strip 8pt expressed as a
        // fraction of the event-area width, peer tolerance 20min. This matches
        // the SwiftUI host's `stackPeekFraction` / `stackPeekPeerToleranceSeconds`.
        let eventAreaWidth = max(0, model.contentWidth - model.eventHorizontalInset * 2)
        let stackPeekStripWidthPt: CGFloat = 8
        let peekFraction: CGFloat = eventAreaWidth > stackPeekStripWidthPt * 2
            ? stackPeekStripWidthPt / eventAreaWidth
            : 0
        let peerTolerance: TimeInterval = 20 * 60

        // Interrupt relationship lookups (static-case mirror of the host's
        // non-live derivations in TimelineView: interruptParentLookup /
        // interruptChildrenLookup / embeddedInterruptIDs).
        let interrupt = InterruptContext(occurrences: model.occurrences)

        // ── Live overlap topology (FIX #1: live-impact preview) ──────────
        // During a move/resize drag the SwiftUI host recomputes the overlap
        // off LIVE-ADJUSTED occurrence ranges (TimelineView `visibleOccurrences`
        // rebuilt via `liveLayoutRange`), so neighbors re-column / shift in
        // real time around the dragged event's PREVIEW position. We mirror that
        // here: feed live-adjusted ranges into `overlapLayout` so the topology
        // reacts to the drag. Outside a drag this is a no-op (the closure
        // returns each occurrence unchanged) so the static path is unchanged.
        //
        // Parity note (TimelineView:3658-3678): a dragged `.todo` is EXCLUDED
        // from the live overlap candidates so peer events keep their original
        // split (a todo being dragged through a 2-way cluster must NOT squeeze
        // the peers to a 3-way). A dragged `.event` participates normally so
        // event-on-event drags get the live cluster recompute. The dragged
        // block itself then reads its slot from `stableSlots` (move mode) so it
        // keeps its source column while following the finger.
        let activeSession = gestureController.activeEventSession
        let draggedTodoOccurrenceID: String? = {
            guard let s = activeSession, s.event.kind == .todo else { return nil }
            return s.occurrenceID
        }()
        // FIX 1: when an interrupt PARENT is being dragged, its embedded children
        // must follow it out of the source overlap (else `slots[parent.id]` is
        // nil → their `parentContext` is nil → they fall to the standalone
        // full-width branch and re-lay-out every drag frame — the "interrupt
        // 没跟上" thrash) AND hide with the parent's chip. Recompute the set here
        // (the only place `interrupt` is in scope) into the host-level single
        // source of truth read below + by `applyInteractionState`.
        draggedInterruptChildIDs = activeSession.map {
            interrupt.embeddedChildIDs(ofParent: $0.event)
        } ?? []
        let draggedInterruptChildIDs = self.draggedInterruptChildIDs
        // Stack-peek mode excludes embedded interrupt children from overlap
        // layout (they render at child-overlay geometry on their parent), and
        // matches the host's `overlapCandidates` filter.
        var overlapCandidates = model.occurrences.compactMap { occ -> CalendarLayout.EventOccurrence? in
            if let draggedTodoOccurrenceID, occ.id == draggedTodoOccurrenceID { return nil }
            if occ.event.isInterrupt, occ.event.interruptRelation != nil,
               interrupt.embeddedIDs.contains(occ.id) {
                return nil
            }
            // FIX 1: the dragged interrupt parent's embedded children leave the
            // source-day overlap with the parent (which is dropped below), so
            // they don't strand as full-width default-column blocks that
            // re-lay-out every drag frame.
            if draggedInterruptChildIDs.contains(occ.id) { return nil }
            // When an in-grid preview for the same event is active on THIS host,
            // drop the real dragged occurrence so neighbors reflow around the
            // PREVIEW slot, not the hidden source slot.
            if let preview = dragPreviewOccurrence,
               preview.event.id == occ.event.id,
               gestureController.activeEventSession?.occurrenceID == occ.id {
                return nil
            }
            return liveAdjustedOccurrence(occ, model: model)
        }
        // Synthesize the in-grid preview occurrence from the stored preview when
        // it belongs to this day (and isn't a real occurrence already), so the
        // overlap layout columns the dragged event into this day's timeline.
        let synthesizedPreview: CalendarLayout.EventOccurrence? = {
            guard let preview = dragPreviewOccurrence else { return nil }
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: model.date)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            guard preview.range.end > dayStart, preview.range.start < dayEnd else { return nil }
            // Dedup against OTHER real occurrences of this event on this day
            // (e.g. a recurring projection), but NOT against the actively-dragged
            // occurrence itself — on the source day it's in `model.occurrences`
            // but it's hidden + excluded from overlap, so the preview must
            // replace it (else same-day drag shows nothing: real hidden + preview
            // deduped away = the "event disappears when preview is active" bug).
            let draggedID = gestureController.activeEventSession?.occurrenceID
            guard !model.occurrences.contains(where: {
                $0.event.id == preview.event.id && $0.id != draggedID
            }) else { return nil }
            return preview
        }()
        if let synthesizedPreview { overlapCandidates.append(synthesizedPreview) }
        let slots = CalendarLayout.overlapLayout(
            for: overlapCandidates,
            on: model.date,
            peekFraction: peekFraction,
            peerTolerance: peerTolerance
        )
        // The dragged block (move mode) keeps its SOURCE column: its slot comes
        // from the STATIC overlap (computed off un-adjusted ranges), matching
        // the SwiftUI `stableOverlapSlots` read for the dragged occurrence.
        // Computed only while a move drag is active (otherwise `slots` is used).
        let stableSlots: [String: CalendarLayout.EventOverlapSlot]
        if activeSession?.mode == .move {
            let stableCandidates = model.occurrences.filter { occ in
                guard occ.event.isInterrupt, occ.event.interruptRelation != nil else { return true }
                return !interrupt.embeddedIDs.contains(occ.id)
            }
            stableSlots = CalendarLayout.overlapLayout(
                for: stableCandidates,
                on: model.date,
                peekFraction: peekFraction,
                peerTolerance: peerTolerance
            )
        } else {
            stableSlots = slots
        }

        let contentHeight = calendarTimelineContentHeight(
            hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )

        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date,
            leadingExtendedHours: model.leadingExtendedHours
        )
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: model.date,
            trailingExtendedHours: model.trailingExtendedHours
        )

        // S6 viewport: the buffered visible rect (this view's coords). `nil`
        // means "show all" (no scroll view resolved yet / non-scrolling
        // harness) — the pre-S6 behavior, kept for correctness fallback.
        let visibleRect = bufferedVisibleRect()
        lastCullVisibleRect = visibleRect ?? .null
        // The actively-manipulated occurrence must NEVER be culled even if its
        // live (dragged / resized) frame scrolls out of the buffered rect via
        // edge auto-scroll — its layer must stay alive + in `renderedFrames` so
        // the gesture keeps hit-testing and the preview stays visible.
        let manipulatedID = gestureController.activeEventSession?.occurrenceID

        var liveIDs = Set<String>()
        var placements: [String: CachedPlacement] = [:]
        var rendered: [String: RenderedEventFrame] = [:]

        // NOTE: `synthesizedPreview` is fed into `overlapCandidates` (above) for
        // neighbor REFLOW ONLY — it is deliberately NOT iterated/painted here.
        // The floating chip is the dragged event's single visible block; painting
        // the preview too would double-image AND reintroduce the cull/dedup
        // fragility that made the event vanish. Neighbors reflow to open a gap;
        // the chip sits in it.
        for staticOccurrence in model.occurrences {
            // Live drag: the actively-dragged occurrence renders differently by
            // mode (mirrors the SwiftUI `renderedRange` / `slot` selection,
            // TimelineView:3875-3884):
            //  • MOVE — the block renders at its STATIC range + SOURCE column
            //    (`stableSlots`) and follows the finger via a CONTAINER
            //    TRANSLATION (both x AND y) applied in `applyInteractionState`.
            //    Folding move-Y into the FRAME instead made the block snap back
            //    on any interleaved render (scroll-KVO cull / SwiftUI re-apply)
            //    that recomputed the static frame — the "doesn't follow the
            //    finger" regression. A transform offset over a fixed frame is
            //    idempotent: every render writes the same frame, so concurrent
            //    paths can't fight it.
            //  • RESIZE — the edit folds into the range (the block's extent
            //    genuinely changes), so we keep `liveAdjustedOccurrence`.
            let isMoveDraggedHere = activeSession?.occurrenceID == staticOccurrence.id
                && activeSession?.mode == .move
            let occurrence = isMoveDraggedHere
                ? staticOccurrence
                : liveAdjustedOccurrence(staticOccurrence, model: model)
            // Embedded interrupt children render relative to the parent's slot
            // via child-overlay geometry, not their own overlap slot.
            let isEmbeddedChild = interrupt.embeddedIDs.contains(occurrence.id)
            // The dragged block (move) keeps its source column from the static
            // overlap; everything else (incl. neighbors reacting to the drag)
            // uses the LIVE overlap so they re-column around the preview.
            let slotSource = isMoveDraggedHere ? stableSlots : slots
            let parentContext = interrupt.parentSlotContext(
                for: occurrence,
                slots: slotSource,
                eventAreaWidth: eventAreaWidth,
                inset: model.eventHorizontalInset
            )

            let slot = slotSource[occurrence.id] ?? .default

            // Horizontal: embedded children sit on the parent's column at the
            // child-overlay geometry; otherwise the 2px gutter between
            // overlapping stack columns. None of this depends on hourHeight, so
            // it is cached and reused verbatim by the cheap repaint path.
            let blockX: CGFloat
            let blockWidth: CGFloat
            if isEmbeddedChild, let parent = parentContext {
                let geo = calendarInterruptChildOverlayGeometry(parentWidth: parent.width)
                let overlapGap: CGFloat = parent.hasOverlap ? 2 : 0
                blockWidth = max(0, geo.width - overlapGap)
                blockX = parent.x + geo.xOffset
            } else {
                let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                blockWidth = max(0, eventAreaWidth * slot.widthFraction - overlapGap)
                blockX = model.eventHorizontalInset + eventAreaWidth * slot.xOffsetFraction
            }

            // Vertical frame (depends on hourHeight) — shared with the cheap
            // path so both compute it identically.
            let verticalFrame = verticalFrame(
                for: occurrence,
                model: model,
                contentHeight: contentHeight,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd
            )
            let frame = CGRect(
                x: blockX,
                y: verticalFrame.y,
                width: blockWidth,
                height: verticalFrame.height
            )

            // z-order from the overlap slot (deeper events on top). Embedded
            // children paint above their parent.
            let zPosition: CGFloat = isEmbeddedChild
                ? (parentContext?.zIndex ?? CGFloat(slot.zIndex)) + 1
                : CGFloat(slot.zIndex)

            // The placement cache + `renderedFrames` are populated for EVERY
            // occurrence (cheap struct-only work): the S3 pinch cache must stay
            // complete, and keeping every occurrence's frame in `renderedFrames`
            // means a gesture that lands on any visible block hit-tests
            // correctly regardless of which subtrees are currently built.
            placements[occurrence.id] = CachedPlacement(
                blockX: blockX,
                blockWidth: blockWidth,
                zPosition: zPosition,
                occurrence: staticOccurrence,
                slot: slot,
                isEmbeddedChild: isEmbeddedChild
            )
            rendered[occurrence.id] = RenderedEventFrame(
                occurrence: occurrence,
                frame: frame,
                slot: slot,
                isEmbeddedChild: isEmbeddedChild
            )

            // ── S6 viewport cull ─────────────────────────────────────────────
            // Build / update a layer subtree ONLY for an occurrence whose frame
            // intersects the buffered visible rect, OR the actively-manipulated
            // occurrence (which must stay alive even if it scrolls off via edge
            // auto-scroll). Everything else is left out of the layer tree so
            // per-frame configure cost ∝ visible-N, not total-N.
            let mustKeep = occurrence.id == manipulatedID
                || occurrence.id == synthesizedPreview?.id
            guard mustKeep || isWithinViewport(frame, visibleRect: visibleRect) else {
                continue
            }

            liveIDs.insert(occurrence.id)
            let layers = acquireLayers(for: occurrence.id)

            configure(
                layers,
                frame: frame,
                occurrence: occurrence,
                model: model,
                slot: slot,
                isEmbeddedChild: isEmbeddedChild,
                interrupt: interrupt,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                stackPeekStripWidth: stackPeekStripWidthPt
            )
            applyInteractionState(layers, occurrence: occurrence, frame: frame, model: model)

            layers.container.zPosition = zPosition
        }

        // Recycle subtrees for occurrences that left the day OR were culled out
        // of the buffered viewport this pass — park them in the reuse pool.
        for (id, layers) in pool where !liveIDs.contains(id) {
            recycleLayers(id: id, layers: layers)
        }

        renderedFrames = rendered
        renderCreationPreview(model: model, contentHeight: contentHeight, visibleStart: visibleStart)

        // Background chrome (S2): grid, future-zone tint, horizon line,
        // now-line. Shares the same disable-actions transaction as events.
        renderChrome(
            model: model,
            contentHeight: contentHeight,
            visibleStart: visibleStart
        )

        // Cache the hourHeight-invariant work so the next vertical-only change
        // (a pinch frame) can skip the overlap recompute + layer rebuild.
        cachedStructureKey = model.structureKey
        cachedPlacements = placements
        cachedInterrupt = interrupt
        cachedStackPeekStripWidth = stackPeekStripWidthPt
        // Rebuild the start-sorted cull index so subsequent scroll/pinch culls
        // can binary-search the visible candidate slice (issue #14). Only the
        // full render changes the occurrence set, so this is the right home.
        rebuildCullIndex(model.occurrences)
    }

    // MARK: Layer pool acquire / recycle (S6)

    /// Get a live `EventLayers` subtree for `id`: prefer the one already in the
    /// active `pool`; else reuse a parked subtree (same id first to keep its
    /// content warm, then any free one) with its animation state reset so a
    /// scroll-in does NOT fire entry animations; else allocate a fresh subtree.
    /// Reused / fresh subtrees are (re)attached to the root layer.
    private func acquireLayers(for id: String) -> EventLayers {
        if let existing = pool[id] { return existing }
        // Reuse: exact-id park hit, else any parked subtree.
        let recycled: EventLayers?
        if let exact = freePool.removeValue(forKey: id) {
            recycled = exact
        } else if let anyKey = freePool.keys.first {
            recycled = freePool.removeValue(forKey: anyKey)
        } else {
            recycled = nil
        }
        if let recycled {
            // Scrolled back into view — appear instantly, not "newly absorbed".
            recycled.resetAnimationState()
            pool[id] = recycled
            layer.addSublayer(recycled.container)
            return recycled
        }
        let fresh = EventLayers()
        pool[id] = fresh
        layer.addSublayer(fresh.container)
        return fresh
    }

    /// Detach a subtree from the active layer tree and park it in the reuse
    /// pool (capped). Capacity overflow drops the subtree entirely (ARC frees
    /// it) so a huge day can't retain unbounded recycled layers.
    private func recycleLayers(id: String, layers: EventLayers) {
        layers.container.removeFromSuperlayer()
        pool.removeValue(forKey: id)
        layers.pulseSettleWork?.cancel()
        layers.pulseSettleWork = nil
        // Tear down any hosted spinner blur backing for this occurrence; a
        // recycled subtree reacquires one only if it's still analyzing.
        removeSpinnerBlur(for: id)
        if freePool.count < freePoolCapacity {
            freePool[id] = layers
        }
        // else: not parked → released.
    }

    /// Re-run the viewport cull against a (possibly new) buffered rect WITHOUT
    /// recomputing overlap topology / horizontal placement. Reuses the S3
    /// caches (`cachedPlacements` / `cachedInterrupt`) so a scroll frame only
    /// pays for the events crossing the buffer edge — the entire S6 win. Builds
    /// subtrees for newly-visible occurrences, recycles ones that left the
    /// buffer, and refreshes the live vertical geometry of the kept ones.
    private func cullViewport(visibleRect: CGRect) {
        guard let model = currentModel else { return }
        // Without a placement cache (e.g. before the first full render) there's
        // nothing to cull against — defer to the normal render path.
        guard cachedStructureKey == model.structureKey,
              let interrupt = cachedInterrupt,
              !cachedPlacements.isEmpty else {
            return
        }
        lastCullVisibleRect = visibleRect
        let manipulatedID = gestureController.activeEventSession?.occurrenceID

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let contentHeight = calendarTimelineContentHeight(
            hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date, leadingExtendedHours: model.leadingExtendedHours
        )
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: model.date, trailingExtendedHours: model.trailingExtendedHours
        )

        // ── Sub-linear visible-set decision (issue #14) ──────────────────
        // On a pure scroll the content Y of every occurrence is UNCHANGED since
        // the last full render (only the viewport moved), so `renderedFrames`
        // is already correct for off-screen blocks — we only need to find which
        // blocks NOW intersect the viewport. Binary-search the start-sorted
        // index for the candidate SLICE and iterate ONLY that slice
        // (O(log N + candidateCount)); a `nil` slice means no index → fall back
        // to scanning all occurrences (the pre-#14 O(N) path) for correctness.
        let slice = cullCandidateSlice(
            visibleRect: visibleRect, model: model,
            contentHeight: contentHeight, visibleStart: visibleStart, visibleEnd: visibleEnd
        )

        var liveIDs = Set<String>()
        if let slice {
            // Iterate only the candidate slice + the manipulated occurrence.
            var visited = Set<String>()
            func process(_ id: String) {
                guard let placement = cachedPlacements[id], visited.insert(id).inserted else { return }
                let occurrence = placement.occurrence
                // A move-dragged block renders at its STATIC frame + follows the
                // finger via the container transform (see `render` / FIX #2), so
                // a scroll-KVO cull mid-drag must NOT fold move-Y into its range
                // (that would set `container.frame.y` live and fight the
                // transform → the block snaps back). Resize still live-adjusts.
                let live = isMoveDraggedStatic(id) ? occurrence
                    : liveAdjustedOccurrence(occurrence, model: model)
                let vertical = verticalFrame(
                    for: live, model: model,
                    contentHeight: contentHeight, visibleStart: visibleStart, visibleEnd: visibleEnd
                )
                let frame = CGRect(
                    x: placement.blockX, y: vertical.y,
                    width: placement.blockWidth, height: vertical.height
                )
                renderedFrames[id] = RenderedEventFrame(
                    occurrence: live, frame: frame,
                    slot: placement.slot, isEmbeddedChild: placement.isEmbeddedChild
                )
                let mustKeep = id == manipulatedID
                guard mustKeep || isWithinViewport(frame, visibleRect: visibleRect) else { return }
                liveIDs.insert(id)
                let alreadyLive = pool[id] != nil
                let layers = acquireLayers(for: id)
                if !alreadyLive {
                    configure(
                        layers, frame: frame, occurrence: live, model: model,
                        slot: placement.slot, isEmbeddedChild: placement.isEmbeddedChild,
                        interrupt: interrupt, visibleStart: visibleStart, visibleEnd: visibleEnd,
                        stackPeekStripWidth: cachedStackPeekStripWidth
                    )
                    applyInteractionState(layers, occurrence: live, frame: frame, model: model)
                    layers.container.zPosition = placement.zPosition
                }
            }
            #if DEBUG
            lastCullCandidateCount = slice.count
            #endif
            for entry in slice { process(entry.id) }
            if let manipulatedID { process(manipulatedID) }
        } else {
            #if DEBUG
            lastCullCandidateCount = model.occurrences.count
            #endif
            // Fallback: no index → scan all occurrences (pre-#14 behavior).
            for occurrence in model.occurrences {
                guard let placement = cachedPlacements[occurrence.id] else { continue }
                // Move-dragged block keeps its static frame (transform follow).
                let live = isMoveDraggedStatic(occurrence.id) ? occurrence
                    : liveAdjustedOccurrence(occurrence, model: model)
                let vertical = verticalFrame(
                    for: live, model: model,
                    contentHeight: contentHeight, visibleStart: visibleStart, visibleEnd: visibleEnd
                )
                let frame = CGRect(
                    x: placement.blockX, y: vertical.y,
                    width: placement.blockWidth, height: vertical.height
                )
                renderedFrames[occurrence.id] = RenderedEventFrame(
                    occurrence: live, frame: frame,
                    slot: placement.slot, isEmbeddedChild: placement.isEmbeddedChild
                )
                let mustKeep = occurrence.id == manipulatedID
                guard mustKeep || isWithinViewport(frame, visibleRect: visibleRect) else { continue }
                liveIDs.insert(occurrence.id)
                let alreadyLive = pool[occurrence.id] != nil
                let layers = acquireLayers(for: occurrence.id)
                if !alreadyLive {
                    configure(
                        layers, frame: frame, occurrence: live, model: model,
                        slot: placement.slot, isEmbeddedChild: placement.isEmbeddedChild,
                        interrupt: interrupt, visibleStart: visibleStart, visibleEnd: visibleEnd,
                        stackPeekStripWidth: cachedStackPeekStripWidth
                    )
                    applyInteractionState(layers, occurrence: live, frame: frame, model: model)
                    layers.container.zPosition = placement.zPosition
                }
            }
        }

        // Never recycle the in-grid drag preview here: it is NOT in the cull
        // index (built from `model.occurrences`), so the candidate slice never
        // re-keeps it — but it must survive scroll-settle culls between full
        // renders, or it vanishes while neighbors (in the index) stay (the
        // "preview gone in the slot after auto-scroll, only neighbors react"
        // bug). The next full render re-positions it; the cull just must not
        // kill it. (`manipulatedID` is force-kept above for the same reason.)
        let previewID = dragPreviewOccurrence?.id
        for (id, layers) in pool where !liveIDs.contains(id) && id != previewID {
            recycleLayers(id: id, layers: layers)
        }
    }

    /// Vertical frame (Y + height) for an occurrence at the Model's current
    /// `hourHeight`. Pure reuse of the spec-03 fraction mapping — identical math
    /// to the full `render` loop, factored out so the cheap repaint path and the
    /// full path can never diverge. The +1.5 / −3 cosmetic gaps are applied here.
    private func verticalFrame(
        for occurrence: CalendarLayout.EventOccurrence,
        model: Model,
        contentHeight: CGFloat,
        visibleStart: Date,
        visibleEnd: Date
    ) -> (y: CGFloat, height: CGFloat) {
        // Clipped seconds within the visible window (spec 03 §1.3).
        let clippedStart = max(occurrence.range.start, visibleStart)
        let clippedEnd = min(occurrence.range.end, visibleEnd)
        let blockSeconds = max(0, clippedEnd.timeIntervalSince(clippedStart))

        let heightFrac = calendarTimelineDurationFraction(
            seconds: blockSeconds,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )
        // −3 cosmetic shrink (spec 03 §1.3).
        let blockHeight = max(0, heightFrac * contentHeight - 3)

        let yFraction = calendarTimelineYFraction(
            for: occurrence.range.start,
            containing: model.date,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )
        // headerHeight + fraction*contentHeight, then the +1.5 top gap.
        let blockY = model.headerHeight + yFraction * contentHeight + 1.5
        return (blockY, blockHeight)
    }

    // MARK: Live drag / interaction rendering (S4)

    /// Replace the dragged occurrence's range with its live preview range so
    /// the block renders where the finger has it (move-Y / resize fold into
    /// the range here; move-X is a container translation in
    /// `applyInteractionState`). Non-dragged occurrences pass through
    /// unchanged — this matches the SwiftUI `liveOccurrenceRange` guard so
    /// only the dragged block tracks the per-frame offset.
    /// True when `id` is the actively MOVE-dragged occurrence — which renders
    /// at its STATIC frame and follows the finger via the container transform
    /// (FIX #2), so render/cull paths must NOT fold its move offset into the
    /// frame. A resize drag returns false (resize genuinely changes the range).
    private func isMoveDraggedStatic(_ id: String) -> Bool {
        guard let s = gestureController.activeEventSession else { return false }
        return s.occurrenceID == id && s.mode == .move
    }

    private func liveAdjustedOccurrence(
        _ occurrence: CalendarLayout.EventOccurrence,
        model: Model
    ) -> CalendarLayout.EventOccurrence {
        guard let session = gestureController.activeEventSession,
              session.occurrenceID == occurrence.id else {
            return occurrence
        }
        // Clip the live preview to this day window (mirror of
        // `calendarAdjustedOccurrenceRange`). For move we keep the dragged
        // block visible in its source day even as the preview leaves; for
        // resize the range stays within the day.
        let preview = calendarResolvedDragEditRange(
            draggingOriginalRange: session.originalRange,
            dragOffset: gestureController.liveResolvedOffset,
            dragMode: session.mode,
            hourHeight: model.hourHeight,
            dayColumnStep: session.mode == .move ? model.dragPreviewDayStep : 0
        ) ?? occurrence.range
        let dayStart = Calendar.current.startOfDay(for: model.date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let adjusted = calendarAdjustedOccurrenceRange(
            occurrenceID: occurrence.id,
            occurrenceRange: occurrence.range,
            draggingOccurrenceID: occurrence.id,
            draggingOriginalRange: session.originalRange,
            dragMode: session.mode,
            previewRange: preview,
            dayStart: dayStart,
            dayEnd: dayEnd
        ) ?? occurrence.range
        return CalendarLayout.EventOccurrence(
            id: occurrence.id,
            event: occurrence.event,
            range: adjusted
        )
    }

    /// Apply per-frame interaction visuals on a single block AND fire the
    /// scoped S5 animations on STATE TRANSITIONS (never per frame).
    ///
    /// Transaction discipline (spec 04 cross-cutting): this runs inside the
    /// caller's `setDisableActions(true)` transaction, so the model-value
    /// writes below NEVER animate implicitly (a pinch / drag / scroll frame
    /// repaints instantly). Animation is opt-in: only when a remembered edge
    /// flips do we `add(_:forKey:)` an explicit `CA*Animation` on the SPECIFIC
    /// sublayer + keypath that owns it. Explicit `add(_:forKey:)` plays even
    /// inside a disable-actions transaction (that flag suppresses only the
    /// default *implicit* actions), so this mirrors SwiftUI's scoped
    /// `withAnimation` / `.animation(value:)` without a root transaction.
    /// FIX 1 + 3 single source of truth: is this occurrence's source block
    /// owned by the floating drag chip right now (so it must be hidden — opacity
    /// 0, and its spinner blur subview too)? True for the dragged occurrence
    /// itself in move mode, AND for an embedded interrupt CHILD of the dragged
    /// parent (the parent's chip silhouette stands in for it for now). Read by
    /// both `applyInteractionState` and `configureSpinner` so the CALayer opacity
    /// and the `UIVisualEffectView` blur stay in lockstep. `draggedInterruptChildIDs`
    /// is recomputed once per `render(_:)` before either consumer runs.
    private func chipHidesSource(for occurrenceID: String) -> Bool {
        guard gestureController.isChipActive,
              let session = gestureController.activeEventSession,
              session.mode == .move else { return false }
        return session.occurrenceID == occurrenceID
            || draggedInterruptChildIDs.contains(occurrenceID)
    }

    private func applyInteractionState(
        _ layers: EventLayers,
        occurrence: CalendarLayout.EventOccurrence,
        frame: CGRect,
        model: Model
    ) {
        let event = occurrence.event
        let session = gestureController.activeEventSession
        let isDraggedOccurrence = session?.occurrenceID == occurrence.id
        let isMoveDragging = isDraggedOccurrence && session?.mode == .move
        let reduceMotion = calendarReduceMotionEnabled
        // Floating chip owns the visual during a move drag: hide the source
        // block instantly (opacity 0) and pin it in place (no move translation).
        //
        // FIX 1: an embedded interrupt child of the dragged parent hides for the
        // drag duration too (its parent's chip silhouette covers it for now;
        // compositing the children into the chip snapshot is a later batch). It
        // already left the overlap above, so without this it would re-appear at
        // the source as a full-width block.
        let chipHidesSource = chipHidesSource(for: occurrence.id)

        // Focus: a focused block keeps full opacity + shadow; non-focused
        // siblings dim to 0.28 while a focus context is active.
        let isFocused = model.focusedEventID == event.id
            && (model.focusedOccurrenceID == nil || model.focusedOccurrenceID == occurrence.id)
        let isDimmedByFocus = model.isFocusContextActive && !isFocused
            && model.focusedEventID != nil && !isDraggedOccurrence

        // `isInDragState` mirror (EventBlock:2912 keys the easeInOut 0.15 on
        // this). The dragged occurrence is in a drag; the root .animation also
        // covers focus dim/shadow which settle on the same toggle.
        let isInDragState = isDraggedOccurrence
        let firstApply = !layers.hasAppliedAnimState

        // ── §3 focus-dim opacity + focus/drag shadow ─────────────────────
        // Deferred done-fade (EventBlock `displayedDoneState` /
        // `opacityForDisplayedDoneState`, EventBlock.swift:2533-2565): the
        // visible 0.55 fade is driven by a LAGGED per-occurrence done state,
        // NOT `event.isDone` directly, so a `.todo` marked done while its block
        // is off-screen (behind a detail sheet) fades on RE-APPEARANCE rather
        // than silently. We advance that lagged state here and learn whether
        // this apply should animate the fade.
        //
        // Mirror of `syncDisplayedDoneState()`:
        //   • first sync (`displayedDoneState == nil`): snap to real isDone.
        //   • appear (`didJustAppear`) with drift: animate 0.4 (the "fades
        //     while you look at it on return" case).
        //   • in-place render with drift (the EventBlock defensive
        //     `.onChange(of: event.isDone)`): animate 0.4 — an on-screen
        //     done toggle still follows without a disappear/reappear.
        // `event` items never fade (guarded by `isTodo`), matching EventBlock's
        // `guard event.kind == .todo`.
        // The `didJustAppear` flag is the LAG mechanism, not a branch here:
        // while a subtree is parked (recycled / detached) no apply runs, so
        // `event.isDone` can drift away from `displayedDoneState`; the first
        // apply after re-acquire is exactly when that drift surfaces as the
        // deferred fade. EventBlock animates drift on BOTH the appear-with-stale
        // path and the in-place `.onChange(of: event.isDone)` path, so the
        // animate decision keys purely on whether the lagged value advanced.
        let isTodo = event.kind == .todo
        let realDone = isTodo && event.isDone
        let previousDisplayedDone = layers.displayedDoneState
        let displayedDone: Bool
        let doneFadeShouldAnimate: Bool
        if previousDisplayedDone == nil {
            // First sync for this subtree — snap, never animate (initial render
            // must not pop). EventBlock: `displayedDoneState = target`.
            displayedDone = realDone
            doneFadeShouldAnimate = false
        } else if previousDisplayedDone != realDone {
            // Drift between shown and real done → advance + animate the fade.
            displayedDone = realDone
            doneFadeShouldAnimate = true
        } else {
            // No drift — hold the shown value, no animation.
            displayedDone = previousDisplayedDone!
            doneFadeShouldAnimate = false
        }
        layers.displayedDoneState = displayedDone

        let doneFade: Float = displayedDone ? 0.55 : 1.0
        let dimFade: Float = isDimmedByFocus ? 0.28 : 1.0
        let targetOpacity: Float = chipHidesSource ? 0 : doneFade * dimFade

        let showsShadow = isFocused || isDraggedOccurrence
        let targetShadowOpacity: Float = showsShadow ? 0.18 : 0
        let targetShadowRadius: CGFloat = showsShadow ? 3 : 0
        layers.container.shadowColor = UIColor.black.cgColor
        layers.container.shadowOffset = .zero

        // Fire the easeInOut(0.15) tween only when the drag-state edge flips
        // (EventBlock:2912). Opacity/shadow are written to their target inside
        // the disable-actions transaction; the explicit animation supplies the
        // visible tween from the previously-presented value.
        let dragStateChanged = layers.lastInDragState != isInDragState
        // Deferred done-fade tween (EventBlock.swift:2556-2564 `withAnimation(
        // .easeInOut(duration: 0.4))`): fire when the LAGGED done state advanced
        // (`doneFadeShouldAnimate`), to/from the 0.55 composed target. Unlike
        // the other S5 edges this can legitimately fire on a `firstApply`: a
        // recycle→re-acquire resets `hasAppliedAnimState` but PRESERVES
        // `displayedDoneState`, so a done flip that happened while the subtree
        // was parked off-screen surfaces as the deferred fade on the first
        // post-appear apply (the whole point of the lag). A pinch/scroll/drag
        // frame leaves the lagged value unchanged → no tween. The drag-state
        // tween takes precedence on a drag edge to avoid two opacity anims.
        if !firstApply && !reduceMotion && dragStateChanged && !chipHidesSource {
            addEaseInOut(
                to: layers.container, keyPath: "opacity",
                from: layers.container.presentation()?.opacity ?? layers.container.opacity,
                to: targetOpacity, duration: 0.15, key: "s5.opacity"
            )
            addEaseInOut(
                to: layers.container, keyPath: "shadowOpacity",
                from: layers.container.presentation()?.shadowOpacity ?? layers.container.shadowOpacity,
                to: targetShadowOpacity, duration: 0.15, key: "s5.shadowOpacity"
            )
            addEaseInOut(
                to: layers.container, keyPath: "shadowRadius",
                from: layers.container.presentation()?.shadowRadius ?? layers.container.shadowRadius,
                to: targetShadowRadius, duration: 0.15, key: "s5.shadowRadius"
            )
        } else if doneFadeShouldAnimate && !reduceMotion {
            // Done flip (in-place toggle) OR deferred re-appear with drift:
            // easeInOut 0.4 opacity to the composed target. The reverse
            // (isDone → false) animates back symmetrically.
            addEaseInOut(
                to: layers.container, keyPath: "opacity",
                from: layers.container.presentation()?.opacity ?? layers.container.opacity,
                to: targetOpacity, duration: 0.4, key: "s5.opacity"
            )
        }
        layers.container.opacity = targetOpacity
        layers.container.shadowOpacity = targetShadowOpacity
        layers.container.shadowRadius = targetShadowRadius
        layers.lastInDragState = isInDragState
        layers.lastDoneFade = doneFade

        // ── §4 absorption pulse × §5 drop-target — ONE transform.scale ───
        // Compose both scale sources into the SAME `transform.scale` value (the
        // pulse 1.0/1.08 and the drop-target 1.03) — never two competing
        // transform animations (spec 04 §4/§5, highest-risk port).
        let isDropTarget = gestureController.callbacks.dragState?.currentDropTargetEventID == event.id
        let dropTargetChanged = layers.lastDropTarget != isDropTarget
        let targetDropScale: CGFloat = isDropTarget ? 1.03 : 1.0
        layers.dropTargetScale = targetDropScale
        if !firstApply && !reduceMotion && dropTargetChanged {
            // Drop-target highlight (§5): the 1.03 bump, easeInOut 0.15. The
            // accent stroke is applied below. The composed resting transform is
            // re-applied unconditionally further down (with the live move-X).
            animateComposedScale(layers, duration: 0.15, timing: .easeInEaseOut)
        }
        // Drop-target ring (§5): a DEDICATED inset accent stroke layer that
        // mirrors SwiftUI's `RoundedRectangle(cornerRadius: interruptCornerRadius,
        // style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2.5)`
        // overlay (EventBlock.swift:2477-2478). `.strokeBorder` insets the
        // stroke by half its width so it sits INSIDE the silhouette — unlike
        // the centered `border` layer — so we inset by lineWidth/2 and stroke a
        // continuous rounded rect at the interrupt corner radius. Leaving the
        // centered `border` untouched preserves the §2 color/width.
        if isDropTarget {
            let ringWidth: CGFloat = 2.5
            let ringInset = ringWidth / 2
            let ringRadius: CGFloat = event.isInterrupt ? 3 : 4
            let localBounds = CGRect(origin: .zero, size: frame.size)
            let ringRect = localBounds.insetBy(dx: ringInset, dy: ringInset)
            layers.dropTargetRing.isHidden = false
            layers.dropTargetRing.frame = localBounds
            layers.dropTargetRing.path = continuousRoundedRectPath(
                in: ringRect, cornerRadius: max(0, ringRadius - ringInset)
            )
            layers.dropTargetRing.strokeColor = UIColor(named: "AccentColor")?.cgColor
                ?? UIColor.tintColor.cgColor
            layers.dropTargetRing.lineWidth = ringWidth
        } else {
            layers.dropTargetRing.isHidden = true
            layers.dropTargetRing.path = nil
        }
        layers.lastDropTarget = isDropTarget

        // ── §4 absorption pulse trigger (edge into recently-absorbed set) ──
        // Fire when this event NEWLY enters the recently-absorbed set (mirror
        // of EventBlock `.onChange(of: isRecentlyAbsorbedInto)` / `.onAppear`).
        let isRecentlyAbsorbed = model.recentlyAbsorbedEventIDs.contains(event.id)
        if isRecentlyAbsorbed
            && (firstApply || !layers.lastRecentlyAbsorbed)
            && !reduceMotion {
            triggerAbsorptionPulse(layers)
        }
        layers.lastRecentlyAbsorbed = isRecentlyAbsorbed

        // ── Move translation (finger-follow) + composed scale ────────────
        // Block scale stays the no-op 1.0 base; the pulse/drop-target factors
        // are the only scale sources. During a MOVE drag the block is rendered
        // at its STATIC frame (see the render loop) and follows the finger via
        // this translation — BOTH axes. Keeping the follow in the transform
        // (read fresh from `liveResolvedOffset` every frame) rather than in the
        // frame makes the per-frame update idempotent, so an interleaved
        // static-frame render can't snap the block back to its origin (the
        // "doesn't follow the finger" regression). Kept inside the caller's
        // disable-actions transaction so the block stays glued to the finger.
        // While the floating chip is up, the source block stays put (hidden);
        // otherwise it follows the finger via this live translation.
        let moveX: CGFloat = (isMoveDragging && !chipHidesSource) ? gestureController.liveResolvedOffset.x : 0
        let moveY: CGFloat = (isMoveDragging && !chipHidesSource) ? gestureController.liveResolvedOffset.y : 0
        applyComposedScale(layers, moveX: moveX, moveY: moveY)
        if isDraggedOccurrence {
            layers.container.zPosition = 200
        }

        // ── §1 overlap-topology reflow spring ────────────────────────────
        // When a NON-dragged block's frame moves (an adjacent drag reshaped the
        // overlap cluster), spring its position/bounds (spec 04 §1,
        // response 0.25 / damping 0.85). The actively-dragged block is excluded
        // (`isDraggedOccurrence`) so it stays glued to the finger; pinch frames
        // are excluded because the StructureKey is unchanged → the cheap path
        // runs and `lastBlock*` tracking only updates on full renders where the
        // X/W actually changed.
        let reflowChanged = !firstApply
            && !isDraggedOccurrence
            && !reduceMotion
            && layers.lastBlockX.isFinite
            && (abs(layers.lastBlockX - frame.minX) > 0.5
                || abs(layers.lastBlockW - frame.width) > 0.5)
        if reflowChanged {
            let posFrom = CGPoint(
                x: layers.lastBlockX + layers.lastBlockW / 2,
                y: layers.lastBlockY + layers.lastBlockH / 2
            )
            let posTo = CGPoint(x: frame.midX, y: frame.midY)
            let pos = calendarCASpring(keyPath: "position", response: 0.25, dampingFraction: 0.85)
            pos.fromValue = NSValue(cgPoint: posFrom)
            pos.toValue = NSValue(cgPoint: posTo)
            layers.container.add(pos, forKey: "s5.reflow.position")
            if abs(layers.lastBlockW - frame.width) > 0.5 {
                let bnds = calendarCASpring(keyPath: "bounds.size", response: 0.25, dampingFraction: 0.85)
                bnds.fromValue = NSValue(cgSize: CGSize(width: layers.lastBlockW, height: layers.lastBlockH))
                bnds.toValue = NSValue(cgSize: frame.size)
                layers.container.add(bnds, forKey: "s5.reflow.bounds")
            }
        }
        layers.lastBlockX = frame.minX
        layers.lastBlockY = frame.minY
        layers.lastBlockW = frame.width
        layers.lastBlockH = frame.height

        // ── §13 resize-handle visibility + active emphasis ───────────────
        let isGraceTarget = model.graceResizeEventID == event.id
            && (model.graceResizeOccurrenceID == nil || model.graceResizeOccurrenceID == occurrence.id)
        let isResizing = isDraggedOccurrence && session?.mode != .move
        let showHandles = (frame.height >= 32) && (isFocused || isGraceTarget || isResizing)
        let handleOpacity: Float = {
            if isFocused || isResizing { return 1 }
            if isGraceTarget { return Float(model.graceResizeHandleOpacity) }
            return 0
        }()
        let targetTop: Float = showHandles ? handleOpacity : 0
        let targetBottom: Float = showHandles ? handleOpacity : 0

        // §13 active-resize emphasis easeOut(0.2) (EventBlock:2801-2802); §14
        // grace fade rides the model's `graceResizeHandleOpacity` linear ramp.
        let resizingChanged = layers.lastResizing != isResizing
        if !firstApply && !reduceMotion && resizingChanged {
            addEaseOut(
                to: layers.topHandle, keyPath: "opacity",
                from: layers.topHandle.presentation()?.opacity ?? layers.topHandle.opacity,
                to: targetTop, duration: 0.2, key: "s5.handleTop"
            )
            addEaseOut(
                to: layers.bottomHandle, keyPath: "opacity",
                from: layers.bottomHandle.presentation()?.opacity ?? layers.bottomHandle.opacity,
                to: targetBottom, duration: 0.2, key: "s5.handleBottom"
            )
        }
        layers.topHandle.opacity = targetTop
        layers.bottomHandle.opacity = targetBottom
        layers.lastResizing = isResizing

        // Appear consumed: subsequent in-place renders are NOT appears, so the
        // deferred-done lag only re-syncs on the next genuine (re)acquire.
        layers.didJustAppear = false
        layers.hasAppliedAnimState = true
    }

    /// Set the composed `transform.scale` (pulse × drop-target) plus the
    /// move translation (x AND y, the finger-follow for a move drag) as a
    /// single transform, WITHOUT an implicit tween.
    private func applyComposedScale(_ layers: EventLayers, moveX: CGFloat, moveY: CGFloat = 0) {
        let scale = layers.pulseScale * layers.dropTargetScale
        var t = CATransform3DMakeTranslation(moveX, moveY, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        layers.container.transform = t
    }

    /// Animate the composed scale to its current target with a basic timing
    /// curve (used by the drop-target 1.03 bump, easeInOut 0.15).
    private func animateComposedScale(
        _ layers: EventLayers,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        let toScale = layers.pulseScale * layers.dropTargetScale
        let fromScale = (layers.container.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? toScale
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = fromScale
        anim.toValue = toScale
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: timing)
        layers.container.add(anim, forKey: "s5.scale")
        applyComposedScale(layers, moveX: currentMoveX(layers), moveY: currentMoveY(layers))
    }

    /// Re-derive the move translation currently applied so a scale animation
    /// does not stomp the translation component of the container transform
    /// (matters during a move drag of a `.todo`, where the drop-target/pulse
    /// scale animations fire WHILE the block is following the finger in both x
    /// and y — zeroing the translation here would snap it back).
    private func currentMoveX(_ layers: EventLayers) -> CGFloat {
        (layers.container.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
    }
    private func currentMoveY(_ layers: EventLayers) -> CGFloat {
        (layers.container.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
    }

    /// §4 absorption pulse: easeOut 0.12 up to 1.08, then a bouncy spring
    /// (response 0.35 / damping 0.55) back to 1.0 — composed into the single
    /// `transform.scale` alongside the drop-target factor (spec 04 §4/§5).
    private func triggerAbsorptionPulse(_ layers: EventLayers) {
        layers.pulseSettleWork?.cancel()

        // Phase 1: easeOut 0.12 to 1.08.
        layers.pulseScale = 1.08
        let up = CABasicAnimation(keyPath: "transform.scale")
        let fromScale = (layers.container.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat)
            ?? (1.0 * layers.dropTargetScale)
        up.fromValue = fromScale
        up.toValue = layers.pulseScale * layers.dropTargetScale
        up.duration = 0.12
        up.timingFunction = CAMediaTimingFunction(name: .easeOut)
        up.fillMode = .forwards
        layers.container.add(up, forKey: "s5.scale")
        applyComposedScale(layers, moveX: currentMoveX(layers), moveY: currentMoveY(layers))

        // Phase 2 (after 0.12s): bouncy spring back to 1.0.
        let settle = DispatchWorkItem { [weak layers] in
            guard let layers else { return }
            layers.pulseScale = 1.0
            let down = calendarCASpring(keyPath: "transform.scale", response: 0.35, dampingFraction: 0.55)
            let presented = (layers.container.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat)
                ?? (1.08 * layers.dropTargetScale)
            down.fromValue = presented
            down.toValue = layers.pulseScale * layers.dropTargetScale
            layers.container.add(down, forKey: "s5.scale")
            // Update the resting transform value (preserving whatever move
            // translation — x AND y — applies for an in-flight move drag).
            let scale = layers.pulseScale * layers.dropTargetScale
            var t = CATransform3DMakeTranslation(
                (layers.container.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0,
                (layers.container.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0,
                0
            )
            t = CATransform3DScale(t, scale, scale, 1)
            layers.container.transform = t
        }
        layers.pulseSettleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: settle)
    }

    /// Helper: explicit easeInOut basic animation on a sublayer keypath.
    private func addEaseInOut(
        to layer: CALayer, keyPath: String,
        from: Any?, to: Any?, duration: CFTimeInterval, key: String
    ) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: key)
    }

    /// Helper: explicit easeOut basic animation on a sublayer keypath.
    private func addEaseOut(
        to layer: CALayer, keyPath: String,
        from: Any?, to: Any?, duration: CFTimeInterval, key: String
    ) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: key)
    }

    /// Draw the drag-to-create preview (or post-release pending ghost) for
    /// this day. Mirrors `TimelineDayView.creationPreview`: corner 10 (2 if
    /// zero-duration), fill indicator@0.15, stroke 0.6/2pt, title label.
    private func renderCreationPreview(
        model: Model,
        contentHeight: CGFloat,
        visibleStart: Date
    ) {
        _ = previewLayersInstalled
        guard let range = model.creationPreviewRange else {
            creationPreviewLayer.isHidden = true
            creationPreviewBorder.isHidden = true
            creationPreviewText.isHidden = true
            return
        }

        let eventAreaWidth = max(0, model.contentWidth - model.eventHorizontalInset * 2)
        let yStart = calendarTimelineYFraction(
            for: range.start,
            containing: model.date,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        ) * contentHeight + model.headerHeight
        let yEnd = calendarTimelineYFraction(
            for: range.end,
            containing: model.date,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        ) * contentHeight + model.headerHeight
        let rect = CGRect(
            x: model.eventHorizontalInset,
            y: yStart,
            width: eventAreaWidth,
            height: max(0, yEnd - yStart)
        )
        let isZero = range.end.timeIntervalSince(range.start) < 1
        let radius: CGFloat = isZero ? 2 : 10
        let color = Self.currentTimeIndicatorColor()

        creationPreviewLayer.isHidden = false
        creationPreviewBorder.isHidden = false
        creationPreviewLayer.frame = bounds
        creationPreviewBorder.frame = bounds
        // Continuous-curvature corners to match the SwiftUI creation preview
        // (`RoundedRectangle(style: .continuous)`).
        let path = continuousRoundedRectPath(in: rect, cornerRadius: radius)
        creationPreviewLayer.path = path
        creationPreviewLayer.fillColor = color.withAlphaComponent(0.15).cgColor
        creationPreviewBorder.path = path
        creationPreviewBorder.strokeColor = color.withAlphaComponent(0.6).cgColor
        creationPreviewBorder.lineWidth = 2

        if model.showEventText, rect.height >= 18 {
            let fontSize = min(max(CGFloat(model.titleFontSizeSetting), 9), 16)
            creationPreviewText.isHidden = false
            creationPreviewText.frame = CGRect(
                x: rect.minX + 6, y: rect.minY + 4,
                width: max(0, rect.width - 12),
                height: UIFont.systemFont(ofSize: fontSize, weight: .semibold).lineHeight
            )
            creationPreviewText.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            creationPreviewText.fontSize = fontSize
            creationPreviewText.foregroundColor = UIColor.label.cgColor
            creationPreviewText.string = L(.newEvent)
        } else {
            creationPreviewText.isHidden = true
        }
    }

    // MARK: Geometry exposed to the gesture controller (S4)

    /// The live model (gesture math needs date / hourHeight / extension / etc).
    var liveModel: Model? { currentModel }

    /// In-grid drag preview occurrence pushed by the gesture controller while a
    /// move drag is settled (not auto-scrolling). Plain UIKit state — not part
    /// of Model / StructureKey / visualStateEqual; drives a live repaint only.
    private var dragPreviewOccurrence: CalendarLayout.EventOccurrence?
    func applyDragPreview(_ occ: CalendarLayout.EventOccurrence?) {
        guard dragPreviewOccurrence != occ else { return }   // EventOccurrence is Equatable
        dragPreviewOccurrence = occ
        renderLiveDragFrame()
    }

    /// Snapshot the rendered block of a dragged occurrence into a window-space
    /// image + rect, for the floating cross-day drag chip. Rendered at identity
    /// transform so an in-flight scale/translate doesn't bake into the image.
    func snapshotDraggedOccurrence(_ id: String) -> (image: UIImage, windowRect: CGRect)? {
        guard let layers = pool[id], let rf = renderedFrames[id] else { return nil }
        // FIX 1b: an interrupt PARENT draws its embedded children as SEPARATE
        // container layers (own subtrees in the pool) inside the parent's
        // cutout. Rendering only the parent container leaves an empty hole where
        // the children should be (batch A hides the real children for the drag),
        // so the chip must also bake in each embedded child. The child
        // containers live at their own `renderedFrames` rects in `self.layer`'s
        // space, within the parent's x/y rect — so render each translated by the
        // parent frame's origin. A non-interrupt event has no embedded children
        // here, so the loop is empty and the chip is just the parent block.
        let childIDs = cachedInterrupt?.embeddedChildIDs(ofParent: rf.occurrence.event) ?? []
        let savedT = layers.container.transform
        layers.container.transform = CATransform3DIdentity
        let img = UIGraphicsImageRenderer(size: rf.frame.size).image { ctx in
            layers.container.render(in: ctx.cgContext)
            for childID in childIDs {
                guard let childLayers = pool[childID], let childRF = renderedFrames[childID] else { continue }
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: childRF.frame.minX - rf.frame.minX,
                                          y: childRF.frame.minY - rf.frame.minY)
                let savedChildT = childLayers.container.transform
                childLayers.container.transform = CATransform3DIdentity
                childLayers.container.render(in: ctx.cgContext)
                childLayers.container.transform = savedChildT
                ctx.cgContext.restoreGState()
            }
        }
        layers.container.transform = savedT
        let windowRect = convert(rf.frame, to: nil)
        return (img, windowRect)
    }

    /// Force a full repaint reflecting the controller's live drag offset.
    /// Called each drag frame. Plain UIKit call path — no SwiftUI invalidation.
    func renderLiveDragFrame() {
        guard let model = currentModel else { return }
        cachedStructureKey = nil // ensure the dragged block's frame refreshes
        render(model)
    }

    /// Map a Y position in this view's coordinate space to a snapped date,
    /// reusing the shared mapping (creation gesture parity).
    func dateFromY(_ y: CGFloat, snapMinutes: Int) -> Date {
        guard let model = currentModel else { return Date() }
        return calendarTimelineDateFromYPosition(
            y,
            containing: model.date,
            headerHeight: model.headerHeight,
            hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours,
            snapMinutes: snapMinutes
        )
    }

    // MARK: Cheap vertical-only repaint (S3 — the pinch fast path)

    /// Repaint when ONLY vertical scale changed (hourHeight + derived
    /// header / contentHeight). Reuses the cached overlap result + horizontal
    /// placement; recomputes per-occurrence Y/height (height-dependent
    /// silhouette + decorations + text re-fit go through the same `configure`
    /// the full path uses, so visual parity holds at the new height) plus the
    /// grid, now-line, and future-zone / horizon. All inside ONE
    /// disable-actions transaction — no overlap recompute, no layer add/remove.
    private func repaintVertical(_ model: Model) {
        guard let interrupt = cachedInterrupt else {
            // No cache yet (shouldn't happen given the guard in layoutSubviews)
            // — fall back to a full render to stay correct.
            render(model)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let contentHeight = calendarTimelineContentHeight(
            hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date,
            leadingExtendedHours: model.leadingExtendedHours
        )
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: model.date,
            trailingExtendedHours: model.trailingExtendedHours
        )

        // S6: a vertical-scale change (pinch) moves every event's Y, so the
        // visible set can shift. Re-evaluate the buffered viewport here too so
        // the cheap pinch path stays ∝ visible-N: build subtrees for occurrences
        // that scrolled/zoomed into the buffer, recycle ones that left, and
        // never cull the actively-manipulated occurrence.
        let visibleRect = bufferedVisibleRect()
        lastCullVisibleRect = visibleRect ?? .null
        let manipulatedID = gestureController.activeEventSession?.occurrenceID

        // Sub-linear cull decision (issue #14): binary-search the start-sorted
        // index for the candidate slice that COULD intersect the viewport at the
        // new scale. A pinch moves every Y, so `renderedFrames` must still be
        // refreshed for ALL occurrences (cheap struct-only arithmetic for the
        // gesture hit-test); but the EXPENSIVE per-event visible test +
        // `configure` / `applyInteractionState` is paid only for candidates.
        // `nil` → no viewport / no index → scan all (pre-#14 correctness fallback).
        let candidateIDs: Set<String>? = visibleRect.flatMap { rect in
            cullCandidateIDs(
                visibleRect: rect, model: model,
                contentHeight: contentHeight, visibleStart: visibleStart, visibleEnd: visibleEnd
            )
        }

        var liveIDs = Set<String>()
        for occurrence in model.occurrences {
            guard let placement = cachedPlacements[occurrence.id] else { continue }

            let vertical = verticalFrame(
                for: occurrence,
                model: model,
                contentHeight: contentHeight,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd
            )
            let frame = CGRect(
                x: placement.blockX,
                y: vertical.y,
                width: placement.blockWidth,
                height: vertical.height
            )
            // Keep `renderedFrames` complete (gesture hit-test) even for culled
            // occurrences — it is struct-only and hourHeight-dependent.
            renderedFrames[occurrence.id] = RenderedEventFrame(
                occurrence: placement.occurrence, frame: frame,
                slot: placement.slot, isEmbeddedChild: placement.isEmbeddedChild
            )

            let mustKeep = occurrence.id == manipulatedID
            // Binary search already proved non-candidates cannot overlap — skip
            // their exact viewport test + subtree work (they're recycled below
            // if pooled). Candidates still run the EXACT `isWithinViewport`
            // predicate so the visible set is byte-for-byte the O(N)-scan result.
            if let candidateIDs, !mustKeep, !candidateIDs.contains(occurrence.id) {
                continue
            }
            guard mustKeep || isWithinViewport(frame, visibleRect: visibleRect) else { continue }
            liveIDs.insert(occurrence.id)
            let layers = acquireLayers(for: occurrence.id)

            // Re-run `configure` so the silhouette mask, border, hatch,
            // handles, and TEXT re-fit at the new height (the SwiftUI path
            // re-fits text on every hourHeight change — spec 03 §3 text ramp).
            // This is the same routine the full path uses; only the
            // hourHeight-invariant overlap/horizontal work is skipped.
            configure(
                layers,
                frame: frame,
                occurrence: placement.occurrence,
                model: model,
                slot: placement.slot,
                isEmbeddedChild: placement.isEmbeddedChild,
                interrupt: interrupt,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                stackPeekStripWidth: cachedStackPeekStripWidth
            )
            applyInteractionState(layers, occurrence: placement.occurrence, frame: frame, model: model)
            layers.container.zPosition = placement.zPosition
        }

        // Recycle subtrees that pinched/scrolled out of the buffered viewport.
        for (id, layers) in pool where !liveIDs.contains(id) {
            recycleLayers(id: id, layers: layers)
        }

        // Chrome (grid / now-line / future-zone / horizon) is all vertical —
        // recompute it in the same transaction.
        renderChrome(
            model: model,
            contentHeight: contentHeight,
            visibleStart: visibleStart
        )
        renderCreationPreview(model: model, contentHeight: contentHeight, visibleStart: visibleStart)
    }

    // MARK: Chrome render (S2 — grid / now-line / future-zone tint)

    private func renderChrome(
        model: Model,
        contentHeight: CGFloat,
        visibleStart: Date
    ) {
        let eventAreaWidth = max(0, model.contentWidth - model.eventHorizontalInset * 2)
        let lineInsetX = model.eventHorizontalInset // == (contentWidth - lineWidth)/2

        // ── Grid (spec 03 §9, TimelineView.swift:4895-4926) ──────────────
        // Live-vs-frozen slot asymmetry during pinch (spec 03 §9):
        //  • line DENSITY (`isSubHourLine` half-hour test) uses the LIVE
        //    slotMinutes (30 iff hourHeight>=76) — TimelineView.swift:4857.
        //  • `slotHeight` / `slotCount` use the EFFECTIVE slotMinutes, which is
        //    the value frozen at pinch start (`frozenSlotMinutes`) so the grid
        //    doesn't reflow / flicker as hourHeight crosses the 76pt threshold
        //    mid-pinch. Outside pinch `frozenSlotMinutes` is nil → live ==
        //    effective and there is no asymmetry.
        let liveSlotMinutes = calendarLegendSlotMinutes(forHourHeight: model.hourHeight)
        let effectiveSlotMinutes = model.frozenSlotMinutes ?? liveSlotMinutes
        let isHalfHourGrid = liveSlotMinutes == 30
        let slotHeight = model.hourHeight * CGFloat(effectiveSlotMinutes) / 60
        let totalVisibleHours = calendarTimelineTotalVisibleHours(
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours
        )
        let slotCount = max(1, Int(CGFloat(totalVisibleHours * 60) / CGFloat(effectiveSlotMinutes)) + 1)
        // `.view` style: solid (gridDashed=false) hour lines, secondary@0.15.
        let gridColor = UIColor.secondaryLabel.withAlphaComponent(0.15)

        let hourPath = CGMutablePath()      // solid 1px fills
        let halfHourPath = CGMutablePath()  // dashed [3,4], 1.5pt
        for index in 0..<slotCount {
            let y = model.headerHeight + CGFloat(index) * slotHeight
            let isSubHourLine = isHalfHourGrid && index % 2 != 0
            if isSubHourLine {
                halfHourPath.move(to: CGPoint(x: lineInsetX, y: y))
                halfHourPath.addLine(to: CGPoint(x: lineInsetX + eventAreaWidth, y: y))
            } else {
                // Solid hour line is a 1px-tall filled rect in SwiftUI.
                hourPath.addRect(CGRect(x: lineInsetX, y: y, width: eventAreaWidth, height: 1))
            }
        }
        chrome.hourGrid.isHidden = false
        chrome.hourGrid.frame = bounds
        chrome.hourGrid.path = hourPath
        chrome.hourGrid.fillColor = gridColor.cgColor

        if isHalfHourGrid {
            chrome.halfHourGrid.isHidden = false
            chrome.halfHourGrid.frame = bounds
            chrome.halfHourGrid.path = halfHourPath
            chrome.halfHourGrid.strokeColor = gridColor.cgColor
            chrome.halfHourGrid.lineWidth = 1.5
            chrome.halfHourGrid.lineDashPattern = [3, 4]
        } else {
            chrome.halfHourGrid.isHidden = true
            chrome.halfHourGrid.path = nil
        }

        // ── Future-zone tint + horizon line (TimelineView.swift:3506-3540) ─
        // Horizon recomputed from now at render time (NOT stored in the Model).
        let now = Date()
        let calendar = Calendar.current
        let horizonMoment = EventZone.horizonDate(from: model.nearFutureHorizonDays, now: now, calendar: calendar)
        let isHorizonDay = calendar.isDate(model.date, inSameDayAs: horizonMoment)
        let isFullyInFutureZone: Bool = {
            let horizonDayStart = calendar.startOfDay(for: horizonMoment)
            guard let dayAfterHorizon = calendar.date(byAdding: .day, value: 1, to: horizonDayStart) else {
                return false
            }
            return calendar.startOfDay(for: model.date) >= dayAfterHorizon
        }()
        let tintColor = UIColor.systemOrange.withAlphaComponent(0.04)

        if isFullyInFutureZone {
            chrome.futureTint.isHidden = false
            chrome.futureTint.frame = bounds
            chrome.futureTint.backgroundColor = tintColor.cgColor
        } else if isHorizonDay {
            let horizonY = model.headerHeight
                + max(0, horizonMoment.timeIntervalSince(visibleStart) / 3600 * model.hourHeight)
            chrome.futureTint.isHidden = false
            chrome.futureTint.frame = CGRect(
                x: 0,
                y: horizonY,
                width: bounds.width,
                height: max(0, bounds.height - horizonY)
            )
            chrome.futureTint.backgroundColor = tintColor.cgColor
        } else {
            chrome.futureTint.isHidden = true
            chrome.futureTint.backgroundColor = nil
        }

        // Horizon boundary line (orange 0.45, 1.5pt) — horizon day only.
        if isHorizonDay {
            let horizonY = model.headerHeight
                + max(0, horizonMoment.timeIntervalSince(visibleStart) / 3600 * model.hourHeight)
            chrome.horizonLine.isHidden = false
            chrome.horizonLine.frame = CGRect(x: 0, y: horizonY, width: bounds.width, height: 1.5)
            chrome.horizonLine.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.45).cgColor
        } else {
            chrome.horizonLine.isHidden = true
            chrome.horizonLine.backgroundColor = nil
        }

        // ── Now-line (spec 03 §2, TimelineView.swift:4618-4644) ──────────
        // Today only. y = headerHeight + yFraction(now)*contentHeight.
        let showsNow = calendar.isDate(model.date, inSameDayAs: now)
        if showsNow {
            let yFraction = calendarTimelineYFraction(
                for: now,
                containing: model.date,
                leadingExtendedHours: model.leadingExtendedHours,
                trailingExtendedHours: model.trailingExtendedHours
            )
            // Pixel-align Y to avoid shimmer (spec 03 §10 / §2.3).
            let scale = max(1, UIScreen.main.scale)
            let rawY = model.headerHeight + yFraction * contentHeight
            let y = (rawY * scale).rounded() / scale
            let lineHeight: CGFloat = 1.5
            let dotSize: CGFloat = 7
            let indicatorColor = Self.currentTimeIndicatorColor()

            chrome.nowLine.isHidden = false
            chrome.nowLine.frame = bounds

            chrome.nowLineFill.frame = CGRect(
                x: model.eventHorizontalInset,
                y: y - lineHeight / 2,
                width: max(0, eventAreaWidth),
                height: lineHeight
            )
            chrome.nowLineFill.backgroundColor = indicatorColor.withAlphaComponent(0.92).cgColor

            let dotRect = CGRect(
                x: model.eventHorizontalInset - dotSize / 2,
                y: y - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            chrome.nowDot.frame = bounds
            chrome.nowDot.path = UIBezierPath(ovalIn: dotRect).cgPath
            chrome.nowDot.fillColor = indicatorColor.cgColor

            // Shadow: black 0.18, radius 1.5, y 0.5 (matches SwiftUI).
            chrome.nowLine.shadowColor = UIColor.black.cgColor
            chrome.nowLine.shadowOpacity = 0.18
            chrome.nowLine.shadowRadius = 1.5
            chrome.nowLine.shadowOffset = CGSize(width: 0, height: 0.5)
        } else {
            chrome.nowLine.isHidden = true
        }
    }

    /// Now-line / horizon indicator color (mirrors the file-private
    /// `calendarCurrentTimeIndicatorColor()` in TimelineView): white in dark,
    /// `white:0.22` in light. Same approach S1 inlined for analyzing events.
    private static func currentTimeIndicatorColor() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : UIColor(white: 0.22, alpha: 1)
        }
    }

    // swiftlint:disable:next function_body_length
    private func configure(
        _ layers: EventLayers,
        frame: CGRect,
        occurrence: CalendarLayout.EventOccurrence,
        model: Model,
        slot: CalendarLayout.EventOverlapSlot,
        isEmbeddedChild: Bool,
        interrupt: InterruptContext,
        visibleStart: Date,
        visibleEnd: Date,
        stackPeekStripWidth: CGFloat
    ) {
        let event = occurrence.event
        // Color (spec: agentic-analyzing events use the live time-indicator
        // color, matching the host's `eventBlock(...)` color prop).
        let analyzing = event.agenticIntake?.processingPhase == .analyzing
        let color: UIColor = analyzing
            // Mirrors `calendarCurrentTimeIndicatorColor()` (file-private in
            // TimelineView): white in dark mode, near-black in light mode.
            ? UIColor { traits in
                traits.userInterfaceStyle == .dark ? .white : UIColor(white: 0.22, alpha: 1)
            }
            : UIColor(CalendarLayout.eventColor(for: event))
        // Corner radius: smaller, tighter corners (was 5/6 to match the legacy
        // SwiftUI RoundedRectangle; reduced per design — CALayer is the renderer).
        let isInterrupt = event.isInterrupt
        let cornerRadius: CGFloat = isInterrupt ? 3 : 4
        let strokeWidth: CGFloat = isInterrupt ? max(0.8, 1.2 + 0.2) : 1.2

        let localBounds = CGRect(origin: .zero, size: frame.size)
        // Reset the transform to identity BEFORE setting `.frame`. `.frame` on a
        // layer with a non-identity transform makes UIKit re-derive `position`
        // to compensate for that transform — which cancels the live-drag
        // follow-translate (set last frame by applyInteractionState) and leaves
        // the block visually static (the "doesn't follow the finger" bug; the
        // residual compensation is the frameY jitter). With identity here, the
        // frame is computed cleanly and applyInteractionState re-applies the
        // translate afterward.
        layers.container.transform = CATransform3DIdentity
        layers.container.frame = frame
        layers.container.backgroundColor = UIColor.clear.cgColor
        layers.maskedContent.frame = localBounds
        layers.silhouetteMask.frame = localBounds

        // ── Compound interrupt geometry (spec 01 §16) ─────────────────────
        // Only non-interrupt parents that have embedded children in-day get a
        // compound silhouette. Mirrors the host's compoundParentRange /
        // childRangesForBlock + EventBlock's `compoundGeometry` / `compoundShape`.
        let resolvedRange = occurrence.range
        let childRanges: [Event.TimeRange] = isInterrupt
            ? []
            : interrupt.childRanges(
                for: occurrence,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd
            )
        let isEmbeddedMoat = isInterrupt
            && isEmbeddedChild
            && interrupt.parentColor(for: occurrence) != nil
        let needsMoat = isEmbeddedMoat || !childRanges.isEmpty
        let horizontalMoat: CGFloat = needsMoat ? 3 : 0
        let verticalMoat: CGFloat = needsMoat ? 2 : 0

        // Slice the parent range to this day's window (host
        // `compoundParentRangeForBlock`).
        let compoundParentRange: Event.TimeRange = {
            let clippedStart = max(resolvedRange.start, visibleStart)
            let clippedEnd = min(resolvedRange.end, visibleEnd)
            guard clippedEnd > clippedStart else { return resolvedRange }
            return Event.TimeRange(start: clippedStart, end: clippedEnd)
        }()

        let compoundGeometry: CalendarInterruptParentCompoundGeometry? = childRanges.isEmpty
            ? nil
            : calendarInterruptParentCompoundGeometry(
                parentRange: compoundParentRange,
                childRanges: childRanges,
                parentWidth: frame.width,
                parentHeight: frame.height,
                horizontalGap: horizontalMoat,
                verticalGap: verticalMoat
            )
        let compoundShape: CalendarInterruptParentCompoundShape? = {
            guard let geo = compoundGeometry, !geo.cutouts.isEmpty else { return nil }
            return CalendarInterruptParentCompoundShape(
                cornerRadius: max(cornerRadius, 4),
                visibleSegments: geo.visibleSegments
            )
        }()
        let usesNativeShapeMask = compoundShape != nil || isEmbeddedMoat

        // ── Silhouette path (spec 01 §3) ─────────────────────────────────
        // Priority: compound polygon → embedded/rounded rect.
        let silhouettePath: CGPath = {
            if let compoundShape {
                return compoundShape.path(in: localBounds).cgPath
            }
            // Continuous-curvature (squircle) corners to match SwiftUI's
            // `RoundedRectangle(style: .continuous)` (spec 01 §1.4 upgrade).
            return continuousRoundedRectPath(in: localBounds, cornerRadius: cornerRadius)
        }()
        layers.silhouetteMask.path = silhouettePath

        // ── Background fill (spec 01 §1) ─────────────────────────────────
        // Always fill a plain rect — the silhouette mask above clips it to the
        // final shape. (SwiftUI uses Rectangle when masked, RoundedRectangle
        // otherwise; with our hard mask the fill shape is irrelevant since the
        // mask clips, so a rect is equivalent and avoids double-rounding.)
        let bgPath = usesNativeShapeMask
            ? UIBezierPath(rect: localBounds).cgPath
            : continuousRoundedRectPath(in: localBounds, cornerRadius: cornerRadius)
        layers.bg.path = bgPath
        layers.bg.frame = localBounds
        layers.bg.fillColor = composite(tint: color, alpha: 0.4, over: .systemBackground).cgColor

        // ── Diagonal hatch (spec 01 §6), clipped by mask ─────────────────
        let isTimerActive = event.timerStartedAt != nil
        if isTimerActive {
            layers.hatch.isHidden = false
            layers.hatch.frame = localBounds
            layers.hatch.path = diagonalHatchPath(in: localBounds, spacing: 6)
            layers.hatch.strokeColor = color.withAlphaComponent(0.3).cgColor
            layers.hatch.lineWidth = 1
        } else {
            layers.hatch.isHidden = true
            layers.hatch.path = nil
        }

        // ── Agentic shimmer gradient (spec 01 §7a), STATIC, clipped ──────
        let phase = event.agenticIntake?.processingPhase
        let isAgenticAnalyzing = phase == .queued || phase == .analyzing
        if isAgenticAnalyzing {
            layers.agenticGradient.isHidden = false
            layers.agenticGradient.frame = localBounds
            layers.agenticGradient.colors = [
                UIColor.white.withAlphaComponent(0.05).cgColor,
                UIColor.white.withAlphaComponent(0.22).cgColor,
                UIColor.white.withAlphaComponent(0.05).cgColor
            ]
            layers.agenticGradient.startPoint = CGPoint(x: 0, y: 0)   // .topLeading
            layers.agenticGradient.endPoint = CGPoint(x: 1, y: 1)     // .bottomTrailing
            // Static (no drag in S1) → 0.18 multiplier.
            layers.agenticGradient.opacity = 0.18
        } else {
            layers.agenticGradient.isHidden = true
        }

        // ── Multi-type corner triangle (spec 01 §8), clipped ─────────────
        let showsMultiType = model.multiTypeEnabled
            && (event.additionalTypes?.isEmpty == false)
        if showsMultiType {
            layers.triangle.isHidden = false
            let size: CGFloat = 14
            let triRect = CGRect(x: frame.width - size, y: 0, width: size, height: size)
            let tri = UIBezierPath()
            tri.move(to: CGPoint(x: triRect.minX, y: triRect.minY))
            tri.addLine(to: CGPoint(x: triRect.maxX, y: triRect.minY))
            tri.addLine(to: CGPoint(x: triRect.maxX, y: triRect.maxY))
            tri.close()
            layers.triangle.frame = localBounds
            layers.triangle.path = tri.cgPath
            layers.triangle.fillColor = UIColor.label.withAlphaComponent(0.28).cgColor
        } else {
            layers.triangle.isHidden = true
            layers.triangle.path = nil
        }

        // ── Border (spec 01 §2), centered stroke, post-mask ──────────────
        // Stroke follows compound / embedded / rounded shape.
        let borderPath: CGPath = {
            if let compoundShape {
                return compoundShape.path(in: localBounds).cgPath
            }
            return continuousRoundedRectPath(in: localBounds, cornerRadius: cornerRadius)
        }()
        layers.border.frame = localBounds
        layers.border.path = borderPath
        layers.border.strokeColor = color.withAlphaComponent(0.7).cgColor
        layers.border.lineWidth = strokeWidth

        // ── Effort left bar (spec 01 §10), post-mask, own clip ───────────
        if event.colorDepth > 0 {
            layers.effortBar.isHidden = false
            let barWidth: CGFloat = model.isWeekMode
                ? 1.0 + CGFloat(event.colorDepth) * 1.5
                : 1.5 + CGFloat(event.colorDepth) * 2.5
            // Fill a leading strip, then clip to the block silhouette so the
            // top/bottom follow the rounded corners (matches the SwiftUI
            // double-mask: silhouette ∩ leading strip).
            let stripRect = CGRect(x: 0, y: 0, width: barWidth, height: frame.height)
            layers.effortBar.frame = localBounds
            layers.effortBar.path = UIBezierPath(rect: stripRect).cgPath
            layers.effortBar.fillColor = color.cgColor
            let clip = CAShapeLayer()
            clip.frame = localBounds
            clip.path = silhouettePath
            clip.fillColor = UIColor.white.cgColor
            layers.effortBar.mask = clip
        } else {
            layers.effortBar.isHidden = true
            layers.effortBar.path = nil
            layers.effortBar.mask = nil
        }

        // ── Todo border (spec 01 §4), INSET stroke, post-mask ────────────
        let isTodo = event.kind == .todo
        if isTodo && !event.isDone {
            layers.todoBorder.isHidden = false
            // strokeBorder = inset by half the line width.
            let inset: CGFloat = 0.5
            let insetRect = localBounds.insetBy(dx: inset, dy: inset)
            let insetRadius = max(0, cornerRadius - inset)
            layers.todoBorder.frame = localBounds
            layers.todoBorder.path = continuousRoundedRectPath(in: insetRect, cornerRadius: insetRadius)
            layers.todoBorder.strokeColor = todoBorderColor(for: event).cgColor
            layers.todoBorder.lineWidth = 1
        } else {
            layers.todoBorder.isHidden = true
            layers.todoBorder.path = nil
        }

        // ── Resize-handle capsules (spec 01 §11), visual only ────────────
        // Static S1: no edit style / long-press / preview-handle target, so
        // `showHandles` is false → opacity 0 (container present but invisible).
        // We still lay them out so S4 can flip visibility without a relayout.
        configureHandles(
            layers,
            frame: frame,
            color: color,
            compoundGeometry: compoundGeometry
        )
        // Static config seeds handles hidden; the real visibility (resize edge /
        // grace / long-press emphasis) is driven afterward by applyInteractionState.
        layers.topHandle.opacity = 0
        layers.bottomHandle.opacity = 0

        // ── Agentic spinner (spec 01 §7b), post-mask, static ─────────────
        if isAgenticAnalyzing {
            configureSpinner(layers, frame: frame, occurrenceID: occurrence.id)
        } else {
            layers.spinnerBacking.isHidden = true
            layers.spinner.isHidden = true
            removeSpinnerBlur(for: occurrence.id)
        }

        // ── Text (spec 01 §9), clipped by mask ───────────────────────────
        // Focused occurrence uses the `.edit` block style (showTimeRange:true);
        // all others use `.preview` (TimelineView.swift:5038 — blockStyle =
        // isEventFocused ? .edit : .preview).
        let isFocused = model.focusedEventID == event.id
            && (model.focusedOccurrenceID == nil || model.focusedOccurrenceID == occurrence.id)
        configureText(
            layers,
            frame: frame,
            event: event,
            occurrenceRange: occurrence.range,
            model: model,
            compoundGeometry: compoundGeometry,
            isInterrupt: isInterrupt,
            slot: slot,
            compoundParentRange: compoundParentRange,
            stackPeekStripWidth: stackPeekStripWidth,
            styleShowTimeRange: isFocused
        )

        // ── Opacity states (spec 01 §13) ─────────────────────────────────
        // Static path: no focus dim (isDimmedByFocus = false), no shadow
        // (isFocused / isInDragState = false). Done-todo fade applies (0.55).
        //
        // Deferred done-fade (FIX 2): seed the opacity from the LAGGED
        // `displayedDoneState`, NOT raw `event.isDone`, so this disable-actions
        // write doesn't eagerly snap the fade at the data flip ahead of
        // `applyInteractionState` (which always runs right after in every path
        // — render / cull / repaintVertical — and owns the real opacity + the
        // 0.4 deferred tween). On a first build `displayedDoneState` is still
        // nil, so we fall back to the real value, which `applyInteractionState`
        // then snaps to identically (no animation on first appear).
        let displayedDoneForSeed = layers.displayedDoneState ?? (isTodo && event.isDone)
        let doneFade: Float = displayedDoneForSeed ? 0.55 : 1.0
        layers.container.opacity = doneFade

        // Shadow (spec 01 §5): radius 3 iff focused/dragging — neither in S1.
        layers.container.shadowOpacity = 0
        layers.container.shadowRadius = 0

        // Block scale (spec 01 §12a): constant 1.0 — preserve as no-op.
        layers.container.transform = CATransform3DIdentity
    }

    // MARK: Resize handles (visual only — gesture is S4)

    private func configureHandles(
        _ layers: EventLayers,
        frame: CGRect,
        color: UIColor,
        compoundGeometry: CalendarInterruptParentCompoundGeometry?
    ) {
        // Static: not resizing → idle width, fill 0.45 * resizeHandleOpacity(=1).
        let handleFill = color.withAlphaComponent(0.45).cgColor
        let height: CGFloat = 3

        let top = calendarResizeHandlePlacement(
            viewWidth: frame.width,
            compoundGeometry: compoundGeometry,
            edge: .top
        )
        let topRect = CGRect(
            x: top.centerX - top.width / 2,
            y: 6.5 - height / 2,
            width: top.width,
            height: height
        )
        layers.topHandle.frame = CGRect(origin: .zero, size: frame.size)
        layers.topHandle.path = UIBezierPath(roundedRect: topRect, cornerRadius: height / 2).cgPath
        layers.topHandle.fillColor = handleFill

        let bottom = calendarResizeHandlePlacement(
            viewWidth: frame.width,
            compoundGeometry: compoundGeometry,
            edge: .bottom
        )
        let bottomRect = CGRect(
            x: bottom.centerX - bottom.width / 2,
            y: frame.height - 6.5 - height / 2,
            width: bottom.width,
            height: height
        )
        layers.bottomHandle.frame = CGRect(origin: .zero, size: frame.size)
        layers.bottomHandle.path = UIBezierPath(roundedRect: bottomRect, cornerRadius: height / 2).cgPath
        layers.bottomHandle.fillColor = handleFill
    }

    // MARK: Agentic spinner (static — animation is S5)

    private func configureSpinner(_ layers: EventLayers, frame: CGRect, occurrenceID: String) {
        // FIX 3: the spinner's frosted blur is a host SUBVIEW keyed by occurrence
        // id, re-positioned every render regardless of chip state — so when the
        // floating chip hides the source block, the blur circle would otherwise
        // be stranded at the source. Hide the source block AND its blur in
        // lockstep: when the chip owns this occurrence, tear the blur down (it
        // re-creates lazily via `spinnerBlurView(for:)` on the first render after
        // the drag ends, when `chipHidesSource(for:)` is false again) and leave
        // the ring CALayers hidden. Mirrors the `chipHidesSource` opacity-0 the
        // CALayer container gets in `applyInteractionState`.
        if chipHidesSource(for: occurrenceID) {
            layers.spinnerBacking.isHidden = true
            layers.spinnerBacking.path = nil
            layers.spinner.isHidden = true
            layers.spinner.path = nil
            removeSpinnerBlur(for: occurrenceID)
            return
        }
        // `.padding(5)` → ultraThinMaterial Circle → `.padding(5)`, top-right.
        // ProgressView(.small) is ~16pt; with 5pt inner padding the backing
        // circle is ~26pt; 5pt outer padding offsets from the corner.
        let spinnerDiameter: CGFloat = 16
        let backingDiameter = spinnerDiameter + 5 * 2
        let outerPad: CGFloat = 5
        let backingRect = CGRect(
            x: frame.width - outerPad - backingDiameter,
            y: outerPad,
            width: backingDiameter,
            height: backingDiameter
        )
        // Real ultraThinMaterial blur (spec 01 §7b upgrade): a CALayer can't
        // blur, so host a `UIVisualEffectView(.systemUltraThinMaterial)` as a
        // circular subview behind the spinner ring. Positioned in the host's
        // coordinate space (container.frame origin + local backingRect) and
        // circularly masked. The old translucent-fill `spinnerBacking` shape is
        // retired (hidden) now that the blur view provides the material.
        layers.spinnerBacking.isHidden = true
        layers.spinnerBacking.path = nil
        // The container-level spinner ring is retired in favor of a ring drawn
        // INSIDE the blur view's contentView (so it reads above the material —
        // a UIView subview otherwise occludes the host's own CALayer sublayers).
        layers.spinner.isHidden = true
        layers.spinner.path = nil

        let blur = spinnerBlurView(for: occurrenceID)
        // FIX 3: offset by the UNTRANSFORMED layout origin (`frame`, the same
        // origin the CALayer decorations are positioned from), NOT
        // `layers.container.frame`. `container` may carry a transform from a
        // PREVIOUS frame (drop-target 1.03 / absorption pulse 1.08), and
        // `CALayer.frame` is transform-adjusted — so reading it here would
        // desync the blur backing (a plain host subview that does NOT inherit
        // the container's scale) from the unscaled decorations whenever an
        // event is simultaneously analyzing AND a drop-target / pulsing. The
        // passed-in `frame` is the layout rect used to set `container.frame`
        // before any transform, so it tracks correctly in the normal
        // (untransformed) analyzing case too.
        let backingInHost = backingRect.offsetBy(dx: frame.minX, dy: frame.minY)
        blur.frame = backingInHost
        blur.layer.cornerRadius = backingDiameter / 2
        blur.layer.masksToBounds = true
        // Sit above the event content (UIView subviews already render above the
        // host's layer sublayers; this keeps a stable order among blur views).
        bringSubviewToFront(blur)

        // Static circular ring (the spin animation is S5) drawn in blur-local
        // coords, centered in the backing circle, on the contentView's layer.
        let ringLayer = blur.contentView.layer.sublayers?.first as? CAShapeLayer
            ?? {
                let l = CAShapeLayer()
                l.fillColor = UIColor.clear.cgColor
                blur.contentView.layer.addSublayer(l)
                return l
            }()
        ringLayer.frame = CGRect(origin: .zero, size: backingRect.size)
        let center = CGPoint(x: backingDiameter / 2, y: backingDiameter / 2)
        let ring = UIBezierPath(
            arcCenter: center,
            radius: spinnerDiameter / 2 - 1.5,
            startAngle: -.pi / 2,
            endAngle: .pi,
            clockwise: true
        )
        ringLayer.path = ring.cgPath
        ringLayer.strokeColor = UIColor.secondaryLabel.cgColor
        ringLayer.lineWidth = 2
        ringLayer.lineCap = .round
    }

    /// Reusable per-occurrence agentic-spinner blur backing
    /// (`systemUltraThinMaterial`). Created on demand and cached so a long
    /// analyzing phase doesn't churn views; torn down by `removeSpinnerBlur`.
    private func spinnerBlurView(for id: String) -> UIVisualEffectView {
        if let existing = spinnerBlurViews[id] { return existing }
        let effect = UIBlurEffect(style: .systemUltraThinMaterial)
        let v = UIVisualEffectView(effect: effect)
        v.isUserInteractionEnabled = false
        spinnerBlurViews[id] = v
        addSubview(v)
        return v
    }

    /// Remove and release an occurrence's spinner blur backing (event stopped
    /// analyzing, was culled, or recycled).
    private func removeSpinnerBlur(for id: String) {
        guard let v = spinnerBlurViews.removeValue(forKey: id) else { return }
        v.removeFromSuperview()
    }

    /// Tear down ALL hosted spinner blur backings (window detach). A parked
    /// `window == nil` column must not retain live `UIVisualEffectView`
    /// subviews. Safe to re-attach: a subsequent render of a still-analyzing
    /// event calls `configureSpinner` → `spinnerBlurView(for:)`, which lazily
    /// recreates the backing on demand (it was only cached, never required to
    /// persist across detaches).
    private func removeAllSpinnerBlurViews() {
        for (_, v) in spinnerBlurViews { v.removeFromSuperview() }
        spinnerBlurViews.removeAll()
    }

    // MARK: Text (spec 01 §9 — structural gates, NOT alpha)

    private func configureText(
        _ layers: EventLayers,
        frame: CGRect,
        event: Event,
        occurrenceRange: Event.TimeRange,
        model: Model,
        compoundGeometry: CalendarInterruptParentCompoundGeometry?,
        isInterrupt: Bool,
        slot: CalendarLayout.EventOverlapSlot,
        compoundParentRange: Event.TimeRange,
        stackPeekStripWidth: CGFloat,
        styleShowTimeRange: Bool
    ) {
        func hideAllText() {
            layers.title.isHidden = true
            layers.subtitle.isHidden = true
            layers.time.isHidden = true
            layers.title.string = nil
            layers.subtitle.string = nil
            layers.time.string = nil
        }

        guard model.showEventText else { hideAllText(); return }

        // ── Degenerate short-circuit (issue #14 perf) ────────────────────
        // Below the structural text floor (16pt — the height at which
        // `calendarEventTextLayout` returns nil and NO text renders) skip the
        // text layers entirely: no layout resolution, no cache lookup, no
        // `boundingRect`. A compound block this short has every contentRect
        // ≤ frame.height < 16 too, so it would also resolve to nil — the
        // short-circuit is parity-exact. This makes the zoomed-out / tiny-block
        // case (many short events) free of all text work.
        guard frame.height >= 16, frame.width >= 28 else {
            hideAllText()
            layers.lastTextLayoutKey = nil
            return
        }

        let titleFontSize = min(max(CGFloat(model.titleFontSizeSetting), 9), 16)
        let showsMultiType = model.multiTypeEnabled
            && (event.additionalTypes?.isEmpty == false)

        // ⚠️ failed-badge prefix: static S1 — phase==.failed shows the prefix.
        // The 5s-then-fade behavior is an animation (S5); the resting display
        // for a freshly-failed event is the prefixed title, so we show it.
        let isFailed = event.agenticIntake?.processingPhase == .failed
        let displayTitle = isFailed ? "⚠️ \(event.title)" : event.title

        // Stack-peek text geometry: augment compound geometry (or a full-rect
        // fallback) with cover bands so text avoids the covered region. Drives
        // ONLY text fitting (spec 01 §16e). Skip for interrupt events.
        let textGeometry: CalendarInterruptParentCompoundGeometry? = {
            guard !isInterrupt,
                  !slot.coverRanges.isEmpty,
                  stackPeekStripWidth > 0 else {
                return compoundGeometry
            }
            return calendarStackPeekTextGeometry(
                baseGeometry: compoundGeometry,
                eventRange: compoundParentRange,
                coverRanges: slot.coverRanges,
                parentWidth: frame.width,
                parentHeight: frame.height,
                peekStripWidth: stackPeekStripWidth
            )
        }()

        // Resolve text layout exactly as `EventBlock.content` does.
        let layout: CalendarEventTextLayout? = {
            if let textGeometry, !isInterrupt {
                return calendarInterruptParentTextLayout(
                    geometry: textGeometry,
                    title: displayTitle,
                    styleShowTimeRange: styleShowTimeRange, // .edit when focused, else .preview
                    isWeekMode: model.isWeekMode,
                    isThreeDayMode: model.isThreeDayMode,
                    baseFontSize: titleFontSize,
                    showTimeBelowTitle: model.showTimeBelowTitle
                )
            }
            return calendarEventTextLayout(
                in: CGRect(origin: .zero, size: frame.size),
                title: displayTitle,
                requireTitleFit: false,
                styleShowTimeRange: styleShowTimeRange, // .edit when focused, else .preview
                isWeekMode: model.isWeekMode,
                isThreeDayMode: model.isThreeDayMode,
                baseFontSize: titleFontSize,
                showTimeBelowTitle: model.showTimeBelowTitle
            )
        }()

        guard let layout else { hideAllText(); return }

        let timeFontSize = calendarEventTimeFontSize(
            forTitleFontSize: titleFontSize,
            isWeekMode: layout.isWeekMode
        )
        let titleSpacing = calendarEventBlockTitleSpacing(
            isWeekMode: layout.isWeekMode,
            isThreeDayMode: layout.isThreeDayMode
        )

        // Build the VStack-equivalent: title, optional subtitle, optional time.
        let titleFont = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let titleLineHeight = titleFont.lineHeight
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium)
        let subtitleFont = UIFont.systemFont(ofSize: timeFontSize, weight: .medium)

        let contentRect = layout.contentRect
        var cursorY = contentRect.minY

        // Title height = the title's ACTUAL wrapped height (capped at the line
        // limit), not the full line-limit reservation — so the time/subtitle row
        // stacks tight under a short title like SwiftUI's intrinsic-height VStack,
        // instead of being pushed down by unused reserved lines.
        //
        // The wrapping/measurement (`boundingRect`) depends only on (title,
        // width, font) — height-independent — so we memoize the UNBOUNDED
        // natural wrapped height per occurrence (issue #14). The height-dependent
        // CAP (`maxTitleHeight`, from `titleLineLimit` × lineHeight clamped to
        // the contentRect height) is applied per-frame as a cheap O(1) min — the
        // structural gate stays per-frame, only the measurement is cached.
        //
        // Parity: measuring with an unbounded height then applying
        // `min(ceil(h/lh)*lh, maxTitleHeight)` is identical to the previous
        // measure-with-`maxTitleHeight` form. A constrained `boundingRect` only
        // ever yields ≤ maxTitleHeight worth of line fragments; the subsequent
        // `min(..., maxTitleHeight)` clamps the unbounded measurement to the same
        // value, so the rounded line-snapped result matches byte-for-byte.
        let maxTitleHeight = min(CGFloat(layout.titleLineLimit) * titleLineHeight, contentRect.height)
        let textKey = EventLayers.TextLayoutKey(
            title: displayTitle,
            contentWidth: contentRect.width,
            titleFontSize: titleFontSize,
            styleShowTimeRange: styleShowTimeRange,
            showTimeBelowTitle: model.showTimeBelowTitle,
            isWeekMode: model.isWeekMode,
            isThreeDayMode: model.isThreeDayMode,
            showsMultiType: showsMultiType,
            subtitleText: showsMultiType ? multiTypeSubtitleText(for: event) : ""
        )
        let naturalTitleHeight: CGFloat
        #if DEBUG
        let bypassTextCache = CalendarTextMeasureCache.bypassForBenchmark
        #else
        let bypassTextCache = false
        #endif
        if !bypassTextCache, layers.lastTextLayoutKey == textKey {
            // Cache hit (the pinch fast path): width/string/font unchanged →
            // reuse the cached unbounded measurement, zero `boundingRect`.
            naturalTitleHeight = layers.cachedNaturalTitleHeight
        } else {
            naturalTitleHeight = CalendarTextMeasureCache.boundingHeight(
                for: displayTitle,
                width: contentRect.width,
                constrainHeight: .greatestFiniteMagnitude,
                font: titleFont,
                fontSize: titleFontSize,
                weight: UIFont.Weight.semibold,
                monospacedDigit: false
            )
            layers.lastTextLayoutKey = textKey
            layers.cachedNaturalTitleHeight = naturalTitleHeight
        }
        let titleHeight = min(ceil(naturalTitleHeight / titleLineHeight) * titleLineHeight, maxTitleHeight)
        layers.title.isHidden = false
        layers.title.frame = CGRect(
            x: contentRect.minX,
            y: cursorY,
            width: contentRect.width,
            height: titleHeight
        )
        layers.title.font = titleFont
        layers.title.fontSize = titleFontSize
        layers.title.foregroundColor = UIColor.label.cgColor
        layers.title.string = displayTitle
        cursorY += titleHeight + titleSpacing

        // Multi-type subtitle (primary @ 0.55), single line.
        if showsMultiType {
            let subtitleText = multiTypeSubtitleText(for: event)
            if !subtitleText.isEmpty {
                layers.subtitle.isHidden = false
                layers.subtitle.frame = CGRect(
                    x: contentRect.minX,
                    y: cursorY,
                    width: contentRect.width,
                    height: subtitleFont.lineHeight
                )
                layers.subtitle.font = subtitleFont
                layers.subtitle.fontSize = timeFontSize
                layers.subtitle.foregroundColor = UIColor.label.withAlphaComponent(0.55).cgColor
                layers.subtitle.isWrapped = false
                layers.subtitle.string = subtitleText
                cursorY += subtitleFont.lineHeight + titleSpacing
            } else {
                layers.subtitle.isHidden = true
                layers.subtitle.string = nil
            }
        } else {
            layers.subtitle.isHidden = true
            layers.subtitle.string = nil
        }

        // Time range (secondary), single line. Static path: displayed range
        // == the occurrence's rendered range.
        if layout.showsTimeRange {
            let formatter = Self.timeFormatter()
            let timeStr = "\(formatter.string(from: occurrenceRange.start)) - \(formatter.string(from: occurrenceRange.end))"
            layers.time.isHidden = false
            layers.time.frame = CGRect(
                x: contentRect.minX,
                y: cursorY,
                width: contentRect.width,
                height: timeFont.lineHeight
            )
            layers.time.font = timeFont
            layers.time.fontSize = timeFontSize
            layers.time.foregroundColor = UIColor.secondaryLabel.cgColor
            layers.time.isWrapped = false
            layers.time.string = timeStr
        } else {
            layers.time.isHidden = true
            layers.time.string = nil
        }
    }

    // MARK: Helpers

    /// Multi-type subtitle (spec 01 §9d): `effectiveTypes` primary-first joined
    /// by " · "; empty if < 2 types.
    private func multiTypeSubtitleText(for event: Event) -> String {
        let allTypes = event.effectiveTypes.filter { !$0.isEmpty }
        guard allTypes.count >= 2 else { return "" }
        return allTypes.joined(separator: " · ")
    }

    /// Todo border urgency ramp (spec 01 §4), evaluated against now.
    private func todoBorderColor(for event: Event) -> UIColor {
        let subtle = UIColor.white.withAlphaComponent(0.45)
        guard event.kind == .todo, !event.isDone else { return subtle }
        guard let dl = event.deadline else { return subtle }
        let now = Date()
        if dl < now { return UIColor.red.withAlphaComponent(0.9) }
        if dl.timeIntervalSince(now) < 24 * 3600 { return UIColor.orange.withAlphaComponent(0.9) }
        return subtle
    }

    /// Time formatter mirroring `EventBlock` (24h `H:mm` / 12h `h:mm a`).
    private static func timeFormatter() -> DateFormatter {
        if AppTimeFormat.current.is24 {
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            return f
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }

    /// Continuous-curvature ("squircle") rounded-rect path matching SwiftUI's
    /// `RoundedRectangle(style: .continuous)` (spec 01 §1.4 parity upgrade).
    ///
    /// Apple's continuous corner is a superellipse-like blend, NOT a circular
    /// arc. iOS builds it from the documented control-point construction where
    /// the corner spans ~1.528665× the nominal radius along each edge and the
    /// curve is two cubic Béziers per corner. The magic ratios below are the
    /// published PaintCode/Figma-derived constants that reproduce
    /// `UIBezierPath` continuous corners to sub-pixel accuracy. When the radius
    /// is large relative to the side (`limit`), the construction degrades
    /// gracefully toward the circular form, matching SwiftUI's clamp.
    ///
    /// Used for ALL simple (non-compound) rounded-rect blocks so the silhouette
    /// mask, background fill, centered border, todo border, and effort-bar clip
    /// all share the identical continuous curve. Compound interrupt silhouettes
    /// keep `CalendarInterruptParentCompoundShape` (a quad-curve polygon that
    /// already matches SwiftUI's own compound shape — SwiftUI does NOT use a
    /// continuous superellipse there, so no upgrade is needed for compounds).
    private func continuousRoundedRectPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let radius = max(0, min(cornerRadius, limit))
        guard radius > 0 else { return UIBezierPath(rect: rect).cgPath }

        // The continuous-corner "comfortable" extent is up to 1.528665×r along
        // each edge. If two adjacent corners would overlap, fall back to the
        // proportional construction Apple uses (scale all constants by the
        // available room) so the shape never self-intersects.
        let maxExtent = min(rect.width, rect.height) / 2
        let p = min(radius * 1.528665, maxExtent)

        // Per-corner cubic control constants (fractions of `p`), from Apple's
        // continuous-curve construction.
        let c1 = p * 1.0
        let c2 = p * 0.83255
        let c3 = p * 0.68678
        let c4 = p * 0.43687
        let c5 = p * 0.26835
        let c6 = p * 0.05904

        let path = UIBezierPath()
        let minX = rect.minX, minY = rect.minY
        let maxX = rect.maxX, maxY = rect.maxY

        // Top edge → top-right corner
        path.move(to: CGPoint(x: minX + p, y: minY))
        path.addLine(to: CGPoint(x: maxX - p, y: minY))
        path.addCurve(
            to: CGPoint(x: maxX - c3, y: minY + c6),
            controlPoint1: CGPoint(x: maxX - c2, y: minY),
            controlPoint2: CGPoint(x: maxX - c4, y: minY + c6)
        )
        path.addCurve(
            to: CGPoint(x: maxX - c6, y: minY + c3),
            controlPoint1: CGPoint(x: maxX - c5, y: minY + c5),
            controlPoint2: CGPoint(x: maxX - c6, y: minY + c4)
        )
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + c1),
            controlPoint1: CGPoint(x: maxX - c6, y: minY + c4),
            controlPoint2: CGPoint(x: maxX, y: minY + c2)
        )
        // Right edge → bottom-right corner
        path.addLine(to: CGPoint(x: maxX, y: maxY - p))
        path.addCurve(
            to: CGPoint(x: maxX - c6, y: maxY - c3),
            controlPoint1: CGPoint(x: maxX, y: maxY - c2),
            controlPoint2: CGPoint(x: maxX - c6, y: maxY - c4)
        )
        path.addCurve(
            to: CGPoint(x: maxX - c3, y: maxY - c6),
            controlPoint1: CGPoint(x: maxX - c6, y: maxY - c4),
            controlPoint2: CGPoint(x: maxX - c5, y: maxY - c5)
        )
        path.addCurve(
            to: CGPoint(x: maxX - c1, y: maxY),
            controlPoint1: CGPoint(x: maxX - c4, y: maxY - c6),
            controlPoint2: CGPoint(x: maxX - c2, y: maxY)
        )
        // Bottom edge → bottom-left corner
        path.addLine(to: CGPoint(x: minX + p, y: maxY))
        path.addCurve(
            to: CGPoint(x: minX + c3, y: maxY - c6),
            controlPoint1: CGPoint(x: minX + c2, y: maxY),
            controlPoint2: CGPoint(x: minX + c4, y: maxY - c6)
        )
        path.addCurve(
            to: CGPoint(x: minX + c6, y: maxY - c3),
            controlPoint1: CGPoint(x: minX + c5, y: maxY - c5),
            controlPoint2: CGPoint(x: minX + c6, y: maxY - c4)
        )
        path.addCurve(
            to: CGPoint(x: minX, y: maxY - c1),
            controlPoint1: CGPoint(x: minX + c6, y: maxY - c4),
            controlPoint2: CGPoint(x: minX, y: maxY - c2)
        )
        // Left edge → top-left corner
        path.addLine(to: CGPoint(x: minX, y: minY + p))
        path.addCurve(
            to: CGPoint(x: minX + c6, y: minY + c3),
            controlPoint1: CGPoint(x: minX, y: minY + c2),
            controlPoint2: CGPoint(x: minX + c6, y: minY + c4)
        )
        path.addCurve(
            to: CGPoint(x: minX + c3, y: minY + c6),
            controlPoint1: CGPoint(x: minX + c6, y: minY + c4),
            controlPoint2: CGPoint(x: minX + c5, y: minY + c5)
        )
        path.addCurve(
            to: CGPoint(x: minX + c1, y: minY),
            controlPoint1: CGPoint(x: minX + c4, y: minY + c6),
            controlPoint2: CGPoint(x: minX + c2, y: minY)
        )
        path.close()
        return path.cgPath
    }

    /// Diagonal hatch path (spec 01 §6): 45° lines bottom-left → top-right,
    /// generated from -height to width+height, spaced `spacing` pt.
    private func diagonalHatchPath(in rect: CGRect, spacing: CGFloat) -> CGPath {
        let path = UIBezierPath()
        let totalLength = rect.width + rect.height
        var offset: CGFloat = -rect.height
        while offset < totalLength {
            path.move(to: CGPoint(x: offset, y: rect.height))
            path.addLine(to: CGPoint(x: offset + rect.height, y: 0))
            offset += spacing
        }
        return path.cgPath
    }

    /// Precomposite a tint color at `alpha` over an opaque base so a single
    /// `CAShapeLayer` fill reproduces the SwiftUI two-layer (opaque base +
    /// color@0.4) result exactly, without a second sublayer.
    private func composite(tint: UIColor, alpha: CGFloat, over base: UIColor) -> UIColor {
        UIColor { traits in
            let b = base.resolvedColor(with: traits)
            let t = tint.resolvedColor(with: traits)
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            t.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            // Standard source-over: out = tint*a + base*(1-a) (base is opaque).
            let a = alpha * ta
            return UIColor(
                red: tr * a + br * (1 - a),
                green: tg * a + bg * (1 - a),
                blue: tb * a + bb * (1 - a),
                alpha: 1
            )
        }
    }
}

// MARK: - Interrupt relationship context (static-case host mirror)

/// Static-case mirror of `TimelineView`'s non-live interrupt lookups
/// (`interruptParentLookup` / `interruptChildrenLookup` / `embeddedInterruptIDs`).
/// Used by the CALayer day view to derive compound-parent cutouts and embedded
/// child overlay geometry from occurrences alone (no drag state in S1).
private struct InterruptContext {
    /// parent anchor id → parent occurrence
    let parentLookup: [UUID: CalendarLayout.EventOccurrence]
    /// parent id → embedded child occurrences
    let childrenLookup: [UUID: [CalendarLayout.EventOccurrence]]
    /// occurrence ids that are embedded interrupt children overlapping a parent
    let embeddedIDs: Set<String>

    init(occurrences: [CalendarLayout.EventOccurrence]) {
        var parents: [UUID: CalendarLayout.EventOccurrence] = [:]
        for occ in occurrences where !occ.event.isInterrupt {
            parents[Self.anchorID(for: occ.event)] = occ
        }

        var children: [UUID: [CalendarLayout.EventOccurrence]] = [:]
        for occ in occurrences {
            guard let rel = occ.event.interruptRelation, rel.state == .embedded else { continue }
            children[rel.parentEventID, default: []].append(occ)
        }

        var embedded = Set<String>()
        for occ in occurrences {
            guard occ.event.isInterrupt,
                  let rel = occ.event.interruptRelation, rel.state == .embedded,
                  let parent = parents[rel.parentEventID] else { continue }
            let parentRange = parent.range
            if occ.range.end > parentRange.start && occ.range.start < parentRange.end {
                embedded.insert(occ.id)
            }
        }

        self.parentLookup = parents
        self.childrenLookup = children
        self.embeddedIDs = embedded
    }

    static func anchorID(for event: Event) -> UUID {
        event.recurrenceParentId ?? event.id
    }

    /// FIX 1: occurrence ids of the embedded interrupt children whose PARENT is
    /// `parentEvent`. Used to make a dragged interrupt parent's children follow
    /// the parent out of the source day's overlap (so they don't strand as
    /// full-width default-column blocks re-laying-out every drag frame) and to
    /// hide them while the parent's chip is up. Empty when `parentEvent` is an
    /// interrupt itself or has no embedded children (drag is then a no-op here).
    func embeddedChildIDs(ofParent parentEvent: Event) -> Set<String> {
        guard !parentEvent.isInterrupt,
              let children = childrenLookup[Self.anchorID(for: parentEvent)] else {
            return []
        }
        return Set(children.map(\.id)).intersection(embeddedIDs)
    }

    /// Child ranges of a parent occurrence, clipped to in-day visibility
    /// (mirror of host `childRangesForBlock`).
    func childRanges(
        for occurrence: CalendarLayout.EventOccurrence,
        visibleStart: Date,
        visibleEnd: Date
    ) -> [Event.TimeRange] {
        guard !occurrence.event.isInterrupt,
              let children = childrenLookup[Self.anchorID(for: occurrence.event)] else {
            return []
        }
        let parentRange = occurrence.range
        return children.compactMap { child in
            let r = child.range
            guard r.end > parentRange.start, r.start < parentRange.end else { return nil }
            guard r.end > visibleStart, r.start < visibleEnd else { return nil }
            return r
        }
    }

    /// Primary type color of an interrupt child's parent (mirror of host
    /// `parentColorForBlock`).
    func parentColor(for occurrence: CalendarLayout.EventOccurrence) -> Color? {
        guard let rel = occurrence.event.interruptRelation,
              let parentOcc = parentLookup[rel.parentEventID] else { return nil }
        return CalendarLayout.eventColor(for: parentOcc.event)
    }

    struct ParentContext {
        let width: CGFloat
        let x: CGFloat
        let hasOverlap: Bool
        let zIndex: CGFloat
    }

    /// Resolves the parent slot geometry for an embedded interrupt child
    /// (mirror of host `interruptParentSlotContext` + width/x derivation).
    func parentSlotContext(
        for occurrence: CalendarLayout.EventOccurrence,
        slots: [String: CalendarLayout.EventOverlapSlot],
        eventAreaWidth: CGFloat,
        inset: CGFloat
    ) -> ParentContext? {
        guard let rel = occurrence.event.interruptRelation,
              let parentOcc = parentLookup[rel.parentEventID],
              let parentSlot = slots[parentOcc.id] else { return nil }
        let width = eventAreaWidth * parentSlot.widthFraction
        let x = inset + eventAreaWidth * parentSlot.xOffsetFraction
        return ParentContext(
            width: width,
            x: x,
            hasOverlap: parentSlot.widthFraction < 1,
            zIndex: CGFloat(parentSlot.zIndex)
        )
    }
}

// MARK: - Gesture controller (S4)

/// Drives move / resize / drag-to-create / edge-auto-scroll / boundary-paging
/// / absorption-drop-targeting / tap-deselect on a persistent `DayLayerHostView`.
///
/// This is the UIKit-state home the spec demands (05 section 7, 06 G-79..81):
/// the live drag offset, the decided drag mode, the captured scroll-view refs,
/// and the accumulated auto-scroll compensation all live here as plain fields
/// — never in `@Published` — so a SwiftUI content rebuild cannot destroy them
/// mid-drag and per-frame writes never invalidate the host body. Only the
/// COARSE fields (`draggingEventID`, `currentDropTargetEventID`, `dragMode`,
/// edge flags, touch point) mirror back into the observed `EventDragState`.
///
/// The pure logic (mode resolution, promotion gate, snap math, auto-scroll
/// curve + compensation, boundary-page offset, drag→time mapping, terminal
/// state, adjacent snap) is REUSED verbatim from the shared free functions —
/// the SwiftUI `EventBlockDragGesture.Coordinator` and `CreationDragGesture`
/// call the same ones, so there is one source of truth and no parity drift.
final class CalendarDayGestureController: NSObject, UIGestureRecognizerDelegate {

    private weak var host: DayLayerHostView?
    var callbacks = DayLayerHostView.Callbacks()

    // Recognizers (G-1, G-46). Event drag uses the 0.35s manipulation hold;
    // create uses the 0.5s wired duration; tap is the empty-space deselect.
    private var eventGesture: TracingLongPressGesture?
    private var createGesture: UILongPressGestureRecognizer?
    private var tapGesture: UITapGestureRecognizer?

    init(host: DayLayerHostView) {
        self.host = host
    }

    func installGestures(on view: DayLayerHostView) {
        let event = TracingLongPressGesture(target: self, action: #selector(handleEventGesture(_:)))
        event.minimumPressDuration = calendarEventManipulationLongPressDuration // 0.35
        event.delegate = self
        view.addGestureRecognizer(event)
        eventGesture = event

        let create = UILongPressGestureRecognizer(target: self, action: #selector(handleCreateGesture(_:)))
        create.minimumPressDuration = 0.5 // wired value (G-46)
        create.delegate = self
        view.addGestureRecognizer(create)
        createGesture = create

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        tapGesture = tap
    }

    deinit {
        // Terminal recovery (G-32): synthesize a `.cancelled` if a drag was
        // mid-flight so the host never sees a nil `onDragEnded`.
        if calendarDragGestureNeedsTerminalRecovery(
            hasActiveGesture: activeGesture != nil,
            isDragging: eventSession != nil,
            hasMovedAfterLongPress: hasMovedAfterLongPress,
            hasPromotedManipulation: hasPromotedManipulation,
            dragOffset: liveResolvedOffset,
            isHorizontalEdgeDragging: mirroredEdgeDragging,
            isHorizontalAutoScrolling: mirroredAutoScrolling
        ) {
            if let session = eventSession {
                callbacks.onEventLongPressResolved?(
                    CalendarEventLongPressResolution(
                        event: session.event,
                        occurrenceID: session.occurrenceID,
                        actionDate: session.originalRange.start,
                        dragMode: session.mode,
                        terminalState: .cancelled,
                        didMove: hasMovedAfterLongPress,
                        touchPointGlobal: lastLocationInWindow
                    )
                )
            }
            calendarResetSharedEventDragStateIfPresent()
        }
        stopAutoScroll()
        restoreScrollPanGestures()
    }

    /// Window-detach teardown (blocker #1): invalidate BOTH `CADisplayLink`s
    /// (move/resize auto-scroll + creation auto-scroll) — each retains `self`
    /// as its `target:`, so an unstopped link outliving the view detach would
    /// keep this controller (and the host) alive past `deinit`. Also cleanly
    /// terminate any in-flight drag (synthesizing a `.cancelled` resolution so
    /// the host never sees a dropped `onDragEnded`) and reset creation state.
    /// Idempotent and crash-safe: `stopAutoScroll`/`stopCreationAutoScroll`
    /// invalidate-then-nil their link, so a second call is a no-op (no
    /// double-invalidate).
    func cancelActiveInteractionsOnDetach() {
        // 1. Kill both display links first so no further ticks fire mid-teardown.
        stopAutoScroll()
        stopCreationAutoScroll()

        // 2. Cleanly resolve ANY in-flight session — promoted (a live
        //    move/resize) OR merely STAGED (an unpromoted long-press that has
        //    already fired `onEventLongPressBegan`, raising focus / the
        //    express menu at the TimelineView level). Both the normal gesture
        //    terminal (the `.ended/.cancelled/.failed` handler) and `deinit`
        //    fire `onEventLongPressResolved` for the unpromoted case to clear
        //    that staged host state; if we resolved only promoted sessions
        //    here, a detach-while-staged (column recycled, so `deinit` may
        //    never run) would strand the host's focus/menu state forever.
        //    Mirror `deinit`'s `.cancelled` / `didMove: hasMovedAfterLongPress`
        //    form (`hasMovedAfterLongPress` is false for a staged press) and
        //    only reset the SHARED drag scratchpad for a promoted drag (a
        //    staged press never wrote it — `syncSharedDragStateForBegin` runs
        //    only on promotion).
        if let session = eventSession {
            let resolution = CalendarEventLongPressResolution(
                event: session.event,
                occurrenceID: session.occurrenceID,
                actionDate: session.originalRange.start,
                dragMode: session.mode,
                terminalState: .cancelled,
                didMove: hasMovedAfterLongPress,
                touchPointGlobal: lastLocationInWindow
            )
            // Re-entrancy (finding #4): unlike `deinit` (which runs at dealloc,
            // outside any view-update pass), this runs synchronously inside
            // `didMoveToWindow`, which is typically invoked DURING a SwiftUI-
            // driven view-hierarchy mutation. Firing the resolution here would
            // mutate TimelineView's focus / express-menu @State mid-update
            // ("Modifying state during view update" hazard). Defer it one
            // runloop tick so the write lands after the current update settles.
            // We capture the resolution closure by VALUE (not via `self`), so
            // the callback still fires even if this controller / host is torn
            // down before the tick — closing the dropped-resolution gap the
            // task flagged. Resetting the SHARED scratchpad (a promoted-only
            // concern) likewise rides the tick.
            let resolved = callbacks.onEventLongPressResolved
            let dragStateToReset = hasPromotedManipulation ? callbacks.dragState : nil
            DispatchQueue.main.async {
                resolved?(resolution)
                if let dragStateToReset {
                    calendarResetSharedEventDragState(dragStateToReset)
                }
            }
        }
        eventSession = nil
        finalizeTouchInteraction()

        // 3. Reset any in-flight drag-to-create.
        if isCreating || isLongPressingCreation {
            resetCreationState()
        }
    }

    // MARK: Active session exposed to the renderer

    /// Identity + base range + mode of the actively dragged occurrence, read
    /// by the host to render the live preview block. Set ONLY after the drag
    /// promotes past 8pt (G-13); nil during a staged long-press or no drag.
    struct EventSession {
        let event: Event
        let occurrenceID: String
        let originalRange: Event.TimeRange
        var mode: EventDragMode
    }
    private(set) var eventSession: EventSession?
    /// Exposed to the renderer only once promoted (so the static block doesn't
    /// jump before the 8pt threshold).
    var activeEventSession: EventSession? { hasPromotedManipulation ? eventSession : nil }
    /// The resolved (snapped / clamped) live offset for the current frame.
    private(set) var liveResolvedOffset: DragOffset = .zero

    // MARK: Plain UIKit drag state (mirrors EventBlock.Coordinator fields)

    private weak var activeGesture: UILongPressGestureRecognizer?
    private var initialPointInWindow: CGPoint = .zero
    private var lastLocationInWindow: CGPoint = .zero
    private var autoScrollCompensationX: CGFloat = 0
    private var autoScrollCompensationY: CGFloat = 0
    private weak var horizontalScrollView: UIScrollView?
    private weak var verticalScrollView: UIScrollView?
    private var autoScrollVelocityX: CGFloat = 0
    private var autoScrollVelocityY: CGFloat = 0
    private var autoScrollDisplayLink: CADisplayLink?
    private var isHorizontalSnapSuppressed = false
    private var hasMovedAfterLongPress = false
    private var hasPromotedManipulation = false
    private var currentMode: EventDragMode = .move
    private var lastSnappedStep = 0
    private var verticalDragBounds: ClosedRange<CGFloat> = -.infinity ... .infinity
    private var lastHorizontalBoundaryPageTimestamp: CFTimeInterval = 0
    private let horizontalBoundaryPageMinimumInterval: CFTimeInterval = 0.8
    private var horizontalBoundaryPageCount = 0
    private var horizontalBoundaryPageOriginX: CGFloat = 0
    private var disabledScrollGestures: [(gesture: UIGestureRecognizer, wasEnabled: Bool)] = []
    private var savedCanCancelContentTouches: [(scrollView: UIScrollView, wasEnabled: Bool)] = []
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private var mirroredEdgeDragging = false
    private var mirroredAutoScrolling = false

    // Floating cross-day drag chip (move-only). A single window-space UIView
    // that follows the finger; snaps its X to the day-column under the finger
    // while horizontal snap is NOT suppressed, free-follows the finger while it
    // is (edge / auto-scroll). Rendered above all columns so it never clips.
    private var dragChip: UIView?
    private var chipGrabOffset: CGSize = .zero      // finger→block-center at promotion (window space)
    private var chipSourceSize: CGSize = .zero
    private var lastSnappedColumnCenterX: CGFloat?  // avoid re-springing every frame
    private(set) var isChipActive = false
    // The host currently showing the in-grid drag preview (so we can clear it
    // when the finger moves to a different day or the drag ends).
    private weak var lastPreviewHost: DayLayerHostView?

    // Creation drag state (mirrors CreationDragGesture consumer @State).
    private var isCreating = false
    private var isLongPressingCreation = false
    private var creationStartY: CGFloat = 0
    private var creationCurrentY: CGFloat = 0
    private var lastTickMinutes = -1
    private var lastSnappedStartEdge: Date?
    private var lastSnappedEndEdge: Date?
    private var creationAutoScrollLink: CADisplayLink?
    private let creationActivationThreshold: CGFloat = 18
    private let adjacentEventSnapThresholdPt: CGFloat = 8
    private let createHaptic = UIImpactFeedbackGenerator(style: .light)
    private let snapHaptic = UISelectionFeedbackGenerator()

    private var usesHorizontalBoundaryPaging: Bool {
        guard let m = host?.liveModel else { return false }
        return m.dayColumnStep <= 0 && m.dragPreviewDayStep > 0
    }
    private var dayColumnStep: CGFloat { host?.liveModel?.dayColumnStep ?? 0 }
    private var dragPreviewDayStep: CGFloat { host?.liveModel?.dragPreviewDayStep ?? 0 }

    private func calendarResetSharedEventDragStateIfPresent() {
        if let dragState = callbacks.dragState {
            calendarResetSharedEventDragState(dragState)
        }
    }

    // MARK: Hit testing

    /// Returns the occurrence under `pointInView` honoring the same
    /// fall-through inset as the SwiftUI hit area (G-3/4/5): a touch in the
    /// top/bottom edge band of a block falls through to drag-to-create.
    /// Topmost (deepest z) wins.
    private func eventOccurrence(at pointInView: CGPoint) -> DayLayerHostView.RenderedEventFrame? {
        guard let host else { return nil }
        var best: (frame: DayLayerHostView.RenderedEventFrame, z: CGFloat)?
        for (_, rf) in host.renderedFrames {
            let frame = rf.frame
            guard frame.contains(pointInView) else { continue }
            // Fall-through edge inset (smoothstep) — only blocks without
            // visible resize handles use the 6pt band; focused/grace blocks
            // keep their full edge so handles stay hittable.
            let model = host.liveModel
            let isFocused = model?.focusedEventID == rf.occurrence.event.id
            let inset = isFocused ? 0 : calendarFallThroughEdgeInsetPublic(maxInset: 6, height: frame.height)
            if inset > 0 {
                let band = frame.insetBy(dx: 0, dy: inset)
                if !band.contains(pointInView) { continue }
            }
            let z = CGFloat(rf.slot.zIndex) + (rf.isEmbeddedChild ? 1000 : 0)
            if best == nil || z > best!.z {
                best = (rf, z)
            }
        }
        return best?.frame
    }

    // MARK: Delegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Event drag: coexist only AFTER promotion so nothing cancels an
        // active drag, but stay exclusive before (G-34). Create gesture is
        // exclusive (G-46).
        if gestureRecognizer === eventGesture {
            return hasPromotedManipulation
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host, let view = gestureRecognizer.view else { return true }
        let point = gestureRecognizer.location(in: view)
        let hit = eventOccurrence(at: point)
        // Route the touch: event gesture begins only over a block; the
        // create / tap gestures begin only on empty canvas (mirrors the
        // SwiftUI layering where the creation layer sits beneath events and
        // the fall-through inset hands edge-band touches to it).
        if gestureRecognizer === eventGesture {
            // Suppress during pinch (G-2/71) and require an interaction-allowed
            // block (focus gating, G-81).
            if host.liveModel?.isPinchActive == true { return false }
            return hit != nil && isInteractionAllowed(for: hit!)
        }
        if gestureRecognizer === createGesture {
            return hit == nil && callbacks.onCreateEvent != nil
        }
        if gestureRecognizer === tapGesture {
            // Tap handles BOTH cases (see handleTap): over a block → onEventTap
            // (open detail); empty canvas → onNonEventTap. Gating this to
            // `hit == nil` dead-ended the event-tap branch, so tapping an event
            // opened nothing. A quick tap and the 0.35s event long-press are
            // mutually exclusive by timing, so beginning over a block is safe.
            return true
        }
        return true
    }

    private func isInteractionAllowed(for hit: DayLayerHostView.RenderedEventFrame) -> Bool {
        guard let model = host?.liveModel else { return true }
        return calendarShouldAllowEventInteraction(
            focusedEventID: model.focusedEventID,
            candidateEventID: hit.occurrence.event.id,
            isFocusContextActive: model.isFocusContextActive
        )
    }

    // MARK: Tap (G-53, G-63)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let host, let view = gesture.view else { return }
        let point = gesture.location(in: view)
        if let hit = eventOccurrence(at: point) {
            callbacks.onEventTap?(hit.occurrence.event, hit.occurrence.range.start)
        } else {
            callbacks.onNonEventTap?()
        }
        _ = host
    }

    // MARK: Event move / resize (G-6..G-34)

    @objc private func handleEventGesture(_ gesture: UILongPressGestureRecognizer) {
        guard let host, let view = gesture.view else { return }
        let location = gesture.location(in: view)

        switch gesture.state {
        case .began:
            guard let hit = eventOccurrence(at: location) else { return }
            initialPointInWindow = gesture.location(in: nil)
            lastLocationInWindow = initialPointInWindow
            activeGesture = gesture
            let targets = findScrollTargets(startingAt: view)
            horizontalScrollView = targets.horizontal
            verticalScrollView = targets.vertical
            autoScrollCompensationX = 0
            autoScrollCompensationY = 0
            autoScrollVelocityX = 0
            autoScrollVelocityY = 0
            isHorizontalSnapSuppressed = false
            hasMovedAfterLongPress = false
            hasPromotedManipulation = false
            lastSnappedStep = 0
            lastHorizontalBoundaryPageTimestamp = 0
            horizontalBoundaryPageCount = 0
            horizontalBoundaryPageOriginX = initialPointInWindow.x
            liveResolvedOffset = .zero

            // Mode decided ONCE from view-local touch position (G-8, G-85).
            let frame = hit.frame
            let localX = location.x - frame.minX
            let localY = location.y - frame.minY
            let canResizeTop = canResizeTop(for: hit)
            let canResizeBottom = canResizeBottom(for: hit)
            currentMode = calendarResolveDragMode(
                locationX: localX,
                locationY: localY,
                viewWidth: frame.width,
                viewHeight: frame.height,
                edgeThreshold: 10,
                canResizeTop: canResizeTop,
                canResizeBottom: canResizeBottom
            )
            verticalDragBounds = computedVerticalDragBounds(for: hit)
            eventSession = EventSession(
                event: hit.occurrence.event,
                occurrenceID: hit.occurrence.id,
                originalRange: hit.occurrence.range,
                mode: currentMode
            )

            let frameInWindow = view.convert(frame, to: nil)
            callbacks.onEventLongPressBegan?(
                CalendarEventLongPressBegan(
                    event: hit.occurrence.event,
                    occurrenceID: hit.occurrence.id,
                    actionDate: hit.occurrence.range.start,
                    dragMode: currentMode,
                    touchPointGlobal: initialPointInWindow,
                    eventFrameGlobal: frameInWindow
                )
            )
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        case .changed:
            guard let session = eventSession else { return }
            let raw = gesture.location(in: nil)
            lastLocationInWindow = raw
            let dx = raw.x - initialPointInWindow.x
            let dy = raw.y - initialPointInWindow.y
            let crossed = hypot(dx, dy) > 8

            if !hasPromotedManipulation {
                guard calendarShouldPromoteLongPressToManipulation(
                    dragMode: currentMode,
                    canMove: canMove(for: session),
                    movementExceededThreshold: crossed
                ) else {
                    stopAutoScroll()
                    return
                }
                hasMovedAfterLongPress = true
                hasPromotedManipulation = true
                (gesture as? TracingLongPressGesture)?.isDragPromoted = true
                disableScrollPanGesturesForDrag()
                // Floating drag chip (move-only). Snapshot the rendered block,
                // lift it into the window above all columns, and hide the source
                // block (section G). If the snapshot can't be taken, fall through
                // to the existing in-column finger-follow behavior.
                if currentMode == .move, dragChip == nil, let window = host.window,
                   let snap = host.snapshotDraggedOccurrence(session.occurrenceID) {
                    let chip = UIImageView(image: snap.image)
                    chip.frame = snap.windowRect
                    chip.contentMode = .scaleToFill
                    chip.layer.shadowColor = UIColor.black.cgColor
                    chip.layer.shadowOpacity = 0.22
                    chip.layer.shadowRadius = 8
                    chip.layer.shadowOffset = CGSize(width: 0, height: 3)
                    chip.alpha = 0.97
                    chip.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
                    chipSourceSize = snap.windowRect.size
                    chipGrabOffset = CGSize(
                        width: initialPointInWindow.x - snap.windowRect.midX,
                        height: initialPointInWindow.y - snap.windowRect.midY
                    )
                    window.addSubview(chip)
                    dragChip = chip
                    isChipActive = true
                    lastSnappedColumnCenterX = nil
                    host.renderLiveDragFrame() // hide the source block immediately
                    updateChipPosition()
                }
                // Callback order matches the SwiftUI path (G-15):
                // onManipulationPromotion (resets menu + sets focus, reading
                // the touch point) FIRST, then onDragBegan's equivalent
                // (syncSharedDragStateForBegin writes the coarse identity).
                callbacks.dragState?.currentTouchPointGlobal = raw
                if let frame = host.renderedFrames[session.occurrenceID]?.frame {
                    callbacks.onEventManipulationPromotion?(
                        session.event, session.occurrenceID, session.originalRange.start,
                        currentMode, raw, view.convert(frame, to: nil)
                    )
                }
                syncSharedDragStateForBegin(session: session)
                updateAutoScrollVelocity()
                updateDragOffset(using: gesture)
                return
            }

            if hasMovedAfterLongPress {
                updateAutoScrollVelocity()
            } else {
                stopAutoScroll()
            }
            updateDragOffset(using: gesture)

        case .ended, .cancelled, .failed:
            guard let terminal = calendarDragTerminalState(for: gesture.state),
                  let session = eventSession else { return }
            if hasPromotedManipulation {
                let forward = calendarShouldForwardDrop(for: terminal)
                updateDragOffset(using: gesture)
                // Cross-day commit (chip path): the dragged event lands in the
                // column the finger is over (absolute), regardless of free vs
                // snapped chip X. Translate the source→target day gap into the
                // existing dayStep-based X offset that `handleEventDrag` rounds.
                // Resolved BEFORE finalize (which clears the gesture state).
                //
                // FIX 2: this absolute `dayColumnUnderFinger` override is only
                // valid in MULTI-DAY CONTINUOUS mode (`dayColumnStep > 0`, i.e.
                // multiple columns visible at once). In single-day/boundary-
                // paging mode the pager PAGE-TURNS: the gesture-owning host has
                // been re-modeled to the NEW date, so `srcDate == col.date` →
                // dayOffset 0 → the page-turn would be discarded and the event
                // would snap back to the original day. There `liveResolvedOffset`
                // already bakes in the committed day via `horizontalBoundaryPageCount`
                // (see `calendarBoundaryPagedHorizontalDragOffset`), so leave it
                // untouched.
                var finalOffset = liveResolvedOffset
                if isChipActive, currentMode == .move, !usesHorizontalBoundaryPaging,
                   let col = dayColumnUnderFinger(), let srcDate = host.liveModel?.date {
                    let cal = Calendar.current
                    let dayOffset = cal.dateComponents(
                        [.day], from: cal.startOfDay(for: srcDate), to: cal.startOfDay(for: col.date)
                    ).day ?? 0
                    finalOffset.x = CGFloat(dayOffset) * dragPreviewDayStep
                    finalOffset.y = liveResolvedOffset.y
                }
                let mode = currentMode
                let didMove = hasMovedAfterLongPress
                finalizeTouchInteraction()
                if forward && didMove {
                    switch mode {
                    case .move:
                        callbacks.onEventDragEnded?(
                            session.event, session.occurrenceID, session.originalRange,
                            finalOffset, dragPreviewDayStep
                        )
                    case .resizeTop:
                        callbacks.onEventResizeEnded?(
                            session.event, session.occurrenceID, session.originalRange,
                            session.originalRange.start, .resizeTop, finalOffset.y
                        )
                    case .resizeBottom:
                        callbacks.onEventResizeEnded?(
                            session.event, session.occurrenceID, session.originalRange,
                            session.originalRange.start, .resizeBottom, finalOffset.y
                        )
                    }
                }
                callbacks.onEventLongPressResolved?(
                    CalendarEventLongPressResolution(
                        event: session.event, occurrenceID: session.occurrenceID,
                        actionDate: session.originalRange.start, dragMode: mode,
                        terminalState: terminal, didMove: didMove,
                        touchPointGlobal: lastLocationInWindow
                    )
                )
                // Clear the observed scratchpad (G-28 onDragTerminal consumer).
                calendarResetSharedEventDragStateIfPresent()
                eventSession = nil
                host.renderLiveDragFrame()
                return
            }
            // Pure long-press (no move past 8pt): resolve without commit (G-29).
            let mode = currentMode
            finalizeTouchInteraction()
            callbacks.onEventLongPressResolved?(
                CalendarEventLongPressResolution(
                    event: session.event, occurrenceID: session.occurrenceID,
                    actionDate: session.originalRange.start, dragMode: mode,
                    terminalState: terminal, didMove: false,
                    touchPointGlobal: lastLocationInWindow
                )
            )
            eventSession = nil

        default:
            break
        }
    }

    private func syncSharedDragStateForBegin(session: EventSession) {
        guard let dragState = callbacks.dragState else { return }
        dragState.draggingEventID = session.event.id
        dragState.draggingOccurrenceID = session.occurrenceID
        dragState.draggingEvent = session.event
        dragState.draggingOriginalRange = session.originalRange
        dragState.draggingRenderDayStart = host?.liveModel.map { Calendar.current.startOfDay(for: $0.date) }
        dragState.currentTouchPointGlobal = lastLocationInWindow
        dragState.dragMode = session.mode
        dragState.dayColumnStep = dragPreviewDayStep
        dragState.isHorizontalEdgeDragging = false
        dragState.isHorizontalAutoScrolling = false
        // NOTE: dragState.dragOffset is deliberately NOT written per frame —
        // the CALayer view renders the preview from `liveResolvedOffset`
        // (plain UIKit state). Mirroring the per-frame offset into @Observable
        // is the exact perf hazard the contract forbids (spec 05 section 7).
    }

    // MARK: Drag offset math (G-16..G-22) — reuses the shared free funcs

    private func updateDragOffset(using gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: nil)
        lastLocationInWindow = location
        // Mirror the live touch point so the absorption hit-test (run at body
        // level for the SwiftUI host AND here for the drop target) tracks it.
        callbacks.dragState?.currentTouchPointGlobal = location

        let resolvedFingerDeltaX: CGFloat = {
            guard currentMode == .move, usesHorizontalBoundaryPaging, dragPreviewDayStep > 0 else {
                return location.x - initialPointInWindow.x
            }
            let localOffsetX = location.x - horizontalBoundaryPageOriginX
            return calendarBoundaryPagedHorizontalDragOffset(
                localOffsetX: localOffsetX,
                pageCount: horizontalBoundaryPageCount,
                dayStep: dragPreviewDayStep
            )
        }()
        let fingerDelta = DragOffset(
            x: resolvedFingerDeltaX,
            y: location.y - initialPointInWindow.y
        )
        let composed = calendarComposedDragOffset(
            fingerDelta: fingerDelta,
            autoScrollCompensation: DragOffset(x: autoScrollCompensationX, y: autoScrollCompensationY)
        )
        applyDragOffset(composed)
    }

    private func applyDragOffset(_ offset: DragOffset) {
        let suppressHorizontalSnap = isHorizontalSnapSuppressed || autoScrollVelocityX != 0
        var resolved = calendarResolvedDragOffset(
            rawOffset: offset,
            dragMode: currentMode,
            dayColumnStep: dragPreviewDayStep,
            suppressHorizontalSnap: suppressHorizontalSnap
        )
        resolved.y = calendarClampedMoveDragOffsetY(
            rawOffsetY: resolved.y,
            dragMode: currentMode,
            verticalDragBounds: verticalDragBounds
        )

        // Per-15-min snap haptic (G-21).
        if let hourHeight = host?.liveModel?.hourHeight, hourHeight > 0 {
            let snapSize = hourHeight / 4
            if snapSize > 0 {
                let step = Int((resolved.y / snapSize).rounded())
                if step != lastSnappedStep {
                    lastSnappedStep = step
                    impactFeedback.impactOccurred()
                }
            }
        }

        // Keep the floating chip glued to the finger every frame (the chip reads
        // the live finger position, not `liveResolvedOffset`), so run it even
        // when the resolved offset is unchanged (free-follow within snap grid).
        updateChipPosition()
        updateInGridPreview()

        guard resolved != liveResolvedOffset else { return }
        liveResolvedOffset = resolved
        updateAbsorptionDropTarget()
        host?.renderLiveDragFrame()
    }

    // MARK: Floating cross-day drag chip (move-only)

    /// Position the floating chip each frame. Y follows the finger continuously
    /// (preserving the grab offset). X free-follows the finger while horizontal
    /// snap is suppressed (edge / auto-scroll), otherwise snaps to the center of
    /// the day-column under the finger.
    private func updateChipPosition() {
        guard let chip = dragChip else { return }
        // The chip is the dragged event's ONE always-visible representation for
        // the whole drag — it must never be hidden, or the event vanishes when
        // the in-grid preview path hiccups (the "event disappears" bug). In snap
        // mode it snaps to the column center (sitting in the reflowed gap); in
        // free/auto-scroll it follows the finger. The in-grid preview only drives
        // neighbor reflow; it does NOT paint the event block (the chip does).
        chip.isHidden = false
        let finger = lastLocationInWindow
        let centerY = finger.y - chipGrabOffset.height
        let centerX: CGFloat
        if isHorizontalSnapSuppressed {
            // FREE: follow finger, clamp to window so it stays visible at edges.
            var x = finger.x - chipGrabOffset.width
            if let w = chip.window {
                let half = chipSourceSize.width / 2
                x = min(max(x, w.bounds.minX + half), w.bounds.maxX - half)
            }
            centerX = x
            lastSnappedColumnCenterX = nil
        } else if let col = dayColumnUnderFinger() {
            centerX = col.windowCenterX
        } else {
            centerX = chip.center.x
        }
        // Snap mode: spring only when the target column center changes; free
        // mode: set directly (1:1 finger-follow, no animation).
        if !isHorizontalSnapSuppressed, lastSnappedColumnCenterX != centerX {
            lastSnappedColumnCenterX = centerX
            UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                chip.center = CGPoint(x: centerX, y: centerY)
            }
        } else {
            chip.center = CGPoint(x: centerX, y: centerY)
        }
    }

    /// The day-column host whose window-space bounds contain the finger X (or
    /// the nearest one if the finger is past all columns), plus its center X and
    /// date. Walks the window subtree so it finds every visible day-column.
    private func dayColumnUnderFinger() -> (host: DayLayerHostView, windowCenterX: CGFloat, date: Date)? {
        guard let host, let window = host.window else { return nil }
        var hosts: [DayLayerHostView] = []
        func walk(_ v: UIView) {
            if let h = v as? DayLayerHostView { hosts.append(h) }
            v.subviews.forEach(walk)
        }
        walk(window)
        let fingerX = lastLocationInWindow.x
        var best: (h: DayLayerHostView, rect: CGRect)?
        for h in hosts {
            guard h.liveModel != nil else { continue }
            let r = h.convert(h.bounds, to: nil)
            if r.minX <= fingerX, fingerX <= r.maxX { best = (h, r); break }
            if best == nil || abs(r.midX - fingerX) < abs(best!.rect.midX - fingerX) { best = (h, r) }
        }
        guard let chosen = best, let date = chosen.h.liveModel?.date else { return nil }
        return (chosen.h, chosen.rect.midX, date)
    }

    // MARK: In-grid drag preview (move-only, snap mode)

    /// While a move drag is settled (NOT auto-scrolling), push a real-time
    /// preview occurrence onto the day-column under the finger: the dragged
    /// event slots into THAT day's timeline at the dragged time (Y → time,
    /// day = the absolute target column), so neighbors reflow around it. The
    /// floating chip is hidden in this mode (see `updateChipPosition`).
    private func updateInGridPreview() {
        guard let host, hasPromotedManipulation, currentMode == .move,
              let session = eventSession, !isHorizontalSnapSuppressed,
              let col = dayColumnUnderFinger(), let srcDate = host.liveModel?.date else {
            clearInGridPreview(); return
        }
        // FIX 5: a dragged todo deliberately does NOT participate in overlap
        // (it's excluded from `overlapCandidates` via `draggedTodoOccurrenceID`),
        // so it must never squeeze peers. Pushing a `#preview` occurrence into
        // the target day's overlap would reintroduce exactly that squeeze, so a
        // dragged todo gets no in-grid preview — the floating chip alone
        // represents it. (Same predicate the overlap exclusion uses.)
        if session.event.kind == .todo {
            clearInGridPreview(); return
        }
        let cal = Calendar.current
        let timeRange = calendarResolvedDragEditRange(
            draggingOriginalRange: session.originalRange,
            dragOffset: DragOffset(x: 0, y: liveResolvedOffset.y),
            dragMode: .move,
            hourHeight: host.liveModel?.hourHeight ?? 0,
            dayColumnStep: 0
        ) ?? session.originalRange
        let dayDelta = cal.dateComponents([.day], from: cal.startOfDay(for: srcDate), to: cal.startOfDay(for: col.date)).day ?? 0
        let shiftedStart = cal.date(byAdding: .day, value: dayDelta, to: timeRange.start) ?? timeRange.start
        let shiftedEnd   = cal.date(byAdding: .day, value: dayDelta, to: timeRange.end)   ?? timeRange.end
        let shifted = Event.TimeRange(start: shiftedStart, end: shiftedEnd)
        let dayStart = cal.startOfDay(for: col.date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let clipped = calendarAdjustedOccurrenceRange(
            occurrenceID: session.occurrenceID,
            occurrenceRange: shifted,
            draggingOccurrenceID: session.occurrenceID,
            draggingOriginalRange: session.originalRange,
            dragMode: .move,
            previewRange: shifted,
            dayStart: dayStart,
            dayEnd: dayEnd
        ) ?? shifted
        let occ = CalendarLayout.EventOccurrence(id: session.occurrenceID + "#preview", event: session.event, range: clipped)
        if let last = lastPreviewHost, last !== col.host { last.applyDragPreview(nil) }
        lastPreviewHost = col.host
        col.host.applyDragPreview(occ)
    }

    private func clearInGridPreview() {
        lastPreviewHost?.applyDragPreview(nil)
        lastPreviewHost = nil
    }

    // MARK: Absorption drop-targeting (G-57..G-62)

    /// Spatial hit-test of the live touch point against rendered event frames;
    /// mirrors the chosen parent's id coarsely into `currentDropTargetEventID`.
    private func updateAbsorptionDropTarget() {
        guard let host, let dragState = callbacks.dragState,
              let session = eventSession,
              session.event.kind == .todo, !session.event.isRecurringSeries,
              !mirroredAutoScrolling, !mirroredEdgeDragging else {
            return
        }
        // FIX 4: hit-test the day column UNDER THE FINGER, not just the source
        // host. Dragging a todo over an event on a DIFFERENT day's column must
        // still find an absorb target. Resolve that column's host and hit-test
        // its `renderedFrames` in ITS OWN coordinate space (convert the window
        // touch point into the target host). When the finger is over the source
        // column, `dayColumnUnderFinger()` returns the source host → identical
        // same-day behavior. Falls back to the source host if unresolved.
        let targetHost = dayColumnUnderFinger()?.host ?? host
        let touchInView = targetHost.convert(lastLocationInWindow, from: nil)
        var best: (id: UUID, depth: Int)?
        for (id, rf) in targetHost.renderedFrames {
            let occ = rf.occurrence
            guard occ.event.kind == .event, occ.event.id != session.event.id,
                  occ.event.absorbedIntoEventID == nil,
                  id != session.occurrenceID else { continue }
            guard rf.frame.contains(touchInView) else { continue }
            let depth = rf.slot.depth + (rf.isEmbeddedChild ? 1 : 0)
            if best == nil || depth > best!.depth {
                best = (occ.event.id, depth)
            }
        }
        // Only-clear-if-we-still-own (G-59): write non-nil unconditionally;
        // clear only if the current target was the one we'd set.
        if let id = best?.id {
            dragState.currentDropTargetEventID = id
        } else if dragState.currentDropTargetEventID != nil {
            dragState.currentDropTargetEventID = nil
        }
    }

    // MARK: Edge auto-scroll (G-35..G-41) — reuses the shared curve

    private enum ScrollAxis { case horizontal, vertical }

    private func updateAutoScrollVelocity() {
        guard hasMovedAfterLongPress else {
            stopAutoScroll()
            isHorizontalSnapSuppressed = false
            mirrorEdgeFlags(edge: false, auto: false)
            return
        }
        let horizontalEdgeActive = isInHorizontalAutoScrollEdgeZone()
        if currentMode == .move, usesHorizontalBoundaryPaging {
            autoScrollVelocityX = 0
            handleHorizontalBoundaryPagingIfNeeded(horizontalEdgeActive: horizontalEdgeActive)
        } else {
            autoScrollVelocityX = currentMode == .move
                ? autoScrollVelocity(for: horizontalScrollView, axis: .horizontal)
                : 0
        }
        autoScrollVelocityY = autoScrollVelocity(for: verticalScrollView, axis: .vertical)

        let needsBoundaryPagingTick = usesHorizontalBoundaryPaging && horizontalEdgeActive
        if autoScrollVelocityX == 0 && autoScrollVelocityY == 0 && !needsBoundaryPagingTick {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
        let isAutoScrolling = autoScrollVelocityX != 0
        isHorizontalSnapSuppressed = horizontalEdgeActive || isAutoScrolling
        mirrorEdgeFlags(edge: isHorizontalSnapSuppressed, auto: isAutoScrolling)
    }

    private func mirrorEdgeFlags(edge: Bool, auto: Bool) {
        mirroredEdgeDragging = edge
        mirroredAutoScrolling = auto
        callbacks.dragState?.isHorizontalEdgeDragging = edge
        callbacks.dragState?.isHorizontalAutoScrolling = auto
    }

    private func handleHorizontalBoundaryPagingIfNeeded(horizontalEdgeActive: Bool) {
        guard horizontalEdgeActive, dragPreviewDayStep > 0,
              let request = callbacks.onHorizontalBoundaryPageRequest else { return }
        let direction = horizontalBoundaryPageDirection()
        guard direction != 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastHorizontalBoundaryPageTimestamp >= horizontalBoundaryPageMinimumInterval else { return }
        guard request(direction) else { return }
        lastHorizontalBoundaryPageTimestamp = now
        horizontalBoundaryPageCount += direction
        horizontalBoundaryPageOriginX = lastLocationInWindow.x
        if let gesture = activeGesture { updateDragOffset(using: gesture) }
    }

    private func startAutoScroll() {
        guard autoScrollDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        autoScrollDisplayLink = link
    }

    private func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollVelocityX = 0
        autoScrollVelocityY = 0
        mirroredAutoScrolling = false
        callbacks.dragState?.isHorizontalAutoScrolling = false
    }

    @objc private func handleAutoScrollTick(_ link: CADisplayLink) {
        guard autoScrollVelocityX != 0 || autoScrollVelocityY != 0 else {
            stopAutoScroll()
            return
        }
        let dt = max(link.targetTimestamp - link.timestamp, 0)
        let delta = CGPoint(
            x: calendarHorizontalAutoScrollDelta(velocityX: autoScrollVelocityX, deltaTime: dt),
            y: autoScrollVelocityY * CGFloat(dt)
        )
        // Same-scrollview special case (G-39): one combined apply if the
        // horizontal & vertical targets are the same object.
        if let shared = horizontalScrollView, shared === verticalScrollView {
            let applied = applyAutoScroll(on: shared, delta: delta)
            autoScrollCompensationX += applied.x
            autoScrollCompensationY += applied.y
        } else {
            if let sv = horizontalScrollView {
                autoScrollCompensationX += applyAutoScroll(on: sv, delta: CGPoint(x: delta.x, y: 0)).x
            }
            if let sv = verticalScrollView {
                autoScrollCompensationY += applyAutoScroll(on: sv, delta: CGPoint(x: 0, y: delta.y)).y
            }
        }
        if let gesture = activeGesture { lastLocationInWindow = gesture.location(in: nil) }
        updateAutoScrollVelocity()
        if let gesture = activeGesture { updateDragOffset(using: gesture) }
        // A stationary finger over a scrolling pager still needs the chip + snap
        // target refreshed each tick (columns slide under the finger).
        updateChipPosition()
        updateInGridPreview()
    }

    private func autoScrollVelocity(for scrollView: UIScrollView?, axis: ScrollAxis) -> CGFloat {
        guard let scrollView else { return 0 }
        let minOffset: CGFloat
        let maxOffset: CGFloat
        let boundsSize: CGFloat
        let loc: CGFloat
        let edgeInset: CGFloat
        switch axis {
        case .horizontal:
            minOffset = -scrollView.adjustedContentInset.left
            maxOffset = max(minOffset, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
            boundsSize = scrollView.bounds.width
            loc = locationInViewport(for: scrollView, axis: .horizontal)
            edgeInset = calendarHorizontalAutoScrollEdgeInsetDefault
        case .vertical:
            minOffset = -scrollView.adjustedContentInset.top
            maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            boundsSize = scrollView.bounds.height
            loc = locationInViewport(for: scrollView, axis: .vertical)
            edgeInset = calendarVerticalAutoScrollEdgeInsetDefault
        }
        let currentOffset = axis == .horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
        return calendarAutoScrollVelocity(
            locationInViewport: loc, viewportLength: boundsSize, currentOffset: currentOffset,
            minOffset: minOffset, maxOffset: maxOffset, edgeInset: edgeInset,
            maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
    }

    private func locationInViewport(for scrollView: UIScrollView, axis: ScrollAxis) -> CGFloat {
        let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
        return axis == .horizontal
            ? lastLocationInWindow.x - frameInWindow.minX
            : lastLocationInWindow.y - frameInWindow.minY
    }

    private func isInHorizontalAutoScrollEdgeZone() -> Bool {
        guard currentMode == .move, let sv = horizontalScrollView else { return false }
        return calendarIsInAutoScrollEdgeZone(
            locationInViewport: locationInViewport(for: sv, axis: .horizontal),
            viewportLength: sv.bounds.width,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault
        )
    }

    private func horizontalBoundaryPageDirection() -> Int {
        guard let sv = horizontalScrollView else { return 0 }
        return calendarHorizontalBoundaryPageDirection(
            locationInViewport: locationInViewport(for: sv, axis: .horizontal),
            viewportLength: sv.bounds.width,
            edgeInset: calendarHorizontalAutoScrollEdgeInsetDefault
        )
    }

    private func applyAutoScroll(on scrollView: UIScrollView, delta: CGPoint) -> CGPoint {
        let minX = -scrollView.adjustedContentInset.left
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let current = scrollView.contentOffset
        let clampedX = min(max(current.x + delta.x, minX), maxX)
        let clampedY = min(max(current.y + delta.y, minY), maxY)
        guard abs(clampedX - current.x) > .ulpOfOne || abs(clampedY - current.y) > .ulpOfOne else { return .zero }
        scrollView.setContentOffset(CGPoint(x: clampedX, y: clampedY), animated: false)
        return CGPoint(x: clampedX - current.x, y: clampedY - current.y)
    }

    private func findScrollTargets(startingAt view: UIView) -> (horizontal: UIScrollView?, vertical: UIScrollView?) {
        var current: UIView? = view.superview
        var h: UIScrollView?
        var v: UIScrollView?
        while let candidate = current {
            if let sv = candidate as? UIScrollView, sv.isScrollEnabled {
                if h == nil && sv.contentSize.width - sv.bounds.width > 1 { h = sv }
                if v == nil && sv.contentSize.height - sv.bounds.height > 1 { v = sv }
                if h != nil && v != nil { break }
            }
            current = candidate.superview
        }
        return (h, v)
    }

    // MARK: Scroll-gesture suppression during drag (G-33)

    private func disableScrollPanGesturesForDrag() {
        guard disabledScrollGestures.isEmpty else { return }
        var current: UIView? = activeGesture?.view?.superview
        var seen = Set<ObjectIdentifier>()
        while let v = current {
            if let sv = v as? UIScrollView {
                let id = ObjectIdentifier(sv)
                if !seen.contains(id) {
                    seen.insert(id)
                    savedCanCancelContentTouches.append((sv, sv.canCancelContentTouches))
                    sv.canCancelContentTouches = false
                    for g in sv.gestureRecognizers ?? [] {
                        disabledScrollGestures.append((g, g.isEnabled))
                        g.isEnabled = false
                    }
                }
            }
            current = v.superview
        }
    }

    private func restoreScrollPanGestures() {
        for entry in savedCanCancelContentTouches {
            entry.scrollView.canCancelContentTouches = entry.wasEnabled
        }
        savedCanCancelContentTouches.removeAll()
        for entry in disabledScrollGestures {
            entry.gesture.isEnabled = entry.wasEnabled
        }
        disabledScrollGestures.removeAll()
    }

    private func finalizeTouchInteraction() {
        stopAutoScroll()
        (activeGesture as? TracingLongPressGesture)?.isDragPromoted = false
        restoreScrollPanGestures()
        activeGesture = nil
        horizontalScrollView = nil
        verticalScrollView = nil
        hasMovedAfterLongPress = false
        hasPromotedManipulation = false
        isHorizontalSnapSuppressed = false
        liveResolvedOffset = .zero
        autoScrollCompensationX = 0
        autoScrollCompensationY = 0
        lastHorizontalBoundaryPageTimestamp = 0
        horizontalBoundaryPageCount = 0
        horizontalBoundaryPageOriginX = 0
        mirrorEdgeFlags(edge: false, auto: false)
        // Tear down the floating drag chip (if any). The source block's opacity
        // restores on the next normal render once the session clears.
        dragChip?.removeFromSuperview()
        dragChip = nil
        isChipActive = false
        lastSnappedColumnCenterX = nil
        clearInGridPreview()
    }

    // MARK: Per-hit capability + bounds (mirror TimelineDayView.eventBlock)

    private func canMove(for session: EventSession) -> Bool {
        guard let model = host?.liveModel else { return true }
        let isGrace = model.graceResizeEventID == session.event.id
            && (model.graceResizeOccurrenceID == nil || model.graceResizeOccurrenceID == session.occurrenceID)
        return !isGrace
    }

    private func canResizeTop(for hit: DayLayerHostView.RenderedEventFrame) -> Bool {
        guard let model = host?.liveModel else { return true }
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date, leadingExtendedHours: model.leadingExtendedHours
        )
        return hit.occurrence.range.start >= visibleStart
    }

    private func canResizeBottom(for hit: DayLayerHostView.RenderedEventFrame) -> Bool {
        guard let model = host?.liveModel else { return true }
        let visibleEnd = calendarTimelineVisibleEnd(
            containing: model.date, trailingExtendedHours: model.trailingExtendedHours
        )
        return hit.occurrence.range.end <= visibleEnd
    }

    private func computedVerticalDragBounds(for hit: DayLayerHostView.RenderedEventFrame) -> ClosedRange<CGFloat> {
        guard let model = host?.liveModel, model.hourHeight > 0 else { return -.infinity ... .infinity }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: model.date)
        let maxBoundaryStart = dayStart.addingTimeInterval(
            TimeInterval(-calendarTimelineMaximumBoundaryExtensionHours * 3600)
        )
        let maxBoundaryEnd = dayStart.addingTimeInterval(
            TimeInterval((calendarTimelineBaseVisibleHours + calendarTimelineMaximumBoundaryExtensionHours) * 3600)
        )
        let range = hit.occurrence.range
        let dur = range.end.timeIntervalSince(range.start)
        let minY = CGFloat(maxBoundaryStart.timeIntervalSince(range.start) / 3600) * model.hourHeight
        let maxY = CGFloat((maxBoundaryEnd.timeIntervalSince(range.start) - dur) / 3600) * model.hourHeight
        return minY ... max(minY, maxY)
    }

    // MARK: Drag-to-create (G-46..G-56)

    @objc private func handleCreateGesture(_ gesture: UILongPressGestureRecognizer) {
        guard let host, let view = gesture.view else { return }
        let y = gesture.location(in: view).y

        switch gesture.state {
        case .began:
            verticalScrollView = findScrollTargets(startingAt: view).vertical
            isLongPressingCreation = true
            isCreating = false
            creationStartY = y
            creationCurrentY = y
            lastTickMinutes = -1
            lastSnappedStartEdge = nil
            lastSnappedEndEdge = nil
            snapHaptic.prepare()
            createHaptic.impactOccurred()

        case .changed:
            guard isLongPressingCreation else { return }
            creationCurrentY = y
            if !isCreating {
                if calendarShouldActivateCreationAfterLongPress(
                    dragDeltaY: y - creationStartY,
                    threshold: creationActivationThreshold
                ) {
                    isCreating = true
                    lastTickMinutes = currentSnappedMinutes(for: y)
                    createHaptic.impactOccurred()
                    startCreationAutoScroll()
                }
                pushCreationPreview()
                return
            }
            checkCreationHapticTick()
            checkAdjacentSnapHaptic()
            pushCreationPreview()
            updateCreationAutoScrollVelocity()

        case .ended:
            stopCreationAutoScroll()
            if isCreating, let range = creationPreviewRange() {
                let minDuration: TimeInterval = 15 * 60
                let finalRange = range.end.timeIntervalSince(range.start) < minDuration
                    ? Event.TimeRange(start: range.start, end: range.start.addingTimeInterval(minDuration))
                    : range
                callbacks.onCreateEvent?(finalRange)
            }
            resetCreationState()

        case .cancelled, .failed:
            stopCreationAutoScroll()
            resetCreationState()

        default:
            break
        }
        _ = host
    }

    private func resetCreationState() {
        isCreating = false
        isLongPressingCreation = false
        lastTickMinutes = -1
        lastSnappedStartEdge = nil
        lastSnappedEndEdge = nil
        verticalScrollView = nil
        // Clear the live preview mapping.
        if let date = host?.liveModel?.date {
            callbacks.onCreationPreviewChanged?(date, nil)
        }
    }

    private func pushCreationPreview() {
        guard let date = host?.liveModel?.date else { return }
        callbacks.onCreationPreviewChanged?(date, isCreating ? creationPreviewRange() : nil)
    }

    private func creationPreviewRange() -> Event.TimeRange? {
        guard isCreating else { return nil }
        let startTime = timeFromYWithAdjacentSnap(creationStartY).snappedTime
        let endTime = timeFromYWithAdjacentSnap(creationCurrentY).snappedTime
        return startTime < endTime
            ? Event.TimeRange(start: startTime, end: endTime)
            : Event.TimeRange(start: endTime, end: startTime)
    }

    private func timeFromYWithAdjacentSnap(_ y: CGFloat) -> (snappedTime: Date, snappedEdge: Date?) {
        guard let host, let model = host.liveModel else {
            return (host?.dateFromY(y, snapMinutes: 15) ?? Date(), nil)
        }
        let candidate = host.dateFromY(y, snapMinutes: 15)
        guard model.hourHeight > 0 else { return (candidate, nil) }
        let raw = calendarTimelineDateFromYPosition(
            y, containing: model.date, headerHeight: model.headerHeight, hourHeight: model.hourHeight,
            leadingExtendedHours: model.leadingExtendedHours,
            trailingExtendedHours: model.trailingExtendedHours, snapMinutes: 1
        )
        let thresholdSeconds = TimeInterval(adjacentEventSnapThresholdPt / model.hourHeight * 3600)
        return calendarApplyAdjacentEventSnap(
            candidateTime: candidate, rawTime: raw,
            neighborEdges: neighborEventEdges(), thresholdSeconds: thresholdSeconds
        )
    }

    private func neighborEventEdges() -> [Date] {
        guard let host else { return [] }
        var edges: [Date] = []
        for (_, rf) in host.renderedFrames {
            edges.append(rf.occurrence.range.start)
            edges.append(rf.occurrence.range.end)
        }
        return edges
    }

    private func currentSnappedMinutes(for y: CGFloat) -> Int {
        guard let model = host?.liveModel else { return 0 }
        let time = host?.dateFromY(y, snapMinutes: 15) ?? model.date
        let visibleStart = calendarTimelineVisibleStart(
            containing: model.date, leadingExtendedHours: model.leadingExtendedHours
        )
        return Int((time.timeIntervalSince(visibleStart) / 60).rounded())
    }

    private func checkCreationHapticTick() {
        let minutes = currentSnappedMinutes(for: creationCurrentY)
        if minutes != lastTickMinutes {
            lastTickMinutes = minutes
            createHaptic.impactOccurred()
        }
    }

    private func checkAdjacentSnapHaptic() {
        let startEdge = timeFromYWithAdjacentSnap(creationStartY).snappedEdge
        let endEdge = timeFromYWithAdjacentSnap(creationCurrentY).snappedEdge
        if startEdge != lastSnappedStartEdge {
            if startEdge != nil { snapHaptic.selectionChanged() }
            lastSnappedStartEdge = startEdge
        }
        if endEdge != lastSnappedEndEdge {
            if endEdge != nil { snapHaptic.selectionChanged() }
            lastSnappedEndEdge = endEdge
        }
    }

    // Creation auto-scroll (G-54): vertical-only, identical curve.
    private func startCreationAutoScroll() {
        guard creationAutoScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleCreationAutoScrollTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        creationAutoScrollLink = link
    }

    private func stopCreationAutoScroll() {
        creationAutoScrollLink?.invalidate()
        creationAutoScrollLink = nil
    }

    private func updateCreationAutoScrollVelocity() {
        guard isCreating, let sv = verticalScrollView else {
            stopCreationAutoScroll()
            return
        }
        let velocity = creationVerticalVelocity(for: sv)
        if velocity == 0 { stopCreationAutoScroll() } else { startCreationAutoScroll() }
    }

    @objc private func handleCreationAutoScrollTick(_ link: CADisplayLink) {
        guard let sv = verticalScrollView else { stopCreationAutoScroll(); return }
        let velocity = creationVerticalVelocity(for: sv)
        guard velocity != 0 else { stopCreationAutoScroll(); return }
        let dt = max(link.targetTimestamp - link.timestamp, 0)
        let delta = velocity * CGFloat(dt)
        _ = applyAutoScroll(on: sv, delta: CGPoint(x: 0, y: delta))
        // Extend the preview as the content scrolls under a stationary finger.
        if let gesture = createGesture, let view = gesture.view {
            creationCurrentY = gesture.location(in: view).y
        }
        if isCreating { checkCreationHapticTick(); pushCreationPreview() }
    }

    private func creationVerticalVelocity(for scrollView: UIScrollView) -> CGFloat {
        guard let gesture = createGesture else { return 0 }
        let loc = gesture.location(in: nil).y - scrollView.convert(scrollView.bounds, to: nil).minY
        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        return calendarAutoScrollVelocity(
            locationInViewport: loc, viewportLength: scrollView.bounds.height,
            currentOffset: scrollView.contentOffset.y, minOffset: minOffset, maxOffset: maxOffset,
            edgeInset: calendarVerticalAutoScrollEdgeInsetDefault, maxSpeed: calendarMaxAutoScrollSpeedDefault
        )
    }
}

/// Long-press subclass that swallows touch-cancels once a drag has promoted,
/// so a SwiftUI content rebuild mid-drag cannot cancel the active gesture
/// (G-30). Mirrors `EventBlockDragGesture.TracingLongPressGesture`.
final class TracingLongPressGesture: UILongPressGestureRecognizer {
    var isDragPromoted = false

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if isDragPromoted { return }  // absorb (G-30)
        super.touchesCancelled(touches, with: event)
    }
}

// MARK: - Animation helpers (S5)

/// Convert a SwiftUI `.spring(response:dampingFraction:)` to a configured
/// `CASpringAnimation` on the given keyPath, per spec 04 cheat-sheet:
/// `stiffness = (2π/response)²`, `damping = (4π·dampingFraction)/response`,
/// `mass = 1`. `duration` is set to `settlingDuration` so the layer HOLDS the
/// final value (otherwise CA snaps back at animation end).
func calendarCASpring(
    keyPath: String,
    response: CGFloat,
    dampingFraction: CGFloat
) -> CASpringAnimation {
    let anim = CASpringAnimation(keyPath: keyPath)
    anim.mass = 1
    anim.stiffness = pow((2 * .pi) / response, 2)
    anim.damping = (4 * .pi * dampingFraction) / response
    anim.initialVelocity = 0
    anim.duration = anim.settlingDuration
    return anim
}

/// Whether motion should be substituted with an instant value set (spec 04
/// Reduce-Motion list). Read once per transition, not per frame.
var calendarReduceMotionEnabled: Bool { UIAccessibility.isReduceMotionEnabled }

/// Public mirror of EventBlock's file-private `calendarFallThroughEdgeInset`
/// (smoothstep collapse 12pt -> full 32pt). The gesture controller needs the
/// SAME curve as the SwiftUI hit area so edge-band touches fall through to
/// drag-to-create in lockstep (G-3/4/5).
func calendarFallThroughEdgeInsetPublic(maxInset: CGFloat, height: CGFloat) -> CGFloat {
    guard maxInset > 0 else { return 0 }
    let lo: CGFloat = 12
    let hi: CGFloat = 32
    if height <= lo { return 0 }
    if height >= hi { return maxInset }
    let t = (height - lo) / (hi - lo)
    return maxInset * (t * t * (3 - 2 * t))
}
