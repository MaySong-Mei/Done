//
//  MiniDayTimelineLayerView.swift
//  Done
//
//  CALayer-backed port of the SwiftUI `miniDayTimelineVisual` overlay
//  (issue #71). The mini-day timeline is the compact preview rendered
//  inside `CalendarEventDetailView` that frames the focused event in
//  context with surrounding sibling occurrences, an hour grid, an optional
//  live-progress fill, note markers, and a current-position thumb.
//
//  Goal: pixel parity with the SwiftUI tree at
//  `CalendarEventDetailView.swift:miniDayTimelineVisual` without a SwiftUI
//  re-evaluation per `TimelineView(.periodic)` tick. Gated by
//  `AppSettingsKeys.calendarUseCALayerMiniDayTimeline`, default OFF;
//  flipped ON only after A/B parity is verified (mirrors the #60→#74 arc).
//
//  This file is intentionally self-contained UIKit/CALayer code — it
//  pulls shared math from the file-scope helpers in `EventBlock.swift`
//  (`calendarEventTextLayout`, `calendarEventTimeFontSize`,
//  `calendarEventBlockTitleSpacing`) and from `CalendarLayout`
//  (`overlapLayout`) so the SwiftUI path and the CALayer path share one
//  source of truth.
//
//  Scope: STATIC preview surface — no pinch, no scroll, no drag, no
//  resize. The live tick (1Hz) only refreshes the focused-block progress
//  fill, the current-position thumb, and the note-nearby highlights —
//  all the other geometry rebuilds only when the host re-applies inputs.

import SwiftUI
import UIKit

// MARK: - Inputs (host → renderer)

/// Snapshot of everything the CALayer mini-day renderer needs to draw a
/// frame. Designed to be cheap to construct on the SwiftUI side (the
/// caller computes the overlap layout once, passes the result through)
/// and `Equatable` so repeated SwiftUI body re-evals short-circuit when
/// nothing changed — same idempotent-apply pattern as `TimeAxisLayerView`.
struct MiniDayTimelineLayerInputs: Equatable {
    /// Focused event + the time-range slice the detail page is rendering
    /// (matches the SwiftUI `range` parameter; may differ from the
    /// event's stored range when the parent is scoping to one occurrence).
    var focusedEvent: Event
    var focusedRange: Event.TimeRange
    /// Slot dictionary keyed by occurrence id, as produced by
    /// `CalendarLayout.overlapLayout(..., mode: .equalSplit)`. The
    /// focused event also has an entry here.
    var slots: [String: CalendarLayout.EventOverlapSlot]
    /// Sibling occurrences in render order, excluding the focused event
    /// and any interrupt children that are drawn via the stripe overlay.
    var siblingOccurrences: [CalendarLayout.EventOccurrence]
    /// The synthetic id used for the focused event's slot (mirrors
    /// `MiniDayLayout.focusedID` on the SwiftUI side).
    var focusedSlotID: String
    /// Interrupt children of the focused event, drawn as right-edge
    /// stripes inside the focused block (expanded only).
    var interruptStripes: [Stripe]
    /// Timeline notes drawn as marker dots (expanded only, mirrors the
    /// SwiftUI `notes` parameter).
    var notes: [EventLogTimelineNote]
    /// Current scrubbing mode. `.live` → progress follows wall clock;
    /// `.manual` → progress is `manualProgress`. Live progress + thumb
    /// position + note-nearby highlights derive from this.
    var timelineMode: CalendarEventTimelineMode
    var manualProgress: CGFloat
    /// Window pad above and below the focused range. The SwiftUI tree
    /// uses `focusedRange ± 3600s` and hardcodes 90pt hour height; we
    /// pass these through so the renderer doesn't need to recompute.
    var windowStart: Date
    var windowEnd: Date
    var hourHeight: CGFloat
    var collapsedHeight: CGFloat
    var isExpanded: Bool
    /// Mirrors the user's `calendarEventFontSize` setting (clamped 9–16
    /// upstream). Drives both the title and the time-row font sizes via
    /// the shared `calendarEventTextLayout` helper.
    var baseFontSize: CGFloat
    var showTimeBelowTitle: Bool

    struct Stripe: Equatable, Hashable {
        let id: UUID
        let tint: Color
        /// Fraction (0…1) of the focused range where the stripe starts.
        let startFraction: Double
        /// Fraction (0…1) of the focused range where the stripe ends.
        let endFraction: Double
    }
}

// MARK: - SwiftUI host

/// SwiftUI-side host for the CALayer mini-day timeline. Drop-in renderer
/// for the SwiftUI `miniDayTimelineVisual` body sans the chevron + tap
/// gesture (those stay in SwiftUI — they are not hot-path).
struct MiniDayTimelineLayerHost: UIViewRepresentable {
    let inputs: MiniDayTimelineLayerInputs

    func makeUIView(context: Context) -> MiniDayTimelineLayerView {
        let view = MiniDayTimelineLayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: MiniDayTimelineLayerView, context: Context) {
        uiView.apply(inputs: inputs)
    }
}

// MARK: - UIView host (CALayer backing)

/// CALayer-backed mini-day timeline. Owns sublayers for the hour-axis
/// labels, the hour grid lines, sibling event blocks, the focused event
/// block (with live progress fill), interrupt stripes, note markers, and
/// the current-position thumb.
///
/// All sublayers have implicit animations disabled — the host never
/// animates, parity with the SwiftUI tree (which has no animation on the
/// mini-day surface beyond the chevron-driven `withAnimation` toggle
/// applied to the SwiftUI host wrapper, not its internals).
final class MiniDayTimelineLayerView: UIView {
    /// Width reserved for the leading hour-label column. Matches the
    /// SwiftUI `frame(width: 30)` on `miniDayHourLabels`.
    private static let hourColumnWidth: CGFloat = 30

    private var currentInputs: MiniDayTimelineLayerInputs?

    // Hour column (labels) — fixed-width view on the left, holding label
    // pool. Lives in its own UIView so the trailing event-block area can
    // get the remaining width without slicing layer math.
    private let hourLabelContainer = UIView()
    private var hourLabels: [UILabel] = []

    // Event-block area container — holds the grid lines, sibling blocks,
    // focused block, interrupt stripes, note markers, and thumb. Sits to
    // the right of the hour column.
    private let eventAreaContainer = UIView()

    // Hour grid lines — lightweight CALayer per line. Rebuilt structurally
    // when the window changes; positions update on every layout pass.
    private var hourGridLines: [CALayer] = []

    // Event-block visuals. Each entry owns the small subtree (background,
    // mid-overlay for live progress, border, effort bar, title, time row).
    private var siblingBlocks: [String: BlockLayers] = [:]
    private let focusedBlock = BlockLayers()
    private var focusedBlockInstalled = false

    // Interrupt stripe pool (right-edge stripes inside the focused block).
    private var stripeLayers: [CAShapeLayer] = []

    // Note marker pool (dot + horizontal hairline). Each entry is one
    // marker; the pool grows / shrinks with `inputs.notes.count`.
    private var noteMarkers: [NoteMarker] = []

    // Current-position thumb (4×12pt rounded rect + thin hairline). Drawn
    // only when expanded.
    private let thumbBlock = CALayer()
    private let thumbLine = CALayer()

    // Periodic tick — drives live progress fill, thumb position, and note
    // nearby highlighting. Mirrors SwiftUI's
    // `TimelineView(.periodic(from: .now, by: 1))`. Tolerance 0.25s so the
    // OS can coalesce wake-ups with other low-rate timers.
    private var nowTickTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.actions = MiniDayTimelineLayerView.disabledActions
        hourLabelContainer.isUserInteractionEnabled = false
        hourLabelContainer.backgroundColor = .clear
        hourLabelContainer.layer.actions = MiniDayTimelineLayerView.disabledActions
        eventAreaContainer.isUserInteractionEnabled = false
        eventAreaContainer.backgroundColor = .clear
        eventAreaContainer.clipsToBounds = false
        eventAreaContainer.layer.actions = MiniDayTimelineLayerView.disabledActions
        addSubview(hourLabelContainer)
        addSubview(eventAreaContainer)

        // Thumb block + line: lazily installed below the focused block on
        // first expand. `isHidden = true` keeps them inert until then.
        thumbBlock.isHidden = true
        thumbLine.isHidden = true
        thumbBlock.actions = MiniDayTimelineLayerView.disabledActions
        thumbLine.actions = MiniDayTimelineLayerView.disabledActions
        thumbBlock.cornerRadius = 1.5
        eventAreaContainer.layer.addSublayer(thumbLine)
        eventAreaContainer.layer.addSublayer(thumbBlock)
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
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshNowDependentState()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        nowTickTimer = timer
        refreshNowDependentState()
    }

    private func stopNowTick() {
        nowTickTimer?.invalidate()
        nowTickTimer = nil
    }

    private func refreshNowDependentState() {
        guard let currentInputs else { return }
        updateLiveOverlays(inputs: currentInputs, now: Date())
    }

    fileprivate static let disabledActions: [String: CAAction] = [
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
        layoutContainers()
        if let currentInputs {
            layoutContent(inputs: currentInputs)
        }
    }

    /// Mini-day height in points: the SwiftUI tree uses `displayHeight`
    /// (= collapsedHeight or fullHeight) clipped over a `fullHeight`
    /// content frame offset by `contentOffset`. We mirror that exactly so
    /// the renderer's `bounds.height` matches the SwiftUI layout it's
    /// replacing.
    private func layoutContainers() {
        let columnWidth = MiniDayTimelineLayerView.hourColumnWidth
        hourLabelContainer.frame = CGRect(
            x: 0, y: 0,
            width: columnWidth, height: bounds.height
        )
        eventAreaContainer.frame = CGRect(
            x: columnWidth, y: 0,
            width: max(0, bounds.width - columnWidth),
            height: bounds.height
        )
    }

    // MARK: - Apply

    /// Apply latest inputs from the SwiftUI host. Idempotent — repeated
    /// calls with the same inputs return early so SwiftUI body re-evals
    /// (which call `updateUIView` on every up-tree state change) don't
    /// churn CALayer.
    func apply(inputs: MiniDayTimelineLayerInputs) {
        if currentInputs == inputs { return }
        currentInputs = inputs
        rebuildStructure(inputs: inputs)
        setNeedsLayout()
        layoutIfNeeded()
        updateLiveOverlays(inputs: inputs, now: Date())
    }

    // MARK: - Structure rebuild

    private func rebuildStructure(inputs: MiniDayTimelineLayerInputs) {
        rebuildHourLabels(inputs: inputs)
        rebuildHourGridLines(inputs: inputs)
        rebuildSiblingBlocks(inputs: inputs)
        installFocusedBlockIfNeeded()
        rebuildStripes(inputs: inputs)
        rebuildNoteMarkers(inputs: inputs)
    }

    private func layoutContent(inputs: MiniDayTimelineLayerInputs) {
        layoutHourLabels(inputs: inputs)
        layoutHourGridLines(inputs: inputs)
        layoutSiblingBlocks(inputs: inputs)
        layoutFocusedBlock(inputs: inputs)
        layoutStripes(inputs: inputs)
        layoutNoteMarkers(inputs: inputs)
        // Thumb position is live-only; primed here so the initial layout
        // (pre-tick) is already correct.
        positionThumb(inputs: inputs, now: Date())
    }

    // MARK: - Hour labels (parity with miniDayHourLabels)

    private func rebuildHourLabels(inputs: MiniDayTimelineLayerInputs) {
        let texts = Self.hourLabelTexts(
            windowStart: inputs.windowStart,
            windowEnd: inputs.windowEnd
        )
        while hourLabels.count < texts.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 10, weight: .medium)
            // Apply monospaced-digit feature for time-format parity with
            // the SwiftUI `.monospacedDigit()` modifier.
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = UIColor.secondaryLabel
            label.textAlignment = .right
            label.numberOfLines = 1
            label.backgroundColor = .clear
            hourLabelContainer.addSubview(label)
            hourLabels.append(label)
        }
        while hourLabels.count > texts.count {
            hourLabels.removeLast().removeFromSuperview()
        }
        for (i, item) in texts.enumerated() {
            hourLabels[i].text = item.text
        }
    }

    private func layoutHourLabels(inputs: MiniDayTimelineLayerInputs) {
        let texts = Self.hourLabelTexts(
            windowStart: inputs.windowStart,
            windowEnd: inputs.windowEnd
        )
        let containerWidth = hourLabelContainer.bounds.width
        // SwiftUI uses `.position(x: 15, y: yPos)` — geometric center at
        // x=15 with `.foregroundStyle(.secondary)` font(10pt medium). The
        // UIKit equivalent centers the label horizontally on x=15 too.
        let centerX: CGFloat = 15
        // Content offset mirrors the SwiftUI `.offset(y: contentOffset)`
        // applied to the full-height content stack before clipping.
        let contentOffset = Self.contentOffsetY(for: inputs)
        for (i, item) in texts.enumerated() {
            guard i < hourLabels.count else { break }
            let label = hourLabels[i]
            let fit = label.sizeThatFits(
                CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            )
            let yPos = CGFloat(item.date.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
            label.frame = CGRect(
                x: centerX - fit.width / 2,
                y: yPos + contentOffset - fit.height / 2,
                width: fit.width, height: fit.height
            )
        }
    }

    /// Mirrors the SwiftUI `miniDayHourLabels` slot construction: every
    /// whole-hour boundary inside `[windowStart, windowEnd)`, with the
    /// first slot starting at the next whole-hour ≥ windowStart.
    private static func hourLabelTexts(
        windowStart: Date,
        windowEnd: Date
    ) -> [(date: Date, text: String)] {
        let calendar = Calendar.current
        let startHourComp = calendar.dateComponents([.year, .month, .day, .hour], from: windowStart)
        let firstWholeHour = calendar.date(from: startHourComp) ?? windowStart
        let start = firstWholeHour <= windowStart
            ? firstWholeHour.addingTimeInterval(3600)
            : firstWholeHour

        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "ha"
            formatter.amSymbol = "a"
            formatter.pmSymbol = "p"
        }

        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        let hourCount = max(0, Int(ceil(windowDuration / 3600)) + 1)
        var result: [(date: Date, text: String)] = []
        result.reserveCapacity(hourCount)
        for i in 0..<hourCount {
            let hourDate = start.addingTimeInterval(Double(i) * 3600)
            if hourDate < windowEnd {
                result.append((hourDate, formatter.string(from: hourDate)))
            }
        }
        return result
    }

    // MARK: - Hour grid lines (parity with miniDayGridLines)

    private func rebuildHourGridLines(inputs: MiniDayTimelineLayerInputs) {
        let texts = Self.hourLabelTexts(
            windowStart: inputs.windowStart,
            windowEnd: inputs.windowEnd
        )
        while hourGridLines.count < texts.count {
            let line = CALayer()
            line.backgroundColor = UIColor.label.withAlphaComponent(0.06).cgColor
            line.actions = MiniDayTimelineLayerView.disabledActions
            eventAreaContainer.layer.insertSublayer(line, at: 0)
            hourGridLines.append(line)
        }
        while hourGridLines.count > texts.count {
            hourGridLines.removeLast().removeFromSuperlayer()
        }
        // Re-color in case of trait change (light → dark).
        for line in hourGridLines {
            line.backgroundColor = UIColor.label.withAlphaComponent(0.06).cgColor
        }
    }

    private func layoutHourGridLines(inputs: MiniDayTimelineLayerInputs) {
        let texts = Self.hourLabelTexts(
            windowStart: inputs.windowStart,
            windowEnd: inputs.windowEnd
        )
        let width = eventAreaContainer.bounds.width
        let contentOffset = Self.contentOffsetY(for: inputs)
        for (i, item) in texts.enumerated() {
            guard i < hourGridLines.count else { break }
            let yPos = CGFloat(item.date.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
            hourGridLines[i].frame = CGRect(
                x: 0,
                y: yPos + contentOffset,
                width: width,
                height: 0.5
            )
        }
    }

    // MARK: - Sibling event blocks

    private func rebuildSiblingBlocks(inputs: MiniDayTimelineLayerInputs) {
        // Drop entries whose occurrence id is no longer in the inputs;
        // recycle the rest. The pool is keyed by occurrence id (stable
        // across re-applies) so a sibling's CALayer subtree lives across
        // structural changes without flicker.
        let liveIDs = Set(inputs.siblingOccurrences.map(\.id))
        for (id, block) in siblingBlocks where !liveIDs.contains(id) {
            block.removeFromSuperlayer()
            siblingBlocks.removeValue(forKey: id)
        }
        for occurrence in inputs.siblingOccurrences {
            if siblingBlocks[occurrence.id] == nil {
                let block = BlockLayers()
                block.install(in: eventAreaContainer.layer, below: focusedBlockInstalled ? focusedBlock.container : nil)
                siblingBlocks[occurrence.id] = block
            }
        }
    }

    private func installFocusedBlockIfNeeded() {
        guard !focusedBlockInstalled else { return }
        focusedBlock.install(in: eventAreaContainer.layer, below: nil)
        focusedBlockInstalled = true
    }

    private func layoutSiblingBlocks(inputs: MiniDayTimelineLayerInputs) {
        let areaWidth = eventAreaContainer.bounds.width
        let contentOffset = Self.contentOffsetY(for: inputs)
        for occurrence in inputs.siblingOccurrences {
            guard let block = siblingBlocks[occurrence.id] else { continue }
            let slot = inputs.slots[occurrence.id] ?? .default
            let blockStart = max(occurrence.range.start, inputs.windowStart)
            let blockEnd = min(occurrence.range.end, inputs.windowEnd)
            let yTop = CGFloat(blockStart.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
            let heightSeconds = max(0, blockEnd.timeIntervalSince(blockStart))
            // Duration-proportional; 2pt hairline floor for zero-duration
            // edge case (matches the SwiftUI `max(2, …)` floor).
            let blockHeight = max(2, CGFloat(heightSeconds / 3600) * inputs.hourHeight)
            let xOffset = slot.xOffsetFraction * areaWidth
            // -1pt trailing gap parity (SwiftUI `slot.widthFraction *
            // areaWidth - 1` floor at 8pt).
            let blockWidth = max(8, slot.widthFraction * areaWidth - 1)
            block.configure(
                event: occurrence.event,
                displayRange: occurrence.range,
                frame: CGRect(
                    x: xOffset,
                    y: yTop + contentOffset,
                    width: blockWidth, height: blockHeight
                ),
                isFocused: false,
                baseFontSize: inputs.baseFontSize,
                showTimeBelowTitle: inputs.showTimeBelowTitle
            )
        }
    }

    private func layoutFocusedBlock(inputs: MiniDayTimelineLayerInputs) {
        let areaWidth = eventAreaContainer.bounds.width
        let contentOffset = Self.contentOffsetY(for: inputs)
        let slot = inputs.slots[inputs.focusedSlotID] ?? .default
        let xOffset = slot.xOffsetFraction * areaWidth
        let width = max(8, slot.widthFraction * areaWidth - 1)
        let eventDuration = inputs.focusedRange.end.timeIntervalSince(inputs.focusedRange.start)
        let yTop = CGFloat(inputs.focusedRange.start.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
        let height = max(2, CGFloat(eventDuration / 3600) * inputs.hourHeight)
        focusedBlock.configure(
            event: inputs.focusedEvent,
            displayRange: inputs.focusedRange,
            frame: CGRect(
                x: xOffset,
                y: yTop + contentOffset,
                width: width, height: height
            ),
            isFocused: true,
            baseFontSize: inputs.baseFontSize,
            showTimeBelowTitle: inputs.showTimeBelowTitle
        )
    }

    // MARK: - Interrupt stripes (parity with the SwiftUI ForEach)

    private func rebuildStripes(inputs: MiniDayTimelineLayerInputs) {
        let needed = inputs.isExpanded ? inputs.interruptStripes.count : 0
        while stripeLayers.count < needed {
            let layer = CAShapeLayer()
            layer.actions = MiniDayTimelineLayerView.disabledActions
            layer.fillColor = UIColor.clear.cgColor
            eventAreaContainer.layer.addSublayer(layer)
            stripeLayers.append(layer)
        }
        while stripeLayers.count > needed {
            stripeLayers.removeLast().removeFromSuperlayer()
        }
    }

    private func layoutStripes(inputs: MiniDayTimelineLayerInputs) {
        guard inputs.isExpanded else {
            for layer in stripeLayers { layer.isHidden = true }
            return
        }
        let areaWidth = eventAreaContainer.bounds.width
        let contentOffset = Self.contentOffsetY(for: inputs)
        let slot = inputs.slots[inputs.focusedSlotID] ?? .default
        let xOffset = slot.xOffsetFraction * areaWidth
        let eventDuration = inputs.focusedRange.end.timeIntervalSince(inputs.focusedRange.start)
        let focusedYTop = CGFloat(inputs.focusedRange.start.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
        let focusedHeight = max(2, CGFloat(eventDuration / 3600) * inputs.hourHeight)
        // SwiftUI: stripe is `.frame(width: 6, height: segHeight)`
        // `.offset(x: focusedX + 2, y: focusedY + startFrac * focusedH)`.
        let stripeWidth: CGFloat = 6
        let stripeXOffset: CGFloat = 2
        let cornerRadius: CGFloat = 3
        for (i, stripe) in inputs.interruptStripes.enumerated() {
            guard i < stripeLayers.count else { break }
            let layer = stripeLayers[i]
            let segHeight = max(4, CGFloat(stripe.endFraction - stripe.startFraction) * focusedHeight)
            let y = focusedYTop + contentOffset + CGFloat(stripe.startFraction) * focusedHeight
            let rect = CGRect(x: xOffset + stripeXOffset, y: y, width: stripeWidth, height: segHeight)
            layer.path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).cgPath
            layer.fillColor = UIColor(stripe.tint).withAlphaComponent(0.6).cgColor
            layer.isHidden = false
        }
    }

    // MARK: - Note markers + thumb (live-driven via the 1Hz tick)

    private func rebuildNoteMarkers(inputs: MiniDayTimelineLayerInputs) {
        let needed = inputs.isExpanded ? inputs.notes.count : 0
        while noteMarkers.count < needed {
            let marker = NoteMarker()
            marker.install(in: eventAreaContainer.layer)
            noteMarkers.append(marker)
        }
        while noteMarkers.count > needed {
            noteMarkers.removeLast().removeFromSuperlayer()
        }
    }

    private func layoutNoteMarkers(inputs: MiniDayTimelineLayerInputs) {
        guard inputs.isExpanded else {
            for marker in noteMarkers { marker.hide() }
            return
        }
        let areaWidth = eventAreaContainer.bounds.width
        let contentOffset = Self.contentOffsetY(for: inputs)
        let eventDuration = inputs.focusedRange.end.timeIntervalSince(inputs.focusedRange.start)
        let focusedYTop = CGFloat(inputs.focusedRange.start.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
        let focusedHeight = max(2, CGFloat(eventDuration / 3600) * inputs.hourHeight)
        for (i, note) in inputs.notes.enumerated() {
            guard i < noteMarkers.count else { break }
            let progress = calendarEventTimelineProgress(for: note.createdAt, range: inputs.focusedRange)
            let noteY = focusedYTop + contentOffset + focusedHeight * progress
            // Default to NOT nearby; live tick updates nearby state.
            noteMarkers[i].layout(
                centerY: noteY,
                areaWidth: areaWidth,
                isNearby: false
            )
        }
        _ = eventDuration
    }

    private func updateLiveOverlays(inputs: MiniDayTimelineLayerInputs, now: Date) {
        // 1. Focused-block live progress fill
        let liveState = calendarEventTimelineResolvedState(
            mode: inputs.timelineMode,
            manualProgress: inputs.manualProgress,
            now: now,
            range: inputs.focusedRange
        )
        focusedBlock.applyLiveProgress(
            displayProgress: liveState.displayProgress,
            tint: UIColor(CalendarLayout.eventColor(for: inputs.focusedEvent))
        )

        guard inputs.isExpanded else {
            thumbBlock.isHidden = true
            thumbLine.isHidden = true
            for marker in noteMarkers { marker.setNearby(false) }
            return
        }

        // 2. Note nearby highlight — mirrors `isNoteNearSlider` (window =
        // max(5% of total, 60s)).
        let snapshotDate = liveState.snapshotDate
        let totalDuration = inputs.focusedRange.end.timeIntervalSince(inputs.focusedRange.start)
        let nearbyWindow = max(totalDuration * 0.05, 60)
        for (i, note) in inputs.notes.enumerated() {
            guard i < noteMarkers.count else { break }
            let isNearby = abs(note.createdAt.timeIntervalSince(snapshotDate)) <= nearbyWindow
            noteMarkers[i].setNearby(isNearby)
        }

        // 3. Current-position thumb
        positionThumb(inputs: inputs, now: now)
    }

    private func positionThumb(inputs: MiniDayTimelineLayerInputs, now: Date) {
        guard inputs.isExpanded else {
            thumbBlock.isHidden = true
            thumbLine.isHidden = true
            return
        }
        let liveState = calendarEventTimelineResolvedState(
            mode: inputs.timelineMode,
            manualProgress: inputs.manualProgress,
            now: now,
            range: inputs.focusedRange
        )
        let areaWidth = eventAreaContainer.bounds.width
        let contentOffset = Self.contentOffsetY(for: inputs)
        let eventDuration = inputs.focusedRange.end.timeIntervalSince(inputs.focusedRange.start)
        let focusedYTop = CGFloat(inputs.focusedRange.start.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
        let focusedHeight = max(2, CGFloat(eventDuration / 3600) * inputs.hourHeight)
        let thumbY = focusedYTop + contentOffset + focusedHeight * liveState.displayProgress
        let tint = UIColor(CalendarLayout.eventColor(for: inputs.focusedEvent))
        thumbBlock.isHidden = false
        thumbLine.isHidden = false
        // SwiftUI: HStack { 4×12 rounded rect (tint) + 1pt rect (tint @ 0.5) }
        // `.offset(y: thumbY - 6)`. The rounded rect is at the leading
        // edge (x=0), the hairline trails it across the area width.
        thumbBlock.frame = CGRect(x: 0, y: thumbY - 6, width: 4, height: 12)
        thumbBlock.backgroundColor = tint.cgColor
        thumbLine.frame = CGRect(x: 4, y: thumbY - 0.5, width: max(0, areaWidth - 4), height: 1)
        thumbLine.backgroundColor = tint.withAlphaComponent(0.5).cgColor
    }

    // MARK: - Helpers

    /// Mirrors the SwiftUI tree's `contentOffset` (`isExpanded ? 0 :
    /// -eventTop`). When collapsed, content slides up so the focused
    /// event sits at the top.
    private static func contentOffsetY(for inputs: MiniDayTimelineLayerInputs) -> CGFloat {
        if inputs.isExpanded { return 0 }
        let eventTop = CGFloat(inputs.focusedRange.start.timeIntervalSince(inputs.windowStart) / 3600) * inputs.hourHeight
        return -eventTop
    }
}

// MARK: - Block layers (event-block visual subtree)

/// CALayer subtree for a single mini-day event block. Mirrors the SwiftUI
/// `miniDayEventBlockVisual` exactly: systemBackground knock-out + tint
/// fill + optional mid-overlay (live progress for the focused block) +
/// border + effort bar + title + optional time row.
private final class BlockLayers {
    let container = CALayer()
    private let backgroundLayer = CAShapeLayer()
    private let tintLayer = CAShapeLayer()
    private let midOverlay = CALayer()          // focused-block progress fill
    private let borderLayer = CAShapeLayer()
    private let effortBarLayer = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let timeLayer = CATextLayer()

    private static let cornerRadius: CGFloat = 6
    private static let strokeWidth: CGFloat = 1.2

    private var lastConfigKey: ConfigKey?

    private struct ConfigKey: Equatable {
        let eventID: UUID
        let title: String
        let typeKey: String
        let rangeStart: Date
        let rangeEnd: Date
        let width: CGFloat
        let height: CGFloat
        let isFocused: Bool
        let colorDepth: Int
        let baseFontSize: CGFloat
        let showTimeBelowTitle: Bool
    }

    init() {
        container.actions = MiniDayTimelineLayerView.disabledActions
        for layer in [backgroundLayer, tintLayer, borderLayer, effortBarLayer] {
            layer.actions = MiniDayTimelineLayerView.disabledActions
            layer.fillColor = UIColor.clear.cgColor
            layer.contentsScale = UIScreen.main.scale
        }
        midOverlay.actions = MiniDayTimelineLayerView.disabledActions
        for text in [titleLayer, timeLayer] {
            text.actions = MiniDayTimelineLayerView.disabledActions
            text.contentsScale = UIScreen.main.scale
            text.isWrapped = true
            text.truncationMode = .end
            text.alignmentMode = .left
        }
        // SwiftUI tree z-order (bottom → top):
        //   systemBackground knockout → tint fill → midOverlay (clipped) →
        //   border → effort bar → title → time
        container.addSublayer(backgroundLayer)
        container.addSublayer(tintLayer)
        container.addSublayer(midOverlay)
        container.addSublayer(borderLayer)
        container.addSublayer(effortBarLayer)
        container.addSublayer(titleLayer)
        container.addSublayer(timeLayer)
        // The mid-overlay clips to the block silhouette (cornerRadius),
        // mirroring SwiftUI `.clipShape(blockShape)` on the caller-injected
        // overlay.
        midOverlay.cornerRadius = BlockLayers.cornerRadius
        midOverlay.masksToBounds = true
    }

    func install(in parent: CALayer, below: CALayer?) {
        if let below {
            parent.insertSublayer(container, below: below)
        } else {
            parent.addSublayer(container)
        }
    }

    func removeFromSuperlayer() {
        container.removeFromSuperlayer()
    }

    func configure(
        event: Event,
        displayRange: Event.TimeRange,
        frame: CGRect,
        isFocused: Bool,
        baseFontSize: CGFloat,
        showTimeBelowTitle: Bool
    ) {
        container.frame = frame
        let bodyRect = CGRect(origin: .zero, size: frame.size)
        // Continuous-rounded-rect path matching `RoundedRectangle(style:
        // .continuous)`. We use UIBezierPath's circular approximation — the
        // 6pt radius is small enough on a mini-day block that the
        // continuous/circular difference is sub-pixel; the main calendar's
        // exact superellipse helper isn't worth re-importing.
        let path = UIBezierPath(roundedRect: bodyRect, cornerRadius: BlockLayers.cornerRadius).cgPath

        backgroundLayer.frame = bodyRect
        backgroundLayer.path = path
        backgroundLayer.fillColor = UIColor.systemBackground.cgColor

        let tint = UIColor(CalendarLayout.eventColor(for: event))
        let fillOpacity: CGFloat = isFocused ? 0.5 : 0.4
        tintLayer.frame = bodyRect
        tintLayer.path = path
        tintLayer.fillColor = tint.withAlphaComponent(fillOpacity).cgColor

        // midOverlay frame matches the bodyRect so live-progress writes
        // can size their own sublayers against (0,0,width,height). Hidden
        // by default; the focused block's `applyLiveProgress` unhides it.
        midOverlay.frame = bodyRect
        if !isFocused {
            midOverlay.isHidden = true
            midOverlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        }

        let strokeOpacity: CGFloat = isFocused ? 0.9 : 0.7
        borderLayer.frame = bodyRect
        borderLayer.path = path
        borderLayer.strokeColor = tint.withAlphaComponent(strokeOpacity).cgColor
        borderLayer.lineWidth = BlockLayers.strokeWidth
        borderLayer.fillColor = UIColor.clear.cgColor

        // Effort bar — 1.0 + colorDepth * 1.5 pt wide strip at the leading
        // edge, masked to the block silhouette (so its top/bottom corners
        // curve with the block).
        if event.colorDepth > 0 {
            let barWidth: CGFloat = 1.0 + CGFloat(event.colorDepth) * 1.5
            let barRect = CGRect(x: 0, y: 0, width: barWidth, height: bodyRect.height)
            // Compose: intersect the block silhouette (path) with a
            // leading-aligned width rectangle. CAShapeLayer doesn't
            // compose paths intrinsically, so we use a mask layer.
            effortBarLayer.frame = bodyRect
            // Draw the bar as a filled path of the leading strip,
            // then clip it to the block silhouette via a separate mask.
            effortBarLayer.path = UIBezierPath(rect: barRect).cgPath
            effortBarLayer.fillColor = tint.cgColor
            // Mask installs the silhouette path so the corners match.
            let mask: CAShapeLayer
            if let existing = effortBarLayer.mask as? CAShapeLayer {
                mask = existing
            } else {
                mask = CAShapeLayer()
                mask.actions = MiniDayTimelineLayerView.disabledActions
                effortBarLayer.mask = mask
            }
            mask.path = path
            mask.frame = bodyRect
            mask.fillColor = UIColor.white.cgColor
            effortBarLayer.isHidden = false
        } else {
            effortBarLayer.isHidden = true
        }

        // Text layout uses the shared helper so the SwiftUI and CALayer
        // paths share one source of truth for content rect + lineLimit +
        // showsTimeRange + verticalCenter.
        let title = event.title.isEmpty ? "Untitled" : event.title
        let textLayout = calendarEventTextLayout(
            in: bodyRect,
            title: title,
            requireTitleFit: false,
            styleShowTimeRange: isFocused,
            isWeekMode: true,
            baseFontSize: baseFontSize,
            showTimeBelowTitle: showTimeBelowTitle
        )

        // Layout text. Mirrors the SwiftUI tree's VStack(spacing:
        // titleSpacing) { Text(title)+Text(time) } inside the resolved
        // content rect (verticalCenter sets the y-anchor).
        let titleFontSize = baseFontSize
        let timeFontSize = calendarEventTimeFontSize(forTitleFontSize: titleFontSize, isWeekMode: true)
        let titleSpacing = calendarEventBlockTitleSpacing(isWeekMode: true, isThreeDayMode: false)
        let titleFont = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium)

        if let layout = textLayout {
            let contentRect = layout.contentRect
            var cursorY = contentRect.minY
            let titleLineHeight = titleFont.lineHeight
            let maxTitleHeight = min(CGFloat(layout.titleLineLimit) * titleLineHeight, contentRect.height)
            let naturalTitleHeight = title.boundingRect(
                with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: titleFont],
                context: nil
            ).height
            let titleHeight = min(ceil(naturalTitleHeight / titleLineHeight) * titleLineHeight, maxTitleHeight)
            if layout.verticalCenter {
                var stackHeight = titleHeight
                if layout.showsTimeRange {
                    stackHeight += titleSpacing + timeFont.lineHeight
                }
                cursorY = contentRect.minY + max(0, (contentRect.height - stackHeight) / 2)
            }
            titleLayer.isHidden = false
            titleLayer.frame = CGRect(
                x: contentRect.minX, y: cursorY,
                width: contentRect.width, height: titleHeight
            )
            titleLayer.font = titleFont
            titleLayer.fontSize = titleFontSize
            titleLayer.foregroundColor = UIColor.label.cgColor
            titleLayer.string = title
            cursorY += titleHeight + titleSpacing

            if layout.showsTimeRange {
                let timeStr = "\(Self.timeText(displayRange.start)) – \(Self.timeText(displayRange.end))"
                timeLayer.isHidden = false
                timeLayer.frame = CGRect(
                    x: contentRect.minX, y: cursorY,
                    width: contentRect.width, height: timeFont.lineHeight
                )
                timeLayer.font = timeFont
                timeLayer.fontSize = timeFontSize
                timeLayer.foregroundColor = UIColor.secondaryLabel.cgColor
                timeLayer.isWrapped = false
                timeLayer.string = timeStr
            } else {
                timeLayer.isHidden = true
                timeLayer.string = nil
            }
        } else {
            titleLayer.isHidden = true
            titleLayer.string = nil
            timeLayer.isHidden = true
            timeLayer.string = nil
        }
    }

    /// Update the focused-block live progress overlay. Builds the SwiftUI
    /// tree's VStack { Rectangle(fill: tint@0.22, height: live%) + Spacer }
    /// as a single child CALayer of `midOverlay`.
    func applyLiveProgress(displayProgress: CGFloat, tint: UIColor) {
        midOverlay.isHidden = false
        let height = midOverlay.bounds.height * displayProgress
        let fillLayer: CALayer
        if let existing = midOverlay.sublayers?.first {
            fillLayer = existing
        } else {
            fillLayer = CALayer()
            fillLayer.actions = MiniDayTimelineLayerView.disabledActions
            midOverlay.addSublayer(fillLayer)
        }
        fillLayer.frame = CGRect(x: 0, y: 0, width: midOverlay.bounds.width, height: height)
        fillLayer.backgroundColor = tint.withAlphaComponent(0.22).cgColor
    }

    /// Matches `timelineTimeLabel` in CalendarEventDetailView.
    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Note marker (dot + hairline)

/// CALayer pair for a single timeline-note marker. Dot grows from 5→7pt
/// and the hairline darkens from 0.12→0.3 when the note is "nearby" the
/// current scrub position.
private final class NoteMarker {
    private let dot = CAShapeLayer()
    private let line = CALayer()

    private static let dotIdleSize: CGFloat = 5
    private static let dotNearbySize: CGFloat = 7

    init() {
        dot.actions = MiniDayTimelineLayerView.disabledActions
        line.actions = MiniDayTimelineLayerView.disabledActions
        dot.fillColor = UIColor.label.withAlphaComponent(0.4).cgColor
        line.backgroundColor = UIColor.label.withAlphaComponent(0.12).cgColor
    }

    func install(in parent: CALayer) {
        parent.addSublayer(dot)
        parent.addSublayer(line)
    }

    func removeFromSuperlayer() {
        dot.removeFromSuperlayer()
        line.removeFromSuperlayer()
    }

    func hide() {
        dot.isHidden = true
        line.isHidden = true
    }

    func layout(centerY: CGFloat, areaWidth: CGFloat, isNearby: Bool) {
        let size = isNearby ? NoteMarker.dotNearbySize : NoteMarker.dotIdleSize
        let yOffset: CGFloat = size / 2
        dot.isHidden = false
        dot.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
        dot.frame = CGRect(x: 0, y: centerY - yOffset, width: size, height: size)
        line.isHidden = false
        // Hairline starts past the dot's right edge, extends across the
        // remaining area width. Mirrors the SwiftUI HStack(spacing: 0).
        line.frame = CGRect(x: size, y: centerY - 0.25, width: max(0, areaWidth - size), height: 0.5)
    }

    func setNearby(_ nearby: Bool) {
        dot.fillColor = (nearby ? UIColor.label : UIColor.label.withAlphaComponent(0.4)).cgColor
        line.backgroundColor = UIColor.label.withAlphaComponent(nearby ? 0.3 : 0.12).cgColor
        // Re-bound the dot to the nearby/idle size if the layout result
        // has gone stale (cheap path — the next layoutNoteMarkers call
        // will repopulate the frame on the next apply).
        let currentBounds = dot.bounds
        let targetSize = nearby ? NoteMarker.dotNearbySize : NoteMarker.dotIdleSize
        if abs(currentBounds.width - targetSize) > 0.5 {
            let origin = dot.frame.origin
            let centerY = origin.y + currentBounds.height / 2
            let yOffset = targetSize / 2
            dot.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: targetSize, height: targetSize)).cgPath
            dot.frame = CGRect(x: origin.x, y: centerY - yOffset, width: targetSize, height: targetSize)
        }
    }
}

// Note: `CalendarLayout.EventOverlapSlot.default` is defined in
// `CalendarLayout.swift`; this file reuses it directly via the `??
// .default` fallback in `layoutSiblingBlocks` / `layoutFocusedBlock`.
