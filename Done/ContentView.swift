//
//  ContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: EventStore
    @StateObject private var calendarState = CalendarViewState()
    @StateObject private var skillInsightStore = SkillInsightStore()
    @State private var skillAnalysisService: SkillAnalysisService?
    var body: some View {
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
            let events = store.calendarEvents
            Task { await service.analyzePastEvents(events) }
        }
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
