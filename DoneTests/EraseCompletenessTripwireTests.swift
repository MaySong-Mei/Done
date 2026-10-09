import XCTest
@testable import Done

//  The instrument for a whole defect family: gh#256, gh#258, gh#260, gh#261,
//  gh#263 — five in a row, each a copy of user data surviving "erase all local
//  data", most of them in a directory iOS Device Backup includes. Every one was
//  found by a review happening to look.
//
//  The erase works by NAMING things, and nothing made the author of a new
//  store come back and add a name.
//
//  TWO censuses, because there are two storage media and the family hit both:
//
//    1. FILES — every production source that can write to disk must carry a
//       disposition. The unit is the WRITER, not the path: all five defects
//       were "the erase did not know this store existed".
//    2. DEFAULTS — every `AppSettingsKeys` key must be in the resettable
//       sweep or be classified. This is the census that would have caught
//       gh#258's worst finding (`mcpURL`, a live third-party read credential)
//       directly, rather than via a snapshot that happened to carry it.
//
//  ## What these DO NOT cover — read this before trusting them
//
//  A first version of this file scanned `appendingPathComponent("literal")`.
//  It was false comfort and a review said so: the dominant idiom here is a
//  NAMED CONSTANT, so the instrument built to prevent gh#258 could not see
//  gh#258's own `backup-snapshot.json`. Hence the writer-level unit below.
//
//  The writer census still has a real limit, stated rather than papered over:
//  it fires when a FILE becomes write-capable, not when an already-declared
//  file adds a new path. `DurableEventStorage` growing a new subdirectory
//  will not redden anything. That is the residual hole; it is narrower than
//  the one it replaced, and naming it here is the point.

final class EraseCompletenessTripwireTests: XCTestCase {

    // MARK: - Dispositions

    enum WriterDisposition {
        /// Named on the erase path. The string says where.
        case sweptByErase(String)
        /// Writes nothing user-attributable. The string is the argument, so a
        /// reader can disagree with it instead of guessing at it.
        case notUserData(String)
        /// Writes only behind `#if DEBUG`.
        case debugOnly(String)
        /// Its writes land in another declared writer's storage; that
        /// writer's disposition governs. The string names it.
        case ownedBy(String)
        /// Survives the erase, deliberately not fixed. Needs an issue.
        case knownGap(issue: String)
    }

    enum KeyDisposition {
        /// In `resettableUserDefaultsKeys`, so the sweep removes it.
        case inResettableSweep
        /// Removed by a named call rather than the list.
        case removedExplicitly(String)
        /// Not user state. The string is the argument.
        case notUserState(String)
        /// A default VALUE, not a key — nothing is ever stored under it.
        case notAKey
        /// Survives and should not. Needs an issue.
        case knownGap(issue: String)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    private let productionDirectories = ["Done", "Shared", "DoneWidget"]

    // MARK: - Census 1: writers

    private let writers: [String: WriterDisposition] = [
        "Done/Services/Agent/AgenticIntakeAssetStore.swift": .sweptByErase(
            "AgenticIntakeAssetStore().removeAllAssets() (gh#260)"),
        "Done/Views/Calendar/EventPeoplePickerView.swift": .sweptByErase(
            "PersonAvatarStore.removeAll() (gh#263)"),
        "Done/Services/Report/ReportStore.swift": .sweptByErase(
            "ReportStore().wipe() (gh#261)"),
        "Done/Services/SpikeRunStore.swift": .sweptByErase(
            "SpikeRunStore.wipe() (gh#263)"),
        "Done/Services/BackupSnapshotService.swift": .sweptByErase(
            "backupSnapshotService.wipe() (gh#258). The writer the FIRST version "
            + "of this census could not see, which is why the unit is the file."),
        "Done/Services/Agent/LLMUsageStore.swift": .sweptByErase(
            "LLMUsageStore.shared.clearAll() (gh#263) — note it rewrites the "
            + "file EMPTY rather than removing it, so the file survives with no "
            + "contents; QA pinned that in testLLMUsageClearAllLeavesNo"
            + "ModelActivityOnDiskButKeepsTheFile"),
        "Done/Models/EventTypeTemplateStore.swift": .sweptByErase(
            "agentRuntime.eventTypeTemplateStore.resetToDefaults(), plus the two "
            + "legacy key removals that are only allowed here"),
        "Done/Services/DiagnosticTrail.swift": .sweptByErase(
            "DiagnosticTrail.clear() from EventStore.clearAllLocalData — removes "
            + "the live, rotated and share-ready export FILES. Not the directory: "
            + "Application Support/Diagnostics survives, and MetricPayloadStore "
            + "writes into it as well (see its own entry)"),
        "Done/Services/Storage/DurableEventStorage.swift": .sweptByErase(
            "the per-slot empty-envelope commit plus purgeAuxiliaryCopies "
            + "(backup, quarantine, snapshots) and clearAllPendingWork(kind:) at "
            + "EventStore.swift:1965 — which an earlier version of this file "
            + "wrongly declared a knownGap, see the gh#264 note below"),
        "Done/Services/Storage/CalendarDeltaLog.swift": .ownedBy(
            "DurableEventStorage — purgeAuxiliaryCopies calls clearCalendarLog, "
            + "and the log holds event plaintext, so this is load-bearing (gh#235)"),
        "Done/Services/Storage/AtomicValueFile.swift": .ownedBy(
            "DurableEventStorage — the slot write primitive; conversations use it "
            + "and are erased via AgentConversationRepository.wipe()"),
        "Done/Services/Agent/ConversationDeltaLog.swift": .ownedBy(
            "AgentConversationRepository.wipe(), which clears the log as well as "
            + "the checkpoint"),
        "Done/Services/ImageBackupCoordinator.swift": .ownedBy(
            "AgenticIntakeAssetStore — restored downloads land in the same "
            + "AgenticIntakeAssets layout, so removeAllAssets() takes them"),
        "Done/Views/Analysis/AnalysisView.swift": .sweptByErase(
            "MeAvatarStore.delete() — this file holds MeAvatarStore, whose "
            + "me-avatar.jpg is the user's own photo"),
        "Done/Services/Agent/AgenticIntakeAssetGarbageCollector.swift": .notUserData(
            "only ever REMOVES files; it creates nothing, so it cannot strand "
            + "anything"),
        "Done/Services/Storage/EventStorageLocation.swift": .notUserData(
            "resolves and creates directories; the rows are written by "
            + "DurableEventStorage through it"),
        "Done/Services/Storage/MetricPayloadStore.swift": .notUserData(
            "MXMetricPayload / MXDiagnosticPayload jsonRepresentation() only — "
            + "hang durations, CPU and disk-write counters, exception stacks. "
            + "Telemetry about the app, carrying no titles, notes, people or "
            + "images. Survives the erase in BOTH its directories (Application "
            + "Support/Diagnostics/MetricKit and the legacy Documents/Diagnostics), "
            + "so this argument is about CONTENT, not reach — disagree and it "
            + "becomes a gap, with no technical obstacle to purging it"),
        "Done/Services/Agent/AgentService.swift": .debugOnly(
            "agent_decision_debug.log and its .old.log sibling, both written only "
            + "through the #if DEBUG wrapper agentDecisionDebugLog. WOULD be user "
            + "data (event ids, type strings) if a release build produced it"),
        "Done/Views/Calendar/Components/Timeline/TimelineView.swift": .debugOnly(
            "calendar-debug.log, DEBUG-gated and in Caches/, which iOS does not "
            + "back up"),
    ]

    func testEveryWriterIsClassifiedAgainstTheErase() throws {
        var found = Set<String>()
        for dir in productionDirectories {
            let root = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                let path = dir + "/" + rel
                let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
                if Self.canWriteToDisk(text) { found.insert(path) }
            }
        }
        XCTAssertFalse(found.isEmpty, "liveness: a scan finding nothing would pass everything below for free")
        XCTAssertTrue(found.contains("Done/Services/BackupSnapshotService.swift"),
                      "liveness: the writer the first version of this census MISSED must be visible to this one")

        let declared = Set(writers.keys)
        XCTAssertTrue(
            found.subtracting(declared).isEmpty,
            "NEW writer(s) with no disposition: \(found.subtracting(declared).sorted()).\n"
            + "A file that can write to disk is how gh#256 / #258 / #260 / #261 / "
            + "#263 each stranded user data. Add an entry and pick a disposition: "
            + "sweptByErase (say where), notUserData (say why), debugOnly, "
            + "ownedBy, or knownGap (with an issue)."
        )
        XCTAssertTrue(
            declared.subtracting(found).isEmpty,
            "declared but no longer write-capable: \(declared.subtracting(found).sorted()) "
            + "— remove the entries so the inventory cannot drift into fiction"
        )
    }

    // MARK: - Census 2: UserDefaults keys

    private let keyExceptions: [String: KeyDisposition] = [
        "syncUploadsEnabled": .removedExplicitly(
            "set to false at the TOP of resetAllLocalData, deliberately before the "
            + "wipes, so the debounced sinks cannot push an emptied state to cloud"),
        "agentProviderDefault": .notAKey,
        "meBackgroundTypesDefault": .notAKey,
        "calendarUseCALayerAxisMarkers": .notUserState("render feature flag"),
        "tokenInferenceLLMEnabled": .notUserState("feature flag (gh#182)"),
        "calendarHeaderExposedTools": .knownGap(issue: "gh#265"),
        "detailHeaderExposedTools": .knownGap(issue: "gh#265"),
        "calendarLastRangeMode": .knownGap(issue: "gh#265"),
        "calendarRememberViewMode": .knownGap(issue: "gh#265"),
        "calendarAutoReturnToToday": .knownGap(issue: "gh#265"),
        "holidaysShowSolarTerms": .knownGap(issue: "gh#265"),
        "holidaysShowGregorianHolidays": .knownGap(issue: "gh#265"),
        "calendarShareStyle": .knownGap(issue: "gh#265"),
    ]

    func testEveryDefaultsKeyIsSweptOrClassified() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/ContentView.swift"),
            encoding: .utf8)
        let (declaredKeys, resettable) = try Self.appSettingsKeys(in: source)

        XCTAssertGreaterThan(declaredKeys.count, 30, "liveness: the key scan must find the real set")
        XCTAssertTrue(resettable.contains("agentAPIKey"),
                      "liveness: the resettable-list scan must find a known member")
        // The census that would have caught gh#258's worst finding on its own.
        XCTAssertTrue(resettable.contains("mcpURL"),
                      "mcpURL is a live third-party read credential — it must be swept")
        XCTAssertTrue(resettable.contains("customAnniversaries"),
                      "customAnniversaries is user-authored content")

        let unaccounted = declaredKeys
            .subtracting(resettable)
            .subtracting(keyExceptions.keys)
        XCTAssertTrue(
            unaccounted.isEmpty,
            "AppSettingsKeys with no erase story: \(unaccounted.sorted()).\n"
            + "gh#258's worst finding was exactly this — mcpURL, a token granting "
            + "external read access to the account, sitting outside the sweep. "
            + "Either add it to resettableUserDefaultsKeys or give it a "
            + "KeyDisposition here."
        )
    }

    // MARK: - The claims the inventories make

    /// Both censuses let a declaration CLAIM "swept by X". Nothing above reads
    /// X. So: read the erase body and require every call the writer inventory
    /// names, derived FROM the inventory rather than from a second hand-written
    /// list — an earlier version kept them separate, which let a declaration
    /// name a call the guard never checked.
    ///
    /// Comments are stripped first. The earlier version matched raw text, so a
    /// commented-out call satisfied it — and its own liveness assertion was
    /// satisfied by a backticked mention of that call inside a comment.
    func testTheEraseStillContainsEveryCallTheInventoryNames() throws {
        // The erase is TWO functions, and the first version of this guard read
        // only the view's — which made it fail on `DiagnosticTrail.clear()`,
        // a call that is really there, in the other half. The guard being
        // wrong about a true claim is still the guard working: it is the
        // claim-to-code link that is being checked, and the link was broken.
        let viewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Views/Agent/AgentSettingsView.swift"),
            encoding: .utf8)
        let storeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Done/Models/EventStore.swift"),
            encoding: .utf8)
        let viewBody = try Self.eraseBody(in: viewSource, named: "private func resetAllLocalData() {")
        let storeBody = try Self.eraseBody(in: storeSource, named: "func clearAllLocalData() {")
        let body = viewBody + "\n" + storeBody

        XCTAssertTrue(body.contains("store.clearAllLocalData()"),
                      "liveness: the view half must be the real erase, in code")
        XCTAssertTrue(body.contains("MeAvatarStore.delete()"),
                      "liveness: and must reach the TAIL of it, not stop early")
        XCTAssertTrue(body.contains("DiagnosticTrail.clear()"),
                      "liveness: the store half must be present too — this is the "
                      + "assertion whose absence exposed the single-function bug")

        for (file, disposition) in writers {
            guard case .sweptByErase(let claim) = disposition else { continue }
            guard let call = Self.callSite(inClaim: claim) else { continue }
            XCTAssertTrue(
                body.contains(call),
                "\(file) is declared sweptByErase by \(call), and the erase body "
                + "no longer contains it — the declaration is now fiction"
            )
        }
    }

    /// Known gaps are plaintext copies of user data surviving an erase. Pinned
    /// so adding one is a deliberate edit with a reason in the commit message.
    ///
    /// The writer census has NONE. An earlier version declared `pending/` a gap
    /// on a false premise: the erase does call `clearAllPendingWork` (gh#264,
    /// closed not-a-defect). The lesson is in the grep, not the judgement — the
    /// search was for `clearPending`, and the function is `clearAllPendingWork`.
    func testTheKnownGapsAreDeliberate() {
        let writerGaps = writers.compactMap { k, v -> String? in
            if case .knownGap(let i) = v { return "\(k) → \(i)" }
            return nil
        }
        XCTAssertEqual(writerGaps.sorted(), [], "no writer may survive the erase unclassified")

        let keyGaps = Set(keyExceptions.compactMap { k, v -> String? in
            if case .knownGap(let i) = v { return i }
            return nil
        })
        XCTAssertEqual(keyGaps, ["gh#265"],
                       "the only open defaults gap is the UI-preference class in gh#265")
    }

    // MARK: - Scanners

    /// A file can put bytes on disk. Deliberately broad — a false positive
    /// costs one inventory line, a false negative costs a privacy defect.
    nonisolated static func canWriteToDisk(_ source: String) -> Bool {
        let needles = [
            ".write(to:", "FileManager.default.createFile", "FileHandle(forWritingTo:",
            ".createDirectory(at:", "removeItem(at:",
        ]
        return needles.contains { source.contains($0) }
    }

    /// `(all declared keys, those in resettableUserDefaultsKeys)`.
    nonisolated static func appSettingsKeys(in source: String) throws -> (Set<String>, Set<String>) {
        guard let start = source.range(of: "enum AppSettingsKeys"),
              let sweepStart = source.range(of: "resettableUserDefaultsKeys: [String] = ["),
              let sweepEnd = source.range(of: "\n    ]", range: sweepStart.upperBound..<source.endIndex),
              let end = source.range(of: "\n}", range: sweepEnd.upperBound..<source.endIndex)
        else { throw XCTSkip("AppSettingsKeys has been restructured — re-point this scanner") }

        let block = String(source[start.lowerBound..<end.lowerBound])
        var keys = Set<String>()
        for line in block.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("static let "), let eq = t.range(of: " = \"") else { continue }
            let name = t["static let ".endIndex..<eq.lowerBound]
            keys.insert(name.trimmingCharacters(in: .whitespaces))
        }
        var listed = Set<String>()
        for line in source[sweepStart.upperBound..<sweepEnd.lowerBound].split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), t.hasSuffix(","), !t.contains("(") else { continue }
            listed.insert(String(t.dropLast()))
        }
        return (keys, listed)
    }

    /// A named function's body with line comments stripped.
    nonisolated static func eraseBody(in source: String, named signature: String) throws -> String {
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { throw XCTSkip("\(signature) has been renamed — re-point this guard") }
        return source[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("//") ? "" : String(line)
            }
            .joined(separator: "\n")
    }

    /// The `Foo.bar()` call at the head of a `sweptByErase` claim.
    nonisolated static func callSite(inClaim claim: String) -> String? {
        guard let paren = claim.range(of: "()") else { return nil }
        let head = claim[..<paren.upperBound]
        guard let spaceIdx = head.lastIndex(where: { $0 == " " }) else { return String(head) }
        return String(head[head.index(after: spaceIdx)...])
    }
}
