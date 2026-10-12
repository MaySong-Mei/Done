import Foundation
import UIKit

final class AgenticIntakeAssetStore {
    typealias ImageProcessor = (Data) throws -> (data: Data, size: CGSize)

    struct ImportedImage: Identifiable {
        let id: UUID
        let data: Data

        init(id: UUID = UUID(), data: Data) {
            self.id = id
            self.data = data
        }
    }

    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let maxPixelDimension: CGFloat
    private let jpegQuality: CGFloat
    private let imageProcessor: ImageProcessor?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        maxPixelDimension: CGFloat = 2048,
        jpegQuality: CGFloat = 0.82,
        imageProcessor: ImageProcessor? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL ?? Self.defaultBaseDirectoryURL(fileManager: fileManager)
        self.maxPixelDimension = maxPixelDimension
        self.jpegQuality = jpegQuality
        self.imageProcessor = imageProcessor
    }

    func saveImages(_ images: [ImportedImage], for eventID: UUID) throws -> [AgenticIntakeImageRef] {
        guard !images.isEmpty else { return [] }
        let eventDirectory = baseDirectoryURL.appendingPathComponent(eventID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: eventDirectory, withIntermediateDirectories: true, attributes: nil)

        return try images.map { imported in
            let processed: (data: Data, size: CGSize)
            if let imageProcessor {
                processed = try imageProcessor(imported.data)
            } else {
                processed = try processedJPEG(from: imported.data)
            }
            let fileURL = eventDirectory.appendingPathComponent("\(imported.id.uuidString).jpg")
            try processed.data.write(to: fileURL, options: .atomic)
            let relativePath = eventID.uuidString + "/" + fileURL.lastPathComponent
            return AgenticIntakeImageRef(
                id: imported.id,
                relativePath: relativePath,
                pixelWidth: Int(processed.size.width.rounded()),
                pixelHeight: Int(processed.size.height.rounded()),
                fileSizeBytes: processed.data.count
            )
        }
    }

    func loadImage(for ref: AgenticIntakeImageRef) -> UIImage? {
        let url = absoluteURL(for: ref)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func absoluteURL(for ref: AgenticIntakeImageRef) -> URL {
        baseDirectoryURL.appendingPathComponent(ref.relativePath)
    }

    func removeAssets(for intake: AgenticIntakeRecord) {
        removeAssets(for: intake.images)
    }

    func removeAssets(for refs: [AgenticIntakeImageRef]) {
        guard !refs.isEmpty else { return }
        for ref in refs {
            let url = absoluteURL(for: ref)
            try? fileManager.removeItem(at: url)
        }

        let parentDirs: Set<URL> = Set(refs.compactMap { ref in
            guard let slashIndex = ref.relativePath.lastIndex(of: "/") else { return nil }
            let parentRelativePath = String(ref.relativePath[..<slashIndex])
            return baseDirectoryURL.appendingPathComponent(parentRelativePath, isDirectory: true)
        })
        for dir in parentDirs {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fileManager.removeItem(at: dir)
            }
        }
    }

    private func processedJPEG(from data: Data) throws -> (data: Data, size: CGSize) {
        guard let image = UIImage(data: data) else {
            throw AssetStoreError.invalidImageData
        }
        let resized = resizeIfNeeded(image)
        guard let jpeg = resized.jpegData(compressionQuality: jpegQuality) else {
            throw AssetStoreError.encodingFailed
        }
        return (jpeg, resized.size)
    }

    private func resizeIfNeeded(_ image: UIImage) -> UIImage {
        let size = image.size
        let maxDimension = max(size.width, size.height)
        guard maxDimension.isFinite, maxDimension > maxPixelDimension, maxPixelDimension > 0 else {
            return image
        }

        let scale = maxPixelDimension / maxDimension
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Take EVERY asset, for "erase all local data" (gh#260).
    ///
    /// `removeAssets(for:)` above is per-ref and is reached only from the
    /// single-row delete path, which a wholesale `rawCalendarEvents = []`
    /// never enters — so before this existed, an erase left every attached
    /// photo on disk in a directory the doc below says is deliberately
    /// included in iOS Device Backup.
    ///
    /// The pre-fix exposure was a WINDOW, not permanent unreachability — an
    /// earlier version of this comment claimed the latter and a review
    /// disproved it. The reasoning was that
    /// `EventStore.scheduleStartupOrphanAssetSweep` refuses while every row
    /// array is empty ("no rows loaded"), which looked like the permanent
    /// post-erase state. It is not: `adopt` marks a wiped slot SEEDABLE and
    /// `load()` then seeds the demo events, so the arrays are NOT empty on
    /// the next launch and the sweep runs.
    ///
    /// So the real window was: from the erase until the next launch's
    /// background sweep — plus any photo inside the sweep's own grace
    /// period, plus indefinitely for a user who erases and never relaunches.
    /// Narrower than "forever", wide enough to matter, and the fix is the
    /// same either way: the erase should not depend on a later sweep to
    /// finish erasing.
    ///
    /// The refusal is left alone. It exists to stop a half-loaded launch
    /// deleting live assets, and with the erase purging wholesale there is
    /// nothing left for the sweep to do on this path.
    ///
    /// Removes the directory itself rather than walking it. A missing
    /// directory is success — the erase is confirmed by the user and there
    /// is nothing to report.
    @discardableResult
    func removeAllAssets() -> Bool {
        // GATED, and the gate is not optional. `EventStorageLocation`'s own doc
        // for `ownsSharedAssetDirectory` says why: this directory is NOT
        // redirected under XCTest — it is one path for the whole container —
        // so a test-host store sweeping it "would delete the dogfood user's
        // photos". `EventStore.swift` honours that for the orphan sweep; a
        // first version of THIS method did not, which made any test that drove
        // the production erase destroy every real attached photo on the
        // machine running it.
        //
        // Refusing is the right answer rather than redirecting: there is
        // nothing to redirect to. A test that wants to exercise the purge
        // injects `baseDirectoryURL` and calls `removeAllAssets(at:)` below.
        guard EventStorageLocation.production.ownsSharedAssetDirectory else { return false }
        return Self.removeTree(at: baseDirectoryURL, fileManager: fileManager)
    }

    /// The purge against an EXPLICIT directory, for tests. Takes the URL so
    /// there is no way to aim it at the shared container by accident.
    @discardableResult
    func removeAllAssets(at directory: URL) -> Bool {
        Self.removeTree(at: directory, fileManager: fileManager)
    }

    private static func removeTree(at directory: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: directory)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true   // nothing to erase is success
        } catch {
            return false
        }
    }

    /// Images live under `Library/Application Support/AgenticIntakeAssets/`.
    /// This location is **deliberately included in iOS Device Backup**: we
    /// rely on it so user-attached event photos survive device loss when
    /// they're not separately synced to Supabase (CloudKit-based image sync
    /// is tracked in issue #16). Do **not** set
    /// `URLResourceKey.isExcludedFromBackupKey = true` on this directory or
    /// its contents without a follow-up cloud backup plan in place.
    nonisolated static func defaultBaseDirectoryURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport.appendingPathComponent("AgenticIntakeAssets", isDirectory: true)
    }

    enum AssetStoreError: LocalizedError {
        case invalidImageData
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return "Invalid image data"
            case .encodingFailed:
                return "Failed to encode image"
            }
        }
    }
}
