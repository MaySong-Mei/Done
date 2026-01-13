//
//  CalendarView.swift
//  Done
//
//  Created by Shiqi Liu on 1/14/26.
//

import SwiftUI

struct CalendarView: View {
    var body: some View {
        GeometryReader { proxy in
            let topHeight = max(120, proxy.size.height * 0.12)

            VStack(spacing: 16) {
                GlassCard()
                    .frame(height: topHeight)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                ScrollView {
                    CalendarTimelineView()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct GlassCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
    }
}

private struct CalendarTimelineView: View {
    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                        .padding(.top, 6)
                }
                .frame(height: hourHeight, alignment: .top)
            }
        }
    }
}
