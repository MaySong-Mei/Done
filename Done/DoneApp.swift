//
//  DoneApp.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import UIKit
import MetricKit
import os

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

/// The one geometry request the gate-open repair loop should issue for a
/// given (pose, window shape, reported orientation) reading, or `nil`
/// when there is nothing to repair.
enum FocusGateOpenRepairAction: Equatable {
    /// Reported orientation is portrait while the device lies landscape:
    /// a landscape-only request validates against the open supported set
    /// and is not "already satisfied", so it rotates. UIKit picks the
    /// side matching the pose.
    case requestLandscape
    /// The split state's one instrument: pull the REPORTED orientation
    /// down to match the geometry with a `.portrait` request. Once that
    /// commits, the next evaluation issues `requestLandscape` against a
    /// reported-portrait scene, which rotates normally.
    ///
    /// The calibration changes no window geometry — this case only
    /// fires while the window already renders portrait — but the commit
    /// still runs one visible scene-level transition animation. That
    /// swing is the known cost of repairing the split state: an
    /// animation-free model-layer repair (writing the window frame
    /// directly) was tried and falsified on device — the presentation
    /// layer does not follow model-layer writes, only a real
    /// orientation transition rotates it, and its orientation is not
    /// observable from the model layer, so the failure cannot even be
    /// detected. The falsification archive lives in this commit's
    /// message; do not retry that path.
    case calibrateReportedOrientationToPortrait

    /// The exact geometry-request mask this action issues. On the pure
    /// layer so the masks are pinned by equality tests: the landscape
    /// mask must contain BOTH sides (UIKit picks the one matching the
    /// pose) and must NOT contain portrait — a portrait bit there is
    /// bookkeeping-satisfied in the cold-start split state and silently
    /// revives the no-op defect. The calibration mask is portrait alone.
    var requestMask: UIInterfaceOrientationMask {
        switch self {
        case .requestLandscape:
            return [.landscapeLeft, .landscapeRight]
        case .calibrateReportedOrientationToPortrait:
            return .portrait
        }
    }
}

/// Pure helper: one step of the gate-open repair loop. Extracted so the
/// decision's truth table — and the loop's convergence — is testable
/// without UIKit.
///
/// UIKit changes interface orientation when it processes a
/// device-orientation event (evaluated against the supported mask at
/// that instant), when it receives an explicit `requestGeometryUpdate`
/// whose mask its bookkeeping does not already satisfy, and — measured
/// on device — when a supported-orientations invalidation lands while
/// the scene is at rest, in which case it does re-resolve against the
/// current pose. What it does NOT do is revisit the decision in exactly
/// two shapes, and those are the gh#174 stuck class: (a) the
/// invalidation lands while a rotation transition is in flight or just
/// committed — the re-queries merely validate, and portrait is
/// deliberately inside the open-gate mask, so "stay portrait" is a
/// legal answer — and (b) the landscape cold start, where the window
/// laid out portrait before the gate opened. In both shapes the device
/// is already lying landscape, the window renders portrait, and no
/// further pose change is ever due to re-offer UIKit the rotation.
/// The repair is an explicit request, while the SUPPORTED mask stays
/// portrait+landscape so a later physical rotation back to portrait
/// still works.
///
/// The window-shape input is the WINDOW's rendered truth, deliberately
/// NOT the reported `interfaceOrientation`: at a landscape cold start
/// the reported orientation already reads landscape (system chrome
/// rotated) while the window itself laid out portrait, so the reported
/// value cannot serve as the mismatch signal. The reported orientation
/// IS an input, but for a different question: it selects the
/// instrument. When it reads landscape, a landscape request is
/// bookkeeping-satisfied and silently no-ops (the cold-start defect),
/// so the split state calibrates first; when it reads portrait, the
/// landscape request fires directly.
///
/// WHERE the caller sources these inputs is part of the contract. Live
/// `window.bounds` lag a geometry commit, so a commit-triggered
/// re-evaluation must NOT read them — it feeds the committed
/// orientation to BOTH inputs (post-commit they are synonymous, and a
/// live-bounds read there tears: new reported value against stale
/// bounds mis-fires the split-state repair or mis-reads "done"). The
/// split state — the one reading where the two inputs differ — is a
/// rest-only state, detectable only by the gate-open evaluation's live
/// bounds read; it cannot arrive via the commit path.
///
/// The guard is pose-based on purpose and covers BOTH entry paths with
/// the one principle "pose truth at gate-open" — it is deliberately NOT
/// scoped to the auto-focus-on-rotation trigger. A manual focus entry
/// while the device is genuinely held landscape is the same stuck shape
/// arriving via the manual path: the gate opens on the tap, the pose is
/// already landscape and static, so no device event is ever due and
/// UIKit would validate portrait forever. With auto-focus-on-rotation
/// off (the default configuration), the manual path is therefore the
/// ONLY way this branch fires; that is intended behavior, not an
/// accident of the guard. Scoping it to the auto path would reintroduce
/// gh#174 for exactly that configuration.
///
/// Every non-landscape pose returns `nil`: an upright device — in
/// particular a manual focus entry in portrait — must never be
/// force-rotated (repo bedrock: entering focus never rotates an upright
/// device), and the flat poses (`.faceUp`/`.faceDown`) plus `.unknown`
/// carry no information about which way the device is held, so they
/// don't justify a rotation either. `.unknown` degrading to "no
/// request" is the deliberate cold-start decision: the gate only opens
/// landscape-justified after a real landscape device sample has been
/// processed (the auto-focus trigger requires one, and notification
/// generation starts at `OrientationManager` construction, before any
/// gate write), so at that instant the sensor read is a real pose — and
/// if `.unknown` were ever read anyway, staying portrait reproduces the
/// pre-fix behavior rather than rotating on a guess.
func focusGateOpenRepairAction(
    devicePose: UIDeviceOrientation,
    windowIsLandscapeShaped: Bool,
    reportedInterfaceIsLandscape: Bool
) -> FocusGateOpenRepairAction? {
    guard devicePose.isLandscape, !windowIsLandscapeShaped else { return nil }
    return reportedInterfaceIsLandscape
        ? .calibrateReportedOrientationToPortrait
        : .requestLandscape
}

/// Rest-state invariant, pure so the confirmation rule is pinned by
/// tests: a scene truly at rest has its window shape and reported
/// orientation in agreement. A disagreeing at-rest reading is either
/// the split state (it persists) or a torn read beside a commit the
/// repair loop's observer was not yet armed for (it vanishes once the
/// bounds settle) — indistinguishable at read time, so a disagreeing
/// reading must be re-read after a settle window before it may act. An
/// agreeing reading never waits: the plain requestLandscape cell and
/// the nothing-to-repair cell pay no added latency.
func focusGateOpenAtRestReadingNeedsConfirmation(
    windowIsLandscapeShaped: Bool,
    reportedInterfaceIsLandscape: Bool
) -> Bool {
    windowIsLandscapeShaped != reportedInterfaceIsLandscape
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

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "OrientationGate"
    )

    /// Ask UIKit to re-evaluate the supported orientations on the root
    /// view controller, optionally forcing a specific orientation.
    /// Pass `target = nil` on enter so the device's pose drives rotation;
    /// pass `.portrait` on exit to snap back when focus ends.
    ///
    /// On enter, "the pose drives rotation" has one hole: the pose event
    /// that justified opening the gate has already been consumed by UIKit
    /// against the still-closed mask, and if the device never moves again
    /// no rotation opportunity recurs (gh#174). So while the gate is
    /// open, a repair loop watches for the stuck shape — device
    /// landscape, window rendering portrait — and issues the explicit
    /// request `focusGateOpenRepairAction` computes; in every other
    /// state it stays hands-off.
    ///
    /// The loop, not a one-shot: the stuck shape can also RE-form after
    /// the gate opens — a portrait request queued by a just-closed exit
    /// leg can land after a rapid re-enter, putting a portrait window
    /// under an open gate again with the enter-time evaluation already
    /// spent. So the enter leg arms a KVO observation on the scene's
    /// `effectiveGeometry` and re-evaluates after every geometry commit;
    /// the exit leg tears it down. The evaluation is pure and idempotent
    /// (`focusGateOpenRepairAction`), so re-runs are safe, and the loop
    /// converges: each issued request strictly moves reported orientation
    /// and window toward agreement with the pose, and an agreeing state
    /// evaluates to "nothing to repair".
    ///
    /// Input sourcing is asymmetric, and that is load-bearing. A
    /// commit-triggered re-evaluation takes the COMMITTED orientation as
    /// the window truth for both decision inputs — live `window.bounds`
    /// lag the commit, and reading them there tears (new reported value
    /// against stale bounds), mis-firing the calibration or mis-reading
    /// "done". Only the gate-open evaluation reads live bounds and the
    /// reported orientation: the split state is a rest-only reading, and
    /// bounds are its only probe. The observation covers only commits
    /// that land AFTER it is armed — a commit landing just before arming
    /// can leave that at-rest read torn with no corrector ever due — so
    /// a disagreeing at-rest reading is confirmed after a settle window
    /// before it may act, while an agreeing reading acts immediately
    /// (see `evaluateGateOpenRepairAtRest`).
    ///
    /// The first evaluation MUST run on the next main-queue turn, after
    /// the invalidation below: an explicit geometry request validates
    /// against the root view controller's CACHED supported set, which a
    /// same-turn invalidation has not yet refreshed — a same-turn
    /// landscape-only request is rejected against the stale
    /// portrait-only cache. KVO-triggered evaluations are deferred
    /// through the same hop, so every request the loop issues sees the
    /// refreshed cache.
    static func applyOrientationChange(target: UIInterfaceOrientationMask?) {
        if target != nil {
            // Exit leg: the repair loop must not outlive the gate.
            endGateOpenRepairLoop()
        }
        guard let scene = UIApplication.shared
                .connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }
        if let target {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard target == nil else { return }
        beginGateOpenRepairLoop(scene: scene)
    }

    /// KVO observation driving the gate-open repair loop. Non-nil
    /// exactly while the gate is open (armed by the enter leg, torn
    /// down by the exit leg; re-arming replaces the previous
    /// observation, so repeated enter-leg syncs never stack observers).
    private static var geometryObservation: NSKeyValueObservation?

    /// Repair-session token: incremented on every arm AND every
    /// teardown. Each deferred continuation — the initial at-rest
    /// evaluation, its confirmation re-read, and every KVO evaluation
    /// hop — captures the token at scheduling time and discards itself
    /// if the session has moved on. This closes two gaps the `allowsLandscape` bail alone leaves
    /// open across a rapid close-and-reopen: a stale confirmation from
    /// the previous session acting unconfirmed in the new one, and two
    /// confirmation chains coexisting. The `allowsLandscape` bail stays
    /// as the second, independent guard.
    private static var repairSessionToken = 0

    private static func beginGateOpenRepairLoop(scene: UIWindowScene) {
        geometryObservation?.invalidate()
        repairSessionToken += 1
        let token = repairSessionToken
        geometryObservation = scene.observe(\.effectiveGeometry) { scene, _ in
            // The commit that woke this observer is the window truth for
            // the re-evaluation it schedules: live window.bounds lag the
            // commit, so they must NOT be read on this path. Post-commit
            // the window shape and the reported orientation are
            // synonymous, so the committed orientation feeds both
            // decision inputs; the split state (inputs differing) is a
            // rest-only reading and cannot arrive here. Captured before
            // the hop so the evaluation judges the commit that woke it,
            // not whatever is current by then — a newer commit schedules
            // its own evaluation.
            let committedIsLandscape = MainActor.assumeIsolated {
                scene.effectiveGeometry.interfaceOrientation.isLandscape
            }
            // UIKit posts the change on main; the hop both re-asserts
            // that at the type level and moves the evaluation onto its
            // own settled turn (refreshed supported-set cache).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == repairSessionToken else { return }
                    evaluateGateOpenRepair(scene: scene, commitIsLandscape: committedIsLandscape)
                }
            }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard token == repairSessionToken else { return }
                evaluateGateOpenRepairAtRest(scene: scene, sessionToken: token)
            }
        }
    }

    private static func endGateOpenRepairLoop() {
        geometryObservation?.invalidate()
        geometryObservation = nil
        repairSessionToken += 1
    }

    /// Settle bound for confirming a disagreeing at-rest reading: a
    /// wall-clock upper bound with margin over the measured settle
    /// envelope. Wall-clock on purpose — the
    /// bounds settle with layout, which is frame-paced, while chained
    /// main-queue hops are queue drains: on a busy queue they can all
    /// run inside a single render pass with zero layout progress, and
    /// the re-read replays the tear it was meant to outwait. Margin
    /// arithmetic lives in the commit message.
    private static let atRestSettleUpperBound: TimeInterval = 0.05

    private static func afterSettleWindow(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + atRestSettleUpperBound) {
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    /// The gate-open evaluation: the ONLY reader of live window bounds
    /// and the reported orientation, because the split state — window
    /// portrait, reported landscape — is a rest-only condition and live
    /// bounds are its only probe. Commit-triggered re-evaluations must
    /// come through the `commitIsLandscape` shape instead; see the
    /// input-sourcing note on `applyOrientationChange`.
    ///
    /// The KVO observation covers only commits that land after it is
    /// armed, so a commit landing just before arming leaves this read
    /// torn — new reported value against bounds that settle later — with
    /// no commit due to correct it: a portrait-commit tear reads as
    /// "window landscape, nothing to repair" and deadlocks in the bug
    /// state, and a landscape-commit tear is input-indistinguishable
    /// from the true split state and would mis-fire a visible
    /// calibration. The rest-state invariant separates them
    /// (`focusGateOpenAtRestReadingNeedsConfirmation`): a disagreeing
    /// reading is re-read once after a settle window and acted on then,
    /// whatever it says — no recursive confirmation, so the wait is
    /// bounded — while an agreeing reading acts immediately, keeping the
    /// plain repair cells latency-free.
    private static func evaluateGateOpenRepairAtRest(scene: UIWindowScene, sessionToken: Int) {
        let first = atRestReading(scene)
        guard focusGateOpenAtRestReadingNeedsConfirmation(
            windowIsLandscapeShaped: first.windowIsLandscapeShaped,
            reportedInterfaceIsLandscape: first.reportedInterfaceIsLandscape
        ) else {
            evaluateGateOpenRepair(
                scene: scene,
                windowIsLandscapeShaped: first.windowIsLandscapeShaped,
                reportedInterfaceIsLandscape: first.reportedInterfaceIsLandscape
            )
            return
        }
        afterSettleWindow {
            // The gate may have closed — or closed and reopened —
            // while the confirmation was pending; both guards, per the
            // session-token contract.
            guard allowsLandscape, sessionToken == repairSessionToken else { return }
            let second = atRestReading(scene)
            evaluateGateOpenRepair(
                scene: scene,
                windowIsLandscapeShaped: second.windowIsLandscapeShaped,
                reportedInterfaceIsLandscape: second.reportedInterfaceIsLandscape
            )
        }
    }

    private static func atRestReading(
        _ scene: UIWindowScene
    ) -> (windowIsLandscapeShaped: Bool, reportedInterfaceIsLandscape: Bool) {
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        let bounds = window?.bounds ?? .zero
        return (bounds.width > bounds.height, scene.interfaceOrientation.isLandscape)
    }

    /// Commit-path evaluation: the committed orientation IS the window
    /// truth and feeds both decision inputs by construction — the
    /// sourcing contract lives in this signature, so violating it means
    /// changing a type, not just drifting a call site. The two-input
    /// form below is reserved for the at-rest reader.
    private static func evaluateGateOpenRepair(scene: UIWindowScene, commitIsLandscape: Bool) {
        evaluateGateOpenRepair(
            scene: scene,
            windowIsLandscapeShaped: commitIsLandscape,
            reportedInterfaceIsLandscape: commitIsLandscape
        )
    }

    /// One turn of the repair loop: issue the one request the pure
    /// decision names for the given readings, or nothing. The caller
    /// owns input sourcing (at-rest reads vs commit truth); this only
    /// re-reads the gate and the pose, which are not geometry.
    private static func evaluateGateOpenRepair(
        scene: UIWindowScene,
        windowIsLandscapeShaped: Bool,
        reportedInterfaceIsLandscape: Bool
    ) {
        // The gate may have closed between scheduling and this turn
        // (the exit leg tears the observer down, but an already-queued
        // evaluation still runs); a landscape request against a closed
        // portrait-only gate would be rejected by design, so bail.
        guard allowsLandscape else { return }
        guard let action = focusGateOpenRepairAction(
            devicePose: UIDevice.current.orientation,
            windowIsLandscapeShaped: windowIsLandscapeShaped,
            reportedInterfaceIsLandscape: reportedInterfaceIsLandscape
        ) else { return }
        switch action {
        case .requestLandscape:
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: action.requestMask)) { error in
                // A rejection here means the app is back in the gh#174
                // stuck state with no further rotation opportunity due,
                // so the failure must leave a trace rather than silently
                // no-op.
                logger.error("gate-open landscape geometry request rejected: \(error.localizedDescription, privacy: .public)")
            }
        case .calibrateReportedOrientationToPortrait:
            // Split state: pull the reported orientation down to the
            // geometry so the landscape request stops being
            // bookkeeping-satisfied. The commit runs one visible
            // scene-level transition — the known cost of repairing the
            // split state (see the enum case doc for why the
            // animation-free alternative is closed) — and re-enters the
            // loop via KVO; the next evaluation issues the landscape
            // request. The probe records the readings at calibration
            // time.
            let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
            logger.debug("calibrate-probe coordSpace=\(String(describing: scene.coordinateSpace.bounds), privacy: .public) windowFrame=\(String(describing: window?.frame), privacy: .public)")
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: action.requestMask)) { error in
                logger.error("gate-open calibration geometry request rejected: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register the MetricKit subscriber as early as possible so the first
        // post-launch delivery (which can carry the PREVIOUS run's crash) is
        // captured. See AppMetricsReporter.
        AppMetricsReporter.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        focusOrientationMask(allowsLandscape: FocusOrientationGate.allowsLandscape)
    }
}

/// MetricKit subscriber: watches the CALayer-rewrite rollout in the field.
///
/// MetricKit delivers payloads ~once per day at launch, and ONLY on real
/// devices (never the simulator). First-party — no third-party telemetry,
/// consistent with the app's local-first / privacy stance. Summaries go to
/// `os.Logger` (visible in Console / device logs); full payloads are persisted
/// to `Documents/Diagnostics/` so crash call-stacks and metrics survive
/// os_log truncation and ride along in device backups for later retrieval.
///
/// The headline signal for the rewrite is `scrollHitchTimeRatio` — it answers,
/// in the field, whether the UIKit+CALayer timeline actually scrolls smoother
/// than the old SwiftUI path. Crash/hang diagnostics let us catch regressions
/// in the (default-ON, no-remote-kill-switch) rewrite that on-device testing
/// missed.
final class AppMetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = AppMetricsReporter()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "Metrics"
    )

    func start() {
        MXMetricManager.shared.add(self)
        logger.log("MetricKit subscriber registered (payloads arrive ~daily, device-only)")
    }

    // Daily aggregated performance metrics.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let ratio = payload.animationMetrics?.scrollHitchTimeRatio {
                // Headline CALayer-rewrite field signal: lower = smoother scroll.
                logger.log("metric scrollHitchTimeRatio=\(ratio.value, privacy: .public)")
            }
            if let peak = payload.memoryMetrics?.peakMemoryUsage {
                logger.log("metric peakMemoryMB=\(peak.converted(to: .megabytes).value, privacy: .public)")
            }
            persist(payload.jsonRepresentation(), kind: "metric")
        }
    }

    // Crashes, hangs, CPU/disk exceptions — delivered near-real-time on device.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                logger.error("diagnostic CRASH type=\(crash.exceptionType?.intValue ?? -1) code=\(crash.exceptionCode?.intValue ?? -1) signal=\(crash.signal?.intValue ?? -1) reason=\(crash.terminationReason ?? "?", privacy: .public)")
            }
            for hang in payload.hangDiagnostics ?? [] {
                logger.error("diagnostic HANG durationSec=\(hang.hangDuration.converted(to: .seconds).value, privacy: .public)")
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                logger.error("diagnostic CPU-EXCEPTION cpuTimeSec=\(cpu.totalCPUTime.converted(to: .seconds).value, privacy: .public)")
            }
            persist(payload.jsonRepresentation(), kind: "diagnostic")
        }
    }

    /// Persist the raw payload JSON to `Documents/Diagnostics/` so crash stacks
    /// and metrics survive beyond os_log truncation and are captured by device
    /// backup. Mirrors the quarantine-to-Documents pattern in EventStore.
    private func persist(_ data: Data, kind: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("Diagnostics", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(kind)-\(stamp).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            logger.log("persisted \(kind, privacy: .public) payload → \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("failed to persist \(kind, privacy: .public) payload: \(error.localizedDescription, privacy: .public)")
        }
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
    // `.production` is the real store. Under XCTest it resolves to a
    // separate directory (see `EventStorageLocation`) — DoneTests is a
    // host-app bundle, so THIS store is alive during a test run and would
    // otherwise be reading and writing the dogfood user's calendar.
    @StateObject private var store = EventStore(storage: .production)
    @StateObject private var agentRuntime = AgentRuntime()
    @StateObject private var orientationManager = OrientationManager()
    /// gh#197 SPIKE v2: app-level owner of armed spike runs and the single
    /// writer of the harness's instrumentation seams. Lives here, beside
    /// the store, so a run armed from the sheet-presented settings UI
    /// survives that sheet's dismissal — v1's view-owned runner died with
    /// the sheet mid-run, silently dropping every signal.
    @StateObject private var spikeSession = SpikeSessionCoordinator()
    /// FIX WATCH: the resident observability tier. Plain @State (NOT an
    /// ObservableObject — its signal path must never publish during a
    /// view update); created once in onAppear, and ONLY when not running
    /// under XCTest (R-F10): DoneTests is a host-app bundle, and a
    /// resident wired at app launch would run counter work and real
    /// CADisplayLink auto-windows during timing-sensitive tests. Tests
    /// construct their own centers over scratch stores.
    @State private var residentObservation: ResidentObservationCenter? = nil
    /// Auto-enter focus mode when device rotates to landscape. Default off:
    /// users opt in. Manual entry via the calendar header focus button is
    /// always available regardless of this flag.
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = false
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
    @AppStorage(AppSettingsKeys.nearFutureHorizonDays) private var nearFutureHorizonDays: Int = EventZone.defaultHorizonDays
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue
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
                    .environmentObject(spikeSession)

                if showSplash {
                    SplashView()
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .environmentObject(spikeSession)
                        .transition(.opacity)
                        .zIndex(1)
                }

                // Focus is a state, not an orientation. Auto-on-rotation
                // is one optional way to enter (rotating physically to
                // landscape with the toggle on). Manual entry via the
                // header button is the other, independent of orientation.
                if focusActive {
                    focusModeOverlay
                        .zIndex(2)
                }
            }
            // No `.transition` on that branch and no
            // `.animation(_:value: focusActive)` on this container. Both
            // shipped as fixes for the entry cut and neither works here:
            // a transition only runs when the update that flips the branch
            // carries an animation, and in this app that update reliably
            // doesn't. Instrumented across repeated launches, an insertion
            // driven by `withAnimation` around the flag write animated 0
            // times out of 5 — and 0 out of 5 again with the
            // orientation-lock side effect deferred out of the same turn,
            // which was the standing theory for why. So focus is not faded
            // in from out here at all: the surface fades itself up on
            // `@State` it owns, which needs nothing from this update. See
            // `entryProgress` in FocusModeView.
            .environmentObject(orientationManager)
            .preferredColorScheme((AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
            .onAppear {
                doneApplyIdleTimerPolicy(shouldDisableIdleTimer)
                syncOrientationLock(focusActive: focusActive)
                handleDominoScenePhase(.active)
                // gh#197 SPIKE: close orphaned spike runs — open records
                // on disk that no live runner in THIS process owns (the
                // process that armed them died) — as interrupted rather
                // than leaving them "in progress" forever. Runs armed
                // right now are excluded: this hook re-fires on scene
                // reconnect with the process surviving, and an armed
                // run's write-ahead record must never be closed out from
                // under a live measurement. No-op when no spike has ever
                // run.
                SpikeRunStore.reconcileAllRegisteredSpikesAtLaunch(excludingRunIDs: spikeSession.armedRunIDs)
                // FIX WATCH: wire the resident tier — real app only, never
                // under XCTest (see `residentObservation`'s doc).
                if residentObservation == nil, !EventStorageLocation.isRunningUnderXCTest {
                    let center = ResidentObservationCenter(coordinator: spikeSession, store: store)
                    center.activate()
                    residentObservation = center
                }
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

    /// Focus held open by the device's pose rather than by the user's
    /// choice. `onExit` clears only the manual flag, so while this is
    /// true nothing the focus surface does can end the session.
    private var autoFocusTrigger: Bool {
        orientationManager.isLandscape && landscapeFocusModeEnabled
    }

    private var focusActive: Bool {
        autoFocusTrigger || orientationManager.manualFocusActive
    }

    private func syncOrientationLock(focusActive: Bool) {
        FocusOrientationGate.allowsLandscape = focusActive
        // On enter: don't force a specific orientation on an upright
        // device. The supported set now includes portrait + landscape, so
        // iOS keeps the current orientation and rotates when the user
        // physically rotates the device — except when the rotation that
        // opened the gate has already been consumed against the closed
        // mask, which the enter path detects and resolves itself (see
        // `applyOrientationChange`). On exit: force back to portrait
        // since landscape is no longer a supported orientation.
        FocusOrientationGate.applyOrientationChange(
            target: focusActive ? nil : .portrait
        )
    }

    @ViewBuilder
    private var focusModeOverlay: some View {
        FocusModeView(
            // canvasRenderableCalendarEvents: same absorbed-filter the
            // main canvas uses.  Without it, an absorbed `.todo`
            // overlapping `now` could become the focus protagonist —
            // contradicting "absorbed todos live inside the parent".
            events: store.canvasRenderableCalendarEvents,
            templates: agentRuntime.eventTypeTemplateStore.templates,
            onExit: { orientationManager.endManualFocus() },
            canExitBySwipe: !autoFocusTrigger,
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
        // 15-min cadence — each tick visibly shifts past-horizon todos
        // by ~15pt at the default hourHeight (60pt/h), big enough that
        // the user can verify "yes, the push is happening" at a
        // glance.  Per-minute ticks made the shift ~1pt — visually
        // indistinguishable from "nothing happened", which is what
        // tripped the original dogfood report.  Catch-up on
        // foreground enter still fires immediately and uses the full
        // since-last-push delta regardless of cadence.
        //
        // Block-based Timer fires on the run loop that scheduled it
        // (main, since we schedule from `.onAppear`/`.onChange`), and
        // EventStore isn't @MainActor-isolated, so the closure
        // doesn't need an additional actor hop.
        dominoPushTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            store.dominoPushTodosPastHorizon(horizonDays: nearFutureHorizonDays)
        }
    }

    private func stopDominoPushTimer() {
        dominoPushTimer?.invalidate()
        dominoPushTimer = nil
    }
}
