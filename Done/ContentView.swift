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
    @State private var deleteZoneFrame: CGRect = .zero

    var body: some View {
        TabView {
            NavigationStack {
                EventGridView(
                    events: store.activeEvents,
                    isDraggingEvent: $isDraggingEvent,
                    deleteZoneFrame: $deleteZoneFrame,
                    isSplitMode: $isSplitMode
                )
                    .environmentObject(store)
                    .navigationTitle("Event")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isSplitMode.toggle()
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
                    .overlay(alignment: .bottom) {
                        if !isDraggingEvent {
                            Button {
                                isShowingCreateEvent = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 48, height: 48)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                            }
                            .accessibilityLabel("Create event")
                            .padding(.bottom, 30)
                        }
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
