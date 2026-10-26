//
//  WristRootView.swift
//  DoneWatch
//
//  Three pages, swiped left and right: Record (start a type / the running
//  session), Today (the day's timeline, the default page) and Stats (time
//  by category, today or this week). The minute schedule re-resolves every
//  page at event boundaries; the running counter ticks on its own through
//  `Text(_:style: .timer)`.
//

import SwiftUI
import WatchKit

struct WristRootView: View {
    @EnvironmentObject private var client: WristSessionClient
    @State private var page = WristPage.initial
    private let housekeeping = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.everyMinute) { context in
            let strings = WristStrings(code: client.snapshot?.language)
            TabView(selection: $page) {
                NavigationStack { record(now: context.date, strings: strings) }
                    .tag(WristPage.record)
                NavigationStack { today(now: context.date, strings: strings) }
                    .tag(WristPage.today)
                NavigationStack {
                    WristStatsView(stats: client.snapshot?.stats, now: context.date, strings: strings)
                }
                .tag(WristPage.stats)
            }
            .tabViewStyle(.page)
        }
        .onReceive(housekeeping) { now in
            client.tick(now: now)
        }
    }

    @ViewBuilder
    private func record(now: Date, strings: WristStrings) -> some View {
        switch client.display(now: now) {
        case .noPhoneData:
            WristEmptyView(strings: strings)
        case .idle(let types, let since):
            WristIdleView(
                types: types,
                sinceLastRecord: since,
                snapshotAge: client.snapshot.map { now.timeIntervalSince($0.generatedAt) },
                strings: strings,
                onStart: { client.start($0) }
            )
        case .active(let occurrence, let pending):
            WristActiveView(
                occurrence: occurrence,
                pending: pending,
                strings: strings,
                onExtend: { client.extend(occurrence) },
                onFinish: { client.finish(occurrence) }
            )
        }
    }

    @ViewBuilder
    private func today(now: Date, strings: WristStrings) -> some View {
        if let snapshot = client.snapshot {
            let timeline = WristStateReducer.overlaid(snapshot, pending: client.pending, now: now).occurrences
            let current: String? = {
                if case .active(let occurrence, _) = client.display(now: now) { return occurrence.id }
                return nil
            }()
            WristTodayView(
                occurrences: timeline, dismissed: client.dismissed, stats: snapshot.stats,
                now: now, currentID: current, strings: strings, types: snapshot.types,
                onCreate: { type, start, end in client.create(type, start: start, end: end) }
            )
        } else {
            WristEmptyView(strings: strings)
        }
    }
}

enum WristPage: String, Hashable {
    case record, today, stats

    /// Today. Debug builds accept `-wristPage record|today|stats` so a
    /// paired-simulator check can open a page nothing can swipe to.
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

/// The day from midnight to midnight, one hour per `hourHeight` points,
/// scrolled to the present on open (the Digital Crown scrolls it).
///
/// Press and hold on empty time, then drag, to draw a block — the phone's
/// drag to create (`WristDraftMapping`). The page holds still while the
/// finger is down; on release a type picker names the block, and closing
/// it discards the draft.
struct WristTodayView: View {
    let occurrences: [WristOccurrence]
    let dismissed: [WristDismissal]
    let stats: CategoryStatsPayload?
    let now: Date
    let currentID: String?
    let strings: WristStrings
    var types: [WristType] = []
    var onCreate: (WristType, Date, Date) -> Void = { _, _, _ in }

    /// The press point and the drawn range, in the day's own points.
    private struct Draft: Equatable {
        var anchorY: Double
        var range: WristDraftMapping.Range
    }

    @State private var draft: Draft?
    @State private var picking = false
    /// True from the moment the hold is recognized until the finger lifts
    /// (or the system takes the touch): the page does not scroll meanwhile.
    @GestureState private var holding = false
    /// How far the day is scrolled, to turn a touch on the scroll view into
    /// a point of the day.
    @State private var scrollY: CGFloat = 0

    private let hourHeight: CGFloat = 34
    private let gutter: CGFloat = 22
    /// The watch's own zone — the one its face shows. The stats payload
    /// carries the phone's zone at its last write, which may be another.
    private var calendar: Calendar { .current }

    var body: some View {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let rows = WristDayLayout.hourRows(dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
        let height = CGFloat(dayEnd.timeIntervalSince(dayStart) / 3600) * hourHeight
        let blocks = WristDayLayout.blocks(
            occurrences, dismissed: dismissed, dayStart: dayStart, dayEnd: dayEnd, now: now, currentID: currentID
        )
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
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: gutter - 2, alignment: .leading)
                                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                            }
                            .frame(height: hourHeight, alignment: .top)
                            .id(index)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        GeometryReader { geometry in
                            let width = geometry.size.width - gutter
                            ForEach(blocks) { block in
                                blockView(block)
                                    .frame(
                                        width: max(4, width / CGFloat(block.lanes) - 2 - (block.occurrence.isInterrupt ? 6 : 0)),
                                        height: max(3, CGFloat(block.end.timeIntervalSince(block.start) / 3600) * hourHeight - 1)
                                    )
                                    .offset(
                                        x: gutter + width / CGFloat(block.lanes) * CGFloat(block.lane)
                                            + (block.occurrence.isInterrupt ? 6 : 0),
                                        y: CGFloat(WristDayLayout.fraction(block.start, dayStart: dayStart, dayEnd: dayEnd)) * height
                                    )
                            }
                            Rectangle()
                                .fill(.red)
                                .frame(width: width + 4, height: 1.5)
                                .offset(x: gutter - 4, y: nowY)
                            Circle().fill(.red).frame(width: 5, height: 5)
                                .offset(x: gutter - 6, y: nowY - 1.75)
                            if let draft {
                                draftView(draft.range)
                                    .frame(
                                        width: max(4, width - 2),
                                        height: max(3, CGFloat(draft.range.end.timeIntervalSince(draft.range.start) / 3600) * hourHeight - 1)
                                    )
                                    .offset(
                                        x: gutter,
                                        y: CGFloat(WristDayLayout.fraction(draft.range.start, dayStart: dayStart, dayEnd: dayEnd)) * height
                                    )
                            }
                        }
                    }
                    // Midnight can still scroll clear of the clock row.
                    .padding(.top, top)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in scrollY = y }
                // On the scroll view, not its content: any drag on the
                // content takes every pan from the scroll view, while one
                // here leaves it its scrolls until the hold is recognized.
                .simultaneousGesture(createGesture(mapping, blocks: blocks, top: top))
                .scrollDisabled(holding || draft != nil)
                .mask(WristEdgeFade(top: 0, bottom: 10))
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(max(0, nowRow - 1), anchor: .top) }
                }
            }
        }
        // Lifting the finger ends the drag the same way whether the gesture
        // ended or was taken away: a drawn draft goes to the picker.
        .onChange(of: holding) { _, isHolding in
            if !isHolding, draft != nil { picking = true }
        }
        .sheet(isPresented: $picking, onDismiss: { draft = nil }) {
            if let range = draft?.range {
                WristDraftTypePicker(types: types, range: range, strings: strings) { type in
                    onCreate(type, range.start, range.end)
                    picking = false
                }
            }
        }
#if DEBUG
        .onAppear { seedDebugDraft(mapping) }
#endif
    }

    /// Hold, then drag. The draft appears at the press once the hold is
    /// recognized and the first drag sample names where the finger is; each
    /// move after that sets the finger's end. A click marks every new grid
    /// mark or block edge the finger's end lands on.
    private func createGesture(_ mapping: WristDraftMapping, blocks: [WristDayBlock], top: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let dayY = { (y: CGFloat) in Double(y + scrollY - top) }
                if let current = draft {
                    let range = mapping.range(anchorY: current.anchorY, currentY: dayY(drag.location.y))
                    guard range != current.range else { return }
                    if range.moving.time != current.range.moving.time {
                        WKInterfaceDevice.current().play(.click)
                    }
                    draft?.range = range
                } else {
                    let y = dayY(drag.startLocation.y)
                    guard !picking, mapping.isEmpty(atY: y, blocks: blocks) else { return }
                    draft = Draft(anchorY: y, range: mapping.range(anchorY: y, currentY: dayY(drag.location.y)))
                    WKInterfaceDevice.current().play(.click)
                }
            }
    }

    /// The draft in the blocks' shape, neutral until it has a type: grey
    /// fill, a white border, and its range in place of a title.
    private func draftView(_ range: WristDraftMapping.Range) -> some View {
        let height = CGFloat(range.end.timeIntervalSince(range.start) / 3600) * hourHeight
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(WristColor.fill("", strength: 0.4))
            .overlay(alignment: .topLeading) {
                if height >= 13 {
                    Text(strings.timeRange(range.start, range.end))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
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

    private func blockView(_ block: WristDayBlock) -> some View {
        let hex = block.occurrence.colorHex
        let height = CGFloat(block.end.timeIntervalSince(block.start) / 3600) * hourHeight
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(WristColor.fill(hex, strength: block.isCurrent ? 0.6 : 0.4))
            .overlay(alignment: .topLeading) {
                if height >= 13 {
                    Text(block.occurrence.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(height >= 26 ? 2 : 1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.top, 1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        block.isCurrent ? .white.opacity(0.9) : WristColor.border(hex),
                        lineWidth: block.isCurrent || block.occurrence.isInterrupt ? 1 : 0.75
                    )
            }
    }
}

/// Names a drawn block: the types as the record page's tiles, under the
/// block's range. The sheet's close button discards the draft.
struct WristDraftTypePicker: View {
    let types: [WristType]
    let range: WristDraftMapping.Range
    let strings: WristStrings
    let onPick: (WristType) -> Void

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
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
                            onPick(type)
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

/// A type as the record page draws it: its name on the type color.
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
/// share logged and its hours, like the today page's.
struct WristStatsView: View {
    let stats: CategoryStatsPayload?
    let now: Date
    let strings: WristStrings
    @State private var period: WristStatsPeriod = Self.initialPeriod

    /// Today. Debug builds accept `-wristStatsPeriod today|threeDays|sevenDays|thirtyDays`,
    /// so a check can open a period without a tap.
    private static var initialPeriod: WristStatsPeriod {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-wristStatsPeriod"), i + 1 < arguments.count,
           let period = WristStatsPeriod(rawValue: arguments[i + 1]) {
            return period
        }
#endif
        return .today
    }

    var body: some View {
        let figures = WristStatsFigures.of(stats, period: period, asOf: now)
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
                            rowView(row)
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
            period = next == all.endIndex ? all[all.startIndex] : all[next]
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

    private func rowView(_ row: CategoryStatsRow) -> some View {
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
                Text(row.percentText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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

struct WristIdleView: View {
    let types: [WristType]
    let sinceLastRecord: TimeInterval?
    let snapshotAge: TimeInterval?
    let strings: WristStrings
    let onStart: (WristType) -> Void

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        WristPageFrame(header: header) { top in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if types.isEmpty {
                        Text(strings.noTypes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(types) { type in
                            Button {
                                onStart(type)
                            } label: {
                                WristTypeTile(type: type)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let age = snapshotAge, age > 24 * 3600 {
                        Text(strings.stale(age))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, top + 2)
                .padding(.horizontal, 6)
                .padding(.bottom, 18)
            }
            .mask(WristEdgeFade(top: 0, bottom: 10))
        }
    }

    /// "2h16m since last" in the clock row; nothing after half a day, when
    /// the gap is no longer news.
    private var header: Text? {
        guard let since = sinceLastRecord, since < 12 * 3600 else { return nil }
        return strings.sinceLastHeader(hours: since / 3600)
    }
}

struct WristActiveView: View {
    let occurrence: WristOccurrence
    let pending: Bool
    let strings: WristStrings
    let onExtend: () -> Void
    let onFinish: () -> Void

    private var color: Color { WristColor.color(occurrence.colorHex) }

    var body: some View {
        VStack(spacing: 4) {
            if occurrence.type != occurrence.title, !occurrence.type.isEmpty {
                Text(occurrence.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(occurrence.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(occurrence.start, style: .timer)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if !occurrence.isOpenEnded {
                Text(strings.endsAt(occurrence.end))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if occurrence.quickActionsEnabled {
                HStack(spacing: 8) {
                    Button(strings.extend, action: onExtend)
                    Button(strings.finish, action: onFinish)
                        .tint(color)
                        .handGestureShortcut(.primaryAction)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            } else {
                Text(strings.editOnPhone)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if pending {
                Text(strings.sending)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(color.opacity(0.45).gradient, for: .navigation)
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
/// hours, in grey. Nil when the stats cannot answer the period.
enum WristStatsHeader {
    static func text(_ stats: CategoryStatsPayload?, period: WristStatsPeriod, asOf: Date, strings: WristStrings) -> Text? {
        let figures = WristStatsFigures.of(stats, period: period, asOf: asOf)
        switch figures.status {
        case .ok, .empty:
            let span = Text(strings.compactDuration(hours: figures.totalHours)).foregroundStyle(.secondary)
            guard figures.elapsedHours > 0 else { return span }
            let rate = Int((figures.totalHours / figures.elapsedHours * 100).rounded())
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
