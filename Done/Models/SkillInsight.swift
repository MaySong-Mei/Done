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
    private var analyzedIdsDirty = false
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

    /// Batch variant of `markAnalyzed`: records the id in memory only, so a
    /// backlog sweep does not rewrite the entire id set to UserDefaults once
    /// per event (each such write also fires
    /// `UserDefaults.didChangeNotification`, re-arming the debounced sync
    /// sinks). The sweep calls `flushAnalyzedIds()` once when it exits.
    func markAnalyzedDeferringSave(_ eventId: UUID) {
        analyzedEventIds.insert(eventId.uuidString)
        analyzedIdsDirty = true
    }

    /// Persists ids recorded by `markAnalyzedDeferringSave`. No-op when
    /// nothing was deferred.
    func flushAnalyzedIds() {
        guard analyzedIdsDirty else { return }
        analyzedIdsDirty = false
        saveAnalyzedIds()
    }

    /// Drops in-memory analyzed ids that are not on disk, and the dirty
    /// flag with them — for a sweep that straddled "Reset all local data".
    ///
    /// `clearAll()` empties both halves at erase time, but a sweep already
    /// awaiting a provider response goes on inserting ids afterwards. Not
    /// flushing is not enough: `markAnalyzed` (the immediate path) persists
    /// the WHOLE set, so one post-erase single-event analysis would write
    /// the straddling sweep's pre-erase event ids back out. Re-reading from
    /// disk is the cheap way to say "keep only what survived the erase" with
    /// no per-sweep id bookkeeping.
    func forgetUnpersistedMarks() {
        analyzedIdsDirty = false
        analyzedEventIds = Set(defaults.array(forKey: analyzedKey) as? [String] ?? [])
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

    @discardableResult
    private func save() -> Bool {
        guard let data = try? JSONEncoder().encode(insights) else { return false }
        defaults.set(data, forKey: key)
        return true
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

    /// The remote applier's write (design §6): the whole array as the page
    /// left it, saved once. Not `add`: a remote row is not a new analysis.
    /// False when the array did not encode, so nothing was saved (see
    /// testASkillsWriteThatDidNotLandWritesNoBaseline).
    @discardableResult
    func replaceInsightsFromSync(_ rows: [SkillInsight]) -> Bool {
        insights = rows
        return save()
    }

    /// After the applier wrote a merged `skillAnalyzedEventIds` into
    /// `UserDefaults`: take it as the in-memory set, so the next
    /// `markAnalyzed` (which writes the WHOLE set) does not drop the ids
    /// another device contributed. Ids a deferred sweep recorded and has not
    /// flushed yet are kept.
    func adoptSyncedAnalyzedIds() {
        let stored = Set(defaults.array(forKey: analyzedKey) as? [String] ?? [])
        analyzedEventIds = analyzedIdsDirty ? analyzedEventIds.union(stored) : stored
    }

    func clearAll() {
        insights = []
        analyzedEventIds = []
        analyzedIdsDirty = false
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
