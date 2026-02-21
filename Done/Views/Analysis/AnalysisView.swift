//
//  AnalysisView.swift
//  Done
//

import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var skillStore: SkillInsightStore
    @StateObject private var viewModel = AnalysisViewModel()
    @State private var suggestions: [AISuggestion] = []
    @State private var isLoadingSuggestions = false
    private let suggestionService = AnalysisSuggestionService()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                periodSelector

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
        .onChange(of: viewModel.period) { _ in
            viewModel.offset = 0
            suggestions = []
        }
        .onChange(of: viewModel.offset) { _ in
            suggestions = []
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
                        Button("Today") {
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
