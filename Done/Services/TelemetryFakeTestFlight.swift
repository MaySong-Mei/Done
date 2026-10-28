//
//  TelemetryFakeTestFlight.swift
//  Done
//
//  gh#273 §16 QA seam: a launch variable that stands in for StoreKit's
//  answer, so a simulator run can play a TestFlight install (`1`) or an App
//  Store one (`0`) end to end: the default switching on, then a definite
//  App Store answer taking it back. DEBUG only, like `SyncOfflineSwitch`:
//  the type does not exist in other builds, so a release build has nothing
//  that could read the variable (`TelemetryFakeTestFlightTests` scans for
//  that). DoneApp hands the value to `TelemetryUploader.live(isTestFlight:)`.
//

#if DEBUG
import Foundation

nonisolated enum TelemetryFakeTestFlight {
    static let launchVariable = "TELEMETRY_FAKE_TESTFLIGHT"

    /// `1` → TestFlight, `0` → App Store; unset or anything else → nil, and
    /// the real answer is asked.
    static func value(in environment: [String: String]) -> Bool? {
        switch environment[launchVariable] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    static var launchValue: Bool? { value(in: ProcessInfo.processInfo.environment) }
}
#endif
