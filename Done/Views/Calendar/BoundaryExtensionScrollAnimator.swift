import Foundation
import QuartzCore

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
        // Damped spring "release-from-stretch" response: starts at 1 (fully
        // stretched), decays toward 0 with a SINGLE, restrained settle past the
        // target. Higher ζ trades the old ~8% bounce for a ~1.5% overshoot — a
        // refined "ease into place" rather than a spring-back — and a softer ω
        // makes the deceleration more graceful. (#55: silkier rebounce; was
        // ω=7.5 ζ=0.62, originally ω=11 ζ=0.55.)
        let omega = 7.0
        let zeta = 0.78
        let envelope = exp(-zeta * omega * t)
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let stepResponse = 1 - envelope * (cos(omegaD * t) + (zeta * omega / omegaD) * sin(omegaD * t))
        onTick(CGFloat(1 - stepResponse))
    }
}
