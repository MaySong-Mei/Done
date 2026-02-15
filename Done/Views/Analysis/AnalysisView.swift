//
//  AnalysisView.swift
//  Done
//

import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject var store: EventStore
    @StateObject private var viewModel = AnalysisViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                periodSelector

                AnalysisSummaryCards(
                    hours: viewModel.totalScheduledHours(store: store),
                    completed: viewModel.tasksCompletedCount(store: store),
                    rate: viewModel.completionRate(store: store),
                    active: viewModel.activeTasksCount(store: store)
                )

                let allocations = viewModel.typeAllocations(store: store)
                if !allocations.isEmpty {
                    TimeAllocationChart(data: allocations)
                }

                let dailyData = viewModel.dailyHoursData(store: store)
                if !dailyData.isEmpty {
                    DailyHoursChart(data: dailyData, period: viewModel.period)
                }

                let trendData = viewModel.taskCompletionTrend(store: store)
                if trendData.contains(where: { $0.count > 0 }) {
                    TaskCompletionTrendChart(data: trendData)
                }
            }
            .padding()
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: viewModel.period) { _ in
            viewModel.offset = 0
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
}
