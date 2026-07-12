//
//  TimeAxisLayerView.swift
//  Done
//
//  CALayer-backed port of the SwiftUI `TimeAxisLabels` overlay (issue #60).
//
//  Goal: identical pixel parity with the SwiftUI tree at
//  `TimelineView.swift:2590-2918` (axis hour labels + now-time legend +
//  drag-preview pills + band-fade mask), without rebuilding a SwiftUI
//  sub-tree per drag frame. Gated by `AppSettingsKeys.calendarUseCALayerAxisMarkers`,
//  default OFF; flipped ON only after A/B parity is verified.
//
//  This file is intentionally self-contained UIKit/CALayer code — it pulls
//  shared math from the file-scope helpers in `TimelineView.swift` /
//  `TimelineEditMapping.swift` so the SwiftUI path and the CALayer path
//  share one source of truth for label text, slot heights, and collision
//  rules.

import SwiftUI
import UIKit

// MARK: - SwiftUI host

/// SwiftUI-side host for the CALayer axis. Drop-in replacement for the
/// SwiftUI `TimeAxisLabels` view — same input surface so the call site at
/// `timeAxis()` can swap the two behind the experimental flag.
struct TimeAxisLayerHost: UIViewRepresentable {
    let anchorDate: Date
    let headerHeight: CGFloat
    let hourHeight: CGFloat
    let slotMinutes: Int
    let leadingExtendedHours: Int
    let trailingExtendedHours: Int
    /// Spec 07: REAL band window for which hour labels to DRAW (band regions
    /// render empty when closed). Defaults to the coordinate hours ⇒ identity.
    var drawableLeadingHours: Int = -1
    var drawableTrailingHours: Int = -1
    let mode: PageMode
    var editMappingPresentation: TimelineAxisMarkerPresentation? = nil
    var leadingFadeProgress: CGFloat = 0
    var trailingFadeProgress: CGFloat = 0
    var isSingleDay: Bool = false

    func makeUIView(context: Context) -> TimeAxisLayerView {
        let view = TimeAxisLayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TimeAxisLayerView, context: Context) {
        uiView.apply(
            anchorDate: anchorDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            slotMinutes: slotMinutes,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours,
            drawableLeadingHours: drawableLeadingHours >= 0 ? drawableLeadingHours : leadingExtendedHours,
            drawableTrailingHours: drawableTrailingHours >= 0 ? drawableTrailingHours : trailingExtendedHours,
            editMappingPresentation: editMappingPresentation,
            leadingFadeProgress: leadingFadeProgress,
            trailingFadeProgress: trailingFadeProgress,
            isSingleDay: isSingleDay
        )
    }
}

// MARK: - UIView host (CALayer backing)

/// CALayer-backed axis. Owns its own sublayers for hour labels, now-time
/// legend, drag-preview pills, and the band-fade mask. Currently a scaffold
/// — sublayers are added in subsequent commits as parity slices are ported.
final class TimeAxisLayerView: UIView {
    // Snapshot of the most recently applied inputs. Used to short-circuit
    // identical re-applies + to drive incremental layer updates.
    private struct Inputs: Equatable {
        var anchorDate: Date
        var headerHeight: CGFloat
        var hourHeight: CGFloat
        var slotMinutes: Int
        var leadingExtendedHours: Int
        var trailingExtendedHours: Int
        var drawableLeadingHours: Int
        var drawableTrailingHours: Int
        var editMappingPresentation: TimelineAxisMarkerPresentation?
        var leadingFadeProgress: CGFloat
        var trailingFadeProgress: CGFloat
        var isSingleDay: Bool
    }
    private var inputs: Inputs?

    // Hour-label pool. Each non-empty slot (i.e. on the hour) gets one
    // UILabel; empty slots (half-hour ticks when slotMinutes == 30) are
    // skipped entirely to match the SwiftUI tree's `guard minute == 0
    // else { return "" }` rule.
    private var hourLabels: [UILabel] = []
    // Index into `hourLabels` — captures the slot index each pool entry
    // currently represents. Aligned 1:1 with `hourLabels`.
    private var hourLabelSlotIndices: [Int] = []

    // Hour labels live in this container so the band-fade mask (#55
    // follow-on) applies ONLY to them — markers + now-legend stay fully
    // opaque, parity with the SwiftUI `.mask(...)` modifier scoping at
    // TimelineView.swift:2685.
    private let hourLabelContainer = UIView()
    // CALayer mask for `hourLabelContainer`. Constructed as a stack of
    // white sublayers with per-band opacity = `1 - fadeProgress`.
    private let hourLabelMaskLayer = CALayer()

    // Now-time legend (mirrors the SwiftUI Text inside the
    // `TimelineView(.periodic(from: .now, by: 1))` block at line 2687).
    // Rendered as a single UILabel positioned at the current wall-clock
    // time's Y; gated by `showsCurrentTime` (= true when multi-day OR
    // when this page IS today).
    private let nowLegendLabel: UILabel = {
        let label = UILabel()
        // Equivalent of SwiftUI `.font(.system(size: 9, weight: .bold).monospacedDigit())`.
        let base = UIFont.systemFont(ofSize: 9, weight: .bold)
        let mono = UIFontDescriptor.FeatureKey.featureIdentifier
        let monoVal = UIFontDescriptor.FeatureKey.typeIdentifier
        // Use modern descriptor API (iOS 13+) for digit monospacing.
        if let descriptor = base.fontDescriptor.withDesign(.default)?
            .addingAttributes([
                UIFontDescriptor.AttributeName.featureSettings: [
                    [mono: kNumberSpacingType, monoVal: kMonospacedNumbersSelector]
                ]
            ]) {
            label.font = UIFont(descriptor: descriptor, size: 9)
        } else {
            label.font = base
        }
        label.textAlignment = .right
        label.numberOfLines = 1
        label.backgroundColor = .clear
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        // Soft drop shadow (parity with SwiftUI .shadow(... radius: 1)).
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.18
        label.layer.shadowRadius = 1
        label.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        return label
    }()
    // 1-Hz tick for the now-legend + hour-label collision opacity.
    // Mirrors SwiftUI's `TimelineView(.periodic(from: .now, by: 1))`.
    private var nowTickTimer: Timer?
    // Tracks the latest crossfade target so a tick mid-animation doesn't
    // tug opacities off-target. UIKit's `animate(withDuration:)` won't
    // re-enter cleanly otherwise.
    private var nowLegendShowsCurrentTime: Bool = true

    // Axis-marker pill pool. Up to 4 pills are live at any time: 2 for
    // the primary range (start / end), 2 for the cross-midnight wrap
    // pair when present. Pills outside the active count are hidden.
    private var axisMarkerPills: [AxisMarkerPillView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Disable implicit animations on sublayers — we never want a
        // CALayer fade when the axis rebuilds, parity with the SwiftUI
        // tree (which only animates via explicit `.transition(.opacity)`
        // at the call site, driven by the `.id(effectiveSlotMinutes)`
        // crossfade — and that wraps THIS view, not its internals).
        layer.actions = TimeAxisLayerView.disabledActions
        // Z order: hour-label container (mask-fadeable) at the bottom,
        // now-legend + axis pills on top, matching the SwiftUI ZStack
        // ordering (mask child first, then legend, then markers — see
        // TimelineView.swift:2644-2702).
        hourLabelContainer.isUserInteractionEnabled = false
        hourLabelContainer.backgroundColor = .clear
        hourLabelContainer.layer.actions = TimeAxisLayerView.disabledActions
        addSubview(hourLabelContainer)
        addSubview(nowLegendLabel)
        // Mask layer applies ONLY to the hour-label container — the
        // band-fade rule fades hour labels in the leading / trailing
        // extension bands without touching the now-legend or pills.
        hourLabelMaskLayer.actions = TimeAxisLayerView.disabledActions
        hourLabelContainer.layer.mask = hourLabelMaskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startNowTick()
        } else {
            stopNowTick()
        }
    }

    deinit {
        nowTickTimer?.invalidate()
    }

    private func startNowTick() {
        guard nowTickTimer == nil else { return }
        // Re-evaluate the now-legend every second. Mirrors SwiftUI
        // `TimelineView(.periodic(from: .now, by: 1))`. `tolerance` is
        // 0.25s so the OS can coalesce wake-ups with other low-rate
        // timers — the legend doesn't need second-precise alignment.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshNowDependentState()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        nowTickTimer = timer
        // Refresh immediately so the legend doesn't lag a second behind
        // first appearance.
        refreshNowDependentState()
    }

    private func stopNowTick() {
        nowTickTimer?.invalidate()
        nowTickTimer = nil
    }

    private func refreshNowDependentState() {
        guard let inputs else { return }
        updateNowLegend(inputs: inputs, now: Date())
        updateHourLabelOpacities(inputs: inputs, now: Date())
    }

    private static let disabledActions: [String: CAAction] = [
        "contents": NSNull(),
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "opacity": NSNull(),
        "transform": NSNull(),
        "sublayers": NSNull(),
        "hidden": NSNull()
    ]

    override func layoutSubviews() {
        super.layoutSubviews()
        hourLabelContainer.frame = bounds
        // Width-dependent layout (hour-label trailing edge) is handled in
        // `layoutHourLabels`; trigger it now in case `apply(...)` was
        // called before the bounds resolved.
        if let inputs {
            layoutHourLabels(inputs: inputs)
            updateHourLabelMask(inputs: inputs)
        }
    }

    /// Apply the latest inputs from the SwiftUI host. Idempotent — repeated
    /// calls with the same inputs return early so SwiftUI body re-evals
    /// (which call `updateUIView` on every state change up-tree) don't
    /// churn CALayer.
    func apply(
        anchorDate: Date,
        headerHeight: CGFloat,
        hourHeight: CGFloat,
        slotMinutes: Int,
        leadingExtendedHours: Int,
        trailingExtendedHours: Int,
        drawableLeadingHours: Int,
        drawableTrailingHours: Int,
        editMappingPresentation: TimelineAxisMarkerPresentation?,
        leadingFadeProgress: CGFloat,
        trailingFadeProgress: CGFloat,
        isSingleDay: Bool
    ) {
        let next = Inputs(
            anchorDate: anchorDate,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            slotMinutes: slotMinutes,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours,
            drawableLeadingHours: drawableLeadingHours,
            drawableTrailingHours: drawableTrailingHours,
            editMappingPresentation: editMappingPresentation,
            leadingFadeProgress: leadingFadeProgress,
            trailingFadeProgress: trailingFadeProgress,
            isSingleDay: isSingleDay
        )
        if inputs == next { return }
        // Hour-label rebuild is required when the structural inputs change
        // (slot count, extension hours, hour height). Cheaper inputs
        // (fade progress, marker presentation) re-flow through dedicated
        // refresh paths in subsequent commits.
        let structuralChanged = inputs == nil
            || inputs!.headerHeight != next.headerHeight
            || inputs!.hourHeight != next.hourHeight
            || inputs!.slotMinutes != next.slotMinutes
            || inputs!.leadingExtendedHours != next.leadingExtendedHours
            || inputs!.trailingExtendedHours != next.trailingExtendedHours
            || inputs!.drawableLeadingHours != next.drawableLeadingHours
            || inputs!.drawableTrailingHours != next.drawableTrailingHours
        inputs = next
        if structuralChanged {
            rebuildHourLabels(inputs: next)
        }
        layoutHourLabels(inputs: next)
        let now = Date()
        updateNowLegend(inputs: next, now: now)
        updateHourLabelOpacities(inputs: next, now: now)
        updateAxisMarkers(inputs: next)
        updateHourLabelMask(inputs: next)
    }

    // MARK: - Hour labels (parity with TimeAxisLabels.body's slot ForEach)

    private func rebuildHourLabels(inputs: Inputs) {
        // Compute slot count + which slots carry text (on-the-hour only,
        // matching `label(forSlot:)` in `TimeAxisLabels`).
        let slotCount = Self.slotCount(
            slotMinutes: inputs.slotMinutes,
            leadingExtendedHours: inputs.leadingExtendedHours,
            trailingExtendedHours: inputs.trailingExtendedHours
        )
        // Spec 07: draw labels only within the REAL day window (drawable hours);
        // band-region labels are skipped when closed, keeping their Y positions
        // (which use the coordinate hours). Identity when drawable == coordinate.
        let drawTopMin = -inputs.drawableLeadingHours * 60
        let drawBottomMin = (calendarTimelineBaseVisibleHours + inputs.drawableTrailingHours) * 60
        var wantedSlots: [Int] = []
        wantedSlots.reserveCapacity(slotCount)
        for index in 0..<slotCount {
            let slotMin = -inputs.leadingExtendedHours * 60 + index * inputs.slotMinutes
            if slotMin < drawTopMin || slotMin > drawBottomMin { continue }
            if Self.labelText(
                forSlot: index,
                slotMinutes: inputs.slotMinutes,
                leadingExtendedHours: inputs.leadingExtendedHours
            ) != nil {
                wantedSlots.append(index)
            }
        }
        // Grow / shrink the pool.
        while hourLabels.count < wantedSlots.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 9, weight: .semibold)
            label.textColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
            label.textAlignment = .right
            label.numberOfLines = 1
            label.backgroundColor = .clear
            hourLabelContainer.addSubview(label)
            hourLabels.append(label)
        }
        while hourLabels.count > wantedSlots.count {
            hourLabels.removeLast().removeFromSuperview()
        }
        hourLabelSlotIndices = wantedSlots
        // Assign text. Re-evaluated on every rebuild because slotMinutes
        // / extension hours can shift which slot maps to which hour-of-day.
        for (poolIndex, slotIndex) in wantedSlots.enumerated() {
            let text = Self.labelText(
                forSlot: slotIndex,
                slotMinutes: inputs.slotMinutes,
                leadingExtendedHours: inputs.leadingExtendedHours
            ) ?? ""
            hourLabels[poolIndex].text = text
        }
    }

    private func layoutHourLabels(inputs: Inputs) {
        guard !hourLabelSlotIndices.isEmpty else { return }
        let slotHeight = inputs.hourHeight * CGFloat(inputs.slotMinutes) / 60
        let trailingPadding: CGFloat = 2
        // SwiftUI uses `.fixedSize(horizontal: true, vertical: false)` —
        // label gets its intrinsic width, anchored to the trailing edge.
        // Mirror by sizing each UILabel to `sizeThatFits` (intrinsic
        // width) and positioning its right edge at `bounds.width -
        // trailingPadding`.
        let rightEdge = bounds.width - trailingPadding
        // SwiftUI tree: each slot row is `frame(height: slotHeight, alignment: .top)`,
        // its overlay Text has `.offset(y: -2)`. Net: label top Y is
        // `headerHeight + slotIndex * slotHeight - 2`.
        for (poolIndex, slotIndex) in hourLabelSlotIndices.enumerated() {
            let label = hourLabels[poolIndex]
            let fitSize = label.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            let topY = inputs.headerHeight + CGFloat(slotIndex) * slotHeight - 2
            label.frame = CGRect(
                x: rightEdge - fitSize.width,
                y: topY,
                width: fitSize.width,
                height: fitSize.height
            )
        }
    }

    // MARK: - Now-time legend (parity with the SwiftUI Text at TimelineView.swift:2687)

    private func updateNowLegend(inputs: Inputs, now: Date) {
        // Single-day axis only shows the now-legend when this page IS today.
        // Multi-day always shows it (parity with the SwiftUI gate).
        let showsCurrentTime = !inputs.isSingleDay
            || Calendar.current.isDate(inputs.anchorDate, inSameDayAs: now)
        nowLegendLabel.text = Self.currentTimeText(for: now)
        nowLegendLabel.textColor = Self.currentTimeIndicatorColor()
        // Position: parity with the SwiftUI tree's
        // `.offset(y: currentTimeLegendYOffset(for: now))` — pointerY -
        // labelHeight/2, clamped so the label stays within the axis frame.
        let labelHeight: CGFloat = 12
        let pointerY = calendarTimelineYPosition(
            for: now,
            containing: now,
            headerHeight: inputs.headerHeight,
            hourHeight: inputs.hourHeight,
            leadingExtendedHours: inputs.leadingExtendedHours,
            trailingExtendedHours: inputs.trailingExtendedHours
        )
        let maxY = inputs.headerHeight
            + CGFloat(
                calendarTimelineTotalVisibleHours(
                    leadingExtendedHours: inputs.leadingExtendedHours,
                    trailingExtendedHours: inputs.trailingExtendedHours
                )
            ) * inputs.hourHeight
            - labelHeight
        let y = min(max(inputs.headerHeight, pointerY - labelHeight / 2), maxY)
        let trailingPadding: CGFloat = 2
        let fitSize = nowLegendLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: labelHeight)
        )
        let rightEdge = bounds.width - trailingPadding
        nowLegendLabel.frame = CGRect(
            x: rightEdge - fitSize.width,
            y: y,
            width: fitSize.width,
            height: labelHeight
        )
        // Crossfade between "this page is today" and "this page isn't".
        // SwiftUI uses `.animation(.easeInOut(duration: 0.22), value: showsCurrentTime)`
        // — mirror with UIView.animate. No-op when already in target state.
        let targetAlpha: CGFloat = showsCurrentTime ? 1 : 0
        if nowLegendLabel.alpha != targetAlpha
            || nowLegendShowsCurrentTime != showsCurrentTime
        {
            nowLegendShowsCurrentTime = showsCurrentTime
            UIView.animate(
                withDuration: 0.22, delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: { [weak self] in
                    self?.nowLegendLabel.alpha = targetAlpha
                }
            )
        }
    }

    /// Yield the colliding hour label's opacity to the now-legend when
    /// they overlap within `collisionThresholdPoints`. Driven by the same
    /// 1-Hz tick + a crossfade animation so the page-switch transition
    /// blends back in step. Mirrors `TimeAxisLabels.hourLabelOpacity`.
    private func updateHourLabelOpacities(inputs: Inputs, now: Date) {
        let showsCurrentTime = !inputs.isSingleDay
            || Calendar.current.isDate(inputs.anchorDate, inSameDayAs: now)
        let nowTotalMinutes = Self.totalMinutesSinceMidnight(for: now)
        for (poolIndex, slotIndex) in hourLabelSlotIndices.enumerated() {
            let label = hourLabels[poolIndex]
            let totalMinutes = -inputs.leadingExtendedHours * 60
                + slotIndex * inputs.slotMinutes
            let targetAlpha: CGFloat
            if !showsCurrentTime {
                // No legend on this page → nothing to yield to.
                targetAlpha = 1
            } else if calendarShouldHideLegendHourLabel(
                legendTotalMinutes: totalMinutes,
                nowTotalMinutes: nowTotalMinutes,
                hourHeight: inputs.hourHeight
            ) {
                targetAlpha = 0
            } else {
                targetAlpha = 1
            }
            if label.alpha != targetAlpha {
                UIView.animate(
                    withDuration: 0.22, delay: 0,
                    options: [.beginFromCurrentState, .curveEaseInOut],
                    animations: { label.alpha = targetAlpha }
                )
            }
        }
    }

    // MARK: - Band-fade mask (#55 follow-on, parity with TimeAxisLabels.bandFadeMask)

    /// Rebuild the alpha mask on `hourLabelContainer` so the leading /
    /// trailing extension bands fade their hour labels per
    /// `leadingFadeProgress` / `trailingFadeProgress` (0 = solid, 1 =
    /// transparent). Header + base 24h are always opaque; an 8pt buffer
    /// overhangs the base segment into each band so the midnight "0:00"
    /// label remains fully opaque while the band's interior hours fade.
    /// (Same buffer geometry as TimelineView.swift:2727.)
    private func updateHourLabelMask(inputs: Inputs) {
        // The mask width matches the SwiftUI tree's 80pt right-aligned
        // mask — generous enough that even the widest hour label (e.g.
        // "23:00" with intrinsic width ~24pt) doesn't fall off the
        // leftward edge once leftward bleed past the trailing column edge
        // is accounted for.
        let maskWidth: CGFloat = 80
        // Trailing-aligned: mask sits with its right edge flush against
        // `bounds.width`, extending leftward. `alignment: .trailing` on the
        // SwiftUI mask call site (TimelineView.swift:2685) does the same.
        let maskOriginX = bounds.width - maskWidth
        let buffer: CGFloat = 8
        let leadingBuf: CGFloat = inputs.leadingExtendedHours > 0 ? buffer : 0
        let trailingBuf: CGFloat = inputs.trailingExtendedHours > 0 ? buffer : 0
        let leadingBandHeight = max(
            0,
            CGFloat(inputs.leadingExtendedHours) * inputs.hourHeight - leadingBuf
        )
        let baseHeight = CGFloat(calendarTimelineBaseVisibleHours) * inputs.hourHeight
            + leadingBuf + trailingBuf
        let trailingBandHeight = max(
            0,
            CGFloat(inputs.trailingExtendedHours) * inputs.hourHeight - trailingBuf
        )
        // Build the 5-segment stack: header (opaque), leading band
        // (faded), base 24h (opaque), trailing band (faded), tail
        // (opaque). Each is a single CALayer with `backgroundColor =
        // white` and the segment's per-band opacity.
        var segments: [(height: CGFloat, opacity: Float)] = []
        segments.append((inputs.headerHeight, 1))
        if inputs.leadingExtendedHours > 0 {
            segments.append((leadingBandHeight, Float(1 - inputs.leadingFadeProgress)))
        }
        segments.append((baseHeight, 1))
        if inputs.trailingExtendedHours > 0 {
            segments.append((trailingBandHeight, Float(1 - inputs.trailingFadeProgress)))
        }
        // Tail fills any remaining space — the mask is a stack, anything
        // beyond the last opaque-or-faded segment must stay opaque so
        // labels there aren't dropped. Calculated from the container's
        // height (= bounds.height).
        let consumed = segments.reduce(0) { $0 + $1.height }
        let remaining = max(0, bounds.height - consumed)
        if remaining > 0 {
            segments.append((remaining, 1))
        }
        // Reconcile against existing sublayers (grow / shrink).
        let existing = hourLabelMaskLayer.sublayers ?? []
        while (hourLabelMaskLayer.sublayers?.count ?? 0) < segments.count {
            let l = CALayer()
            l.backgroundColor = UIColor.white.cgColor
            l.actions = TimeAxisLayerView.disabledActions
            hourLabelMaskLayer.addSublayer(l)
        }
        while (hourLabelMaskLayer.sublayers?.count ?? 0) > segments.count {
            hourLabelMaskLayer.sublayers?.last?.removeFromSuperlayer()
        }
        _ = existing  // silence unused-let warning; reconciliation above
        // Position each segment top-to-bottom inside the mask layer.
        let segmentLayers = hourLabelMaskLayer.sublayers ?? []
        var y: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let l = segmentLayers[index]
            l.frame = CGRect(x: 0, y: y, width: maskWidth, height: segment.height)
            l.opacity = segment.opacity
            y += segment.height
        }
        // Position the mask itself against `hourLabelContainer`. The
        // mask layer's coordinate space is the container's bounds.
        hourLabelMaskLayer.frame = CGRect(
            x: maskOriginX, y: 0,
            width: maskWidth, height: bounds.height
        )
    }

    // MARK: - Axis markers (drag pills, parity with TimeAxisLabels.axisMarkers)

    private func updateAxisMarkers(inputs: Inputs) {
        guard let presentation = inputs.editMappingPresentation else {
            // No edit in progress → hide all pills.
            for pill in axisMarkerPills { pill.isHidden = true }
            return
        }
        // Build the (text, y) pairs the SwiftUI tree would render.
        var slots: [(text: String, y: CGFloat)] = []
        if presentation.isCollapsed {
            // Two separate labels spread apart so the wide collapsed
            // text doesn't overflow the narrow axis column.
            let midY = (presentation.startY + presentation.endY) / 2
            let markerHeight: CGFloat = 16
            let halfSpread = markerHeight / 2 + 1
            slots.append((presentation.startText, midY - halfSpread))
            slots.append((presentation.endText, midY + halfSpread))
        } else {
            slots.append((presentation.startText, presentation.startY))
            slots.append((presentation.endText, presentation.endY))
        }
        // Wrap-around pair for cross-midnight live ranges (#53B follow-on).
        if let wrappedStartY = presentation.wrappedStartY,
           let wrappedEndY = presentation.wrappedEndY {
            slots.append((presentation.startText, wrappedStartY))
            slots.append((presentation.endText, wrappedEndY))
        }
        // Grow pool to match.
        while axisMarkerPills.count < slots.count {
            let pill = AxisMarkerPillView()
            addSubview(pill)
            axisMarkerPills.append(pill)
        }
        let markerColor: UIColor = {
            if let color = presentation.color { return UIColor(color) }
            return UIColor(Color.accentColor)
        }()
        let foreground = Self.legendForegroundColor(for: markerColor)
        let totalVisibleHours = calendarTimelineTotalVisibleHours(
            leadingExtendedHours: inputs.leadingExtendedHours,
            trailingExtendedHours: inputs.trailingExtendedHours
        )
        let yMin = inputs.headerHeight
        let yMax = inputs.headerHeight + CGFloat(totalVisibleHours) * inputs.hourHeight
        let markerHeight: CGFloat = 16
        // SwiftUI tree positions each pill via
        //   .offset(x: 15, y: clampedY - markerHeight / 2)
        // wrapped in `.frame(maxWidth: .infinity, alignment: .trailing)
        //  .padding(.trailing, 8)`. Net trailing edge of the pill is
        // `bounds.width - 8 + 15` = `bounds.width + 7`. The leftward
        // 15pt offset is what makes the pill jut past the axis column
        // into the day-grid gutter.
        let trailingEdge = bounds.width - 8 + 15
        for (pillIndex, slot) in slots.enumerated() {
            let pill = axisMarkerPills[pillIndex]
            pill.isHidden = false
            pill.configure(
                text: slot.text,
                background: markerColor,
                foreground: foreground
            )
            let clampedY = min(max(yMin, slot.y), yMax)
            let pillSize = pill.intrinsicContentSize
            pill.frame = CGRect(
                x: trailingEdge - pillSize.width,
                y: clampedY - markerHeight / 2,
                width: pillSize.width,
                height: pillSize.height
            )
        }
        // Hide unused pool entries.
        for pillIndex in slots.count..<axisMarkerPills.count {
            axisMarkerPills[pillIndex].isHidden = true
        }
    }

    // MARK: - Helpers (mirror TimeAxisLabels' private free funcs)

    /// Mirrors `TimeAxisLabels.slotCount`.
    private static func slotCount(
        slotMinutes: Int,
        leadingExtendedHours: Int,
        trailingExtendedHours: Int
    ) -> Int {
        let totalMinutes = calendarTimelineTotalVisibleHours(
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        ) * 60
        return max(1, totalMinutes / max(1, slotMinutes) + 1)
    }

    /// Mirrors `TimeAxisLabels.label(forSlot:)`. Returns nil for empty
    /// slots (half-hour ticks etc.) so the rebuild path skips them
    /// entirely; non-nil slots produce labels in the pool.
    private static func labelText(
        forSlot index: Int,
        slotMinutes: Int,
        leadingExtendedHours: Int
    ) -> String? {
        let totalMinutes = -leadingExtendedHours * 60 + index * slotMinutes
        let normalizedTotalMinutes = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let hour24 = normalizedTotalMinutes / 60
        let minute = normalizedTotalMinutes % 60
        guard minute == 0 else { return nil }
        if AppTimeFormat.current.is24 {
            return String(format: "%d:00", hour24)
        } else {
            let meridiem = hour24 < 12 ? "am" : "pm"
            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            return "\(hour12) \(meridiem)"
        }
    }

    /// Mirrors `TimeAxisLabels.currentTimeText(for:)` + the static
    /// `currentTimeFormatter`. Lowercased to match the SwiftUI tree
    /// (`...string(from: now).lowercased()`).
    private static func currentTimeText(for now: Date) -> String {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mma"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter.string(from: now).lowercased()
    }

    /// Mirrors `TimeAxisLabels.totalMinutesSinceMidnight(for:)`.
    private static func totalMinutesSinceMidnight(for date: Date) -> CGFloat {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
            + CGFloat(components.second ?? 0) / 60
    }

    /// UIColor equivalent of TimelineView's private `calendarCurrentTimeIndicatorColor()`.
    /// Resolves to white on dark mode, near-black on light mode.
    private static func currentTimeIndicatorColor() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .white
                : UIColor(white: 0.22, alpha: 1)
        }
    }

    /// UIColor equivalent of TimelineView's private `calendarLegendForegroundColor(for:)`.
    /// Picks white-or-near-black per the background's relative luminance,
    /// so pill text stays readable on whatever event-theme color is in play.
    private static func legendForegroundColor(for background: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = background.resolvedColor(with: traits)
            guard let luminance = Self.relativeLuminance(of: resolved) else {
                return .white
            }
            return luminance > 0.58
                ? UIColor(white: 0.12, alpha: 1)
                : .white
        }
    }

    private static func relativeLuminance(of color: UIColor) -> CGFloat? {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return linearizedSRGBComponent(white)
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return 0.2126 * linearizedSRGBComponent(red)
                + 0.7152 * linearizedSRGBComponent(green)
                + 0.0722 * linearizedSRGBComponent(blue)
        }
        return nil
    }

    private static func linearizedSRGBComponent(_ c: CGFloat) -> CGFloat {
        return c <= 0.03928
            ? c / 12.92
            : pow((c + 0.055) / 1.055, 2.4)
    }
}

// MARK: - Axis marker pill view

/// Single drag-preview pill (a capsule with hour text inside). UIKit
/// equivalent of the SwiftUI `axisMarkerRow` Text + Capsule background
/// (TimelineView.swift:2789-2819).
private final class AxisMarkerPillView: UIView {
    private let label = UILabel()
    private let shadowOpacity: Float = 0.25

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The pill IS the background — clip subviews to its rounded shape
        // by setting `layer.cornerRadius` in `layoutSubviews`.
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                         "cornerRadius": NSNull(), "backgroundColor": NSNull()]
        // Drop shadow parity with `.shadow(... radius: 2, x: 0, y: 1)`.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = shadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.backgroundColor = .clear
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Update the pill's text + theme. Color comparison short-circuits
    /// noisy updates from the per-frame drag path.
    func configure(text: String, background: UIColor, foreground: UIColor) {
        if label.text != text { label.text = text }
        if backgroundColor != background { backgroundColor = background }
        if label.textColor != foreground { label.textColor = foreground }
    }

    override var intrinsicContentSize: CGSize {
        // Parity with SwiftUI `.padding(.horizontal, 4).padding(.vertical, 1)
        // .fixedSize()` — text intrinsic + 8pt horizontal, 2pt vertical.
        let labelSize = label.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(
            width: ceil(labelSize.width) + 8,
            height: max(16, ceil(labelSize.height) + 2)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = bounds.height / 2
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }
}

