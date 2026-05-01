//
//  DoneApp.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import UIKit

/// Single source of truth for "is the app currently allowed to leave
/// portrait?" Read by `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`,
/// flipped when focus mode toggles. Info.plist permits landscape but we
/// only actually allow rotation when `allowsLandscape` is true, keeping
/// the rest of the app portrait-locked.
///
/// Important: when `allowsLandscape` is true the supported set must
/// include **portrait too**, not just landscape. Otherwise UIKit forces
/// the UI out of portrait the moment focus engages, even if the device
/// is upright — which is exactly the "focus goes landscape on tap" bug
/// we ran into when the mask read `.landscape`.
enum FocusOrientationLock {
    static var allowsLandscape: Bool = false

    /// Ask UIKit to re-evaluate the supported orientations on the root
    /// view controller, optionally forcing a specific orientation.
    /// Pass `target = nil` on enter so the device's pose drives rotation;
    /// pass `.portrait` on exit to snap back when focus ends.
    @MainActor
    static func applyOrientationChange(target: UIInterfaceOrientationMask?) {
        guard let scene = UIApplication.shared
                .connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }
        if let target {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        FocusOrientationLock.allowsLandscape
            ? [.portrait, .landscapeLeft, .landscapeRight]
            : .portrait
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

                // Focus is a state, not an orientation. Auto-on-rotation
                // is one optional way to enter (rotating physically to
                // landscape with the toggle on). Manual entry via the
                // header button is the other, independent of orientation.
                if focusActive {
                    focusModeOverlay
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
            .environmentObject(orientationManager)
            .onAppear {
                doneApplyIdleTimerPolicy(shouldDisableIdleTimer)
                syncOrientationLock(focusActive: focusActive)
            }
            .onChange(of: shouldDisableIdleTimer) { _, newValue in
                doneApplyIdleTimerPolicy(newValue)
            }
            .onChange(of: focusActive) { _, active in
                // While focus is active the device may rotate freely; when
                // it ends, we restrict back to portrait. Pushing the lock
                // change here keeps the side effect out of the gate
                // expression in `body`.
                syncOrientationLock(focusActive: active)
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

    private var focusActive: Bool {
        let autoTrigger = orientationManager.isLandscape && landscapeFocusModeEnabled
        let manualTrigger = orientationManager.manualFocusActive
        return autoTrigger || manualTrigger
    }

    private func syncOrientationLock(focusActive: Bool) {
        FocusOrientationLock.allowsLandscape = focusActive
        // On enter: don't force a specific orientation. The supported set
        // now includes portrait + landscape, so iOS keeps the current
        // orientation and only rotates when the user physically rotates
        // the device. On exit: force back to portrait since landscape is
        // no longer a supported orientation.
        FocusOrientationLock.applyOrientationChange(
            target: focusActive ? nil : .portrait
        )
    }

    @ViewBuilder
    private var focusModeOverlay: some View {
        FocusModeView(
            events: store.calendarEvents,
            onExit: { orientationManager.manualFocusActive = false },
            onExtendCurrent: { event, delta in
                applyEndTimeDelta(to: event, delta: delta)
            },
            onEndCurrent: { event, now in
                applyEndTime(to: event, end: now)
            }
        )
        .ignoresSafeArea()
    }

    /// Mutates the first time range of `event` by adding `delta` to its end.
    /// Single-range non-recurring events only — recurring/multi-range events
    /// are deferred to a future iteration that can hand them off to
    /// `applyRecurringEdit` with a chosen scope.
    private func applyEndTimeDelta(to event: Event, delta: TimeInterval) {
        guard !event.timeRanges.isEmpty else { return }
        var updated = event
        updated.timeRanges[0].end = updated.timeRanges[0].end.addingTimeInterval(delta)
        store.updateCalendarEvent(updated)
    }

    private func applyEndTime(to event: Event, end: Date) {
        guard !event.timeRanges.isEmpty else { return }
        var updated = event
        // Don't allow the end to fall before the start; clamp to start + 1s.
        let start = updated.timeRanges[0].start
        updated.timeRanges[0].end = max(end, start.addingTimeInterval(1))
        store.updateCalendarEvent(updated)
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
