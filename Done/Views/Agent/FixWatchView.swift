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

    var body: some View {
        settingsPage("观察站") {
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
                settingsHintText("所有数据只写本机 Documents/spike-runs(JSONL,随设备备份);导出仍是 devicectl device copy from。每日 rollup 与自动窗口记录与手动 run 同池、同上限、同压实规则。")
            }
        }
        .onAppear(perform: refresh)
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
        // Shared with the settings row's attention indicator (review Q5),
        // so the two surfaces can never disagree about the same records.
        verdicts = FixWatchAttention.loadVerdicts()
        storageBytes = spikeRunsDirectoryBytes()
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
        ResidentObservationCenter.shared?.flushDaily()
        let dailies = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID)
        let windows = SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.effortPathFixID)
        return [
            FixWatchVerdictEvaluator.evaluateEffortPath(dailies: dailies, windows: windows),
            FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: dailies),
            FixWatchVerdictEvaluator.evaluateTouchDelivery(dailies: dailies),
        ]
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
