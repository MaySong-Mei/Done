//
//  EventGridContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI
import UIKit

struct EventGridContentView: View {
    let events: [Event]
    @Binding var dragState: DragState?
    @Binding var selectedEvent: Event?
    @Binding var addToCalendarEvent: Event?
    @Binding var longPressingEventID: UUID?
    @Binding var shakeTriggers: [UUID: CGFloat]
    @Binding var isDraggingEvent: Bool

    let shouldBeginDrag: (UUID) -> Bool
    let bringToFront: (UUID) -> Void
    let beginDrag: (PositionedEvent) -> Void
    let updateDrag: (UUID, CGSize) -> Void
    let endDrag: (PositionedEvent, CGSize, CGPoint, CGFloat) -> Void
    let zIndex: (UUID) -> Double

    var body: some View {
        GeometryReader { proxy in
            let columnsCount = EventGridLayout.columnsCount
            let horizontalPadding: CGFloat = 16
            let verticalPadding: CGFloat = 12
            let availableWidth = proxy.size.width - horizontalPadding * 2
            let cellSize = max(8, availableWidth / CGFloat(columnsCount))
            let placedEvents = positionedEvents(from: events)
            let maxRow = placedEvents.map { $0.gridY + $0.spanRows }.max() ?? 0
            let extraRows = 50
            let minRows = 50
            let contentRows = max(minRows, maxRow + extraRows)
            let contentHeight = max(
                proxy.size.height,
                CGFloat(contentRows) * cellSize + verticalPadding * 2
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
                            GridDotsView(
                                columns: columnsCount,
                                rows: contentRows,
                                cellSize: cellSize
                            )
                            .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)
                            ForEach(placedEvents) { placed in
                                let height = cellSize * CGFloat(placed.spanRows)
                                let width = cellSize * CGFloat(placed.spanColumns)
                                let dragOffset = dragState?.eventID == placed.event.id ? (dragState?.translation ?? .zero) : .zero
                                let baseX = CGFloat(placed.gridX) * cellSize
                                let baseY = CGFloat(placed.gridY) * cellSize

                                ZStack {
                                    EventCardView(event: placed.event, availableHeight: height)
                                        .frame(width: width, height: height)
                                        .scaleEffect(longPressingEventID == placed.event.id ? 0.98 : 1.0)
                                        .modifier(ShakeEffect(animatableData: shakeTriggers[placed.event.id, default: 0]))
                                        .animation(.easeOut(duration: 0.2), value: longPressingEventID == placed.event.id)
                                    UIKitDragGestureView(
                                        minimumPressDuration: 0.3,
                                        shouldBegin: {
                                            shouldBeginDrag(placed.event.id)
                                        },
                                        onTap: {
                                            bringToFront(placed.event.id)
                                            selectedEvent = placed.event
                                        },
                                        onPanBegan: {
                                            bringToFront(placed.event.id)
                                            beginDrag(placed)
                                        },
                                        onPanChanged: { translation in
                                            updateDrag(placed.event.id, translation)
                                        },
                                        onPanEnded: { translation, endLocation in
                                            endDrag(placed, translation, endLocation, cellSize)
                                        }
                                    )
                                }
                                .frame(width: width, height: height)
                                .overlay(alignment: .bottomTrailing) {
                                    Button {
                                        addToCalendarEvent = placed.event
                                    } label: {
                                        Image(systemName: "calendar.badge.plus")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Add to calendar")
                                    .padding(8)
                                }
                                .position(
                                    x: baseX + width * 0.5 + dragOffset.width,
                                    y: baseY + height * 0.5 + dragOffset.height
                                )
                                .scaleEffect(dragState?.eventID == placed.event.id ? 1.03 : 1.0)
                                .shadow(
                                    color: .black.opacity(dragState?.eventID == placed.event.id ? 0.2 : 0.08),
                                    radius: dragState?.eventID == placed.event.id ? 12 : 4,
                                    x: 0,
                                    y: dragState?.eventID == placed.event.id ? 6 : 2
                                )
                                .animation(
                                    .spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1),
                                    value: dragState?.eventID == placed.event.id
                                )
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.45)
                                        .onChanged { _ in
                                            guard !isDraggingEvent else { return }
                                            if longPressingEventID != placed.event.id {
                                                longPressingEventID = placed.event.id
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            }
                                        }
                                        .onEnded { _ in
                                            guard longPressingEventID == placed.event.id else { return }
                                            longPressingEventID = nil
                                            withAnimation(.linear(duration: 0.35)) {
                                                shakeTriggers[placed.event.id, default: 0] += 1
                                            }
                                        }
                                )
                                .zIndex(zIndex(placed.event.id))
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
