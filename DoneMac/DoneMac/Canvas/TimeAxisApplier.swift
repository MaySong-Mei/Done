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
    /// The synced 12h/24h clock setting.
    var is24: Bool = true

    func makeNSView(context: Context) -> TimeAxisApplierView {
        let view = TimeAxisApplierView()
        view.is24 = is24
        return view
    }

    func updateNSView(_ view: TimeAxisApplierView, context: Context) {
        view.is24 = is24
    }
}

final class TimeAxisApplierView: NSView {
    private var labelLayers: [CATextLayer] = []
    var is24 = true {
        didSet { if is24 != oldValue { applyLabelStrings() } }
    }

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
            text.string = calendarHourAxisLabel(hour24: hour, is24: is24)
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

    private func applyLabelStrings() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (hour, text) in labelLayers.enumerated() {
            text.string = calendarHourAxisLabel(hour24: hour, is24: is24)
        }
        CATransaction.commit()
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
