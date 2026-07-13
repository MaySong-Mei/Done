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
    @State private var isConfirmingClear = false

    var body: some View {
        settingsPage(L(.developer)) {
            settingsCard("Token Usage") {
                periodRow("Today", daysBack: 0)
                periodRow("Last 7 days", daysBack: 6)
                periodRow("Last 30 days", daysBack: 29)
            }

            if last30.requests > 0 {
                settingsCard("Last 30 Days") {
                    settingsLabeledRow("Requests", value: "\(last30.requests)")
                    settingsLabeledRow("Input (cache miss)", value: formatTokens(last30.input))
                    settingsLabeledRow("Input (cache hit)", value: formatTokens(last30.cached))
                    settingsLabeledRow("Output", value: formatTokens(last30.output))
                }

                breakdownCard("By Purpose · 30 Days", groupedBy: \.purpose)
                breakdownCard("By Model · 30 Days", groupedBy: \.model)
            }

            settingsCard {
                settingsDestructiveButton("Clear Usage Data") {
                    isConfirmingClear = true
                }
            }

            settingsHintCard("Counted from the usage block of each API response — billed tokens as the provider reports them, not estimates. Apple on-device requests are free and not counted. Data never leaves this device.")
        }
        .onAppear { reload() }
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
    }

    // MARK: - Data

    private func reload() {
        buckets = LLMUsageStore.shared.allBuckets()
    }

    private struct Totals {
        var requests = 0
        var input = 0
        var cached = 0
        var output = 0

        var tokens: Int { input + cached + output }
    }

    private func totals(daysBack: Int) -> Totals {
        let days = LLMUsageStore.shared.dayKeys(back: daysBack)
        var result = Totals()
        for bucket in buckets where days.contains(bucket.day) {
            result.requests += bucket.requests
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
        return settingsLabeledRow(
            label,
            value: stats.requests == 0
                ? "—"
                : "\(stats.requests) req · \(formatTokens(stats.tokens))"
        )
    }

    /// One card listing 30-day totals grouped by a bucket field (purpose or
    /// model), largest first.
    private func breakdownCard(_ title: String, groupedBy key: KeyPath<LLMUsageBucket, String>) -> some View {
        let days = LLMUsageStore.shared.dayKeys(back: 29)
        var grouped: [String: Totals] = [:]
        for bucket in buckets where days.contains(bucket.day) {
            var entry = grouped[bucket[keyPath: key]] ?? Totals()
            entry.requests += bucket.requests
            entry.input += bucket.inputTokens
            entry.cached += bucket.cachedInputTokens
            entry.output += bucket.outputTokens
            grouped[bucket[keyPath: key]] = entry
        }
        let rows = grouped.sorted { $0.value.tokens > $1.value.tokens }

        return settingsCard(title) {
            ForEach(rows, id: \.key) { name, stats in
                settingsLabeledRow(
                    name,
                    value: "\(stats.requests) req · \(formatTokens(stats.tokens))"
                )
            }
        }
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
