//
//  EventBlock.swift
//  Done
//
//  Unified event block component for timeline display.
//

import SwiftUI
import UIKit

// Extracted for regression tests: computes edge auto-scroll velocity for one axis.
func calendarAutoScrollVelocity(
    locationInViewport: CGFloat,
    viewportLength: CGFloat,
    currentOffset: CGFloat,
    minOffset: CGFloat,
    maxOffset: CGFloat,
    edgeInset: CGFloat,
    maxSpeed: CGFloat
) -> CGFloat {
    guard maxOffset - minOffset > 1 else { return 0 }
    guard viewportLength > 0 else { return 0 }

    let effectiveInset = min(max(edgeInset, 0), viewportLength * 0.48)
    guard effectiveInset > 0 else { return 0 }

    var velocity: CGFloat = 0
    if locationInViewport < effectiveInset {
        let progress = min(1, max(0, (effectiveInset - locationInViewport) / effectiveInset))
        velocity = -maxSpeed * progress * progress
    } else if locationInViewport > viewportLength - effectiveInset {
        let progress = min(1, max(0, (locationInViewport - (viewportLength - effectiveInset)) / effectiveInset))
        velocity = maxSpeed * progress * progress
    }

    let atMin = currentOffset <= minOffset + 0.5
    let atMax = currentOffset >= maxOffset - 0.5
    if (atMin && velocity < 0) || (atMax && velocity > 0) {
        return 0
    }

    return velocity
}

// Extracted for regression tests: quantize continuous auto-scroll delta into unit steps.
func calendarQuantizedStepDelta(
    proposedDelta: CGFloat,
    unitStep: CGFloat,
    carryIn: CGFloat
) -> (applied: CGFloat, carryOut: CGFloat) {
    guard unitStep > 1 else {
        return (proposedDelta, 0)
    }

    var carry = carryIn + proposedDelta
    guard abs(carry) >= unitStep else {
        return (0, carry)
    }

    let direction: CGFloat = carry > 0 ? 1 : -1
    let steps = floor(abs(carry) / unitStep)
    let applied = direction * steps * unitStep
    carry -= applied
    return (applied, carry)
}

/// Event block style configuration
struct EventBlockStyle {
    let fillOpacity: Double
    let strokeOpacity: Double
    let strokeWidth: CGFloat
    let showTimeRange: Bool

    static let edit = EventBlockStyle(
        fillOpacity: 0.2,
        strokeOpacity: 0.8,
        strokeWidth: 1.2,
        showTimeRange: true
    )

    static let preview = EventBlockStyle(
        fillOpacity: 0.25,
        strokeOpacity: 0.4,
        strokeWidth: 1,
        showTimeRange: false
    )
}

/// Drag offset containing both X and Y components.
struct DragOffset: Equatable {
    var x: CGFloat
    var y: CGFloat

    static let zero = DragOffset(x: 0, y: 0)
}

/// Type of drag operation on event block
enum EventDragMode: Equatable {
    case move       // Drag from middle - move entire event
    case resizeTop  // Drag from top edge - adjust start time
    case resizeBottom // Drag from bottom edge - adjust end time
}

/// UIView subclass that extends its touch area vertically for edge resize detection.
class ExtendedHitAreaView: UIView {
    var verticalExtension: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -verticalExtension).contains(point)
    }
}

/// UIKit-based long press drag gesture for event blocks.
/// Detects drag position to determine move vs resize operations.
struct EventBlockDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.3
    var edgeThreshold: CGFloat = 10 // Points from inside edge to trigger resize
    var outerEdgeThreshold: CGFloat = 0 // Points outside event block to trigger resize
    var snapSize: CGFloat = 14 // Points per 15-minute snap interval
    var horizontalAutoScrollEdgeInset: CGFloat = 72
    var verticalAutoScrollEdgeInset: CGFloat = 144
    var maxAutoScrollSpeed: CGFloat = 620 // pt/s
    var horizontalAutoScrollUnitStep: CGFloat = 0
    var canResizeTop: Bool = true
    var canResizeBottom: Bool = true
    var onDragBegan: ((EventDragMode) -> Void)?
    var onDragChanged: ((DragOffset) -> Void)?
    var onDragEnded: ((EventDragMode, DragOffset) -> Void)?
    @Binding var isDragging: Bool
    @Binding var dragOffset: DragOffset
    @Binding var dragMode: EventDragMode

    func makeUIView(context: Context) -> ExtendedHitAreaView {
        let view = ExtendedHitAreaView()
        view.backgroundColor = .clear
        view.verticalExtension = outerEdgeThreshold

        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = minimumPressDuration
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)

        return view
    }

    func updateUIView(_ uiView: ExtendedHitAreaView, context: Context) {
        uiView.verticalExtension = outerEdgeThreshold
        // CRITICAL: Update parent reference so bindings work correctly
        context.coordinator.parent = self
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.edgeThreshold = edgeThreshold
        context.coordinator.snapSize = snapSize
        context.coordinator.horizontalAutoScrollEdgeInset = horizontalAutoScrollEdgeInset
        context.coordinator.verticalAutoScrollEdgeInset = verticalAutoScrollEdgeInset
        context.coordinator.maxAutoScrollSpeed = maxAutoScrollSpeed
        context.coordinator.horizontalAutoScrollUnitStep = horizontalAutoScrollUnitStep
        context.coordinator.canResizeTop = canResizeTop
        context.coordinator.canResizeBottom = canResizeBottom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: EventBlockDragGesture
        var onDragBegan: ((EventDragMode) -> Void)?
        var onDragChanged: ((DragOffset) -> Void)?
        var onDragEnded: ((EventDragMode, DragOffset) -> Void)?
        var edgeThreshold: CGFloat = 20
        var snapSize: CGFloat = 14
        var horizontalAutoScrollEdgeInset: CGFloat = 72
        var verticalAutoScrollEdgeInset: CGFloat = 144
        var maxAutoScrollSpeed: CGFloat = 620
        var horizontalAutoScrollUnitStep: CGFloat = 0
        var canResizeTop: Bool = true
        var canResizeBottom: Bool = true
        private var initialPointInWindow: CGPoint = .zero
        private var lastLocationInWindow: CGPoint = .zero
        private var initialScrollOffsetX: CGFloat = 0
        private var initialScrollOffsetY: CGFloat = 0
        private weak var horizontalScrollView: UIScrollView?
        private weak var verticalScrollView: UIScrollView?
        private weak var activeGesture: UILongPressGestureRecognizer?
        private var autoScrollVelocityX: CGFloat = 0
        private var autoScrollVelocityY: CGFloat = 0
        private var autoScrollDisplayLink: CADisplayLink?
        private var horizontalAutoScrollCarry: CGFloat = 0
        private var hasMovedAfterLongPress: Bool = false
        private var currentMode: EventDragMode = .move
        private var lastSnappedStep: Int = 0
        private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        private let horizontalStepAnimationDuration: TimeInterval = 0.16

        init(_ parent: EventBlockDragGesture) {
            self.parent = parent
            self.onDragBegan = parent.onDragBegan
            self.onDragChanged = parent.onDragChanged
            self.onDragEnded = parent.onDragEnded
            self.edgeThreshold = parent.edgeThreshold
            self.snapSize = parent.snapSize
            self.horizontalAutoScrollEdgeInset = parent.horizontalAutoScrollEdgeInset
            self.verticalAutoScrollEdgeInset = parent.verticalAutoScrollEdgeInset
            self.maxAutoScrollSpeed = parent.maxAutoScrollSpeed
            self.horizontalAutoScrollUnitStep = parent.horizontalAutoScrollUnitStep
            self.canResizeTop = parent.canResizeTop
            self.canResizeBottom = parent.canResizeBottom
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let viewHeight = view.bounds.height

            switch gesture.state {
            case .began:
                initialPointInWindow = gesture.location(in: nil)
                lastLocationInWindow = initialPointInWindow
                activeGesture = gesture
                let scrollTargets = findScrollTargets(startingAt: view)
                horizontalScrollView = scrollTargets.horizontal
                verticalScrollView = scrollTargets.vertical
                initialScrollOffsetX = horizontalScrollView?.contentOffset.x ?? 0
                initialScrollOffsetY = verticalScrollView?.contentOffset.y ?? 0
                autoScrollVelocityX = 0
                autoScrollVelocityY = 0
                horizontalAutoScrollCarry = 0
                hasMovedAfterLongPress = false
                lastSnappedStep = 0
                // Determine drag mode based on touch position
                if location.y < edgeThreshold && canResizeTop {
                    currentMode = .resizeTop
                } else if location.y > viewHeight - edgeThreshold && canResizeBottom {
                    currentMode = .resizeBottom
                } else {
                    currentMode = .move
                }
                parent.isDragging = true
                parent.dragOffset = .zero
                parent.dragMode = currentMode
                // Haptic on long press recognized
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDragBegan?(currentMode)

            case .changed:
                updateDragOffset(using: gesture)
                let rawLocationInWindow = gesture.location(in: nil)
                let rawDeltaX = rawLocationInWindow.x - initialPointInWindow.x
                let rawDeltaY = rawLocationInWindow.y - initialPointInWindow.y
                if !hasMovedAfterLongPress {
                    hasMovedAfterLongPress = hypot(rawDeltaX, rawDeltaY) > 2
                }
                if hasMovedAfterLongPress {
                    updateAutoScrollVelocity()
                } else {
                    stopAutoScroll()
                }

            case .ended, .cancelled, .failed:
                let finalOffset = parent.dragOffset
                let mode = currentMode
                stopAutoScroll()
                activeGesture = nil
                horizontalScrollView = nil
                verticalScrollView = nil
                hasMovedAfterLongPress = false
                parent.isDragging = false
                parent.dragOffset = .zero
                onDragEnded?(mode, finalOffset)

            default:
                break
            }
        }

        deinit {
            stopAutoScroll()
        }

        // Keep drag offset stable in window coordinates, then add scroll compensation
        // so auto-scrolling still advances the dragged time while finger stays near edge.
        private func updateDragOffset(using gesture: UILongPressGestureRecognizer) {
            let locationInWindow = gesture.location(in: nil)
            lastLocationInWindow = locationInWindow

            let scrollCompensationX = (horizontalScrollView?.contentOffset.x ?? initialScrollOffsetX) - initialScrollOffsetX
            let scrollCompensationY = (verticalScrollView?.contentOffset.y ?? initialScrollOffsetY) - initialScrollOffsetY
            let offset = DragOffset(
                x: locationInWindow.x - initialPointInWindow.x + scrollCompensationX,
                y: locationInWindow.y - initialPointInWindow.y + scrollCompensationY
            )
            applyDragOffset(offset)
        }

        private func applyDragOffset(_ offset: DragOffset) {
            // Haptic on each 15-minute snap boundary crossed
            if snapSize > 0 {
                let currentStep = Int((offset.y / snapSize).rounded())
                if currentStep != lastSnappedStep {
                    lastSnappedStep = currentStep
                    impactFeedback.impactOccurred()
                }
            }

            guard parent.dragOffset != offset else { return }
            parent.dragOffset = offset
            onDragChanged?(offset)
        }

        private enum ScrollAxis {
            case horizontal
            case vertical
        }

        private func updateAutoScrollVelocity() {
            guard hasMovedAfterLongPress else {
                stopAutoScroll()
                return
            }

            autoScrollVelocityX = currentMode == .move
                ? autoScrollVelocity(for: horizontalScrollView, axis: .horizontal)
                : 0
            autoScrollVelocityY = autoScrollVelocity(for: verticalScrollView, axis: .vertical)

            if autoScrollVelocityX == 0 && autoScrollVelocityY == 0 {
                stopAutoScroll()
            } else {
                startAutoScroll()
            }
        }

        private func startAutoScroll() {
            guard autoScrollDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollDisplayLink = link
        }

        private func stopAutoScroll() {
            autoScrollDisplayLink?.invalidate()
            autoScrollDisplayLink = nil
            autoScrollVelocityX = 0
            autoScrollVelocityY = 0
            horizontalAutoScrollCarry = 0
        }

        @objc private func handleAutoScrollTick(_ displayLink: CADisplayLink) {
            guard autoScrollVelocityX != 0 || autoScrollVelocityY != 0 else {
                stopAutoScroll()
                return
            }

            let dt = max(displayLink.targetTimestamp - displayLink.timestamp, 0)
            let proposedDeltaX = autoScrollVelocityX * CGFloat(dt)
            let horizontalStep = horizontalAutoScrollStep()
            let deltaX: CGFloat
            if autoScrollVelocityX == 0 {
                horizontalAutoScrollCarry = 0
                deltaX = 0
            } else {
                let quantized = calendarQuantizedStepDelta(
                    proposedDelta: proposedDeltaX,
                    unitStep: horizontalStep,
                    carryIn: horizontalAutoScrollCarry
                )
                deltaX = quantized.applied
                horizontalAutoScrollCarry = quantized.carryOut
            }
            let delta = CGPoint(
                x: deltaX,
                y: autoScrollVelocityY * CGFloat(dt)
            )
            let shouldAnimateHorizontalStep = abs(deltaX) > .ulpOfOne && horizontalStep > 1

            if let sharedScrollView = horizontalScrollView, sharedScrollView === verticalScrollView {
                _ = applyAutoScroll(
                    on: sharedScrollView,
                    delta: delta,
                    animateHorizontalStep: shouldAnimateHorizontalStep
                )
            } else {
                if let scrollView = horizontalScrollView {
                    _ = applyAutoScroll(
                        on: scrollView,
                        delta: CGPoint(x: delta.x, y: 0),
                        animateHorizontalStep: shouldAnimateHorizontalStep
                    )
                }
                if let scrollView = verticalScrollView {
                    _ = applyAutoScroll(on: scrollView, delta: CGPoint(x: 0, y: delta.y))
                }
            }

            if let gesture = activeGesture {
                updateDragOffset(using: gesture)
            }
            updateAutoScrollVelocity()
        }

        private func horizontalAutoScrollStep() -> CGFloat {
            if horizontalAutoScrollUnitStep > 1 {
                return horizontalAutoScrollUnitStep
            }
            guard let horizontalScrollView else { return 0 }
            return horizontalScrollView.bounds.width
        }

        private func autoScrollVelocity(for scrollView: UIScrollView?, axis: ScrollAxis) -> CGFloat {
            guard let scrollView else { return 0 }

            let minOffset: CGFloat
            let maxOffset: CGFloat
            let boundsSize: CGFloat
            let pointerLocationInViewport: CGFloat
            let edgeInset: CGFloat

            switch axis {
            case .horizontal:
                minOffset = -scrollView.adjustedContentInset.left
                maxOffset = max(minOffset, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
                boundsSize = scrollView.bounds.width
                pointerLocationInViewport = locationInViewport(for: scrollView, axis: .horizontal)
                edgeInset = horizontalAutoScrollEdgeInset
            case .vertical:
                minOffset = -scrollView.adjustedContentInset.top
                maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                boundsSize = scrollView.bounds.height
                pointerLocationInViewport = locationInViewport(for: scrollView, axis: .vertical)
                edgeInset = verticalAutoScrollEdgeInset
            }

            let currentOffset: CGFloat = axis == .horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
            return calendarAutoScrollVelocity(
                locationInViewport: pointerLocationInViewport,
                viewportLength: boundsSize,
                currentOffset: currentOffset,
                minOffset: minOffset,
                maxOffset: maxOffset,
                edgeInset: edgeInset,
                maxSpeed: maxAutoScrollSpeed
            )
        }

        private func locationInViewport(for scrollView: UIScrollView, axis: ScrollAxis) -> CGFloat {
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            switch axis {
            case .horizontal:
                return lastLocationInWindow.x - frameInWindow.minX
            case .vertical:
                return lastLocationInWindow.y - frameInWindow.minY
            }
        }

        private func applyAutoScroll(
            on scrollView: UIScrollView,
            delta: CGPoint,
            animateHorizontalStep: Bool = false
        ) -> Bool {
            let minOffsetX = -scrollView.adjustedContentInset.left
            let maxOffsetX = max(minOffsetX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)

            let currentOffset = scrollView.contentOffset
            let proposedX = scrollView.contentOffset.x + delta.x
            let proposedY = scrollView.contentOffset.y + delta.y
            let clampedX = min(max(proposedX, minOffsetX), maxOffsetX)
            let clampedY = min(max(proposedY, minOffsetY), maxOffsetY)

            let xChanged = abs(clampedX - currentOffset.x) > .ulpOfOne
            let yChanged = abs(clampedY - currentOffset.y) > .ulpOfOne
            guard xChanged || yChanged else {
                return false
            }

            let targetOffset = CGPoint(x: clampedX, y: clampedY)
            if animateHorizontalStep && xChanged {
                if yChanged {
                    scrollView.setContentOffset(
                        CGPoint(x: currentOffset.x, y: clampedY),
                        animated: false
                    )
                }
                UIView.animate(
                    withDuration: horizontalStepAnimationDuration,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
                ) {
                    scrollView.contentOffset = targetOffset
                }
                return true
            }

            scrollView.setContentOffset(targetOffset, animated: false)
            return true
        }

        private func findScrollTargets(startingAt view: UIView) -> (horizontal: UIScrollView?, vertical: UIScrollView?) {
            var current: UIView? = view.superview
            var bestHorizontal: UIScrollView?
            var bestVertical: UIScrollView?

            while let candidate = current {
                if let scrollView = candidate as? UIScrollView, scrollView.isScrollEnabled {
                    let horizontalRange = scrollView.contentSize.width - scrollView.bounds.width
                    if bestHorizontal == nil && horizontalRange > 1 {
                        bestHorizontal = scrollView
                    }

                    let verticalRange = scrollView.contentSize.height - scrollView.bounds.height
                    if bestVertical == nil && verticalRange > 1 {
                        bestVertical = scrollView
                    }

                    if bestHorizontal != nil && bestVertical != nil {
                        break
                    }
                }
                current = candidate.superview
            }

            return (bestHorizontal, bestVertical)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

/// Renders an event block in the timeline grid.
struct EventBlock: View {
    let event: Event
    var occurrenceID: String? = nil
    var dragSourceRange: Event.TimeRange? = nil
    let displayRange: Event.TimeRange?
    let color: Color
    let showText: Bool
    let style: EventBlockStyle
    var hourHeight: CGFloat = 56
    var dayColumnStep: CGFloat = 0
    var onTap: (() -> Void)? = nil
    var onDragEnded: ((DragOffset) -> Void)? = nil
    var onResizeTopEnded: ((CGFloat) -> Void)? = nil    // Y offset for top edge
    var onResizeBottomEnded: ((CGFloat) -> Void)? = nil // Y offset for bottom edge
    var canResizeTop: Bool = true
    var canResizeBottom: Bool = true
    var isTimerActive: Bool = false

    // External drag state for cross-day sync (when another occurrence of this event is being dragged)
    @ObservedObject var dragState: EventDragState

    @State private var isDragging = false
    @State private var dragOffset: DragOffset = .zero
    @State private var dragMode: EventDragMode = .move

    /// Whether this block should follow external drag (same event being dragged elsewhere)
    private var isFollowingExternalDrag: Bool {
        !isDragging
            && dragState.draggingEventID == event.id
            && isActiveDraggedOccurrence(
                occurrenceID: occurrenceID,
                draggingOccurrenceID: dragState.draggingOccurrenceID,
                dragMode: dragState.dragMode
            )
    }

    /// Effective offset to apply (either local drag or external sync)
    private var effectiveDragOffset: DragOffset {
        if isDragging {
            return dragOffset
        } else if isFollowingExternalDrag {
            return dragState.dragOffset
        }
        return .zero
    }

    /// Whether block is visually in drag state (either local or synced)
    private var isInDragState: Bool {
        isDragging || isFollowingExternalDrag
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isDragEnabled: Bool {
        onDragEnded != nil || onResizeTopEnded != nil || onResizeBottomEnded != nil
    }

    /// 15-minute snap size in points
    private var snapSize: CGFloat { hourHeight / 4 }

    /// Drag offset snapped to 15-minute increments (only for resize modes)
    private var snappedResizeOffset: CGFloat {
        guard isDragging, dragMode != .move else { return 0 }
        return (dragOffset.y / snapSize).rounded() * snapSize
    }

    /// Adjusted height during resize drag
    private func resizeHeight(baseHeight: CGFloat) -> CGFloat {
        guard isDragging, dragMode != .move else { return baseHeight }
        let minHeight = hourHeight / 2
        switch dragMode {
        case .resizeTop:
            return max(minHeight, baseHeight - snappedResizeOffset)
        case .resizeBottom:
            return max(minHeight, baseHeight + snappedResizeOffset)
        case .move:
            return baseHeight
        }
    }

    /// Drag Y offset snapped to 15-minute increments for move mode
    private var snappedMoveOffsetY: CGFloat {
        let offset = effectiveDragOffset
        let mode = isDragging ? dragMode : dragState.dragMode
        guard isInDragState, mode == .move else { return 0 }
        return (offset.y / snapSize).rounded() * snapSize
    }

    /// Drag X offset snapped to day-column boundaries (0 = no snap)
    private var snappedMoveOffsetX: CGFloat {
        let offset = effectiveDragOffset
        let mode = isDragging ? dragMode : dragState.dragMode
        guard isInDragState, mode == .move else { return offset.x }
        guard dayColumnStep > 0 else { return 0 }
        return (offset.x / dayColumnStep).rounded() * dayColumnStep
    }

    /// Display range adjusted by the current drag offset
    private var adjustedDisplayRange: Event.TimeRange? {
        guard let range = displayRange else { return nil }
        guard isInDragState else { return range }
        let mode = isDragging ? dragMode : dragState.dragMode
        switch mode {
        case .move:
            // Show the full (unclipped) preview range so cross-day segments
            // display e.g. "23:00 - 01:00" instead of "00:00 - 01:00"
            return dragState.previewRange(hourHeight: hourHeight) ?? range
        case .resizeTop:
            let offsetSeconds = TimeInterval(snappedResizeOffset / hourHeight * 3600)
            let newStart = range.start.addingTimeInterval(offsetSeconds)
            return newStart < range.end ? Event.TimeRange(start: newStart, end: range.end) : range
        case .resizeBottom:
            let offsetSeconds = TimeInterval(snappedResizeOffset / hourHeight * 3600)
            let newEnd = range.end.addingTimeInterval(offsetSeconds)
            return newEnd > range.start ? Event.TimeRange(start: range.start, end: newEnd) : range
        }
    }

    /// Y offset for the block during resizeTop drag
    private func resizeYOffset(baseHeight: CGFloat) -> CGFloat {
        guard isDragging, dragMode == .resizeTop else { return 0 }
        let minHeight = hourHeight / 2
        // Clamp so block doesn't shrink below minimum
        return min(snappedResizeOffset, baseHeight - minHeight)
    }

    var body: some View {
        GeometryReader { geo in
            let baseHeight = geo.size.height
            let handleWidth = min(geo.size.width * 0.4, 36)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(style.fillOpacity))
                )
                .overlay {
                    if isTimerActive {
                        DiagonalHatchingPattern(spacing: 6, lineWidth: 1)
                            .stroke(color.opacity(0.3), lineWidth: 1)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(style.strokeOpacity), lineWidth: style.strokeWidth)
                )
                .overlay {
                    if isDragEnabled {
                        VStack {
                            if canResizeTop {
                                Capsule()
                                    .fill(color.opacity(0.45))
                                    .frame(width: handleWidth, height: 3)
                                    .padding(.top, 5)
                            }
                            Spacer()
                            if canResizeBottom {
                                Capsule()
                                    .fill(color.opacity(0.45))
                                    .frame(width: handleWidth, height: 3)
                                    .padding(.bottom, 5)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: resizeHeight(baseHeight: baseHeight)
                )
                .scaleEffect(isInDragState && (isDragging ? dragMode : dragState.dragMode) == .move ? 1.05 : 1.0)
                .shadow(radius: isInDragState ? 8 : 0)
                // X offset for cross-day column snapping, Y offset only for resize (move Y is handled by TimelineDayView's adjustedRange)
                .offset(x: (isDragging ? dragMode : dragState.dragMode) == .move ? snappedMoveOffsetX : 0,
                        y: isDragging && dragMode != .move ? resizeYOffset(baseHeight: baseHeight) : 0)
                .contentShape(Rectangle())
                .overlay {
                    if isDragEnabled {
                        EventBlockDragGesture(
                            snapSize: snapSize,
                            horizontalAutoScrollUnitStep: dayColumnStep,
                            canResizeTop: canResizeTop,
                            canResizeBottom: canResizeBottom,
                            onDragEnded: { mode, offset in
                                switch mode {
                                case .move:
                                    onDragEnded?(offset)
                                case .resizeTop:
                                    onResizeTopEnded?(offset.y)
                                case .resizeBottom:
                                    onResizeBottomEnded?(offset.y)
                                }
                            },
                            isDragging: $isDragging,
                            dragOffset: $dragOffset,
                            dragMode: $dragMode
                        )
                    }
                }
                .onTapGesture { onTap?() }
                .animation(.easeInOut(duration: 0.15), value: isInDragState)
                .onChange(of: isDragging) { newValue in
                    if newValue {
                        dragState.draggingEventID = event.id
                        dragState.draggingOccurrenceID = occurrenceID
                        dragState.draggingEvent = event
                        // Use the specific occurrence's full range when available.
                        // This keeps multi-range events from switching to another range.
                        dragState.draggingOriginalRange = dragSourceRange ?? event.primaryTimeRange
                        dragState.dragOffset = dragOffset
                        dragState.dragMode = dragMode
                    } else {
                        dragState.draggingEventID = nil
                        dragState.draggingOccurrenceID = nil
                        dragState.draggingEvent = nil
                        dragState.draggingOriginalRange = nil
                        dragState.dragOffset = .zero
                        dragState.dragMode = .move
                    }
                }
                .onChange(of: dragOffset) { newValue in
                    if isDragging {
                        dragState.dragOffset = newValue
                    }
                }
                .onChange(of: dragMode) { newValue in
                    if isDragging {
                        dragState.dragMode = newValue
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if showText {
            ViewThatFits(in: .vertical) {
                // Full content: title + time range
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if style.showTimeRange, let range = adjustedDisplayRange {
                        Text("\(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)

                // Title only
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(8)

                // Nothing - block too small
                Color.clear
            }
        } else {
            Color.clear
        }
    }
}
