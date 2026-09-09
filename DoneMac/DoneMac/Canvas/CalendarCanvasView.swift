//
//  CalendarCanvasView.swift
//  DoneMac
//
//  The SwiftUI applier over CanvasFrame, plus gesture translation for the
//  DragController. Everything geometric is positioning of pre-computed
//  fractions; gestures reduce to (dayKey, fraction) pairs before they
//  reach the controller, so the controller stays view-free and testable.
//

import SwiftUI

struct CalendarCanvasView: View {
    let surface: CalendarSurfaceModel
    let drag: DragController
    var onEditEvent: (UUID) -> Void = { _ in }
    var hourHeight: CGFloat = 44

    private var contentHeight: CGFloat { hourHeight * 24 }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            allDayRow
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TimeAxisApplier()
                        .frame(width: 46, height: contentHeight)
                    ForEach(Array(surface.frame.days.enumerated()), id: \.element.key) { index, day in
                        DayColumnView(
                            day: day,
                            nowLine: surface.frame.nowLine?.dayKey == day.key
                                ? surface.frame.nowLine : nil,
                            overlay: drag.overlay?.dayKey == day.key ? drag.overlay : nil,
                            onDragBegan: { fraction in beginDrag(day: day, fraction: fraction) },
                            onDragMoved: { fraction, dayDelta in
                                moveDrag(dayIndex: index, dayDelta: dayDelta, fraction: fraction)
                            },
                            onDragEnded: { fraction, dayDelta in
                                endDrag(dayIndex: index, dayDelta: dayDelta, fraction: fraction)
                            },
                            onDoubleClickBlock: { eventID in onEditEvent(eventID) }
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: contentHeight)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.separator).frame(width: 1)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gesture reduction

    /// Bottom strip of a block that grabs as a resize handle, as a
    /// fraction of the day.
    private static let resizeGripDayFraction: CGFloat = 8.0 / (44 * 24)

    private func beginDrag(day: DayModel, fraction: CGFloat) {
        guard !drag.isDragging else { return }
        // Topmost block under the pointer wins; its bottom strip resizes.
        let hit = day.blocks
            .filter { fraction >= $0.yFraction && fraction <= $0.yFraction + $0.heightFraction }
            .max { $0.zIndex < $1.zIndex }
        guard let hit,
              let event = surfaceEvent(id: hit.eventID) else {
            drag.beginCreate(day: day.key, fraction: fraction)
            return
        }
        let bottomGrip = hit.yFraction + hit.heightFraction - Self.resizeGripDayFraction
        if fraction >= bottomGrip {
            drag.beginResizeBottom(event: event)
        } else {
            drag.beginMove(event: event, grabFraction: fraction - hit.yFraction)
        }
    }

    private func moveDrag(dayIndex: Int, dayDelta: Int, fraction: CGFloat) {
        guard drag.isDragging else { return }
        drag.updateMove(pointerDay: pointerDay(dayIndex: dayIndex, dayDelta: dayDelta), pointerFraction: fraction)
        drag.updateResizeBottom(pointerFraction: fraction)
        drag.updateCreate(pointerFraction: fraction)
    }

    private func endDrag(dayIndex: Int, dayDelta: Int, fraction: CGFloat) {
        guard drag.isDragging else { return }
        let now = Date()
        drag.endMove(
            pointerDay: pointerDay(dayIndex: dayIndex, dayDelta: dayDelta),
            pointerFraction: fraction, now: now
        )
        drag.endResizeBottom(pointerFraction: fraction, now: now)
        drag.endCreate(pointerFraction: fraction, now: now)
        if let created = drag.pendingComposerEventID {
            drag.pendingComposerEventID = nil
            onEditEvent(created)
        }
    }

    private func pointerDay(dayIndex: Int, dayDelta: Int) -> DayKey {
        let keys = surface.windowKeys
        let clamped = min(max(0, dayIndex + dayDelta), keys.count - 1)
        return keys.isEmpty ? surface.anchorDay : keys[clamped]
    }

    private func surfaceEvent(id: UUID) -> Event? {
        surfaceStore(surface).calendarEvents.first { $0.id == id }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 46, height: 1)
            ForEach(surface.frame.days, id: \.key) { day in
                Text(String(format: "%d/%d", day.key.month, day.key.day))
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var allDayRow: some View {
        if surface.frame.days.contains(where: { !$0.allDayChips.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: 46, height: 1)
                ForEach(surface.frame.days, id: \.key) { day in
                    VStack(spacing: 2) {
                        ForEach(day.allDayChips) { chip in
                            Text(chip.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 1)
                                .background(chip.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// The surface deliberately hides its store from views; gesture hit-tests
/// need the Event value to hand the controller. One narrow, documented
/// seam instead of views importing the store type everywhere.
@MainActor
private func surfaceStore(_ surface: CalendarSurfaceModel) -> MacEventStore {
    surface.storeForGestures
}

struct DayColumnView: View {
    let day: DayModel
    let nowLine: NowLineModel?
    var overlay: DragController.Overlay?
    var onDragBegan: (CGFloat) -> Void = { _ in }
    var onDragMoved: (CGFloat, Int) -> Void = { _, _ in }
    var onDragEnded: (CGFloat, Int) -> Void = { _, _ in }
    var onDoubleClickBlock: (UUID) -> Void = { _ in }

    @State private var dragActive = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                hourGrid(height: size.height)
                ForEach(day.blocks) { block in
                    blockView(block)
                        .frame(
                            width: max(1, size.width * block.widthFraction - 2),
                            height: max(6, size.height * block.heightFraction - 1)
                        )
                        .offset(
                            x: size.width * block.xOffsetFraction + 1,
                            y: size.height * block.yFraction
                        )
                        .zIndex(block.zIndex)
                        .onTapGesture(count: 2) { onDoubleClickBlock(block.eventID) }
                }
                if let overlay {
                    overlayView(overlay)
                        .frame(
                            width: max(1, size.width - 4),
                            height: max(6, size.height * overlay.heightFraction)
                        )
                        .offset(x: 2, y: size.height * overlay.yFraction)
                        .zIndex(10_000)
                }
                if let nowLine {
                    Rectangle()
                        .fill(.red)
                        .frame(height: 1)
                        .offset(y: size.height * nowLine.yFraction)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        let fraction = fractionOf(value.location.y, height: size.height)
                        if !dragActive {
                            dragActive = true
                            onDragBegan(fractionOf(value.startLocation.y, height: size.height))
                        }
                        onDragMoved(fraction, dayDelta(value.location.x, width: size.width))
                    }
                    .onEnded { value in
                        dragActive = false
                        onDragEnded(
                            fractionOf(value.location.y, height: size.height),
                            dayDelta(value.location.x, width: size.width)
                        )
                    }
            )
        }
        .clipped()
    }

    private func fractionOf(_ y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return clamp(y / height, 0, 1)
    }

    private func dayDelta(_ x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int(floor(x / width))
    }

    private func hourGrid(height: CGFloat) -> some View {
        ForEach(1..<24, id: \.self) { hour in
            Rectangle()
                .fill(.separator.opacity(0.5))
                .frame(height: 1)
                .offset(y: height * CGFloat(hour) / 24)
        }
    }

    private func overlayView(_ overlay: DragController.Overlay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(overlay.title.isEmpty ? "New event" : overlay.title)
                .font(.caption2.bold())
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.blue, style: StrokeStyle(lineWidth: 1, dash: overlay.isCreate ? [4] : []))
        )
        .allowsHitTesting(false)
    }

    private func blockView(_ block: DayBlockModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(block.title.isEmpty ? "Untitled" : block.title)
                .font(.caption2)
                .lineLimit(2)
            if block.heightFraction > 0.035 {
                Text(block.timeText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(block.color.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(block.color, style: block.isTodo
                    ? StrokeStyle(lineWidth: 1)
                    : StrokeStyle(lineWidth: 0.5))
        )
    }
}
