//
//  ConversationFirstFrameFoldQATests.swift
//  DoneTests
//
//  INDEPENDENT QA net for gh#148 (defer the first-frame conversation fold).
//  Written by the reviewing lane, not the implementer: it attacks the four
//  concurrency obligations the deferral takes on, and it is built to FAIL if a
//  guard the fix depends on is removed.
//
//  The deferral's whole safety argument rests on one structural fact: the
//  repository is `@MainActor`, `load()` has no `await`, and every mutation and
//  every exporter routes through `ensureLoaded()` first. So the main actor
//  serialises all access, the fold runs atomically, and the deferred launch
//  task is a no-op by the time any forcing caller has finished. These tests pin
//  each edge of that argument with a POSITIVE control — the folded result is
//  checked against the array the writes actually produced, never merely against
//  a sibling fold that could be wrong in the same way.
//

import XCTest
@testable import Done

@MainActor
final class ConversationFirstFrameFoldQATests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ConversationFirstFrameFoldQATests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private var fileURL: URL {
        directory.appendingPathComponent(AgentConversationRepository.conversationsFilename)
    }
    private var backupURL: URL {
        directory.appendingPathComponent("conversations.bak")
    }
    private var logURL: URL {
        directory.appendingPathComponent(AgentConversationRepository.logFilename)
    }

    /// A raw, NOT-yet-folded repository — exactly what `init` leaves behind on
    /// the first-frame path. `hasFolded` is false and the served state is empty
    /// until a forcing reader or the launch task runs.
    private func rawDeferredRepository() -> AgentConversationRepository {
        AgentConversationRepository(directory: directory, legacyDefaults: nil)
    }

    /// A repository force-folded on the calling (main) thread — the old
    /// synchronous `init` behaviour, and the way a relaunch is simulated.
    private func foldedRepository() -> AgentConversationRepository {
        let repository = rawDeferredRepository()
        repository.ensureLoaded()
        return repository
    }

    private func conversation(_ text: String,
                              id: UUID = UUID(),
                              at date: Date = Date(timeIntervalSince1970: 1_700_000_000))
    -> AgentConversation {
        AgentConversation(
            id: id,
            title: nil,
            createdAt: date,
            updatedAt: date,
            messages: [
                ChatMessage(id: UUID(), role: .user, content: text, timestamp: date),
                ChatMessage(id: UUID(), role: .assistant, content: "re: \(text)", timestamp: date),
            ]
        )
    }

    // MARK: - Concern 1: the sync gate on a not-yet-folded FROZEN store

    /// `isFrozen` is a POSITIVE control for why the export gate must fold before
    /// it judges: on a store whose file is genuinely unreadable, `isFrozen`
    /// still reads `false` until the fold runs the read that discovers the
    /// fault. A gate that trusted `isFrozen` on a not-yet-folded store would
    /// therefore wave an empty history through — the gh#219 loss amplifier.
    func testPreFoldIsFrozenLiesAboutAnUnreadableFile() throws {
        // Establish real history, then shred the checkpoint (and drop the
        // recoverable backup) so the file is genuinely unreadable.
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([conversation("the cloud's last copy")]))
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)

        let raw = rawDeferredRepository()
        XCTAssertFalse(raw.hasFolded, "fixture guard: the fold is still deferred")
        XCTAssertFalse(raw.isFrozen,
                       "isFrozen reads false pre-fold even though the file is unreadable — "
                       + "this is exactly why a gate may not trust it without folding first")

        // Folding is the only thing that discovers the fault.
        raw.ensureLoaded()
        XCTAssertTrue(raw.isFrozen, "the fold ran the read that discovered the unreadable file")
    }

    /// The catastrophe the fix exists to stop, in the direction the branch's own
    /// tests do NOT cover: the export gate consulted on a not-yet-folded FROZEN
    /// store must fold, discover the fault, and SUPPRESS — never wave the empty
    /// `[]` through onto the cloud's last surviving copy.
    func testExportGate_NotYetFoldedFrozenStore_FoldsThenSuppresses() throws {
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([conversation("real history the cloud still holds")]))
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)

        let raw = rawDeferredRepository()
        XCTAssertFalse(raw.hasFolded, "fixture guard: still deferred")

        let suppressed = SupabaseSyncService.agentConversationsExportSuppressed(raw)

        XCTAssertTrue(suppressed,
                      "an unreadable, not-yet-folded store must be suppressed, not uploaded as []")
        XCTAssertTrue(raw.hasFolded, "the gate folded before judging")
        XCTAssertTrue(raw.isFrozen, "and the fold is what made isFrozen true")
    }

    // MARK: - Concern 2: parity of the deferred fold with the synchronous fold

    /// Empty store: both folds agree on `[]` and neither is frozen.
    func testParity_EmptyStore() async {
        let synchronous = rawDeferredRepository()
        synchronous.ensureLoaded()

        let deferred = rawDeferredRepository()
        await deferred.loadTask?.value

        XCTAssertEqual(synchronous.conversations, [])
        XCTAssertEqual(deferred.conversations, [])
        XCTAssertFalse(synchronous.isFrozen)
        XCTAssertFalse(deferred.isFrozen)
    }

    /// Checkpoint-only (a single seeding write, empty delta log): both folds
    /// reconstruct the seeded array, checked against the array actually written.
    func testParity_CheckpointOnly() async {
        let c1 = conversation("only")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([c1]))            // seeds the checkpoint, log empty
        let truth = seed.conversations
        XCTAssertEqual(truth, [c1], "fixture guard")
        XCTAssertEqual((try? Data(contentsOf: logURL))?.count ?? 0, 0,
                       "fixture guard: checkpoint-only means no delta log")

        let synchronous = rawDeferredRepository()
        synchronous.ensureLoaded()

        let deferred = rawDeferredRepository()
        await deferred.loadTask?.value

        XCTAssertEqual(synchronous.conversations, truth)
        XCTAssertEqual(deferred.conversations, truth)
    }

    /// A torn (un-terminated) last log line is an un-fsynced tail, not
    /// corruption: both folds must serve the checkpoint plus every COMPLETED
    /// delta — identical to each other AND to that known-good array — and stay
    /// unfrozen. The positive control is `truth`, captured before the tearing.
    func testParity_TornTailLosesOnlyTheTail() async throws {
        let c1 = conversation("one")
        let c2 = conversation("two")
        let c3 = conversation("three")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([c1]))            // checkpoint
        XCTAssertTrue(seed.replaceAll([c1, c2]))        // completed delta 1
        XCTAssertTrue(seed.replaceAll([c1, c2, c3]))    // completed delta 2
        let truth = seed.conversations
        XCTAssertEqual(truth, [c1, c2, c3], "fixture guard")

        // Append a partial, un-terminated record — a kill mid-append.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"changed\":[],\"order\":[\"7f3a".utf8))
        try handle.close()

        let synchronous = rawDeferredRepository()
        synchronous.ensureLoaded()

        let deferred = rawDeferredRepository()
        await deferred.loadTask?.value

        XCTAssertEqual(synchronous.conversations, truth,
                       "the synchronous fold drops only the torn tail")
        XCTAssertEqual(deferred.conversations, truth,
                       "and the deferred fold drops the identical tail — parity, tail included")
        XCTAssertFalse(synchronous.isFrozen, "a torn tail is not corruption")
        XCTAssertFalse(deferred.isFrozen)
    }

    /// A COMMITTED (newline-terminated) but undecodable log record is genuine
    /// corruption: both folds must serve the checkpoint ALONE and both must
    /// freeze. Checked against the checkpoint-only truth, not just each other.
    func testParity_CorruptCommittedRecordServesCheckpointAndFreezes() async throws {
        let c1 = conversation("survivor")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([c1]))            // checkpoint
        XCTAssertTrue(seed.replaceAll([c1, conversation("about to be lost to corruption")]))
        let checkpointTruth = [c1]

        // Overwrite the log with a complete, newline-terminated, undecodable
        // line — corruption, not a torn tail.
        try Data("this is not a delta record\n".utf8).write(to: logURL)

        let synchronous = rawDeferredRepository()
        synchronous.ensureLoaded()

        let deferred = rawDeferredRepository()
        await deferred.loadTask?.value

        XCTAssertEqual(synchronous.conversations, checkpointTruth,
                       "synchronous fold serves the checkpoint alone")
        XCTAssertEqual(deferred.conversations, checkpointTruth,
                       "deferred fold serves the identical checkpoint alone — parity")
        XCTAssertTrue(synchronous.isFrozen, "corruption freezes so it is not mirrored as a shorter history")
        XCTAssertTrue(deferred.isFrozen, "and the deferred fold reaches the identical frozen verdict")
    }

    /// The two exporters (`SupabaseSyncService.agentConversationsToRow` and
    /// `BackupSnapshotService`) both read `encodedJSONForSync()`. A deferred and
    /// a synchronous fold must hand them BYTE-IDENTICAL data, or the row hash
    /// churns and a relaunch re-uploads a transcript that did not change.
    func testParity_ExportBytesAreByteIdenticalAcrossFoldTiming() async {
        let c1 = conversation("one")
        let c2 = conversation("two")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([c1]))
        XCTAssertTrue(seed.replaceAll([c1, c2]))

        let synchronous = rawDeferredRepository()
        synchronous.ensureLoaded()
        let syncBytes = synchronous.encodedJSONForSync()

        let deferred = rawDeferredRepository()
        await deferred.loadTask?.value
        let deferredBytes = deferred.encodedJSONForSync()

        XCTAssertNotNil(syncBytes)
        XCTAssertEqual(syncBytes, deferredBytes,
                       "fold timing must not change the exported bytes — the sync hash is built on them")
        // And the encoder is deterministic across repeated encodes of the same fold.
        XCTAssertEqual(syncBytes, synchronous.encodedJSONForSync(),
                       "two encodes of one fold are byte-identical")
    }

    // MARK: - Concern 3: a write that lands BEFORE the deferred fold

    /// The nastiest race: a write arrives while the launch fold is still
    /// pending. The write MUST fold first (so `hasFolded` is set and the base is
    /// real), and the late-completing launch task MUST then be a no-op that does
    /// not clobber the just-written state. Disk integrity is confirmed by a
    /// relaunch fold, and the write's own force-fold is pinned by `hasFolded`
    /// becoming true the instant the write returns — the assertion that dies if
    /// `replaceAll` stops folding first.
    func testWriteBeforeFold_ForcesTheFold_AndLateTaskDoesNotClobber() async throws {
        let c1 = conversation("one")
        let c2 = conversation("two")
        let c3 = conversation("three")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([c1]))            // checkpoint on disk
        XCTAssertTrue(seed.replaceAll([c1, c2]))        // delta on disk

        let r = rawDeferredRepository()
        XCTAssertFalse(r.hasFolded, "fixture guard: launch fold still pending")

        // A write lands during the deferred window.
        XCTAssertTrue(r.replaceAll([c1, c2, c3]))
        XCTAssertTrue(r.hasFolded,
                      "the write must have folded the real base before writing — "
                      + "without this the write would seed a fresh checkpoint over disk history")
        XCTAssertEqual(r.conversations, [c1, c2, c3])

        // The late launch task resolves. It must observe hasFolded and no-op.
        await r.loadTask?.value
        XCTAssertEqual(r.conversations, [c1, c2, c3],
                       "the late fold did not clobber the newer in-memory state")

        // Disk truth: a real relaunch reconstructs everything, so nothing was
        // dropped by a reseed of the checkpoint.
        let relaunch = foldedRepository()
        XCTAssertEqual(relaunch.conversations, [c1, c2, c3],
                       "the on-disk checkpoint+log still fold to the full history")
    }

    // MARK: - Concern 4: ordering / idempotence once a reader has forced the fold

    /// Once any reader forces the fold, the deferred launch task must be a pure
    /// no-op: it must not re-read disk over an in-memory mutation made after the
    /// force, and it must not double-count. Modelled by forcing via the exporter
    /// read, mutating in memory, then letting the launch task resolve.
    func testLateLaunchTask_IsANoOpAfterAReaderForcedTheFold() async {
        let c1 = conversation("one")
        let c2 = conversation("two")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([c1]))

        let r = rawDeferredRepository()
        XCTAssertFalse(r.hasFolded)

        // A reader (the exporter path) forces the fold.
        _ = r.encodedJSONForSync()
        XCTAssertTrue(r.hasFolded, "the reader forced the fold")
        XCTAssertEqual(r.conversations, [c1])

        // An in-memory mutation lands after the force but before the task runs.
        XCTAssertTrue(r.replaceAll([c1, c2]))
        XCTAssertEqual(r.conversations, [c1, c2])

        // The launch task resolves last and must change nothing.
        await r.loadTask?.value
        XCTAssertEqual(r.conversations, [c1, c2],
                       "the deferred launch task is a no-op once a reader has folded")
    }

    /// The pre-fold served state is well-defined empty, never a half-built
    /// partial fold, and the exporter read returns the COMPLETE history. This is
    /// the read-during-window obligation stated as: empty (fine) or complete
    /// (fine), never torn.
    func testReaderInTheWindow_SeesEmptyThenComplete_NeverPartial() throws {
        let a = conversation("a")
        let b = conversation("b")
        let seed = foldedRepository()
        XCTAssertTrue(seed.replaceAll([a]))
        XCTAssertTrue(seed.replaceAll([a, b]))
        let truthIDs = seed.conversations.map(\.id)

        let r = rawDeferredRepository()
        XCTAssertTrue(r.conversations.isEmpty,
                      "the pre-fold served state is a well-defined empty array")

        let bytes = try XCTUnwrap(r.encodedJSONForSync())
        let decoded = try JSONDecoder().decode([AgentConversation].self, from: bytes)
        XCTAssertEqual(decoded.map(\.id), truthIDs,
                       "the exporter read folds and returns the complete history, never []")
    }
}
