//
//  AgentSettingsView.swift
//  Done
//

import SwiftUI

func providerDisplayName(_ provider: String) -> String {
    switch provider {
    case "openai": return "OpenAI"
    case "deepseek": return "DeepSeek"
    case "claude": return "Claude"
    case "apple": return L(.providerAppleOnDevice)
    default: return provider.capitalized
    }
}

// MARK: - Settings Page Components

@ViewBuilder
func settingsCard<Content: View>(
    _ title: String? = nil,
    spacing: CGFloat = 12,
    @ViewBuilder content: () -> Content
) -> some View {
    GlassCardView(cornerRadius: 16, contentPadding: 14) {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content()
        }
        .font(.subheadline)
    }
}

/// The standalone hint card — a hint floating in its own glass card.
@ViewBuilder
func settingsHintCard(_ text: String) -> some View {
    GlassCardView(cornerRadius: 16, contentPadding: 14) {
        settingsHintText(text)
    }
}

/// The hint's caption styling, for embedding directly inside a `settingsCard`
/// (below its controls) instead of floating in a separate card.
@ViewBuilder
func settingsHintText(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
}

@ViewBuilder
func settingsDestructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(role: .destructive, action: action) {
        Text(title)
            .font(.headline)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Capsule())
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
    }
    .buttonStyle(.plain)
}

@ViewBuilder
func settingsLabeledRow(_ label: String, value: String) -> some View {
    HStack {
        Text(label)
            .foregroundStyle(.primary)
        Spacer()
        Text(value)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .animation(.default, value: value)
    }
    .font(.subheadline)
}

/// A settings row that shows a title on the left and a tappable dropdown on
/// the right (the system Settings look). The dropdown presents `options` as an
/// inline menu and reflects the current selection's title.
@ViewBuilder
func settingsPickerRow<T: Hashable>(
    _ label: String,
    selection: Binding<T>,
    options: [(value: T, title: String)],
    disabled: Bool = false
) -> some View {
    HStack {
        Text(label)
            .foregroundStyle(.primary)
        Spacer()
        Menu {
            Picker(label, selection: selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.value == selection.wrappedValue }?.title ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.primary)
        }
        .tint(.primary)
        .disabled(disabled)
    }
    .font(.subheadline)
}

/// Subtle press feedback for settings nav rows / similar full-card buttons.
/// Used in place of `.buttonStyle(.plain)` to add a gentle scale + opacity
/// dim on press so the user gets a hint that the row is reacting.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

@ViewBuilder
func settingsPage<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    ScrollView {
        VStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
}

struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @AppStorage(AppSettingsKeys.agentProvider) private var selectedProvider = AppSettingsKeys.agentProviderDefault
    @AppStorage(AppSettingsKeys.agentAPIKey) private var apiKey = ""
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.agentAskBeforeCreatingEventTypeTemplates) private var askBeforeCreatingEventTypeTemplates = true
    @AppStorage(AppSettingsKeys.tokenInferenceLLMEnabled) private var tokenInferenceLLMEnabled = false

    let showsDoneButton: Bool

    init(showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        settingsPage(L(.aiAndAgent)) {
            settingsCard(L(.status)) {
                settingsLabeledRow(L(.provider), value: providerDisplayName(selectedProvider))
                if selectedProvider != "apple" {
                    settingsLabeledRow(L(.apiKey), value: apiKey.isEmpty ? L(.missing) : L(.configured))
                }
                settingsLabeledRow(L(.learnedRulesLabel), value: "\(agentRuntime.preferenceStore.listRules().count)")
            }

            settingsCard(L(.provider)) {
                Picker(L(.llmProvider), selection: $selectedProvider) {
                    Text("Claude").tag("claude")
                    Text("OpenAI").tag("openai")
                    Text("DeepSeek").tag("deepseek")
                    Text(L(.providerAppleOnDevice)).tag("apple")
                }
                .pickerStyle(.segmented)
            }

            if selectedProvider != "apple" {
                settingsCard(L(.apiKey)) {
                    SecureField(L(.enterApiKey), text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if apiKey.isEmpty {
                        Label(L(.notConfigured), systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Label("\(L(.keySaved)) (\(apiKey.prefix(8))...)", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            settingsHintCard(providerHint)

            settingsCard(L(.behavior)) {
                Toggle(L(.aiTypeSuggestionsAfterSave), isOn: $calendarAgenticCreateEnabled)
                Toggle(L(.askBeforeCreatingTemplates), isOn: $askBeforeCreatingEventTypeTemplates)
                Toggle(L(.tokenInferenceEngineToggle), isOn: $tokenInferenceLLMEnabled)
            }

            settingsHintCard(L(.hintTypeSuggestions))

            if tokenInferenceLLMEnabled {
                settingsHintCard(L(.hintTokenInferenceEngine))
            }

            settingsCard(L(.learning)) {
                if agentRuntime.preferenceStore.listRules().isEmpty {
                    Text(L(.noLearnedPreferences))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(agentRuntime.preferenceStore.listRules().prefix(8))) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ruleRowTitle(rule))
                                .font(.caption.weight(.semibold))
                            Text(ruleRowSubtitle(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                settingsDestructiveButton(L(.clearLearnedPreferences)) {
                    agentRuntime.preferenceStore.clearRules()
                }

                settingsDestructiveButton(L(.clearDecisionHistory)) {
                    agentRuntime.preferenceStore.clearDecisionHistory()
                }
            }

            settingsHintCard(L(.hintLearning))
        }
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var providerHint: String {
        switch selectedProvider {
        case "claude": return L(.hintApiKeyClaude)
        case "openai": return L(.hintApiKeyOpenAI)
        case "deepseek": return L(.hintApiKeyDeepSeek)
        case "apple": return L(.hintProviderApple)
        default: return ""
        }
    }

    private func ruleRowTitle(_ rule: AgentPreferenceRule) -> String {
        let trigger = rule.triggerPattern.value
        switch rule.preferredAction.kind {
        case .createTypeTemplate:
            return "\"\(trigger)\" -> prefer create template"
        case .keepTypeOnly:
            return "\"\(trigger)\" -> prefer keep type only"
        case .useExistingType:
            return "\"\(trigger)\" -> use \(rule.preferredAction.value ?? "existing type")"
        case .customInstruction:
            return "\"\(trigger)\" -> custom instruction"
        }
    }

    private func ruleRowSubtitle(_ rule: AgentPreferenceRule) -> String {
        let fmt = RelativeDateTimeFormatter()
        let time = fmt.localizedString(for: rule.lastUsedAt, relativeTo: Date())
        var suffix = "Evidence \(rule.evidenceCount) • \(time)"
        if rule.preferredAction.kind == .customInstruction, let text = rule.preferredAction.value, !text.isEmpty {
            let snippet = String(text.prefix(48))
            suffix += " • \(snippet)\(text.count > 48 ? "…" : "")"
        }
        return suffix
    }
}

struct SettingsHomeView: View {
    @EnvironmentObject private var syncService: SupabaseSyncService
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var authService: AuthService
    // Only the System Status card reads settings values directly now; the
    // per-row summaries were removed, so the rest of the @AppStorage mirrors
    // they relied on are gone too.
    @AppStorage(AppSettingsKeys.agentProvider) private var selectedProvider = AppSettingsKeys.agentProviderDefault
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    /// Review Q5 — display cache only; recomputed on every appear (which
    /// includes navigation pops back to this page) from the deck's own
    /// evaluator output.
    @State private var fixWatchNeedsAttention = false
    /// gh#273 §8.3: the storage hint below reads differently while
    /// statistics are shared.
    @AppStorage(AppSettingsKeys.telemetryUploadsEnabled) private var telemetryUploadsEnabled = false

    var body: some View {
        settingsPage(L(.settings)) {
            meCard

            settingsCard(spacing: 14) {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsLinkRow(title: L(.general))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    CalendarHeaderSettingsView()
                } label: {
                    settingsLinkRow(title: L(.tabCalendar))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    CalendarRecurringSeriesListView()
                        .environmentObject(store)
                } label: {
                    settingsLinkRow(title: L(.recurringEventsTitle))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    HolidaysSettingsView()
                        .environmentObject(store)
                } label: {
                    settingsLinkRow(title: L(.holidaysAndTerms))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    WorkflowSettingsView()
                } label: {
                    settingsLinkRow(title: L(.recordingAndWorkflow))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    PeopleSettingsView()
                        .environmentObject(store)
                } label: {
                    settingsLinkRow(title: L(.peopleAndGroups))
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard(spacing: 14) {
                NavigationLink {
                    AgentSettingsView()
                        .environmentObject(agentRuntime)
                } label: {
                    settingsLinkRow(title: L(.aiAndAgent))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    AnalysisPreferencesView()
                } label: {
                    settingsLinkRow(title: L(.analysisPreferences))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    WatchSettingsView()
                        .environmentObject(store)
                } label: {
                    settingsLinkRow(title: L(.watchSettings))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    ConnectionsView()
                        .environmentObject(authService)
                } label: {
                    settingsLinkRow(title: L(.connections))
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard(spacing: 14) {
                // FIX WATCH (R-F10): 观察站 sits top-level — the verdict
                // deck for merged fixes under observation, with the manual
                // Spikes list as its child page. It deliberately does NOT
                // live under Experimental: it watches SHIPPED fixes, not
                // candidate features.
                //
                // Review Q5: a firing tripwire alarm (or an overdue review
                // date) shows HERE, on the row, so it cannot hide behind a
                // page nobody opens. Passive read of the same evaluator
                // output the deck renders — no new state in the resident.
                NavigationLink {
                    FixWatchView()
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Text("观察站")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if fixWatchNeedsAttention {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("回归警报或已到复查期限")
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    ExperimentalSettingsView()
                } label: {
                    settingsLinkRow(title: L(.experimental))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    DeveloperSettingsView()
                } label: {
                    settingsLinkRow(title: L(.developer))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    DataPrivacySettingsView()
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .environmentObject(skillStore)
                        .environmentObject(authService)
                } label: {
                    settingsLinkRow(title: L(.dataAndPrivacy))
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard(L(.systemStatus)) {
                statusRow(label: L(.providerLabel), value: providerDisplayName(selectedProvider))
                statusRow(label: L(.typeSuggestions), value: calendarAgenticCreateEnabled ? L(.on) : L(.off))
                statusRow(label: L(.learnedRulesLabel), value: "\(agentRuntime.preferenceStore.listRules().count)")
                statusRow(label: L(.insightsStored), value: "\(skillStore.insights.count)")
            }

            settingsCard(L(.storage)) {
                Text(TelemetrySettingsCopy.localDataHint(sharing: telemetryUploadsEnabled))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            fixWatchNeedsAttention = FixWatchAttention.needsAttention()
        }
    }

    @ViewBuilder
    private var meCard: some View {
        settingsCard {
            NavigationLink {
                AccountView()
                    .environmentObject(authService)
                    .environmentObject(store)
                    .environmentObject(agentRuntime)
                    .environmentObject(skillStore)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authService.session?.user.email ?? L(.tabMe))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        // gh#234: same persisted flag as the card on the
                        // account page. Without it the Me tab reads exactly
                        // like a device that was never signed in.
                        let endedBySrv = !authService.isSignedIn && authService.needsReauthentication
                        // Erased on another device is its own sentence, not
                        // "sign-in expired" (sim QA S6; design §10.7).
                        let accountGone = !authService.isSignedIn && syncService.accountCheck.isAccountGone
                        Text(accountGone ? L(.meAccountGone)
                                         : endedBySrv ? L(.meSessionEnded)
                                         : (authService.isSignedIn ? L(.meSyncAccount) : L(.meSignInToSync)))
                            .font(.subheadline)
                            .foregroundStyle(endedBySrv || accountGone ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
        }
    }

    @ViewBuilder
    private func settingsLinkRow(title: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: value)
        }
        .font(.subheadline)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppSettingsKeys.rememberLastTab) private var rememberLastTab = true
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.calendar.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @AppStorage(AppSettingsLocale.languageKey) private var languageRaw = AppLanguage.english.rawValue
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormatRaw = AppTimeFormat.twentyFour.rawValue
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    var body: some View {
        settingsPage(L(.general)) {
            settingsCard(L(.preferences)) {
                settingsPickerRow(
                    L(.language),
                    selection: $languageRaw,
                    options: AppLanguage.allCases.map { ($0.rawValue, $0.displayName) }
                )

                settingsPickerRow(
                    L(.timeFormat),
                    selection: $timeFormatRaw,
                    options: AppTimeFormat.allCases.map { ($0.rawValue, $0.displayName) }
                )

                settingsPickerRow(
                    L(.appearance),
                    selection: $appearanceModeRaw,
                    options: AppAppearanceMode.allCases.map { ($0.rawValue, L($0.titleKey)) }
                )
            }

            settingsCard(L(.launch)) {
                Toggle(L(.rememberLastTab), isOn: $rememberLastTab)

                settingsPickerRow(
                    L(.defaultTab),
                    selection: $defaultTabRawValue,
                    // Wanna tab is temporarily removed — don't offer it as a default.
                    options: RootTab.allCases.filter { $0 != .wanna }.map { ($0.rawValue, L($0.titleKey)) },
                    disabled: rememberLastTab
                )

                settingsHintText(L(.hintDefaultTab))
            }

            settingsCard(L(.interface)) {
                Toggle(L(.showTimerBanner), isOn: $showTimerBanner)
            }
        }
    }
}

struct WorkflowSettingsView: View {
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = false
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.effortOpacityEnabled) private var effortOpacityEnabled = true

    var body: some View {
        settingsPage(L(.recordingAndWorkflow)) {
            settingsCard(L(.workflow)) {
                Toggle(L(.landscapeFocusMode), isOn: $landscapeFocusModeEnabled)
                Toggle(L(.landscapeFocusKeepAwake), isOn: $landscapeFocusKeepAwakeEnabled)
                Toggle(L(.enableAiTypeSuggestions), isOn: $calendarAgenticCreateEnabled)
                Toggle(L(.effortBasedEventOpacity), isOn: $effortOpacityEnabled)

                settingsHintText(L(.hintLandscapeAndAgent))
                settingsHintText(L(.hintEffortBasedEventOpacity))
            }
        }
    }
}

struct AnalysisPreferencesView: View {
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false

    var body: some View {
        settingsPage(L(.analysisPreferences)) {
            settingsCard(L(.defaults)) {
                Picker(L(.analysisPeriod), selection: $defaultPeriodRawValue) {
                    ForEach(AnalysisPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)

                Toggle(L(.autoLoadSuggestions), isOn: $autoLoadSuggestions)
            }

            settingsHintCard(L(.hintAnalysisPeriod))
        }
    }
}

struct ExperimentalSettingsView: View {
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var multiTypeEnabled = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeMaxCount) private var multiTypeMaxCount = 2
    @AppStorage(AppSettingsKeys.calendarUseCALayerAxisMarkers) private var calayerAxisMarkers = true

    var body: some View {
        settingsPage(L(.experimental)) {
            settingsHintCard(L(.hintLabsFeatures))

            settingsCard(L(.multiTypeEvents)) {
                Toggle(L(.enableMultiTypeEvents), isOn: $multiTypeEnabled)

                if multiTypeEnabled {
                    Stepper(value: $multiTypeMaxCount, in: 2...4) {
                        HStack {
                            Text(L(.maxTypesPerEvent))
                            Spacer()
                            Text("\(multiTypeMaxCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(multiTypeMaxCount)))
                                .animation(.snappy(duration: 0.18), value: multiTypeMaxCount)
                        }
                    }
                }
            }

            settingsHintCard(L(.hintMultiTypeEvents))

            // Issue #60: CALayer-backed port of the calendar time axis
            // (hour labels + now-time legend + drag pills + extension
            // band fade). Strictly parity-first; the SwiftUI path stays
            // the default until A/B verification settles.
            settingsCard("CALayer Time Axis") {
                Toggle("Use CALayer time axis", isOn: $calayerAxisMarkers)
                Text("Experimental: render the calendar's time axis (hour labels, current-time legend, drag-preview pills) through CALayer instead of SwiftUI. Strict parity, no design changes. Default off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: multiTypeMaxCount) { _, newValue in
            if newValue < 2 {
                multiTypeMaxCount = 2
            } else if newValue > 4 {
                multiTypeMaxCount = 4
            }
        }
    }
}

struct DataPrivacySettingsView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var restoreCoordinator: RestoreCoordinator
    @EnvironmentObject private var imageBackupCoordinator: ImageBackupCoordinator
    @EnvironmentObject private var backupSnapshotService: BackupSnapshotService
    @EnvironmentObject private var syncStatusReporter: SyncStatusReporter
    @EnvironmentObject private var syncService: SupabaseSyncService
    /// For `resetAllLocalData()`: two of the keys the sweep removes live in
    /// this object's memory as well as on disk. Supplied by `ContentView`'s
    /// `.environmentObject(calendarState)`, the same source every other
    /// object on this view comes from.
    @EnvironmentObject private var calendarState: CalendarViewState
    @AppStorage(AppSettingsKeys.syncUploadsEnabled) private var syncUploadsEnabled = true
    /// gh#273 design §8.2: default OFF, per device, independent of the sync
    /// switch above. OFF → ON records the consent watermark.
    @AppStorage(AppSettingsKeys.telemetryUploadsEnabled) private var telemetryUploadsEnabled = false
    @AppStorage(AppSettingsKeys.telemetryNoteUploadsEnabled) private var telemetryNoteUploadsEnabled = false
    /// nil under XCTest and before the app created one — the card then
    /// shows the switches without the status row.
    @Environment(\.telemetryUploader) private var telemetryUploader
    @State private var isConfirmingSkillClear = false
    @State private var isConfirmingInferenceClear = false
    @State private var isConfirmingResetAll = false
    @State private var isWarningBeforeErase = false
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingRestoreSheet = false
    @State private var isPresentingPreviewSheet = false
    @State private var isPresentingTelemetrySample = false
    /// Design §10.7 (b): opened from the "this account no longer exists"
    /// prompt with the reset confirmation already up, so "Erase this phone"
    /// is the one existing erase and nothing else.
    private let armResetConfirmation: Bool

    init(armResetConfirmation: Bool = false) {
        self.armResetConfirmation = armResetConfirmation
    }

    var body: some View {
        settingsPage(L(.dataAndPrivacy)) {
            settingsCard(L(.privacy)) {
                Text(TelemetrySettingsCopy.localDataHint(sharing: telemetryUploadsEnabled))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // gh#273 design §8.2 / §8.3: the statistics switch, its note
            // sub-switch, and the visible feedback that answers "did it
            // upload, and what" — the sample sheet shows a formatted copy
            // of the same redacted content the most recent ATTEMPT sent
            // (review P2-5: same rows after the Redactor, not the wire bytes).
            settingsCard(L(.telemetryCardTitle), spacing: 14) {
                Toggle(isOn: $telemetryUploadsEnabled) {
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

            settingsCard("Sync", spacing: 14) {
                Toggle(isOn: $syncUploadsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L(.uploadToCloud))
                            .font(.subheadline.weight(.medium))
                        Text(L(.uploadToCloudHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #if DEBUG
                Text("Debug build: uploads to production are blocked regardless of this toggle, as an extra safety net. On the local stack or staging, uploads follow this toggle.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }

            settingsCard("Cloud Backup", spacing: 14) {
                Button {
                    isPresentingPreviewSheet = true
                } label: {
                    backupActionRow(
                        title: "Preview Cloud Backup",
                        summary: "Read-only fetch — verify what's in the cloud without changing the device",
                        icon: "eye"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
                .disabled(!restoreCoordinator.isConfigured)

                Button {
                    isPresentingRestoreSheet = true
                } label: {
                    backupActionRow(
                        title: "Restore from Cloud",
                        summary: "Apply the cloud snapshot — you'll pick merge vs replace",
                        icon: "icloud.and.arrow.down"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
                .disabled(!restoreCoordinator.isConfigured)
            }

            settingsCard("Sync Status", spacing: 14) {
                // Wrap in a TimelineView so the "X sec ago" relative strings
                // actually tick over time, not just on the next sync event.
                // 30s cadence keeps the resolution honest without burning CPU.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        syncStatusRow(
                            title: "Structured data",
                            status: syncStatusReporter.structured,
                            now: context.date
                        )
                        syncStatusRow(
                            title: "Images",
                            status: syncStatusReporter.images,
                            now: context.date
                        )
                        syncStatusRow(
                            title: "Local snapshot",
                            status: syncStatusReporter.snapshot,
                            now: context.date
                        )
                    }
                }
                // Without this hint the card looks broken when the toggle is
                // off — three idle rows with no obvious reason. Surface the
                // gate state directly so the user can connect cause and effect.
                if !syncUploadsEnabled {
                    Text(L(.uploadsOffHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NavigationLink {
                    SyncInspectView()
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundStyle(Color.accentColor)
                        Text(L(.calendarSyncSnapshot))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            settingsCard(L(.manageData)) {
                settingsDestructiveButton(L(.clearSkillInsights)) {
                    isConfirmingSkillClear = true
                }

                settingsDestructiveButton(L(.clearTokenCache)) {
                    isConfirmingInferenceClear = true
                }

                settingsDestructiveButton(L(.resetAllData)) {
                    isConfirmingResetAll = true
                }
            }
        }
        .sheet(isPresented: $isPresentingRestoreSheet) {
            RestoreSheet()
                .environmentObject(restoreCoordinator)
                .environmentObject(imageBackupCoordinator)
        }
        .sheet(isPresented: $isPresentingPreviewSheet) {
            RestoreSheet(previewOnly: true)
                .environmentObject(restoreCoordinator)
                .environmentObject(imageBackupCoordinator)
        }
        .sheet(isPresented: $isPresentingTelemetrySample) {
            if let telemetryUploader {
                TelemetrySampleSheet(uploader: telemetryUploader)
            }
        }
        .onChange(of: telemetryUploadsEnabled) { oldValue, newValue in
            // OFF → ON is the consent moment (design §8.2): the watermark is
            // written HERE and only here (review P2-4), even when no uploader
            // exists, so a later one cannot read "consented" as "consented
            // since forever". ON → OFF withdraws the note sub-consent with it
            // (Q5): the sub-switch is not left armed for the next ON.
            if !oldValue, newValue {
                TelemetryConsentStore.recordGrant(UserDefaults.standard, at: Date())
            } else if oldValue, !newValue {
                telemetryNoteUploadsEnabled = false
            }
            telemetryUploader?.switchDidChange(from: oldValue, to: newValue)
        }
        .onChange(of: syncUploadsEnabled) { oldValue, newValue in
            // OFF → ON: catch the cloud up with everything that accumulated
            // while uploads were paused. Triggers a full structured-data
            // sync and clears the image-suppression cache so previously
            // skipped images get re-evaluated.
            // ON → OFF: the switch gates both directions (D9) — the
            // puller stops as well.
            if oldValue, !newValue {
                syncService.userDidDisableUploads()
                return
            }
            guard !oldValue, newValue else { return }
            syncService.userDidEnableUploads()
            imageBackupCoordinator.userDidEnableUploads()
        }
        .alert(L(.alertClearSkillInsights), isPresented: $isConfirmingSkillClear) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.clear), role: .destructive) {
                skillStore.clearAll()
            }
        } message: {
            Text(L(.hintClearSkillInsights))
        }
        .alert(L(.alertClearTokenCache), isPresented: $isConfirmingInferenceClear) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.clear), role: .destructive) {
                TokenInferenceRepository.shared.clearAll()
            }
        } message: {
            Text(L(.hintClearTokenCache))
        }
        .alert(L(.alertResetAllData), isPresented: $isConfirmingResetAll) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.reset), role: .destructive) {
                // Design §6.6 擦除前的警告: offers the user has not decided
                // block the erase until they confirm losing them.
                if syncService.hasUndecidedOffers {
                    isWarningBeforeErase = true
                } else {
                    resetAllLocalData()
                    closeAfterArmedReset()
                }
            }
        } message: {
            Text(L(.hintResetAllData))
        }
        .onAppear {
            if armResetConfirmation { isConfirmingResetAll = true }
        }
        .syncUndecidedOffersWarning(isPresented: $isWarningBeforeErase, count: syncService.pendingPromptCount,
                                    action: .erase, syncService: syncService) {
            resetAllLocalData()
            closeAfterArmedReset()
        }
    }

    /// Opened by "Erase this phone" (`armResetConfirmation`, design §10.7):
    /// the sheet exists for the reset alone, so once it ran the sheet goes
    /// (sim QA: it stayed open over the erased data).
    private func closeAfterArmedReset() {
        if armResetConfirmation { dismiss() }
    }

    private func resetAllLocalData() {
        LocalDataEraser(store: store, skillStore: skillStore, agentRuntime: agentRuntime, authService: authService,
                        calendarState: calendarState, syncService: syncService,
                        imageBackupCoordinator: imageBackupCoordinator, backupSnapshotService: backupSnapshotService,
                        telemetryUploader: telemetryUploader)
            .resetAllLocalData(keepingSession: false)
    }

    @ViewBuilder
    private func syncStatusRow(title: String, status: SyncChannelStatus, now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(syncStatusSubtitle(status, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if status.isActive {
                ProgressView()
                    .controlSize(.small)
            } else if status.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if status.lastCompletedAt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private func syncStatusSubtitle(_ status: SyncChannelStatus, now: Date) -> String {
        if status.isActive {
            return status.detail.map { "Syncing… \($0)" } ?? "Syncing…"
        }
        if let error = status.lastError {
            return "Error: \(error)"
        }
        guard let when = status.lastCompletedAt else {
            return "Not yet this session"
        }
        let stamp = Self.relativeFormatter.localizedString(for: when, relativeTo: now)
        if let detail = status.detail, !detail.isEmpty {
            return "\(detail) · \(stamp)"
        }
        return stamp
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Inline row layout for the cloud-backup action buttons. Matches the
    /// glass-card look of `settingsLinkRow` (used elsewhere in this file for
    /// NavigationLinks) without the trailing chevron — these are sheet-
    /// presenting actions, not navigations, so a chevron would mislead.
    private func backupActionRow(title: String, summary: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Telemetry copy and status (gh#273 design §8.3)

/// The two existing "data stays on this device" hints, chosen by the
/// statistics switch: with it on, the sentence would be a lie (B·F30).
enum TelemetrySettingsCopy {
    static func localDataHint(sharing: Bool) -> String {
        sharing ? L(.hintLocalDataSharing) : L(.hintLocalData)
    }

    static func statusLine(uploader: TelemetryUploader, now: Date) -> String {
        guard let lastUploadAt = uploader.lastUploadAt else { return L(.telemetryStatusNever) }
        let when = RelativeDateTimeFormatter.telemetryShort.localizedString(for: lastUploadAt, relativeTo: now)
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        return String(format: L(.telemetryStatusFormat), when, "\(uploader.lastBatchCount)", "\(uploader.totalAcknowledged)", build)
    }

    /// What the most recent attempt concluded, for EVERY outcome (review
    /// P2-2): the manual button is the device checklist's probe, and
    /// "nothing to send" must read differently from "stopped at a gate".
    /// nil for a plain success — the status line above already says it.
    static func outcomeLine(_ outcome: TelemetryUploadOutcome?) -> String? {
        switch outcome {
        case nil, .uploaded?: return nil
        case .switchOff?: return L(.telemetryOutcomeSwitchOff)
        case .notAttached?: return L(.telemetryOutcomeNotAttached)
        case .blockedByBuild?: return L(.telemetryOutcomeBlockedByBuild)
        case .noConsent?: return L(.telemetryOutcomeNoConsent)
        case .signedOut?: return L(.telemetryOutcomeSignedOut)
        case .nothingPending?: return L(.telemetryOutcomeNothingPending)
        case .staleAfterErase?: return L(.telemetryOutcomeStale)
        case .partial(let uploaded, let quarantined)?:
            return String(format: L(.telemetryOutcomePartialFormat), "\(uploaded)", "\(quarantined)")
        case .failed(let kind, let code)?:
            return String(format: L(.telemetryLastFailureFormat), "\(kind) \(code)")
        }
    }

    /// Rows the server refused and the cursor parked, when any.
    static func quarantinedLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return String(format: L(.telemetryQuarantinedFormat), "\(count)")
    }

    /// A failed or partial attempt is shown in orange; a gate or an empty
    /// run in the secondary colour.
    static func outcomeIsWarning(_ outcome: TelemetryUploadOutcome?) -> Bool {
        switch outcome {
        case .failed?, .partial?, .staleAfterErase?: return true
        default: return false
        }
    }
}

private extension RelativeDateTimeFormatter {
    static let telemetryShort: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// "上次上传 · 条数 · 累计 · 构建", the sample button and the manual
/// upload button — the visible feedback B·F29 demanded. Observes the
/// uploader directly so the row updates when a batch lands.
struct TelemetryStatusRows: View {
    @ObservedObject var uploader: TelemetryUploader
    /// The main switch: with it off the manual button is disabled (review
    /// P2-2) — a tap would only report `.switchOff`.
    let isEnabled: Bool
    @Binding var isPresentingSample: Bool
    @State private var isUploading = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(TelemetrySettingsCopy.statusLine(uploader: uploader, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let outcome = TelemetrySettingsCopy.outcomeLine(uploader.lastOutcome) {
                    Text(outcome)
                        .font(.caption)
                        .foregroundStyle(TelemetrySettingsCopy.outcomeIsWarning(uploader.lastOutcome) ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let parked = TelemetrySettingsCopy.quarantinedLine(count: uploader.quarantinedCount) {
                    Text(parked)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        HStack(spacing: 12) {
            Button {
                isPresentingSample = true
            } label: {
                Text(L(.telemetryViewSample))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                guard !isUploading else { return }
                isUploading = true
                Task {
                    await uploader.uploadNow(trigger: .deckOpen)
                    isUploading = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isUploading {
                        ProgressView().controlSize(.small)
                    }
                    Text(L(.telemetryUploadNow))
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isUploading || !isEnabled)
        }
    }
}

/// The most recent attempt's request content: a pretty-printed copy of
/// the same redacted rows (review P2-5 — the wire carries them compact and
/// unordered; the content is identical, the bytes are not).
struct TelemetrySampleSheet: View {
    @ObservedObject var uploader: TelemetryUploader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(uploader.lastRequestBodyPreview ?? L(.telemetrySampleEmpty))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(L(.telemetrySampleTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.ok)) { dismiss() }
                }
            }
        }
    }
}

/// The one local erase ("Reset all local data", design §6.4 擦除接线). Data &
/// Privacy runs it signed out; the account card's "switch to this account"
/// (gh#257: data belongs to its account) runs it keeping the session it is
/// switching to and then starts sync (`SupabaseSyncService.switchToCurrentAccount`).
/// One body for both, so a purge added for one is a purge for the other.
@MainActor
struct LocalDataEraser {
    let store: EventStore
    let skillStore: SkillInsightStore
    let agentRuntime: AgentRuntime
    let authService: AuthService
    let calendarState: CalendarViewState
    let syncService: SupabaseSyncService
    let imageBackupCoordinator: ImageBackupCoordinator
    let backupSnapshotService: BackupSnapshotService
    /// gh#273: the telemetry uploader's in-memory state is the previous
    /// owner's too. Optional because the eraser is also built in contexts
    /// (and tests) that have no uploader.
    var telemetryUploader: TelemetryUploader? = nil

    func resetAllLocalData(keepingSession: Bool) {
        // FIRST — before the uploads flag, before any purge. Three paths in
        // this app await a network round trip and then write user content to
        // a backed-up directory; deleting files cannot stop a write that has
        // not happened yet. This marks the boundary those writers check on
        // their way back. See `LocalDataEraseEpoch`.
        LocalDataEraseEpoch.bump()

        // Disable uploads first. Without this, the debounced sinks fired
        // by the wipes below (EventStore @Published; and, for the keys that
        // still live in UserDefaults, didChangeNotification) would fire 2-5s
        // later, see canUpload
        // still true, hash now-empty rows against just-wiped hash maps,
        // and push an essentially-empty state to cloud — bulldozing the
        // user's existing cloud data right when they may want it preserved
        // for a future restore. "Reset all" is local-scoped by name; the
        // user re-enables uploads explicitly if they want fresh-cloud too.
        UserDefaults.standard.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)

        store.clearAllLocalData()
        skillStore.clearAll()
        TokenInferenceRepository.shared.clearAll()
        agentRuntime.preferenceStore.clearRules()
        agentRuntime.preferenceStore.clearDecisionHistory()
        agentRuntime.eventTypeTemplateStore.resetToDefaults()

        let defaults = UserDefaults.standard
        // BEFORE the sweep, which removes both keys this reads.
        //
        // The MCP connector URL carries a live read token, and the Account
        // page has a Copy button whose whole purpose is to put it in the
        // system clipboard. Removing `mcpURL` from `UserDefaults` left the
        // credential one paste away — and, with Universal Clipboard, on the
        // user's other devices too. Cleared only when the clipboard still
        // holds our copy; see `mcpURLPasteboardChangeCount` for why this is
        // a counter comparison and not a read.
        if AppSettingsKeys.shouldClearPasteboardOnErase(
            defaults: defaults,
            currentChangeCount: UIPasteboard.general.changeCount
        ) {
            UIPasteboard.general.items = []
        }
        AppSettingsKeys.removeResettableKeys(from: defaults)
        // The sweep just reset the interface language and clock format, and
        // `store.clearAllLocalData()` above stamped the widget's mirror of
        // both BEFORE the sweep, from the pre-erase values. The widget now
        // renders its chrome from that mirror (gh#239 F5), so without this
        // second flush an erased phone shows an English app beside a
        // Chinese "no events" widget until the next calendar save. The
        // payload hash includes both values, so this is one real write.
        store.flushWidgetSnapshotSync()
        // Sign out, not just clear the notice.
        //
        // `supabaseAuthSession` was the seventh store found surviving this
        // function. It was a JSON blob in `UserDefaults.standard` — so in
        // device and iCloud backup — holding `accessToken`, `refreshToken`,
        // `expiresAt` and `AuthUser { id, email, createdAt }`. It is in no
        // by-name list and matches no prefix scan, so an "erased" phone
        // handed to the next person showed them the previous owner's email
        // address in Me → Account, and the refresh token was still live:
        // "restore from cloud" pulled back every event this function had
        // just deleted. Exactly the shape the `mcpURL` comment in
        // `ContentView` describes — a live credential left on disk in a
        // backed-up location by the act that promises to remove it.
        //
        // gh#249 moved the session into the Keychain, which no `UserDefaults`
        // sweep reaches at all, and the live object holds a copy in memory.
        // Sign-out is the single write point that ends all three (Keychain
        // item, legacy `UserDefaults` key, in-memory session); a reset that
        // left any of them would come back signed in as the account whose
        // data it just erased. The legacy key stays on the sweep's list only
        // for the copy an interrupted migration may have left behind.
        //
        // The cloud side is deliberately untouched (this function is
        // local-scoped by name), so the cost is one sign-in, not any loss of
        // restore capability — and the sweep already removes
        // `hasOfferedAutoRestore.<userID>` below, which re-arms the restore
        // offer for exactly that next sign-in.
        //
        // `signOut()` subsumes `forgetReauthenticationNotice()`: it routes
        // through `clearSession(reason: .userInitiated)`, which nils the
        // published `session`, removes the session key, and removes
        // `authNeedsReauthentication` plus its `@Published` copy. That last
        // part is still load-bearing for gh#234 — the sweep above removes
        // that key by name, behind the live `AuthService`'s back, and
        // without telling the owner the re-auth card and the orange Me-tab
        // row survive the wipe until relaunch.
        //
        // `keepingSession` is "switch to this account" (gh#257): the session
        // on this phone is the account the user is switching TO, signed in a
        // moment ago; what is erased is the other account's data. Everything
        // else below runs the same.
        if !keepingSession {
            authService.signOut()
        }
        // The by-name sweep removes `calendar.timeline.hourHeight` and
        // `calendarLastRangeMode`, which this object holds in memory and
        // writes back — the zoom from a geometry pass, the range mode from
        // the next view-mode tap. Same rule as the sign-out above and the
        // coordinator below.
        calendarState.forgetPersistedViewState()
        // Sync diff-hash maps are keyed per-userId, so they aren't in the
        // static resettable list — wipe them with a prefix scan instead.
        SupabaseSyncService.wipeAllPersistedHashes()
        // The owner guard's copy beside the data (`owner.json`). The shelf's
        // wipe below removes its directory too; named here so the record
        // does not depend on where the shelf keeps its file.
        SyncOwnerRecord.production.remove()
        // "Erased on another device" and the choice: the sweep above took
        // the two keys; this ends the state the live engine holds, so the
        // account card does not keep describing data that is gone.
        syncService.forgetAccountGone()
        // The conflict shelf holds the losing versions of synced rows — the
        // user's own account data, in its own Application Support directory
        // that no prefix scan reaches.
        ConflictShelf.wipe()

        // Additional UserDefaults blobs that aren't in the static
        // resettable list but ARE user-owned state per the full-backup
        // audit. Missing these meant "Reset all" kept conversations /
        // avatar slot / log-template preferences / etc. across the reset.
        // The chat history moved to `AgentConversationRepository`; wipe the file
        // as well as the two legacy keys. Both removals belong to the same
        // "only place allowed to purge" rule as the event-type keys below: they
        // are the rollback net everywhere else, and here leaving them would let
        // a downgraded binary resurrect the conversations the user just erased.
        AgentConversationRepository.shared.wipe()
        defaults.removeObject(forKey: AgentConversationsStorageKey)
        defaults.removeObject(forKey: AgentConversationRepository.legacyMessagesKey)
        defaults.removeObject(forKey: EventLogTemplatePreferenceStore.storageKey)
        // The event types moved to `EventTypeCatalog`, and `resetToDefaults()`
        // above already wiped the files. These two removals are the ONLY place
        // in the app allowed to purge the legacy keys — everywhere else they
        // are left untouched as the rollback safety net. Here the opposite is
        // true: leaving them would let a downgraded binary resurrect the very
        // types the user just asked to erase.
        defaults.removeObject(forKey: EventTypeTemplateStore.storageKey)
        defaults.removeObject(forKey: EventTypeTemplateStore.colorHistoryKey)
        defaults.removeObject(forKey: "skillAnalyzedEventIds")
        // The frozen reference time zone is user data too — every occurrence
        // record's `dayKey` was derived in it, and those records were just
        // erased above. Wiping it is ALSO the only local exit from the store's
        // `.unusable` state, which otherwise suppresses every settings upload
        // and every local DR snapshot until a cloud restore happens to carry
        // the key. The legacy key falls under the same "only place allowed to
        // purge" rule as the event-type keys above: leaving it would let a
        // downgraded binary resurrect the zone the user just asked to erase.
        OccurrenceKeyMetadataStore.shared.wipe()
        defaults.removeObject(forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey)
        // Composer rescue drafts. These used to be written only on a scene
        // departure, so the slots were almost always empty at reset time;
        // now that they're written continuously while typing, any session
        // the user ever typed into leaves one behind — and surviving a
        // "reset all local data" it would resurface as a resume banner
        // carrying pre-reset content.
        CalendarComposerDraftStore.clear()
        CalendarEditDraftStore.clear()
        CalendarDetailComposerDraftStore.clear()
        // Per-user keys (prefix scan, same shape as wipeAllPersistedHashes):
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("lastSyncedAvatarVersion.") || key.hasPrefix("hasOfferedAutoRestore.") {
            defaults.removeObject(forKey: key)
        }
        // Two more per-user key families, handled here rather than added to
        // the scan above. (This comment used to say the scan "has two
        // prefixes and needed four", which was wrong twice: the scan still
        // has its original two, and counting every per-user family on the
        // device gives five — the two above, these two, and `syncHashes.`,
        // swept by `wipeAllPersistedHashes` earlier. The set is complete;
        // the sentence was arithmetic nobody could check.)
        //
        // These hold `<eventID>/<imageID>` pairs — the user's own event ids,
        // never pruned, in a backed-up domain — and survived the erase
        // completely:
        // per-user keys are not in the by-name list, and the scan did not
        // know about them. Told rather than swept here because the
        // coordinator keeps the same set in memory behind a dirty flag and
        // would write it back (the `forgetReauthenticationNotice` rule).
        imageBackupCoordinator.forgetConfirmedUploads()
        // Avatar file on disk (UserDefaults-only reset won't catch it).
        MeAvatarStore.delete()
        // The position is load-bearing (gh#258), but the constraint is
        // "after everything the snapshot READS", not "last" — five disk
        // purges follow it below and are none of its business. This comment
        // said "LAST" and went on saying it after those five were appended
        // directly underneath; the ordering assertion that actually holds
        // the line is
        // `testResetAllLocalDataCallsTheSnapshotWipeAfterTheStoreErasures`,
        // which compares this call's position against
        // `MeAvatarStore.delete()` and deliberately claims no more.
        //
        // What must precede it is every component of
        // `SnapshotComponents`: the event slots, event types, skills, agent
        // rules and decision history, the settings sweep, the conversation
        // repository, and the avatar bytes — that last one is why
        // `MeAvatarStore.delete()` sits immediately above and is the anchor.
        //
        // The local DR snapshot is a plaintext JSON of every slot plus event
        // types, skills, conversations and settings, and it lives in `Documents/`
        // precisely so iOS Device Backup — and so iCloud — picks it up. Every
        // erase above has to have happened first: `wipe()` rebuilds the
        // service's trigger subscriptions to discard the 30 s debounce that
        // this function's own store mutations just armed, and that rebuild
        // re-arms `attach`'s `dropFirst(5)`, which swallows the five
        // emissions the stores send on subscribe. Called any earlier, it
        // would swallow PRE-wipe values and let the wipe's own emissions
        // through to a write — recreating the file ~30 s later.
        //
        // Told, not deleted around: same rule as `forgetReauthenticationNotice`
        // above. The owner knows where its file is and what else has to
        // settle; this function does not.
        backupSnapshotService.wipe()
        // Disk copies the sweep above does not reach, each with its own
        // store and its own backed-up directory. Every one of these was
        // found by a REVIEW happening to look, not by anything in the tree
        // noticing.
        //
        // ⚠️ THAT IS STILL TRUE. Nothing here makes the next one fail on
        // arrival. A census test was written for this spot and withdrawn
        // (gh#266): it could only approximate "writes user data" by scanning
        // for syntax, it was defeated four review rounds running by a
        // storage medium its needles did not cover, and it ended up
        // CERTIFYING a key that really was unswept
        // (`calendar.timeline.hourHeight`, a bare literal on a private let).
        // A detector that emits false green is worse than none.
        //
        // The fix is a registry — an `ErasableLocalStore` the store conforms
        // to AT ITS POINT OF DEFINITION, so this list is derived instead of
        // remembered and "forgot to add it" becomes a compile error. gh#266.
        // Until then this block is maintained by hand and by review, and
        // `EraseDiskWitnessQATests` only witnesses that the calls below do
        // what they say — not that the list is complete.
        //
        // gh#260 — attached event/log photos. `Library/Application Support/
        // AgenticIntakeAssets/`, deliberately backed up per the store's own
        // doc. The window was erase → next launch's background sweep, not
        // forever: an earlier comment here said the sweep refuses
        // permanently post-erase, and it does not — the wiped slots are
        // seeded, so the arrays are not empty. See `removeAllAssets`.
        AgenticIntakeAssetStore().removeAllAssets()
        // gh#263 — contact avatars. Must come AFTER `store.clearAllLocalData()`
        // for correctness of the erase, but note the cost of that order: it
        // destroys `Person.avatarImageName` first, which is the only thing
        // that said which JPEG belonged to whom. Photographs of other people,
        // so leaving them unidentifiable was worse than leaving them.
        PersonAvatarStore.removeAll()
        // gh#261 — reports. Same `Documents/` directory, so the same backup
        // path as the snapshot above. Carries `userNote`: the user's own words.
        ReportStore().wipe()
        // gh#263 — per-day/model activity counters. `clearAll()` already
        // existed but was wired only to a Developer-page button.
        LLMUsageStore.shared.clearAll()
        // gh#263 — spike run records, including user-entered notes.
        // `FixWatchView` tells the user these are backed up with the device.
        SpikeRunStore.wipe()
        // gh#273 — the uploader's memory of those files: status row, sample,
        // last outcome, throttle clock. Told, not reached around (the owner
        // knows its fields); the files themselves went with the wipe above.
        telemetryUploader?.forgetAfterErase()
        // Round 2. MetricKit payloads in `Diagnostics/MetricKit/` and the
        // legacy `Documents/Diagnostics` pile. `DiagnosticTrail.clear()`
        // already empties the trail in the same directory and left this
        // sibling folder standing — see `MetricPayloadStore.wipe`.
        MetricPayloadStore.standard().wipe()
    }
}
