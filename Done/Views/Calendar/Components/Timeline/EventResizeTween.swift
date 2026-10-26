//
//  EventResizeTween.swift
//  Done
//
//  Inbetweening for a block whose length changes — a harness feature spike
//  (`event-resize-tween`, speed picked in 观察站 → 手动 Spike 列表).
//
//  Two moments, one mechanism:
//    * dragging an edge: each 15-minute snap step glides instead of jumping;
//    * a length changed without a finger (the form, the AI, another device):
//      the block goes from its old length to the new one, and neighbours the
//      change pushed aside go with it.
//  A move that keeps the length is not tweened — the block would fly from
//  where it was.
//
//  `EventResizeTween.capture` records a block subtree's geometry as it is on
//  screen (the presentation value, so a step that lands mid-glide continues
//  from where the glide is); `animate` then adds one explicit animation per
//  property `configure` changed, from that value to the new one.
//

import UIKit
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

enum EventResizeTween {
    struct Geometry {
        let position: CGPoint
        let bounds: CGRect
        let path: CGPath?
    }

    /// One entry per layer of the subtree, as currently on screen.
    struct Capture {
        let entries: [(layer: CALayer, geometry: Geometry)]
    }

    static func capture(_ root: CALayer) -> Capture {
        var entries: [(CALayer, Geometry)] = []
        func walk(_ layer: CALayer) {
            let shown = layer.animationKeys()?.contains(where: { $0.hasPrefix(key) }) == true
                ? layer.presentation() ?? layer
                : layer
            entries.append((layer, Geometry(
                position: shown.position,
                bounds: shown.bounds,
                path: (shown as? CAShapeLayer)?.path
            )))
            layer.sublayers?.forEach(walk)
            if let mask = layer.mask { walk(mask) }
        }
        walk(root)
        return Capture(entries: entries)
    }

    /// Tweens every property that moved since `capture`. Returns whether the
    /// block's own frame moved (what the host logs). Layers added after the
    /// capture, and paths whose shape changed kind (another element count —
    /// Core Animation can't inbetween those), just take their new value.
    @discardableResult
    static func animate(from capture: Capture, root: CALayer, duration: CFTimeInterval) -> Bool {
        guard duration > 0, !UIAccessibility.isReduceMotionEnabled else { return false }
        // Position + bounds, not frame: the container's transform is reset
        // inside `configure`, which changes `frame` without moving it.
        guard let old = capture.entries.first?.geometry,
              old.position != root.position || old.bounds != root.bounds else { return false }
        let timing = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.35, 1)
        func tween(_ layer: CALayer, _ keyPath: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: key + keyPath)
        }
        for (layer, old) in capture.entries {
            if old.position != layer.position {
                tween(layer, "position", from: old.position, to: layer.position)
            }
            if old.bounds != layer.bounds {
                tween(layer, "bounds", from: old.bounds, to: layer.bounds)
            }
            if let shape = layer as? CAShapeLayer, let oldPath = old.path, let newPath = shape.path,
               oldPath != newPath, elementCount(oldPath) == elementCount(newPath) {
                tween(layer, "path", from: oldPath, to: newPath)
            }
        }
        return true
    }

    private static let key = "resizeTween."

    private static func elementCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }
}
