//
//  DoneApp.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import UIKit

/// Single source of truth for "is the app currently allowed to be in landscape
/// orientation?" Read by `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`,
/// flipped by the manual focus button. Info.plist permits landscape but we
/// only actually allow it when `allowsLandscape` is true, keeping the rest
/// of the app portrait-locked.
enum FocusOrientationLock {
    static var allowsLandscape: Bool = false

    /// Push the lock state to the active scene and ask UIKit to re-evaluate
    /// the supported orientations on the root view controller. Call this
    /// after toggling `allowsLandscape`.
    @MainActor
    static func applyOrientationChange(target: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared
                .connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        FocusOrientationLock.allowsLandscape ? .landscape : .portrait
    }
}

func doneShouldDisableIdleTimer(
    isLandscape: Bool,
    landscapeFocusModeEnabled: Bool,
    landscapeFocusKeepAwakeEnabled: Bool,
    manualFocusActive: Bool = false,
    showSplash: Bool,
    scenePhase: ScenePhase
) -> Bool {
    let autoVisible = isLandscape && landscapeFocusModeEnabled
    let focusVisible = autoVisible || manualFocusActive
    return focusVisible && landscapeFocusKeepAwakeEnabled && !showSplash && scenePhase == .active
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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = EventStore()
    @StateObject private var agentRuntime = AgentRuntime()
    @StateObject private var orientationManager = OrientationManager()
    /// Auto-enter focus mode when device rotates to landscape. Default off:
    /// users opt in. Manual entry via the calendar header focus button is
    /// always available regardless of this flag.
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = false
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

                // Auto path is gated on physical landscape orientation
                // (the user explicitly rotated the device). Manual path
                // is independent: tapping the header button triggers a
                // forced UI rotation via `FocusOrientationLock`, but
                // `UIDevice.orientation` only reflects physical pose, so
                // we cannot wait on `isLandscape` here.
                let autoTrigger = orientationManager.isLandscape && landscapeFocusModeEnabled
                let manualTrigger = orientationManager.manualFocusActive
                if autoTrigger || manualTrigger {
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
            manualFocusActive: orientationManager.manualFocusActive,
            showSplash: showSplash,
            scenePhase: scenePhase
        )
    }
}
