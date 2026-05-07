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

struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("agentAPIKey") private var apiKey = ""
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage("agentAskBeforeCreatingEventTypeTemplates") private var askBeforeCreatingEventTypeTemplates = true

    let showsDoneButton: Bool

    init(showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        Form {
            Section("Status") {
                settingsStatusRow(title: "Provider", value: providerDisplayName(selectedProvider))
                settingsStatusRow(title: "API Key", value: apiKey.isEmpty ? "Missing" : "Configured")
                settingsStatusRow(title: "Learned Rules", value: "\(agentRuntime.preferenceStore.listRules().count)")
            }

            Section("Provider") {
                Picker("LLM Provider", selection: $selectedProvider) {
                    Text("Claude").tag("claude")
                    Text("OpenAI").tag("openai")
                    Text("DeepSeek").tag("deepseek")
                }
                .pickerStyle(.segmented)
            }

            Section("API Key") {
                SecureField("Enter your API key", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if apiKey.isEmpty {
                    Label("Not configured", systemImage: "xmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Label("Key saved (\(apiKey.prefix(8))...)", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text(providerHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("AI type suggestions after save", isOn: $calendarAgenticCreateEnabled)
                Toggle("Ask before creating event type templates", isOn: $askBeforeCreatingEventTypeTemplates)
            }

            Section {
                Text("When enabled, calendar forms can preselect a type while you type using existing event history and local heuristics, then ask AI after save if needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Learning") {
                if agentRuntime.preferenceStore.listRules().isEmpty {
                    Text("No learned preferences yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(agentRuntime.preferenceStore.listRules().prefix(8))) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ruleRowTitle(rule))
                                .font(.footnote.weight(.semibold))
                            Text(ruleRowSubtitle(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button("Clear Learned Preferences", role: .destructive) {
                    agentRuntime.preferenceStore.clearRules()
                }

                Button("Clear Decision History", role: .destructive) {
                    agentRuntime.preferenceStore.clearDecisionHistory()
                }

                Text("Learning is stored locally on this device and is currently based on explicit decisions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI & Agent")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private func settingsStatusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
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
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("agentAPIKey") private var apiKey = ""
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.effortOpacityEnabled) private var effortOpacityEnabled = true
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var experimentalMultiTypeEnabled = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeMaxCount) private var experimentalMultiTypeMaxCount = 2
    @AppStorage(AppSettingsKeys.calendarHeaderExposedTools) private var headerExposedToolsRaw = "create"

    @AppStorage(AppSettingsKeys.calendarRememberViewMode) private var rememberViewMode = false
    @AppStorage(AppSettingsKeys.calendarAutoReturnToToday) private var autoReturnToToday = false
    @AppStorage(AppSettingsKeys.detailHeaderExposedTools) private var detailExposedToolsRaw = "add"

    @AppStorage("mcpURL") private var mcpURL: String = ""

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
        Form {
            Section {
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
                            Text(authService.isSignedIn ? "Sync & Account" : "Sign in to sync your data")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section(L(.settings)) {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsLinkRow(
                        title: L(.general),
                        summary: "\(rememberLastTab ? "Remember last tab" : "Start on \(tabSummary)") • Timer banner \(showTimerBanner ? "on" : "off")"
                    )
                }

                NavigationLink {
                    CalendarHeaderSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Calendar",
                        summary: calendarSettingsSummary
                    )
                }

                NavigationLink {
                    DetailHeaderSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Event Detail",
                        summary: detailSettingsSummary
                    )
                }

                NavigationLink {
                    WorkflowSettingsView()
                } label: {
                    settingsLinkRow(
                        title: L(.recordingAndWorkflow),
                        summary: "Landscape focus \(landscapeFocusModeEnabled ? "on" : "off") • Keep awake \(landscapeFocusKeepAwakeEnabled ? "on" : "off") • Type suggestions \(calendarAgenticCreateEnabled ? "on" : "off") • Effort opacity \(effortOpacityEnabled ? "on" : "off")"
                    )
                }

                NavigationLink {
                    AgentSettingsView()
                        .environmentObject(agentRuntime)
                } label: {
                    settingsLinkRow(
                        title: L(.aiAndAgent),
                        summary: "\(providerDisplayName(selectedProvider)) • \(apiKey.isEmpty ? "key missing" : "key configured") • \(agentRuntime.preferenceStore.listRules().count) rules"
                    )
                }

                NavigationLink {
                    AnalysisPreferencesView()
                } label: {
                    settingsLinkRow(
                        title: L(.analysisPreferences),
                        summary: "\(defaultPeriodRawValue) default • Auto suggestions \(autoLoadSuggestions ? "on" : "off")"
                    )
                }

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

                NavigationLink {
                    ConnectionsView()
                        .environmentObject(authService)
                } label: {
                    settingsLinkRow(
                        title: "Connections",
                        summary: mcpURL.isEmpty ? "Set up to let AI apps read your data" : "AI Connector active"
                    )
                }
            }

            Section(L(.systemStatus)) {
                LabeledContent(L(.providerLabel), value: providerDisplayName(selectedProvider))
                LabeledContent(L(.typeSuggestions), value: calendarAgenticCreateEnabled ? L(.on) : L(.off))
                LabeledContent(L(.learnedRulesLabel), value: "\(agentRuntime.preferenceStore.listRules().count)")
                LabeledContent(L(.insightsStored), value: "\(skillStore.insights.count)")
            }

            Section(L(.storage)) {
                Text("Settings, insights, templates, and AI learning are kept on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L(.settings))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tabSummary: String {
        RootTab(rawValue: defaultTabRawValue)?.rawValue.capitalized ?? "Event"
    }

    @ViewBuilder
    private func settingsLinkRow(title: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppSettingsKeys.rememberLastTab) private var rememberLastTab = true
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.wanna.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @AppStorage(AppSettingsLocale.languageKey) private var languageRaw = AppLanguage.english.rawValue
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormatRaw = AppTimeFormat.twentyFour.rawValue

    var body: some View {
        Form {
            Section {
                Picker(L(.language), selection: $languageRaw) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }

                Picker(L(.timeFormat), selection: $timeFormatRaw) {
                    ForEach(AppTimeFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt.rawValue)
                    }
                }
            }

            Section(L(.launch)) {
                Toggle(L(.rememberLastTab), isOn: $rememberLastTab)

                Picker("Default tab", selection: $defaultTabRawValue) {
                    ForEach(RootTab.allCases) { tab in
                        Text(tab.rawValue.capitalized).tag(tab.rawValue)
                    }
                }
                .disabled(rememberLastTab)
            }

            Section(L(.interface)) {
                Toggle(L(.showTimerBanner), isOn: $showTimerBanner)
            }

            Section {
                Text(L(.hintDefaultTab))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L(.general))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkflowSettingsView: View {
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = false
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.effortOpacityEnabled) private var effortOpacityEnabled = true

    var body: some View {
        Form {
            Section(L(.workflow)) {
                Toggle(L(.landscapeFocusMode), isOn: $landscapeFocusModeEnabled)
                Toggle(L(.landscapeFocusKeepAwake), isOn: $landscapeFocusKeepAwakeEnabled)
                Toggle(L(.enableAiTypeSuggestions), isOn: $calendarAgenticCreateEnabled)
                Toggle(L(.effortBasedEventOpacity), isOn: $effortOpacityEnabled)
            }

            Section {
                Text(L(.hintLandscapeAndAgent))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L(.hintEffortBasedEventOpacity))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L(.recordingAndWorkflow))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AnalysisPreferencesView: View {
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default period", selection: $defaultPeriodRawValue) {
                    ForEach(AnalysisPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period.rawValue)
                    }
                }

                Toggle("Auto-load AI suggestions", isOn: $autoLoadSuggestions)
            }

            Section {
                Text("The selected period is applied when opening analysis from a new session. Auto-loading suggestions can make the analysis page feel heavier on large data sets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Analysis Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExperimentalSettingsView: View {
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var multiTypeEnabled = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeMaxCount) private var multiTypeMaxCount = 2

    var body: some View {
        Form {
            Section {
                Text("Labs features are experimental and may change, break, or be removed without notice. Your existing data is always preserved when toggling them off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Multi-type events") {
                Toggle("Enable multi-type events", isOn: $multiTypeEnabled)

                if multiTypeEnabled {
                    Stepper(value: $multiTypeMaxCount, in: 2...4) {
                        HStack {
                            Text("Max types per event")
                            Spacer()
                            Text("\(multiTypeMaxCount)")
                                .foregroundStyle(.secondary)
                        }
                    }

                }
            }

            Section {
                Text("When enabled, an event can carry up to the configured number of types. The Reflection page shows them as a stack of cards — the top card is the primary type. Tap any other card to make it primary, or long-press for more options. Turning this off hides the editor but keeps the data — re-enabling restores it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: multiTypeMaxCount) { _, newValue in
            // Defensive clamp in case a stale stored value lands outside the
            // currently-supported range.
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
        Form {
            Section(L(.privacy)) {
                Text(L(.hintLocalData))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(L(.manageData)) {
                Button(L(.clearSkillInsights), role: .destructive) {
                    isConfirmingSkillClear = true
                }

                Button(L(.clearTokenCache), role: .destructive) {
                    isConfirmingInferenceClear = true
                }

                Button(L(.resetAllData), role: .destructive) {
                    isConfirmingResetAll = true
                }
            }
        }
        .navigationTitle(L(.dataAndPrivacy))
        .navigationBarTitleDisplayMode(.inline)
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
