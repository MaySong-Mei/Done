//
//  DoneMacApp.swift
//  DoneMac
//
//  macOS companion app. Phase 2: truth layer wired with flush-on-exit.
//

import SwiftUI

@main
struct DoneMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    private let runtime: MacAppRuntime? = MacAppRuntime()

    var body: some Scene {
        WindowGroup {
            RootView(runtime: runtime)
                .task {
                    guard let runtime else { return }
                    appDelegate.runtime = runtime
                    await runtime.start()
                }
        }
    }
}
