//
//  SyncRestoreKeepLocalDeletesPreviewQATests.swift
//  DoneTests
//
//  Independent QA for fix/restore-keep-local-deletes: what the merge review
//  counts against what the apply then does, and when the review is shown.
//  Uses the fix's `MergePreview.keptDeleted`, so this file is fix-only (the
//  behaviour tests that also run on king are SyncRestoreKeepLocalDeletesQATests).
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreKeepLocalDeletesPreviewQATests: SyncRestoreKeepLocalDeletesTestCase {

    /// The device's own rows (its default event types) uploaded, as the
    /// app's first full sync does, so a merge with nothing to do is a no-op
    /// here as it is in the app.
    private func fullSync() async throws {
        switchOff()
        switchOn()
        let types = device.types.templates
        try await syncEventually("the device's types are on the server", timeout: 5) {
            types.allSatisfy { self.server.row(table: "event_types", key: $0.id.uuidString) != nil }
        }
        try await settle()
        await puller.pullToHead()
        try await settle()
    }

    private func applyLines() -> [String] {
        trailLines("restore APPLY strategy=merge")
    }

    private func keptDeletedInTrail() -> Int? {
        guard let line = applyLines().last, let r = line.range(of: "keptDeleted=") else { return nil }
        return Int(line[r.upperBound...].prefix { $0.isNumber })
    }

    /// Every table deleted here, plus a cloud-only row (add), a local-only
    /// row (keep) and a conflict. What the review counts is what the apply
    /// does: the adds it shows are the rows the apply adds, the rows it says
    /// stay deleted are the ones the apply leaves out (and the trail's
    /// count), and nothing else changes on the device.
    func testThePreviewsCountsAreWhatTheApplyDoes() async throws {
        let fixture = try await seedEveryTable()
        let k = makeEvent("K, conflict", note: "v1")
        server.seed(table: "events", rows: [row(k)])
        await puller.pullToHead()
        var mine = try XCTUnwrap(local(k.id))
        mine.note = "mine"
        store.updateCalendarEvent(mine)
        deleteOnDevice(fixture)
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        let l = makeEvent("L, only here")
        store.addCalendarEvent(l)   // the debounce is not advanced: it stays local-only

        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview(_, let preview) = c.phase else { return XCTFail("fixture: reviewed, got \(c.phase)") }
        XCTAssertEqual(preview.addsFromCloud.totalCount, 1, "only Y is an add")
        XCTAssertEqual(preview.addsFromCloud.calendarEvents, 1)
        XCTAssertEqual(preview.keepsLocalOnly.calendarEvents, 1, "L is local-only")
        XCTAssertEqual(preview.conflicts.calendarEvents, [k.id])
        XCTAssertEqual(preview.keptDeleted.totalCount, fixture.deleted.count)

        let calBefore = store.rawCalendarEvents.count, todoBefore = store.events.count
        let logsBefore = store.calendarEventLogRecords.count, fbBefore = store.calendarEventFeedbackRecords.count
        let listsBefore = store.todoLists.count, typesBefore = device.types.templates.count, skillsBefore = device.skills.insights.count
        DiagnosticTrail.clear()
        await c.applyMerge(resolution: .keepCloud)
        guard case .finished(let summary, _, _) = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }

        XCTAssertEqual(summary.addedCalendarEvents, preview.addsFromCloud.calendarEvents)
        XCTAssertEqual(summary.addedTodoEvents, preview.addsFromCloud.todoEvents)
        XCTAssertEqual(summary.addedLogs, preview.addsFromCloud.logs)
        XCTAssertEqual(summary.addedFeedback, preview.addsFromCloud.feedback)
        XCTAssertEqual(summary.addedLists, preview.addsFromCloud.todoLists)
        XCTAssertEqual(summary.addedTypes, preview.addsFromCloud.eventTypes)
        XCTAssertEqual(summary.addedSkills, preview.addsFromCloud.skills)
        XCTAssertEqual(keptDeletedInTrail(), preview.keptDeleted.totalCount, applyLines().joined(separator: "\n"))
        XCTAssertEqual(store.rawCalendarEvents.count, calBefore + preview.addsFromCloud.calendarEvents)
        XCTAssertEqual(store.events.count, todoBefore + preview.addsFromCloud.todoEvents)
        XCTAssertEqual(store.calendarEventLogRecords.count, logsBefore + preview.addsFromCloud.logs)
        XCTAssertEqual(store.calendarEventFeedbackRecords.count, fbBefore + preview.addsFromCloud.feedback)
        XCTAssertEqual(store.todoLists.count, listsBefore + preview.addsFromCloud.todoLists)
        XCTAssertEqual(device.types.templates.count, typesBefore + preview.addsFromCloud.eventTypes)
        XCTAssertEqual(device.skills.insights.count, skillsBefore + preview.addsFromCloud.skills)
        XCTAssertEqual(local(k.id)?.note, "v1", "positive control: keep-cloud resolved K")
        XCTAssertNotNil(local(l.id), "the local-only row was dropped")
    }

    /// A merge whose one effect would be keeping a delete is shown for
    /// review (nothing to resolve, add or keep; the one line about the
    /// delete), and Apply then finishes without changing the device.
    func testAMergeThatOnlyKeepsADeleteIsReviewed_andApplyChangesNothing() async throws {
        try await fullSync()
        let x = makeEvent("X")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview(_, let p) = c.phase else { return XCTFail("a merge that keeps a delete was applied silently: \(c.phase)") }
        XCTAssertTrue(p.conflicts.isEmpty)
        XCTAssertEqual(p.addsFromCloud.totalCount, 0)
        XCTAssertEqual(p.keepsLocalOnly.totalCount, 0)
        XCTAssertEqual(p.keptDeleted.totalCount, 1)
        XCTAssertEqual(p.keptDeleted.calendarEvents, 1)
        let before = store.rawCalendarEvents.map(\.id)
        await c.applyMerge(resolution: .keepLocal)
        guard case .finished = c.phase else { return XCTFail("the restore did not finish: \(c.phase)") }
        XCTAssertEqual(store.rawCalendarEvents.map(\.id), before)
    }

    /// Control: nothing deleted, nothing different — the merge is still a
    /// silent no-op (no review).
    func testControl_aMergeWithNothingToDoIsStillAppliedWithoutAReview() async throws {
        try await fullSync()
        let x = makeEvent("X")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .finished = c.phase else { return XCTFail("a no-op merge was reviewed: \(c.phase)") }
    }

    /// One calendar event deleted by the user is counted with the log and
    /// the feedback its delete pruned: the review says 3 rows.
    func testOneDeletedEventIsCountedWithItsCascadedLogAndFeedback() async throws {
        let e = makeEvent("E")
        let log = makeLog(for: e), fb = makeFeedback(for: e)
        server.seed(table: "events", rows: [row(e)])
        server.seed(table: "event_logs", rows: [service.logToRow(log)])
        server.seed(table: "event_feedback", rows: [service.feedbackToRow(fb)])
        await puller.pullToHead()
        store.deleteCalendarEvent(try XCTUnwrap(local(e.id)), unlinkAssets: false)
        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview(_, let p) = c.phase else { return XCTFail("not reviewed: \(c.phase)") }
        XCTAssertEqual(p.keptDeleted.calendarEvents, 1)
        XCTAssertEqual(p.keptDeleted.logs, 1)
        XCTAssertEqual(p.keptDeleted.feedback, 1)
        XCTAssertEqual(p.keptDeleted.totalCount, 3)
    }

    /// A delete made during the review is not in the review's count (it was
    /// computed before), but the apply keeps it and the trail counts it.
    func testADeleteDuringTheReviewIsCountedByTheApplyNotByTheReview() async throws {
        let x = makeEvent("X")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        let c = coordinator()
        await c.startFetch()
        await c.prepareMerge()
        guard case .mergeReview(_, let p) = c.phase else { return XCTFail("not reviewed: \(c.phase)") }
        XCTAssertEqual(p.keptDeleted.totalCount, 0)
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        DiagnosticTrail.clear()
        await c.applyMerge(resolution: .keepLocal)
        XCTAssertNil(local(x.id))
        XCTAssertEqual(keptDeletedInTrail(), 1)
    }

    /// A pending delete the cloud no longer holds is not counted (there is
    /// nothing to leave out), and alone it leaves the merge a silent no-op.
    func testAPendingDeleteTheCloudNoLongerHoldsIsNotCounted() async throws {
        try await fullSync()
        let x = makeEvent("X")
        server.seed(table: "events", rows: [row(x)])
        await puller.pullToHead()
        _ = server.tombstoneDirectly(table: "events", key: x.id.uuidString)
        store.deleteCalendarEvent(try XCTUnwrap(local(x.id)), unlinkAssets: false)
        let c = coordinator()
        await c.startFetch()
        DiagnosticTrail.clear()
        await c.prepareMerge()
        guard case .finished = c.phase else { return XCTFail("reviewed with nothing to show: \(c.phase)") }
        XCTAssertEqual(keptDeletedInTrail(), 0)
    }
}
