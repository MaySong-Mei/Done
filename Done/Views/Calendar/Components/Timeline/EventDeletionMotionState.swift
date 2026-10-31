//
//  EventDeletionMotionState.swift
//  Done
//
//  The delete motion's state — the spike's flag, the registry of events a
//  person just deleted, and its trail — split out of EventDeletionMotion.swift
//  without UIKit so the shared EventStore (also built for the Mac) can mark
//  deletions. The motion itself stays in EventDeletionMotion.swift.
//

import Foundation
import os

enum EventDeletionMotionVariant: String, CaseIterable {
    /// 沙化:the block breaks into grains that blow off left → right.
    case dissolve
    /// 碎裂:a few shards jump and fall under gravity, spinning.
    case shatter
    /// 关电视:squashed to a bright line, then to a dot, then gone.
    case crtOff
    /// 掉落:loses its right-hand nail, swings, and drops.
    case fall
    /// 膨胀破裂:breathes in, swells like a balloon under pressure and pops —
    /// a shock ring, comic burst lines and droplets of its colour.
    case pop

    var title: String {
        switch self {
        case .dissolve: return "沙化飘散"
        case .shatter: return "碎裂下落"
        case .crtOff: return "关电视"
        case .fall: return "脱钉掉落"
        case .pop: return "膨胀破裂"
        }
    }
}

enum EventDeletionMotionFlag {
    static let spikeID = "event-delete-motion"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SpikeFeatureFlag.enabledKey(spikeID))
    }

    static var variant: EventDeletionMotionVariant {
        UserDefaults.standard.string(forKey: SpikeFeatureFlag.variantKey(spikeID))
            .flatMap(EventDeletionMotionVariant.init(rawValue:))
            ?? .dissolve
    }
}

final class EventDeletionMotionRegistry {
    enum Source: String {
        case local
        case remote
    }

    struct Mark: Equatable {
        let at: Date
        let source: Source
    }

    static let shared = EventDeletionMotionRegistry()

    /// How long after the store removes a row its block may still be
    /// claimed as a deletion ghost. The removal reaches the day host on the
    /// next SwiftUI pass — well inside this — and a host that renders later
    /// than this (a column re-mounted long after) must not resurrect it.
    static let lifetime: TimeInterval = 4

    /// Injectable so tests can drive the registry without UserDefaults.
    var isEnabled: () -> Bool = { EventDeletionMotionFlag.isEnabled }

    /// Part of a series that is gone while the series itself survives
    /// (`.single` / `.following`). Matched by the anchor day an occurrence id
    /// carries (`<series>-recur-<anchor>`, `CalendarLayout`), never by the
    /// series id alone — the series' other occurrences can still change id
    /// (an edit materializes an exception) without being deleted.
    private struct SeriesSpan {
        let firstAnchor: Int
        let lastAnchor: Int?
        let mark: Mark
    }

    private var marks: [UUID: Mark] = [:]
    private var seriesSpans: [UUID: [SeriesSpan]] = [:]

    /// Whole events: every block of these ids is gone.
    func mark<S: Sequence>(_ ids: S, source: Source, now: Date = Date()) where S.Element == UUID {
        guard isEnabled() else { return }
        prune(now: now)
        for id in ids {
            marks[id] = Mark(at: now, source: source)
            EventDeletionMotionLog.append("mark event=\(id.uuidString) source=\(source.rawValue)")
        }
    }

    /// Occurrences of `seriesID` anchored on `firstDay` through `lastDay`
    /// (`nil` = open-ended) are gone; both days are start-of-day instants.
    func markSeries(
        _ seriesID: UUID, from firstDay: Date, through lastDay: Date?,
        source: Source, now: Date = Date()
    ) {
        guard isEnabled() else { return }
        prune(now: now)
        let first = Int(firstDay.timeIntervalSince1970)
        let last = lastDay.map { Int($0.timeIntervalSince1970) }
        seriesSpans[seriesID, default: []].append(
            SeriesSpan(firstAnchor: first, lastAnchor: last, mark: Mark(at: now, source: source))
        )
        EventDeletionMotionLog.append(
            "mark series=\(seriesID.uuidString) anchors=\(first)...\(last.map(String.init) ?? "") source=\(source.rawValue)"
        )
    }

    /// Not consumed on read: a cross-midnight event has a block on two day
    /// hosts, and both should play.
    func mark(for id: UUID, now: Date = Date()) -> Mark? {
        guard let mark = marks[id], now.timeIntervalSince(mark.at) < Self.lifetime else { return nil }
        return mark
    }

    /// The span mark covering this recurring occurrence id, if any.
    func mark(forOccurrence occurrenceID: String, of seriesID: UUID, now: Date = Date()) -> Mark? {
        guard let spans = seriesSpans[seriesID],
              let anchor = Self.anchor(ofOccurrenceID: occurrenceID, seriesID: seriesID) else { return nil }
        return spans.last { span in
            now.timeIntervalSince(span.mark.at) < Self.lifetime
                && anchor >= span.firstAnchor
                && span.lastAnchor.map { anchor <= $0 } ?? true
        }?.mark
    }

    /// `<series>-recur-<anchor>` and `<series>-allday-recur-<anchor>`.
    static func anchor(ofOccurrenceID occurrenceID: String, seriesID: UUID) -> Int? {
        let series = seriesID.uuidString
        for infix in ["-recur-", "-allday-recur-"] where occurrenceID.hasPrefix(series + infix) {
            return Int(occurrenceID.dropFirst(series.count + infix.count))
        }
        return nil
    }

    private func prune(now: Date) {
        marks = marks.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
        seriesSpans = seriesSpans
            .mapValues { $0.filter { now.timeIntervalSince($0.mark.at) < Self.lifetime } }
            .filter { !$0.value.isEmpty }
    }
}

/// File log, written only while the spike is on. Lives in the app
/// container (Library/Application Support/DeleteMotion/delete_motion.log)
/// so it can be pulled with `devicectl device copy from`.
enum EventDeletionMotionLog {
    private static let queue = DispatchQueue(label: "Done.EventDeletionMotionLog")
    private static let maxBytes = 256 * 1024
    private static let timestamp = ISO8601DateFormatter()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "DeleteMotion"
    )

    static func append(_ message: @autoclosure () -> String) {
        guard EventDeletionMotionFlag.isEnabled else { return }
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
            .appendingPathComponent("DeleteMotion", isDirectory: true)
            .appendingPathComponent("delete_motion.log")
    }
}
