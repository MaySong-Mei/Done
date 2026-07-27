//
//  ReminderPanelView.swift
//  Done
//
//  Inline reminder section in the gap between the calendar header and the
//  timeline. Collapsed, it shows only a faint count line ("N reminders") styled
//  like the timeline's gray hour labels. Pulling the timeline down at the top
//  (handled by the host) springs it open; it then occupies real layout space and
//  the timeline reflows BELOW it — never covered. Swiping up on its grabber (or
//  scrolling the timeline up, handled by the host) collapses it again.
//
//  Height is host-driven via `height`, so the open/close animation and the
//  timeline reflow stay in sync. Lists `store.visibleReminders`; scheduling/AI
//  prefill happens in the host via `onAddToSchedule`.
//

import SwiftUI

struct ReminderPanelView: View {
    @EnvironmentObject private var store: EventStore
    @Binding var isOpen: Bool
    /// Current (animated) visible height, owned by the host. 0 == collapsed.
    var height: CGFloat
    var maxHeight: CGFloat
    var horizontalPadding: CGFloat
    var schedulingReminderID: UUID?
    var onAddToSchedule: (Reminder) -> Void

    @GestureState private var closeDrag: CGFloat = 0
    @State private var newReminderText = ""
    @FocusState private var isComposerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// Match the calendar event card's title size (same user setting).
    @AppStorage(AppSettingsKeys.calendarEventFontSize)
    private var eventFontSizeSetting: Double = Double(calendarEventTitleFontSizeDefault)
    private var itemFontSize: CGFloat { min(max(CGFloat(eventFontSizeSetting), 9), 16) }

    private static let headerHeight: CGFloat = 46
    private static let composerHeight: CGFloat = 54
    private static let rowHeight: CGFloat = 46

    private var reminders: [Reminder] { store.visibleReminders }
    /// Count of *pending* (not-yet-done) reminders — completed-today items still
    /// show in the open list but don't count toward the badge/collapsed hint.
    private var pendingCount: Int { reminders.lazy.filter { !$0.isCompleted }.count }

    /// Fully-open height for a given reminder count — the host uses the same math
    /// to size the timeline inset, so they agree.
    static func openHeight(count: Int, maxHeight: CGFloat) -> CGFloat {
        let chrome = headerHeight + composerHeight
        let naturalList = count == 0 ? 56 : CGFloat(count) * rowHeight
        let listCeiling = max(96, maxHeight - chrome)
        return chrome + min(naturalList, listCeiling)
    }

    private var openHeight: CGFloat {
        Self.openHeight(count: reminders.count, maxHeight: maxHeight)
    }

    private var listHeight: CGFloat {
        openHeight - Self.headerHeight - Self.composerHeight
    }

    /// Live height incl. the rubber-banded close drag.
    private var clampedHeight: CGFloat {
        min(openHeight, max(0, height + closeDrag))
    }

    var body: some View {
        Group {
            if clampedHeight > 1 {
                card
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Capture-first: a half-typed reminder commits rather than dying
        // with the process. addReminder clears the field, so a phase flap
        // can't double-add (store guards the then-empty title).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active,
               !newReminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addReminder()
            }
        }
    }

    // MARK: - Open card

    private var card: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider().opacity(0.35)
            list
            Divider().opacity(0.35)
            composer
        }
        .frame(height: openHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        // Clip to the host-driven height so content reveals from the top as it
        // opens — no card background, it sits directly on the calendar.
        .frame(height: clampedHeight, alignment: .top)
        .clipped()
    }

    /// Title row. Drag up here (or scroll the timeline up) collapses.
    private var cardHeader: some View {
        HStack {
            Text(L(.reminders))
                // Match the header capsule's date title.
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.headerHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($closeDrag) { value, state, _ in
                    state = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.predictedEndTranslation.height < -openHeight * 0.25 {
                        setOpen(false)
                    }
                }
        )
    }

    @ViewBuilder
    private var list: some View {
        if reminders.isEmpty {
            Text(L(.noRemindersYet))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .frame(height: listHeight)
        } else {
            List {
                ForEach(reminders) { reminder in
                    ReminderRow(
                        reminder: reminder,
                        isScheduling: schedulingReminderID == reminder.id,
                        fontSize: itemFontSize,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.toggleReminderCompletion(reminder)
                            }
                        },
                        onSchedule: { onAddToSchedule(reminder) },
                        onRename: { newTitle in
                            var updated = reminder
                            updated.title = newTitle
                            store.updateReminder(updated)
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.deleteReminder(reminder)
                        } label: {
                            Label(L(.delete), systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Strip List's default top/bottom inset and section spacing so rows
            // sit flush against the title and composer (no fat padding).
            .contentMargins(.vertical, 0, for: .scrollContent)
            .listSectionSpacing(0)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            TextField(L(.newReminderPlaceholder), text: $newReminderText)
                .font(.system(size: itemFontSize))
                .focused($isComposerFocused)
                .submitLabel(.done)
                .onSubmit(addReminder)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.composerHeight)
    }

    private func addReminder() {
        store.addReminder(titled: newReminderText)
        newReminderText = ""
        isComposerFocused = true
    }

    private func setOpen(_ open: Bool) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            isOpen = open
        }
        if !open { isComposerFocused = false }
    }
}

// MARK: - Row

private struct ReminderRow: View {
    let reminder: Reminder
    let isScheduling: Bool
    let fontSize: CGFloat
    let onToggle: () -> Void
    let onSchedule: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: reminder.isCompleted ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.isCompleted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)

            if isEditing {
                TextField("", text: $draft)
                    .font(.system(size: fontSize))
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(reminder.title)
                    .font(.system(size: fontSize))
                    .strikethrough(reminder.isCompleted, color: .secondary)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if !reminder.isCompleted && !isEditing {
                if isScheduling {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: onSchedule) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.body)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(.addToSchedule))
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .contentShape(Rectangle())
        // Tap the row to edit its title inline.
        .onTapGesture { beginEditing() }
        .contextMenu {
            if !reminder.isCompleted {
                Button {
                    onSchedule()
                } label: {
                    Label(L(.addToSchedule), systemImage: "calendar.badge.plus")
                }
            }
        }
        // Focus loss doesn't fire on backgrounding/kill; commit the in-
        // flight rename rather than lose it. commit() no-ops on an
        // unchanged/empty draft, so repeats are safe.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, isEditing {
                commit()
            }
        }
    }

    private func beginEditing() {
        guard !isEditing else { return }
        draft = reminder.title
        isEditing = true
        fieldFocused = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != reminder.title {
            onRename(trimmed)
        }
        isEditing = false
        fieldFocused = false
    }
}
