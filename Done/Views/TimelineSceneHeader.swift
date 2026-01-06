//
//  TimelineSceneHeader.swift
//  Done
//
//  Header card for TimelineScene.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TimelineSceneHeader: View {
    let useLiquidGlassHeader: Bool
    let headerCardHeight: CGFloat
    let cornerRadius: CGFloat
    let timeAxisWidth: CGFloat
    let viewModeLabel: String
    let formattedDate: String
    let viewMode: TimelineViewModel.DisplayMode
    let dates: [Date]
    let isToday: Bool
    let onToday: () -> Void
    let onAdd: () -> Void
    let onCycleViewMode: () -> Void
    @State private var isPressing = false
    private let haptics = HeaderHaptics()

    var body: some View {
        Group {
            if useLiquidGlassHeader {
                liquidHeaderCard
            } else {
                materialHeaderCard
            }
        }
        .scaleEffect(isPressing ? 0.97 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isPressing)
        .onLongPressGesture(
            minimumDuration: 0.4,
            maximumDistance: 20,
            pressing: { pressing in
                isPressing = pressing
                if pressing {
                    haptics.playPreview()
                }
            },
            perform: {
                haptics.playCommit()
                onCycleViewMode()
            }
        )
    }

    private var headerCardContent: some View {
        let verticalPadding: CGFloat = showsDateStrip ? 10 : 12
        let spacing: CGFloat = showsDateStrip ? 10 : 0

        return VStack(alignment: .leading, spacing: spacing) {
            topRow

            if showsDateStrip {
                dateStrip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, verticalPadding)
    }

    private var materialHeaderCard: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(maxWidth: .infinity, minHeight: headerCardHeight, maxHeight: headerCardHeight)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
            .overlay(headerCardContent)
    }

    private var liquidHeaderCard: some View {
        GlassEffectContainer(cornerRadius: cornerRadius) {
            headerCardContent
        }
        .frame(maxWidth: .infinity, minHeight: headerCardHeight, maxHeight: headerCardHeight)
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 8)
    }

    @ViewBuilder
    private func headerIconButton(
        _ systemName: String,
        useLiquidGlass: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if useLiquidGlass {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .iconGlass()
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .background { Circle().fill(.ultraThinMaterial) }
            .overlay { Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.8) }
        }
    }

    @ViewBuilder
    private func headerTextButton(
        _ title: String,
        useLiquidGlass: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if useLiquidGlass {
            Button(action: action) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .capsuleGlass()
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .background { Capsule().fill(.ultraThinMaterial) }
            .overlay { Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.8) }
        }
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formattedDate)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()

            if !isToday {
                headerTextButton("Today", useLiquidGlass: useLiquidGlassHeader, action: onToday)
            }

            headerIconButton("plus", useLiquidGlass: useLiquidGlassHeader, action: onAdd)
                .accessibilityLabel("Add entry")
        }
    }

    private var dateStrip: some View {
        GeometryReader { geo in
            let totalWidth = max(0, geo.size.width - timeAxisWidth)
            let dayWidth = dates.isEmpty ? 0 : totalWidth / CGFloat(dates.count)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: timeAxisWidth)

                ForEach(dates, id: \.self) { date in
                    dateCell(for: date, width: dayWidth)
                }
            }
        }
        .frame(height: 32)
    }

    private var showsDateStrip: Bool {
        dates.count > 1
    }

    private func dateCell(for date: Date, width: CGFloat) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let text = dateLabel(for: date)
        let padding = datePadding
        let contentWidth = max(0, width - padding * 2)

        return VStack(spacing: 4) {
            Text(text)
                .font(.caption2.weight(isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: contentWidth, alignment: .center)

            Rectangle()
                .fill(isToday ? Color.accentColor : Color.clear)
                .frame(height: 3)
                .frame(width: max(20, contentWidth * 0.6))
                .opacity(isToday ? 1 : 0)
        }
        .frame(width: contentWidth)
        .padding(.horizontal, padding)
    }

    private func dateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        switch viewMode {
        case .threeDays:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d"
            return formatter.string(from: date)
        case .week:
            let day = calendar.component(.day, from: date)
            let weekday = calendar.component(.weekday, from: date)
            let symbols = ["S", "M", "T", "W", "T", "F", "S"]
            let symbol = symbols[(weekday - 1 + symbols.count) % symbols.count]
            return "\(symbol) \(day)"
        case .day:
            return ""
        }
    }

    private var datePadding: CGFloat {
        viewMode == .week ? 2 : 0
    }
}

private struct HeaderHaptics {
    func playPreview() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.6)
#endif
    }

    func playCommit() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
#endif
    }
}
