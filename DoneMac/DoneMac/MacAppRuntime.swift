//
//  MacAppRuntime.swift
//  DoneMac
//
//  Owns the app's object graph. Since the Mac caught up with king (gh#257)
//  the truth is the SHARED graph the iPhone runs — `EventStore`,
//  `AuthService`, `SupabaseSyncService`, `AgentRuntime` (type catalog and
//  preference store) and `SkillInsightStore` — wired the way
//  `ContentView.onAppear` wires them. The Mac adds only its observation
//  adapter (`MacEventStore`), the clock and the work bill.
//

import AppKit
import SwiftUI

@MainActor
final class MacAppRuntime {
    let bill = MacWorkBill()
    let shared: EventStore
    let store: MacEventStore
    let clock: ClockHub
    let auth: AuthService
    let sync: SupabaseSyncService
    let agentRuntime: AgentRuntime
    let skillStore: SkillInsightStore
    let syncStatus = SyncStatusReporter()
    /// Held only so the shared erase has every store it purges. Not attached:
    /// the Mac has no photo intake or device-backup snapshot to run, and
    /// `CalendarViewState` is the iOS view state whose persisted keys the
    /// erase forgets (the Mac keeps none of its own yet).
    let imageBackup = ImageBackupCoordinator()
    let backupSnapshot = BackupSnapshotService()
    let calendarViewState = CalendarViewState()
    let billLog: BillLog?
    /// ONE calendar snapshot for the whole graph — store, projection and
    /// views must never disagree on day membership (review round-2 #21).
    private(set) var calendar: Calendar

    private var resignObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    init() {
        // Before anything reads a setting: the sync master switch defaults
        // ON (design D9) — the same first line as the iOS app's init.
        AppSettingsKeys.registerLaunchDefaults()
        Self.removeRetiredSidecar()
        let calendar = Calendar.current
        self.calendar = calendar
        // No demo events on a device that has, or has had, an account
        // (design §7 Phase 1): they would upload into it.
        let shared = EventStore(storage: .production,
                                seedsSampleDataIfEmpty: AuthService.seedsSampleDataAtLaunch())
        self.shared = shared
        store = MacEventStore(shared: shared, bill: bill, calendar: calendar)
        clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: true)
        billLog = try? BillLog(location: .production, calendar: calendar)
        #if DEBUG
        // A QA launch with an injected session (SYNC_DEBUG_SESSION, non-
        // production only) keeps it in memory: an ad-hoc-signed debug build
        // changes identity every build, and a login-keychain item written by
        // one build makes the next build's read stop on a keychain prompt.
        if ProcessInfo.processInfo.environment[AuthService.injectedSessionVariable] != nil {
            auth = AuthService(sessionStore: InMemorySessionStore())
        } else {
            auth = AuthService()
        }
        #else
        auth = AuthService()
        #endif
        agentRuntime = AgentRuntime()
        skillStore = SkillInsightStore()
        sync = SupabaseSyncService(ownerRecord: .production)
        sync.statusReporter = syncStatus
        // gh#257 (data belongs to its account): a sign-in over another
        // account's fully synced data switches on its own through the one
        // erase. Set before `attach`, whose session sink may switch at once.
        let eraser = LocalDataEraser(store: shared, skillStore: skillStore, agentRuntime: agentRuntime,
                                     authService: auth, calendarState: calendarViewState,
                                     syncService: sync, imageBackupCoordinator: imageBackup,
                                     backupSnapshotService: backupSnapshot)
        sync.ownerSwitchEraser = { eraser.resetAllLocalData(keepingSession: true) }
        sync.attach(
            authService: auth,
            eventStore: shared,
            eventTypeStore: agentRuntime.eventTypeTemplateStore,
            skillStore: skillStore,
            preferenceStore: agentRuntime.preferenceStore
        )
    }

    /// The retired Mac engine's revision sidecar (per-row revisions, server
    /// stamps, unpushed tombstones) beside the storage directory. Nothing
    /// reads it since the Mac runs the shared engine, and it holds event ids,
    /// so it goes with the old engine rather than outliving every erase
    /// (review 2026-10-24 Q3). Its unpushed deletes are not replayed: that
    /// engine could not reach the backend after 2026-09-23 (legacy keys
    /// revoked), so no installed Mac carries any.
    private static func removeRetiredSidecar() {
        guard let directory = try? EventStorageLocation.production.directoryURL() else { return }
        let sidecar = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + "-Sidecar", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        try? FileManager.default.removeItem(at: sidecar)
        DiagnosticTrail.record("Persistence", "mac.retired-sidecar removed")
    }

    private var started = false
    /// The one window that presents the account-safety prompts; every
    /// window observes the same engine, and N windows would stack N alerts.
    var safetyHostID: UUID?

    /// The system time zone changed: move every day-frame holder the runtime
    /// owns to the new `Calendar.current`. Returns whether anything changed;
    /// windows rebuild their surface models when the zone differs from the
    /// one they were built in.
    @discardableResult
    func adoptCurrentCalendar(now: Date) -> Bool {
        NSTimeZone.resetSystemTimeZone()
        let current = Calendar.current
        guard current.timeZone != calendar.timeZone else { return false }
        calendar = current
        store.adoptCalendar(current)
        clock.adoptCalendar(current, now: now)
        return true
    }

    func start() async {
        // Every window's .task calls this; observers register once.
        guard !started else { return }
        started = true
        let store = self.store
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await store.flush()
                if let self { self.billLog?.appendSnapshot(self.bill, now: Date()) }
            }
        }
        let clock = self.clock
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Any window visible → the app is on screen. All occluded
                // → suspend the clock entirely (clockTicksWhileOccluded
                // stays a live tripwire, never routine).
                let anyVisible = NSApp.windows.contains {
                    $0.occlusionState.contains(.visible)
                }
                clock.setOccluded(!anyVisible, now: Date())
                self?.onOcclusionChange?(anyVisible)
            }
        }
    }

    /// The one local erase ("Reset all local data"), the same body iOS runs.
    var eraser: LocalDataEraser {
        LocalDataEraser(store: shared, skillStore: skillStore, agentRuntime: agentRuntime,
                        authService: auth, calendarState: calendarViewState,
                        syncService: sync, imageBackupCoordinator: imageBackup,
                        backupSnapshotService: backupSnapshot)
    }

    /// Surfaces subscribe here for the visibility clause.
    var onOcclusionChange: ((Bool) -> Void)?

    func flush() async {
        await store.flush()
        billLog?.appendSnapshot(bill, now: Date())
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    var runtime: MacAppRuntime?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        Task { @MainActor in
            await runtime.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
