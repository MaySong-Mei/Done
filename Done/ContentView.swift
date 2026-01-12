//
//  ContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = EventStore()

    var body: some View {
        TabView {
            NavigationStack {
                EventListView(events: store.events)
                    .navigationTitle("Event")
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
    }
}

private struct EventListView: View {
    let events: [Event]

    var body: some View {
        Group {
            if events.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 32, weight: .semibold))
                    Text("No events")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(events) { event in
                            EventCardView(event: event)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

private struct CalendarPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32, weight: .semibold))
            Text("Calendar coming soon")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
