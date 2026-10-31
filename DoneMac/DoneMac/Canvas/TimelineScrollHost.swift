//
//  TimelineScrollHost.swift
//  DoneMac
//
//  B4: the vertical timeline scrolls inside an AppKit NSScrollView, not a
//  SwiftUI ScrollView — so the offset is PROGRAMMABLE. That unlocks focal
//  zoom anchoring (B1) and edge-autoscroll during a drag (B3), neither of
//  which SwiftUI's ScrollView exposes.
//
//  Left-click-drag never scrolls an NSScrollView (scrolling is wheel /
//  two-finger / scroller), so the block move/resize/create DragGestures
//  hosted inside still receive their events unchanged — the reason this swap
//  is low-risk for gestures. A flipped document view keeps y=0 at the top so
//  the fraction math reads top-down like the rest of the canvas.
//

import SwiftUI

/// Commands + reads the timeline's vertical scroll. Held by the canvas as
/// @State; B1/B3 drive it. The offset math (`scrollTargetY`) is a pure,
/// tested function so the AppKit plumbing carries no arithmetic of its own.
@MainActor
final class TimelineScrollController {
    fileprivate weak var scrollView: NSScrollView?

    /// Scroll so `fraction` (0…1 of content height) sits at the viewport
    /// CENTER, clamped to the scrollable range.
    func centerOnFraction(_ fraction: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds.height
        let y = Self.scrollTargetY(fraction: fraction,
                                   contentHeight: document.bounds.height,
                                   visibleHeight: visible)
        scrollTo(y)
    }

    /// Current top-edge offset and the visible height, for anchoring math.
    var verticalOffset: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }
    var visibleHeight: CGFloat { scrollView?.contentView.bounds.height ?? 0 }

    /// The content fraction currently at the viewport CENTER — the focal time
    /// a zoom should hold fixed (B1). 0 when unsized.
    var centerFraction: CGFloat {
        guard let document = scrollView?.documentView, document.bounds.height > 0 else { return 0 }
        return (verticalOffset + visibleHeight / 2) / document.bounds.height
    }

    /// Set by a zoom just before it changes the content height; the host
    /// re-centers on it AFTER the new height lays out, so the focal time stays
    /// put instead of the view jumping (B1).
    var pendingRecenterFraction: CGFloat?

    private func scrollTo(_ y: CGFloat) {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Where to put the top edge so `fraction` of the content is centered.
    /// Clamped to [0, contentHeight − visibleHeight]; 0 when everything fits.
    static func scrollTargetY(fraction: CGFloat, contentHeight: CGFloat,
                              visibleHeight: CGFloat) -> CGFloat {
        guard contentHeight > visibleHeight else { return 0 }
        let raw = fraction * contentHeight - visibleHeight / 2
        return min(max(0, raw), contentHeight - visibleHeight)
    }
}

/// A flipped NSScrollView subclass that fires `onFirstValidLayout` once, when
/// it first has a real size — the reliable moment to apply the initial
/// scroll-to-now (an .onAppear can run before AppKit has laid out).
final class TimelineScrollView: NSScrollView {
    var onFirstValidLayout: (() -> Void)?
    private var firedInitialLayout = false

    override func layout() {
        super.layout()
        if !firedInitialLayout, contentView.bounds.height > 0 {
            firedInitialLayout = true
            onFirstValidLayout?()
        }
    }
}

/// A flipped document container (NSView.isFlipped IS overridable, unlike
/// NSHostingView's) so scroll y grows downward and the fraction math reads
/// top-down. The SwiftUI content is hosted as its pinned subview.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

struct VerticalScrollHost<Content: View>: NSViewRepresentable {
    let controller: TimelineScrollController
    let contentHeight: CGFloat
    /// Applied once, when the scroll view first has a real size.
    let initialFraction: CGFloat
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> TimelineScrollView {
        let scroll = TimelineScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed

        let document = FlippedDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Carry no intrinsic size of its own — the edge pins fully determine
        // the frame, so the hosting view can't emit conflicting constraints
        // (B4 review #3 hardening).
        hosting.sizingOptions = []
        document.addSubview(hosting)
        scroll.documentView = document

        let heightConstraint = document.heightAnchor.constraint(equalToConstant: contentHeight)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            heightConstraint,
            hosting.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: document.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        context.coordinator.heightConstraint = heightConstraint
        context.coordinator.hosting = hosting

        controller.scrollView = scroll
        let fraction = initialFraction
        let controller = controller
        // The scroll view's first real size can arrive before the document's
        // constraints are solved: the document still reads height 0, the
        // target clamps to 0, and the window opens at midnight instead of on
        // the now-line (装机清单 ①, seen again 2026-10-24). Scroll on the next
        // turn, after laying the document out at its real height.
        scroll.onFirstValidLayout = { [weak scroll] in
            DispatchQueue.main.async {
                scroll?.layoutSubtreeIfNeeded()
                controller.centerOnFraction(fraction)
            }
        }
        return scroll
    }

    func updateNSView(_ scrollView: TimelineScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content
        if context.coordinator.heightConstraint?.constant != contentHeight {
            context.coordinator.heightConstraint?.constant = contentHeight
            // A zoom changed the content height: lay out at the NEW height,
            // then re-center on the focal time it captured — so the time under
            // the viewport center stays put instead of the view jumping (B1).
            if let fraction = controller.pendingRecenterFraction {
                scrollView.layoutSubtreeIfNeeded()
                controller.centerOnFraction(fraction)
                controller.pendingRecenterFraction = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var heightConstraint: NSLayoutConstraint?
        var hosting: NSHostingView<Content>?
    }
}
