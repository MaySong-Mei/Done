//
//  AnalysisView.swift
//  Done
//

import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var skillStore: SkillInsightStore
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false
    @StateObject private var viewModel: AnalysisViewModel
    @State private var suggestions: [AISuggestion] = []
    @State private var isLoadingSuggestions = false
    private let suggestionService = AnalysisSuggestionService()

    init() {
        _viewModel = StateObject(wrappedValue: AnalysisViewModel())
    }

    var body: some View {
        let tokenAnalysis = viewModel.displayedTokenHypothesisAnalysis(store: store)
        let tokenRefreshSignature = viewModel.tokenHypothesisRefreshSignature(store: store)
        let suggestionRefreshSignature = "\(tokenRefreshSignature)-\(autoLoadSuggestions)"

        ScrollView {
            VStack(spacing: 20) {
                periodSelector

                TokenHypothesisSection(
                    analysis: tokenAnalysis,
                    period: viewModel.period,
                    isRefreshing: viewModel.isRefreshingTokenHypothesisAnalysis
                )

                AnalysisSummaryCards(
                    recordRate: viewModel.recordRate(store: store),
                    streak: viewModel.recordStreak(store: store),
                    rate: viewModel.completionRate(store: store),
                    active: viewModel.activeTasksCount(store: store)
                )

                let allocations = viewModel.typeAllocations(store: store)
                let dailyData = viewModel.dailyHoursData(store: store)
                if !allocations.isEmpty || !dailyData.isEmpty {
                    HoursChartPager(
                        allocations: allocations,
                        dailyData: dailyData,
                        period: viewModel.period
                    )
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
            .padding()
        }
        .navigationTitle(L(.analysis))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.period) { _, _ in
            viewModel.offset = 0
            viewModel.invalidateTokenHypothesisAnalysis()
            suggestions = []
        }
        .onChange(of: viewModel.offset) { _, _ in
            viewModel.invalidateTokenHypothesisAnalysis()
            suggestions = []
        }
        .task(id: tokenRefreshSignature) {
            await viewModel.refreshTokenHypothesisAnalysis(store: store)
        }
        .task(id: suggestionRefreshSignature) {
            triggerSuggestionLoadIfNeeded()
        }
    }

    private var periodSelector: some View {
        VStack(spacing: 12) {
            Picker("Period", selection: $viewModel.period) {
                ForEach(AnalysisPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { viewModel.offset -= 1 } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(viewModel.periodLabel)
                        .font(.system(size: 15, weight: .semibold))
                    if viewModel.offset != 0 {
                        Button(L(.today)) {
                            viewModel.offset = 0
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                }

                Spacer()

                Button { viewModel.offset += 1 } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
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

struct ProfileHubView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisShowProfileSummary) private var showAnalysisSummary = true
    @StateObject private var overviewModel: AnalysisViewModel

    init() {
        _overviewModel = StateObject(wrappedValue: AnalysisViewModel(initialPeriod: .week))
    }

    var body: some View {
        let topSkill = skillStore.aggregatedSkills(
            start: overviewModel.dateRange.start,
            end: overviewModel.dateRange.end
        ).first

        ScrollView {
            VStack(spacing: 20) {
                profileHeaderCard(topSkill: topSkill)
                quickLinksSection

                if showAnalysisSummary {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeader(L(.thisWeek))
                        AnalysisSummaryCards(
                            recordRate: overviewModel.recordRate(store: store),
                            streak: overviewModel.recordStreak(store: store),
                            rate: overviewModel.completionRate(store: store),
                            active: overviewModel.activeTasksCount(store: store)
                        )
                        if let topSkill {
                            insightCard(
                                title: L(.topSkill),
                                detail: "\(topSkill.skillName) \(L(.skillLeadsWeek)) \(String(format: "%.1f", topSkill.totalPoints))h"
                            )
                        } else {
                            insightCard(
                                title: L(.noSkillData),
                                detail: L(.completeToSeeWeekly)
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(L(.systemStatus))
                    profileStatusCard(
                        title: L(.aiAndAgent),
                        rows: [
                            (L(.providerLabel), providerDisplayName(selectedProvider)),
                            (L(.typeSuggestions), calendarAgenticCreateEnabled ? L(.on) : L(.off)),
                            (L(.learnedRulesLabel), "\(agentRuntime.preferenceStore.listRules().count)")
                        ]
                    )
                    profileStatusCard(
                        title: L(.defaults),
                        rows: [
                            (L(.analysisPeriod), defaultPeriodRawValue),
                            (L(.insightsStored), "\(skillStore.insights.count)"),
                            (L(.pendingDecisions), "\(agentRuntime.decisionCenter.pendingCount)")
                        ]
                    )
                }
            }
            .padding()
        }
        .navigationTitle(L(.tabMe))
        .navigationBarTitleDisplayMode(.large)
    }

    private func profileHeaderCard(topSkill: SkillAggregate?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L(.profileSubtitle))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 16) {
                profileMetric(title: L(.hours), value: overviewModel.totalScheduledHours(store: store), suffix: "h")
                profileMetric(title: L(.active), value: Double(overviewModel.activeTasksCount(store: store)), suffix: "")
                profileMetric(title: L(.streak), value: Double(overviewModel.recordStreak(store: store)), suffix: "d")
            }

            Text(topSkill.map { "\(L(.momentumStrongest)) \($0.skillName)." } ?? L(.useSettingsHint))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.16), Color.teal.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(L(.explore))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                NavigationLink {
                    AnalysisView()
                        .environmentObject(store)
                        .environmentObject(skillStore)
                } label: {
                    profileNavigationCard(
                        title: L(.analysis),
                        detail: L(.analysisSummary),
                        icon: "chart.bar.xaxis",
                        color: .blue
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    SettingsHomeView()
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .environmentObject(skillStore)
                } label: {
                    profileNavigationCard(
                        title: L(.settings),
                        detail: L(.settingsSummary),
                        icon: "gearshape",
                        color: .orange
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileMetric(title: String, value: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(metricString(value, suffix: suffix))
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricString(_ value: Double, suffix: String) -> String {
        if suffix == "h" {
            return String(format: "%.1f%@", value, suffix)
        }
        return "\(Int(value))\(suffix)"
    }

    private func profileNavigationCard(
        title: String,
        detail: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func profileStatusCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                        .font(.system(size: 14, weight: .medium))
                }
                .font(.system(size: 14))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func insightCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
