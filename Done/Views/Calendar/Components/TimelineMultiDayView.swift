//
//  TimelineMultiDayView.swift
//  Done
//
//  Multi-day timeline with shared time axis. Supports preview/edit modes and
//  configurable day count (e.g., 3-day, 7-day week).
//

import SwiftUI

struct TimelineMultiDayView: View {
    enum Mode {
        case preview
        case edit
    }

    let events: [Event]
    @Binding var selectedDayOffset: Int
    let daysCount: Int
    let mode: Mode

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let daySpacing: CGFloat = 12
    private let eventHorizontalInset: CGFloat = 10
    private let dayRange = -30...30

    private let headerHeight: CGFloat = 0

    var body: some View {
        let contentHeight = headerHeight + (CGFloat(25) * hourHeight)

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)
            let dayWidth = max(
                0,
                (contentWidth - daySpacing * CGFloat(daysCount - 1)) / CGFloat(daysCount)
            )

            HStack(spacing: 0) {
                TimeAxisView(
                    headerHeight: headerHeight,
                    hourHeight: hourHeight,
                    mode: mode
                )
                .frame(width: labelWidth, alignment: .trailing)

                TabView(selection: selectionBinding) {
                    ForEach(startOffsets, id: \.self) { startOffset in
                        MultiDayPage(
                            startOffset: startOffset,
                            daysCount: daysCount,
                            dayWidth: dayWidth,
                            daySpacing: daySpacing,
                            contentHeight: contentHeight,
                            events: events,
                            headerHeight: headerHeight,
                            hourHeight: hourHeight,
                            eventHorizontalInset: eventHorizontalInset,
                            style: mode == .edit ? .edit : .view
                        )
                        .tag(startOffset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .frame(height: contentHeight, alignment: .top)
    }

    private var startOffsets: [Int] {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound - (daysCount - 1)
        guard lower <= upper else { return [0] }
        return stride(from: lower, through: upper, by: daysCount).map { $0 }
    }

    private var selectionBinding: Binding<Int> {
        Binding<Int>(
            get: { snap(selectedDayOffset) },
            set: { selectedDayOffset = snap($0) }
        )
    }

    private func snap(_ offset: Int) -> Int {
        guard let nearest = startOffsets.min(by: { abs($0 - offset) < abs($1 - offset) }) else {
            return offset
        }
        return nearest
    }
}

private struct MultiDayPage: View {
    let startOffset: Int
    let daysCount: Int
    let dayWidth: CGFloat
    let daySpacing: CGFloat
    let contentHeight: CGFloat
    let events: [Event]
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let style: TimelineStyle

    var body: some View {
        HStack(spacing: daySpacing) {
            ForEach(0..<daysCount, id: \.self) { index in
                let date = date(for: startOffset + index)
                TimelineDayView(
                    date: date,
                    events: events,
                    contentWidth: dayWidth,
                    headerHeight: headerHeight,
                    hourHeight: hourHeight,
                    eventHorizontalInset: eventHorizontalInset,
                    style: style
                )
                .frame(width: dayWidth, height: contentHeight, alignment: .top)
            }
        }
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }
}

/// Shows the static hour labels shared by the multi-day timeline.
private struct TimeAxisView: View {
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let mode: TimelineMultiDayView.Mode

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: headerHeight)

            ForEach(0...24, id: \.self) { hour in
                Text(timeLabel(for: hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    private func timeLabel(for hour: Int) -> String {
        switch mode {
        case .edit:
            return String(format: "%02d:00", hour)
        case .preview:
            return "\(hour)"
        }
    }
}
