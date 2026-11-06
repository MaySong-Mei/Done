//
//  CalendarPageHandlerHelpers.swift
//  Done
//
//  Pure handler helpers extracted from `CalendarPageView.swift` per the §4
//  prescription in `Docs/calendar-page-state-map.md` (v3). Each helper has
//  zero SwiftUI / view dependencies so it can be unit-tested directly via
//  `@testable import Done` (see `DoneTests/CalendarPageHandlerHelpersTests.swift`).
//
//  Strict behavior parity is required: the call sites in `CalendarPageView`
//  shrink to "build inputs → call helper", with NO logic changes. Extractions
//  exist to (a) name the predicates / magic numbers the cross-midnight audit
//  flagged, and (b) give the test suite a unit-testable seam without touching
//  the view's `@State`.
//

import Foundation
import CoreGraphics

// MARK: - §4e. Cross-day follow settle window (named magic number)

/// Duration of the post-follow-event settle window. While this window is open,
/// `refreshAbandonedExtension` and `handleTimelineBoundaryExtensionStateChange`
/// stop driving the abandoned-extension dissolve path so the follow-event
/// rebounce animator can write fade progress directly without churn.
///
/// Read by `refreshAbandonedExtension` (settle-window guard) and by
/// `handleTimelineBoundaryExtensionStateChange`'s `followGuardActive` closure.
/// See §4e of `Docs/calendar-page-state-map.md`. NB: this is NOT
/// `stage1MaxFade` (which is also 0.6 — coincidence of value, different
/// concept).
internal let crossDayFollowSettleWindow: TimeInterval = 0.6

// MARK: - Follow-day mirror (gh#285)

/// What the follow-event-across-midnight swap mirrors, and how far the
/// vertical offset moves so the same instant keeps its screen position.
struct CalendarFollowDayMirror: Equatable {
    /// The whole old day as a band of the new day: below it when the view
    /// went back a day, above it when it went forward.
    let mirroredExtension: TimelineBoundaryExtensionState
    /// Added to the offset at the swap: how far the window's start moved.
    let scrollDelta: CGFloat
    /// Where the offset settles afterwards: the new day's start at the top.
    let settleOffset: CGFloat
}

/// `oldDayClock` is the day the view was on, `newDayClock` the day it
/// follows the event to, `dayDelta` their signed distance in days, and
/// `currentLeadingHours` the band open above the old day at the swap.
/// The mirrored band is as long as the OLD day, and the offset moves by
/// how far the window's start moved: going back, from (old day − band
/// above) to the new day's start; going forward, the new window starts a
/// whole old day before the new day — the old day's start — so the swap
/// is a pure rename.
func calendarFollowDayMirror(
    oldDayClock: DayClock,
    newDayClock: DayClock,
    dayDelta: Int,
    currentLeadingHours: Int,
    hourHeight: CGFloat,
    newHostDayOffset: Int
) -> CalendarFollowDayMirror {
    let mirroredHours = Int((oldDayClock.length / 3600).rounded())
    let mirroredExtension = dayDelta < 0
        ? TimelineBoundaryExtensionState(
            leadingHours: 0, trailingHours: mirroredHours, source: nil, anchorDayOffset: newHostDayOffset
        )
        : TimelineBoundaryExtensionState(
            leadingHours: mirroredHours, trailingHours: 0, source: nil, anchorDayOffset: newHostDayOffset
        )
    let oldWindowStart = calendarTimelineVisibleStart(
        clock: oldDayClock, leadingExtendedHours: currentLeadingHours
    )
    let newWindowStart = calendarTimelineVisibleStart(
        clock: newDayClock, leadingExtendedHours: mirroredExtension.leadingHours
    )
    let scrollDelta = CGFloat(oldWindowStart.timeIntervalSince(newWindowStart) / 3600) * hourHeight
    let settleOffset = dayDelta < 0 ? 0 : CGFloat(mirroredExtension.leadingHours) * hourHeight
    return CalendarFollowDayMirror(
        mirroredExtension: mirroredExtension,
        scrollDelta: scrollDelta,
        settleOffset: settleOffset
    )
}

// MARK: - Stack-card drop (gh#285 S1.5)

/// Where a stack card dropped at `localY` — below the top of the selected
/// column's frame — lands: nil outside the column's drawn window, else the
/// quarter hour there. The mapping reads the hour height the column is
/// drawn with from the page's geometry, so in the normalized mode a special
/// day's scaled column maps the finger onto the hour it is over.
///
/// The last minute is held back from the window, as every finger→time
/// mapping of the page does: without it the very last pixel of the column
/// rounds to the next day's midnight, which this column cannot paint.
func calendarTodoStackDropStart(
    localY: CGFloat,
    headerHeight: CGFloat,
    geometry: CalendarTimelineGeometry,
    bandState: TimelineBoundaryExtensionState
) -> Date? {
    let hourHeight = geometry.selectedColumnHourHeight
    guard hourHeight.isFinite, hourHeight > 0 else { return nil }
    let clock = geometry.selectedDayClock
    let totalVisibleMinutes = calendarTimelineVisibleMinutes(
        clock: clock,
        leadingExtendedHours: bandState.leadingHours,
        trailingExtendedHours: bandState.trailingHours
    )
    let maxLocalY = headerHeight + CGFloat(max(0, totalVisibleMinutes - 1)) / 60 * hourHeight
    guard localY >= headerHeight, localY <= maxLocalY else { return nil }
    return calendarTimelineDateFromYPosition(
        localY,
        clock: clock,
        headerHeight: headerHeight,
        hourHeight: hourHeight,
        leadingExtendedHours: bandState.leadingHours,
        trailingExtendedHours: bandState.trailingHours,
        snapMinutes: 15
    )
}

// MARK: - §4b. Midnight-shift gate predicate

/// Whether a pending midnight offset shift may be applied now.
///
/// The shift is blocked while any of {drag, resize-grace, live-interrupt}
/// owns a frame-of-reference that the shift would desynchronise. Each gate
/// has an `.onChange` retry observer in `CalendarPageView`; each is also
/// checked together inside `tryApplyPendingMidnightShift` so that whichever
/// observer fires last actually wins.
///
/// See §4b of `Docs/calendar-page-state-map.md` and invariant 1 of §3.
internal func shouldAllowMidnightShift(
    draggingEventID: UUID?,
    resizeGrace: CalendarResizeGraceState?,
    liveInterrupt: CalendarInterruptLiveSession?
) -> Bool {
    draggingEventID == nil
        && resizeGrace == nil
        && liveInterrupt == nil
}

// MARK: - §4c. RangeMode → boundary-extension clear predicate

/// Whether changing into `newMode` should clear an open boundary extension.
///
/// Boundary extensions only make sense in `.day` rangeMode (multi-day columns
/// are too narrow for meaningful extended interaction). This predicate
/// codifies "non-day mode + currently-open extension → must clear" so the
/// two call sites that enforce it (the proactive `onChange(rangeMode)` and
/// the reactive `handleTimelineBoundaryExtensionStateChange` early-return)
/// can't drift.
///
/// See §4c of `Docs/calendar-page-state-map.md` and invariant 2 of §3.
internal func boundaryExtensionShouldClearOnRangeModeChange(
    newMode: RangeMode,
    currentExtensionState: TimelineBoundaryExtensionState
) -> Bool {
    newMode != .day && currentExtensionState != .none
}

// MARK: - §4a. Abandoned-extension fade-curve math

/// Inputs to `computeAbandonedFadeCurves`.
///
/// One field per scalar the curve math actually reads. The three view-side
/// inset fields (`topOverlayInset`, `timelineAllDayHeight`,
/// `timelineHeaderHeight`) collapse to `extensionOriginY` because they only
/// flow into a single sum (line 2706 in the original `refreshAbandonedExtension`
/// — see the §4a footnote in `Docs/calendar-page-state-map.md`).
internal struct AbandonedFadeInputs {
    let rawState: TimelineBoundaryExtensionState
    let appliedState: TimelineBoundaryExtensionState
    let dragOriginalRange: Event.TimeRange
    let dragOffsetY: CGFloat
    /// The hour height the dragged column is drawn with: the finger's
    /// offset, the bands and the day are all measured in it. (In the
    /// normalized mode a special day's column is scaled, gh#285 S1.5.)
    let hourHeight: CGFloat
    /// `topOverlayInset + timelineAllDayHeight + timelineHeaderHeight`.
    let extensionOriginY: CGFloat
    let scrollY: CGFloat
    let viewportHeight: CGFloat
    /// The day the drag began in: its start is the 0:00 line above the
    /// leading band, its end the line the trailing band hangs from.
    let dayClock: DayClock
}

/// Result of `computeAbandonedFadeCurves`.
///
/// `nil` for a side means "leave the current `@State` value untouched"
/// (matches the original handler's "only write if the side has hours" gate
/// — see §4a). The caller's `if abs(diff) > 0.001` write-coalescing gate
/// stays at the call site, since it's a state-write concern, not part of
/// the curve math.
internal struct AbandonedFadeCurves: Equatable {
    let leading: CGFloat?
    let trailing: CGFloat?
}

/// Compute the abandoned-extension fade progress for the leading and trailing
/// bands, given a snapshot of inputs.
///
/// Returns `(nil, nil)` (an "early-return" result) when the abandoned
/// dissolve should not run at all. Otherwise, returns `nil` for whichever
/// side currently has zero hours, mirroring the original handler's behavior
/// of only writing to a side that's actually open.
///
/// See §4a (signature + carveout rationale) and §4d (nested-helper names)
/// of `Docs/calendar-page-state-map.md`.
internal func computeAbandonedFadeCurves(_ input: AbandonedFadeInputs) -> AbandonedFadeCurves {
    let earlyOut = AbandonedFadeCurves(leading: nil, trailing: nil)
    guard input.appliedState.hasAnyExtension else { return earlyOut }
    // Only while actively dragging with the intent (raw) OUT of the zone.
    guard input.rawState.source != nil, !input.rawState.hasAnyExtension else { return earlyOut }
    guard input.hourHeight > 0 else { return earlyOut }

    let leading = input.appliedState.leadingHours
    let trailing = input.appliedState.trailingHours

    // STAGE 1 — finger-driven dim, CAPPED below full transparency. The
    // dragged edge = original edge + drag offset (move shifts both;
    // resizeTop shifts start; resizeBottom shifts end — leading keys on
    // start, trailing on end). As you pull the edge back into the day the
    // band dims, but only to `stage1MaxFade` (never empties → no in-view
    // gap). (#55 two-stage fade)
    let offsetHours = Double(input.dragOffsetY) / Double(input.hourHeight)
    let dayStart = input.dayClock.start
    let abandonFadeStartHours: Double = 4   // tunable: dim begins here
    let abandonFadeRangeHours: Double = 4   // tunable: reaches the cap after this
    let stage1MaxFade: CGFloat = 0.6        // tunable: opacity floor = 1 - this
    // NB: same numeric value as `crossDayFollowSettleWindow`, different
    // concept — do NOT collapse. (See §4e footnote.)

    /// Finger-driven fade keyed on how far the dragged edge has pulled back
    /// past `abandonFadeStartHours` into the day. Capped at `stage1MaxFade`.
    func fingerDrivenStage1Fade(distHours: Double) -> CGFloat {
        min(
            stage1MaxFade,
            CGFloat(max(0, min(1, (distHours - abandonFadeStartHours) / abandonFadeRangeHours)))
        )
    }

    // STAGE 2 — ABSOLUTE position fade keyed on WHERE THE MIDNIGHT LINE is
    // relative to the viewport edge (scroll only moves it indirectly). The
    // band fully fades as its boundary (0:00 / 24:00) reaches the edge. At
    // min pinch the band is tiny and the boundary already sits near the
    // edge → it can reach full transparency with little/no scroll; at max
    // pinch the boundary is deep in view → it needs the edge to come to it.
    // Pure opacity (no scroll write → no detach).
    let visibleTop = max(0, input.scrollY)
    let visibleBottom = visibleTop + input.viewportHeight

    /// Position-driven fade keyed on how far the band's outer boundary
    /// (0:00 for leading, 24:00 for trailing) sits inside the viewport.
    /// Reaches 1 when the boundary touches the viewport edge.
    func positionDrivenStage2Fade(boundarySpan: CGFloat, bandHeight: CGFloat) -> CGFloat {
        // `boundarySpan` is the signed distance from the viewport edge to
        // the relevant boundary line. Positive = boundary still inside the
        // viewport. At 0 the band is fully off (s2 = 1).
        max(0, min(1, 1 - boundarySpan / bandHeight))
    }

    /// Combine the two fades via multiply-complement: result = 1 when either
    /// stage saturates; partial when both partial. Equivalent to over-blending
    /// two independent opacities.
    func combineFades(_ s1: CGFloat, _ s2: CGFloat) -> CGFloat {
        1 - (1 - s1) * (1 - s2)
    }

    var leadingResult: CGFloat? = nil
    var trailingResult: CGFloat? = nil

    if leading > 0 {
        let liveStart = input.dragOriginalRange.start.addingTimeInterval(offsetHours * 3600)
        let s1 = fingerDrivenStage1Fade(distHours: liveStart.timeIntervalSince(dayStart) / 3600)
        let bandHeight = CGFloat(leading) * input.hourHeight
        // d = how far the 0:00 line sits below the viewport top.
        // 0 = boundary at the top (band fully off) → s2 = 1.
        let d = (input.extensionOriginY + bandHeight) - visibleTop
        let s2 = positionDrivenStage2Fade(boundarySpan: d, bandHeight: bandHeight)
        leadingResult = combineFades(s1, s2)
    }
    if trailing > 0 {
        let dayEnd = input.dayClock.end
        let liveEnd = input.dragOriginalRange.end.addingTimeInterval(offsetHours * 3600)
        let s1 = fingerDrivenStage1Fade(distHours: dayEnd.timeIntervalSince(liveEnd) / 3600)
        let bandHeight = CGFloat(trailing) * input.hourHeight
        let bandTop = input.extensionOriginY
            + calendarTimelineContentHeight(
                clock: input.dayClock,
                hourHeight: input.hourHeight,
                leadingExtendedHours: leading
            )
        // d = how far the 24:00 line sits above the viewport bottom.
        let d = visibleBottom - bandTop
        let s2 = positionDrivenStage2Fade(boundarySpan: d, bandHeight: bandHeight)
        trailingResult = combineFades(s1, s2)
    }

    return AbandonedFadeCurves(leading: leadingResult, trailing: trailingResult)
}
