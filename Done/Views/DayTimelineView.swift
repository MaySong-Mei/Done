//
//  DayTimelineView.swift
//  Done
//
//  Created by Claude on 12/25/25.
//

import SwiftUI
import Combine

// MARK: - Timeline Geometry
struct TimelineGeometry {
    let hourHeight: CGFloat = 60
    let totalHeight: CGFloat = 1440  // 24 * 60
    let leftMargin: CGFloat = 50
    let rightMargin: CGFloat = 16

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
    @State private var selectedDate = Date()
    @State private var selectedEntry: TimeEntry?
    @State private var currentTime = Date()
    @State private var showDatePicker = false
    @State private var showCreateEntry = false
    @State private var timerCancellable: AnyCancellable?

    private let geometry = TimelineGeometry()

    private var todayEntries: [TimeEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return dataManager.getEntriesForDateRange(start: start, end: end)
            .filter { $0.endTime != nil }
    }

    private var layoutedEntries: [LayoutedEntry] {
        layoutOverlappingEvents(todayEntries)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DayNavigationBar(
                    selectedDate: $selectedDate,
                    showDatePicker: $showDatePicker
                )

                ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                TimelineGrid(geometry: geometry)

                                TimelineAxis(geometry: geometry)

                                ForEach(layoutedEntries) { layouted in
                                    TimelineEventBlock(
                                        entry: layouted.entry,
                                        geometry: geometry,
                                        availableWidth: geo.size.width,
                                        column: layouted.column,
                                        totalColumns: layouted.totalColumns,
                                        selectedEntry: $selectedEntry
                                    )
                                }

                                if isToday {
                                    CurrentTimeLine(geometry: geometry, currentTime: currentTime)
                                }
                            }
                            .frame(height: geometry.totalHeight)
                            .id("timeline")
                        }
                        .frame(height: geometry.totalHeight)
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
                TimeEntryDetailView(entry: entry)
            }
            .sheet(isPresented: $showCreateEntry) {
                TimeEntryCreateView(selectedDate: selectedDate)
            }
            .sheet(isPresented: $showDatePicker) {
                NavigationStack {
                    DatePicker("Select Date", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("Select Date")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showDatePicker = false }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
            .onAppear {
                startTimer()
            }
            .onDisappear {
                stopTimer()
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

    // MARK: - Overlap Layout Algorithm
    private func layoutOverlappingEvents(_ entries: [TimeEntry]) -> [LayoutedEntry] {
        guard !entries.isEmpty else { return [] }

        // 按开始时间排序
        let sorted = entries.sorted { $0.startTime < $1.startTime }

        var result: [LayoutedEntry] = []
        var currentGroup: [TimeEntry] = []
        var maxEndTime: Date?

        for entry in sorted {
            guard let endTime = entry.endTime else { continue }

            // 检查是否需要处理当前组（新事件不与当前组冲突）
            if let maxEnd = maxEndTime, entry.startTime >= maxEnd {
                // 处理当前组
                result.append(contentsOf: layoutGroup(currentGroup))

                // 开始新组
                currentGroup = [entry]
                maxEndTime = endTime
            } else {
                // 加入当前组，更新最大结束时间
                currentGroup.append(entry)
                maxEndTime = max(maxEndTime ?? endTime, endTime)
            }
        }

        // 处理最后一组
        if !currentGroup.isEmpty {
            result.append(contentsOf: layoutGroup(currentGroup))
        }

        return result
    }

    private func layoutGroup(_ group: [TimeEntry]) -> [LayoutedEntry] {
        guard !group.isEmpty else { return [] }

        // 单个事件直接返回
        if group.count == 1 {
            return [LayoutedEntry(entry: group[0], column: 0, totalColumns: 1)]
        }

        // 为组内事件分配列
        var columns: [[TimeEntry]] = []
        var entryToColumn: [UUID: Int] = [:]

        for entry in group {
            guard let endTime = entry.endTime else { continue }

            // 找到第一个不冲突的列
            var assignedColumn = -1
            for (colIndex, column) in columns.enumerated() {
                let conflicts = column.contains { existing in
                    guard let existingEnd = existing.endTime else { return false }
                    return entry.startTime < existingEnd && endTime > existing.startTime
                }

                if !conflicts {
                    assignedColumn = colIndex
                    columns[colIndex].append(entry)
                    break
                }
            }

            // 如果没有找到不冲突的列，创建新列
            if assignedColumn == -1 {
                assignedColumn = columns.count
                columns.append([entry])
            }

            entryToColumn[entry.id] = assignedColumn
        }

        // 一次性生成LayoutedEntry，使用正确的totalColumns
        let totalColumns = columns.count
        return group.compactMap { entry in
            guard let column = entryToColumn[entry.id] else { return nil }
            return LayoutedEntry(entry: entry, column: column, totalColumns: totalColumns)
        }
    }
}

// MARK: - Layouted Entry
struct LayoutedEntry: Identifiable {
    let entry: TimeEntry
    var column: Int
    var totalColumns: Int

    var id: UUID { entry.id }
}

// MARK: - Day Navigation Bar
struct DayNavigationBar: View {
    @Binding var selectedDate: Date
    @Binding var showDatePicker: Bool

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: previousDay) {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .foregroundColor(.primary)
            }

            Spacer()

            Button(action: { showDatePicker = true }) {
                Text(formatDate(selectedDate))
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            Spacer()

            Button(action: nextDay) {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .foregroundColor(.primary)
            }

            if !isToday {
                Button("Today") {
                    withAnimation {
                        selectedDate = Date()
                    }
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    private func previousDay() {
        withAnimation {
            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)!
        }
    }

    private func nextDay() {
        withAnimation {
            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate)!
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
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
                    with: .color(Color(.separator).opacity(0.5)),
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

            // 计算可用区域（时间轴右侧的空间）
            let contentWidth = availableWidth - geometry.leftMargin - geometry.rightMargin

            // 计算当前事件的宽度和X偏移
            let blockWidth = contentWidth / CGFloat(totalColumns)
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
            .frame(width: blockWidth - 4, height: height, alignment: .topLeading)
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

// MARK: - Time Entry Detail View
struct TimeEntryDetailView: View {
    let entry: TimeEntry
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Activity") {
                    HStack {
                        Circle()
                            .fill(Color(hex: entry.colorHex) ?? .blue)
                            .frame(width: 12, height: 12)
                        Text(entry.templateName)
                            .font(.headline)
                    }
                }

                Section("Time") {
                    LabeledContent("Start", value: formatDateTime(entry.startTime))
                    if let endTime = entry.endTime {
                        LabeledContent("End", value: formatDateTime(endTime))
                        LabeledContent("Duration", value: entry.durationString)
                    } else {
                        LabeledContent("Status", value: "In Progress")
                    }
                }

                if entry.syncedToCalendar {
                    Section("Sync") {
                        Label("Synced to Google Calendar", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                Section {
                    Button("Delete Entry", role: .destructive) {
                        dataManager.deleteTimeEntry(entry)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Entry Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
