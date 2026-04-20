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
    @EnvironmentObject private var authService: AuthService
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisShowProfileSummary) private var showAnalysisSummary = true
    @State private var thisWeekExpanded = false
    @State private var systemStatusExpanded = false
    @StateObject private var overviewModel: AnalysisViewModel

    init() {
        _overviewModel = StateObject(wrappedValue: AnalysisViewModel(initialPeriod: .week))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Account
                profileSection {
                    NavigationLink {
                        AccountView()
                            .environmentObject(authService)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authService.session?.user.email ?? L(.tabMe))
                                    .font(.system(size: 18, weight: .semibold))
                                Text(authService.isSignedIn ? "Sync & Account" : "Sign in to sync your data")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                // MARK: - Quick Access
                profileSection {
                    profileNavRow(
                        icon: "chart.bar.xaxis",
                        color: .blue,
                        title: L(.analysis),
                        detail: profileAnalysisDetail
                    ) {
                        AnalysisView()
                            .environmentObject(store)
                            .environmentObject(skillStore)
                    }
                    profileDivider()
                    profileNavRow(
                        icon: "gearshape.fill",
                        color: .gray,
                        title: L(.settings),
                        detail: nil
                    ) {
                        SettingsHomeView()
                            .environmentObject(store)
                            .environmentObject(agentRuntime)
                            .environmentObject(skillStore)
                            .environmentObject(authService)
                    }
                }

                // MARK: - This Week & System Status
                profileSection {
                    if showAnalysisSummary {
                        collapsibleHeaderRow(
                            icon: "chart.line.uptrend.xyaxis",
                            color: .green,
                            title: L(.thisWeek),
                            isExpanded: $thisWeekExpanded
                        )
                        if thisWeekExpanded {
                            profileDivider()
                            profileStatRow(
                                icon: "clock.fill", color: .blue,
                                title: L(.hours),
                                value: String(format: "%.1fh", overviewModel.totalScheduledHours(store: store))
                            )
                            profileDivider()
                            profileStatRow(
                                icon: "flame.fill", color: .orange,
                                title: L(.streak),
                                value: "\(overviewModel.recordStreak(store: store))\(L(.days))"
                            )
                            profileDivider()
                            profileStatRow(
                                icon: "checkmark.circle.fill", color: .green,
                                title: L(.completionRate),
                                value: String(format: "%.0f%%", overviewModel.completionRate(store: store))
                            )
                            profileDivider()
                            profileStatRow(
                                icon: "tray.full.fill", color: .pink,
                                title: L(.activeTasks),
                                value: "\(overviewModel.activeTasksCount(store: store))"
                            )
                        }
                        profileDivider()
                    }

                    collapsibleHeaderRow(
                        icon: "cpu.fill",
                        color: .purple,
                        title: L(.systemStatus),
                        isExpanded: $systemStatusExpanded
                    )
                    if systemStatusExpanded {
                        profileDivider()
                        profileStatRow(
                            icon: "cpu.fill", color: .purple,
                            title: L(.providerLabel),
                            value: providerDisplayName(selectedProvider)
                        )
                        profileDivider()
                        profileStatRow(
                            icon: "sparkles", color: .yellow,
                            title: L(.typeSuggestions),
                            value: calendarAgenticCreateEnabled ? L(.on) : L(.off)
                        )
                        profileDivider()
                        profileStatRow(
                            icon: "brain.head.profile.fill", color: .teal,
                            title: L(.learnedRulesLabel),
                            value: "\(agentRuntime.preferenceStore.listRules().count)"
                        )
                        profileDivider()
                        profileStatRow(
                            icon: "doc.text.fill", color: .indigo,
                            title: L(.insightsStored),
                            value: "\(skillStore.insights.count)"
                        )
                    }
                }
            }
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Section Builders

    private func profileSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func collapsibleHeaderRow(
        icon: String,
        color: Color,
        title: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                profileIconBadge(icon: icon, color: color)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func profileDivider() -> some View {
        Divider()
            .padding(.leading, 44)
            .padding(.vertical, 2)
    }

    // MARK: - Row Builders

    private func profileNavRow<Destination: View>(
        icon: String,
        color: Color,
        title: String,
        detail: String?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                profileIconBadge(icon: icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func profileStatRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            profileIconBadge(icon: icon, color: color)
            Text(title)
                .font(.system(size: 16))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func profileIconBadge(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var profileAnalysisDetail: String? {
        let topSkill = skillStore.aggregatedSkills(
            start: overviewModel.dateRange.start,
            end: overviewModel.dateRange.end
        ).first
        return topSkill.map { "\($0.skillName) \(String(format: "%.1f", $0.totalPoints))h" }
    }
}
