//
//  ContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = EventStore()
    @State private var isShowingCreateEvent = false
    @State private var isDraggingEvent = false
    @State private var deleteZoneFrame: CGRect = .zero

    var body: some View {
        TabView {
            NavigationStack {
                EventGridView(
                    events: store.events,
                    isDraggingEvent: $isDraggingEvent,
                    deleteZoneFrame: $deleteZoneFrame
                )
                    .environmentObject(store)
                    .navigationTitle("Event")
                    .navigationBarTitleDisplayMode(.large)
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
                CreateEventPlaceholderView()
                    .environmentObject(store)
            }
            .tabItem {
                Label("Event", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                CalendarPlaceholderView()
                    .navigationTitle("Calendar")
            }
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }
        }
        .overlay(alignment: .bottom) {
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
            }
        }
        .onPreferenceChange(DeleteZoneFrameKey.self) { frame in
            deleteZoneFrame = frame
        }
    }
}

private struct DeleteZoneView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .semibold))
            Text("Drop to Delete")
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(Color.red.opacity(0.9))
    }
}

private struct DeleteZoneFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
