//
//  ActivityTemplate.swift
//  Done Watch App
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

struct ActivityTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var colorKey: CategoryColorKey  // 新：使用颜色键
    var colorHex: String            // 保留：向后兼容
    var icon: String
    var order: Int

    init(id: UUID = UUID(), name: String, colorKey: CategoryColorKey, icon: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.colorKey = colorKey
        self.colorHex = colorKey.hexValue  // 自动生成 hex
        self.icon = icon
        self.order = order
    }

    // 向后兼容：支持旧的 init（从 hex 推断 colorKey）
    init(id: UUID = UUID(), name: String, colorHex: String, icon: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.colorKey = CategoryColorKey.from(hex: colorHex)
        self.colorHex = colorHex
        self.icon = icon
        self.order = order
    }

    // Watch 使用加强对比度的颜色
    func categoryColor(variant: ColorSystem.ColorVariant = .watch) -> ColorSystem.Category {
        ColorSystem.Category.color(for: colorKey, variant: variant)
    }

    var color: Color {
        categoryColor().fill
    }

    var tintColor: Color {
        categoryColor().tint
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
