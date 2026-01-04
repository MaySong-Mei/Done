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
    @State private var isDraggingActive = false

    var body: some View {
        if renderEnd > renderStart {
            let startY = yPosition(for: renderStart)
            let height = max(1, height(from: renderStart, to: renderEnd))

            let blockWidth = max(1, availableWidth - 2)
            let content = eventContent(height: height)
                .offset(x: 1, y: startY)

            if type == .completed || type == .draft {
                content
                    .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 8) {
                        guard !isDraggingActive else { return }
                        isDraggingActive = true
                        onDragStateChanged(true)
                    }
                    .simultaneousGesture(moveGesture)
            } else {
                content
            }
        }
    }

    private func eventContent(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabels {
                Text(entry.templateName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(labelColor)
                    .lineLimit(1)

                if height > 40 {
                    Text(formatTimeRange(start: renderStart, end: renderEnd))
                        .font(.caption2)
                        .foregroundColor(labelColor.opacity(0.8))
                }
            }
        }
        .padding(8)
        .frame(width: max(1, availableWidth - 2), height: height, alignment: .topLeading)
        .background(eventBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color(hex: entry.colorHex) ?? .blue, lineWidth: type == .ongoing ? 0.8 : 0)
        )
        .cornerRadius(6)
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

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onEnded { value in
                defer {
                    if isDraggingActive {
                        onDragStateChanged(false)
                    }
                    isDraggingActive = false
                }
                guard isDraggingActive else { return }
                applyMove(translation: value.translation)
            }
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
