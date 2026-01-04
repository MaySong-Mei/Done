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
    let onDragStateChanged: (Bool) -> Void
    let onMove: (TimeEntry) -> Void
    @State private var dragPhase: LongPressDragPhase = .inactive
    private let cornerRadius: CGFloat = 6

    var body: some View {
        if renderEnd > renderStart {
            let startY = yPosition(for: renderStart)
            let height = max(1, height(from: renderStart, to: renderEnd))
            let displayStart = renderStart.addingTimeInterval(dragTimeDeltaSeconds)
            let displayEnd = renderEnd.addingTimeInterval(dragTimeDeltaSeconds)

            let content = eventContent(height: height, displayStart: displayStart, displayEnd: displayEnd)
                .scaleEffect(isDragActive ? 1.03 : 1)
                .shadow(color: Color.black.opacity(isDragActive ? 0.18 : 0), radius: isDragActive ? 8 : 0, x: 0, y: 3)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(isDragActive ? 0.35 : 0), lineWidth: 1)
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragActive)
                .offset(
                    x: 1 + dragTranslation.width,
                    y: startY + dragTranslation.height
                )

            if type == .completed || type == .draft {
                content
                    .longPressDragGesture(phase: $dragPhase) { translation in
                        applyMove(translation: translation)
                    }
                    .onChange(of: isDragActive) { _, isActive in
                        onDragStateChanged(isActive)
                    }
            } else {
                content
            }
        }
    }

    private func eventContent(height: CGFloat, displayStart: Date, displayEnd: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabels {
                Text(entry.templateName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(labelColor)
                    .lineLimit(1)

                if height > 40 {
                    Text(formatTimeRange(start: displayStart, end: displayEnd))
                        .font(.caption2)
                        .foregroundColor(labelColor.opacity(0.8))
                }
            }
        }
        .padding(8)
        .frame(width: max(1, availableWidth - 2), height: height, alignment: .topLeading)
        .background(eventBackground)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(hex: entry.colorHex) ?? .blue, lineWidth: type == .ongoing ? 0.8 : 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var eventBackground: some View {
        let base = Color(hex: entry.colorHex) ?? .blue
        switch type {
        case .completed, .empty:
            base
        case .ongoing, .draft:
            ActiveStripeFill(color: base)
        }
    }

    private var labelColor: Color {
        let base = Color(hex: entry.colorHex) ?? .blue
        return (type == .ongoing || type == .draft) ? base : .white
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

    private var dragTimeDeltaSeconds: TimeInterval {
        let hoursDelta = dragTranslation.height / hourHeight
        return TimeInterval(hoursDelta * 3600)
    }

    private func applyMove(translation: CGSize) {
        guard let endTime = entry.endTime else { return }

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

    private func formatTimeRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)
        return "\(startStr) - \(endStr)"
    }
}

private struct ActiveStripeFill: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 8
            let lineWidth: CGFloat = 1
            let stripeColor = color.opacity(0.35)

            context.stroke(
                Path { path in
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        x += spacing
                    }
                },
                with: .color(stripeColor),
                lineWidth: lineWidth
            )
        }
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
            onDragStateChanged: { isDragging = $0 },
            onMove: { updatedEntry in
                entry = clampedToDay(updatedEntry)
            }
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
