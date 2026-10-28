//
//  WristGestureTrail.swift
//  DoneWatch
//
//  A troubleshooting trail of the today page's touches, written on the
//  watch itself so a device build can be read back with devicectl: when a
//  finger went down, when the hold armed, what it made, the drag, the
//  scroll view's phases, why a hold was given up, the picker, the lift.
//  Off unless Settings → Gesture log is on or the app was launched with
//  `-wristGestureLog`. One line per moment, newest last; the file is kept
//  small by dropping its older half when it outgrows `capacity`.
//

import Foundation

nonisolated enum WristGestureTrail {
    static let enabledKey = "wrist.gestureLog"
    static let launchArgument = "-wristGestureLog"
    static let capacity = 64 * 1024
    /// Drag samples between grid steps are noted at most this often.
    static let sampleInterval: TimeInterval = 0.15

    private static let launchedWithLog = ProcessInfo.processInfo.arguments.contains(launchArgument)

    static var isEnabled: Bool {
        launchedWithLog || UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Library/Application Support/WristGesture/trail.log in the app's
    /// container.
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("WristGesture", isDirectory: true)
            .appendingPathComponent("trail.log", isDirectory: false)
    }

    private static let queue = DispatchQueue(label: "wrist.gesture-trail", qos: .utility)
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()
    /// Touched on the queue only.
    nonisolated(unsafe) private static var wroteHeader = false
    /// Touched on the main thread only.
    nonisolated(unsafe) private static var lastSampleAt = Date.distantPast

    static func note(_ text: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = text()
        let at = Date()
        queue.async { write(line, at: at) }
    }

    /// A drag sample: noted when `step` (the range changed) or when enough
    /// time has passed since the last sample noted.
    static func sample(_ text: @autoclosure () -> String, step: Bool) {
        guard isEnabled else { return }
        let now = Date()
        guard step || now.timeIntervalSince(lastSampleAt) >= sampleInterval else { return }
        lastSampleAt = now
        note(text())
    }

    private static func write(_ line: String, at date: Date) {
        let url = fileURL
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var text = ""
            if !wroteHeader {
                wroteHeader = true
                let info = Bundle.main.infoDictionary
                let version = info?["CFBundleShortVersionString"] as? String ?? "?"
                let build = info?["CFBundleVersion"] as? String ?? "?"
                text += "\(formatter.string(from: date)) launch \(version) (\(build))\n"
            }
            text += "\(formatter.string(from: date)) \(line)\n"
            let data = Data(text.utf8)
            if !manager.fileExists(atPath: url.path) {
                try data.write(to: url)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            let size = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            if Int(size) + data.count > capacity { trim(url) }
        } catch {
            // A trail that cannot be written is no trail; the app goes on.
        }
    }

    /// Keeps the newer half of the file, from a line's start.
    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        var cut = data.count - capacity / 2
        while cut < data.count, data[cut] != UInt8(ascii: "\n") { cut += 1 }
        let kept = cut < data.count ? data.subdata(in: (cut + 1)..<data.count) : Data()
        try? kept.write(to: url, options: .atomic)
    }
}
