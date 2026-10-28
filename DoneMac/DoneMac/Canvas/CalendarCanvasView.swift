//
//  CalendarCanvasView.swift
//  DoneMac
//
//  The SwiftUI applier over CanvasFrame, plus gesture translation for the
//  DragController. Everything geometric is positioning of pre-computed
//  fractions; gestures reduce to (dayKey, fraction) pairs before they
//  reach the controller, so the controller stays view-free and testable.
//

import AppKit
import SwiftUI

struct CalendarCanvasView: View {
    let surface: CalendarSurfaceModel
    let drag: DragController
    /// The event whose inspector is open — drawn with a selection ring.
    var selectedID: UUID? = nil
    // Callbacks carry the occurrence's day: a recurring block shares its
    // series id across every occurrence, so an edit/delete needs to know
    // WHICH day was acted on.
    var onSelectBlock: (UUID, Date) -> Void = { _, _ in }
    /// A block context-menu action that opens the inspector somewhere specific.
    var onOpenBlock: (UUID, Date, EventInspectorModel.Intent) -> Void = { _, _, _ in }
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
    @AppStorage(AppSettingsKeys.calendarEventFontSize) private var calendarEventFontSize: Double = Double(calendarEventTitleFontSizeDefault)
    @AppStorage(AppSettingsKeys.calendarEventShowTimeBelowTitle) private var showTimeBelowTitle: Bool = true
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var multiTypeEnabled = false
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormat: String = AppTimeFormat.twentyFour.rawValue
    @Environment(\.colorScheme) private var colorScheme
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

    /// The iPhone's `systemBackground`: black in dark mode, white in light.
    /// The block fill is composited over it, so the canvas and the blocks
    /// must agree on it.
    static func systemBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            allDayRow
            Divider()
            VerticalScrollHost(controller: scrollController,
                               contentHeight: contentHeight,
                               initialFraction: scrollAnchorFraction) {
                // The phone's live drag-to-create layout, for the draft's day.
                let creationReflow = drag.overlay.flatMap { overlay in
                    overlay.isCreate ? surface.creationReflow(for: overlay.dayKey, draft: overlay.range) : nil
                }
                HStack(alignment: .top, spacing: 0) {
                    TimeAxisApplier(is24: (AppTimeFormat(rawValue: timeFormat) ?? .twentyFour).is24)
                        .frame(width: axisWidth, height: contentHeight)
                    ForEach(Array(surface.frame.days.enumerated()), id: \.element.key) { index, day in
                        DayColumnView(
                            day: day,
                            nowLine: surface.frame.nowLine?.dayKey == day.key
                                ? surface.frame.nowLine : nil,
                            overlay: drag.overlay?.dayKey == day.key ? drag.overlay : nil,
                            creationReflow: drag.overlay?.dayKey == day.key ? creationReflow : nil,
                            onDragBegan: { hitID, yFraction in
                                beginDrag(day: day, hitID: hitID, yFraction: yFraction)
                            },
                            onDragMoved: { fraction, dayDelta in
                                moveDrag(dayIndex: index, dayDelta: dayDelta, fraction: fraction)
                            },
                            onDragEnded: { fraction, dayDelta in
                                endDrag(dayIndex: index, dayDelta: dayDelta, fraction: fraction)
                            },
                            selectedID: selectedID,
                            onSelectBlock: onSelectBlock,
                            onOpenBlock: onOpenBlock,
                            onToggleDone: onToggleDone,
                            onDeleteBlock: onDeleteBlock,
                            titleFontSize: CGFloat(min(max(calendarEventFontSize, 9), 16)),
                            isWeekMode: surface.frame.days.count >= 7,
                            isThreeDayMode: surface.frame.days.count == 3,
                            showTimeBelowTitle: showTimeBelowTitle,
                            is24HourTime: (AppTimeFormat(rawValue: timeFormat) ?? .twentyFour).is24,
                            multiTypeEnabled: multiTypeEnabled
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
        .background(Self.systemBackground(colorScheme))
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

    private func beginDrag(day: DayModel, hitID: String?, yFraction: CGFloat) {
        guard !drag.isDragging else { return }
        // The column resolved the topmost block under the pointer against the
        // DRAWN frames (DayColumnView.hitBlock); its bottom strip resizes.
        let hit = day.blocks.first { $0.id == hitID }
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
    /// While a create draft is on this day: its column, and the blocks
    /// re-seated around it.
    var creationReflow: CreationReflow?
    /// The block under the drag's start (nil = empty canvas) and its y.
    var onDragBegan: (String?, CGFloat) -> Void = { _, _ in }
    var onDragMoved: (CGFloat, Int) -> Void = { _, _ in }
    var onDragEnded: (CGFloat, Int) -> Void = { _, _ in }
    var selectedID: UUID? = nil
    var onSelectBlock: (UUID, Date) -> Void = { _, _ in }
    /// A block context-menu action that opens the inspector somewhere specific.
    var onOpenBlock: (UUID, Date, EventInspectorModel.Intent) -> Void = { _, _, _ in }
    var onToggleDone: (UUID, Date) -> Void = { _, _ in }
    var onDeleteBlock: (UUID, Date) -> Void = { _, _ in }
    /// The phone's title size setting (Settings → event font size) and its
    /// week-mode font and effort-bar ratios.
    var titleFontSize: CGFloat = calendarEventTitleFontSizeDefault
    var isWeekMode = false
    var isThreeDayMode = false
    /// The phone's synced "show time below title" toggle and 12h/24h clock.
    var showTimeBelowTitle = true
    var is24HourTime = true
    /// The phone's experimental multi-type setting (corner triangle + subtitle).
    var multiTypeEnabled = false

    @State private var dragActive = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let blocks = creationReflow?.apply(to: day.blocks) ?? day.blocks
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                hourGrid(height: size.height)
                ForEach(blocks) { block in
                    let rect = Self.blockRect(block, in: size)
                    blockView(block, size: rect.size)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
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
                            // The phone's long-press menu: View Details / Log
                            // (a todo has no Reflection page, as on the phone).
                            Button("View Details") { onOpenBlock(block.eventID, block.range.start, .details) }
                            if !block.isTodo {
                                Button(L(.logEvent)) { onOpenBlock(block.eventID, block.range.start, .log) }
                            }
                            Button(L(.addNote)) { onOpenBlock(block.eventID, block.range.start, .addNote) }
                            Button(L(.toolShare)) { onOpenBlock(block.eventID, block.range.start, .share) }
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
                if let overlay, overlay.isCreate {
                    creationPreview(overlay, size: size)
                        .zIndex(10_000)
                        .transition(.opacity)
                } else if let overlay {
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
            // The same spring carries the blocks stepping aside for a
            // create draft and back when it goes.
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: blocks)
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
                                Self.hitBlock(blocks, at: value.startLocation, in: size)?.id,
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
                // The phone's grid: secondary label at 0.15.
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
                .offset(y: height * CGFloat(hour) / 24)
        }
    }

    /// The phone's drag-to-create draft (CalendarDayLayerView
    /// .renderCreationPreview): the now-line color at 0.15 fill under a 0.6
    /// centered stroke, a normal block's continuous corners, in the
    /// column the overlap pass gave it, with the block's title and time row.
    /// It also stays up as the form-open ghost while the create form is open.
    private func creationPreview(_ overlay: DragController.Overlay, size: CGSize) -> some View {
        let slot = creationReflow?.draftSlot ?? .default
        let x = size.width * slot.xOffsetFraction + 1
        let width = max(1, size.width * slot.widthFraction - 2)
        let height = max(0, size.height * overlay.heightFraction)
        let color = colorScheme == .dark ? Color.white : Color(white: 0.22)
        let shape = RoundedRectangle(
            cornerRadius: calendarEventBlockCornerRadius(isInterrupt: false, isWeekMode: isWeekMode),
            style: .continuous)
        let insets = calendarEventBlockInsets(isWeekMode: isWeekMode, isThreeDayMode: isThreeDayMode)
        let spacing = calendarEventBlockTitleSpacing(isWeekMode: isWeekMode, isThreeDayMode: isThreeDayMode)
        let timeFontSize = calendarEventTimeFontSize(forTitleFontSize: titleFontSize, isWeekMode: isWeekMode)
        let titleLineHeight = MacBlockTextLayout.lineHeight(NSFont.systemFont(ofSize: titleFontSize, weight: .semibold))
        let timeLineHeight = MacBlockTextLayout.lineHeight(
            NSFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium))
        // The phone's gates: a title once the draft is ~a title line tall,
        // the time row once a full block's title + time fit.
        let showsTitle = height >= (insets.vertical * 2 + titleLineHeight) * 0.85
        let showsTime = showsTitle
            && height >= insets.vertical * 2 + titleLineHeight + spacing + timeLineHeight
        let timeText = (is24HourTime ? creationReflow?.draftTimeText24 : creationReflow?.draftTimeText12) ?? ""
        return ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(0.15))
            shape.stroke(color.opacity(0.6),
                         lineWidth: calendarEventBlockStrokeWidth(isInterrupt: false, isWeekMode: isWeekMode))
            if showsTitle {
                VStack(alignment: .leading, spacing: spacing) {
                    Text(overlay.title)
                        .font(.system(size: titleFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showsTime {
                        Text(timeText)
                            .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .padding(.top, insets.vertical)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(x: x, y: size.height * overlay.yFraction)
        .allowsHitTesting(false)
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
                .strokeBorder(.blue, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    /// The iPhone's block (CalendarDayLayerView.configure), drawn in SwiftUI
    /// in the phone's layer order: clipped content (opaque 0.4 fill, timer
    /// hatch, agentic shimmer, multi-type triangle, text), then the centered
    /// 0.7 border, the effort bar above it, the todo urgency border, the
    /// spinner. Numbers come from EventBlockMetrics, the file the phone's
    /// renderer reads.
    private func blockView(_ block: DayBlockModel, size: CGSize) -> some View {
        let style = EventBlockStyle.edit
        let cornerRadius = calendarEventBlockCornerRadius(isInterrupt: block.isInterrupt, isWeekMode: isWeekMode)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // An interrupt parent's compound silhouette: a moat cut around each
        // embedded child (phone: 3pt across, 2pt above/below).
        let compound = Self.compoundGeometry(block, size: size)
        let silhouette: AnyShape = compound.map {
            AnyShape(CalendarInterruptParentCompoundShape(cornerRadius: max(cornerRadius, 4),
                                                          visibleSegments: $0.visibleSegments))
        } ?? AnyShape(shape)
        let color = blockColor(block)
        let isAgenticActive = block.agenticPhase == .queued || block.agenticPhase == .analyzing
        let showsMultiType = multiTypeEnabled && block.hasAdditionalTypes
        let selected = block.eventID == selectedID
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                silhouette.fill(CalendarCanvasView.systemBackground(colorScheme))
                silhouette.fill(color.opacity(style.fillOpacity))
                if block.isTimerActive {
                    DiagonalHatch(spacing: 6).stroke(color.opacity(0.3), lineWidth: 1)
                }
                if isAgenticActive {
                    LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.22), .white.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(0.18)
                }
                if showsMultiType {
                    CornerTriangle(size: 14).fill(Color.primary.opacity(0.28))
                }
                blockText(block, size: size, contentRects: compound?.contentRects, selected: selected,
                          subtitle: showsMultiType ? block.typeSubtitle : "")
            }
            .clipShape(silhouette)
            silhouette.stroke(color.opacity(style.strokeOpacity),
                              lineWidth: calendarEventBlockStrokeWidth(isInterrupt: block.isInterrupt, isWeekMode: isWeekMode))
            if block.colorDepth > 0 {
                Rectangle()
                    .fill(color)
                    .frame(width: calendarEventEffortBarWidth(colorDepth: block.colorDepth, isWeekMode: isWeekMode))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .clipShape(silhouette)
            }
            if block.isTodo && !block.isDone {
                // Redrawn exactly when the urgency can change (24h before the
                // deadline, and at it) — no clock polling.
                TimelineView(.explicit(Self.urgencyTransitions(deadline: block.deadline, now: Date()))) { _ in
                    shape.inset(by: calendarTodoBorderWidth / 2)
                        .stroke(todoBorderColor(block, now: Date()), lineWidth: calendarTodoBorderWidth)
                }
            }
            if isAgenticActive {
                ProgressView()
                    .controlSize(.small)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // A completed todo fades — the phone's done-fade (0.55), todos only.
        // Applied BEFORE the ring so a selected done todo still shows a
        // full-strength selection ring, not a 55%-dimmed one (review #4).
        .opacity(block.isTodo && block.isDone ? 0.55 : 1)
        // The selection ring: a crisp accent frame at full opacity.
        .overlay {
            if compound != nil {
                silhouette.stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0)
            } else {
                shape.strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
            }
        }
    }

    /// The topmost block whose DRAWN frame (blockRect) holds `point`, so a
    /// press on an interrupt parent's uncut strip is the parent's, as on the
    /// phone (renderedFrames) — review F10's both-axes rule, in points.
    static func hitBlock(_ blocks: [DayBlockModel], at point: CGPoint, in size: CGSize) -> DayBlockModel? {
        blocks
            .filter { blockRect($0, in: size).contains(point) }
            .max { $0.zIndex < $1.zIndex }
    }

    /// Where a block draws in its column, in points: its slot less the 1pt
    /// gutters, and for an embedded interrupt child the phone's child-overlay
    /// inset within the parent's slot.
    static func blockRect(_ block: DayBlockModel, in size: CGSize) -> CGRect {
        var x = size.width * block.xOffsetFraction + 1
        var width = max(1, size.width * block.widthFraction - 2)
        if block.isEmbeddedInterruptChild {
            let geo = calendarInterruptChildOverlayGeometry(parentWidth: width)
            x += geo.xOffset
            width = max(1, geo.width)
        }
        return CGRect(x: x, y: size.height * block.yFraction,
                      width: width, height: max(6, size.height * block.heightFraction - 1))
    }

    /// The phone's compound geometry for an interrupt parent with embedded
    /// children (nil for every other block, or when no cutout lands).
    static func compoundGeometry(_ block: DayBlockModel, size: CGSize) -> CalendarInterruptParentCompoundGeometry? {
        guard let parentRange = block.compoundParentRange, !block.interruptChildRanges.isEmpty else { return nil }
        let geo = calendarInterruptParentCompoundGeometry(
            parentRange: parentRange, childRanges: block.interruptChildRanges,
            parentWidth: size.width, parentHeight: size.height,
            horizontalGap: 3, verticalGap: 2
        )
        return geo.cutouts.isEmpty ? nil : geo
    }

    /// Title, optional multi-type subtitle, optional "start - end", gated by
    /// the phone's text layout.
    /// A compound parent's text goes in one of its uncut regions
    /// (`contentRects`), picked as the phone does.
    private func blockText(_ block: DayBlockModel, size: CGSize, contentRects: [CGRect]?,
                           selected: Bool, subtitle: String) -> some View {
        let timeFontSize = calendarEventTimeFontSize(forTitleFontSize: titleFontSize, isWeekMode: isWeekMode)
        let insets = calendarEventBlockInsets(isWeekMode: isWeekMode, isThreeDayMode: isThreeDayMode)
        let spacing = calendarEventBlockTitleSpacing(isWeekMode: isWeekMode, isThreeDayMode: isThreeDayMode)
        let titleLineHeight = MacBlockTextLayout.lineHeight(NSFont.systemFont(ofSize: titleFontSize, weight: .semibold))
        let timeLineHeight = MacBlockTextLayout.lineHeight(
            NSFont.monospacedDigitSystemFont(ofSize: timeFontSize, weight: .medium))
        let rect = contentRects.map {
            MacBlockTextLayout.compoundTextRect($0, insets: insets, titleLineHeight: titleLineHeight)
        } ?? CGRect(origin: .zero, size: size)
        let layout = MacBlockTextLayout(
            size: rect?.size ?? .zero, insets: insets, spacing: spacing,
            titleLineHeight: titleLineHeight, timeLineHeight: timeLineHeight,
            showTimeBelowTitle: showTimeBelowTitle, isSelected: selected
        )
        let title = block.title.isEmpty ? "Untitled" : block.title
        return VStack(alignment: .leading, spacing: spacing) {
            if layout.showsText {
                // The phone's failed-intake badge prefixes the title.
                Text(block.agenticPhase == .failed ? "⚠️ \(title)" : title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(layout.titleLineLimit)
                    .allowsTightening(true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: timeFontSize, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineLimit(1)
                }
                if layout.showsTime {
                    Text(block.timeText(is24: is24HourTime))
                        .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .padding(.vertical, layout.centersVertically ? 0 : insets.vertical)
        .frame(width: rect?.width ?? 0, height: rect?.height ?? 0,
               alignment: layout.centersVertically ? .leading : .topLeading)
        .offset(x: rect?.minX ?? 0, y: rect?.minY ?? 0)
    }

    /// An analyzing event takes the now-line color (white in dark, white 0.22
    /// in light), as on the phone; otherwise the type color.
    private func blockColor(_ block: DayBlockModel) -> Color {
        guard block.agenticPhase == .analyzing else { return block.color }
        return colorScheme == .dark ? .white : Color(white: 0.22)
    }

    /// The instants after `now` at which `CalendarTodoBorderUrgency` changes
    /// for this deadline (normal → dueSoon → overdue), a second past each
    /// boundary since both comparisons are strict.
    static func urgencyTransitions(deadline: Date?, now: Date) -> [Date] {
        guard let deadline else { return [] }
        return [deadline.addingTimeInterval(-24 * 3600 + 1), deadline.addingTimeInterval(1)]
            .filter { $0 > now }
    }

    /// The phone's todo urgency colors for `CalendarTodoBorderUrgency`.
    private func todoBorderColor(_ block: DayBlockModel, now: Date) -> Color {
        switch CalendarTodoBorderUrgency(deadline: block.deadline, isDone: block.isDone, now: now) {
        case .normal: return .white.opacity(0.9)
        case .dueSoon: return .orange.opacity(0.95)
        case .overdue: return .red.opacity(0.95)
        }
    }
}

/// The phone's timer hatch (diagonalHatchPath): parallel lines rising left
/// to right, `spacing` apart.
struct DiagonalHatch: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var offset = -rect.height
        while offset < rect.width + rect.height {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += spacing
        }
        return path
    }
}

/// The phone's multi-type corner triangle: top-right, `size` on a side.
struct CornerTriangle: Shape {
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - size, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + size))
        path.closeSubpath()
        return path
    }
}

/// The phone's block text gate (calendarEventTextLayout, EventBlock.swift):
/// no text under 28x16; title centred with no vertical inset when even one
/// title line won't fit the insets; the time row only when it geometrically
/// fits under the title (setting on), else only on the focused block at
/// 88x42 or more (setting off — the phone's `.edit`-style gate, which on the
/// Mac is the selected block).
struct MacBlockTextLayout: Equatable {
    let showsText: Bool
    let showsTime: Bool
    let centersVertically: Bool
    let titleLineLimit: Int

    init(size: CGSize, insets: CalendarEventBlockInsets, spacing: CGFloat,
         titleLineHeight: CGFloat, timeLineHeight: CGFloat,
         showTimeBelowTitle: Bool, isSelected: Bool) {
        showsText = size.width >= 28 && size.height >= 16
        centersVertically = size.height < insets.vertical * 2 + titleLineHeight
        if size.width < 48 {
            titleLineLimit = size.height >= 40 ? 3 : (size.height >= 28 ? 2 : 1)
        } else {
            titleLineLimit = 2
        }
        let fitsTime: Bool
        if showTimeBelowTitle {
            let needed = (centersVertically ? 0 : insets.vertical * 2) + titleLineHeight + spacing + timeLineHeight
            fitsTime = size.width >= 48 && size.height >= needed
        } else {
            fitsTime = isSelected && size.width >= 88 && size.height >= 42
        }
        showsTime = showsText && fitsTime
    }

    /// The phone's calendarInterruptParentTextLayout pick: the topmost region
    /// where a title line fits under the insets, else the largest region that
    /// takes any text. (The phone measures the whole title for "fits"; one
    /// line is the Mac's stand-in.) nil → no text.
    static func compoundTextRect(_ rects: [CGRect], insets: CalendarEventBlockInsets,
                                 titleLineHeight: CGFloat) -> CGRect? {
        func takesText(_ r: CGRect) -> Bool { r.width >= 28 && r.height >= 16 }
        if let top = rects.sorted(by: { $0.minY < $1.minY }).first(where: {
            takesText($0) && $0.height >= insets.vertical * 2 + titleLineHeight
                && $0.width > insets.leading + insets.trailing
        }) {
            return top
        }
        return rects.sorted { lhs, rhs in
            let la = lhs.width * lhs.height, ra = rhs.width * rhs.height
            if abs(la - ra) > 0.5 { return la > ra }
            if abs(lhs.minY - rhs.minY) > 0.5 { return lhs.minY < rhs.minY }
            return lhs.width > rhs.width
        }.first(where: takesText)
    }

    /// UIFont.lineHeight's AppKit counterpart.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }
}
