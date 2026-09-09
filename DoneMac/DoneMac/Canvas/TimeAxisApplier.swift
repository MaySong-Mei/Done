//
//  TimeAxisApplier.swift
//  DoneMac
//
//  The renderer escape hatch, proven small (plan §2.3): an NSView-hosted
//  CALayer applier for the hour axis. Layers are built once and diff-
//  applied on layout — the same hosting pattern a DayColumn CALayer
//  cutover would use at scale, exercised here from day one so the hatch
//  is a measured path, not a theory.
//

import AppKit
import SwiftUI

struct TimeAxisApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> TimeAxisApplierView {
        TimeAxisApplierView()
    }

    func updateNSView(_ view: TimeAxisApplierView, context: Context) {}
}

final class TimeAxisApplierView: NSView {
    private var labelLayers: [CATextLayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayersOnce()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        buildLayersOnce()
    }

    override var isFlipped: Bool { true }

    private func buildLayersOnce() {
        guard labelLayers.isEmpty, let hostLayer = layer else { return }
        for hour in 0..<24 {
            let text = CATextLayer()
            text.string = String(format: "%02d:00", hour)
            text.fontSize = 9
            text.alignmentMode = .right
            text.contentsScale = window?.backingScaleFactor ?? 2
            hostLayer.addSublayer(text)
            labelLayers.append(text)
        }
        applyAppearanceColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Insurance for a nil backing layer at init (review round-2 #17).
        buildLayersOnce()
    }

    override func layout() {
        super.layout()
        // Idempotent full rewrite of 24 frames in one transaction — the
        // hosting + transaction-discipline half of the escape-hatch
        // pattern (an id-keyed diff joins when content becomes dynamic).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height
        for (hour, text) in labelLayers.enumerated() {
            text.frame = CGRect(
                x: 0,
                y: max(0, height * CGFloat(hour) / 24 - 5),
                width: bounds.width - 6,
                height: 11
            )
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in labelLayers {
            text.contentsScale = scale
        }
    }

    /// cgColor snapshots the appearance at resolve time; a light↔dark
    /// switch must re-resolve or the labels keep the old contrast
    /// (review round-2 #16).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.secondaryLabelColor.cgColor
            for text in labelLayers {
                text.foregroundColor = color
            }
        }
    }
}
