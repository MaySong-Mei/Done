//
//  ConversationRowView.swift
//  Done
//

import SwiftUI

struct ConversationRowView: View {
    let conversation: AgentConversation
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.displayTitle)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(relativeDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                if !eventNames.isEmpty {
                    ForEach(eventNames.prefix(3), id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                            .lineLimit(1)
                    }
                    if eventNames.count > 3 {
                        Text("+\(eventNames.count - 3)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(.systemGray5) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var eventNames: [String] {
        Array(conversation.involvedEventNames.values)
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }
}
