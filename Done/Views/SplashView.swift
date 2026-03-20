//
//  SplashView.swift
//  Done
//

import SwiftUI

struct SplashView: View {
    @EnvironmentObject private var store: EventStore
    @State private var welcomeText: String = ""
    @State private var displayedText: String = ""
    @State private var showContent = false
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var typingFinished = false
    @State private var dismissing = false
    @State private var showTapHint = false

    private let fallbackMessages = [
        "New day, new wins. Let's get it done.",
        "Your goals are waiting. Let's make progress.",
        "Small steps, big results. Ready when you are.",
        "Focus on what matters. You've got this.",
        "One task at a time. Let's begin.",
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // App Icon
                AppIconView()
                    .frame(width: 100, height: 100)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                // App Name
                Text("Done")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .opacity(logoOpacity)

                // AI Welcome Message
                Text(displayedText)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .frame(minHeight: 44)
                    .opacity(textOpacity)

                Spacer()

                // Tap to continue hint
                Text("tap to continue")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .opacity(showTapHint ? 1 : 0)
                    .padding(.bottom, 60)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !dismissing else { return }
            dismiss()
        }
        .task {
            // Animate logo in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }

            // Show tap hint shortly after logo
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.easeIn(duration: 0.3)) {
                showTapHint = true
            }

            // Fetch AI welcome message
            let message = await generateWelcomeMessage()
            welcomeText = message

            // Start typing animation after a brief pause
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeIn(duration: 0.2)) {
                textOpacity = 1.0
            }

            await typeText(message)

            withAnimation(.easeIn(duration: 0.3)) {
                typingFinished = true
            }

            // Auto-dismiss after a delay
            try? await Task.sleep(for: .seconds(3))
            if !dismissing {
                dismiss()
            }
        }
    }

    private func dismiss() {
        dismissing = true
        withAnimation(.easeOut(duration: 0.35)) {
            showContent = true
        }
        // Notify parent to transition
        NotificationCenter.default.post(name: .splashDidFinish, object: nil)
    }

    private func typeText(_ text: String) async {
        for char in text {
            displayedText.append(char)
            let delay = char == "." || char == "," || char == "!" || char == "?" ? 80 : 30
            try? await Task.sleep(for: .milliseconds(delay))
        }
    }

    private func generateWelcomeMessage() async -> String {
        let providerType = UserDefaults.standard.string(forKey: "agentProvider") ?? "claude"
        let apiKey = UserDefaults.standard.string(forKey: "agentAPIKey") ?? ""

        guard !apiKey.isEmpty else {
            return fallbackMessages.randomElement()!
        }

        let provider: any LLMProvider
        switch providerType {
        case "openai":
            provider = OpenAIProvider(apiKey: apiKey)
        case "deepseek":
            provider = DeepSeekProvider(apiKey: apiKey)
        default:
            provider = ClaudeProvider(apiKey: apiKey)
        }

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        case 17..<21: timeOfDay = "evening"
        default: timeOfDay = "night"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: now)

        let activeTodos = store.activeEvents.count
        let completedTodos = store.completedCount

        var contextParts: [String] = []
        contextParts.append("Time: \(weekday) \(timeOfDay)")
        if activeTodos > 0 { contextParts.append("\(activeTodos) active tasks") }
        if completedTodos > 0 { contextParts.append("\(completedTodos) tasks completed so far") }

        let context = contextParts.joined(separator: ", ")

        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .user,
                    content: "Generate a single short welcome greeting (under 15 words) for a productivity app user. Be warm, motivational, and specific to their context. No quotes, no emoji. Context: \(context)"
                )
            ],
            tools: [],
            systemPrompt: "You write ultra-concise, warm greetings for a productivity app splash screen. Reply with ONLY the greeting text. Keep it under 15 words. Match the language style to be natural and encouraging."
        )

        do {
            let response = try await provider.send(request)
            if let text = response.content?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count < 100 {
                return text
            }
        } catch {
            // Fall through to fallback
        }

        return fallbackMessages.randomElement()!
    }
}

private struct AppIconView: View {
    var body: some View {
        if let icon = loadAppIcon() {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .primary.opacity(0.08), radius: 12, y: 4)
        } else {
            // Fallback styled icon
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.blue.gradient)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .primary.opacity(0.08), radius: 12, y: 4)
        }
    }

    private func loadAppIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
              let iconName = iconFiles.last else {
            return nil
        }
        return UIImage(named: iconName)
    }
}

extension Notification.Name {
    static let splashDidFinish = Notification.Name("splashDidFinish")
}
