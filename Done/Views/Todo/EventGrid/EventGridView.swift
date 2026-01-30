//
//  EventGridView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventGridView: View {
    let events: [Event]
    @EnvironmentObject var store: EventStore
    @State var dragState: DragState?
    @State private var selectedEvent: Event?
    @State private var addToCalendarEvent: Event?
    @State var zOrder: [UUID] = []
    @State var longPressingEventID: UUID?
    @State private var shakeTriggers: [UUID: CGFloat] = [:]
    @Binding var isDraggingEvent: Bool
    @Binding var deleteZoneFrame: CGRect

    var body: some View {
        GeometryReader { proxy in
            let columnsCount = EventGridLayout.columnsCount
            let horizontalPadding: CGFloat = 16
            let verticalPadding: CGFloat = 12
            let availableWidth = proxy.size.width - horizontalPadding * 2
            let cellSize = max(8, availableWidth / CGFloat(columnsCount))
            let placedEvents = PositionedEvent.from(events)
            let maxRow = placedEvents.map { $0.gridY + $0.spanRows }.max() ?? 0
            let contentRows = max(50, maxRow + 50)
            let contentHeight = max(
                proxy.size.height,
                CGFloat(contentRows) * cellSize + verticalPadding * 2
            )

            Group {
                if events.isEmpty {
                    EmptyStateView(title: "No events", systemImage: "checklist")
                } else {
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            GridDotsView(columns: columnsCount, rows: contentRows, cellSize: cellSize)
                                .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)

                            dragGhostView(placedEvents: placedEvents, cellSize: cellSize, columnsCount: columnsCount)
                                .allowsHitTesting(false)
                                .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)

                            ForEach(placedEvents) { placed in
                                eventCardView(placed: placed, cellSize: cellSize)
                            }
                        }
                        .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                    }
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            EditEventView(event: event)
        }
        .sheet(item: $addToCalendarEvent) { event in
            AddToCalendarView(event: event)
        }
        .onAppear {
            syncZOrder(with: events)
        }
        .onChange(of: events) { updatedEvents in
            syncZOrder(with: updatedEvents)
        }
    }
}

// MARK: - Sub Views

private extension EventGridView {

    @ViewBuilder
    func dragGhostView(placedEvents: [PositionedEvent], cellSize: CGFloat, columnsCount: Int) -> some View {
        if let dragState,
           let placed = placedEvents.first(where: { $0.event.id == dragState.eventID }) {
            let width = cellSize * CGFloat(placed.spanColumns)
            let height = cellSize * CGFloat(placed.spanRows)
            let snapped = dragState.snappedPosition(
                translation: dragState.translation,
                cellSize: cellSize,
                columnsCount: columnsCount
            )
            let targetRect = CGRect(
                x: CGFloat(snapped.x) * cellSize,
                y: CGFloat(snapped.y) * cellSize,
                width: width,
                height: height
            )
            let color = EventTypeTemplateStore.color(for: placed.event.type)
            let snappedTranslation = CGSize(
                width: CGFloat(snapped.x - dragState.initialGridX) * cellSize,
                height: CGFloat(snapped.y - dragState.initialGridY) * cellSize
            )
            let dx = abs(dragState.translation.width - snappedTranslation.width)
            let dy = abs(dragState.translation.height - snappedTranslation.height)
            let isNearSnap = dx < 8 && dy < 8

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: targetRect.width, height: targetRect.height)
                    .position(x: targetRect.midX, y: targetRect.midY)
                if isNearSnap {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.55), lineWidth: 1)
                        .frame(width: targetRect.width, height: targetRect.height)
                        .position(x: targetRect.midX, y: targetRect.midY)
                }
            }
        }
    }

    func eventCardView(placed: PositionedEvent, cellSize: CGFloat) -> some View {
        let height = cellSize * CGFloat(placed.spanRows)
        let width = cellSize * CGFloat(placed.spanColumns)
        let dragOffset = dragState?.eventID == placed.event.id ? (dragState?.translation ?? .zero) : .zero
        let isDragging = dragState?.eventID == placed.event.id
        let baseGridX = isDragging ? (dragState?.initialGridX ?? placed.gridX) : placed.gridX
        let baseGridY = isDragging ? (dragState?.initialGridY ?? placed.gridY) : placed.gridY
        let baseX = CGFloat(baseGridX) * cellSize
        let baseY = CGFloat(baseGridY) * cellSize

        return ZStack {
            EventCardView(event: placed.event, availableHeight: height)
                .frame(width: width, height: height)
                .scaleEffect(longPressingEventID == placed.event.id ? 0.98 : 1.0)
                .modifier(ShakeEffect(animatableData: shakeTriggers[placed.event.id, default: 0]))
                .animation(.easeOut(duration: 0.2), value: longPressingEventID == placed.event.id)
            UIKitDragGestureView(
                minimumPressDuration: 0.3,
                shouldBegin: { self.shouldBeginDrag(for: placed.event.id) },
                onPanBegan: {
                    self.bringToFront(placed.event.id)
                    self.beginDrag(for: placed)
                },
                onPanChanged: { translation in self.updateDrag(for: placed.event.id, translation: translation) },
                onPanEnded: { translation, endLocation in
                    self.endDrag(for: placed, translation: translation, endLocation: endLocation, cellSize: cellSize)
                }
            )
        }
        .onTapGesture {
            bringToFront(placed.event.id)
            selectedEvent = placed.event
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
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .shadow(color: .black.opacity(0.08), radius: isDragging ? 5 : 4, x: 0.5, y: 0.5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1), value: isDragging)
        .position(
            x: baseX + width * 0.5 + dragOffset.width,
            y: baseY + height * 0.5 + dragOffset.height
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
        .zIndex(zIndex(for: placed.event.id))
    }
}
