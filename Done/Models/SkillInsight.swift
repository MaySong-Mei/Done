//
//  SkillInsight.swift
//  Done
//

import Foundation
import Combine

struct SkillInsight: Identifiable, Codable, Equatable {
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
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        defaults.set(data, forKey: key)
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SkillInsight].self, from: data) {
            insights = decoded
        }
        if let ids = defaults.array(forKey: analyzedKey) as? [String] {
            analyzedEventIds = Set(ids)
        }
    }

    private func saveAnalyzedIds() {
        defaults.set(Array(analyzedEventIds), forKey: analyzedKey)
    }

    func clearAll() {
        insights = []
        analyzedEventIds = []
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: analyzedKey)
    }

    /// Apply a cloud restore snapshot.
    ///
    /// - `.merge`: union by ID. Cloud rows with new IDs are appended. Same-ID
    ///   collisions resolve to `.keepLocal` (no-op) or `.keepCloud` (replace).
    /// - `.cloudOverwritesLocal`: replace `insights` entirely. `resolution` is ignored.
    /// Returns the number of insights added (or set, when overwriting).
    @discardableResult
    func applyRestore(
        insights incoming: [SkillInsight],
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: [UUID: ConflictResolution]? = nil
    ) -> Int {
        switch strategy {
        case .cloudOverwritesLocal:
            insights = incoming
            save()
            return incoming.count

        case .merge:
            let idIndex: [UUID: Int] = Dictionary(
                uniqueKeysWithValues: insights.enumerated().map { ($0.element.id, $0.offset) }
            )
            var added = 0
            var didMutate = false
            for cloud in incoming {
                if let idx = idIndex[cloud.id] {
                    let effective = perRowDecisions?[cloud.id] ?? resolution
                    if effective == .keepCloud {
                        insights[idx] = cloud
                        didMutate = true
                    }
                } else {
                    insights.append(cloud)
                    added += 1
                    didMutate = true
                }
            }
            if didMutate { save() }
            return added
        }
    }
}
