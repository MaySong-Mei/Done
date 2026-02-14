//
//  AgentSettingsView.swift
//  Done
//

import SwiftUI

struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agentProvider") private var selectedProvider = "claude"
    @AppStorage("agentAPIKey") private var apiKey = ""

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
}
