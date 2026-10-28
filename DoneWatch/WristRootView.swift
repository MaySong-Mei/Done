//
//  WristRootView.swift
//  DoneWatch
//
//  Three pages, swiped left and right: Today (the day's timeline, the
//  default page, with the running session's bar at its foot), Stats (time
//  by category over a period) and Settings. The minute schedule
//  re-resolves every page at event boundaries; the running counter ticks
//  on its own through `Text(_:style: .timer)`.
//

import Combine
import SwiftUI
import WatchKit

struct WristRootView: View {
    @EnvironmentObject private var client: WristSessionClient
    @State private var page = WristPage.initial
    @AppStorage(WristLocalSettings.zoomKey) private var zoomRaw = WristLocalSettings.Zoom.standard.rawValue
    /// Empty until a period is picked on the watch: the phone's applies.
    @AppStorage(WristLocalSettings.statsPeriodKey) private var periodRaw = ""
    /// Where the running bar's top is on the screen.
    @State private var barTop: CGFloat?
    private let housekeeping = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.everyMinute) { context in
            let strings = WristStrings(code: client.snapshot?.language)
            let settings = client.statsSettings
            let stats = client.snapshot?.stats?.markingLeftOut(settings)
            let running = runningSession(now: context.date)
            TabView(selection: $page) {
                NavigationStack {
                    today(now: context.date, strings: strings, stats: stats, running: running)
                }
                .tag(WristPage.today)
                NavigationStack {
                    WristStatsView(
                        stats: stats,
                        overlap: settings.overlap,
                        openingPeriod: WristLocalSettings.openingPeriod(watch: periodRaw, phone: settings.defaultPeriod),
                        now: context.date, strings: strings
                    )
                }
                .tag(WristPage.stats)
                NavigationStack {
                    WristSettingsView(
                        zoomRaw: $zoomRaw, periodRaw: $periodRaw,
                        settings: settings,
                        hasPhoneData: client.snapshot != nil,
                        phoneTakesEdits: client.snapshot?.takesSettingsEdits ?? false,
                        snapshotAge: client.snapshot.map { context.date.timeIntervalSince($0.generatedAt) },
                        strings: strings,
                        onEditOverlap: { client.editStatsSettings(overlap: $0) },
                        onEditBackground: { client.editStatsSettings(excludesBackground: $0) }
                    )
                }
                .tag(WristPage.settings)
            }
            .tabViewStyle(.page)
            // Over the pages, not inside Today: in a paged TabView's page
            // the bar's ticking counter re-renders the page every frame for
            // as long as a session runs, the same trap as
            // `containerBackground(for: .navigation)`.
            .overlay(alignment: .bottom) {
                ZStack {
                    if page == .today, let running {
                        WristRunningBar(
                            occurrence: running.occurrence, pending: running.pending, strings: strings,
                            onExtend: { client.extend(running.occurrence) },
                            onFinish: { client.finish(running.occurrence) }
                        )
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { _, y in barTop = y }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: page == .today)
            }
        }
        .onReceive(housekeeping) { now in
            client.tick(now: now)
        }
    }

    private func runningSession(now: Date) -> (occurrence: WristOccurrence, pending: Bool)? {
        if case .active(let occurrence, let pending) = client.display(now: now) {
            return (occurrence, pending)
        }
        return nil
    }

    /// Room the running bar takes at the foot of Today, in the day's
    /// full-screen coordinates.
    private func barInset(_ running: Bool) -> CGFloat {
        guard running else { return 0 }
        guard let barTop else { return WristRunningBar.height }
        return max(0, WKInterfaceDevice.current().screenBounds.height - barTop)
    }

    @ViewBuilder
    private func today(
        now: Date, strings: WristStrings, stats: CategoryStatsPayload?,
        running: (occurrence: WristOccurrence, pending: Bool)?
    ) -> some View {
        if let snapshot = client.snapshot {
            let (timeline, pendingIDs) = WristStateReducer.overlaid(snapshot, pending: client.pending, now: now)
            WristTodayView(
                occurrences: timeline, dismissed: client.dismissed, stats: stats,
                now: now, currentID: running?.occurrence.id, strings: strings, types: snapshot.types,
                titleHints: snapshot.titleHints,
                localCreates: client.localCreates, motions: snapshot.motions,
                hourHeight: CGFloat(WristLocalSettings.Zoom(stored: zoomRaw).hourHeight),
                bottomInset: barInset(running != nil),
                takesRangeEdits: snapshot.takesRangeEdits,
                pendingEventIDs: pendingIDs,
                onCreate: { type, title, start, end in client.create(type, title: title, start: start, end: end) },
                onEditRange: { occurrence, start, end in client.editRange(occurrence, start: start, end: end) },
                onExtend: { client.extend($0) },
                onFinish: { client.finish($0) },
                onFlick: { step in
                    // Today is the leftmost page.
                    guard step > 0 else { return }
                    withAnimation { page = .stats }
                }
            )
        } else {
            WristEmptyView(strings: strings)
        }
    }
}

enum WristPage: String, Hashable {
    case today, stats, settings

    /// Today. Debug builds accept `-wristPage today|stats|settings` so a
    /// paired-simulator check can open a page without a swipe.
    static var initial: WristPage {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-wristPage"), i + 1 < arguments.count,
           let page = WristPage(rawValue: arguments[i + 1]) {
            return page
        }
#endif
        return .today
    }
}

/// The day from midnight to midnight at about a point a minute — a quarter
/// hour is a fingertip, and a half-hour block has room for its name and
/// times — centered on the present on open (the Digital Crown scrolls it).
///
/// Press and hold on empty time, then drag, to draw a block — the phone's
/// drag to create (`WristDraftMapping`). The page holds still while the
/// finger is down; on release a type picker names the block — then, when
/// the phone knows names for that type, the likeliest few for this range —
/// and closing it discards the draft. Drawing from the now line is how a
/// session starts now.
///
/// Tap a block to select it: a card names it and offers its quick changes
/// (+15 and Finish for the running one, the end a quarter hour earlier or
/// later for the rest). Press and hold a block, then drag, to move it — or,
/// pressed near its top or bottom edge, to resize that edge — the phone's
/// edit on its day timeline (`WristBlockEdit`); the release sends the new
/// range to the phone (`WristCommand.Kind.setRange`), shown at once and
/// put back if the phone refuses it.
struct WristTodayView: View {
    let occurrences: [WristOccurrence]
    let dismissed: [WristDismissal]
    let stats: CategoryStatsPayload?
    let now: Date
    let currentID: String?
    let strings: WristStrings
    var types: [WristType] = []
    var titleHints: [String: [WristTitleHint]] = [:]
    /// The events this watch started that the phone has not reflected yet,
    /// and the phone's motion switches (`WristMotionPlan`).
    var localCreates: Set<UUID> = []
    var motions: WristMotionSettings = .off
    /// Points per hour (`WristLocalSettings.Zoom`).
    var hourHeight: CGFloat = CGFloat(WristLocalSettings.Zoom.standard.hourHeight)
    /// What the running bar covers at the foot of the page: the day scrolls
    /// clear of it, and drawing scrolls at its top edge.
    var bottomInset: CGFloat = 0
    /// The phone applies range edits (`WristSnapshot.takesRangeEdits`), and
    /// the events with a command it has not answered yet.
    var takesRangeEdits: Bool = false
    var pendingEventIDs: Set<UUID> = []
    /// Returns the created event's id.
    var onCreate: (WristType, String?, Date, Date) -> UUID? = { _, _, _, _ in nil }
    /// A block's range moved, resized or nudged here.
    var onEditRange: (WristOccurrence, Date, Date) -> Void = { _, _, _ in }
    var onExtend: (WristOccurrence) -> Void = { _ in }
    var onFinish: (WristOccurrence) -> Void = { _ in }
    /// A sideways flick: -1 for the page to the left, +1 to the right. The
    /// hold-and-drag on the day is a drag gesture, and any drag gesture here
    /// keeps the paged TabView from turning the page itself.
    var onFlick: (Int) -> Void = { _ in }

    /// The press point and the drawn range, in the day's own points.
    private struct Draft: Equatable {
        var anchorY: Double
        var range: WristDraftMapping.Range
    }

    @State private var draft: Draft?
    @State private var picking = false
    /// A block being moved or resized: which one, as it was when grabbed,
    /// and where it is going.
    private struct Edit: Equatable {
        var motionKey: String
        var occurrence: WristOccurrence
        var model: WristBlockEdit
        var range: WristDraftMapping.Range
    }
    @State private var edit: Edit?
    /// The hold under the finger has been read (a draft, an edit, a hint or
    /// nothing): later samples of the same hold only follow the finger.
    @State private var holdRead = false
    /// The release of an edit: the change it makes lands in the preview's
    /// place without a tween, as the phone's drop does.
    @State private var editLanding = false
    /// When the last hold ended — the release of a hold also reads as a tap
    /// or a flick, which must not act on it.
    @State private var holdEndedAt = Date.distantPast
    /// The tapped block, by motion key, and its card.
    @State private var selectedKey: String?
    /// A short note over the day: why a hold did nothing.
    @State private var hint: String?
    @State private var hintToken = UUID()
    /// The scroll view's width, to find the block under a touch.
    @State private var contentWidth: CGFloat = 0
    /// The draft a block was just created from, and the event it made: the
    /// block starts in the draft's place and look. `sheetUp` holds it there
    /// until the picker is gone.
    private struct Landing: Equatable {
        var eventID: UUID
        var span: WristTimeSpan
        var slot: WristOverlapSlot
    }
    @State private var landing: Landing?
    /// The created draft's range, for the picker while it slides away.
    @State private var landingRange: WristDraftMapping.Range?
    @State private var sheetUp = false
    /// The page as last drawn, for the next change's motions.
    private struct MotionInput: Equatable {
        var blocks: [WristDayBlock]
        var occurrences: [WristOccurrence]
        var dayStart: Date
    }
    @State private var drawn: MotionInput?
    private struct Ghost: Identifiable {
        let id = UUID()
        let block: WristDayBlock
        let motion: WristMotionPlan.Departure
    }
    @State private var ghosts: [Ghost] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True from the moment the hold is recognized until the finger lifts
    /// (or the system takes the touch): the page does not scroll meanwhile.
    @GestureState private var holding = false
    /// How far the day is scrolled, to turn a touch on the scroll view into
    /// a point of the day.
    @State private var scrollY: CGFloat = 0
    /// The visible height of the day and its full height, for the drag's
    /// edge scrolling.
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// Where the finger is while drawing, in the scroll view's coordinates:
    /// near an edge the day scrolls under a still finger, and the draft's
    /// moving end follows the time that passes under it.
    @State private var fingerY: CGFloat?
    /// Ticks only while a finger is drawing: the watch does not wake for it
    /// otherwise.
    private var edgeTicks: AnyPublisher<Date, Never> {
        holding
            ? Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
            : Empty().eraseToAnyPublisher()
    }

    private let gutter: CGFloat = 28
    /// The watch's own zone — the one its face shows. The stats payload
    /// carries the phone's zone at its last write, which may be another.
    private var calendar: Calendar { .current }

    var body: some View {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let rows = WristDayLayout.hourRows(dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
        let height = CGFloat(dayEnd.timeIntervalSince(dayStart) / 3600) * hourHeight
        let page = WristDayLayout.page(
            occurrences, dismissed: dismissed, dayStart: dayStart, dayEnd: dayEnd, now: now, currentID: currentID,
            draft: draft.map { WristTimeSpan(start: $0.range.start, end: $0.range.end) }
        )
        let blocks = page.blocks
        let input = MotionInput(blocks: blocks, occurrences: occurrences, dayStart: dayStart)
        let plan = motionPlan(to: input)
        let nowY = CGFloat(WristDayLayout.fraction(now, dayStart: dayStart, dayEnd: dayEnd)) * height
        let nowRow = rows.lastIndex { $0.start <= now } ?? 0
        let mapping = WristDraftMapping(
            dayStart: dayStart, dayEnd: dayEnd, height: Double(height),
            edges: blocks.flatMap { [$0.start, $0.end] }
        )

        WristPageFrame(header: WristStatsHeader.text(stats, period: .today, asOf: now, strings: strings)) { top in
            ScrollViewReader { proxy in
                ScrollView {
                    // The hour rows are the real layout (so `scrollTo` finds
                    // them); the blocks and the now line are drawn over them.
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 2) {
                                Text(strings.hourLabel(rows[index].hour))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: gutter - 2, alignment: .trailing)
                                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                            }
                            .frame(height: hourHeight, alignment: .top)
                            .id(index)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        GeometryReader { geometry in
                            let width = geometry.size.width - gutter
                            let place = { (slot: WristOverlapSlot, start: Date, end: Date, embedded: Bool) in
                                rect(slot: slot, start: start, end: end, embedded: embedded,
                                     width: width, dayStart: dayStart, dayEnd: dayEnd, height: height)
                            }
                            ZStack(alignment: .topLeading) {
                                ForEach(blocks, id: \.motionKey) { block in
                                    let frame = place(block.slot, block.start, block.end, block.parentID != nil)
                                    let fromDraft = landing.flatMap { landing in
                                        landing.eventID == block.occurrence.eventID
                                            ? place(landing.slot, landing.span.start, landing.span.end, false) : nil
                                    }
                                    blockView(block, size: frame.size, selected: selectedKey == block.motionKey && edit == nil)
                                        // Grabbed: the block stays faded in its place while
                                        // the preview shows where it is going.
                                        .opacity(edit?.motionKey == block.motionKey ? 0.35 : 1)
                                        .modifier(WristArrivalEffect(
                                            arrival: plan.arrivals[block.motionKey], frame: frame,
                                            draftFrame: fromDraft, holding: sheetUp
                                        ))
                                }
                            }
                            .animation(
                                plan.tween.map { .timingCurve(0.25, 0.8, 0.35, 1, duration: $0.duration) },
                                value: blocks
                            )
                            // Over the blocks that reflow into the space.
                            ForEach(ghosts) { ghost in
                                let frame = place(ghost.block.slot, ghost.block.start, ghost.block.end, ghost.block.parentID != nil)
                                WristDepartureView(
                                    block: ghost.block, motion: ghost.motion, frame: frame,
                                    content: AnyView(blockView(ghost.block, size: frame.size))
                                )
                            }
                            if let edit, let block = blocks.first(where: { $0.motionKey == edit.motionKey }) {
                                let start = max(edit.range.start, dayStart), end = min(edit.range.end, dayEnd)
                                let frame = place(block.slot, start, end, block.parentID != nil)
                                editPreview(block, range: edit.range, height: frame.height)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                                    // Each quarter-hour step glides when the phone's
                                    // resize tween is on, as its edge drag does.
                                    .animation(
                                        reduceMotion ? nil : motions.resize.map { .easeOut(duration: $0.stepDuration) },
                                        value: edit.range
                                    )
                            }
                            if let draft {
                                let frame = place(page.draftSlot ?? .full, draft.range.start, draft.range.end, false)
                                draftView(draft.range)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                            }
                            // Over the draft too: a block drawn across the
                            // present still shows where the present is.
                            Rectangle()
                                .fill(.red)
                                .frame(width: width + 4, height: 1.5)
                                .offset(x: gutter - 4, y: nowY)
                            Circle().fill(.red).frame(width: 5, height: 5)
                                .offset(x: gutter - 6, y: nowY - 1.75)
                        }
                    }
                    // Midnight can still scroll clear of the clock row, and
                    // the night clear of the running bar.
                    .padding(.top, top)
                    .padding(.bottom, bottomInset)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in scrollY = y }
                .onScrollGeometryChange(for: CGSize.self, of: { CGSize(width: $0.containerSize.height, height: $0.contentSize.height) }) { _, size in
                    viewportHeight = size.width
                    contentHeight = size.height
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in contentWidth = width }
                .onReceive(edgeTicks) { _ in scrollAtEdge(mapping, top: top) }
                // On the scroll view, not its content: any drag on the
                // content takes every pan from the scroll view, while one
                // here leaves it its scrolls until the hold is recognized.
                .simultaneousGesture(createGesture(mapping, blocks: blocks, top: top, height: height))
                .simultaneousGesture(flickGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        tap(at: value.location, blocks: blocks, mapping: mapping, top: top, height: height)
                    }
                )
                .scrollDisabled(holding || draft != nil || edit != nil)
                .mask(WristEdgeFade(top: 0, bottom: 10))
                .overlay(alignment: .bottom) {
                    if draft == nil, edit == nil,
                       let key = selectedKey, let block = blocks.first(where: { $0.motionKey == key }) {
                        card(block)
                            .padding(.bottom, bottomInset + 2)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if let hint {
                        Text(hint)
                            .font(.system(size: 12, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.top, top + 4)
                            .padding(.horizontal, 6)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(Self.debugScrollRow ?? nowRow, anchor: .center) }
                }
                // A new zoom puts the same hour row elsewhere: back to now.
                .onChange(of: hourHeight) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo(nowRow, anchor: .center) }
                }
            }
        }
        // Lifting the finger ends the drag the same way whether the gesture
        // ended or was taken away: a drawn draft goes to the picker.
        .onChange(of: holding) { _, isHolding in
            if !isHolding {
                fingerY = nil
                if holdRead { holdEndedAt = Date() }
                holdRead = false
                if draft != nil { picking = true }
                if let current = edit {
                    let original = current.model.original
                    if current.range.start != original.start || current.range.end != original.end {
                        editLanding = true
                        onEditRange(current.occurrence, current.range.start, current.range.end)
                        // Should the edit change nothing on the page, the next
                        // change must still tween.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { editLanding = false }
                    }
                    edit = nil
                }
            }
        }
        .onChange(of: picking) { _, isPicking in
            if isPicking { sheetUp = true }
        }
        .onAppear { if drawn == nil { drawn = input } }
        .onChange(of: input) { _, new in
            editLanding = false
            if let key = selectedKey, !new.blocks.contains(where: { $0.motionKey == key }) { selectedKey = nil }
            for departure in motionPlan(to: new).departures {
                let ghost = Ghost(block: departure.block, motion: departure.motion)
                ghosts.append(ghost)
                DispatchQueue.main.asyncAfter(deadline: .now() + WristDepartureView.duration(of: ghost.motion) + 0.05) {
                    ghosts.removeAll { $0.id == ghost.id }
                }
            }
            drawn = new
        }
        .sheet(isPresented: $picking, onDismiss: {
            draft = nil
            sheetUp = false
        }) {
            if let range = (draft?.range ?? landingRange) {
                WristDraftTypePicker(
                    types: types, titleHints: titleHints, occurrences: occurrences, range: range,
                    calendar: calendar, strings: strings
                ) { type, title in
                    // The draft goes in the same update its block arrives,
                    // so the two never share the page.
                    if let eventID = onCreate(type, title, range.start, range.end) {
                        landing = Landing(
                            eventID: eventID, span: WristTimeSpan(start: range.start, end: range.end),
                            slot: page.draftSlot ?? .full
                        )
                        landingRange = range
                    }
                    draft = nil
                    picking = false
                }
            }
        }
#if DEBUG
        .onAppear { seedDebugDraft(mapping) }
#endif
    }

    /// Hold, then drag. What the hold is on is read once the hold is
    /// recognized and the first drag sample names where the finger went
    /// down: empty time starts a draft at the press, a block the phone lets
    /// the watch edit is grabbed (`WristBlockEdit` — its edge or the whole
    /// block), any other block says why not. Each move after that sets the
    /// finger's end; a click marks every new grid mark or block edge it
    /// lands on.
    private func createGesture(
        _ mapping: WristDraftMapping, blocks: [WristDayBlock], top: CGFloat, height: CGFloat
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let dayY = { (y: CGFloat) in Double(y + scrollY - top) }
                fingerY = drag.location.y
                if let current = draft {
                    let range = mapping.range(anchorY: current.anchorY, currentY: dayY(drag.location.y))
                    guard range != current.range else { return }
                    if range.moving.time != current.range.moving.time {
                        WKInterfaceDevice.current().play(.click)
                    }
                    draft?.range = range
                } else if let current = edit {
                    let range = current.model.range(currentY: dayY(drag.location.y))
                    guard range != current.range else { return }
                    if range.moving.time != current.range.moving.time {
                        WKInterfaceDevice.current().play(.click)
                    }
                    edit?.range = range
                } else if !holdRead, !picking {
                    holdRead = true
                    let y = dayY(drag.startLocation.y)
                    if let (block, frame) = blockHit(x: drag.startLocation.x, dayY: y, blocks: blocks, mapping: mapping, height: height) {
                        grab(block, frame: frame, pressY: y, fingerY: dayY(drag.location.y), blocks: blocks, mapping: mapping)
                    } else if mapping.isEmpty(atY: y, blocks: blocks) {
                        draft = Draft(anchorY: y, range: mapping.range(anchorY: y, currentY: dayY(drag.location.y)))
                        WKInterfaceDevice.current().play(.click)
                    }
                }
            }
    }

    /// Whether the phone lets the watch change this block's range: not a
    /// repeating event or a running timer, and a phone that takes edits.
    private func isEditable(_ occurrence: WristOccurrence) -> Bool {
        takesRangeEdits && occurrence.quickActionsEnabled && !occurrence.isOpenEnded
    }

    /// A hold on a block: grab it, or say why it stays put.
    private func grab(
        _ block: WristDayBlock, frame: CGRect, pressY: Double, fingerY: Double,
        blocks: [WristDayBlock], mapping: WristDraftMapping
    ) {
        let occurrence = block.occurrence
        guard isEditable(occurrence) else {
            WKInterfaceDevice.current().play(.directionDown)
            show(hint: takesRangeEdits ? strings.cannotMoveHere : strings.updatePhoneForEdits)
            return
        }
        let mode = WristBlockEdit.mode(
            pressY: pressY - Double(frame.minY), blockHeight: Double(frame.height),
            canResizeTop: occurrence.start >= mapping.dayStart, canResizeBottom: occurrence.end <= mapping.dayEnd
        )
        var day = mapping
        // Every other block's own edges — not the day's clipped ones, and
        // not a running timer's placeholder end.
        day.edges = blocks.filter { $0.motionKey != block.motionKey }.flatMap { other -> [Date] in
            other.occurrence.isOpenEnded ? [other.occurrence.start] : [other.occurrence.start, other.occurrence.end]
        }
        let model = WristBlockEdit(
            mapping: day, original: WristTimeSpan(start: occurrence.start, end: occurrence.end),
            mode: mode, anchorY: pressY
        )
        edit = Edit(motionKey: block.motionKey, occurrence: occurrence, model: model, range: model.range(currentY: fingerY))
        selectedKey = block.motionKey
        WKInterfaceDevice.current().play(.click)
    }

    /// The topmost block under a point of the day, and its frame.
    private func blockHit(
        x: CGFloat, dayY: Double, blocks: [WristDayBlock], mapping: WristDraftMapping, height: CGFloat
    ) -> (WristDayBlock, CGRect)? {
        let width = contentWidth - gutter
        guard width > 0 else { return nil }
        let point = CGPoint(x: x, y: CGFloat(dayY))
        for block in blocks.reversed() {
            let frame = rect(
                slot: block.slot, start: block.start, end: block.end, embedded: block.parentID != nil,
                width: width, dayStart: mapping.dayStart, dayEnd: mapping.dayEnd, height: height
            )
            // A thin block is still a fingertip tall to aim at.
            let slop = max(0, (12 - frame.height) / 2)
            if frame.insetBy(dx: -1, dy: -slop).contains(point) { return (block, frame) }
        }
        return nil
    }

    /// A tap selects the block under it (again, or on empty time, closes
    /// the card). The release of a hold is no tap.
    private func tap(at location: CGPoint, blocks: [WristDayBlock], mapping: WristDraftMapping, top: CGFloat, height: CGFloat) {
        guard draft == nil, edit == nil, !picking, Date().timeIntervalSince(holdEndedAt) > 0.4 else { return }
        let hit = blockHit(x: location.x, dayY: Double(location.y + scrollY - top), blocks: blocks, mapping: mapping, height: height)
        let key = hit.map(\.0.motionKey)
        withAnimation(.easeOut(duration: 0.15)) {
            selectedKey = key == selectedKey ? nil : key
        }
    }

    private func show(hint text: String) {
        let token = UUID()
        hintToken = token
        withAnimation(.easeOut(duration: 0.15)) { hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard hintToken == token else { return }
            withAnimation(.easeOut(duration: 0.2)) { hint = nil }
        }
    }

    /// Turns the page on a sideways swipe that never became a hold: mostly
    /// horizontal, and far or fast enough to read as a page turn.
    private var flickGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard draft == nil, edit == nil, !picking, Date().timeIntervalSince(holdEndedAt) > 0.4 else { return }
                let dx = value.translation.width, dy = value.translation.height
                let reach = max(abs(dx), abs(value.predictedEndTranslation.width))
                guard abs(dx) > abs(dy) * 1.5, reach > 40 else { return }
                onFlick(dx < 0 ? 1 : -1)
            }
    }

    /// Points from either edge of the visible day where a held finger
    /// scrolls it, and the fastest it scrolls, in points per tick.
    private let edgeZone: CGFloat = 28
    private let edgeSpeed: CGFloat = 9

    /// While drawing or editing with the finger near the top or bottom edge,
    /// scroll the day toward it — faster the deeper in — and carry the
    /// moving end to the time now under the finger, as the phone's drag does.
    private func scrollAtEdge(_ mapping: WristDraftMapping, top: CGFloat) {
        guard holding, draft != nil || edit != nil, let fingerY, viewportHeight > 0 else { return }
        let depth: CGFloat
        // The top edge is under the clock row's glass.
        if fingerY < top + edgeZone {
            depth = -(top + edgeZone - fingerY) / edgeZone
        } else if fingerY > viewportHeight - bottomInset - edgeZone {
            // The bottom edge is the running bar's top, when it is up.
            depth = (fingerY - (viewportHeight - bottomInset - edgeZone)) / edgeZone
        } else {
            return
        }
        let maxY = max(0, contentHeight - viewportHeight)
        let target = min(max(0, scrollY + edgeSpeed * min(1, depth)), maxY)
        guard abs(target - scrollY) >= 0.5 else { return }
        scrollY = target
        position.scrollTo(y: target)
        let y = Double(fingerY + target - top)
        if let current = draft {
            let range = mapping.range(anchorY: current.anchorY, currentY: y)
            guard range != current.range else { return }
            if range.moving.time != current.range.moving.time {
                WKInterfaceDevice.current().play(.click)
            }
            draft?.range = range
        } else if let current = edit {
            let range = current.model.range(currentY: y)
            guard range != current.range else { return }
            if range.moving.time != current.range.moving.time {
                WKInterfaceDevice.current().play(.click)
            }
            edit?.range = range
        }
    }

    /// The draft in the blocks' shape, neutral until it has a type: a grey
    /// fill the grid and blocks under it show through, a white border, and
    /// its range in place of a title.
    private func draftView(_ range: WristDraftMapping.Range) -> some View {
        let height = CGFloat(range.end.timeIntervalSince(range.start) / 3600) * hourHeight
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(white: 0.3).opacity(0.6))
            .overlay(alignment: .topLeading) {
                if height >= 13 {
                    Text(strings.timeRange(range.start, range.end))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.top, 1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1)
            }
            .allowsHitTesting(false)
    }

    /// `-wristScrollHour <hour>` opens the page on that hour instead of
    /// now, for a screenshot of a given stretch. Debug builds only.
    private static var debugScrollRow: Int? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-wristScrollHour"), i + 1 < arguments.count { return Int(arguments[i + 1]) }
#endif
        return nil
    }

#if DEBUG
    /// `-wristDraft <start hour> <end hour>` (fractions allowed) opens the
    /// page with a draft drawn and the picker up, for a check that cannot
    /// hold and drag. Debug builds only.
    private func seedDebugDraft(_ mapping: WristDraftMapping) {
        let arguments = ProcessInfo.processInfo.arguments
        guard draft == nil, let i = arguments.firstIndex(of: "-wristDraft"), i + 2 < arguments.count,
              let from = Double(arguments[i + 1]), let to = Double(arguments[i + 2]) else { return }
        let hours = mapping.dayEnd.timeIntervalSince(mapping.dayStart) / 3600
        let anchorY = from / hours * mapping.height
        draft = Draft(anchorY: anchorY, range: mapping.range(anchorY: anchorY, currentY: to / hours * mapping.height))
        picking = true
    }
#endif

    /// What changes from the page as last drawn to `input` play.
    private func motionPlan(to input: MotionInput) -> WristMotionPlan {
        guard let drawn else { return WristMotionPlan() }
        return WristMotionPlan.make(
            old: drawn.blocks, new: input.blocks, oldAll: drawn.occurrences, newAll: input.occurrences,
            localCreates: localCreates, settings: motions, sameDay: drawn.dayStart == input.dayStart,
            drawing: draft != nil || edit != nil || editLanding, reduceMotion: reduceMotion
        )
    }

    /// A slot and range in the page's points. A column beside another
    /// keeps a 2pt gutter on its right; an interrupt embedded in a parent
    /// sits on the parent's column, inset from its left edge so the
    /// parent shows beside it — the phone's child overlay.
    private func rect(
        slot: WristOverlapSlot, start: Date, end: Date, embedded: Bool,
        width: CGFloat, dayStart: Date, dayEnd: Date, height: CGFloat
    ) -> CGRect {
        let inset: CGFloat = embedded ? Self.interruptInset : 0
        let x = gutter + width * CGFloat(slot.x) + inset
        let w = max(4, width * CGFloat(slot.width) - 2 - inset)
        let y = CGFloat(WristDayLayout.fraction(start, dayStart: dayStart, dayEnd: dayEnd)) * height
        let h = max(3, CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 1)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static let interruptInset: CGFloat = 6

    /// Where a grabbed block is going: the block lifted — its colour full,
    /// a white outline — with the range it would get, title and all when
    /// there is room.
    private func editPreview(_ block: WristDayBlock, range: WristDraftMapping.Range, height: CGFloat) -> some View {
        let hex = block.occurrence.colorHex
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(WristColor.fill(hex, strength: 0.7))
            .overlay(alignment: .topLeading) {
                if height >= 13 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(strings.timeRange(range.start, range.end))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(.white)
                        if height >= 30 {
                            Text(block.occurrence.title)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.top, 1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white, lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.6), radius: 3)
            .allowsHitTesting(false)
    }

    /// The selected block's card: its name, type and range, and the quick
    /// changes the phone allows for it — +15 and Finish while it runs, its
    /// end a quarter hour earlier or later otherwise.
    private func card(_ block: WristDayBlock) -> some View {
        let occurrence = block.occurrence
        let color = WristColor.color(occurrence.colorHex)
        let end = occurrence.isOpenEnded ? block.end : occurrence.end
        let running = block.isCurrent && occurrence.quickActionsEnabled
        let editable = isEditable(occurrence)
        let pending = pendingEventIDs.contains(occurrence.eventID)
        let canShorten = end.addingTimeInterval(-WristTiming.extendStep).timeIntervalSince(occurrence.start)
            >= WristTiming.minimumDuration
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(occurrence.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(occurrence.type) · \(strings.timeRange(occurrence.start, end))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selectedKey = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.close)
            }
            if pending {
                Text(strings.sending)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if running {
                HStack(spacing: 6) {
                    cardButton(strings.extend, fill: Color.white.opacity(0.18)) { onExtend(occurrence) }
                    cardButton(nil, systemImage: "checkmark", fill: color.opacity(0.85)) { onFinish(occurrence) }
                        .accessibilityLabel(strings.finish)
                }
            } else if editable {
                HStack(spacing: 6) {
                    cardButton(strings.endEarlier, fill: Color.white.opacity(0.18), enabled: canShorten) {
                        onEditRange(occurrence, occurrence.start, end.addingTimeInterval(-WristTiming.extendStep))
                    }
                    cardButton(strings.endLater, fill: Color.white.opacity(0.18)) {
                        onEditRange(occurrence, occurrence.start, end.addingTimeInterval(WristTiming.extendStep))
                    }
                }
            } else {
                Text(takesRangeEdits || occurrence.isOpenEnded || !occurrence.quickActionsEnabled
                     ? strings.editOnPhoneShort : strings.updatePhoneForEdits)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Plain fills, like the running bar: no blur redrawn as the day moves.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.3))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }

    private func cardButton(
        _ title: String?, systemImage: String? = nil, fill: Color, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            action()
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .bold))
                } else {
                    Text(title ?? "")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(fill, in: Capsule())
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func blockView(_ block: WristDayBlock, size: CGSize, selected: Bool = false) -> some View {
        let hex = block.occurrence.colorHex
        let strong = block.isCurrent || selected
        let height = size.height
        // A stack-peek host's title stays in the half the blocks over it
        // leave clear, where they reach its top — the phone's text region.
        let titleBand = block.start.addingTimeInterval(Double(min(height, 30) / hourHeight) * 3600)
        let titleCovered = block.slot.coverRanges.contains { $0.start < titleBand && $0.end > block.start }
        let embedded = block.parentID != nil
        return RoundedRectangle(cornerRadius: embedded ? 3 : 4, style: .continuous)
            .fill(WristColor.fill(hex, strength: strong ? 0.6 : 0.4))
            .overlay(alignment: .topLeading) {
                if height >= 13 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(block.occurrence.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(height >= 46 ? 2 : 1)
                            .foregroundStyle(.white)
                        if height >= 30 {
                            Text(strings.timeRange(block.start, block.end))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.top, 1)
                    .frame(maxWidth: titleCovered ? max(0, size.width * 0.5 - 2) : .infinity, alignment: .leading)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: embedded ? 3 : 4, style: .continuous)
                    .strokeBorder(
                        strong ? .white.opacity(0.9) : WristColor.border(hex),
                        lineWidth: selected ? 2 : block.isCurrent || block.occurrence.isInterrupt ? 1 : 0.75
                    )
            }
            // The moat the phone cuts round an embedded interrupt: a ring of
            // the page's black between it and its parent.
            .background {
                if embedded {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(.black)
                        .padding(-1.5)
                }
            }
    }
}

/// Names a drawn block: the types as tiles, under the
/// block's range. A type the phone knows names for opens a second step with
/// the likeliest of them for this range and "just <type>"; one without
/// creates at once. The sheet's close button discards the draft.
struct WristDraftTypePicker: View {
    let types: [WristType]
    var titleHints: [String: [WristTitleHint]] = [:]
    /// The timeline the block was drawn on: what is right before and after
    /// it, and how far into the day it is, steer the names.
    var occurrences: [WristOccurrence] = []
    let range: WristDraftMapping.Range
    var calendar: Calendar = .current
    let strings: WristStrings
    let onPick: (WristType, String?) -> Void

    /// The type being named and its names, ranked once when the step
    /// opens: a snapshot that lands meanwhile must not reorder the rows
    /// under the finger.
    private struct Naming: Hashable {
        var type: WristType
        var names: [String]
    }

    @State private var naming: Naming?

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    private func names(for type: WristType) -> [String] {
        guard let hints = titleHints[type.title], !hints.isEmpty else { return [] }
        let table = WristTitleTable(typeOrder: types.map(\.title), hints: titleHints)
        let context = WristTitleTimeline(occurrences: occurrences)
            .context(start: range.start, end: range.end, table: table, calendar: calendar)
        return WristTitleRanking.rank(hints, start: range.start, end: range.end, calendar: calendar, context: context)
    }

    var body: some View {
        NavigationStack {
            typeGrid
                .navigationDestination(item: $naming) { naming in
                    WristDraftTitlePicker(
                        type: naming.type, names: naming.names, range: range, strings: strings,
                        onPick: { onPick(naming.type, $0) }
                    )
                }
        }
#if DEBUG
        .onAppear(perform: seedDebugNaming)
#endif
    }

#if DEBUG
    /// `-wristDraftType <type title>` with `-wristDraft` opens the names
    /// step for that type, for a check that cannot tap. Debug builds only.
    private func seedDebugNaming() {
        let arguments = ProcessInfo.processInfo.arguments
        guard naming == nil, let i = arguments.firstIndex(of: "-wristDraftType"), i + 1 < arguments.count,
              let type = types.first(where: { $0.title == arguments[i + 1] }) else { return }
        let names = names(for: type)
        guard !names.isEmpty else { return }
        naming = Naming(type: type, names: names)
    }
#endif

    private var typeGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.timeRange(range.start, range.end))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if types.isEmpty {
                    Text(strings.noTypes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(types) { type in
                        Button {
                            let names = names(for: type)
                            if names.isEmpty {
                                onPick(type, nil)
                            } else {
                                naming = Naming(type: type, names: names)
                            }
                        } label: {
                            WristTypeTile(type: type, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The second step: the type's likeliest names for the drawn range, one
/// tap each, then the type alone — what a block was named before names
/// were offered.
struct WristDraftTitlePicker: View {
    let type: WristType
    let names: [String]
    let range: WristDraftMapping.Range
    let strings: WristStrings
    let onPick: (String?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.timeRange(range.start, range.end))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                ForEach(names, id: \.self) { name in
                    Button {
                        onPick(name)
                    } label: {
                        row(name, fill: WristColor.fill(type.colorHex), border: WristColor.border(type.colorHex))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    onPick(nil)
                } label: {
                    row(strings.justType(type.title), fill: Color(white: 0.16), border: .white.opacity(0.2))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(type.title)
    }

    private func row(_ text: String, fill: Color, border: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A type as the picker draws it: its name on the type color.
struct WristTypeTile: View {
    let type: WristType
    var minHeight: CGFloat = 48

    var body: some View {
        Text(type.title)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(
                WristColor.fill(type.colorHex),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(WristColor.border(type.colorHex), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Time by category for today or the last 3, 7 or 30 days — tap the
/// period line for the next one. The clock row carries the period's
/// share logged and its hours, like the today page's. What counts, and how
/// overlapping events are credited, is the phone's Settings → Apple Watch
/// (the overlap rule and background types can be changed on the settings
/// page too).
struct WristStatsView: View {
    /// Already marked with the types the settings leave out.
    let stats: CategoryStatsPayload?
    let overlap: WristOverlapRule
    /// The watch's pick, else the phone's
    /// (`WristLocalSettings.openingPeriod`).
    let openingPeriod: WristStatsPeriod
    let now: Date
    let strings: WristStrings
    /// Nil until a tap: the page follows the opening period.
    @State private var chosen: WristStatsPeriod? = Self.launchPeriod

    /// Debug builds accept `-wristStatsPeriod today|threeDays|sevenDays|thirtyDays`,
    /// so a check can open a period without a tap.
    private static var launchPeriod: WristStatsPeriod? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-wristStatsPeriod"), i + 1 < arguments.count,
           let period = WristStatsPeriod(rawValue: arguments[i + 1]) {
            return period
        }
#endif
        return nil
    }

    private var period: WristStatsPeriod { chosen ?? openingPeriod }

    /// Debug builds accept `-wristOverlap split|full|latestStart` over the
    /// phone's choice, to compare the rules on one fixture.
    private var rule: WristOverlapRule {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-wristOverlap"), i + 1 < arguments.count,
           let rule = WristOverlapRule(rawValue: arguments[i + 1]) {
            return rule
        }
#endif
        return overlap
    }

    var body: some View {
        let figures = WristStatsFigures.of(stats, period: period, asOf: now, overlap: rule)
        let rows = CategoryStats.breakdown(figures.categories, maxRows: 5, unlogged: figures.unloggedHours)
        WristPageFrame(header: WristStatsHeader.text(stats, period: period, asOf: now, strings: strings)) { top in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    picker
                    switch figures.status {
                    case .noData:
                        note(strings.statsNoData)
                    case .stale:
                        note(figures.leftOutToFit ? strings.statsLeftOut : strings.statsStale)
                    case .empty, .ok:
                        bar(rows)
                        if figures.totalHours <= 0 { note(strings.nothingLogged) }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            rowView(row, figures: figures)
                        }
                    }
                }
                .padding(.top, top + 2)
                .padding(.horizontal, 6)
                .padding(.bottom, 18)
            }
            .mask(WristEdgeFade(top: 0, bottom: 10))
        }
    }

    /// One line: the period's name and a dot per period. A tap anywhere on
    /// the line moves to the next period, wrapping after month.
    private var picker: some View {
        let all = WristStatsPeriod.allCases
        return Button {
            let i = all.firstIndex(of: period) ?? all.startIndex
            let next = all.index(after: i)
            chosen = next == all.endIndex ? all[all.startIndex] : all[next]
        } label: {
            HStack(spacing: 6) {
                Text(strings.periodLabel(period))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(all, id: \.self) { option in
                        Circle()
                            .fill(Color.white.opacity(option == period ? 0.9 : 0.25))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            // The whole line is the target, not only the glyphs.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func color(of row: CategoryStatsRow) -> Color {
        if row.isUnlogged { return .white.opacity(0.15) }
        if row.isRemainder { return .gray }
        return WristColor.color(row.colorHex ?? "")
    }

    private func label(of row: CategoryStatsRow) -> String {
        if row.isUnlogged { return strings.unlogged }
        if row.isRemainder { return strings.others }
        return row.name
    }

    private func bar(_ rows: [CategoryStatsRow]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle()
                        .fill(color(of: row))
                        .frame(width: max(0, geometry.size.width * row.share - 1))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

    /// Under `full` the rows overlap, so a share of their sum would hide
    /// how much of the period each took: each row is its own share of the
    /// elapsed time instead, and they can sum past 100%.
    private func percentText(_ row: CategoryStatsRow, figures: WristStatsFigures) -> String {
        guard rule == .full, figures.elapsedHours > 0 else { return row.percentText }
        let percent = Int((row.hours / figures.elapsedHours * 100).rounded())
        return percent == 0 && row.hours > 0 ? "<1%" : "\(percent)%"
    }

    private func rowView(_ row: CategoryStatsRow, figures: WristStatsFigures) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(of: row)).frame(width: 8, height: 8)
            Text(label(of: row))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(row.isUnlogged ? Color.secondary : Color.white)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(strings.compactDuration(hours: row.hours))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(percentText(row, figures: figures))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// The watch's settings. Zoom and the period stats open on live on the
/// watch. The overlap rule and the background switch are the phone's
/// Settings → Apple Watch, edited from here: the change shows at once and
/// goes to the phone, whose next snapshot carries it. Which types count
/// stays on the phone — a list of every type is a phone-sized choice — and
/// the page says so. Every choice is one row; a tap moves to its next value.
struct WristSettingsView: View {
    @Binding var zoomRaw: String
    @Binding var periodRaw: String
    let settings: WristStatsSettings
    let hasPhoneData: Bool
    /// The phone applies settings edits (`WristSnapshot.takesSettingsEdits`).
    let phoneTakesEdits: Bool
    let snapshotAge: TimeInterval?
    let strings: WristStrings
    let onEditOverlap: (WristOverlapRule) -> Void
    let onEditBackground: (Bool) -> Void

    private var zoom: WristLocalSettings.Zoom { WristLocalSettings.Zoom(stored: zoomRaw) }
    /// Nil while the phone's period applies.
    private var watchPeriod: WristStatsPeriod? { WristStatsPeriod(rawValue: periodRaw) }

    var body: some View {
        WristPageFrame(header: Text(strings.settingsTitle)) { top in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    section(strings.settingsOnWatch)
                    cycleRow(
                        strings.zoom, value: strings.zoomLabel(zoom),
                        index: WristLocalSettings.Zoom.allCases.firstIndex(of: zoom) ?? 0,
                        count: WristLocalSettings.Zoom.allCases.count
                    ) {
                        zoomRaw = Self.next(after: zoom, in: WristLocalSettings.Zoom.allCases).rawValue
                    }
                    let periods: [WristStatsPeriod?] = [nil] + WristStatsPeriod.allCases
                    cycleRow(
                        strings.statsOpensOn,
                        value: watchPeriod.map(strings.periodLabel) ?? strings.followPhone(settings.defaultPeriod),
                        index: periods.firstIndex(of: watchPeriod) ?? 0, count: periods.count
                    ) {
                        periodRaw = Self.next(after: watchPeriod, in: periods)?.rawValue ?? ""
                    }

                    section(strings.settingsFromPhone).padding(.top, 6)
                    if hasPhoneData {
                        cycleRow(
                            strings.overlap, value: strings.overlapLabel(settings.overlap),
                            index: WristOverlapRule.allCases.firstIndex(of: settings.overlap) ?? 0,
                            count: WristOverlapRule.allCases.count
                        ) {
                            onEditOverlap(Self.next(after: settings.overlap, in: WristOverlapRule.allCases))
                        }
                        .disabled(!phoneTakesEdits)
                        Toggle(isOn: Binding(get: { settings.excludesBackground }, set: { onEditBackground($0) })) {
                            Text(strings.leaveOutBackground)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(!phoneTakesEdits)
                        if !phoneTakesEdits { note(strings.updatePhoneForSettings) }
                        note(strings.typesOnPhone(leftOut: settings.excludedTypes.count))
                    } else {
                        note(strings.noPhoneData)
                    }
                    if let age = snapshotAge, age > 24 * 3600 {
                        note(strings.stale(age))
                    }
                }
                .padding(.top, top + 2)
                .padding(.horizontal, 6)
                .padding(.bottom, 18)
            }
            .mask(WristEdgeFade(top: 0, bottom: 10))
        }
    }

    static func next<T: Equatable>(after value: T, in all: [T]) -> T {
        guard let i = all.firstIndex(of: value) else { return all[0] }
        return all[(i + 1) % all.count]
    }

    private func section(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    /// A setting's name over its value, with a dot per value.
    private func cycleRow(_ title: String, value: String, index: Int, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        ForEach(0..<count, id: \.self) { option in
                            Circle()
                                .fill(Color.white.opacity(option == index ? 0.9 : 0.25))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WristEmptyView: View {
    let strings: WristStrings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(strings.noPhoneData)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The running session at the foot of the today page (laid over the
/// pages by `WristRootView`): its name, the
/// counter, +15 and Finish (the double tap). A session the phone cannot
/// end from here (a repeating event, a phone timer) shows no buttons.
struct WristRunningBar: View {
    static let height: CGFloat = 46

    let occurrence: WristOccurrence
    let pending: Bool
    let strings: WristStrings
    let onExtend: () -> Void
    let onFinish: () -> Void

    private var color: Color { WristColor.color(occurrence.colorHex) }

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(occurrence.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Group {
                    if pending {
                        Text("\(Text(occurrence.start, style: .timer)) · \(strings.sending)")
                    } else if occurrence.quickActionsEnabled {
                        Text(occurrence.start, style: .timer)
                    } else {
                        Text("\(Text(occurrence.start, style: .timer)) · \(strings.editOnPhoneShort)")
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if occurrence.quickActionsEnabled {
                Button(action: onExtend) {
                    Text(strings.extend)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(width: 38, height: 30)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onFinish) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 38, height: 30)
                        .background(color.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.finish)
                .handGestureShortcut(.primaryAction)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        // Plain fills, no material: the bar sits over a scroll view, and a
        // blur there would be redrawn whenever the day moves.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))
        )
        .padding(.horizontal, 4)
    }
}

enum WristColor {
    static func color(_ hex: String) -> Color {
        guard let rgb = components(hex) else { return .gray }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// The phone's block fill: the type color at `strength` over the black
    /// face, made opaque so grid lines don't show through. Dark enough that
    /// every title can be white.
    static func fill(_ hex: String, strength: Double = 0.4) -> Color {
        guard let rgb = components(hex) else { return Color(white: 0.25) }
        return Color(red: rgb.r * strength, green: rgb.g * strength, blue: rgb.b * strength)
    }

    /// The phone's block border.
    static func border(_ hex: String) -> Color {
        color(hex).opacity(0.7)
    }

    private static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 8, let value = UInt64(sanitized, radix: 16) else {
            return nil
        }
        let shift: UInt64 = sanitized.count == 8 ? 8 : 0
        return (
            Double((value >> (16 + shift)) & 0xFF) / 255,
            Double((value >> (8 + shift)) & 0xFF) / 255,
            Double((value >> shift) & 0xFF) / 255
        )
    }
}

/// Every page's frame: the content runs edge to edge, under a frosted
/// clock row that carries the page's `header` beside the clock. No title —
/// the page dots say which page this is.
struct WristPageFrame<Content: View>: View {
    let header: Text?
    @ViewBuilder let content: (_ clockRow: CGFloat) -> Content

    var body: some View {
        GeometryReader { screen in
            let top = screen.safeAreaInsets.top
            ZStack(alignment: .topLeading) {
                content(top)
                WristGlassBar(height: top)
                if let header {
                    header
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        // Clear of the rounded corner, and of the clock.
                        .frame(maxWidth: screen.size.width * 0.58, maxHeight: top, alignment: .leading)
                        .padding(.leading, 14)
                }
            }
            .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// "94% 21h34m": the share of `period` logged so far, in white, then the
/// hours, in grey. Nil when the stats cannot answer the period. Wall-clock
/// time, so the same under every overlap rule and never past 100%.
enum WristStatsHeader {
    static func text(_ stats: CategoryStatsPayload?, period: WristStatsPeriod, asOf: Date, strings: WristStrings) -> Text? {
        let figures = WristStatsFigures.of(stats, period: period, asOf: asOf)
        switch figures.status {
        case .ok, .empty:
            let span = Text(strings.compactDuration(hours: figures.loggedHours)).foregroundStyle(.secondary)
            guard figures.elapsedHours > 0 else { return span }
            let rate = Int((figures.loggedHours / figures.elapsedHours * 100).rounded())
            return Text("\(rate)% ").foregroundStyle(.white) + span
        case .noData, .stale:
            return nil
        }
    }
}

/// Frosted glass behind the clock row: the timeline scrolls under it
/// blurred, and its lower edge dissolves instead of drawing a line.
struct WristGlassBar: View {
    let height: CGFloat
    private let feather: CGFloat = 14

    var body: some View {
        // The watch's thinnest material still darkens a lot; at half
        // strength it reads as glass rather than a band.
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(0.5)
            .frame(height: height + feather)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: height / (height + feather)),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }
}

/// Content fades out at the top and bottom edges instead of being cut off.
struct WristEdgeFade: View {
    var top: CGFloat = 14
    var bottom: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottom)
        }
    }
}
