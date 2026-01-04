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
    private let hourHeight: CGFloat = 60
    private var totalHeight: CGFloat { 24 * hourHeight }
    private let timeAxisWidth: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            bodyScroll
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { _ in
                    // guard !isEventDragging else { return }
                    if lockedScrollCenterDate == nil {
                        lockedScrollCenterDate = scrollCenterDate ?? viewModel.centerDate
                    }
                    isMagnifying = true
                    viewModel.beginMagnification()
                }
                .onEnded { value in
                    // guard !isEventDragging else { return }
                    let lockedDate = lockedScrollCenterDate ?? viewModel.centerDate
                    viewModel.centerDate = Calendar.current.startOfDay(for: lockedDate)
                    viewModel.handleMagnificationGestureEnded(value)
                    scrollCenterDate = lockedDate
                    lockedScrollCenterDate = nil
                    isMagnifying = false
                }
        )
        .onAppear {
            eventProvider.update(entries: dataManager.timelineEntries)
            scrollCenterDate = viewModel.centerDate
        }
        .onChange(of: dataManager.timeEntries) { _, newValue in
            eventProvider.update(entries: dataManager.timelineEntries)
        }
        .sheet(isPresented: $showCreateEntry) {
            TimeEntryCreateView(selectedDate: viewModel.centerDate)
        }
    }

    // MARK: Body Scroll
    private var bodyScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            GeometryReader { proxy in
                let contentWidth = max(0, proxy.size.width - timeAxisWidth)
                HStack(spacing: 0) {
                    timeAxis
                        .frame(width: timeAxisWidth, alignment: .trailing)

                    timelineColumns(contentWidth: contentWidth)
                }
                .frame(height: totalHeight, alignment: .top)
            }
            .frame(height: totalHeight)
        }
        .scrollDisabled(isEventDragging)
    }

    // MARK: - Time Axis
    private var timeAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%d", hour))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .center)
            }
        }
        .padding(.trailing, 4)
    }

    // MARK: - Timeline Columns
    private func timelineColumns(contentWidth: CGFloat) -> some View {
        let columnWidth = contentWidth / CGFloat(max(1, viewModel.dayCount))
        let scrollPositionBinding = Binding<Date?>(
            get: { scrollCenterDate },
            set: { newValue in
                guard !isMagnifying, !isEventDragging else { return }
                scrollCenterDate = newValue
            }
        )
        return ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 0) {
                ForEach(viewModel.renderDates, id: \.self) { date in
                    timelineColumn(date: date, width: columnWidth)
                        .id(date)
                }
            }
            .scrollTargetLayout()
            .frame(height: totalHeight, alignment: .top)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: scrollPositionBinding, anchor: .center)
        .scrollDisabled(isEventDragging)
        .frame(width: contentWidth, height: totalHeight, alignment: .leading)
    }

    private func timelineColumn(date: Date, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            timelineGrid

            eventBlocks(for: date, width: width)
        }
        .frame(width: width, height: totalHeight)
    }

    // MARK: Event Blocks
    private func eventBlocks(for date: Date, width: CGFloat) -> some View {
        let entries = eventProvider.entriesForDate(date)
        return ZStack(alignment: .topLeading) {
            ForEach(entries) { entry in
                let dayStart = Calendar.current.startOfDay(for: date)
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? date
                let entryEnd = entry.endTime ?? Date()
                let start = max(entry.startTime, dayStart)
                let end = min(entryEnd, dayEnd)
                if end > start {
                    TimelineEventBlockView(
                        entry: entry,
                        renderStart: start,
                        renderEnd: end,
                        hourHeight: hourHeight,
                        availableWidth: width,
                        columnWidth: width,
                        showsLabels: viewModel.dayCount == 1,
                        type: eventProvider.type(for: entry),
                        onDragStateChanged: { isDragging in
                            isEventDragging = isDragging
                        },
                        onMove: { updatedEntry in
                            dataManager.updateTimeEntry(updatedEntry)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Timeline Grid
    private var timelineGrid: some View {
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
        .frame(height: totalHeight)
    }

    // MARK: Header Card
    private var headerCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
            .overlay(alignment: .topTrailing) {
                Button {
                    showCreateEntry = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Add entry")
            }
    }
}
