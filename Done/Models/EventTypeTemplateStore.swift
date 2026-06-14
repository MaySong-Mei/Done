//
//  EventTypeTemplateStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import Combine

struct EventTypeTemplate: Codable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var colorHex: String

    init(id: UUID = UUID(), title: String, colorHex: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}

enum EventTypeTemplateChangeResult: Equatable {
    case created(EventTypeTemplate)
    case existing(EventTypeTemplate)
    case invalid
}

final class EventTypeTemplateStore: ObservableObject {
    @Published private(set) var templates: [EventTypeTemplate] = []

    static let storageKey = "eventTypeTemplates"
    /// Neutral gray used as the fallback type color and the default for new templates.
    static let fallbackColorHex = "#8E8E93"
    private static let colorHistoryKey = "eventTypeColorHistory"
    private let defaults: UserDefaults

    private let fallbackTemplates: [EventTypeTemplate] = [
        EventTypeTemplate(title: "Study", colorHex: "#34C759"),
        EventTypeTemplate(title: "Work", colorHex: "#0A84FF"),
        EventTypeTemplate(title: "Exercise", colorHex: "#FFD60A"),
        EventTypeTemplate(title: "Sleep", colorHex: "#AF52DE")
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func ensureIncludes(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !templates.contains(where: { $0.title == trimmed }) {
            templates.append(
                EventTypeTemplate(title: trimmed, colorHex: Self.defaultColorHex(for: trimmed))
            )
            save()
        }
    }

    func add(_ title: String, colorHex: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !templates.contains(where: { $0.title == trimmed }) else { return }
        templates.append(EventTypeTemplate(title: trimmed, colorHex: colorHex))
        save()
    }

    func contains(title: String) -> Bool {
        let normalized = Self.normalizedTitle(title)
        guard !normalized.isEmpty else { return false }
        return templates.contains { Self.normalizedTitle($0.title) == normalized }
    }

    @discardableResult
    func ensureTemplate(title: String) -> EventTypeTemplateChangeResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        if let existing = templates.first(where: { Self.normalizedTitle($0.title) == Self.normalizedTitle(trimmed) }) {
            return .existing(existing)
        }

        let created = EventTypeTemplate(title: trimmed, colorHex: Self.defaultColorHex(for: trimmed))
        templates.append(created)
        save()
        return .created(created)
    }

    func update(from originalTitle: String, to newTitle: String, colorHex: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = templates.firstIndex(where: { $0.title == originalTitle }) else { return }

        if let existingIndex = templates.firstIndex(where: { $0.title == trimmed }),
           existingIndex != index {
            templates[existingIndex].colorHex = colorHex
            templates.remove(at: index)
        } else {
            templates[index].title = trimmed
            templates[index].colorHex = colorHex
        }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func remove(title: String) {
        guard let index = templates.firstIndex(where: { $0.title == title }) else { return }
        let colorHex = templates[index].colorHex
        templates.remove(at: index)
        save()
        saveColorToHistory(title: title, colorHex: colorHex)
    }

    func resetToDefaults() {
        templates = fallbackTemplates
        defaults.removeObject(forKey: Self.colorHistoryKey)
        save()
    }

    func colorHex(for title: String) -> String {
        if let match = templates.first(where: { $0.title == title }) {
            return match.colorHex
        }
        return Self.defaultColorHex(for: title)
    }

    static func color(for title: String, defaults: UserDefaults = .standard) -> Color {
        if let data = defaults.data(forKey: storageKey) {
            if let decoded = try? JSONDecoder().decode([EventTypeTemplate].self, from: data) {
                if let match = decoded.first(where: { $0.title == title }) {
                    return ColorHex.toColor(match.colorHex)
                }
            } else if let decoded = try? JSONDecoder().decode([String].self, from: data) {
                if decoded.contains(title) {
                    return ColorHex.toColor(Self.defaultColorHex(for: title))
                }
            }
        }
        if let history = defaults.dictionary(forKey: colorHistoryKey) as? [String: String],
           let hex = history[title] {
            return ColorHex.toColor(hex)
        }
        return ColorHex.toColor(Self.defaultColorHex(for: title))
    }

    static func colorHex(for title: String, defaults: UserDefaults = .standard) -> String {
        if let data = defaults.data(forKey: storageKey) {
            if let decoded = try? JSONDecoder().decode([EventTypeTemplate].self, from: data) {
                if let match = decoded.first(where: { $0.title == title }) {
                    return match.colorHex
                }
            }
        }
        if let history = defaults.dictionary(forKey: colorHistoryKey) as? [String: String],
           let hex = history[title] {
            return hex
        }
        return Self.defaultColorHex(for: title)
    }

    static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            templates = fallbackTemplates
            return
        }
        if let decoded = try? JSONDecoder().decode([EventTypeTemplate].self, from: data),
           !decoded.isEmpty {
            templates = decoded
        } else if let decoded = try? JSONDecoder().decode([String].self, from: data),
                  !decoded.isEmpty {
            templates = decoded.map { EventTypeTemplate(title: $0, colorHex: Self.defaultColorHex(for: $0)) }
            save()
        } else {
            templates = fallbackTemplates
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func saveColorToHistory(title: String, colorHex: String) {
        var history = defaults.dictionary(forKey: Self.colorHistoryKey) as? [String: String] ?? [:]
        history[title] = colorHex
        defaults.set(history, forKey: Self.colorHistoryKey)
    }

    /// Apply a cloud restore snapshot.
    ///
    /// Event types are deduped by **normalized title** (not UUID), because the
    /// user-facing identity is the title — events reference their type via
    /// `Event.type: String`, not via the template's UUID. Different devices
    /// independently generate UUIDs for the seed types ("Study", "Work", …);
    /// merging by UUID would clone them visibly. Title is the right dedupe key.
    ///
    /// - `.merge`: union by normalized title. Cloud rows with a new title are
    ///   appended. Same-title collisions resolve to `.keepLocal` (no-op) or
    ///   `.keepCloud` (replace the local row, adopting cloud's UUID + colorHex).
    /// - `.cloudOverwritesLocal`: replace `templates` entirely. Cloud's own
    ///   title duplicates are collapsed before assignment so the user doesn't
    ///   inherit server-side clutter. Falls back to the built-in defaults if
    ///   cloud delivered no templates so the store is never left empty.
    ///   `resolution` is ignored.
    /// Returns the number of templates added (or set, when overwriting).
    @discardableResult
    func applyRestore(
        templates incoming: [EventTypeTemplate],
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: [UUID: ConflictResolution]? = nil
    ) -> Int {
        switch strategy {
        case .cloudOverwritesLocal:
            let deduped = Self.dedupedByTitle(incoming)
            let resolved = deduped.isEmpty ? fallbackTemplates : deduped
            templates = resolved
            save()
            return resolved.count

        case .merge:
            // Dedupe cloud by normalized title before merging so same-title
            // duplicates (e.g., two cloud "Study" rows from different installs'
            // seed runs) don't produce last-write-wins ambiguity. Matches the
            // pre-dedup `cloudOverwritesLocal` already does on its input.
            let dedupedIncoming = Self.dedupedByTitle(incoming)
            var added = 0
            var didMutate = false
            for cloud in dedupedIncoming {
                let key = Self.normalizedTitle(cloud.title)
                if let idx = templates.firstIndex(where: {
                    Self.normalizedTitle($0.title) == key
                }) {
                    let effective = perRowDecisions?[cloud.id] ?? resolution
                    if effective == .keepCloud {
                        templates[idx] = cloud
                        didMutate = true
                    }
                } else {
                    templates.append(cloud)
                    added += 1
                    didMutate = true
                }
            }
            if didMutate { save() }
            return added
        }
    }

    /// Drop server-side title duplicates so a single cloud restore can't
    /// inflate the local list. Keeps the first occurrence of each normalized
    /// title.
    private static func dedupedByTitle(_ list: [EventTypeTemplate]) -> [EventTypeTemplate] {
        var seen = Set<String>()
        var result: [EventTypeTemplate] = []
        for t in list where seen.insert(normalizedTitle(t.title)).inserted {
            result.append(t)
        }
        return result
    }

    private static func defaultColorHex(for title: String) -> String {
        switch title {
        case "Study":
            return "#34C759"
        case "Work":
            return "#0A84FF"
        case "Exercise":
            return "#FFD60A"
        case "Sleep":
            return "#AF52DE"
        default:
            return fallbackColorHex
        }
    }
}

enum ColorHex {
    static func toColor(_ hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        let value = UInt64(sanitized, radix: 16)

        switch sanitized.count {
        case 6:
            guard let value else { return .secondary }
            let red = Double((value >> 16) & 0xFF) / 255.0
            let green = Double((value >> 8) & 0xFF) / 255.0
            let blue = Double(value & 0xFF) / 255.0
            return Color(red: red, green: green, blue: blue)
        case 8:
            guard let value else { return .secondary }
            let red = Double((value >> 24) & 0xFF) / 255.0
            let green = Double((value >> 16) & 0xFF) / 255.0
            let blue = Double((value >> 8) & 0xFF) / 255.0
            let opacity = Double(value & 0xFF) / 255.0
            return Color(red: red, green: green, blue: blue, opacity: opacity)
        default:
            return .secondary
        }
    }

    static func fromColor(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let redByte = colorByte(red)
            let greenByte = colorByte(green)
            let blueByte = colorByte(blue)
            let alphaByte = colorByte(alpha)
            if alphaByte == 255 {
                return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
            }
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return EventTypeTemplateStore.fallbackColorHex
    }

    private static func colorByte(_ value: CGFloat) -> Int {
        Int((max(0, min(1, value)) * 255.0).rounded())
    }
}
