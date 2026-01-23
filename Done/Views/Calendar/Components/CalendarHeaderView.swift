//
//  CalendarHeaderView.swift
//  Done
//
//  Calendar-specific header that renders actions inside the reusable
//  `GlassCardView`. Keeps calendar-only UI out of the generic glass container.
//
//  Created by opencode and yifan mei on 1/14/26.
//

// 组装ui的文件
// 这是日历视图的头部视图，包含标题、副标题和一些操作按钮
// todo: 重构这个文件

import SwiftUI

struct CalendarHeaderView: View {
    enum Mode: Equatable {
        case normal
        case expanded
    }

    var title: String
    var subtitle: String
    var mode: Mode = .normal

    var onTodayTapped: () -> Void = {}
    var onAddTapped: () -> Void = {}
    var onSearchTapped: () -> Void = {}
    var onFilterTapped: () -> Void = {}

    @State private var subtitleProgress: Int = 0
    @State private var subtitleToken = UUID()
    @Namespace private var headerNamespace
    @State private var pagerPage: Int = 0

    var body: some View {
        GlassCardView {
            VStack(alignment: .leading, spacing: 6) {
                if mode == .expanded {
                    expandedPager
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .matchedGeometryEffect(id: "content", in: headerNamespace)
                } else {
                    normalRow
                        .transition(.opacity)
                        .matchedGeometryEffect(id: "content", in: headerNamespace)
                }
            }
        }
        .onAppear {
            subtitleProgress = 0
            subtitleToken = UUID()
        }
        .onChange(of: subtitle) { _ in
            subtitleProgress = 0
            subtitleToken = UUID()
        }
    }

    /// Swipeable pages available only in expanded (edit) mode.
    private var expandedPager: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $pagerPage) {
                VStack(alignment: .leading, spacing: 8) {
                    titleText
                        .matchedGeometryEffect(id: "title", in: headerNamespace)
                    subtitleRow
                        .matchedGeometryEffect(id: "subtitle", in: headerNamespace)
                    expandedTools
                }
                .tag(0)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcuts")
                        .font(.headline)
                    HStack(spacing: 10) {
                        toolButton("Today", systemName: "sun.max", action: onTodayTapped)
                        toolButton("Add", systemName: "plus", action: onAddTapped)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == pagerPage ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            titleText

            Spacer(minLength: 0)

            todayButton
        }
    }

    private var normalRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                subtitleRow
                    .matchedGeometryEffect(id: "subtitle", in: headerNamespace)
                titleText
                    .matchedGeometryEffect(id: "title", in: headerNamespace)
            }

            Spacer(minLength: 0)

            todayButton
        }
    }

    private var expandedTools: some View {
        HStack(spacing: 10) {
            toolButton("Add", systemName: "plus", action: onAddTapped)
            toolButton("Search", systemName: "magnifyingglass", action: onSearchTapped)
            toolButton("Filter", systemName: "line.3.horizontal.decrease.circle", action: onFilterTapped)
        }
    }

    private var todayButton: some View {
        Button(action: onTodayTapped) {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var titleText: some View {
        Text(title)
            .font(.title2.bold())
    }

    private var pageCount: Int {
        2
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

    private var subtitleRow: some View {
        TypingSubtitleView(
            text: subtitle,
            font: .footnote,
            color: .secondary,
            progress: $subtitleProgress,
            restartToken: subtitleToken
        )
    }
}
