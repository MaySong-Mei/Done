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
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.event.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = true
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("agentAPIKey") private var apiKey = ""
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisShowProfileSummary) private var showProfileSummary = true
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false

    var body: some View {
        Form {
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
                    WorkflowSettingsView()
                } label: {
                    settingsLinkRow(
                        title: L(.recordingAndWorkflow),
                        summary: "Landscape focus \(landscapeFocusModeEnabled ? "on" : "off") • Keep awake \(landscapeFocusKeepAwakeEnabled ? "on" : "off") • Type suggestions \(calendarAgenticCreateEnabled ? "on" : "off")"
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
                        summary: "\(defaultPeriodRawValue) default • Profile summary \(showProfileSummary ? "on" : "off") • Auto suggestions \(autoLoadSuggestions ? "on" : "off")"
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
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.event.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @AppStorage(AppSettingsLocale.languageKey) private var languageRaw = AppLanguage.english.rawValue
    @AppStorage(AppSettingsLocale.timeFormatKey) private var timeFormatRaw = AppTimeFormat.twentyFour.rawValue

    var body: some View {
        Form {
            Section(L(.language)) {
                Picker(L(.language), selection: $languageRaw) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L(.timeFormat)) {
                Picker(L(.timeFormat), selection: $timeFormatRaw) {
                    ForEach(AppTimeFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt.rawValue)
                    }
                }
                .pickerStyle(.segmented)
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
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = true
    @AppStorage(AppSettingsKeys.landscapeFocusKeepAwake) private var landscapeFocusKeepAwakeEnabled = true
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true

    var body: some View {
        Form {
            Section(L(.workflow)) {
                Toggle(L(.landscapeFocusMode), isOn: $landscapeFocusModeEnabled)
                Toggle(L(.landscapeFocusKeepAwake), isOn: $landscapeFocusKeepAwakeEnabled)
                Toggle(L(.enableAiTypeSuggestions), isOn: $calendarAgenticCreateEnabled)
            }

            Section {
                Text(L(.hintLandscapeAndAgent))
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
    @AppStorage(AppSettingsKeys.analysisShowProfileSummary) private var showProfileSummary = true
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default period", selection: $defaultPeriodRawValue) {
                    ForEach(AnalysisPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period.rawValue)
                    }
                }

                Toggle("Show analysis summary on Me", isOn: $showProfileSummary)
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
