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
    let viewModeLabel: String
    let formattedDate: String
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
