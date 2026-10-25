//
//  AppLifecycle.swift
//  Done
//
//  The process-lifecycle edges the shared store and sync engine listen to,
//  named once for both platforms. On iOS these are exactly the UIApplication
//  notifications the call sites used before; nothing about iOS changes.
//
//  macOS has no background state. An app that loses focus keeps running and
//  may be quit at any moment, so "resign active" is the earliest edge after
//  which the user may stop looking — it stands in for both iOS's
//  willResignActive and didEnterBackground, and "will become active" stands
//  in for willEnterForeground. Every listener lands on an idempotent flush
//  or pull, so the two mapped edges firing back to back is harmless.
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
    static let didEnterBackground = NSApplication.didResignActiveNotification
    static let willTerminate = NSApplication.willTerminateNotification
    static let willEnterForeground = NSApplication.willBecomeActiveNotification
    #endif
}
