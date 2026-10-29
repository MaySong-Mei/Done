//
//  EventCreationMotionState.swift
//  Done
//
//  The create motion's state — the spike's flag, the registry of events a
//  person just created, and its trail — split out of EventCreationMotion.swift
//  without UIKit so the shared EventStore (also built for the Mac) can mark
//  creations. The motion itself stays in EventCreationMotion.swift.
//

import Foundation
import os

enum EventCreationMotionVariant: String, CaseIterable {
    /// 聚沙成形:grains drift in from the upper left and settle left → right.
    case assemble
    /// 预览转实:a dashed draft outline fills with the block from the top.
    case inkFill
    /// 落钉:drops in from just above and is pinned with a small bounce.
    case pinDrop
    /// 开电视:a dot stretches to a bright line, then opens into the block.
    case crtOn

    var title: String {
        switch self {
        case .assemble: return "聚沙成形"
        case .inkFill: return "预览转实"
        case .pinDrop: return "落钉"
        case .crtOn: return "开电视"
        }
    }
}

enum EventCreationMotionFlag {
    static let spikeID = "event-create-motion"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SpikeFeatureFlag.enabledKey(spikeID))
    }

    static var variant: EventCreationMotionVariant {
        UserDefaults.standard.string(forKey: SpikeFeatureFlag.variantKey(spikeID))
            .flatMap(EventCreationMotionVariant.init(rawValue:))
            ?? .assemble
    }
}

final class EventCreationMotionRegistry {
    enum Source: String {
        case local
        case remote
    }

    struct Mark: Equatable {
        let at: Date
        let source: Source
    }

    static let shared = EventCreationMotionRegistry()

    /// How long after a create its block may still be claimed by a day host.
    /// The insert reaches the host on the next SwiftUI pass; a column first
    /// rendered later than this (re-mounted long after) shows it plainly.
    static let lifetime: TimeInterval = 4

    /// More new rows than this in one remote page is an import (first sync,
    /// restore from the cloud), not someone creating events: none play.
    static let maxRemoteArrivals = 8

    /// Injectable so tests can drive the registry without UserDefaults.
    var isEnabled: () -> Bool = { EventCreationMotionFlag.isEnabled }

    private var marks: [UUID: Mark] = [:]

    func mark<S: Sequence>(_ ids: S, source: Source, now: Date = Date()) where S.Element == UUID {
        guard isEnabled() else { return }
        marks = marks.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
        for id in ids {
            marks[id] = Mark(at: now, source: source)
            EventCreationMotionLog.append("mark event=\(id.uuidString) source=\(source.rawValue)")
        }
    }

    /// Not consumed on read: a cross-midnight event has a block on two day
    /// hosts, and both should play.
    func mark(for id: UUID, now: Date = Date()) -> Mark? {
        guard let mark = marks[id], now.timeIntervalSince(mark.at) < Self.lifetime else { return nil }
        return mark
    }

    /// Whether anything was created here within `window` — asked when the
    /// drag-create draft goes away: saved (a local mark just landed, so the
    /// draft is kept to turn into the block) or cancelled (nothing, it goes).
    func hasLocalMark(within window: TimeInterval, now: Date = Date()) -> Bool {
        marks.values.contains { $0.source == .local && now.timeIntervalSince($0.at) < window }
    }
}

/// File log, written only while the spike is on
/// (Library/Application Support/CreateMotion/create_motion.log, pulled with
/// `devicectl device copy from`).
enum EventCreationMotionLog {
    private static let queue = DispatchQueue(label: "Done.EventCreationMotionLog")
    private static let maxBytes = 256 * 1024
    private static let timestamp = ISO8601DateFormatter()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "CreateMotion"
    )

    static func append(_ message: @autoclosure () -> String) {
        guard EventCreationMotionFlag.isEnabled else { return }
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
            .appendingPathComponent("CreateMotion", isDirectory: true)
            .appendingPathComponent("create_motion.log")
    }
}

/// The layers one create motion added. The host cancels it when the block
/// leaves (recycled mid-motion); cancelling removes the pieces and stops the
/// pending reveal, and the host shows the block itself.
