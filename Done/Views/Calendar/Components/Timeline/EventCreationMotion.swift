//
//  EventCreationMotion.swift
//  Done
//
//  Create motion for timeline blocks — a harness feature spike
//  (`event-create-motion`, variants picked in 观察站 → 手动 Spike 列表),
//  the counterpart of `EventDeletionMotion`.
//
//  Same three pieces:
//    * `EventCreationMotionFlag` — the spike's enabled/variant keys. Off is
//      king's shape: nothing is marked, so no block is ever held back.
//    * `EventCreationMotionRegistry` — which event ids were just created by a
//      user (here, on another device, or on the watch). Creation call sites
//      opt in through `EventStore.addCalendarEvent(_:creationMotion:)`; the
//      store's own inserts (a series split, an exception instance, samples)
//      and a todo dragged onto the canvas do not, so a block that merely
//      appears never plays.
//    * `EventCreationMotion.play` — the variants, played over the real block,
//      which the host keeps hidden until the motion lands on it.
//

import UIKit
import os

final class EventCreationMotionPlayback {
    fileprivate(set) var layers: [CALayer] = []
    fileprivate(set) var isCancelled = false

    func cancel() {
        isCancelled = true
        for layer in layers { layer.removeFromSuperlayer() }
        layers = []
    }
}

enum EventCreationMotion {
    /// Plays `variant` into `block` — the real, configured block, hidden by
    /// the host — then shows the block and removes everything it added
    /// before calling `completion`. Returns the planned duration (for the
    /// log) and the playback the host cancels if the block is recycled
    /// first. `lightweight` plays a plain fade-in instead (past the first few
    /// of one burst, so a burst can't hitch the main thread).
    static func play(
        _ variant: EventCreationMotionVariant,
        block: CALayer,
        tint: UIColor,
        lightweight: Bool = false,
        completion: @escaping () -> Void
    ) -> (duration: CFTimeInterval, playback: EventCreationMotionPlayback) {
        let playback = EventCreationMotionPlayback()
        let frame = block.frame
        guard let parent = block.superlayer else {
            reveal(block)
            completion()
            return (0, playback)
        }
        if lightweight || UIAccessibility.isReduceMotionEnabled || frame.width < 2 || frame.height < 2 {
            return (fadeIn(block, playback: playback, completion: completion), playback)
        }
        // `render(in:)` skips a hidden layer's content; show it for the
        // capture only, inside one transaction, so no frame sees it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.isHidden = false
        let image = EventDeletionMotion.snapshot(block)
        block.isHidden = true
        CATransaction.commit()
        guard let image else {
            return (fadeIn(block, playback: playback, completion: completion), playback)
        }
        // The block's own layer, not above everything: it lands where the
        // layout put it, under any neighbour stacked over it, so nothing
        // jumps in front when the pieces hand over to the block.
        let zPosition = block.zPosition
        let pieces: (layers: [CALayer], duration: CFTimeInterval)
        switch variant {
        case .assemble: pieces = assemble(image: image, frame: frame, in: parent, zPosition: zPosition)
        case .inkFill: pieces = inkFill(image: image, frame: frame, tint: tint, in: parent, zPosition: zPosition)
        case .pinDrop: pieces = pinDrop(image: image, frame: frame, in: parent, zPosition: zPosition)
        case .crtOn: pieces = crtOn(image: image, frame: frame, tint: tint, in: parent, zPosition: zPosition)
        }
        playback.layers = pieces.layers
        DispatchQueue.main.asyncAfter(deadline: .now() + pieces.duration + 0.03) {
            guard !playback.isCancelled else { return }
            // Show the block in the same transaction the pieces leave in, so
            // there is no frame with neither.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            block.isHidden = false
            playback.cancel()
            CATransaction.commit()
            completion()
        }
        return (pieces.duration, playback)
    }

    /// The drag-create draft turning into the block it became: Material's
    /// container transform — the box you dragged out is the container, it
    /// never leaves. It glides to the block's frame (the form may have moved
    /// or resized it), the block's colour floods in while the draft's tint
    /// and outline fade, it gives a 3% squeeze-and-settle, and a highlight
    /// runs down it once. `draft` is the draft as drawn, at `draftFrame`;
    /// the caller hides the draft itself in the same transaction.
    static func morph(
        fromDraft draft: CGImage,
        draftFrame: CGRect,
        block: CALayer,
        completion: @escaping () -> Void
    ) -> (duration: CFTimeInterval, playback: EventCreationMotionPlayback) {
        let playback = EventCreationMotionPlayback()
        let frame = block.frame
        guard let parent = block.superlayer else {
            reveal(block)
            completion()
            return (0, playback)
        }
        if UIAccessibility.isReduceMotionEnabled || frame.width < 2 || frame.height < 2 {
            return (fadeIn(block, playback: playback, completion: completion), playback)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.isHidden = false
        let image = EventDeletionMotion.snapshot(block)
        block.isHidden = true
        CATransaction.commit()
        guard let image else {
            return (fadeIn(block, playback: playback, completion: completion), playback)
        }

        let duration: CFTimeInterval = 0.36
        let zPosition = block.zPosition
        // Pinned to the top and clipped, not stretched: when the form moved
        // the times, text keeps its size while the box grows or shrinks.
        func piece(_ contents: CGImage) -> CALayer {
            let layer = EventDeletionMotion.imageLayer(image: contents, frame: frame)
            layer.contentsGravity = .top
            layer.masksToBounds = true
            layer.cornerRadius = 4
            layer.cornerCurve = .continuous
            layer.zPosition = zPosition
            return layer
        }
        let from = piece(draft)
        let to = piece(image)
        let sheen = CAGradientLayer()
        sheen.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.32).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.locations = [0, 0.5, 1]
        sheen.frame = CGRect(origin: .zero, size: frame.size)
        to.addSublayer(sheen)

        // Slight overshoot (~3%) when the frame actually travels.
        func glide(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.fromValue = from
            spring.toValue = to
            spring.mass = 1
            spring.stiffness = 420
            spring.damping = 30
            spring.initialVelocity = 0
            spring.duration = duration
            return spring
        }
        let start = CGPoint(x: draftFrame.midX, y: draftFrame.midY)
        let end = CGPoint(x: frame.midX, y: frame.midY)
        let startBounds = CGRect(origin: .zero, size: draftFrame.size)
        let endBounds = CGRect(origin: .zero, size: frame.size)
        func squeeze() -> CAKeyframeAnimation {
            let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
            squeeze.values = [1, 0.97, 1.012, 1]
            squeeze.keyTimes = [0, 0.3, 0.68, 1]
            squeeze.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeOut),
            ]
            return squeeze
        }
        func fade(_ values: [Float], _ keyTimes: [NSNumber]) -> CAKeyframeAnimation {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = values
            fade.keyTimes = keyTimes
            return fade
        }
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = -frame.height / 2
        sweep.toValue = frame.height * 1.5
        sweep.beginTime = duration * 0.3
        sweep.duration = duration * 0.7
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSublayer(from)
        parent.addSublayer(to)
        sheen.position.y = frame.height * 1.5
        from.add(EventDeletionMotion.group([
            glide("position", from: start, to: end),
            glide("bounds", from: startBounds, to: endBounds),
            squeeze(),
            fade([1, 1, 0], [0, 0.15, 0.6]),
        ], duration: duration), forKey: "createMotion")
        to.add(EventDeletionMotion.group([
            glide("position", from: start, to: end),
            glide("bounds", from: startBounds, to: endBounds),
            squeeze(),
            fade([0, 1, 1], [0, 0.5, 1]),
        ], duration: duration), forKey: "createMotion")
        sheen.add(EventDeletionMotion.group([sweep], duration: duration), forKey: "createMotion")
        CATransaction.commit()
        playback.layers = [from, to]

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) {
            guard !playback.isCancelled else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            block.isHidden = false
            playback.cancel()
            CATransaction.commit()
            completion()
        }
        return (duration, playback)
    }

    private static func reveal(_ block: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.isHidden = false
        CATransaction.commit()
    }

    // MARK: Variants

    /// The reverse of 沙化: grains no smaller than 5pt (at most ~360) drift in
    /// from the upper left, growing and turning upright, the left edge first.
    private static func assemble(
        image: CGImage, frame: CGRect, in parent: CALayer, zPosition: CGFloat
    ) -> (layers: [CALayer], duration: CFTimeInterval) {
        let side = max(5, (frame.width * frame.height / 360).squareRoot())
        let cols = max(1, Int((frame.width / side).rounded(.up)))
        let rows = max(1, Int((frame.height / side).rounded(.up)))
        let sweep: CFTimeInterval = 0.2
        let flight: CFTimeInterval = 0.3
        let jitter: CFTimeInterval = 0.08
        let now = CACurrentMediaTime()
        var layers: [CALayer] = []
        layers.reserveCapacity(cols * rows)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in 0..<rows {
            for col in 0..<cols {
                let tile = EventDeletionMotion.tileLayer(
                    image: image, frame: frame, cols: cols, rows: rows, col: col, row: row
                )
                tile.zPosition = zPosition
                parent.addSublayer(tile)
                layers.append(tile)

                let delay = sweep * Double(col) / Double(max(1, cols - 1)) + .random(in: 0...jitter)
                let drift = CGPoint(x: -.random(in: 16...44), y: -.random(in: 8...30))
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = CGPoint(x: tile.position.x + drift.x, y: tile.position.y + drift.y)
                move.toValue = tile.position
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let grow = CABasicAnimation(keyPath: "transform")
                grow.fromValue = CATransform3DRotate(
                    CATransform3DMakeScale(0.35, 0.35, 1), .random(in: -1.2...1.2), 0, 0, 1
                )
                grow.toValue = CATransform3DIdentity
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let anim = EventDeletionMotion.group([move, fade, grow], duration: flight)
                anim.beginTime = now + delay
                tile.add(anim, forKey: "createMotion")
            }
        }
        CATransaction.commit()
        return (layers, sweep + jitter + flight)
    }

    /// The drag-create draft's dashed outline appears first, then the block
    /// fills it from the top like ink running down; the outline fades as the
    /// fill reaches the bottom.
    private static func inkFill(
        image: CGImage, frame: CGRect, tint: UIColor, in parent: CALayer, zPosition: CGFloat
    ) -> (layers: [CALayer], duration: CFTimeInterval) {
        let duration: CFTimeInterval = 0.42
        let outline = CAShapeLayer()
        outline.frame = frame
        outline.path = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: frame.size).insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4
        ).cgPath
        outline.fillColor = tint.withAlphaComponent(0.12).cgColor
        outline.strokeColor = tint.cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [4, 3]
        outline.zPosition = zPosition

        let fill = EventDeletionMotion.imageLayer(image: image, frame: frame)
        fill.zPosition = zPosition
        let wipe = CALayer()
        wipe.backgroundColor = UIColor.white.cgColor
        wipe.anchorPoint = CGPoint(x: 0.5, y: 0)
        wipe.frame = CGRect(origin: .zero, size: frame.size)
        fill.mask = wipe

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSublayer(outline)
        parent.addSublayer(fill)
        let run = CAKeyframeAnimation(keyPath: "transform.scale.y")
        run.values = [0.001, 0.001, 1]
        run.keyTimes = [0, 0.18, 1]
        run.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1),
        ]
        wipe.add(EventDeletionMotion.group([run], duration: duration), forKey: "createMotion")
        let dashFade = CAKeyframeAnimation(keyPath: "opacity")
        dashFade.values = [0, 1, 1, 0]
        dashFade.keyTimes = [0, 0.12, 0.6, 1]
        outline.add(EventDeletionMotion.group([dashFade], duration: duration), forKey: "createMotion")
        CATransaction.commit()
        return ([outline, fill], duration)
    }

    /// Drops in from 18pt above, overshoots by a hair and is pinned —
    /// 脱钉掉落 played backwards, without the swing.
    private static func pinDrop(
        image: CGImage, frame: CGRect, in parent: CALayer, zPosition: CGFloat
    ) -> (layers: [CALayer], duration: CFTimeInterval) {
        let duration: CFTimeInterval = 0.45
        let block = EventDeletionMotion.imageLayer(image: image, frame: frame)
        block.zPosition = zPosition
        block.shadowColor = UIColor.black.cgColor
        block.shadowOffset = CGSize(width: 0, height: 3)
        block.shadowRadius = 5

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSublayer(block)
        let times: [NSNumber] = [0, 0.55, 0.78, 1]
        let drop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        drop.values = [-18, 2.5, -1, 0]
        drop.keyTimes = times
        drop.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.04, 0.985, 1.005, 1]
        scale.keyTimes = times
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 1]
        fade.keyTimes = [0, 0.35, 0.78, 1]
        let lift = CAKeyframeAnimation(keyPath: "shadowOpacity")
        lift.values = [0.25, 0.05, 0, 0]
        lift.keyTimes = times
        block.add(EventDeletionMotion.group([drop, scale, fade, lift], duration: duration), forKey: "createMotion")
        CATransaction.commit()
        return ([block], duration)
    }

    /// 关电视 backwards: a glowing dot stretches to a 2pt line across the
    /// block's width, then the line opens to full height and the glow fades.
    private static func crtOn(
        image: CGImage, frame: CGRect, tint: UIColor, in parent: CALayer, zPosition: CGFloat
    ) -> (layers: [CALayer], duration: CFTimeInterval) {
        let duration: CFTimeInterval = 0.38
        let screen = EventDeletionMotion.imageLayer(image: image, frame: frame)
        screen.zPosition = zPosition
        let glow = CALayer()
        glow.frame = screen.bounds
        glow.cornerRadius = 4
        glow.backgroundColor = tint.mixed(with: .white, amount: 0.75).cgColor
        screen.addSublayer(glow)
        screen.shadowColor = tint.cgColor
        screen.shadowRadius = 6
        screen.shadowOffset = .zero

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSublayer(screen)
        let line = max(0.02, 2 / frame.height)
        let dot = max(0.02, 3 / frame.width)
        let times: [NSNumber] = [0, 0.3, 0.62, 1]
        let open = CAKeyframeAnimation(keyPath: "transform")
        open.values = [
            CATransform3DMakeScale(dot, line, 1),
            CATransform3DMakeScale(1.04, line, 1),
            CATransform3DIdentity,
            CATransform3DIdentity,
        ].map(NSValue.init(caTransform3D:))
        open.keyTimes = times
        open.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
        ]
        let shine = CAKeyframeAnimation(keyPath: "shadowOpacity")
        shine.values = [1, 0.9, 0.3, 0]
        shine.keyTimes = times
        let appear = CAKeyframeAnimation(keyPath: "opacity")
        appear.values = [0, 1, 1, 1]
        appear.keyTimes = [0, 0.12, 0.62, 1]
        screen.add(EventDeletionMotion.group([open, shine, appear], duration: duration), forKey: "createMotion")
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [1, 1, 0.6, 0]
        flash.keyTimes = times
        glow.add(EventDeletionMotion.group([flash], duration: duration), forKey: "createMotion")
        CATransaction.commit()
        return ([screen], duration)
    }

    private static func fadeIn(
        _ block: CALayer, playback: EventCreationMotionPlayback, completion: @escaping () -> Void
    ) -> CFTimeInterval {
        let duration: CFTimeInterval = 0.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = block.opacity
        fade.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.isHidden = false
        block.add(fade, forKey: "createMotion")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard !playback.isCancelled else { return }
            completion()
        }
        return duration
    }
}
