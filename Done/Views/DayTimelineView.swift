//
//  DayTimelineView.swift
//  Done
//
//  Created by Claude on 12/25/25.
//

import SwiftUI
import Combine

// MARK: - View Mode
enum TimelineViewMode: Int, CaseIterable {
    case day = 1
    case threeDays = 3
    case week = 7

    var displayName: String {
        switch self {
        case .day: return "Day"
        case .threeDays: return "3 Days"
        case .week: return "Week"
        }
    }
}

// MARK: - Timeline Geometry
struct TimelineGeometry {
    let hourHeight: CGFloat = 60
    var totalHeight: CGFloat { 24 * hourHeight }
    var leftMargin: CGFloat = 50
    var rightMargin: CGFloat = 16

    func yPosition(for date: Date) -> CGFloat {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let totalMinutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return CGFloat(totalMinutes / 60.0) * hourHeight
    }

    func height(from start: Date, to end: Date) -> CGFloat {
        let duration = end.timeIntervalSince(start) / 3600.0
        return max(CGFloat(duration) * hourHeight, 20)
    }
}

// MARK: - Main View
struct DayTimelineView: View {
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var calendarService = GoogleCalendarService.shared
    @State private var selectedDate = Date()
    @State private var selectedEntry: TimeEntry?
    @State private var currentTime = Date()
    @State private var showCreateEntry = false
    @State private var timerCancellable: AnyCancellable?
    @State private var syncTimerCancellable: AnyCancellable?
    @State private var viewMode: TimelineViewMode = .day
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private let geometry = TimelineGeometry()

    private func adaptedGeometry(for columnIndex: Int) -> TimelineGeometry {
        var geo = geometry
        // 所有列都没有leftMargin，因为时间轴已经固定在左侧
        geo.leftMargin = 0
        geo.rightMargin = 0
        return geo
    }

    private var displayDates: [Date] {
        let calendar = Calendar.current
        let dayCount = viewMode.rawValue
        let baseDate = calendar.startOfDay(for: selectedDate)

        // 包含前一天、当前范围、后一天，用于滑动效果
        return (-1..<(dayCount + 1)).map { offset in
            calendar.date(byAdding: .day, value: offset, to: baseDate)!
        }
    }

    private var visibleDateIndices: Range<Int> {
        // 实际显示的日期索引（不包括前后的缓冲日期）
        let dayCount = viewMode.rawValue
        return 1..<(dayCount + 1)
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

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // 顶部日期栏（只显示可见的日期）
                    HStack(spacing: 0) {
                        // 左侧占位（与时间轴同宽）
                        Color.clear
                            .frame(width: 50)

                        ForEach(Array(visibleDateIndices), id: \.self) { index in
                            let date = displayDates[index]
                            let dayWidth: CGFloat = {
                                let totalWidth = geo.size.width
                                let columnCount = CGFloat(viewMode.rawValue)
                                let timeAxisWidth: CGFloat = 50
                                let contentTotalWidth = totalWidth - timeAxisWidth
                                return contentTotalWidth / columnCount
                            }()

                            DateHeaderView(date: date, width: dayWidth)
                        }
                    }
                    .frame(height: 40)
                    .background(Color(.systemBackground))
                    .overlay(alignment: .trailing) {
                        // Today按钮覆盖在右侧
                        if !isToday {
                            Button("Today") {
                                withAnimation {
                                    selectedDate = Date()
                                }
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .padding(.trailing, 16)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 0) {
                                        ForEach(displayDates.indices, id: \.self) { index in
                                            let date = displayDates[index]

                                            // 计算列宽：所有列宽度相同
                                            let dayWidth: CGFloat = {
                                                let totalWidth = geo.size.width
                                                let columnCount = CGFloat(viewMode.rawValue)
                                                let timeAxisWidth: CGFloat = 50

                                                // 内容区总宽度（扣除时间轴）
                                                let contentTotalWidth = totalWidth - timeAxisWidth
                                                // 每列内容宽度
                                                return contentTotalWidth / columnCount
                                            }()

                                            DayColumn(
                                                date: date,
                                                entries: entriesForDate(date),
                                                geometry: adaptedGeometry(for: index),
                                                width: dayWidth,
                                                showCurrentTime: Calendar.current.isDateInToday(date),
                                                currentTime: currentTime,
                                                isFirstColumn: false,
                                                selectedEntry: $selectedEntry
                                            )
                                        }
                                    }
                                    .frame(height: geometry.totalHeight)
                                    .offset(x: calculateTimelineOffset(screenWidth: geo.size.width))
                                    .id("timeline")
                                }
                            }
                            .onAppear {
                                let targetHour = isToday ? Calendar.current.component(.hour, from: Date()) : 8
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation {
                                        proxy.scrollTo("hour-\(targetHour)", anchor: .center)
                                    }
                                }
                            }
                        }

                        // 固定的时间轴（覆盖在左侧）
                        VStack(spacing: 0) {
                            // 顶部占位（与日期栏同高）
                            Color.clear
                                .frame(height: 40)

                            // 时间轴
                            TimelineAxis(geometry: geometry)
                        }
                    }
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onEnded { value in
                            print("🔍 Pinch gesture: \(value), current mode: \(viewMode.displayName)")
                            handleMagnificationGesture(value)
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            // 只处理主要是水平方向的拖拽
                            if abs(value.translation.width) > abs(value.translation.height) {
                                isDragging = true
                                dragOffset = value.translation.width
                            }
                        }
                        .onEnded { value in
                            handleSwipeEnd(translation: value.translation, velocity: value.predictedEndTranslation)
                        }
                )
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showCreateEntry = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                TimeEntryEditView(entry: entry)
            }
            .sheet(isPresented: $showCreateEntry) {
                TimeEntryCreateView(selectedDate: selectedDate)
            }
            .onAppear {
                startTimer()
                startSyncTimer()
                // 立即检查一次未同步的事件
                Task {
                    await calendarService.syncPendingEntries()
                }
            }
            .onDisappear {
                stopTimer()
                stopSyncTimer()
            }
        }
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [self] _ in
                currentTime = Date()
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    private func startSyncTimer() {
        // 每30分钟检查一次未同步的事件
        syncTimerCancellable = Timer.publish(every: 1800, on: .main, in: .common)
            .autoconnect()
            .sink { [self] _ in
                Task {
                    await calendarService.syncPendingEntries()
                }
            }
    }

    private func stopSyncTimer() {
        syncTimerCancellable?.cancel()
        syncTimerCancellable = nil
    }

    // MARK: - Gesture Handling
    private func handleMagnificationGesture(_ value: CGFloat) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if value < 0.95 {
                // 缩小：查看更多天
                switch viewMode {
                case .day:
                    viewMode = .threeDays
                    print("✅ Switched to 3 Days")
                case .threeDays:
                    viewMode = .week
                    print("✅ Switched to Week")
                case .week:
                    print("⚠️ Already at Week view")
                }
            } else if value > 1.05 {
                // 放大：查看更少天
                switch viewMode {
                case .week:
                    viewMode = .threeDays
                    print("✅ Switched to 3 Days")
                case .threeDays:
                    viewMode = .day
                    print("✅ Switched to Day")
                case .day:
                    print("⚠️ Already at Day view")
                }
            } else {
                print("ℹ️ Magnification \(value) within threshold (0.95-1.05), no change")
            }
        }
    }

    private func calculateTimelineOffset(screenWidth: CGFloat) -> CGFloat {
        // 计算初始offset，让第一天（索引1）显示在屏幕上
        let timeAxisWidth: CGFloat = 50
        let contentTotalWidth = screenWidth - timeAxisWidth
        let contentWidth = contentTotalWidth / CGFloat(viewMode.rawValue)

        // 基础offset：向左移动一个列宽，让索引1的列显示在最左边
        // 同时加上时间轴宽度，让内容显示在时间轴右侧
        let baseOffset = -contentWidth + timeAxisWidth

        // 加上拖拽offset
        return baseOffset + dragOffset
    }

    private func handleSwipeEnd(translation: CGSize, velocity: CGSize) {
        let threshold: CGFloat = 100 // 切换日期的距离阈值
        let velocityThreshold: CGFloat = 500 // 速度阈值

        let calendar = Calendar.current
        let shouldChangePage = abs(translation.width) > threshold || abs(velocity.width) > velocityThreshold

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if shouldChangePage {
                if translation.width > 0 {
                    // 向右滑动：切换到前一天
                    selectedDate = calendar.date(byAdding: .day, value: -1, to: selectedDate)!
                    print("⬅️ Swiped to previous day")
                } else {
                    // 向左滑动：切换到后一天
                    selectedDate = calendar.date(byAdding: .day, value: 1, to: selectedDate)!
                    print("➡️ Swiped to next day")
                }
            }

            // 重置状态
            dragOffset = 0
            isDragging = false
        }
    }
}

// MARK: - Day Column
struct DayColumn: View {
    let date: Date
    let entries: [TimeEntry]
    let geometry: TimelineGeometry
    let width: CGFloat
    let showCurrentTime: Bool
    let currentTime: Date
    let isFirstColumn: Bool
    @Binding var selectedEntry: TimeEntry?

    var body: some View {
        ZStack(alignment: .topLeading) {
                // 背景网格
                TimelineGrid(geometry: geometry)
                    .frame(width: width)

                // 事件块
                ForEach(entries) { entry in
                    TimelineEventBlock(
                        entry: entry,
                        geometry: geometry,
                        availableWidth: width,
                        column: 0,
                        totalColumns: 1,
                        selectedEntry: $selectedEntry
                    )
                }

                // 当前时间线
                if showCurrentTime {
                    CurrentTimeLine(geometry: geometry, currentTime: currentTime)
                }
            }
            .frame(width: width)
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

// MARK: - Layouted Entry
struct LayoutedEntry: Identifiable {
    let entry: TimeEntry
    var column: Int
    var totalColumns: Int

    var id: UUID { entry.id }
}

// MARK: - Timeline Axis
struct TimelineAxis: View {
    let geometry: TimelineGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: 0) {
                    Text(formatHour(hour))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .padding(.trailing, 8)

                    Spacer()
                }
                .frame(height: geometry.hourHeight, alignment: .top)
                .id("hour-\(hour)")
            }
        }
    }

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:00"
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return formatter.string(from: date)
    }
}

// MARK: - Timeline Grid
struct TimelineGrid: View {
    let geometry: TimelineGeometry

    var body: some View {
        Canvas { context, size in
            // 绘制时段背景色
            drawTimeBasedBackground(context: context, size: size)

            // 绘制小时分隔线
            for hour in 0..<24 {
                let y = CGFloat(hour) * geometry.hourHeight
                let path = Path { p in
                    p.move(to: CGPoint(x: geometry.leftMargin, y: y))
                    p.addLine(to: CGPoint(x: size.width - geometry.rightMargin, y: y))
                }
                context.stroke(
                    path,
                    with: .color(.gray.opacity(0.3)),
                    lineWidth: 0.5
                )
            }
        }
        .frame(height: geometry.totalHeight)
    }

    private func drawTimeBasedBackground(context: GraphicsContext, size: CGSize) {
        // 时段定义
        let sunrise = 6.0      // 日出 6:00
        let dayStart = 7.0     // 白天开始 7:00
        let duskStart = 18.0   // 黄昏开始 18:00
        let nightStart = 20.0  // 夜晚开始 20:00

        // 颜色定义（很淡的颜色）
        let nightColor = Color(red: 0.93, green: 0.94, blue: 0.96)    // 很淡的蓝灰（雾蓝）
        let dayColor = Color(red: 0.99, green: 0.98, blue: 0.95)      // 很淡的暖色（米白）
        let duskColor = Color(red: 0.99, green: 0.95, blue: 0.93)     // 很淡的橙粉（杏色）

        let contentX = geometry.leftMargin
        let contentWidth = size.width - geometry.leftMargin - geometry.rightMargin

        // 夜晚 (0:00 - 6:00)
        let night1Height = sunrise * geometry.hourHeight
        context.fill(
            Path(CGRect(x: contentX, y: 0, width: contentWidth, height: night1Height)),
            with: .color(nightColor)
        )

        // 日出渐变 (6:00 - 7:00)
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

        // 白天 (7:00 - 18:00)
        let dayY = dayStart * geometry.hourHeight
        let dayHeight = (duskStart - dayStart) * geometry.hourHeight
        context.fill(
            Path(CGRect(x: contentX, y: dayY, width: contentWidth, height: dayHeight)),
            with: .color(dayColor)
        )

        // 黄昏渐变 (18:00 - 20:00)
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

        // 夜晚 (20:00 - 24:00)
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
    @Binding var selectedEntry: TimeEntry?

    var body: some View {
        if let endTime = entry.endTime {
            let startY = geometry.yPosition(for: entry.startTime)
            let height = geometry.height(from: entry.startTime, to: endTime)

            // 计算可用区域（时间轴右侧的空间）- 防止负数
            let contentWidth = max(0, availableWidth - geometry.leftMargin - geometry.rightMargin)

            // 计算当前事件的宽度和X偏移 - 防止负数/NaN
            let blockWidth = max(0, contentWidth / CGFloat(totalColumns))
            let xOffset = geometry.leftMargin + (blockWidth * CGFloat(column))

            VStack(alignment: .leading, spacing: 4) {
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
            .padding(8)
            .frame(width: max(1, blockWidth - 4), height: height, alignment: .topLeading)
            .background(Color(hex: entry.colorHex) ?? .blue)
            .cornerRadius(6)
            .offset(x: xOffset + 2, y: startY)
            .onTapGesture {
                selectedEntry = entry
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

// MARK: - Time Entry Edit View
struct TimeEntryEditView: View {
    let entry: TimeEntry
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    @State private var selectedTemplate: ActivityTemplate?
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDeleteConfirmation = false

    init(entry: TimeEntry) {
        self.entry = entry
        _startTime = State(initialValue: entry.startTime)
        _endTime = State(initialValue: entry.endTime ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    if dataManager.templates.isEmpty {
                        Text("No templates available")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Template", selection: $selectedTemplate) {
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

                Section("Time") {
                    DatePicker("Start", selection: $startTime)
                    DatePicker("End", selection: $endTime)

                    if let duration = calculateDuration() {
                        LabeledContent("Duration", value: duration.formatAsHoursMinutes())
                            .foregroundColor(.secondary)
                    }
                }

                if entry.syncedToCalendar {
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

                Section {
                    Button("Delete Entry", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChanges() }
                        .disabled(selectedTemplate == nil)
                }
            }
            .onAppear {
                // 查找匹配的模板
                selectedTemplate = dataManager.templates.first { $0.id == entry.templateId }
                    ?? dataManager.templates.first { $0.name == entry.templateName }
            }
            .onChange(of: startTime) { _, _ in
                validateTimes()
            }
            .onChange(of: endTime) { _, _ in
                validateTimes()
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    dataManager.deleteTimeEntry(entry)
                    dismiss()
                }
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

    private func saveChanges() {
        guard let template = selectedTemplate else { return }

        guard endTime > startTime else {
            showError = true
            errorMessage = "End time must be after start time"
            return
        }

        // 创建更新后的条目（保留原ID和同步状态）
        let updatedEntry = TimeEntry(
            id: entry.id,
            templateId: template.id,
            templateName: template.name,
            startTime: startTime,
            endTime: endTime,
            colorHex: template.colorHex,
            syncedToCalendar: entry.syncedToCalendar,
            calendarEventId: entry.calendarEventId
        )

        dataManager.updateTimeEntry(updatedEntry)
        dismiss()
    }
}

// MARK: - Time Entry Create View
struct TimeEntryCreateView: View {
    let selectedDate: Date
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    @State private var selectedTemplate: ActivityTemplate?
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showError = false
    @State private var errorMessage = ""

    init(selectedDate: Date) {
        self.selectedDate = selectedDate

        let calendar = Calendar.current
        let now = Date()

        // 如果选择的是今天，使用当前时间；否则使用选定日期的8:00
        if calendar.isDateInToday(selectedDate) {
            _startTime = State(initialValue: now)
            _endTime = State(initialValue: calendar.date(byAdding: .hour, value: 1, to: now)!)
        } else {
            let dayStart = calendar.startOfDay(for: selectedDate)
            let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart)!
            _startTime = State(initialValue: start)
            _endTime = State(initialValue: calendar.date(byAdding: .hour, value: 1, to: start)!)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    if dataManager.templates.isEmpty {
                        Text("No templates available")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Template", selection: $selectedTemplate) {
                            Text("Select an activity").tag(nil as ActivityTemplate?)
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

                Section("Time") {
                    DatePicker("Start", selection: $startTime)
                    DatePicker("End", selection: $endTime)

                    if let duration = calculateDuration() {
                        LabeledContent("Duration", value: duration.formatAsHoursMinutes())
                            .foregroundColor(.secondary)
                    }
                }

                if showError {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEntry() }
                        .disabled(selectedTemplate == nil)
                }
            }
            .onChange(of: startTime) { _, _ in
                validateTimes()
            }
            .onChange(of: endTime) { _, _ in
                validateTimes()
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

        let entry = TimeEntry(
            templateId: template.id,
            templateName: template.name,
            startTime: startTime,
            endTime: endTime,
            colorHex: template.colorHex,
            syncedToCalendar: false,
            calendarEventId: nil
        )

        dataManager.addTimeEntry(entry)
        dismiss()
    }
}

#Preview {
    DayTimelineView()
}
