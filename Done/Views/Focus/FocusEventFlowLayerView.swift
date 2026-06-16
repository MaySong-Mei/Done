//
//  FocusEventFlowLayerView.swift
//  Done
//
//  CALayer-backed port of the SwiftUI `FocusEventFlowView` mini-timeline
//  rendered in landscape focus mode (issue #72). Strict-parity port —
//  no design changes, gated by `AppSettingsKeys.calendarUseCALayerFocusEventFlow`,
//  default OFF; flipped ON only after A/B parity is verified (mirrors the
//  #60→#74 and #71 arcs).
//
//  Reuses the same module-scope helpers as the SwiftUI tree:
//  `CalendarLayout.overlapLayout` (pinned to `.equalSplit`),
//  `CalendarLayout.eventColor`,
//  `calendarInterruptParentCompoundGeometry`,
//  `CalendarInterruptParentCompoundShape`,
//  `calendarInterruptChildOverlayGeometry`.
//
//  Scope: STATIC preview surface — no pinch, no scroll, no gesture. The
//  parent `FocusModeView` already drives a 1Hz `now` re-evaluation; the
//  host re-applies inputs each tick and the renderer relayouts without
//  rebuilding structure when the occurrence set is unchanged.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI host

/// SwiftUI-side host for the CALayer focus-event-flow timeline. Drop-in
/// replacement for the SwiftUI `FocusEventFlowView` body — same inputs
/// (`now`, `allOccurrences`) since `currentEvent`/`currentRange` were
/// declared on the SwiftUI struct but never consumed by its body.
struct FocusEventFlowLayerHost: UIViewRepresentable {
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]

    func makeUIView(context: Context) -> FocusEventFlowLayerView {
        let view = FocusEventFlowLayerView()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: FocusEventFlowLayerView, context: Context) {
        uiView.apply(now: now, allOccurrences: allOccurrences)
    }
}

// MARK: - UIView host (CALayer backing)

/// CALayer-backed focus-event-flow mini timeline. Owns three z-ordered
/// container tiers so SwiftUI's two-pass z-order (blocks below, titles
/// above) is preserved without a re-layout per tick:
///
///   1. grid lines (CAShapeLayer)        — pass 0, bottom
///   2. hour labels (UILabel children)   — pass 0
///   3. event-block silhouettes          — pass 1
///   4. event titles (UILabel children)  — pass 2
///   5. now indicator (line + dot)       — top
final class FocusEventFlowLayerView: UIView {
    // Coordinate-system constants — mirror FocusEventFlowView's literals.
    private static let labelWidth: CGFloat = 42
    private static let eventInset: CGFloat = 8
    private static let visibleHours: CGFloat = 6
    private static let blockCornerRadius: CGFloat = 6
    private static let childBlockCornerRadius: CGFloat = 5

    private let calendar = Calendar.current

    private var currentNow: Date?
    private var currentOccurrences: [CalendarLayout.EventOccurrence] = []
    private var overlapSlots: [String: CalendarLayout.EventOverlapSlot] = [:]
    private var parentLookup: [UUID: CalendarLayout.EventOccurrence] = [:]
    private var childrenLookup: [UUID: [CalendarLayout.EventOccurrence]] = [:]
    private var embeddedIDs: Set<String> = []

    // Per-block CALayer subtree.
    private struct BlockNode {
        let bg: CAShapeLayer
        let border: CAShapeLayer
    }

    // Sublayer/subview containers — preserve z-order even when contents change.
    private let gridLineContainer = CALayer()
    private let hourLabelContainer = UIView()
    private let blockContainer = CALayer()
    private let titleContainer = UIView()
    private let nowIndicatorContainer = CALayer()

    private var gridLines: [CAShapeLayer] = []
    private var hourLabels: [UILabel] = []
    private let currentTimeLabel = UILabel()

    private var siblingBlocks: [String: BlockNode] = [:]
    private var childBlocks: [String: BlockNode] = [:]
    private var titleLabels: [String: UILabel] = [:]

    private let nowDot = CAShapeLayer()
    private let nowLine = CAShapeLayer()

    private static let disabledActions: [String: CAAction] = [
        "contents": NSNull(),
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "opacity": NSNull(),
        "transform": NSNull(),
        "sublayers": NSNull(),
        "hidden": NSNull(),
        "path": NSNull(),
        "fillColor": NSNull(),
        "strokeColor": NSNull()
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.actions = Self.disabledActions

        for container in [gridLineContainer, blockContainer, nowIndicatorContainer] {
            container.actions = Self.disabledActions
        }

        // Z-order: gridLineContainer (bottom) → hourLabelContainer → blockContainer
        // → titleContainer → nowIndicatorContainer (top). Add in that order so
        // both addSublayer and addSubview append to layer.sublayers correctly.
        layer.addSublayer(gridLineContainer)
        hourLabelContainer.isUserInteractionEnabled = false
        hourLabelContainer.backgroundColor = .clear
        hourLabelContainer.layer.actions = Self.disabledActions
        addSubview(hourLabelContainer)
        layer.addSublayer(blockContainer)
        titleContainer.isUserInteractionEnabled = false
        titleContainer.backgroundColor = .clear
        titleContainer.layer.actions = Self.disabledActions
        addSubview(titleContainer)
        layer.addSublayer(nowIndicatorContainer)

        // Now indicator: line + 8pt dot. Static structure; positions update
        // per layout pass.
        nowLine.actions = Self.disabledActions
        nowDot.actions = Self.disabledActions
        nowLine.fillColor = UIColor.label.cgColor
        nowDot.fillColor = UIColor.label.cgColor
        nowIndicatorContainer.addSublayer(nowLine)
        nowIndicatorContainer.addSublayer(nowDot)

        // Current-time label sits next to the dot; uses monospaced digits to
        // avoid width jitter per tick.
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        currentTimeLabel.textColor = .label
        currentTimeLabel.isUserInteractionEnabled = false
        addSubview(currentTimeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContent()
    }

    // MARK: - Apply

    /// Apply latest inputs from the SwiftUI host. The structure (sublayer
    /// pools) is rebuilt only when the occurrence set changes; the per-tick
    /// `now` advance only triggers a relayout.
    func apply(now: Date, allOccurrences: [CalendarLayout.EventOccurrence]) {
        let occurrencesChanged = currentOccurrences != allOccurrences
        currentNow = now
        if occurrencesChanged {
            currentOccurrences = allOccurrences
            recomputeLookups()
            rebuildStructure()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - Lookups (mirrors FocusEventFlowView body)

    private func recomputeLookups() {
        var parents: [UUID: CalendarLayout.EventOccurrence] = [:]
        for occ in currentOccurrences where !occ.event.isInterrupt {
            parents[occ.event.recurrenceParentId ?? occ.event.id] = occ
        }
        parentLookup = parents

        var children: [UUID: [CalendarLayout.EventOccurrence]] = [:]
        for occ in currentOccurrences {
            guard let relation = occ.event.interruptRelation,
                  relation.state == .embedded else { continue }
            children[relation.parentEventID, default: []].append(occ)
        }
        childrenLookup = children

        var embedded: Set<String> = []
        for occ in currentOccurrences {
            guard occ.event.isInterrupt,
                  let relation = occ.event.interruptRelation,
                  relation.state == .embedded,
                  parents[relation.parentEventID] != nil else { continue }
            embedded.insert(occ.id)
        }
        embeddedIDs = embedded

        // Overlap layout reads only widthFraction/xOffsetFraction (see
        // OverlapMode.equalSplit contract) so coverRanges is empty here.
        let overlapCandidates = currentOccurrences.filter { !embedded.contains($0.id) }
        let referenceDate = currentNow ?? Date()
        overlapSlots = CalendarLayout.overlapLayout(
            for: overlapCandidates,
            on: referenceDate,
            calendar: calendar,
            mode: .equalSplit
        )
    }

    // MARK: - Structure rebuild

    private func rebuildStructure() {
        rebuildBlockNodes()
        rebuildTitleLabels()
    }

    /// Sync `siblingBlocks` + `childBlocks` pools with the current occurrences.
    /// One BlockNode (bg + border CAShapeLayers) per visible non-embedded
    /// occurrence; one per embedded interrupt child.
    private func rebuildBlockNodes() {
        var keptSibling: Set<String> = []
        var keptChild: Set<String> = []

        for occ in currentOccurrences {
            if embeddedIDs.contains(occ.id) {
                keptChild.insert(occ.id)
                if childBlocks[occ.id] == nil {
                    childBlocks[occ.id] = installBlockNode()
                }
            } else {
                keptSibling.insert(occ.id)
                if siblingBlocks[occ.id] == nil {
                    siblingBlocks[occ.id] = installBlockNode()
                }
            }
        }

        // Remove stale entries.
        for key in siblingBlocks.keys where !keptSibling.contains(key) {
            if let node = siblingBlocks.removeValue(forKey: key) {
                node.bg.removeFromSuperlayer()
                node.border.removeFromSuperlayer()
            }
        }
        for key in childBlocks.keys where !keptChild.contains(key) {
            if let node = childBlocks.removeValue(forKey: key) {
                node.bg.removeFromSuperlayer()
                node.border.removeFromSuperlayer()
            }
        }
    }

    private func installBlockNode() -> BlockNode {
        let bg = CAShapeLayer()
        bg.actions = Self.disabledActions
        bg.lineWidth = 0
        let border = CAShapeLayer()
        border.actions = Self.disabledActions
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = 1.2
        blockContainer.addSublayer(bg)
        blockContainer.addSublayer(border)
        return BlockNode(bg: bg, border: border)
    }

    private func rebuildTitleLabels() {
        var kept: Set<String> = []
        for occ in currentOccurrences {
            kept.insert(occ.id)
            if titleLabels[occ.id] == nil {
                let label = UILabel()
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .label
                label.numberOfLines = 2
                label.lineBreakMode = .byTruncatingTail
                label.isUserInteractionEnabled = false
                titleContainer.addSubview(label)
                titleLabels[occ.id] = label
            }
            titleLabels[occ.id]?.text = occ.event.title
        }
        for key in titleLabels.keys where !kept.contains(key) {
            titleLabels.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    // MARK: - Layout

    private func layoutContent() {
        guard let now = currentNow else { return }
        let h = bounds.height
        let w = bounds.width
        guard h > 0, w > 0 else { return }

        let nowY = h * 0.5
        let pps = h / (Self.visibleHours * 3600)
        let windowStart = now.addingTimeInterval(-Double(Self.visibleHours) * 3600 * 0.5)
        let windowEnd = now.addingTimeInterval(Double(Self.visibleHours) * 3600 * 0.5)
        let eventLeft = Self.labelWidth
        let eventW = w - eventLeft
        let areaW = eventW - Self.eventInset * 2

        // Containers stretch full bounds; their children are absolute-positioned.
        for container in [gridLineContainer, blockContainer, nowIndicatorContainer] {
            container.frame = bounds
        }
        hourLabelContainer.frame = bounds
        titleContainer.frame = bounds

        layoutGrid(
            now: now,
            nowY: nowY,
            pps: pps,
            windowStart: windowStart,
            windowEnd: windowEnd,
            eventLeft: eventLeft,
            areaW: areaW
        )

        layoutBlocks(
            now: now,
            nowY: nowY,
            pps: pps,
            eventLeft: eventLeft,
            areaW: areaW,
            viewportHeight: h
        )

        layoutTitles(
            now: now,
            nowY: nowY,
            pps: pps,
            eventLeft: eventLeft,
            areaW: areaW,
            viewportHeight: h
        )

        layoutNowIndicator(
            nowY: nowY,
            eventLeft: eventLeft,
            eventW: eventW,
            now: now
        )
    }

    private func layoutGrid(
        now: Date,
        nowY: CGFloat,
        pps: CGFloat,
        windowStart: Date,
        windowEnd: Date,
        eventLeft: CGFloat,
        areaW: CGFloat
    ) {
        let hours = hourMarkers(from: windowStart, to: windowEnd)
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let lineX = eventLeft + Self.eventInset

        // Grow / shrink grid-line layer pool.
        while gridLines.count < hours.count {
            let line = CAShapeLayer()
            line.actions = Self.disabledActions
            line.fillColor = UIColor.secondaryLabel.withAlphaComponent(0.2).cgColor
            line.lineWidth = 0
            gridLineContainer.addSublayer(line)
            gridLines.append(line)
        }
        while gridLines.count > hours.count {
            gridLines.removeLast().removeFromSuperlayer()
        }

        // Hour label pool — sized to match hours.count so we don't churn
        // UILabel allocations per tick.
        while hourLabels.count < hours.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabel
            label.isUserInteractionEnabled = false
            hourLabelContainer.addSubview(label)
            hourLabels.append(label)
        }
        while hourLabels.count > hours.count {
            hourLabels.removeLast().removeFromSuperview()
        }

        for (idx, hour) in hours.enumerated() {
            let y = nowY + CGFloat(hour.timeIntervalSince(now)) * pps
            let lineRect = CGRect(x: lineX, y: y, width: areaW, height: 1)
            gridLines[idx].path = UIBezierPath(rect: lineRect).cgPath

            let hourMinutes = calendar.component(.hour, from: hour) * 60
            let label = hourLabels[idx]
            if abs(hourMinutes - nowMinutes) > 15 {
                label.isHidden = false
                label.text = formatHour12(hour)
                label.sizeToFit()
                var f = label.frame
                f.origin = CGPoint(x: 4, y: y - 7)
                label.frame = f
            } else {
                label.isHidden = true
            }
        }

        // Current-time label always shown, at nowY.
        currentTimeLabel.text = formatCurrentTime(now)
        currentTimeLabel.sizeToFit()
        var ctf = currentTimeLabel.frame
        ctf.origin = CGPoint(x: 4, y: nowY - 7)
        currentTimeLabel.frame = ctf
    }

    private func layoutBlocks(
        now: Date,
        nowY: CGFloat,
        pps: CGFloat,
        eventLeft: CGFloat,
        areaW: CGFloat,
        viewportHeight h: CGFloat
    ) {
        for occ in currentOccurrences where !embeddedIDs.contains(occ.id) {
            guard let node = siblingBlocks[occ.id] else { continue }
            let color = CalendarLayout.eventColor(for: occ.event)
            let slot = overlapSlots[occ.id] ?? .default
            let blockTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
            let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
            let blockBottom = blockTop + blockH
            let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
            let blockW = max(0, areaW * slot.widthFraction - overlapGap)
            let blockX = eventLeft + Self.eventInset + areaW * slot.xOffsetFraction
            let drawnH = max(0, blockH - 3)
            let drawnY = blockTop + 1.5

            let onScreen = blockBottom > -20 && blockTop < h + 20
            node.bg.isHidden = !onScreen
            node.border.isHidden = !onScreen
            if !onScreen { continue }

            let anchorID = occ.event.recurrenceParentId ?? occ.event.id
            let childRanges = (childrenLookup[anchorID] ?? []).map(\.range)
            let frame = CGRect(x: blockX, y: drawnY, width: blockW, height: drawnH)
            node.bg.frame = frame
            node.border.frame = frame
            let localBounds = CGRect(origin: .zero, size: frame.size)

            let path: CGPath
            if !childRanges.isEmpty {
                let compoundGeo = calendarInterruptParentCompoundGeometry(
                    parentRange: occ.range,
                    childRanges: childRanges,
                    parentWidth: blockW,
                    parentHeight: drawnH,
                    horizontalGap: 3,
                    verticalGap: 3
                )
                let compoundShape = CalendarInterruptParentCompoundShape(
                    cornerRadius: Self.blockCornerRadius,
                    visibleSegments: compoundGeo.visibleSegments
                )
                path = compoundShape.path(in: localBounds).cgPath
            } else {
                path = UIBezierPath(
                    roundedRect: localBounds,
                    cornerRadius: Self.blockCornerRadius
                ).cgPath
            }

            node.bg.path = path
            node.bg.fillColor = composite(tint: color, alpha: 0.4, over: .systemBackground).cgColor
            node.border.path = path
            node.border.strokeColor = UIColor(color).withAlphaComponent(0.7).cgColor
        }

        // Embedded interrupt children — rounded-rect overlays inside their parent.
        for occ in currentOccurrences where embeddedIDs.contains(occ.id) {
            guard let node = childBlocks[occ.id],
                  let parentID = occ.event.interruptRelation?.parentEventID,
                  let parentOcc = parentLookup[parentID] else {
                continue
            }
            let parentSlot = overlapSlots[parentOcc.id] ?? .default
            let parentOverlapGap: CGFloat = parentSlot.widthFraction < 1 ? 2 : 0
            let parentW = max(0, areaW * parentSlot.widthFraction - parentOverlapGap)
            let parentX = eventLeft + Self.eventInset + areaW * parentSlot.xOffsetFraction
            let childGeo = calendarInterruptChildOverlayGeometry(parentWidth: parentW)
            let childTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
            let childH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
            let drawnH = max(0, childH - 3)
            let drawnY = childTop + 1.5
            let childX = parentX + childGeo.xOffset
            let childW = max(0, childGeo.width)
            let frame = CGRect(x: childX, y: drawnY, width: childW, height: drawnH)
            node.bg.frame = frame
            node.border.frame = frame
            let local = CGRect(origin: .zero, size: frame.size)
            let path = UIBezierPath(
                roundedRect: local,
                cornerRadius: Self.childBlockCornerRadius
            ).cgPath
            let childColor = CalendarLayout.eventColor(for: occ.event)
            node.bg.path = path
            node.bg.fillColor = composite(tint: childColor, alpha: 0.4, over: .systemBackground).cgColor
            node.border.path = path
            node.border.strokeColor = UIColor(childColor).withAlphaComponent(0.7).cgColor
        }
    }

    private func layoutTitles(
        now: Date,
        nowY: CGFloat,
        pps: CGFloat,
        eventLeft: CGFloat,
        areaW: CGFloat,
        viewportHeight h: CGFloat
    ) {
        for occ in currentOccurrences {
            guard let label = titleLabels[occ.id] else { continue }
            let slot = overlapSlots[occ.id] ?? .default
            let blockTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
            let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
            let blockBottom = blockTop + blockH
            let blockX = eventLeft + Self.eventInset + areaW * slot.xOffsetFraction

            guard blockH >= 16, blockBottom > 0, blockTop < h else {
                label.isHidden = true
                continue
            }

            let titleX: CGFloat
            let titleY: CGFloat
            let titleMaxW: CGFloat

            if embeddedIDs.contains(occ.id) {
                // Embedded interrupt child — title aligns with the child overlay.
                let parentID = occ.event.interruptRelation?.parentEventID
                guard let parentOcc = parentID.flatMap({ parentLookup[$0] }) else {
                    label.isHidden = true
                    continue
                }
                let parentSlot = overlapSlots[parentOcc.id] ?? .default
                let parentOverlapGap: CGFloat = parentSlot.widthFraction < 1 ? 2 : 0
                let parentW = max(0, areaW * parentSlot.widthFraction - parentOverlapGap)
                let parentX = eventLeft + Self.eventInset + areaW * parentSlot.xOffsetFraction
                let childGeo = calendarInterruptChildOverlayGeometry(parentWidth: parentW)
                let childX = parentX + childGeo.xOffset
                let stickyTop = max(8, -blockTop + 8)
                let childTitleY = blockTop + 1.5 + stickyTop
                if childTitleY < blockBottom - 20, childTitleY < h - 10 {
                    titleX = childX + 8
                    titleY = childTitleY
                    titleMaxW = max(0, max(0, childGeo.width) - 16)
                } else {
                    label.isHidden = true
                    continue
                }
            } else {
                let anchorID = occ.event.recurrenceParentId ?? occ.event.id
                let children = childrenLookup[anchorID] ?? []
                let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                let blockW = max(0, areaW * slot.widthFraction - overlapGap)

                if !children.isEmpty {
                    // Parent with children — title sits below the last child.
                    let lastChildBottom = children.map { child in
                        nowY + CGFloat(child.range.end.timeIntervalSince(now)) * pps
                    }.max() ?? blockTop
                    let candidate = max(lastChildBottom + 10, max(8, blockTop + 1.5 + 8))
                    guard candidate < blockBottom - 20, candidate < h - 10 else {
                        label.isHidden = true
                        continue
                    }
                    titleX = blockX + 8
                    titleY = candidate
                    titleMaxW = max(0, blockW - 16)
                } else {
                    let stickyTop = max(8, -blockTop + 8)
                    titleX = blockX + 8
                    titleY = blockTop + 1.5 + stickyTop
                    titleMaxW = max(0, blockW - 16)
                }
            }

            label.isHidden = false
            let measured = label.sizeThatFits(CGSize(width: titleMaxW, height: .greatestFiniteMagnitude))
            let titleH = min(measured.height, label.font.lineHeight * 2 + 2)
            label.frame = CGRect(x: titleX, y: titleY, width: titleMaxW, height: titleH)
        }
    }

    private func layoutNowIndicator(
        nowY: CGFloat,
        eventLeft: CGFloat,
        eventW: CGFloat,
        now: Date
    ) {
        let dotRect = CGRect(
            x: eventLeft + Self.eventInset - 4,
            y: nowY - 4,
            width: 8,
            height: 8
        )
        nowDot.path = UIBezierPath(ovalIn: dotRect).cgPath
        let lineRect = CGRect(
            x: eventLeft + Self.eventInset,
            y: nowY - 0.75,
            width: max(0, eventW - Self.eventInset),
            height: 1.5
        )
        nowLine.path = UIBezierPath(rect: lineRect).cgPath
    }

    // MARK: - Helpers (mirror FocusEventFlowView)

    private func hourMarkers(from start: Date, to end: Date) -> [Date] {
        var markers: [Date] = []
        var hour = calendar.nextDate(
            after: start.addingTimeInterval(-3600),
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .strict,
            direction: .forward
        ) ?? start
        while hour <= end {
            markers.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return markers
    }

    private func formatHour12(_ date: Date) -> String {
        let hour24 = calendar.component(.hour, from: date)
        let meridiem = hour24 < 12 ? "am" : "pm"
        let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
        return "\(hour12) \(meridiem)"
    }

    private static let currentTimeFormatter24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    private static let currentTimeFormatter12: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private func formatCurrentTime(_ date: Date) -> String {
        let formatter = AppTimeFormat.current.is24
            ? Self.currentTimeFormatter24
            : Self.currentTimeFormatter12
        return formatter.string(from: date)
    }

    /// Mirrors SwiftUI's `Rectangle().fill(systemBackground).overlay(color.opacity(0.4))`:
    /// alpha-composite `tint` at `alpha` over the opaque `base` so the layer can
    /// fill with a single solid color.
    private func composite(tint: Color, alpha: CGFloat, over base: UIColor) -> UIColor {
        let tintUI = UIColor(tint)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        tintUI.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let a = alpha * ta
        return UIColor(
            red: tr * a + br * (1 - a),
            green: tg * a + bg * (1 - a),
            blue: tb * a + bb * (1 - a),
            alpha: 1
        )
    }
}
