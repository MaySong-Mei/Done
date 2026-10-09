import XCTest
@testable import Done

//  The instrument for a whole defect family (gh#258 / #260 / #261 / #263).
//
//  Every one of those was found the same way: a review happened to look. The
//  erase works by NAMING things — `AppSettingsKeys.resettableUserDefaultsKeys`
//  for defaults, explicit calls for each owning store — and nothing made the
//  author of a NEW on-disk location come back and add a name. So the list
//  silently fell behind the code, four times, and each gap was a plaintext
//  copy of user data sitting in a directory iOS Device Backup includes.
//
//  This is the census that fails at the moment a location is ADDED rather than
//  whenever someone next audits. It is the `Spike201EmitSiteInventoryTests`
//  idiom: scan production sources, require the found set to equal a declared
//  set, and make every declaration carry a DISPOSITION — so a new path cannot
//  be waved through, only classified.
//
//  Adding a path? You will see this test go red. Decide which disposition it
//  has and say why. "I'll deal with it later" is `.knownGap`, which needs an
//  issue number — that is the whole point: the gap becomes visible instead of
//  invisible.

final class EraseCompletenessTripwireTests: XCTestCase {

    /// Why a given on-disk name does not need a line in the erase path — or
    /// does, and has one.
    enum Disposition {
        /// Named on the erase path. The string is where.
        case sweptByErase(String)
        /// Holds no user data. The string is the argument, which a reader is
        /// free to disagree with — that is better than guessing at it.
        case notUserData(String)
        /// Only written behind `#if DEBUG`, so no release build creates it.
        case debugOnly(String)
        /// A per-row file or temp name INSIDE a directory declared above;
        /// the directory's disposition governs it. The string is the parent.
        case insideDeclaredDirectory(String)
        /// Known to survive the erase, deliberately not fixed here. Needs an
        /// issue, and the issue must say what was and was not verified.
        case knownGap(issue: String)
    }

    /// `#filePath` is this file's location at COMPILE time, so two
    /// directories up is the checkout the test binary was built from.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    /// Production targets only. `DoneTests/` is excluded on purpose: a test
    /// fixture's scratch directory is not a place user data can be stranded.
    private let productionDirectories = ["Done", "Shared", "DoneWidget"]

    /// Every distinct literal passed to `appendingPathComponent(` in
    /// production, and what it is.
    ///
    /// Deliberately keyed on the LITERAL, not on a store name: the whole
    /// failure mode was a store nobody thought about, and a literal is what
    /// the compiler forces an author to write.
    private let inventory: [String: Disposition] = [
        // ── Erased, each by its own owner being told ──
        "AgenticIntakeAssets": .sweptByErase(
            "AgenticIntakeAssetStore().removeAllAssets() in resetAllLocalData (gh#260)"),
        "PersonAvatars": .sweptByErase(
            "PersonAvatarStore.removeAll() in resetAllLocalData (gh#263)"),
        "Reports": .sweptByErase(
            "ReportStore().wipe() in resetAllLocalData (gh#261)"),
        "DeveloperStats": .sweptByErase(
            "LLMUsageStore.shared.clearAll() in resetAllLocalData (gh#263)"),
        "llm-usage.json": .insideDeclaredDirectory("DeveloperStats"),
        "me-avatar.jpg": .sweptByErase("MeAvatarStore.delete() in resetAllLocalData"),
        "EventTypeCatalogs": .sweptByErase(
            "agentRuntime.eventTypeTemplateStore.resetToDefaults() in resetAllLocalData"),
        "OccurrenceKeyMetadata": .sweptByErase(
            "OccurrenceKeyMetadataStore.shared.wipe() in resetAllLocalData"),
        "AgentRuntime": .sweptByErase(
            "preferenceStore.clearRules() + clearDecisionHistory() in resetAllLocalData"),
        "preference_rules.json": .insideDeclaredDirectory("AgentRuntime"),
        "decision_records.json": .insideDeclaredDirectory("AgentRuntime"),
        "quarantine": .sweptByErase(
            "DurableEventStorage.purgeAuxiliaryCopies, per slot, during the wipe"),
        "snapshots": .sweptByErase(
            "DurableEventStorage.purgeAuxiliaryCopies, per slot, during the wipe"),
        "Diagnostics": .sweptByErase(
            "DiagnosticTrail.clear() from EventStore.clearAllLocalData — note it "
            + "removes the trail FILES (live, rotated, export), not the whole "
            + "directory, which is why MetricKit below is declared separately"),
        "trail.log": .insideDeclaredDirectory("Diagnostics"),
        "trail.1.log": .insideDeclaredDirectory("Diagnostics"),
        "done-diagnostic-trail.txt": .sweptByErase(
            "DiagnosticTrail.clear() removes the share-ready export copy too"),

        // ── Not user data ──
        "MetricKit": .notUserData(
            "MetricKit diagnostic payloads — hang durations, CPU and disk-write "
            + "counters, exception stacks. Telemetry ABOUT the app's behaviour, "
            + "carrying no event titles, notes, people or images. Nested under "
            + "Diagnostics/ but NOT removed by DiagnosticTrail.clear(), so this "
            + "is a real survival and the argument for it is content, not reach. "
            + "Disagree and it becomes a gap: there is no technical obstacle to "
            + "purging it."),

        // ── DEBUG only ──
        "agent_decision_debug.log": .debugOnly(
            "written only through the #if DEBUG wrapper agentDecisionDebugLog; "
            + "carries event ids and type strings, so it WOULD be user data if a "
            + "release build ever produced it"),
        "calendar-debug.log": .debugOnly(
            "DEBUG-gated, and in Caches/, which iOS does not back up"),

        // ── Known gap, deliberately not fixed in this change ──
        "pending": .knownGap(issue: "gh#264"),
    ]

    /// Interpolated names — `"\(id.uuidString).json"` and friends. They are
    /// not fixed strings, so they cannot be declared by value; each is a
    /// per-row or temp file inside a directory the inventory already covers.
    /// Matched by shape so a NEW interpolated name in a NEW directory still
    /// has to be classified.
    private let interpolatedPrefixesInsideDeclaredDirectories = [
        "spike-runs-", "\\(spikeID)", "\\(id.uuidString)", "\\(base)",
        "\\(imported.id.uuidString)", "\\(slot.rawValue)", "\\(temporaryPrefix)",
        ".tmp-",
    ]

    // MARK: - The census

    func testEveryOnDiskLocationIsClassifiedAgainstTheErase() throws {
        var found = Set<String>()
        for dir in productionDirectories {
            let root = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
                for literal in Self.pathComponentLiterals(in: text) {
                    found.insert(literal)
                }
            }
        }
        XCTAssertFalse(found.isEmpty,
                       "liveness: the scan must find SOMETHING — an empty found set "
                       + "would make every assertion below pass for free")

        let interpolated = found.filter { $0.contains("\\(") || $0.hasPrefix("spike-runs-") }
        let fixed = found.subtracting(interpolated)

        // Fixed names: exact census.
        let declared = Set(inventory.keys)
        let undeclared = fixed.subtracting(declared)
        XCTAssertTrue(
            undeclared.isEmpty,
            "NEW on-disk location(s) with no disposition: \(undeclared.sorted()).\n"
            + "The erase works by NAMING things, and nothing else makes an author "
            + "come back and add a name — that is how gh#258 / #260 / #261 / #263 "
            + "each shipped a plaintext copy of user data into a backed-up "
            + "directory. Add an entry to `inventory` and pick a disposition: "
            + "sweptByErase (say where), notUserData (say why), debugOnly, "
            + "insideDeclaredDirectory, or knownGap (with an issue)."
        )
        let stale = declared.subtracting(fixed)
        XCTAssertTrue(
            stale.isEmpty,
            "declared but no longer in the code: \(stale.sorted()) — remove the "
            + "entries so the inventory cannot drift into fiction"
        )

        // Interpolated names: every one must sit inside a declared directory.
        for name in interpolated {
            XCTAssertTrue(
                interpolatedPrefixesInsideDeclaredDirectories.contains(where: { name.contains($0) }),
                "interpolated path \(name) matches no known per-row/temp shape — "
                + "classify it, or declare the directory it lives in"
            )
        }
    }

    /// The inventory is only worth anything if `knownGap` is rare and loud.
    /// This fails when one is added, so the number in it has to be bumped
    /// deliberately — the same tripwire shape the spike emit-site census uses.
    func testTheKnownGapCountIsDeliberate() {
        let gaps = inventory.compactMap { key, value -> String? in
            if case .knownGap(let issue) = value { return "\(key) → \(issue)" }
            return nil
        }
        XCTAssertEqual(
            gaps.sorted(), ["pending → gh#264"],
            "every known gap is a plaintext copy of user data surviving an erase. "
            + "Adding one is a decision, not a detail — change this assertion in "
            + "the same commit and say why in the message."
        )
    }

    /// The inventory CLAIMS "swept by X". Nothing above checks X is still
    /// there — delete the call from the view and the census stays green,
    /// because the declaration is a claim about the code, not a reading of
    /// it. So: read the erase body and require every call the inventory
    /// names.
    ///
    /// `resetAllLocalData` is in a SwiftUI view, so this target cannot drive
    /// it; a source guard is the only instrument available. gh#234's probe
    /// shipped with exactly this hole, and the gh#258 branch shipped it a
    /// second time (its guard read the consumer file and missed the producer).
    func testTheEraseStillContainsEveryCallTheInventoryClaims() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Done/Views/Agent/AgentSettingsView.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private func resetAllLocalData() {"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return XCTFail("resetAllLocalData has been renamed — re-point this guard") }
        let body = String(source[start.upperBound..<end.lowerBound])

        // Liveness: a body that failed to extract would satisfy nothing below
        // by being empty, so prove it is the real one first.
        XCTAssertTrue(body.contains("store.clearAllLocalData()"),
                      "liveness: the extracted body must be the real erase")

        for call in [
            "AgenticIntakeAssetStore().removeAllAssets()",   // gh#260
            "PersonAvatarStore.removeAll()",                 // gh#263
            "ReportStore().wipe()",                          // gh#261
            "LLMUsageStore.shared.clearAll()",               // gh#263
            "SpikeRunStore.wipe()",                          // gh#263
            "backupSnapshotService.wipe()",                  // gh#258
            "MeAvatarStore.delete()",
            "OccurrenceKeyMetadataStore.shared.wipe()",
        ] {
            XCTAssertTrue(
                body.contains(call),
                "the erase must still call \(call) — the inventory declares the "
                + "location it covers as sweptByErase, and without the call that "
                + "declaration is fiction"
            )
        }
    }

    /// Positive control for the census: the scanner must actually find the
    /// paths this change added. Without this, a regex that matched nothing
    /// would make `undeclared.isEmpty` pass forever.
    func testTheScannerSeesThePathsThisChangeHadToClassify() throws {
        let store = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Done/Services/Agent/AgenticIntakeAssetStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(Self.pathComponentLiterals(in: store).contains("AgenticIntakeAssets"),
                      "the scanner must see the directory gh#260 was about")
    }

    // MARK: - Scanner

    /// Literal first arguments to `appendingPathComponent(`. Keyed on the
    /// literal because that is what an author is forced to type.
    nonisolated static func pathComponentLiterals(in source: String) -> Set<String> {
        var out = Set<String>()
        let needle = "appendingPathComponent(\""
        var idx = source.startIndex
        while let hit = source.range(of: needle, range: idx..<source.endIndex) {
            if let close = source.range(of: "\"", range: hit.upperBound..<source.endIndex) {
                out.insert(String(source[hit.upperBound..<close.lowerBound]))
                idx = close.upperBound
            } else {
                break
            }
        }
        return out
    }
}
