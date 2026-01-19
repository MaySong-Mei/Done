//
//  GlassCardView.swift
//  Done
//
//  Small visual component used by `CalendarPageView`.
//  Renders the decorative glass card at the top of the calendar page.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

struct GlassCardView: View {
    enum Mode: Equatable {
        case normal
        case expanded
    }

    var mode: Mode = .normal

    var onTodayTapped: () -> Void = {}
    var onAddTapped: () -> Void = {}
    var onSearchTapped: () -> Void = {}
    var onFilterTapped: () -> Void = {}

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                topRow

                if mode == .expanded {
                    expandedTools
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text("View and manage your events")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            Text("Calendar")
                .font(.title2.bold())

            Spacer(minLength: 0)

            Button(action: onTodayTapped) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var expandedTools: some View {
        HStack(spacing: 10) {
            toolButton("Add", systemName: "plus", action: onAddTapped)
            toolButton("Search", systemName: "magnifyingglass", action: onSearchTapped)
            toolButton("Filter", systemName: "line.3.horizontal.decrease.circle", action: onFilterTapped)
        }
    }

    private func toolButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct GlassEffectContainer<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                    }
                    .overlay {
                        shape.fill(.white.opacity(0.06))
                    }
            }
            .clipShape(shape)
    }
}
