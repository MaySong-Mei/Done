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

    private var resignObserver: NSObjectProtocol?

    init() throws {
        let calendar = Calendar.current
        persistence = try MacPersistence(location: .production)
        store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: true)
    }

    func start() async {
        await store.load()
        let store = self.store
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await store.flush() }
        }
    }

    func flush() async {
        await store.flush()
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
