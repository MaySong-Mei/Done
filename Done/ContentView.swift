//
//  ContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var orientationManager: OrientationManager
    @StateObject private var calendarState = CalendarViewState()
    @State private var savedDayOffsetBeforeLandscape: Int?
    @State private var calendarDayOffsetUnfreezeTask: Task<Void, Never>?
    @StateObject private var skillInsightStore = SkillInsightStore()
    @State private var skillAnalysisService: SkillAnalysisService?
    @State private var tokenInferenceCoordinator: TokenInferenceCoordinator?

    private var isDecisionQuestionVisible: Bool {
        agentRuntime.decisionCenter.currentDecision != nil
    }

    var body: some View {
        ZStack {
            TabView {
                NavigationStack {
                    TodoListsView()
                        .environmentObject(store)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let calEvent = store.activeTimerCalendarEvent,
                       let timerStart = calEvent.timerStartedAt {
                        TimerBannerView(
                            title: calEvent.title,
                            startedAt: timerStart,
                            color: EventTypeTemplateStore.color(for: calEvent.type),
                            onStop: {
                                if let todoId = calEvent.linkedTodoEventId,
                                   let todo = store.events.first(where: { $0.id == todoId }) {
                                    store.stopTimer(for: todo)
                                } else {
                                    store.stopActiveTimer()
                                }
                            }
                        )
                    }
                }
                .toolbar(isDecisionQuestionVisible ? .hidden : .visible, for: .tabBar)
                .tabItem {
                    Label("Event", systemImage: "list.bullet.rectangle")
                }

                NavigationStack {
                    CalendarPageView()
                        .environmentObject(store)
                }
                .toolbar((isDecisionQuestionVisible || calendarState.isEventFocused) ? .hidden : .visible, for: .tabBar)
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

                NavigationStack {
                    DailyAgendaView()
                        .environmentObject(store)
                        .toolbar(.hidden, for: .navigationBar)
                        .safeAreaInset(edge: .top) {
                            HStack(spacing: 10) {
                                Text("Agenda")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 40)
                                    .background(.ultraThinMaterial, in: Capsule())
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                        }
                }
                .toolbar(isDecisionQuestionVisible ? .hidden : .visible, for: .tabBar)
                .tabItem {
                    Label("Agenda", systemImage: "list.bullet.clipboard")
                }

                NavigationStack {
                    AnalysisView()
                        .environmentObject(store)
                        .environmentObject(skillInsightStore)
                        .toolbar(.hidden, for: .navigationBar)
                        .safeAreaInset(edge: .top) {
                            HStack(spacing: 10) {
                                Text("Analysis")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 40)
                                    .background(.ultraThinMaterial, in: Capsule())
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                        }
                }
                .toolbar(isDecisionQuestionVisible ? .hidden : .visible, for: .tabBar)
                .tabItem {
                    Label("Analysis", systemImage: "chart.bar.xaxis")
                }
            }
            .scaleEffect(isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundScale : 1)
            .offset(y: isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundOffsetY : 0)
            .shadow(
                color: .black.opacity(isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundShadowOpacity : 0),
                radius: isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundShadowRadius : 0,
                x: 0,
                y: isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundShadowYOffset : 0
            )
            .animation(AgentDecisionPresentationStyle.spring, value: isDecisionQuestionVisible)

            Color.black
                .opacity(isDecisionQuestionVisible ? AgentDecisionPresentationStyle.scrimOpacity : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(AgentDecisionPresentationStyle.spring, value: isDecisionQuestionVisible)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AgentDecisionCardHost()
        }
        .environmentObject(calendarState)
        .onChange(of: orientationManager.isLandscape) { isLandscape in
            calendarDayOffsetUnfreezeTask?.cancel()
            if isLandscape {
                savedDayOffsetBeforeLandscape = calendarState.selectedDayOffset
                calendarState.isDayOffsetFrozen = true
            } else {
                if let saved = savedDayOffsetBeforeLandscape {
                    calendarState.selectedDayOffset = saved
                }
                calendarDayOffsetUnfreezeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled, !orientationManager.isLandscape else { return }
                    calendarState.isDayOffsetFrozen = false
                    savedDayOffsetBeforeLandscape = nil
                }
            }
        }
        .onDisappear {
            calendarDayOffsetUnfreezeTask?.cancel()
        }
        .onAppear {
            let service = SkillAnalysisService(insightStore: skillInsightStore)
            skillAnalysisService = service
            if tokenInferenceCoordinator == nil {
                tokenInferenceCoordinator = TokenInferenceCoordinator(store: store)
            }
            store.onCalendarEventRecordCompleted = { event in
                Task { await service.analyzeEvent(event) }
            }
            let events = store.calendarEvents
            Task { await service.analyzePastEvents(events) }
        }
    }
}

private enum AgentDecisionPresentationStyle {
    static let backgroundScale: CGFloat = 0.985
    static let backgroundOffsetY: CGFloat = -6
    static let scrimOpacity: Double = 0.08
    static let backgroundShadowOpacity: Double = 0.08
    static let backgroundShadowRadius: CGFloat = 14
    static let backgroundShadowYOffset: CGFloat = 4
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)
}

struct TimerBannerView: View {
    let title: String
    let startedAt: Date
    let color: Color
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(formattedDuration(elapsed))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onStop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct AgentDecisionCardHost: View {
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @State private var visibleOperationEventID: UUID?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            if let latest = agentRuntime.operationCenter.latestEvent,
               visibleOperationEventID == latest.id {
                agentOperationToast(latest)
            }

            if let decision = agentRuntime.decisionCenter.currentDecision {
                AgentDecisionCardView(
                    request: decision,
                    pendingCount: agentRuntime.decisionCenter.pendingCount,
                    onSelect: { optionID in
                        agentRuntime.decisionCenter.resolveCurrent(with: .selected(optionID: optionID))
                    },
                    onOtherwise: { text in
                        agentRuntime.decisionCenter.resolveCurrent(with: .otherwise(text: text))
                    },
                    onDismiss: {
                        agentRuntime.decisionCenter.dismissCurrent()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(AgentDecisionPresentationStyle.spring, value: agentRuntime.decisionCenter.currentDecision != nil)
        .onChange(of: agentRuntime.operationCenter.latestEvent?.id) { _ in
            showLatestOperationToastIfNeeded()
        }
        .onChange(of: agentRuntime.decisionCenter.currentDecision?.id) { newID in
            if let newID {
                agentDecisionDebugLog("AgentDecisionCardHost currentDecision visible id=\(newID.uuidString)")
            } else {
                agentDecisionDebugLog("AgentDecisionCardHost currentDecision cleared")
            }
        }
        .onDisappear {
            toastDismissTask?.cancel()
        }
    }

    @ViewBuilder
    private func agentOperationToast(_ event: AgentOperationEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: event.phase))
                .font(.system(size: 12, weight: .semibold))
            Text(event.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(strokeColor(for: event.phase).opacity(0.35), lineWidth: 1)
        )
    }

    private func showLatestOperationToastIfNeeded() {
        toastDismissTask?.cancel()
        guard let latest = agentRuntime.operationCenter.latestEvent else {
            visibleOperationEventID = nil
            return
        }
        visibleOperationEventID = latest.id
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if self.visibleOperationEventID == latest.id {
                    self.visibleOperationEventID = nil
                }
            }
        }
    }

    private func iconName(for phase: AgentOperationPhase) -> String {
        switch phase {
        case .started, .resumed:
            return "bolt.fill"
        case .waitingDecision:
            return "questionmark.circle"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .defaulted:
            return "clock.badge.exclamationmark"
        }
    }

    private func strokeColor(for phase: AgentOperationPhase) -> Color {
        switch phase {
        case .succeeded:
            return .green
        case .failed:
            return .orange
        case .defaulted:
            return .yellow
        case .waitingDecision:
            return .blue
        case .started, .resumed:
            return .accentColor
        }
    }
}

private struct AgentDecisionCardView: View {
    let request: AgentDecisionRequest
    let pendingCount: Int
    let onSelect: (String) -> Void
    let onOtherwise: (String) -> Void
    let onDismiss: () -> Void

    @State private var showOtherwiseInput = false
    @State private var otherwiseText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(request.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if pendingCount > 0 {
                    Text("+\(pendingCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(option.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .multilineTextAlignment(.leading)
                                    if option.isRecommended {
                                        Text("Recommended")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.12), in: Capsule())
                                    }
                                }
                                if let subtitle = option.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                if request.otherwiseEnabled {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showOtherwiseInput.toggle()
                        }
                    } label: {
                        HStack {
                            Text("3. Tell Done to do otherwise")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: showOtherwiseInput ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    if showOtherwiseInput {
                        VStack(spacing: 8) {
                            TextField("Tell Done what to do instead", text: $otherwiseText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.systemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))

                            HStack {
                                Spacer()
                                Button("Submit") {
                                    let text = otherwiseText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !text.isEmpty else { return }
                                    onOtherwise(text)
                                    otherwiseText = ""
                                    showOtherwiseInput = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(otherwiseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            HStack {
                if let timeout = request.timeout, timeout > 0 {
                    Text("Dismiss to use default")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Dismiss to apply default")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Dismiss") {
                    onDismiss()
                }
                .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 2)
    }
}
