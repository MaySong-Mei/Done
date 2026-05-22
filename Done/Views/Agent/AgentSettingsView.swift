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

@ViewBuilder
func settingsHintCard(_ text: String) -> some View {
    GlassCardView(cornerRadius: 16, contentPadding: 14) {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
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

    let showsDoneButton: Bool

    init(showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        settingsPage(L(.aiAndAgent)) {
            settingsCard(L(.status)) {
                settingsLabeledRow(L(.provider), value: providerDisplayName(selectedProvider))
                settingsLabeledRow(L(.apiKey), value: apiKey.isEmpty ? L(.missing) : L(.configured))
                settingsLabeledRow(L(.learnedRulesLabel), value: "\(agentRuntime.preferenceStore.listRules().count)")
            }

            settingsCard(L(.provider)) {
                Picker(L(.llmProvider), selection: $selectedProvider) {
                    Text("Claude").tag("claude")
                    Text("OpenAI").tag("openai")
                    Text("DeepSeek").tag("deepseek")
                }
                .pickerStyle(.segmented)
            }

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

            settingsHintCard(providerHint)

            settingsCard(L(.behavior)) {
                Toggle(L(.aiTypeSuggestionsAfterSave), isOn: $calendarAgenticCreateEnabled)
                Toggle(L(.askBeforeCreatingTemplates), isOn: $askBeforeCreatingEventTypeTemplates)
            }

            settingsHintCard(L(.hintTypeSuggestions))

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
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @AppStorage(AppSettingsKeys.rememberLastTab) private var rememberLastTab = true
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.wanna.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = false
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
    @AppStorage(AppSettingsKeys.agentProvider) private var selectedProvider = AppSettingsKeys.agentProviderDefault
    @AppStorage(AppSettingsKeys.agentAPIKey) private var apiKey = ""
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.effortOpacityEnabled) private var effortOpacityEnabled = true
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var experimentalMultiTypeEnabled = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeMaxCount) private var experimentalMultiTypeMaxCount = 2
    @AppStorage(AppSettingsKeys.calendarHeaderExposedTools) private var headerExposedToolsRaw = "create"

    @AppStorage(AppSettingsKeys.calendarRememberViewMode) private var rememberViewMode = false
    @AppStorage(AppSettingsKeys.calendarAutoReturnToToday) private var autoReturnToToday = false
    @AppStorage(AppSettingsKeys.detailHeaderExposedTools) private var detailExposedToolsRaw = "add"

    @AppStorage(AppSettingsKeys.mcpURL) private var mcpURL: String = ""

    private var calendarSettingsSummary: String {
        let exposed = calendarHeaderExposedTools(from: headerExposedToolsRaw)
        let names = CalendarHeaderTool.allCases.filter { exposed.contains($0) }.map(\.label)
        var parts: [String] = []
        parts.append(names.isEmpty ? "All in menu" : names.joined(separator: ", "))
        if rememberViewMode { parts.append("remember view") }
        if autoReturnToToday { parts.append("auto-today") }
        return parts.joined(separator: " \u{2022} ")
    }

    private var detailSettingsSummary: String {
        let exposed = detailHeaderExposedTools(from: detailExposedToolsRaw)
        let names = DetailHeaderTool.allCases.filter { exposed.contains($0) }.map(\.label)
        return names.isEmpty ? "All in menu" : names.joined(separator: ", ")
    }

    @EnvironmentObject private var authService: AuthService

    var body: some View {
        settingsPage(L(.settings)) {
            meCard

            settingsCard(spacing: 14) {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsLinkRow(
                        title: L(.general),
                        summary: "\(rememberLastTab ? "Remember last tab" : "Start on \(tabSummary)") • Timer banner \(showTimerBanner ? "on" : "off")"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    CalendarHeaderSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Calendar",
                        summary: calendarSettingsSummary
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    DetailHeaderSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Event Detail",
                        summary: detailSettingsSummary
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    WorkflowSettingsView()
                } label: {
                    settingsLinkRow(
                        title: L(.recordingAndWorkflow),
                        summary: "Landscape focus \(landscapeFocusModeEnabled ? "on" : "off") • Keep awake \(landscapeFocusKeepAwakeEnabled ? "on" : "off") • Type suggestions \(calendarAgenticCreateEnabled ? "on" : "off") • Effort opacity \(effortOpacityEnabled ? "on" : "off")"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard(spacing: 14) {
                NavigationLink {
                    AgentSettingsView()
                        .environmentObject(agentRuntime)
                } label: {
                    settingsLinkRow(
                        title: L(.aiAndAgent),
                        summary: "\(providerDisplayName(selectedProvider)) • \(apiKey.isEmpty ? "key missing" : "key configured") • \(agentRuntime.preferenceStore.listRules().count) rules"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    AnalysisPreferencesView()
                } label: {
                    settingsLinkRow(
                        title: L(.analysisPreferences),
                        summary: "\(defaultPeriodRawValue) default • Auto suggestions \(autoLoadSuggestions ? "on" : "off")"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    ConnectionsView()
                        .environmentObject(authService)
                } label: {
                    settingsLinkRow(
                        title: "Connections",
                        summary: mcpURL.isEmpty ? "Set up to let AI apps read your data" : "AI Connector active"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard(spacing: 14) {
                NavigationLink {
                    ExperimentalSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Experimental",
                        summary: experimentalMultiTypeEnabled
                            ? "Multi-type events on • max \(experimentalMultiTypeMaxCount)"
                            : "Off"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    DataPrivacySettingsView()
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .environmentObject(skillStore)
                } label: {
                    settingsLinkRow(
                        title: L(.dataAndPrivacy),
                        summary: "\(skillStore.insights.count) insights • \(store.calendarEvents.count) calendar items • stored locally"
                    )
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
                Text(L(.hintLocalData))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var meCard: some View {
        settingsCard {
            NavigationLink {
                AccountView()
                    .environmentObject(authService)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authService.session?.user.email ?? L(.tabMe))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(authService.isSignedIn ? "Sync & Account" : "Sign in to sync your data")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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

    private var tabSummary: String {
        RootTab(rawValue: defaultTabRawValue)?.rawValue.capitalized ?? "Event"
    }

    @ViewBuilder
    private func settingsLinkRow(title: String, summary: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
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
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.wanna.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @AppStorage(AppSettingsLocale.languageKey) private var languageRaw = AppLanguage.english.rawValue
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormatRaw = AppTimeFormat.twentyFour.rawValue

    var body: some View {
        settingsPage(L(.general)) {
            settingsCard {
                Picker(L(.language), selection: $languageRaw) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)

                Picker(L(.timeFormat), selection: $timeFormatRaw) {
                    ForEach(AppTimeFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
            }

            settingsCard(L(.launch)) {
                Toggle(L(.rememberLastTab), isOn: $rememberLastTab)

                Picker(L(.defaultTab), selection: $defaultTabRawValue) {
                    ForEach(RootTab.allCases) { tab in
                        Text(tab.rawValue.capitalized).tag(tab.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .disabled(rememberLastTab)
            }

            settingsCard(L(.interface)) {
                Toggle(L(.showTimerBanner), isOn: $showTimerBanner)
            }

            settingsHintCard(L(.hintDefaultTab))
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
            }

            settingsHintCard(L(.hintLandscapeAndAgent))
            settingsHintCard(L(.hintEffortBasedEventOpacity))
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
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var restoreCoordinator: RestoreCoordinator
    @EnvironmentObject private var imageBackupCoordinator: ImageBackupCoordinator
    @EnvironmentObject private var syncStatusReporter: SyncStatusReporter
    @State private var isConfirmingSkillClear = false
    @State private var isConfirmingInferenceClear = false
    @State private var isConfirmingResetAll = false
    @State private var isPresentingRestoreSheet = false
    @State private var isPresentingPreviewSheet = false

    var body: some View {
        settingsPage(L(.dataAndPrivacy)) {
            settingsCard(L(.privacy)) {
                Text(L(.hintLocalData))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
                resetAllLocalData()
            }
        } message: {
            Text(L(.hintResetAllData))
        }
    }

    private func resetAllLocalData() {
        store.clearAllLocalData()
        skillStore.clearAll()
        TokenInferenceRepository.shared.clearAll()
        agentRuntime.preferenceStore.clearRules()
        agentRuntime.preferenceStore.clearDecisionHistory()
        agentRuntime.eventTypeTemplateStore.resetToDefaults()

        let defaults = UserDefaults.standard
        for key in AppSettingsKeys.resettableUserDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
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
