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
    /// perf batch 2a: the follower timing readout — report-only, this device.
    @State private var followerSummary: FollowerReport.Summary?

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

            if let followerSummary {
                followerCard(followerSummary)
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
                    // Side by side when it fits; a segment-named report-only
                    // row ("iPhone16,2 · iOS 26 · tap lag p50") is usually
                    // too long for that, so it stacks instead of squeezing
                    // both halves into a ragged wrap.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            readoutName(readout)
                            Spacer(minLength: 8)
                            readoutValue(readout)
                                .multilineTextAlignment(.trailing)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            readoutName(readout)
                            readoutValue(readout)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                        }
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

    // MARK: Followers (perf batch 2a, report-only)

    /// Main-thread work that ran because a store changed, attributed per
    /// follower. Never a verdict: no badge, no threshold, no colour.
    @ViewBuilder
    private func followerCard(_ summary: FollowerReport.Summary) -> some View {
        settingsCard("Followers · report-only") {
            Text("提交之后主线程上跟着跑的工作:同步、日历缓存重建、备份快照、colorDepth 镜像、小组件 / 手表投影、图片扫描。只展示,永不参与判定;本机数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if summary.windowCount == 0 && summary.todayRows.isEmpty {
                Text("还没有数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if summary.windowCount > 0 {
                Text(followerWindowHeadline(summary))
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(summary.windowRows.prefix(8)) { row in
                    followerRow(row)
                }
            }
            if !summary.todayRows.isEmpty {
                Text("今天(前台)")
                    .font(.caption.weight(.semibold))
                ForEach(summary.todayRows.prefix(8)) { row in
                    followerRow(row)
                }
            }
        }
    }

    private func followerWindowHeadline(_ summary: FollowerReport.Summary) -> String {
        var line = "最近 \(summary.windowCount) 个自动窗口"
        if let largest = summary.largestFrameMs {
            line += String(format: " · 最大帧 %.0fms", largest)
        }
        if let inFrames = summary.inLargestFramesMs {
            line += String(format: " · 各窗口最大帧内跟随者合计 %.0fms", inFrames)
        }
        return line
    }

    private func followerRow(_ row: FollowerReport.Row) -> some View {
        var value = String(format: "%.1fms / %d 次 · 最长 %.1fms", row.totalMs, row.runs, row.maxMs)
        if let inMax = row.inMaxFrameMs {
            value += String(format: " · 最大帧内 %.1fms", inMax)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                Text(row.id).font(.caption.monospaced())
                Spacer(minLength: 8)
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.id).font(.caption.monospaced())
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
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

    private func readoutName(_ readout: FixMetricReadout) -> some View {
        Text(readout.id)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func readoutValue(_ readout: FixMetricReadout) -> some View {
        Text("\(readout.measured) · \(readout.threshold)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(readoutColor(readout))
            .fixedSize(horizontal: false, vertical: true)
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
        // This device first, at once — through the deck's own no-cloud path,
        // so it covers the same window the cloud read will; then the
        // account's cloud rows when there is a cloud to ask (§16 rule 3).
        let local = FixWatchAttention.loadLocalRecords()
        let now = Date()
        let installID = SpikeRunStore.installID()
        let segment = FixWatchSegment.thisDevice()
        let firstPaint = FixWatchAttention.observatory(
            localDailies: local.dailies, localWindows: local.windows, cloud: nil, localInstall: installID,
            sinceDayKey: FixWatchAttention.observatorySinceDayKey(now: now), currentSegment: segment)
        verdicts = firstPaint.verdicts
        source = firstPaint.source
        followerSummary = FixWatchAttention.followerSummary(local: local, now: now)
        storageBytes = spikeRunsDirectoryBytes()
        guard let telemetryUploader else { return }
        Task {
            let read = await FixWatchAttention.loadObservatory(
                local: local, readCloud: { await telemetryUploader.fetchObservatoryCloudRuns(sinceDayKey: $0) },
                now: now, localInstall: installID, currentSegment: segment)
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
/// any entry has a firing alarm or is past its review date. That indicator
/// reads THIS device's records only (`loadRowVerdicts`); the deck, once a
/// cloud read succeeds, shows this account's records merged across devices
/// (`loadObservatory`). The two can therefore disagree — ruled acceptable,
/// behaviour unchanged (§16 decision ③). Nothing here holds new state:
/// every call is a passive re-read.
enum FixWatchAttention {
    /// The settings row's read: this device's records, with the live
    /// resident's unwritten day (if any) folded over them the way collapse
    /// folds a next line — so the evaluator never reads a stale day — and
    /// NO flush. The row runs on every appear of the Settings page, pop-backs
    /// from each of its sub-pages included; when it borrowed the deck's
    /// flush-then-load barrier, every one of those appends wrote a daily line
    /// and fired a `.deckOpen` upload (red-team S2). The deck keeps its own
    /// barrier (`loadLocalRecords`).
    @MainActor
    static func loadRowVerdicts(
        currentSegment: FixWatchSegment, location: SpikeRunStorageLocation = .production
    ) -> [FixVerdict] {
        var dailies = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
        if let unwritten = ResidentObservationCenter.shared?.unwrittenDailyRecord() {
            dailies = SpikeRunLog.collapse(dailies + [unwritten])
        }
        let windows = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID, location: location)
        return evaluate(dailies: dailies, windows: windows, currentSegment: currentSegment)
    }

    /// The local half of the deck's read: flush today so far, then this
    /// device's records.
    @MainActor
    static func loadLocalRecords() -> (dailies: [SpikeRun], windows: [SpikeRun]) {
        ResidentObservationCenter.shared?.flushDaily()
        return (SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID),
                SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID))
    }

    /// `currentSegment` is the phone doing the reading — the timing
    /// criteria are judged on its records only (`FixWatchSegment`); the
    /// Me-tab tripwire reads every segment.
    static func evaluate(dailies: [SpikeRun], windows: [SpikeRun], currentSegment: FixWatchSegment) -> [FixVerdict] {
        [
            FixWatchVerdictEvaluator.evaluateEffortPath(dailies: dailies, windows: windows, currentSegment: currentSegment),
            FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: dailies),
            FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: dailies, currentSegment: currentSegment),
        ]
    }

    /// How far back the deck reads, with a cloud or without one (review
    /// P1-3; QA: one phone read 29 online and 115 offline): recent weeks,
    /// not the account's lifetime. The settings row's indicator does not
    /// use it — it reads this device's whole pool (`loadRowVerdicts`).
    static let observatoryWindowDays = 60

    /// The first day inside the window: today minus `observatoryWindowDays`,
    /// on the device calendar, as a day key.
    static func observatorySinceDayKey(now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -observatoryWindowDays, to: today) ?? today
        return TelemetryClaimKey.dayKey(forDayStart: first, calendar: calendar).dayKey
    }

    /// The deck's read in one place — the view only assigns what comes back
    /// (QA: this used to sit in the view, where only an end-to-end run could
    /// reach it). The window is computed ONCE and handed to both the cloud
    /// read and the merge, so the two halves always cover the same days.
    /// A read that answers nil (no cloud, a failed request), throws, or
    /// answers nothing leaves the deck this device's records in the same
    /// window — never empty.
    @MainActor
    static func loadObservatory(
        local: (dailies: [SpikeRun], windows: [SpikeRun]),
        readCloud: (_ sinceDayKey: String) async throws -> [SpikeRun]?,
        now: Date, calendar: Calendar = .current, localInstall: UUID, currentSegment: FixWatchSegment
    ) async -> (verdicts: [FixVerdict], source: FixWatchSource) {
        let since = observatorySinceDayKey(now: now, calendar: calendar)
        let cloud = try? await readCloud(since)
        return observatory(localDailies: local.dailies, localWindows: local.windows, cloud: cloud,
                           localInstall: localInstall, sinceDayKey: since, calendar: calendar,
                           currentSegment: currentSegment)
    }

    /// §16 rule 3, pure: the deck's verdicts and its source line from this
    /// device's records and — when there is one — this account's cloud
    /// rows, every record cut to the window starting at `sinceDayKey`. No
    /// cloud (offline, signed out, a failed read) or an empty one falls
    /// back to this device and says "this device only"; otherwise the two
    /// are merged (`TelemetryObservatoryMerge`) and the line names how many
    /// installs the release records came from. Cloud rows carry their
    /// own model and OS, so another phone's records land in their own
    /// segment, report-only beside `currentSegment`'s verdict.
    static func observatory(
        localDailies: [SpikeRun], localWindows: [SpikeRun], cloud: [SpikeRun]?, localInstall: UUID,
        sinceDayKey: String, calendar: Calendar = .current, currentSegment: FixWatchSegment
    ) -> (verdicts: [FixVerdict], source: FixWatchSource) {
        let inWindow: (SpikeRun) -> Bool = { FixWatchVerdictEvaluator.dayKey(of: $0, calendar: calendar) >= sinceDayKey }
        let dailiesHere = localDailies.filter(inWindow)
        let windowsHere = localWindows.filter(inWindow)
        guard let cloud, !cloud.isEmpty else {
            return (evaluate(dailies: dailiesHere, windows: windowsHere, currentSegment: currentSegment), .localOnly)
        }
        let merged = TelemetryObservatoryMerge.merge(local: dailiesHere + windowsHere, cloud: cloud.filter(inWindow))
        let dailies = merged.filter { $0.spikeID == FixObservationRegistry.residentDailySpikeID }
        let windows = merged.filter { $0.spikeID == FixObservationRegistry.effortPathFixID }
        let installs = TelemetryObservatoryMerge.installCount(merged.filter(FixWatchVerdictEvaluator.isRelease),
                                                              localInstall: localInstall)
        return (evaluate(dailies: dailies, windows: windows, currentSegment: currentSegment),
                .cloud(devices: max(installs, 1)))
    }

    /// perf batch 2a: the follower readout over this device's records — the
    /// windows inside the deck's window and today's daily line (the latest
    /// one for today when the day has several). Report-only; no verdict
    /// reads it.
    static func followerSummary(
        local: (dailies: [SpikeRun], windows: [SpikeRun]), now: Date, calendar: Calendar = .current
    ) -> FollowerReport.Summary {
        let since = observatorySinceDayKey(now: now, calendar: calendar)
        let today = TelemetryClaimKey.dayKey(forDayStart: calendar.startOfDay(for: now), calendar: calendar).dayKey
        let windows = local.windows.filter { FixWatchVerdictEvaluator.dayKey(of: $0, calendar: calendar) >= since }
        let todays = local.dailies
            .filter { FixWatchVerdictEvaluator.dayKey(of: $0, calendar: calendar) == today }
            .max { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
        return FollowerReport.summarize(windows: windows, today: todays)
    }

    /// The settings row's indicator: this device's records only — the deck
    /// may read otherwise once it has merged the cloud (§16 decision ③). A
    /// read: it writes nothing and triggers no upload.
    @MainActor
    static func needsAttention(now: Date = Date(), location: SpikeRunStorageLocation = .production) -> Bool {
        needsAttention(verdicts: loadRowVerdicts(currentSegment: .thisDevice(), location: location),
                       entries: FixObservationRegistry.all, now: now)
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


// MARK: - This phone's segment

extension FixWatchSegment {
    /// The segment of the phone doing the reading, from the same stamp
    /// the records it writes now are stamped with — so those always fall
    /// in it. The only device read on the verdict path; the evaluator
    /// itself takes the segment as a parameter.
    @MainActor
    static func thisDevice() -> FixWatchSegment {
        let stamp = SpikeRunContext.stamp()
        return FixWatchSegment(deviceModel: stamp.deviceModel, osVersion: stamp.osVersion)
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
