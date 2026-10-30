//
//  SyncRestoreAndSwitchQATests.swift
//  DoneTests
//
//  Independent QA for fix/sync-restore-and-toggle (90141d28). The
//  implementer's SyncRestoreAndSwitchTests drive the calendar table and the
//  skills POST; these attack what that harness does not reach:
//
//  1. The merge restore across every id table (todo events, logs with
//     their occurrence-key ids, feedback, todo lists, skills): what the
//     cloud lacks goes up, what it carried is recorded at its cloud seq.
//  2. A merge restore landing while a full sync has a row in flight.
//  3. The switch: many flips with edits between them, the end-of-pass
//     flush against a puller that has not reached head, an erase in the
//     middle of a pass, and every way a pass can end leaving the next one
//     startable (the in-flight flag never sticks).
//  4. The session changing during a pass: the same account signing out
//     and back in, another account signing in (blocked, or A → B → A),
//     the switch and a sign-in together, and a token refresh (round 2,
//     1972163d).
//  5. The pass stopping at a table boundary once the switch is off (the
//     implementer's surviving mutant): nothing is built for a table after.
//  6. Main-thread cost of the restore replay at a production data size.
//
//  The fixture is the implementer's `SyncRestoreAndSwitchTestCase` (switch
//  on, puller at head, the session sink attached); nothing here edits it.
//

import XCTest
@testable import Done

@MainActor
class SyncRestoreAndSwitchQATestCase: SyncRestoreAndSwitchTestCase {

    func makeLog(for event: Event) -> CalendarEventLogRecord {
        let day = Calendar.current.startOfDay(for: event.timeRanges[0].start)
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: day)
        return CalendarEventLogRecord(id: key, eventID: event.id, baseSeriesEventID: nil,
                                      occurrenceDate: day, createdAt: Self.t0, updatedAt: Self.t0)
    }

    func makeFeedback(for event: Event) -> CalendarEventFeedbackRecord {
        let day = Calendar.current.startOfDay(for: event.timeRanges[0].start)
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: day)
        return CalendarEventFeedbackRecord(id: key, eventID: event.id, baseSeriesEventID: nil,
                                           occurrenceDate: day, createdAt: Self.t0, updatedAt: Self.t0)
    }

    /// A full sync started by `start`, parked on the first request that
    /// `park` matches.
    func parkAPass(on park: @escaping (SyncFakeServer.Verb, String) -> Bool,
                   startedBy start: () async -> Void) async throws {
        server.holdWhen = park
        await start()
        try await syncEventually("the pass is parked") { self.server.heldCount == 1 }
    }

    /// The parked request answered; the pass (and any rerun) runs on.
    func releaseEverything() async throws {
        server.holdWhen = nil
        server.releaseAll()
        try await syncEventually("nothing is held") { self.server.heldCount == 0 }
        try await settle()
        try await settle()
    }

    func writeCount() -> Int { writes().count }
}

// MARK: - 1. The merge restore

@MainActor
final class SyncMergeRestoreQATests: SyncRestoreAndSwitchQATestCase {

    /// Every id table, not only calendar: a row made while uploads were off
    /// in each of them is unrecorded after a merge and goes up when the
    /// switch comes back on; every row the cloud carried is recorded at the
    /// seq the cloud holds for it — the log's occurrence-key id included —
    /// and none of them is sent again.
    func testQA_R1_aMergeLeavesTheOfflineRowsOfEveryIdTableToBeSent_andRecordsWhatTheCloudCarriedAtItsSeq() async throws {
        let cal = makeEvent("cloud calendar")
        let todo = makeEvent("cloud todo")
        let skill = makeSkill("cloud skill")
        let list = TodoList(title: "cloud list", colorName: "green", createdAt: Self.t0)
        let log = makeLog(for: cal)
        let feedback = makeFeedback(for: cal)
        server.seed(table: "events", rows: [service.eventToRow(cal, kind: "calendar"), service.eventToRow(todo, kind: "todo")])
        server.seed(table: "skill_insights", rows: [service.skillToRow(skill)])
        server.seed(table: "todo_lists", rows: [service.todoListToRow(list)])
        server.seed(table: "event_logs", rows: [service.logToRow(log)])
        server.seed(table: "event_feedback", rows: [service.feedbackToRow(feedback)])
        await puller.pullToHead()
        XCTAssertTrue(store.events.contains { $0.id == todo.id }, "fixture: the todo was pulled")
        XCTAssertTrue(store.calendarEventLogRecords.contains { $0.id == log.id }, "fixture: the log was pulled")
        XCTAssertTrue(store.calendarEventFeedbackRecords.contains { $0.id == feedback.id }, "fixture: the feedback was pulled")

        switchOff()
        let offCal = makeEvent("offline calendar")
        store.addCalendarEvent(offCal)
        let offTodo = makeEvent("offline todo")
        store.add(offTodo)
        let offSkill = makeSkill("offline skill")
        device.skills.add(offSkill)
        let offList = TodoList(title: "offline list", colorName: "blue", createdAt: Self.t0)
        store.addList(offList)
        let offLog = makeLog(for: offCal)
        store.calendarEventLogRecords.append(offLog)
        let offFeedback = makeFeedback(for: offCal)
        store.calendarEventFeedbackRecords.append(offFeedback)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: nothing left the phone with the switch off")

        try await restore(.merge)

        let offline: [(table: String, server: String, id: String)] = [
            ("calendar_events", "events", offCal.id.uuidString),
            ("events", "events", offTodo.id.uuidString),
            ("skill_insights", "skill_insights", offSkill.id.uuidString),
            ("todo_lists", "todo_lists", offList.id.uuidString),
            ("event_logs", "event_logs", service.encodeOccurrenceKey(offLog.id)),
            ("event_feedback", "event_feedback", service.encodeOccurrenceKey(offFeedback.id)),
        ]
        let carried: [(table: String, server: String, id: String)] = [
            ("calendar_events", "events", cal.id.uuidString),
            ("events", "events", todo.id.uuidString),
            ("skill_insights", "skill_insights", skill.id.uuidString),
            ("todo_lists", "todo_lists", list.id.uuidString),
            ("event_logs", "event_logs", service.encodeOccurrenceKey(log.id)),
            ("event_feedback", "event_feedback", service.encodeOccurrenceKey(feedback.id)),
        ]
        for row in offline {
            XCTAssertNil(service.baseline.entry(table: row.table, id: row.id),
                         "\(row.table): the merge recorded a row the cloud never had as uploaded")
        }
        for row in carried {
            let seq = try XCTUnwrap(server.seq(table: row.server, key: row.id), "fixture: \(row.table) is on the server")
            XCTAssertEqual(service.baseline.entry(table: row.table, id: row.id)?.seq, seq,
                           "\(row.table): a row the cloud carried is not recorded at its cloud seq")
        }
        let before = server.requests.count

        switchOn()
        for row in offline {
            try await syncEventually("\(row.table): the offline row reached the cloud") {
                self.server.row(table: row.server, key: row.id) != nil
            }
        }
        try await settle()
        let later = writes(after: before)
        // A log and a feedback record of one occurrence share their id, so
        // a write is matched on its table as well as its key.
        func naming(_ row: (table: String, server: String, id: String)) -> [SyncFakeServer.Request] {
            later.filter { $0.table == row.server && $0.keys.contains { $0.lowercased() == row.id.lowercased() } }
        }
        for row in carried {
            XCTAssertEqual(naming(row).map(\.verb), [], "\(row.table): a row the cloud holds as it is was sent again")
        }
        for row in offline {
            XCTAssertEqual(naming(row).map(\.verb), [.insert], "\(row.table): the offline row was not sent exactly once")
        }
    }

    /// A merge restore while a full sync has a never-uploaded row in flight
    /// (its POST sent, the answer not back). The snapshot cannot carry it;
    /// the replay must keep the in-flight mark, so the answer, when it
    /// comes, records the row at the seq the server gave it. Recorded as
    /// clean in its place, the answer is "superseded", the row keeps no
    /// seq, and its next edit goes out as a POST the server ignores.
    func testQA_R2_aMergeRestoreWhileARowIsInFlightLetsItsAnswerRecordTheServerSeq() async throws {
        switchOff()
        let offline = makeEvent("made while uploads were off")
        store.addCalendarEvent(offline)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: nothing left the phone")

        // The switch on: the pass runs the calendar table and its POST is
        // held at the server, before it lands.
        try await parkAPass(on: { verb, table in verb == .insert && table == "events" },
                            startedBy: { self.switchOn() })
        // Whichever sends it — the pass, or the chain's flush at head when
        // the restarted puller's I1 held the pass — the POST is held.
        try await syncEventually("the head flush posted the offline row") {
            self.server.requests(.insert, table: "events").contains { self.names($0, offline.id) }
        }
        XCTAssertNil(onServer(offline), "fixture: the POST has not landed")
        XCTAssertEqual(entry(offline)?.isUnknown, true, "fixture: the row is marked in flight")

        try await restore(.merge)
        XCTAssertEqual(entry(offline)?.isUnknown, true, "the merge overwrote the in-flight mark")

        try await releaseEverything()
        try await syncEventually("the row landed") { self.onServer(offline) != nil }
        let landedSeq = try XCTUnwrap(server.seq(table: "events", key: offline.id.uuidString))
        try await syncEventually("the answer recorded the server seq") { self.entry(offline)?.seq == landedSeq }

        // And it stays live: an edit goes out as a PATCH on that seq.
        var edited = offline
        edited.note = "edited after the restore"
        store.updateCalendarEvent(edited)
        scheduler.advance(by: debounce)
        try await syncEventually("the edit reached the cloud") { self.onServer(offline)?["note"] as? String == "edited after the restore" }
    }

    /// A merge over a cloud that DOES hold the settings row: a key changed
    /// while uploads were off is kept local and sent as a PATCH on the
    /// cloud's seq; nothing else in the row reads changed.
    func testQA_R3_aMergeOverACloudSettingsRowSendsTheKeyItKeptLocalOnTheCloudSeq() async throws {
        server.seed(table: "user_settings", rows: [["user_id": uid, "settings": [AppSettingsKeys.showTimerBanner: false]]])
        await puller.pullToHead()
        XCTAssertEqual(defaults.object(forKey: AppSettingsKeys.showTimerBanner) as? Bool, false, "fixture: the cloud's value was pulled")
        let cloudSeq = try XCTUnwrap(server.seq(table: "user_settings", key: uid))

        switchOff()
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        scheduler.advance(by: SupabaseSyncConfig.settingsDebounceSeconds)
        try await settle()
        XCTAssertTrue(writes().isEmpty, "positive control: nothing left the phone")

        try await restore(.merge)
        XCTAssertEqual(defaults.object(forKey: AppSettingsKeys.showTimerBanner) as? Bool, true, "fixture: keep-local kept the local value")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the kept-local key reached the cloud") {
            (self.server.row(table: "user_settings", key: self.uid)?.data["settings"] as? [String: Any])?[AppSettingsKeys.showTimerBanner] as? Bool == true
        }
        let settingsWrites = writes(after: before).filter { $0.table == "user_settings" }
        XCTAssertEqual(settingsWrites.map(\.verb), [.patch])
        XCTAssertEqual(settingsWrites.first?.baseSeq, cloudSeq, "the kept-local key was not sent on the cloud's version")
    }
}

// MARK: - 1b. The built-in types after a merge

@MainActor
final class SyncMergeRestoreTypesQATests: SyncRestoreAndSwitchQATestCase {

    /// The implementer's note: never-uploaded built-in types now go up
    /// after a merge. Over a cloud whose types all share the seeds' titles
    /// (the account's own colours), the merge keeps the seeds locally (keep
    /// local, by title) and records nothing for them, so the event_types
    /// baseline stays empty and the first pull drops the seeds for the
    /// account's types (`dropUnconfirmedSeeds`): the account's colours
    /// stand everywhere and no seed is sent. Before the fix the replay
    /// recorded the seeds as uploaded, the baseline was not empty, and the
    /// namesake rule decided each title by UUID — the account's type
    /// tombstoned about half the time.
    func testQA_R4_aMergeOverTheAccountsNamesakesOfTheSeedsKeepsTheAccountsTypes() async throws {
        let seeds = device.types.templates
        XCTAssertFalse(seeds.isEmpty)
        XCTAssertTrue(seeds.allSatisfy(EventTypeCatalog.isBuiltInSeed), "fixture: the catalog is the built-in seeds")
        XCTAssertTrue(service.baseline.entries(table: "event_types").isEmpty, "fixture: no type was ever sent")
        let account = seeds.map { EventTypeTemplate(title: $0.title, colorHex: "#123456") }

        switchOff()
        server.seed(table: "event_types", rows: account.map(service.eventTypeToRow))
        let offline = makeEvent("made while uploads were off")
        store.addCalendarEvent(offline)
        scheduler.advance(by: debounce)
        try await settle()

        try await restore(.merge)
        XCTAssertEqual(Set(device.types.templates.map(\.id)), Set(seeds.map(\.id)), "fixture: keep-local kept the seeds")
        let before = server.requests.count

        switchOn()
        try await syncEventually("the offline row reached the cloud") { self.onServer(offline) != nil }
        try await settle()
        for type in account {
            XCTAssertFalse(server.isTombstoned(table: "event_types", key: type.id.uuidString), "\(type.title): the account's type was tombstoned")
            XCTAssertEqual(server.row(table: "event_types", key: type.id.uuidString)?.data["color_hex"] as? String, "#123456")
        }
        let seedIds = Set(seeds.map { $0.id.uuidString.lowercased() })
        XCTAssertFalse(writes(after: before).contains { $0.table == "event_types" && $0.keys.contains { seedIds.contains($0.lowercased()) } },
                       "a seed was sent over the account's namesake")
        XCTAssertEqual(Set(device.types.templates.map(\.id)), Set(account.map(\.id)), "the device does not hold the account's types")
    }
}

// MARK: - 2. The switch during a full sync

@MainActor
final class SyncSwitchFullSyncQATests: SyncRestoreAndSwitchQATestCase {

    private static let parkOnSkills: (SyncFakeServer.Verb, String) -> Bool = { verb, table in
        verb == .insert && table == "skill_insights"
    }

    /// A pass that really sends — started by a token refresh with the
    /// puller at head (`$session` re-publishing) — parked on its skills
    /// POST. The calendar table is behind it.
    private func parkARefreshPass() async throws {
        device.skills.add(makeSkill("parks the pass \(UUID().uuidString)"))
        try await parkAPass(on: Self.parkOnSkills, startedBy: { await self.device.auth.forceRefreshToken() })
    }

    /// Ten flips while a pass is parked, an edit between each: one pass at
    /// a time, the puller following the switch, every edit on the server
    /// at the end, and no row written twice.
    func testQA_S1_tenFlipsWithAnEditBetweenEach_onePassAtATime_everyEditSentOnce() async throws {
        try await parkARefreshPass()
        var edits: [Event] = []
        var skillsMadeOff: [SkillInsight] = []
        for i in 0..<10 {
            if i.isMultiple(of: 2) { switchOff() } else { switchOn() }
            let on = !i.isMultiple(of: 2)
            let edit = makeEvent("flip \(i) \(on ? "on" : "off")")
            store.addCalendarEvent(edit)
            edits.append(edit)
            if !on {
                let skill = makeSkill("skill while off \(i)")
                device.skills.add(skill)
                skillsMadeOff.append(skill)
            }
            scheduler.advance(by: debounce)
            try await settle()
            XCTAssertLessThanOrEqual(server.heldCount, 1, "flip \(i): a second pass started beside the parked one")
            XCTAssertEqual(puller.active, on, "flip \(i): the puller does not follow the switch")
        }
        XCTAssertTrue(service.canUpload, "fixture: the switch ended on")

        try await releaseEverything()
        for edit in edits {
            try await syncEventually("\(edit.title) reached the cloud") { self.onServer(edit) != nil }
        }
        for skill in skillsMadeOff {
            try await syncEventually("\(skill.skillName) reached the cloud") {
                self.server.row(table: "skill_insights", key: skill.id.uuidString) != nil
            }
        }
        try await settle()
        for edit in edits {
            let inserts = server.requests(.insert, table: "events").filter { names($0, edit.id) }
            XCTAssertEqual(inserts.count, 1, "\(edit.title) was POSTed \(inserts.count) times")
            XCTAssertEqual(server.versions(table: "events", key: edit.id.uuidString).count, 1, "\(edit.title) was written twice")
        }
        XCTAssertTrue(puller.active)
    }

    /// The end-of-pass flush against a puller not yet at head: the switch
    /// flipped off and on during the pass restarts the puller, whose launch
    /// pull is held. An edit delivered during the pass is owed; another
    /// device edits the same row meanwhile. Nothing names the row until the
    /// pull lands, and no version is written over the other device's
    /// without it as parent (the live-array race, `sync.flush.live`).
    func testQA_S2_theEndOfPassFlushWaitsForThePullerAndNeverOverwritesALaterRemoteEditUnseen() async throws {
        let shared = makeEvent("shared", note: "v1")
        server.seed(table: "events", rows: [row(shared)])
        await puller.pullToHead()
        XCTAssertNotNil(entry(shared)?.seq, "fixture: the device holds the row")

        try await parkARefreshPass()
        server.holdWhen = { verb, table in Self.parkOnSkills(verb, table) || verb == .pull }
        switchOff()
        switchOn()
        try await syncEventually("the restarted puller's pull is held") { self.server.heldCount == 2 }
        XCTAssertFalse(service.inboundAtHead, "fixture: I1 closed by the restart")

        var mine = shared
        mine.note = "mine"
        store.updateCalendarEvent(mine)
        scheduler.advance(by: debounce)
        try await settle()
        let theirsSeq = server.writeDirectly(table: "events", key: shared.id.uuidString, data: ["note": "theirs"])
        let theirsVersion = try XCTUnwrap(server.versionId(table: "events", key: shared.id.uuidString))
        let before = server.requests.count

        server.release(count: 1)                       // the skills POST: the pass (and its rerun) end
        try await syncEventually("the parked skill landed") {
            self.server.requests(.insert, table: "skill_insights").count >= 1 && self.server.heldCount == 1
        }
        try await settle()
        try await settle()
        XCTAssertFalse(writes(after: before).contains { names($0, shared.id) },
                       "the end-of-pass flush wrote the row before the puller reached head")

        try await releaseEverything()
        try await syncEventually("the puller reached head") { self.service.inboundAtHead }
        try await settle()
        let later = server.versions(table: "events", key: shared.id.uuidString).filter { $0.seq > theirsSeq }
        XCTAssertTrue(later.allSatisfy { $0.parentVersionId == theirsVersion },
                      "a version was written over the other device's edit without it as parent")
        let kept = (onServer(shared)?["note"] as? String) == "theirs"
            || shelved(shared.id).contains { $0.row["note"] as? String == "theirs" }
        XCTAssertTrue(kept, "the other device's edit is neither on the server nor on the shelf")
    }

    /// An erase during a pass, in the eraser's order: the switch off first
    /// (no `userDidDisableUploads`: the eraser writes the default), the
    /// stores emptied, the session ended. Nothing is written after it — no
    /// tombstone for the emptied stores, no row — when the parked request
    /// is answered and the deliveries fire.
    func testQA_S3_anEraseDuringAPassWritesNothingAfterIt() async throws {
        let kept = makeEvent("on the server")
        server.seed(table: "events", rows: [row(kept)])
        await puller.pullToHead()
        try await parkARefreshPass()
        let before = writeCount()

        defaults.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)
        store.clearAllLocalData()
        device.skills.clearAll()
        device.types.resetToDefaults()
        device.auth.signOut()
        scheduler.advance(by: SupabaseSyncConfig.settingsDebounceSeconds + debounce)
        try await settle()

        try await releaseEverything()
        scheduler.advance(by: SupabaseSyncConfig.settingsDebounceSeconds + debounce)
        try await settle()
        XCTAssertEqual(writes().dropFirst(before).map { "\($0.verb) \($0.table)" }, [],
                       "a write went out after the erase")
        XCTAssertFalse(server.isTombstoned(table: "events", key: kept.id.uuidString))
    }

    /// The in-flight flag never sticks: after a pass ends by the switch,
    /// by a sign-out, or by running to its end, the next start runs a pass
    /// that sends an edit made while the switch was off.
    func testQA_S4_afterEveryWayAPassEnds_theNextSwitchOnRunsAPass() async throws {
        // 1. Ended by the switch.
        try await parkARefreshPass()
        switchOff()
        try await releaseEverything()
        let afterSwitch = makeEvent("after a pass the switch ended")
        store.addCalendarEvent(afterSwitch)
        scheduler.advance(by: debounce)
        try await settle()
        switchOn()
        try await syncEventually("sent after a pass the switch ended") { self.onServer(afterSwitch) != nil }

        // 2. Ended by a sign-out (and a sign-in after it ended).
        try await parkARefreshPass()
        device.auth.signOut()
        try await releaseEverything()
        XCTAssertTrue(device.auth.adoptInjectedSessionIfPresent(launchEnvironment: ["SYNC_DEBUG_SESSION": sessionJSON()],
                                                                syncEnvironment: .local), "fixture: signed in again")
        try await syncEventually("the puller reached head after the sign-in") { self.puller.active && self.service.inboundAtHead }
        switchOff()
        let afterSignOut = makeEvent("after a pass a sign-out ended")
        store.addCalendarEvent(afterSignOut)
        scheduler.advance(by: debounce)
        try await settle()
        switchOn()
        try await syncEventually("sent after a pass a sign-out ended") { self.onServer(afterSignOut) != nil }

        // 3. Ran to its end.
        try await parkARefreshPass()
        try await releaseEverything()
        switchOff()
        let afterEnd = makeEvent("after a pass that ran to its end")
        store.addCalendarEvent(afterEnd)
        scheduler.advance(by: debounce)
        try await settle()
        switchOn()
        try await syncEventually("sent after a pass that ran to its end") { self.onServer(afterEnd) != nil }
    }

    /// Sign-out and sign-in of the same account while a pass is in flight.
    /// A delivery while signed out is dropped (no session to owe it to), and
    /// the pass had already read the calendar table, so only a rerun sends
    /// the edit made while signed out: the session the sign-in begins owes
    /// one (`beginSession`), and the sign-in's own full sync is refused while
    /// the pass runs. (Up to 90141d28 nothing owed that rerun and the edit
    /// waited for its table's next edit or the next launch; fixed in
    /// 1972163d.)
    func testQA_S5_anEditMadeWhileSignedOutDuringAPassIsSentAfterTheSameAccountSignsBackIn() async throws {
        try await parkARefreshPass()
        device.auth.signOut()
        let signedOut = makeEvent("made while signed out")
        store.addCalendarEvent(signedOut)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(device.auth.adoptInjectedSessionIfPresent(launchEnvironment: ["SYNC_DEBUG_SESSION": sessionJSON()],
                                                                syncEnvironment: .local), "fixture: signed in again")
        try await releaseEverything()
        try await syncEventually("the puller reached head after the sign-in") { self.puller.active && self.service.inboundAtHead }
        try await syncEventually("the edit made while signed out reached the cloud") { self.onServer(signedOut) != nil }
    }

    /// The surviving mutant (the pass ignores the switch at table
    /// boundaries). The switch off while the pass is parked on its calendar
    /// POST: nothing is built for the four id tables after it. The mutant
    /// builds every one of them on the main thread and has `flushGate`
    /// refuse each.
    func testQA_S6_aPassTheSwitchStoppedBuildsNothingForTheTablesAfterIt() async throws {
        store.calendarEventLogRecords.append(makeLog(for: makeEvent("logged")))
        store.addList(TodoList(title: "a list", colorName: "green", createdAt: Self.t0))
        device.skills.add(makeSkill("a skill"))
        let parked = makeEvent("parks the pass on the calendar table")
        store.addCalendarEvent(parked)
        let displaced = FollowerTiming.recorder
        let recorder = FollowerTimingRecorder()
        FollowerTiming.recorder = recorder
        defer { FollowerTiming.recorder = displaced }

        try await parkAPass(on: { verb, table in verb == .insert && table == "events" },
                            startedBy: { await self.device.auth.forceRefreshToken() })
        let atPark = recorder.dailySnapshot()
        XCTAssertEqual(atPark[.syncLogsBuild].count, 0, "fixture: parked before the logs table")
        XCTAssertEqual(atPark[.syncCalendarBuild].count, 1, "fixture: parked in the calendar table")
        switchOff()
        try await releaseEverything()

        // The todo table (charged to `other`) was built before the park.
        let day = recorder.dailySnapshot()
        XCTAssertEqual(day[.syncLogsBuild].count, 0, "the pass built the logs table with the switch off")
        XCTAssertEqual(day[.syncFeedbackBuild].count, 0, "the pass built the feedback table with the switch off")
        XCTAssertEqual(day[.syncOtherBuild].count, atPark[.syncOtherBuild].count,
                       "the pass built todo lists / skills with the switch off")

        // Positive control: on again, the next pass builds them.
        switchOn()
        try await syncEventually("the next pass built the logs table") { recorder.dailySnapshot()[.syncLogsBuild].count > 0 }
    }

    /// "Rerun once" ends: the switch on during a pass owes one more run,
    /// and after it the engine is out of the pass — a later delivery goes
    /// straight to its flush instead of being owed to a pass that never
    /// ends (each pass re-arming the rerun would keep the flag up and every
    /// delivery owed, with a full pass of hashing per turn of the loop).
    func testQA_S7_thePassAndItsOneRerunEnd_aLaterDeliveryIsNotOwedToAPass() async throws {
        let displaced = FollowerTiming.recorder
        let recorder = FollowerTimingRecorder()
        FollowerTiming.recorder = recorder
        defer { FollowerTiming.recorder = displaced }
        try await parkARefreshPass()
        switchOff()
        switchOn()
        try await releaseEverything()
        try await syncEventually("the restarted puller reached head") { self.service.inboundAtHead }
        try await settle()
        let calendarBuilds = recorder.dailySnapshot()[.syncCalendarBuild].count
        try await settle()
        try await settle()
        XCTAssertEqual(recorder.dailySnapshot()[.syncCalendarBuild].count, calendarBuilds,
                       "passes keep running after the one rerun")

        let later = makeEvent("after the rerun")
        store.addCalendarEvent(later)
        scheduler.advance(by: debounce)
        XCTAssertFalse(service.needsFlush.contains("calendar_events"), "a delivery after the rerun was owed to a pass")
        try await syncEventually("the later edit reached the cloud") { self.onServer(later) != nil }
    }

    /// A token refresh while the switch is off during a pass runs the
    /// session sink's `!canUpload` branch. With the switch back on, a
    /// delivery to the row the pass has in flight is owed to the pass, not
    /// sent beside the pass's own POST of it (up to 90141d28 that branch
    /// marked the full sync done while the pass ran, and the row was POSTed
    /// twice; fixed in 1972163d). The edit ends on the server, nothing is
    /// shelved or lost for it.
    func testQA_S8_aRefreshWithTheSwitchOffDuringAPass_thenAnEditToTheRowInFlight_stillLands() async throws {
        let inFlight = makeEvent("in flight", note: "v1")
        store.addCalendarEvent(inFlight)
        try await parkAPass(on: { verb, table in verb == .insert && table == "events" },
                            startedBy: { await self.device.auth.forceRefreshToken() })
        XCTAssertTrue(server.requests(.insert, table: "events").contains { names($0, inFlight.id) }, "fixture: the pass sent the row")
        switchOff()
        await device.auth.forceRefreshToken()
        switchOn()
        try await syncEventually("the restarted puller reached head") { self.service.inboundAtHead }
        var edited = inFlight
        edited.note = "v2"
        store.updateCalendarEvent(edited)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(service.needsFlush.contains("calendar_events"), "the delivery was not owed to the running pass")
        XCTAssertEqual(server.requests(.insert, table: "events").filter { names($0, inFlight.id) }.count, 1,
                       "the delivery sent the row beside the pass")

        try await releaseEverything()
        try await syncEventually("the edit reached the cloud") { self.onServer(inFlight)?["note"] as? String == "v2" }
        try await settle()
        XCTAssertEqual(shelved(inFlight.id).count, 0, "the device's own edit was shelved")
        XCTAssertEqual(store.rawCalendarEvents.first { $0.id == inFlight.id }?.note, "v2", "the edit was lost locally")
    }

    private func sessionJSON() -> String {
        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        return #"{"access_token":"at-again","refresh_token":"r-again","user_id":"\#(uid)","email":"switch@example.com","expires_at":\#(expiresAt)}"#
    }
}

// MARK: - 2b. The session changing during a full sync (round 2, 1972163d)

@MainActor
final class SyncSessionDuringFullSyncQATests: SyncRestoreAndSwitchQATestCase {
    private let uidB = "66666666-7777-4888-8999-aaaaaaaaaaaa"

    private func trailLines(_ text: String) -> Int {
        DiagnosticTrail.combinedText().split(separator: "\n").filter { $0.contains(text) }.count
    }

    /// A phone whose one gateway points at whichever account's cloud is
    /// signed in, switch on, puller at head as A.
    private func twoAccountPhone() async -> (phone: SyncSwitchTestDevice, cloudA: SyncFakeServer, cloudB: SyncFakeServer, router: SyncAccountRouter) {
        let cloudA = SyncFakeServer(userId: uid), cloudB = SyncFakeServer(userId: uidB)
        let router = SyncAccountRouter(cloudA)
        let phone = SyncSwitchTestDevice(server: cloudA, gateway: router, uid: uid, start: Self.t0, switchOnAtAttach: false)
        phone.defaults.set(true, forKey: AppSettingsKeys.syncUploadsEnabled)
        phone.puller.beginSession(autoPull: false)
        await phone.puller.pullToHead()
        return (phone, cloudA, cloudB, router)
    }

    private func writes(_ server: SyncFakeServer) -> [SyncFakeServer.Request] {
        server.requests.filter { Self.writeVerbs.contains($0.verb) }
    }

    /// Another account signs in while A's pass is parked on its calendar
    /// POST, and A's unsent data blocks it (no switch). A's pass stops at its
    /// next table instead of reading A's lists, skills and settings for B;
    /// the rerun the new session is owed runs for B and every table is
    /// refused by the owner guard: B's cloud is never written, and A's cloud
    /// gets nothing after the switch beyond the request already parked.
    func testQA_T1_anotherAccountBlockedByAsDataSignsInDuringAsPass_nothingReachesEitherCloud() async throws {
        let (phone, cloudA, cloudB, router) = await twoAccountPhone()
        defer {
            cloudA.holdWhen = nil
            cloudA.releaseAll()
            phone.tearDown()
        }
        let rowA = makeEvent("A's calendar row")
        phone.store.addCalendarEvent(rowA)
        phone.store.addList(TodoList(title: "A's list", colorName: "green", createdAt: Self.t0))
        phone.skills.add(makeSkill("A's skill"))
        cloudA.holdWhen = { verb, table in verb == .insert && table == "events" }
        phone.service.userDidEnableUploads()
        try await syncEventually("A's pass is parked on its calendar POST") { cloudA.heldCount == 1 }
        DiagnosticTrail.clear()
        let requestsToA = cloudA.requests.count

        phone.auth.signOut()
        router.current = cloudB
        XCTAssertTrue(phone.signIn(uidB), "fixture: B signed in")
        guard case .blocked = phone.service.ownerState else {
            return XCTFail("fixture: A's unsent rows block B, got \(phone.service.ownerState)")
        }
        let madeUnderB = makeEvent("made in B's session")
        phone.store.addCalendarEvent(madeUnderB)
        phone.scheduler.advance(by: debounce)
        cloudA.holdWhen = nil
        cloudA.releaseAll()
        try await syncEventually("A's pass stopped for the account change") {
            self.trailLines("sync.fullsync.stopped reason=account_changed") == 1
        }
        try await settle()
        try await settle()

        XCTAssertEqual(writes(cloudB).map { "\($0.verb) \($0.table)" }, [], "B's cloud was written while A's data blocks it")
        XCTAssertEqual(cloudA.requests.count, requestsToA, "A's cloud was written after the switch")
        XCTAssertNil(cloudA.row(table: "todo_lists", key: phone.store.todoLists.first?.id.uuidString ?? "-"),
                     "A's pass read on into its lists after the switch")
    }

    /// A → B → A while A's pass is parked: signed out, an edit made (its
    /// delivery fires with no session), B signs in (blocked), signs out, A
    /// signs back in. A's pass reads on for A, the rerun the sign-ins owed
    /// sends the edit to A's cloud, B's cloud is never written, and the
    /// engine leaves the pass: a later delivery is not owed to one.
    func testQA_T2_aToBToAWhileAsPassIsParked_theSignedOutEditReachesA_bIsNeverWritten_thePassEnds() async throws {
        let (phone, cloudA, cloudB, router) = await twoAccountPhone()
        defer {
            cloudA.holdWhen = nil
            cloudA.releaseAll()
            phone.tearDown()
        }
        phone.skills.add(makeSkill("parks A's pass"))
        cloudA.holdWhen = { verb, table in verb == .insert && table == "skill_insights" }
        phone.service.userDidEnableUploads()
        try await syncEventually("A's pass is parked on skills") { cloudA.heldCount == 1 }

        phone.auth.signOut()
        let signedOut = makeEvent("made while signed out")
        phone.store.addCalendarEvent(signedOut)
        phone.scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(phone.service.needsFlush.isEmpty, "positive control: nothing owes the edit")
        router.current = cloudB
        XCTAssertTrue(phone.signIn(uidB), "fixture: B signed in")
        phone.auth.signOut()
        router.current = cloudA
        XCTAssertTrue(phone.signIn(uid), "fixture: A signed in again")
        XCTAssertEqual(phone.service.ownerState, .active(uid: uid))

        cloudA.holdWhen = nil
        cloudA.releaseAll()
        try await syncEventually("the edit made while signed out reached A's cloud") {
            cloudA.row(table: "events", key: signedOut.id.uuidString) != nil
        }
        try await settle()
        XCTAssertEqual(writes(cloudB).map { "\($0.verb) \($0.table)" }, [], "B's cloud was written")
        XCTAssertEqual(Set(writes(cloudA).compactMap { ($0.body as? [[String: Any]])?.first?["user_id"] as? String }), [uid])

        let later = makeEvent("after it all")
        phone.store.addCalendarEvent(later)
        phone.scheduler.advance(by: debounce)
        XCTAssertFalse(phone.service.needsFlush.contains("calendar_events"), "a delivery after the rerun was owed to a pass that never ended")
        try await syncEventually("the later edit reached A's cloud") { cloudA.row(table: "events", key: later.id.uuidString) != nil }
    }

    /// The switch and the session together: the switch off, signed out, an
    /// edit, then an interactive sign-in (which turns the switch on without
    /// `userDidEnableUploads`), all while a pass is parked. The puller runs
    /// again and the edit is sent.
    func testQA_T3_switchOffThenSignOutThenAnInteractiveSignInDuringAPass_thePullerRuns_andTheEditIsSent() async throws {
        device.skills.add(makeSkill("parks the pass"))
        try await parkAPass(on: { verb, table in verb == .insert && table == "skill_insights" },
                            startedBy: { await self.device.auth.forceRefreshToken() })
        switchOff()
        device.auth.signOut()
        let edit = makeEvent("made with the switch off, signed out")
        store.addCalendarEvent(edit)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(device.signIn(uid), "fixture: signed in")
        XCTAssertTrue(service.canUpload, "fixture: an interactive sign-in turns the switch on")
        XCTAssertTrue(puller.active, "signed in with the switch on and nothing pulls")
        try await releaseEverything()
        try await syncEventually("the edit reached the cloud") { self.onServer(edit) != nil }
    }

    /// A token refresh during a pass owes no second pass, and loses nothing:
    /// an edit delivered during the pass to a table it has passed is sent
    /// once, when the pass ends.
    func testQA_T4_aRefreshDuringAPassOwesNoRerun_butAnEditDeliveredMeanwhileIsSentOnce() async throws {
        let displaced = FollowerTiming.recorder
        let recorder = FollowerTimingRecorder()
        FollowerTiming.recorder = recorder
        defer { FollowerTiming.recorder = displaced }
        device.skills.add(makeSkill("parks the pass"))
        try await parkAPass(on: { verb, table in verb == .insert && table == "skill_insights" },
                            startedBy: { self.service.userDidEnableUploads() })
        XCTAssertEqual(recorder.dailySnapshot()[.syncLogsBuild].count, 1, "fixture: the pass read the logs table once")
        await device.auth.forceRefreshToken()
        let edit = makeEvent("delivered during the pass")
        store.addCalendarEvent(edit)
        scheduler.advance(by: debounce)
        try await settle()
        XCTAssertTrue(service.needsFlush.contains("calendar_events"), "fixture: the delivery is owed to the pass")
        try await releaseEverything()
        try await syncEventually("the edit reached the cloud") { self.onServer(edit) != nil }
        try await settle()
        XCTAssertEqual(server.requests(.insert, table: "events").filter { names($0, edit.id) }.count, 1)
        XCTAssertEqual(recorder.dailySnapshot()[.syncLogsBuild].count, 1, "the refresh ran a second pass")
    }
}

// MARK: - 3. Main-thread cost of the replay

/// The replay runs on the main actor in the restore's apply tick. Measured
/// at the production account's size (14,532 rows on 2026-10-22). The
/// overwrite branch of `replayBaseline` is the replay as it was before the
/// fix for every strategy (cloud hash at the cloud seq where the snapshot
/// has one, the local hash otherwise), so timing the merge against the
/// overwrite over the same rows is the before/after comparison, the
/// baseline persist included.
@MainActor
final class SyncRestoreReplayCostQATests: XCTestCase {
    private let uid = "55555555-6666-4777-8888-999999999999"
    private var suite = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!

    override func setUp() async throws {
        try await super.setUp()
        suite = "SyncRestoreReplayCostQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server.connection(), userId: uid, defaults: defaults,
                                      scheduler: SyncManualScheduler(start: Date(timeIntervalSince1970: 1_780_000_000)),
                                      environment: .local)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func events(_ n: Int) -> [Event] {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        return (0..<n).map { i in
            Event(title: "event \(i)", note: "local note \(i)",
                  timeRanges: [.init(start: t0.addingTimeInterval(Double(i) * 3600), end: t0.addingTimeInterval(Double(i) * 3600 + 1800))],
                  createdAt: t0)
        }
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    /// Median of five runs of the replay over `local`, with `snapshot`.
    private func replayTime(_ local: [Event], _ snapshot: RestoreSnapshot, _ strategy: RestoreStrategy) -> Double {
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<5 {
            service.baseline.replaceEntries(table: "calendar_events", with: [:])
            times.append(ms(clock.measure {
                service.markRestoreCompleted(todoEvents: [], calendarEvents: local, logs: [], feedback: [], todoLists: [],
                                             eventTypes: [], skills: [], snapshot: snapshot, strategy: strategy)
            }))
        }
        return median(times)
    }

    func testQA_C1_theMergeReplayAtProductionSizeCostsNoMoreThanTheReplayBeforeTheFix() {
        let n = 14_532
        let local = events(n)
        let cases: [(name: String, carried: Int, seqs: Bool)] = [
            ("015, every row carried", n, true),
            ("015, a fifth never uploaded", n * 4 / 5, true),
            ("before 015, every row carried", n, false),
        ]
        for c in cases {
            var cloud = Array(local.prefix(c.carried))
            // Every other carried row differs from the local copy (kept local).
            for i in stride(from: 0, to: cloud.count, by: 2) { cloud[i].note = "cloud note \(i)" }
            var snapshot = RestoreSnapshot.empty
            snapshot.calendarEvents = cloud
            if c.seqs {
                for (i, e) in cloud.enumerated() {
                    snapshot.cloudSeqs[SyncBaselineKey(table: "calendar_events", id: e.id.uuidString)] = Int64(i + 1)
                }
            }
            let merge = replayTime(local, snapshot, .merge)
            let before = replayTime(local, snapshot, .cloudOverwritesLocal)
            print(String(format: "QA-COST replay rows=%d %@: merge (fix) %.1f ms, the pre-fix replay %.1f ms, ratio %.2f",
                         n, c.name, merge, before, merge / before))
            // Loose on purpose (CPU contention in a full run): a gross
            // regression, not a ratio, is what this holds.
            XCTAssertLessThan(merge, before * 2 + 50, "\(c.name): the merge replay costs far more than the replay before the fix")
        }
    }
}
