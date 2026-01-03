//
//  TimelineScene.swift
//  Done
//
//  Created by Shiqi Liu on 1/3/26.
//

import SwiftUI

struct TimelineScene: View {
    @StateObject private var viewModel = TimelineViewModel()
    private let hourHeight: CGFloat = 60
    private var totalHeight: CGFloat { 24 * hourHeight }
    private let timeAxisWidth: CGFloat = 30

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
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { _ in
                    viewModel.beginMagnification()
                }
                .onEnded { value in
                    viewModel.handleMagnificationGestureEnded(value)
                }
        )
    }

    // MARK: Body Scroll
    private var bodyScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            GeometryReader { proxy in
                let contentWidth = max(0, proxy.size.width - timeAxisWidth)
                HStack(spacing: 0) {
                    timeAxis
                        .frame(width: timeAxisWidth, alignment: .trailing)

                    timelineColumns(contentWidth: contentWidth)
                }
                .frame(height: totalHeight, alignment: .top)
            }
            .frame(height: totalHeight)
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

    // MARK: - Timeline Columns
    private func timelineColumns(contentWidth: CGFloat) -> some View {
        let columnWidth = contentWidth / CGFloat(max(1, viewModel.dayCount))
        return HStack(spacing: 0) {
            ForEach(0..<viewModel.dayCount, id: \.self) { _ in
                timelineGrid
                    .frame(width: columnWidth, height: totalHeight)
            }
        }
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
