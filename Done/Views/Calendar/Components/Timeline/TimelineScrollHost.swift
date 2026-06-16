//
//  TimelineScrollHost.swift
//  Done
//
//  UIScrollView-backed alternative to the vertical SwiftUI `ScrollView` that
//  hosts the calendar timeline (issue #57). When the
//  `calendarUseUIScrollViewTimeline` flag is ON, `CalendarPageView`'s
//  `timelineScroll(...)` produces this host instead of the SwiftUI tree, and
//  band-collapse co-commits `contentSize` + `contentOffset` in a single
//  `CATransaction` so the user-visible 1-frame mismatch (covered today by
//  `timelineCollapseDim`) goes away.
//
//  Architecture (the Plan agent's Path A):
//    - `UIScrollView` (vertical) wraps a `UIHostingController` whose view
//      renders the existing SwiftUI timeline subtree. We OWN the scroll
//      view's `contentSize` math (computed from `hourHeight` × visible
//      hours) so we never have to wait on `UIHostingController`'s async
//      intrinsic size to settle — the prior #57 retry failure mode.
//    - A `TimelineScrollProxy` exposes the scroll API the page view used to
//      reach through `.scrollPosition`/`scrollTo`. It also holds the
//      `coCommit(...)` entrypoint used by the band-collapse close path.
//
//  This file deliberately does NOT migrate the per-callsite `scrollTo`
//  consumers — they go through the `CalendarPageView.scrollVerticallyTo`
//  fork helper. See issue #57 PR #1 scope notes.
//

import SwiftUI
import UIKit
import Combine

// MARK: - Scroll proxy

/// SwiftUI-facing handle to the UIScrollView-backed timeline. Mirrors the
/// subset of SwiftUI's `ScrollPosition` API the calendar page view uses
/// (`scrollTo(point:)`), plus the atomic co-commit entrypoint required by
/// the issue-#57 close path.
@MainActor
final class TimelineScrollProxy: ObservableObject {
    /// Live content offset Y published from the scroll view's delegate.
    /// Drives consumers that previously read SwiftUI's
    /// `onScrollGeometryChange`.
    @Published private(set) var currentOffsetY: CGFloat = 0
    /// Viewport height (== scroll view's bounds height). Published so the
    /// `timelineScrollViewportHeight` gate at `CalendarPageView` can run on
    /// the same 0.5pt threshold it always has.
    @Published private(set) var viewportHeight: CGFloat = 0

    fileprivate weak var scrollView: UIScrollView?
    fileprivate weak var contentHost: UIView?

    fileprivate func updatePublishedScroll(offsetY: CGFloat, viewportHeight: CGFloat) {
        currentOffsetY = offsetY
        self.viewportHeight = viewportHeight
    }

    /// Mirror of `verticalScrollPosition.scrollTo(point:)`. The
    /// non-animated path disables implicit `CATransaction` animations —
    /// matches the existing `Transaction.disablesAnimations` discipline at
    /// every existing scroll call site on the page view. The animated
    /// path uses UIScrollView's native bounce-aware setContentOffset
    /// animator, parity with a SwiftUI scrollTo issued inside a default
    /// transaction.
    func scrollTo(y: CGFloat, animated: Bool = false) {
        guard let scrollView else { return }
        if animated {
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollView.contentOffset = CGPoint(x: 0, y: y)
            CATransaction.commit()
        }
    }

    /// THE atomic co-commit (issue #57). Both writes land in ONE
    /// `CATransaction` with implicit actions disabled, so the user never
    /// sees a frame where `contentSize` has shrunk but `contentOffset`
    /// hasn't compensated.
    ///
    /// Caller computes `contentHeight` from the same hourHeight × visible
    /// hours math the day-host frames use; we do NOT read SwiftUI's
    /// intrinsic size back (the prior failure mode).
    func coCommit(contentHeight: CGFloat, contentWidth: CGFloat, offsetY: CGFloat) {
        guard let scrollView, let contentHost else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentHost.frame.size = CGSize(width: contentWidth, height: contentHeight)
        scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
        scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        CATransaction.commit()
    }

    /// Snapshot reads — used in places that previously read from the
    /// SwiftUI `ScrollGeometry` to decide flow control without subscribing.
    var contentSize: CGSize { scrollView?.contentSize ?? .zero }
}

// MARK: - Content-height helper

/// Replica of the SwiftUI `timelineLayer`'s vertical extent — must agree
/// with `TimelinePagerView.totalHeight` to the pixel so an atomic
/// `coCommit` doesn't strand the scroll view at a contentSize SwiftUI is
/// about to fight on the next render tick. Slot-minute aware so 30-min
/// half-hour grids don't accumulate a ±0.5×hourHeight drift across band
/// open/close.
func calendarTimelineHostContentHeight(
    headerHeight: CGFloat,
    allDayHeight: CGFloat,
    hourHeight: CGFloat,
    effectiveSlotMinutes: Int,
    leadingExtendedHours: Int,
    trailingExtendedHours: Int,
    timelineBottomInset: CGFloat,
    topOverlayInset: CGFloat,
    timelineBottomScrollPadding: CGFloat
) -> CGFloat {
    let totalVisibleHours = calendarTimelineTotalVisibleHours(
        leadingExtendedHours: leadingExtendedHours,
        trailingExtendedHours: trailingExtendedHours
    )
    let slotMinutes = max(1, effectiveSlotMinutes)
    let slotCount = (totalVisibleHours * 60) / slotMinutes + 1
    let slotHeight = hourHeight * CGFloat(slotMinutes) / 60
    let timelineHeight = headerHeight + CGFloat(slotCount) * slotHeight + timelineBottomInset
    let totalHeight = allDayHeight + timelineHeight
    return topOverlayInset + totalHeight + timelineBottomScrollPadding
}

// MARK: - SwiftUI representable

struct TimelineScrollHost<Content: View>: UIViewRepresentable {
    let proxy: TimelineScrollProxy
    /// Externally-computed content size. We push this onto the scroll view;
    /// the UIHostingController's view is sized to the same rect.
    let contentSize: CGSize
    /// Called from `scrollViewDidScroll` so consumers that previously read
    /// `onScrollGeometryChange` keep working. Gated at the call site (the
    /// CalendarPageView handler already throttles for 0.5pt / 2pt deltas).
    let onScrollChange: (_ offsetY: CGFloat, _ viewportHeight: CGFloat) -> Void
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(proxy: proxy, onScrollChange: onScrollChange)
    }

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.scrollView.delegate = context.coordinator
        container.scrollView.alwaysBounceVertical = true
        container.scrollView.showsHorizontalScrollIndicator = false
        container.scrollView.showsVerticalScrollIndicator = true
        container.scrollView.contentInsetAdjustmentBehavior = .never

        let host = UIHostingController(rootView: AnyView(content()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.autoresizingMask = []
        host.view.frame = CGRect(origin: .zero, size: contentSize)
        container.scrollView.addSubview(host.view)
        container.scrollView.contentSize = contentSize
        // Hosted SwiftUI subtree's `.onAppear` callbacks need the
        // UIHostingController to be a CHILD of a real parent view
        // controller — otherwise `viewWillAppear` / `viewDidAppear` never
        // fire and timer-/fetch-driven .onAppear blocks silently no-op.
        // `attachIfNeeded` resolves the nearest UIVC via the responder
        // chain once the container is in a window; on cold-start the
        // container's responder chain isn't ready yet, so retry from
        // `didMoveToWindow`.
        container.pendingHost = host
        container.attachIfNeeded()

        proxy.scrollView = container.scrollView
        proxy.contentHost = host.view
        context.coordinator.host = host

        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        let scrollView = container.scrollView
        if scrollView.contentSize != contentSize {
            // Initial sync only — the close-path co-commit owns subsequent
            // changes via `proxy.coCommit(...)`. Updating contentSize from
            // here on every SwiftUI re-eval would race the co-commit and
            // re-introduce the issue-#57 flash.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            context.coordinator.host?.view.frame = CGRect(origin: .zero, size: contentSize)
            scrollView.contentSize = contentSize
            CATransaction.commit()
        }
        context.coordinator.host?.rootView = AnyView(content())
    }

    static func dismantleUIView(_ container: ContainerView, coordinator: Coordinator) {
        if let host = coordinator.host {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        coordinator.host = nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let proxy: TimelineScrollProxy
        let onScrollChange: (CGFloat, CGFloat) -> Void
        var host: UIHostingController<AnyView>?

        init(
            proxy: TimelineScrollProxy,
            onScrollChange: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.proxy = proxy
            self.onScrollChange = onScrollChange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y
            let h = scrollView.bounds.height
            proxy.updatePublishedScroll(offsetY: y, viewportHeight: h)
            onScrollChange(y, h)
        }
    }

    // MARK: Container

    final class ContainerView: UIView {
        let scrollView = UIScrollView()
        /// `UIHostingController` waiting to be added as a child of the
        /// nearest ancestor view controller. `nil` once `attachIfNeeded`
        /// successfully parents it.
        fileprivate weak var pendingHost: UIHostingController<AnyView>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        fileprivate func attachIfNeeded() {
            guard let host = pendingHost, host.parent == nil else { return }
            guard let parentVC = nearestParentViewController() else { return }
            parentVC.addChild(host)
            host.didMove(toParent: parentVC)
            pendingHost = nil
        }

        private func nearestParentViewController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let vc = next as? UIViewController { return vc }
                responder = next
            }
            return nil
        }
    }
}
