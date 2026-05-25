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

/// Resolve the value to commit when the user finishes inline title
/// editing. Returns `nil` when the trimmed draft matches the current
/// title — the caller should skip the store write in that case to avoid
/// a redundant `updateCalendarEvent` (which would re-broadcast through
/// the event sync / inference pipeline). Empty-string commits are
/// allowed; the data layer handles them and the view falls back to a
/// placeholder for display.
func focusTitleCommitValue(draft: String, current: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == current ? nil : trimmed
}

/// Resolve the trimmed text to commit when the user submits an inline
/// timeline note. Returns `nil` for an empty/whitespace-only draft —
/// notes carry meaning, an all-blank submission is just noise. Unlike
/// the title path, there is no "unchanged vs. new" distinction; every
/// note creates a fresh entry tied to its own timestamp.
func focusNoteCommitText(draft: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
    @AppStorage(AppSettingsKeys.nearFutureHorizonDays) private var nearFutureHorizonDays: Int = EventZone.defaultHorizonDays
    @State private var showSplash = true
    /// Per-minute Domino-push timer.  Lives only while the scene is
    /// `.active` — backgrounding cancels it so we never push silently
    /// off-screen (battery + sync pressure + user expectation that the
    /// app is idle when not in front).  Foreground-enter does a fresh
    /// catch-up push before re-scheduling.
    @State private var dominoPushTimer: Timer? = nil

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
                handleDominoScenePhase(.active)
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
            .onChange(of: scenePhase) { _, newPhase in
                handleDominoScenePhase(newPhase)
            }
            .onDisappear {
                doneApplyIdleTimerPolicy(false)
                stopDominoPushTimer()
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
            onAddNoteToCurrent: { occurrence, text in
                appendFocusNote(for: occurrence, text: text)
            },
            onStartTracking: { template, title, start, end in
                startTracking(template: template, title: title, start: start, end: end)
            }
        )
        .ignoresSafeArea()
    }

    /// Attach a focus-mode timeline note to the current occurrence. Notes
    /// are stored on the occurrence-keyed log record (not on the series
    /// template), so the recurring guard does not apply here — a note on
    /// a recurring occurrence safely sticks to that single occurrence.
    private func appendFocusNote(for occurrence: CalendarLayout.EventOccurrence, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let context = CalendarEventOccurrenceContext(
            eventID: occurrence.event.id,
            occurrenceDate: occurrence.range.start,
            occurrenceID: occurrence.id,
            isAllDay: occurrence.event.isAllDay,
            source: .focus
        )
        store.appendTimelineNote(
            trimmed,
            createdAt: Date(),
            source: CalendarEventOccurrenceContext.Source.focus.rawValue,
            for: context
        )
    }

    /// Create a new event from a focus-mode start request and add it to
    /// the calendar. `template` carries the type cue (and its color for
    /// the entering transition). `title` is whatever the user committed
    /// in the preview — or the template's title when they took the
    /// quick path. `start` and `end` come pre-snapped from the caller.
    /// Once added, FocusModeView's TimelineView ticks and `current`
    /// resolves to this new event, so the screen flips into the
    /// inhabiting state automatically.
    private func startTracking(
        template: EventTypeTemplate,
        title: String,
        start: Date,
        end: Date
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? template.title : trimmed
        let event = Event(
            title: resolvedTitle,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: template.title
        )
        store.addCalendarEvent(event)
    }

    /// Mutates the first time range of `event` by adding `delta` to its end.
    /// Used by both `+15` (positive) and `-15` (negative) focus-mode pills.
    /// Result is snapped to the 15-min grid and clamped to `start + 15min`
    /// minimum so a negative delta can't push end below start. Single-range
    /// non-recurring events only — recurring is gated upstream.
    private func applyEndTimeDelta(to event: Event, delta: TimeInterval) {
        guard focusQuickActionAllowedForEvent(event) else { return }
        guard !event.timeRanges.isEmpty else { return }
        var updated = event
        let start = updated.timeRanges[0].start
        let raw = updated.timeRanges[0].end.addingTimeInterval(delta)
        let snapped = calendarSnapDateToMinuteGrid(raw)
        let minimumEnd = start.addingTimeInterval(15 * 60)
        updated.timeRanges[0].end = max(snapped, minimumEnd)
        store.updateCalendarEvent(updated)
    }

    private func applyEndTime(to event: Event, end: Date) {
        guard focusQuickActionAllowedForEvent(event) else { return }
        guard !event.timeRanges.isEmpty else { return }
        var updated = event
        // Snap End-now to the nearest grid mark for consistency with the
        // rest of the app, then clamp to start + 15min to keep the event
        // a valid (≥1 grid step) duration even if the user fired End-now
        // within seconds of starting.
        let start = updated.timeRanges[0].start
        let snapped = calendarSnapDateToMinuteGrid(end)
        let minimumEnd = start.addingTimeInterval(15 * 60)
        updated.timeRanges[0].end = max(snapped, minimumEnd)
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

    /// Foreground-only Domino push driver.  On `.active`: run an
    /// immediate catch-up (the delta accumulated since last push, which
    /// may be hours or days if backgrounded long) and (re)schedule the
    /// per-minute tick.  On any other phase: cancel the tick so we go
    /// silent off-screen.  Matches the "前台推进就好了，后台静默" UX.
    private func handleDominoScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            store.dominoPushTodosPastHorizon(horizonDays: nearFutureHorizonDays)
            startDominoPushTimer()
        } else {
            stopDominoPushTimer()
        }
    }

    private func startDominoPushTimer() {
        stopDominoPushTimer()
        // 60s cadence matches the time indicator's tick — the marker
        // line and the events that follow it visibly advance together.
        // The block-based Timer fires on the run loop that scheduled
        // it (main, since we schedule from `.onAppear`/`.onChange`),
        // and EventStore isn't @MainActor-isolated, so the closure
        // doesn't need an additional actor hop.
        dominoPushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            store.dominoPushTodosPastHorizon(horizonDays: nearFutureHorizonDays)
        }
    }

    private func stopDominoPushTimer() {
        dominoPushTimer?.invalidate()
        dominoPushTimer = nil
    }
}
