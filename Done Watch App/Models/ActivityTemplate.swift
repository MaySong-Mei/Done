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
    var colorHex: String
    var icon: String
    var order: Int

    init(id: UUID = UUID(), name: String, colorHex: String, icon: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.order = order
    }

    var color: Color {
        Color(hex: colorHex) ?? .blue
    }

    static let defaultTemplates: [ActivityTemplate] = [
        ActivityTemplate(name: "Work", colorHex: "#007AFF", icon: "laptopcomputer", order: 0),
        ActivityTemplate(name: "Meeting", colorHex: "#34C759", icon: "person.3.fill", order: 1),
        ActivityTemplate(name: "Exercise", colorHex: "#FF9500", icon: "figure.run", order: 2),
        ActivityTemplate(name: "Study", colorHex: "#AF52DE", icon: "book.fill", order: 3),
        ActivityTemplate(name: "Break", colorHex: "#FF3B30", icon: "cup.and.saucer.fill", order: 4),
        ActivityTemplate(name: "Travel", colorHex: "#5856D6", icon: "car.fill", order: 5)
    ]
}
