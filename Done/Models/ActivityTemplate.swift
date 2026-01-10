//
//  ActivityTemplate.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

struct ActivityTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var colorKey: CategoryColorKey
    var colorHex: String
    var icon: String
    var order: Int
    var subtasks: [String]

    init(
        id: UUID = UUID(),
        name: String,
        colorKey: CategoryColorKey,
        icon: String,
        order: Int = 0,
        subtasks: [String] = []
    ) {
        self.id = id
        self.name = name
        self.colorKey = colorKey
        self.colorHex = colorKey.hexValue
        self.icon = icon
        self.order = order
        self.subtasks = subtasks
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorKey
        case colorHex
        case icon
        case order
        case subtasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorKey = try container.decode(CategoryColorKey.self, forKey: .colorKey)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        icon = try container.decode(String.self, forKey: .icon)
        order = try container.decode(Int.self, forKey: .order)
        subtasks = try container.decodeIfPresent([String].self, forKey: .subtasks) ?? []
    }

    func categoryColor(variant: ColorSystem.ColorVariant = .standard) -> ColorSystem.Category {
        ColorSystem.Category.color(for: colorKey, variant: variant)
    }

    var color: Color {
        categoryColor().fill
    }

    var tintColor: Color {
        categoryColor().tint
    }

    var googleColorId: String {
        categoryColor().googleColorId
    }

    static let defaultTemplates: [ActivityTemplate] = [
        ActivityTemplate(name: "Work", colorKey: .basil, icon: "laptopcomputer", order: 0, subtasks: []),
        ActivityTemplate(name: "Meeting", colorKey: .tomato, icon: "person.3.fill", order: 1, subtasks: []),
        ActivityTemplate(name: "Exercise", colorKey: .banana, icon: "figure.run", order: 2, subtasks: []),
        ActivityTemplate(name: "Study", colorKey: .flamingo, icon: "book.fill", order: 3, subtasks: []),
        ActivityTemplate(name: "Break", colorKey: .lavender, icon: "cup.and.saucer.fill", order: 4, subtasks: []),
        ActivityTemplate(name: "Travel", colorKey: .peacock, icon: "car.fill", order: 5, subtasks: [])
    ]
}
