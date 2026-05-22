import SwiftUI

/// Modal that drives the cloud-restore flow.
/// Opens auto-fetching; the user then picks a strategy or cancels.
///
/// In `previewOnly` mode the fetch still happens, snapshot counts and sample
/// titles are shown, but the apply buttons are replaced with a "Preview only"
/// footer — nothing on the device is mutated. Used to safely verify what's
/// in the cloud before a real restore.
struct RestoreSheet: View {
    @EnvironmentObject private var coordinator: RestoreCoordinator
    @EnvironmentObject private var imageBackupCoordinator: ImageBackupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingOverwrite = false

    let previewOnly: Bool

    init(previewOnly: Bool = false) {
        self.previewOnly = previewOnly
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(previewOnly ? "Preview Cloud Backup" : "Restore from Cloud")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isApplying)
                    }
                }
        }
        .interactiveDismissDisabled(isApplying)
        .task {
            if case .idle = coordinator.phase {
                await coordinator.startFetch()
            }
        }
        .onDisappear {
            // Discard the fetched snapshot once the sheet closes, so reopening
            // forces a fresh pull.
            coordinator.reset()
        }
        .confirmationDialog(
            "Replace all local data with the cloud snapshot?",
            isPresented: $isConfirmingOverwrite,
            titleVisibility: .visible
        ) {
            Button("Replace local data", role: .destructive) {
                Task { await coordinator.applyOverwrite() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any local edits not yet synced to the cloud will be permanently lost.")
        }
    }

    private var isApplying: Bool {
        if case .applying = coordinator.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle, .fetching:
            loadingView("Fetching from cloud…")
        case .ready(let snapshot):
            readyView(snapshot)
        case .mergeReview(let snapshot, let preview):
            mergeReviewView(snapshot: snapshot, preview: preview)
        case .perRowReview(let snapshot, let preview):
            PerRowReviewView(snapshot: snapshot, preview: preview)
                .environmentObject(coordinator)
        case .applying:
            loadingView("Applying restore…")
        case .finished(let summary, let strategy, let resolution):
            finishedView(summary: summary, strategy: strategy, resolution: resolution)
        case .failed(let message):
            failedView(message: message)
        }
    }

    private func loadingView(_ label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .foregroundStyle(.secondary)
            // Surfaced specifically during the apply phase of restore when
            // the image backup coordinator is fetching cloud-stored photos.
            // Nil at all other times.
            if let progress = imageBackupCoordinator.restoreDownloadProgress {
                Text("Downloading images: \(progress.current) / \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func readyView(_ snapshot: RestoreSnapshot) -> some View {
        Form {
            Section("Found in cloud") {
                row("Calendar events", snapshot.calendarEvents.count)
                row("Todo items", snapshot.todoEvents.count)
                row("Activity logs", snapshot.logs.count)
                row("Feedback records", snapshot.feedback.count)
                row("Lists", snapshot.todoLists.count)
                row("Event types", snapshot.eventTypes.count)
                row("Skill insights", snapshot.skills.count)
            }

            // In preview mode, surface a few sample titles so the user can
            // sanity-check the fetched data without applying anything.
            if previewOnly && !snapshot.isEmpty {
                sampleSection(snapshot)
            }

            if snapshot.isEmpty {
                Section {
                    Text("No data found in the cloud for this account.")
                        .foregroundStyle(.secondary)
                    Button("Close") { dismiss() }
                }
            } else if previewOnly {
                Section {
                    Button("Done") { dismiss() }
                } header: {
                    Label("Preview only — no changes made", systemImage: "eye")
                        .textCase(nil)
                } footer: {
                    Text("This is a read-only dry run. Nothing on the device has been touched. Use \"Restore from Cloud\" if you want to actually apply the snapshot.")
                }
            } else {
                Section {
                    Button {
                        Task { await coordinator.prepareMerge() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Merge").fontWeight(.semibold)
                            Text("Add cloud rows missing locally. If the same row exists on both sides with different content, you'll be asked how to resolve.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        isConfirmingOverwrite = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud overwrites local").fontWeight(.semibold)
                            Text("Replace everything on this device with the cloud snapshot. Unsynced local changes will be lost.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Choose how to apply")
                } footer: {
                    Text("Tip: pick \"Merge\" when restoring on a device that already has data. Pick \"Cloud overwrites local\" on a fresh install or after a reset.")
                }
            }
        }
    }

    private func mergeReviewView(snapshot: RestoreSnapshot, preview: MergePreview) -> some View {
        let hasConflicts = !preview.conflicts.isEmpty
        return Form {
            Section {
                if hasConflicts {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(preview.conflicts.totalCount) row\(preview.conflicts.totalCount == 1 ? "" : "s") exist on both sides with different content.")
                        Text("**Merge always keeps your local-only rows** — only the overlapping rows are affected by your choice below. To replace local entirely (drop local-only too), cancel and pick \"Cloud overwrites local\" instead.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else {
                    Text("No content conflicts. Cloud-only rows will be added; your local-only rows stay untouched.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Per-table preview") {
                previewRow("Calendar events",
                           add: preview.addsFromCloud.calendarEvents,
                           keep: preview.keepsLocalOnly.calendarEvents,
                           conflicts: preview.conflicts.calendarEvents.count)
                previewRow("Todo items",
                           add: preview.addsFromCloud.todoEvents,
                           keep: preview.keepsLocalOnly.todoEvents,
                           conflicts: preview.conflicts.todoEvents.count)
                previewRow("Activity logs",
                           add: preview.addsFromCloud.logs,
                           keep: preview.keepsLocalOnly.logs,
                           conflicts: preview.conflicts.logs.count)
                previewRow("Feedback records",
                           add: preview.addsFromCloud.feedback,
                           keep: preview.keepsLocalOnly.feedback,
                           conflicts: preview.conflicts.feedback.count)
                previewRow("Lists",
                           add: preview.addsFromCloud.todoLists,
                           keep: preview.keepsLocalOnly.todoLists,
                           conflicts: preview.conflicts.todoLists.count)
                previewRow("Event types",
                           add: preview.addsFromCloud.eventTypes,
                           keep: preview.keepsLocalOnly.eventTypes,
                           conflicts: preview.conflicts.eventTypes.count)
                previewRow("Skill insights",
                           add: preview.addsFromCloud.skills,
                           keep: preview.keepsLocalOnly.skills,
                           conflicts: preview.conflicts.skills.count)
            }

            if hasConflicts {
                Section {
                    Button {
                        Task { await coordinator.applyMerge(resolution: .keepLocal) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keep all local versions").fontWeight(.semibold)
                            Text("On conflict, the device's version wins. Cloud-only rows are still added.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        Task { await coordinator.applyMerge(resolution: .keepCloud) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keep all cloud versions").fontWeight(.semibold)
                            Text("On conflict, the cloud version replaces the device's. Use only if you trust cloud is more up to date.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        coordinator.enterPerRowReview()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Review each individually", systemImage: "list.bullet.rectangle")
                                .fontWeight(.semibold)
                            Text("Open every conflict and pick the winner one by one. Cloud-only rows are still added regardless.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Resolve overlaps")
                }
            } else {
                Section {
                    Button {
                        Task { await coordinator.applyMerge(resolution: .keepLocal) }
                    } label: {
                        Label("Apply merge", systemImage: "checkmark.circle.fill")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    /// One row showing the three numbers for a table. Shows a check mark if
    /// all three are zero so the user can quickly scan for "nothing happens here".
    @ViewBuilder
    private func previewRow(_ title: String, add: Int, keep: Int, conflicts: Int) -> some View {
        if add == 0 && keep == 0 && conflicts == 0 {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("no change")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if conflicts > 0 {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                    }
                    Text(title).fontWeight(.medium)
                    Spacer()
                }
                HStack(spacing: 12) {
                    if add > 0 { tag("+\(add) add", color: .blue) }
                    if keep > 0 { tag("\(keep) keep", color: .secondary) }
                    if conflicts > 0 { tag("\(conflicts) conflict", color: .orange) }
                }
                .font(.footnote)
                .padding(.leading, 28)
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .monospacedDigit()
    }

    @ViewBuilder
    private func sampleSection(_ snapshot: RestoreSnapshot) -> some View {
        let calendarSample = snapshot.calendarEvents.prefix(3).map(\.title)
        let todoSample = snapshot.todoEvents.prefix(3).map(\.title)
        let listSample = snapshot.todoLists.prefix(3).map(\.title)

        Section {
            sampleRow("Calendar", titles: Array(calendarSample), total: snapshot.calendarEvents.count)
            sampleRow("Todos", titles: Array(todoSample), total: snapshot.todoEvents.count)
            sampleRow("Lists", titles: Array(listSample), total: snapshot.todoLists.count)
        } header: {
            Text("Sample entries")
        } footer: {
            Text("Showing up to 3 titles per category so you can spot-check.")
        }
    }

    @ViewBuilder
    private func sampleRow(_ category: String, titles: [String], total: Int) -> some View {
        if titles.isEmpty {
            HStack {
                Text(category).fontWeight(.medium)
                Spacer()
                Text("—").foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(category).fontWeight(.medium)
                    Spacer()
                    if total > titles.count {
                        Text("+\(total - titles.count) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                ForEach(titles, id: \.self) { title in
                    Text(title.isEmpty ? "(untitled)" : "• \(title)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func finishedView(
        summary: RestoreApplySummary,
        strategy: RestoreStrategy,
        resolution: ConflictResolution?
    ) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Restore complete").font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 6) {
                switch strategy {
                case .cloudOverwritesLocal:
                    Text("Replaced \(summary.replacedTotalCount) local records.")
                    Text("Local data now matches the cloud snapshot.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .merge:
                    if let resolution {
                        Text(resolution == .keepLocal
                             ? "Conflicts resolved: local versions kept."
                             : "Conflicts resolved: cloud versions kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    addedRow("Calendar events", summary.addedCalendarEvents)
                    addedRow("Todo items", summary.addedTodoEvents)
                    addedRow("Activity logs", summary.addedLogs)
                    addedRow("Feedback", summary.addedFeedback)
                    addedRow("Lists", summary.addedLists)
                    addedRow("Event types", summary.addedTypes)
                    addedRow("Skill insights", summary.addedSkills)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.top, 40)
        .padding(.bottom, 24)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Restore failed").font(.title3).fontWeight(.semibold)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack {
                Button("Cancel") { dismiss() }
                Button("Try again") {
                    Task {
                        coordinator.reset()
                        await coordinator.startFetch()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private func row(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func addedRow(_ title: String, _ count: Int) -> some View {
        if count > 0 {
            HStack {
                Text("• \(title)")
                Spacer()
                Text("+\(count)")
                    .foregroundStyle(.green)
                    .monospacedDigit()
            }
            .font(.callout)
        }
    }
}

// MARK: - Per-row review

/// Drill-down view for the "review each conflict individually" path. Lists
/// every conflicting row across all tables, shows the local + cloud versions
/// side-by-side, and lets the user pick a winner per row. Rows the user
/// doesn't touch default to keep-local at apply time.
private struct PerRowReviewView: View {
    let snapshot: RestoreSnapshot
    let preview: MergePreview

    @EnvironmentObject private var coordinator: RestoreCoordinator
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore

    var body: some View {
        Form {
            Section {
                let (l, c) = coordinator.perRowDecisions.counts
                Text("Tap **Local** or **Cloud** on any row to override the default. Untouched rows keep local. \(l + c)/\(preview.conflicts.totalCount) decided so far (\(l) local, \(c) cloud).")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if !preview.conflicts.calendarEvents.isEmpty {
                Section("Calendar events (\(preview.conflicts.calendarEvents.count))") {
                    ForEach(preview.conflicts.calendarEvents, id: \.self) { id in
                        if let local = store.calendarEvents.first(where: { $0.id == id }),
                           let cloud = snapshot.calendarEvents.first(where: { $0.id == id }) {
                            conflictRow(
                                titleText: local.title.isEmpty ? "(untitled event)" : local.title,
                                localContent: { eventDiffCard(local) },
                                cloudContent: { eventDiffCard(cloud) },
                                binding: coordinator.rowBinding(table: \.calendarEvents, id: id)
                            )
                        }
                    }
                }
            }

            if !preview.conflicts.todoEvents.isEmpty {
                Section("Todo items (\(preview.conflicts.todoEvents.count))") {
                    ForEach(preview.conflicts.todoEvents, id: \.self) { id in
                        if let local = store.events.first(where: { $0.id == id }),
                           let cloud = snapshot.todoEvents.first(where: { $0.id == id }) {
                            conflictRow(
                                titleText: local.title.isEmpty ? "(untitled todo)" : local.title,
                                localContent: { eventDiffCard(local) },
                                cloudContent: { eventDiffCard(cloud) },
                                binding: coordinator.rowBinding(table: \.todoEvents, id: id)
                            )
                        }
                    }
                }
            }

            if !preview.conflicts.logs.isEmpty {
                Section("Activity logs (\(preview.conflicts.logs.count))") {
                    ForEach(preview.conflicts.logs, id: \.self) { key in
                        if let local = store.calendarEventLogRecords.first(where: { $0.id == key }),
                           let cloud = snapshot.logs.first(where: { $0.id == key }) {
                            conflictRow(
                                titleText: formatOccurrenceDate(local.occurrenceDate),
                                localContent: { logDiffCard(local) },
                                cloudContent: { logDiffCard(cloud) },
                                binding: coordinator.rowBinding(table: \.logs, id: key)
                            )
                        }
                    }
                }
            }

            if !preview.conflicts.feedback.isEmpty {
                Section("Feedback records (\(preview.conflicts.feedback.count))") {
                    ForEach(preview.conflicts.feedback, id: \.self) { key in
                        if let local = store.calendarEventFeedbackRecords.first(where: { $0.id == key }),
                           let cloud = snapshot.feedback.first(where: { $0.id == key }) {
                            conflictRow(
                                titleText: formatOccurrenceDate(local.occurrenceDate),
                                localContent: { feedbackDiffCard(local) },
                                cloudContent: { feedbackDiffCard(cloud) },
                                binding: coordinator.rowBinding(table: \.feedback, id: key)
                            )
                        }
                    }
                }
            }

            if !preview.conflicts.todoLists.isEmpty {
                Section("Lists (\(preview.conflicts.todoLists.count))") {
                    ForEach(preview.conflicts.todoLists, id: \.self) { id in
                        if let local = store.todoLists.first(where: { $0.id == id }),
                           let cloud = snapshot.todoLists.first(where: { $0.id == id }) {
                            conflictRow(
                                titleText: local.title.isEmpty ? "(untitled list)" : local.title,
                                localContent: { listDiffCard(local) },
                                cloudContent: { listDiffCard(cloud) },
                                binding: coordinator.rowBinding(table: \.todoLists, id: id)
                            )
                        }
                    }
                }
            }

            if !preview.conflicts.eventTypes.isEmpty {
                Section("Event types (\(preview.conflicts.eventTypes.count))") {
                    ForEach(preview.conflicts.eventTypes, id: \.self) { cloudID in
                        // Local lookup is by normalized title, not UUID (see
                        // EventTypeTemplateStore.applyRestore for why).
                        if let cloud = snapshot.eventTypes.first(where: { $0.id == cloudID }) {
                            let normalize = EventTypeTemplateStore.normalizedTitle
                            if let local = agentRuntime.eventTypeTemplateStore.templates.first(
                                where: { normalize($0.title) == normalize(cloud.title) }
                            ) {
                                conflictRow(
                                    titleText: cloud.title.isEmpty ? "(untitled type)" : cloud.title,
                                    localContent: { typeDiffCard(local) },
                                    cloudContent: { typeDiffCard(cloud) },
                                    binding: coordinator.rowBinding(table: \.eventTypes, id: cloudID)
                                )
                            }
                        }
                    }
                }
            }

            if !preview.conflicts.skills.isEmpty {
                Section("Skill insights (\(preview.conflicts.skills.count))") {
                    ForEach(preview.conflicts.skills, id: \.self) { id in
                        if let local = skillStore.insights.first(where: { $0.id == id }),
                           let cloud = snapshot.skills.first(where: { $0.id == id }) {
                            conflictRow(
                                titleText: local.skillName.isEmpty ? "(unnamed skill)" : local.skillName,
                                localContent: { skillDiffCard(local) },
                                cloudContent: { skillDiffCard(cloud) },
                                binding: coordinator.rowBinding(table: \.skills, id: id)
                            )
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { coordinator.leavePerRowReview() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apply") {
                    Task { await coordinator.applyPerRow() }
                }
                .fontWeight(.semibold)
            }
        }
    }

    /// Shared row layout: title up top, two diff cards side by side, picker below.
    @ViewBuilder
    private func conflictRow<L: View, C: View>(
        titleText: String,
        @ViewBuilder localContent: () -> L,
        @ViewBuilder cloudContent: () -> C,
        binding: Binding<ConflictResolution>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleText)
                .font(.subheadline)
                .fontWeight(.semibold)
            HStack(alignment: .top, spacing: 8) {
                diffCardBackground(title: "Local", isSelected: binding.wrappedValue == .keepLocal) {
                    localContent()
                }
                diffCardBackground(title: "Cloud", isSelected: binding.wrappedValue == .keepCloud) {
                    cloudContent()
                }
            }
            Picker("", selection: binding) {
                Text("Keep local").tag(ConflictResolution.keepLocal)
                Text("Keep cloud").tag(ConflictResolution.keepCloud)
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func diffCardBackground<Content: View>(
        title: String,
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    // MARK: Per-table diff cards

    private func eventDiffCard(_ e: Event) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.title.isEmpty ? "(untitled)" : e.title)
                .font(.footnote).fontWeight(.medium)
                .lineLimit(1)
            if let range = e.primaryTimeRange {
                Text(formatRange(range.start, range.end))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !e.type.isEmpty {
                Text(e.type)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !e.note.isEmpty {
                Text(e.note)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func logDiffCard(_ log: CalendarEventLogRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !log.summary.isEmpty {
                Text(log.summary)
                    .font(.footnote).fontWeight(.medium)
                    .lineLimit(2)
            } else if !log.note.isEmpty {
                Text(log.note)
                    .font(.footnote)
                    .lineLimit(2)
            } else {
                Text("(no summary)")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            if let effort = log.effort {
                Text("effort \(effort)/5")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !log.emotions.isEmpty || !log.behaviors.isEmpty {
                Text("\(log.emotions.count)e / \(log.behaviors.count)b")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func feedbackDiffCard(_ f: CalendarEventFeedbackRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !f.selfNote.isEmpty {
                Text(f.selfNote)
                    .font(.footnote)
                    .lineLimit(2)
            } else {
                Text("(no note)")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            if let effort = f.effort {
                Text("effort \(effort)/5")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !f.emotions.isEmpty || !f.behaviors.isEmpty {
                Text("\(f.emotions.count)e / \(f.behaviors.count)b")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func listDiffCard(_ l: TodoList) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.title)
                .font(.footnote).fontWeight(.medium)
            Text("color: \(l.colorName)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func typeDiffCard(_ t: EventTypeTemplate) -> some View {
        HStack(spacing: 6) {
            ColorHex.toColor(t.colorHex)
                .frame(width: 14, height: 14)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title)
                    .font(.footnote).fontWeight(.medium)
                Text(t.colorHex)
                    .font(.caption2).foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer(minLength: 0)
        }
    }

    private func skillDiffCard(_ s: SkillInsight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.skillName)
                .font(.footnote).fontWeight(.medium)
            HStack(spacing: 6) {
                Text(String(format: "%.2f pts", s.points))
                Text("·")
                Text(formatOccurrenceDate(s.date))
            }
            .font(.caption2).foregroundStyle(.secondary)
            if !s.eventTitle.isEmpty {
                Text("from: \(s.eventTitle)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // `reasoning` is the field most likely to differ between local and
            // cloud (regenerated by AI per device); surface it so the diff is
            // actually comparable.
            if !s.reasoning.isEmpty {
                Text(s.reasoning)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    // MARK: Helpers

    private func formatOccurrenceDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func formatRange(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "\(f.string(from: start)) – \(DateFormatter.localizedString(from: end, dateStyle: .none, timeStyle: .short))"
    }
}
