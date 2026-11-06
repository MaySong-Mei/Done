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
    /// The day the axis is drawn for: the leftmost column of the settled
    /// window (the selected day in single-day mode).
    let clock: DayClock
    /// The zone, for the day `now` is in when it is not `clock`'s.
    let zoneClock: CalendarZoneClock
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
    /// The instants the now-legend shows for: the axis day on a single-day
    /// page, the settled window in multi-day (gh#285 S2).
    let nowLegendWindow: DateInterval

    func makeUIView(context: Context) -> TimeAxisLayerView {
        let view = TimeAxisLayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TimeAxisLayerView, context: Context) {
        uiView.apply(
            clock: clock,
            zoneClock: zoneClock,
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
            nowLegendWindow: nowLegendWindow
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
        var clock: DayClock
        var zoneClock: CalendarZoneClock
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
        var nowLegendWindow: DateInterval
    }
    private var inputs: Inputs?
    // The labels the pool was last built for, so a clock change can tell
    // whether the rows it brings differ from the rows on screen.
    private var hourLabelTexts: [CalendarAxisHourLabel] = []
    #if DEBUG
    /// TEST-ONLY: how many times a settled clock change brought different
    /// rows, which is what the label container crossfades for.
    private(set) var debugAxisCrossfadeCount = 0
    #endif

    // Hour-label pool. Each non-empty slot (i.e. on the hour) gets one
    // UILabel; empty slots (half-hour ticks when slotMinutes == 30) are
    // skipped entirely to match the SwiftUI tree's `guard minute == 0
    // else { return "" }` rule.
    private var hourLabels: [UILabel] = []
    // Index into `hourLabels` — captures the slot index each pool entry
    // currently represents. Aligned 1:1 with `hourLabels`.
    private var hourLabelSlotIndices: [Int] = []
    // The zone abbreviation under a twice-visited hour's label (gh#285),
    // aligned 1:1 with `hourLabels`; nil for every other slot.
    private var hourLabelZones: [String?] = []
    // Zone sublabel pool, one per non-nil entry of `hourLabelZones`.
    private var zoneLabels: [UILabel] = []

    // Hour labels live in this container so the band-fade mask (#55
    // follow-on) applies ONLY to them — markers + now-legend stay fully
    // opaque, parity with the SwiftUI `.mask(...)` modifier scoping at
    // TimelineView.swift:2685.
    private let hourLabelContainer = UIView()
    // CALayer mask for `hourLabelContainer`. Constructed as a stack of
    // white sublayers with per-band opacity = `1 - fadeProgress`.
    private let hourLabelMaskLayer = CALayer()

    // Now-time legend (mirrors the SwiftUI Text inside the
    // `TimelineView(.periodic(from: .now, by: 1))` block). Rendered as a
    // single UILabel positioned at the current wall-clock time's Y via
    // the shared `calendarTimelineNowLegendY` (gh#80); visible only when
    // the page gate is on (multi-day OR this page IS today) AND the
    // now-pointer lies inside the visible hour window.
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
    private var nowLegendVisible: Bool = true

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
        let now = Date()
        let legendVisible = updateNowLegend(inputs: inputs, now: now)
        updateHourLabelOpacities(inputs: inputs, now: now, legendVisible: legendVisible)
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
        clock: DayClock,
        zoneClock: CalendarZoneClock,
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
        nowLegendWindow: DateInterval
    ) {
        let next = Inputs(
            clock: clock,
            zoneClock: zoneClock,
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
            nowLegendWindow: nowLegendWindow
        )
        if inputs == next { return }
        // Hour-label rebuild is required when the structural inputs change
        // (slot count, extension hours, hour height). Cheaper inputs
        // (fade progress, marker presentation) re-flow through dedicated
        // refresh paths in subsequent commits.
        let structuralChanged = inputs == nil
            || inputs!.clock != next.clock
            || inputs!.headerHeight != next.headerHeight
            || inputs!.hourHeight != next.hourHeight
            || inputs!.slotMinutes != next.slotMinutes
            || inputs!.leadingExtendedHours != next.leadingExtendedHours
            || inputs!.trailingExtendedHours != next.trailingExtendedHours
            || inputs!.drawableLeadingHours != next.drawableLeadingHours
            || inputs!.drawableTrailingHours != next.drawableTrailingHours
        let previous = inputs
        inputs = next
        if structuralChanged {
            let wanted = Self.wantedLabels(inputs: next)
            // The settled window moved the axis onto another day's clock
            // (gh#285 S2). When that alone changes what the rows say, the
            // label container crossfades instead of snapping — the axis's
            // half of the split / merge transition. A pinch or a band also
            // rebuilds the pool, but keeps every row's text, and never
            // crossfades.
            let clockAloneChangedTheRows = previous.map { before in
                before.clock != next.clock
                    && before.headerHeight == next.headerHeight
                    && before.hourHeight == next.hourHeight
                    && before.slotMinutes == next.slotMinutes
                    && before.leadingExtendedHours == next.leadingExtendedHours
                    && before.trailingExtendedHours == next.trailingExtendedHours
                    && before.drawableLeadingHours == next.drawableLeadingHours
                    && before.drawableTrailingHours == next.drawableTrailingHours
                    && wanted.labels != hourLabelTexts
            } ?? false
            if clockAloneChangedTheRows {
                #if DEBUG
                debugAxisCrossfadeCount += 1
                #endif
            }
            if clockAloneChangedTheRows, window != nil, !calendarReduceMotionEnabled {
                UIView.transition(
                    with: hourLabelContainer,
                    duration: DayLayerHostView.legendTransitionDuration,
                    options: [.transitionCrossDissolve, .beginFromCurrentState],
                    animations: { [self] in
                        rebuildHourLabels(wanted: wanted)
                        layoutHourLabels(inputs: next)
                    }
                )
            } else {
                rebuildHourLabels(wanted: wanted)
            }
        }
        layoutHourLabels(inputs: next)
        let now = Date()
        let legendVisible = updateNowLegend(inputs: next, now: now)
        updateHourLabelOpacities(inputs: next, now: now, legendVisible: legendVisible)
        updateAxisMarkers(inputs: next)
        updateHourLabelMask(inputs: next)
    }

    // MARK: - Hour labels (parity with TimeAxisLabels.body's slot ForEach)

    /// The slots that carry a label and what each says, for `inputs`.
    private static func wantedLabels(inputs: Inputs) -> (slots: [Int], labels: [CalendarAxisHourLabel]) {
        // Compute slot count + which slots carry text (on-the-hour only,
        // matching `label(forSlot:)` in `TimeAxisLabels`).
        let slotCount = Self.slotCount(
            clock: inputs.clock,
            slotMinutes: inputs.slotMinutes,
            leadingExtendedHours: inputs.leadingExtendedHours,
            trailingExtendedHours: inputs.trailingExtendedHours
        )
        // Spec 07: draw labels only within the REAL day window (drawable hours);
        // band-region labels are skipped when closed, keeping their Y positions
        // (which use the coordinate hours). Identity when drawable == coordinate.
        let drawTopMin = -inputs.drawableLeadingHours * 60
        let drawBottomMin = calendarTimelineVisibleMinutes(
            clock: inputs.clock,
            trailingExtendedHours: inputs.drawableTrailingHours
        )
        // gh#219 slice E: the time-format read is loop-invariant across both
        // per-slot loops below — hoist it once (was read inside `labelText` on
        // every slot). The first loop only tests nil-ness (unaffected by is24),
        // but the param is now required so it shares this single read.
        let is24 = AppTimeFormat.current.is24
        var wantedSlots: [Int] = []
        var wantedLabels: [CalendarAxisHourLabel] = []
        wantedSlots.reserveCapacity(slotCount)
        for index in 0..<slotCount {
            let slotMin = -inputs.leadingExtendedHours * 60 + index * inputs.slotMinutes
            if slotMin < drawTopMin || slotMin > drawBottomMin { continue }
            if let label = Self.labelText(
                forSlot: index,
                slotMinutes: inputs.slotMinutes,
                leadingExtendedHours: inputs.leadingExtendedHours,
                clock: inputs.clock,
                zoneClock: inputs.zoneClock,
                is24: is24
            ) {
                wantedSlots.append(index)
                wantedLabels.append(label)
            }
        }
        return (wantedSlots, wantedLabels)
    }

    private func rebuildHourLabels(wanted: (slots: [Int], labels: [CalendarAxisHourLabel])) {
        let wantedSlots = wanted.slots
        let wantedLabels = wanted.labels
        hourLabelTexts = wantedLabels
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
        // / extension hours / the day can shift which slot maps to which
        // hour-of-day.
        for (poolIndex, label) in wantedLabels.enumerated() {
            hourLabels[poolIndex].text = label.text
        }
        hourLabelZones = wantedLabels.map(\.zoneAbbreviation)
        let wantedZones = hourLabelZones.compactMap { $0 }
        while zoneLabels.count < wantedZones.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 7, weight: .semibold)
            label.textColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
            label.textAlignment = .right
            label.numberOfLines = 1
            label.backgroundColor = .clear
            hourLabelContainer.addSubview(label)
            zoneLabels.append(label)
        }
        while zoneLabels.count > wantedZones.count {
            zoneLabels.removeLast().removeFromSuperview()
        }
        for (zoneIndex, zone) in wantedZones.enumerated() {
            zoneLabels[zoneIndex].text = zone
        }
    }

    /// The zone sublabel needs its own line under the hour; below this
    /// hour height the lines would collide with the next hour's label.
    static let zoneSublabelMinimumHourHeight: CGFloat = 28

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
        var zoneIndex = 0
        let showsZones = inputs.hourHeight >= Self.zoneSublabelMinimumHourHeight
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
            if poolIndex < hourLabelZones.count, hourLabelZones[poolIndex] != nil, zoneIndex < zoneLabels.count {
                let zoneLabel = zoneLabels[zoneIndex]
                zoneIndex += 1
                zoneLabel.isHidden = !showsZones
                let zoneSize = zoneLabel.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                )
                zoneLabel.frame = CGRect(
                    x: rightEdge - zoneSize.width,
                    y: topY + fitSize.height - 1,
                    width: zoneSize.width,
                    height: zoneSize.height
                )
            }
        }
    }

    // MARK: - Now-time legend (parity with TimeAxisLabels' legend Text)

    /// Returns whether the legend is visible this pass, so the hour-label
    /// collision yield can key off the SAME predicate (gh#80: a culled
    /// legend must not dim any hour label).
    private func updateNowLegend(inputs: Inputs, now: Date) -> Bool {
        // The legend shows only while now is inside the window the axis is
        // drawn for: the page's day, or the settled multi-day window
        // (gh#285 S2; parity with the SwiftUI gate).
        let showsCurrentTime = calendarNowLegendIsShown(now: now, window: inputs.nowLegendWindow)
        nowLegendLabel.text = Self.currentTimeText(for: now)
        nowLegendLabel.textColor = Self.currentTimeIndicatorColor()
        let labelHeight = calendarTimelineNowLegendLabelHeight
        // Single-source position (gh#80), shared with the SwiftUI tree:
        // nil = culled, either because the page gate above is off OR
        // because the now-pointer falls outside the visible hour window
        // (never edge-pinned into the axis frame).
        // The legend sits at now's elapsed time in now's own day: the axis
        // day when now is in it, else (multi-day) the day now is in.
        let nowClock = inputs.clock.contains(now) ? inputs.clock : inputs.zoneClock.day(containing: now)
        let legendY: CGFloat? = showsCurrentTime
            ? calendarTimelineNowLegendY(
                for: now,
                clock: nowClock,
                headerHeight: inputs.headerHeight,
                hourHeight: inputs.hourHeight,
                leadingExtendedHours: inputs.leadingExtendedHours,
                trailingExtendedHours: inputs.trailingExtendedHours
            )
            : nil
        if let legendY {
            let trailingPadding: CGFloat = 2
            let fitSize = nowLegendLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: labelHeight)
            )
            let rightEdge = bounds.width - trailingPadding
            nowLegendLabel.frame = CGRect(
                x: rightEdge - fitSize.width,
                y: legendY,
                width: fitSize.width,
                height: labelHeight
            )
        }
        // When culled the frame is deliberately left where it was — the
        // label is fading to alpha 0 and repositioning it mid-fade would
        // flash it across the axis.
        let legendVisible = legendY != nil
        // Crossfade on visibility flips. SwiftUI uses
        // `.animation(.easeInOut(duration: 0.22), value: legendY != nil)`
        // — mirror with UIView.animate. No-op when already in target state.
        let targetAlpha: CGFloat = legendVisible ? 1 : 0
        if nowLegendLabel.alpha != targetAlpha
            || nowLegendVisible != legendVisible
        {
            nowLegendVisible = legendVisible
            UIView.animate(
                withDuration: 0.22, delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: { [weak self] in
                    self?.nowLegendLabel.alpha = targetAlpha
                }
            )
        }
        return legendVisible
    }

    /// Yield the colliding hour label's opacity to the now-legend when
    /// they overlap within `collisionThresholdPoints`. Driven by the same
    /// 1-Hz tick + a crossfade animation so the page-switch transition
    /// blends back in step. Mirrors `TimeAxisLabels.hourLabelOpacity`.
    private func updateHourLabelOpacities(inputs: Inputs, now: Date, legendVisible: Bool) {
        // The same elapsed measure the slots are laid out in, against the
        // day the legend was positioned on.
        let nowClock = inputs.clock.contains(now) ? inputs.clock : inputs.zoneClock.day(containing: now)
        let nowTotalMinutes = calendarTimelineElapsedMinutes(of: now, clock: nowClock)
        for (poolIndex, slotIndex) in hourLabelSlotIndices.enumerated() {
            let label = hourLabels[poolIndex]
            let totalMinutes = -inputs.leadingExtendedHours * 60
                + slotIndex * inputs.slotMinutes
            let targetAlpha: CGFloat
            if !legendVisible {
                // No legend rendered (page gate off or out-of-window cull,
                // both routed through `updateNowLegend`'s return — gh#80)
                // → nothing to yield to.
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
        let baseHeight = calendarTimelineContentHeight(clock: inputs.clock, hourHeight: inputs.hourHeight)
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
        let yMin = inputs.headerHeight
        let yMax = inputs.headerHeight + calendarTimelineContentHeight(
            clock: inputs.clock,
            hourHeight: inputs.hourHeight,
            leadingExtendedHours: inputs.leadingExtendedHours,
            trailingExtendedHours: inputs.trailingExtendedHours
        )
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
        clock: DayClock,
        slotMinutes: Int,
        leadingExtendedHours: Int,
        trailingExtendedHours: Int
    ) -> Int {
        let totalMinutes = calendarTimelineVisibleMinutes(
            clock: clock,
            leadingExtendedHours: leadingExtendedHours,
            trailingExtendedHours: trailingExtendedHours
        )
        return max(1, totalMinutes / max(1, slotMinutes) + 1)
    }

    /// Mirrors `TimeAxisLabels.label(forSlot:)`. Returns nil for empty
    /// slots (half-hour ticks etc.) so the rebuild path skips them
    /// entirely; non-nil slots produce labels in the pool. The text is the
    /// hour of the slot's real instant (gh#285), through the shared
    /// `calendarTimelineAxisHourLabel`.
    // gh#219 slice E: internal so the hoist test can pin the is24 arm.
    static func labelText(
        forSlot index: Int,
        slotMinutes: Int,
        leadingExtendedHours: Int,
        clock: DayClock,
        zoneClock: CalendarZoneClock,
        is24: Bool
    ) -> CalendarAxisHourLabel? {
        calendarTimelineAxisHourLabel(
            slotMinute: -leadingExtendedHours * 60 + index * slotMinutes,
            clock: clock,
            zoneClock: zoneClock,
            is24: is24
        )
    }

    /// Mirrors `TimeAxisLabels.currentTimeText(for:)` + the static
    /// `currentTimeFormatter`. Lowercased to match the SwiftUI tree
    /// (`...string(from: now).lowercased()`).
    // gh#219 slice B: SELECTED static-let pair (was a fresh DateFormatter per
    // call, driven by the 1Hz Timer). Byte-identical config; the `.lowercased()`
    // that mirrors the SwiftUI tree is preserved at the return.
    private static let currentTimeFormatter24: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()
    private static let currentTimeFormatter12: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
    static func currentTimeText(for now: Date) -> String {
        let formatter = AppTimeFormat.current.is24 ? currentTimeFormatter24 : currentTimeFormatter12
        return formatter.string(from: now).lowercased()
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

