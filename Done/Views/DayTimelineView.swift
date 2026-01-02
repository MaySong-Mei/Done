//
//  DayTimelineView.swift
//  Done
//
//  Created by Shiqi Liu on 12/25/25.
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
    @State private var currentTime = Date()
    @State private var showCreateEntry = false
    @State private var timerCancellable: AnyCancellable?
    @State private var syncTimerCancellable: AnyCancellable?
    @State private var viewMode: TimelineViewMode = .day
    @State private var leadingDate: Date? // 绑定横向滚动位置（屏幕最左列）
    @State private var stripAnchorDate: Date = Calendar.current.startOfDay(for: Date()) // 固定条带锚点，避免滚动时重建

    private let geometry = TimelineGeometry()
    private let timeAxisWidth: CGFloat = 30
    private let stripRangeDays: Int = 365 * 2 // 2 年缓冲，避免轻易触边

    private func adaptedGeometry(for columnIndex: Int) -> TimelineGeometry {
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
                                                geometry: adaptedGeometry(for: 0),
                                                viewMode: viewMode,
                                                showCurrentTime: Calendar.current.isDateInToday(date),
                                                currentTime: currentTime,
                                                isFirstColumn: false,
                                                selectedEntry: $selectedEntry
                                            )
                                            // 每个 DayColumn 占内容区的 1/dayCount 宽度，保证按“天列”对齐吸附
                                            .containerRelativeFrame(.horizontal, count: dayCount, spacing: 0)
                                            .id(date)
                                        }
                                    }
                                    .scrollTargetLayout()
                                }
                                .scrollTargetBehavior(.viewAligned)
                                .scrollIndicators(.hidden)
                                // leadingDate 作为 scrollPosition 的绑定，保持 header 与内容一致
                                .scrollPosition(id: $leadingDate, anchor: .leading)
                                .frame(width: contentWidth, height: geometry.totalHeight)
                                .clipped()
                            }
                            .frame(width: geo.size.width, height: geometry.totalHeight)
                        }
                        .onAppear {
                            stripAnchorDate = startOfDay(selectedDate) // 只在出现时固定条带中心
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
                            print("🔍 Pinch gesture: \(value), current mode: \(viewMode.displayName)")
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

}

// MARK: - Glass Segment (真玻璃组件)
struct GlassSegment: View {
    let y: CGFloat
    let height: CGFloat
    let width: CGFloat
    let tintColor: Color?
    let intensity: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat = 6

    // 确保尺寸有效
    private var safeWidth: CGFloat {
        max(1, width.isFinite ? width : 1)
    }

    private var safeHeight: CGFloat {
        max(1, height.isFinite ? height : 1)
    }

    // 根据深浅色模式调整空白段样式
    private var emptySegmentBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.10)
    }

    private var emptySegmentStripeOpacity: CGFloat {
        colorScheme == .dark ? 0.12 : 0.08
    }

    private var emptySegmentStripeColor: Color {
        colorScheme == .dark ? .white : .gray
    }

    var body: some View {
        if width > 0 && height > 0 && width.isFinite && height.isFinite {
            if let color = tintColor {
                // 有事件：彩色玻璃块（圆角）
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        // 事件颜色染色
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(color.opacity(intensity))
                            .blendMode(.plusLighter)
                    )
                    .overlay(
                        // 高光边缘（外轮廓）
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.4),
                                        .white.opacity(0.08),
                                        .white.opacity(0.15)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .overlay(
                        // 顶部高光（玻璃反光）
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.2),
                                        .white.opacity(0.04),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .blendMode(.overlay)
                    )
                    .frame(width: safeWidth, height: safeHeight)
                    .offset(x: 0, y: y)
            } else {
                // 无事件：透明底 + 斜线修饰 + 轻微描边 + 边缘内阴影（淡90%，集中在边框）
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.clear)
                    .overlay(
                        // 斜线修饰图案（根据深浅色模式调整）
                        GeometryReader { geo in
                            Canvas { context, size in
                                let spacing: CGFloat = 8
                                let lineWidth: CGFloat = 0.5

                                context.stroke(
                                    Path { path in
                                        var x: CGFloat = -size.height
                                        while x < size.width + size.height {
                                            path.move(to: CGPoint(x: x, y: 0))
                                            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                                            x += spacing
                                        }
                                    },
                                    with: .color(emptySegmentStripeColor.opacity(emptySegmentStripeOpacity)),
                                    lineWidth: lineWidth
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                emptySegmentBorderColor,
                                lineWidth: 0.3
                            )
                            .blendMode(colorScheme == .dark ? .plusLighter : .screen)
                    )
                    .innerShadow(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), color: .black.opacity(0.018), radius: 1, x: 0, y: 0.5)
                    .innerShadow(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), color: .black.opacity(0.010), radius: 0.8, x: 0.5, y: 0)
                    .compositingGroup()
                    .frame(width: safeWidth, height: max(1, safeHeight - 0.5))
                    .offset(x: 0, y: y)
            }
        }
    }
}

// MARK: - Past Time Overlay (真玻璃遮罩)
struct PastTimeOverlay: View {
    let date: Date
    let geometry: TimelineGeometry
    let width: CGFloat
    let currentTime: Date
    let entries: [TimeEntry]
    let activeEntry: TimeEntry?

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
        if shouldShowOverlay {
            ZStack(alignment: .topLeading) {
                // 绘制所有时间段（玻璃块）
                ForEach(timeSegments, id: \.id) { segment in
                    GlassSegment(
                        y: segment.y,
                        height: segment.height,
                        width: width,
                        tintColor: segment.color,
                        intensity: segment.intensity
                    )
                }
            }
            .frame(width: width, height: geometry.totalHeight, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private struct TimeSegment: Identifiable {
        let id = UUID()
        let y: CGFloat
        let height: CGFloat
        let color: Color?
        let intensity: CGFloat
    }

    private var timeSegments: [TimeSegment] {
        var segments: [TimeSegment] = []
        let calendar = Calendar.current

        // 收集所有已过去的事件段
        var eventRanges: [(start: CGFloat, end: CGFloat, color: Color, intensity: CGFloat)] = []

        for entry in entries {
            guard let endTime = entry.endTime,
                  entry.startTime < currentTime else { continue }

            let segmentStart = geometry.yPosition(for: entry.startTime)
            let segmentEnd = min(geometry.yPosition(for: endTime), elapsedHeight)

            if segmentEnd > segmentStart,
               let color = Color(hex: entry.colorHex) {
                eventRanges.append((segmentStart, segmentEnd, color, 0.18))
            }
        }

        // 添加正在进行的活动（仅今天）
        if isToday,
           let active = activeEntry,
           active.endTime == nil,
           calendar.isDate(active.startTime, inSameDayAs: date),
           active.startTime < currentTime,
           let color = Color(hex: active.colorHex) {

            let segmentStart = geometry.yPosition(for: active.startTime)
            let segmentEnd = min(geometry.yPosition(for: currentTime), elapsedHeight)

            if segmentEnd > segmentStart {
                eventRanges.append((segmentStart, segmentEnd, color, 0.28))
            }
        }

        // 合并重叠区间并创建玻璃段
        eventRanges.sort { $0.start < $1.start }

        var currentY: CGFloat = 0
        for range in eventRanges {
            // 空白段（无色玻璃）
            if range.start > currentY {
                segments.append(TimeSegment(
                    y: currentY,
                    height: range.start - currentY,
                    color: nil,
                    intensity: 0
                ))
            }

            // 事件段（染色玻璃）
            segments.append(TimeSegment(
                y: range.start,
                height: range.end - range.start,
                color: range.color,
                intensity: range.intensity
            ))

            currentY = range.end
        }

        // 最后的空白段
        if currentY < elapsedHeight {
            segments.append(TimeSegment(
                y: currentY,
                height: elapsedHeight - currentY,
                color: nil,
                intensity: 0
            ))
        }

        return segments
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
    let isFirstColumn: Bool
    @Binding var selectedEntry: TimeEntry?

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, proxy.size.width) // 用真实宽度，避免外部传 0

            ZStack(alignment: .topLeading) {
                // 背景网格（最底层）
                TimelineGrid(geometry: geometry)
                    .frame(width: columnWidth)

                // 过去时间玻璃遮罩（态势层）
                PastTimeOverlay(
                    date: date,
                    geometry: geometry,
                    width: columnWidth,
                    currentTime: currentTime,
                    entries: entries,
                    activeEntry: DataManager.shared.activeEntry
                )

                // 事件块（清晰可读层）
                ForEach(entries) { entry in
                    TimelineEventBlock(
                        entry: entry,
                        geometry: geometry,
                        availableWidth: columnWidth,
                        column: 0,
                        totalColumns: 1,
                        showsLabels: viewMode != .week,
                        selectedEntry: $selectedEntry
                    )
                }

                // 当前时间线（最上层）
                if showCurrentTime {
                    CurrentTimeLine(geometry: geometry, currentTime: currentTime)
                }
            }
            .frame(width: columnWidth, height: geometry.totalHeight, alignment: .topLeading)
        }
        .frame(height: geometry.totalHeight) // 固定高度，避免 GeometryReader 撑大
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

// MARK: - Noise Texture (程序化噪声)
struct NoiseTexture: View {
    var body: some View {
        Canvas { context, size in
            // 使用随机点阵模拟噪声（避免依赖图片资源）
            let dotSize: CGFloat = 1.5
            let spacing: CGFloat = 4

            for x in stride(from: 0, to: size.width, by: spacing) {
                for y in stride(from: 0, to: size.height, by: spacing) {
                    // 使用位置生成伪随机值（确保每次渲染一致）
                    let seed = Int(x * 1000 + y)
                    let random = Double((seed * 9301 + 49297) % 233280) / 233280.0

                    if random > 0.5 { // 50% 密度
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
            // 背景渐变
            Canvas { context, size in
                // 绘制时段背景色（根据设置决定是否显示）
                if dataManager.showDayNightBackground {
                    drawTimeBasedBackground(context: context, size: size)
                }

                // 绘制小时分隔线（虚线）
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

            // 添加细微噪声纹理（让玻璃有东西可折射）
            NoiseTexture()
                .opacity(0.04)
                .blendMode(.overlay)
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
    let showsLabels: Bool
    @Binding var selectedEntry: TimeEntry?
    @ObservedObject var dataManager = DataManager.shared

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
                Section(dataManager.wordlessMode ? "" : "Activity") {
                    if dataManager.templates.isEmpty {
                        if !dataManager.wordlessMode {
                            Text("No templates available")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        if dataManager.wordlessMode {
                            // 无字模式：只显示颜色选择器
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
                            // 正常模式：显示名称
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
                Section(dataManager.wordlessMode ? "" : "Activity") {
                    if dataManager.templates.isEmpty {
                        if !dataManager.wordlessMode {
                            Text("No templates available")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        if dataManager.wordlessMode {
                            // 无字模式：只显示颜色选择器
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
                            // 正常模式：显示名称
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

// MARK: - Inner Shadow Extension (Cross-version compatible)
extension View {
    /// Cross-version inner shadow (works on iOS 15/16/17+)
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
