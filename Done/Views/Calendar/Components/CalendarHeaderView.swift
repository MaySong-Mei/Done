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

    var title: String
    var subtitle: String
    var mode: Mode = .normal

    var onTodayTapped: () -> Void = {}
    var onAddTapped: () -> Void = {}
    var onSearchTapped: () -> Void = {}
    var onFilterTapped: () -> Void = {}

    @State private var subtitleVisibleCount: Int = 0
    @State private var subtitleTimer: Timer?
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
        .onAppear(perform: restartSubtitleTyping)
        .onDisappear(perform: stopSubtitleTimer)
        .onChange(of: subtitle) { _ in
            restartSubtitleTyping()
        }
    }

    /// Swipeable pages available only in expanded (edit) mode.
    private var expandedPager: some View {
        ZStack(alignment: .bottomLeading) {
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
        Text(currentSubtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var currentSubtitle: String {
        let prefix = subtitle.prefix(subtitleVisibleCount)
        return String(prefix)
    }

    private func restartSubtitleTyping() {
        stopSubtitleTimer()
        subtitleVisibleCount = 0
        guard !subtitle.isEmpty else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let next = subtitleVisibleCount + 1
            subtitleVisibleCount = min(next, subtitle.count)
            if subtitleVisibleCount >= subtitle.count {
                timer.invalidate()
            }
        }
        subtitleTimer = timer
    }

    private func stopSubtitleTimer() {
        subtitleTimer?.invalidate()
        subtitleTimer = nil
    }
}
