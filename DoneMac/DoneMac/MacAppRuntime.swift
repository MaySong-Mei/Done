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
import Observation

/// Window coordination the views observe: who hosts the account-safety
/// prompts, and when the day frame moved (windows rebuild their models).
@MainActor
@Observable
final class WindowRoles {
    /// The key window presents the account-safety prompts. Whichever window
    /// the user is in claims it, so a prompt never lands in a closed or
    /// background window and a Reset asked for in one window is confirmed
    /// in that window (review round 2, Q2).
    var safetyHostID: UUID?
    /// Bumped when the runtime moves to a new day frame.
    var dayFrameGeneration = 0
}

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
    /// ONE calendar for the whole graph — store, projection and views must
    /// never disagree on day membership (review round-2 #21). The process's
    /// default time zone is PINNED to it (see `init`), so the shared store,
    /// which reads `Calendar.current` per call, computes in the same frame.
    private(set) var calendar: Calendar
    let roles = WindowRoles()
    /// Windows with an edit in flight (composer open, drag active,
    /// inspector open). A zone change waits until this is empty.
    private var busyWindowIDs: Set<UUID> = []
    private var zoneChangePending = false
    private var occlusionHandlers: [UUID: (Bool) -> Void] = [:]
    private var zoneObserver: NSObjectProtocol?

    private var resignObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    init() {
        // Before anything reads a setting: the sync master switch defaults
        // ON (design D9) — the same first line as the iOS app's init.
        AppSettingsKeys.registerLaunchDefaults()
        Self.removeRetiredSidecar()
        // Pin the frame. The shared store reads `Calendar.current` on every
        // call while the Mac's surfaces hold one calendar; a system zone
        // change mid-session would otherwise split them and land edits on the
        // wrong day (review 2026-10-24 #2). With the default zone set
        // explicitly, `Calendar.current` stays on it until the runtime moves
        // both sides together, at a moment no edit is in flight.
        NSTimeZone.default = TimeZone.current
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
    /// (review 2026-10-24 Q3). Deleting it changes nothing about sync: the
    /// shared engine never read it. Deletes that engine recorded but could
    /// not push (it was refused by the backend from 2026-09-23, when the
    /// legacy keys were revoked) come back on the shared engine's first
    /// pull, with or without this file.
    private static func removeRetiredSidecar() {
        guard let directory = try? EventStorageLocation.production.directoryURL() else { return }
        let sidecar = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + "-Sidecar", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        try? FileManager.default.removeItem(at: sidecar)
        DiagnosticTrail.record("Persistence", "mac.retired-sidecar removed")
    }

    private var started = false

    // MARK: - Windows

    /// A window reports whether it has an edit in flight. Leaving the busy
    /// set may apply a zone change that was waiting for it.
    func setWindow(_ id: UUID, busy: Bool) {
        if busy {
            busyWindowIDs.insert(id)
        } else {
            busyWindowIDs.remove(id)
            applyZoneChangeIfIdle(now: Date())
        }
    }

    func windowClosed(_ id: UUID) {
        busyWindowIDs.remove(id)
        occlusionHandlers[id] = nil
        draftFlushers[id] = nil
        if roles.safetyHostID == id { roles.safetyHostID = nil }
        applyZoneChangeIfIdle(now: Date())
    }

    /// Each window's surface hears the visibility clause (one slot per
    /// window; a single slot left every window but the last stale).
    func setOcclusionHandler(_ id: UUID, _ handler: ((Bool) -> Void)?) {
        occlusionHandlers[id] = handler
    }

    /// Per-window "keep what's typed" hooks (the inspector's open note and
    /// reflection drafts), run before the store's terminate flush — the
    /// phone flushes these when the app leaves the foreground; SwiftUI's
    /// onDisappear is not reliable at quit.
    private var draftFlushers: [UUID: () -> Void] = [:]

    func setDraftFlusher(_ id: UUID, _ flusher: (() -> Void)?) {
        draftFlushers[id] = flusher
    }

    func flushDrafts() {
        for flusher in draftFlushers.values { flusher() }
    }

    /// The system zone changed and no window has an edit in flight: move the
    /// pinned default zone, the runtime's calendar, the store's and the
    /// clock's together, then tell the windows to rebuild (they are idle, so
    /// nothing typed or dragged is lost — review round 2 (c)). With every
    /// window closed it applies at once and the next window builds in it.
    private func applyZoneChangeIfIdle(now: Date) {
        guard zoneChangePending, busyWindowIDs.isEmpty else { return }
        zoneChangePending = false
        NSTimeZone.resetSystemTimeZone()
        let system = NSTimeZone.system
        guard system != calendar.timeZone else { return }
        NSTimeZone.default = system
        let current = Calendar.current
        calendar = current
        store.adoptCalendar(current)
        clock.adoptCalendar(current, now: now)
        roles.dayFrameGeneration += 1
        DiagnosticTrail.record("Calendar", "mac.frame.adopted zone=\(system.identifier)")
    }

    func start() async {
        // Every window's .task calls this; observers register once.
        guard !started else { return }
        started = true
        zoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.zoneChangePending = true
                self.applyZoneChangeIfIdle(now: Date())
            }
        }
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
                for handler in self?.occlusionHandlers.values ?? [:].values {
                    handler(anyVisible)
                }
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

    func flush() async {
        flushDrafts()
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
