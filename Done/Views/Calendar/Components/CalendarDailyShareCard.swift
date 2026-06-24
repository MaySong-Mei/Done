//
//  CalendarDailyShareCard.swift
//  Done
//
//  Shareable card snapshot of a single day's calendar timeline.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Hairline color used by share-card grid rules. Was previously read off
/// the now-deleted `TimelineStyle.view.gridColor`; rest of `TimelineStyle`
/// was dead (#66 §2), so we inlined the only live constant here.
private let calendarDailyShareCardGridColor: Color = Color.secondary.opacity(0.15)

// MARK: - Share Style

enum CalendarDailyShareStyle: String, CaseIterable, Identifiable, Equatable {
    case calendar
    case glow
    case minimal
    case neon

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .calendar: return "Calendar"
        case .glow:     return "Glow"
        case .minimal:  return "Minimal"
        case .neon:     return "Neon"
        }
    }

    @ViewBuilder
    func swatch() -> some View {
        switch self {
        case .calendar: CalendarShareCalendarSwatch()
        case .glow:     CalendarShareGlowSwatch()
        case .minimal:  CalendarShareMinimalSwatch()
        case .neon:     CalendarShareNeonSwatch()
        }
    }
}

// MARK: - Style swatches (abstract previews for the picker)

private struct CalendarShareCalendarSwatch: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)

            VStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { _ in
                    Rectangle()
                        .fill(calendarDailyShareCardGridColor)
                        .frame(height: 0.5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.blue.opacity(0.75))
                    .frame(width: 30, height: 7)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.orange.opacity(0.75))
                    .frame(width: 22, height: 12)
            }
            .padding(.leading, 20)
            .padding(.top, 14)
        }
    }
}

private struct CalendarShareGlowSwatch: View {
    var body: some View {
        let hue: Double = 0.62
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.18, brightness: 0.98),
                    Color(hue: hue, saturation: 0.36, brightness: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.55, brightness: 0.78),
                            Color(hue: hue, saturation: 0.65, brightness: 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.purple.opacity(0.85))
                        .frame(width: 36, height: 4)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.green.opacity(0.85))
                        .frame(width: 28, height: 4)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: 32, height: 4)
                }
            }
            .padding(8)
        }
    }
}

private struct CalendarShareMinimalSwatch: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.96)

            VStack(alignment: .leading, spacing: 5) {
                Text("M")
                    .font(.system(size: 14, weight: .light, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.85))
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 14, height: 0.6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.blue.opacity(0.7)).frame(width: 1.5, height: 5)
                        Rectangle().fill(Color.black.opacity(0.7)).frame(width: 30, height: 1.5)
                    }
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 1.5, height: 5)
                        Rectangle().fill(Color.black.opacity(0.7)).frame(width: 24, height: 1.5)
                    }
                }
            }
            .padding(8)
        }
    }
}

private struct CalendarShareNeonSwatch: View {
    var body: some View {
        let accent = Color(red: 0.4, green: 0.95, blue: 0.85)
        ZStack(alignment: .topLeading) {
            Color.black

            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 16, height: 2)
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.purple)
                        .frame(width: 34, height: 5)
                        .shadow(color: Color.purple.opacity(0.9), radius: 3)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color(red: 0.3, green: 0.9, blue: 1))
                        .frame(width: 26, height: 5)
                        .shadow(color: Color(red: 0.3, green: 0.9, blue: 1).opacity(0.9), radius: 3)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.pink)
                        .frame(width: 30, height: 5)
                        .shadow(color: Color.pink.opacity(0.9), radius: 3)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Daily Share Card

struct CalendarDailyShareCard: View {
    let date: Date
    let occurrences: [CalendarLayout.EventOccurrence]
    var style: CalendarDailyShareStyle = .calendar
    var displayName: String = ""
    var avatarHue: Double? = nil

    static let cardSize = CGSize(width: 360, height: 720)

    private static let staticDragState = EventDragState()

    private var calendar: Calendar { Calendar.current }

    private var dayStart: Date { calendar.startOfDay(for: date) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart }

    /// Clamp each occurrence to the visible day so multi-day events render
    /// only the portion that falls on this day.
    private var clampedItems: [(occurrence: CalendarLayout.EventOccurrence, range: Event.TimeRange)] {
        occurrences.compactMap { occ in
            let start = max(occ.range.start, dayStart)
            let end = min(occ.range.end, dayEnd)
            guard end > start else { return nil }
            return (occ, Event.TimeRange(start: start, end: end))
        }
        .sorted { $0.range.start < $1.range.start }
    }

    /// Overlap slots keyed by occurrence id. Mirrors the day-view calendar's
    /// equal-split column layout so overlapping events sit side-by-side
    /// instead of stacking on top of each other.
    private var overlapSlots: [String: CalendarLayout.EventOverlapSlot] {
        // Pinned to .equalSplit: see OverlapMode doc — calendarEventBlock
        // reads only widthFraction/xOffsetFraction/zIndex, never coverRanges.
        CalendarLayout.overlapLayout(for: occurrences, on: date, mode: .equalSplit)
    }

    /// Visible hour range. We crop to the active band [earliest-1, latest+1]
    /// so the card focuses on real activity instead of empty hours.
    private var visibleHourRange: ClosedRange<Int> {
        guard !clampedItems.isEmpty else { return 8...20 }
        let firstHour = clampedItems.map { calendar.component(.hour, from: $0.range.start) }.min() ?? 8
        let lastEnd = clampedItems.map { $0.range.end }.max() ?? dayEnd
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
        Group {
            switch style {
            case .calendar: calendarBody
            case .glow:     glowBody
            case .minimal:  minimalBody
            case .neon:     neonBody
            }
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
    }

    // MARK: - Calendar style (matches the day-view timeline)

    private var calendarBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekdayLabel.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Text(dateLabel)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
            }
            calendarTimelineStrip
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .background(Color(.systemBackground))
    }

    private var calendarTimelineStrip: some View {
        GeometryReader { proxy in
            let labelWidth: CGFloat = 26
            let labelGap: CGFloat = 4
            let eventAreaX = labelWidth + labelGap
            let eventAreaWidth = max(0, proxy.size.width - eventAreaX)
            let eventHorizontalInset: CGFloat = 4
            let blockWidth = max(0, eventAreaWidth - eventHorizontalInset * 2)
            let canvasHeight = proxy.size.height
            let startHour = visibleHourRange.lowerBound
            let endHour = visibleHourRange.upperBound
            let totalHours = max(1, endHour - startHour)
            let hourHeight = canvasHeight / CGFloat(totalHours)

            ZStack(alignment: .topLeading) {
                calendarGrid(
                    startHour: startHour,
                    endHour: endHour,
                    hourHeight: hourHeight,
                    originX: eventAreaX,
                    width: eventAreaWidth
                )

                ForEach(startHour...endHour, id: \.self) { hour in
                    Text(hourLabel(for: hour))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(y: CGFloat(hour - startHour) * hourHeight - 6)
                }

                let slots = overlapSlots
                ForEach(Array(clampedItems.enumerated()), id: \.offset) { _, item in
                    calendarEventBlock(
                        item: item,
                        slot: slots[item.occurrence.id] ?? .default,
                        startHour: startHour,
                        hourHeight: hourHeight,
                        eventAreaOriginX: eventAreaX + eventHorizontalInset,
                        eventAreaWidth: blockWidth
                    )
                }

                if clampedItems.isEmpty {
                    Text(L(.nothingScheduled))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    private func calendarGrid(
        startHour: Int,
        endHour: Int,
        hourHeight: CGFloat,
        originX: CGFloat,
        width: CGFloat
    ) -> some View {
        let gridColor = calendarDailyShareCardGridColor
        return Canvas { context, _ in
            for hour in startHour...endHour {
                let y = CGFloat(hour - startHour) * hourHeight
                context.fill(
                    Path(CGRect(x: originX, y: y, width: width, height: 1)),
                    with: .color(gridColor)
                )
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func calendarEventBlock(
        item: (occurrence: CalendarLayout.EventOccurrence, range: Event.TimeRange),
        slot: CalendarLayout.EventOverlapSlot,
        startHour: Int,
        hourHeight: CGFloat,
        eventAreaOriginX: CGFloat,
        eventAreaWidth: CGFloat
    ) -> some View {
        let visibleStart = calendar.date(
            bySettingHour: startHour, minute: 0, second: 0, of: dayStart
        ) ?? dayStart
        let secondsFromTop = item.range.start.timeIntervalSince(visibleStart)
        let y = CGFloat(secondsFromTop / 3600) * hourHeight
        let duration = item.range.end.timeIntervalSince(item.range.start)
        let height = max(0, CGFloat(duration / 3600) * hourHeight - 3)
        let blockWidth = max(0, eventAreaWidth * slot.widthFraction)
        let blockX = eventAreaOriginX + eventAreaWidth * slot.xOffsetFraction
        let color = CalendarLayout.eventColor(for: item.occurrence.event)

        EventBlock(
            event: item.occurrence.event,
            occurrenceID: item.occurrence.id,
            renderDayStart: dayStart,
            displayRange: item.range,
            color: color,
            showText: true,
            style: .preview,
            liveHourHeight: CalendarHourHeightBox(hourHeight),
            dragState: Self.staticDragState
        )
        .frame(width: blockWidth, height: height, alignment: .top)
        .offset(x: blockX, y: y + 1.5)
        .zIndex(slot.zIndex)
    }

    // MARK: - Glow style (original colorful gradient)

    private var glowBody: some View {
        let hue = avatarHue ?? (Double(abs(displayName.hashValue) % 360) / 360.0)

        return ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.18, brightness: 0.98),
                    Color(hue: hue, saturation: 0.36, brightness: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 14) {
                glowHeader(hue: hue)

                glowTimelineStrip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                glowSummaryRow

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
    }

    private func glowHeader(hue: Double) -> some View {
        HStack(alignment: .center, spacing: 12) {
            glowAvatar(size: 40, hue: hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.isEmpty ? L(.today) : displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .lineLimit(1)
                Text(dateLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.55))
            }
            Spacer(minLength: 0)
            Text(glowWeekdayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.5))
                .tracking(1.5)
        }
    }

    private func glowAvatar(size: CGFloat, hue: Double) -> some View {
        let initial = displayName.first.map(String.init)?.uppercased() ?? "·"
        let image = MeAvatarStore.load()
        return ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
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
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var glowTimelineStrip: some View {
        GeometryReader { proxy in
            let labelWidth: CGFloat = 30
            let canvasWidth = max(0, proxy.size.width - labelWidth - 4)
            let canvasHeight = proxy.size.height
            let startHour = visibleHourRange.lowerBound
            let endHour = visibleHourRange.upperBound
            let totalHours = max(1, endHour - startHour)
            let hourHeight = canvasHeight / CGFloat(totalHours)

            ZStack(alignment: .topLeading) {
                ForEach(startHour...endHour, id: \.self) { hour in
                    let y = CGFloat(hour - startHour) * hourHeight
                    HStack(spacing: 4) {
                        Text(hourLabel(for: hour))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.black.opacity(0.35))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: labelWidth, alignment: .trailing)
                        Rectangle()
                            .fill(Color.black.opacity(0.08))
                            .frame(height: 0.5)
                    }
                    .offset(y: y)
                }

                let slots = overlapSlots
                ForEach(Array(clampedItems.enumerated()), id: \.offset) { _, item in
                    glowEventBlock(
                        item: item,
                        slot: slots[item.occurrence.id] ?? .default,
                        startHour: startHour,
                        hourHeight: hourHeight,
                        labelWidth: labelWidth,
                        canvasWidth: canvasWidth
                    )
                }

                if clampedItems.isEmpty {
                    HStack {
                        Spacer()
                        Text(L(.nothingScheduled))
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
    private func glowEventBlock(
        item: (occurrence: CalendarLayout.EventOccurrence, range: Event.TimeRange),
        slot: CalendarLayout.EventOverlapSlot,
        startHour: Int,
        hourHeight: CGFloat,
        labelWidth: CGFloat,
        canvasWidth: CGFloat
    ) -> some View {
        let visibleStart = calendar.date(
            bySettingHour: startHour, minute: 0, second: 0, of: dayStart
        ) ?? dayStart
        let blockStart = item.range.start.timeIntervalSince(visibleStart) / 3600
        let duration = item.range.end.timeIntervalSince(item.range.start) / 3600
        let y = CGFloat(blockStart) * hourHeight
        let height = max(8, CGFloat(duration) * hourHeight)
        let color = CalendarLayout.eventColor(for: item.occurrence.event)
        let title = item.occurrence.event.title.isEmpty ? "Untitled" : item.occurrence.event.title

        let slotWidth = max(0, canvasWidth * slot.widthFraction - 4)
        let slotX = labelWidth + 4 + 2 + canvasWidth * slot.xOffsetFraction

        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(0.9))
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(height > 22 ? 2 : 1)
                    if height > 28 {
                        Text(glowTimeRangeLabel(start: item.range.start, end: item.range.end))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(width: slotWidth, height: height, alignment: .topLeading)
            .offset(x: slotX, y: y)
            .zIndex(slot.zIndex)
    }

    private var glowSummaryRow: some View {
        let count = clampedItems.count
        let totalSeconds = clampedItems.reduce(0.0) { $0 + $1.range.end.timeIntervalSince($1.range.start) }
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

    // MARK: - Minimal style (editorial / journal list)

    private var minimalBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(weekdayLabel.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(.secondary)
                Text(dateLabel)
                    .font(.system(size: 28, weight: .light, design: .serif))
                    .foregroundStyle(.primary)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.55))
                .frame(width: 36, height: 1)

            if clampedItems.isEmpty {
                Text(L(.nothingScheduled))
                    .font(.system(size: 14, design: .serif).italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(clampedItems.enumerated()), id: \.offset) { _, item in
                        minimalEventRow(item: item)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(28)
        .background(Color(white: 0.96))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func minimalEventRow(
        item: (occurrence: CalendarLayout.EventOccurrence, range: Event.TimeRange)
    ) -> some View {
        let color = CalendarLayout.eventColor(for: item.occurrence.event)
        let title = item.occurrence.event.title.isEmpty ? "Untitled" : item.occurrence.event.title

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(minimalTimeLabel(item.range.start))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(minimalTimeLabel(item.range.end))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, alignment: .trailing)

            Rectangle()
                .fill(color)
                .frame(width: 2, height: 24)
                .padding(.top, 2)

            Text(title)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func minimalTimeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Neon style (dark / glow timeline)

    private var neonAccent: Color {
        Color(red: 0.4, green: 0.95, blue: 0.85)
    }

    private var neonBody: some View {
        ZStack {
            Color.black

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weekdayLabel.uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(neonAccent)
                    Text(dateLabel.uppercased())
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                }

                neonTimelineStrip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(20)
        }
    }

    private var neonTimelineStrip: some View {
        GeometryReader { proxy in
            let labelWidth: CGFloat = 28
            let labelGap: CGFloat = 6
            let eventAreaX = labelWidth + labelGap
            let eventAreaWidth = max(0, proxy.size.width - eventAreaX)
            let eventInset: CGFloat = 4
            let canvasHeight = proxy.size.height
            let startHour = visibleHourRange.lowerBound
            let endHour = visibleHourRange.upperBound
            let totalHours = max(1, endHour - startHour)
            let hourHeight = canvasHeight / CGFloat(totalHours)
            let accent = neonAccent

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for hour in startHour...endHour {
                        let y = CGFloat(hour - startHour) * hourHeight
                        context.fill(
                            Path(CGRect(x: eventAreaX, y: y, width: eventAreaWidth, height: 0.5)),
                            with: .color(accent.opacity(0.18))
                        )
                    }
                }
                .allowsHitTesting(false)

                ForEach(startHour...endHour, id: \.self) { hour in
                    Text(hourLabel(for: hour))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.6))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(y: CGFloat(hour - startHour) * hourHeight - 6)
                }

                let slots = overlapSlots
                ForEach(Array(clampedItems.enumerated()), id: \.offset) { _, item in
                    neonEventBlock(
                        item: item,
                        slot: slots[item.occurrence.id] ?? .default,
                        startHour: startHour,
                        hourHeight: hourHeight,
                        eventAreaOriginX: eventAreaX + eventInset,
                        eventAreaWidth: max(0, eventAreaWidth - eventInset * 2)
                    )
                }

                if clampedItems.isEmpty {
                    Text("// nothing scheduled")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func neonEventBlock(
        item: (occurrence: CalendarLayout.EventOccurrence, range: Event.TimeRange),
        slot: CalendarLayout.EventOverlapSlot,
        startHour: Int,
        hourHeight: CGFloat,
        eventAreaOriginX: CGFloat,
        eventAreaWidth: CGFloat
    ) -> some View {
        let visibleStart = calendar.date(
            bySettingHour: startHour, minute: 0, second: 0, of: dayStart
        ) ?? dayStart
        let blockStart = item.range.start.timeIntervalSince(visibleStart) / 3600
        let duration = item.range.end.timeIntervalSince(item.range.start) / 3600
        let y = CGFloat(blockStart) * hourHeight
        let height = max(8, CGFloat(duration) * hourHeight)
        let color = CalendarLayout.eventColor(for: item.occurrence.event)
        let title = item.occurrence.event.title.isEmpty ? "Untitled" : item.occurrence.event.title
        let blockWidth = max(0, eventAreaWidth * slot.widthFraction)
        let blockX = eventAreaOriginX + eventAreaWidth * slot.xOffsetFraction

        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .shadow(color: color.opacity(0.85), radius: 6, x: 0, y: 0)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(height > 22 ? 2 : 1)
                    if height > 28 {
                        Text(neonTimeRange(start: item.range.start, end: item.range.end))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(width: blockWidth, height: height, alignment: .topLeading)
            .offset(x: blockX, y: y)
            .zIndex(slot.zIndex)
    }

    private func neonTimeRange(start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }

    // MARK: - Formatting

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private var weekdayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private var glowWeekdayLabel: String {
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

    private func glowTimeRangeLabel(start: Date, end: Date) -> String {
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
