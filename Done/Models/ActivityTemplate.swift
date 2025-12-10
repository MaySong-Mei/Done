//
//  ActivityTemplate.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

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

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    func toHex() -> String? {
        #if os(iOS)
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return nil
        }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
        #else
        return nil
        #endif
    }
}
