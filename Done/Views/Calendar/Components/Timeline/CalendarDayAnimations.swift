//
//  CalendarDayAnimations.swift
//  Done
//
//  Animation helpers (S5) for the CALayer day renderer — `CASpringAnimation`
//  configuration, Reduce-Motion check, and the fall-through edge-inset
//  smoothstep curve mirrored from `EventBlock`. Extracted from
//  `CalendarDayLayerView.swift` (#69) — no behavior change.
//

import SwiftUI
import UIKit

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
