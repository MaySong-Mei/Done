//
//  AgentSettingsView.swift
//  Done
//

import SwiftUI

struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("agentAPIKey") private var apiKey = ""
    @AppStorage("calendarAgenticCreateEnabled") private var calendarAgenticCreateEnabled = true
    @AppStorage("agentAskBeforeCreatingEventTypeTemplates") private var askBeforeCreatingEventTypeTemplates = true

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Experimental") {
                    Toggle("Agentic Calendar Create", isOn: $calendarAgenticCreateEnabled)
                    Text("Replaces calendar create form with AI-assisted text/image intake. Images are uploaded to the configured provider only when the provider supports image analysis.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Agent Decisions & Learning") {
                    Toggle("Ask before creating event type templates", isOn: $askBeforeCreatingEventTypeTemplates)

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

                    Text("Learning is stored locally on this device and currently uses explicit choices (including 'Tell Done to do otherwise').")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Agent Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
