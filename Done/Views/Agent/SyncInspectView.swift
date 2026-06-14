import SwiftUI

/// Calendar-style "where does each event live, and is it in the cloud?"
/// inspector. Reachable from Data & Privacy → Sync Status → "Calendar Sync
/// Snapshot". Read-only — does not trigger syncs, just visualizes the state
/// that `SupabaseSyncService`'s in-memory hash maps already track (which
/// are persisted across launches per #30).
///
/// Layout:
///
///   ←  May 2026  →
///
///   Mo Tu We Th Fr Sa Su
///   .  .  ●  ●  ●  ●  .
///   ●  ●  ●  ●  ◐  .  .
///   ●  ⚠  ●  ●  ●  ●  .
///   ...
///
/// Each cell shows the day number and a per-day rollup dot:
///   ●  every event on that day is synced
///   ◐  at least one event on that day is pending
///   ·  no events placed on that day
///
/// Tap a day → bottom sheet with the day's events and per-event status.
/// Non-event tables (event_types / todo_lists / skill_insights /
/// user_settings) get an aggregate row at the bottom — they don't live on
/// a calendar.
struct SyncInspectView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var syncService: SupabaseSyncService
    @EnvironmentObject private var skillStore: SkillInsightStore

    // Follows the convention in `CalendarEventFormView`, `EventFormView`,
    // `CalendarInterruptComposer`: `EventTypeTemplateStore` is UserDefaults-
    // backed so multiple @StateObject instances stay in sync via the same
    // backing store. Avoids pulling in the full `AgentRuntime` env-object
    // (which would re-render this view on any unrelated agent state change).
    @StateObject private var templateStore = EventTypeTemplateStore()

    @State private var displayedMonth: Date = Self.startOfMonth(Date())
    @State private var selectedDay: SelectedDay?

    // Cached results of the expensive hash sweeps. SwiftUI re-runs `body` on
    // any @EnvironmentObject publish, but the per-event / per-table SHA256
    // work only needs to rerun when the underlying data actually changes — so
    // it's recomputed via `.task(id:)` keyed on a cheap fingerprint (record
    // counts + displayed month) instead of on every body pass. Grid and
    // tables are split so switching months doesn't redo the month-independent
    // table summaries (incl. the large skill-insights table).
    //
    // Known proxy limitation (matches the issue's accepted tradeoff): an
    // in-place edit that leaves all counts unchanged won't refresh the grid
    // dots until the next count change or month switch. The day-detail sheet
    // resolves state live on tap, so per-event truth is always one tap away.
    @State private var gridCells: [DayCell] = []
    @State private var tableSummaries: [TableSummaryEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                monthHeader
                weekdayHeader
                calendarGrid
                legend
                otherTablesSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(L(.calendarSyncSnapshot))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: gridCacheKey) { recomputeGrid() }
        .task(id: tablesCacheKey) { recomputeTables() }
        .sheet(item: $selectedDay) { day in
            DaySyncDetailSheet(day: day.date, events: events(on: day.date, using: eventsByDay))
                .environmentObject(syncService)
        }
    }

    // MARK: - Month header / nav

    private var monthHeader: some View {
        HStack {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            Spacer()
            Text(Self.monthYearFormatter.string(from: displayedMonth))
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                shift(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
            .disabled(Self.startOfMonth(Date()) <= displayedMonth)
        }
        .buttonStyle(.borderless)
    }

    private func shift(by months: Int) {
        guard let new = Calendar.current.date(byAdding: .month, value: months, to: displayedMonth) else { return }
        displayedMonth = Self.startOfMonth(new)
    }

    // MARK: - Grid

    private var weekdayHeader: some View {
        // Mon-first layout matches existing calendar code's convention.
        let labels = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        return HStack(spacing: 0) {
            ForEach(labels, id: \.self) { l in
                Text(l)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var calendarGrid: some View {
        // Cells (and their resolved sync state) come from `gridCells`, rebuilt
        // by `recomputeGrid()` only when the data fingerprint changes — not on
        // every body pass.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
            ForEach(gridCells) { cell in
                dayCell(cell)
                    .onTapGesture {
                        guard cell.inMonth, !cell.events.isEmpty else { return }
                        selectedDay = SelectedDay(date: cell.date)
                    }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: DayCell) -> some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: cell.date))")
                .font(.caption)
                .foregroundStyle(.primary)  // outer `.opacity` fades out-of-month
            statusDot(for: cell)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cell.events.isEmpty || !cell.inMonth ? Color.clear : Color.secondary.opacity(0.06))
        )
        // Keep the 36pt visual height (a 44pt grid overflows one screen on
        // smaller phones) but expand the tap target to meet the HIG ≥44pt
        // minimum: 36 + 4pt on each side ≈ 44pt of hittable height.
        .contentShape(Rectangle().inset(by: -4))
        .opacity(cell.inMonth ? 1 : 0.55)
    }

    @ViewBuilder
    private func statusDot(for cell: DayCell) -> some View {
        if let state = cell.state {
            Circle()
                .fill(color(for: state))
                .frame(width: 6, height: 6)
        } else {
            // Hidden placeholder so day numbers align vertically across
            // event-bearing and empty cells. A real dot would shift the row.
            Circle().fill(Color.clear).frame(width: 6, height: 6)
        }
    }

    private func color(for state: SupabaseSyncService.RowSyncState) -> Color {
        switch state {
        case .synced:  return .green
        case .pending: return .orange
        case .offline: return .gray
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(.green, "synced")
            legendItem(.orange, "pending")
            legendItem(.gray, "offline")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    // MARK: - Other tables summary

    private var otherTablesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other tables")
                .font(.headline)
            ForEach(tableSummaries) { entry in
                tableRow(entry.title, summary: entry.summary)
            }
        }
    }

    @ViewBuilder
    private func tableRow(_ title: String, summary: SupabaseSyncService.TableSyncSummary) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(summaryText(summary))
                .font(.caption)
                .foregroundStyle(.secondary)
            Circle()
                .fill(summaryColor(summary))
                .frame(width: 6, height: 6)
        }
    }

    private func summaryText(_ s: SupabaseSyncService.TableSyncSummary) -> String {
        switch s {
        case .empty:                                return "empty"
        case .synced(let n):                        return "\(n) synced"
        case .pending(let synced, let pending):     return "\(pending) pending · \(synced) synced"
        case .offline:                              return "offline"
        }
    }

    private func summaryColor(_ s: SupabaseSyncService.TableSyncSummary) -> Color {
        switch s {
        case .synced, .empty: return .green
        case .pending:        return .orange
        case .offline:        return .gray
        }
    }

    // MARK: - Data shaping

    /// Bucket every event by start-of-day once per render so the grid layout
    /// is O(events) instead of O(events × days). Recurring / multi-day events
    /// appear on their first occurrence's day; per-occurrence expansion is
    /// out of scope for v1.
    ///
    /// Cheap (O(events), no hashing), so it stays a computed property. The
    /// expensive per-event hash sweep that *consumes* this lives behind
    /// `recomputeGrid()` / `.task(id: gridCacheKey)`.
    private var eventsByDay: [Date: [(event: Event, kind: String)]] {
        let cal = Calendar.current
        var map: [Date: [(Event, String)]] = [:]
        for e in store.events {
            guard let s = e.timeRanges.first?.start else { continue }
            map[cal.startOfDay(for: s), default: []].append((e, "todo"))
        }
        for e in store.rawCalendarEvents {
            guard let s = e.timeRanges.first?.start else { continue }
            map[cal.startOfDay(for: s), default: []].append((e, "calendar"))
        }
        return map
    }

    private func events(on day: Date, using map: [Date: [(event: Event, kind: String)]]) -> [(event: Event, kind: String)] {
        map[Calendar.current.startOfDay(for: day)] ?? []
    }

    private func aggregateState(for events: [(event: Event, kind: String)]) -> SupabaseSyncService.RowSyncState {
        var hasPending = false
        for pair in events {
            switch syncService.syncStateForEvent(pair.event, kind: pair.kind) {
            case .offline: return .offline
            case .pending: hasPending = true
            case .synced:  break
            }
        }
        return hasPending ? .pending : .synced
    }

    // MARK: - Cached recompute

    /// Cheap fingerprint of the inputs the grid depends on. When it's
    /// unchanged, `.task(id:)` skips the per-event hash sweep entirely.
    private var gridCacheKey: String {
        "\(displayedMonth.timeIntervalSinceReferenceDate)|\(store.events.count)|\(store.rawCalendarEvents.count)"
    }

    /// Tables are month-independent, so their key omits `displayedMonth` —
    /// switching months never redoes these summaries (incl. the large
    /// skill-insights sweep).
    private var tablesCacheKey: String {
        "\(templateStore.templates.count)|\(store.todoLists.count)|\(store.calendarEventLogRecords.count)|\(store.calendarEventFeedbackRecords.count)|\(skillStore.insights.count)"
    }

    private func recomputeGrid() {
        var cells = monthCells(for: displayedMonth, eventsByDay: eventsByDay)
        for i in cells.indices where !cells[i].events.isEmpty {
            cells[i].state = aggregateState(for: cells[i].events)
        }
        gridCells = cells
    }

    private func recomputeTables() {
        tableSummaries = [
            TableSummaryEntry(title: "Event types", summary: syncService.syncSummaryForEventTypes(templateStore.templates)),
            TableSummaryEntry(title: "Todo lists", summary: syncService.syncSummaryForTodoLists(store.todoLists)),
            TableSummaryEntry(title: "Event logs", summary: syncService.syncSummaryForLogs(store.calendarEventLogRecords)),
            TableSummaryEntry(title: "Event feedback", summary: syncService.syncSummaryForFeedback(store.calendarEventFeedbackRecords)),
            TableSummaryEntry(title: "Skill insights", summary: syncService.syncSummaryForSkills(skillStore.insights)),
            TableSummaryEntry(title: "User settings", summary: syncService.syncSummaryForSettings()),
        ]
    }

    // MARK: - Grid math

    private func monthCells(for monthStart: Date, eventsByDay map: [Date: [(event: Event, kind: String)]]) -> [DayCell] {
        let cal = Calendar.current
        // Find the Monday on/before monthStart (gridStart) and lay out 6 weeks.
        let weekday = cal.component(.weekday, from: monthStart)  // 1=Sun ... 7=Sat
        // Convert to Mon-first index (0=Mon ... 6=Sun)
        let monIndex = (weekday + 5) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -monIndex, to: monthStart) else { return [] }

        var out: [DayCell] = []
        let monthIdx = cal.component(.month, from: monthStart)
        let yearIdx = cal.component(.year, from: monthStart)
        for offset in 0..<42 {
            guard let d = cal.date(byAdding: .day, value: offset, to: gridStart) else { continue }
            let inMonth = cal.component(.month, from: d) == monthIdx
                && cal.component(.year, from: d) == yearIdx
            out.append(DayCell(
                date: cal.startOfDay(for: d),
                inMonth: inMonth,
                events: inMonth ? events(on: d, using: map) : []
            ))
        }
        return out
    }

    private struct DayCell: Identifiable {
        let date: Date
        let inMonth: Bool
        let events: [(event: Event, kind: String)]
        /// Resolved per-day rollup, filled by `recomputeGrid()`. `nil` = no dot
        /// (empty / out-of-month cell).
        var state: SupabaseSyncService.RowSyncState? = nil
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    }

    private struct TableSummaryEntry: Identifiable {
        let title: String
        let summary: SupabaseSyncService.TableSyncSummary
        var id: String { title }
    }

    private struct SelectedDay: Identifiable {
        let date: Date
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: comps) ?? date
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()
}

// MARK: - Day detail sheet

private struct DaySyncDetailSheet: View {
    let day: Date
    let events: [(event: Event, kind: String)]
    @EnvironmentObject private var syncService: SupabaseSyncService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    Text("No events placed on this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events.indices, id: \.self) { i in
                        let pair = events[i]
                        eventRow(pair.event, kind: pair.kind)
                    }
                }
            }
            .navigationTitle(Self.dayFormatter.string(from: day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: Event, kind: String) -> some View {
        let state = syncService.syncStateForEvent(event, kind: kind)
        HStack(spacing: 12) {
            Circle()
                .fill(color(for: state))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "(untitled)" : event.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(secondaryText(for: event, kind: kind, state: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func secondaryText(for event: Event, kind: String, state: SupabaseSyncService.RowSyncState) -> String {
        var parts: [String] = [kind]
        if let start = event.timeRanges.first?.start {
            parts.append(Self.timeFormatter.string(from: start))
        }
        switch state {
        case .synced:  parts.append("synced")
        case .pending: parts.append("pending")
        case .offline: parts.append("offline")
        }
        return parts.joined(separator: " · ")
    }

    private func color(for state: SupabaseSyncService.RowSyncState) -> Color {
        switch state {
        case .synced:  return .green
        case .pending: return .orange
        case .offline: return .gray
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
