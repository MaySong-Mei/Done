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
