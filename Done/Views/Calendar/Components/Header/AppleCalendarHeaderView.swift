//
//  AppleCalendarHeaderView.swift
//  Done
//
//  Apple Calendar inspired floating header capsules.
//

import SwiftUI

// MARK: - Header Tool Configuration

enum CalendarHeaderTool: String, CaseIterable, Identifiable {
    case create
    case search
    case agent
    case view

    var id: String { rawValue }

    var label: String {
        switch self {
        case .create: return "Create"
        case .search: return "Search"
        case .agent: return "Agent"
        case .view: return "View"
        }
    }

    var icon: String {
        switch self {
        case .create: return "plus"
        case .search: return "magnifyingglass"
        case .agent: return "sparkles"
        case .view: return "rectangle.grid.1x2"
        }
    }
}

func calendarHeaderExposedTools(from raw: String) -> Set<CalendarHeaderTool> {
    let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var result = Set<CalendarHeaderTool>()
    for id in ids {
        if let tool = CalendarHeaderTool(rawValue: id) {
            result.insert(tool)
        }
    }
    return result
}

func calendarHeaderExposedToolsString(from tools: Set<CalendarHeaderTool>) -> String {
    CalendarHeaderTool.allCases.filter { tools.contains($0) }.map(\.rawValue).joined(separator: ",")
}

func calendarRangeModeTimelineOptions() -> [RangeMode] {
    [.day, .threeDay, .week]
}

func calendarRangeModeExtraOptions() -> [RangeMode] {
    [.stream]
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
    case .stream:
        return "Timeline Stream"
    }
}

struct AppleCalendarHeaderView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AppSettingsKeys.calendarHeaderExposedTools) private var exposedToolsRaw = "create"
    @State private var didTriggerDateLongPress = false

    let selectedDate: Date
    let rangeMode: RangeMode
    let leftCapsuleTitle: String
    let isCapsulesVisible: Bool
    let isActionCapsuleVisible: Bool
    var onMonthTap: () -> Void
    var onMonthLongPress: () -> Void
    var onSelectRangeMode: (RangeMode) -> Void
    var onAgentTap: () -> Void
    var onSearchTap: () -> Void
    var onAddTap: () -> Void
    var onOpenTimeZoneSchedule: () -> Void

    init(
        selectedDate: Date,
        rangeMode: RangeMode,
        leftCapsuleTitle: String,
        isCapsulesVisible: Bool,
        isActionCapsuleVisible: Bool,
        onMonthTap: @escaping () -> Void,
        onMonthLongPress: @escaping () -> Void,
        onSelectRangeMode: @escaping (RangeMode) -> Void,
        onAgentTap: @escaping () -> Void,
        onSearchTap: @escaping () -> Void,
        onAddTap: @escaping () -> Void,
        onOpenTimeZoneSchedule: @escaping () -> Void = {}
    ) {
        self.selectedDate = selectedDate
        self.rangeMode = rangeMode
        self.leftCapsuleTitle = leftCapsuleTitle
        self.isCapsulesVisible = isCapsulesVisible
        self.isActionCapsuleVisible = isActionCapsuleVisible
        self.onMonthTap = onMonthTap
        self.onMonthLongPress = onMonthLongPress
        self.onSelectRangeMode = onSelectRangeMode
        self.onAgentTap = onAgentTap
        self.onSearchTap = onSearchTap
        self.onAddTap = onAddTap
        self.onOpenTimeZoneSchedule = onOpenTimeZoneSchedule
    }

    private var exposedTools: Set<CalendarHeaderTool> {
        calendarHeaderExposedTools(from: exposedToolsRaw)
    }

    private func action(for tool: CalendarHeaderTool) {
        switch tool {
        case .create: onAddTap()
        case .search: onSearchTap()
        case .agent: onAgentTap()
        case .view: break // handled as Menu, not Button
        }
    }

    @ViewBuilder
    private func rangeModeMenuItems() -> some View {
        ForEach(calendarRangeModeTimelineOptions(), id: \.self) { mode in
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

        Divider()

        ForEach(calendarRangeModeExtraOptions(), id: \.self) { mode in
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

        Divider()

        Button {
            onOpenTimeZoneSchedule()
        } label: {
            Label("Time Zone Schedule…", systemImage: "globe")
        }
    }

    @ViewBuilder
    private func viewModeMenu(showLabel: Bool = false) -> some View {
        Menu {
            rangeModeMenuItems()
        } label: {
            if showLabel {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.grid.1x2")
                        .font(.system(size: 14, weight: .semibold))
                    Text("View")
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "rectangle.grid.1x2")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
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
                Button {
                    if didTriggerDateLongPress {
                        didTriggerDateLongPress = false
                        return
                    }
                    onMonthTap()
                } label: {
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
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        didTriggerDateLongPress = true
                        onMonthLongPress()
                    }
                )
                .offset(y: capsuleOffsetY(isVisible: isCapsulesVisible))
                .transition(capsuleTransition)
            }

            Spacer(minLength: 0)

            if isActionCapsuleVisible {
                HStack(spacing: 0) {
                    // Exposed tools (shown directly in the capsule)
                    // Single exposed tool: icon + label. Multiple: icon only.
                    let exposed = CalendarHeaderTool.allCases.filter { exposedTools.contains($0) }
                    let showLabels = exposed.count == 1
                    ForEach(Array(exposed.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.14))
                                .frame(width: 1, height: 16)
                        }
                        if tool == .view {
                            viewModeMenu(showLabel: showLabels)
                        } else {
                            Button { action(for: tool) } label: {
                                if showLabels {
                                    HStack(spacing: 6) {
                                        Image(systemName: tool.icon)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(tool.label)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 40)
                                    .contentShape(Rectangle())
                                } else {
                                    Image(systemName: tool.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 40, height: 40)
                                        .contentShape(Rectangle())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Divider before "..." menu
                    if !exposed.isEmpty {
                        Rectangle()
                            .fill(Color.primary.opacity(0.14))
                            .frame(width: 1, height: 16)
                    }

                    // "..." menu with non-exposed tools + view mode
                    let menuTools = CalendarHeaderTool.allCases.filter { !exposedTools.contains($0) }
                    Menu {
                        ForEach(menuTools) { tool in
                            if tool == .view {
                                // Inside the overflow menu, render as a
                                // labeled sub-menu (not an icon button).
                                Menu {
                                    rangeModeMenuItems()
                                } label: {
                                    Label("View", systemImage: "rectangle.grid.1x2")
                                }
                            } else {
                                Button { action(for: tool) } label: {
                                    Label(tool.label, systemImage: tool.icon)
                                }
                            }
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
    /// +1 when navigating forward (later date), -1 when backward.
    @State private var slideDirection: CGFloat = 1
    @State private var cleanupTask: Task<Void, Never>?

    init(title: String) {
        self.title = title
        _displayedTitle = State(initialValue: title)
    }

    private let slideDistance: CGFloat = 12

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoingTitle {
                titleText(outgoingTitle)
                    .opacity(1 - transitionProgress)
                    .offset(x: -slideDistance * transitionProgress * slideDirection)
                    .blur(radius: 1.5 * transitionProgress)
            }

            titleText(displayedTitle)
                .opacity(transitionProgress)
                .offset(x: slideDistance * (1 - transitionProgress) * slideDirection)
        }
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

        let wasAnimating = transitionProgress < 0.95
        cleanupTask?.cancel()
        if accessibilityReduceMotion {
            outgoingTitle = nil
            displayedTitle = newValue
            transitionProgress = 1
            return
        }

        if wasAnimating {
            // Rapid change (previous animation still in flight):
            // skip slide, just fade in the new value directly.
            outgoingTitle = nil
            displayedTitle = newValue
            transitionProgress = 0.3
            withAnimation(.easeOut(duration: 0.2)) {
                transitionProgress = 1
            }
        } else {
            // Normal single change: slide transition.
            slideDirection = newValue > displayedTitle ? 1 : -1
            outgoingTitle = displayedTitle
            displayedTitle = newValue
            transitionProgress = 0
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                transitionProgress = 1
            }
        }

        cleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            outgoingTitle = nil
            cleanupTask = nil
        }
    }
}

// MARK: - Calendar Header Settings

struct CalendarHeaderSettingsView: View {
    @AppStorage(AppSettingsKeys.calendarHeaderExposedTools) private var exposedToolsRaw = "create"
    @AppStorage(AppSettingsKeys.calendarRememberViewMode) private var rememberViewMode = false
    @AppStorage(AppSettingsKeys.calendarAutoReturnToToday) private var autoReturnToToday = false

    private var exposedTools: Set<CalendarHeaderTool> {
        calendarHeaderExposedTools(from: exposedToolsRaw)
    }

    private func toggleTool(_ tool: CalendarHeaderTool) {
        var current = exposedTools
        if current.contains(tool) {
            current.remove(tool)
        } else {
            current.insert(tool)
        }
        exposedToolsRaw = calendarHeaderExposedToolsString(from: current)
    }

    var body: some View {
        Form {
            Section {
                ForEach(CalendarHeaderTool.allCases) { tool in
                    Toggle(isOn: Binding(
                        get: { exposedTools.contains(tool) },
                        set: { _ in toggleTool(tool) }
                    )) {
                        Label(tool.label, systemImage: tool.icon)
                    }
                }
            } header: {
                Text("Header Tools")
            } footer: {
                Text("Enabled tools appear directly in the header bar. Disabled tools are placed in the \u{2026} menu.")
            }

            Section {
                Toggle("Remember View Mode", isOn: $rememberViewMode)

                Toggle("Return to Today on Tab Switch", isOn: $autoReturnToToday)
            } header: {
                Text("Behavior")
            } footer: {
                Text("Remember View Mode restores your last calendar view (Day, 3-Day, Week) when reopening the app. Return to Today jumps back to the current date when switching away and returning to the calendar tab.")
            }
        }
        .navigationTitle("Calendar")
    }
}
