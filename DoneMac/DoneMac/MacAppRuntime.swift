//
//  MacAppRuntime.swift
//  DoneMac
//
//  Owns the truth-layer object graph and wires flush() to the two exits
//  the OS gives us — terminate and resign-active. A commit inside the
//  persistence drain window must never be lost to a quit (QA round 1,
//  finding 5).
//

import AppKit
import SwiftUI

@MainActor
final class MacAppRuntime {
    let bill = MacWorkBill()
    let persistence: MacPersistence
    let store: MacEventStore
    let clock: ClockHub
    let auth: AuthService
    let sync: MacSyncEngine
    let billLog: BillLog?
    /// ONE calendar snapshot for the whole graph — store, projection and
    /// views must never disagree on day membership (review round-2 #21).
    let calendar: Calendar

    private var resignObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    init() throws {
        let calendar = Calendar.current
        self.calendar = calendar
        persistence = try MacPersistence(location: .production)
        store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: true)
        billLog = try? BillLog(location: .production, calendar: calendar)
        // SupabaseSyncConfig.anonKey is platform-split: on macOS it IS the
        // true anon key (plan hard gate: never join iOS's service_role
        // rotation hazard).
        let auth = AuthService(projectAPIKey: SupabaseSyncConfig.anonKey)
        self.auth = auth
        // Strong capture: the runtime owns auth for the process lifetime;
        // a deallocated auth graph must never read as merely signed-out.
        sync = MacSyncEngine(
            store: store,
            gateway: SupabaseEventsGateway(authService: auth),
            identity: { auth.userId }
        )
    }

    func start() async {
        await store.load()
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
