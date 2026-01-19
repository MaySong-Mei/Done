//
//  CalendarHeaderView.swift
//  Done
//
//  Calendar-specific header that renders actions inside the reusable
//  `GlassCardView`. Keeps calendar-only UI out of the generic glass container.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

struct CalendarHeaderView: View {
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
        GlassCardView {
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
        }
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
