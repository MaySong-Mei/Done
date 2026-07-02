//
//  ReportViews.swift
//  Done
//
//  The report system's whole UI surface (Discussion #111): the dedicated Report
//  tab, the report detail destination, and the shared formatting helpers.  The
//  entry point is now a top-level tab (owner decision, superseding the earlier
//  Analysis-page card) — a report is a *destination you revisit*, not a feed you
//  scroll, so the tab pairs a single "generate" action for the current window
//  with the full back-catalogue of past reports to open.
//
//  Generation snapshots the event set and the window on the main actor before
//  entering the background async pipeline (`ReportGenerationService.generate`
//  is non-isolated, so the CPU-bound stats build stays off the main thread).
//

import SwiftUI
import MarkdownUI

// MARK: - Tab

/// The report entry point: a full-page tab that pairs the generation controls
/// for the currently selected window (period picker + generate action with
/// loading/error states) with the newest-first list of every past report.
///
/// It owns its own `AnalysisViewModel` (defaulting to the week window) purely
/// to derive `dateRange`/`periodLabel`; unlike the Analysis page it doesn't
/// swipe between offsets — the picker just reframes the current window.  The
/// enclosing `NavigationStack` is provided by `ContentView`'s tab, so this view
/// only supplies the title + destinations.
struct ReportTabView: View {
    @EnvironmentObject private var store: EventStore
    @StateObject private var viewModel = AnalysisViewModel(initialPeriod: .week)

    @State private var reports: [Report] = []
    @State private var isGenerating = false
    /// Non-nil while a failure is being shown; `errorIsNoKey` splits the
    /// "go set up a key" case (no retry) from a retryable failure.
    @State private var errorMessage: String?
    @State private var errorIsNoKey = false
    /// Set on a successful generate to push straight into the new report.
    @State private var justGenerated: Report?

    private let reportStore = ReportStore()
    private let service = ReportGenerationService()

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            reportList
        }
        .navigationTitle(L(.reportTitle))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $justGenerated) { report in
            ReportDetailView(report: report)
        }
        .onAppear { reports = reportStore.loadAll() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L(.periodPickerLabel), selection: $viewModel.period) {
                ForEach(AnalysisPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(viewModel.periodLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !errorIsNoKey {
                        Button(L(.reportRetry)) { generate() }
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            generateButton
        }
    }

    private var generateButton: some View {
        Button(action: generate) {
            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text(L(.reportGenerating))
                } else {
                    Image(systemName: "sparkles")
                    Text(L(.reportGenerate))
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .disabled(isGenerating)
    }

    // MARK: List

    private var reportList: some View {
        List {
            ForEach(reports) { report in
                NavigationLink {
                    ReportDetailView(report: report)
                } label: {
                    reportRow(report)
                }
            }
            .onDelete(perform: deleteReports)
        }
        .listStyle(.plain)
        .overlay {
            if reports.isEmpty {
                Text(L(.reportHistoryEmpty))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reportRow(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(reportGeneratedAtText(report.createdAt))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(reportProviderBadge(report.providerModel))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Text(reportFirstLine(report.prose))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: Actions

    /// Snapshots the events + window on the main actor, then runs the async
    /// pipeline off it.  Uses the same event set the Analysis charts feed on so
    /// the report and the charts elsewhere can never disagree.
    private func generate() {
        guard !isGenerating else { return }
        let events = store.canvasRenderableCalendarEvents
        let range = viewModel.dateRange
        let language = AppLanguage.current
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let report = try await service.generate(
                    events: events,
                    start: range.start,
                    end: range.end,
                    calendar: .current,
                    language: language
                )
                await MainActor.run {
                    reports = reportStore.loadAll()
                    isGenerating = false
                    justGenerated = report
                }
            } catch {
                let described = Self.describe(error)
                await MainActor.run {
                    errorMessage = described.message
                    errorIsNoKey = described.isNoKey
                    isGenerating = false
                }
            }
        }
    }

    private func deleteReports(_ offsets: IndexSet) {
        for index in offsets {
            try? reportStore.delete(id: reports[index].id)
        }
        reports.remove(atOffsets: offsets)
    }

    private static func describe(_ error: Error) -> (message: String, isNoKey: Bool) {
        if let reportError = error as? ReportGenerationError {
            if case .noAPIKey = reportError {
                return (reportError.localizedDescription, true)
            }
            // Surface a localized underlying reason when we have one (e.g. the
            // on-device model still downloading), rather than the generic
            // "couldn't generate" wrapper.
            if case .generationFailed(let underlying) = reportError,
               let localized = (underlying as? LocalizedError)?.errorDescription {
                return (localized, false)
            }
            return (reportError.localizedDescription, false)
        }
        return (error.localizedDescription, false)
    }
}

// MARK: - Detail

/// One report, in full: window + generation time, the model's markdown prose,
/// and the provider/model provenance line.
struct ReportDetailView: View {
    let report: Report

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reportPeriodText(start: report.periodStart, end: report.periodEnd))
                        .font(.headline)
                    Text(reportGeneratedAtText(report.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Markdown(report.prose)
                    .markdownTextStyle {
                        FontSize(15)
                    }

                Divider()

                Text(String(format: L(.reportGeneratedByFormat), report.providerModel))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle(L(.reportTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared formatting

/// First non-empty line of the markdown prose, with leading heading/list markup
/// stripped, for the card + history one-line preview.
private func reportFirstLine(_ prose: String) -> String {
    let markup = CharacterSet(charactersIn: "#*>-").union(.whitespaces)
    for raw in prose.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmed = raw.trimmingCharacters(in: markup)
        if !trimmed.isEmpty { return trimmed }
    }
    return prose.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The reporting window as an inclusive date range (`end` is exclusive, so the
/// last shown day is `end - 1`).
private func reportPeriodText(start: Date, end: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.current.locale
    formatter.dateStyle = .medium
    let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
    return "\(formatter.string(from: start)) – \(formatter.string(from: lastDay))"
}

private func reportGeneratedAtText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.current.locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

/// Short provider-family label for list rows ("Apple", "Claude", …), derived
/// from the stored model identifier; the detail footer keeps the full id.
private func reportProviderBadge(_ providerModel: String) -> String {
    let lower = providerModel.lowercased()
    if lower.hasPrefix("apple") { return "Apple" }
    if lower.contains("claude") { return "Claude" }
    if lower.contains("deepseek") { return "DeepSeek" }
    if lower.contains("gpt") { return "OpenAI" }
    return providerModel
}
