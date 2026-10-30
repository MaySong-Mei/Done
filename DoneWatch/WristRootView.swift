//
//  WristRootView.swift
//  DoneWatch
//
//  Four pages, swiped left and right: the event page (one event, its end
//  on the crown), Today (the day's timeline, the default page), Stats
//  (time by category over a period) and Settings. The block selected on
//  Today is the event page's subject. The minute schedule re-resolves
//  every page at event boundaries.
//

import Combine
import SwiftUI
import WatchKit

struct WristRootView: View {
    @EnvironmentObject private var client: WristSessionClient
    @State private var page = WristPage.initial
    /// The block selected on Today, by its range (a motion key would name
    /// another range of the event once the phone adds one before it):
    /// shared with the event page, whose subject it is. Held, not
    /// observed: only those two pages redraw for a selection.
    @State private var selectionModel = WristSelectionModel()
    @AppStorage(WristLocalSettings.zoomKey) private var zoomRaw = WristLocalSettings.Zoom.standard.rawValue
    /// Empty until a period is picked on the watch: the phone's applies.
    @AppStorage(WristLocalSettings.statsPeriodKey) private var periodRaw = ""
    private let housekeeping = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.everyMinute) { context in
            let strings = WristStrings(code: client.snapshot?.language)
            let settings = client.statsSettings
            let stats = client.snapshot?.stats?.markingLeftOut(settings)
            let running = runningSession(now: context.date)
            TabView(selection: $page) {
                NavigationStack {
                    eventPage(now: context.date, strings: strings, running: running)
                }
                .tag(WristPage.event)
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
        }
        .onReceive(housekeeping) { now in
            client.tick(now: now)
        }
#if DEBUG
        .onAppear {
            guard let key = WristPage.initialSelection, let snapshot = client.snapshot else { return }
            let running = runningSession(now: Date())?.occurrence
            selectionModel.selection = dayBlocks(snapshot, now: Date(), currentID: running?.id).blocks
                .first { $0.motionKey == key }.map { WristEventSubject.Selection($0.occurrence) }
        }
#endif
    }

    private func runningSession(now: Date) -> (occurrence: WristOccurrence, pending: Bool)? {
        if case .active(let occurrence, let pending) = client.display(now: now) {
            return (occurrence, pending)
        }
        return nil
    }

    /// Today's blocks as the day lays them out, for the event page's subject
    /// and its neighbours' edges.
    private func dayBlocks(_ snapshot: WristSnapshot, now: Date, currentID: String?) -> (blocks: [WristDayBlock], pendingIDs: Set<UUID>, dayStart: Date, dayEnd: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let (timeline, pendingIDs) = WristStateReducer.overlaid(snapshot, pending: client.pending, now: now)
        let blocks = WristDayLayout.blocks(
            timeline, dismissed: client.dismissed, dayStart: dayStart, dayEnd: dayEnd, now: now, currentID: currentID
        )
        return (blocks, pendingIDs, dayStart, dayEnd)
    }

    @ViewBuilder
    private func eventPage(
        now: Date, strings: WristStrings, running: (occurrence: WristOccurrence, pending: Bool)?
    ) -> some View {
        if let snapshot = client.snapshot {
            let day = dayBlocks(snapshot, now: now, currentID: running?.occurrence.id)
            WristEventPage(
                selectionModel: selectionModel,
                blocks: day.blocks, running: running?.occurrence, takesRangeEdits: snapshot.takesRangeEdits,
                dayStart: day.dayStart, dayEnd: day.dayEnd, localCreates: client.localCreates,
                pendingEventIDs: day.pendingIDs,
                page: $page,
                now: now, strings: strings,
                onSend: { client.editRange($0.occurrence, start: $0.start, end: $0.end) },
                onExtend: { client.extend($0) },
                onFinish: { client.finish($0) }
            )
        } else {
            WristEmptyView(strings: strings)
        }
    }

    @ViewBuilder
    private func today(
        now: Date, strings: WristStrings, stats: CategoryStatsPayload?,
        running: (occurrence: WristOccurrence, pending: Bool)?
    ) -> some View {
        if let snapshot = client.snapshot {
            let timeline = WristStateReducer.overlaid(snapshot, pending: client.pending, now: now).occurrences
            WristTodayView(
                occurrences: timeline, dismissed: client.dismissed, stats: stats,
                now: now, currentID: running?.occurrence.id, strings: strings, types: snapshot.types,
                titleHints: snapshot.titleHints,
                localCreates: client.localCreates, motions: snapshot.motions,
                hourHeight: CGFloat(WristLocalSettings.Zoom(stored: zoomRaw).hourHeight),
                takesRangeEdits: snapshot.takesRangeEdits,
                selectionModel: selectionModel,
                onCreate: { type, name, start, end in
                    client.create(type, title: name.title, awaitsName: name == .later, start: start, end: end)
                },
                onEditRange: { occurrence, start, end in client.editRange(occurrence, start: start, end: end) },
                onFlick: { step in
                    // The event page is to the left, Stats to the right.
                    withAnimation { page = step > 0 ? .stats : .event }
                }
            )
        } else {
            WristEmptyView(strings: strings)
        }
    }
}

enum WristPage: String, Hashable {
    case event, today, stats, settings

    /// Today. Debug builds accept `-wristPage event|today|stats|settings` so
    /// a paired-simulator check can open a page without a swipe.
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

    /// Nothing. Debug builds accept `-wristSelect <motion key>` (e.g.
    /// `00000000-0000-0000-0000-000000000003#0` for the parallel fixture's
    /// Deep work) so a check can open with a block selected without a tap.
    static var initialSelection: String? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-wristSelect"), i + 1 < arguments.count { return arguments[i + 1] }
#endif
        return nil
    }
}

/// The day from midnight to midnight at about a point a minute — a quarter
/// hour is a fingertip, and a half-hour block has room for its name and
/// times — centered on the present on open (the Digital Crown scrolls it).
///
/// Press and hold on empty time to draw a block — the phone's drag to
/// create (`WristDraftMapping`). The hold shows a quarter-hour draft under
/// the still finger with a click (`WristHold`); dragging then sets its
/// other end. The page holds still while the finger is down; on release a
/// type picker names the block — then, when the phone knows names for that
/// type, the likeliest few for this range — and closing it discards the
/// draft. Drawing from the now line is how a session starts now.
///
/// Tap a block to select it: it is outlined, nothing opens over the day.
/// Press and hold a block — it lifts with a click under
/// the still finger — then drag to move it, or, pressed near its top or
/// bottom edge, to resize that edge — the phone's
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
    /// The phone applies range edits (`WristSnapshot.takesRangeEdits`).
    var takesRangeEdits: Bool = false
    /// The tapped block, by its range — the event page's subject.
    @ObservedObject var selectionModel: WristSelectionModel
    private var selection: WristEventSubject.Selection? {
        get { selectionModel.selection }
        nonmutating set { selectionModel.selection = newValue }
    }
    /// Returns the created event's id.
    var onCreate: (WristType, WristDraftName, Date, Date) -> UUID? = { _, _, _, _ in nil }
    /// A block's range moved or resized here.
    var onEditRange: (WristOccurrence, Date, Date) -> Void = { _, _, _ in }
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
    /// The release of an edit: the change it makes lands in the preview's
    /// place without a tween, as the phone's drop does.
    @State private var editLanding = false
    /// When the last hold ended — the release of a hold also reads as a tap
    /// or a flick, which must not act on it.
    @State private var holdEndedAt = Date.distantPast
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
    /// True while a finger is on the day, until it lifts or the system
    /// takes the touch.
    @GestureState private var touching = false
    /// The finger on the day, from touch-down: pending until it has been
    /// held still long enough, then armed until it lifts.
    @State private var hold: WristHold?
    /// The hold has armed: the page does not scroll until the finger lifts.
    private var holding: Bool { hold?.isArmed == true }
    /// How far the day is scrolled, to turn a touch on the scroll view into
    /// a point of the day.
    @State private var scrollY: CGFloat = 0
    /// The visible height of the day and its full height, for the drag's
    /// edge scrolling.
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// The day has opened on the present.
    @State private var opened = false
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
                                    blockView(block, size: frame.size, selected: selection?.matches(block.occurrence) == true && edit == nil)
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
                    // Midnight can still scroll clear of the clock row.
                    .padding(.top, top)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                    scrollY = y
                    if hold?.isPending == true { cancelHold { $0.scrolled(to: Double(y)) } }
                }
                // A pan the scroll view takes is no hold, however slowly the
                // finger goes.
                .onScrollPhaseChange { old, new in
                    if hold != nil { WristGestureTrail.note("scroll \(old) → \(new)") }
                    if new == .interacting, hold?.isPending == true { cancelHold { $0.scrollBegan() } }
                }
                .onScrollGeometryChange(for: CGSize.self, of: { CGSize(width: $0.containerSize.height, height: $0.contentSize.height) }) { _, size in
                    viewportHeight = size.width
                    contentHeight = size.height
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in contentWidth = width }
                .onReceive(edgeTicks) { _ in scrollAtEdge(mapping, top: top) }
                // On the scroll view, not its content: any drag on the
                // content takes every pan from the scroll view, while one
                // here leaves it its scrolls until the hold is recognized.
                .simultaneousGesture(holdGesture(mapping, blocks: blocks, top: top, height: height))
                .simultaneousGesture(flickGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        tap(at: value.location, blocks: blocks, mapping: mapping, top: top, height: height)
                    }
                )
                .scrollDisabled(holding || draft != nil || edit != nil)
                .mask(WristEdgeFade(top: 0, bottom: 10))
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
                // Opens on the present once; back from the event page (or
                // any other) the day is where it was left.
                .onAppear {
                    guard !opened else { return }
                    opened = true
                    DispatchQueue.main.async { proxy.scrollTo(Self.debugScrollRow ?? nowRow, anchor: .center) }
                }
                // A new zoom puts the same hour row elsewhere: back to now.
                .onChange(of: hourHeight) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo(nowRow, anchor: .center) }
                }
            }
        }
        // Lifting the finger ends the hold the same way whether the gesture
        // ended or was taken away: a draft — drawn or only held — goes to
        // the picker, a changed edit is sent.
        .onChange(of: touching) { _, isTouching in
            if !isTouching {
                let armed = holding
                let editChanged = edit.map {
                    $0.range.start != $0.model.original.start || $0.range.end != $0.model.original.end
                } ?? false
                let release = WristHold.release(hasDraft: draft != nil, editChanged: editChanged)
                WristGestureTrail.note("release armed=\(armed) phase=\(hold?.phase.name ?? "none") → \(release)")
                hold = nil
                fingerY = nil
                if armed { holdEndedAt = Date() }
                if release == .pick {
                    picking = true
                    WristGestureTrail.note("picker shown \(draft.map { strings.timeRange($0.range.start, $0.range.end) } ?? "")")
                }
                if let current = edit {
                    if release == .sendEdit {
                        editLanding = true
                        onEditRange(current.occurrence, current.range.start, current.range.end)
                        // A move gives the range a new start: the selection
                        // goes with it.
                        if selection?.matches(current.occurrence) == true {
                            selection = WristEventSubject.Selection(eventID: current.occurrence.eventID, rangeStart: current.range.start)
                        }
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
            if let current = selection, !new.blocks.contains(where: { current.matches($0.occurrence) }) { selection = nil }
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
                ) { type, name in
                    // The draft goes in the same update its block arrives,
                    // so the two never share the page.
                    if let eventID = onCreate(type, name, range.start, range.end) {
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

    /// Hold, then drag. A drag of no minimum distance follows the finger
    /// from touch-down (the scroll view keeps its pans meanwhile); a timer
    /// started then arms the hold if the finger has stayed within the slop
    /// and the day has not scrolled (`WristHold`). Armed, the hold reads
    /// what the press is on under the still finger: empty time starts a
    /// draft at the press, a block the phone lets the watch edit is grabbed
    /// (`WristBlockEdit` — its edge or the whole block), any other block
    /// says why not. Each move after that sets the finger's end; a click
    /// marks the hold and every new grid mark or block edge it lands on.
    private func holdGesture(
        _ mapping: WristDraftMapping, blocks: [WristDayBlock], top: CGFloat, height: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                guard let current = hold else {
                    // A touch while the picker is up starts nothing.
                    guard !picking else { return }
                    beginHold(at: value.startLocation, mapping: mapping, blocks: blocks, top: top, height: height)
                    return
                }
                if current.isPending {
                    cancelHold { $0.track(x: Double(value.location.x), y: Double(value.location.y)) }
                    return
                }
                guard current.isArmed else { return }
                follow(value.location, mapping: mapping, top: top)
            }
    }

    /// A finger went down on the day: note it, and start the hold's timer.
    private func beginHold(
        at location: CGPoint, mapping: WristDraftMapping, blocks: [WristDayBlock], top: CGFloat, height: CGFloat
    ) {
        let downAt = Date()
        hold = WristHold(downAt: downAt, x: Double(location.x), y: Double(location.y), scroll: Double(scrollY))
        WristGestureTrail.note(String(
            format: "down x=%.0f y=%.0f dayY=%.0f scroll=%.0f",
            Double(location.x), Double(location.y), Double(location.y + scrollY - top), Double(scrollY)
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + WristHold.duration) {
            guard var current = hold, current.downAt == downAt, current.arm(at: Date()) else { return }
            hold = current
            armHold(current, mapping: mapping, blocks: blocks, top: top, height: height)
        }
    }

    /// Applies `change` to the pending hold and notes why it was given up.
    private func cancelHold(_ change: (inout WristHold) -> Void) {
        guard var current = hold else { return }
        let before = current.phase
        change(&current)
        guard current.phase != before else { return }
        hold = current
        if case .cancelled(let reason) = current.phase {
            WristGestureTrail.note("cancel \(reason.rawValue) after \(Int(Date().timeIntervalSince(current.downAt) * 1000))ms")
        }
    }

    /// The hold armed with the finger still where it went down: read what
    /// it is on, and answer at once.
    private func armHold(
        _ hold: WristHold, mapping: WristDraftMapping, blocks: [WristDayBlock], top: CGFloat, height: CGFloat
    ) {
        guard !picking, draft == nil, edit == nil else { return }
        let y = hold.downY + Double(scrollY - top)
        let hit = blockHit(x: CGFloat(hold.downX), dayY: y, blocks: blocks, mapping: mapping, height: height)
        let target = hit.map { block, frame in
            WristHold.Target(
                minY: Double(frame.minY), height: Double(frame.height),
                editable: isEditable(block.occurrence),
                canResizeTop: block.occurrence.start >= mapping.dayStart,
                canResizeBottom: block.occurrence.end <= mapping.dayEnd
            )
        }
        let reading = WristHold.read(pressY: y, target: target, emptyAtPress: mapping.isEmpty(atY: y, blocks: blocks), mapping: mapping)
        fingerY = CGFloat(hold.downY)
        switch reading {
        case .draft(let range):
            draft = Draft(anchorY: y, range: range)
            WKInterfaceDevice.current().play(.click)
            WristGestureTrail.note("armed draft \(strings.timeRange(range.start, range.end))")
        case .grab(let mode):
            guard let (block, frame) = hit else { return }
            grab(block, frame: frame, mode: mode, pressY: y, blocks: blocks, mapping: mapping)
            WristGestureTrail.note("armed grab \(mode) \(strings.timeRange(block.start, block.end))")
        case .refused:
            WKInterfaceDevice.current().play(.directionDown)
            show(hint: takesRangeEdits ? strings.cannotMoveHere : strings.updatePhoneForEdits)
            WristGestureTrail.note("armed refused")
        case .nothing:
            WristGestureTrail.note("armed nothing")
        }
    }

    /// The finger moved while armed: the draft's or the edit's moving end
    /// follows it.
    private func follow(_ location: CGPoint, mapping: WristDraftMapping, top: CGFloat) {
        let y = Double(location.y + scrollY - top)
        fingerY = location.y
        if let current = draft {
            let range = mapping.range(anchorY: current.anchorY, currentY: y)
            let step = range.moving.time != current.range.moving.time
            WristGestureTrail.sample(String(format: "drag y=%.0f ", Double(location.y)) + strings.timeRange(range.start, range.end), step: step)
            guard range != current.range else { return }
            if step { WKInterfaceDevice.current().play(.click) }
            draft?.range = range
        } else if let current = edit {
            let range = current.model.range(currentY: y)
            let step = range.moving.time != current.range.moving.time
            WristGestureTrail.sample(String(format: "drag y=%.0f ", Double(location.y)) + strings.timeRange(range.start, range.end), step: step)
            guard range != current.range else { return }
            if step { WKInterfaceDevice.current().play(.click) }
            edit?.range = range
        }
    }

    /// Whether the phone lets the watch change this block's range: not a
    /// repeating event or a running timer, and a phone that takes edits.
    private func isEditable(_ occurrence: WristOccurrence) -> Bool {
        takesRangeEdits && occurrence.quickActionsEnabled && !occurrence.isOpenEnded
    }

    /// A hold on a block the watch may edit: grab its edge or the whole of
    /// it, lifted under the still finger.
    private func grab(
        _ block: WristDayBlock, frame: CGRect, mode: WristEditMode, pressY: Double,
        blocks: [WristDayBlock], mapping: WristDraftMapping
    ) {
        let occurrence = block.occurrence
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
        edit = Edit(motionKey: block.motionKey, occurrence: occurrence, model: model, range: model.range(currentY: pressY))
        let grabbed = WristEventSubject.Selection(block.occurrence)
        if selection != grabbed { selection = grabbed }
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

    /// A tap selects the block under it (again, or on empty time, clears
    /// it). The release of a hold is no tap.
    private func tap(at location: CGPoint, blocks: [WristDayBlock], mapping: WristDraftMapping, top: CGFloat, height: CGFloat) {
        guard draft == nil, edit == nil, !picking, !holding, Date().timeIntervalSince(holdEndedAt) > 0.4 else { return }
        let hit = blockHit(x: location.x, dayY: Double(location.y + scrollY - top), blocks: blocks, mapping: mapping, height: height)
        let tapped = hit.map { WristEventSubject.Selection($0.0.occurrence) }
        withAnimation(.easeOut(duration: 0.15)) {
            selection = tapped == selection ? nil : tapped
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
                guard draft == nil, edit == nil, !picking, !holding, Date().timeIntervalSince(holdEndedAt) > 0.4 else { return }
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
        } else if fingerY > viewportHeight - edgeZone {
            depth = (fingerY - (viewportHeight - edgeZone)) / edgeZone
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
            // Waiting for a name: the dashed outline the "name later" row
            // drew, over the block's own.
            .overlay {
                if block.occurrence.awaitsName {
                    RoundedRectangle(cornerRadius: embedded ? 3 : 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
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

/// What the naming settled on for a drawn block: a picked name, the type
/// alone, or "name later" — the type alone, with the phone asking for a
/// name (`WristCommand.Kind.start`'s `awaitsName`).
enum WristDraftName: Hashable {
    case named(String)
    case typeOnly
    case later

    /// The title the start carries: nil names the event after its type.
    var title: String? {
        if case .named(let name) = self { return name }
        return nil
    }
}

/// Names a drawn block: the types as tiles, under the
/// block's range. A type the phone knows names for opens a second step with
/// the likeliest of them for this range, "just <type>" and "name later"; one
/// without creates at once. "Name later" under the grid arms the next type
/// tapped to be created waiting for a name, so it is there for every type —
/// a tile tapped while armed skips the names step. The sheet's close button
/// discards the draft.
struct WristDraftTypePicker: View {
    let types: [WristType]
    var titleHints: [String: [WristTitleHint]] = [:]
    /// The timeline the block was drawn on: what is right before and after
    /// it, and how far into the day it is, steer the names.
    var occurrences: [WristOccurrence] = []
    let range: WristDraftMapping.Range
    var calendar: Calendar = .current
    let strings: WristStrings
    let onPick: (WristType, WristDraftName) -> Void

    /// The type being named and its names, ranked once when the step
    /// opens: a snapshot that lands meanwhile must not reorder the rows
    /// under the finger.
    private struct Naming: Hashable {
        var type: WristType
        var names: [String]
    }

    @State private var naming: Naming?
    @State private var namingLater = false

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
    /// step for that type, for a check that cannot tap;
    /// `-wristDraftNameLater` arms "name later" on the grid. Debug builds only.
    private func seedDebugNaming() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-wristDraftNameLater") { namingLater = true }
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
                            if namingLater {
                                onPick(type, .later)
                            } else if names.isEmpty {
                                onPick(type, .typeOnly)
                            } else {
                                naming = Naming(type: type, names: names)
                            }
                        } label: {
                            WristTypeTile(type: type, minHeight: 40, awaitsName: namingLater)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !types.isEmpty {
                    Button {
                        namingLater.toggle()
                    } label: {
                        WristNameLaterRow(text: namingLater ? strings.nameLaterArmed : strings.nameLater, armed: namingLater)
                    }
                    .buttonStyle(.plain)
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
    let onPick: (WristDraftName) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.timeRange(range.start, range.end))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                ForEach(names, id: \.self) { name in
                    Button {
                        onPick(.named(name))
                    } label: {
                        row(name, fill: WristColor.fill(type.colorHex), border: WristColor.border(type.colorHex))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    onPick(.typeOnly)
                } label: {
                    row(strings.justType(type.title), fill: Color(white: 0.16), border: .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                Button {
                    onPick(.later)
                } label: {
                    WristNameLaterRow(text: strings.nameLater, armed: false)
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
    /// "Name later" is armed: the tile is drawn the way the block will be,
    /// waiting for a name.
    var awaitsName = false

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
                    .strokeBorder(
                        awaitsName ? Color.white.opacity(0.9) : WristColor.border(type.colorHex),
                        style: awaitsName ? WristNameLaterRow.dash : StrokeStyle(lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "Name later": a dashed row — the outline a block waiting for a name
/// gets, here and on the phone. Armed on the type grid it reads as the
/// mode it puts the tiles in.
struct WristNameLaterRow: View {
    static let dash = StrokeStyle(lineWidth: 1.5, dash: [4, 3])

    let text: String
    let armed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: armed ? "checkmark.circle.fill" : "pencil.line")
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(armed ? Color(white: 0.26) : Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(armed ? 0.9 : 0.45), style: Self.dash)
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
    /// `WristGestureTrail`: off unless turned on here.
    @AppStorage(WristGestureTrail.enabledKey) private var gestureLog = false
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
                    Toggle(isOn: $gestureLog) {
                        Text(strings.gestureLog)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: gestureLog) { _, on in
                        // Marks where a stretch of trail begins.
                        if on { WristGestureTrail.note("log on") }
                    }
                    if gestureLog { note(strings.gestureLogNote) }

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
