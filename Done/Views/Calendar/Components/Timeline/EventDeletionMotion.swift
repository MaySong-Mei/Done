//
//  EventDeletionMotion.swift
//  Done
//
//  Delete motion for timeline blocks — a harness feature spike
//  (`event-delete-motion`, variants picked in 观察站 → 手动 Spike 列表).
//
//  Three pieces, smallest surface first:
//    * `EventDeletionMotionFlag` — reads the spike's enabled/variant keys.
//      Off is king's shape: nothing is marked, so no block ever ghosts.
//    * `EventDeletionMotionRegistry` — which event ids were just deleted
//      (by this device or by a remote tombstone). `EventStore` marks;
//      `DayLayerHostView` asks when a pooled block leaves the day, which is
//      the only way it can tell a deletion from a scroll-out, a filter
//      change or a move to another day.
//    * `EventDeletionMotion.play` — the variants themselves, on a detached
//      block subtree the host hands over and forgets.
//

import UIKit
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

    var title: String {
        switch self {
        case .dissolve: return "沙化飘散"
        case .shatter: return "碎裂下落"
        case .crtOff: return "关电视"
        case .fall: return "脱钉掉落"
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

enum EventDeletionMotion {
    /// Plays `variant` over `ghost` — a block subtree already detached from
    /// the host's pool but still in its layer tree — and removes everything
    /// it added (and `ghost`) before calling `completion`. Returns the
    /// planned duration so the caller can log it. `lightweight` plays the
    /// plain fade instead — for the ghosts past the first few of one burst
    /// (a sync page of tombstones), so a burst can't hitch the main thread.
    @discardableResult
    static func play(
        _ variant: EventDeletionMotionVariant,
        ghost: CALayer,
        tint: UIColor,
        lightweight: Bool = false,
        completion: @escaping () -> Void
    ) -> CFTimeInterval {
        guard let parent = ghost.superlayer else {
            completion()
            return 0
        }
        let frame = ghost.frame
        if lightweight || UIAccessibility.isReduceMotionEnabled || frame.width < 2 || frame.height < 2 {
            return fadeOut(ghost, completion: completion)
        }
        let duration: CFTimeInterval
        let added: [CALayer]
        switch variant {
        case .dissolve, .shatter:
            guard let image = snapshot(ghost) else { return fadeOut(ghost, completion: completion) }
            let pieces = variant == .dissolve
                ? dissolve(image: image, frame: frame, in: parent, zPosition: ghost.zPosition)
                : shatter(image: image, frame: frame, in: parent, zPosition: ghost.zPosition)
            ghost.removeFromSuperlayer()
            duration = pieces.duration
            added = pieces.layers
        case .crtOff:
            guard let image = snapshot(ghost) else { return fadeOut(ghost, completion: completion) }
            let screen = crtOff(image: image, frame: frame, tint: tint, in: parent, zPosition: ghost.zPosition)
            ghost.removeFromSuperlayer()
            duration = screen.duration
            added = screen.layers
        case .fall:
            guard let image = snapshot(ghost) else { return fadeOut(ghost, completion: completion) }
            let drop = fall(image: image, frame: frame, in: parent, zPosition: ghost.zPosition)
            ghost.removeFromSuperlayer()
            duration = drop.duration
            added = drop.layers
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            for layer in added { layer.removeFromSuperlayer() }
            completion()
        }
        return duration
    }

    // MARK: Variants

    /// Children of a group default to 0.25s, not the group's duration, and
    /// snap back once they end inside it — so every child runs the group's
    /// whole span (or its explicit window) and holds its end value.
    /// Shared with `EventCreationMotion`.
    static func group(_ children: [CAAnimation], duration: CFTimeInterval) -> CAAnimationGroup {
        for child in children {
            if child.duration == 0 { child.duration = duration - child.beginTime }
            child.fillMode = .both
        }
        let group = CAAnimationGroup()
        group.animations = children
        group.duration = duration
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        return group
    }

    private struct Pieces {
        let layers: [CALayer]
        let duration: CFTimeInterval
    }

    /// Grains no smaller than 5pt and never more than ~360 of them, so a
    /// tall block costs the same as a short one.
    private static func dissolve(image: CGImage, frame: CGRect, in parent: CALayer, zPosition: CGFloat) -> Pieces {
        let side = max(5, (frame.width * frame.height / 360).squareRoot())
        let cols = max(1, Int((frame.width / side).rounded(.up)))
        let rows = max(1, Int((frame.height / side).rounded(.up)))
        let sweep: CFTimeInterval = 0.35
        let flight: CFTimeInterval = 0.45
        let jitter: CFTimeInterval = 0.1
        let now = CACurrentMediaTime()
        var layers: [CALayer] = []
        layers.reserveCapacity(cols * rows)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in 0..<rows {
            for col in 0..<cols {
                let tile = tileLayer(image: image, frame: frame, cols: cols, rows: rows, col: col, row: row)
                tile.zPosition = zPosition
                parent.addSublayer(tile)
                layers.append(tile)

                let delay = sweep * Double(col) / Double(max(1, cols - 1)) + .random(in: 0...jitter)
                let drift = CGPoint(x: .random(in: 16...48), y: -.random(in: 8...36))
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = tile.position
                move.toValue = CGPoint(x: tile.position.x + drift.x, y: tile.position.y + drift.y)
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.fromValue = CATransform3DIdentity
                shrink.toValue = CATransform3DRotate(
                    CATransform3DMakeScale(0.35, 0.35, 1), .random(in: -1.2...1.2), 0, 0, 1
                )
                let anim = group([move, fade, shrink], duration: flight)
                anim.beginTime = now + delay
                tile.add(anim, forKey: "deleteMotion")
            }
        }
        CATransaction.commit()
        return Pieces(layers: layers, duration: sweep + jitter + flight)
    }

    /// 2–6 columns × 2–8 rows of shards. Each one is thrown up and away from
    /// the block's centre, then falls; the throw is a quadratic path so the
    /// arc reads as gravity rather than a straight slide.
    private static func shatter(image: CGImage, frame: CGRect, in parent: CALayer, zPosition: CGFloat) -> Pieces {
        let cols = min(6, max(2, Int(frame.width / 26)))
        let rows = min(8, max(2, Int(frame.height / 26)))
        let crack: CFTimeInterval = 0.07
        let flight: CFTimeInterval = 0.7
        let now = CACurrentMediaTime()
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var layers: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in 0..<rows {
            for col in 0..<cols {
                let shard = tileLayer(image: image, frame: frame, cols: cols, rows: rows, col: col, row: row)
                shard.zPosition = zPosition
                parent.addSublayer(shard)
                layers.append(shard)

                let start = shard.position
                let away = CGPoint(
                    x: (start.x - center.x) / max(1, frame.width / 2),
                    y: (start.y - center.y) / max(1, frame.height / 2)
                )
                let dx = away.x * .random(in: 40...90) + .random(in: -14...14)
                let lift = .random(in: 50...110) - away.y * 30
                let end = CGPoint(x: start.x + dx, y: start.y + .random(in: 220...320))
                let control = CGPoint(x: start.x + dx * 0.5, y: start.y - lift)
                // The crack: shards part by a hair before they fly, and the
                // throw leaves from where the crack left them.
                let parted = CGPoint(x: start.x + away.x * 2.5, y: start.y + away.y * 2.5)
                let path = UIBezierPath()
                path.move(to: parted)
                path.addQuadCurve(to: end, controlPoint: control)

                let part = CABasicAnimation(keyPath: "position")
                part.fromValue = start
                part.toValue = parted
                part.duration = crack
                part.beginTime = 0

                let throwAnim = CAKeyframeAnimation(keyPath: "position")
                throwAnim.path = path.cgPath
                throwAnim.beginTime = crack
                throwAnim.duration = flight
                throwAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.8, 0.6)

                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Double.random(in: 1.5...4) * (Bool.random() ? 1 : -1)
                spin.beginTime = crack
                spin.duration = flight

                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 1, 0]
                fade.keyTimes = [0, 0.55, 1]
                fade.beginTime = crack
                fade.duration = flight

                let anim = group([part, throwAnim, spin, fade], duration: crack + flight)
                anim.beginTime = now
                shard.add(anim, forKey: "deleteMotion")
            }
        }
        CATransaction.commit()
        return Pieces(layers: layers, duration: crack + flight)
    }

    /// Squash to a 2pt line while it glows (the block's own colour brightened
    /// towards white), pinch the line to a dot, let the dot fade.
    private static func crtOff(image: CGImage, frame: CGRect, tint: UIColor, in parent: CALayer, zPosition: CGFloat) -> Pieces {
        let duration: CFTimeInterval = 0.42
        let screen = imageLayer(image: image, frame: frame)
        screen.zPosition = zPosition
        let glow = CALayer()
        glow.frame = screen.bounds
        glow.cornerRadius = 4
        glow.backgroundColor = tint.mixed(with: .white, amount: 0.75).cgColor
        glow.opacity = 0
        screen.addSublayer(glow)
        screen.shadowColor = tint.cgColor
        screen.shadowRadius = 6
        screen.shadowOffset = .zero

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSublayer(screen)
        let line = max(0.02, 2 / frame.height)
        let dot = max(0.02, 3 / frame.width)
        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [
            CATransform3DIdentity,
            CATransform3DMakeScale(1.04, line, 1),
            CATransform3DMakeScale(dot, line, 1),
            CATransform3DMakeScale(dot, line, 1),
        ].map(NSValue.init(caTransform3D:))
        squash.keyTimes = [0, 0.42, 0.72, 1]
        squash.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]
        let shine = CAKeyframeAnimation(keyPath: "shadowOpacity")
        shine.values = [0, 0.9, 1, 0]
        shine.keyTimes = [0, 0.42, 0.72, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 1, 0]
        fade.keyTimes = [0, 0.42, 0.72, 1]
        screen.add(group([squash, shine, fade], duration: duration), forKey: "deleteMotion")

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.9, 1, 1]
        flash.keyTimes = [0, 0.42, 0.72, 1]
        flash.duration = duration
        flash.fillMode = .forwards
        flash.isRemovedOnCompletion = false
        glow.add(flash, forKey: "deleteMotion")
        CATransaction.commit()
        return Pieces(layers: [screen], duration: duration)
    }

    /// Hinged at the top-left corner: the right side drops and swings past
    /// rest twice (a nail giving way), then the block falls out of the day,
    /// still turning.
    private static func fall(image: CGImage, frame: CGRect, in parent: CALayer, zPosition: CGFloat) -> Pieces {
        let duration: CFTimeInterval = 0.78
        let block = imageLayer(image: image, frame: frame)
        block.zPosition = zPosition
        // Hinge at the top-left corner without moving the block.
        block.anchorPoint = .zero
        block.position = frame.origin

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSublayer(block)
        // A tall block would sweep a huge arc; keep the swing to ~16pt at
        // the free end.
        let swing = min(0.32, 16 / max(1, frame.width) + 0.08)
        let swingTimes: [NSNumber] = [0, 0.16, 0.26, 0.34, 1]
        let rotate = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotate.values = [0, swing, swing * 0.7, swing * 0.85, swing * 2.4]
        rotate.keyTimes = swingTimes
        rotate.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        let drop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        drop.values = [0, 0, 0, 0, 260 + frame.height * 0.4]
        drop.keyTimes = swingTimes
        drop.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.5, 0, 1, 1),
        ]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.6, 1]
        block.add(group([rotate, drop, fade], duration: duration), forKey: "deleteMotion")
        CATransaction.commit()
        return Pieces(layers: [block], duration: duration)
    }

    private static func fadeOut(_ ghost: CALayer, completion: @escaping () -> Void) -> CFTimeInterval {
        let duration: CFTimeInterval = 0.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ghost.presentation()?.opacity ?? ghost.opacity
        fade.toValue = 0
        fade.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.opacity = 0
        ghost.add(fade, forKey: "deleteMotion")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            ghost.removeFromSuperlayer()
            completion()
        }
        return duration
    }

    // MARK: Snapshot helpers

    /// `render(in:)` draws the subtree in its own bounds space (its own
    /// transform and position are not applied), at screen scale. It is not
    /// guaranteed to honour `mask`, so the block's rounded silhouette is
    /// clipped here as well (4pt, the event corner radius).
    static func snapshot(_ layer: CALayer) -> CGImage? {
        let size = layer.bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                context.cgContext.addPath(
                    UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).cgPath
                )
                context.cgContext.clip()
                layer.render(in: context.cgContext)
            }
            .cgImage
    }

    static func imageLayer(image: CGImage, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsScale = UIScreen.main.scale
        return layer
    }

    static func tileLayer(
        image: CGImage, frame: CGRect, cols: Int, rows: Int, col: Int, row: Int
    ) -> CALayer {
        let unitW = 1 / CGFloat(cols)
        let unitH = 1 / CGFloat(rows)
        let tile = CALayer()
        tile.frame = CGRect(
            x: frame.minX + frame.width * unitW * CGFloat(col),
            y: frame.minY + frame.height * unitH * CGFloat(row),
            width: frame.width * unitW,
            height: frame.height * unitH
        )
        tile.contents = image
        tile.contentsRect = CGRect(x: unitW * CGFloat(col), y: unitH * CGFloat(row), width: unitW, height: unitH)
        tile.contentsScale = UIScreen.main.scale
        return tile
    }
}

extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue: b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        )
    }
}
