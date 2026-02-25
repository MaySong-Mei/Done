//
//  DoneApp.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

@main
struct DoneApp: App {
    @StateObject private var store = EventStore()
    @StateObject private var agentRuntime = AgentRuntime()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(store)
                    .environmentObject(agentRuntime)

                if showSplash {
                    SplashView()
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .splashDidFinish)) { _ in
                withAnimation(.easeOut(duration: 0.35)) {
                    showSplash = false
                }
            }
        }
    }
}
