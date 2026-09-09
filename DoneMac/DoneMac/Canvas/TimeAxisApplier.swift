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
    var hourHeight: CGFloat

    func makeNSView(context: Context) -> TimeAxisApplierView {
        TimeAxisApplierView()
    }

    func updateNSView(_ view: TimeAxisApplierView, context: Context) {
        view.hourHeight = hourHeight
    }
}

final class TimeAxisApplierView: NSView {
    private var labelLayers: [CATextLayer] = []

    var hourHeight: CGFloat = 44 {
        didSet { if hourHeight != oldValue { needsLayout = true } }
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
            text.string = String(format: "%02d:00", hour)
            text.fontSize = 9
            text.foregroundColor = NSColor.secondaryLabelColor.cgColor
            text.alignmentMode = .right
            text.contentsScale = window?.backingScaleFactor ?? 2
            hostLayer.addSublayer(text)
            labelLayers.append(text)
        }
    }

    override func layout() {
        super.layout()
        // Diff-apply: position writes only — no layer churn per pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height
        for (hour, text) in labelLayers.enumerated() {
            text.frame = CGRect(
                x: 0,
                y: height * CGFloat(hour) / 24 - 5,
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
}
