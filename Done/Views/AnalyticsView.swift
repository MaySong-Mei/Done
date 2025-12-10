//
//  AnalyticsView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI
import Charts

struct AnalyticsView: View {
    @StateObject private var dataManager = DataManager.shared
    @State private var selectedPeriod = Period.week

    enum Period: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"

        var dateRange: (start: Date, end: Date) {
            let calendar = Calendar.current
            let now = Date()

            switch self {
            case .week:
                let start = calendar.date(byAdding: .day, value: -7, to: now)!
                return (start, now)
            case .month:
                let start = calendar.date(byAdding: .month, value: -1, to: now)!
                return (start, now)
            case .year:
                let start = calendar.date(byAdding: .year, value: -1, to: now)!
                return (start, now)
            }
        }
    }

    var filteredEntries: [TimeEntry] {
        let (start, end) = selectedPeriod.dateRange
        return dataManager.getEntriesForDateRange(start: start, end: end)
    }

    var activitySummary: [(template: String, duration: TimeInterval, color: String)] {
        let grouped = Dictionary(grouping: filteredEntries) { $0.templateName }
        return grouped.map { (template: $0.key, duration: $0.value.compactMap { $0.duration }.reduce(0, +), color: $0.value.first?.colorHex ?? "#007AFF") }
            .sorted { $0.duration > $1.duration }
    }

    var totalDuration: TimeInterval {
        activitySummary.map { $0.duration }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Picker("Period", selection: $selectedPeriod) {
                        ForEach(Period.allCases, id: \.self) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if !filteredEntries.isEmpty {
                        VStack(spacing: 16) {
                            Text("Total: \(formatDuration(totalDuration))")
                                .font(.title2)
                                .fontWeight(.bold)

                            Chart(activitySummary, id: \.template) { item in
                                SectorMark(
                                    angle: .value("Duration", item.duration),
                                    innerRadius: .ratio(0.5),
                                    angularInset: 2
                                )
                                .foregroundStyle(Color(hex: item.color) ?? .blue)
                            }
                            .frame(height: 250)
                            .padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Breakdown")
                                .font(.headline)
                                .padding(.horizontal)

                            ForEach(activitySummary, id: \.template) { item in
                                ActivitySummaryRow(
                                    name: item.template,
                                    duration: item.duration,
                                    percentage: totalDuration > 0 ? item.duration / totalDuration : 0,
                                    color: Color(hex: item.color) ?? .blue
                                )
                            }
                        }
                        .padding(.vertical)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)

                            Text("No data for this period")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("Start tracking time on your Apple Watch")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                    }

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Analytics")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) % 3600 / 60
        return "\(hours)h \(minutes)m"
    }
}

struct ActivitySummaryRow: View {
    let name: String
    let duration: TimeInterval
    let percentage: Double
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)

                Text(name)
                    .font(.subheadline)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatDuration(duration))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("\(Int(percentage * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray5))

                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * percentage)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) % 3600 / 60
        return "\(hours)h \(minutes)m"
    }
}

#Preview {
    AnalyticsView()
}
