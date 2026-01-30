//
//  CompletedEventsView.swift
//  Done
//
//  Created by Shiqi Liu on 1/31/26.
//

import SwiftUI

struct CompletedEventsView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.completedEvents.isEmpty {
                    EmptyStateView(title: "No completed events", systemImage: "checkmark.circle")
                } else {
                    List {
                        ForEach(store.completedEvents) { event in
                            Button {
                                store.markActive(event)
                            } label: {
                                completedRow(event)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(event)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    store.markActive(event)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Completed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func completedRow(_ event: Event) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(EventTypeTemplateStore.color(for: event.type))
                .frame(width: 10, height: 10)

            Text(event.title)
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let completeAt = event.completeAt {
                Text(completeAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
