//
//  TimelineView.swift
//  Done
//
//  Unified timeline view supporting single-day (paged) and multi-day (scrolling) modes.
//

import SwiftUI

/// Unified timeline view. Use daysCount=1 for single-day paged mode, >1 for multi-day scroll mode.
struct TimelineView: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let daysCount: Int
    let mode: PageMode
    let showEventText: Bool
    let dayRange: ClosedRange<Int>
    var onEventTap: ((Event) -> Void)? = nil
    var onEventDragEnded: ((Event, Event.TimeRange, DragOffset) -> Void)? = nil

    // MARK: - Layout Constants

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36
    private let daySpacing: CGFloat = 12
    private let eventHorizontalInset: CGFloat = 0
    private let headerHeight: CGFloat = 0

    // MARK: - Computed Properties

    private var isSingleDay: Bool { daysCount == 1 }
    private var showDayLabel: Bool { mode == .edit }
    private var labelBarHeight: CGFloat { showDayLabel ? 18 : 0 }
    private var labelBarSpacing: CGFloat { showDayLabel ? 6 : 0 }
    private var timelineHeight: CGFloat { headerHeight + CGFloat(25) * hourHeight }
    private var totalHeight: CGFloat { labelBarHeight + timelineHeight }

    // MARK: - Multi-day Scroll State

    @State private var hasScrolledToInitial = false
    @State private var isRestoringScroll = true
    @State private var pendingScrollTarget: Int? = nil
    @State private var isUserScrollUpdating = false

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)
            let dayWidth = isSingleDay
                ? contentWidth
                : max(0, (contentWidth - daySpacing * CGFloat(daysCount - 1)) / CGFloat(daysCount))
            let labelRowHeight = max(0, labelBarHeight - labelBarSpacing)

            HStack(spacing: 0) {
                timeAxis(labelRowHeight: labelRowHeight)
                    .frame(width: labelWidth, alignment: .trailing)

                if isSingleDay {
                    singleDayContent(
                        contentWidth: contentWidth,
                        labelRowHeight: labelRowHeight
                    )
                } else {
                    multiDayContent(
                        dayWidth: dayWidth,
                        labelRowHeight: labelRowHeight
                    )
                }
            }
        }
        .frame(height: totalHeight, alignment: .top)
    }

    // MARK: - Time Axis

    @ViewBuilder
    private func timeAxis(labelRowHeight: CGFloat) -> some View {
        if showDayLabel {
            VStack(spacing: labelBarSpacing) {
                Color.clear.frame(height: labelRowHeight)
                TimeAxisLabels(headerHeight: headerHeight, hourHeight: hourHeight, mode: mode)
                    .frame(height: timelineHeight, alignment: .top)
            }
        } else {
            TimeAxisLabels(headerHeight: headerHeight, hourHeight: hourHeight, mode: mode)
        }
    }

    // MARK: - Single Day (TabView Paging)

    @ViewBuilder
    private func singleDayContent(contentWidth: CGFloat, labelRowHeight: CGFloat) -> some View {
        TabView(selection: $selectedDayOffset) {
            ForEach(dayRange, id: \.self) { offset in
                dayColumn(
                    offset: offset,
                    width: contentWidth,
                    labelRowHeight: labelRowHeight
                )
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    // MARK: - Multi Day (Horizontal ScrollView)

    @ViewBuilder
    private func multiDayContent(dayWidth: CGFloat, labelRowHeight: CGFloat) -> some View {
        let leadingRange = leadingOffsetsRange()

        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: daySpacing) {
                    ForEach(dayRange, id: \.self) { offset in
                        dayColumn(
                            offset: offset,
                            width: dayWidth,
                            labelRowHeight: labelRowHeight
                        )
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

    // MARK: - Day Column (Shared)

    @ViewBuilder
    private func dayColumn(offset: Int, width: CGFloat, labelRowHeight: CGFloat) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()

        if showDayLabel {
            VStack(spacing: labelBarSpacing) {
                Text(slotLabel(for: offset))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: labelRowHeight, alignment: .center)
                    .allowsHitTesting(false)

                dayView(date: date, offset: offset, width: width)
            }
        } else {
            dayView(date: date, offset: offset, width: width)
        }
    }

    @ViewBuilder
    private func dayView(date: Date, offset: Int, width: CGFloat) -> some View {
        TimelineDayView(
            date: date,
            occurrences: occurrencesForOffset(offset),
            contentWidth: width,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            eventHorizontalInset: eventHorizontalInset,
            showEventText: showEventText,
            style: mode == .edit ? .edit : .view,
            onEventTap: mode == .edit ? onEventTap : nil,
            onEventDragEnded: mode == .edit ? onEventDragEnded : nil
        )
        .frame(width: width, height: timelineHeight, alignment: .top)
    }

    // MARK: - Helpers

    private func leadingOffsetsRange() -> ClosedRange<Int> {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound - (daysCount - 1)
        return lower <= upper ? lower...upper : lower...lower
    }

    private func slotLabel(for offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let day = Calendar.current.component(.day, from: date)
        let weekdayIndex = Calendar.current.component(.weekday, from: date) - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        let letter = symbols.indices.contains(weekdayIndex)
            ? String(symbols[weekdayIndex].prefix(1))
            : ""
        return "\(day)\(letter)"
    }
}

// MARK: - Time Axis Labels

private struct TimeAxisLabels: View {
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let mode: PageMode

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight)

            ForEach(0...24, id: \.self) { hour in
                Text(timeLabel(for: hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    private func timeLabel(for hour: Int) -> String {
        mode == .edit ? String(format: "%02d:00", hour) : "\(hour)"
    }
}
