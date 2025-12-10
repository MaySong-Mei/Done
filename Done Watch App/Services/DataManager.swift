//
//  DataManager.swift
//  Done Watch App
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation
import Combine

@MainActor
class DataManager: ObservableObject {
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
        if let data = UserDefaults.standard.data(forKey: templatesKey),
           let decoded = try? JSONDecoder().decode([ActivityTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = ActivityTemplate.defaultTemplates
            saveTemplates()
        }
    }

    func saveTemplates() {
        if let encoded = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(encoded, forKey: templatesKey)
        }
    }

    func updateTemplates(_ newTemplates: [ActivityTemplate]) {
        templates = newTemplates.sorted { $0.order < $1.order }
        saveTemplates()
    }

    func loadTimeEntries() {
        if let data = UserDefaults.standard.data(forKey: timeEntriesKey),
           let decoded = try? JSONDecoder().decode([TimeEntry].self, from: data) {
            timeEntries = decoded.sorted { $0.startTime > $1.startTime }
        }
    }

    func saveTimeEntries() {
        if let encoded = try? JSONEncoder().encode(timeEntries) {
            UserDefaults.standard.set(encoded, forKey: timeEntriesKey)
        }
    }

    func loadActiveEntry() {
        if let data = UserDefaults.standard.data(forKey: activeEntryKey),
           let decoded = try? JSONDecoder().decode(TimeEntry.self, from: data) {
            activeEntry = decoded
        }
    }

    func saveActiveEntry() {
        if let activeEntry = activeEntry,
           let encoded = try? JSONEncoder().encode(activeEntry) {
            UserDefaults.standard.set(encoded, forKey: activeEntryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeEntryKey)
        }
    }

    func startTracking(template: ActivityTemplate) {
        // 如果有正在进行的追踪，先停止它
        if activeEntry != nil {
            stopTracking()
        }

        let entry = TimeEntry(
            templateId: template.id,
            templateName: template.name,
            startTime: Date(),
            colorHex: template.colorHex
        )

        activeEntry = entry
        saveActiveEntry()
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
