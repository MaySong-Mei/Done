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
    }
    .font(.subheadline)
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
        settingsPage("AI & Agent") {
            settingsCard("Status") {
                settingsLabeledRow("Provider", value: providerDisplayName(selectedProvider))
                settingsLabeledRow("API Key", value: apiKey.isEmpty ? "Missing" : "Configured")
                settingsLabeledRow("Learned Rules", value: "\(agentRuntime.preferenceStore.listRules().count)")
            }

            settingsCard("Provider") {
                Picker("LLM Provider", selection: $selectedProvider) {
                    Text("Claude").tag("claude")
                    Text("OpenAI").tag("openai")
                    Text("DeepSeek").tag("deepseek")
                }
                .pickerStyle(.segmented)
            }

            settingsCard("API Key") {
                SecureField("Enter your API key", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if apiKey.isEmpty {
                    Label("Not configured", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Label("Key saved (\(apiKey.prefix(8))...)", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            settingsHintCard(providerHint)

            settingsCard("Behavior") {
                Toggle("AI type suggestions after save", isOn: $calendarAgenticCreateEnabled)
                Toggle("Ask before creating event type templates", isOn: $askBeforeCreatingEventTypeTemplates)
            }

            settingsHintCard("When enabled, calendar forms can preselect a type while you type using existing event history and local heuristics, then ask AI after save if needed.")

            settingsCard("Learning") {
                if agentRuntime.preferenceStore.listRules().isEmpty {
                    Text("No learned preferences yet.")
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

                settingsDestructiveButton("Clear Learned Preferences") {
                    agentRuntime.preferenceStore.clearRules()
                }

                settingsDestructiveButton("Clear Decision History") {
                    agentRuntime.preferenceStore.clearDecisionHistory()
                }
            }

            settingsHintCard("Learning is stored locally on this device and is currently based on explicit decisions.")
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
        case "claude": return "Get your API key from console.anthropic.com"
        case "openai": return "Get your API key from platform.openai.com"
        case "deepseek": return "Get your API key from platform.deepseek.com"
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
                .buttonStyle(.plain)

                NavigationLink {
                    CalendarHeaderSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Calendar",
                        summary: calendarSettingsSummary
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DetailHeaderSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Event Detail",
                        summary: detailSettingsSummary
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    WorkflowSettingsView()
                } label: {
                    settingsLinkRow(
                        title: L(.recordingAndWorkflow),
                        summary: "Landscape focus \(landscapeFocusModeEnabled ? "on" : "off") • Keep awake \(landscapeFocusKeepAwakeEnabled ? "on" : "off") • Type suggestions \(calendarAgenticCreateEnabled ? "on" : "off") • Effort opacity \(effortOpacityEnabled ? "on" : "off")"
                    )
                }
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)

                NavigationLink {
                    AnalysisPreferencesView()
                } label: {
                    settingsLinkRow(
                        title: L(.analysisPreferences),
                        summary: "\(defaultPeriodRawValue) default • Auto suggestions \(autoLoadSuggestions ? "on" : "off")"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ConnectionsView()
                        .environmentObject(authService)
                } label: {
                    settingsLinkRow(
                        title: "Connections",
                        summary: mcpURL.isEmpty ? "Set up to let AI apps read your data" : "AI Connector active"
                    )
                }
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)

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
                .buttonStyle(.plain)
            }

            settingsCard(L(.systemStatus)) {
                statusRow(label: L(.providerLabel), value: providerDisplayName(selectedProvider))
                statusRow(label: L(.typeSuggestions), value: calendarAgenticCreateEnabled ? L(.on) : L(.off))
                statusRow(label: L(.learnedRulesLabel), value: "\(agentRuntime.preferenceStore.listRules().count)")
                statusRow(label: L(.insightsStored), value: "\(skillStore.insights.count)")
            }

            settingsCard(L(.storage)) {
                Text("Settings, insights, templates, and AI learning are kept on this device.")
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
            .buttonStyle(.plain)
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

                Picker("Default tab", selection: $defaultTabRawValue) {
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
        settingsPage("Analysis Preferences") {
            settingsCard("Defaults") {
                Picker("Default period", selection: $defaultPeriodRawValue) {
                    ForEach(AnalysisPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)

                Toggle("Auto-load AI suggestions", isOn: $autoLoadSuggestions)
            }

            settingsHintCard("The selected period is applied when opening analysis from a new session. Auto-loading suggestions can make the analysis page feel heavier on large data sets.")
        }
    }
}

struct ExperimentalSettingsView: View {
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var multiTypeEnabled = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeMaxCount) private var multiTypeMaxCount = 2

    var body: some View {
        settingsPage("Experimental") {
            settingsHintCard("Labs features are experimental and may change, break, or be removed without notice. Your existing data is always preserved when toggling them off.")

            settingsCard("Multi-type events") {
                Toggle("Enable multi-type events", isOn: $multiTypeEnabled)

                if multiTypeEnabled {
                    Stepper(value: $multiTypeMaxCount, in: 2...4) {
                        HStack {
                            Text("Max types per event")
                            Spacer()
                            Text("\(multiTypeMaxCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            settingsHintCard("When enabled, an event can carry up to the configured number of types. The Reflection page shows them as a stack of cards — the top card is the primary type. Tap any other card to make it primary, or long-press for more options. Turning this off hides the editor but keeps the data — re-enabling restores it.")
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
    @State private var isConfirmingSkillClear = false
    @State private var isConfirmingInferenceClear = false
    @State private var isConfirmingResetAll = false

    var body: some View {
        settingsPage(L(.dataAndPrivacy)) {
            settingsCard(L(.privacy)) {
                Text(L(.hintLocalData))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
}
