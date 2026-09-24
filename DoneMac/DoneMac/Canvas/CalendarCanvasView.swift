//
//  CalendarCanvasView.swift
//  DoneMac
//
//  The SwiftUI applier over CanvasFrame, plus gesture translation for the
//  DragController. Everything geometric is positioning of pre-computed
//  fractions; gestures reduce to (dayKey, fraction) pairs before they
//  reach the controller, so the controller stays view-free and testable.
//

import SwiftUI

struct CalendarCanvasView: View {
    let surface: CalendarSurfaceModel
    let drag: DragController
    var onNameFreshCreation: (UUID) -> Void = { _ in }
    /// The event whose inspector is open — drawn with a selection ring.
    var selectedID: UUID? = nil
    // Callbacks carry the occurrence's day: a recurring block shares its
    // series id across every occurrence, so an edit/delete needs to know
    // WHICH day was acted on.
    var onSelectBlock: (UUID, Date) -> Void = { _, _ in }
    var onToggleDone: (UUID, Date) -> Void = { _, _ in }
    var onDeleteBlock: (UUID, Date) -> Void = { _, _ in }
    /// Taller rows than the first cut so a day reads like the phone's
    /// full-height timeline, not a dense grid. Zoomable (B1) via pinch —
    /// @State so a magnify re-lays the timeline.
    @State private var hourHeight: CGFloat = 56
    /// Base height + focal fraction captured ONCE at the start of a pinch:
    /// the magnification scales from the starting height, and the focal time
    /// is held for the whole gesture so it can't creep near the top/bottom
    /// edge where the recenter clamps (B1 review F1).
    @State private var zoomBaseHeight: CGFloat?
    @State private var zoomAnchorFraction: CGFloat?
    private let axisWidth: CGFloat = 54

    static let minHourHeight: CGFloat = 28
    static let maxHourHeight: CGFloat = 160

    private var contentHeight: CGFloat { hourHeight * 24 }
    /// B4: the timeline scrolls inside an NSScrollView so B1 zoom-anchoring
    /// and B3 edge-autoscroll can command the offset. A reference type held
    /// in @State so it survives body re-evaluations.
    @State private var scrollController = TimelineScrollController()

    static func clampedHourHeight(_ h: CGFloat) -> CGFloat {
        min(max(minHourHeight, h), maxHourHeight)
    }

    /// Zoom the hour height, holding a focal TIME fixed: the host re-centers
    /// on `focalFraction` after the new height lays out (B1). A no-op at the
    /// clamp bounds (so no spurious recenter there).
    private func zoom(to newHeight: CGFloat, focalFraction: CGFloat) {
        let clamped = Self.clampedHourHeight(newHeight)
        guard clamped != hourHeight else { return }
        scrollController.pendingRecenterFraction = focalFraction
        hourHeight = clamped
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            allDayRow
            Divider()
            VerticalScrollHost(controller: scrollController,
                               contentHeight: contentHeight,
                               initialFraction: scrollAnchorFraction) {
                HStack(alignment: .top, spacing: 0) {
                    TimeAxisApplier()
                        .frame(width: axisWidth, height: contentHeight)
                    ForEach(Array(surface.frame.days.enumerated()), id: \.element.key) { index, day in
                        DayColumnView(
                            day: day,
                            nowLine: surface.frame.nowLine?.dayKey == day.key
                                ? surface.frame.nowLine : nil,
                            overlay: drag.overlay?.dayKey == day.key ? drag.overlay : nil,
                            onDragBegan: { xFraction, yFraction in
                                beginDrag(day: day, xFraction: xFraction, yFraction: yFraction)
                            },
                            onDragMoved: { fraction, dayDelta in
                                moveDrag(dayIndex: index, dayDelta: dayDelta, fraction: fraction)
                            },
                            onDragEnded: { fraction, dayDelta in
                                endDrag(dayIndex: index, dayDelta: dayDelta, fraction: fraction)
                            },
                            selectedID: selectedID,
                            onSelectBlock: onSelectBlock,
                            onToggleDone: onToggleDone,
                            onDeleteBlock: onDeleteBlock
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: contentHeight)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.separator).frame(width: 1)
                        }
                    }
                }
            }
            // Trackpad pinch zooms the hour height (phone parity). The
            // cumulative magnification scales from the height at gesture start.
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        // Ignore a pinch before the scroll view is laid out —
                        // centerFraction would read 0 and anchor the zoom to
                        // 00:00 instead of the visible time (code-review F5).
                        guard scrollController.visibleHeight > 0 else { return }
                        if zoomBaseHeight == nil {
                            zoomBaseHeight = hourHeight
                            zoomAnchorFraction = scrollController.centerFraction   // captured ONCE
                        }
                        zoom(to: (zoomBaseHeight ?? hourHeight) * value.magnification,
                             focalFraction: zoomAnchorFraction ?? scrollController.centerFraction)
                    }
                    .onEnded { _ in zoomBaseHeight = nil; zoomAnchorFraction = nil }
            )
        }
    }

    /// Where to rest the initial scroll: the now-line if today is in view,
    /// else 8am — the phone opens near the working day, not at midnight.
    private var scrollAnchorFraction: CGFloat {
        surface.frame.nowLine?.yFraction ?? (8.0 / 24.0)
    }

    // MARK: - Gesture reduction

    /// Bottom strip of a block that grabs as a resize handle: 8pt at the
    /// CURRENT hourHeight (review round-3 F13 — never a hardcoded 44).
    private var resizeGripDayFraction: CGFloat { 8.0 / (hourHeight * 24) }

    private func beginDrag(day: DayModel, xFraction: CGFloat, yFraction: CGFloat) {
        guard !drag.isDragging else { return }
        // Topmost block under the pointer wins — in BOTH axes (review F10:
        // equalSplit lays peers side by side); its bottom strip resizes.
        let hit = day.blocks
            .filter {
                yFraction >= $0.yFraction && yFraction <= $0.yFraction + $0.heightFraction
                    && xFraction >= $0.xOffsetFraction
                    && xFraction < $0.xOffsetFraction + $0.widthFraction
            }
            .max { $0.zIndex < $1.zIndex }
        guard let hit,
              let event = surface.storeForGestures.calendarEvents.first(where: { $0.id == hit.eventID }) else {
            drag.beginCreate(day: day.key, fraction: yFraction)
            return
        }
        // Series templates don't drag on Mac until scope-asking machinery
        // exists (review F4a): a template shift re-anchors every occurrence.
        guard !event.isRecurringSeries else { return }
        switch Self.gripAction(
            pointerY: yFraction, blockTop: hit.yFraction, blockHeight: hit.heightFraction,
            grip: resizeGripDayFraction,
            topIsRealStart: hit.topIsRealStart, bottomIsRealEnd: hit.bottomIsRealEnd
        ) {
        case .resizeBottom:
            drag.beginResizeBottom(event: event, grabbedRange: hit.range)
        case .resizeTop:
            drag.beginResizeTop(event: event, grabbedRange: hit.range)
        case .move:
            drag.beginMove(event: event, grabbedRange: hit.range, grabFraction: yFraction - hit.yFraction)
        }
    }

    enum GripAction: Equatable { case move, resizeTop, resizeBottom }

    /// Which drag a grab starts, as a PURE function so the edge-gating is
    /// testable. A resize handle is offered ONLY at the occurrence's REAL
    /// edge: grabbing a midnight CLIP line (a cross-midnight event's clipped
    /// head-bottom or tail-top) falls through to MOVE, never a resize that
    /// would relocate the real start/end into the wrong day and destroy the
    /// off-day portion (B2 review F1 — closes both edges). Bottom takes
    /// precedence; the top handle needs `2.5*grip` of height so the two
    /// handles never overlap a short block's move zone.
    static func gripAction(
        pointerY: CGFloat, blockTop: CGFloat, blockHeight: CGFloat, grip: CGFloat,
        topIsRealStart: Bool, bottomIsRealEnd: Bool
    ) -> GripAction {
        let bottomGrip = blockTop + blockHeight - grip
        let topGrip = blockTop + grip
        let tallEnough = blockHeight > 2.5 * grip
        if bottomIsRealEnd && pointerY >= bottomGrip { return .resizeBottom }
        if topIsRealStart && tallEnough && pointerY <= topGrip { return .resizeTop }
        return .move
    }

    private func moveDrag(dayIndex: Int, dayDelta: Int, fraction: CGFloat) {
        guard drag.isDragging else { return }
        let day = pointerDay(dayIndex: dayIndex, dayDelta: dayDelta)
        drag.updateMove(pointerDay: day, pointerFraction: fraction)
        drag.updateResizeBottom(pointerDay: day, pointerFraction: fraction)
        drag.updateResizeTop(pointerDay: day, pointerFraction: fraction)
        drag.updateCreate(pointerFraction: fraction)
    }

    private func endDrag(dayIndex: Int, dayDelta: Int, fraction: CGFloat) {
        guard drag.isDragging else { return }
        let now = Date()
        let day = pointerDay(dayIndex: dayIndex, dayDelta: dayDelta)
        drag.endMove(pointerDay: day, pointerFraction: fraction, now: now)
        drag.endResizeBottom(pointerDay: day, pointerFraction: fraction, now: now)
        drag.endResizeTop(pointerDay: day, pointerFraction: fraction, now: now)
        drag.endCreate(pointerFraction: fraction, now: now)
        // Drop feedback (Force Touch trackpads only; inert elsewhere) — ONLY
        // on a real commit, not a drop-in-place or empty-space no-create
        // (code-review F7).
        if drag.didCommitLastDrop {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if let created = drag.pendingComposerEventID {
            drag.pendingComposerEventID = nil
            onNameFreshCreation(created)
        }
    }

    private func pointerDay(dayIndex: Int, dayDelta: Int) -> DayKey {
        let keys = surface.windowKeys
        let clamped = min(max(0, dayIndex + dayDelta), keys.count - 1)
        return keys.isEmpty ? surface.anchorDay : keys[clamped]
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: axisWidth, height: 1)
            ForEach(surface.frame.days, id: \.key) { day in
                let today = isToday(day.key)
                VStack(spacing: 1) {
                    Text(weekdayName(day.key))
                        .font(.caption2)
                        .foregroundStyle(today ? Color.accentColor : .secondary)
                    Text("\(day.key.day)")
                        .font(.title3.monospacedDigit().weight(today ? .bold : .regular))
                        .foregroundStyle(today ? .white : .primary)
                        .frame(width: 30, height: 30)
                        .background {
                            if today { Circle().fill(Color.accentColor) }
                        }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    private func isToday(_ key: DayKey) -> Bool {
        surface.frame.nowLine?.dayKey == key
    }

    private func weekdayName(_ key: DayKey) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = .current
        guard let date = key.startOfDay(calendar: cal) else { return "" }
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = "EEE"
        return df.string(from: date)
    }

    @ViewBuilder
    private var allDayRow: some View {
        if surface.frame.days.contains(where: { !$0.allDayChips.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: axisWidth, height: 1)
                ForEach(surface.frame.days, id: \.key) { day in
                    VStack(spacing: 2) {
                        ForEach(day.allDayChips) { chip in
                            Text(chip.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 1)
                                .background(chip.color.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct DayColumnView: View {
    let day: DayModel
    let nowLine: NowLineModel?
    var overlay: DragController.Overlay?
    var onDragBegan: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onDragMoved: (CGFloat, Int) -> Void = { _, _ in }
    var onDragEnded: (CGFloat, Int) -> Void = { _, _ in }
    var selectedID: UUID? = nil
    var onSelectBlock: (UUID, Date) -> Void = { _, _ in }
    var onToggleDone: (UUID, Date) -> Void = { _, _ in }
    var onDeleteBlock: (UUID, Date) -> Void = { _, _ in }

    @State private var dragActive = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                hourGrid(height: size.height)
                ForEach(day.blocks) { block in
                    blockView(block)
                        .frame(
                            width: max(1, size.width * block.widthFraction - 2),
                            height: max(6, size.height * block.heightFraction - 1)
                        )
                        .offset(
                            x: size.width * block.xOffsetFraction + 1,
                            y: size.height * block.yFraction
                        )
                        .zIndex(block.eventID == selectedID ? block.zIndex + 5_000 : block.zIndex)
                        // Lifecycle motion, honestly driven by the delta layer:
                        // a genuine create grows+fades in, a delete shrinks+
                        // fades out (gh#196's hard part — telling a real
                        // lifecycle event from virtualization — is free here
                        // because DayModel identity comes from CommitDelta).
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 0.85).combined(with: .opacity)
                        ))
                        // Single click selects (opens the inspector hub).
                        // No count:2 sibling — a double-click gesture would
                        // force every single click to wait out the
                        // disambiguation window for no added behavior (QA #2).
                        .onTapGesture { onSelectBlock(block.eventID, block.range.start) }
                        .contextMenu {
                            Button("Edit") { onSelectBlock(block.eventID, block.range.start) }
                            if block.isTodo {
                                Button(block.isDone ? "Mark Active" : "Mark Done") {
                                    onToggleDone(block.eventID, block.range.start)
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                onDeleteBlock(block.eventID, block.range.start)
                            }
                        }
                }
                if let overlay {
                    overlayView(overlay)
                        .frame(
                            width: max(1, size.width - 4),
                            height: max(6, size.height * overlay.heightFraction)
                        )
                        .offset(x: 2, y: size.height * overlay.yFraction)
                        // The pickup lift: a dragged block rides slightly
                        // larger with a shadow, like the phone's scaleEffect
                        // + shadow(3).
                        .scaleEffect(1.03)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .zIndex(10_000)
                        .transition(.opacity)
                }
                if let nowLine {
                    // A dot + hairline, like the phone's now indicator.
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.red).frame(height: 1.5)
                        Circle().fill(.red).frame(width: 7, height: 7).offset(x: -1)
                    }
                    .offset(y: size.height * nowLine.yFraction - 3)
                    .allowsHitTesting(false)
                }
            }
            // Blocks settle between positions/sizes with a spring, and
            // insert/remove run their transitions — the phone's drop-settle
            // and lifecycle feel, keyed on the value-equatable day model.
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: day.blocks)
            // Key on PRESENCE, not the value: animate only the overlay's
            // insert/remove fade at drag begin/end. Keying on `overlay` eased
            // the per-frame offset too, so the pickup lagged the cursor by
            // ~0.16s (code-review F3); the drag must track 1:1.
            .animation(.easeOut(duration: 0.16), value: overlay == nil)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        let fraction = fractionOf(value.location.y, height: size.height)
                        if !dragActive {
                            dragActive = true
                            onDragBegan(
                                size.width > 0 ? clamp(value.startLocation.x / size.width, 0, 1) : 0,
                                fractionOf(value.startLocation.y, height: size.height)
                            )
                        }
                        onDragMoved(fraction, dayDelta(value.location.x, width: size.width))
                    }
                    .onEnded { value in
                        dragActive = false
                        onDragEnded(
                            fractionOf(value.location.y, height: size.height),
                            dayDelta(value.location.x, width: size.width)
                        )
                    }
            )
        }
        .clipped()
    }

    private func fractionOf(_ y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return clamp(y / height, 0, 1)
    }

    private func dayDelta(_ x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int(floor(x / width))
    }

    private func hourGrid(height: CGFloat) -> some View {
        ForEach(1..<24, id: \.self) { hour in
            Rectangle()
                .fill(.separator.opacity(0.5))
                .frame(height: 1)
                .offset(y: height * CGFloat(hour) / 24)
        }
    }

    private func overlayView(_ overlay: DragController.Overlay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(overlay.title.isEmpty ? "New event" : overlay.title)
                .font(.caption2.bold())
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.blue, style: StrokeStyle(lineWidth: 1, dash: overlay.isCreate ? [4] : []))
        )
        .allowsHitTesting(false)
    }

    private func blockView(_ block: DayBlockModel) -> some View {
        // Phone-like: a full soft tint (subtle top-down gradient) with a
        // colored border and title over a time range — no accent bar, to
        // match the iPhone's filled blocks. Todos keep the heavier 1pt
        // border they carry on the phone.
        let tall = block.heightFraction > 0.028
        let selected = block.eventID == selectedID
        return VStack(alignment: .leading, spacing: 1) {
            Text(block.title.isEmpty ? "Untitled" : block.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .strikethrough(block.isDone, color: .secondary)
                .lineLimit(tall ? 2 : 1)
            if tall {
                Text(block.timeText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [block.color.opacity(0.32), block.color.opacity(0.20)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(block.color.opacity(0.7),
                              lineWidth: block.isTodo ? 1.5 : 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        // A completed todo fades — the phone's deferred done-fade. Applied
        // BEFORE the ring so a selected done todo still shows a full-strength
        // selection ring, not a 55%-dimmed one (review #4).
        .opacity(block.isDone ? 0.55 : 1)
        // The selection ring: a crisp accent frame at full opacity.
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
        )
    }
}
