//
//  EventBlock.swift
//  Done
//
//  Unified event block component for timeline display.
//

import SwiftUI
import UIKit

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
        var canResizeTop: Bool = true
        var canResizeBottom: Bool = true
        private var initialPoint: CGPoint = .zero
        private var initialPointInWindow: CGPoint = .zero
        private var currentMode: EventDragMode = .move
        private var lastSnappedStep: Int = 0
        private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

        init(_ parent: EventBlockDragGesture) {
            self.parent = parent
            self.onDragBegan = parent.onDragBegan
            self.onDragChanged = parent.onDragChanged
            self.onDragEnded = parent.onDragEnded
            self.edgeThreshold = parent.edgeThreshold
            self.snapSize = parent.snapSize
            self.canResizeTop = parent.canResizeTop
            self.canResizeBottom = parent.canResizeBottom
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let viewHeight = view.bounds.height

            switch gesture.state {
            case .began:
                initialPoint = location
                initialPointInWindow = gesture.location(in: nil)
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
                // Use window coordinates for offset calculation.
                // This makes the reported drag distance immune to parent
                // view repositioning (adjustedRange changing .offset()),
                // which would otherwise shift the UIView's coordinate
                // system and create a feedback loop causing flickering.
                let locationInWindow = gesture.location(in: nil)
                let offset = DragOffset(
                    x: locationInWindow.x - initialPointInWindow.x,
                    y: locationInWindow.y - initialPointInWindow.y
                )
                // Haptic on each 15-minute snap boundary crossed
                if snapSize > 0 {
                    let currentStep = Int((offset.y / snapSize).rounded())
                    if currentStep != lastSnappedStep {
                        lastSnappedStep = currentStep
                        impactFeedback.impactOccurred()
                    }
                }
                parent.dragOffset = offset
                onDragChanged?(offset)

            case .ended, .cancelled:
                let finalOffset = parent.dragOffset
                let mode = currentMode
                parent.isDragging = false
                parent.dragOffset = .zero
                onDragEnded?(mode, finalOffset)

            default:
                break
            }
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
        !isDragging && dragState.draggingEventID == event.id && dragState.dragMode == .move
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
        guard dayColumnStep > 0 else { return offset.x }
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
                        dragState.draggingEvent = event
                        // Use the event's full time range, not the clipped displayRange
                        // This enables correct cross-day preview calculations
                        dragState.draggingOriginalRange = event.primaryTimeRange
                        dragState.dragOffset = dragOffset
                        dragState.dragMode = dragMode
                    } else {
                        dragState.draggingEventID = nil
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
