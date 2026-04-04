//
//  DoneApp.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import UIKit

func doneShouldDisableIdleTimer(
    isLandscape: Bool,
    landscapeFocusModeEnabled: Bool,
    landscapeFocusKeepAwakeEnabled: Bool,
    showSplash: Bool,
    scenePhase: ScenePhase
) -> Bool {
    isLandscape && landscapeFocusModeEnabled && landscapeFocusKeepAwakeEnabled && !showSplash && scenePhase == .active
}

func doneShouldDisableIdleTimer(
    isLandscape: Bool,
    landscapeFocusModeEnabled: Bool,
    showSplash: Bool,
    scenePhase: ScenePhase
) -> Bool {
    doneShouldDisableIdleTimer(
        isLandscape: isLandscape,
        landscapeFocusModeEnabled: landscapeFocusModeEnabled,
        landscapeFocusKeepAwakeEnabled: true,
        showSplash: showSplash,
        scenePhase: scenePhase
    )
}

@MainActor
func doneApplyIdleTimerPolicy(_ isDisabled: Bool) {
    UIApplication.shared.isIdleTimerDisabled = isDisabled
}

@main
struct DoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = EventStore()
    @StateObject private var agentRuntime = AgentRuntime()
    @StateObject private var orientationManager = OrientationManager()
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = true
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
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

                if orientationManager.isLandscape && landscapeFocusModeEnabled {
                    focusModeOverlay
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
            .environmentObject(orientationManager)
            .onAppear {
                doneApplyIdleTimerPolicy(shouldDisableIdleTimer)
            }
            .onChange(of: shouldDisableIdleTimer) { _, newValue in
                doneApplyIdleTimerPolicy(newValue)
            }
            .onDisappear {
                doneApplyIdleTimerPolicy(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .splashDidFinish)) { _ in
                withAnimation(.easeOut(duration: 0.35)) {
                    showSplash = false
                }
            }
        }
    }

    @ViewBuilder
    private var focusModeOverlay: some View {
        GeometryReader { geo in
            let landscapeW = max(geo.size.width, geo.size.height)
            let landscapeH = min(geo.size.width, geo.size.height)
            let needsRotation = geo.size.width < geo.size.height

            FocusModeView(events: store.calendarEvents)
                .frame(width: landscapeW, height: landscapeH)
                .rotationEffect(needsRotation ? orientationManager.rotation : .zero)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    private var shouldDisableIdleTimer: Bool {
        doneShouldDisableIdleTimer(
            isLandscape: orientationManager.isLandscape,
            landscapeFocusModeEnabled: landscapeFocusModeEnabled,
            landscapeFocusKeepAwakeEnabled: landscapeFocusKeepAwakeEnabled,
            showSplash: showSplash,
            scenePhase: scenePhase
        )
    }
}
