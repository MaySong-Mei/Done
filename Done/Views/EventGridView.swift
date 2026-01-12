//
//  EventGridView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventGridView: View {
    let events: [Event]

    var body: some View {
        GeometryReader { proxy in
            let columnsCount = 16
            let spacing: CGFloat = 6
            let horizontalPadding: CGFloat = 16
            let totalSpacing = CGFloat(columnsCount - 1) * spacing
            let availableWidth = proxy.size.width - horizontalPadding * 2 - totalSpacing
            let cellSize = max(8, availableWidth / CGFloat(columnsCount))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: spacing), count: columnsCount)

            Group {
                if events.isEmpty {
                    EmptyStateView(
                        title: "No events",
                        systemImage: "checklist"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: spacing) {
                            ForEach(events) { event in
                                EventCardView(event: event)
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

struct CalendarPlaceholderView: View {
    var body: some View {
        EmptyStateView(
            title: "Calendar coming soon",
            systemImage: "calendar.badge.clock"
        )
    }
}

struct CreateEventPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Enter title", text: $title)
                        .textInputAutocapitalization(.sentences)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
