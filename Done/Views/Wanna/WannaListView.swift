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
    @State private var isShowingCreate = false
    @State private var showCompleted = false
    @State private var selectedEventID: UUID?

    private var activeWannas: [Event] {
        store.activeEvents.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(activeWannas) { event in
                    WannaCardView(
                        event: event,
                        isScheduled: event.linkedCalendarEventId != nil,
                        onComplete: { store.completeWanna(event) },
                        onPushToCalendar: { pushToCalendar(event) },
                        onRecallFromCalendar: { recallFromCalendar(event) },
                        onDelete: { store.markArchived(event) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedEventID = event.id
                    }
                }

                if activeWannas.isEmpty {
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
            if let event = store.events.first(where: { $0.id == eventID }) {
                EditEventView(event: event)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateEventView(listID: nil)
                .environmentObject(store)
        }
        .sheet(isPresented: $showCompleted) {
            NavigationStack {
                CompletedListView()
                    .environmentObject(store)
            }
        }
    }

    private var wannaHeader: some View {
        HStack(spacing: 10) {
            Text("Wanna")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if store.completedCount > 0 {
                    Button {
                        showCompleted = true
                    } label: {
                        Text("\u{2713} \(store.completedCount)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }

                Button {
                    isShowingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

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
        .padding(.top, 80)
    }

    private func pushToCalendar(_ event: Event) {
        store.pushWannaToCalendar(event)
    }

    private func recallFromCalendar(_ event: Event) {
        store.recallWannaFromCalendar(event)
    }
}
