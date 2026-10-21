//
//  SyncOfflineSwitch.swift
//  Done
//
//  The harness's "offline" switch, one of the DEBUG seams design §8.4 asks
//  for: two simulators share the host's network stack, so a single device
//  cannot be taken offline from outside. Instead, a launch variable names a
//  file, and while that file exists every REST request and every doorbell
//  connection throws `URLError(.notConnectedToInternet)` before anything
//  goes out. The harness toggles the device with `touch` / `rm` inside the
//  simulator's container; the file is checked on every request, so no
//  relaunch is needed. DEBUG only: the type does not exist in other builds.
//

#if DEBUG
import Foundation

nonisolated enum SyncOfflineSwitch {
    static let launchVariable = "SYNC_OFFLINE_FILE"

    /// The path named at launch, nil when the seam is not armed. A `var`
    /// only so a test can arm it for the duration of one test.
    nonisolated(unsafe) static var filePath: String? = ProcessInfo.processInfo.environment[launchVariable]

    /// Throws `URLError(.notConnectedToInternet)` while the armed file
    /// exists. Returns at once when the seam is not armed.
    static func checkOnline() throws {
        guard let filePath, FileManager.default.fileExists(atPath: filePath) else { return }
        throw URLError(.notConnectedToInternet)
    }
}
#endif
