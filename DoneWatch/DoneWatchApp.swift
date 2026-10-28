//
//  DoneWatchApp.swift
//  DoneWatch
//
//  The day on the wrist: draw a block to log or start one, see the running
//  session, finish or extend it. The phone owns every event; this app only renders the last
//  `WristSnapshot` it was pushed and sends `WristCommand`s back — see
//  Shared/WristProtocol.swift.
//

import SwiftUI

@main
struct DoneWatchApp: App {
    @StateObject private var client = WristSessionClient()

    var body: some Scene {
        WindowGroup {
            WristRootView()
                .environmentObject(client)
        }
    }
}
