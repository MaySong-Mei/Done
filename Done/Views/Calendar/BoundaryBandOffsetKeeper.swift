import SwiftUI
import UIKit

/// Keeps the single-day timeline still when the band above today opens or
/// closes.
///
/// That band's hours sit at the top of the scroll content, so opening or
/// closing it moves everything below by its height, and the offset has to
/// move by the same height in the frame the new content first draws. A
/// `ScrollPosition` write can't promise that: while a finger is down,
/// UIKit's pan keeps writing the offset from where it thinks the content
/// is, and an edge autoscroll moves the offset between the write's read and
/// its landing. The keeper instead moves `contentOffset` from inside the
/// scroll view's own `contentSize` change, the layout pass that resizes the
/// content, so a drag, a coast or an autoscroll carries on from there.
///
/// A band below today needs none of this: its hours come and go at the
/// bottom of the content and nothing above the viewport moves.
@MainActor
final class BoundaryBandOffsetKeeper {
    private(set) weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?
    private var pending: (heightChange: CGFloat, armedAt: CFTimeInterval)?
    /// The offset just before the content size changes. When the scroll is
    /// at rest, UIKit clamps the offset into the shorter range before the
    /// change is reported, and that clamped value is not where the user was.
    private var offsetBeforeSizeChange: CGFloat?
    /// How long an armed shift waits for the content to resize. The resize
    /// lands in the layout pass right after the state write, so anything
    /// later is some other change.
    private let armWindow: CFTimeInterval = 0.25

    /// True while a finger or a coast is moving the scroll. A
    /// `ScrollPosition` write then loses to the finger, or stops the coast.
    /// A finger merely resting on the content doesn't count: UIKit takes a
    /// write until the pan begins.
    var userIsScrolling: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating
    }

    /// Where the scroll is right now; nil before a scroll view is attached.
    var liveOffsetY: CGFloat? { scrollView?.contentOffset.y }

    func attach(_ candidate: UIScrollView) {
        guard candidate !== scrollView else { return }
        scrollView = candidate
        pending = nil
        observation = candidate.observe(\.contentSize, options: [.prior, .old, .new]) { [weak self] view, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                if change.isPrior {
                    self.offsetBeforeSizeChange = view.contentOffset.y
                    return
                }
                self.contentSizeChanged(view, old: change.oldValue ?? .zero, new: change.newValue ?? .zero)
            }
        }
    }

    /// Arms one offset shift of `heightChange` (the band's height: positive
    /// when it opens, negative when it closes) for the next time the content
    /// resizes that way. Returns false when no scroll view is attached, so
    /// the caller falls back to a `ScrollPosition` write.
    func expect(heightChange: CGFloat) -> Bool {
        guard scrollView != nil, heightChange != 0 else { return false }
        let stamp = CACurrentMediaTime()
        pending = (heightChange, stamp)
        DispatchQueue.main.asyncAfter(deadline: .now() + armWindow) { [weak self] in
            guard let self, let p = self.pending, p.armedAt == stamp else { return }
            self.pending = nil
            calendarDebugLog("band.keeper.expired", fields: ["heightChange": String(format: "%.1f", p.heightChange)])
        }
        return true
    }

    private func contentSizeChanged(_ view: UIScrollView, old: CGSize, new: CGSize) {
        let reportedBefore = offsetBeforeSizeChange
        offsetBeforeSizeChange = nil
        guard let p = pending else { return }
        let resize = new.height - old.height
        // Only a resize the band's way by at least half its height is this
        // band; one the other way, or one that barely moves, is something else.
        guard resize * p.heightChange > 0, abs(resize) >= abs(p.heightChange) / 2 else { return }
        pending = nil
        let atReport = view.contentOffset.y
        let before = reportedBefore ?? atReport
        let after = max(-view.adjustedContentInset.top, before + p.heightChange)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.contentOffset.y = after
        CATransaction.commit()
        calendarDebugLog(
            "band.keeper.shift",
            fields: [
                "heightChange": String(format: "%.1f", p.heightChange),
                "contentResize": String(format: "%.1f", resize),
                "before": String(format: "%.1f", before),
                "atReport": String(format: "%.1f", atReport),
                "after": String(format: "%.1f", after),
                "dragging": "\(view.isDragging)",
                "decelerating": "\(view.isDecelerating)",
                "lagMs": String(format: "%.1f", (CACurrentMediaTime() - p.armedAt) * 1000)
            ]
        )
    }
}

/// Zero-size view inside the timeline's scroll content that hands the
/// backing `UIScrollView` to a `BoundaryBandOffsetKeeper`.
struct BoundaryBandOffsetKeeperProbe: UIViewRepresentable {
    let keeper: BoundaryBandOffsetKeeper

    final class ProbeView: UIView {
        var onScrollView: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The hosting hierarchy is only complete after this pass.
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view, !(current is UIScrollView) { view = current.superview }
                if let scrollView = view as? UIScrollView { self?.onScrollView?(scrollView) }
            }
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onScrollView = { [keeper] in keeper.attach($0) }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}
}
