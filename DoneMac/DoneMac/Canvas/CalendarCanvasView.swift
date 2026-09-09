//
//  CalendarCanvasView.swift
//  DoneMac
//
//  The SwiftUI applier over CanvasFrame. Everything here is positioning of
//  pre-computed fractions — window resize re-multiplies geometry without
//  invalidating any derived state (plan budget assertion 3).
//

import SwiftUI

struct CalendarCanvasView: View {
    let surface: CalendarSurfaceModel
    var hourHeight: CGFloat = 44

    private var contentHeight: CGFloat { hourHeight * 24 }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            allDayRow
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TimeAxisApplier(hourHeight: hourHeight)
                        .frame(width: 46, height: contentHeight)
                    ForEach(surface.frame.days, id: \.key) { day in
                        DayColumnView(
                            day: day,
                            nowLine: surface.frame.nowLine?.dayKey == day.key
                                ? surface.frame.nowLine : nil
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: contentHeight)
                        .overlay(alignment: .leading) { Divider().frame(width: 1) }
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 46, height: 1)
            ForEach(surface.frame.days, id: \.key) { day in
                Text(String(format: "%d/%d", day.key.month, day.key.day))
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var allDayRow: some View {
        if surface.frame.days.contains(where: { !$0.allDayChips.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: 46, height: 1)
                ForEach(surface.frame.days, id: \.key) { day in
                    VStack(spacing: 2) {
                        ForEach(day.allDayChips) { chip in
                            Text(chip.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 1)
                                .background(chip.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct DayColumnView: View {
    let day: DayModel
    let nowLine: NowLineModel?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                hourGrid(height: size.height)
                ForEach(day.blocks) { block in
                    blockView(block)
                        .frame(
                            width: max(1, size.width * block.widthFraction - 2),
                            height: max(6, size.height * block.heightFraction - 1)
                        )
                        .offset(
                            x: size.width * block.xOffsetFraction + 1,
                            y: size.height * block.yFraction
                        )
                        .zIndex(block.zIndex)
                }
                if let nowLine {
                    Rectangle()
                        .fill(.red)
                        .frame(height: 1)
                        .offset(y: size.height * nowLine.yFraction)
                }
            }
        }
        .clipped()
    }

    private func hourGrid(height: CGFloat) -> some View {
        ForEach(1..<24, id: \.self) { hour in
            Divider()
                .offset(y: height * CGFloat(hour) / 24)
        }
    }

    private func blockView(_ block: DayBlockModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(block.title)
                .font(.caption2)
                .lineLimit(2)
            if block.heightFraction > 0.035 {
                Text(block.timeText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(block.color.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(block.color, style: block.isTodo
                    ? StrokeStyle(lineWidth: 1)
                    : StrokeStyle(lineWidth: 0.5))
        )
    }
}
