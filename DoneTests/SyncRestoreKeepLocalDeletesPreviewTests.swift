//
//  SyncRestoreKeepLocalDeletesPreviewTests.swift
//  DoneTests
//
//  What the merge review shows, and what the trail records, for rows this
//  device deleted whose delete had not reached the cloud
//  (fix/restore-keep-local-deletes; the behaviour itself is
//  SyncRestoreKeepLocalDeletesTests). The merge leaves those rows out, so
//  the preview must not count them as "added from cloud"; it counts them as
//  kept deleted, and the review says how many.
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreKeepLocalDeletesPreviewTests: SyncRestoreKeepLocalDeletesTestCase {

    private func preview(_ c: RestoreCoordinator) async throws -> MergePreview {
        await c.startFetch()
        guard case .ready = c.phase else { throw FixtureFailure(description: "the fetch did not finish: \(c.phase)") }
        await c.prepareMerge()
        guard case .mergeReview(_, let preview) = c.phase else {
            throw FixtureFailure(description: "the merge was not reviewed: \(c.phase)")
        }
        return preview
    }

    /// Every table's deleted row is counted as kept deleted and none as an
    /// add. A cloud row the device never had (Y) is still an add.
    func testThePreviewCountsEachPendingDeleteAsKeptDeleted_notAsAnAdd() async throws {
        let fixture = try await seedEveryTable()
        deleteOnDevice(fixture)
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])

        let preview = try await preview(coordinator())

        XCTAssertEqual(preview.addsFromCloud.calendarEvents, 1, "positive control: the cloud-only row is an add")
        XCTAssertEqual(preview.addsFromCloud.totalCount, 1, "a row deleted here was counted as added from cloud")
        let kept = preview.keptDeleted
        XCTAssertEqual([kept.calendarEvents, kept.todoEvents, kept.logs, kept.feedback, kept.todoLists,
                        kept.eventTypes, kept.skills], Array(repeating: 1, count: fixture.deleted.count),
                       "calendar, todo, log, feedback, list, type, skill")
        XCTAssertEqual(kept.totalCount, fixture.deleted.count)
        XCTAssertTrue(preview.conflicts.isEmpty)
    }

    /// The deleted type's cloud row beside a new local type of the same
    /// title: neither a conflict nor an add, but kept deleted; the new type
    /// is local-only.
    func testThePreviewCountsADeletedTypeBesideANewNamesakeAsKeptDeleted_notAsAConflict() async throws {
        let reading = EventTypeTemplate(title: "Reading", colorHex: "#445566")
        server.seed(table: "event_types", rows: [service.eventTypeToRow(reading)])
        await puller.pullToHead()
        device.types.remove(title: "Reading")
        device.types.add("Reading", colorHex: "#00AA00")

        let preview = try await preview(coordinator())

        XCTAssertEqual(preview.conflicts.eventTypes, [], "the deleted type was offered as a conflict")
        XCTAssertEqual(preview.addsFromCloud.eventTypes, 0)
        XCTAssertEqual(preview.keptDeleted.eventTypes, 1)
        XCTAssertGreaterThanOrEqual(preview.keepsLocalOnly.eventTypes, 1, "the new type is local-only")
    }

    /// Nothing deleted here: nothing is counted as kept deleted, and the
    /// row the cloud holds that the device does not is an add.
    func testControl_withNoPendingDeleteNothingIsKeptDeleted() async throws {
        let y = makeEvent("Y, only on the cloud")
        server.seed(table: "events", rows: [row(y)])
        let preview = try await preview(coordinator())
        XCTAssertEqual(preview.addsFromCloud.calendarEvents, 1)
        XCTAssertEqual(preview.keptDeleted.totalCount, 0)
    }

    /// A merge whose one effect would be keeping a delete is reviewed, not
    /// applied silently: the review is where the user is told.
    func testAKeptDeleteAloneMakesTheMergeWorthReviewing() {
        var preview = MergePreview()
        XCTAssertTrue(preview.isNoOp, "positive control: an empty preview is a no-op")
        preview.keptDeleted.calendarEvents = 1
        XCTAssertFalse(preview.isNoOp)
    }

    // MARK: - The review's line

    func testTheReviewLineNamesTheCountInBothLanguages() {
        for language in AppLanguage.allCases {
            let one = LCount(.restoreKeptDeletesFormat, one: .restoreKeptDeletesOne, 1, language: language)
            let many = LCount(.restoreKeptDeletesFormat, one: .restoreKeptDeletesOne, 3, language: language)
            XCTAssertTrue(one.contains("1"), "\(language): \(one)")
            XCTAssertTrue(many.contains("3"), "\(language): \(many)")
            XCTAssertFalse(many.contains("%"), "\(language): \(many)")
        }
        XCTAssertNotEqual(LCount(.restoreKeptDeletesFormat, one: .restoreKeptDeletesOne, 3, language: .english),
                          LCount(.restoreKeptDeletesFormat, one: .restoreKeptDeletesOne, 3, language: .chinese))
        XCTAssertNotEqual(LCount(.restoreKeptDeletesFormat, one: .restoreKeptDeletesOne, 1, language: .english),
                          LCount(.restoreKeptDeletesFormat, one: .restoreKeptDeletesOne, 3, language: .english)
                            .replacingOccurrences(of: "3", with: "1"),
                          "English has a singular")
    }

    // MARK: - The trail

    /// The apply line counts the rows the merge kept deleted; an overwrite
    /// keeps none.
    func testTheApplyLineCountsTheRowsKeptDeleted() async throws {
        let fixture = try await seedEveryTable()
        deleteOnDevice(fixture)
        DiagnosticTrail.clear()
        try await restore(.merge)
        XCTAssertEqual(trailLines("restore APPLY strategy=merge").filter { $0.hasSuffix(" keptDeleted=\(fixture.deleted.count)") }.count, 1,
                       trailLines("restore APPLY").joined(separator: "\n"))
    }

    func testTheApplyLineOfAnOverwriteCountsNoneKeptDeleted() async throws {
        let fixture = try await seedEveryTable()
        deleteOnDevice(fixture)
        DiagnosticTrail.clear()
        try await restore(.cloudOverwritesLocal)
        XCTAssertEqual(trailLines("restore APPLY strategy=cloudOverwritesLocal").filter { $0.hasSuffix(" keptDeleted=0") }.count, 1,
                       trailLines("restore APPLY").joined(separator: "\n"))
    }
}
