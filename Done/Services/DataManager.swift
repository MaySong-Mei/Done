//
//  DataManager.swift
//  Done
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

    private let templatesKey = "activityTemplates"
    private let timeEntriesKey = "timeEntries"

    private init() {
        loadTemplates()
        loadTimeEntries()
    }

    func loadTemplates() {
        if let data = UserDefaults.standard.data(forKey: templatesKey),
           let decoded = try? JSONDecoder().decode([ActivityTemplate].self, from: data) {
            templates = decoded.sorted { $0.order < $1.order }
        } else {
            templates = ActivityTemplate.defaultTemplates
            saveTemplates()
        }
    }

    func saveTemplates() {
        if let encoded = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(encoded, forKey: templatesKey)
            PhoneConnectivityManager.shared.syncTemplates(templates)
        }
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

        // 收集要移动的元素
        var movedItems: [ActivityTemplate] = []
        for index in source.sorted().reversed() {
            movedItems.insert(reordered.remove(at: index), at: 0)
        }

        // 计算插入位置
        let insertIndex = destination > (source.first ?? 0) ? destination - source.count : destination

        // 插入到新位置
        reordered.insert(contentsOf: movedItems, at: insertIndex)

        // 更新数组和 order
        templates = reordered
        for (index, var template) in templates.enumerated() {
            template.order = index
            templates[index] = template
        }

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

    func addTimeEntry(_ entry: TimeEntry) {
        timeEntries.insert(entry, at: 0)
        saveTimeEntries()

        Task {
            await GoogleCalendarService.shared.syncTimeEntry(entry)
        }
    }

    func deleteTimeEntry(_ entry: TimeEntry) {
        timeEntries.removeAll { $0.id == entry.id }
        saveTimeEntries()
    }

    func getEntriesForDateRange(start: Date, end: Date) -> [TimeEntry] {
        timeEntries.filter { entry in
            entry.startTime >= start && entry.startTime < end
        }
    }
}
