//
//  EventGridContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct EventGridContentView: View {
    let events: [Event]
    @Binding var dragState: DragState?
    @Binding var selectedEvent: Event?
    @Binding var addToCalendarEvent: Event?
    @Binding var longPressingEventID: UUID?
    @Binding var shakeTriggers: [UUID: CGFloat]
    @Binding var dragTrails: [UUID: [CGSize]]
    @Binding var dragTrailAlphas: [UUID: CGFloat]
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
                            Canvas { context, size in
                                    guard
                                        let dragState,
                                        let trail = dragTrails[dragState.eventID],
                                        let placed = placedEvents.first(where: { $0.event.id == dragState.eventID })
                                    else { return }

                                    let decay = dragTrailAlphas[dragState.eventID] ?? 0
                                    guard decay > 0 else { return }

                                    let baseGridX = dragState.initialGridX
                                    let baseGridY = dragState.initialGridY
                                    let width = cellSize * CGFloat(placed.spanColumns)
                                    let height = cellSize * CGFloat(placed.spanRows)
                                    let baseX = CGFloat(baseGridX) * cellSize
                                    let baseY = CGFloat(baseGridY) * cellSize
                                    let baseCenter = CGPoint(x: baseX + width * 0.5, y: baseY + height * 0.5)
                                    let currentCenter = CGPoint(
                                        x: baseCenter.x + dragState.translation.width,
                                        y: baseCenter.y + dragState.translation.height
                                    )
                                    let currentRect = CGRect(
                                        x: currentCenter.x - width * 0.5,
                                        y: currentCenter.y - height * 0.5,
                                        width: width,
                                        height: height
                                    )
                                    let color = EventTypeTemplateStore.color(for: placed.event.type)
                                    let cornerRadius: CGFloat = 10
                                    let eventSeed = abs(placed.event.id.hashValue)

                                    context.drawLayer { layer in
                                        var clipPath = Path()
                                        clipPath.addRect(CGRect(origin: .zero, size: size))
                                        clipPath.addRoundedRect(in: currentRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
                                        layer.clip(to: clipPath, style: .init(eoFill: true))

                                        for (index, sample) in trail.enumerated() {
                                            let factor = trail.count > 1
                                                ? CGFloat(index) / CGFloat(trail.count - 1)
                                                : 0
                                            let fade = pow(1 - factor, 1.6) * decay

                                            let sampleCenter = CGPoint(
                                                x: baseCenter.x + sample.width,
                                                y: baseCenter.y + sample.height
                                            )

                                            let prevSample = index > 0 ? trail[index - 1] : sample
                                            let velocity = CGSize(
                                                width: sample.width - prevSample.width,
                                                height: sample.height - prevSample.height
                                            )
                                            let speed = min(80, max(0.1, hypot(velocity.width, velocity.height)))
                                            let dir = CGPoint(x: velocity.width / speed, y: velocity.height / speed)
                                            let perp = CGPoint(x: -dir.y, y: dir.x)
                                            let speedBoost = min(1, speed / 40)

                                            let length = (6 + 20 * speedBoost) * (0.7 + 0.3 * fade)
                                            let thickness = max(1.6, 4.2 * fade)
                                            let opacity = 0.75 * fade * (0.6 + 0.4 * speedBoost)

                                            layer.translateBy(
                                                x: sampleCenter.x - dir.x * length * 0.4,
                                                y: sampleCenter.y - dir.y * length * 0.4
                                            )
                                            layer.rotate(by: Angle(radians: Double(atan2(dir.y, dir.x))))
                                            let streakRect = CGRect(
                                                x: -length * 0.5,
                                                y: -thickness * 0.5,
                                                width: length,
                                                height: thickness
                                            )
                                            layer.fill(
                                                Path(roundedRect: streakRect, cornerRadius: thickness * 0.5),
                                                with: .color(color.opacity(opacity))
                                            )
                                            layer.rotate(by: Angle(radians: -Double(atan2(dir.y, dir.x))))
                                            layer.translateBy(
                                                x: -(sampleCenter.x - dir.x * length * 0.4),
                                                y: -(sampleCenter.y - dir.y * length * 0.4)
                                            )

                                            if factor < 0.85 {
                                                let headSize = 2.6 * (0.6 + fade * 0.6)
                                                let headRect = CGRect(
                                                    x: sampleCenter.x - headSize * 0.5,
                                                    y: sampleCenter.y - headSize * 0.5,
                                                    width: headSize,
                                                    height: headSize
                                                )
                                                layer.fill(
                                                    Path(ellipseIn: headRect),
                                                    with: .color(color.opacity(min(1, opacity * 1.2)))
                                                )
                                            }

                                            let sparkleCount = Int((randomUnit(seed: eventSeed ^ (index &* 97)) * 3).rounded(.down))
                                            if sparkleCount > 0 {
                                                for sparkle in 0..<sparkleCount {
                                                    let seed = eventSeed &+ (index &+ 1) &* 131 &+ (sparkle &+ 1) &* 17
                                                    let spread = 2 + 4 * fade
                                                    let along = (randomUnit(seed: seed) * 6 - 3) * (1 - factor)
                                                    let across = (randomUnit(seed: seed &* 7) * 2.0 - 1.0) * spread
                                                    let point = CGPoint(
                                                        x: sampleCenter.x + dir.x * along + perp.x * across,
                                                        y: sampleCenter.y + dir.y * along + perp.y * across
                                                    )
                                                    let size = 1.1 + 0.9 * Double(randomUnit(seed: seed &* 13))
                                                    let rect = CGRect(
                                                        x: point.x - size * 0.5,
                                                        y: point.y - size * 0.5,
                                                        width: size,
                                                        height: size
                                                    )
                                                    layer.fill(
                                                        Path(ellipseIn: rect),
                                                        with: .color(color.opacity(opacity * 0.7))
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)
                            ForEach(placedEvents) { placed in
                                let height = cellSize * CGFloat(placed.spanRows)
                                let width = cellSize * CGFloat(placed.spanColumns)
                                let dragOffset = dragState?.eventID == placed.event.id ? (dragState?.translation ?? .zero) : .zero
                                let isDragging = dragState?.eventID == placed.event.id
                                let baseGridX = isDragging ? (dragState?.initialGridX ?? placed.gridX) : placed.gridX
                                let baseGridY = isDragging ? (dragState?.initialGridY ?? placed.gridY) : placed.gridY
                                let baseX = CGFloat(baseGridX) * cellSize
                                let baseY = CGFloat(baseGridY) * cellSize

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
                                .scaleEffect(isDragging ? 1.03 : 1.0)
                                .shadow(
                                    color: .black.opacity(isDragging ? 0.2 : 0.08),
                                    radius: isDragging ? 12 : 4,
                                    x: 0,
                                    y: isDragging ? 6 : 2
                                )
                                .animation(.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1), value: isDragging)
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

    private func randomUnit(seed: Int) -> CGFloat {
        var value = UInt32(truncatingIfNeeded: seed &* 1103515245 &+ 12345)
        value = 1103515245 &* value &+ 12345
        return CGFloat(value % 10_000) / 10_000
    }
}
