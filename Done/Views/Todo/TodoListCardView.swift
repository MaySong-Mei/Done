//
//  TodoListCardView.swift
//  Done
//
//  Created by Shiqi Liu on 2/21/26.
//

import SwiftUI

struct ListCardRow: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.primary)

            Spacer()

            Text("\(count)")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
