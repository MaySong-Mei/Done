//
//  AnalysisView.swift
//  Done
//

import SwiftUI

struct AnalysisContentView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var skillStore: SkillInsightStore
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false
    @StateObject private var viewModel: AnalysisViewModel
    @State private var suggestions: [AISuggestion] = []
    @State private var isLoadingSuggestions = false
    @State private var hoursPagerFrame: CGRect = .zero
    private let suggestionService = AnalysisSuggestionService()

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
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: HoursPagerFrameKey.self,
                                    value: proxy.frame(in: .global)
                                )
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    .onPreferenceChange(HoursPagerFrameKey.self) { hoursPagerFrame = $0 }
                }

                let trendData = viewModel.taskCompletionTrend(store: store)
                if trendData.contains(where: { $0.count > 0 }) {
                    TaskCompletionTrendChart(data: trendData)
                }

                let range = viewModel.dateRange
                let skillAggregates = skillStore.aggregatedSkills(start: range.start, end: range.end)
                SkillPanel(data: skillAggregates)

                AISuggestionsCard(
                    suggestions: suggestions,
                    isLoading: isLoadingSuggestions,
                    onRefresh: { loadSuggestions() },
                    onAddEvent: { addSuggestedEvent($0) }
                )
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .simultaneousGesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .global)
                    .onEnded { value in
                        // Ignore swipes that started inside the HoursChartPager —
                        // those are reserved for switching cards in the carousel.
                        if hoursPagerFrame.contains(value.startLocation) { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.offset += dx < 0 ? 1 : -1
                        }
                    }
            )
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

private struct HoursPagerFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
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
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        ScrollView {
            AnalysisContentView()
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
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
}
