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
    @State private var selectedDate = Date()
    @State private var selectedEntry: TimeEntry?
    @State private var showCreateEntry = false
    @State private var viewMode: TimelineViewMode = .day
    @State private var leadingDate: Date?
    @State private var stripAnchorDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var syncTask: Task<Void, Never>?

    private let geometry = TimelineGeometry()
    private let timeAxisWidth: CGFloat = 30
    private let stripRangeDays: Int = 365

    private var contentGeometry: TimelineGeometry {
        var geo = geometry
        geo.leftMargin = 0
        geo.rightMargin = 2
        return geo
    }

    private var dayCount: Int { viewMode.rawValue }

    private func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
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
        let base = leadingDate ?? startOfDay(selectedDate)
        return (0..<dayCount).compactMap { i in
            cal.date(byAdding: .day, value: i, to: base)
        }
    }

    private func entriesForDate(_ date: Date) -> [TimeEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!

        return dataManager.getEntriesForDateRange(start: start, end: end)
            .filter { $0.endTime != nil }
            .sorted { $0.startTime < $1.startTime }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var formattedDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        switch viewMode {
        case .day:
            // Single day: "Monday, Jan 2"
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: selectedDate)

        case .threeDays:
            // Three days: "Jan 2 - Jan 4"
            let startDate = calendar.startOfDay(for: selectedDate)
            let endDate = calendar.date(byAdding: .day, value: 2, to: startDate)!
            formatter.dateFormat = "MMM d"
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)
            return "\(startStr) - \(endStr)"

        case .week:
            // Week view: "2026 Week 1"
            let weekOfYear = calendar.component(.weekOfYear, from: selectedDate)
            let weekYear = calendar.component(.yearForWeekOfYear, from: selectedDate)
            return "\(weekYear) Week \(weekOfYear)"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date

            NavigationStack {
                GeometryReader { geo in
                    let contentWidth = geo.size.width - timeAxisWidth

                    VStack(spacing: 0) {
                        ScrollViewReader { vProxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                HStack(spacing: 0) {
                                    TimelineAxis(geometry: geometry)
                                        .frame(width: timeAxisWidth, height: geometry.totalHeight, alignment: .top)
                                        .background(Color(.systemBackground))
                                        .zIndex(10)
                                        .allowsHitTesting(false)

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
                                                    selectedEntry: $selectedEntry
                                                )
                                                .containerRelativeFrame(.horizontal, count: dayCount, spacing: 0)
                                                .id(date)
                                            }
                                        }
                                        .scrollTargetLayout()
                                    }
                                    .scrollTargetBehavior(.viewAligned)
                                    .scrollIndicators(.hidden)
                                    .scrollPosition(id: $leadingDate, anchor: .leading)
                                    .frame(width: contentWidth, height: geometry.totalHeight)
                                    .clipped()
                                }
                                .frame(width: geo.size.width, height: geometry.totalHeight)
                            }
                            .onAppear {
                                stripAnchorDate = startOfDay(selectedDate)
                                leadingDate = startOfDay(selectedDate)
                                let targetHour = isToday ? Calendar.current.component(.hour, from: Date()) : 8
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation {
                                        vProxy.scrollTo("hour-\(targetHour)", anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        if viewMode != .day {
                            headerBar(contentWidth: contentWidth)
                                .frame(height: 40)
                                .background(.ultraThinMaterial)
                                .mask(
                                    LinearGradient(
                                        colors: [
                                            .black,
                                            .black,
                                            .black.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onEnded { value in
                                handleMagnificationGesture(value)
                            }
                    )
                    .onChange(of: leadingDate) { _, newValue in
                        guard let newValue else { return }
                        selectedDate = startOfDay(newValue)
                    }
                    .onChange(of: viewMode) { _, _ in
                        leadingDate = startOfDay(selectedDate)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top) {
                    HStack(spacing: 0) {
                        Text(formattedDate)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.leading, timeAxisWidth)

                        Spacer()

                        if !isToday {
                            Button("Today") {
                                withAnimation { leadingDate = startOfDay(Date()) }
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .padding(.trailing, 12)
                        }

                        Button(action: { showCreateEntry = true }) {
                            Image(systemName: "plus")
                        }
                        .padding(.trailing, 16)
                    }
                    .frame(height: 44)
                    .background(Color(.systemBackground))
                }
                .sheet(item: $selectedEntry) { entry in
                    TimeEntryEditView(entry: entry)
                }
                .sheet(isPresented: $showCreateEntry) {
                    TimeEntryCreateView(selectedDate: selectedDate)
                }
                .onAppear {
                    syncTask?.cancel()
                    syncTask = Task {
                        while !Task.isCancelled {
                            await calendarService.syncPendingEntries()
                            try? await Task.sleep(nanoseconds: 1_800_000_000_000)
                        }
                    }
                }
                .onDisappear {
                    syncTask?.cancel()
                    syncTask = nil
                }
            }
        }
    }

    @ViewBuilder
    private func headerBar(contentWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeAxisWidth)

            let colWidth = contentWidth / CGFloat(dayCount)
            ForEach(currentVisibleDates, id: \.self) { date in
                DateHeaderView(date: date, width: colWidth)
            }
        }
    }

    // MARK: - Gesture Handling
    private func handleMagnificationGesture(_ value: CGFloat) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if value < 0.95 {
                switch viewMode {
                case .day:
                    viewMode = .threeDays
                case .threeDays:
                    viewMode = .week
                case .week:
                    print("Already at Week view")
                }
            } else if value > 1.05 {
                switch viewMode {
                case .week:
                    viewMode = .threeDays
                case .threeDays:
                    viewMode = .day
                case .day:
                    print("Already at Day view")
                }
            } else {
                print("No change")
            }
        }
    }

}

// MARK: - Past Time Overlay
struct PastTimeOverlay: View {
    let date: Date
    let geometry: TimelineGeometry
    let width: CGFloat
    let currentTime: Date

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var isPast: Bool {
        Calendar.current.compare(date, to: Date(), toGranularity: .day) == .orderedAscending
    }

    private var shouldShowOverlay: Bool {
        isToday || isPast
    }

    private var elapsedHeight: CGFloat {
        if isPast {
            return geometry.totalHeight
        } else if isToday {
            return geometry.yPosition(for: currentTime)
        } else {
            return 0
        }
    }

    var body: some View {
        if shouldShowOverlay && elapsedHeight > 0 {
            ZStack(alignment: .topLeading) {
                glassBase
                    .frame(width: width, height: elapsedHeight)

                StripeOverlay()
                    .frame(width: width, height: elapsedHeight)
            }
            .frame(width: width, height: geometry.totalHeight, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private var glassBase: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .blendMode(.screen)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    private struct StripeOverlay: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Canvas { context, size in
                let spacing: CGFloat = 8
                let lineWidth: CGFloat = 0.5
                let color: Color = (colorScheme == .dark ? Color.white : Color.gray)
                    .opacity(colorScheme == .dark ? 0.12 : 0.08)

                context.stroke(
                    Path { path in
                        var x: CGFloat = -size.height
                        while x < size.width + size.height {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                            x += spacing
                        }
                    },
                    with: .color(color),
                    lineWidth: lineWidth
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Day Column
struct DayColumn: View {
    let date: Date
    let entries: [TimeEntry]
    let geometry: TimelineGeometry
    let viewMode: TimelineViewMode
    let showCurrentTime: Bool
    let currentTime: Date
    @Binding var selectedEntry: TimeEntry?

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, proxy.size.width)

            ZStack(alignment: .topLeading) {
                TimelineGrid(geometry: geometry)
                    .frame(width: columnWidth)

                PastTimeOverlay(
                    date: date,
                    geometry: geometry,
                    width: columnWidth,
                    currentTime: currentTime
                )

            ForEach(entries) { entry in
                TimelineEventBlock(
                    entry: entry,
                    geometry: geometry,
                    availableWidth: columnWidth,
                    column: 0,
                    totalColumns: 1,
                    showsLabels: viewMode != .week,
                    currentTime: currentTime,
                    style: .completed,
                    selectedEntry: $selectedEntry
                )
            }

            if let active = DataManager.shared.activeEntry,
               active.endTime == nil,
               Calendar.current.isDate(active.startTime, inSameDayAs: date) {
                TimelineEventBlock(
                    entry: active,
                    geometry: geometry,
                    availableWidth: columnWidth,
                    column: 0,
                    totalColumns: 1,
                    showsLabels: viewMode != .week,
                    currentTime: currentTime,
                    style: .active,
                    selectedEntry: $selectedEntry
                )
            }

                if showCurrentTime {
                    CurrentTimeLine(geometry: geometry, currentTime: currentTime)
                }
            }
            .frame(width: columnWidth, height: geometry.totalHeight, alignment: .topLeading)
        }
        .frame(height: geometry.totalHeight)
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

// MARK: - Noise Texture
struct NoiseTexture: View {
    var body: some View {
        Canvas { context, size in
            let dotSize: CGFloat = 1.5
            let spacing: CGFloat = 4

            for x in stride(from: 0, to: size.width, by: spacing) {
                for y in stride(from: 0, to: size.height, by: spacing) {
                    let seed = Int(x * 1000 + y)
                    let random = Double((seed * 9301 + 49297) % 233280) / 233280.0

                    if random > 0.5 {
                        let opacity = random * 0.8 + 0.2
                        let point = CGPoint(x: x, y: y)
                        let dotRect = CGRect(
                            x: point.x - dotSize / 2,
                            y: point.y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        context.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(.black.opacity(opacity))
                        )
                    }
                }
            }
        }
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

            NoiseTexture()
                .opacity(0.04)
                .blendMode(.overlay)
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

// MARK: - Timeline Event Block
struct TimelineEventBlock: View {
    let entry: TimeEntry
    let geometry: TimelineGeometry
    let availableWidth: CGFloat
    let column: Int
    let totalColumns: Int
    let showsLabels: Bool
    let currentTime: Date
    let style: EventStyle
    @Binding var selectedEntry: TimeEntry?
    @ObservedObject var dataManager = DataManager.shared

    enum EventStyle {
        case completed
        case active
    }

    var body: some View {
        let endTime = entry.endTime ?? currentTime
        if endTime > entry.startTime {
            let startY = geometry.yPosition(for: entry.startTime)
            let height = geometry.height(from: entry.startTime, to: endTime)

            let contentWidth = max(0, availableWidth - geometry.leftMargin - geometry.rightMargin)

            let blockWidth = max(0, contentWidth / CGFloat(totalColumns))
            let xOffset = geometry.leftMargin + (blockWidth * CGFloat(column))

            VStack(alignment: .leading, spacing: 4) {
                if showsLabels && !dataManager.wordlessMode {
                    Text(entry.templateName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if height > 40 {
                        Text(formatTimeRange(entry))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .padding(8)
            .frame(width: max(1, blockWidth - 4), height: height, alignment: .topLeading)
            .background(eventBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder((Color(hex: entry.colorHex) ?? .blue), lineWidth: style == .active ? 0.8 : 0)
            )
            .cornerRadius(6)
            .offset(x: xOffset + 2, y: startY)
            .onTapGesture {
                selectedEntry = entry
            }
        }
    }

    @ViewBuilder
    private var eventBackground: some View {
        let base = Color(hex: entry.colorHex) ?? .blue
        switch style {
        case .completed:
            base
        case .active:
            ActiveStripeFill(color: base)
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

    private func formatTimeRange(_ entry: TimeEntry) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        let start = formatter.string(from: entry.startTime)
        if let end = entry.endTime {
            let endStr = formatter.string(from: end)
            return "\(start) - \(endStr)"
        }
        return start
    }
}

// MARK: - Current Time Line
struct CurrentTimeLine: View {
    let geometry: TimelineGeometry
    let currentTime: Date

    var body: some View {
        let y = geometry.yPosition(for: currentTime)

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.red)
                .frame(height: 2)
                .offset(x: geometry.leftMargin)

            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .offset(x: geometry.leftMargin - 6)
        }
        .offset(y: y)
    }
}

// MARK: - Entry Form
struct EntryFormView: View {
    let title: String
    let initialStart: Date
    let initialEnd: Date
    let initialTemplateId: UUID?
    let initialTemplateName: String?
    let showsTemplatePlaceholder: Bool
    let showsDelete: Bool
    let showsSyncedLabel: Bool
    let onCancel: () -> Void
    let onSave: (Date, Date, ActivityTemplate) -> Void
    let onDelete: (() -> Void)?

    @StateObject private var dataManager = DataManager.shared
    @State private var selectedTemplate: ActivityTemplate?
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDeleteConfirmation = false

    init(
        title: String,
        initialStart: Date,
        initialEnd: Date,
        initialTemplateId: UUID?,
        initialTemplateName: String?,
        showsTemplatePlaceholder: Bool,
        showsDelete: Bool,
        showsSyncedLabel: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Date, Date, ActivityTemplate) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.initialTemplateId = initialTemplateId
        self.initialTemplateName = initialTemplateName
        self.showsTemplatePlaceholder = showsTemplatePlaceholder
        self.showsDelete = showsDelete
        self.showsSyncedLabel = showsSyncedLabel
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _startTime = State(initialValue: initialStart)
        _endTime = State(initialValue: initialEnd)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(dataManager.wordlessMode ? "" : "Activity") {
                    if dataManager.templates.isEmpty {
                        if !dataManager.wordlessMode {
                            Text("No templates available")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        if dataManager.wordlessMode {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(dataManager.templates) { template in
                                        Circle()
                                            .fill(Color(hex: template.colorHex) ?? .blue)
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(Color.primary, lineWidth: selectedTemplate?.id == template.id ? 3 : 0)
                                            )
                                            .onTapGesture {
                                                selectedTemplate = template
                                            }
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        } else {
                            Picker("Template", selection: $selectedTemplate) {
                                if showsTemplatePlaceholder {
                                    Text("Select an activity").tag(nil as ActivityTemplate?)
                                }
                                ForEach(dataManager.templates) { template in
                                    HStack {
                                        Circle()
                                            .fill(Color(hex: template.colorHex) ?? .blue)
                                            .frame(width: 12, height: 12)
                                        Text(template.name)
                                    }
                                    .tag(template as ActivityTemplate?)
                                }
                            }
                        }
                    }
                }

                Section("Time") {
                    DatePicker("Start", selection: $startTime)
                    DatePicker("End", selection: $endTime)

                    if let duration = calculateDuration() {
                        LabeledContent("Duration", value: duration.formatAsHoursMinutes())
                            .foregroundColor(.secondary)
                    }
                }

                if showsSyncedLabel {
                    Section("Sync") {
                        Label("Synced to Google Calendar", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                if showError {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                if showsDelete {
                    Section {
                        Button("Delete Entry", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEntry() }
                        .disabled(selectedTemplate == nil)
                }
            }
            .onAppear {
                if selectedTemplate == nil {
                    selectedTemplate = dataManager.templates.first { $0.id == initialTemplateId }
                        ?? dataManager.templates.first { $0.name == initialTemplateName }
                }
            }
            .onChange(of: startTime) { _, _ in
                validateTimes()
            }
            .onChange(of: endTime) { _, _ in
                validateTimes()
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) { onDelete?() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }

    private func calculateDuration() -> TimeInterval? {
        guard endTime > startTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    private func validateTimes() {
        if endTime <= startTime {
            showError = true
            errorMessage = "End time must be after start time"
        } else {
            showError = false
            errorMessage = ""
        }
    }

    private func saveEntry() {
        guard let template = selectedTemplate else { return }
        guard endTime > startTime else {
            showError = true
            errorMessage = "End time must be after start time"
            return
        }
        onSave(startTime, endTime, template)
    }
}

// MARK: - Time Entry Edit View
struct TimeEntryEditView: View {
    let entry: TimeEntry
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    var body: some View {
        EntryFormView(
            title: "Edit Entry",
            initialStart: entry.startTime,
            initialEnd: entry.endTime ?? Date(),
            initialTemplateId: entry.templateId,
            initialTemplateName: entry.templateName,
            showsTemplatePlaceholder: false,
            showsDelete: true,
            showsSyncedLabel: entry.syncedToCalendar,
            onCancel: { dismiss() },
            onSave: { start, end, template in
                let updatedEntry = TimeEntry(
                    id: entry.id,
                    templateId: template.id,
                    templateName: template.name,
                    startTime: start,
                    endTime: end,
                    colorHex: template.colorHex,
                    syncedToCalendar: entry.syncedToCalendar,
                    calendarEventId: entry.calendarEventId
                )
                dataManager.updateTimeEntry(updatedEntry)
                dismiss()
            },
            onDelete: {
                dataManager.deleteTimeEntry(entry)
                dismiss()
            }
        )
    }
}

// MARK: - Time Entry Create View
struct TimeEntryCreateView: View {
    let selectedDate: Date
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared
    private let initialStart: Date
    private let initialEnd: Date

    init(selectedDate: Date) {
        self.selectedDate = selectedDate

        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(selectedDate) {
            initialStart = now
            initialEnd = calendar.date(byAdding: .hour, value: 1, to: now)!
        } else {
            let dayStart = calendar.startOfDay(for: selectedDate)
            let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart)!
            initialStart = start
            initialEnd = calendar.date(byAdding: .hour, value: 1, to: start)!
        }
    }

    var body: some View {
        EntryFormView(
            title: "New Entry",
            initialStart: initialStart,
            initialEnd: initialEnd,
            initialTemplateId: nil,
            initialTemplateName: nil,
            showsTemplatePlaceholder: true,
            showsDelete: false,
            showsSyncedLabel: false,
            onCancel: { dismiss() },
            onSave: { start, end, template in
                let entry = TimeEntry(
                    templateId: template.id,
                    templateName: template.name,
                    startTime: start,
                    endTime: end,
                    colorHex: template.colorHex,
                    syncedToCalendar: false,
                    calendarEventId: nil
                )
                dataManager.addTimeEntry(entry)
                dismiss()
            }
        )
    }
}

// MARK: - Inner Shadow Extension
extension View {
    /// Cross-version inner shadow
    func innerShadow<S: Shape>(
        _ shape: S,
        color: Color = .black.opacity(0.18),
        radius: CGFloat = 3,
        x: CGFloat = 0,
        y: CGFloat = 1
    ) -> some View {
        self.overlay(
            shape
                .stroke(color, lineWidth: max(1, radius * 2))
                .blur(radius: radius)
                .offset(x: x, y: y)
                .mask(shape)
        )
    }
}

#Preview {
    DayTimelineView()
}
