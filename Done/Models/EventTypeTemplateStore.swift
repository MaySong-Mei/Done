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

final class EventTypeTemplateStore: ObservableObject {
    @Published private(set) var templates: [EventTypeTemplate] = []

    static let storageKey = "eventTypeTemplates"
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
        return ColorHex.toColor(Self.defaultColorHex(for: title))
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
            return "#8E8E93"
        }
    }
}

enum ColorHex {
    static func toColor(_ hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
            return .secondary
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    static func fromColor(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        }
        return "#8E8E93"
    }
}