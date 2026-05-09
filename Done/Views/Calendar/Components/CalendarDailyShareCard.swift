//
//  CalendarDailyShareCard.swift
//  Done
//
//  Shareable card snapshot of a single day's calendar timeline.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Daily Share Card

struct CalendarDailyShareCard: View {
    let date: Date
    let occurrences: [CalendarLayout.EventOccurrence]
    let displayName: String
    let avatarHue: Double?

    static let cardSize = CGSize(width: 360, height: 520)

    private var calendar: Calendar { Calendar.current }

    private var dayStart: Date { calendar.startOfDay(for: date) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart }

    /// Clamp each occurrence to the visible day so multi-day events render
    /// only the portion that falls on this day.
    private var clampedRanges: [(occurrence: CalendarLayout.EventOccurrence, start: Date, end: Date)] {
        occurrences.compactMap { occ in
            let start = max(occ.range.start, dayStart)
            let end = min(occ.range.end, dayEnd)
            guard end > start else { return nil }
            return (occ, start, end)
        }
        .sorted { $0.start < $1.start }
    }

    /// Visible hour range. We crop to the active band [earliest-1, latest+1]
    /// so the card focuses on real activity instead of empty hours.
    private var visibleHourRange: ClosedRange<Int> {
        guard !clampedRanges.isEmpty else { return 8...20 }
        let firstHour = clampedRanges.map { calendar.component(.hour, from: $0.start) }.min() ?? 8
        let lastEnd = clampedRanges.map { $0.end }.max() ?? dayEnd
        let lastEndHour: Int = {
            let comps = calendar.dateComponents([.hour, .minute], from: lastEnd)
            let h = comps.hour ?? 0
            let m = comps.minute ?? 0
            return m > 0 ? h + 1 : h
        }()
        let lo = max(0, firstHour - 1)
        let hi = min(24, lastEndHour + 1)
        return lo...max(hi, lo + 4) // ensure a minimum span
    }

    var body: some View {
        let hue = avatarHue ?? (Double(abs(displayName.hashValue) % 360) / 360.0)

        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.18, brightness: 0.98),
                    Color(hue: hue, saturation: 0.36, brightness: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 14) {
                header(hue: hue)

                timelineStrip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                summaryRow

                HStack {
                    Spacer()
                    Text("done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.4))
                        .tracking(2.0)
                }
            }
            .padding(24)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
    }

    // MARK: - Header

    private func header(hue: Double) -> some View {
        HStack(alignment: .center, spacing: 12) {
            avatar(size: 40, hue: hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.isEmpty ? "Today" : displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .lineLimit(1)
                Text(headerDateLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.55))
            }
            Spacer(minLength: 0)
            Text(weekdayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.5))
                .tracking(1.5)
        }
    }

    private func avatar(size: CGFloat, hue: Double) -> some View {
        let initial = displayName.first.map(String.init)?.uppercased() ?? "·"
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.78),
                        Color(hue: hue, saturation: 0.65, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initial)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Timeline strip

    private var timelineStrip: some View {
        GeometryReader { proxy in
            let labelWidth: CGFloat = 30
            let canvasWidth = max(0, proxy.size.width - labelWidth - 4)
            let canvasHeight = proxy.size.height
            let startHour = visibleHourRange.lowerBound
            let endHour = visibleHourRange.upperBound
            let totalHours = max(1, endHour - startHour)
            let hourHeight = canvasHeight / CGFloat(totalHours)

            ZStack(alignment: .topLeading) {
                // Hour gridlines + labels
                ForEach(startHour...endHour, id: \.self) { hour in
                    let y = CGFloat(hour - startHour) * hourHeight
                    HStack(spacing: 4) {
                        Text(hourLabel(for: hour))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.black.opacity(0.35))
                            .frame(width: labelWidth, alignment: .trailing)
                        Rectangle()
                            .fill(Color.black.opacity(0.08))
                            .frame(height: 0.5)
                    }
                    .offset(y: y)
                }

                // Events
                ForEach(Array(clampedRanges.enumerated()), id: \.offset) { _, item in
                    eventBlock(
                        item: item,
                        startHour: startHour,
                        hourHeight: hourHeight,
                        labelWidth: labelWidth,
                        canvasWidth: canvasWidth
                    )
                }

                if clampedRanges.isEmpty {
                    HStack {
                        Spacer()
                        Text("Nothing scheduled")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black.opacity(0.45))
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func eventBlock(
        item: (occurrence: CalendarLayout.EventOccurrence, start: Date, end: Date),
        startHour: Int,
        hourHeight: CGFloat,
        labelWidth: CGFloat,
        canvasWidth: CGFloat
    ) -> some View {
        let blockStart = hoursSinceMidnight(item.start) - Double(startHour)
        let blockEnd = hoursSinceMidnight(item.end) - Double(startHour)
        let y = CGFloat(blockStart) * hourHeight
        let height = max(8, CGFloat(blockEnd - blockStart) * hourHeight)
        let color = CalendarLayout.eventColor(for: item.occurrence.event)
        let title = item.occurrence.event.title.isEmpty ? "Untitled" : item.occurrence.event.title

        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(0.9))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(height > 22 ? 2 : 1)
                    if height > 28 {
                        Text(timeRangeLabel(start: item.start, end: item.end))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .frame(width: canvasWidth - 4, height: height, alignment: .topLeading)
            .offset(x: labelWidth + 4 + 2, y: y)
    }

    // MARK: - Summary

    private var summaryRow: some View {
        let count = clampedRanges.count
        let totalSeconds = clampedRanges.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let hours = totalSeconds / 3600
        return HStack(spacing: 8) {
            Text("\(count) event\(count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
            Text("·")
                .foregroundStyle(.black.opacity(0.35))
            Text(String(format: "%.1f hours", hours))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black.opacity(0.6))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Formatting

    private var headerDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private var weekdayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func hourLabel(for hour: Int) -> String {
        let h = hour % 24
        if h == 0 { return "12 AM" }
        if h < 12 { return "\(h) AM" }
        if h == 12 { return "12 PM" }
        return "\(h - 12) PM"
    }

    private func hoursSinceMidnight(_ date: Date) -> Double {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h = Double(comps.hour ?? 0)
        let m = Double(comps.minute ?? 0)
        return h + m / 60.0
    }

    private func timeRangeLabel(start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }
}

// MARK: - Transferable Item

struct CalendarDailyShareItem: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.image.pngData() ?? Data()
        }
    }
}

// MARK: - Renderer

@MainActor
func calendarDailyShareCardRender(_ card: CalendarDailyShareCard) -> UIImage? {
    let renderer = ImageRenderer(
        content: card.frame(
            width: CalendarDailyShareCard.cardSize.width,
            height: CalendarDailyShareCard.cardSize.height
        )
    )
    renderer.scale = 3
    return renderer.uiImage
}
