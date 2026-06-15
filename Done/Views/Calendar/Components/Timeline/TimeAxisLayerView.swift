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

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Sublayer geometry is driven by `apply(...)` based on inputs, not
        // by `layoutSubviews` — but a bounds change still needs a refresh
        // because the band-fade mask + axis marker frames depend on width.
        // Future commits will hook layout here.
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
        inputs = next
        // Subsequent commits add: hour-label rebuild, now-legend refresh,
        // axis marker refresh, band-fade mask refresh.
    }
}
