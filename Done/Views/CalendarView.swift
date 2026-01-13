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
    private let headerHeight: CGFloat = 32
    private let dayRange = -30...30
    @State private var selectedDayOffset = 0
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    var body: some View {
        let contentHeight = totalHeight

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - labelWidth)

            HStack(spacing: 0) {
                timeAxis
                    .frame(width: labelWidth, alignment: .trailing)

                timelineColumns(contentWidth: contentWidth)
            }
        }
        .frame(height: contentHeight, alignment: .top)
    }

    private var timeAxis: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: headerHeight)

            ForEach(0...24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    private func timelineColumns(contentWidth: CGFloat) -> some View {
        TabView(selection: $selectedDayOffset) {
            ForEach(dayRange, id: \.self) { offset in
                timelinePage(date: date(for: offset), contentWidth: contentWidth)
                    .frame(width: contentWidth, height: totalHeight, alignment: .top)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .padding(.leading, 8)
    }

    private func timelinePage(date: Date, contentWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Self.dateFormatter.string(from: date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: contentWidth, height: headerHeight, alignment: .center)

            ForEach(0...24, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: contentWidth, height: 1)
                    .padding(.top, 6)
                    .frame(height: hourHeight, alignment: .top)
            }
        }
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    private var totalHeight: CGFloat {
        headerHeight + (CGFloat(25) * hourHeight)
    }
}
