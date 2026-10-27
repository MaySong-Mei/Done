//
//  FixWatchView.swift
//  Done
//
//  FIX WATCH — 观察站 (Observatory): the verdict surface. One card per
//  registry entry, computed by the pure `FixWatchVerdictEvaluator` from
//  the collapsed daily rollups and window records on disk. This deck is
//  the named PRIMARY consumer of the resident's records — the build-order
//  rule from the 62.7M-token incident: if the deck were cut, nothing
//  would flush. It does not render every field: the per-window forensic
//  lists (wCommitMs / wFrameAfterCommitMs / wLagMs / wFrameLargestDeltasMs),
//  the censoring and probe-integrity markers, and the context stamps are
//  consumed off-device via `devicectl device copy from` on the JSONL
//  files — the same export path as manual runs. The deck shows verdicts
//  and criteria readouts; devicectl is the co-consumer for the rest.
//
//  Wording is neutral-developer by ruling (R-F10): 观察中 / 数据不足 /
//  达标 / 未达标, and a tripwire positive is a 回归警报 marker on its own
//  card — no red app-is-broken banner. Retired entries stay listed,
//  greyed (R-F11: retirement never deletes an entry or its emit sites;
//  retiring itself is a code change to the registry literal, not a
//  runtime button — a button that pretended to edit a compile-time array
//  would lie).
//
//  Reads happen on appear: ask the live resident (if any) to flush, then
//  load and evaluate. No live observation of the center — it is not an
//  ObservableObject on purpose (its signal path must never publish
//  during a view update).
//

import SwiftUI

struct FixWatchView: View {
    @State private var verdicts: [FixVerdict] = []
    @State private var storageBytes: Int = 0
    /// §16 rule 3: where the verdicts below were computed from.
    @State private var source: FixWatchSource = .localOnly
    @AppStorage(AppSettingsKeys.telemetryUploadsEnabled) private var telemetryUploadsEnabled = false
    @AppStorage(AppSettingsKeys.telemetryNoteUploadsEnabled) private var telemetryNoteUploadsEnabled = false
    /// nil under XCTest and before the app created one — the card then
    /// shows the switches without the status row, and the deck reads this
    /// device only.
    @Environment(\.telemetryUploader) private var telemetryUploader
    @State private var isPresentingTelemetrySample = false

    var body: some View {
        settingsPage("观察站") {
            telemetryCard

            settingsHintCard("Fix Watch:已合入修复的常驻观察。判定只读 Release 构建的数据;Debug 数据单独计数、永不参与判定 — 所以在 Debug 构建里,卡片会一直停在 观察中/数据不足,这是设计而非故障。逐项标准与诚实性注记见各卡片。")

            if let alarmed = verdicts.first(where: \.alarm) {
                settingsCard("回归警报") {
                    Text("\(entryTitle(alarmed.entryID)):检测到 \(alarmed.entryID == FixObservationRegistry.meTabGateFixID ? "隐藏状态下的聚合计算" : "违例")。任何正值都视为回归,详见下方卡片。")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(FixObservationRegistry.all) { entry in
                fixCard(entry)
            }

            settingsCard("Manual Spikes") {
                NavigationLink {
                    SpikeListView()
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Text("手动 Spike 列表(gh#197 harness)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard("Data") {
                settingsLabeledRow("spike-runs 占用", value: byteString(storageBytes))
                // gh#273 §8.3: "只写本机" becomes a lie the moment the
                // statistics switch is on, so the text follows the switch.
                settingsHintText(telemetryUploadsEnabled ? L(.fixWatchDataSharing) : L(.fixWatchDataLocalOnly))
            }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $isPresentingTelemetrySample) {
            if let telemetryUploader {
                TelemetrySampleSheet(uploader: telemetryUploader)
            }
        }
    }

    // MARK: Statistics (design §16 rule 1: the one entrance)

    /// The switch, its note sub-switch and the visible feedback ("did it
    /// upload, and what") — moved here from Data & Privacy so collecting the
    /// data and reading it sit on one page. The toggle is BOUND to
    /// `TelemetrySwitchEdge.apply` rather than observed: a programmatic
    /// write of the stored value (the TestFlight default) must not pass for
    /// the user's own flip.
    @ViewBuilder
    private var telemetryCard: some View {
        settingsCard(L(.telemetryCardTitle), spacing: 14) {
            Toggle(isOn: Binding(
                get: { telemetryUploadsEnabled },
                set: { newValue in
                    let oldValue = telemetryUploadsEnabled
                    telemetryUploadsEnabled = newValue
                    TelemetrySwitchEdge.apply(from: oldValue, to: newValue, defaults: .standard, now: Date(),
                                              uploader: telemetryUploader)
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.telemetryShareToggle))
                        .font(.subheadline.weight(.medium))
                    Text(L(.telemetryShareHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $telemetryNoteUploadsEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.telemetryNoteToggle))
                        .font(.subheadline.weight(.medium))
                    Text(L(.telemetryNoteHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!telemetryUploadsEnabled)
            if let telemetryUploader {
                TelemetryStatusRows(uploader: telemetryUploader, isEnabled: telemetryUploadsEnabled,
                                    isPresentingSample: $isPresentingTelemetrySample)
            }
            if !telemetryUploadsEnabled {
                settingsHintText(L(.telemetryOffRetentionHint))
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func fixCard(_ entry: FixObservationEntry) -> some View {
        let verdict = verdicts.first { $0.entryID == entry.id }
        settingsCard(entry.title) {
            HStack(spacing: 6) {
                if let verdict {
                    stateBadge(verdict)
                    if verdict.alarm {
                        badge("回归警报", color: .orange)
                    }
                }
                if entry.lifecycle == .retired {
                    badge("retired", color: .gray)
                }
                if isOverdue(entry) {
                    badge("OVERDUE", color: .orange)
                }
                Spacer()
                Text(entry.issueNumbers.map { "gh#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let verdict {
                ForEach(verdict.readouts) { readout in
                    HStack(alignment: .top) {
                        Text(readout.id)
                            .font(.caption)
                        Spacer(minLength: 8)
                        Text("\(readout.measured) · \(readout.threshold)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(readoutColor(readout))
                            .multilineTextAlignment(.trailing)
                    }
                }
                Text("Release 天数 \(verdict.releaseDayCount) · 非 Release 记录 \(verdict.nonReleaseCount)(不参与判定)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(source.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(verdict.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            settingsLabeledRow("SHAs", value: entry.mergedSHAs.joined(separator: " "))
            settingsLabeledRow("复查期限", value: entry.reviewBy)
        }
        .opacity(entry.lifecycle == .retired ? 0.55 : 1)
    }

    private func stateBadge(_ verdict: FixVerdict) -> some View {
        let (label, color): (String, Color) = {
            switch verdict.state {
            case .observing: return ("观察中", .blue)
            case .insufficient: return ("数据不足", .gray)
            case .holding: return ("达标", .green)
            case .failing: return ("未达标", .orange)
            }
        }()
        return badge(label, color: color)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func readoutColor(_ readout: FixMetricReadout) -> Color {
        switch readout.passing {
        case .some(true): return .green
        case .some(false): return .orange
        case nil: return .secondary
        }
    }

    private func entryTitle(_ id: String) -> String {
        FixObservationRegistry.entry(for: id)?.title ?? id
    }

    private func isOverdue(_ entry: FixObservationEntry) -> Bool {
        FixWatchAttention.isOverdue(entry, now: Date())
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Data

    private func refresh() {
        // This device first, at once (shared with the settings row's
        // attention indicator, review Q5); then the account's cloud rows
        // when there is a cloud to ask (§16 rule 3).
        let local = FixWatchAttention.loadLocalRecords()
        verdicts = FixWatchAttention.evaluate(dailies: local.dailies, windows: local.windows)
        source = .localOnly
        storageBytes = spikeRunsDirectoryBytes()
        guard let telemetryUploader else { return }
        Task {
            let read = await FixWatchAttention.loadObservatory(local: local, uploader: telemetryUploader, now: Date(),
                                                               localInstall: SpikeRunStore.installID())
            verdicts = read.verdicts
            source = read.source
        }
    }

    private func spikeRunsDirectoryBytes() -> Int {
        let directory = SpikeRunStorageLocation.production.directory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

// MARK: - Attention (review Q5)

/// The alarm must be visible WITHOUT opening 观察站 — a tripwire whose
/// firing can only be seen by navigating to the page it lives on is easy
/// to miss, which defeats it. The settings ROW shows an indicator whenever
/// any entry has a firing alarm or is past its review date. Both surfaces
/// (row indicator, deck) read THIS loader, so they can never disagree;
/// nothing here holds new state — every call is a passive re-read of the
/// same records the deck evaluates.
enum FixWatchAttention {
    /// Flush-then-load read barrier, exactly the deck's own: the live
    /// resident (if any) flushes today-so-far first, so the evaluator
    /// never reads a stale day.
    @MainActor
    static func loadVerdicts() -> [FixVerdict] {
        let local = loadLocalRecords()
        return evaluate(dailies: local.dailies, windows: local.windows)
    }

    /// The local half of the deck's read: flush today so far, then this
    /// device's records.
    @MainActor
    static func loadLocalRecords() -> (dailies: [SpikeRun], windows: [SpikeRun]) {
        ResidentObservationCenter.shared?.flushDaily()
        return (SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID),
                SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID))
    }

    static func evaluate(dailies: [SpikeRun], windows: [SpikeRun]) -> [FixVerdict] {
        [
            FixWatchVerdictEvaluator.evaluateEffortPath(dailies: dailies, windows: windows),
            FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: dailies),
            FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: dailies),
        ]
    }

    /// How far back the deck reads once the cloud is involved (review P1-3):
    /// recent weeks, not the account's lifetime.
    static let observatoryWindowDays = 60

    /// The first day inside the window: today minus `observatoryWindowDays`,
    /// on the device calendar, as a day key.
    static func observatorySinceDayKey(now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -observatoryWindowDays, to: today) ?? today
        return TelemetryClaimKey.dayKey(forDayStart: first, calendar: calendar).dayKey
    }

    /// The deck's cloud half in one place — the view only assigns what comes
    /// back: the window is computed ONCE and handed to both the cloud read
    /// and the merge, so the two halves always cover the same days.
    @MainActor
    static func loadObservatory(
        local: (dailies: [SpikeRun], windows: [SpikeRun]), uploader: TelemetryUploader,
        now: Date, calendar: Calendar = .current, localInstall: UUID
    ) async -> (verdicts: [FixVerdict], source: FixWatchSource) {
        let since = observatorySinceDayKey(now: now, calendar: calendar)
        let cloud = await uploader.fetchObservatoryCloudRuns(sinceDayKey: since)
        return observatory(localDailies: local.dailies, localWindows: local.windows, cloud: cloud,
                           localInstall: localInstall, sinceDayKey: since, calendar: calendar)
    }

    /// §16 rule 3, pure: the deck's verdicts and its source line from this
    /// device's records and — when there is one — this account's cloud
    /// rows. No cloud (offline, signed out, a failed read) or an empty one
    /// falls back to this device and says "this device only"; otherwise the
    /// two are merged (`TelemetryObservatoryMerge`), both halves cut to the
    /// window starting at `sinceDayKey`, and the line names how many
    /// installs the release records came from.
    static func observatory(
        localDailies: [SpikeRun], localWindows: [SpikeRun], cloud: [SpikeRun]?, localInstall: UUID,
        sinceDayKey: String, calendar: Calendar = .current
    ) -> (verdicts: [FixVerdict], source: FixWatchSource) {
        guard let cloud, !cloud.isEmpty else {
            return (evaluate(dailies: localDailies, windows: localWindows), .localOnly)
        }
        let inWindow: (SpikeRun) -> Bool = { FixWatchVerdictEvaluator.dayKey(of: $0, calendar: calendar) >= sinceDayKey }
        let merged = TelemetryObservatoryMerge.merge(local: (localDailies + localWindows).filter(inWindow),
                                                     cloud: cloud.filter(inWindow))
        let dailies = merged.filter { $0.spikeID == FixObservationRegistry.residentDailySpikeID }
        let windows = merged.filter { $0.spikeID == FixObservationRegistry.effortPathFixID }
        let installs = TelemetryObservatoryMerge.installCount(merged.filter(FixWatchVerdictEvaluator.isRelease),
                                                              localInstall: localInstall)
        return (evaluate(dailies: dailies, windows: windows), .cloud(devices: max(installs, 1)))
    }

    @MainActor
    static func needsAttention(now: Date = Date()) -> Bool {
        needsAttention(verdicts: loadVerdicts(), entries: FixObservationRegistry.all, now: now)
    }

    /// Pure half, pinned by fixture: any firing alarm, or any entry past
    /// its review date (retired entries included — an overdue retired
    /// entry is exactly the "quietly forgotten" state the date exists to
    /// surface, and the deck's own OVERDUE badge ignores lifecycle too).
    static func needsAttention(verdicts: [FixVerdict], entries: [FixObservationEntry], now: Date) -> Bool {
        verdicts.contains(where: \.alarm) || entries.contains { isOverdue($0, now: now) }
    }

    static func isOverdue(_ entry: FixObservationEntry, now: Date) -> Bool {
        // Civil-date string compare works because the format is ISO
        // year-month-day.
        entry.reviewBy < isoDayString(now)
    }

    static func isoDayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}


// MARK: - Source (design §16 rule 3)

/// Where the deck's verdicts were computed from, stated on every card.
enum FixWatchSource: Equatable {
    case localOnly
    case cloud(devices: Int)

    var label: String {
        switch self {
        case .localOnly: return L(.fixWatchSourceLocal)
        case .cloud(let devices): return String(format: L(.fixWatchSourceCloudFormat), "\(devices)")
        }
    }
}
