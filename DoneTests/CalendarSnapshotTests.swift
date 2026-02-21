import XCTest
import SwiftUI
import SnapshotTesting
@testable import Done

final class CalendarSnapshotTests: XCTestCase {
    private let snapshotConfig = ViewImageConfig.iPhoneSe

    func testHeaderExpandedAndCollapsedSnapshots() {
        let selectedDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 2, day: 14, hour: 10)
        )!

        let expanded = CalendarTopOverlaySnapshotHarness(
            selectedDate: selectedDate,
            rangeMode: .week,
            leftCapsuleTitle: "Feb 11-17, Week 7",
            capsulesVisible: true,
            safeAreaTop: 47
        )
        .frame(width: 320, height: 220, alignment: .top)

        let collapsed = CalendarTopOverlaySnapshotHarness(
            selectedDate: selectedDate,
            rangeMode: .week,
            leftCapsuleTitle: "Feb 11-17, Week 7",
            capsulesVisible: false,
            safeAreaTop: 47
        )
        .frame(width: 320, height: 220, alignment: .top)

        assertSnapshotView(expanded, named: "header-expanded")
        assertSnapshotView(collapsed, named: "header-collapsed")
    }

    func testHeaderLeftCapsuleLegendAcrossRangeModes() {
        let selectedDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 2, day: 14, hour: 10)
        )!

        let day = CalendarTopOverlaySnapshotHarness(
            selectedDate: selectedDate,
            rangeMode: .day,
            leftCapsuleTitle: "Feb 14, Saturday",
            capsulesVisible: true,
            safeAreaTop: 47
        )
        .frame(width: 320, height: 220, alignment: .top)

        let threeDay = CalendarTopOverlaySnapshotHarness(
            selectedDate: selectedDate,
            rangeMode: .threeDay,
            leftCapsuleTitle: "Feb 13-15, Fri-Sun",
            capsulesVisible: true,
            safeAreaTop: 47
        )
        .frame(width: 320, height: 220, alignment: .top)

        let week = CalendarTopOverlaySnapshotHarness(
            selectedDate: selectedDate,
            rangeMode: .week,
            leftCapsuleTitle: "Feb 11-17, Week 7",
            capsulesVisible: true,
            safeAreaTop: 47
        )
        .frame(width: 320, height: 220, alignment: .top)

        assertSnapshotView(day, named: "header-day-title")
        assertSnapshotView(threeDay, named: "header-three-day-title")
        assertSnapshotView(week, named: "header-week-title")
    }

    func testEventBlockPreviewVsEditHandleSnapshots() {
        let event = sampleEvent()
        let range = event.effectiveTimeRanges[0]

        let preview = EventBlock(
            event: event,
            occurrenceID: "occ-preview",
            dragSourceRange: range,
            displayRange: range,
            color: .green,
            showText: true,
            style: .preview,
            hourHeight: 56,
            dayColumnStep: 0,
            isFocused: false,
            isFocusContextActive: false,
            onDragEnded: { _ in },
            onResizeTopEnded: { _ in },
            onResizeBottomEnded: { _ in },
            dragState: EventDragState()
        )
        .frame(width: 180, height: 140)
        .padding(20)
        .background(Color.white)

        let edit = EventBlock(
            event: event,
            occurrenceID: "occ-edit",
            dragSourceRange: range,
            displayRange: range,
            color: .green,
            showText: true,
            style: .edit,
            hourHeight: 56,
            dayColumnStep: 0,
            isFocused: false,
            isFocusContextActive: false,
            onDragEnded: { _ in },
            onResizeTopEnded: { _ in },
            onResizeBottomEnded: { _ in },
            dragState: EventDragState()
        )
        .frame(width: 180, height: 140)
        .padding(20)
        .background(Color.white)

        assertSnapshotView(preview, named: "event-preview-no-handles")
        assertSnapshotView(edit, named: "event-edit-with-handles")
    }

    func testEventBlockFocusDimAndPushBackSnapshot() {
        let event = sampleEvent()
        let range = event.effectiveTimeRanges[0]

        let focused = EventBlock(
            event: event,
            occurrenceID: "occ-focused",
            dragSourceRange: range,
            displayRange: range,
            color: .green,
            showText: true,
            style: .edit,
            hourHeight: 56,
            dayColumnStep: 0,
            isFocused: true,
            isFocusContextActive: true,
            onDragEnded: { _ in },
            dragState: EventDragState()
        )
        .frame(width: 160, height: 120)

        let dimmed = EventBlock(
            event: event,
            occurrenceID: "occ-dimmed",
            dragSourceRange: range,
            displayRange: range,
            color: .green,
            showText: true,
            style: .preview,
            hourHeight: 56,
            dayColumnStep: 0,
            isFocused: false,
            isFocusContextActive: true,
            onDragEnded: { _ in },
            dragState: EventDragState()
        )
        .frame(width: 160, height: 120)

        let stack = HStack(spacing: 20) {
            focused
            dimmed
        }
        .padding(20)
        .background(Color.white)

        assertSnapshotView(stack, named: "event-focus-dim-pushback")
    }

    private func assertSnapshotView<V: View>(
        _ view: V,
        named name: String,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = .light
        assertSnapshot(
            of: controller,
            as: .image(on: snapshotConfig),
            named: name,
            file: file,
            testName: testName,
            line: line
        )
    }

    private func sampleEvent() -> Event {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9, minute: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 30))!

        return Event(
            title: "Deep Work",
            note: "Focus session",
            startTime: start,
            endTime: end,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            repeatUnit: .none,
            isAllDay: false,
            type: "Work"
        )
    }
}

private struct CalendarTopOverlaySnapshotHarness: View {
    let selectedDate: Date
    let rangeMode: RangeMode
    let leftCapsuleTitle: String
    let capsulesVisible: Bool
    let safeAreaTop: CGFloat

    private let horizontalPadding: CGFloat = 16
    private let labelWidth: CGFloat = 32
    private let timelineEdgePadding: CGFloat = 6
    private let daySpacing: CGFloat = 12
    private let topOverlayGap: CGFloat = 6
    private let legendBottomPadding: CGFloat = 4
    private let legendVerticalNudge: CGFloat = -6
    private let overlayBottomFadeHeight: CGFloat = 12
    private let overlayMaterialOpacity: CGFloat = 0.82

    private var visibleDates: [Date] {
        calendarVisibleDatesForRange(
            selectedDayOffset: 0,
            rangeMode: rangeMode,
            referenceDate: selectedDate
        )
    }

    private var overlayHeight: CGFloat {
        calendarTopOverlayInset(
            safeAreaTop: safeAreaTop,
            isCapsuleVisible: capsulesVisible
        ) + legendBottomPadding
    }

    var body: some View {
        let fadeStart = calendarOverlayFadeMaskStart(
            totalHeight: overlayHeight,
            fadeHeight: overlayBottomFadeHeight
        )

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if rangeMode == .day {
                    AppleCalendarHeaderView(
                        selectedDate: selectedDate,
                        rangeMode: rangeMode,
                        leftCapsuleTitle: leftCapsuleTitle,
                        isCapsulesVisible: capsulesVisible,
                        onMonthTap: {},
                        onSelectRangeMode: { _ in },
                        onAgentTap: {},
                        onSearchTap: {},
                        onAddTap: {}
                    )
                    .padding(.horizontal, horizontalPadding)
                    .frame(
                        height: calendarCapsuleVisibleHeight(isVisible: capsulesVisible),
                        alignment: .top
                    )
                    dayCenteredLegendBar
                } else {
                    AppleCalendarHeaderView(
                        selectedDate: selectedDate,
                        rangeMode: rangeMode,
                        leftCapsuleTitle: leftCapsuleTitle,
                        isCapsulesVisible: capsulesVisible,
                        onMonthTap: {},
                        onSelectRangeMode: { _ in },
                        onAgentTap: {},
                        onSearchTap: {},
                        onAddTap: {}
                    )
                    .padding(.horizontal, horizontalPadding)
                    .frame(
                        height: calendarCapsuleVisibleHeight(isVisible: capsulesVisible),
                        alignment: .top
                    )

                    dateLegendBar
                        .offset(y: legendVerticalNudge)
                }
            }
            .padding(.top, safeAreaTop + topOverlayGap)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(overlayMaterialOpacity)
                    .frame(maxWidth: .infinity)
                    .frame(height: overlayHeight, alignment: .top)
                    .mask(alignment: .top) {
                        if fadeStart >= 1 {
                            Rectangle().fill(Color.black)
                        } else {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: fadeStart),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
            }

            Spacer(minLength: 0)
        }
        .background(Color.white)
    }

    private var dateLegendBar: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width - horizontalPadding * 2)
            let daysCount = max(1, visibleDates.count)
            let dayAreaWidth = max(0, totalWidth - timelineEdgePadding * 2 - labelWidth)
            let spacing = daysCount == 1 ? CGFloat(0) : daySpacing
            let dayWidth = daysCount == 1
                ? dayAreaWidth
                : max(0, (dayAreaWidth - spacing * CGFloat(daysCount - 1)) / CGFloat(daysCount))

            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 30)
                HStack(spacing: spacing) {
                    ForEach(Array(visibleDates.enumerated()), id: \.offset) { entry in
                        let date = entry.element
                        VStack(spacing: 2) {
                            Text(Self.weekdayFormatter.string(from: date).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(Self.dayFormatter.string(from: date))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(width: dayWidth, height: 30)
                    }
                }
            }
            .padding(.horizontal, horizontalPadding + timelineEdgePadding)
            .frame(width: proxy.size.width, height: 30, alignment: .leading)
        }
        .frame(height: 30)
        .padding(.bottom, legendBottomPadding)
    }

    private var dayCenteredLegendBar: some View {
        let date = visibleDates.first ?? selectedDate

        return VStack(spacing: 2) {
            Text(Self.weekdayFormatter.string(from: date).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Self.dayFormatter.string(from: date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
        .padding(.bottom, legendBottomPadding)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}
