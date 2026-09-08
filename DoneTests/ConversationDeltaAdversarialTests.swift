//
//  ConversationDeltaAdversarialTests.swift
//  DoneTests
//
//  INDEPENDENT QA (gh#219 delta-writes lane). These tests are NOT part of the
//  branch's own acceptance net; they are the attacker's witnesses. Durability
//  first: a lost chat message is unrecoverable user data.
//
//  Two of them are POSITIVE controls that must stay green (the fold math is
//  exact; a same-conversation write failure self-heals). One is the WITNESS to
//  a durability regression: a transient append failure whose recovering write
//  lands on a DIFFERENT conversation permanently loses the failed message —
//  the whole-array commit this replaced healed exactly this on the next write.
//

import XCTest
@testable import Done

@MainActor
final class ConversationDeltaAdversarialTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ConversationDeltaAdversarial-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private var snapshotURL: URL { directory.appendingPathComponent("conversations.json") }
    private var logURL: URL { directory.appendingPathComponent("conversations.log") }

    private func makeRepo(threshold: Int = 10_000_000) -> AgentConversationRepository {
        AgentConversationRepository(directory: directory, legacyDefaults: nil, compactionThresholdBytes: threshold)
    }

    private func msg(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            content: text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func conversation(id: UUID, title: String, messages: [ChatMessage]) -> AgentConversation {
        AgentConversation(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messages: messages
        )
    }

    // MARK: - Positive control 1: the pure fold is exact over random sequences

    /// A deterministic fuzz over grow / add / delete / reorder / edit, always
    /// diffing against the running array (every delta lands). fold(base, log)
    /// must equal the running array at every step. This pins the fold MATH —
    /// so a later failure of the witness below is isolated to the FAILURE-
    /// handling path, not to the fold itself.
    func testFoldExactnessOverRandomizedOperationSequences() {
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng }
        func pick(_ n: Int) -> Int { n == 0 ? 0 : Int(next() % UInt64(n)) }

        for trial in 0..<40 {
            let baseCount = 1 + pick(3)
            var running: [AgentConversation] = (0..<baseCount).map { i in
                conversation(id: UUID(), title: "c\(i)", messages: [msg("seed\(i)")])
            }
            let base = running
            var records: [ConversationDeltaRecord] = []

            func step(_ nextArray: [AgentConversation]) {
                if let r = ConversationDeltaFold.delta(from: running, to: nextArray) {
                    records.append(r)
                }
                running = nextArray
                XCTAssertEqual(ConversationDeltaFold.fold(base: base, records: records), running,
                               "trial \(trial): fold diverged from the running array")
            }

            for _ in 0..<25 {
                var arr = running
                switch pick(5) {
                case 0: // grow a random conversation
                    guard !arr.isEmpty else { break }
                    let i = pick(arr.count)
                    arr[i].messages.append(msg("m\(next() % 1000)"))
                case 1: // add a new conversation
                    arr.append(conversation(id: UUID(), title: "n\(next() % 1000)", messages: [msg("hi")]))
                case 2: // delete a random conversation
                    guard !arr.isEmpty else { break }
                    arr.remove(at: pick(arr.count))
                case 3: // reorder (swap two)
                    guard arr.count >= 2 else { break }
                    let i = pick(arr.count), j = pick(arr.count)
                    arr.swapAt(i, j)
                default: // edit a title
                    guard !arr.isEmpty else { break }
                    let i = pick(arr.count)
                    arr[i].title = "edited\(next() % 1000)"
                }
                step(arr)
            }
        }
    }

    // MARK: - Positive control 2: a same-conversation write failure self-heals

    /// When an append fails and the NEXT write continues the SAME conversation,
    /// that write's delta carries the whole conversation body (the unit is the
    /// conversation, not the message), so the failed message is recovered. This
    /// is the case that DOES heal — the contrast that isolates the witness.
    func testSameConversationAppendFailureHealsOnTheNextWrite() throws {
        let repo = makeRepo()
        let aID = UUID()
        let a0 = conversation(id: aID, title: "a", messages: [msg("a0")])
        XCTAssertTrue(repo.replaceAll([a0]))            // seed checkpoint

        // Force the next append to fail (a directory where the log file goes).
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let a1 = conversation(id: aID, title: "a", messages: [msg("a0"), msg("a1")])
        XCTAssertFalse(repo.replaceAll([a1]), "the append fails while the path is blocked")

        // Unblock; the SAME conversation continues.
        try FileManager.default.removeItem(at: logURL)
        let a2 = conversation(id: aID, title: "a", messages: [msg("a0"), msg("a1"), msg("a2")])
        XCTAssertTrue(repo.replaceAll([a2]))

        let relaunched = makeRepo()
        XCTAssertEqual(relaunched.conversations.first(where: { $0.id == aID })?.messages.map(\.content),
                       ["a0", "a1", "a2"],
                       "continuing the same conversation heals the transiently-failed append")
    }

    // MARK: - WITNESS: cross-conversation recovering write loses the failed one

    /// The regression. `AtomicValueFile.commit` rewrote the WHOLE array every
    /// write, so a transient failure was healed by the next successful write no
    /// matter which row it touched. The delta log diffs each write against the
    /// UN-persisted in-memory state, so a message whose append failed is lost
    /// the instant the recovering write lands on a DIFFERENT conversation — its
    /// delta does not carry the failed row's body. Worse, that successful write
    /// clears `writeFailed`, so the degraded banner drops and the loss is silent
    /// until the next launch reveals the missing message.
    func testTransientAppendFailureThenCrossConversationWriteSilentlyLosesAMessage() throws {
        let repo = makeRepo()
        let aID = UUID(), bID = UUID()
        let a0 = conversation(id: aID, title: "a", messages: [msg("a0")])
        let b0 = conversation(id: bID, title: "b", messages: [msg("b0")])
        XCTAssertTrue(repo.replaceAll([a0, b0]))        // seed checkpoint with A and B

        // A transient failure hits A's message append (disk full / IO error;
        // simulated by blocking the log path with a directory).
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let a1 = conversation(id: aID, title: "a", messages: [msg("a0"), msg("a1")])
        XCTAssertFalse(repo.replaceAll([a1, b0]), "A's append fails")
        XCTAssertTrue(repo.isDegraded, "and the store reports itself degraded")

        // The condition clears (space freed), and the recovering write is a
        // message in the OTHER conversation, B.
        try FileManager.default.removeItem(at: logURL)
        let b1 = conversation(id: bID, title: "b", messages: [msg("b0"), msg("b1")])
        XCTAssertTrue(repo.replaceAll([a1, b1]))
        XCTAssertFalse(repo.isDegraded,
                       "the successful B write clears the degraded flag — the warning is gone")

        // Relaunch: B's message is here; A's a1 is GONE.
        let relaunched = makeRepo()
        XCTAssertFalse(relaunched.isFrozen)
        XCTAssertEqual(relaunched.conversations.first(where: { $0.id == bID })?.messages.map(\.content),
                       ["b0", "b1"], "B's message persisted")
        XCTAssertEqual(relaunched.conversations.first(where: { $0.id == aID })?.messages.map(\.content),
                       ["a0", "a1"],
                       "A's a1 must survive — a whole-array commit would have healed it on the B write")
    }
}
