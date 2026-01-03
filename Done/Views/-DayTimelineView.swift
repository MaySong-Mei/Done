//
//  DayTimelineView.swift
//  Done
//
//  Created by Shiqi Liu on 12/25/25.
//

import SwiftUI

// MARK: - View Mode
enum TimelineViewMode: Int, CaseIterable {
    case day = 1
    case threeDays = 3
    case week = 7
}

// MARK: - Timeline Geometry
struct TimelineGeometry {
    let hourHeight: CGFloat = 60
    var totalHeight: CGFloat { 24 * hourHeight }
    var leftMargin: CGFloat = 0
    var rightMargin: CGFloat = 0

    func yPosition(for date: Date) -> CGFloat {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let totalMinutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return CGFloat(totalMinutes / 60.0) * hourHeight
    }

    func height(from start: Date, to end: Date) -> CGFloat {
        let duration = end.timeIntervalSince(start) / 3600.0
        return CGFloat(duration) * hourHeight
    }
}

// MARK: - Main View
struct DayTimelineView: View {
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var calendarService = GoogleCalendarService.shared
    @State private var selectedEntry: TimeEntry?
    @State private var showCreateEntry = false
    @State var viewMode: TimelineViewMode = .day
    @State var centerDate: Date? = Calendar.current.startOfDay(for: Date())
    @State private var syncTask: Task<Void, Never>?
    @State private var stripAnchorDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var stripUpdateTask: Task<Void, Never>?
    @State private var draftEntry: TimeEntry?
    @State private var draftEditEntry: TimeEntry?

    private let geometry = TimelineGeometry()
    private let timeAxisWidth: CGFloat = 30
    private let stripRangeDays: Int = 10

    private var contentGeometry: TimelineGeometry {
        var geo = geometry
        geo.leftMargin = 0
        geo.rightMargin = 0
        return geo
    }

    var dayCount: Int { viewMode.rawValue }

    func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    var normalizedCenterDate: Date {
        startOfDay(centerDate ?? Date())
    }

    private var stripDates: [Date] {
        let cal = Calendar.current
        let base = stripAnchorDate
        return (-stripRangeDays...stripRangeDays).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: base)
        }
    }
    
    private var currentVisibleDates: [Date] {
        let cal = Calendar.current
        let center = normalizedCenterDate
        let offset = dayCount / 2
        return (-offset...offset).compactMap { i in
            cal.date(byAdding: .day, value: i, to: center)
        }
    }

    private func entriesForDate(_ date: Date) -> [TimeEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!

        return dataManager.timeEntries
            .filter { entry in
                guard let endTime = entry.endTime else { return false }
                return entry.startTime < end && endTime > start
            }
            .sorted { $0.startTime < $1.startTime }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(normalizedCenterDate)
    }

    private var formattedDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        let baseDate = normalizedCenterDate

        switch viewMode {
        case .day:
            // Single day: "Monday, Jan 2"
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: baseDate)

        case .threeDays:
            // Three days: "Jan 2 - Jan 4"
            let startDate = calendar.startOfDay(for: baseDate)
            let endDate = calendar.date(byAdding: .day, value: 2, to: startDate)!
            formatter.dateFormat = "MMM d"
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)
            return "\(startStr) - \(endStr)"

        case .week:
            // Week view: "2026 Week 1"
            let weekOfYear = calendar.component(.weekOfYear, from: baseDate)
            let weekYear = calendar.component(.yearForWeekOfYear, from: baseDate)
            return "\(weekYear) Week \(weekOfYear)"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            timelineContent(now: context.date)
        }
    }

    @ViewBuilder
    private func timelineContent(now: Date) -> some View {
        NavigationStack {
            GeometryReader { geo in
                timelineBody(now: now, geo: geo)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedEntry) { entry in
                TimeEntryEditView(entry: entry)
            }
            .sheet(isPresented: $showCreateEntry) {
                TimeEntryCreateView(selectedDate: normalizedCenterDate)
            }
            .sheet(item: $draftEditEntry) { entry in
                TimeEntryEditView(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func timelineBody(now: Date, geo: GeometryProxy) -> some View {
        let contentWidth = geo.size.width - timeAxisWidth

        ScrollViewReader { vProxy in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(spacing: 0) {
                    TimelineAxis(geometry: geometry)
                        .frame(width: timeAxisWidth, height: geometry.totalHeight, alignment: .top)
                        .background(Color(.systemBackground))
                        .zIndex(10)
                        .allowsHitTesting(false)

                    timelineColumns(now: now, contentWidth: contentWidth)
                }
                .frame(width: geo.size.width, height: geometry.totalHeight, alignment: .top)
            }
            .onAppear {
                centerDate = normalizedCenterDate
                stripAnchorDate = normalizedCenterDate
                let targetHour = isToday ? Calendar.current.component(.hour, from: Date()) : 8
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation {
                        vProxy.scrollTo("hour-\(targetHour)", anchor: .top)
                    }
                }
            }
        }
        
        .simultaneousGesture(
            MagnificationGesture()
                .onEnded { value in
                    handleMagnificationGesture(value)
                }
        )
        .onChange(of: viewMode) { _, _ in
            centerDate = normalizedCenterDate
            stripAnchorDate = normalizedCenterDate
        }
        .onChange(of: centerDate) { _, _ in
            stripAnchorDate = normalizedCenterDate
        }
        .safeAreaInset(edge: .top) {
            TimelineHeader(
                topInset: geo.safeAreaInsets.top,
                timeAxisWidth: timeAxisWidth,
                contentWidth: contentWidth,
                viewMode: viewMode,
                formattedDate: formattedDate,
                isToday: isToday,
                dayCount: dayCount,
                currentVisibleDates: currentVisibleDates,
                onToday: {
                    withAnimation { centerDate = startOfDay(Date()) }
                },
                onAdd: { showCreateEntry = true }
            )
        }
    }

    @ViewBuilder
    private func timelineColumns(now: Date, contentWidth: CGFloat) -> some View {
        let columnWidth = contentWidth / CGFloat(max(1, dayCount))
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(stripDates, id: \.self) { date in
                    DayColumn(
                        date: date,
                        entries: entriesForDate(date),
                        geometry: contentGeometry,
                        viewMode: viewMode,
                        showCurrentTime: Calendar.current.isDateInToday(date),
                        currentTime: now,
                        selectedEntry: $selectedEntry,
                        draftEntry: $draftEntry,
                        draftEditEntry: $draftEditEntry
                    )
                    .frame(width: columnWidth, height: geometry.totalHeight)
                    .id(date)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $centerDate, anchor: .center)
        .frame(width: contentWidth, height: geometry.totalHeight)
        .clipped()
    }
}

// MARK: - Feathered Header
private struct TimelineHeader: View {
    let topInset: CGFloat
    let timeAxisWidth: CGFloat
    let contentWidth: CGFloat
    let viewMode: TimelineViewMode
    let formattedDate: String
    let isToday: Bool
    let dayCount: Int
    let currentVisibleDates: [Date]
    let onToday: () -> Void
    let onAdd: () -> Void

    private let rowHeight: CGFloat = 44
    private let headerBarHeight: CGFloat = 40
    private let topPadding: CGFloat = 2
    private let bottomPadding: CGFloat = 6
    private let bottomFade: CGFloat = 15
    private let contentLift: CGFloat = 60

    var body: some View {
        let secondaryHeight = viewMode == .day ? 0 : headerBarHeight
        let headerHeight = topInset + topPadding + rowHeight + secondaryHeight + bottomPadding
        let lift = contentLift
        let layoutHeight = max(0, headerHeight - lift)

        ZStack(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: headerHeight + bottomFade)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: bottomFade)
                    }
                }
                .ignoresSafeArea(edges: [.top, .horizontal])
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                headerTopRow
                    .frame(height: rowHeight)

                if viewMode != .day {
                    headerBar
                        .frame(height: headerBarHeight)
                }
            }
            .padding(.top, topInset + topPadding)
            .padding(.bottom, bottomPadding)
            .frame(height: headerHeight, alignment: .top)
            .offset(y: -lift)
        }
        .frame(height: layoutHeight, alignment: .top)
    }

    private var headerTopRow: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: timeAxisWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formattedDate)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()

            if !isToday {
                materialTextButton("Today", action: onToday)
            }

            materialIconButton("plus", action: onAdd)
        }
        .padding(.trailing, 12)
    }

    private var headerBar: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeAxisWidth)

            let colWidth = contentWidth / CGFloat(dayCount)
            ForEach(currentVisibleDates, id: \.self) { date in
                DateHeaderView(date: date, width: colWidth)
            }
        }
    }

    private var viewModeLabel: String {
        switch viewMode {
        case .day:
            return "Day"
        case .threeDays:
            return "3 Days"
        case .week:
            return "Week"
        }
    }

    private func materialIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .background { Circle().fill(.ultraThinMaterial) }
        .overlay { Circle().stroke(.primary.opacity(0.14), lineWidth: 0.8) }
    }

    private func materialTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .background { Capsule().fill(.ultraThinMaterial) }
        .overlay { Capsule().stroke(.primary.opacity(0.14), lineWidth: 0.8) }
    }
}

// MARK: - Date Header View
struct DateHeaderView: View {
    let date: Date
    let width: CGFloat

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter.string(from: date)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var body: some View {
        Text(dateText)
            .font(.caption)
            .fontWeight(isToday ? .bold : .regular)
            .foregroundColor(isToday ? .blue : .secondary)
            .frame(width: width)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Timeline Axis
struct TimelineAxis: View {
    let geometry: TimelineGeometry

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(formatHour(hour))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: geometry.hourHeight, alignment: .topTrailing)
                    .id("hour-\(hour)")
            }
        }
        .padding(.trailing, 4)
    }

    private func formatHour(_ hour: Int) -> String {
        String(format: "%d", hour)
    }
}

// MARK: - Timeline Grid
struct TimelineGrid: View {
    let geometry: TimelineGeometry
    @ObservedObject var dataManager = DataManager.shared

    var body: some View {
        ZStack {
            Canvas { context, size in
                if dataManager.showDayNightBackground {
                    drawTimeBasedBackground(context: context, size: size)
                }

                for hour in 0..<24 {
                    let y = CGFloat(hour) * geometry.hourHeight
                    let path = Path { p in
                        p.move(to: CGPoint(x: geometry.leftMargin, y: y))
                        p.addLine(to: CGPoint(x: size.width - geometry.rightMargin, y: y))
                    }
                    context.stroke(
                        path,
                        with: .color(.gray.opacity(0.3)),
                        style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                    )
                }
            }
        }
        .frame(height: geometry.totalHeight)
    }

    private func drawTimeBasedBackground(context: GraphicsContext, size: CGSize) {
        let sunrise = 6.0
        let dayStart = 7.0
        let duskStart = 18.0
        let nightStart = 20.0

        let nightColor = Color(red: 0.93, green: 0.94, blue: 0.96)
        let dayColor = Color(red: 0.99, green: 0.98, blue: 0.95)
        let duskColor = Color(red: 0.99, green: 0.95, blue: 0.93)

        let contentX = geometry.leftMargin
        let contentWidth = size.width - geometry.leftMargin - geometry.rightMargin

        let night1Height = sunrise * geometry.hourHeight
        context.fill(
            Path(CGRect(x: contentX, y: 0, width: contentWidth, height: night1Height)),
            with: .color(nightColor)
        )

        let sunriseY = sunrise * geometry.hourHeight
        let sunriseHeight = (dayStart - sunrise) * geometry.hourHeight
        let sunriseGradient = Gradient(colors: [nightColor, dayColor])
        context.fill(
            Path(CGRect(x: contentX, y: sunriseY, width: contentWidth, height: sunriseHeight)),
            with: .linearGradient(
                sunriseGradient,
                startPoint: CGPoint(x: contentX, y: sunriseY),
                endPoint: CGPoint(x: contentX, y: sunriseY + sunriseHeight)
            )
        )

        let dayY = dayStart * geometry.hourHeight
        let dayHeight = (duskStart - dayStart) * geometry.hourHeight
        context.fill(
            Path(CGRect(x: contentX, y: dayY, width: contentWidth, height: dayHeight)),
            with: .color(dayColor)
        )

        let duskY = duskStart * geometry.hourHeight
        let duskHeight = (nightStart - duskStart) * geometry.hourHeight
        let duskGradient = Gradient(colors: [dayColor, duskColor, nightColor])
        context.fill(
            Path(CGRect(x: contentX, y: duskY, width: contentWidth, height: duskHeight)),
            with: .linearGradient(
                duskGradient,
                startPoint: CGPoint(x: contentX, y: duskY),
                endPoint: CGPoint(x: contentX, y: duskY + duskHeight)
            )
        )

        let night2Y = nightStart * geometry.hourHeight
        let night2Height = (24 - nightStart) * geometry.hourHeight
        context.fill(
            Path(CGRect(x: contentX, y: night2Y, width: contentWidth, height: night2Height)),
            with: .color(nightColor)
        )
    }
}

#Preview {
    DayTimelineView()
}
