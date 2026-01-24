//
//  TimelineEventPlaceholderView.swift
//  Done
//
//  Placeholder modal for preview long-press events.
//

import SwiftUI

struct TimelineEventPlaceholderView: View {
    let event: Event
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(event.title)
                    .font(.title2.bold())

                if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(event.note)
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Placeholder detail view.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
