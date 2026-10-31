//
//  BillLog.swift
//  DoneMac
//
//  The dogfood evidence channel (plan Phase 6: "seven days of daily JSONL
//  with all budgets holding IS the ship evidence"). One line per app day:
//  the full counter snapshot plus which tripwires fired. Pure append via
//  the persistence actor's sibling-directory rule; readable later with
//  jq or by the observation panel.
//

import Foundation

@MainActor
final class BillLog {
    private let directory: URL
    private let calendar: Calendar

    /// Tripwires expected 0 — a nonzero value in a daily line is a
    /// regression alarm, the Fix Watch convention.
    static let tripwires: [MacWorkBill.Counter] = [
        .clockTicksWhileOccluded,
        .sidecarOrphansSeen,
        .sidecarUnreadableSeen,
        .persistWriteFailuresSeen,
        .preLoadMutationRefused,
        .indexShadowMismatches,
    ]

    init(location: EventStorageLocation, calendar: Calendar) throws {
        let storageDirectory = try location.directoryURL()
        directory = storageDirectory.deletingLastPathComponent()
            .appendingPathComponent(storageDirectory.lastPathComponent + "-BillLog", isDirectory: true)
        self.calendar = calendar
    }

    var fileURL: URL {
        directory.appendingPathComponent("work-bill.jsonl")
    }

    /// Append today's snapshot. Called on resign-active/terminate — cheap
    /// enough that duplicate lines per day are fine (readers take the last
    /// line per day).
    func appendSnapshot(_ bill: MacWorkBill, now: Date) {
        var object: [String: Any] = [:]
        let day = DayKey(date: now, calendar: calendar)
        object["day"] = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        object["at"] = ISO8601DateFormatter().string(from: now)
        object["counters"] = bill.snapshot()
        object["tripwiresFired"] = Self.tripwires
            .filter { bill.count($0) > 0 }
            .map(\.rawValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: fileURL, options: .atomic)
            }
        } catch {
            // Evidence-channel failure must not break the app; the panel
            // shows counters live regardless.
        }
    }
}
