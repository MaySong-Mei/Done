import Foundation
import QuartzCore

/// Drives a CADisplayLink-paced spring interpolation over a fixed duration.
/// Used for the proactive boundary-extension OPEN transition during drag:
/// SwiftUI's `ScrollPosition.scrollTo(point:)` snaps in one frame on iOS 26
/// regardless of ambient `withAnimation`, so we feed it 60 interpolated
/// targets/sec from this animator while the `.animation(_:value:)` modifier
/// on `leading` springs over the same duration. Both run on the same time
/// axis → events stay glued to their visible window position as the canvas
/// unfolds. (#55)
@MainActor
final class BoundaryExtensionScrollAnimator: NSObject {
    private var displayLink: CADisplayLink?
    private let startTime: CFTimeInterval
    private let duration: CFTimeInterval
    /// Receives spring-eased progress in [0, 1]. Caller computes scroll/offset
    /// from progress so both writes stay on the same time axis.
    private let onTick: (CGFloat) -> Void
    private let onComplete: () -> Void
    private var completed = false
    private var tickCount = 0

    init(
        duration: CFTimeInterval = 0.28,
        onTick: @escaping (CGFloat) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.startTime = CACurrentMediaTime()
        self.duration = duration
        self.onTick = onTick
        self.onComplete = onComplete
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    func cancel(reason: String = "external") {
        guard !completed else { return }
        completed = true
        NSLog("[#55ext] animator CANCEL tick=%d elapsed=%.3f reason=%@",
              tickCount, CACurrentMediaTime() - startTime, reason)
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleTick() {
        let elapsed = CACurrentMediaTime() - startTime
        tickCount += 1
        if elapsed >= duration {
            NSLog("[#55ext] animator tick=%d FINAL elapsed=%.3f progress=1.0", tickCount, elapsed)
            onTick(1.0)
            displayLink?.invalidate()
            displayLink = nil
            completed = true
            onComplete()
            return
        }
        let t = elapsed / duration
        let progress = CGFloat(Self.springEase(t))
        if tickCount % 3 == 1 {
            NSLog("[#55ext] animator tick=%d elapsed=%.3f t=%.2f progress=%.3f",
                  tickCount, elapsed, t, progress)
        }
        onTick(progress)
    }

    /// Closed-form damped-spring approximation matching the visual feel of
    /// `.interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.12)`.
    /// Slight under-damping (ζ=0.88) for a barely-perceptible settle, no overshoot.
    private static func springEase(_ t: Double) -> Double {
        let omega = 8.0
        let zeta = 0.88
        let envelope = exp(-zeta * omega * t)
        if zeta < 1 {
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            return 1 - envelope * (cos(omegaD * t) + (zeta * omega / omegaD) * sin(omegaD * t))
        }
        return 1 - envelope * (1 + omega * t)
    }
}

/// Single-overshoot "rebounce" animator (#55 follow-event-across-midnight).
/// Emits a unitless amplitude value in [0, 1] that peaks early and decays
/// back to 0, suitable for adding a temporary scroll-offset overshoot on
/// top of an already-snapped target so the user feels an elastic settle
/// after the cross-day re-anchor.
@MainActor
final class CalendarRebounceAnimator: NSObject {
    private var displayLink: CADisplayLink?
    private let startTime: CFTimeInterval
    private let duration: CFTimeInterval
    private let onTick: (CGFloat) -> Void
    private let onComplete: () -> Void
    private var completed = false

    init(
        duration: CFTimeInterval = 0.42,
        onTick: @escaping (CGFloat) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.startTime = CACurrentMediaTime()
        self.duration = duration
        self.onTick = onTick
        self.onComplete = onComplete
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleTick() {
        let elapsed = CACurrentMediaTime() - startTime
        if elapsed >= duration {
            onTick(0)
            displayLink?.invalidate()
            displayLink = nil
            completed = true
            onComplete()
            return
        }
        let t = elapsed / duration
        // Damped spring "release-from-stretch" response: starts at 1
        // (fully stretched), decays toward 0 with a single visible
        // overshoot past zero (perceived as a brief settle past the
        // target before snapping back). Softer ω + slightly more ζ
        // gives a gentler, more flowing settle (was ω=11, ζ=0.55).
        let omega = 7.5
        let zeta = 0.62
        let envelope = exp(-zeta * omega * t)
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let stepResponse = 1 - envelope * (cos(omegaD * t) + (zeta * omega / omegaD) * sin(omegaD * t))
        onTick(CGFloat(1 - stepResponse))
    }
}
