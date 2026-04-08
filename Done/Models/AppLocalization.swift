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
    case tabEvent, tabCalendar, tabAgenda, tabMe

    // Common
    case cancel, done, save, delete, edit, add, submit, dismiss, search, today, back, create, newEvent, timeFormat
    case noEvents, noMoreEvents, noEventsToday

    // Settings
    case settings, general, aiAndAgent, recordingAndWorkflow, analysisPreferences, dataAndPrivacy
    case status, provider, apiKey, learnedRules, enterApiKey, notConfigured
    case behavior, learning, controls, launch, interface, workflow, defaults, privacy, manageData, storage
    case clearLearnedPreferences, clearDecisionHistory, clearSkillInsights, clearTokenCache, resetAllData
    case noLearnedPreferences
    case aiTypeSuggestionsAfterSave, askBeforeCreatingTemplates
    case rememberLastTab, showTimerBanner, landscapeFocusMode, landscapeFocusKeepAwake, enableAiTypeSuggestions
    case effortBasedEventOpacity, hintEffortBasedEventOpacity
    case showAnalysisSummary, autoLoadSuggestions
    case language

    // Settings hints
    case hintApiKeyClaude, hintApiKeyOpenAI, hintApiKeyDeepSeek
    case hintTypeSuggestions, hintDefaultTab, hintLandscapeAndAgent
    case hintLearning, hintAnalysisPeriod, hintLocalData, hintClearData
    case hintClearSkillInsights, hintClearTokenCache, hintResetAllData

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
    case agenticCreate, describeEvent, addPhotos, useClassicForm
    case aiCreateFailed, howAiUsesThis, warnings

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
        case .tabEvent: return "Event"
        case .tabCalendar: return "Calendar"
        case .tabAgenda: return "Agenda"
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
        case .behavior: return "Behavior"
        case .learning: return "Learning"
        case .controls: return "Controls"
        case .launch: return "Launch"
        case .interface: return "Interface"
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
        case .landscapeFocusMode: return "Enable landscape focus mode"
        case .landscapeFocusKeepAwake: return "Keep screen awake in landscape focus"
        case .enableAiTypeSuggestions: return "Enable AI type suggestions"
        case .effortBasedEventOpacity: return "Effort-based event opacity"
        case .hintEffortBasedEventOpacity: return "When on, events without an effort log appear semi-transparent. High-effort events are fully opaque; low-effort events are more transparent."
        case .showAnalysisSummary: return "Show analysis summary on Me"
        case .autoLoadSuggestions: return "Auto-load AI suggestions"
        case .language: return "Language"

        // Settings hints
        case .hintApiKeyClaude: return "Get your API key from console.anthropic.com"
        case .hintApiKeyOpenAI: return "Get your API key from platform.openai.com"
        case .hintApiKeyDeepSeek: return "Get your API key from platform.deepseek.com"
        case .hintTypeSuggestions: return "When enabled, calendar forms can preselect a type while you type using existing event history and local heuristics, then ask AI after save if needed."
        case .hintDefaultTab: return "If last tab memory is enabled, the default tab is only used when there is no previous selection yet."
        case .hintLandscapeAndAgent: return "Landscape focus mode swaps to the immersive focus screen when the device rotates. Keep screen awake controls whether that landscape focus screen prevents auto-lock. AI type suggestions can preselect type during calendar input from existing history and ask AI after save if needed."
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
        case .agenticCreate: return "Agentic Create"
        case .describeEvent: return "Describe what happened or what you want to schedule"
        case .addPhotos: return "Add Photos"
        case .useClassicForm: return "Use Classic Form"
        case .aiCreateFailed: return "AI Create Failed"
        case .howAiUsesThis: return "How AI uses this"
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
        }
    }

    // MARK: - Chinese

    private var zh: String {
        switch self {
        // Tabs
        case .tabEvent: return "事件"
        case .tabCalendar: return "日历"
        case .tabAgenda: return "日程"
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
        case .behavior: return "行为"
        case .learning: return "学习"
        case .controls: return "控制"
        case .launch: return "启动"
        case .interface: return "界面"
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
        case .landscapeFocusMode: return "启用横屏专注模式"
        case .landscapeFocusKeepAwake: return "横屏专注时保持常亮"
        case .enableAiTypeSuggestions: return "启用 AI 类型建议"
        case .effortBasedEventOpacity: return "按投入度调整事件透明度"
        case .hintEffortBasedEventOpacity: return "开启后，未记录投入度的事件以半透明显示。高投入度事件完全不透明，低投入度事件更透明。"
        case .showAnalysisSummary: return "在「我」页面显示分析摘要"
        case .autoLoadSuggestions: return "自动加载 AI 建议"
        case .language: return "语言"

        // Settings hints
        case .hintApiKeyClaude: return "从 console.anthropic.com 获取 API 密钥"
        case .hintApiKeyOpenAI: return "从 platform.openai.com 获取 API 密钥"
        case .hintApiKeyDeepSeek: return "从 platform.deepseek.com 获取 API 密钥"
        case .hintTypeSuggestions: return "启用后，日历表单会根据历史事件和本地推断预选类型，保存后如需要会请求 AI 进一步建议。"
        case .hintDefaultTab: return "如果启用了标签页记忆，默认标签页仅在没有上次选择时生效。"
        case .hintLandscapeAndAgent: return "横屏专注模式会在设备旋转时切换到沉浸式专注界面。“横屏专注时保持常亮”决定该界面是否阻止系统自动锁屏。AI 类型建议可以在日历输入时从历史记录预选类型，保存后再请求 AI。"
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
        case .agenticCreate: return "AI 创建"
        case .describeEvent: return "描述发生了什么或你想安排什么"
        case .addPhotos: return "添加照片"
        case .useClassicForm: return "使用经典表单"
        case .aiCreateFailed: return "AI 创建失败"
        case .howAiUsesThis: return "AI 如何使用此信息"
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
        }
    }
}
