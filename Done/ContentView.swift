//
//  ContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = EventStore()
    @StateObject private var calendarState = CalendarViewState()
    @StateObject private var skillInsightStore = SkillInsightStore()
    @State private var skillAnalysisService: SkillAnalysisService?
    @State private var isShowingCreateEvent = false
    @State private var isShowingCompletedEvents = false
    @State private var isDraggingEvent = false
    @State private var isSplitMode = false
    @State private var isMergeMode = false
    @State private var isTimerMode = false
    @State private var deleteZoneFrame: CGRect = .zero
    @State private var isOverDeleteZone: Bool = false

    var body: some View {
        TabView {
            NavigationStack {
                EventGridView(
                    events: store.activeEvents,
                    isDraggingEvent: $isDraggingEvent,
                    deleteZoneFrame: $deleteZoneFrame,
                    isOverDeleteZone: $isOverDeleteZone,
                    isSplitMode: $isSplitMode,
                    isMergeMode: $isMergeMode,
                    isTimerMode: $isTimerMode
                )
                    .environmentObject(store)
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .top) {
                        todoHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }
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
            .toolbar(isDraggingEvent ? .hidden : .visible, for: .tabBar)
            .sheet(isPresented: $isShowingCreateEvent) {
                CreateEventView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $isShowingCompletedEvents) {
                CompletedEventsView()
                    .environmentObject(store)
            }
            .tabItem {
                Label("Event", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                CalendarPageView()
                    .environmentObject(store)
            }
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
            .tabItem {
                Label("Agenda", systemImage: "list.bullet.clipboard")
            }

            NavigationStack {
                AnalysisView()
                    .environmentObject(store)
                    .environmentObject(skillInsightStore)
            }
            .tabItem {
                Label("Analysis", systemImage: "chart.bar.xaxis")
            }
        }
        .environmentObject(calendarState)
        .onAppear {
            let service = SkillAnalysisService(insightStore: skillInsightStore)
            skillAnalysisService = service
            store.onCalendarEventRecordCompleted = { event in
                Task { await service.analyzeEvent(event) }
            }
            // Catch up: analyze past events that were created for the future
            let events = store.calendarEvents
            Task { await service.analyzePastEvents(events) }
        }
        .overlay(alignment: .bottomTrailing) {
            if isDraggingEvent {
                DeleteZoneView(isOver: isOverDeleteZone)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DeleteZoneFrameKey.self,
                                value: proxy.frame(in: .global)
                            )
                        }
                    )
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
        }
        .onPreferenceChange(DeleteZoneFrameKey.self) { frame in
            deleteZoneFrame = frame
        }
    }

    private var todoHeader: some View {
        HStack(spacing: 10) {
            Text("Event")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    isShowingCreateEvent = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create event")

                Button {
                    isMergeMode.toggle()
                    if isMergeMode { isSplitMode = false; isTimerMode = false }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(isMergeMode ? .primary : .secondary)
                }
                .accessibilityLabel("Merge mode")

                Button {
                    if store.activeTimerCalendarEvent != nil {
                        store.stopActiveTimer()
                    } else {
                        isTimerMode.toggle()
                        if isTimerMode { isSplitMode = false; isMergeMode = false }
                    }
                } label: {
                    Image(systemName: store.activeTimerCalendarEvent != nil ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(store.activeTimerCalendarEvent != nil ? .red : (isTimerMode ? .primary : .secondary))
                }
                .accessibilityLabel(store.activeTimerCalendarEvent != nil ? "Stop timer" : "Timer mode")

                Button {
                    isSplitMode.toggle()
                    if isSplitMode { isMergeMode = false; isTimerMode = false }
                } label: {
                    Image(systemName: "scissors")
                        .foregroundStyle(isSplitMode ? .primary : .secondary)
                }
                .accessibilityLabel("Split mode")

                if store.completedCount > 0 {
                    Button {
                        isShowingCompletedEvents = true
                    } label: {
                        Text("\u{2713} \(store.completedCount)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private struct DeleteZoneView: View {
    var isOver: Bool
    @State private var isArmed: Bool = false
    @State private var armWork: DispatchWorkItem?

    var body: some View {
        Image(systemName: "trash")
            .font(.system(size: isArmed ? 20 : 17, weight: .medium))
            .foregroundStyle(isArmed ? .white : .secondary)
            .frame(width: 56, height: 56)
            .background {
                Circle().fill(Color.red.opacity(isArmed ? 0.85 : 0))
            }
            .background(.ultraThinMaterial, in: Circle())
            .scaleEffect(isArmed ? 1.15 : (isOver ? 1.08 : 1.0))
            .shadow(color: isArmed ? .red.opacity(0.35) : .clear, radius: 14)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOver)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isArmed)
            .onChange(of: isOver) { over in
                armWork?.cancel()
                if over {
                    let work = DispatchWorkItem { isArmed = true }
                    armWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
                } else {
                    isArmed = false
                }
            }
            .accessibilityLabel("Drop to delete")
    }
}

private struct DeleteZoneFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
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
