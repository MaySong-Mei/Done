//
//  ConversationDeltaLogTests.swift
//  DoneTests
//
//  gh#219 — the acceptance net for the agent-chat WRITE path moving from a
//  whole-array re-encode per message to an append log with periodic
//  checkpointing (`ConversationDeltaLog` + the append/checkpoint logic in
//  `AgentConversationRepository`).
//
//  Four obligations, each with the mutation that must kill it:
//   * appending N messages writes N delta LINES, not N whole arrays — mutation:
//     revert the hot path to a whole-array commit → 0 lines, snapshot churns;
//   * a torn last line costs only that un-fsynced tail — mutation: drop the
//     tail tolerance → the tail faults → the store freezes and shortens;
//   * crossing the byte bound rewrites the checkpoint and the folded state is
//     unchanged — mutation: never checkpoint → the log grows unbounded;
//   * an existing whole-array file loads and then writes append-only — this is
//     the migration, and it needs no format change because the old file IS the
//     checkpoint format.
//
//  Plus the anti-silent-loss floor (RED LINE 3): a corrupt COMMITTED delta must
//  freeze, never present as a shorter history that then overwrites the cloud.
//

import XCTest
@testable import Done

@MainActor
final class ConversationDeltaLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ConversationDeltaLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private var snapshotURL: URL { directory.appendingPathComponent("conversations.json") }
    private var logURL: URL { directory.appendingPathComponent("conversations.log") }

    private func makeRepo(threshold: Int = 10_000_000) -> AgentConversationRepository {
        AgentConversationRepository(directory: directory, legacyDefaults: nil, compactionThresholdBytes: threshold)
    }

    private func msg(_ text: String, role: ChatMessageRole = .user) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            content: text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func conversation(
        _ text: String,
        id: UUID = UUID(),
        messages: [ChatMessage]? = nil
    ) -> AgentConversation {
        AgentConversation(
            id: id,
            title: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messages: messages ?? [msg(text)]
        )
    }

    /// Probe the raw log the way a forensic reader would — a fresh store over
    /// the same file, decoding each committed line.
    private func logRecords() -> [ConversationDeltaRecord]? {
        ConversationDeltaLog(fileURL: logURL).loadRecords()
    }

    private func createDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Fold: the exactness the whole-array path is held to (RED LINE 4)

    /// A realistic session: a conversation grows, a second is added, then the
    /// first is deleted and the second reordered. The fold of the deltas must
    /// equal the final array the whole-value path would have written.
    func testFoldReproducesTheWholeArrayPathAcrossGrowAddDeleteReorder() {
        let aID = UUID(), bID = UUID()
        let a0 = conversation("a", id: aID, messages: [msg("a1")])
        let base = [a0]

        var records: [ConversationDeltaRecord] = []
        var running = base

        func step(_ next: [AgentConversation]) {
            if let record = ConversationDeltaFold.delta(from: running, to: next) {
                records.append(record)
            }
            running = next
        }

        let a1 = conversation("a", id: aID, messages: [msg("a1"), msg("a2")])
        step([a1])                                   // grow A
        let b0 = conversation("b", id: bID, messages: [msg("b1")])
        step([a1, b0])                               // add B
        step([b0, a1])                               // reorder
        step([b0])                                   // delete A

        XCTAssertEqual(ConversationDeltaFold.fold(base: base, records: records), [b0],
                       "the fold must reproduce the final array element-for-element")
    }

    /// The property checkpoint ordering rests on: replaying the log over a base
    /// that ALREADY folds it in is a no-op. A kill between "write checkpoint"
    /// and "clear log" leaves exactly this state, and it must not double-apply.
    func testFoldIsIdempotentAgainstACheckpointThatAlreadyIncludesIt() {
        let aID = UUID()
        let base = [conversation("a", id: aID, messages: [msg("a1")])]
        let grown = [conversation("a", id: aID, messages: [msg("a1"), msg("a2")])]
        let record = ConversationDeltaFold.delta(from: base, to: grown)!

        let folded = ConversationDeltaFold.fold(base: base, records: [record])
        XCTAssertEqual(folded, grown)
        XCTAssertEqual(ConversationDeltaFold.fold(base: folded, records: [record]), grown,
                       "replaying a delta over a base that includes it must land on the same state")
    }

    func testDeltaIsNilWhenNothingChanged() {
        let rows = [conversation("x")]
        XCTAssertNil(ConversationDeltaFold.delta(from: rows, to: rows),
                     "an identical array is not a write")
    }

    func testDeltaCarriesAPureReorderInTheOrderWithNoBodies() {
        let a = conversation("a"), b = conversation("b")
        guard let record = ConversationDeltaFold.delta(from: [a, b], to: [b, a]) else {
            return XCTFail("a reorder is a change")
        }
        XCTAssertEqual(record.changed.count, 0, "no body changed; the order carries the move")
        XCTAssertEqual(ConversationDeltaFold.fold(base: [a, b], records: [record]), [b, a])
    }

    // MARK: - Obligation 1: N messages → N lines, not N arrays

    func testAppendingNMessagesWritesNDeltaLinesNotNWholeArrays() throws {
        let repo = makeRepo()
        let convID = UUID()
        var conv = conversation("chat", id: convID, messages: [msg("m0")])

        // The first write seeds the checkpoint (a whole-array commit) so that
        // conversations.json exists; it is NOT a delta.
        XCTAssertTrue(repo.replaceAll([conv]))
        XCTAssertEqual(logRecords()?.count, 0, "the seed is a checkpoint, not a delta line")
        let snapshotAfterSeed = try Data(contentsOf: snapshotURL)

        let n = 8
        for i in 1...n {
            conv.messages.append(msg("m\(i)"))
            XCTAssertTrue(repo.replaceAll([conv]))
        }

        XCTAssertEqual(logRecords()?.count, n,
                       "each appended message is ONE delta line")
        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotAfterSeed,
                       "the whole array is NOT re-encoded per message — the checkpoint is untouched")

        // And the folded state on a relaunch is the full transcript.
        let relaunched = makeRepo()
        XCTAssertFalse(relaunched.isFrozen)
        XCTAssertEqual(relaunched.conversations.first?.messages.map(\.content),
                       (0...n).map { "m\($0)" })
    }

    // MARK: - Obligation 2: a torn last line costs only the tail

    func testATornLastDeltaLosesOnlyTheTailAndPriorMessagesSurvive() throws {
        let repo = makeRepo()
        let convID = UUID()
        var conv = conversation("chat", id: convID, messages: [msg("m0")])
        XCTAssertTrue(repo.replaceAll([conv]))          // checkpoint
        conv.messages.append(msg("m1")); XCTAssertTrue(repo.replaceAll([conv]))  // delta 1
        conv.messages.append(msg("m2")); XCTAssertTrue(repo.replaceAll([conv]))  // delta 2

        // Simulate a kill mid-append of a third delta: a partial, un-terminated
        // line at the end. Only bytes past the last good record are touched.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"changed\":[],\"order\":[\"7f3a".utf8))
        try handle.close()

        let relaunched = makeRepo()
        XCTAssertFalse(relaunched.isFrozen,
                       "a torn tail is an un-fsynced write, not corruption")
        XCTAssertEqual(relaunched.conversations.first?.messages.map(\.content), ["m0", "m1", "m2"],
                       "the checkpoint and every COMPLETED delta survive the torn tail")
    }

    /// The heal step: after a torn tail, the NEXT real append must not be lost
    /// to concatenation onto the partial bytes.
    func testAnAppendAfterATornTailStillSurvives() throws {
        let repo = makeRepo()
        let convID = UUID()
        var conv = conversation("chat", id: convID, messages: [msg("m0")])
        XCTAssertTrue(repo.replaceAll([conv]))          // checkpoint
        conv.messages.append(msg("m1")); XCTAssertTrue(repo.replaceAll([conv]))  // delta 1

        // A torn tail lands (crash mid-append), then the process relaunches and
        // the user sends another message.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"order".utf8))   // torn, no newline
        try handle.close()

        let afterCrash = makeRepo()
        XCTAssertEqual(afterCrash.conversations.first?.messages.map(\.content), ["m0", "m1"])
        var conv2 = afterCrash.conversations.first!
        conv2.messages.append(msg("m2"))
        XCTAssertTrue(afterCrash.replaceAll([conv2]))   // heals the tail, appends m2

        let relaunched = makeRepo()
        XCTAssertFalse(relaunched.isFrozen)
        XCTAssertEqual(relaunched.conversations.first?.messages.map(\.content), ["m0", "m1", "m2"],
                       "the post-crash append is not lost to the torn tail before it")
    }

    // MARK: - Obligation 3: crossing the bound checkpoints, folded state unchanged

    func testCrossingTheByteBoundRewritesTheCheckpointAndTheFoldedStateIsUnchanged() throws {
        let repo = makeRepo(threshold: 512)
        let convID = UUID()
        var conv = conversation("chat", id: convID, messages: [msg("m0")])
        XCTAssertTrue(repo.replaceAll([conv]))          // seed checkpoint
        let snapshotAfterSeed = try Data(contentsOf: snapshotURL)

        for i in 1...30 {
            conv.messages.append(msg("a slightly longer message body number \(i)"))
            XCTAssertTrue(repo.replaceAll([conv]))
        }

        // A checkpoint fired: the whole-array file was rewritten past the seed…
        XCTAssertNotEqual(try Data(contentsOf: snapshotURL), snapshotAfterSeed,
                          "crossing the bound must rewrite the checkpoint")
        let snap = try JSONDecoder().decode([AgentConversation].self, from: Data(contentsOf: snapshotURL))
        XCTAssertGreaterThan(snap.first?.messages.count ?? 0, 1,
                             "the checkpoint captured folded state beyond the seed")
        // …and the log is bounded, not growing without limit.
        XCTAssertLessThan(ConversationDeltaLog(fileURL: logURL).byteSize, 512 * 4,
                          "the log is compacted, not unbounded")

        // The folded state is identical to a fresh relaunch's — compaction is
        // behaviour-preserving.
        let relaunched = makeRepo(threshold: 512)
        XCTAssertEqual(relaunched.conversations, repo.conversations)
        XCTAssertEqual(relaunched.conversations.first?.messages.count, 31)
    }

    // MARK: - Obligation 4: migration = the old whole-array file IS the checkpoint

    func testAnExistingWholeArrayFileLoadsThenAllSubsequentWritesAreAppendOnly() throws {
        createDirectory()
        // The pre-#219 shape: a whole `[AgentConversation]` array on disk under
        // the same filename, written by the old code path (here, directly).
        let rows = [conversation("older"), conversation("newer")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(rows).write(to: snapshotURL)

        let repo = makeRepo()
        XCTAssertFalse(repo.isFrozen)
        XCTAssertEqual(repo.conversations.map(\.id), rows.map(\.id),
                       "the existing whole-array file loads unchanged")
        XCTAssertEqual(logRecords()?.count, 0, "no delta log yet — the old file needs no migration")

        // The next edit is a delta line, and it does NOT rewrite the whole array.
        let snapshotBefore = try Data(contentsOf: snapshotURL)
        var changed = repo.conversations
        changed[0].messages.append(msg("added after load"))
        XCTAssertTrue(repo.replaceAll(changed))
        XCTAssertEqual(logRecords()?.count, 1, "the edit landed as one delta line — now in log format")
        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotBefore,
                       "the whole array is not re-encoded for a single edit")

        let relaunched = makeRepo()
        XCTAssertEqual(relaunched.conversations.first?.messages.count,
                       changed.first?.messages.count)
    }

    // MARK: - Anti-silent-loss floor (RED LINE 3)

    /// A COMMITTED (newline-terminated) delta that will not decode is genuine
    /// corruption, not a torn tail. It must freeze — an unreadable history that
    /// presents as a shorter one gets mirrored to the cloud over the last copy.
    func testACorruptCommittedDeltaFreezesRatherThanShorteningTheHistory() throws {
        let repo = makeRepo()
        let convID = UUID()
        var conv = conversation("chat", id: convID, messages: [msg("m0")])
        XCTAssertTrue(repo.replaceAll([conv]))          // checkpoint
        conv.messages.append(msg("m1")); XCTAssertTrue(repo.replaceAll([conv]))  // one delta

        // Overwrite the log with a complete, newline-terminated, undecodable
        // line — a corrupted committed record, not a partial write.
        try Data("this is not a delta record\n".utf8).write(to: logURL)

        let relaunched = makeRepo()
        XCTAssertTrue(relaunched.isFrozen,
                      "a corrupt committed delta must freeze, not present as a shorter history")
        XCTAssertTrue(SupabaseSyncService.agentConversationsExportSuppressed(relaunched),
                      "and while frozen the shortened history must never reach the cloud")
    }

    // MARK: - Store-level: append/load/clear round trips

    func testAppendThenLoadRoundTripsRecords() {
        let log = ConversationDeltaLog(fileURL: logURL)
        let r1 = ConversationDeltaRecord(order: [UUID()], changed: [conversation("a")])
        let r2 = ConversationDeltaRecord(order: [UUID(), UUID()], changed: [conversation("b")])
        XCTAssertTrue(log.append(r1))
        XCTAssertTrue(log.append(r2))
        XCTAssertEqual(ConversationDeltaLog(fileURL: logURL).loadRecords(), [r1, r2])
    }

    func testClearRemovesEveryDelta() {
        let log = ConversationDeltaLog(fileURL: logURL)
        XCTAssertTrue(log.append(ConversationDeltaRecord(order: [UUID()], changed: [conversation("a")])))
        log.clear()
        XCTAssertEqual(log.loadRecords()?.count, 0)
        XCTAssertNil(log.fault)
    }

    func testAnAbsentLogIsEmptyNotAFault() {
        let log = ConversationDeltaLog(fileURL: logURL)
        XCTAssertEqual(log.loadRecords()?.count, 0)
        XCTAssertNil(log.fault)
    }
}
