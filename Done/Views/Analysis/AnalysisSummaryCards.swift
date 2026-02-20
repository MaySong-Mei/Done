//
//  AnalysisSummaryCards.swift
//  Done
//

import SwiftUI

struct AnalysisSummaryCards: View {
    let recordRate: Double
    let streak: Int
    let rate: Double
    let active: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            SummaryCard(title: "Record Rate", value: String(format: "%.0f%%", recordRate), icon: "clock", color: .blue)
            SummaryCard(title: "Streak", value: "\(streak) days", icon: "flame.fill", color: .green)
            SummaryCard(title: "Completion", value: String(format: "%.0f%%", rate), icon: "chart.line.uptrend.xyaxis", color: .orange)
            SummaryCard(title: "Active", value: "\(active)", icon: "flame", color: .red)
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
