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
    let billLog: BillLog?
    /// ONE calendar snapshot for the whole graph — store, projection and
    /// views must never disagree on day membership (review round-2 #21).
    let calendar: Calendar

    private var resignObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    init() {
        // Before anything reads a setting: the sync master switch defaults
        // ON (design D9) — the same first line as the iOS app's init.
        AppSettingsKeys.registerLaunchDefaults()
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
        auth = AuthService()
        agentRuntime = AgentRuntime()
        skillStore = SkillInsightStore()
        sync = SupabaseSyncService(ownerRecord: .production)
        sync.statusReporter = syncStatus
        sync.attach(
            authService: auth,
            eventStore: shared,
            eventTypeStore: agentRuntime.eventTypeTemplateStore,
            skillStore: skillStore,
            preferenceStore: agentRuntime.preferenceStore
        )
    }

    func start() async {
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
