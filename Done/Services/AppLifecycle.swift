//
//  AppLifecycle.swift
//  Done
//
//  The process-lifecycle edges the shared store and sync engine listen to,
//  named once for both platforms. On iOS these are exactly the UIApplication
//  notifications the call sites used before; nothing about iOS changes.
//
//  macOS has no background state. An app that loses focus keeps running, so
//  "resign active" is the earliest edge after which the user may stop
//  looking: it stands in for iOS's willResignActive (the light flush).
//  iOS's didEnterBackground carries the heavy work — the F_FULLFSYNC of the
//  storage directory — and on a Mac that would run on every Cmd-Tab, so it
//  maps to "will terminate" instead (review 2026-10-24 #5). "Will become
//  active" stands in for willEnterForeground. Listeners land on idempotent
//  flushes or pulls, so willTerminate arriving under two names is harmless.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated enum AppLifecycle {
    #if canImport(UIKit)
    static let willResignActive = UIApplication.willResignActiveNotification
    static let didEnterBackground = UIApplication.didEnterBackgroundNotification
    static let willTerminate = UIApplication.willTerminateNotification
    static let willEnterForeground = UIApplication.willEnterForegroundNotification
    #else
    static let willResignActive = NSApplication.willResignActiveNotification
    static let didEnterBackground = NSApplication.willTerminateNotification
    static let willTerminate = NSApplication.willTerminateNotification
    static let willEnterForeground = NSApplication.willBecomeActiveNotification
    #endif
}
