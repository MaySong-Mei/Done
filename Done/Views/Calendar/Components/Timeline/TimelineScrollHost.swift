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
//  NOTE on SourceKit-LSP "No such module 'UIKit'":
//  The `import UIKit` below (and the matching imports in CalendarPageView.swift)
//  may flag a SourceKit-LSP diagnostic in editor tooling. This is BENIGN —
//  `xcodebuild` succeeds. SourceKit-LSP can't read `.xcodeproj` directly, so
//  without a `buildServer.json` it falls back to a default-toolchain compile
//  invocation that doesn't pass `-sdk iphoneos`, leaving UIKit unreachable.
//  The fix (if you want clean editor diagnostics) is to install
//  `xcode-build-server` and run
//      xcode-build-server config -scheme Done -project Done.xcodeproj
//  in the repo root to emit a `buildServer.json` SourceKit-LSP can consume.
//  Do NOT remove these imports — they're load-bearing for the build.
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
    /// Live content offset Y from the scroll view's delegate. Snapshot-read
    /// at `coCommit(...)` time — NOT `@Published`, because doing so would
    /// `objectWillChange` the `@StateObject` on every scroll tick and
    /// invalidate `CalendarPageView.body` 60×/sec (deep-review B1). The
    /// SwiftUI `.onScrollGeometryChange` path writes to local `@State`
    /// behind 0.5pt/2pt gates; we mirror that by routing every scroll
    /// callback through `handleTimelineUIScrollChange(...)` which applies
    /// the same gates.
    private(set) var currentOffsetY: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0

    fileprivate weak var scrollView: UIScrollView?
    /// The `UIHostingController`'s root view — the single subview hosted
    /// inside `scrollView`. Held so the close-path can apply a transient
    /// `CATransform3D` translation to compensate the day-layer's
    /// stale-Model render on a LEADING band collapse (see
    /// `applyCloseLeadingTransientCompensation` below).
    fileprivate weak var hostContentView: UIView?
    /// Height constraint on the hosted content view. Mutated by `coCommit`
    /// to atomically resize the scroll content alongside the
    /// `contentOffset` write. `nil` until the host installs constraints.
    fileprivate weak var contentHeightConstraint: NSLayoutConstraint?

    fileprivate func updateScrollSnapshot(offsetY: CGFloat, viewportHeight: CGFloat) {
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

    /// THE atomic co-commit (issue #57). Drives the height constraint on
    /// the hosted content view + the `contentOffset` write in ONE
    /// `CATransaction` with implicit actions disabled, so the user never
    /// sees a frame where the scroll content has shrunk but the offset
    /// hasn't compensated. Width tracks the scroll view's frame anchor
    /// automatically — caller only owns height.
    ///
    /// Caller computes `contentHeight` from the same hourHeight × visible
    /// hours math the day-host frames use; we do NOT read SwiftUI's
    /// intrinsic size back (the prior failure mode).
    ///
    /// `transientHostYCompensation` is the per-leading-band-close stale-
    /// Model compensation: when non-zero, the hosted content view is
    /// translated UP by that amount inside this SAME transaction (so the
    /// stale-Model day-layer render still LOOKS right after the offset
    /// jump), then the transform clears on the next runloop tick after
    /// SwiftUI's body re-eval has reached the day-layer with the new
    /// `leadingExtendedHours`. See
    /// `applyCloseLeadingTransientCompensation(deltaY:)` for the full
    /// rationale.
    ///
    /// Spec 07 §5 S2 deletion gate: imperative single-day band collapse
    /// goes through `contentInset` (constant `contentSize`), so this
    /// function is only reached on the legacy (non-imperative) fork. When
    /// the imperative flag default flips ON in S7, this + `applyClose
    /// LeadingTransientCompensation` + the height-constraint write path
    /// become dead code and can be removed.
    func coCommit(
        contentHeight: CGFloat,
        offsetY: CGFloat,
        transientHostYCompensation: CGFloat = 0
    ) {
        guard let scrollView, let constraint = contentHeightConstraint else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        constraint.constant = contentHeight
        // Force the layout pass to flush inside this transaction so the
        // contentSize derivation (via `contentLayoutGuide` constraints)
        // commits BEFORE the contentOffset write. Without this the offset
        // would clamp against the stale (larger) contentSize.
        scrollView.layoutIfNeeded()
        // Apply the stale-Model compensation BEFORE the offset write so
        // the transform is present when the contentOffset KVO fires the
        // day-layer's `cullViewportIfChanged` re-render path.
        applyCloseLeadingTransientCompensation(deltaY: transientHostYCompensation)
        scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        CATransaction.commit()
    }

    /// One-shot CADisplayLink wired during a close-path compensation to
    /// clear the transient host translation EXACTLY one display frame
    /// after the offset write. A frame guarantees SwiftUI's body re-eval
    /// + UIHostingController's internal subtree re-render have run, so
    /// the day-layer is now drawing against the NEW
    /// `leadingExtendedHours` Model and the compensation transform is no
    /// longer papering over a stale render.
    ///
    /// Why a display link rather than `DispatchQueue.main.async`: the
    /// async queue runs on the next runloop iteration which may land
    /// BEFORE SwiftUI's scheduler ticks, clearing the transform too
    /// early and exposing the stale frame the compensation was meant to
    /// hide. A CADisplayLink fires AFTER the display-refresh signal and
    /// thus AFTER SwiftUI's per-frame eval has propagated the new Model.
    private var compensationClearDisplayLink: CADisplayLink?

    /// Apply a transient Y translation to the hosted content view that
    /// compensates the day-layer's stale-Model render during a LEADING
    /// band collapse. Issue: `coCommit(...)` writes `contentOffset` inside
    /// a CATransaction; the day-layer's KVO observer + the
    /// `layoutIfNeeded` triggered by the height-constraint change BOTH
    /// re-render against the SwiftUI Model that still carries the OLD
    /// `leadingExtendedHours` (SwiftUI hasn't propagated the new state
    /// yet). Events thus render at their OLD absoluteY (which baked in
    /// the band) but against the NEW compensated viewport offset — they
    /// appear shifted DOWN by `bandHours*hourHeight` for one frame, then
    /// snap back UP on the next SwiftUI tick.
    ///
    /// Compensation: translate `hostContentView` UP by `deltaY` (the
    /// band amount that just closed) inside the same CATransaction.
    /// Visually keeps content in place during the stale-Model frame.
    /// Cleared one display frame later by a one-shot CADisplayLink so
    /// SwiftUI's per-frame body eval (and the propagated UIHostingController
    /// subtree re-render) has had a chance to apply the new Model to
    /// the day-layer before the transform returns to identity.
    ///
    /// Trailing-only collapses pass `deltaY = 0` and this is a no-op.
    /// (Trailing close needs no scroll compensation: the chopped band
    /// was BELOW the viewport, so absoluteY values are unchanged.)
    func applyCloseLeadingTransientCompensation(deltaY: CGFloat) {
        guard abs(deltaY) > 0.5, let hostContentView else { return }
        // Apply inside whatever CATransaction the caller already opened.
        // No begin/commit here — `coCommit(...)` owns the actions-disabled
        // transaction wrapping this call.
        hostContentView.layer.transform = CATransform3DMakeTranslation(0, -deltaY, 0)
        // Schedule the one-shot clear for the next display frame.
        // Cancel any in-flight link first (a fast double-collapse would
        // otherwise leave a stale link firing against a fresh transform).
        compensationClearDisplayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(handleCompensationClearTick(_:)))
        link.add(to: .main, forMode: .common)
        compensationClearDisplayLink = link
    }

    @objc private func handleCompensationClearTick(_ link: CADisplayLink) {
        link.invalidate()
        if compensationClearDisplayLink === link {
            compensationClearDisplayLink = nil
        }
        guard let hostContentView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostContentView.layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: Spec 07 — band visibility via animated contentInset

    /// True while an imperative band-inset OPEN/CLOSE animation is running.
    /// `TimelineScrollHost.updateUIView` skips its (snap) inset sync while this
    /// is set so a SwiftUI re-eval mid-transition doesn't kill the animation;
    /// the animation lands exactly on the resting value `updateUIView` would
    /// have set, so no snap is needed afterward.
    private(set) var isAnimatingBandInset = false

    /// Spec 07 §2A: drive the band's leading/trailing visibility off the scroll
    /// view's `contentInset` (constant `contentSize`). Band OPEN reveals the
    /// always-present 12h band by relaxing the negative inset toward its open
    /// value; CLOSE rebounds it back. `animated` uses a spring so the close
    /// reads as the original "弹性收回" rebounce; the visible time stays put
    /// because `contentInset` changes only the scrollable RANGE, not which
    /// content maps to the current offset (so NO offset compensation — the
    /// race the co-commit fought cannot occur).
    func setBandInset(top: CGFloat, bottom: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let target = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard scrollView.contentInset != target else { return }
        applyContentInsetTarget(target, animated: animated)
    }

    /// Spec 07 §5 S2: drive ONE band side independently. Leading band uses
    /// `setContentInsetTop`, trailing uses `setContentInsetBottom`. Each preserves
    /// the other side's current inset so a single-side rebounce doesn't perturb
    /// the open side. The combined `setBandInset` remains the atomic-both-sides
    /// API used when a state transition flips both at once.
    func setContentInsetTop(_ top: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let current = scrollView.contentInset
        let target = UIEdgeInsets(top: top, left: current.left, bottom: current.bottom, right: current.right)
        guard current != target else { return }
        applyContentInsetTarget(target, animated: animated)
    }

    func setContentInsetBottom(_ bottom: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let current = scrollView.contentInset
        let target = UIEdgeInsets(top: current.top, left: current.left, bottom: bottom, right: current.right)
        guard current != target else { return }
        applyContentInsetTarget(target, animated: animated)
    }

    private func applyContentInsetTarget(_ target: UIEdgeInsets, animated: Bool) {
        guard let scrollView else { return }
        if animated {
            isAnimatingBandInset = true
            UIView.animate(
                withDuration: 0.5, delay: 0,
                usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) {
                scrollView.contentInset = target
            } completion: { [weak self] _ in
                self?.isAnimatingBandInset = false
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollView.contentInset = target
            CATransaction.commit()
        }
    }

    /// Snapshot reads — used in places that previously read from the
    /// SwiftUI `ScrollGeometry` to decide flow control without subscribing.
    var contentSize: CGSize { scrollView?.contentSize ?? .zero }

    /// True once the host's `makeUIView` has installed the height constraint
    /// — i.e. `coCommit(...)` will reach the UIScrollView. Used by
    /// `applyCloseBandStateAtomicCoCommit`'s proxy-not-wired fallback
    /// (deep-review C6).
    var isInstalled: Bool { contentHeightConstraint != nil }

    // MARK: Cold-start scroll-to-now

    /// One-shot callback fired by `ContainerView.layoutSubviews()` the
    /// FIRST time the scroll view has a real bounds AND contentSize
    /// (both > 0). Lets the page view perform an initial scroll-to-now
    /// without polling — the `.task`-based polling fell back to 0:00
    /// when `viewportHeight` (only populated by `scrollViewDidScroll`)
    /// was still 0 on cold start, causing the gate
    /// `contentSize > targetY + viewportHeight` to be evaluated against
    /// a still-zero contentSize for longer than the 1 s polling budget
    /// in some cold paths (e.g. focus state restoration races first
    /// layout). The callback fires exactly once per host install and
    /// is auto-cleared after firing.
    fileprivate var onFirstLayoutReady: (() -> Void)?
    /// Latch so `ContainerView.layoutSubviews` only fires the callback
    /// on the FIRST layout pass that has real bounds — subsequent
    /// layout passes (rotation, content-height changes from boundary-
    /// extension toggles) are no-ops.
    fileprivate var didFireFirstLayoutReady: Bool = false

    /// Register a one-shot callback for the cold-start
    /// "scroll view has real bounds + contentSize" event. If the
    /// scroll view is ALREADY layout-ready when this is called, the
    /// callback fires synchronously on the next runloop tick.
    /// Idempotent: a later call replaces the prior callback (the page
    /// view only ever installs one).
    func setOnFirstLayoutReady(_ callback: @escaping () -> Void) {
        // If the scroll view has already had a real layout pass (e.g.
        // the page view re-set the callback after a flag flip), fire
        // on the next tick. Otherwise wait for `layoutSubviews`.
        if let sv = scrollView,
           sv.bounds.height > 0,
           sv.contentSize.height > 0,
           didFireFirstLayoutReady {
            DispatchQueue.main.async { callback() }
            return
        }
        onFirstLayoutReady = callback
    }

    // MARK: Spec 07 §5 S5.1 — scroll-view installed signal
    //
    // Fired exactly once when `TimelineScrollHost.makeUIView` has wired up
    // the `UIScrollView` + the host content view. Used by the imperative
    // day-layer path to instantiate `DayLayerCoordinator` with a live
    // `UIScrollView` reference + the content host UIView. The proxy's
    // `scrollView` / `hostContentView` weak refs aren't enough on their own
    // because the page view needs an EDGE notification (so it can react
    // exactly once when the refs become non-nil — observing the weak refs
    // by polling reintroduces the lifecycle races the proxy was designed
    // to avoid). Pattern mirrors `setOnFirstLayoutReady` above.
    //
    // If the scroll view is ALREADY installed when the callback is
    // registered (e.g. flag-flip mid-session), fire on the next runloop
    // tick. Otherwise hold until `makeUIView` reaches the install line.

    /// One-shot callback fired by `makeUIView` after the scroll view and
    /// hosted content view are wired into the proxy. Auto-cleared after
    /// firing so it can be re-armed across host install/dismantle cycles
    /// (tab switches, flag flips, range-mode rebuilds).
    fileprivate var onScrollViewInstalled: ((UIScrollView, UIView) -> Void)?

    /// Persistent callback fired by `dismantleUIView` so the imperative
    /// coordinator can detach its host subview before the scroll view goes
    /// away. Survives across install/dismantle cycles so the page view
    /// only registers it once.
    fileprivate var onScrollViewUninstalled: (() -> Void)?

    /// Register a one-shot callback for the "scroll view + content host
    /// wired" edge. Replaces any prior callback. If the scroll view is
    /// ALREADY wired when this is called, fires on the next runloop tick.
    func setOnScrollViewInstalled(_ callback: @escaping (UIScrollView, UIView) -> Void) {
        if let sv = scrollView, let host = hostContentView {
            DispatchQueue.main.async { callback(sv, host) }
            return
        }
        onScrollViewInstalled = callback
    }

    /// Register a persistent callback fired on each dismantle. Replaces
    /// any prior callback. Used by the imperative day-layer path to drop
    /// its host subview so the coordinator can re-add it cleanly on the
    /// next install.
    func setOnScrollViewUninstalled(_ callback: @escaping () -> Void) {
        onScrollViewUninstalled = callback
    }

    fileprivate func fireOnScrollViewInstalledIfNeeded() {
        guard let sv = scrollView, let host = hostContentView else { return }
        let callback = onScrollViewInstalled
        onScrollViewInstalled = nil
        callback?(sv, host)
    }

    fileprivate func fireOnScrollViewUninstalled() {
        onScrollViewUninstalled?()
    }

    fileprivate func fireFirstLayoutReadyIfNeeded() {
        guard !didFireFirstLayoutReady else { return }
        guard let sv = scrollView,
              sv.bounds.height > 0,
              sv.contentSize.height > 0 else { return }
        didFireFirstLayoutReady = true
        let callback = onFirstLayoutReady
        onFirstLayoutReady = nil
        callback?()
    }
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
    /// Externally-computed content HEIGHT (slot-aware, matches the SwiftUI
    /// `timelineLayer.totalHeight` formula). Width auto-tracks the scroll
    /// view's frame anchor via Auto Layout, so the caller never has to
    /// know the viewport width.
    let contentHeight: CGFloat
    /// Spec 07 §2A: content insets that hide the 48h-constant model's leading
    /// (top) / trailing (bottom) bands — band visibility WITHOUT a contentSize
    /// change. Top also folds in the pinned all-day height so 0:00 rests just
    /// below the pinned pills. Both default 0 ⇒ the non-imperative path applies
    /// no inset and is byte-identical.
    var bandContentInsetTop: CGFloat = 0
    var bandContentInsetBottom: CGFloat = 0
    /// Called from `scrollViewDidScroll` so consumers that previously read
    /// `onScrollGeometryChange` keep working. Gated at the call site (the
    /// CalendarPageView handler already throttles for 0.5pt / 2pt deltas).
    let onScrollChange: (_ offsetY: CGFloat, _ viewportHeight: CGFloat) -> Void
    /// Phase bridge that mirrors SwiftUI's `.onScrollPhaseChange`. `true`
    /// while the user is dragging or the scroll view is decelerating;
    /// `false` once decelerating ends or programmatic scrolls finish.
    /// Drives `isVerticallyScrolling` so `VerticalScrollGate` can freeze
    /// the heavy `TimelinePagerView` subtree during scroll (deep-review B2).
    let onPhaseChange: (_ isScrolling: Bool) -> Void
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(proxy: proxy, onScrollChange: onScrollChange, onPhaseChange: onPhaseChange)
    }

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.proxy = proxy
        container.scrollView.delegate = context.coordinator
        container.scrollView.alwaysBounceVertical = true
        container.scrollView.showsHorizontalScrollIndicator = false
        container.scrollView.showsVerticalScrollIndicator = true
        container.scrollView.contentInsetAdjustmentBehavior = .never
        // Spec 07 §2A: drive band visibility off contentInset, never
        // contentSize. Only when a band inset is actually present (imperative
        // path) — keep the non-imperative UIScrollView path byte-identical by
        // not touching indicator insets / contentInset there.
        if bandContentInsetTop != 0 || bandContentInsetBottom != 0 {
            container.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
            container.scrollView.contentInset = UIEdgeInsets(
                top: bandContentInsetTop, left: 0, bottom: bandContentInsetBottom, right: 0
            )
        }

        let host = UIHostingController(rootView: AnyView(content()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.scrollView.addSubview(host.view)

        // Constraint plumbing — the modern UIScrollView pattern. The
        // contentLayoutGuide anchors derive `contentSize` from the host
        // view's frame, so we only mutate the height constraint to grow
        // / shrink the scrollable extent. The frameLayoutGuide.widthAnchor
        // pin auto-sizes the content horizontally to match the viewport.
        let layoutGuide = container.scrollView.contentLayoutGuide
        let widthGuide = container.scrollView.frameLayoutGuide
        let heightConstraint = host.view.heightAnchor.constraint(equalToConstant: contentHeight)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: layoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: layoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: layoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: widthGuide.widthAnchor),
            heightConstraint
        ])

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
        proxy.contentHeightConstraint = heightConstraint
        proxy.hostContentView = host.view
        // Reset the first-layout latch — a new host install (cold
        // start, tab re-entry rebuilding the tree, flag-flip causing a
        // make/dismantle) should fire the cold-start scroll-to-now
        // callback again if the page view is asking for one.
        proxy.didFireFirstLayoutReady = false
        context.coordinator.host = host

        // Spec 07 §5 S5.1: signal to the page view that the scroll view +
        // content host are now wired. This is the only point at which the
        // imperative day-layer coordinator can be constructed — the
        // `UIScrollView` reference doesn't exist before this and a
        // dismantle-then-remake (tab switch) replaces it.
        proxy.fireOnScrollViewInstalledIfNeeded()

        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        // Sync SwiftUI content (input rebuild) on every re-eval.
        context.coordinator.host?.rootView = AnyView(content())

        // Initial / SwiftUI-driven content-height sync. The close-path
        // co-commit owns subsequent changes via `proxy.coCommit(...)`. A
        // mid-flight `coCommit` will have written `constraint.constant`
        // already; here we only re-apply if SwiftUI thinks the height
        // changed (e.g. hourHeight pinch outside the band-collapse path)
        // and the proxy is idle.
        if let constraint = proxy.contentHeightConstraint,
           abs(constraint.constant - contentHeight) > 0.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            constraint.constant = contentHeight
            container.scrollView.layoutIfNeeded()
            CATransaction.commit()
        }

        // Spec 07 §2A: keep the band insets in lockstep with `contentHeight`.
        // The negative insets scale with `hourHeight`, so a pinch that changes
        // the height changes them too. Actions disabled so the scrollable-range
        // shift doesn't animate a contentOffset jump. SKIP while an imperative
        // band OPEN/CLOSE animation is running — `bandContentInsetTop` already
        // reflects the new resting state and a snap here would kill the spring.
        if !proxy.isAnimatingBandInset {
            let targetInset = UIEdgeInsets(
                top: bandContentInsetTop, left: 0, bottom: bandContentInsetBottom, right: 0
            )
            if container.scrollView.contentInset != targetInset {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                container.scrollView.contentInset = targetInset
                CATransaction.commit()
            }
        }
    }

    static func dismantleUIView(_ container: ContainerView, coordinator: Coordinator) {
        // Spec 07 §5 S5.1: notify the imperative day-layer path that the
        // scroll view is going away so the coordinator can drop its host
        // subview BEFORE we tear the hosting controller down.
        container.proxy?.fireOnScrollViewUninstalled()

        if let host = coordinator.host {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        coordinator.host = nil
        // Defensive: the SwiftUI representable lifecycle should drop the
        // coordinator after this call, but the scroll view itself may
        // outlive the dismantle on UIKit's side (parking + retain by
        // ancestor controllers). Detach the delegate now so any in-flight
        // `scrollViewDidScroll` callback can't fire against a
        // about-to-be-released coordinator.
        container.scrollView.delegate = nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let proxy: TimelineScrollProxy
        let onScrollChange: (CGFloat, CGFloat) -> Void
        let onPhaseChange: (Bool) -> Void
        var host: UIHostingController<AnyView>?

        init(
            proxy: TimelineScrollProxy,
            onScrollChange: @escaping (CGFloat, CGFloat) -> Void,
            onPhaseChange: @escaping (Bool) -> Void
        ) {
            self.proxy = proxy
            self.onScrollChange = onScrollChange
            self.onPhaseChange = onPhaseChange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y
            let h = scrollView.bounds.height
            proxy.updateScrollSnapshot(offsetY: y, viewportHeight: h)
            onScrollChange(y, h)
        }

        // MARK: Phase bridge — mirrors SwiftUI's .onScrollPhaseChange union of
        // `.interacting` + `.decelerating`. `isScrolling = true` while either
        // is true; `false` on settle. Drives `VerticalScrollGate`.

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onPhaseChange(true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { onPhaseChange(false) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            onPhaseChange(false)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            onPhaseChange(false)
        }
    }

    // MARK: Container

    final class ContainerView: UIView {
        let scrollView = UIScrollView()
        /// `UIHostingController` waiting to be added as a child of the
        /// nearest ancestor view controller. `nil` once `attachIfNeeded`
        /// successfully parents it.
        fileprivate weak var pendingHost: UIHostingController<AnyView>?
        /// Weak reference back to the proxy so this container can fire
        /// the cold-start `onFirstLayoutReady` callback from
        /// `layoutSubviews()` as soon as the scroll view has both real
        /// bounds AND a real contentSize. Bug 2 fix: replaces the
        /// `.task`-based polling that raced cold-start layout when
        /// `viewportHeight` (only populated by `scrollViewDidScroll`)
        /// was still 0.
        fileprivate weak var proxy: TimelineScrollProxy?

        override init(frame: CGRect) {
            super.init(frame: frame)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            // Spec 07 §5 S5.10: with the imperative day-layer host sitting as
            // a UIScrollView SIBLING (S5.9a) and selective hit-test allowing
            // event taps to land on it (S5.10 main commit), UIScrollView's
            // default 150ms `delaysContentTouches` makes every tap on an
            // event feel like it's racing the scroll. Disable that delay so
            // taps on event blocks reach the host immediately. Vertical
            // scroll still works: UIScrollView's pan recognizer can still
            // take ownership of an in-flight touch when the user starts
            // moving (canCancelContentTouches stays default = true).
            scrollView.delaysContentTouches = false
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

        override func layoutSubviews() {
            super.layoutSubviews()
            // Fire the cold-start one-shot once the scroll view's
            // bounds and contentSize are BOTH real. `contentSize` is
            // derived from the content-layout-guide pin to the
            // hosting view's height constraint; after the first layout
            // pass it equals the constraint constant. `bounds` reflects
            // our own frame, which is set by SwiftUI after the first
            // layout pass.
            proxy?.fireFirstLayoutReadyIfNeeded()
        }

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
