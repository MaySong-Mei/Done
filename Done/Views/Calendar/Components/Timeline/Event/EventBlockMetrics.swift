//
//  EventBlockMetrics.swift
//  Done
//
//  The event block's look as numbers, shared by the iPhone's CALayer
//  renderer (CalendarDayLayerView) and the Mac canvas, so the two draw the
//  same block. `EventBlockStyle` and the font helpers moved here verbatim
//  from EventBlock.swift; the corner radius, effort bar and todo urgency
//  were literals in CalendarDayLayerView and are read from here now.
//

import CoreGraphics
import Foundation

/// Event block style configuration
struct EventBlockStyle: Equatable {
    let showTimeRange: Bool

    var fillOpacity: Double { 0.4 }
    var strokeOpacity: Double { 0.7 }
    var strokeWidth: CGFloat { 1.2 }

    static let edit = EventBlockStyle(showTimeRange: true)
    static let preview = EventBlockStyle(showTimeRange: false)
}

/// Default title font size when the user has not set one. Matches the
/// historical hard-coded value so existing users see no visual change.
let calendarEventTitleFontSizeDefault: CGFloat = 12

/// Time-range font size paired with a given title font size. Keeps the
/// historical 12->8 (or 12->7 in week mode) ratio, with a hard floor at
/// 7pt so the time line stays legible at small title sizes.
func calendarEventTimeFontSize(forTitleFontSize titleFontSize: CGFloat, isWeekMode: Bool) -> CGFloat {
    let ratio: CGFloat = isWeekMode ? (7.0 / 12.0) : (8.0 / 12.0)
    return max(7, (titleFontSize * ratio).rounded())
}

/// Block corner radius (continuous curvature). Interrupt blocks are tighter.
func calendarEventBlockCornerRadius(isInterrupt: Bool) -> CGFloat {
    isInterrupt ? 3 : 4
}

/// Border width: the style's stroke, a little heavier on an interrupt.
func calendarEventBlockStrokeWidth(isInterrupt: Bool) -> CGFloat {
    let base = EventBlockStyle.edit.strokeWidth
    return isInterrupt ? max(0.8, base + 0.2) : base
}

/// The leading effort bar's width for a `colorDepth` in 0…1 (0 = no bar).
func calendarEventEffortBarWidth(colorDepth: Double, isWeekMode: Bool) -> CGFloat {
    isWeekMode
        ? 1.0 + CGFloat(colorDepth) * 1.5
        : 1.5 + CGFloat(colorDepth) * 2.5
}

/// A todo's border width (an inset stroke over the block border).
let calendarTodoBorderWidth: CGFloat = 2

/// Todo border urgency ramp (spec 01 §4), evaluated against `now`.
enum CalendarTodoBorderUrgency: Equatable {
    /// White at 0.9 — the kind signal on the 0.4-tint fill.
    case normal
    /// Orange at 0.95: due within 24 hours.
    case dueSoon
    /// Red at 0.95: past due.
    case overdue

    init(deadline: Date?, isDone: Bool, now: Date) {
        guard !isDone, let deadline else { self = .normal; return }
        if deadline < now { self = .overdue }
        else if deadline.timeIntervalSince(now) < 24 * 3600 { self = .dueSoon }
        else { self = .normal }
    }
}
