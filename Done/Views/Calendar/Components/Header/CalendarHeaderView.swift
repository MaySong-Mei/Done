//
//  CalendarHeaderView.swift
//  Done
//
//  日历头部视图：包含标题、打字机字幕效果、操作按钮
//

import SwiftUI
import Combine

// MARK: - Typing Subtitle Controller

@MainActor
final class TypingSubtitleController: ObservableObject {
    @Published var progress: Int = 0

    private var task: Task<Void, Never>?
    private var currentText: String = ""

    func start(text: String, interval: TimeInterval) {
        guard text != currentText else { return }
        currentText = text

        task?.cancel()
        progress = 0

        guard !text.isEmpty else { return }

        let ns = UInt64(max(0.001, interval) * 1_000_000_000)

        task = Task { [weak self] in
            guard let self else { return }
            for i in 1...text.count {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                self.progress = i
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Typing Subtitle View

private struct TypingSubtitleView: View {
    let text: String
    var font: Font = .footnote
    var color: Color = .secondary
    let progress: Int

    var body: some View {
        Text(String(text.prefix(progress)))
            .font(font)
            .foregroundStyle(color)
    }
}

// MARK: - Calendar Header View

struct CalendarHeaderView: View {
    enum Mode: Hashable {
        case normal
        case expanded
    }

    var title: String
    var subtitle: String
    var year: String = ""
    var mode: Mode = .normal

    var onTodayTapped: () -> Void = {}
    var onAddTapped: () -> Void = {}
    var onSearchTapped: () -> Void = {}
    var onFilterTapped: () -> Void = {}

    @StateObject private var subtitleController = TypingSubtitleController()
    @State private var pagerPage: Int = 0
    private let typingInterval: TimeInterval = 0.05

    var body: some View {
        GlassCardView {
            VStack(alignment: .leading, spacing: 6) {
                if mode == .expanded {
                    expandedPager
                } else {
                    normalRow
                }
            }
        }
        .onAppear {
            subtitleController.start(text: subtitle, interval: typingInterval)
        }
        .onChange(of: subtitle) { newValue in
            subtitleController.start(text: newValue, interval: typingInterval)
        }
        .onDisappear {
            subtitleController.stop()
        }
    }

    // MARK: - Expanded Mode (Pager)

    private var expandedPager: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $pagerPage) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        titleText
                        subtitleRow
                        expandedTools
                    }
                    Spacer(minLength: 0)
                    todayButton
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
                    ForEach(0..<2, id: \.self) { i in
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

    // MARK: - Normal Mode

    private var normalRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                subtitleRow
                titleText
            }

            Spacer(minLength: 0)

            todayButton
        }
    }

    // MARK: - Components

    private var expandedTools: some View {
        HStack(spacing: 10) {
            toolButton("Add", systemName: "plus", action: onAddTapped)
            toolButton("Search", systemName: "magnifyingglass", action: onSearchTapped)
            toolButton("Filter", systemName: "line.3.horizontal.decrease.circle", action: onFilterTapped)
        }
    }

    private var todayButton: some View {
        Button(action: onTodayTapped) {
            Text(year)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var titleText: some View {
        Text(title)
            .font(.title2.bold())
    }

    private var subtitleRow: some View {
        TypingSubtitleView(
            text: subtitle,
            font: .footnote,
            color: .secondary,
            progress: subtitleController.progress
        )
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
