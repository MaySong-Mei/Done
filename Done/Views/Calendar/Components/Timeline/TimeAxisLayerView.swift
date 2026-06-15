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

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Disable implicit animations on sublayers — we never want a
        // CALayer fade when the axis rebuilds, parity with the SwiftUI
        // tree (which only animates via explicit `.transition(.opacity)`
        // at the call site, driven by the `.id(effectiveSlotMinutes)`
        // crossfade — and that wraps THIS view, not its internals).
        layer.actions = TimeAxisLayerView.disabledActions
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

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
        // Width-dependent layout (hour-label trailing edge) is handled in
        // `layoutHourLabels`; trigger it now in case `apply(...)` was
        // called before the bounds resolved.
        if let inputs { layoutHourLabels(inputs: inputs) }
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
        inputs = next
        if structuralChanged {
            rebuildHourLabels(inputs: next)
        }
        layoutHourLabels(inputs: next)
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
        var wantedSlots: [Int] = []
        wantedSlots.reserveCapacity(slotCount)
        for index in 0..<slotCount {
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
            addSubview(label)
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
}
