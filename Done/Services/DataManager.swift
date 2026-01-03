//
//  DataManager.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation
import Combine
import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
class DataManager: ObservableObject, DataStorage {
    static let shared = DataManager()

    @Published var templates: [ActivityTemplate] = []
    @Published var timeEntries: [TimeEntry] = []
    @Published var activeEntry: TimeEntry?
    @Published var wordlessMode: Bool = false
    @Published var showDayNightBackground: Bool = false
    @Published var appearanceMode: AppearanceMode = .system

    private let templatesKey = "activityTemplates"
    private let timeEntriesKey = "timeEntries"
    private let activeEntryKey = "activeEntry"
    private let wordlessModeKey = "wordlessMode"
    private let showDayNightBackgroundKey = "showDayNightBackground"
    private let appearanceModeKey = "appearanceMode"

    private init() {
        loadTemplates()
        loadTimeEntries()
        loadActiveEntry()
        loadWordlessMode()
        loadDayNightBackground()
        loadAppearanceMode()
    }

    func loadWordlessMode() {
        wordlessMode = UserDefaults.standard.bool(forKey: wordlessModeKey)
    }

    func saveWordlessMode() {
        UserDefaults.standard.set(wordlessMode, forKey: wordlessModeKey)
    }

    func loadDayNightBackground() {
        showDayNightBackground = UserDefaults.standard.bool(forKey: showDayNightBackgroundKey)
    }

    func saveDayNightBackground() {
        UserDefaults.standard.set(showDayNightBackground, forKey: showDayNightBackgroundKey)
    }

    func loadAppearanceMode() {
        if let rawValue = UserDefaults.standard.string(forKey: appearanceModeKey),
           let mode = AppearanceMode(rawValue: rawValue) {
            appearanceMode = mode
        } else {
            appearanceMode = .system
        }
    }

    func saveAppearanceMode() {
        UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceModeKey)
    }

    func loadTemplates() {
        if let loaded: [ActivityTemplate] = load(templatesKey) {
            templates = loaded.sorted { $0.order < $1.order }
        } else {
            templates = ActivityTemplate.defaultTemplates
            saveTemplates()
        }
    }

    func saveTemplates() {
        save(templates, key: templatesKey)
        PhoneConnectivityManager.shared.syncTemplates(templates)
    }

    func addTemplate(_ template: ActivityTemplate) {
        templates.append(template)
        templates.sort { $0.order < $1.order }
        saveTemplates()
    }

    func updateTemplate(_ template: ActivityTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
            saveTemplates()
        }
    }

    func deleteTemplate(_ template: ActivityTemplate) {
        templates.removeAll { $0.id == template.id }
        saveTemplates()
    }

    func reorderTemplates(from source: IndexSet, to destination: Int) {
        var reordered = templates

        var movedItems: [ActivityTemplate] = []
        for index in source.sorted().reversed() {
            movedItems.insert(reordered.remove(at: index), at: 0)
        }

        let insertIndex = destination > (source.first ?? 0) ? destination - source.count : destination

        reordered.insert(contentsOf: movedItems, at: insertIndex)

        templates = reordered
        for (index, var template) in templates.enumerated() {
            template.order = index
            templates[index] = template
        }

        saveTemplates()
    }

    func loadTimeEntries() {
        if let loaded: [TimeEntry] = load(timeEntriesKey) {
            timeEntries = loaded.sorted { $0.startTime > $1.startTime }
        }
    }

    func saveTimeEntries() {
        save(timeEntries, key: timeEntriesKey)
    }

    func loadActiveEntry() {
        activeEntry = load(activeEntryKey)
    }

    func saveActiveEntry() {
        if let activeEntry = activeEntry {
            save(activeEntry, key: activeEntryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeEntryKey)
        }
    }

    func setActiveEntry(_ entry: TimeEntry) {
        activeEntry = entry
        saveActiveEntry()
    }

    func clearActiveEntry(matching id: UUID? = nil) {
        guard let current = activeEntry else { return }
        if let id = id, current.id != id {
            return
        }
        activeEntry = nil
        saveActiveEntry()
    }

    func addTimeEntry(_ entry: TimeEntry) {
        timeEntries.insert(entry, at: 0)
        saveTimeEntries()
        clearActiveEntry(matching: entry.id)

        Task {
            await GoogleCalendarService.shared.syncTimeEntry(entry)
        }
    }

    func deleteTimeEntry(_ entry: TimeEntry) {
        timeEntries.removeAll { $0.id == entry.id }
        saveTimeEntries()
    }

    func updateTimeEntry(_ entry: TimeEntry) {
        if let index = timeEntries.firstIndex(where: { $0.id == entry.id }) {
            timeEntries[index] = entry
            saveTimeEntries()

            // 同步到Google Calendar
            Task {
                await GoogleCalendarService.shared.syncTimeEntry(entry)
            }
        } else {
            addTimeEntry(entry)
        }
    }

    func getEntriesForDateRange(start: Date, end: Date) -> [TimeEntry] {
        timeEntries.filter { entry in
            entry.startTime >= start && entry.startTime < end
        }
    }
}
