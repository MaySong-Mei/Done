//
//  PersonAvatarStore.swift
//  Done
//
//  Person avatar JPEGs on disk. Moved verbatim out of EventPeoplePickerView.swift
//  so the local erase (shared with the Mac target) can purge them; the
//  UIImage load/save paths stay iOS-only.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stores uploaded person avatars as downscaled JPEGs on disk (Application
/// Support/PersonAvatars), keyed by a unique filename held on `Person`. Keeps
/// image bytes out of UserDefaults. An in-memory `NSCache` avoids re-reading
/// from disk on every render.
enum PersonAvatarStore {
    #if canImport(UIKit)
    private static let cache = NSCache<NSString, UIImage>()
    #endif

    /// Where the JPEGs live.
    ///
    /// Test-host aware, the same way `SpikeRunStore`, `EventTypeTemplateStore`,
    /// `AgentConversationRepository` and `OccurrenceKeyMetadataStore` already
    /// are. This was the ONE purge-capable store without the seam, and
    /// `removeAll()` below removes the whole directory — so a suite run on a
    /// device or simulator holding real data would have taken every contact
    /// photo the user ever attached, permanently, with the `avatarImageName`
    /// references still pointing at the gone files.
    private static var directoryName: String {
        EventStorageLocation.isRunningUnderXCTest ? "PersonAvatars-test-host" : "PersonAvatars"
    }

    /// Resolves WITHOUT creating. Used by the destructive paths: an accessor
    /// that mkdirs as a side effect made `removeAll()` create a directory in
    /// order to delete it on a device that never had an avatar.
    ///
    /// Not private, so a test can assert against the location the store
    /// ACTUALLY uses instead of hardcoding "PersonAvatars" — the hardcoding
    /// was half of why the first version of that test pointed at the real
    /// container.
    static var resolvedDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Resolves AND creates. Used by `save`.
    private static var directory: URL? {
        guard let dir = resolvedDirectory else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    #if canImport(UIKit)
    static func image(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = resolvedDirectory?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// Downscale + save as JPEG under a fresh unique filename; returns it.
    /// A new filename each time avoids stale `NSCache`/SwiftUI image reuse
    /// when a person's photo is replaced.
    static func save(_ image: UIImage) -> String? {
        let resized = image.resizedForAvatar()
        guard let data = resized.jpegData(compressionQuality: 0.85),
              let dir = directory else { return nil }
        let name = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            cache.setObject(resized, forKey: name as NSString)
            return name
        } catch {
            return nil
        }
    }

    #endif

    static func delete(named name: String) {
        #if canImport(UIKit)
        cache.removeObject(forKey: name as NSString)
        #endif
        if let url = resolvedDirectory?.appendingPathComponent(name) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Take every avatar, for "erase all local data" (gh#263).
    ///
    /// `delete(named:)` is reached only from the picker's replace and remove
    /// flows, so before this existed an erase left the JPEGs behind in a
    /// directory that iOS Device Backup includes.
    ///
    /// And it left them UNIDENTIFIABLE: the erase sets `people = []` first,
    /// which destroys every `Person.avatarImageName` — the only thing that
    /// said which file belonged to whom. Orphaned that way, not even a
    /// manual cleanup could tell them apart. These are photographs of other
    /// people, so the order of those two facts is the whole problem.
    ///
    /// The in-memory `cache` is cleared too: without it a wiped avatar can
    /// still render from memory for the rest of the process.
    static func removeAll() {
        #if canImport(UIKit)
        cache.removeAllObjects()
        #endif
        guard let dir = resolvedDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

#if canImport(UIKit)
private extension UIImage {
    /// Cap the longest side so saved avatars stay small.
    func resizedForAvatar(maxDimension: CGFloat = 256) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
#endif
