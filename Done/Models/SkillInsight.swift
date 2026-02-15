//
//  SkillInsight.swift
//  Done
//

import Foundation
import Combine

struct SkillInsight: Identifiable, Codable {
    var id: UUID = UUID()
    var skillName: String
    var points: Double
    var date: Date
    var eventTitle: String
    var reasoning: String
}

struct SkillAggregate: Identifiable {
    var id: String { skillName }
    var skillName: String
    var totalPoints: Double
}

final class SkillInsightStore: ObservableObject {
    @Published private(set) var insights: [SkillInsight] = []
    private(set) var analyzedEventIds: Set<String> = []

    private let key = "skillInsights"
    private let analyzedKey = "skillAnalyzedEventIds"

    init() {
        load()
    }

    func isAnalyzed(_ eventId: UUID) -> Bool {
        analyzedEventIds.contains(eventId.uuidString)
    }

    func markAnalyzed(_ eventId: UUID) {
        analyzedEventIds.insert(eventId.uuidString)
        saveAnalyzedIds()
    }

    func add(_ insight: SkillInsight) {
        insights.append(insight)
        save()
    }

    func insightsInRange(start: Date, end: Date) -> [SkillInsight] {
        insights.filter { $0.date >= start && $0.date < end }
    }

    func aggregatedSkills(start: Date, end: Date) -> [SkillAggregate] {
        var totals: [String: Double] = [:]
        for insight in insightsInRange(start: start, end: end) {
            totals[insight.skillName, default: 0] += insight.points
        }
        return totals.map { SkillAggregate(skillName: $0.key, totalPoints: $0.value) }
            .sorted { $0.totalPoints > $1.totalPoints }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(insights) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SkillInsight].self, from: data) {
            insights = decoded
        }
        if let ids = UserDefaults.standard.array(forKey: analyzedKey) as? [String] {
            analyzedEventIds = Set(ids)
        }
    }

    private func saveAnalyzedIds() {
        UserDefaults.standard.set(Array(analyzedEventIds), forKey: analyzedKey)
    }
}
