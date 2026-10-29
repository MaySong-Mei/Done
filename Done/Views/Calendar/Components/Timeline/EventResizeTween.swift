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
