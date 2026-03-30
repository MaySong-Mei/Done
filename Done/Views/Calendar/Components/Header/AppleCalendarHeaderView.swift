//
//  AppleCalendarHeaderView.swift
//  Done
//
//  Apple Calendar inspired floating header capsules.
//

import SwiftUI

func calendarRangeModeMenuOptions() -> [RangeMode] {
    [.day, .threeDay, .week, .month]
}

func calendarRangeModeMenuLabel(for mode: RangeMode) -> String {
    switch mode {
    case .day:
        return "Day"
    case .threeDay:
        return "3-Day"
    case .week:
        return "Week"
    case .month:
        return "Month"
    }
}

struct AppleCalendarHeaderView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let selectedDate: Date
    let rangeMode: RangeMode
    let leftCapsuleTitle: String
    let isCapsulesVisible: Bool
    let isActionCapsuleVisible: Bool
    var onMonthTap: () -> Void
    var onSelectRangeMode: (RangeMode) -> Void
    @Binding var isAgenticCreateEnabled: Bool
    var onAgentTap: () -> Void
    var onSearchTap: () -> Void
    var onAddTap: () -> Void

    init(
        selectedDate: Date,
        rangeMode: RangeMode,
        leftCapsuleTitle: String,
        isCapsulesVisible: Bool,
        isActionCapsuleVisible: Bool,
        onMonthTap: @escaping () -> Void,
        onSelectRangeMode: @escaping (RangeMode) -> Void,
        isAgenticCreateEnabled: Binding<Bool>,
        onAgentTap: @escaping () -> Void,
        onSearchTap: @escaping () -> Void,
        onAddTap: @escaping () -> Void
    ) {
        self.selectedDate = selectedDate
        self.rangeMode = rangeMode
        self.leftCapsuleTitle = leftCapsuleTitle
        self.isCapsulesVisible = isCapsulesVisible
        self.isActionCapsuleVisible = isActionCapsuleVisible
        self.onMonthTap = onMonthTap
        self.onSelectRangeMode = onSelectRangeMode
        self._isAgenticCreateEnabled = isAgenticCreateEnabled
        self.onAgentTap = onAgentTap
        self.onSearchTap = onSearchTap
        self.onAddTap = onAddTap
    }

    private var capsuleTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }

    private func capsuleOffsetY(isVisible: Bool) -> CGFloat {
        guard !accessibilityReduceMotion else { return 0 }
        return isVisible ? 0 : -6
    }

    private var createModeMenuTitle: String {
        isAgenticCreateEnabled ? "Agentic Create On" : "Agentic Create Off"
    }

    private var createModeMenuIcon: String {
        isAgenticCreateEnabled ? "wand.and.stars" : "square.and.pencil"
    }

    var body: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            topRow
        }
        .frame(maxWidth: .infinity)
        .animation(accessibilityReduceMotion ? .none : .easeOut(duration: 0.18), value: isCapsulesVisible)
        .animation(accessibilityReduceMotion ? .none : .easeOut(duration: 0.18), value: isActionCapsuleVisible)
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            if isCapsulesVisible {
                Button(action: onMonthTap) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        AnimatedCapsuleTitleText(title: leftCapsuleTitle)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Capsule())
                    .background(Color.black.opacity(0.001), in: Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                .offset(y: capsuleOffsetY(isVisible: isCapsulesVisible))
                .transition(capsuleTransition)
            }

            Spacer(minLength: 0)

            if isActionCapsuleVisible {
                HStack(spacing: 0) {
                    Button(action: onAddTap) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Create")
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 1, height: 16)

                    Menu {
                        Button(action: onSearchTap) {
                            Label("Search", systemImage: "magnifyingglass")
                        }

                        Button(action: onAgentTap) {
                            Label("Agent", systemImage: "sparkles")
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isAgenticCreateEnabled.toggle()
                            }
                        } label: {
                            Label(createModeMenuTitle, systemImage: createModeMenuIcon)
                        }

                        Menu {
                            ForEach(calendarRangeModeMenuOptions(), id: \.self) { mode in
                                Button {
                                    onSelectRangeMode(mode)
                                } label: {
                                    if mode == rangeMode {
                                        Label(calendarRangeModeMenuLabel(for: mode), systemImage: "checkmark")
                                    } else {
                                        Text(calendarRangeModeMenuLabel(for: mode))
                                    }
                                }
                            }
                        } label: {
                            Label("View", systemImage: "rectangle.grid.1x2")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(height: 40)
                .contentShape(Capsule())
                .background(Color.black.opacity(0.001), in: Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
                .offset(y: capsuleOffsetY(isVisible: isActionCapsuleVisible))
                .transition(capsuleTransition)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AnimatedCapsuleTitleText: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let title: String

    @State private var displayedTitle: String
    @State private var outgoingTitle: String?
    @State private var transitionProgress: CGFloat = 1
    @State private var cleanupTask: Task<Void, Never>?

    init(title: String) {
        self.title = title
        _displayedTitle = State(initialValue: title)
    }

    private var animationDuration: TimeInterval { 0.2 }

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoingTitle {
                titleText(outgoingTitle)
                    .opacity(1 - transitionProgress)
                    .offset(y: 4 * transitionProgress)
            }

            titleText(displayedTitle)
                .opacity(transitionProgress)
                .offset(y: (1 - transitionProgress) * -4)
        }
        .clipped()
        .onChange(of: title) { _, newValue in
            animateTitleChange(to: newValue)
        }
        .onDisappear {
            cleanupTask?.cancel()
            cleanupTask = nil
        }
    }

    private func titleText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
    }

    private func animateTitleChange(to newValue: String) {
        guard newValue != displayedTitle else { return }

        cleanupTask?.cancel()
        if accessibilityReduceMotion {
            outgoingTitle = nil
            displayedTitle = newValue
            transitionProgress = 1
            return
        }

        outgoingTitle = displayedTitle
        displayedTitle = newValue
        transitionProgress = 0

        withAnimation(.easeInOut(duration: animationDuration)) {
            transitionProgress = 1
        }

        cleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(animationDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            outgoingTitle = nil
            cleanupTask = nil
        }
    }
}
