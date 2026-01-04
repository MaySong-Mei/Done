//
//  TimelineEventBlockView.swift
//  Done
//
//  Created by Shiqi Liu on 1/3/26.
//

import SwiftUI
import Combine

struct TimelineEventBlockView: View {
    let entry: TimeEntry
    let renderStart: Date
    let renderEnd: Date
    let hourHeight: CGFloat
    let availableWidth: CGFloat
    let columnWidth: CGFloat
    let showsLabels: Bool
    let type: TimelineEventType
    let currentDropTarget: DropTarget?
    let carryDuration: TimeInterval?
    let onDragStateChanged: (Bool) -> Void
    let onMove: (TimeEntry) -> Void
    let onCarryBegan: (CGPoint, CGSize) -> Void
    let onCarryChanged: (CGPoint) -> Void
    let onCarryEnded: () -> Void
    @State private var dragPhase: LongPressDragPhase = .inactive
    @State private var hasBegunCarry = false
    @State private var eventFrame: CGRect = .zero
    @State private var carryAnchorOffset: CGSize = .zero
    private let cornerRadius: CGFloat = 6

    var body: some View {
        if renderEnd > renderStart {
            let startY = yPosition(for: renderStart)
            let height = max(1, height(from: renderStart, to: renderEnd))
            let contentWidth = max(1, availableWidth - 2)
            let contentSize = CGSize(width: contentWidth, height: height)
            let displayDelta = isCarrying ? 0 : dragTimeDeltaSeconds
            let displayStart = renderStart.addingTimeInterval(displayDelta)
            let displayEnd = renderEnd.addingTimeInterval(displayDelta)
            let visualTranslation = isCarrying ? .zero : dragTranslation
            let dragScale: CGFloat = isCarrying ? 1 : (isDragActive ? 1.03 : 1)
            let dragShadowOpacity = isCarrying ? 0 : (isDragActive ? 0.18 : 0)
            let dragShadowRadius: CGFloat = isCarrying ? 0 : (isDragActive ? 8 : 0)
            let dragShadowYOffset: CGFloat = isCarrying ? 0 : (isDragActive ? 3 : 0)
            let dragStrokeOpacity = isCarrying ? 0 : (isDragActive ? 0.35 : 0)

            let content = TimelineEventContentView(
                entry: entry,
                displayStart: displayStart,
                displayEnd: displayEnd,
                height: height,
                width: contentWidth,
                showsLabels: showsLabels,
                type: type,
                cornerRadius: cornerRadius
            )
            .scaleEffect(dragScale)
            .shadow(
                color: Color.black.opacity(dragShadowOpacity),
                radius: dragShadowRadius,
                x: 0,
                y: dragShadowYOffset
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(dragStrokeOpacity), lineWidth: 1)
            )
            .opacity(isCarrying ? 0.2 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragActive)
            .offset(
                x: 1 + visualTranslation.width,
                y: startY + visualTranslation.height
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: EventFramePreferenceKey.self, value: proxy.frame(in: .global))
                }
            )
            .onPreferenceChange(EventFramePreferenceKey.self) { eventFrame = $0 }

            if type == .completed || type == .draft {
                content
                    .longPressDragGesture(phase: $dragPhase) { translation in
                        applyMove(translation: translation)
                    }
                    .onChange(of: isDragActive) { _, isActive in
                        onDragStateChanged(isActive)
                    }
                    .onChange(of: dragPhase) { _, newValue in
                        handleCarryPhaseChange(newValue, eventFrame: eventFrame, contentSize: contentSize)
                    }
            } else {
                content
            }
        }
    }

    private func yPosition(for date: Date) -> CGFloat {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let totalMinutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return CGFloat(totalMinutes / 60.0) * hourHeight
    }

    private func height(from start: Date, to end: Date) -> CGFloat {
        let duration = end.timeIntervalSince(start) / 3600.0
        return CGFloat(duration) * hourHeight
    }

    private var dragTranslation: CGSize {
        dragPhase.translation
    }

    private var isDragActive: Bool {
        dragPhase.isActive
    }

    private var isCarrying: Bool {
        if case .dragging = dragPhase {
            return true
        }
        return false
    }

    private var dragTimeDeltaSeconds: TimeInterval {
        let hoursDelta = dragTranslation.height / hourHeight
        return TimeInterval(hoursDelta * 3600)
    }

    private func applyMove(translation: CGSize) {
        guard let endTime = entry.endTime else { return }

        if let currentDropTarget {
            let duration = carryDuration ?? endTime.timeIntervalSince(entry.startTime)
            let updatedStart = currentDropTarget.snappedStartTime
            let updatedEnd = updatedStart.addingTimeInterval(duration)
            let updatedEntry = TimeEntry(
                id: entry.id,
                templateId: entry.templateId,
                templateName: entry.templateName,
                startTime: updatedStart,
                endTime: updatedEnd,
                colorHex: entry.colorHex,
                syncedToCalendar: entry.syncedToCalendar,
                calendarEventId: entry.calendarEventId,
                type: entry.type
            )
            onMove(updatedEntry)
            return
        }

        let hoursDelta = translation.height / hourHeight
        let timeDelta = TimeInterval(hoursDelta * 3600)
        let dayDelta = Int(round(translation.width / max(1, columnWidth)))

        let calendar = Calendar.current
        let startWithTime = entry.startTime.addingTimeInterval(timeDelta)
        let endWithTime = endTime.addingTimeInterval(timeDelta)
        let updatedStart = calendar.date(byAdding: .day, value: dayDelta, to: startWithTime) ?? startWithTime
        let updatedEnd = calendar.date(byAdding: .day, value: dayDelta, to: endWithTime) ?? endWithTime

        let updatedEntry = TimeEntry(
            id: entry.id,
            templateId: entry.templateId,
            templateName: entry.templateName,
            startTime: updatedStart,
            endTime: updatedEnd,
            colorHex: entry.colorHex,
            syncedToCalendar: entry.syncedToCalendar,
            calendarEventId: entry.calendarEventId,
            type: entry.type
        )
        onMove(updatedEntry)
    }

    private func handleCarryPhaseChange(
        _ phase: LongPressDragPhase,
        eventFrame: CGRect,
        contentSize: CGSize
    ) {
        switch phase {
        case .dragging(_, let location, let startLocation):
            guard eventFrame != .zero else { return }
            if !hasBegunCarry {
                hasBegunCarry = true
                let anchorOffset = CGSize(width: startLocation.x, height: startLocation.y)
                carryAnchorOffset = anchorOffset
                let anchorScreenPoint = CGPoint(
                    x: eventFrame.minX + startLocation.x,
                    y: eventFrame.minY + startLocation.y
                )
                onCarryBegan(anchorScreenPoint, anchorOffset)
            }
            let anchorOffset = carryAnchorOffset
            let screenLocation = CGPoint(
                x: eventFrame.minX + location.x,
                y: eventFrame.minY + location.y
            )
            let ghostTopLeft = CGPoint(
                x: screenLocation.x - anchorOffset.width,
                y: screenLocation.y - anchorOffset.height
            )
            let ghostCenter = CGPoint(
                x: ghostTopLeft.x + contentSize.width / 2,
                y: ghostTopLeft.y + contentSize.height / 2
            )
            onCarryChanged(ghostCenter)
        case .inactive:
            if hasBegunCarry {
                hasBegunCarry = false
                carryAnchorOffset = .zero
                onCarryEnded()
            }
        case .pressing:
            break
        }
    }
}

private struct EventFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

@MainActor
final class TimelineEventProvider: ObservableObject {
    @Published var entries: [TimeEntry] = []

    func update(entries: [TimeEntry]) {
        self.entries = entries
    }

    func entriesForDate(_ date: Date) -> [TimeEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!

        return entries
            .filter { entry in
                guard let endTime = entry.endTime else { return true }
                return entry.startTime < end && endTime > start
            }
            .sorted { $0.startTime < $1.startTime }
    }

    func type(for entry: TimeEntry) -> TimelineEventType {
        entry.type
    }
}

struct DemoCalendarDragView: View {
    @State private var demoDay: Date
    @State private var entry: TimeEntry
    @State private var isDragging = false
    private let hourHeight: CGFloat = 60
    private let timeAxisWidth: CGFloat = 30
    private var totalHeight: CGFloat { 24 * hourHeight }

    init() {
        let baseDay = Calendar.current.startOfDay(for: Date())
        _demoDay = State(initialValue: baseDay)
        _entry = State(initialValue: DemoCalendarDragView.makeSampleEntry(on: baseDay))
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                GeometryReader { proxy in
                    let contentWidth = max(0, proxy.size.width - timeAxisWidth)
                    HStack(spacing: 0) {
                        timeAxis
                            .frame(width: timeAxisWidth, alignment: .trailing)

                        ZStack(alignment: .topLeading) {
                            timelineGrid(width: contentWidth)
                            eventBlock(width: contentWidth)
                        }
                        .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
                    }
                    .frame(height: totalHeight, alignment: .top)
                }
                .frame(height: totalHeight)
            }
            .scrollDisabled(isDragging)
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Long-Press Move Demo")
                .font(.headline)
            Text("Hold for 1 second, then drag to move it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%d", hour))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .center)
            }
        }
        .padding(.trailing, 4)
    }

    private func timelineGrid(width: CGFloat) -> some View {
        Canvas { context, size in
            let centerOffset = hourHeight / 2
            for hour in 0..<24 {
                let y = CGFloat(hour) * hourHeight + centerOffset
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(
                    path,
                    with: .color(.gray.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                )
            }
        }
        .frame(width: width, height: totalHeight)
    }

    @ViewBuilder
    private func eventBlock(width: CGFloat) -> some View {
        let range = renderRange(for: entry)
        TimelineEventBlockView(
            entry: entry,
            renderStart: range.start,
            renderEnd: range.end,
            hourHeight: hourHeight,
            availableWidth: width,
            columnWidth: width,
            showsLabels: true,
            type: .completed,
            currentDropTarget: nil,
            carryDuration: nil,
            onDragStateChanged: { isDragging = $0 },
            onMove: { updatedEntry in
                entry = clampedToDay(updatedEntry)
            },
            onCarryBegan: { _, _ in },
            onCarryChanged: { _ in },
            onCarryEnded: {}
        )
    }

    private func renderRange(for entry: TimeEntry) -> (start: Date, end: Date) {
        let dayStart = demoDay
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? entry.startTime
        let entryEnd = entry.endTime ?? entry.startTime.addingTimeInterval(3600)
        return (max(entry.startTime, dayStart), min(entryEnd, dayEnd))
    }

    private func clampedToDay(_ updatedEntry: TimeEntry) -> TimeEntry {
        var clamped = updatedEntry
        let dayStart = demoDay
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? updatedEntry.startTime
        let entryEnd = updatedEntry.endTime ?? updatedEntry.startTime.addingTimeInterval(3600)
        let duration = entryEnd.timeIntervalSince(updatedEntry.startTime)
        var newStart = updatedEntry.startTime
        var newEnd = entryEnd

        if newStart < dayStart {
            newStart = dayStart
            newEnd = dayStart.addingTimeInterval(duration)
        }

        if newEnd > dayEnd {
            newEnd = dayEnd
            newStart = dayEnd.addingTimeInterval(-duration)
        }

        clamped.startTime = newStart
        clamped.endTime = newEnd
        return clamped
    }

    private static func makeSampleEntry(on dayStart: Date) -> TimeEntry {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: 11, to: dayStart) ?? start.addingTimeInterval(7200)
        return TimeEntry(
            templateId: UUID(),
            templateName: "Focus Block",
            startTime: start,
            endTime: end,
            colorHex: "#4A90E2",
            syncedToCalendar: false,
            calendarEventId: nil,
            type: .completed
        )
    }
}

#Preview {
    DemoCalendarDragView()
}
