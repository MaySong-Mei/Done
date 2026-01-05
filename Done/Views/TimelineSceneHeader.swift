//
//  TimelineSceneHeader.swift
//  Done
//
//  Header card for TimelineScene.
//

import SwiftUI

struct TimelineSceneHeader: View {
    let useLiquidGlassHeader: Bool
    let headerCardHeight: CGFloat
    let viewModeLabel: String
    let formattedDate: String
    let isToday: Bool
    let onToday: () -> Void
    let onAdd: () -> Void

    var body: some View {
        Group {
            if useLiquidGlassHeader {
                liquidHeaderCard
            } else {
                materialHeaderCard
            }
        }
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
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(maxWidth: .infinity, minHeight: headerCardHeight, maxHeight: headerCardHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
            .overlay(headerCardContent)
    }

    private var liquidHeaderCard: some View {
        GlassEffectContainer(cornerRadius: 20) {
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
