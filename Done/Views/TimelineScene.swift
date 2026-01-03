//
//  TimelineScene.swift
//  Done
//
//  Created by Created by Shiqi Liu on 1/3/26.
//

import SwiftUI

struct TimelineScene: View {
    private let hourHeight: CGFloat = 60
    private var totalHeight: CGFloat { 24 * hourHeight }

    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            bodyScroll
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: Body Scroll
    private var bodyScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(spacing: 0) {
                timeAxis
                    .frame(width: 30, alignment: .trailing)

                timelineGrid
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: totalHeight, alignment: .top)
        }
    }

    // MARK: - Time Axis
    private var timeAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%d", hour))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .center)
            }
        }
        .padding(.trailing, 4)
    }

    // MARK: - Timeline Grid
    private var timelineGrid: some View {
        Canvas { context, size in
            let centerOffset = hourHeight / 2
            for hour in 0..<24 {
                let y = CGFloat(hour) * hourHeight + centerOffset
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(
                    path,
                    with: .color(.gray.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                )
            }
        }
        .frame(height: totalHeight)
    }

    // MARK: Header Card
    private var headerCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}
