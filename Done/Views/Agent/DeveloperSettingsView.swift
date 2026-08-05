//
//  DeveloperSettingsView.swift
//  Done
//
//  Developer-facing diagnostics (Settings → Developer).  Deliberately
//  English-only, like the Labs toggles — its audience is whoever is building
//  the app, not end users.  First resident: the LLM token-usage ledger (born
//  from the 2026-07 cost incident, where a runaway loop only showed up on the
//  month's bill); future dev tools should land on this page too.
//

import SwiftUI

struct DeveloperSettingsView: View {
    @State private var buckets: [LLMUsageBucket] = []
    /// Recent reports that carry clue-emission data (schema v2+), newest first
    /// — the observability the pass-1 trigger conditions read (#111 panel:
    /// candidates vs selected vs novelty-suppressed, per generation).
    @State private var clueReports: [Report] = []
    @State private var isConfirmingClear = false
    /// Regenerated on appear so what gets shared is what is on disk now.
    @State private var trailExport: URL?
    @State private var trailBytes = 0
    @State private var isConfirmingTrailClear = false

    var body: some View {
        settingsPage(L(.developer)) {
            settingsCard("Token Usage") {
                periodRow("Today", daysBack: 0)
                periodRow("Last 7 days", daysBack: 6)
                periodRow("Last 30 days", daysBack: 29)
            }

            if !clueReports.isEmpty {
                settingsCard("Report Clue Emission") {
                    ForEach(clueReports.prefix(8), id: \.id) { report in
                        settingsLabeledRow(emissionLabel(report), value: emissionValue(report))
                    }
                    settingsLabeledRow("Candidates by family", value: familyBreakdown)
                }
            }

            if last30.attempts > 0 {
                settingsCard("Last 30 Days") {
                    settingsLabeledRow("Succeeded", value: "\(last30.requests)")
                    settingsLabeledRow("Failed", value: "\(last30.failed)")
                    settingsLabeledRow("Input (cache miss)", value: formatTokens(last30.input))
                    settingsLabeledRow("Input (cache hit)", value: formatTokens(last30.cached))
                    settingsLabeledRow("Output", value: formatTokens(last30.output))
                }

                breakdownCard("By Purpose · 30 Days", groupedBy: \.purpose)
                breakdownCard("By Model · 30 Days", groupedBy: \.model)
            }

            settingsCard("Diagnostic Trail") {
                settingsLabeledRow("Retained", value: trailBytes > 0 ? formatBytes(trailBytes) : "empty")
                if let trailExport {
                    ShareLink(item: trailExport) {
                        HStack {
                            Text("Share Trail")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                settingsDestructiveButton("Clear Trail") {
                    isConfirmingTrailClear = true
                }
            }

            settingsHintCard("A write-ahead record of persistence events that outlives the process. os_log cannot be read back across a relaunch on iOS, so this is the only way to compare what the app reported before it was killed against what it loaded afterwards. Counts and IDs only — no titles or notes. Stays on this device unless you share it.")

            settingsCard {
                settingsDestructiveButton("Clear Usage Data") {
                    isConfirmingClear = true
                }
            }

            settingsHintCard("Counted from the usage block of each API response — billed tokens as the provider reports them, not estimates. Apple on-device requests are free and not counted. Data never leaves this device.")
        }
        .onAppear {
            reload()
            reloadTrail()
        }
        .onReceive(NotificationCenter.default.publisher(for: LLMUsageStore.didChange)) { _ in
            reload()
        }
        .alert("Clear usage data?", isPresented: $isConfirmingClear) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.clear), role: .destructive) {
                LLMUsageStore.shared.clearAll()
            }
        } message: {
            Text("Removes all recorded token usage. The provider's own dashboard is unaffected.")
        }
        .alert("Clear diagnostic trail?", isPresented: $isConfirmingTrailClear) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.clear), role: .destructive) {
                DiagnosticTrail.clear()
                reloadTrail()
            }
        } message: {
            Text("Discards the persistence record, including the previous run's. Do this after sharing it, not before.")
        }
    }

    private func reloadTrail() {
        trailBytes = DiagnosticTrail.retainedByteCount
        trailExport = DiagnosticTrail.exportFile()
    }

    private func formatBytes(_ count: Int) -> String {
        count < 1024 ? "\(count) B" : String(format: "%.1f KB", Double(count) / 1024)
    }

    // MARK: - Data

    private func reload() {
        buckets = LLMUsageStore.shared.allBuckets()
        clueReports = ReportStore().loadAll().filter { $0.candidateFingerprints != nil }
    }

    // MARK: - Clue emission rows

    private func emissionLabel(_ report: Report) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: report.createdAt)
    }

    private func emissionValue(_ report: Report) -> String {
        let candidates = report.candidateFingerprints?.count ?? 0
        let selected = report.clues?.count ?? 0
        let suppressed = report.noveltySuppressedCount ?? 0
        var text = "\(candidates) → \(selected)"
        if suppressed > 0 { text += " (novelty −\(suppressed))" }
        if let rating = report.ownerRating { text += " · ★\(rating)" }
        return text
    }

    /// Candidate counts per detector family across the shown reports —
    /// fingerprints encode the family as their first `|` segment.
    private var familyBreakdown: String {
        var counts: [String: Int] = [:]
        for report in clueReports.prefix(8) {
            for fingerprint in report.candidateFingerprints ?? [] {
                let family = String(fingerprint.split(separator: "|", maxSplits: 1).first ?? "?")
                counts[family, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return "—" }
        return counts.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }

    private struct Totals {
        var requests = 0
        var failed = 0
        var input = 0
        var cached = 0
        var output = 0

        var tokens: Int { input + cached + output }
        var attempts: Int { requests + failed }
    }

    private func totals(daysBack: Int) -> Totals {
        let days = LLMUsageStore.shared.dayKeys(back: daysBack)
        var result = Totals()
        for bucket in buckets where days.contains(bucket.day) {
            result.requests += bucket.requests
            result.failed += bucket.failedRequests
            result.input += bucket.inputTokens
            result.cached += bucket.cachedInputTokens
            result.output += bucket.outputTokens
        }
        return result
    }

    private var last30: Totals { totals(daysBack: 29) }

    // MARK: - Rows

    private func periodRow(_ label: String, daysBack: Int) -> some View {
        let stats = totals(daysBack: daysBack)
        let value: String
        if stats.attempts == 0 {
            value = "—"
        } else {
            value = "\(stats.requests) req"
                + (stats.failed > 0 ? " · \(stats.failed) failed" : "")
                + " · \(formatTokens(stats.tokens))"
        }
        return settingsLabeledRow(label, value: value)
    }

    /// One card listing 30-day totals grouped by a bucket field (purpose or
    /// model): a stacked composition bar of each group's token share on top,
    /// then one row per group (largest first) with its color key and share.
    private func breakdownCard(_ title: String, groupedBy key: KeyPath<LLMUsageBucket, String>) -> some View {
        let days = LLMUsageStore.shared.dayKeys(back: 29)
        var grouped: [String: Totals] = [:]
        for bucket in buckets where days.contains(bucket.day) {
            var entry = grouped[bucket[keyPath: key]] ?? Totals()
            entry.requests += bucket.requests
            entry.failed += bucket.failedRequests
            entry.input += bucket.inputTokens
            entry.cached += bucket.cachedInputTokens
            entry.output += bucket.outputTokens
            grouped[bucket[keyPath: key]] = entry
        }
        let rows = grouped.sorted { $0.value.tokens > $1.value.tokens }
        let total = max(1, rows.reduce(0) { $0 + $1.value.tokens })

        return settingsCard(title) {
            compositionBar(rows: rows, total: total)
            ForEach(Array(rows.enumerated()), id: \.element.key) { index, entry in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Self.palette(index))
                        .frame(width: 7, height: 7)
                    Text(entry.key)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(
                        "\(entry.value.requests) req · \(formatTokens(entry.value.tokens)) · \(sharePercent(entry.value.tokens, of: total))"
                            + (entry.value.failed > 0 ? " · \(entry.value.failed) failed" : "")
                    )
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
        }
    }

    /// One rounded bar, segment widths proportional to each group's tokens.
    /// Tiny groups keep a 2pt sliver so every legend dot has a visible band.
    private func compositionBar(rows: [(key: String, value: Totals)], total: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.element.key) { index, entry in
                    Rectangle()
                        .fill(Self.palette(index))
                        .frame(width: max(2, geo.size.width * CGFloat(entry.value.tokens) / CGFloat(total)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .padding(.bottom, 2)
    }

    /// Rank-ordered colors for composition segments and their legend dots —
    /// rows are sorted largest-first, so color N is "the Nth biggest spender"
    /// in both cards, not an identity assigned to a name.
    private static let compositionPalette: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .gray,
    ]

    private static func palette(_ index: Int) -> Color {
        compositionPalette[index % compositionPalette.count]
    }

    private func sharePercent(_ part: Int, of total: Int) -> String {
        let pct = Double(part) / Double(total) * 100
        return pct < 1 ? "<1%" : String(format: "%.0f%%", pct)
    }

    private func formatTokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fk", Double(count) / 1_000)
        default:
            return "\(count)"
        }
    }
}
