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
    var edgeThreshold: CGFloat = 20 // Points from inside edge to trigger resize
    var outerEdgeThreshold: CGFloat = 10 // Points outside event block to trigger resize
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
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.edgeThreshold = edgeThreshold
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
        private var initialPoint: CGPoint = .zero
        private var currentMode: EventDragMode = .move

        init(_ parent: EventBlockDragGesture) {
            self.parent = parent
            self.onDragBegan = parent.onDragBegan
            self.onDragChanged = parent.onDragChanged
            self.onDragEnded = parent.onDragEnded
            self.edgeThreshold = parent.edgeThreshold
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let viewHeight = view.bounds.height

            switch gesture.state {
            case .began:
                initialPoint = location
                // Determine drag mode based on touch position
                if location.y < edgeThreshold {
                    currentMode = .resizeTop
                } else if location.y > viewHeight - edgeThreshold {
                    currentMode = .resizeBottom
                } else {
                    currentMode = .move
                }
                parent.isDragging = true
                parent.dragOffset = .zero
                parent.dragMode = currentMode
                onDragBegan?(currentMode)

            case .changed:
                let offset = DragOffset(
                    x: location.x - initialPoint.x,
                    y: location.y - initialPoint.y
                )
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
    var onTap: (() -> Void)? = nil
    var onDragEnded: ((DragOffset) -> Void)? = nil
    var onResizeTopEnded: ((CGFloat) -> Void)? = nil    // Y offset for top edge
    var onResizeBottomEnded: ((CGFloat) -> Void)? = nil // Y offset for bottom edge

    @State private var isDragging = false
    @State private var dragOffset: DragOffset = .zero
    @State private var dragMode: EventDragMode = .move

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isDragEnabled: Bool {
        onDragEnded != nil || onResizeTopEnded != nil || onResizeBottomEnded != nil
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(style.fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(style.strokeOpacity), lineWidth: style.strokeWidth)
            )
            .scaleEffect(isDragging && dragMode == .move ? 1.05 : 1.0)
            .shadow(radius: isDragging ? 8 : 0)
            .offset(x: dragMode == .move ? dragOffset.x : 0,
                    y: dragMode == .move ? dragOffset.y : 0)
            .contentShape(Rectangle())
            .overlay {
                if isDragEnabled {
                    EventBlockDragGesture(
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
            .animation(.easeInOut(duration: 0.15), value: isDragging)
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

                    if style.showTimeRange, let range = displayRange {
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
