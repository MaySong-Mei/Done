//
//  MeAvatarStore.swift
//  Done
//
//  The Me tab's avatar file. Moved verbatim out of AnalysisView.swift so the
//  image backup coordinator (shared with the Mac target) can reach the raw
//  byte helpers; the UIImage conveniences stay iOS-only.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Saves the user's avatar image to a stable filename in Documents. Views
/// observe `meAvatarVersion` (via @AppStorage) to know when to reload.
enum MeAvatarStore {
    /// Redirected under XCTest, same reasoning as
    /// `EventStorageLocation.production` and `DiagnosticTrail.directory`:
    /// `DoneTests` runs inside Done.app's container, `Documents` is NOT
    /// redirected for it, and this store is purge-capable — `delete()` sits in
    /// `resetAllLocalData()`. Any test driving the erase would otherwise
    /// delete the dogfood user's own avatar, which is an image they chose and
    /// may no longer have the original of.
    ///
    /// Non-private so tests can assert against the path they are actually
    /// writing, and so the seam itself can be pinned.
    static var fileName: String {
        EventStorageLocation.isRunningUnderXCTest ? "me-avatar-test-host.jpg" : "me-avatar.jpg"
    }

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static var hasImage: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    #if canImport(UIKit)
    static func load() -> UIImage? {
        guard hasImage else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        let resized = downscale(image, maxEdge: 512)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    #endif

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Raw I/O for sync (Phase 1 of full-backup completion)
    //
    // The sync layer deals in bytes, not UIImage. These helpers let
    // `ImageBackupCoordinator` upload the current avatar to Supabase
    // Storage and write a freshly-downloaded one back to disk on restore
    // without re-encoding through `UIImage.jpegData` (which would change
    // bytes round-trip).

    /// Raw JPEG bytes of the current avatar, or nil if none on disk.
    static func loadData() -> Data? {
        guard hasImage else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Write raw JPEG bytes to the avatar slot. Caller-supplied bytes are
    /// assumed to be already-compressed JPEG (the sync layer fetches the
    /// exact bytes that were previously uploaded by the source device).
    static func writeRaw(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    #if canImport(UIKit)
    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let longestEdge = max(w, h)
        guard longestEdge > maxEdge else { return image }
        let scale = maxEdge / longestEdge
        let size = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    #endif
}
