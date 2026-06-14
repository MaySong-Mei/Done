//
//  TodoListsView.swift
//  Done
//
//  Shared views: CompletedListView, ArchivedListView, DeleteZone, etc.
//

import SwiftUI

struct CompletedListView: View {
    @EnvironmentObject var store: EventStore

    var body: some View {
        Group {
            if store.completedEvents.isEmpty {
                EmptyStateView(title: L(.noCompletedEvents), systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.completedEvents) { event in
                            completedCard(event)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                BackButton(title: L(.done))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    private func completedCard(_ event: Event) -> some View {
        EventCardView(event: event, isCompleted: true)
            .overlay(alignment: .topLeading) {
                Button {
                    withAnimation {
                        store.markActive(event)
                    }
                } label: {
                    Color.clear
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
    }
}

struct ArchivedListView: View {
    @EnvironmentObject var store: EventStore

    var body: some View {
        Group {
            if store.archivedEvents.isEmpty {
                EmptyStateView(title: L(.noDeletedEvents), systemImage: "trash")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.archivedEvents) { event in
                            archivedCard(event)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                BackButton(title: L(.deletedLabel))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    private func archivedCard(_ event: Event) -> some View {
        EventCardView(event: event, isCompleted: true)
            .overlay(alignment: .topLeading) {
                Button {
                    withAnimation {
                        store.restoreFromArchive(event)
                    }
                } label: {
                    Color.clear
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
    }
}

private struct BackButton: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Color.black.opacity(0.001), in: Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
