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
    @State private var isShowingCreateEvent = false
    @State private var isShowingCompletedEvents = false
    @State private var isDraggingEvent = false
    @State private var isSplitMode = false
    @State private var isMergeMode = false
    @State private var isTimerMode = false
    @State private var deleteZoneFrame: CGRect = .zero

    var body: some View {
        TabView {
            NavigationStack {
                EventGridView(
                    events: store.activeEvents,
                    isDraggingEvent: $isDraggingEvent,
                    deleteZoneFrame: $deleteZoneFrame,
                    isSplitMode: $isSplitMode,
                    isMergeMode: $isMergeMode,
                    isTimerMode: $isTimerMode
                )
                    .environmentObject(store)
                    .navigationTitle("Event")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isShowingCreateEvent = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Create event")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isMergeMode.toggle()
                                if isMergeMode { isSplitMode = false; isTimerMode = false }
                            } label: {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(isMergeMode ? .primary : .secondary)
                            }
                            .accessibilityLabel("Merge mode")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if store.activeTimerCalendarEvent != nil {
                                    // Timer running — stop it
                                    store.stopActiveTimer()
                                } else {
                                    isTimerMode.toggle()
                                    if isTimerMode { isSplitMode = false; isMergeMode = false }
                                }
                            } label: {
                                Image(systemName: store.activeTimerCalendarEvent != nil ? "record.circle.fill" : "record.circle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(store.activeTimerCalendarEvent != nil ? .red : (isTimerMode ? .primary : .secondary))
                            }
                            .accessibilityLabel(store.activeTimerCalendarEvent != nil ? "Stop timer" : "Timer mode")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isSplitMode.toggle()
                                if isSplitMode { isMergeMode = false; isTimerMode = false }
                            } label: {
                                Image(systemName: "scissors")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(isSplitMode ? .primary : .secondary)
                            }
                            .accessibilityLabel("Split mode")
                        }
                        if store.completedCount > 0 {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    isShowingCompletedEvents = true
                                } label: {
                                    Text("\u{2713} \(store.completedCount)")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
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
        }
        .environmentObject(calendarState)
        .overlay(alignment: .bottomTrailing) {
            if isDraggingEvent {
                DeleteZoneView()
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
}

private struct DeleteZoneView: View {
    var body: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 72, height: 72)
            .background(Color.red.opacity(0.92), in: Circle())
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
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
