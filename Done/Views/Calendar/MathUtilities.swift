//
//  MathUtilities.swift
//  Done
//
//  Common math functions for calendar animations and layout calculations.
//

import CoreGraphics

/// Clamps a CGFloat value to a range [min, max].
/// Example: clamp(1.5, 0, 1) returns 1.0
func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
    min(max(x, a), b)
}

/// Clamps an Int value to a ClosedRange.
/// Example: clamp(15, to: 0...10) returns 10
func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
}

/// Linear interpolation between two values.
/// t=0 returns a, t=1 returns b, t=0.5 returns midpoint.
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * clamp(t, 0, 1)
}
