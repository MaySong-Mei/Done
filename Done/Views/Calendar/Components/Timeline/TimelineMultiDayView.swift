//
//  TimelineMultiDayView.swift
//  Done
//
//  Multi-day timeline with shared time axis. Supports preview/edit modes and
//  configurable day count (e.g., 3-day, 7-day week).
//

import SwiftUI

/// 功能： Renders a multi-day timeline with a shared time axis.
struct TimelineMultiDayView: View {
    /// 功能： Defines edit or preview behavior for multi-day timelines.
    enum Mode {
        case preview
        case edit
    }

    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let daysCount: Int
    let mode: Mode
    let dayRange: ClosedRange<Int>

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let daySpacing: CGFloat = 12
    private let eventHorizontalInset: CGFloat = 10
    private let labelBarHeight: CGFloat = 18
    private let labelBarSpacing: CGFloat = 6

    private let headerHeight: CGFloat = 0
    @State private var hasScrolledToInitial: Bool = false
    @State private var isRestoringScroll: Bool = true
    @State private var pendingScrollTarget: Int? = nil
    @State private var isUserScrollUpdating: Bool = false

    var body: some View {
        let timelineHeight = headerHeight + (CGFloat(25) * hourHeight)
        let totalHeight = labelBarHeight + timelineHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)
            let dayWidth = max(
                0,
                (contentWidth - daySpacing * CGFloat(daysCount - 1)) / CGFloat(daysCount)
            )
            let contentHeight = timelineHeight
            let labelRowHeight = max(0, labelBarHeight - labelBarSpacing)
            let leadingRange = leadingOffsetsRange()

            HStack(spacing: 0) {
                VStack(spacing: labelBarSpacing) {
                    Color.clear
                        .frame(height: labelRowHeight)
                    TimeAxisView(
                        headerHeight: headerHeight,
                        hourHeight: hourHeight,
                        mode: mode
                    )
                    .frame(height: timelineHeight, alignment: .top)
                }
                .frame(width: labelWidth, alignment: .trailing)

                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: daySpacing) {
                            ForEach(dayRange, id: \.self) { offset in
                                VStack(spacing: labelBarSpacing) {
                                    Text(slotLabel(for: offset))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: dayWidth, height: labelRowHeight, alignment: .center)
                                        .allowsHitTesting(false)

                                    TimelineDayView(
                                        date: date(for: offset),
                                        occurrences: occurrencesForOffset(offset),
                                        contentWidth: dayWidth,
                                        headerHeight: headerHeight,
                                        hourHeight: hourHeight,
                                        eventHorizontalInset: eventHorizontalInset,
                                        style: mode == .edit ? .edit : .view
                                    )
                                    .frame(width: dayWidth, height: contentHeight, alignment: .top)
                                }
                                .frame(width: dayWidth)
                                .id(offset)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .onAppear {
                        guard !hasScrolledToInitial else { return }
                        hasScrolledToInitial = true
                        let clamped = clamp(selectedDayOffset, to: leadingRange)
                        if clamped != selectedDayOffset {
                            selectedDayOffset = clamped
                        }
                        pendingScrollTarget = clamped
                        isRestoringScroll = true
                        scrollProxy.scrollTo(clamped, anchor: .leading)
                    }
                    .onChange(of: selectedDayOffset) { newValue in
                        if isUserScrollUpdating {
                            isUserScrollUpdating = false
                            return
                        }
                        let clamped = clamp(newValue, to: leadingRange)
                        pendingScrollTarget = clamped
                        isRestoringScroll = true
                        scrollProxy.scrollTo(clamped, anchor: .leading)
                    }
                    .onChange(of: dayRange) { _ in
                        let clamped = clamp(selectedDayOffset, to: leadingRange)
                        if clamped != selectedDayOffset {
                            selectedDayOffset = clamped
                        }
                        pendingScrollTarget = clamped
                        isRestoringScroll = true
                        scrollProxy.scrollTo(clamped, anchor: .leading)
                    }
                    .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in
                        let step = dayWidth + daySpacing
                        guard step > 0 else { return }
                        if isRestoringScroll {
                            guard let target = pendingScrollTarget else { return }
                            let targetIndex = target - leadingRange.lowerBound
                            let targetX = CGFloat(targetIndex) * step
                            if abs(newValue.contentOffset.x - targetX) > step * 0.5 {
                                return
                            }
                            isRestoringScroll = false
                            pendingScrollTarget = nil
                        }
                        let rawIndex = newValue.contentOffset.x / step
                        let index = Int(rawIndex.rounded(.towardZero))
                        let offset = leadingRange.lowerBound + index
                        let clamped = clamp(offset, to: leadingRange)
                        if selectedDayOffset != clamped {
                            isUserScrollUpdating = true
                            selectedDayOffset = clamped
                        }
                    }
                }
            }
        }
        .frame(height: totalHeight, alignment: .top)
    }

    private func leadingOffsetsRange() -> ClosedRange<Int> {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound - (daysCount - 1)
        if lower <= upper {
            return lower...upper
        }
        return lower...lower
    }

    private func clamp(_ offset: Int, to range: ClosedRange<Int>) -> Int {
        min(max(offset, range.lowerBound), range.upperBound)
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    private func slotLabel(for offset: Int) -> String {
        let date = date(for: offset)
        let day = Calendar.current.component(.day, from: date)
        let weekdayIndex = Calendar.current.component(.weekday, from: date) - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        let letter = symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex].prefix(1) : ""
        return "\(day)\(letter)"
    }
}

/// 功能： Shows the static hour labels shared by the multi-day timeline.
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
