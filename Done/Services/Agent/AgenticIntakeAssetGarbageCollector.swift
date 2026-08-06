//
//  AgenticIntakeAssetGarbageCollector.swift
//  Done
//
//  The other half of "delete the files last" (issue #145 A).
//
//  Deleting image files only after the rows that reference them are durable
//  chooses the recoverable failure direction on purpose: a kill in the middle
//  of a delete can now leave a file behind, but it can no longer destroy a
//  photo belonging to an event that survived. An orphan file is invisible to
//  the user and costs disk; a destroyed photo is gone for good.
//
//  This sweep is what makes "costs disk" temporary. It is deliberately timid,
//  because the blast radius of being wrong is the same unrecoverable loss the
//  ordering fix exists to prevent:
//
//  - a file is deleted only when NO event, log record or feedback record
//    references its relative path;
//  - and only when it is older than `minimumAge` (24h), so a photo written by
//    an in-flight attachment — saved to disk seconds before the row that will
//    reference it is committed, and possibly sitting in a composer draft that
//    has not been submitted yet — is never in scope;
//  - and never when the caller could not prove it read a complete reference
//    set — which means no storage fault AND every slot served from its own
//    committed primary, because a slot recovered from its backup is a whole
//    generation behind and the rows it lost still own their photos (see
//    `EventStore.startupOrphanAssetSweepRefusal`).
//
//  It is NOT a cloud deletion. `ImageBackupCoordinator` may already have
//  uploaded these bytes to Supabase and v1 does not coordinate deletion —
//  which is also why an orphan file on disk is a low-stakes leftover rather
//  than the last copy of anything.
//

import Foundation

nonisolated struct AgenticIntakeAssetGarbageCollector {
    /// A file must be at least this old to be considered abandoned. Sized to
    /// dwarf the real gap between "image written" and "row committed"
    /// (milliseconds) with room for an attachment the user picked, left in an
    /// unsubmitted composer, and came back to later in the day.
    static let defaultMinimumAge: TimeInterval = 24 * 60 * 60

    struct Outcome: Equatable {
        var scannedFiles = 0
        var deletedRelativePaths: [String] = []
        var keptReferenced = 0
        var keptTooYoung = 0
        var reclaimedBytes = 0

        var summary: String {
            "scanned=\(scannedFiles) deleted=\(deletedRelativePaths.count)"
            + " keptReferenced=\(keptReferenced) keptYoung=\(keptTooYoung)"
            + " reclaimedBytes=\(reclaimedBytes)"
        }
    }

    let baseDirectoryURL: URL
    let fileManager: FileManager
    let minimumAge: TimeInterval

    init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        minimumAge: TimeInterval = AgenticIntakeAssetGarbageCollector.defaultMinimumAge
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL
            ?? AgenticIntakeAssetStore.defaultBaseDirectoryURL(fileManager: fileManager)
        self.minimumAge = minimumAge
    }

    /// Remove abandoned image files. Safe to call off the main actor; does no
    /// I/O beyond the asset directory.
    ///
    /// `referencedRelativePaths` must be the FULL reference set. A caller that
    /// only has part of it (a slot that failed to read, an empty store) must
    /// not call this at all — a missing row makes its files look abandoned.
    @discardableResult
    func sweep(referencedRelativePaths: Set<String>, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        guard let eventDirectories = try? fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            // No directory yet (fresh install) is the common case, not an error.
            return outcome
        }

        for directory in eventDirectories {
            let isDirectory = (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var deletedHere = 0
            for file in files {
                outcome.scannedFiles += 1
                let relativePath = directory.lastPathComponent + "/" + file.lastPathComponent
                if referencedRelativePaths.contains(relativePath) {
                    outcome.keptReferenced += 1
                    continue
                }
                let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
                )
                // The NEWER of creation/modification: a file copied into place
                // can carry an old mtime, and erring young only delays a
                // sweep, while erring old deletes a live attachment.
                let stamps = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }
                guard let newest = stamps.max() else {
                    // No timestamps at all — cannot prove it is old, so keep it.
                    outcome.keptTooYoung += 1
                    continue
                }
                guard now.timeIntervalSince(newest) >= minimumAge else {
                    outcome.keptTooYoung += 1
                    continue
                }
                let size = values?.fileSize ?? 0
                guard (try? fileManager.removeItem(at: file)) != nil else { continue }
                deletedHere += 1
                outcome.deletedRelativePaths.append(relativePath)
                outcome.reclaimedBytes += size
            }

            // An event directory that is now empty is itself litter. Only ever
            // removed when THIS sweep emptied it, never when it arrived empty
            // (that is a directory `saveImages` just created for an import in
            // progress).
            //
            // `rmdir(2)`, not `contentsOfDirectory` + `removeItem`. The old
            // pair was a check and a RECURSIVE delete with a gap in between,
            // and this sweep runs detached while `AgenticIntakeAssetStore`
            // writes into these very directories on the main actor: a photo
            // landing inside that gap was deleted with the directory,
            // bypassing BOTH the reference guard and the age guard. `rmdir`
            // makes "is it empty?" and "remove it" one operation — it fails
            // with `ENOTEMPTY` rather than taking anything with it — so the
            // narrowest possible race resolves toward keeping the file.
            if deletedHere > 0 {
                directory.path.withCString { _ = rmdir($0) }
            }
        }

        return outcome
    }
}
