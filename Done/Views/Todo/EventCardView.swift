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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if event.priority > 0 {
                    Text(String(repeating: "!", count: event.priority))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                }
                Text(event.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }
            if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(event.note)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardColor.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(cardColor.opacity(0.4), lineWidth: 1)
        )
    }

    private var cardColor: Color { EventTypeTemplateStore.color(for: event.type) }
}
