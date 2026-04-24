//
//  WannaListView.swift
//  Done
//
//  Flat, single-column list of intentions (wannas).
//  A wanna is an Event with no timeRanges — pure intent, not yet scheduled.
//  Sub-items use listID to reference their parent wanna's ID.
//

import SwiftUI

struct WannaListView: View {
    @EnvironmentObject var store: EventStore
    @State private var showCompleted = false
    @State private var selectedEventID: UUID?
    @State private var newWannaTitle = ""
    @FocusState private var inputFocused: Bool

    // Batch mode
    @State private var isBatchMode = false
    @State private var batchSelection: Set<UUID> = []

    /// Ordered flat list for rendering: parents followed by their children.
    private var orderedItems: [(event: Event, isSubItem: Bool)] {
        let active = store.activeEvents.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        let parents = active.filter { $0.listID == nil }
        let childrenByParent = Dictionary(grouping: active.filter { $0.listID != nil }, by: { $0.listID! })

        var result: [(Event, Bool)] = []
        for parent in parents {
            result.append((parent, false))
            if let children = childrenByParent[parent.id] {
                for child in children {
                    result.append((child, true))
                }
            }
        }
        // Orphaned sub-items whose parent was completed/deleted — show as top-level
        let parentIDs = Set(parents.map(\.id))
        for child in active where child.listID != nil && !parentIDs.contains(child.listID!) {
            result.append((child, false))
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if !isBatchMode {
                    inputCard
                        .padding(.bottom, 4)
                }

                ForEach(orderedItems, id: \.event.id) { item in
                    let event = item.event
                    let sub = item.isSubItem

                    WannaCardView(
                        event: event,
                        isScheduled: event.linkedCalendarEventId != nil,
                        isSelected: batchSelection.contains(event.id),
                        isBatchMode: isBatchMode,
                        onComplete: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                store.completeWanna(event)
                            }
                        },
                        onPushToCalendar: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                store.pushWannaToCalendar(event)
                            }
                        },
                        onRecallFromCalendar: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                store.recallWannaFromCalendar(event)
                            }
                        },
                        onDelete: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                store.markArchived(event)
                            }
                        },
                        onToggleSelect: { toggleBatchSelect(event.id) },
                        onToggleIndent: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                toggleIndent(event)
                            }
                        },
                        isSubItem: sub
                    )
                    .padding(.leading, sub ? 28 : 0)
                    .scaleEffect(sub ? 0.97 : 1, anchor: .leading)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -8)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isBatchMode {
                            toggleBatchSelect(event.id)
                        } else {
                            selectedEventID = event.id
                        }
                    }
                    .onLongPressGesture {
                        if !isBatchMode {
                            enterBatchMode(initialID: event.id)
                        }
                    }
                }

                if orderedItems.isEmpty && newWannaTitle.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            if isBatchMode {
                batchHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            } else {
                wannaHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .navigationDestination(item: $selectedEventID) { eventID in
            WannaDetailView(eventID: eventID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showCompleted) {
            NavigationStack {
                CompletedListView()
                    .environmentObject(store)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isBatchMode)
    }

    // MARK: - Indent / Sub-item

    private func toggleIndent(_ event: Event) {
        if event.listID != nil {
            // Already a sub-item → promote back to top-level
            var updated = event
            updated.listID = nil
            store.update(updated)
        } else {
            // Find the parent above this event in the ordered list
            guard let parentID = findParentAbove(event) else { return }
            var updated = event
            updated.listID = parentID
            store.update(updated)
        }
    }

    private func findParentAbove(_ event: Event) -> UUID? {
        let items = orderedItems
        guard let idx = items.firstIndex(where: { $0.event.id == event.id }), idx > 0 else { return nil }
        // Walk backwards to find the nearest top-level item
        for i in stride(from: idx - 1, through: 0, by: -1) {
            if !items[i].isSubItem {
                return items[i].event.id
            }
        }
        return nil
    }

    // MARK: - Inline Input

    private var inputCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(newWannaTitle.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)

            TextField("I wanna...", text: $newWannaTitle)
                .font(.system(size: 16, weight: .medium))
                .focused($inputFocused)
                .onSubmit { createWanna() }
                .submitLabel(.done)

            if !newWannaTitle.isEmpty {
                Button {
                    createWanna()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(inputFocused ? 0.3 : 0.12), lineWidth: 1)
        )
    }

    private func createWanna() {
        let title = newWannaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let event = Event(title: title, type: "Wanna")
        store.add(event)
        newWannaTitle = ""
    }

    // MARK: - Batch Mode

    private func enterBatchMode(initialID: UUID) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        isBatchMode = true
        batchSelection = [initialID]
    }

    private func exitBatchMode() {
        isBatchMode = false
        batchSelection = []
    }

    private func toggleBatchSelect(_ id: UUID) {
        if batchSelection.contains(id) {
            batchSelection.remove(id)
        } else {
            batchSelection.insert(id)
        }
    }

    private func batchComplete() {
        for id in batchSelection {
            if let event = store.events.first(where: { $0.id == id }) {
                store.completeWanna(event)
            }
        }
        exitBatchMode()
    }

    private func batchDelete() {
        for id in batchSelection {
            if let event = store.events.first(where: { $0.id == id }) {
                store.markArchived(event)
            }
        }
        exitBatchMode()
    }

    private func batchPushToCalendar() {
        for id in batchSelection {
            if let event = store.events.first(where: { $0.id == id }),
               event.linkedCalendarEventId == nil {
                store.pushWannaToCalendar(event)
            }
        }
        exitBatchMode()
    }

    // MARK: - Headers

    private var wannaHeader: some View {
        HStack(spacing: 10) {
            Text("Wanna")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            if store.completedCount > 0 {
                Button {
                    showCompleted = true
                } label: {
                    Text("\u{2713} \(store.completedCount)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var batchHeader: some View {
        HStack(spacing: 10) {
            Button {
                exitBatchMode()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(batchSelection.count) selected")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button { batchPushToCalendar() } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(batchSelection.isEmpty)

                Button { batchComplete() } label: {
                    Image(systemName: "checkmark")
                }
                .disabled(batchSelection.isEmpty)

                Button { batchDelete() } label: {
                    Image(systemName: "trash")
                }
                .disabled(batchSelection.isEmpty)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("What do you wanna do?")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
