//
//  ConflictShelf.swift
//  Done
//
//  Where the losing side of a sync conflict goes — design §6.1 and §6.3
//  (ConflictShelf row) of Docs/sync/00-realtime-sync-design.md. I7: a
//  conflict never loses bytes; the shelf is the ONLY copy of the version
//  that lost, so a failed append refuses the whole page (the caller's
//  job: `append` returns false and the page is not applied).
//
//  - Location: its own sibling directory `Application Support/Sync/`
//    (`Sync-TestHost` under XCTest), never inside `EventStore/`, whose
//    init sweep deletes anything off its whitelist. An unresolvable base
//    falls back to a path under `/dev/null` that cannot be created, so
//    appends refuse and nothing else freezes — the `OccurrenceKeyMetadataStore`
//    precedent.
//  - Shape: append-only JSON lines `{uid, table, id, seq, reason, row}`
//    with the whole row. Deduplicated by `(uid, table, id, seq)` before
//    appending: a re-pulled page re-reaches the same rows, and the seq is
//    always the INCOMING row's (also for a dirty local version shelved
//    under a tombstone), so the retry is idempotent instead of a second
//    line.
//  - Durability (S10): appends go to the page cache; before the PATCH that
//    pushes a local winner leaves, the caller runs `flushDurably()`, one
//    `fcntl(F_FULLFSYNC)` per batch. Plain `fsync` does not promise the
//    bytes survive power loss on Apple platforms, and the loser's other
//    copy (on the server) is overwritten the moment that PATCH lands. The
//    sync call is an injected seam (`FullSync`) so a test can see that it
//    runs, on which file, and what a failure does.
//  - Erase: `ConflictShelf.wipe()` is called by name in `resetAllLocalData`.
//    It works through a fresh instance, so a long-lived instance must not
//    trust anything it remembers about the file: the dedupe cache is keyed
//    on the file's identity (device, inode, size, mtime), and a flush that
//    finds the file gone owes nothing — the erase took the bytes it owed.
//  - Backup: included, like every Application Support store — the rows are
//    the user's own account data.
//
//  Phase 1 has no UI over it.
//

import Foundation

enum ConflictShelfReason: String, Equatable {
    /// The dirty row met a peer's edit: the incoming row lost.
    case conflict
    /// A pending local delete met a peer's edit: the incoming row lost.
    case pendingDelete = "pending_delete"
    /// A tombstone met a dirty local row: the local version lost.
    case tombstoneDirtyLocal = "tombstone_dirty_local"
    /// user_settings keys that lost the per-key merge.
    case settingsKeys = "settings_keys"
    /// A record a parent's tombstone cascade prunes (design §6.1, fresh-eyes
    /// B2): the local version was dirty or never uploaded. The line's seq is
    /// the PARENT tombstone's seq.
    case cascade
}

struct ConflictShelfEntry {
    let uid: String
    let table: String
    let id: String
    /// Always the incoming row's seq.
    let seq: Int64
    let reason: String
    let row: [String: Any]

    init(uid: String, table: String, id: String, seq: Int64, reason: ConflictShelfReason, row: [String: Any]) {
        self.init(uid: uid, table: table, id: id, seq: seq, reasonText: reason.rawValue, row: row)
    }

    private init(uid: String, table: String, id: String, seq: Int64, reasonText: String, row: [String: Any]) {
        self.uid = uid
        self.table = table
        self.id = id
        self.seq = seq
        self.reason = reasonText
        self.row = row
    }

    struct DedupeKey: Hashable {
        let uid: String
        let table: String
        let id: String
        let seq: Int64
    }

    var dedupeKey: DedupeKey { DedupeKey(uid: uid, table: table, id: id, seq: seq) }

    /// One line, newline included. nil when the row is not JSON.
    func jsonLine() -> Data? {
        let object: [String: Any] = [
            "uid": uid, "table": table, "id": id,
            "seq": NSNumber(value: seq), "reason": reason, "row": row,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        data.append(0x0A)
        return data
    }

    init?(jsonLine: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
              let uid = object["uid"] as? String,
              let table = object["table"] as? String,
              let id = object["id"] as? String,
              let seq = (object["seq"] as? NSNumber)?.int64Value,
              let reason = object["reason"] as? String,
              let row = object["row"] as? [String: Any]
        else { return nil }
        self.init(uid: uid, table: table, id: id, seq: seq, reasonText: reason, row: row)
    }
}

final class ConflictShelf {
    static let productionDirectoryName = "Sync"
    static let testHostDirectoryName = "Sync-TestHost"
    static let filename = "conflict-shelf.jsonl"

    /// The durability syscall on an open descriptor; -1 is a failure.
    typealias FullSync = (_ fd: Int32) -> Int32

    static let systemFullSync: FullSync = { fd in fcntl(fd, F_FULLFSYNC) }

    static var productionDirectory: URL {
        let name = EventStorageLocation.isRunningUnderXCTest ? testHostDirectoryName : productionDirectoryName
        guard let base = try? EventStorageLocation.applicationSupport() else {
            return URL(fileURLWithPath: "/dev/null").appendingPathComponent(name, isDirectory: true)
        }
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// The erase's entry point: empties the production shelf.
    static func wipe() {
        ConflictShelf(directory: productionDirectory).wipe()
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    private let fullSync: FullSync

    /// Which file, at which length and modification, `knownKeys` was read
    /// from. Size alone is not enough: another instance can wipe the shelf
    /// and write a different line of the same length.
    private struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int

        init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            mtimeSeconds = Int(info.st_mtimespec.tv_sec)
            mtimeNanoseconds = Int(info.st_mtimespec.tv_nsec)
        }
    }

    /// The dedupe keys on disk, valid while the open file still has
    /// `knownIdentity`; any other identity reloads them from that file.
    private var knownKeys: Set<ConflictShelfEntry.DedupeKey> = []
    private var knownIdentity: FileIdentity?

    /// Whether an append landed since the last successful `flushDurably()`.
    private(set) var hasUnflushedAppends = false

    init(directory: URL, fullSync: @escaping FullSync = ConflictShelf.systemFullSync) {
        self.directory = directory
        self.fullSync = fullSync
    }

    // MARK: Appending

    /// Appends `entry` unless a line with its `(uid, table, id, seq)` is
    /// already there. True when the entry is on the shelf afterwards
    /// (appended now, or already present); false when it could not be
    /// written — the caller refuses the page. A short write is cut back off
    /// the file and reported as a failure. `eraseToken`
    /// (`LocalDataEraseEpoch.capture()` taken before the pull) makes an
    /// append after an erase began refuse too.
    func append(_ entry: ConflictShelfEntry, eraseToken: Int? = nil) -> Bool {
        if let eraseToken, LocalDataEraseEpoch.isStale(eraseToken) { return false }
        guard let line = entry.jsonLine() else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let fd = open(fileURL.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { return false }
        guard refreshKnownKeys(fd: fd, identity: FileIdentity(before)) else { return false }
        if knownKeys.contains(entry.dedupeKey) { return true }

        let written = line.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += n
            }
            return offset
        }
        guard written == line.count else {
            // A torn line would glue itself onto the next append; cut it.
            _ = ftruncate(fd, before.st_size)
            knownIdentity = nil
            return false
        }
        knownKeys.insert(entry.dedupeKey)
        var after = stat()
        knownIdentity = fstat(fd, &after) == 0 ? FileIdentity(after) : nil
        hasUnflushedAppends = true
        return true
    }

    // MARK: Durability

    /// `FullSync` on the shelf file (and, best effort, its directory, for a
    /// file the batch created). Call once per batch, before the PATCH that
    /// pushes a local winner. True when nothing is pending, when the file is
    /// gone (an erase removed what was owed), or when the sync succeeded;
    /// false keeps the batch owed.
    @discardableResult
    func flushDurably() -> Bool {
        guard hasUnflushedAppends else { return true }
        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                hasUnflushedAppends = false
                knownIdentity = nil
                return true
            }
            return false
        }
        let result = fullSync(fd)
        close(fd)
        guard result != -1 else { return false }
        let dirFd = open(directory.path, O_RDONLY | O_CLOEXEC)
        if dirFd >= 0 {
            _ = fullSync(dirFd)
            close(dirFd)
        }
        hasUnflushedAppends = false
        return true
    }

    // MARK: Reading

    /// Every line that parses, in file order.
    func entries() -> [ConflictShelfEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return Self.parse(data)
    }

    // MARK: Erase

    func wipe() {
        try? FileManager.default.removeItem(at: directory)
        knownKeys = []
        knownIdentity = nil
        hasUnflushedAppends = false
    }

    // MARK: Plumbing

    private static func parse(_ data: Data) -> [ConflictShelfEntry] {
        data.split(separator: 0x0A).compactMap { ConflictShelfEntry(jsonLine: Data($0)) }
    }

    /// Reloads the dedupe keys from the open file unless they were read
    /// from a file with exactly this identity. False when the file cannot
    /// be read — the append refuses rather than risk a duplicate it cannot
    /// see.
    private func refreshKnownKeys(fd: Int32, identity: FileIdentity) -> Bool {
        guard identity != knownIdentity else { return true }
        guard let data = Self.readAll(fd: fd, size: Int(identity.size)) else {
            knownIdentity = nil
            return false
        }
        knownKeys = Set(Self.parse(data).map(\.dedupeKey))
        knownIdentity = identity
        return true
    }

    private static func readAll(fd: Int32, size: Int) -> Data? {
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let n = pread(fd, base + offset, buffer.count - offset, off_t(offset))
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if n == 0 { break }
                offset += n
            }
            return offset
        }
        guard read == size else { return nil }
        return data
    }
}
