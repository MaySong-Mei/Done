//
//  WannaListView.swift
//  Done
//
//  Flat, single-column list of intentions (wannas).
//  A wanna is an Event with no timeRanges — pure intent, not yet scheduled.
//

import SwiftUI

struct WannaListView: View {
    @EnvironmentObject var store: EventStore
    @State private var showCompleted = false
    @State private var selectedEventID: UUID?
    @State private var newWannaTitle = ""
    @State private var isInputFocused = false
    @FocusState private var inputFocused: Bool

    private var activeWannas: [Event] {
        store.activeEvents.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                // Inline create
                inputCard

                ForEach(activeWannas) { event in
                    WannaCardView(
                        event: event,
                        isScheduled: event.linkedCalendarEventId != nil,
                        onComplete: { store.completeWanna(event) },
                        onPushToCalendar: { store.pushWannaToCalendar(event) },
                        onRecallFromCalendar: { store.recallWannaFromCalendar(event) },
                        onDelete: { store.markArchived(event) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedEventID = event.id
                    }
                }

                if activeWannas.isEmpty && newWannaTitle.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            wannaHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
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
        let event = Event(title: title)
        store.add(event)
        newWannaTitle = ""
    }

    // MARK: - Header

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
