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

    var body: some View {
        TabView {
            NavigationStack {
                EventGridView(events: store.events)
                    .environmentObject(store)
                    .navigationTitle("Event")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isShowingCreateEvent = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Create event")
                        }
                    }
            }
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
    }
}
