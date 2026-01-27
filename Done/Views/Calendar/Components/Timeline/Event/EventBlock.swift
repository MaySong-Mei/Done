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

/// UIKit-based long press drag gesture that doesn't conflict with scroll.
struct LongPressDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.3
    var onDragChanged: ((DragOffset) -> Void)?
    var onDragEnded: ((DragOffset) -> Void)?
    @Binding var isDragging: Bool
    @Binding var dragOffset: DragOffset

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = minimumPressDuration
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: LongPressDragGesture
        var onDragChanged: ((DragOffset) -> Void)?
        var onDragEnded: ((DragOffset) -> Void)?
        private var initialPoint: CGPoint = .zero

        init(_ parent: LongPressDragGesture) {
            self.parent = parent
            self.onDragChanged = parent.onDragChanged
            self.onDragEnded = parent.onDragEnded
        }

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                initialPoint = location
                parent.isDragging = true
                parent.dragOffset = .zero
            case .changed:
                let offset = DragOffset(
                    x: location.x - initialPoint.x,
                    y: location.y - initialPoint.y
                )
                parent.dragOffset = offset
                onDragChanged?(offset)
            case .ended, .cancelled:
                let finalOffset = parent.dragOffset
                parent.isDragging = false
                parent.dragOffset = .zero
                onDragEnded?(finalOffset)
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
    var onDragChanged: ((DragOffset) -> Void)? = nil
    var onDragEnded: ((DragOffset) -> Void)? = nil

    @State private var isDragging = false
    @State private var dragOffset: DragOffset = .zero

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isDragEnabled: Bool { onDragEnded != nil }

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
            .scaleEffect(isDragging ? 1.05 : 1.0)
            .shadow(radius: isDragging ? 8 : 0)
            .offset(x: dragOffset.x, y: dragOffset.y)
            .contentShape(Rectangle())
            .overlay {
                if isDragEnabled {
                    LongPressDragGesture(
                        onDragChanged: onDragChanged,
                        onDragEnded: onDragEnded,
                        isDragging: $isDragging,
                        dragOffset: $dragOffset
                    )
                }
            }
            .onTapGesture { onTap?() }
            .animation(.easeInOut(duration: 0.15), value: isDragging)
    }

    @ViewBuilder
    private var content: some View {
        if showText {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if style.showTimeRange, let range = displayRange {
                    Text("\(Self.timeFormatter.string(from: range.start)) - \(Self.timeFormatter.string(from: range.end))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            Color.clear
        }
    }
}
