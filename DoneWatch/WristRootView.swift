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
                now: now, currentID: current, strings: strings
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
struct WristTodayView: View {
    let occurrences: [WristOccurrence]
    let dismissed: [WristDismissal]
    let stats: CategoryStatsPayload?
    let now: Date
    let currentID: String?
    let strings: WristStrings

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

        VStack(alignment: .leading, spacing: 2) {
            if let header = header() {
                Text(header)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
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
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(max(0, nowRow - 1), anchor: .top) }
                }
            }
        }
        .navigationTitle(strings.todayTitle)
    }

    private func header() -> String? {
        let summary = CategoryStats.summary(of: stats, period: .today, asOf: now, basis: .elapsed)
        switch summary.status {
        case .ok, .empty:
            let rate = summary.elapsedHours > 0
                ? Int((summary.totalHours / summary.elapsedHours * 100).rounded()) : nil
            return strings.dayHeader(logged: summary.totalHours, rate: rate)
        case .noData, .stale:
            return nil
        }
    }

    private func blockView(_ block: WristDayBlock) -> some View {
        let color = WristColor.color(block.occurrence.colorHex)
        let height = CGFloat(block.end.timeIntervalSince(block.start) / 3600) * hourHeight
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(block.isCurrent ? 0.95 : 0.6))
            .overlay(alignment: .topLeading) {
                if height >= 13 {
                    Text(block.occurrence.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(height >= 26 ? 2 : 1)
                        .foregroundStyle(WristColor.foreground(on: block.occurrence.colorHex))
                        .padding(.horizontal, 3)
                        .padding(.top, 1)
                }
            }
            .overlay {
                if block.isCurrent || block.occurrence.isInterrupt {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(block.isCurrent ? 0.9 : 0.5), lineWidth: 1)
                }
            }
    }
}

/// Time by category — the widget's numbers. Tap the title to switch
/// between today and this week.
struct WristStatsView: View {
    let stats: CategoryStatsPayload?
    let now: Date
    let strings: WristStrings
    @State private var period: CategoryStatsPeriod = .today

    var body: some View {
        let summary = CategoryStats.summary(of: stats, period: period, asOf: now, basis: .elapsed)
        let rows = CategoryStats.breakdown(summary.categories, maxRows: 5, unlogged: summary.unloggedHours)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    period = period == .today ? .week : .today
                } label: {
                    HStack {
                        Text(period == .today ? strings.todayTitle : strings.weekTitle)
                            .font(.headline)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if summary.status == .ok || summary.status == .empty {
                            Text(strings.duration(hours: summary.totalHours))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                switch summary.status {
                case .noData:
                    note(strings.statsNoData)
                case .stale:
                    note(strings.statsStale)
                case .empty, .ok:
                    bar(rows)
                    if summary.totalHours <= 0 { note(strings.nothingLogged) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        rowView(row)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle(strings.statsTitle)
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
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(row.isUnlogged ? .secondary : .primary)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(strings.duration(hours: row.hours))
                    .font(.caption2)
                    .monospacedDigit()
                Text(row.percentText)
                    .font(.system(size: 10))
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
        .navigationTitle(strings.appTitle)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let since = sinceLastRecord, since < 12 * 3600 {
                    Text(strings.sinceLastRecord(since))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                            Text(type.title)
                                .font(.system(.callout, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .background(
                            WristColor.color(type.colorHex),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(WristColor.foreground(on: type.colorHex))
                    }
                }
                if let age = snapshotAge, age > 24 * 3600 {
                    Text(strings.stale(age))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(strings.recordTitle)
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
        .navigationTitle(strings.recordTitle)
        .containerBackground(color.opacity(0.45).gradient, for: .navigation)
    }
}

enum WristColor {
    static func color(_ hex: String) -> Color {
        guard let rgb = components(hex) else { return .gray }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Black on light fills, white on dark ones.
    static func foreground(on hex: String) -> Color {
        guard let rgb = components(hex) else { return .white }
        let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
        return luminance > 0.6 ? .black : .white
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
