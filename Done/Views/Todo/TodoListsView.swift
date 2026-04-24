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
                EmptyStateView(title: "No completed events", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    let columns = masonryColumns(store.completedEvents)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            ForEach(columns.left) { event in
                                completedCard(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        VStack(spacing: 12) {
                            ForEach(columns.right) { event in
                                completedCard(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                BackButton(title: "Done")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
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

    private func masonryColumns(_ events: [Event]) -> (left: [Event], right: [Event]) {
        var left: [Event] = []
        var right: [Event] = []
        for (i, event) in events.enumerated() {
            if i % 2 == 0 {
                left.append(event)
            } else {
                right.append(event)
            }
        }
        return (left, right)
    }
}

struct ArchivedListView: View {
    @EnvironmentObject var store: EventStore

    var body: some View {
        Group {
            if store.archivedEvents.isEmpty {
                EmptyStateView(title: "No deleted events", systemImage: "trash")
            } else {
                ScrollView {
                    let columns = masonryColumns(store.archivedEvents)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            ForEach(columns.left) { event in
                                archivedCard(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        VStack(spacing: 12) {
                            ForEach(columns.right) { event in
                                archivedCard(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                BackButton(title: "Deleted")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
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

    private func masonryColumns(_ events: [Event]) -> (left: [Event], right: [Event]) {
        var left: [Event] = []
        var right: [Event] = []
        for (i, event) in events.enumerated() {
            if i % 2 == 0 {
                left.append(event)
            } else {
                right.append(event)
            }
        }
        return (left, right)
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
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DeleteZoneOverlay: View {
    var isOver: Bool
    @Binding var deleteZoneFrame: CGRect

    var body: some View {
        DeleteZoneView(isOver: isOver)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DeleteZoneFrameKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            )
            .padding(.trailing, 20)
            .padding(.bottom, 24)
            .onPreferenceChange(DeleteZoneFrameKey.self) { frame in
                deleteZoneFrame = frame
            }
    }
}

private struct DeleteZoneView: View {
    var isOver: Bool
    @State private var isArmed: Bool = false
    @State private var armWork: DispatchWorkItem?

    var body: some View {
        Image(systemName: "trash")
            .font(.system(size: isArmed ? 20 : 17, weight: .medium))
            .foregroundStyle(isArmed ? .white : .secondary)
            .frame(width: 56, height: 56)
            .background {
                Circle().fill(Color.red.opacity(isArmed ? 0.85 : 0))
            }
            .background(.ultraThinMaterial, in: Circle())
            .scaleEffect(isArmed ? 1.15 : (isOver ? 1.08 : 1.0))
            .shadow(color: isArmed ? .red.opacity(0.35) : .clear, radius: 14)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOver)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isArmed)
            .onChange(of: isOver) { _, over in
                armWork?.cancel()
                if over {
                    let work = DispatchWorkItem { isArmed = true }
                    armWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
                } else {
                    isArmed = false
                }
            }
    }
}

private struct DeleteZoneFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
