//
//  AgentConversationRepositoryTests.swift
//  DoneTests
//
//  The acceptance net for the first half of issue #144: the agent chat
//  history off `UserDefaults` and onto a file.
//
//  Two distinct bugs are being fenced off, and they fail in opposite
//  directions:
//
//  * a save reported success while the bytes were still in cfprefsd, so a
//    swipe-kill after a round with the agent could lose it — and the encode
//    failure was swallowed outright, so an unwritten 351 KB transcript looked
//    exactly like a written one;
//  * an UNREADABLE blob decoded to `[]` in `agentConversationsToRow()` and was
//    uploaded, replacing the cloud's copy at the one moment the cloud was the
//    last copy standing. Several tests below exist only to pin "must not
//    present as an empty history".
//
//  And a third, found by review of the fix for the first two: the freeze that
//  protects the cloud copy said NOTHING to the user, so a session spent typing
//  into a store that refuses every write looked completely normal until the
//  relaunch. See "Telling the user" at the bottom.
//

import Combine
import XCTest
@testable import Done

@MainActor
final class AgentConversationRepositoryTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentConversationRepositoryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        suiteName = "AgentConversationRepositoryTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName, let suite { suite.removePersistentDomain(forName: suiteName) }
        directory = nil
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A fresh repository over the same directory — the relaunch simulation.
    private func makeRepository(legacy: UserDefaults? = nil) -> AgentConversationRepository {
        AgentConversationRepository(directory: directory, legacyDefaults: legacy)
    }

    private var fileURL: URL {
        directory.appendingPathComponent(AgentConversationRepository.conversationsFilename)
    }
    private var backupURL: URL {
        directory.appendingPathComponent("conversations.bak")
    }
    private var witnessURL: URL {
        directory.appendingPathComponent("conversations.committed")
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

    private func seedLegacyConversations(_ rows: [AgentConversation]) throws {
        suite.set(try JSONEncoder().encode(rows), forKey: AgentConversationsStorageKey)
    }

    /// A repository whose file is shredded and whose backup is gone — i.e.
    /// genuinely unreadable, not merely recoverable. One commit, so there is no
    /// `.bak`: that is the normal state right after the legacy migration and
    /// again right after "reset all local data".
    private func makeFrozenRepository(legacy: UserDefaults? = nil) throws
    -> AgentConversationRepository {
        let seeded = makeRepository(legacy: legacy)
        XCTAssertTrue(seeded.replaceAll([conversation("seed")]))
        try Data("shredded".utf8).write(to: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        let frozen = makeRepository(legacy: legacy)
        XCTAssertTrue(frozen.isFrozen, "fixture guard")
        return frozen
    }

    // MARK: - The reported loss: a round with the agent, then a swipe-kill

    func testAConversationSurvivesARelaunch() {
        let a = makeRepository()
        let rows = [conversation("what did I do last week")]
        XCTAssertTrue(a.replaceAll(rows))

        let b = makeRepository()
        XCTAssertEqual(b.conversations.map(\.id), rows.map(\.id))
        XCTAssertEqual(b.conversations.first?.messages.map(\.content),
                       rows.first?.messages.map(\.content))
        XCTAssertFalse(b.isFrozen)
    }

    /// The commit point is `rename(2)`, so the bytes are on disk when
    /// `replaceAll` returns rather than whenever cfprefsd next feels like it.
    func testTheFileExistsOnDiskAsSoonAsTheWriteReturns() {
        let a = makeRepository()
        XCTAssertTrue(a.replaceAll([conversation("now")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAgentServiceRoutesItsSaveThroughTheRepository() {
        let repository = makeRepository()
        let service = AgentService(repository: repository)
        service.createNewConversation()
        service.sendMessage("hello")

        XCTAssertFalse(repository.conversations.isEmpty,
                       "the service's save must reach the durable file")
        let relaunched = makeRepository()
        XCTAssertEqual(relaunched.conversations.first?.messages.first?.content, "hello")

        let relaunchedService = AgentService(repository: relaunched)
        XCTAssertEqual(relaunchedService.conversations.count, relaunched.conversations.count)
        XCTAssertEqual(relaunchedService.currentConversationID, relaunched.conversations.first?.id)
    }

    // MARK: - Migration

    func testLegacyConversationsBlobMigratesAndTheKeySurvives() throws {
        let rows = [conversation("older"), conversation("newer")]
        try seedLegacyConversations(rows)

        let repository = makeRepository(legacy: suite)
        XCTAssertEqual(repository.conversations.map(\.id), rows.map(\.id))
        XCTAssertNotNil(suite.data(forKey: AgentConversationsStorageKey),
                        "the legacy blob is the rollback net and must never be deleted")

        // And it is a file now, not a re-read of the key on every launch.
        suite.removeObject(forKey: AgentConversationsStorageKey)
        let afterKeyIsGone = makeRepository(legacy: suite)
        XCTAssertEqual(afterKeyIsGone.conversations.map(\.id), rows.map(\.id))
    }

    /// Killed between the legacy read and the commit, the next launch must do
    /// the same thing again rather than deciding the store is fresh.
    func testMigrationIsReEntrant() throws {
        let rows = [conversation("only round")]
        try seedLegacyConversations(rows)

        let first = makeRepository(legacy: suite)
        XCTAssertEqual(first.conversations.map(\.id), rows.map(\.id))

        // Simulate "the commit never landed": remove every trace the migration
        // left behind, legacy key still in place.
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: witnessURL)

        let second = makeRepository(legacy: suite)
        XCTAssertEqual(second.conversations.map(\.id), rows.map(\.id))
        XCTAssertFalse(second.isFrozen)
    }

    func testLegacyFlatTranscriptWrapsIntoOneConversationAndTheKeySurvives() throws {
        let messages = [
            ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "second"),
            ChatMessage(role: .assistant, content: "", isLoading: true),
        ]
        suite.set(try JSONEncoder().encode(messages),
                  forKey: AgentConversationRepository.legacyMessagesKey)

        let repository = makeRepository(legacy: suite)
        XCTAssertEqual(repository.conversations.count, 1)
        XCTAssertEqual(repository.conversations.first?.messages.map(\.content), ["first", "second"],
                       "a loading placeholder is UI state mid-request, not content")
        XCTAssertNotNil(suite.data(forKey: AgentConversationRepository.legacyMessagesKey),
                        "the old migration DELETED this key; it is the rollback net and now survives")
    }

    /// The newer key wins outright when it is present at all. Reaching the
    /// older key whenever the newer one merely decodes EMPTY would let an
    /// undecodable `agentChatMessages` — dead data for years — freeze a user
    /// whose real state is "no conversations".
    func testAnEmptyConversationsKeyDoesNotResurrectTheOlderTranscript() throws {
        try seedLegacyConversations([])
        suite.set(Data("not chat messages".utf8),
                  forKey: AgentConversationRepository.legacyMessagesKey)

        let repository = makeRepository(legacy: suite)
        XCTAssertTrue(repository.conversations.isEmpty)
        XCTAssertFalse(repository.isFrozen, "an empty history is not a fault")
    }

    // MARK: - Unreadable must not present as empty

    /// The loss amplifier this closes: a corrupt blob decoded to `[]` in the
    /// row builder and was UPLOADED over the cloud's copy.
    func testUndecodableLegacyBytesFreezeRatherThanReadingAsNoHistory() {
        suite.set(Data("this is not JSON".utf8), forKey: AgentConversationsStorageKey)

        let repository = makeRepository(legacy: suite)
        XCTAssertTrue(repository.isFrozen)
        XCTAssertTrue(SupabaseSyncService.agentConversationsExportSuppressed(repository),
                      "an unreadable history must never be mirrored to the cloud as []")
    }

    func testACorruptFileFreezesAndRefusesWrites() throws {
        let frozen = try makeFrozenRepository()
        XCTAssertTrue(frozen.conversations.isEmpty)
        XCTAssertTrue(SupabaseSyncService.agentConversationsExportSuppressed(frozen))

        XCTAssertFalse(frozen.replaceAll([conversation("typed while frozen")]),
                       "a write over an unreadable file destroys the file")
        XCTAssertTrue(frozen.conversations.isEmpty,
                      "a refused write must not leave the exporters holding the array we failed to persist")
    }

    /// A corrupt primary is MOVED into `quarantine/` by the read that found it,
    /// so without durable proof of a prior commit the freeze would last exactly
    /// one process lifetime — and the launch after that would re-migrate the
    /// pre-migration legacy blob, rolling back every round since, quietly.
    func testTheFreezeOutlivesTheProcessThatRaisedIt() throws {
        let rows = [conversation("cloud has this")]
        try seedLegacyConversations(rows)
        _ = try makeFrozenRepository(legacy: suite)

        let nextLaunch = makeRepository(legacy: suite)
        XCTAssertTrue(nextLaunch.isFrozen,
                      "the relaunch after a corruption must not read the directory as a first run")
        XCTAssertTrue(nextLaunch.conversations.isEmpty)
    }

    /// Both copies gone out of band, witness still there: written-and-lost, not
    /// never-written.
    func testALostFileFreezesInsteadOfRemigratingTheLegacyBlob() throws {
        try seedLegacyConversations([conversation("stale snapshot")])
        let seeded = makeRepository(legacy: suite)
        XCTAssertTrue(seeded.replaceAll([conversation("everything since")]))

        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: witnessURL.path), "fixture guard")

        let nextLaunch = makeRepository(legacy: suite)
        XCTAssertTrue(nextLaunch.isFrozen)
        XCTAssertTrue(nextLaunch.conversations.isEmpty,
                      "re-serving the pre-migration blob would look legitimate while rolling back every round since")
    }

    // MARK: - The change signal

    /// Cloud sync used to wake on `UserDefaults.didChangeNotification`. A file
    /// posts nothing, so this notification is the whole reason cloud backup
    /// keeps working — its absence is invisible until the device is gone.
    func testARealCommitPostsTheChangeNotification() {
        let repository = makeRepository()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: AgentConversationRepository.didChangeNotification,
            object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(repository.replaceAll([conversation("round one")]))
        XCTAssertEqual(posts, 1)
    }

    /// The identical-payload skip performs no I/O, so there is nothing to
    /// upload — and posting anyway would restore exactly the wake-on-every-
    /// write noise this replaced.
    func testAnIdenticalCommitDoesNotPost() {
        let repository = makeRepository()
        let rows = [conversation("same bytes")]
        XCTAssertTrue(repository.replaceAll(rows))

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: AgentConversationRepository.didChangeNotification,
            object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(repository.replaceAll(rows))
        XCTAssertEqual(posts, 0)
    }

    // MARK: - What the exporters read

    func testEncodedJSONForSyncRoundTripsThroughJSONSerialization() {
        let repository = makeRepository()
        let rows = [conversation("uploaded"), conversation("also uploaded")]
        XCTAssertTrue(repository.replaceAll(rows))

        guard let data = repository.encodedJSONForSync() else {
            return XCTFail("the row builder needs bytes")
        }
        let decoded = try? JSONSerialization.jsonObject(with: data)
        XCTAssertEqual((decoded as? [Any])?.count, 2,
                       "the sync row builder and the DR snapshot both go through this")
        XCTAssertEqual(try? JSONDecoder().decode([AgentConversation].self, from: data).map(\.id),
                       rows.map(\.id))
    }

    // MARK: - Restore and reset

    func testRestoreCommitsTheCloudCopyAndUnfreezes() throws {
        let frozen = try makeFrozenRepository()
        let restored = [conversation("from the cloud")]
        let blob = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored))

        try frozen.applyRestore(blobData: JSONSerialization.data(withJSONObject: blob))

        XCTAssertFalse(frozen.isFrozen, "a user-confirmed restore is the one path back")
        XCTAssertEqual(frozen.conversations.map(\.id), restored.map(\.id))
        XCTAssertEqual(makeRepository().conversations.map(\.id), restored.map(\.id))
    }

    func testRestoreRejectsABlobItCannotDecodeAndLeavesTheHistoryIntact() {
        let repository = makeRepository()
        let rows = [conversation("mine")]
        XCTAssertTrue(repository.replaceAll(rows))

        XCTAssertThrowsError(try repository.applyRestore(blobData: Data("{}".utf8)))
        XCTAssertEqual(repository.conversations.map(\.id), rows.map(\.id))
        XCTAssertEqual(makeRepository().conversations.map(\.id), rows.map(\.id))
    }

    /// A wipe that only DELETED would leave a witness with no file, which is
    /// `.lostAfterCommit` — the next launch would present "reset all local
    /// data" as a storage fault.
    func testWipeLeavesACommittedEmptyStateRatherThanAFault() {
        let repository = makeRepository()
        XCTAssertTrue(repository.replaceAll([conversation("to be erased")]))

        repository.wipe()
        XCTAssertTrue(repository.conversations.isEmpty)

        let nextLaunch = makeRepository()
        XCTAssertTrue(nextLaunch.conversations.isEmpty)
        XCTAssertFalse(nextLaunch.isFrozen)
    }

    /// The reset flow purges the legacy key AFTER wiping the file. A kill in
    /// between must not have the next launch call the directory a first run and
    /// re-migrate exactly what the user asked to erase.
    func testWipeIsNotUndoneByTheLegacyBlobStillBeingThere() throws {
        try seedLegacyConversations([conversation("erased")])
        let repository = makeRepository(legacy: suite)
        XCTAssertFalse(repository.conversations.isEmpty, "fixture guard")

        repository.wipe()

        let nextLaunch = makeRepository(legacy: suite)
        XCTAssertTrue(nextLaunch.conversations.isEmpty)
    }

    // MARK: - Telling the user

    /// THE PROBE. Shred `conversations.json`, lose the `.bak`, relaunch: the
    /// chat list renders EMPTY, a new round is accepted and shown, every save
    /// is refused, and the next launch has nothing — indefinitely, because only
    /// a user-initiated restore clears the fault and nothing would prompt one.
    ///
    /// Every part of that posture is deliberate EXCEPT the silence. `isDegraded`
    /// existed with zero consumers, which is the swallowed `catch {}` this
    /// series removed, relocated from an empty error handler to a flag nobody
    /// read. So this asserts on the BANNER's predicate, not on the flag: the
    /// flag was already true when the bug was filed.
    func testProbe_AFrozenRepositoryRaisesTheStorageFaultBanner() throws {
        let storageName = "AgentConversationRepositoryTests-\(UUID().uuidString)"
        let location = TestStorage.reset(storageName)
        defer { TestStorage.tearDown(storageName) }
        let storeDefaults = UserDefaults(suiteName: storageName)!
        let eventStore = EventStore(defaults: storeDefaults,
                                    storage: location,
                                    seedsSampleDataIfEmpty: false)
        let types = EventTypeTemplateStore(defaults: storeDefaults)

        let healthy = makeRepository()
        XCTAssertFalse(
            StorageFaultBannerState(store: eventStore,
                                    eventTypeStore: types,
                                    conversations: healthy).isDegraded,
            "fixture guard: nothing else in the app is degraded, so the assertions below "
            + "can only be about the chat file")

        let frozen = try makeFrozenRepository()
        XCTAssertTrue(frozen.conversations.isEmpty, "fixture guard: the chat list renders empty")

        let service = AgentService(repository: frozen)
        service.createNewConversation()
        service.sendMessage("typed into a store that cannot keep it")
        XCTAssertFalse(service.conversations.isEmpty,
                       "fixture guard: the UI accepts the round exactly as it always did")
        XCTAssertTrue(makeRepository().conversations.isEmpty,
                      "fixture guard: and the next launch does not have it")

        let banner = StorageFaultBannerState(store: eventStore,
                                             eventTypeStore: types,
                                             conversations: frozen)
        XCTAssertTrue(banner.isDegraded,
                      "an unreadable chat file must reach the USER — the export suppression and "
                      + "the snapshot gate protect the cloud copy, not the person typing")
        XCTAssertTrue(banner.isUnreadable,
                      "and it is the \"could not be read, restore from a backup\" wording, not "
                      + "the \"a save did not complete\" one")
    }

    /// A write that does not LAND is not a freeze — the file was never proven
    /// unreadable, the bytes just did not get there — so nothing in the load
    /// path would ever raise the flag. It has to be raised at the failure, and
    /// it has to publish, or a view already on screen never redraws.
    func testAWriteThatCouldNotLandRaisesDegradedMidSessionAndPublishes() {
        let repository = makeRepository()
        XCTAssertTrue(repository.replaceAll([conversation("landed")]))
        XCTAssertFalse(repository.isDegraded, "fixture guard: a healthy store shows no banner")

        let publishes = Counter()
        let subscription = repository.objectWillChange.sink { _ in publishes.value += 1 }
        defer { subscription.cancel() }

        // The directory becomes a regular FILE: nothing was proven unreadable,
        // but no commit can be made either.
        try? FileManager.default.removeItem(at: directory)
        FileManager.default.createFile(atPath: directory.path, contents: Data())

        XCTAssertFalse(repository.replaceAll([conversation("did not land")]))
        XCTAssertFalse(repository.isFrozen, "fixture guard: this is the write half, not the read half")
        XCTAssertTrue(repository.isDegraded,
                      "\"a save did not complete\" is the other thing the banner says")
        XCTAssertGreaterThan(publishes.value, 0,
                             "a flag that does not publish cannot raise a banner mid-session")
    }

    /// The two wordings are not interchangeable: "could not be read" tells the
    /// user to restart and then restore, "a save did not complete" tells them
    /// their previous data is intact. A write that failed over a readable file
    /// must not claim the first.
    func testAWriteFailureAsksForTheWriteFailedWordingNotTheRestoreOne() throws {
        let storageName = "AgentConversationRepositoryTests-\(UUID().uuidString)"
        let location = TestStorage.reset(storageName)
        defer { TestStorage.tearDown(storageName) }
        let storeDefaults = UserDefaults(suiteName: storageName)!
        let eventStore = EventStore(defaults: storeDefaults,
                                    storage: location,
                                    seedsSampleDataIfEmpty: false)
        let types = EventTypeTemplateStore(defaults: storeDefaults)

        let repository = makeRepository()
        XCTAssertTrue(repository.replaceAll([conversation("landed")]))
        try? FileManager.default.removeItem(at: directory)
        FileManager.default.createFile(atPath: directory.path, contents: Data())
        XCTAssertFalse(repository.replaceAll([conversation("did not land")]))

        let banner = StorageFaultBannerState(store: eventStore,
                                             eventTypeStore: types,
                                             conversations: repository)
        XCTAssertTrue(banner.isDegraded)
        XCTAssertFalse(banner.isUnreadable, "nothing here was proven unreadable")
    }

    /// The banner is not dismissible — it comes down when the condition does,
    /// so the condition has to actually clear on the two paths that end it.
    func testTheDegradedFlagClearsOnTheRestoreAndTheWipe() throws {
        let restored = try makeFrozenRepository()
        XCTAssertTrue(restored.isDegraded, "fixture guard")
        try restored.applyRestore(blobData: JSONEncoder().encode([conversation("from the cloud")]))
        XCTAssertFalse(restored.isDegraded)

        let wiped = try makeFrozenRepository()
        XCTAssertTrue(wiped.isDegraded, "fixture guard")
        wiped.wipe()
        XCTAssertFalse(wiped.isDegraded,
                       "\"reset all local data\" is a state the user asked for, not a fault")
    }

    // MARK: - The other half of "one owner rather than N caches"

    /// THE PROBE. Naming an owner fixed the READ side only. `AgentChatView`
    /// and `CalendarEventChatView` each `@StateObject` their own
    /// `AgentService`; each copied `repository.conversations` once at init and
    /// wrote its whole array back on every save, so a live one reverted
    /// anything that moved the file underneath it.
    ///
    /// This is the sharpest of the three, because a user-confirmed restore is
    /// the ONLY exit from a freeze — and a frozen session is by definition one
    /// with a chat view open, showing `[]`, being told to restore. The restore
    /// lands, the view still renders the pre-restore array, one round writes
    /// it back over the restored file, and `didChangeNotification` then wakes
    /// the sync sink and uploads the clobber over the cloud copy the restore
    /// came from.
    func testProbe_ARestoreReachesALiveAgentService() throws {
        let repository = makeRepository()
        let live = AgentService(repository: repository)          // the open Agent tab
        live.createNewConversation()
        let localID = try XCTUnwrap(live.currentConversationID)

        // Settings → restore from cloud. `RestoreCoordinator` hands the blob
        // to the repository, which owns the file.
        let cloud = conversation("from the cloud")
        try repository.applyRestore(blobData: JSONEncoder().encode([cloud]))

        XCTAssertEqual(live.conversations.map(\.id), [cloud.id],
                       "the open chat view must render the restored history, not the array it "
                       + "snapshotted before the restore")
        XCTAssertEqual(live.currentConversationID, cloud.id,
                       "and it cannot stay pointed at a conversation the restore replaced")
        XCTAssertNotEqual(live.conversations.map(\.id), [localID], "fixture guard")

        // The next round after the restore. This is the write that used to
        // destroy it — locally, and then in the cloud.
        live.createNewConversation()
        XCTAssertTrue(repository.conversations.contains { $0.id == cloud.id })
        XCTAssertTrue(makeRepository().conversations.contains { $0.id == cloud.id },
                      "the restored conversation must still be on disk after the live service saves")
        XCTAssertFalse(makeRepository().conversations.contains { $0.id == localID },
                       "and the pre-restore conversation must not come back")
    }

    /// Same shape for "reset all local data": `AgentSettingsView` calls
    /// `wipe()`, and a live service then re-committed the erased transcript on
    /// its next save.
    func testProbe_AResetReachesALiveAgentService() {
        let repository = makeRepository()
        let live = AgentService(repository: repository)
        live.createNewConversation()
        live.sendMessage("erase me")
        XCTAssertTrue(repository.conversations.contains { conversation in
            conversation.messages.contains { $0.content == "erase me" }
        }, "fixture guard")

        repository.wipe()
        XCTAssertTrue(live.conversations.isEmpty,
                      "the chat list must empty out with the reset the user just confirmed")

        live.createNewConversation()
        let onDisk = makeRepository().conversations.flatMap { $0.messages.map(\.content) }
        XCTAssertFalse(onDisk.contains("erase me"),
                       "a live service must not resurrect what \"reset all local data\" erased")
    }

    /// And between the two views. Both are alive at once — the event sheet is
    /// presented over the tab — so the one that started earlier held an array
    /// that predated the other's rounds and replaced them wholesale.
    func testProbe_TwoLiveServicesDoNotClobberEachOther() throws {
        let repository = makeRepository()
        let tab = AgentService(repository: repository)           // AgentChatView
        let sheet = AgentService(repository: repository)         // CalendarEventChatView

        tab.createNewConversation()
        let tabID = try XCTUnwrap(tab.currentConversationID)

        sheet.createNewConversation()
        let sheetID = try XCTUnwrap(sheet.currentConversationID)

        let onDisk = makeRepository().conversations.map(\.id)
        XCTAssertEqual(onDisk.count, 2,
                       "the sheet's save wrote an array snapshotted before the tab's conversation existed")
        XCTAssertTrue(onDisk.contains(tabID))
        XCTAssertTrue(onDisk.contains(sheetID))
        XCTAssertTrue(tab.conversations.contains { $0.id == sheetID },
                      "and the tab's own list has to show the round the sheet just committed")
    }

    /// The guard that keeps the subscription from being a new bug: a frozen
    /// repository REFUSES the write and keeps last-known-good, which is `[]`.
    /// If that refusal reached the cache, the user's typing would vanish from
    /// the screen mid-session — the opposite of the deliberate posture pinned
    /// by `testProbe_AFrozenRepositoryRaisesTheStorageFaultBanner`.
    func testARefusedWriteDoesNotEmptyTheLiveConversationList() throws {
        let frozen = try makeFrozenRepository()
        let live = AgentService(repository: frozen)
        live.createNewConversation()
        live.sendMessage("typed into a store that cannot keep it")

        XCTAssertFalse(live.conversations.isEmpty,
                       "the UI keeps accepting rounds while frozen; the banner is what tells the user")
        XCTAssertTrue(frozen.conversations.isEmpty, "fixture guard: the owner stays at last-known-good")
    }

    /// The other guard. Our own commit posts too, and lands in the same
    /// subscription — so a reload that did not check whether the owner had
    /// actually moved would rebuild the live message list on every keystroke,
    /// deleting the loading bubble (the repository deliberately does not store
    /// it) and stranding the spinner with nothing on screen.
    func testAServiceOwnCommitDoesNotRebuildItsOwnMessageList() throws {
        let repository = makeRepository()
        let live = AgentService(repository: repository)
        live.createNewConversation()
        let id = try XCTUnwrap(live.currentConversationID)

        live.sendMessage("one round")

        XCTAssertEqual(live.currentConversationID, id, "our own save must not re-point the view")
        XCTAssertTrue(live.messages.contains { $0.isLoading },
                      "the request in flight owns `messages`; the commit it triggered must not "
                      + "reach back in and rebuild them from the stored transcript")
        XCTAssertEqual(live.messages.filter { !$0.isLoading }.map(\.content), ["one round"])
    }
}

/// A reference box so the Combine sink above mutates something shared rather
/// than a captured `var`, which strict concurrency will not let a
/// non-isolated closure touch.
private final class Counter: @unchecked Sendable {
    var value = 0
}
