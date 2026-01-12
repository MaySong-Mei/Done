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
                    .overlay(alignment: .bottomTrailing) {
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
                        .padding(.trailing, 35)
                        .padding(.bottom, 40)
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
