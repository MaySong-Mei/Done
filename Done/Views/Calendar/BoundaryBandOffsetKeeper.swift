import SwiftUI
import UIKit

/// Keeps the single-day timeline still when the band above today closes.
///
/// Closing that band takes its hours off the top of the scroll content, so
/// the offset has to drop by the same height in the frame the shorter
/// content first draws. A `ScrollPosition` write can't promise that: while a
/// finger is down, UIKit's pan keeps writing the offset from where it thinks
/// the content is, and the whole day jumps by the band's height. The keeper
/// instead moves `contentOffset` from inside the scroll view's own
/// `contentSize` change, the layout pass that shrinks the content, so a drag
/// or a coast carries on from the moved offset.
///
/// A band below today needs none of this: its hours leave the bottom of the
/// content and nothing above the viewport moves.
@MainActor
final class BoundaryBandOffsetKeeper {
    private(set) weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?
    private var pending: (heightChange: CGFloat, armedAt: CFTimeInterval)?
    /// How long an armed shift waits for the content to shrink. The shrink
    /// lands in the layout pass right after the state write, so anything
    /// later is some other change.
    private let armWindow: CFTimeInterval = 0.25

    func attach(_ candidate: UIScrollView) {
        guard candidate !== scrollView else { return }
        scrollView = candidate
        pending = nil
        observation = candidate.observe(\.contentSize, options: [.old, .new]) { [weak self] view, change in
            MainActor.assumeIsolated {
                self?.contentSizeChanged(view, old: change.oldValue ?? .zero, new: change.newValue ?? .zero)
            }
        }
    }

    /// Arms one offset shift of `heightChange` (negative: the band's height)
    /// for the next time the content shrinks. Returns false when no scroll
    /// view is attached, so the caller falls back to a `ScrollPosition`
    /// write.
    func expect(heightChange: CGFloat) -> Bool {
        guard scrollView != nil, heightChange < 0 else { return false }
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
        guard let p = pending else { return }
        let shrink = new.height - old.height
        // Only a shrink of at least half the band is this close; a content
        // change that grows, or barely moves, is something else.
        guard shrink <= p.heightChange / 2 else { return }
        pending = nil
        let before = view.contentOffset.y
        let after = max(-view.adjustedContentInset.top, before + p.heightChange)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.contentOffset.y = after
        CATransaction.commit()
        calendarDebugLog(
            "band.keeper.shift",
            fields: [
                "heightChange": String(format: "%.1f", p.heightChange),
                "contentShrink": String(format: "%.1f", shrink),
                "before": String(format: "%.1f", before),
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
