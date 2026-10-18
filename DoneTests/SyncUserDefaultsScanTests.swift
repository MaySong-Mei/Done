//
//  SyncUserDefaultsScanTests.swift
//  DoneTests
//
//  The sync path reads the `UserDefaults` it was handed, never `.standard`
//  (survey M6(4)): two virtual devices in one test process each get their
//  own suite, and settings convergence means something only if no read
//  slips past the injection. A grep, read as code with comments removed
//  (`EraseWiringScan.strippingComments`), over every file of the sync path;
//  the sites allowed to name `.standard` are listed here by their exact
//  line, each must still be present exactly once, and anything else fails.
//
//  It also pins that the outbound debounce runs on the injected scheduler.
//

import XCTest
@testable import Done

/// Reading the sync path's sources from the checkout the tests were built from.
enum SyncSourceScan {
    static var repoRoot: URL { EraseWiringScan.repoRoot }

    /// Files read whole: every Swift file under `Done/Services/Sync/` (listed
    /// from disk, so a new file is covered without touching this), the
    /// service and its restore half, and the synced-settings model.
    static func syncPathFiles() throws -> [String] {
        let dir = repoRoot.appendingPathComponent("Done/Services/Sync")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return names.map { "Done/Services/Sync/\($0)" } + [
            "Done/Services/SupabaseSyncService.swift",
            "Done/Services/SupabaseSyncService+Restore.swift",
            "Done/Models/SyncedSettings.swift",
        ]
    }

    /// Function bodies read on their own: the bridged owners
    /// `SyncedSettings` routes its `defaults` through. The rest of those
    /// files is not the sync path.
    static let routedFunctions: [(signature: String, file: String)] = [
        ("static func forDefaults(_ defaults: UserDefaults) -> EventTypeCatalog {", "Done/Models/EventTypeTemplateStore.swift"),
        ("static func forDefaults(_ defaults: UserDefaults) -> OccurrenceKeyMetadataStore {", "Done/Services/Storage/OccurrenceKeyMetadataStore.swift"),
    ]

    static func code(of relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        return EraseWiringScan.strippingComments(source)
    }

    /// Code lines (trimmed) that name a `.standard` member, whatever comes
    /// before the dot: `UserDefaults.standard`, and every implicit-member
    /// spelling (`= .standard`, `return .standard`, `?? .standard`,
    /// `{ .standard }`, …). Matching the token rather than guessing which
    /// contexts expect a `UserDefaults` means a new spelling cannot slip
    /// past; a `.standard` of some other type would show up here too and
    /// has to be listed in `allowed` with that reason.
    static func standardSites(in code: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\.\s*standard\b"#)
        return code.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let text = String(line)
            guard pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }
}

@MainActor
final class SyncUserDefaultsScanTests: XCTestCase {

    /// Every site on the sync path allowed to name `.standard`, by file and
    /// exact trimmed line. Each is the production default of an injectable
    /// parameter, or the routing that sends `.standard` to the app's shared
    /// owner; none is a read that bypasses an injected suite.
    private static let allowed: [String: [String]] = [
        "Done/Services/SupabaseSyncService.swift": [
            "defaults: UserDefaults = .standard,",
            "static func wipeAllPersistedHashes(_ defaults: UserDefaults = .standard) {",
            "static func settingsExportSuppressed(_ defaults: UserDefaults = .standard) -> Bool {",
        ],
        "Done/Models/SyncedSettings.swift": [
            "static func currentSnapshot(_ defaults: UserDefaults = .standard) -> [String: Any] {",
            "static func hasUnreadableBridgedOwner(_ defaults: UserDefaults = .standard) -> Bool {",
            "to defaults: UserDefaults = .standard",
            "static func replace(with blob: [String: Any], to defaults: UserDefaults = .standard) {",
        ],
        "Done/Models/EventTypeTemplateStore.swift#forDefaults": [
            "if defaults === UserDefaults.standard { return shared }",
        ],
        "Done/Services/Storage/OccurrenceKeyMetadataStore.swift#forDefaults": [
            "if defaults === UserDefaults.standard { return shared }",
        ],
    ]

    private func scannedSites() throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for file in try SyncSourceScan.syncPathFiles() {
            out[file] = SyncSourceScan.standardSites(in: try SyncSourceScan.code(of: file))
        }
        for routed in SyncSourceScan.routedFunctions {
            let body = try EraseWiringScan.functionBody(of: routed.signature, inFileAt: routed.file)
            out["\(routed.file)#forDefaults"] = SyncSourceScan.standardSites(in: body)
        }
        return out
    }

    func testNoUnlistedStandardDefaultsOnTheSyncPath() throws {
        let scanned = try scannedSites()
        for (file, sites) in scanned {
            var remaining = Self.allowed[file] ?? []
            for site in sites {
                if let index = remaining.firstIndex(of: site) {
                    remaining.remove(at: index)
                } else {
                    XCTFail("\(file): `\(site)` names UserDefaults.standard on the sync path — read the injected `defaults` instead, or, if this is a production default of an injectable parameter, list it in SyncUserDefaultsScanTests.allowed")
                }
            }
        }
    }

    /// The list cannot go stale: every allowed site is still there, once.
    func testEveryAllowedSiteStillExistsExactlyOnce() throws {
        let scanned = try scannedSites()
        for (file, lines) in Self.allowed {
            let sites = try XCTUnwrap(scanned[file], "\(file) is no longer scanned")
            for line in lines {
                XCTAssertEqual(sites.filter { $0 == line }.count, 1, "\(file): allowed site `\(line)` is gone or duplicated — update the list")
            }
        }
    }

    /// Positive control for the matcher itself.
    func testMatcherCatchesEachSpellingAndIgnoresComments() {
        let source = """
        let a = UserDefaults.standard.bool(forKey: "k")
        func f(_ d: UserDefaults = .standard) {}
        SyncBaselineStore(defaults: .standard, userId: "")
        guard let injected else { return .standard }
        let c = injected ?? .standard
        let pick: () -> UserDefaults = { .standard }
        let d = UserDefaults
            .standard
        // UserDefaults.standard in a comment
        let b = defaults.bool(forKey: "k")
        let standardized = b
        """
        let sites = SyncSourceScan.standardSites(in: EraseWiringScan.strippingComments(source))
        XCTAssertEqual(sites, [
            "let a = UserDefaults.standard.bool(forKey: \"k\")",
            "func f(_ d: UserDefaults = .standard) {}",
            "SyncBaselineStore(defaults: .standard, userId: \"\")",
            "guard let injected else { return .standard }",
            "let c = injected ?? .standard",
            "let pick: () -> UserDefaults = { .standard }",
            ".standard",
        ])
    }

    func testTheRoutedFunctionsAreFound() throws {
        for routed in SyncSourceScan.routedFunctions {
            XCTAssertNoThrow(try EraseWiringScan.functionBody(of: routed.signature, inFileAt: routed.file))
        }
    }

    /// The outbound debounce: every sink runs on the injected scheduler,
    /// none on a hard-wired run loop.
    func testOutboundDebounceRunsOnTheInjectedScheduler() throws {
        let code = try SyncSourceScan.code(of: "Done/Services/SupabaseSyncService.swift")
        XCTAssertFalse(code.contains(".debounce("), "a Combine debounce runs on a real clock; use syncDebounceSink(for:on: scheduler)")
        XCTAssertFalse(code.contains("RunLoop.main"))
        XCTAssertTrue(code.contains(".syncDebounceSink(for: debounce, on: scheduler)"))
        XCTAssertTrue(code.contains(".syncDebounceSink(for: SupabaseSyncConfig.settingsDebounceSeconds, on: scheduler)"))
    }

    /// The flush gate's upload toggle is read from the injected suite.
    func testCanUploadReadsTheInjectedDefaults() throws {
        let suite = "SyncUserDefaultsScanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: "u"), userId: "u", defaults: defaults)
        XCTAssertTrue(service.defaults === defaults)
        // DEBUG builds block uploads outright, so the toggle is only
        // observable in a release build; the scan above pins the read.
        if !SupabaseSyncService.debugBlocksUploads {
            defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
            XCTAssertTrue(service.canUpload)
            defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
            XCTAssertFalse(service.canUpload)
        }
    }

    /// The erase's hash wipe sweeps the suite it is handed.
    func testWipeAllPersistedHashesSweepsTheGivenSuite() throws {
        let suite = "SyncUserDefaultsScanTests-wipe-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("x", forKey: "syncHashes.someone.events")
        defaults.set("keep", forKey: "unrelated")

        SupabaseSyncService.wipeAllPersistedHashes(defaults)

        XCTAssertNil(defaults.object(forKey: "syncHashes.someone.events"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }
}
