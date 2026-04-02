//
//  TodoListsView.swift
//  Done
//
//  Created by Shiqi Liu on 2/21/26.
//

import SwiftUI

struct TodoListsView: View {
    @EnvironmentObject var store: EventStore
    @State private var isShowingCreateList = false
    @State private var newListTitle = ""
    @State private var newListColor = "blue"

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // User lists
                ForEach(store.todoLists) { list in
                    NavigationLink(value: list) {
                        ListCardRow(
                            title: list.title,
                            count: store.eventCount(for: list),
                            icon: "list.bullet",
                            color: todoListColor(list)
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Done card
                NavigationLink(value: "completed") {
                    ListCardRow(
                        title: "Done",
                        count: store.completedCount,
                        icon: "checkmark",
                        color: .green
                    )
                }
                .buttonStyle(.plain)

                // Deleted card
                NavigationLink(value: "archived") {
                    ListCardRow(
                        title: "Deleted",
                        count: store.archivedCount,
                        icon: "trash",
                        color: .red
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationDestination(for: TodoList.self) { list in
            TodoListDetailView(list: list)
                .environmentObject(store)
        }
        .navigationDestination(for: String.self) { value in
            if value == "archived" {
                ArchivedListView()
                    .environmentObject(store)
            } else {
                CompletedListView()
                    .environmentObject(store)
            }
        }
        .alert("New List", isPresented: $isShowingCreateList) {
            TextField("List name", text: $newListTitle)
            Button("Cancel", role: .cancel) {
                newListTitle = ""
                newListColor = "blue"
            }
            Button("Create") {
                let trimmed = newListTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let list = TodoList(
                    title: trimmed,
                    colorName: newListColor
                )
                store.addList(list)
                newListTitle = ""
                newListColor = "blue"
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            listsHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    private var listsHeader: some View {
        HStack(spacing: 10) {
            Text("Lists")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    isShowingCreateList = true
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

    private func todoListColor(_ list: TodoList) -> Color {
        switch list.colorName {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        case "yellow": return .yellow
        case "mint": return .mint
        default: return .blue
        }
    }
}

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

struct TodoListDetailView: View {
    let list: TodoList
    @EnvironmentObject var store: EventStore
    @State private var isShowingCreateEvent = false
    @State private var isShowingCompletedEvents = false
    @State private var isDraggingEvent = false
    @State private var isSplitMode = false
    @State private var isMergeMode = false
    @State private var isTimerMode = false
    @State private var deleteZoneFrame: CGRect = .zero
    @State private var isOverDeleteZone: Bool = false

    private var listEvents: [Event] {
        store.events(for: list)
    }

    private var listCompletedCount: Int {
        store.events.filter { $0.listID == list.id && $0.status == .completed }.count
    }

    var body: some View {
        EventGridView(
            events: listEvents,
            listID: list.id,
            isDraggingEvent: $isDraggingEvent,
            deleteZoneFrame: $deleteZoneFrame,
            isOverDeleteZone: $isOverDeleteZone,
            isSplitMode: $isSplitMode,
            isMergeMode: $isMergeMode,
            isTimerMode: $isTimerMode
        )
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            detailHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            if isDraggingEvent {
                DeleteZoneOverlay(
                    isOver: isOverDeleteZone,
                    deleteZoneFrame: $deleteZoneFrame
                )
            }
        }
        .toolbar(isDraggingEvent ? .hidden : .visible, for: .tabBar)
        .sheet(isPresented: $isShowingCreateEvent) {
            CreateEventView(listID: list.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $isShowingCompletedEvents) {
            NavigationStack {
                CompletedListView()
                    .environmentObject(store)
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            BackButton(title: list.title)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    isShowingCreateEvent = true
                } label: {
                    Image(systemName: "plus")
                }

                Button {
                    isMergeMode.toggle()
                    if isMergeMode { isSplitMode = false; isTimerMode = false }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                }

                Button {
                    if store.activeTimerCalendarEvent != nil {
                        store.stopActiveTimer()
                    } else {
                        isTimerMode.toggle()
                        if isTimerMode { isSplitMode = false; isMergeMode = false }
                    }
                } label: {
                    Image(systemName: store.activeTimerCalendarEvent != nil ? "record.circle.fill" : "record.circle")
                }

                Button {
                    isSplitMode.toggle()
                    if isSplitMode { isMergeMode = false; isTimerMode = false }
                } label: {
                    Image(systemName: "scissors")
                }

                if listCompletedCount > 0 {
                    Button {
                        isShowingCompletedEvents = true
                    } label: {
                        Text("\u{2713} \(listCompletedCount)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
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
