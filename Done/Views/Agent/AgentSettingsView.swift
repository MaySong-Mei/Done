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
                Toggle("Agentic Calendar Create", isOn: $calendarAgenticCreateEnabled)
                Toggle("Ask before creating event type templates", isOn: $askBeforeCreatingEventTypeTemplates)
            }

            Section {
                Text("Agentic create replaces the calendar create form with AI-assisted text or image intake when enabled.")
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
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("agentAPIKey") private var apiKey = ""
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage(AppSettingsKeys.analysisDefaultPeriod) private var defaultPeriodRawValue = AnalysisPeriod.week.rawValue
    @AppStorage(AppSettingsKeys.analysisShowProfileSummary) private var showProfileSummary = true
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false

    var body: some View {
        Form {
            Section("Controls") {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "General",
                        summary: "\(rememberLastTab ? "Remember last tab" : "Start on \(tabSummary)") • Timer banner \(showTimerBanner ? "on" : "off")"
                    )
                }

                NavigationLink {
                    WorkflowSettingsView()
                } label: {
                    settingsLinkRow(
                        title: "Recording & Workflow",
                        summary: "Landscape focus \(landscapeFocusModeEnabled ? "on" : "off") • Agent create \(calendarAgenticCreateEnabled ? "on" : "off")"
                    )
                }

                NavigationLink {
                    AgentSettingsView()
                        .environmentObject(agentRuntime)
                } label: {
                    settingsLinkRow(
                        title: "AI & Agent",
                        summary: "\(providerDisplayName(selectedProvider)) • \(apiKey.isEmpty ? "key missing" : "key configured") • \(agentRuntime.preferenceStore.listRules().count) rules"
                    )
                }

                NavigationLink {
                    AnalysisPreferencesView()
                } label: {
                    settingsLinkRow(
                        title: "Analysis Preferences",
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
                        title: "Data & Privacy",
                        summary: "\(skillStore.insights.count) insights • \(store.calendarEvents.count) calendar items • stored locally"
                    )
                }
            }

            Section("Storage") {
                Text("Settings, insights, templates, and AI learning are kept on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
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

    var body: some View {
        Form {
            Section("Launch") {
                Toggle("Remember last viewed tab", isOn: $rememberLastTab)

                Picker("Default tab", selection: $defaultTabRawValue) {
                    ForEach(RootTab.allCases) { tab in
                        Text(tab.rawValue.capitalized).tag(tab.rawValue)
                    }
                }
                .disabled(rememberLastTab)
            }

            Section("Interface") {
                Toggle("Show active timer banner", isOn: $showTimerBanner)
            }

            Section {
                Text("If last tab memory is enabled, the default tab is only used when there is no previous selection yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkflowSettingsView: View {
    @AppStorage(AppSettingsKeys.landscapeFocusMode) private var landscapeFocusModeEnabled = true
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true

    var body: some View {
        Form {
            Section("Workflow") {
                Toggle("Enable landscape focus mode", isOn: $landscapeFocusModeEnabled)
                Toggle("Use agent-assisted calendar create", isOn: $calendarAgenticCreateEnabled)
            }

            Section {
                Text("Landscape focus mode swaps to the immersive focus screen when the device rotates. Agent-assisted create replaces the manual calendar form with AI intake.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Recording & Workflow")
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
            Section("Privacy") {
                Text("Done currently keeps its data locally on this device. Clearing data below cannot be undone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Manage Data") {
                Button("Clear Skill Insights", role: .destructive) {
                    isConfirmingSkillClear = true
                }

                Button("Clear Token Inference Cache", role: .destructive) {
                    isConfirmingInferenceClear = true
                }

                Button("Reset All Local Data", role: .destructive) {
                    isConfirmingResetAll = true
                }
            }
        }
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear skill insights?", isPresented: $isConfirmingSkillClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                skillStore.clearAll()
            }
        } message: {
            Text("This removes all saved skill growth data and analysis markers.")
        }
        .alert("Clear token inference cache?", isPresented: $isConfirmingInferenceClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                TokenInferenceRepository.shared.clearAll()
            }
        } message: {
            Text("This removes cached token projections and dynamic hypotheses.")
        }
        .alert("Reset all local data?", isPresented: $isConfirmingResetAll) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetAllLocalData()
            }
        } message: {
            Text("This clears events, logs, insights, AI learning, templates, keys, and local preferences.")
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
