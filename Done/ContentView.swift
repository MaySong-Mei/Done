//
//  ContentView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var calendarService = GoogleCalendarService.shared

    var body: some View {
        TabView {
            TemplateManagementView()
                .tabItem {
                    Label("Templates", systemImage: "square.grid.2x2")
                }

            DayTimelineView()
                .tabItem {
                    Label("Timeline", systemImage: "calendar")
                }

            TimeEntriesView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            AnalyticsView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .onAppear {
            _ = PhoneConnectivityManager.shared
        }
        .preferredColorScheme(dataManager.appearanceMode.colorScheme)
    }
}

#Preview {
    ContentView()
}
