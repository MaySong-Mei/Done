//
//  TodoList.swift
//  Done
//
//  Created by Shiqi Liu on 2/21/26.
//

import Foundation

struct TodoList: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var colorName: String
    var createdAt = Date()

    static let availableColors = [
        "blue", "green", "orange", "purple", "red", "pink", "teal", "indigo", "yellow", "mint"
    ]
}
