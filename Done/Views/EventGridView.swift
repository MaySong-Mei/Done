//
//  EventGridView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import UIKit

struct EventGridView: View {
    let events: [Event]
    @EnvironmentObject private var store: EventStore
    @State private var dragState: DragState?

    var body: some View {
        GeometryReader { proxy in
            let columnsCount = EventGridLayout.columnsCount
            let horizontalPadding: CGFloat = 16
            let verticalPadding: CGFloat = 12
            let availableWidth = proxy.size.width - horizontalPadding * 2
            let cellSize = max(8, availableWidth / CGFloat(columnsCount))
            let placedEvents = positionedEvents(from: events)
            let maxRow = placedEvents.map { $0.gridY + $0.spanRows }.max() ?? 0
            let contentHeight = max(
                proxy.size.height,
                CGFloat(maxRow) * cellSize + verticalPadding * 2
            )

            Group {
                if events.isEmpty {
                    EmptyStateView(
                        title: "No events",
                        systemImage: "checklist"
                    )
                } else {
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            ForEach(placedEvents) { placed in
                                let height = cellSize * CGFloat(placed.spanRows)
                                let width = cellSize * CGFloat(placed.spanColumns)
                                let dragOffset = dragState?.eventID == placed.event.id ? (dragState?.translation ?? .zero) : .zero
                                let baseX = CGFloat(placed.gridX) * cellSize
                                let baseY = CGFloat(placed.gridY) * cellSize

                                ZStack {
                                    EventCardView(event: placed.event)
                                        .frame(width: width, height: height)
                                    UIKitDragGestureView(
                                        minimumPressDuration: 0.3,
                                        shouldBegin: {
                                            shouldBeginDrag(for: placed.event.id)
                                        },
                                        onPanBegan: {
                                            beginDrag(for: placed)
                                        },
                                        onPanChanged: { translation in
                                            updateDrag(for: placed.event.id, translation: translation)
                                        },
                                        onPanEnded: { translation, _ in
                                            endDrag(
                                                for: placed,
                                                translation: translation,
                                                cellSize: cellSize
                                            )
                                        }
                                    )
                                }
                                .frame(width: width, height: height)
                                .position(
                                    x: baseX + width * 0.5 + dragOffset.width,
                                    y: baseY + height * 0.5 + dragOffset.height
                                )
                                .zIndex(dragState?.eventID == placed.event.id ? 1 : 0)
                            }
                        }
                        .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                    }
                }
            }
        }
    }
}

private struct DragState {
    let eventID: UUID
    let initialGridX: Int
    let initialGridY: Int
    let spanColumns: Int
    let spanRows: Int
    var translation: CGSize
}

private extension EventGridView {
    func shouldBeginDrag(for eventID: UUID) -> Bool {
        dragState == nil || dragState?.eventID == eventID
    }

    func beginDrag(for placed: PositionedEvent) {
        guard shouldBeginDrag(for: placed.event.id) else { return }
        dragState = DragState(
            eventID: placed.event.id,
            initialGridX: placed.gridX,
            initialGridY: placed.gridY,
            spanColumns: placed.spanColumns,
            spanRows: placed.spanRows,
            translation: .zero
        )
    }

    func updateDrag(for eventID: UUID, translation: CGSize) {
        guard var current = dragState, current.eventID == eventID else { return }
        current.translation = translation
        dragState = current
    }

    func endDrag(for placed: PositionedEvent, translation: CGSize, cellSize: CGFloat) {
        guard let dragState, dragState.eventID == placed.event.id else { return }
        let snapped = snappedPosition(for: dragState, translation: translation, cellSize: cellSize)
        updateEvent(placed.event, gridX: snapped.x, gridY: snapped.y)
        self.dragState = nil
    }

    func snappedPosition(
        for dragState: DragState,
        translation: CGSize,
        cellSize: CGFloat
    ) -> (x: Int, y: Int) {
        let deltaColumns = Int(round(translation.width / cellSize))
        let deltaRows = Int(round(translation.height / cellSize))
        let maxX = max(0, EventGridLayout.columnsCount - dragState.spanColumns)
        let snappedX = min(max(0, dragState.initialGridX + deltaColumns), maxX)
        let snappedY = max(0, dragState.initialGridY + deltaRows)
        return (x: snappedX, y: snappedY)
    }

    func updateEvent(_ event: Event, gridX: Int, gridY: Int) {
        guard event.gridX != gridX || event.gridY != gridY else { return }
        var updated = event
        updated.gridX = gridX
        updated.gridY = gridY
        store.update(updated)
    }
}

private struct UIKitDragGestureView: UIViewRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: () -> Bool
        var onBegan: () -> Void
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize, CGPoint) -> Void

        private weak var longPress: UILongPressGestureRecognizer?
        private weak var scrollView: UIScrollView?
        private weak var referenceView: UIView?

        private var startPoint: CGPoint = .zero

        init(
            shouldBegin: @escaping () -> Bool,
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGSize) -> Void,
            onEnded: @escaping (CGSize, CGPoint) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(_ recognizer: UILongPressGestureRecognizer, in view: UIView) {
            self.longPress = recognizer

            if scrollView == nil {
                scrollView = view.findSuperview(of: UIScrollView.self)
            }
            if let scrollView {
                scrollView.panGestureRecognizer.require(toFail: recognizer)
            }
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }

            let ref = referenceView ?? view.window ?? scrollView ?? view
            referenceView = ref

            let location = recognizer.location(in: ref)

            switch recognizer.state {
            case .began:
                guard shouldBegin() else {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                startPoint = location
                onBegan()

            case .changed:
                let t = CGSize(width: location.x - startPoint.x, height: location.y - startPoint.y)
                onChanged(t)

            case .ended, .cancelled, .failed:
                let t = CGSize(width: location.x - startPoint.x, height: location.y - startPoint.y)
                onEnded(t, .zero)
                referenceView = nil

            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            shouldBegin()
        }
    }

    let minimumPressDuration: TimeInterval
    let shouldBegin: () -> Bool
    let onPanBegan: () -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: (CGSize, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldBegin: shouldBegin,
            onBegan: onPanBegan,
            onChanged: onPanChanged,
            onEnded: onPanEnded
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        longPress.minimumPressDuration = minimumPressDuration
        longPress.allowableMovement = 1000
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator

        view.addGestureRecognizer(longPress)
        context.coordinator.attach(longPress, in: view)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onBegan = onPanBegan
        context.coordinator.onChanged = onPanChanged
        context.coordinator.onEnded = onPanEnded
    }
}

private extension UIView {
    func findSuperview<T: UIView>(of type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }
}

struct CalendarPlaceholderView: View {
    var body: some View {
        EmptyStateView(
            title: "Calendar coming soon",
            systemImage: "calendar.badge.clock"
        )
    }
}

struct CreateEventPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @State private var title = ""
    @State private var selectedType: EventTypeOption = .study

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Enter title", text: $title)
                        .textInputAutocapitalization(.sentences)
                }
                Section("Type") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(EventTypeOption.allCases) { option in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 10, height: 10)
                                Text(option.title)
                            }
                            .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let event = Event(title: trimmedTitle, type: selectedType.rawValue)
                        store.addWithAutoPlacement(event)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private enum EventTypeOption: String, CaseIterable, Identifiable {
    case study = "Study"
    case work = "Work"
    case exercise = "Exercise"
    case sleep = "Sleep"

    var id: String { rawValue }
    var title: String { rawValue }

    var color: Color {
        switch self {
        case .study:
            return .green
        case .work:
            return .blue
        case .exercise:
            return .yellow
        case .sleep:
            return .purple
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PositionedEvent: Identifiable {
    let event: Event
    let gridX: Int
    let gridY: Int
    let spanColumns: Int
    let spanRows: Int

    var id: UUID { event.id }
}

private func positionedEvents(from events: [Event]) -> [PositionedEvent] {
    events.compactMap { event in
        guard let x = event.gridX, let y = event.gridY else { return nil }
        return PositionedEvent(
            event: event,
            gridX: x,
            gridY: y,
            spanColumns: EventGridLayout.spanColumns(for: event),
            spanRows: EventGridLayout.spanRows(for: event)
        )
    }
}
