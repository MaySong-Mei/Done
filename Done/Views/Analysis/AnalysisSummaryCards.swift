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
            SummaryCard(title: L(.recordRate), value: String(format: "%.0f%%", recordRate), icon: "clock", color: .blue)
            SummaryCard(title: L(.streak), value: "\(streak) \(L(.days))", icon: "flame.fill", color: .green)
            SummaryCard(title: L(.completionRate), value: String(format: "%.0f%%", rate), icon: "checkmark.circle.fill", color: .orange)
            SummaryCard(title: L(.activeTasks), value: "\(active)", icon: "tray.full.fill", color: .pink)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
