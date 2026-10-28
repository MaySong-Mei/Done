//
//  SettingsOrphanCleanupTests.swift
//  DoneTests
//
//  The launch cleanup of the preferences (`SettingsOrphanCleanup`): the keys
//  nothing reads and the old temp siblings of the live plist go; the live
//  plist, a temp file young enough to be a write in progress, every other
//  name, and every key on the do-not-touch list stay; a second run is a
//  no-op that writes no trail line.
//

import XCTest
@testable import Done

@MainActor
final class SettingsOrphanCleanupTests: XCTestCase {

    private let bundleIdentifier = "wordless.shiqiliuyifanmei.app"
    private let uid = "6b6b6b6b-0000-4000-8000-0000000000c1"
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var suite = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suite = "SettingsOrphanCleanupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsOrphanCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        directory = nil
        super.tearDown()
    }

    /// Keys the cleanup must never take: the downgrade net's legacy keys
    /// (`DurableEventStorage`), the account-ownership evidence
    /// (`SyncOwnerGuard.hasSyncedState`), skill insights, the token `.v2`
    /// state, and a key nobody has heard of.
    private var keep: [String: Any] {
        [
            "events": Data("legacy todos".utf8),
            "calendarEvents": Data("legacy calendar".utf8),
            "calendarEventLogRecords": Data("legacy logs".utf8),
            "calendarEventFeedbackRecords": Data("legacy feedback".utf8),
            "agentConversations": Data("legacy chat".utf8),
            "syncHashes.\(uid).calendar_events": Data("{}".utf8),
            "syncHashes.\(uid).agent_preferences": "abc@4",
            "syncHashes.\(uid).cursor": "{\"cursor\":4}",
            "skillInsights": Data("insights".utf8),
            "tokenInferenceDynamicHypotheses.v2": Data("[]".utf8),
            "tokenInferenceMetaHypotheses.v2": Data("[]".utf8),
            "tokenInferenceProjections.v2": Data("[]".utf8),
            "googleCalendarSomethingNew": "not on the list",
        ]
    }

    private func seedKeys() {
        defaults.set("ya29.access", forKey: "googleAccessToken")
        defaults.set("1//refresh", forKey: "googleRefreshToken")
        defaults.set(1_768_000_000.0, forKey: "googleTokenExpiry")
        defaults.set("someone@example.com", forKey: "googleUserEmail")
        defaults.set(Data("[old projections]".utf8), forKey: "tokenInferenceProjections.v1")
        for (key, value) in keep { defaults.set(value, forKey: key) }
    }

    @discardableResult
    private func file(_ name: String, bytes: Int, age: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ name: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)) != nil
    }

    private func trailCount(_ needle: String) -> Int {
        DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
    }

    private func runCleanup() -> SettingsOrphanCleanup.Outcome {
        SettingsOrphanCleanup.run(defaults: defaults, preferencesDirectory: directory,
                                  bundleIdentifier: bundleIdentifier, now: now)
    }

    func testTheOrphanedKeysAndTheOldTempPlistGoAndNothingElse() throws {
        seedKeys()
        let day: TimeInterval = 24 * 3600
        try file("\(bundleIdentifier).plist", bytes: 300, age: 30 * day)
        try file("\(bundleIdentifier).plist.v3luSiL", bytes: 9_900, age: 27 * day)
        try file("\(bundleIdentifier).plist.Ab12Cd", bytes: 1_100, age: day + 60)
        try file("\(bundleIdentifier).plist.fresh01", bytes: 500, age: day - 60)
        try file("\(bundleIdentifier).plist.", bytes: 10, age: 30 * day)
        try file("\(bundleIdentifier).plistX", bytes: 10, age: 30 * day)
        try file("other.app.plist.v3luSiL", bytes: 10, age: 30 * day)
        try file("x.\(bundleIdentifier).plist.v3luSiL", bytes: 10, age: 30 * day)
        let folder = directory.appendingPathComponent("\(bundleIdentifier).plist.folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: folder.path)
        // A link whose own mtime is old, pointing at a file outside.
        let target = try file("target-outside", bytes: 10, age: 30 * day)
        let link = directory.appendingPathComponent("\(bundleIdentifier).plist.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var times = [timeval(tv_sec: Int(now.timeIntervalSince1970) - Int(30 * day), tv_usec: 0),
                     timeval(tv_sec: Int(now.timeIntervalSince1970) - Int(30 * day), tv_usec: 0)]
        XCTAssertEqual(lutimes(link.path, &times), 0, "fixture: the link itself looks old")
        let linesBefore = trailCount("settings: cleanup removed ")
        let line = "settings: cleanup removed keys=googleAccessToken,googleRefreshToken,googleTokenExpiry,googleUserEmail,tokenInferenceProjections.v1 files=2 bytes=11000\n"
        let exactBefore = trailCount(line)

        let outcome = runCleanup()

        XCTAssertEqual(outcome.removedKeys, ["googleAccessToken", "googleRefreshToken", "googleTokenExpiry",
                                             "googleUserEmail", "tokenInferenceProjections.v1"])
        XCTAssertEqual(outcome.removedFiles, 2)
        XCTAssertEqual(outcome.removedBytes, 9_900 + 1_100)
        for key in outcome.removedKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        for (key, value) in keep {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject, "\(key) kept, value and all")
        }
        XCTAssertFalse(exists("\(bundleIdentifier).plist.v3luSiL"))
        XCTAssertFalse(exists("\(bundleIdentifier).plist.Ab12Cd"))
        for name in ["\(bundleIdentifier).plist", "\(bundleIdentifier).plist.fresh01", "\(bundleIdentifier).plist.",
                     "\(bundleIdentifier).plistX", "other.app.plist.v3luSiL", "x.\(bundleIdentifier).plist.v3luSiL",
                     "\(bundleIdentifier).plist.folder", "\(bundleIdentifier).plist.link", "target-outside"] {
            XCTAssertTrue(exists(name), "\(name) kept")
        }
        XCTAssertEqual(trailCount(line), exactBefore + 1, "key names, file count and bytes")
        XCTAssertEqual(trailCount("settings: cleanup removed "), linesBefore + 1)
        XCTAssertFalse(DiagnosticTrail.combinedText().contains("1//refresh"), "names only, never values")
    }

    func testASecondRunIsANoOpThatWritesNoTrailLine() throws {
        seedKeys()
        try file("\(bundleIdentifier).plist.v3luSiL", bytes: 9_900, age: 27 * 24 * 3600)
        let first = runCleanup()
        XCTAssertFalse(first.isEmpty, "fixture: the first run removed something")
        let linesBefore = trailCount("settings: cleanup removed ")
        let snapshot = defaults.dictionaryRepresentation().keys.sorted()

        let second = runCleanup()

        XCTAssertEqual(second, SettingsOrphanCleanup.Outcome())
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.sorted(), snapshot)
        XCTAssertEqual(trailCount("settings: cleanup removed "), linesBefore)
    }

    /// The list is names nothing reads: none of them is a key the app's
    /// own key registries know.
    func testNoOrphanedKeyIsOneTheAppStillKnows() {
        let known = Set(SyncedSettings.allKeys)
        for key in SettingsOrphanCleanup.orphanedKeys {
            XCTAssertFalse(known.contains(key), key)
            XCTAssertFalse(key.hasPrefix(SyncBaselineStore.keyPrefix), key)
            XCTAssertFalse(key.hasSuffix(".v2"), key)
        }
    }

    func testWithoutADirectoryOrABundleIdentifierOnlyKeysAreTouched() throws {
        seedKeys()
        try file("\(bundleIdentifier).plist.v3luSiL", bytes: 9_900, age: 27 * 24 * 3600)
        let outcome = SettingsOrphanCleanup.run(defaults: defaults, preferencesDirectory: directory,
                                                bundleIdentifier: nil, now: now)
        XCTAssertEqual(outcome.removedFiles, 0)
        XCTAssertTrue(exists("\(bundleIdentifier).plist.v3luSiL"))
        XCTAssertEqual(outcome.removedKeys.count, 5)
    }
}
