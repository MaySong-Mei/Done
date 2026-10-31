//
//  EraseWiringQATests.swift
//  DoneTests
//
//  Round 2 of the erase campaign. Everything here exists because a mutant
//  survived: the production code was correct and nothing held it down.
//

import XCTest
@testable import Done

/// The measured gap this file closes.
///
/// Round-1 review landed three in-flight gates, four XCTest seams and two
/// key families, with 1974 tests green. Three independent reviewers then
/// said the same thing — the code is right, the suite cannot see it — and a
/// mutation sweep agreed: **16 single-line reverts to the pre-fix behaviour
/// left the whole suite green.** Among them, every one of the seven disk
/// purges in `resetAllLocalData()`, both unpinned XCTest seams, all three
/// usage-ledger gates, and taking the LLM token after the `await` that the
/// primitive's own doc calls "the bug".
///
/// One of those survivors was the control. `MeAvatarStore.delete()` was
/// supposed to be held by an ordering test — and that test matched the
/// string inside a COMMENT about itself, so deleting the real call stayed
/// green. See `EraseWiringScan.functionBody`.
/// `@MainActor` on the class, not on single methods: under this module's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the things under test here —
/// `AgentPreferenceStore`, `LLMUsageStore`, the `LLMProvider` ledger helpers
/// and `CalendarViewState` — are all MainActor-isolated. Which is also the
/// invariant the gates' zero-width TOCTOU window depends on; see
/// `LocalDataEraseEpoch`'s header.
@MainActor
final class EraseWiringQATests: XCTestCase {

    // MARK: - The purges are still wired in

    /// Each of these was individually deletable with 1974 tests green.
    ///
    /// Presence assertions, not behaviour: `resetAllLocalData()` is `private`
    /// on a SwiftUI view, so no test can drive it. The scope and the honesty
    /// limits of reading source here are in `EraseWiringScan`'s doc — and
    /// gh#266's registry is what replaces this with a derived list.
    func testEveryPurgeIsStillWiredIntoTheErase() throws {
        let body = try EraseWiringScan.functionBody(
            of: "func resetAllLocalData(keepingSession: Bool) {",
            inFileAt: "Done/Services/LocalDataEraser.swift"
        )

        // call site -> what survives the erase without it
        let required: [(String, String)] = [
            ("LocalDataEraseEpoch.bump()",
             "no in-flight writer learns the erase happened; gh#266's three races all re-open"),
            ("store.clearAllLocalData()",
             "the events themselves"),
            ("imageBackupCoordinator.forgetConfirmedUploads()",
             "imageBackup.confirmedUploadedObjects.* — the user's event ids, never pruned, in a backed-up domain"),
            ("authService.signOut()",
             "supabaseAuthSession — a live refresh token and the user's email address"),
            ("calendarState.forgetPersistedViewState()",
             "the pre-erase zoom and range mode, in memory, written back by the next geometry pass"),
            ("MeAvatarStore.delete()",
             "the user's own avatar JPEG in Documents/"),
            ("AgenticIntakeAssetStore().removeAllAssets()",
             "every attached event and log photo (gh#260)"),
            ("PersonAvatarStore.removeAll()",
             "photographs of other people (gh#263)"),
            ("ReportStore().wipe()",
             "reports, including userNote — the user's own writing (gh#261)"),
            ("LLMUsageStore.shared.clearAll()",
             "per-day/model activity counters (gh#263)"),
            ("SpikeRunStore.wipe()",
             "spike run records including user-entered notes (gh#263) — and, in the same directory, the "
             + "telemetry upload cursor, install id and last request sample (gh#273): an erased phone that "
             + "kept them would present itself to the server as the previous owner's install"),
            ("telemetryUploader?.forgetAfterErase()",
             "the uploader's in-memory status — last upload time, row counts, the request sample, the last "
             + "outcome and the daily throttle clock — describing the previous owner's uploads (gh#273)"),
            ("ResidentObservationCenter.shared?.forgetAfterErase()",
             "the resident observer's day in memory — counters, followers, an open auto-window and the "
             + "daily id with its owner — which the next flush wrote back into the wiped directory "
             + "under the erased owner"),
            ("SpikeSessionCoordinator.shared?.forgetAfterErase()",
             "a manual spike run armed from the Developer page, still shown as armed and still "
             + "measuring after the erase, and the runners' last completed run — the erased owner's"),
            ("AppSettingsKeys.removeResettableKeys(from: defaults)",
             "the by-name sweep, which now also carries the telemetry switch, its consent moment, "
             + "the note opt-in, the decided bit and the by-default bit (gh#273): the next account on "
             + "this phone would inherit the previous owner's consent to share statistics"),
            ("syncService.forgetAccountGone()",
             "the in-memory \"account erased elsewhere\" card and choice, describing data the erase removed"),
            ("ConflictShelf.wipe()",
             "the sync conflict shelf — the losing versions of the user's synced rows, whole"),
            ("SyncOwnerRecord.production.remove()",
             "owner.json, the owner guard's record beside the data: the next sign-in would be "
             + "blocked on an account whose data the erase just removed"),
            ("MetricPayloadStore.standard().wipe()",
             "MetricKit payloads in Diagnostics/ and the legacy Documents/Diagnostics pile"),
            ("UIPasteboard.general.items = []",
             "the MCP connector URL — a live read token — still in the system clipboard, "
             + "and with Universal Clipboard on the user's other devices too"),
            ("AppSettingsKeys.shouldClearPasteboardOnErase(",
             "the clipboard clear loses the three conditions that decide whether it is "
             + "ours to clear; see the decision-table test below"),
        ]

        for (call, consequence) in required {
            EraseWiringScan.assertCalls(call, in: body, because: consequence)
        }

        // Liveness: the scan must be reading real code, not an empty string.
        XCTAssertTrue(body.contains("UserDefaults.standard"),
                      "liveness: the extracted body must be the real function")
        XCTAssertFalse(body.contains("THAT IS STILL TRUE"),
                       "liveness: comments must have been stripped — the raw body contains this "
                       + "phrase, and a scan that still sees it is reading prose as code")
    }

    /// gh#257 "switch to this account" runs this same erase keeping the
    /// session it switches to. Only the sign-out may depend on that, and the
    /// account card must hand the engine THIS erase — the engine's own test
    /// (`SyncCatchUpTests`) can only drive a stand-in.
    func testTheAccountSwitchRunsTheOneEraseAndOnlyTheSignOutIsKept() throws {
        let erase = try EraseWiringScan.functionBody(
            of: "func resetAllLocalData(keepingSession: Bool) {",
            inFileAt: "Done/Services/LocalDataEraser.swift"
        )
        let collapsed = erase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(collapsed.contains("if !keepingSession { authService.signOut() }"),
                      "the session is the one thing the switch keeps, and only it")
        XCTAssertEqual(erase.components(separatedBy: "keepingSession").count - 1, 1,
                       "one use of the flag: every purge runs for both callers")

        let card = try EraseWiringScan.functionBody(
            of: "private func switchToThisAccount() {",
            inFileAt: "Done/Views/Agent/AccountView.swift"
        )
        let cardCollapsed = card.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(cardCollapsed.contains("syncService.switchToCurrentAccount { eraser.resetAllLocalData(keepingSession: true) }"),
                      "the card hands the engine the real erase, keeping the session")
    }

    /// The ordering constraint, restated here because the test that owned it
    /// was the one the comment disarmed.
    func testTheSnapshotWipeStillComesAfterTheAvatarDelete() throws {
        let body = try EraseWiringScan.functionBody(
            of: "func resetAllLocalData(keepingSession: Bool) {",
            inFileAt: "Done/Services/LocalDataEraser.swift"
        )
        let avatar = try XCTUnwrap(body.range(of: "MeAvatarStore.delete()"))
        let snapshot = try XCTUnwrap(body.range(of: "backupSnapshotService.wipe()"))
        XCTAssertTrue(snapshot.lowerBound > avatar.lowerBound,
                      "gh#258: the snapshot wipe re-attaches and swallows the emissions the "
                      + "store erasures produce, so it must run after them")
        XCTAssertEqual(body.components(separatedBy: "MeAvatarStore.delete()").count - 1, 1,
                       "exactly one occurrence — more than one means the scan is matching "
                       + "something other than the call, which is how this went green before")
    }

    /// The resident's forget mints the next daily id under the owner that holds
    /// at the moment it runs, so it must follow everything that changes that
    /// owner or that answers for it: the sign-out, the wipe of the records'
    /// directory, and the uploader's reset (which drops the owner it cached
    /// before attaching to a session).
    func testTheResidentForgetsAfterTheSignOutTheWipeAndTheUploaderReset() throws {
        let body = try EraseWiringScan.functionBody(
            of: "func resetAllLocalData(keepingSession: Bool) {",
            inFileAt: "Done/Services/LocalDataEraser.swift"
        )
        let forget = try XCTUnwrap(body.range(of: "ResidentObservationCenter.shared?.forgetAfterErase()"))
        for earlier in ["authService.signOut()", "SpikeRunStore.wipe()", "telemetryUploader?.forgetAfterErase()"] {
            let call = try XCTUnwrap(body.range(of: earlier), "liveness: \(earlier) is in the erase")
            XCTAssertTrue(call.lowerBound < forget.lowerBound,
                          "\(earlier) must run before the resident forgets: its fresh id is minted for the owner after it")
        }
        XCTAssertEqual(body.components(separatedBy: "ResidentObservationCenter.shared?.forgetAfterErase()").count - 1, 1,
                       "exactly one occurrence — more means the scan matches something other than the call")
    }

    /// gh#239 made the widget render its chrome from the App Group's language
    /// mirror. `store.clearAllLocalData()` stamps that mirror from the
    /// pre-erase settings, and the sweep that resets the language runs after
    /// it — so the mirror has to be stamped a second time, after the sweep.
    func testTheWidgetMirrorIsRestampedAfterTheSettingsSweep() throws {
        let body = try EraseWiringScan.functionBody(
            of: "func resetAllLocalData(keepingSession: Bool) {",
            inFileAt: "Done/Services/LocalDataEraser.swift"
        )
        let sweep = try XCTUnwrap(body.range(of: "AppSettingsKeys.removeResettableKeys(from: defaults)"))
        let flush = try XCTUnwrap(body.range(of: "store.flushWidgetSnapshotSync()"),
                                  "the erase must re-flush the widget payload once the language and "
                                  + "clock keys are gone, or the widget keeps the pre-erase language")
        XCTAssertTrue(flush.lowerBound > sweep.lowerBound,
                      "the flush before the sweep is the one inside clearAllLocalData(); this one "
                      + "must come after it")
        XCTAssertEqual(body.components(separatedBy: "store.flushWidgetSnapshotSync()").count - 1, 1,
                       "exactly one occurrence — more means the scan matches something other than "
                       + "the call")
    }

    // MARK: - The XCTest seams

    /// Two of these were pinned nowhere, and reverting the `PersonAvatars`
    /// one destroys every contact photo on the machine running the suite —
    /// permanently, and with `Person.avatarImageName` already gone, so even
    /// a manual cleanup could not tell the files apart.
    ///
    /// Asserted on the LEAF rather than the whole path: the directory's
    /// location is not the claim, the redirect is.
    func testEveryPurgeCapableStoreIsRedirectedUnderXCTest() throws {
        XCTAssertEqual(
            try XCTUnwrap(PersonAvatarStore.resolvedDirectory).lastPathComponent,
            "PersonAvatars-test-host",
            "a suite run would otherwise removeAll() the real contact photos")
        XCTAssertEqual(
            DiagnosticTrail.directory.lastPathComponent,
            "Diagnostics-TestHost",
            "clear() is in the erase and ~20 test call sites reach it; iOS grants no "
            + "entitlement to read the system log store back, so this one has no second copy")
        XCTAssertEqual(
            DiagnosticTrail.exportURL.lastPathComponent,
            "done-diagnostic-trail-test-host.txt",
            "clear() removes this path too — a shared name has a test run delete the copy "
            + "the user just generated to attach to a report")
        XCTAssertEqual(
            MeAvatarStore.url.lastPathComponent,
            "me-avatar-test-host.jpg",
            "the erase deletes this file")
        XCTAssertEqual(
            SpikeRunStorageLocation.production.directory.lastPathComponent,
            "spike-runs-test-host",
            "SpikeRunStore.wipe() is in the erase, and DoneApp reconciles spikes at launch "
            + "inside the test host")
        XCTAssertEqual(
            AgentPreferenceStore().directoryName,
            "AgentRuntime-TestHost",
            "clearRules()/clearDecisionHistory()/save() overwrite both JSON files whole")
        XCTAssertEqual(
            ConflictShelf.productionDirectory.lastPathComponent,
            "Sync-TestHost",
            "ConflictShelf.wipe() is in the erase and removes the whole directory — "
            + "unredirected, a suite run deletes the device's real conflict shelf")
        XCTAssertEqual(
            SyncOwnerRecord.production.directory.lastPathComponent,
            "Sync-TestHost",
            "SyncOwnerRecord.production.remove() is in the erase — unredirected, a suite run "
            + "deletes the device's real owner record")
        XCTAssertTrue(
            SharedWidgetData.suiteName.hasSuffix(".test-host"),
            "clearAllLocalData() flushes the widget payload synchronously, and 22 test call "
            + "sites reach it — unredirected they blank the dogfood device's real widget")
        XCTAssertEqual(
            ReportStore().directoryURL.lastPathComponent,
            "Reports-test-host",
            "ReportStore().wipe() is in the erase and removes the whole directory — "
            + "unredirected, a suite run deletes the device's reports, userNote included")
        XCTAssertEqual(
            LLMUsageStore.shared.fileURL.deletingLastPathComponent().lastPathComponent,
            "DeveloperStats-test-host",
            "LLMUsageStore.shared.clearAll() is in the erase and rewrites llm-usage.json whole")
        XCTAssertEqual(
            AgentConversationRepository.shared.directory.lastPathComponent,
            "AgentChat-TestHost",
            "AgentConversationRepository.shared.wipe() is in the erase — the chat history")
        XCTAssertEqual(
            OccurrenceKeyMetadataStore.shared.directory.lastPathComponent,
            "OccurrenceKey-TestHost",
            "OccurrenceKeyMetadataStore.shared.wipe() is in the erase — the frozen reference zone")
        XCTAssertEqual(
            EventTypeCatalog.shared.directory.lastPathComponent,
            "EventTypes-TestHost",
            "resetToDefaults() on the app's store is in the erase and rewrites the event types whole")
    }

    /// The assertion above pins the suite's NAME; this pins the INSTANCE the
    /// production write opens. `sharedDefaults` is cached (gh#239: the
    /// widget's `L(...)` reads it on every string), and a cache opened on
    /// `appGroupID` instead of `suiteName` left this whole suite green while
    /// `clearAllLocalData()` wrote `events: []` into the real App Group — the
    /// review mutant created the dogfood device's group plist with 44/0 green.
    /// So: write through the production path and ask both suites which moved.
    func testTheWidgetWriteLandsInTheRedirectedSuiteNotTheRealGroup() throws {
        let redirected = try XCTUnwrap(UserDefaults(suiteName: SharedWidgetData.suiteName))
        let real = try XCTUnwrap(UserDefaults(suiteName: SharedWidgetData.appGroupID))
        XCTAssertNotEqual(SharedWidgetData.suiteName, SharedWidgetData.appGroupID,
                          "liveness: under XCTest the two suites must be different stores")

        let keys = [SharedWidgetData.snapshotKey, SharedWidgetData.lastUpdatedKey,
                    SharedWidgetData.timeFormatKey, SharedWidgetData.languageKey,
                    SharedWidgetData.timeZoneKey]
        let saved = keys.map { ($0, redirected.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { redirected.set(value, forKey: key) } else { redirected.removeObject(forKey: key) }
            }
        }

        let realStampBefore = real.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date
        let realPayloadBefore = real.data(forKey: SharedWidgetData.snapshotKey)
        let before = Date()
        XCTAssertTrue(SharedWidgetData.write(events: [], timeFormat: "24h", language: "en",
                                             timeZone: TimeZone.current.identifier))

        let stamp = try XCTUnwrap(redirected.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date,
                                  "the production write must land in the redirected suite")
        XCTAssertGreaterThanOrEqual(stamp, before.addingTimeInterval(-1))
        XCTAssertEqual(real.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date, realStampBefore,
                       "the real App Group is the dogfood device's widget; a test must never stamp it")
        XCTAssertEqual(real.data(forKey: SharedWidgetData.snapshotKey), realPayloadBefore,
                       "nor replace its payload")
    }

    /// The regression round 1 introduced: the redirect moved the path and
    /// left the migration flag on the production side, so a suite run that
    /// coincided with a MetricKit delivery marked the REAL
    /// `Documents/Diagnostics` pile as already migrated — stranding it
    /// forever. A redirect that moves half a store's state is worse than
    /// none.
    func testTheMetricStoresMigrationFlagMovesWithItsPath() {
        let store = MetricPayloadStore.standard()
        XCTAssertEqual(store.migrationFlagKey,
                       "MetricPayloadStore.migratedDocumentsDiagnostics.v1.test-host",
                       "the flag has to be redirected with the directory: the migration sets it "
                       + "when the legacy pile is ABSENT, which under XCTest it always is")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: "MetricPayloadStore.migratedDocumentsDiagnostics.v1"),
            "liveness: constructing the store must not have touched the production flag")
    }

    // MARK: - gh#260's purge, actually executed

    /// `removeAllAssets()`'s working line was unreachable in the whole suite:
    /// its gate is `!isRunningUnderXCTest`, so every test took the refusal
    /// branch and `return false` in place of the removal came back green.
    func testTheAssetPurgeRemovesTheTreeWhenItOwnsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-purge-\(UUID().uuidString)", isDirectory: true)
        let nested = directory.appendingPathComponent("EVENT-1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let photo = nested.appendingPathComponent("IMAGE-1.jpg")
        try Data("not really a jpeg".utf8).write(to: photo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path),
                      "liveness: the fixture photo must be on disk")

        XCTAssertTrue(AgenticIntakeAssetStore(purgingDirectory: directory).removeAllAssets(),
                      "gh#260: the purge must report success")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "gh#260: attached event and log photos must not survive the erase")
    }

    /// The positive control for the test above: the gate is still live, so
    /// the default store — the one the erase constructs — still refuses
    /// under XCTest rather than sweeping the shared container.
    func testTheDefaultAssetStoreStillRefusesUnderXCTest() {
        XCTAssertFalse(AgenticIntakeAssetStore().removeAllAssets(),
                       "the shared asset directory is one path for the whole container and is "
                       + "NOT redirected; a test-host store sweeping it deletes the dogfood "
                       + "user's photos")
    }

    // MARK: - The usage ledger

    /// All three ledger gates were deletable with the suite green, and the
    /// test named after them re-typed the rule in its own body instead of
    /// calling the production code. These call the real helpers.
    func testTheLedgerRefusesAPreEraseRequestAndStillRecordsAFreshOne() {
        LocalDataEraseEpoch.withIsolatedEpoch {
            let store = LLMUsageStore(directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true))

            let staleToken = LocalDataEraseEpoch.capture()
            LocalDataEraseEpoch.bump()
            recordAnthropicUsage(
                ["usage": ["input_tokens": 11, "output_tokens": 22]],
                model: "claude-test", purpose: "qa", eraseEpoch: staleToken, store: store)
            recordOpenAIUsage(
                ["usage": ["prompt_tokens": 33, "completion_tokens": 44]],
                model: "gpt-test", purpose: "qa", eraseEpoch: staleToken, store: store)
            recordUsageFailure(
                model: "fail-test", purpose: "qa", eraseEpoch: staleToken, store: store)
            XCTAssertTrue(store.allBuckets().isEmpty,
                          "a request that began before the erase must not be folded into the "
                          + "ledger afterwards — the erase cleared it a moment ago")

            // Positive control. Without it, "refuses to record" is
            // indistinguishable from "never records", which would be the
            // other bug: an erase that permanently breaks accounting.
            let freshToken = LocalDataEraseEpoch.capture()
            recordAnthropicUsage(
                ["usage": ["input_tokens": 11, "output_tokens": 22]],
                model: "claude-test", purpose: "qa", eraseEpoch: freshToken, store: store)
            XCTAssertFalse(store.allBuckets().isEmpty,
                           "accounting must restart after the erase, not stop forever")
        }
    }

    // MARK: - Where the token is taken

    /// `LocalDataEraseEpoch`'s doc says, in those words, that a token taken
    /// after the `await` is the bug. Both sites that do it were deletable
    /// with the suite green, and neither can be driven from a test:
    /// `fetchLLMResponseJSON` hardcodes `URLSession.shared`, and
    /// `generate()` reads the dogfood user's real API key out of
    /// `UserDefaults.standard` — a test that drove it would issue a real,
    /// billed request against that key.
    ///
    /// So the position is asserted in the source, with comments stripped.
    /// One closed fact per assertion: the capture appears exactly once, and
    /// before the first suspension point.
    func testTheTokenIsTakenBeforeTheAwaitNotAfterIt() throws {
        let fetch = try EraseWiringScan.functionBody(
            of: ") async throws -> (json: [String: Any], eraseEpoch: Int) {",
            inFileAt: "Done/Services/Agent/LLMProvider.swift",
            closingBrace: "\n}\n"
        )
        let capture = try XCTUnwrap(
            fetch.range(of: "let eraseEpoch = LocalDataEraseEpoch.capture()"),
            "fetchLLMResponseJSON must capture an epoch token")
        let suspension = try XCTUnwrap(
            fetch.range(of: "await URLSession.shared.data(for: urlRequest)"),
            "the anchor await moved — re-derive this assertion")
        XCTAssertTrue(capture.lowerBound < suspension.lowerBound,
                      "the token must be taken BEFORE the request is sent; taken after, it is "
                      + "already the post-erase value and the gate can never fire")
        XCTAssertEqual(fetch.components(separatedBy: "LocalDataEraseEpoch.capture()").count - 1, 1,
                       "exactly one capture site — a second one taken later is the bug this "
                       + "assertion exists to catch")

        let generate = try EraseWiringScan.functionBody(
            of: "    ) async throws -> Report {",
            inFileAt: "Done/Services/Report/ReportGenerationService.swift"
        )
        XCTAssertEqual(generate.components(separatedBy: "LocalDataEraseEpoch.capture()").count - 1, 1,
                       "generate() must capture exactly once, at the top — a capture passed to "
                       + "saveIfStillWanted after the provider returns defeats the gate")
        let generateCapture = try XCTUnwrap(
            generate.range(of: "let eraseEpoch = LocalDataEraseEpoch.capture()"))
        let firstAwait = try XCTUnwrap(generate.range(of: "await "))
        XCTAssertTrue(generateCapture.lowerBound < firstAwait.lowerBound,
                      "the capture must precede the first suspension point in generate()")
    }

    // MARK: - List membership

    /// `ResetSweepQATests` drives the production loop over
    /// `resettableUserDefaultsKeys` — which proves the loop iterates the
    /// list it is handed, and is structurally incapable of noticing a
    /// MISSING entry. Deleting `customAnniversaries` from the list came back
    /// green for exactly that reason.
    func testTheSweepListStillNamesTheKeysThatCarryUserContent() {
        let list = Set(AppSettingsKeys.resettableUserDefaultsKeys)
        let required: [(String, String)] = [
            (AppSettingsKeys.customAnniversaries,
             "its own declaration calls it user-AUTHORED content, not a preference"),
            (AppSettingsKeys.calendarTimelineHourHeight,
             "the key a review caught and both censuses were blind to"),
            (AppSettingsKeys.calendarLastRangeMode, "remembered calendar view state"),
            (AppSettingsKeys.calendarRememberViewMode, "remembered calendar view state"),
            (AppSettingsKeys.mcpURL,
             "a permanent connector URL WITH TOKEN granting external apps read access"),
            (AppSettingsKeys.mcpURLPasteboardChangeCount,
             "the erase's only way to know the clipboard still holds that credential"),
            (AppSettingsLocale.languageKey,
             "the interface language the user chose, same shape as appearanceMode which is swept"),
            (AppSettingsLocale.timeFormatKey, "the clock format the user chose"),
            (AppSettingsKeys.calendarHeaderExposedTools, "tools the user pinned by hand"),
            (AppSettingsKeys.detailHeaderExposedTools, "tools the user pinned by hand"),
            (AppSettingsKeys.calendarAutoReturnToToday, "a preference the user set"),
            (AppSettingsKeys.holidaysShowSolarTerms, "a preference the user set"),
            (AppSettingsKeys.holidaysShowGregorianHolidays, "a preference the user set"),
            (AppSettingsKeys.calendarUseCALayerAxisMarkers,
             "its three sibling render flags are all on the list"),
            (AppSettingsKeys.tokenInferenceLLMEnabled, "a flag that gates LLM spend"),
            (AppSettingsKeys.calendarShareStyle, "the share style the user chose"),
        ]
        for (key, why) in required {
            XCTAssertTrue(list.contains(key),
                          "`\(key)` must be in resettableUserDefaultsKeys — \(why)")
        }
    }

    // MARK: - The clipboard the erase does not own

    /// The clipboard clear survived the first verification sweep: deleting
    /// the whole block left the suite green.
    ///
    /// Its `UIPasteboard` write is the one line in the erase that no test
    /// may execute — `DoneTests` runs inside Done.app, so clearing "the
    /// clipboard" clears the real one, on this device and, with Universal
    /// Clipboard, on the user's others. So the decision moved into
    /// `AppSettingsKeys.shouldClearPasteboardOnErase`, where each condition
    /// is a case, and the wiring test above holds the call and the write.
    ///
    /// The asymmetry is deliberate: clearing a clipboard we no longer own
    /// destroys something the user put there, while failing to clear one
    /// leaves a token exposed. Both are real, so all three conditions must
    /// hold and every near-miss must fall through to "leave it alone".
    func testTheClipboardIsClearedOnlyWhileItStillHoldsOurCopy() throws {
        let suiteName = "EraseWiringQATests-clipboard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        func decide(count: Int) -> Bool {
            AppSettingsKeys.shouldClearPasteboardOnErase(
                defaults: suite, currentChangeCount: count)
        }

        // Nothing recorded at all: a user who never opened the Account page.
        XCTAssertFalse(decide(count: 0),
                       "with no connector URL there is nothing of ours to clear")

        suite.set(42, forKey: AppSettingsKeys.mcpURLPasteboardChangeCount)
        XCTAssertFalse(decide(count: 42),
                       "a recorded Copy without a connector URL is stale bookkeeping — "
                       + "the URL was already removed, so the token is not ours to chase")

        suite.set("https://example.com/mcp?token=t", forKey: AppSettingsKeys.mcpURL)
        XCTAssertTrue(decide(count: 42),
                      "URL present, Copy recorded, count unchanged: our string is still "
                      + "on the clipboard and the erase must take it")
        XCTAssertFalse(decide(count: 43),
                       "the count moved — something else has been copied since, and "
                       + "clearing would destroy the user's current clipboard")
        XCTAssertFalse(decide(count: 0),
                       "a count of zero is a restarted device, not a match: the "
                       + "comparison must fail closed rather than clear blind")

        suite.removeObject(forKey: AppSettingsKeys.mcpURLPasteboardChangeCount)
        XCTAssertFalse(decide(count: 0),
                       "no recorded Copy: the URL exists but was never put on the "
                       + "clipboard, and 0 == 0 must not be read as a match")

        suite.set("", forKey: AppSettingsKeys.mcpURL)
        suite.set(42, forKey: AppSettingsKeys.mcpURLPasteboardChangeCount)
        XCTAssertFalse(decide(count: 42),
                       "an empty URL string is no URL — `?.isEmpty == false` and "
                       + "`!= nil` differ here, and only the first is right")
    }

    // MARK: - Telling the owner, not just removing the key

    /// The rule `AuthService.forgetReauthenticationNotice` states and the
    /// erase applies to four owners now. This is the one it was missing: the
    /// sweep removed the zoom key while the live object still held the
    /// pre-erase value and wrote it back.
    func testForgettingTheViewStateDoesNotWriteEitherKeyBack() throws {
        let suite = UserDefaults(suiteName: "CalendarViewStateForget-\(UUID().uuidString)")!
        suite.set(96.0, forKey: AppSettingsKeys.calendarTimelineHourHeight)
        suite.set(true, forKey: AppSettingsKeys.calendarRememberViewMode)
        suite.set("week", forKey: AppSettingsKeys.calendarLastRangeMode)

        let state = CalendarViewState(defaults: suite)
        XCTAssertEqual(state.timelineHourHeight, 96, "liveness: the pinched zoom must be restored")
        // Compared by raw value: `RangeMode`'s `Equatable` conformance is
        // MainActor-isolated under this module's default isolation, and an
        // `XCTAssertEqual` on it is an error in the Swift 6 language mode.
        XCTAssertTrue(state.rangeMode == .week || {
            if case .week = state.rangeMode { return true } else { return false }
        }(), "liveness: the remembered range mode must be restored")

        // What the erase does: remove the keys, then tell the owner.
        suite.removeObject(forKey: AppSettingsKeys.calendarTimelineHourHeight)
        suite.removeObject(forKey: AppSettingsKeys.calendarLastRangeMode)
        state.forgetPersistedViewState()

        XCTAssertEqual(state.timelineHourHeight, calendarTimelineHourHeightDefault,
                       "the in-memory zoom must go back to the default, or the next geometry "
                       + "pass commits the pre-erase value straight back to disk")
        XCTAssertNil(suite.object(forKey: AppSettingsKeys.calendarLastRangeMode),
                     "resetting rangeMode must not re-create the key the sweep just removed — "
                     + "its didSet persists unconditionally")

        // And the commit path, driven, is now writing the default rather
        // than the pre-erase value.
        state.commitTimelineHourHeight()
        XCTAssertEqual(suite.double(forKey: AppSettingsKeys.calendarTimelineHourHeight),
                       Double(calendarTimelineHourHeightDefault),
                       "the pre-erase zoom must be gone from memory, not just from disk")
    }
}
