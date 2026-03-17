//
//  EventBlock.swift
//  Done
//
//  Unified event block component for timeline display.
//

import SwiftUI
import UIKit

private let resizeMinHeight: CGFloat = 32

let calendarHorizontalAutoScrollEdgeInsetDefault: CGFloat = 64
let calendarVerticalAutoScrollEdgeInsetDefault: CGFloat = 168
let calendarMaxAutoScrollSpeedDefault: CGFloat = 1200
let calendarAutoScrollCurveExponent: CGFloat = 1.5

/// Determines the drag mode based on touch position within an event block.
/// Resize only triggers when touching near the handle capsule (vertically AND horizontally).
func calendarResolveDragMode(
    locationX: CGFloat,
    locationY: CGFloat,
    viewWidth: CGFloat,
    viewHeight: CGFloat,
    edgeThreshold: CGFloat,
    canResizeTop: Bool,
    canResizeBottom: Bool
) -> EventDragMode {
    // Block too small for resize — move only
    guard viewHeight >= resizeMinHeight else { return .move }

    let scaledThreshold = min(edgeThreshold, max(8, viewHeight * 0.2))
    let inTopEdge = locationY < scaledThreshold && canResizeTop
    let inBottomEdge = locationY > viewHeight - scaledThreshold && canResizeBottom
    guard inTopEdge || inBottomEdge else { return .move }

    // Handle capsule: centered, width = min(viewWidth * 0.4, 36).
    // Expand hit zone by 12pt on each side for comfortable tapping.
    let handleWidth = min(viewWidth * 0.4, 36)
    let handleMargin: CGFloat = 12
    let centerX = viewWidth / 2
    let hitLeft = centerX - handleWidth / 2 - handleMargin
    let hitRight = centerX + handleWidth / 2 + handleMargin
    guard locationX >= hitLeft && locationX <= hitRight else { return .move }

    return inTopEdge ? .resizeTop : .resizeBottom
}

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
        let scaledProgress = CGFloat(pow(Double(progress), Double(calendarAutoScrollCurveExponent)))
        velocity = -maxSpeed * scaledProgress
    } else if locationInViewport > viewportLength - effectiveInset {
        let progress = min(1, max(0, (locationInViewport - (viewportLength - effectiveInset)) / effectiveInset))
        let scaledProgress = CGFloat(pow(Double(progress), Double(calendarAutoScrollCurveExponent)))
        velocity = maxSpeed * scaledProgress
    }

    let atMin = currentOffset <= minOffset + 0.5
    let atMax = currentOffset >= maxOffset - 0.5
    if (atMin && velocity < 0) || (atMax && velocity > 0) {
        return 0
    }

    return velocity
}

// Extracted for regression tests: continuous horizontal auto-scroll delta.
func calendarHorizontalAutoScrollDelta(
    velocityX: CGFloat,
    deltaTime: CFTimeInterval
) -> CGFloat {
    velocityX * CGFloat(max(deltaTime, 0))
}

// Extracted for regression tests: drag X/Y should compose finger delta with
// explicit auto-scroll compensation only (never implicit scroll offset jumps).
func calendarComposedDragOffset(
    fingerDelta: DragOffset,
    autoScrollCompensation: DragOffset
) -> DragOffset {
    DragOffset(
        x: fingerDelta.x + autoScrollCompensation.x,
        y: fingerDelta.y + autoScrollCompensation.y
    )
}

// Extracted for regression tests: snap X move offset by column unless snap is suppressed
// (e.g. during horizontal edge-zone or auto-scroll drag).
func calendarMoveOffsetX(
    rawOffsetX: CGFloat,
    dayColumnStep: CGFloat,
    suppressSnap: Bool
) -> CGFloat {
    if suppressSnap {
        return rawOffsetX
    }
    guard dayColumnStep > 0 else { return 0 }
    return (rawOffsetX / dayColumnStep).rounded() * dayColumnStep
}

// Extracted for regression tests: edge-zone detection for auto-scroll.
func calendarIsInAutoScrollEdgeZone(
    locationInViewport: CGFloat,
    viewportLength: CGFloat,
    edgeInset: CGFloat
) -> Bool {
    guard viewportLength > 0 else { return false }
    let effectiveInset = min(max(edgeInset, 0), viewportLength * 0.48)
    guard effectiveInset > 0 else { return false }
    return locationInViewport < effectiveInset || locationInViewport > viewportLength - effectiveInset
}

// Extracted for regression tests: resolve drag offset at gesture source so X snap
// does not depend on delayed SwiftUI state propagation.
func calendarResolvedDragOffset(
    rawOffset: DragOffset,
    dragMode: EventDragMode,
    dayColumnStep: CGFloat,
    suppressHorizontalSnap: Bool
) -> DragOffset {
    guard dragMode == .move else {
        return DragOffset(x: 0, y: rawOffset.y)
    }

    let resolvedX = calendarMoveOffsetX(
        rawOffsetX: rawOffset.x,
        dayColumnStep: dayColumnStep,
        suppressSnap: suppressHorizontalSnap
    )
    return DragOffset(x: resolvedX, y: rawOffset.y)
}

/// Event block style configuration
struct EventBlockStyle: Equatable {
    let showTimeRange: Bool

    var fillOpacity: Double { 0.4 }
    var strokeOpacity: Double { 0.7 }
    var strokeWidth: CGFloat { 1.2 }

    static let edit = EventBlockStyle(showTimeRange: true)
    static let preview = EventBlockStyle(showTimeRange: false)
}

enum EventBlockInterruptVisualMode: Equatable {
    case none
    case embeddedMoat
    case weakRelation
}

func calendarInterruptVisualMode(
    isInterruptEvent: Bool,
    relationState: EventInterruptRelationState?,
    isCurrentlyEmbedded: Bool,
    hasParentColor: Bool
) -> EventBlockInterruptVisualMode {
    guard isInterruptEvent else { return .none }
    if isCurrentlyEmbedded && hasParentColor {
        return .embeddedMoat
    }
    switch relationState {
    case .embedded, .detached, .orphaned:
        return .weakRelation
    case nil:
        return .none
    }
}

func calendarInterruptMoatWidth(
    availableWidth: CGFloat,
    availableHeight: CGFloat
) -> CGFloat {
    availableWidth < 48 || availableHeight < 26 ? 2 : 3
}

struct CalendarInterruptOverlayGeometry: Equatable {
    let width: CGFloat
    let xOffset: CGFloat
}

func calendarInterruptOverlayGeometry(parentWidth: CGFloat) -> CalendarInterruptOverlayGeometry {
    guard parentWidth > 0 else {
        return CalendarInterruptOverlayGeometry(width: 0, xOffset: 0)
    }
    let leadingInset: CGFloat = parentWidth < 80 ? 3 : 5
    let width = max(0, parentWidth - leadingInset)
    let xOffset = min(leadingInset, parentWidth)
    return CalendarInterruptOverlayGeometry(width: width, xOffset: xOffset)
}

func calendarInterruptChildOverlayGeometry(parentWidth: CGFloat) -> CalendarInterruptOverlayGeometry {
    let base = calendarInterruptOverlayGeometry(parentWidth: parentWidth)
    guard base.width > 0 else { return base }

    let trailingTrim: CGFloat = parentWidth < 80 ? 7 : 10
    let width = max(0, base.width - trailingTrim)
    let xOffset = min(parentWidth, base.xOffset + trailingTrim)
    return CalendarInterruptOverlayGeometry(width: width, xOffset: xOffset)
}

func calendarInterruptCutoutGeometry(
    parentWidth: CGFloat,
    moatWidth: CGFloat
) -> CalendarInterruptOverlayGeometry {
    let childOverlay = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
    let xOffset = max(0, childOverlay.xOffset - moatWidth)
    return CalendarInterruptOverlayGeometry(
        width: max(0, parentWidth - xOffset),
        xOffset: xOffset
    )
}

struct CalendarInterruptCompoundCutoutGeometry: Equatable {
    let rect: CGRect
    let hasTopLobe: Bool
    let hasBottomLobe: Bool
}

struct CalendarInterruptParentVisibleSegment: Equatable {
    let yStart: CGFloat
    let yEnd: CGFloat
    let width: CGFloat
}

struct CalendarInterruptParentCompoundGeometry: Equatable {
    let cutouts: [CalendarInterruptCompoundCutoutGeometry]
    let spineRect: CGRect
    let visibleSegments: [CalendarInterruptParentVisibleSegment]

    var isStandaloneSpine: Bool {
        cutouts.count == 1 && !cutouts[0].hasTopLobe && !cutouts[0].hasBottomLobe
    }
}

func calendarInterruptMergedRanges(
    parentRange: Event.TimeRange,
    childRanges: [Event.TimeRange]
) -> [Event.TimeRange] {
    let clipped = childRanges.compactMap { childRange -> Event.TimeRange? in
        let start = max(parentRange.start, childRange.start)
        let end = min(parentRange.end, childRange.end)
        guard end > start else { return nil }
        return Event.TimeRange(start: start, end: end)
    }
    .sorted { lhs, rhs in
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }

    guard !clipped.isEmpty else { return [] }
    var merged: [Event.TimeRange] = [clipped[0]]
    for range in clipped.dropFirst() {
        let lastIndex = merged.index(before: merged.endIndex)
        if range.start <= merged[lastIndex].end {
            merged[lastIndex].end = max(merged[lastIndex].end, range.end)
        } else {
            merged.append(range)
        }
    }
    return merged
}

func calendarInterruptParentCompoundGeometry(
    parentRange: Event.TimeRange,
    childRanges: [Event.TimeRange],
    parentWidth: CGFloat,
    parentHeight: CGFloat,
    gapWidth: CGFloat
) -> CalendarInterruptParentCompoundGeometry {
    guard parentWidth > 0, parentHeight > 0 else {
        return CalendarInterruptParentCompoundGeometry(
            cutouts: [],
            spineRect: .zero,
            visibleSegments: []
        )
    }

    let mergedRanges = calendarInterruptMergedRanges(
        parentRange: parentRange,
        childRanges: childRanges
    )
    let totalDuration = max(parentRange.end.timeIntervalSince(parentRange.start), 1)
    let cutoutGeometry = calendarInterruptCutoutGeometry(
        parentWidth: parentWidth,
        moatWidth: gapWidth
    )

    let rawRects = mergedRanges.compactMap { range -> CGRect? in
        let topProgress = range.start.timeIntervalSince(parentRange.start) / totalDuration
        let segmentProgress = range.end.timeIntervalSince(range.start) / totalDuration
        let rawTop = parentHeight * CGFloat(topProgress) - gapWidth
        let top = max(0, rawTop)
        let rawHeight = parentHeight * CGFloat(segmentProgress) + gapWidth * 2
        let height = min(
            max(gapWidth * 2 + 2, rawHeight),
            max(0, parentHeight - top)
        )
        guard height > 0 else { return nil }
        return CGRect(
            x: cutoutGeometry.xOffset,
            y: top,
            width: cutoutGeometry.width,
            height: height
        )
    }
    .sorted { lhs, rhs in
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        return lhs.maxY < rhs.maxY
    }

    let mergedRects: [CGRect] = rawRects.reduce(into: []) { partialResult, rect in
        guard let last = partialResult.last else {
            partialResult.append(rect)
            return
        }
        if rect.minY <= last.maxY {
            let mergedRect = CGRect(
                x: last.minX,
                y: last.minY,
                width: last.width,
                height: max(last.maxY, rect.maxY) - last.minY
            )
            partialResult[partialResult.count - 1] = mergedRect
        } else {
            partialResult.append(rect)
        }
    }

    let cutouts = mergedRects.map { rect in
        CalendarInterruptCompoundCutoutGeometry(
            rect: rect,
            hasTopLobe: rect.minY > 0.5,
            hasBottomLobe: rect.maxY < parentHeight - 0.5
        )
    }

    let fullWidth = parentWidth
    let spineWidth = max(0, cutoutGeometry.xOffset)
    var visibleSegments: [CalendarInterruptParentVisibleSegment] = []
    var currentY: CGFloat = 0

    for rect in mergedRects {
        if rect.minY > currentY + 0.5 {
            visibleSegments.append(
                CalendarInterruptParentVisibleSegment(
                    yStart: currentY,
                    yEnd: rect.minY,
                    width: fullWidth
                )
            )
        }
        if rect.maxY > rect.minY + 0.5 {
            visibleSegments.append(
                CalendarInterruptParentVisibleSegment(
                    yStart: rect.minY,
                    yEnd: rect.maxY,
                    width: spineWidth
                )
            )
        }
        currentY = rect.maxY
    }

    if currentY < parentHeight - 0.5 {
        visibleSegments.append(
            CalendarInterruptParentVisibleSegment(
                yStart: currentY,
                yEnd: parentHeight,
                width: fullWidth
            )
        )
    }

    if visibleSegments.isEmpty {
        visibleSegments = [
            CalendarInterruptParentVisibleSegment(
                yStart: 0,
                yEnd: parentHeight,
                width: fullWidth
            )
        ]
    }

    let normalizedVisibleSegments: [CalendarInterruptParentVisibleSegment] = visibleSegments.reduce(into: []) { partialResult, segment in
        guard segment.yEnd > segment.yStart else { return }
        guard let last = partialResult.last else {
            partialResult.append(segment)
            return
        }
        if abs(last.width - segment.width) < 0.5,
           abs(last.yEnd - segment.yStart) < 0.5 {
            partialResult[partialResult.count - 1] = CalendarInterruptParentVisibleSegment(
                yStart: last.yStart,
                yEnd: segment.yEnd,
                width: last.width
            )
        } else {
            partialResult.append(segment)
        }
    }

    return CalendarInterruptParentCompoundGeometry(
        cutouts: cutouts,
        spineRect: CGRect(
            x: 0,
            y: 0,
            width: max(0, cutoutGeometry.xOffset),
            height: parentHeight
        ),
        visibleSegments: normalizedVisibleSegments
    )
}

private func calendarRoundedClosedPolygonPath(
    points: [CGPoint],
    cornerRadius: CGFloat
) -> Path {
    guard points.count >= 3 else { return Path() }

    let effectiveCornerRadius = max(0, cornerRadius)
    var path = Path()

    for index in points.indices {
        let previous = points[(index - 1 + points.count) % points.count]
        let current = points[index]
        let next = points[(index + 1) % points.count]

        let vectorToPrevious = CGVector(
            dx: previous.x - current.x,
            dy: previous.y - current.y
        )
        let vectorToNext = CGVector(
            dx: next.x - current.x,
            dy: next.y - current.y
        )
        let previousLength = hypot(vectorToPrevious.dx, vectorToPrevious.dy)
        let nextLength = hypot(vectorToNext.dx, vectorToNext.dy)
        guard previousLength > 0.001, nextLength > 0.001 else { continue }

        let radius = min(
            effectiveCornerRadius,
            previousLength / 2,
            nextLength / 2
        )
        let entryPoint = CGPoint(
            x: current.x + vectorToPrevious.dx / previousLength * radius,
            y: current.y + vectorToPrevious.dy / previousLength * radius
        )
        let exitPoint = CGPoint(
            x: current.x + vectorToNext.dx / nextLength * radius,
            y: current.y + vectorToNext.dy / nextLength * radius
        )

        if index == 0 {
            path.move(to: entryPoint)
        } else {
            path.addLine(to: entryPoint)
        }

        if radius > 0 {
            path.addQuadCurve(to: exitPoint, control: current)
        } else {
            path.addLine(to: current)
        }
    }

    path.closeSubpath()
    return path
}

// Extracted for regression tests: edit style, explicit handle state,
// or a live long-press edit gesture can expose resize handles.
func calendarShouldShowResizeHandles(
    style: EventBlockStyle,
    showsResizeHandles: Bool,
    isLongPressing: Bool = false
) -> Bool {
    style == .edit || showsResizeHandles || isLongPressing
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

enum EventDragTerminalState: Equatable {
    case completed
    case cancelled
}

func calendarDragTerminalState(
    for gestureState: UIGestureRecognizer.State
) -> EventDragTerminalState? {
    switch gestureState {
    case .ended:
        return .completed
    case .cancelled, .failed:
        return .cancelled
    default:
        return nil
    }
}

func calendarShouldForwardDrop(
    for terminalState: EventDragTerminalState
) -> Bool {
    terminalState == .completed
}

func calendarResetSharedEventDragState(_ dragState: EventDragState) {
    dragState.draggingEventID = nil
    dragState.draggingOccurrenceID = nil
    dragState.draggingEvent = nil
    dragState.draggingOriginalRange = nil
    dragState.dragOffset = .zero
    dragState.dragMode = .move
    dragState.isHorizontalEdgeDragging = false
    dragState.isHorizontalAutoScrolling = false
}

/// UIView subclass that extends its touch area vertically for edge resize detection.
class ExtendedHitAreaView: UIView {
    var verticalExtension: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -verticalExtension).contains(point)
    }
}

let calendarEventManipulationLongPressDuration: TimeInterval = 0.15
let calendarEventExpressMenuLongPressDuration: TimeInterval = 1.0

func calendarEventExpressMenuAdditionalHoldDuration(
    manipulationLongPressDuration: TimeInterval = calendarEventManipulationLongPressDuration,
    expressMenuLongPressDuration: TimeInterval = calendarEventExpressMenuLongPressDuration
) -> TimeInterval {
    max(0, expressMenuLongPressDuration - manipulationLongPressDuration)
}

/// UIKit-based long press drag gesture for event blocks.
/// Detects drag position to determine move vs resize operations.
struct EventBlockDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = calendarEventManipulationLongPressDuration
    var edgeThreshold: CGFloat = 10 // Points from inside edge to trigger resize
    var outerEdgeThreshold: CGFloat = 0 // Points outside event block to trigger resize
    var snapSize: CGFloat // Points per 15-minute snap interval (must be set from hourHeight / 4)
    var horizontalAutoScrollEdgeInset: CGFloat = calendarHorizontalAutoScrollEdgeInsetDefault
    var verticalAutoScrollEdgeInset: CGFloat = calendarVerticalAutoScrollEdgeInsetDefault
    var maxAutoScrollSpeed: CGFloat = calendarMaxAutoScrollSpeedDefault // pt/s
    var horizontalAutoScrollUnitStep: CGFloat = 0
    var canMove: Bool = true
    var canResizeTop: Bool = true
    var canResizeBottom: Bool = true
    var debugEventID: String = ""
    var debugOccurrenceID: String = ""
    var onLongPressBegan: ((EventDragMode, CGPoint, CGRect) -> Void)?
    var onManipulationPromotion: ((EventDragMode, CGPoint, CGRect) -> Void)?
    var onDragBegan: ((EventDragMode) -> Void)?
    var onDragChanged: ((DragOffset) -> Void)?
    var onDragEnded: ((EventDragMode, DragOffset) -> Void)?
    var onDragTerminal: ((EventDragMode, DragOffset, EventDragTerminalState) -> Void)?
    var onLongPressResolved: ((EventDragMode, EventDragTerminalState, Bool, CGPoint) -> Void)?
    @Binding var isDragging: Bool
    @Binding var isHorizontalEdgeDragging: Bool
    @Binding var isHorizontalAutoScrolling: Bool
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
        context.coordinator.onLongPressBegan = onLongPressBegan
        context.coordinator.onManipulationPromotion = onManipulationPromotion
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDragTerminal = onDragTerminal
        context.coordinator.onLongPressResolved = onLongPressResolved
        context.coordinator.edgeThreshold = edgeThreshold
        context.coordinator.snapSize = snapSize
        context.coordinator.horizontalAutoScrollEdgeInset = horizontalAutoScrollEdgeInset
        context.coordinator.verticalAutoScrollEdgeInset = verticalAutoScrollEdgeInset
        context.coordinator.maxAutoScrollSpeed = maxAutoScrollSpeed
        context.coordinator.horizontalAutoScrollUnitStep = horizontalAutoScrollUnitStep
        context.coordinator.canMove = canMove
        context.coordinator.canResizeTop = canResizeTop
        context.coordinator.canResizeBottom = canResizeBottom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: EventBlockDragGesture
        var onLongPressBegan: ((EventDragMode, CGPoint, CGRect) -> Void)?
        var onManipulationPromotion: ((EventDragMode, CGPoint, CGRect) -> Void)?
        var onDragBegan: ((EventDragMode) -> Void)?
        var onDragChanged: ((DragOffset) -> Void)?
        var onDragEnded: ((EventDragMode, DragOffset) -> Void)?
        var onDragTerminal: ((EventDragMode, DragOffset, EventDragTerminalState) -> Void)?
        var onLongPressResolved: ((EventDragMode, EventDragTerminalState, Bool, CGPoint) -> Void)?
        var edgeThreshold: CGFloat = 20
        var snapSize: CGFloat = 0
        var horizontalAutoScrollEdgeInset: CGFloat = calendarHorizontalAutoScrollEdgeInsetDefault
        var verticalAutoScrollEdgeInset: CGFloat = calendarVerticalAutoScrollEdgeInsetDefault
        var maxAutoScrollSpeed: CGFloat = calendarMaxAutoScrollSpeedDefault
        var horizontalAutoScrollUnitStep: CGFloat = 0
        var canMove: Bool = true
        var canResizeTop: Bool = true
        var canResizeBottom: Bool = true
        private var initialPointInWindow: CGPoint = .zero
        private var lastLocationInWindow: CGPoint = .zero
        private var autoScrollCompensationX: CGFloat = 0
        private var autoScrollCompensationY: CGFloat = 0
        private weak var horizontalScrollView: UIScrollView?
        private weak var verticalScrollView: UIScrollView?
        private weak var activeGesture: UILongPressGestureRecognizer?
        private var autoScrollVelocityX: CGFloat = 0
        private var autoScrollVelocityY: CGFloat = 0
        private var autoScrollDisplayLink: CADisplayLink?
        private var isHorizontalSnapSuppressed: Bool = false
        private var disabledPanGestures: [(gesture: UIPanGestureRecognizer, wasEnabled: Bool)] = []
        private var hasMovedAfterLongPress: Bool = false
        private var hasPromotedManipulation = false
        private var currentMode: EventDragMode = .move
        private var lastSnappedStep: Int = 0
        private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        private var lastChangedLogTimestamp: CFTimeInterval = 0
        private var lastLoggedHorizontalAutoScrolling: Bool = false

        /// Returns the gesture view's frame in window coordinates (live UIKit value).
        private var viewFrameInWindow: CGRect {
            guard let view = activeGesture?.view else { return .zero }
            return view.convert(view.bounds, to: nil)
        }

        init(_ parent: EventBlockDragGesture) {
            self.parent = parent
            self.onLongPressBegan = parent.onLongPressBegan
            self.onManipulationPromotion = parent.onManipulationPromotion
            self.onDragBegan = parent.onDragBegan
            self.onDragChanged = parent.onDragChanged
            self.onDragEnded = parent.onDragEnded
            self.onDragTerminal = parent.onDragTerminal
            self.onLongPressResolved = parent.onLongPressResolved
            self.edgeThreshold = parent.edgeThreshold
            self.snapSize = parent.snapSize
            self.horizontalAutoScrollEdgeInset = parent.horizontalAutoScrollEdgeInset
            self.verticalAutoScrollEdgeInset = parent.verticalAutoScrollEdgeInset
            self.maxAutoScrollSpeed = parent.maxAutoScrollSpeed
            self.horizontalAutoScrollUnitStep = parent.horizontalAutoScrollUnitStep
            self.canMove = parent.canMove
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
                autoScrollCompensationX = 0
                autoScrollCompensationY = 0
                autoScrollVelocityX = 0
                autoScrollVelocityY = 0
                isHorizontalSnapSuppressed = false
                hasMovedAfterLongPress = false
                hasPromotedManipulation = false
                lastSnappedStep = 0
                lastLoggedHorizontalAutoScrolling = false

                currentMode = calendarResolveDragMode(
                    locationX: location.x,
                    locationY: location.y,
                    viewWidth: view.bounds.width,
                    viewHeight: viewHeight,
                    edgeThreshold: edgeThreshold,
                    canResizeTop: canResizeTop,
                    canResizeBottom: canResizeBottom
                )

                onLongPressBegan?(currentMode, initialPointInWindow, viewFrameInWindow)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                calendarDebugLog(
                    "event.drag.begin",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "mode": String(describing: currentMode),
                        "touchInViewX": format(location.x),
                        "touchInViewY": format(location.y),
                        "initialWindowX": format(initialPointInWindow.x),
                        "initialWindowY": format(initialPointInWindow.y),
                        "horizontalOffsetX": format(horizontalScrollView?.contentOffset.x ?? 0),
                        "verticalOffsetY": format(verticalScrollView?.contentOffset.y ?? 0)
                    ]
                )

            case .changed:
                let rawLocationInWindow = gesture.location(in: nil)
                lastLocationInWindow = rawLocationInWindow
                let rawDeltaX = rawLocationInWindow.x - initialPointInWindow.x
                let rawDeltaY = rawLocationInWindow.y - initialPointInWindow.y
                let hasCrossedMovementThreshold = hypot(rawDeltaX, rawDeltaY) > 2

                if !hasPromotedManipulation {
                    guard calendarShouldPromoteLongPressToManipulation(
                        dragMode: currentMode,
                        canMove: canMove,
                        movementExceededThreshold: hasCrossedMovementThreshold
                    ) else {
                        stopAutoScroll(reason: "stagedLongPressAwaitingPromotion")
                        return
                    }

                    hasMovedAfterLongPress = true
                    hasPromotedManipulation = true
                    disableScrollPanGesturesForDrag()
                    parent.dragMode = currentMode
                    parent.isHorizontalEdgeDragging = false
                    parent.isHorizontalAutoScrolling = false
                    parent.isDragging = true
                    onManipulationPromotion?(currentMode, lastLocationInWindow, viewFrameInWindow)
                    onDragBegan?(currentMode)
                    updateAutoScrollVelocity()
                    // Compute and apply offset immediately so the first frame
                    // already reflects the finger position (no zero-frame lag).
                    updateDragOffset(using: gesture)
                    return
                }

                if hasMovedAfterLongPress {
                    // Update edge/auto-scroll state first so this frame's drag offset
                    // is rendered with the correct (possibly unsnapped) boundary behavior.
                    updateAutoScrollVelocity()
                } else {
                    stopAutoScroll(reason: "changedWithoutMovement")
                }
                updateDragOffset(using: gesture)
                let now = CACurrentMediaTime()
                if now - lastChangedLogTimestamp >= 0.08 {
                    lastChangedLogTimestamp = now
                    calendarDebugLog(
                        "event.drag.changed",
                        fields: [
                            "eventID": parent.debugEventID,
                            "occurrenceID": debugOccurrenceKey,
                            "mode": String(describing: currentMode),
                            "fingerX": format(rawLocationInWindow.x),
                            "fingerY": format(rawLocationInWindow.y),
                            "deltaX": format(rawDeltaX),
                            "deltaY": format(rawDeltaY),
                            "resolvedOffsetX": format(parent.dragOffset.x),
                            "resolvedOffsetY": format(parent.dragOffset.y),
                            "isEdgeDragging": "\(parent.isHorizontalEdgeDragging)",
                            "isHorizontalAutoScrolling": "\(parent.isHorizontalAutoScrolling)",
                            "velocityX": format(autoScrollVelocityX),
                            "velocityY": format(autoScrollVelocityY)
                        ]
                    )
                }

            case .ended, .cancelled, .failed:
                let gestureState = gesture.state
                guard let terminalState = calendarDragTerminalState(for: gestureState) else {
                    return
                }
                if hasPromotedManipulation {
                    let shouldForwardDrop = calendarShouldForwardDrop(for: terminalState)
                    updateDragOffset(using: gesture)
                    let finalOffset = parent.dragOffset
                    let mode = currentMode
                    let hadMovedAfterLongPress = hasMovedAfterLongPress
                    finalizeTouchInteraction()
                    calendarDebugLog(
                        "event.drag.end",
                        fields: [
                            "eventID": parent.debugEventID,
                            "occurrenceID": debugOccurrenceKey,
                            "mode": String(describing: mode),
                            "finalOffsetX": format(finalOffset.x),
                            "finalOffsetY": format(finalOffset.y),
                            "state": String(describing: gestureState),
                            "terminalState": String(describing: terminalState),
                            "shouldForwardDrop": "\(shouldForwardDrop)",
                            "hadMovedAfterLongPress": "\(hadMovedAfterLongPress)"
                        ]
                    )
                    if shouldForwardDrop && hadMovedAfterLongPress {
                        onDragEnded?(mode, finalOffset)
                    }
                    onLongPressResolved?(mode, terminalState, hadMovedAfterLongPress, lastLocationInWindow)
                    onDragTerminal?(mode, finalOffset, terminalState)
                    return
                }

                let mode = currentMode
                finalizeTouchInteraction()
                calendarDebugLog(
                    "event.longPress.end",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "mode": String(describing: mode),
                        "state": String(describing: gestureState),
                        "terminalState": String(describing: terminalState)
                    ]
                )
                onLongPressResolved?(mode, terminalState, false, lastLocationInWindow)

            default:
                break
            }
        }

        deinit {
            stopAutoScroll(reason: "coordinatorDeinit")
            restoreScrollPanGestures()
        }

        private func finalizeTouchInteraction() {
            stopAutoScroll(reason: "gestureEnded")
            restoreScrollPanGestures()
            activeGesture = nil
            horizontalScrollView = nil
            verticalScrollView = nil
            hasMovedAfterLongPress = false
            hasPromotedManipulation = false
            isHorizontalSnapSuppressed = false
            parent.isDragging = false
            parent.isHorizontalEdgeDragging = false
            parent.isHorizontalAutoScrolling = false
            parent.dragOffset = .zero
            autoScrollCompensationX = 0
            autoScrollCompensationY = 0
        }

        // Keep drag offset stable in window coordinates, then add scroll compensation
        // so auto-scrolling still advances the dragged time while finger stays near edge.
        private func updateDragOffset(using gesture: UILongPressGestureRecognizer) {
            let locationInWindow = gesture.location(in: nil)
            lastLocationInWindow = locationInWindow

            let fingerDelta = DragOffset(
                x: locationInWindow.x - initialPointInWindow.x,
                y: locationInWindow.y - initialPointInWindow.y
            )
            let offset = calendarComposedDragOffset(
                fingerDelta: fingerDelta,
                autoScrollCompensation: DragOffset(
                    x: autoScrollCompensationX,
                    y: autoScrollCompensationY
                )
            )
            applyDragOffset(offset)
        }

        private func applyDragOffset(_ offset: DragOffset) {
            let suppressHorizontalSnap = isHorizontalSnapSuppressed || autoScrollVelocityX != 0
            let resolved = calendarResolvedDragOffset(
                rawOffset: offset,
                dragMode: currentMode,
                dayColumnStep: horizontalAutoScrollUnitStep,
                suppressHorizontalSnap: suppressHorizontalSnap
            )

            // Haptic on each 15-minute snap boundary crossed
            if snapSize > 0 {
                let currentStep = Int((resolved.y / snapSize).rounded())
                if currentStep != lastSnappedStep {
                    lastSnappedStep = currentStep
                    impactFeedback.impactOccurred()
                }
            }

            guard parent.dragOffset != resolved else { return }
            parent.dragOffset = resolved
            onDragChanged?(resolved)
        }

        private enum ScrollAxis {
            case horizontal
            case vertical
        }

        private func updateAutoScrollVelocity() {
            guard hasMovedAfterLongPress else {
                stopAutoScroll(reason: "moveGateFalse")
                isHorizontalSnapSuppressed = false
                parent.isHorizontalEdgeDragging = false
                parent.isHorizontalAutoScrolling = false
                return
            }

            let horizontalEdgeActive = isInHorizontalAutoScrollEdgeZone()
            autoScrollVelocityX = currentMode == .move
                ? autoScrollVelocity(for: horizontalScrollView, axis: .horizontal)
                : 0
            autoScrollVelocityY = autoScrollVelocity(for: verticalScrollView, axis: .vertical)

            if autoScrollVelocityX == 0 && autoScrollVelocityY == 0 {
                stopAutoScroll(reason: "zeroVelocity")
            } else {
                startAutoScroll()
            }
            let isAutoScrolling = autoScrollVelocityX != 0
            // Runtime suppression: only while edge-zone or horizontal auto-scroll is active.
            isHorizontalSnapSuppressed = horizontalEdgeActive || isAutoScrolling
            parent.isHorizontalEdgeDragging = isHorizontalSnapSuppressed
            parent.isHorizontalAutoScrolling = isAutoScrolling
            if isAutoScrolling != lastLoggedHorizontalAutoScrolling {
                lastLoggedHorizontalAutoScrolling = isAutoScrolling
                calendarDebugLog(
                    "event.horizontalAutoScroll.state",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "isAutoScrolling": "\(isAutoScrolling)",
                        "velocityX": format(autoScrollVelocityX),
                        "velocityY": format(autoScrollVelocityY),
                        "isEdgeDragging": "\(parent.isHorizontalEdgeDragging)"
                    ]
                )
            }
        }

        private func startAutoScroll() {
            guard autoScrollDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            autoScrollDisplayLink = link
            calendarDebugLog(
                "event.horizontalAutoScroll.start",
                fields: [
                    "eventID": parent.debugEventID,
                    "occurrenceID": debugOccurrenceKey,
                    "velocityX": format(autoScrollVelocityX),
                    "velocityY": format(autoScrollVelocityY),
                    "isEdgeDragging": "\(parent.isHorizontalEdgeDragging)"
                ]
            )
        }

        private func stopAutoScroll(reason: String) {
            let wasAutoScrolling = autoScrollDisplayLink != nil || autoScrollVelocityX != 0 || autoScrollVelocityY != 0
            autoScrollDisplayLink?.invalidate()
            autoScrollDisplayLink = nil
            autoScrollVelocityX = 0
            autoScrollVelocityY = 0
            parent.isHorizontalAutoScrolling = false
            if wasAutoScrolling {
                calendarDebugLog(
                    "event.horizontalAutoScroll.stop",
                    fields: [
                        "eventID": parent.debugEventID,
                        "occurrenceID": debugOccurrenceKey,
                        "reason": reason,
                        "compensationX": format(autoScrollCompensationX),
                        "compensationY": format(autoScrollCompensationY),
                        "horizontalOffsetX": format(horizontalScrollView?.contentOffset.x ?? 0),
                        "verticalOffsetY": format(verticalScrollView?.contentOffset.y ?? 0)
                    ]
                )
            }
        }

        @objc private func handleAutoScrollTick(_ displayLink: CADisplayLink) {
            guard autoScrollVelocityX != 0 || autoScrollVelocityY != 0 else {
                stopAutoScroll(reason: "tickNoVelocity")
                return
            }

            let dt = max(displayLink.targetTimestamp - displayLink.timestamp, 0)
            let deltaX = calendarHorizontalAutoScrollDelta(
                velocityX: autoScrollVelocityX,
                deltaTime: dt
            )
            let delta = CGPoint(
                x: deltaX,
                y: autoScrollVelocityY * CGFloat(dt)
            )

            if let sharedScrollView = horizontalScrollView, sharedScrollView === verticalScrollView {
                let applied = applyAutoScroll(
                    on: sharedScrollView,
                    delta: delta
                )
                autoScrollCompensationX += applied.x
                autoScrollCompensationY += applied.y
            } else {
                if let scrollView = horizontalScrollView {
                    let applied = applyAutoScroll(
                        on: scrollView,
                        delta: CGPoint(x: delta.x, y: 0)
                    )
                    autoScrollCompensationX += applied.x
                }
                if let scrollView = verticalScrollView {
                    let applied = applyAutoScroll(on: scrollView, delta: CGPoint(x: 0, y: delta.y))
                    autoScrollCompensationY += applied.y
                }
            }

            if let gesture = activeGesture {
                lastLocationInWindow = gesture.location(in: nil)
            }
            updateAutoScrollVelocity()
            if let gesture = activeGesture {
                updateDragOffset(using: gesture)
            }
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

        private func isInHorizontalAutoScrollEdgeZone() -> Bool {
            guard currentMode == .move, let horizontalScrollView else { return false }
            let location = locationInViewport(for: horizontalScrollView, axis: .horizontal)
            return calendarIsInAutoScrollEdgeZone(
                locationInViewport: location,
                viewportLength: horizontalScrollView.bounds.width,
                edgeInset: horizontalAutoScrollEdgeInset
            )
        }

        private func disableScrollPanGesturesForDrag() {
            guard disabledPanGestures.isEmpty else { return }
            var panGestures: [UIPanGestureRecognizer] = []
            if let horizontalPan = horizontalScrollView?.panGestureRecognizer {
                panGestures.append(horizontalPan)
            }
            if let verticalPan = verticalScrollView?.panGestureRecognizer,
               !panGestures.contains(where: { $0 === verticalPan }) {
                panGestures.append(verticalPan)
            }

            for pan in panGestures {
                disabledPanGestures.append((gesture: pan, wasEnabled: pan.isEnabled))
                pan.isEnabled = false
            }
        }

        private func restoreScrollPanGestures() {
            guard !disabledPanGestures.isEmpty else { return }
            for entry in disabledPanGestures {
                entry.gesture.isEnabled = entry.wasEnabled
            }
            disabledPanGestures.removeAll()
        }

        private func applyAutoScroll(
            on scrollView: UIScrollView,
            delta: CGPoint
        ) -> CGPoint {
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
                return .zero
            }

            let applied = CGPoint(x: clampedX - currentOffset.x, y: clampedY - currentOffset.y)
            let targetOffset = CGPoint(x: clampedX, y: clampedY)
            scrollView.setContentOffset(targetOffset, animated: false)
            return applied
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

        private var debugOccurrenceKey: String {
            if parent.debugOccurrenceID.isEmpty {
                return "none"
            }
            return parent.debugOccurrenceID
        }

        private func format(_ value: CGFloat) -> String {
            String(format: "%.2f", value)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

struct CalendarInterruptParentCompoundShape: Shape {
    let cornerRadius: CGFloat
    let visibleSegments: [CalendarInterruptParentVisibleSegment]

    func path(in rect: CGRect) -> Path {
        guard let firstSegment = visibleSegments.first else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        var points: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX + firstSegment.width, y: rect.minY)
        ]

        for (index, segment) in visibleSegments.enumerated() {
            points.append(
                CGPoint(
                    x: rect.minX + segment.width,
                    y: rect.minY + segment.yEnd
                )
            )

            if index < visibleSegments.count - 1 {
                let next = visibleSegments[index + 1]
                if abs(next.width - segment.width) > 0.5 {
                    points.append(
                        CGPoint(
                            x: rect.minX + next.width,
                            y: rect.minY + segment.yEnd
                        )
                    )
                }
            }
        }

        points.append(CGPoint(x: rect.minX, y: rect.maxY))
        return calendarRoundedClosedPolygonPath(
            points: points,
            cornerRadius: cornerRadius
        )
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
    var dragPreviewDayStep: CGFloat = 0
    var showsResizeHandles: Bool = false
    var resizeHandleOpacity: Double = 1
    var canMove: Bool = true
    var isFocused: Bool = false
    var isFocusContextActive: Bool = false
    var onTap: (() -> Void)? = nil
    var onLongPressBegan: ((EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onManipulationPromotion: ((EventDragMode, CGPoint, CGRect) -> Void)? = nil
    var onLongPressResolved: ((EventDragMode, EventDragTerminalState, Bool, CGPoint) -> Void)? = nil
    var onDragEnded: ((DragOffset) -> Void)? = nil
    var onResizeTopEnded: ((CGFloat) -> Void)? = nil    // Y offset for top edge
    var onResizeBottomEnded: ((CGFloat) -> Void)? = nil // Y offset for bottom edge
    var canResizeTop: Bool = true
    var canResizeBottom: Bool = true
    var isTimerActive: Bool = false
    var agenticProcessingPhase: AgenticIntakeProcessingPhase? = nil
    var interruptState: EventInterruptRelationState? = nil
    var interruptParentColor: Color? = nil
    var interruptIsCurrentlyEmbedded: Bool = false
    var interruptEmbeddedChildRanges: [Event.TimeRange] = []

    // External drag state for cross-day sync (when another occurrence of this event is being dragged)
    @ObservedObject var dragState: EventDragState

    @State private var isLongPressing = false
    @State private var isDragging = false
    @State private var isHorizontalEdgeDragging = false
    @State private var isHorizontalAutoScrolling = false
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

    /// Whether block is visually in drag state (long press, dragging, or synced)
    private var isInDragState: Bool {
        isLongPressing || isDragging || isFollowingExternalDrag
    }

    private var isDimmedByFocus: Bool {
        isFocusContextActive && !isFocused
    }

    private var currentDragMode: EventDragMode {
        if isDragging || isLongPressing {
            return dragMode
        }
        return dragState.dragMode
    }

    private var isAgenticAnalyzing: Bool {
        switch agenticProcessingPhase {
        case .queued, .analyzing:
            return true
        default:
            return false
        }
    }

    private var isAgenticFailed: Bool {
        agenticProcessingPhase == .failed
    }

    private var isInterruptEvent: Bool {
        event.isInterrupt
    }

    private var resolvedInterruptState: EventInterruptRelationState? {
        interruptState ?? event.interruptRelation?.state
    }

    private var interruptCornerRadius: CGFloat {
        isInterruptEvent ? 5 : 6
    }

    private var resolvedInterruptVisualMode: EventBlockInterruptVisualMode {
        calendarInterruptVisualMode(
            isInterruptEvent: isInterruptEvent,
            relationState: resolvedInterruptState,
            isCurrentlyEmbedded: interruptIsCurrentlyEmbedded,
            hasParentColor: interruptParentColor != nil
        )
    }

    private var isCompoundParentEvent: Bool {
        !interruptEmbeddedChildRanges.isEmpty
    }

    private func embeddedInterruptCardShape(cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var blockFillOpacity: Double {
        isInterruptEvent ? 0.46 : style.fillOpacity
    }

    private var blockStrokeOpacity: Double {
        isInterruptEvent ? 0.82 : style.strokeOpacity
    }

    private var blockStrokeWidth: CGFloat {
        isInterruptEvent ? max(1.35, style.strokeWidth + 0.15) : style.strokeWidth
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
        let minHeight: CGFloat = 20
        switch dragMode {
        case .resizeTop:
            return max(minHeight, baseHeight - snappedResizeOffset)
        case .resizeBottom:
            return max(minHeight, baseHeight + snappedResizeOffset)
        case .move:
            return baseHeight
        }
    }

    /// Drag X offset for move mode.
    /// During auto-scroll the raw X offset (including scroll compensation)
    /// keeps the event block near the finger even as the page scrolls.
    private var moveOffsetX: CGFloat {
        let mode = currentDragMode
        guard isInDragState, mode == .move else { return 0 }
        return effectiveDragOffset.x
    }

    /// Display range adjusted by the current drag offset
    private var adjustedDisplayRange: Event.TimeRange? {
        guard let range = displayRange else { return nil }
        guard isInDragState else { return range }

        let dragBaseRange: Event.TimeRange
        switch currentDragMode {
        case .move:
            // Preserve the occurrence's full source range while moving so
            // cross-day previews render the real span in the floating block.
            dragBaseRange = dragSourceRange ?? range
        case .resizeTop, .resizeBottom:
            dragBaseRange = range
        }

        return calendarResolvedDragEditRange(
            draggingOriginalRange: dragBaseRange,
            dragOffset: effectiveDragOffset,
            dragMode: currentDragMode,
            hourHeight: hourHeight,
            dayColumnStep: currentDragMode == .move ? dragPreviewDayStep : 0
        ) ?? range
    }

    /// Y offset for the block during resizeTop drag
    private func resizeYOffset(baseHeight: CGFloat) -> CGFloat {
        guard isDragging, dragMode == .resizeTop else { return 0 }
        let minHeight = hourHeight / 2
        // Clamp so block doesn't shrink below minimum
        return min(snappedResizeOffset, baseHeight - minHeight)
    }

    private func syncSharedDragStateForBegin(mode: EventDragMode) {
        calendarDebugLog(
            "event.sharedDragState.begin",
            fields: [
                "eventID": event.id.uuidString,
                "mode": String(describing: mode)
            ]
        )
        dragState.draggingEventID = event.id
        dragState.draggingOccurrenceID = occurrenceID
        dragState.draggingEvent = event
        // Use the specific occurrence's full range when available.
        // This keeps multi-range events from switching to another range.
        dragState.draggingOriginalRange = dragSourceRange ?? event.primaryTimeRange
        dragState.dragMode = mode
        dragState.dayColumnStep = dragPreviewDayStep
        dragState.isHorizontalEdgeDragging = false
        dragState.isHorizontalAutoScrolling = false
    }

    private func clearSharedDragState(reason: String) {
        calendarDebugLog(
            "event.sharedDragState.clear",
            fields: [
                "reason": reason,
                "eventID": event.id.uuidString
            ]
        )
        calendarResetSharedEventDragState(dragState)
    }

    var body: some View {
        GeometryReader { geo in
            let baseHeight = geo.size.height
            let handleWidth = min(geo.size.width * 0.4, 36)
            let moatWidth = resolvedInterruptVisualMode == .embeddedMoat
                || isCompoundParentEvent
                ? calendarInterruptMoatWidth(
                    availableWidth: geo.size.width,
                    availableHeight: baseHeight
                )
                : 0
            let compoundGeometry: CalendarInterruptParentCompoundGeometry? = {
                guard isCompoundParentEvent,
                      let resolvedRange = adjustedDisplayRange else {
                    return nil
                }
                return calendarInterruptParentCompoundGeometry(
                    parentRange: resolvedRange,
                    childRanges: interruptEmbeddedChildRanges,
                    parentWidth: geo.size.width,
                    parentHeight: baseHeight,
                    gapWidth: moatWidth
                )
            }()
            let compoundShape: CalendarInterruptParentCompoundShape? = {
                guard let geometry = compoundGeometry,
                      !geometry.cutouts.isEmpty else {
                    return nil
                }
                return CalendarInterruptParentCompoundShape(
                    cornerRadius: max(interruptCornerRadius, 6),
                    visibleSegments: geometry.visibleSegments
                )
            }()
            let usesNativeShapeMask = compoundShape != nil || resolvedInterruptVisualMode == .embeddedMoat
            let baseVisual = content(availableWidth: geo.size.width, availableHeight: baseHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    blockBackground(
                        usesNativeShapeMask: usesNativeShapeMask
                    )
                )
                .overlay {
                    if isTimerActive {
                        DiagonalHatchingPattern(spacing: 6, lineWidth: 1)
                            .stroke(color.opacity(0.3), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if isAgenticAnalyzing {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.05),
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(isInDragState ? 0.08 : 0.18)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if isAgenticFailed {
                        Rectangle()
                            .stroke(Color.orange.opacity(0.75), lineWidth: max(1.4, blockStrokeWidth + 0.4))
                            .allowsHitTesting(false)
                    }
                }

            baseVisual
                .mask {
                    blockVisualMask(
                        compoundShape: compoundShape,
                        embeddedChildCornerRadius: interruptCornerRadius
                    )
                }
                .overlay {
                    blockBorderOverlay(
                        compoundShape: compoundShape,
                        embeddedChildCornerRadius: interruptCornerRadius
                    )
                        .allowsHitTesting(false)
                }
                .overlay {
                    if isDragEnabled && baseHeight >= 32 && calendarShouldShowResizeHandles(
                        style: style,
                        showsResizeHandles: showsResizeHandles,
                        isLongPressing: isLongPressing
                    ) {
                        let isResizingTop = isInDragState && currentDragMode == .resizeTop
                        let isResizingBottom = isInDragState && currentDragMode == .resizeBottom
                        let activeWidth = max(handleWidth, geo.size.width * 0.7)
                        VStack(spacing: 0) {
                            if canResizeTop {
                                Capsule()
                                    .fill(color.opacity(isResizingTop ? 0.8 : 0.45 * resizeHandleOpacity))
                                    .frame(width: isResizingTop ? activeWidth : handleWidth, height: 3)
                                    .padding(.top, 5)
                            }
                            Spacer()
                            if canResizeBottom {
                                Capsule()
                                    .fill(color.opacity(isResizingBottom ? 0.8 : 0.45 * resizeHandleOpacity))
                                    .frame(width: isResizingBottom ? activeWidth : handleWidth, height: 3)
                                    .padding(.bottom, 5)
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: isResizingTop)
                        .animation(.easeOut(duration: 0.2), value: isResizingBottom)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isAgenticAnalyzing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(5)
                            .allowsHitTesting(false)
                    } else if isAgenticFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: resizeHeight(baseHeight: baseHeight)
                )
                .scaleEffect(
                    calendarEventBlockScale(
                        isMoveDragging: isInDragState && currentDragMode == .move,
                        isFocused: isFocused && !(isInDragState && currentDragMode != .move),
                        isDimmedByFocus: isDimmedByFocus
                    )
                )
                .opacity(isDimmedByFocus ? 0.28 : 1.0)
                .shadow(radius: isFocused ? 4 : (isInDragState ? 3 : 0))
                // X offset follows finger during move drag; Y offset is only for resize
                // (move Y is handled by TimelineDayView's adjustedRange).
                .offset(x: currentDragMode == .move ? moveOffsetX : 0,
                        y: (isDragging && dragMode != .move ? resizeYOffset(baseHeight: baseHeight) : 0))
                .contentShape(Rectangle())
                .overlay {
                    if isDragEnabled {
                        EventBlockDragGesture(
                            snapSize: snapSize,
                            horizontalAutoScrollUnitStep: dayColumnStep,
                            canMove: canMove,
                            canResizeTop: canResizeTop,
                            canResizeBottom: canResizeBottom,
                            debugEventID: event.id.uuidString,
                            debugOccurrenceID: occurrenceID ?? "",
                            onLongPressBegan: { mode, touchPointGlobal, viewFrameGlobal in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    isLongPressing = true
                                    dragMode = mode
                                }
                                onLongPressBegan?(mode, touchPointGlobal, viewFrameGlobal)
                            },
                            onManipulationPromotion: { mode, touchPointGlobal, viewFrameGlobal in
                                onManipulationPromotion?(
                                    mode,
                                    touchPointGlobal,
                                    viewFrameGlobal
                                )
                            },
                            onDragBegan: { mode in
                                syncSharedDragStateForBegin(mode: mode)
                            },
                            onDragChanged: { offset in
                                // Sync immediately to shared drag state so there is
                                // no one-frame lag waiting for SwiftUI onChange.
                                dragState.dragOffset = offset
                            },
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
                            onDragTerminal: { _, _, terminalState in
                                isLongPressing = false
                                clearSharedDragState(
                                    reason: "dragTerminal.\(String(describing: terminalState))"
                                )
                            },
                            onLongPressResolved: { mode, terminalState, didMove, touchPointGlobal in
                                isLongPressing = false
                                onLongPressResolved?(mode, terminalState, didMove, touchPointGlobal)
                            },
                            isDragging: $isDragging,
                            isHorizontalEdgeDragging: $isHorizontalEdgeDragging,
                            isHorizontalAutoScrolling: $isHorizontalAutoScrolling,
                            dragOffset: $dragOffset,
                            dragMode: $dragMode
                        )
                    }
                }
                .onTapGesture { onTap?() }
                .animation(.easeInOut(duration: 0.15), value: isInDragState)
                .onChange(of: isHorizontalEdgeDragging) { newValue in
                    if isDragging {
                        dragState.isHorizontalEdgeDragging = newValue
                    }
                }
                .onChange(of: isHorizontalAutoScrolling) { newValue in
                    if isDragging {
                        dragState.isHorizontalAutoScrolling = newValue
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
    private func blockBackground(
        usesNativeShapeMask: Bool
    ) -> some View {
        ZStack {
            if usesNativeShapeMask {
                Rectangle()
                    .fill(Color(.systemBackground))
                Rectangle()
                    .fill(color.opacity(blockFillOpacity))
            } else {
                RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                    .fill(Color(.systemBackground))
                RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                    .fill(color.opacity(blockFillOpacity))
            }
        }
    }

    @ViewBuilder
    private func blockVisualMask(
        compoundShape: CalendarInterruptParentCompoundShape?,
        embeddedChildCornerRadius: CGFloat
    ) -> some View {
        if let compoundShape {
            compoundShape
                .fill(Color.white)
        } else if resolvedInterruptVisualMode == .embeddedMoat {
            embeddedInterruptCardShape(cornerRadius: embeddedChildCornerRadius)
                .fill(Color.white)
        } else {
            RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                .fill(Color.white)
        }
    }

    @ViewBuilder
    private func blockBorderOverlay(
        compoundShape: CalendarInterruptParentCompoundShape?,
        embeddedChildCornerRadius: CGFloat
    ) -> some View {
        ZStack(alignment: .leading) {
            if let compoundShape {
                compoundShape
                    .stroke(color.opacity(blockStrokeOpacity), lineWidth: blockStrokeWidth)
            } else if resolvedInterruptVisualMode == .embeddedMoat {
                embeddedInterruptCardShape(cornerRadius: embeddedChildCornerRadius)
                    .stroke(color.opacity(blockStrokeOpacity), lineWidth: blockStrokeWidth)
            } else {
                RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)
                    .stroke(color.opacity(blockStrokeOpacity), lineWidth: blockStrokeWidth)
            }

            if resolvedInterruptVisualMode == .weakRelation,
               let interruptParentColor {
                weakInterruptRelationOverlay(parentColor: interruptParentColor)
            }
        }
    }

    @ViewBuilder
    private func content(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let compact = availableWidth < 60
        let fontSize: CGFloat = compact ? 9 : 12
        let pad: CGFloat = compact ? 3 : 8
        let minHeight: CGFloat = compact ? 16 : 24

        if showText, availableHeight >= minHeight {
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(event.title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)

                if !compact, style.showTimeRange, let range = adjustedDisplayRange {
                    Text("\(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(pad)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func weakInterruptRelationOverlay(parentColor: Color) -> some View {
        Rectangle()
            .fill(parentColor.opacity(0.34))
            .frame(width: 1)
            .padding(.vertical, 4)
            .padding(.leading, 4)
    }
}
