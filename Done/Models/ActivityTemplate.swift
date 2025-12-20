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

    init(id: UUID = UUID(), name: String, colorKey: CategoryColorKey, icon: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.colorKey = colorKey
        self.colorHex = colorKey.hexValue
        self.icon = icon
        self.order = order
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
        ActivityTemplate(name: "Work", colorKey: .basil, icon: "laptopcomputer", order: 0),
        ActivityTemplate(name: "Meeting", colorKey: .tomato, icon: "person.3.fill", order: 1),
        ActivityTemplate(name: "Exercise", colorKey: .banana, icon: "figure.run", order: 2),
        ActivityTemplate(name: "Study", colorKey: .flamingo, icon: "book.fill", order: 3),
        ActivityTemplate(name: "Break", colorKey: .lavender, icon: "cup.and.saucer.fill", order: 4),
        ActivityTemplate(name: "Travel", colorKey: .peacock, icon: "car.fill", order: 5)
    ]
}
