//
//  EventResizeTweenState.swift
//  Done
//
//  The resize tween's state — the spike's speed variants, its flag, and its
//  trail — split out of EventResizeTween.swift without UIKit so the shared
//  SpikeModel (also built for the Mac) can read it. The tween itself stays
//  in EventResizeTween.swift.
//

import Foundation
import os

enum EventResizeTweenVariant: String, CaseIterable {
    case brisk
    case standard
    case soft

    var title: String {
        switch self {
        case .brisk: return "轻快"
        case .standard: return "标准"
        case .soft: return "柔和"
        }
    }

    /// One snap step under the finger: short enough never to trail it.
    var stepDuration: CFTimeInterval {
        switch self {
        case .brisk: return 0.07
        case .standard: return 0.1
        case .soft: return 0.14
        }
    }

    /// A length changed elsewhere: long enough to see which block changed.
    var editDuration: CFTimeInterval {
        switch self {
        case .brisk: return 0.2
        case .standard: return 0.28
        case .soft: return 0.36
        }
    }
}

enum EventResizeTweenFlag {
    static let spikeID = "event-resize-tween"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SpikeFeatureFlag.enabledKey(spikeID))
    }

    static var variant: EventResizeTweenVariant {
        UserDefaults.standard.string(forKey: SpikeFeatureFlag.variantKey(spikeID))
            .flatMap(EventResizeTweenVariant.init(rawValue:))
            ?? .standard
    }
}

/// File log, written only while the spike is on
/// (Library/Application Support/ResizeTween/resize_tween.log, pulled with
/// `devicectl device copy from`).
enum EventResizeTweenLog {
    private static let queue = DispatchQueue(label: "Done.EventResizeTweenLog")
    private static let maxBytes = 256 * 1024
    private static let timestamp = ISO8601DateFormatter()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "ResizeTween"
    )

    static func append(_ message: @autoclosure () -> String) {
        guard EventResizeTweenFlag.isEnabled else { return }
        let line = "\(timestamp.string(from: Date())) \(message())"
        logger.info("\(line, privacy: .public)")
        queue.async {
            let url = fileURL()
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > maxBytes {
                let rotated = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("ResizeTween", isDirectory: true)
            .appendingPathComponent("resize_tween.log")
    }
}
