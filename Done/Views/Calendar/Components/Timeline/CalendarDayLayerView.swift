//
//  CalendarDayLayerView.swift
//  Done
//
//  CALayer timeline — the sole calendar day renderer. The legacy SwiftUI
//  `TimelineDayView` was removed once this path landed at full parity.
//
//  A UIViewRepresentable that renders one day column's events as
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

/// Renders one day column's events at full `EventBlock` visual fidelity via a
/// persistent `DayLayerHostView`. Receives the per-day inputs at the pager
/// injection point.
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
    /// HORIZON span in days (from `@AppStorage nearFutureHorizonDays`). Drives the future-zone tint +
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
    /// Extension-band fade progress (#61). 0 = band fully visible, 1 = fully
    /// faded out (matches `extensionFadeMask`'s opacity ramp). Drives the
    /// in-band day-hint label opacity so the "SAT 26"-style hints fade in
    /// lockstep with the band.
    let leadingFadeProgress: CGFloat
    let trailingFadeProgress: CGFloat

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
            leadingFadeProgress: leadingFadeProgress,
            trailingFadeProgress: trailingFadeProgress,
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

