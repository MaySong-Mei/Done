//
//  TimelineScene.swift
//  Done
//
//  Created by Shiqi Liu on 1/3/26.
//

import SwiftUI

struct TimelineScene: View {
    @StateObject private var viewModel = TimelineViewModel()
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var eventProvider = TimelineEventProvider()
    @State private var scrollCenterDate: Date?
    @State private var lockedScrollCenterDate: Date?
    @State private var isMagnifying = false
    @State private var isEventDragging = false
    @State private var showCreateEntry = false
    @State private var selectedEntry: TimeEntry?
    @State private var hourHeight: CGFloat = 60
    @State private var magnificationStartHourHeight: CGFloat = 60
    private let headerCardHeight: CGFloat = 52
    private let headerCornerRadius: CGFloat = 16
    private let minHourHeight: CGFloat = 32
    private let maxHourHeight: CGFloat = 120
    private let timeAxisWidth: CGFloat = 30
    private let horizontalPadding: CGFloat = 16
    private let headerTopPadding: CGFloat = 12
    private let headerBreathingSpace: CGFloat = 12
    private let bodyBottomPadding: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let contentTopInset = safeTop + headerTopPadding + headerCardHeight + headerBreathingSpace

            ZStack(alignment: .top) {
                TimelineSceneBody(
                    viewModel: viewModel,
                    eventProvider: eventProvider,
                    dataManager: dataManager,
                    scrollCenterDate: $scrollCenterDate,
                    isMagnifying: isMagnifying,
                    isEventDragging: $isEventDragging,
                    hourHeight: hourHeight,
                    timeAxisWidth: timeAxisWidth,
                    contentTopInset: contentTopInset,
                    onSelectEntry: { entry in
                        selectedEntry = entry
                    }
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bodyBottomPadding)
                .ignoresSafeArea(edges: .top)

                headerOverlay
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, headerTopPadding)
                    .zIndex(1)
            }
            .background(Color(.systemBackground))
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard !isEventDragging else { return }
                    if lockedScrollCenterDate == nil {
                        lockedScrollCenterDate = scrollCenterDate ?? viewModel.centerDate
                        magnificationStartHourHeight = hourHeight
                    }
                    isMagnifying = true
                    hourHeight = clampedHourHeight(magnificationStartHourHeight * value)
                }
                .onEnded { _ in
                    if isEventDragging {
                        lockedScrollCenterDate = nil
                        isMagnifying = false
                        return
                    }
                    let lockedDate = lockedScrollCenterDate ?? viewModel.centerDate
                    viewModel.centerDate = Calendar.current.startOfDay(for: lockedDate)
                    scrollCenterDate = lockedDate
                    lockedScrollCenterDate = nil
                    isMagnifying = false
                }
        )
        .onAppear {
            eventProvider.update(entries: dataManager.timelineEntries)
            scrollCenterDate = viewModel.centerDate
        }
        .onChange(of: dataManager.timeEntries) { _, _ in
            eventProvider.update(entries: dataManager.timelineEntries)
        }
        .sheet(item: $selectedEntry) { entry in
            TimeEntryEditView(entry: entry)
        }
        .sheet(isPresented: $showCreateEntry) {
            TimeEntryCreateView(selectedDate: viewModel.centerDate)
        }
    }

    private func clampedHourHeight(_ value: CGFloat) -> CGFloat {
        min(maxHourHeight, max(minHourHeight, value))
    }

    private var viewModeLabel: String {
        switch viewModel.viewMode {
        case .day:
            return "Day"
        case .threeDays:
            return "3 Days"
        case .week:
            return "Week"
        }
    }

    private var formattedDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        let baseDate = calendar.startOfDay(for: viewModel.centerDate)

        switch viewModel.viewMode {
        case .day:
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: baseDate)
        case .threeDays:
            let startDate = calendar.startOfDay(for: baseDate)
            let endDate = calendar.date(byAdding: .day, value: 2, to: startDate) ?? baseDate
            formatter.dateFormat = "MMM d"
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)
            return "\(startStr) - \(endStr)"
        case .week:
            let weekOfYear = calendar.component(.weekOfYear, from: baseDate)
            let weekYear = calendar.component(.yearForWeekOfYear, from: baseDate)
            return "\(weekYear) Week \(weekOfYear)"
        }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(viewModel.centerDate)
    }

    private var headerOverlay: some View {
        TimelineSceneHeader(
            useLiquidGlassHeader: dataManager.useLiquidGlassHeader,
            headerCardHeight: headerCardHeight,
            cornerRadius: headerCornerRadius,
            viewModeLabel: viewModeLabel,
            formattedDate: formattedDate,
            isToday: isToday,
            onToday: jumpToToday,
            onAdd: { showCreateEntry = true },
            onCycleViewMode: cycleViewMode
        )
    }

    private func jumpToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        viewModel.centerDate = today
        scrollCenterDate = today
        lockedScrollCenterDate = nil
    }

    private func cycleViewMode() {
        viewModel.cycleViewMode()
        scrollCenterDate = viewModel.centerDate
        lockedScrollCenterDate = nil
    }
}
