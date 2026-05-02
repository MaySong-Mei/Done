//
//  DoneApp.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import UIKit

/// Pure helper: the supported-orientation mask that should be returned
/// while the focus orientation gate is in the given state. Extracted so
/// the AppDelegate's behavior is testable without instantiating UIKit.
///
/// When the gate is open (`allowsLandscape == true`) the mask must
/// include portrait too — without it, UIKit treats portrait as
/// unsupported and force-rotates the UI to landscape the moment focus
/// engages, even on an upright device.
func focusOrientationMask(allowsLandscape: Bool) -> UIInterfaceOrientationMask {
    allowsLandscape
        ? [.portrait, .landscapeLeft, .landscapeRight]
        : .portrait
}

/// Single source of truth for "is the app currently allowed to leave
/// portrait?" Read by `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`,
/// flipped when focus mode toggles. Info.plist permits landscape but we
/// only actually allow rotation when `allowsLandscape` is true, keeping
/// the rest of the app portrait-locked.
///
/// Annotated `@MainActor` so the static state can't be touched from a
/// background context — both the SwiftUI `onChange` writes and the
/// AppDelegate read happen on the main thread by UIKit convention,
/// and this enforces it at the type level.
@MainActor
enum FocusOrientationGate {
    static var allowsLandscape: Bool = false

    /// Ask UIKit to re-evaluate the supported orientations on the root
    /// view controller, optionally forcing a specific orientation.
    /// Pass `target = nil` on enter so the device's pose drives rotation;
    /// pass `.portrait` on exit to snap back when focus ends.
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

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        focusOrientationMask(allowsLandscape: FocusOrientationGate.allowsLandscape)
    }
}

/// Whether focus-mode quick actions (`+15 min`, `End now`, …) may safely
/// mutate the given event via a direct `updateCalendarEvent` call.
///
/// Returns `false` for recurring series events and for materialized
/// occurrences whose origin is a recurring parent — those need
/// scope-aware editing through `EventStore.applyRecurringEdit`. The
/// quick-action callsites here intentionally short-circuit on that
/// path; the broader recurring-events overhaul is tracked on its own
/// branch (issue #5).
func focusQuickActionAllowedForEvent(_ event: Event) -> Bool {
    if event.isRecurringSeries { return false }
    if event.recurrenceParentId != nil { return false }
    return true
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
        FocusOrientationGate.allowsLandscape = focusActive
        // On enter: don't force a specific orientation. The supported set
        // now includes portrait + landscape, so iOS keeps the current
        // orientation and only rotates when the user physically rotates
        // the device. On exit: force back to portrait since landscape is
        // no longer a supported orientation.
        FocusOrientationGate.applyOrientationChange(
            target: focusActive ? nil : .portrait
        )
    }

    @ViewBuilder
    private var focusModeOverlay: some View {
        FocusModeView(
            events: store.calendarEvents,
            templates: agentRuntime.eventTypeTemplateStore.templates,
            onExit: { orientationManager.manualFocusActive = false },
            onExtendCurrent: { event, delta in
                applyEndTimeDelta(to: event, delta: delta)
            },
            onEndCurrent: { event, now in
                applyEndTime(to: event, end: now)
            },
            onStartTracking: { template in
                startTracking(type: template.title)
            }
        )
        .ignoresSafeArea()
    }

    /// Quick-record action from the empty-state focus screen: create a
    /// new event of the chosen type starting now, default 30-min length.
    /// Title defaults to the type name as a stopgap until the in-focus
    /// title-edit flow ships — that gives the user a meaningful display
    /// (no "Untitled" placeholder) and avoids feeding empty strings to
    /// the LLM inference path. Once added, FocusModeView's TimelineView
    /// ticks and `current` resolves to this new event, so the screen
    /// flips into the in-event state automatically.
    private func startTracking(type: String) {
        let now = Date()
        let event = Event(
            title: type,
            timeRanges: [Event.TimeRange(start: now, end: now.addingTimeInterval(30 * 60))],
            type: type
        )
        store.addCalendarEvent(event)
    }

    /// Mutates the first time range of `event` by adding `delta` to its end.
    /// Single-range non-recurring events only. Recurring events short-circuit
    /// here — they need `applyRecurringEdit` with a chosen scope, tracked on
    /// the recurring-events branch (issue #5). The UI also disables the
    /// matching pills via `focusQuickActionAllowedForEvent`, so this guard is
    /// belt-and-braces.
    private func applyEndTimeDelta(to event: Event, delta: TimeInterval) {
        guard focusQuickActionAllowedForEvent(event) else { return }
        guard !event.timeRanges.isEmpty else { return }
        var updated = event
        updated.timeRanges[0].end = updated.timeRanges[0].end.addingTimeInterval(delta)
        store.updateCalendarEvent(updated)
    }

    private func applyEndTime(to event: Event, end: Date) {
        guard focusQuickActionAllowedForEvent(event) else { return }
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
