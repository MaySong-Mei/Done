//
//  DataManager.swift
//  Done Watch App
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation
import Combine

@MainActor
class DataManager: ObservableObject, DataStorage {
    static let shared = DataManager()

    @Published var templates: [ActivityTemplate] = []
    @Published var timeEntries: [TimeEntry] = []
    @Published var activeEntry: TimeEntry?

    private let templatesKey = "activityTemplates"
    private let timeEntriesKey = "timeEntries"
    private let activeEntryKey = "activeEntry"

    private init() {
        loadTemplates()
        loadTimeEntries()
        loadActiveEntry()
    }

    func loadTemplates() {
        if let loaded: [ActivityTemplate] = load(templatesKey) {
            templates = loaded
        } else {
            templates = ActivityTemplate.defaultTemplates
            saveTemplates()
        }
    }

    func saveTemplates() {
        save(templates, key: templatesKey)
    }

    func updateTemplates(_ newTemplates: [ActivityTemplate]) {
        templates = newTemplates.sorted { $0.order < $1.order }
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

    func startTracking(template: ActivityTemplate) {
        if activeEntry != nil {
            stopTracking()
        }

        let hex = template.colorHex.hasPrefix("#") ? template.colorHex : "#\(template.colorHex)"

        let entry = TimeEntry(
            templateId: template.id,
            templateName: template.name,
            startTime: Date(),
            colorHex: hex
        )

        activeEntry = entry
        saveActiveEntry()
        WatchConnectivityManager.shared.sendActiveEntry(entry)
    }

    func stopTracking() {
        guard var entry = activeEntry else { return }

        entry.endTime = Date()
        timeEntries.insert(entry, at: 0)
        saveTimeEntries()

        activeEntry = nil
        saveActiveEntry()

        WatchConnectivityManager.shared.sendTimeEntry(entry)
    }

    func deleteTimeEntry(_ entry: TimeEntry) {
        timeEntries.removeAll { $0.id == entry.id }
        saveTimeEntries()
    }
}
