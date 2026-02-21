//
//  TodoListCardView.swift
//  Done
//
//  Created by Shiqi Liu on 2/21/26.
//

import SwiftUI

struct TodoListRowView: View {
    let list: TodoList
    let eventCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(list.title)
                .font(.system(size: 16, weight: .medium))

            Spacer()

            Text("\(eventCount)")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var listColor: Color {
        switch list.colorName {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        case "yellow": return .yellow
        case "mint": return .mint
        default: return .blue
        }
    }
}
