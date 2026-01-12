//
//  EventCardView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventCardView: View {
    let event: Event

    var body: some View {
        Text(event.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}
