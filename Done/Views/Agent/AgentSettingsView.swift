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
    @EnvironmentObject private var authService: AuthService
    // Only the System Status card reads settings values directly now; the
    // per-row summaries were removed, so the rest of the @AppStorage mirrors
    // they relied on are gone too.
    @AppStorage(AppSettingsKeys.agentProvider) private var selectedProvider = AppSettingsKeys.agentProviderDefault
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true

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
                    ConnectionsView()
                        .environmentObject(authService)
                } label: {
                    settingsLinkRow(title: L(.connections))
                }
                .buttonStyle(SettingsRowButtonStyle())
            }

            settingsCard(spacing: 14) {
                NavigationLink {
                    ExperimentalSettingsView()
                } label: {
                    settingsLinkRow(title: L(.experimental))
                }
                .buttonStyle(SettingsRowButtonStyle())

                NavigationLink {
                    DataPrivacySettingsView()
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .environmentObject(skillStore)
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
                        Text(authService.isSignedIn ? L(.meSyncAccount) : L(.meSignInToSync))
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
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.wanna.rawValue
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
                    options: RootTab.allCases.map { ($0.rawValue, L($0.titleKey)) },
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
    // Default MUST match the renderer's @AppStorage default in TimelineView so
    // the toggle reflects the real state when the key is absent.
    @AppStorage(AppSettingsKeys.useCALayerTimeline) private var useCALayerTimeline = true

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

            settingsCard("Calendar Renderer") {
                Toggle(isOn: $useCALayerTimeline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use CALayer timeline (new renderer)")
                            .font(.subheadline.weight(.medium))
                        Text("On = the new UIKit + CALayer timeline (default). Off = the legacy SwiftUI renderer. Toggle to A/B compare performance and visuals; the calendar updates live.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var restoreCoordinator: RestoreCoordinator
    @EnvironmentObject private var imageBackupCoordinator: ImageBackupCoordinator
    @EnvironmentObject private var syncStatusReporter: SyncStatusReporter
    @EnvironmentObject private var syncService: SupabaseSyncService
    @AppStorage(AppSettingsKeys.syncUploadsEnabled) private var syncUploadsEnabled = false
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

            settingsCard("Sync", spacing: 14) {
                Toggle(isOn: $syncUploadsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upload this device's data to the cloud")
                            .font(.subheadline.weight(.medium))
                        Text("When off, this device only reads (restore still works). Off by default so a fresh install never surprise-writes your cloud data. Independent per device — your other devices keep their own setting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #if DEBUG
                Text("Debug build: uploads are blocked regardless of this toggle as an extra safety net. Use a Release build to actually exercise the cloud write path.")
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
                    Text("Uploads are off for this device. Flip the Sync toggle above to start pushing changes to the cloud.")
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
                        Text("Calendar Sync Snapshot")
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
        .onChange(of: syncUploadsEnabled) { oldValue, newValue in
            // OFF → ON: catch the cloud up with everything that accumulated
            // while uploads were paused. Triggers a full structured-data
            // sync and clears the image-suppression cache so previously
            // skipped images get re-evaluated.
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
                resetAllLocalData()
            }
        } message: {
            Text(L(.hintResetAllData))
        }
    }

    private func resetAllLocalData() {
        // Disable uploads first. Without this, the debounced sinks fired
        // by the wipes below (EventStore @Published, didChangeNotification
        // from each removeObject) would fire 2-5s later, see canUpload
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
        for key in AppSettingsKeys.resettableUserDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        // Sync diff-hash maps are keyed per-userId, so they aren't in the
        // static resettable list — wipe them with a prefix scan instead.
        SupabaseSyncService.wipeAllPersistedHashes()

        // Additional UserDefaults blobs that aren't in the static
        // resettable list but ARE user-owned state per the full-backup
        // audit. Missing these meant "Reset all" kept conversations /
        // avatar slot / log-template preferences / etc. across the reset.
        defaults.removeObject(forKey: AgentConversationsStorageKey)
        defaults.removeObject(forKey: EventLogTemplatePreferenceStore.storageKey)
        defaults.removeObject(forKey: "eventTypeColorHistory")
        defaults.removeObject(forKey: "skillAnalyzedEventIds")
        // Per-user keys (prefix scan, same shape as wipeAllPersistedHashes):
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("lastSyncedAvatarVersion.") || key.hasPrefix("hasOfferedAutoRestore.") {
            defaults.removeObject(forKey: key)
        }
        // Avatar file on disk (UserDefaults-only reset won't catch it).
        MeAvatarStore.delete()
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
