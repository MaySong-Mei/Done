//
//  AnalysisView.swift
//  Done
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AnalysisContentView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var skillStore: SkillInsightStore
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false
    @StateObject private var viewModel: AnalysisViewModel
    @State private var suggestions: [AISuggestion] = []
    @State private var isLoadingSuggestions = false
    private let suggestionService = AnalysisSuggestionService()

    private var dateSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.offset += dx < 0 ? 1 : -1
                }
            }
    }

    init() {
        _viewModel = StateObject(wrappedValue: AnalysisViewModel())
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("Period", selection: $viewModel.period) {
                ForEach(AnalysisPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.period) { _, _ in
                viewModel.offset = 0
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(viewModel.periodLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.offset != 0 {
                        Button(L(.today)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.offset = 0
                            }
                        }
                        .font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dateSwipeGesture)

                let allocations = viewModel.typeAllocations(store: store)
                let dailyData = viewModel.dailyHoursData(store: store)
                if !allocations.isEmpty || !dailyData.isEmpty {
                    NavigationLink {
                        TimeAllocationDetailView(initialPeriod: viewModel.period)
                            .environmentObject(store)
                    } label: {
                        HoursChartPager(
                            allocations: allocations,
                            dailyData: dailyData,
                            period: viewModel.period
                        )
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 16) {
                    let trendData = viewModel.taskCompletionTrend(store: store)
                    if trendData.contains(where: { $0.count > 0 }) {
                        Divider()
                        TaskCompletionTrendChart(data: trendData)
                    }

                    Divider()
                    let range = viewModel.dateRange
                    let skillAggregates = skillStore.aggregatedSkills(start: range.start, end: range.end)
                    SkillPanel(data: skillAggregates)

                    Divider()
                    AISuggestionsCard(
                        suggestions: suggestions,
                        isLoading: isLoadingSuggestions,
                        onRefresh: { loadSuggestions() },
                        onAddEvent: { addSuggestedEvent($0) }
                    )
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dateSwipeGesture)
            }
        }
        .task(id: autoLoadSuggestions) {
            triggerSuggestionLoadIfNeeded()
        }
    }

    // MARK: - AI Suggestions

    private func loadSuggestions() {
        guard !isLoadingSuggestions else { return }
        isLoadingSuggestions = true
        Task {
            let result = await suggestionService.generateSuggestions(store: store, viewModel: viewModel)
            await MainActor.run {
                suggestions = result
                isLoadingSuggestions = false
            }
        }
    }

    private func triggerSuggestionLoadIfNeeded() {
        guard autoLoadSuggestions, suggestions.isEmpty, !isLoadingSuggestions else { return }
        loadSuggestions()
    }

    private func addSuggestedEvent(_ suggested: SuggestedEvent) {
        let calendar = Calendar.current
        let now = Date()
        let roundedMinute = (calendar.component(.minute, from: now) / 15 + 1) * 15
        let start = calendar.date(bySettingHour: calendar.component(.hour, from: now),
                                  minute: roundedMinute, second: 0, of: now) ?? now
        let end = start.addingTimeInterval(Double(suggested.durationMinutes) * 60)

        let event = Event(
            title: suggested.title,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: suggested.type
        )
        store.addCalendarEvent(event)
    }
}

struct AnalysisDetailView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var skillStore: SkillInsightStore

    var body: some View {
        ScrollView {
            AnalysisContentView()
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TimeAllocationDetailView: View {
    @EnvironmentObject var store: EventStore
    @StateObject private var viewModel: AnalysisViewModel

    init(initialPeriod: AnalysisPeriod = .week) {
        let vm = AnalysisViewModel()
        vm.period = initialPeriod
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PeriodSelector(viewModel: viewModel)

                let allocations = viewModel.typeAllocations(store: store)
                let dailyData = viewModel.dailyHoursData(store: store)
                HoursChartPager(
                    allocations: allocations,
                    dailyData: dailyData,
                    period: viewModel.period
                )
            }
            .padding(16)
        }
        .navigationTitle("Time Allocation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PeriodSelector: View {
    @ObservedObject var viewModel: AnalysisViewModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("Period", selection: $viewModel.period) {
                ForEach(AnalysisPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.period) { _, _ in
                viewModel.offset = 0
            }

            HStack {
                Button { viewModel.offset -= 1 } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(viewModel.periodLabel)
                        .font(.headline)
                    if viewModel.offset != 0 {
                        Button(L(.today)) {
                            viewModel.offset = 0
                        }
                        .font(.caption)
                    }
                }

                Spacer()

                Button { viewModel.offset += 1 } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

struct ProfileHubView: View {
    @Binding var selectedTab: RootTab
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var authService: AuthService

    @StateObject private var weekViewModel = AnalysisViewModel(initialPeriod: .week)
    @AppStorage("mcpURL") private var mcpURL: String = ""
    @AppStorage("meDisplayName") private var displayName: String = ""
    @AppStorage("meAvatarHue") private var avatarHue: Double = -1
    @AppStorage("meBackgroundTypes") private var backgroundTypesRaw: String = "Sleep,睡眠,睡觉,Rest,Eat,Meal,吃饭,Commute,Transit,通勤"
    @State private var isEditingProfile = false

    private var backgroundTypeSet: Set<String> {
        Set(backgroundTypesRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        )
    }

    private func isBackground(_ type: String) -> Bool {
        backgroundTypeSet.contains(type.lowercased())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                nowSection
                thisWeekSection
                if !mcpURL.isEmpty {
                    connectionsSection
                }
                recentlyEarnedSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $isEditingProfile) {
            ProfileEditSheet(
                displayName: $displayName,
                avatarHue: $avatarHue,
                backgroundTypesRaw: $backgroundTypesRaw,
                fallbackName: fallbackNameFromAuth(),
                allTypes: knownTypeNames()
            )
            .presentationDetents([.large])
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            SwiftUI.GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Text(L(.tabMe))
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(Capsule())
                        .background(Color.black.opacity(0.001), in: Capsule())
                        .glassEffect(.regular, in: Capsule())
                    Spacer(minLength: 0)
                    NavigationLink {
                        SettingsHomeView()
                            .environmentObject(store)
                            .environmentObject(agentRuntime)
                            .environmentObject(skillStore)
                            .environmentObject(authService)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        let descriptors = topDescriptors()
        let name = effectiveName()

        return Button {
            isEditingProfile = true
        } label: {
            HStack(alignment: .center, spacing: 14) {
                avatarCircle(name: name, hue: avatarHue >= 0 ? avatarHue : nil, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if descriptors.isEmpty {
                        Text("Done is learning who you are.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(descriptors.joined(separator: " · "))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Now

    @ViewBuilder
    private var nowSection: some View {
        let waitingCount = store.activeEvents.filter { $0.linkedCalendarEventId == nil }.count
        let toReviewCount = unreviewedCount()

        if waitingCount > 0 || toReviewCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                sectionHeader("Now")
                    .padding(.top, 4)

                if waitingCount > 0 {
                    Button {
                        selectedTab = .wanna
                    } label: {
                        NowRow(
                            icon: "sparkles",
                            tint: .orange,
                            title: "\(waitingCount) wanna\(waitingCount == 1 ? "" : "s") waiting",
                            subtitle: "Push to calendar when ready"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if toReviewCount > 0 {
                    NowRow(
                        icon: "circle.dotted.circle",
                        tint: .blue,
                        title: "\(toReviewCount) event\(toReviewCount == 1 ? "" : "s") to review",
                        subtitle: "Past 7 days, no log yet"
                    )
                }
            }
        }
    }

    private func unreviewedCount() -> Int {
        let calendar = Calendar.current
        let now = Date()
        guard let weekStart = calendar.date(byAdding: .day, value: -7, to: now) else { return 0 }
        let logged = Set(store.calendarEventLogRecords.map(\.eventID))
        let recentDone = store.events.filter {
            $0.status == .completed
                && ($0.completeAt ?? .distantPast) >= weekStart
                && ($0.completeAt ?? .distantFuture) <= now
                && !logged.contains($0.id)
        }
        return recentDone.count
    }

    // MARK: - This Week

    private var thisWeekSection: some View {
        let doneCount = weekViewModel.tasksCompletedCount(store: store)
        let allAllocations = weekViewModel.typeAllocations(store: store)
        let allDaily = weekViewModel.dailyHoursData(store: store)
        let activeHours = allAllocations
            .filter { !isBackground($0.type) }
            .reduce(0) { $0 + $1.hours }
        let weekStart = weekViewModel.dateRange.start
        let bgPredicate: (String) -> Bool = { isBackground($0) }

        return VStack(alignment: .leading, spacing: 14) {
            Divider()
            sectionHeader("This week")
                .padding(.top, 4)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1fh", activeHours))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                Text("active")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .baselineOffset(2)
                Text("·")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("\(doneCount) done")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            WeekHeatmapView(daily: allDaily, weekStart: weekStart, isBackground: bgPredicate)
                .padding(.top, 4)

            if !allAllocations.isEmpty {
                TypeStackedBar(allocations: allAllocations, isBackground: bgPredicate)
                    .padding(.top, 2)
            }

            ReflectionPromptField()
                .padding(.top, 6)

            HStack(spacing: 16) {
                NavigationLink {
                    AnalysisDetailView()
                        .environmentObject(store)
                        .environmentObject(skillStore)
                } label: {
                    seeMoreLabel("See analysis")
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                shareButton(
                    totalHours: activeHours,
                    doneCount: doneCount,
                    daily: allDaily,
                    weekStart: weekStart
                )
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func shareButton(
        totalHours: Double,
        doneCount: Int,
        daily: [DailyHours],
        weekStart: Date
    ) -> some View {
        let card = WeeklyShareCard(
            name: effectiveName(),
            descriptors: topDescriptors(),
            hue: avatarHue >= 0 ? avatarHue : nil,
            totalHours: totalHours,
            doneCount: doneCount,
            daily: daily,
            weekStart: weekStart,
            weekLabel: weekViewModel.periodLabel
        )
        if let image = renderShareImage(card) {
            let item = WeeklyShareItem(image: image)
            ShareLink(item: item, preview: SharePreview("This week on Done", image: item)) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Share")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        }
    }

    @MainActor
    private func renderShareImage(_ card: WeeklyShareCard) -> UIImage? {
        let renderer = ImageRenderer(content: card.frame(width: 360, height: 450))
        renderer.scale = 3
        return renderer.uiImage
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            sectionHeader("Connections")
                .padding(.top, 4)
            NavigationLink {
                ConnectionsView()
                    .environmentObject(authService)
            } label: {
                MCPMonitorCard()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recently Earned

    @ViewBuilder
    private var recentlyEarnedSection: some View {
        let achievements = AchievementCatalog.compute(store: store, skillStore: skillStore)
        let recent = achievements
            .filter { $0.unlocked }
            .sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
            .prefix(3)

        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader("Recently earned")
                    Spacer()
                    NavigationLink {
                        TrophyView()
                            .environmentObject(store)
                            .environmentObject(skillStore)
                    } label: {
                        HStack(spacing: 2) {
                            Text("All")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
                VStack(spacing: 8) {
                    ForEach(Array(recent), id: \.id) { achievement in
                        AchievementRow(achievement: achievement)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func avatarCircle(name: String, hue overrideHue: Double?, size: CGFloat) -> some View {
        let initial = name.first.map(String.init)?.uppercased() ?? "?"
        let hue = overrideHue ?? (Double(abs(name.hashValue) % 360) / 360.0)
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.78),
                        Color(hue: hue, saturation: 0.65, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private func effectiveName() -> String {
        if !displayName.isEmpty { return displayName }
        return fallbackNameFromAuth()
    }

    private func knownTypeNames() -> [String] {
        var hoursByType: [String: Double] = [:]
        for event in store.calendarEvents {
            let type = event.type.isEmpty ? "Other" : event.type
            for range in event.timeRanges {
                let hours = max(0, range.end.timeIntervalSince(range.start)) / 3600
                hoursByType[type, default: 0] += hours
            }
        }
        return hoursByType
            .sorted { $0.value > $1.value }
            .map { $0.key }
    }

    private func fallbackNameFromAuth() -> String {
        if let email = authService.session?.user.email {
            let base = String(email.split(separator: "@").first ?? Substring(email))
            guard !base.isEmpty else { return L(.tabMe) }
            return base.prefix(1).capitalized + base.dropFirst()
        }
        return L(.tabMe)
    }

    private func topDescriptors() -> [String] {
        let calendar = Calendar.current
        let now = Date()
        guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return [] }
        var hoursByType: [String: Double] = [:]
        for event in store.calendarEvents {
            let type = event.type.isEmpty ? "Other" : event.type
            if isBackground(type) { continue }
            for range in event.timeRanges {
                if range.end < start || range.start > now { continue }
                let lo = max(range.start, start)
                let hi = min(range.end, now)
                let hours = max(0, hi.timeIntervalSince(lo)) / 3600
                hoursByType[type, default: 0] += hours
            }
        }
        return hoursByType
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func seeMoreLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 14, weight: .medium))
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Week Heatmap

private struct WeekHeatmapView: View {
    let daily: [DailyHours]
    let weekStart: Date
    let isBackground: (String) -> Bool

    private let cellHeight: CGFloat = 48

    var body: some View {
        let calendar = Calendar.current
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let aggregated = aggregateByDay()
        let weekMaxTotal = aggregated.values.map(\.totalHours).max() ?? 1

        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let key = calendar.startOfDay(for: day)
                    let entry = aggregated[key]
                    DayHeatmapCell(
                        totalHours: entry?.totalHours ?? 0,
                        segments: entry?.segments ?? [],
                        weekMax: weekMaxTotal,
                        cellHeight: cellHeight
                    )
                }
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    Text(weekdayLabel(for: day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func aggregateByDay() -> [Date: (totalHours: Double, segments: [DaySegment])] {
        let calendar = Calendar.current
        var byDay: [Date: [String: (hours: Double, color: Color)]] = [:]
        for entry in daily {
            let key = calendar.startOfDay(for: entry.date)
            var bucket = byDay[key, default: [:]]
            var (hours, color) = bucket[entry.type] ?? (0, entry.color)
            hours += entry.hours
            color = entry.color
            bucket[entry.type] = (hours, color)
            byDay[key] = bucket
        }
        var result: [Date: (totalHours: Double, segments: [DaySegment])] = [:]
        for (day, types) in byDay {
            let total = types.values.reduce(0) { $0 + $1.hours }
            let bgSegs = types
                .filter { isBackground($0.key) }
                .map { DaySegment(type: $0.key, hours: $0.value.hours, color: $0.value.color, isBackground: true) }
                .sorted { $0.hours > $1.hours }
            let activeSegs = types
                .filter { !isBackground($0.key) }
                .map { DaySegment(type: $0.key, hours: $0.value.hours, color: $0.value.color, isBackground: false) }
                .sorted { $0.hours > $1.hours }
            // background renders at top of fill (fades upward), active anchors at bottom (visible)
            result[day] = (total, bgSegs + activeSegs)
        }
        return result
    }

    private func weekdayLabel(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: day)
    }
}

private struct DaySegment: Identifiable {
    let id = UUID()
    let type: String
    let hours: Double
    let color: Color
    let isBackground: Bool
}

private struct DayHeatmapCell: View {
    let totalHours: Double
    let segments: [DaySegment]
    let weekMax: Double
    let cellHeight: CGFloat

    var body: some View {
        let fillFraction = weekMax > 0 ? min(1.0, totalHours / weekMax) : 0
        let fillHeight = cellHeight * fillFraction

        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.gray.opacity(0.08))

            if totalHours > 0 {
                VStack(spacing: 0) {
                    ForEach(segments) { seg in
                        Rectangle()
                            .fill(seg.color.opacity(seg.isBackground ? 0.32 : 0.95))
                            .frame(height: fillHeight * (seg.hours / totalHours))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - Type Stacked Bar

private struct TypeStackedBar: View {
    let allocations: [TypeAllocation]
    let isBackground: (String) -> Bool
    private let displayLimit = 6

    var body: some View {
        let top = Array(allocations.prefix(displayLimit))
        let total = top.reduce(0) { $0 + $1.hours }

        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(top) { alloc in
                        let frac = total > 0 ? alloc.hours / total : 0
                        let width = max(0, geo.size.width * frac - 2)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(alloc.color.opacity(isBackground(alloc.type) ? 0.35 : 0.95))
                            .frame(width: width)
                    }
                }
            }
            .frame(height: 8)

            FlowingTags(items: top, isBackground: isBackground)
        }
    }
}

private struct FlowingTags: View {
    let items: [TypeAllocation]
    let isBackground: (String) -> Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { alloc in
                let bg = isBackground(alloc.type)
                HStack(spacing: 5) {
                    Circle()
                        .fill(alloc.color.opacity(bg ? 0.35 : 1.0))
                        .frame(width: 6, height: 6)
                    Text(alloc.type)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(bg ? .tertiary : .secondary)
                }
            }
        }
    }
}

// MARK: - Reflection Prompt

private struct ReflectionPromptField: View {
    @State private var draft: String = ""
    @State private var saved: Bool = false
    @AppStorage("meReflectionLog") private var log: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if saved {
                    Text("Saved.")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                } else {
                    TextField("What stood out this week?", text: $draft)
                        .font(.system(size: 14))
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { persist() }
                }
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private func persist() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        log = log.isEmpty ? "\(stamp)\t\(trimmed)" : log + "\n\(stamp)\t\(trimmed)"
        draft = ""
        isFocused = false
        withAnimation(.easeInOut(duration: 0.25)) { saved = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) { saved = false }
            }
        }
    }
}

// MARK: - MCP Monitor Card

private struct MCPMonitorCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text("Claude")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Can read your last 7 days to help you plan.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Achievements

struct Achievement: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let unlocked: Bool
    let unlockedAt: Date?
    let progress: Double
    let progressLabel: String
}

enum AchievementCatalog {
    static func compute(store: EventStore, skillStore: SkillInsightStore) -> [Achievement] {
        let completed = store.events
            .filter { $0.status == .completed && $0.completeAt != nil }
            .sorted { ($0.completeAt ?? .distantPast) < ($1.completeAt ?? .distantPast) }
        let count = completed.count

        var items: [Achievement] = []

        // First Done
        items.append(makeFirstDone(completed: completed))

        // Done milestones
        for milestone in [10, 100, 1000] {
            items.append(makeDoneMilestone(milestone: milestone, completed: completed, count: count))
        }

        // Skills
        let insights = skillStore.insights.sorted { $0.date < $1.date }
        let distinctSkills = Set(insights.map(\.skillName))
        for milestone in [1, 5, 10] {
            items.append(makeSkillMilestone(milestone: milestone, insights: insights, distinct: distinctSkills))
        }

        // Type variety
        let distinctTypes = Set(store.calendarEvents.map { $0.type.isEmpty ? "Other" : $0.type })
        for milestone in [3, 10] {
            let unlocked = distinctTypes.count >= milestone
            items.append(Achievement(
                id: "types_\(milestone)",
                title: milestone == 3 ? "Variety" : "\(milestone) Types",
                subtitle: "\(milestone) different types of activity",
                icon: "circle.grid.3x3.fill",
                unlocked: unlocked,
                unlockedAt: nil,
                progress: min(1, Double(distinctTypes.count) / Double(milestone)),
                progressLabel: "\(distinctTypes.count) / \(milestone)"
            ))
        }

        return items
    }

    private static func makeFirstDone(completed: [Event]) -> Achievement {
        if let first = completed.first {
            return Achievement(
                id: "first_done",
                title: "First Done",
                subtitle: "Completed your first event",
                icon: "checkmark.seal.fill",
                unlocked: true,
                unlockedAt: first.completeAt,
                progress: 1,
                progressLabel: ""
            )
        }
        return Achievement(
            id: "first_done",
            title: "First Done",
            subtitle: "Complete your first event",
            icon: "checkmark.seal",
            unlocked: false,
            unlockedAt: nil,
            progress: 0,
            progressLabel: "0 / 1"
        )
    }

    private static func makeDoneMilestone(milestone: Int, completed: [Event], count: Int) -> Achievement {
        let unlocked = count >= milestone
        let date = unlocked ? completed[milestone - 1].completeAt : nil
        return Achievement(
            id: "done_\(milestone)",
            title: "\(milestone) Done",
            subtitle: "\(milestone) events completed",
            icon: unlocked ? "checkmark.circle.fill" : "checkmark.circle",
            unlocked: unlocked,
            unlockedAt: date,
            progress: min(1, Double(count) / Double(milestone)),
            progressLabel: "\(count) / \(milestone)"
        )
    }

    private static func makeSkillMilestone(milestone: Int, insights: [SkillInsight], distinct: Set<String>) -> Achievement {
        let unlocked = distinct.count >= milestone
        var unlockDate: Date? = nil
        if unlocked {
            var seen: Set<String> = []
            for insight in insights {
                if seen.insert(insight.skillName).inserted, seen.count == milestone {
                    unlockDate = insight.date
                    break
                }
            }
        }
        return Achievement(
            id: "skills_\(milestone)",
            title: milestone == 1 ? "First Skill" : "\(milestone) Skills",
            subtitle: "\(milestone) different skills tracked",
            icon: unlocked ? "sparkles" : "sparkles",
            unlocked: unlocked,
            unlockedAt: unlockDate,
            progress: min(1, Double(distinct.count) / Double(milestone)),
            progressLabel: "\(distinct.count) / \(milestone)"
        )
    }
}

private struct AchievementRow: View {
    let achievement: Achievement

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.18))
                Image(systemName: achievement.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(achievement.title)
                    .font(.system(size: 14, weight: .semibold))
                if let date = achievement.unlockedAt {
                    Text(relativeDateString(from: date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct TrophyView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var skillStore: SkillInsightStore

    var body: some View {
        let achievements = AchievementCatalog.compute(store: store, skillStore: skillStore)
        let unlocked = achievements
            .filter { $0.unlocked }
            .sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
        let locked = achievements
            .filter { !$0.unlocked }
            .sorted { $0.progress > $1.progress }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !unlocked.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Unlocked")
                        ForEach(unlocked) { TrophyCard(achievement: $0) }
                    }
                }
                if !locked.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("In progress")
                        ForEach(locked) { TrophyCard(achievement: $0) }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Trophies")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

private struct TrophyCard: View {
    let achievement: Achievement

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(achievement.unlocked ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.12))
                Image(systemName: achievement.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(achievement.unlocked ? .orange : .secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(achievement.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(achievement.unlocked ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if achievement.unlocked, let date = achievement.unlockedAt {
                        Text(relativeDateString(from: date))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                Text(achievement.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

                if !achievement.unlocked {
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.gray.opacity(0.15))
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(0, geo.size.width * achievement.progress), height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text(achievement.progressLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Now Row

private struct NowRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Profile Edit Sheet

private struct ProfileEditSheet: View {
    @Binding var displayName: String
    @Binding var avatarHue: Double
    @Binding var backgroundTypesRaw: String
    let fallbackName: String
    let allTypes: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var draftName: String = ""
    @State private var draftHue: Double = 0
    @State private var draftBackground: Set<String> = []
    @FocusState private var nameFocused: Bool

    private let presetHues: [Double] = [
        0.05, 0.10, 0.15,
        0.32, 0.50, 0.58,
        0.65, 0.78, 0.92
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    avatarPreview
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)
                        TextField(fallbackName, text: $draftName)
                            .font(.system(size: 17))
                            .focused($nameFocused)
                            .submitLabel(.done)
                        Rectangle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: 0.5)
                    }
                    .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("COLOR")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 9), spacing: 10) {
                            ForEach(presetHues, id: \.self) { hue in
                                Button {
                                    draftHue = hue
                                } label: {
                                    Circle()
                                        .fill(LinearGradient(
                                            colors: [
                                                Color(hue: hue, saturation: 0.55, brightness: 0.78),
                                                Color(hue: hue, saturation: 0.65, brightness: 0.55)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ))
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary, lineWidth: abs(draftHue - hue) < 0.001 ? 2 : 0)
                                        )
                                        .aspectRatio(1, contentMode: .fit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 4)

                    if !allTypes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HIDE FROM ME TAB")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.6)
                            Text("Background time like sleep, meals, commute. Counted but not shown in identity visuals.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.bottom, 4)
                            VStack(spacing: 0) {
                                ForEach(allTypes, id: \.self) { type in
                                    HStack {
                                        Text(type)
                                            .font(.system(size: 14))
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { draftBackground.contains(type.lowercased()) },
                                            set: { newValue in
                                                if newValue {
                                                    draftBackground.insert(type.lowercased())
                                                } else {
                                                    draftBackground.remove(type.lowercased())
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                    .padding(.vertical, 8)
                                    if type != allTypes.last {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.06))
                                            .frame(height: 0.5)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        displayName = trimmed
                        avatarHue = draftHue
                        backgroundTypesRaw = draftBackground.sorted().joined(separator: ",")
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            draftName = displayName
            draftHue = avatarHue >= 0 ? avatarHue : presetHues.first!
            nameFocused = displayName.isEmpty
            draftBackground = Set(
                backgroundTypesRaw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            )
        }
    }

    private var avatarPreview: some View {
        let name = draftName.isEmpty ? fallbackName : draftName
        let initial = name.first.map(String.init)?.uppercased() ?? "?"
        let hue = draftHue
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.78),
                        Color(hue: hue, saturation: 0.65, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initial)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 88, height: 88)
    }
}

// MARK: - Weekly Share Card

struct WeeklyShareCard: View {
    let name: String
    let descriptors: [String]
    let hue: Double?
    let totalHours: Double
    let doneCount: Int
    let daily: [DailyHours]
    let weekStart: Date
    let weekLabel: String

    var body: some View {
        let bgHue = hue ?? (Double(abs(name.hashValue) % 360) / 360.0)
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: bgHue, saturation: 0.20, brightness: 0.97),
                    Color(hue: bgHue, saturation: 0.40, brightness: 0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    avatar(size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.85))
                        if !descriptors.isEmpty {
                            Text(descriptors.joined(separator: " · "))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.black.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("THIS WEEK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.5))
                        .tracking(1.0)
                    Text(weekLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black.opacity(0.55))
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%.1f", totalHours))
                        .font(.system(size: 56, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black.opacity(0.9))
                    Text("hours")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.black.opacity(0.55))
                    Spacer()
                }
                Text("\(doneCount) event\(doneCount == 1 ? "" : "s") completed")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.black.opacity(0.55))

                heatmapStrip
                    .padding(.top, 4)

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Text("done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.4))
                        .tracking(2.0)
                }
            }
            .padding(28)
        }
        .frame(width: 360, height: 450)
    }

    private func avatar(size: CGFloat) -> some View {
        let initial = name.first.map(String.init)?.uppercased() ?? "?"
        let avatarHue = hue ?? (Double(abs(name.hashValue) % 360) / 360.0)
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [
                        Color(hue: avatarHue, saturation: 0.55, brightness: 0.78),
                        Color(hue: avatarHue, saturation: 0.65, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var heatmapStrip: some View {
        let calendar = Calendar.current
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let aggregated = aggregateByDay()

        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let key = calendar.startOfDay(for: day)
                    let entry = aggregated[key]
                    let hours = entry?.hours ?? 0
                    let opacity = max(0, min(1, hours / 8))
                    let color = entry?.color ?? Color.black.opacity(0.4)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color.opacity(0.25 + opacity * 0.6))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    Text(weekdayLabel(for: day))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.black.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func aggregateByDay() -> [Date: (hours: Double, color: Color)] {
        let calendar = Calendar.current
        var byDay: [Date: [String: (hours: Double, color: Color)]] = [:]
        for entry in daily {
            let key = calendar.startOfDay(for: entry.date)
            var bucket = byDay[key, default: [:]]
            var (hours, color) = bucket[entry.type] ?? (0, entry.color)
            hours += entry.hours
            color = entry.color
            bucket[entry.type] = (hours, color)
            byDay[key] = bucket
        }
        var result: [Date: (hours: Double, color: Color)] = [:]
        for (day, types) in byDay {
            let total = types.values.reduce(0) { $0 + $1.hours }
            let dominant = types.max(by: { $0.value.hours < $1.value.hours })
            result[day] = (total, dominant?.value.color ?? Color.gray)
        }
        return result
    }

    private func weekdayLabel(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: day)
    }
}

// MARK: - Weekly Share Item (Transferable)

struct WeeklyShareItem: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.image.pngData() ?? Data()
        }
    }
}
