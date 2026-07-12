import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey) ?? "en") ?? .english
    }

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en")
        case .chinese: return Locale(identifier: "zh_CN")
        }
    }
}

enum AppSettingsLocale {
    static let languageKey = "appLanguage"
    static let timeFormatKey = "appTimeFormat"
}

enum AppTimeFormat: String, CaseIterable, Identifiable {
    case twelve = "12h"
    case twentyFour = "24h"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twelve: return "12h (3:00 pm)"
        case .twentyFour: return "24h (15:00)"
        }
    }

    static var current: AppTimeFormat {
        AppTimeFormat(rawValue: UserDefaults.standard.string(forKey: AppSettingsLocale.timeFormatKey) ?? "24h") ?? .twentyFour
    }

    var is24: Bool { self == .twentyFour }
}

/// Global lookup. Call `L(.key)` anywhere to get the localized string.
func L(_ key: LKey) -> String {
    let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey) ?? "en") ?? .english
    return key.text(for: lang)
}

// MARK: - String Keys

enum LKey {
    // Tabs
    case tabWanna, tabCalendar, tabReport, tabMe

    // Common
    case cancel, done, save, delete, edit, add, submit, dismiss, search, today, back, create, newEvent, timeFormat
    case noEvents, noMoreEvents, noEventsToday

    // Settings
    case settings, general, aiAndAgent, recordingAndWorkflow, analysisPreferences, dataAndPrivacy
    case appearance, appearanceSystem, appearanceLight, appearanceDark
    case status, provider, apiKey, learnedRules, enterApiKey, notConfigured, keySaved
    case missing, configured, llmProvider, defaultTab
    case experimental, multiTypeEvents, enableMultiTypeEvents, maxTypesPerEvent
    case tags, addTag, enterTag
    // Calendar header settings
    case headerTools, dragToCreate, eventBlock, focusMode, titleFontSize
    case rememberViewMode, returnToTodayOnTabSwitch, snapToAdjacentEvents
    case showTimeBelowTitle, confirmBeforeTracking
    // Detail header settings
    case eventDetailPage, detailTools
    // Connections
    case connections, aiConnector, aiSnapshot
    // Edit profile
    case editProfile, name, color, hideFromMeTab
    case behavior, learning, controls, launch, interface, workflow, defaults, privacy, manageData, storage
    case clearLearnedPreferences, clearDecisionHistory, clearSkillInsights, clearTokenCache, resetAllData
    case noLearnedPreferences
    case aiTypeSuggestionsAfterSave, askBeforeCreatingTemplates
    case rememberLastTab, showTimerBanner, landscapeFocusMode, landscapeFocusKeepAwake, enableAiTypeSuggestions
    case effortBasedEventOpacity, hintEffortBasedEventOpacity
    case pageOverview, pageReflection
    case showAnalysisSummary, autoLoadSuggestions
    case language
    case preferences
    case holidaysAndTerms, solarTerms24, gregorianHolidays, hintHolidays
    case anniversaries, addAnniversary, hintAnniversaries, noPerson, displayOnCalendar
    case ok
    case mealEstimateCalories, mealAnalyzing, mealNoPhoto, mealNoAPIKey, mealVisionUnsupported, mealAnalysisFailed
    case personality, personalityGenerate, personalityGenerating, personalityConfigureHint, personalityFailed
    case achievementUnlocked, trophies, achievementsInProgress, recentlyEarned, seeAll

    // Settings hints
    case hintApiKeyClaude, hintApiKeyOpenAI, hintApiKeyDeepSeek
    case hintTypeSuggestions, hintDefaultTab, hintLandscapeAndAgent
    case hintLearning, hintAnalysisPeriod, hintLocalData, hintClearData
    case hintClearSkillInsights, hintClearTokenCache, hintResetAllData
    case hintLabsFeatures, hintMultiTypeEvents
    case hintHeaderTools, hintCalendarBehavior, hintDragSnap, hintEventBlock
    case hintFocusModeConfirm, hintDetailTools
    case hintAiConnector, hintAiSnapshot
    case hintHideFromMe

    // Settings alerts
    case alertClearSkillInsights, alertClearTokenCache, alertResetAllData
    case clear, reset

    // Calendar & Events
    case overview, images, interruptRelation, timeline, suggestions
    case eventNotFound, occurrenceUnavailable, notAvailableAllDay, comingSoon
    case detail, log
    case addNote
    case thisEvent, thisAndFuture, allEvents
    case deleteConfirmSingle, deleteConfirmAll

    // Event Form
    case title, type, allDay, time, location, repeatLabel, description, agenticInput
    case starts, ends, eventTitlePlaceholder, addLocation, endDate
    case kind, kindEvent, kindTodo, deadline, preferredTime
    // Todo detail page (absorption / deadline / done)
    case todoSectionTodo, todoSectionDone, markDone, markActive
    case noDeadline, hasDeadline
    case absorption, absorbIntoEvent, absorbedInto, releaseLabel, releaseAbsorption
    case absorbIntoTitle, addAbsorption, addAbsorptionTitle
    case searchEventsPrompt, searchTodosPrompt, untitledEvent, untitledTodo
    case absorbedTodos
    // Calendar range modes (View menu)
    case rangeDay, rangeThreeDay, rangeWeek, rangeMonth, rangeStream
    // Me / weekly analysis
    case weekActive, weekDoneCountFormat, weekEventsCompletedFormat, reflectionPrompt
    // Generic actions / labels (sweep)
    case closeLabel, applyLabel, setLabel, removeLabel, tryAgainLabel
    case copyLabel, copiedLabel, hideLabel, revealLabel, regenerateLabel
    case completeLabel, startLabel, endLabel, priorityLabel, scheduleLabel
    case goLabel, stopLabel, signalsLabel
    // Calendar detail (sweep)
    case detailNote, detailInterrupt, detailParallel, makePrimary, primaryBadge
    case calendarEventFallback, recurringLabel, liveLabel, parallelWith
    case noNotesYet, noteOptional, originalOccurrenceUnavailable
    case dropNoteAtFormat, scheduledActiveFormat
    case newInterruptFormat, editInterruptFormat, parallelRangeFormat
    case deletedEventFallback, messageAboutEventPlaceholder
    // Interrupt composer (sweep)
    case captureLiveInterruption, createParallelInterruption
    case startsNowCommits, liveOn, liveOff, startLive
    // Event log sheet (sweep)
    case logHumanContextHint, logStructureHint
    // Calendar event form (sweep)
    case visionUsed, visionTextOnly, visionLabelFormat
    // Calendar page / share cards (sweep)
    case shareDay, shareEvent, shareWeek, nothingScheduled, noInterruptsOrNotes
    case jumpToCalendarA11y
    // Wanna (sweep)
    case wannaFallback, recallFromCalendar, pushToCalendar, addDeadline
    case tapToAddNote, removeDeadline, iWannaPlaceholder, whatDoYouWanna
    case overdueDHFormat, dueInDHFormat
    // Todo / event form (sweep)
    case addToCalendar, enterTitle, enterTagReturn, addRange, ddlLabel, setDeadline
    case splitTitle, subTasks, adjustSubtasksPlaceholder, applySplitFormat
    case templateName, pickColor, noCompletedEvents, noDeletedEvents, deletedLabel
    // Analysis (sweep)
    case periodPickerLabel, timeAllocation, dailyHours, taskCompletions, skillsLabel
    case doneLearningWhoYouAre, savedConfirmation, canReadLast7Days
    case choosePhoto, replacePhoto, removePhoto, aiSuggestionsTitle, tapRefreshSuggestions
    // Decision card (sweep)
    case tellDoneStep, tellDoneOtherwise
    // Account / AI connector (sweep)
    case accountTitle, userId, connectedLabel, signOut, signInToSyncShort
    case signInWithApple, signInWithGoogle, setUpAiConnection, generateConnectorHint
    case aiConnectorUrl, activeStatus, ephemeralLinkHint
    // Agent chat / history (sweep)
    case agentFallback, messagePlaceholder, chatsTitle
    // Sync settings (sweep)
    case uploadToCloud, uploadToCloudHint, uploadsOffHint, calendarSyncSnapshot
    // Restore sheet (sweep)
    case previewCloudBackup, restoreFromCloud, replaceLocalConfirm, replaceLocalData
    case unsyncedLostWarning, fetchingFromCloud, applyingRestore, noCloudData
    case previewOnlyNoChanges, mergeLabel, mergeHint, cloudOverwritesLocal
    case cloudOverwritesLocalHint, keepAllLocal, keepAllLocalHint, keepAllCloud
    case keepAllCloudHint, reviewEachIndividually, reviewEachHint, applyMerge
    case restoreComplete, restoreFailed, keepLocal, keepCloud

    // People & Friend Groups
    case withWhom, people, friendGroups, peopleAndGroups, selectPeople
    case addPerson, newPerson, newGroup, personNamePlaceholder, groupNamePlaceholder
    case members, noPeopleYet, managePeopleAndGroups
    case editPerson, defaultGroup

    // Reminders (calendar pull-down panel)
    case reminders, newReminderPlaceholder, addToSchedule, noRemindersYet, reminderCountFormat

    case never, daily, weekly, monthly, yearly
    case onDate, afterCount
    case moreOptions, deleteEvent
    case originalText, aiMetadata

    // Log
    case logEvent, template, completion, note, effort, emotion, behaviorLabel
    case saveLog, editAndSaveLog, none
    case completed, partial, skipped

    // Agenda
    case agenda

    // Analysis / Profile
    case analysis, thisWeek, systemStatus, explore
    case topSkill, noSkillData
    case hours, active, streak
    case profileSubtitle, analysisSummary, settingsSummary
    case recordRate, completionRate, activeTasks, days
    case momentumStrongest, useSettingsHint
    case providerLabel, typeSuggestions, learnedRulesLabel, on, off
    case analysisPeriod, insightsStored, pendingDecisions
    case skillLeadsWeek, completeToSeeWeekly

    // Agentic Create
    case warnings

    // Search
    case searchEvents, searchPlaceholder, searchHint
    case openEvent, jumpToCalendar, openLog

    // Widget
    case focusRing, miniTimeline, timelineBar
    case focusRingDesc, miniTimelineDesc, timelineBarDesc, doneWidgetDesc
    case next, now
    case mLeft, hLeft, hmLeft
    case upNext

    // Decision Card
    case recommended, dismissToDefault, dismissToApply

    // Focus
    case left

    // Header / detail tool labels
    case toolAgent, toolView, toolFocus, toolShare, toolChat

    // Settings list summaries
    case sumRememberLastTab, sumStartOn, sumTimerBanner
    case sumAllInMenu, sumRememberView, sumAutoToday
    case sumLandscapeFocus, sumKeepAwake, sumEffortOpacity
    case sumKeyMissing, sumKeyConfigured
    case sumAutoSuggestions, sumDefaultSuffix, sumSetupAiApps
    case sumMultiTypeOn, sumStoredLocally
    case unitPeople, unitGroups, unitRules, unitMax, unitInsights, unitCalendarItems
    case periodDay, periodWeek, periodMonth
    case meSyncAccount, meSignInToSync

    // Generative report (Discussion #111) — user-visible failure states
    case reportErrorNoAPIKey, reportErrorGenerationFailed, reportErrorEmptyResponse
    // On-device Apple Foundation Models provider
    case providerAppleOnDevice, hintProviderApple
    case afmErrorDeviceUnsupported, afmErrorIntelligenceDisabled, afmErrorModelNotReady
    // Generative report — card, detail, and history UI
    case reportTitle, reportGenerate, reportGenerating, reportEmpty, reportRetry
    case reportHistoryTitle, reportHistoryEmpty, reportGeneratedByFormat
    case reportKindDaily, reportKindWeekly, reportKindMonthly
    case reportChartDailyRhythm, reportChartByCategory
    case reportNotePlaceholder

    func text(for lang: AppLanguage) -> String {
        switch lang {
        case .english: return en
        case .chinese: return zh
        }
    }

    // MARK: - English

    private var en: String {
        switch self {
        // Tabs
        case .tabWanna: return "Wanna"
        case .tabCalendar: return "Calendar"
        case .tabReport: return "Report"
        case .tabMe: return "Me"

        // Common
        case .cancel: return "Cancel"
        case .done: return "Done"
        case .save: return "Save"
        case .delete: return "Delete"
        case .edit: return "Edit"
        case .add: return "Add"
        case .submit: return "Submit"
        case .dismiss: return "Dismiss"
        case .search: return "Search"
        case .today: return "Today"
        case .back: return "Back"
        case .create: return "Create"
        case .newEvent: return "New Event"
        case .timeFormat: return "Time Format"
        case .appearance: return "Appearance"
        case .appearanceSystem: return "System"
        case .appearanceLight: return "Light"
        case .appearanceDark: return "Dark"
        case .noEvents: return "No events"
        case .noMoreEvents: return "No more events"
        case .noEventsToday: return "No events today"

        // Settings
        case .settings: return "Settings"
        case .general: return "General"
        case .aiAndAgent: return "AI & Agent"
        case .recordingAndWorkflow: return "Recording & Workflow"
        case .analysisPreferences: return "Analysis Preferences"
        case .dataAndPrivacy: return "Data & Privacy"
        case .status: return "Status"
        case .provider: return "Provider"
        case .apiKey: return "API Key"
        case .learnedRules: return "Learned Rules"
        case .enterApiKey: return "Enter your API key"
        case .notConfigured: return "Not configured"
        case .keySaved: return "Key saved"
        case .missing: return "Missing"
        case .configured: return "Configured"
        case .llmProvider: return "LLM Provider"
        case .defaultTab: return "Default tab"
        case .experimental: return "Experimental"
        case .multiTypeEvents: return "Multi-type events"
        case .enableMultiTypeEvents: return "Enable multi-type events"
        case .maxTypesPerEvent: return "Max types per event"
        case .hintLabsFeatures: return "Labs features are experimental and may change, break, or be removed without notice. Your existing data is always preserved when toggling them off."
        case .hintMultiTypeEvents: return "When enabled, an event can carry up to the configured number of types. The Reflection page shows them as a stack of cards — the top card is the primary type. Tap any other card to make it primary, or long-press for more options. Turning this off hides the editor but keeps the data — re-enabling restores it."
        case .tags: return "Tags"
        case .addTag: return "Add Tag"
        case .enterTag: return "Enter tag"
        case .headerTools: return "Header Tools"
        case .dragToCreate: return "Drag-to-Create"
        case .eventBlock: return "Event Block"
        case .focusMode: return "Focus Mode"
        case .titleFontSize: return "Title Font Size"
        case .rememberViewMode: return "Remember View Mode"
        case .returnToTodayOnTabSwitch: return "Return to Today on Tab Switch"
        case .snapToAdjacentEvents: return "Snap to Adjacent Events"
        case .showTimeBelowTitle: return "Show Time Below Title"
        case .confirmBeforeTracking: return "Confirm Before Tracking"
        case .eventDetailPage: return "Event Detail"
        case .detailTools: return "Detail Tools"
        case .connections: return "Connections"
        case .aiConnector: return "AI Connector"
        case .aiSnapshot: return "AI Snapshot"
        case .editProfile: return "Edit profile"
        case .name: return "Name"
        case .color: return "Color"
        case .hideFromMeTab: return "Hide from Me tab"
        case .hintHeaderTools: return "Enabled tools show in the header bar; the rest go in the \u{2026} menu."
        case .hintCalendarBehavior: return "Restore your last view on reopen, and jump to today when you return to the calendar."
        case .hintDragSnap: return "Drag-created events snap their edges to nearby events."
        case .hintEventBlock: return "Sets the font size inside event blocks, and optionally shows the time below the title."
        case .hintFocusModeConfirm: return "Preview and adjust before tracking, instead of starting immediately."
        case .hintDetailTools: return "Enabled tools show in the event detail header; the rest go in the \u{2026} menu."
        case .hintAiConnector: return "A permanent URL that lets Claude, ChatGPT, or other AI apps read your Done data on demand to help you plan."
        case .hintAiSnapshot: return "A short-lived link containing your recent schedule and activity. Paste it into a fresh AI conversation."
        case .hintHideFromMe: return "Background time like sleep, meals, commute. Counted but not shown in identity visuals."
        case .behavior: return "Behavior"
        case .learning: return "Learning"
        case .controls: return "Controls"
        case .launch: return "Launch"
        case .interface: return "Interface"
        case .preferences: return "Preferences"
        case .holidaysAndTerms: return "Holidays & Anniversaries"
        case .solarTerms24: return "24 Solar Terms"
        case .gregorianHolidays: return "Holidays"
        case .hintHolidays: return "Shown as small labels on calendar dates. These are display-only markers — they are not events, do not sync, and cannot be tapped or edited."
        case .anniversaries: return "Anniversaries"
        case .addAnniversary: return "Add Anniversary"
        case .hintAnniversaries: return "Your own dates recur yearly and show as calendar labels."
        case .displayOnCalendar: return "Show on calendar"
        case .ok: return "OK"
        case .mealEstimateCalories: return "Estimate calories (AI)"
        case .mealAnalyzing: return "Analyzing…"
        case .mealNoPhoto: return "Add a food photo first."
        case .mealNoAPIKey: return "Set up your AI key in Settings first."
        case .mealVisionUnsupported: return "The current AI provider (%@) can't read images. Switch to Claude or OpenAI in Settings."
        case .mealAnalysisFailed: return "Couldn't analyze the photo. Please try again."
        case .noPerson: return "None"
        case .personality: return "Personality"
        case .personalityGenerate: return "Generate"
        case .personalityGenerating: return "Reading your records…"
        case .personalityConfigureHint: return "Set up AI in Settings to generate your personality tags."
        case .personalityFailed: return "Couldn't generate right now. Try again."
        case .achievementUnlocked: return "Unlocked"
        case .trophies: return "Trophies"
        case .achievementsInProgress: return "In progress"
        case .recentlyEarned: return "Recently earned"
        case .seeAll: return "All"
        case .workflow: return "Workflow"
        case .defaults: return "Defaults"
        case .privacy: return "Privacy"
        case .manageData: return "Manage Data"
        case .storage: return "Storage"
        case .clearLearnedPreferences: return "Clear Learned Preferences"
        case .clearDecisionHistory: return "Clear Decision History"
        case .clearSkillInsights: return "Clear Skill Insights"
        case .clearTokenCache: return "Clear Token Inference Cache"
        case .resetAllData: return "Reset All Local Data"
        case .noLearnedPreferences: return "No learned preferences yet."
        case .aiTypeSuggestionsAfterSave: return "AI type suggestions after save"
        case .askBeforeCreatingTemplates: return "Ask before creating event type templates"
        case .rememberLastTab: return "Remember last viewed tab"
        case .showTimerBanner: return "Show active timer banner"
        case .landscapeFocusMode: return "Auto-enter focus mode on rotation"
        case .landscapeFocusKeepAwake: return "Keep screen awake in landscape focus"
        case .enableAiTypeSuggestions: return "Enable AI type suggestions"
        case .effortBasedEventOpacity: return "Effort-based event opacity"
        case .hintEffortBasedEventOpacity: return "Events fade by logged effort — higher effort is more opaque, unlogged is semi-transparent."
        case .pageOverview: return "Overview"
        case .pageReflection: return "Reflection"
        case .showAnalysisSummary: return "Show analysis summary on Me"
        case .autoLoadSuggestions: return "Auto-load AI suggestions"
        case .language: return "Language"

        // Settings hints
        case .hintApiKeyClaude: return "Get your API key from console.anthropic.com"
        case .hintApiKeyOpenAI: return "Get your API key from platform.openai.com"
        case .hintApiKeyDeepSeek: return "Get your API key from platform.deepseek.com"
        case .hintTypeSuggestions: return "When enabled, calendar forms can preselect a type while you type using existing event history and local heuristics, then ask AI after save if needed."
        case .hintDefaultTab: return "If last tab memory is enabled, the default tab is only used when there is no previous selection yet."
        case .hintLandscapeAndAgent: return "Rotate to landscape to auto-enter immersive focus; the focus screen can stay awake to avoid auto-lock. AI type suggestions preselect a type from your history while you type."
        case .hintLearning: return "Learning is stored locally on this device and is currently based on explicit decisions."
        case .hintAnalysisPeriod: return "The selected period is applied when opening analysis from a new session. Auto-loading suggestions can make the analysis page feel heavier on large data sets."
        case .hintLocalData: return "Settings, insights, templates, and AI learning are kept on this device."
        case .hintClearData: return "Done currently keeps its data locally on this device. Clearing data below cannot be undone."
        case .hintClearSkillInsights: return "This removes all saved skill growth data and analysis markers."
        case .hintClearTokenCache: return "This removes cached token projections and dynamic hypotheses."
        case .hintResetAllData: return "This clears events, logs, insights, AI learning, templates, keys, and local preferences."

        // Settings alerts
        case .alertClearSkillInsights: return "Clear skill insights?"
        case .alertClearTokenCache: return "Clear token inference cache?"
        case .alertResetAllData: return "Reset all local data?"
        case .clear: return "Clear"
        case .reset: return "Reset"

        // Calendar & Events
        case .overview: return "Overview"
        case .images: return "Images"
        case .interruptRelation: return "Interrupt Relation"
        case .timeline: return "Timeline"
        case .suggestions: return "Suggestions"
        case .eventNotFound: return "Event not found."
        case .occurrenceUnavailable: return "Occurrence unavailable"
        case .notAvailableAllDay: return "Not available for all-day events."
        case .comingSoon: return "Coming soon"
        case .detail: return "Detail"
        case .log: return "Log"
        case .addNote: return "Add note"
        case .thisEvent: return "This Event"
        case .thisAndFuture: return "This & Future Events"
        case .allEvents: return "All Events"
        case .deleteConfirmSingle: return "This occurrence will be deleted."
        case .deleteConfirmAll: return "This event will be permanently deleted."

        // Event Form
        case .title: return "Title"
        case .type: return "Type"
        case .allDay: return "All-day"
        case .time: return "Time"
        case .location: return "Location"
        case .repeatLabel: return "Repeat"
        case .description: return "Description"
        case .agenticInput: return "Agentic Input"
        case .starts: return "Starts"
        case .ends: return "Ends"
        case .eventTitlePlaceholder: return "Event title"
        case .kind: return "Kind"
        case .kindEvent: return "Event"
        case .kindTodo: return "Todo"
        case .deadline: return "Deadline"
        case .preferredTime: return "Preferred Time"
        case .todoSectionTodo: return "Todo"
        case .todoSectionDone: return "Done"
        case .markDone: return "Mark done"
        case .markActive: return "Mark active"
        case .noDeadline: return "No deadline"
        case .hasDeadline: return "Has deadline"
        case .absorption: return "Absorption"
        case .absorbIntoEvent: return "Absorb into event…"
        case .absorbedInto: return "Absorbed into"
        case .releaseLabel: return "Release"
        case .releaseAbsorption: return "Release absorption"
        case .absorbIntoTitle: return "Absorb into…"
        case .addAbsorption: return "Add absorption…"
        case .addAbsorptionTitle: return "Add absorption…"
        case .searchEventsPrompt: return "Search events"
        case .searchTodosPrompt: return "Search todos"
        case .untitledEvent: return "Untitled event"
        case .untitledTodo: return "Untitled todo"
        case .absorbedTodos: return "Absorbed todos"
        case .rangeDay: return "Day"
        case .rangeThreeDay: return "3-Day"
        case .rangeWeek: return "Week"
        case .rangeMonth: return "Month"
        case .rangeStream: return "Timeline Stream"
        case .weekActive: return "active"
        case .weekDoneCountFormat: return "%d done"
        case .weekEventsCompletedFormat: return "%d completed"
        case .reflectionPrompt: return "What stood out this week?"

        // People & Friend Groups
        case .withWhom: return "With"
        case .people: return "People"
        case .friendGroups: return "Groups"
        case .peopleAndGroups: return "People & Groups"
        case .selectPeople: return "Select People"
        case .addPerson: return "Add Person"
        case .newPerson: return "New Person"
        case .newGroup: return "New Group"
        case .personNamePlaceholder: return "Name"
        case .groupNamePlaceholder: return "Group name"
        case .members: return "Members"
        case .noPeopleYet: return "No people yet"
        case .managePeopleAndGroups: return "People & Groups"
        case .editPerson: return "Edit Person"
        case .defaultGroup: return "Default"
        case .reminders: return "Reminders"
        case .newReminderPlaceholder: return "Add a reminder…"
        case .addToSchedule: return "Add to Schedule"
        case .noRemindersYet: return "No reminders"
        case .reminderCountFormat: return "%d reminders"
        case .addLocation: return "Add location"
        case .endDate: return "End date"
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .onDate: return "On date"
        case .afterCount: return "After count"
        case .moreOptions: return "More options"
        case .deleteEvent: return "Delete Event"
        case .originalText: return "Original Text"
        case .aiMetadata: return "AI Metadata"

        // Log
        case .logEvent: return "Log Event"
        case .template: return "Template"
        case .completion: return "Completion"
        case .note: return "Note"
        case .effort: return "Effort"
        case .emotion: return "Emotion"
        case .behaviorLabel: return "Behavior"
        case .saveLog: return "Save Log"
        case .editAndSaveLog: return "Edit and save this event log here."
        case .none: return "None"
        case .completed: return "Completed"
        case .partial: return "Partial"
        case .skipped: return "Skipped"

        // Agenda
        case .agenda: return "Agenda"

        // Analysis / Profile
        case .analysis: return "Analysis"
        case .thisWeek: return "This Week"
        case .systemStatus: return "System Status"
        case .explore: return "Explore"
        case .topSkill: return "Top skill"
        case .noSkillData: return "No skill data yet"
        case .hours: return "Hours"
        case .active: return "Active"
        case .streak: return "Streak"
        case .profileSubtitle: return "Control your workflow, review your patterns, and adjust how Done behaves."
        case .analysisSummary: return "Trends, token hypotheses, skills, and suggestions."
        case .settingsSummary: return "General controls, AI behavior, and local data."
        case .recordRate: return "Record Rate"
        case .completionRate: return "Completion"
        case .activeTasks: return "Active Tasks"
        case .days: return "days"
        case .momentumStrongest: return "Momentum is strongest in"
        case .useSettingsHint: return "Use settings to tune the product, and use analysis to understand your current pattern."
        case .providerLabel: return "Provider"
        case .typeSuggestions: return "Type suggestions"
        case .learnedRulesLabel: return "Learned rules"
        case .on: return "On"
        case .off: return "Off"
        case .analysisPeriod: return "Analysis period"
        case .insightsStored: return "Insights stored"
        case .pendingDecisions: return "Pending decisions"
        case .skillLeadsWeek: return "leads this week with"
        case .completeToSeeWeekly: return "Complete and reflect on a few calendar events to build a clearer weekly picture."

        // Agentic Create
        case .warnings: return "Warnings"

        // Search
        case .searchEvents: return "Search Events"
        case .searchPlaceholder: return "Title, note, log, timeline note..."
        case .searchHint: return "Search by title, note, log summary, or timeline note"
        case .openEvent: return "Open Event"
        case .jumpToCalendar: return "Jump to Calendar"
        case .openLog: return "Open Log"

        // Widget
        case .focusRing: return "Focus Ring"
        case .miniTimeline: return "Mini Timeline"
        case .timelineBar: return "Timeline Bar"
        case .focusRingDesc: return "Circular progress for the current event."
        case .miniTimelineDesc: return "A tiny timeline view of your day."
        case .timelineBarDesc: return "Horizontal progress bar for the current event."
        case .doneWidgetDesc: return "View today's events at a glance."
        case .next: return "Next"
        case .now: return "Now"
        case .mLeft: return "m left"
        case .hLeft: return "h left"
        case .hmLeft: return "left"
        case .upNext: return "Up Next"

        // Decision Card
        case .recommended: return "Recommended"
        case .dismissToDefault: return "Dismiss to use default"
        case .dismissToApply: return "Dismiss to apply default"

        // Focus
        case .left: return "left"

        // Header / detail tool labels
        case .toolAgent: return "Agent"
        case .toolView: return "View"
        case .toolFocus: return "Focus"
        case .toolShare: return "Share"
        case .toolChat: return "Chat"

        // Settings list summaries
        case .sumRememberLastTab: return "Remember last tab"
        case .sumStartOn: return "Start on"
        case .sumTimerBanner: return "Timer banner"
        case .sumAllInMenu: return "All in menu"
        case .sumRememberView: return "remember view"
        case .sumAutoToday: return "auto-today"
        case .sumLandscapeFocus: return "Landscape focus"
        case .sumKeepAwake: return "Keep awake"
        case .sumEffortOpacity: return "Effort opacity"
        case .sumKeyMissing: return "key missing"
        case .sumKeyConfigured: return "key configured"
        case .sumAutoSuggestions: return "Auto suggestions"
        case .sumDefaultSuffix: return "default"
        case .sumSetupAiApps: return "Set up to let AI apps read your data"
        case .sumMultiTypeOn: return "Multi-type events on"
        case .sumStoredLocally: return "stored locally"
        case .unitPeople: return "people"
        case .unitGroups: return "groups"
        case .unitRules: return "rules"
        case .unitMax: return "max"
        case .unitInsights: return "insights"
        case .unitCalendarItems: return "calendar items"
        case .periodDay: return "Day"
        case .periodWeek: return "Week"
        case .periodMonth: return "Month"
        case .meSyncAccount: return "Sync & Account"
        case .meSignInToSync: return "Sign in to sync your data"

        case .reportErrorNoAPIKey: return "Set up your AI key in Settings to generate reports."
        case .reportErrorGenerationFailed: return "Couldn't generate the report. Please try again."
        case .reportErrorEmptyResponse: return "The report came back empty. Please try again."
        case .providerAppleOnDevice: return "On-device (Apple)"
        case .hintProviderApple: return "Runs Apple's on-device model — no API key needed. Requires an Apple Intelligence–capable device with the model downloaded."
        case .afmErrorDeviceUnsupported: return "This device doesn't support Apple's on-device model."
        case .afmErrorIntelligenceDisabled: return "Apple Intelligence is off. Turn it on in Settings to use the on-device model."
        case .afmErrorModelNotReady: return "The on-device model is still downloading. Try again once it finishes."
        case .reportTitle: return "Report"
        case .reportGenerate: return "Generate one"
        case .reportGenerating: return "Writing…"
        case .reportEmpty: return "No reports yet. Generate one to look back on this stretch of time."
        case .reportRetry: return "Try again"
        case .reportHistoryTitle: return "Report History"
        case .reportHistoryEmpty: return "No reports yet"
        case .reportGeneratedByFormat: return "Generated by %@"
        case .reportKindDaily: return "Daily"
        case .reportKindWeekly: return "Weekly"
        case .reportKindMonthly: return "Monthly"
        case .reportChartDailyRhythm: return "Daily rhythm"
        case .reportChartByCategory: return "By category"
        case .reportNotePlaceholder: return "Leave a note — the next report will remember"

        // Sweep additions
        case .closeLabel: return "Close"
        case .applyLabel: return "Apply"
        case .setLabel: return "Set"
        case .removeLabel: return "Remove"
        case .tryAgainLabel: return "Try again"
        case .copyLabel: return "Copy"
        case .copiedLabel: return "Copied!"
        case .hideLabel: return "Hide"
        case .revealLabel: return "Reveal"
        case .regenerateLabel: return "Regenerate"
        case .completeLabel: return "Complete"
        case .startLabel: return "Start"
        case .endLabel: return "End"
        case .priorityLabel: return "Priority"
        case .scheduleLabel: return "Schedule"
        case .goLabel: return "Go"
        case .stopLabel: return "Stop"
        case .signalsLabel: return "Signals"
        case .detailNote: return "Note"
        case .detailInterrupt: return "Interrupt"
        case .detailParallel: return "Parallel"
        case .makePrimary: return "Make primary"
        case .primaryBadge: return "primary"
        case .calendarEventFallback: return "Calendar Event"
        case .recurringLabel: return "Recurring"
        case .liveLabel: return "Live"
        case .parallelWith: return "Parallel with"
        case .noNotesYet: return "No notes or interruptions yet."
        case .noteOptional: return "Note (optional)"
        case .originalOccurrenceUnavailable: return "Original occurrence is no longer available."
        case .dropNoteAtFormat: return "Drop a note at %@"
        case .scheduledActiveFormat: return "%@ scheduled · %@ active"
        case .newInterruptFormat: return "New interrupt %@ – %@"
        case .editInterruptFormat: return "Edit interrupt %@ – %@"
        case .parallelRangeFormat: return "Parallel %@ – %@"
        case .deletedEventFallback: return "Deleted Event"
        case .messageAboutEventPlaceholder: return "Message about this event..."
        case .captureLiveInterruption: return "Capture a live interruption."
        case .createParallelInterruption: return "Create a parallel interruption."
        case .startsNowCommits: return "Starts now and commits when stopped."
        case .liveOn: return "Live On"
        case .liveOff: return "Live Off"
        case .startLive: return "Start Live"
        case .logHumanContextHint: return "Capture the human context while it is still fresh."
        case .logStructureHint: return "Optional structure for when you want a more specific reflection."
        case .visionUsed: return "Used"
        case .visionTextOnly: return "Text-only"
        case .visionLabelFormat: return "Vision: %@"
        case .shareDay: return "Share day"
        case .shareEvent: return "Share event"
        case .shareWeek: return "Share week"
        case .nothingScheduled: return "Nothing scheduled"
        case .noInterruptsOrNotes: return "No interrupts or notes"
        case .jumpToCalendarA11y: return "Jump to calendar"
        case .wannaFallback: return "Wanna"
        case .recallFromCalendar: return "Recall from Calendar"
        case .pushToCalendar: return "Push to Calendar"
        case .addDeadline: return "Add Deadline"
        case .tapToAddNote: return "Tap to add a note..."
        case .removeDeadline: return "Remove Deadline"
        case .iWannaPlaceholder: return "I wanna..."
        case .whatDoYouWanna: return "What do you wanna do?"
        case .overdueDHFormat: return "Overdue %dd %dh"
        case .dueInDHFormat: return "Due in %dd %dh"
        case .addToCalendar: return "Add to Calendar"
        case .enterTitle: return "Enter title"
        case .enterTagReturn: return "Enter tag and press return"
        case .addRange: return "Add Range"
        case .ddlLabel: return "DDL"
        case .setDeadline: return "Set deadline"
        case .splitTitle: return "Split"
        case .subTasks: return "Sub-tasks"
        case .adjustSubtasksPlaceholder: return "Adjust subtasks..."
        case .applySplitFormat: return "Apply Split (%d)"
        case .templateName: return "Template name"
        case .pickColor: return "Pick color"
        case .noCompletedEvents: return "No completed events"
        case .noDeletedEvents: return "No deleted events"
        case .deletedLabel: return "Deleted"
        case .periodPickerLabel: return "Period"
        case .timeAllocation: return "Time Allocation"
        case .dailyHours: return "Daily Hours"
        case .taskCompletions: return "Task Completions"
        case .skillsLabel: return "Skills"
        case .doneLearningWhoYouAre: return "Done is learning who you are."
        case .savedConfirmation: return "Saved."
        case .canReadLast7Days: return "Can read your last 7 days to help you plan."
        case .choosePhoto: return "Choose Photo"
        case .replacePhoto: return "Replace Photo"
        case .removePhoto: return "Remove Photo"
        case .aiSuggestionsTitle: return "AI Suggestions"
        case .tapRefreshSuggestions: return "Tap refresh to get AI-powered suggestions for your schedule."
        case .tellDoneStep: return "3. Tell Done to do otherwise"
        case .tellDoneOtherwise: return "Tell Done what to do instead"
        case .accountTitle: return "Account"
        case .userId: return "User ID"
        case .connectedLabel: return "Connected"
        case .signOut: return "Sign Out"
        case .signInToSyncShort: return "Sign in to sync"
        case .signInWithApple: return "Sign in with Apple"
        case .signInWithGoogle: return "Sign in with Google"
        case .setUpAiConnection: return "Set Up AI Connection"
        case .generateConnectorHint: return "Generate a permanent URL to connect Claude, ChatGPT, or other AI apps to your Done data."
        case .aiConnectorUrl: return "AI Connector URL"
        case .activeStatus: return "Active"
        case .ephemeralLinkHint: return "Creates a 5-minute link with your schedule and activity data. Paste it into ChatGPT or Claude."
        case .agentFallback: return "Agent"
        case .messagePlaceholder: return "Message..."
        case .chatsTitle: return "Chats"
        case .uploadToCloud: return "Upload this device's data to the cloud"
        case .uploadToCloudHint: return "When off, this device only reads (restore still works). Off by default so a fresh install never surprise-writes your cloud data. Independent per device — your other devices keep their own setting."
        case .uploadsOffHint: return "Uploads are off for this device. Flip the Sync toggle above to start pushing changes to the cloud."
        case .calendarSyncSnapshot: return "Calendar Sync Snapshot"
        case .previewCloudBackup: return "Preview Cloud Backup"
        case .restoreFromCloud: return "Restore from Cloud"
        case .replaceLocalConfirm: return "Replace all local data with the cloud snapshot?"
        case .replaceLocalData: return "Replace local data"
        case .unsyncedLostWarning: return "Any local edits not yet synced to the cloud will be permanently lost."
        case .fetchingFromCloud: return "Fetching from cloud…"
        case .applyingRestore: return "Applying restore…"
        case .noCloudData: return "No data found in the cloud for this account."
        case .previewOnlyNoChanges: return "Preview only — no changes made"
        case .mergeLabel: return "Merge"
        case .mergeHint: return "Add cloud rows missing locally. If the same row exists on both sides with different content, you'll be asked how to resolve."
        case .cloudOverwritesLocal: return "Cloud overwrites local"
        case .cloudOverwritesLocalHint: return "Replace everything on this device with the cloud snapshot. Unsynced local changes will be lost."
        case .keepAllLocal: return "Keep all local versions"
        case .keepAllLocalHint: return "On conflict, the device's version wins. Cloud-only rows are still added."
        case .keepAllCloud: return "Keep all cloud versions"
        case .keepAllCloudHint: return "On conflict, the cloud version replaces the device's. Use only if you trust cloud is more up to date."
        case .reviewEachIndividually: return "Review each individually"
        case .reviewEachHint: return "Open every conflict and pick the winner one by one. Cloud-only rows are still added regardless."
        case .applyMerge: return "Apply merge"
        case .restoreComplete: return "Restore complete"
        case .restoreFailed: return "Restore failed"
        case .keepLocal: return "Keep local"
        case .keepCloud: return "Keep cloud"
        }
    }

    // MARK: - Chinese

    private var zh: String {
        switch self {
        // Tabs
        case .tabWanna: return "想做"
        case .tabCalendar: return "日历"
        case .tabReport: return "报告"
        case .tabMe: return "我"

        // Common
        case .cancel: return "取消"
        case .done: return "完成"
        case .save: return "保存"
        case .delete: return "删除"
        case .edit: return "编辑"
        case .add: return "添加"
        case .submit: return "提交"
        case .dismiss: return "关闭"
        case .search: return "搜索"
        case .today: return "今天"
        case .back: return "返回"
        case .create: return "创建"
        case .newEvent: return "新事件"
        case .timeFormat: return "时间格式"
        case .appearance: return "外观"
        case .appearanceSystem: return "跟随系统"
        case .appearanceLight: return "浅色"
        case .appearanceDark: return "深色"
        case .noEvents: return "暂无事件"
        case .noMoreEvents: return "没有更多事件"
        case .noEventsToday: return "今日无事件"

        // Settings
        case .settings: return "设置"
        case .general: return "通用"
        case .aiAndAgent: return "AI 与助理"
        case .recordingAndWorkflow: return "记录与工作流"
        case .analysisPreferences: return "分析偏好"
        case .dataAndPrivacy: return "数据与隐私"
        case .status: return "状态"
        case .provider: return "服务商"
        case .apiKey: return "API 密钥"
        case .learnedRules: return "学习规则"
        case .enterApiKey: return "输入你的 API 密钥"
        case .notConfigured: return "未配置"
        case .keySaved: return "密钥已保存"
        case .missing: return "未设置"
        case .configured: return "已配置"
        case .llmProvider: return "大模型服务商"
        case .defaultTab: return "默认标签"
        case .experimental: return "实验功能"
        case .multiTypeEvents: return "多类型事件"
        case .enableMultiTypeEvents: return "启用多类型事件"
        case .maxTypesPerEvent: return "每个事件最多类型数"
        case .hintLabsFeatures: return "实验功能可能随时变更、损坏或被移除。无论何时关闭，已有数据都会保留。"
        case .hintMultiTypeEvents: return "启用后，一个事件可以承载多个类型，最多到设置的上限。反思页面会把这些类型叠成一摞卡片——顶部那张是主类型。轻点其他卡片可将其设为主类型，长按可查看更多选项。关闭后编辑器会隐藏但数据保留，重新启用即可恢复。"
        case .tags: return "标签"
        case .addTag: return "添加标签"
        case .enterTag: return "输入标签"
        case .headerTools: return "顶部工具"
        case .dragToCreate: return "拖拽创建"
        case .eventBlock: return "事件块"
        case .focusMode: return "专注模式"
        case .titleFontSize: return "标题字号"
        case .rememberViewMode: return "记住视图模式"
        case .returnToTodayOnTabSwitch: return "切换标签时返回今天"
        case .snapToAdjacentEvents: return "吸附相邻事件"
        case .showTimeBelowTitle: return "标题下方显示时间"
        case .confirmBeforeTracking: return "开始追踪前确认"
        case .eventDetailPage: return "事件详情"
        case .detailTools: return "详情工具"
        case .connections: return "连接"
        case .aiConnector: return "AI 连接器"
        case .aiSnapshot: return "AI 快照"
        case .editProfile: return "编辑资料"
        case .name: return "名字"
        case .color: return "颜色"
        case .hideFromMeTab: return "从 Me 标签隐藏"
        case .hintHeaderTools: return "启用的显示在顶部栏，其余收进「…」菜单。"
        case .hintCalendarBehavior: return "重开 app 时恢复上次视图，回到日历时跳回今天。"
        case .hintDragSnap: return "拖拽创建事件时自动吸附到附近事件的边缘。"
        case .hintEventBlock: return "调整事件块内的字号，可选在标题下方显示时间。"
        case .hintFocusModeConfirm: return "进入追踪前先预览调整，而不是立即开始。"
        case .hintDetailTools: return "启用的显示在事件详情顶栏，其余收进「…」菜单。"
        case .hintAiConnector: return "一个永久 URL，允许 Claude、ChatGPT 或其他 AI 应用按需读取你的 Done 数据以协助规划。"
        case .hintAiSnapshot: return "一个短期链接，包含你近期的日程和活动数据。粘贴到新的 AI 对话中即可。"
        case .hintHideFromMe: return "睡眠、吃饭、通勤等背景时间。会被记录但不会显示在身份视觉里。"
        case .behavior: return "行为"
        case .learning: return "学习"
        case .controls: return "控制"
        case .launch: return "启动"
        case .interface: return "界面"
        case .preferences: return "偏好设置"
        case .holidaysAndTerms: return "节日与纪念日"
        case .solarTerms24: return "二十四节气"
        case .gregorianHolidays: return "公历节日"
        case .hintHolidays: return "以小标签形式显示在日历日期上。仅作展示标记——不是事件，不参与同步，也不能点开编辑。"
        case .anniversaries: return "纪念日"
        case .addAnniversary: return "添加纪念日"
        case .hintAnniversaries: return "你自己的纪念日每年重复，会作为标签显示在日历上。"
        case .displayOnCalendar: return "在日历上显示"
        case .ok: return "好"
        case .mealEstimateCalories: return "AI 估算热量"
        case .mealAnalyzing: return "分析中…"
        case .mealNoPhoto: return "请先添加一张餐食照片。"
        case .mealNoAPIKey: return "请先在设置里配置 AI 密钥。"
        case .mealVisionUnsupported: return "当前 AI 服务商(%@)不支持识图,请在设置里切换到 Claude 或 OpenAI。"
        case .mealAnalysisFailed: return "热量识别失败,请重试。"
        case .noPerson: return "无"
        case .personality: return "人格标签"
        case .personalityGenerate: return "生成"
        case .personalityGenerating: return "正在读取你的记录…"
        case .personalityConfigureHint: return "在设置里配置 AI 后即可生成你的人格标签。"
        case .personalityFailed: return "暂时生成失败，再试一次。"
        case .achievementUnlocked: return "已解锁"
        case .trophies: return "成就"
        case .achievementsInProgress: return "进行中"
        case .recentlyEarned: return "最近获得"
        case .seeAll: return "全部"
        case .workflow: return "工作流"
        case .defaults: return "默认设置"
        case .privacy: return "隐私"
        case .manageData: return "管理数据"
        case .storage: return "存储"
        case .clearLearnedPreferences: return "清除学习偏好"
        case .clearDecisionHistory: return "清除决策历史"
        case .clearSkillInsights: return "清除技能洞察"
        case .clearTokenCache: return "清除 Token 推理缓存"
        case .resetAllData: return "重置所有本地数据"
        case .noLearnedPreferences: return "暂无学习偏好。"
        case .aiTypeSuggestionsAfterSave: return "保存后 AI 类型建议"
        case .askBeforeCreatingTemplates: return "创建事件类型模板前先询问"
        case .rememberLastTab: return "记住上次浏览的标签页"
        case .showTimerBanner: return "显示计时器横幅"
        case .landscapeFocusMode: return "横屏旋转自动进入专注"
        case .landscapeFocusKeepAwake: return "横屏专注时保持常亮"
        case .enableAiTypeSuggestions: return "启用 AI 类型建议"
        case .effortBasedEventOpacity: return "按投入度调整事件透明度"
        case .hintEffortBasedEventOpacity: return "事件按投入度调整透明度：投入越高越不透明，未记录的半透明。"
        case .pageOverview: return "概览"
        case .pageReflection: return "记录"
        case .showAnalysisSummary: return "在「我」页面显示分析摘要"
        case .autoLoadSuggestions: return "自动加载 AI 建议"
        case .language: return "语言"

        // Settings hints
        case .hintApiKeyClaude: return "从 console.anthropic.com 获取 API 密钥"
        case .hintApiKeyOpenAI: return "从 platform.openai.com 获取 API 密钥"
        case .hintApiKeyDeepSeek: return "从 platform.deepseek.com 获取 API 密钥"
        case .hintTypeSuggestions: return "启用后，日历表单会根据历史事件和本地推断预选类型，保存后如需要会请求 AI 进一步建议。"
        case .hintDefaultTab: return "如果启用了标签页记忆，默认标签页仅在没有上次选择时生效。"
        case .hintLandscapeAndAgent: return "横屏旋转自动进入沉浸式专注；专注界面可保持常亮防止自动锁屏。AI 类型建议会在日历输入时按历史预选类型。"
        case .hintLearning: return "学习数据存储在本设备上，目前基于你的明确决策。"
        case .hintAnalysisPeriod: return "所选分析周期在新会话打开分析时生效。自动加载建议可能会在大数据集上让分析页面变慢。"
        case .hintLocalData: return "设置、洞察、模板和 AI 学习数据保存在本设备上。"
        case .hintClearData: return "Done 目前将数据保存在本设备上。以下清除操作不可撤销。"
        case .hintClearSkillInsights: return "将移除所有已保存的技能成长数据和分析标记。"
        case .hintClearTokenCache: return "将移除缓存的 Token 预测和动态假设。"
        case .hintResetAllData: return "将清除事件、日志、洞察、AI 学习、模板、密钥和本地偏好。"

        // Settings alerts
        case .alertClearSkillInsights: return "清除技能洞察？"
        case .alertClearTokenCache: return "清除 Token 推理缓存？"
        case .alertResetAllData: return "重置所有本地数据？"
        case .clear: return "清除"
        case .reset: return "重置"

        // Calendar & Events
        case .overview: return "概览"
        case .images: return "图片"
        case .interruptRelation: return "中断关联"
        case .timeline: return "时间线"
        case .suggestions: return "建议"
        case .eventNotFound: return "未找到事件。"
        case .occurrenceUnavailable: return "此次事件不可用"
        case .notAvailableAllDay: return "全天事件不支持此功能。"
        case .comingSoon: return "即将推出"
        case .detail: return "详情"
        case .log: return "日志"
        case .addNote: return "添加笔记"
        case .thisEvent: return "仅此事件"
        case .thisAndFuture: return "此事件及之后"
        case .allEvents: return "所有事件"
        case .deleteConfirmSingle: return "此次事件将被删除。"
        case .deleteConfirmAll: return "此事件将被永久删除。"

        // Event Form
        case .title: return "标题"
        case .type: return "类型"
        case .allDay: return "全天"
        case .time: return "时间"
        case .location: return "地点"
        case .repeatLabel: return "重复"
        case .description: return "描述"
        case .agenticInput: return "AI 输入"
        case .starts: return "开始"
        case .ends: return "结束"
        case .eventTitlePlaceholder: return "事件标题"
        case .kind: return "种类"
        case .kindEvent: return "事件"
        case .kindTodo: return "待办"
        case .deadline: return "截止"
        case .preferredTime: return "期望时间"
        case .todoSectionTodo: return "待办"
        case .todoSectionDone: return "已完成"
        case .markDone: return "标记完成"
        case .markActive: return "标记未完成"
        case .noDeadline: return "无截止时间"
        case .hasDeadline: return "设定截止时间"
        case .absorption: return "归入"
        case .absorbIntoEvent: return "归入事件…"
        case .absorbedInto: return "已归入"
        case .releaseLabel: return "解除"
        case .releaseAbsorption: return "解除归入"
        case .absorbIntoTitle: return "归入…"
        case .addAbsorption: return "添加归入…"
        case .addAbsorptionTitle: return "添加归入…"
        case .searchEventsPrompt: return "搜索事件"
        case .searchTodosPrompt: return "搜索待办"
        case .untitledEvent: return "未命名事件"
        case .untitledTodo: return "未命名待办"
        case .absorbedTodos: return "已归入的待办"
        case .rangeDay: return "单日"
        case .rangeThreeDay: return "三日"
        case .rangeWeek: return "周"
        case .rangeMonth: return "月"
        case .rangeStream: return "时间流"
        case .weekActive: return "活跃"
        case .weekDoneCountFormat: return "完成 %d 件"
        case .weekEventsCompletedFormat: return "完成 %d 件"
        case .reflectionPrompt: return "本周有什么值得记录？"

        // People & Friend Groups
        case .withWhom: return "和谁"
        case .people: return "人员"
        case .friendGroups: return "分组"
        case .peopleAndGroups: return "人员与分组"
        case .selectPeople: return "选择人员"
        case .addPerson: return "添加人员"
        case .newPerson: return "新建人员"
        case .newGroup: return "新建分组"
        case .personNamePlaceholder: return "姓名"
        case .groupNamePlaceholder: return "分组名称"
        case .members: return "成员"
        case .noPeopleYet: return "还没有人员"
        case .managePeopleAndGroups: return "人员与分组"
        case .editPerson: return "编辑人员"
        case .defaultGroup: return "默认"
        case .reminders: return "待办"
        case .newReminderPlaceholder: return "添加待办…"
        case .addToSchedule: return "加入日程"
        case .noRemindersYet: return "暂无待办"
        case .reminderCountFormat: return "%d 个待办"
        case .addLocation: return "添加地点"
        case .endDate: return "结束日期"
        case .never: return "从不"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        case .onDate: return "到指定日期"
        case .afterCount: return "重复次数后"
        case .moreOptions: return "更多选项"
        case .deleteEvent: return "删除事件"
        case .originalText: return "原始文本"
        case .aiMetadata: return "AI 元数据"

        // Log
        case .logEvent: return "记录事件"
        case .template: return "模板"
        case .completion: return "完成情况"
        case .note: return "备注"
        case .effort: return "投入程度"
        case .emotion: return "情绪"
        case .behaviorLabel: return "行为"
        case .saveLog: return "保存日志"
        case .editAndSaveLog: return "在此编辑并保存事件日志。"
        case .none: return "无"
        case .completed: return "已完成"
        case .partial: return "部分完成"
        case .skipped: return "已跳过"

        // Agenda
        case .agenda: return "日程"

        // Analysis / Profile
        case .analysis: return "分析"
        case .thisWeek: return "本周"
        case .systemStatus: return "系统状态"
        case .explore: return "探索"
        case .topSkill: return "最佳技能"
        case .noSkillData: return "暂无技能数据"
        case .hours: return "小时"
        case .active: return "活跃"
        case .streak: return "连续"
        case .profileSubtitle: return "管理你的工作流，回顾你的模式，调整 Done 的行为方式。"
        case .analysisSummary: return "趋势、Token 假设、技能和建议。"
        case .settingsSummary: return "通用控制、AI 行为和本地数据。"
        case .recordRate: return "记录率"
        case .completionRate: return "完成率"
        case .activeTasks: return "活跃任务"
        case .days: return "天"
        case .momentumStrongest: return "势头最强的是"
        case .useSettingsHint: return "通过设置调整产品，通过分析了解你当前的模式。"
        case .providerLabel: return "服务商"
        case .typeSuggestions: return "类型建议"
        case .learnedRulesLabel: return "学习规则"
        case .on: return "开"
        case .off: return "关"
        case .analysisPeriod: return "分析周期"
        case .insightsStored: return "已存洞察"
        case .pendingDecisions: return "待定决策"
        case .skillLeadsWeek: return "本周领先，成长"
        case .completeToSeeWeekly: return "完成并回顾一些日历事件，以构建更清晰的周报。"

        // Agentic Create
        case .warnings: return "警告"

        // Search
        case .searchEvents: return "搜索事件"
        case .searchPlaceholder: return "标题、备注、日志、时间线笔记..."
        case .searchHint: return "按标题、备注、日志摘要或时间线笔记搜索"
        case .openEvent: return "打开事件"
        case .jumpToCalendar: return "跳转到日历"
        case .openLog: return "打开日志"

        // Widget
        case .focusRing: return "专注环"
        case .miniTimeline: return "迷你时间线"
        case .timelineBar: return "时间线进度条"
        case .focusRingDesc: return "当前事件的圆形进度。"
        case .miniTimelineDesc: return "一日行程的迷你时间线。"
        case .timelineBarDesc: return "当前事件的水平进度条。"
        case .doneWidgetDesc: return "一览今日事件。"
        case .next: return "下一个"
        case .now: return "进行中"
        case .mLeft: return "分钟剩余"
        case .hLeft: return "小时剩余"
        case .hmLeft: return "剩余"
        case .upNext: return "即将开始"

        // Decision Card
        case .recommended: return "推荐"
        case .dismissToDefault: return "关闭以使用默认"
        case .dismissToApply: return "关闭以应用默认"

        // Focus
        case .left: return "剩余"

        // Header / detail tool labels
        case .toolAgent: return "助理"
        case .toolView: return "视图"
        case .toolFocus: return "专注"
        case .toolShare: return "分享"
        case .toolChat: return "对话"

        // Settings list summaries
        case .sumRememberLastTab: return "记住上次标签"
        case .sumStartOn: return "启动于"
        case .sumTimerBanner: return "计时器横幅"
        case .sumAllInMenu: return "全部收进菜单"
        case .sumRememberView: return "记住视图"
        case .sumAutoToday: return "自动回到今天"
        case .sumLandscapeFocus: return "横屏专注"
        case .sumKeepAwake: return "保持唤醒"
        case .sumEffortOpacity: return "投入度透明度"
        case .sumKeyMissing: return "未配置密钥"
        case .sumKeyConfigured: return "已配置密钥"
        case .sumAutoSuggestions: return "自动建议"
        case .sumDefaultSuffix: return "默认"
        case .sumSetupAiApps: return "设置后即可让 AI 应用读取你的数据"
        case .sumMultiTypeOn: return "多类型事件已开启"
        case .sumStoredLocally: return "本地存储"
        case .unitPeople: return "人"
        case .unitGroups: return "组"
        case .unitRules: return "条规则"
        case .unitMax: return "最多"
        case .unitInsights: return "条洞察"
        case .unitCalendarItems: return "个日历项"
        case .periodDay: return "日"
        case .periodWeek: return "周"
        case .periodMonth: return "月"
        case .meSyncAccount: return "同步与账户"
        case .meSignInToSync: return "登录以同步数据"

        case .reportErrorNoAPIKey: return "生成报告前，请先在设置里配置 AI 密钥。"
        case .reportErrorGenerationFailed: return "报告生成失败，请重试。"
        case .reportErrorEmptyResponse: return "报告返回为空，请重试。"
        case .providerAppleOnDevice: return "端上模型 (Apple)"
        case .hintProviderApple: return "使用 Apple 端上模型，无需 API 密钥。需要支持 Apple Intelligence 的设备并已下载模型。"
        case .afmErrorDeviceUnsupported: return "此设备不支持 Apple 端上模型。"
        case .afmErrorIntelligenceDisabled: return "Apple Intelligence 未开启。请在系统设置中开启后再使用端上模型。"
        case .afmErrorModelNotReady: return "端上模型仍在下载中，下载完成后请重试。"
        case .reportTitle: return "报告"
        case .reportGenerate: return "生成一份"
        case .reportGenerating: return "生成中…"
        case .reportEmpty: return "还没有报告。生成一份，回看你这段时间。"
        case .reportRetry: return "重试"
        case .reportHistoryTitle: return "报告历史"
        case .reportHistoryEmpty: return "还没有报告"
        case .reportGeneratedByFormat: return "由 %@ 生成"
        case .reportKindDaily: return "日报"
        case .reportKindWeekly: return "周报"
        case .reportKindMonthly: return "月报"
        case .reportChartDailyRhythm: return "每日节奏"
        case .reportChartByCategory: return "类目时长"
        case .reportNotePlaceholder: return "写点回应——下一份报告会记得"

        // Sweep additions
        case .closeLabel: return "关闭"
        case .applyLabel: return "应用"
        case .setLabel: return "设置"
        case .removeLabel: return "移除"
        case .tryAgainLabel: return "重试"
        case .copyLabel: return "复制"
        case .copiedLabel: return "已复制！"
        case .hideLabel: return "隐藏"
        case .revealLabel: return "显示"
        case .regenerateLabel: return "重新生成"
        case .completeLabel: return "完成"
        case .startLabel: return "开始"
        case .endLabel: return "结束"
        case .priorityLabel: return "优先级"
        case .scheduleLabel: return "安排"
        case .goLabel: return "前往"
        case .stopLabel: return "停止"
        case .signalsLabel: return "信号"
        case .detailNote: return "笔记"
        case .detailInterrupt: return "打断"
        case .detailParallel: return "并行"
        case .makePrimary: return "设为主要"
        case .primaryBadge: return "主要"
        case .calendarEventFallback: return "日历事件"
        case .recurringLabel: return "重复"
        case .liveLabel: return "实时"
        case .parallelWith: return "并行于"
        case .noNotesYet: return "暂无笔记或打断。"
        case .noteOptional: return "笔记（可选）"
        case .originalOccurrenceUnavailable: return "原始事件已不存在。"
        case .dropNoteAtFormat: return "在 %@ 记一笔"
        case .scheduledActiveFormat: return "计划 %@ · 实际 %@"
        case .newInterruptFormat: return "新建打断 %@ – %@"
        case .editInterruptFormat: return "编辑打断 %@ – %@"
        case .parallelRangeFormat: return "并行 %@ – %@"
        case .deletedEventFallback: return "已删除的事件"
        case .messageAboutEventPlaceholder: return "关于此事件的消息…"
        case .captureLiveInterruption: return "记录一次实时打断。"
        case .createParallelInterruption: return "创建一次并行打断。"
        case .startsNowCommits: return "现在开始，停止时提交。"
        case .liveOn: return "实时开"
        case .liveOff: return "实时关"
        case .startLive: return "开始实时"
        case .logHumanContextHint: return "趁记忆鲜活，记录下当时的情境。"
        case .logStructureHint: return "当你想更具体地反思时，可选的结构。"
        case .visionUsed: return "已使用"
        case .visionTextOnly: return "仅文本"
        case .visionLabelFormat: return "视觉：%@"
        case .shareDay: return "分享当日"
        case .shareEvent: return "分享事件"
        case .shareWeek: return "分享本周"
        case .nothingScheduled: return "暂无安排"
        case .noInterruptsOrNotes: return "暂无打断或笔记"
        case .jumpToCalendarA11y: return "跳转到日历"
        case .wannaFallback: return "想做"
        case .recallFromCalendar: return "从日历撤回"
        case .pushToCalendar: return "加入日历"
        case .addDeadline: return "添加截止"
        case .tapToAddNote: return "点按添加笔记…"
        case .removeDeadline: return "移除截止"
        case .iWannaPlaceholder: return "我想做…"
        case .whatDoYouWanna: return "你想做点什么？"
        case .overdueDHFormat: return "已逾期 %d天%d小时"
        case .dueInDHFormat: return "剩 %d天%d小时"
        case .addToCalendar: return "添加到日历"
        case .enterTitle: return "输入标题"
        case .enterTagReturn: return "输入标签后回车"
        case .addRange: return "添加时段"
        case .ddlLabel: return "截止"
        case .setDeadline: return "设定截止"
        case .splitTitle: return "拆分"
        case .subTasks: return "子任务"
        case .adjustSubtasksPlaceholder: return "调整子任务…"
        case .applySplitFormat: return "应用拆分（%d）"
        case .templateName: return "模板名称"
        case .pickColor: return "选择颜色"
        case .noCompletedEvents: return "暂无已完成事件"
        case .noDeletedEvents: return "暂无已删除事件"
        case .deletedLabel: return "已删除"
        case .periodPickerLabel: return "时段"
        case .timeAllocation: return "时间分配"
        case .dailyHours: return "每日时长"
        case .taskCompletions: return "任务完成"
        case .skillsLabel: return "技能"
        case .doneLearningWhoYouAre: return "Done 正在了解你。"
        case .savedConfirmation: return "已保存。"
        case .canReadLast7Days: return "可读取你最近 7 天的数据来帮助规划。"
        case .choosePhoto: return "选择照片"
        case .replacePhoto: return "更换照片"
        case .removePhoto: return "移除照片"
        case .aiSuggestionsTitle: return "AI 建议"
        case .tapRefreshSuggestions: return "点按刷新，获取 AI 为你日程提供的建议。"
        case .tellDoneStep: return "3. 让 Done 换个做法"
        case .tellDoneOtherwise: return "告诉 Done 该怎么做"
        case .accountTitle: return "账户"
        case .userId: return "用户 ID"
        case .connectedLabel: return "已连接"
        case .signOut: return "退出登录"
        case .signInToSyncShort: return "登录以同步"
        case .signInWithApple: return "通过 Apple 登录"
        case .signInWithGoogle: return "通过 Google 登录"
        case .setUpAiConnection: return "设置 AI 连接"
        case .generateConnectorHint: return "生成一个永久链接，让 Claude、ChatGPT 或其他 AI 应用连接到你的 Done 数据。"
        case .aiConnectorUrl: return "AI 连接器链接"
        case .activeStatus: return "已启用"
        case .ephemeralLinkHint: return "生成一个有效期 5 分钟的链接，包含你的日程和活动数据。粘贴到 ChatGPT 或 Claude 即可。"
        case .agentFallback: return "助理"
        case .messagePlaceholder: return "输入消息…"
        case .chatsTitle: return "对话"
        case .uploadToCloud: return "将此设备的数据上传到云端"
        case .uploadToCloudHint: return "关闭时，此设备仅读取（仍可恢复）。默认关闭，以免全新安装意外写入你的云端数据。每台设备独立——你的其他设备保留各自的设置。"
        case .uploadsOffHint: return "此设备的上传已关闭。打开上方的同步开关即可开始向云端推送更改。"
        case .calendarSyncSnapshot: return "日历同步快照"
        case .previewCloudBackup: return "预览云端备份"
        case .restoreFromCloud: return "从云端恢复"
        case .replaceLocalConfirm: return "用云端快照替换所有本地数据？"
        case .replaceLocalData: return "替换本地数据"
        case .unsyncedLostWarning: return "任何尚未同步到云端的本地修改都将永久丢失。"
        case .fetchingFromCloud: return "正在从云端获取…"
        case .applyingRestore: return "正在恢复…"
        case .noCloudData: return "此账户在云端没有找到数据。"
        case .previewOnlyNoChanges: return "仅预览——未做任何更改"
        case .mergeLabel: return "合并"
        case .mergeHint: return "添加本地缺失的云端记录。如果同一记录在两边内容不同，将询问你如何处理。"
        case .cloudOverwritesLocal: return "云端覆盖本地"
        case .cloudOverwritesLocalHint: return "用云端快照替换此设备上的所有内容。未同步的本地更改将丢失。"
        case .keepAllLocal: return "保留所有本地版本"
        case .keepAllLocalHint: return "冲突时以本设备版本为准。仅云端的记录仍会被添加。"
        case .keepAllCloud: return "保留所有云端版本"
        case .keepAllCloudHint: return "冲突时以云端版本替换本设备。仅在你确信云端更新时使用。"
        case .reviewEachIndividually: return "逐条审阅"
        case .reviewEachHint: return "逐个打开冲突并选择保留项。仅云端的记录仍会被添加。"
        case .applyMerge: return "应用合并"
        case .restoreComplete: return "恢复完成"
        case .restoreFailed: return "恢复失败"
        case .keepLocal: return "保留本地"
        case .keepCloud: return "保留云端"
        }
    }
}
