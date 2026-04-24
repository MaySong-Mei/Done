//
//  WannaDetailView.swift
//  Done
//
//  Detail view for a wanna item, following calendar event detail patterns.
//

import SwiftUI

struct WannaDetailView: View {
    let eventID: UUID
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingTitle = false
    @State private var isEditingNote = false
    @State private var draftTitle = ""
    @State private var draftNote = ""

    private var event: Event? {
        store.events.first { $0.id == eventID }
    }

    private var eventColor: Color {
        guard let event else { return .secondary }
        return EventTypeTemplateStore.color(for: event.type)
    }

    var body: some View {
        ScrollView {
            if let event {
                VStack(alignment: .leading, spacing: 20) {
                    titleSection(event)
                    noteSection(event)
                    metadataSection(event)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            detailHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Header

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text(event?.title ?? "Wanna")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if let event {
                    if event.linkedCalendarEventId != nil {
                        Button {
                            store.recallWannaFromCalendar(event)
                        } label: {
                            Image(systemName: "calendar.badge.minus")
                        }
                    } else {
                        Button {
                            store.pushWannaToCalendar(event)
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                    }

                    Button {
                        withAnimation {
                            store.completeWanna(event)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }

                    Button {
                        store.markArchived(event)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Title

    @ViewBuilder
    private func titleSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(eventColor)
                    .frame(width: 5, height: 28)

                if isEditingTitle {
                    TextField("Title", text: $draftTitle)
                        .font(.system(size: 22, weight: .bold))
                        .onSubmit { commitTitle() }
                        .onAppear { draftTitle = event.title }
                } else {
                    Text(event.title)
                        .font(.system(size: 22, weight: .bold))
                        .onTapGesture {
                            draftTitle = event.title
                            isEditingTitle = true
                        }
                }
            }

            if event.linkedCalendarEventId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                    Text("Scheduled")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(eventColor)
            }

            if !event.type.isEmpty {
                Text(event.type)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(eventColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != event?.title else {
            isEditingTitle = false
            return
        }
        if var updated = event {
            updated.title = trimmed
            store.update(updated)
        }
        isEditingTitle = false
    }

    // MARK: - Note

    @ViewBuilder
    private func noteSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            if isEditingNote {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $draftNote)
                        .font(.system(size: 15))
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onAppear { draftNote = event.note }

                    Button {
                        commitNote()
                    } label: {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(eventColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Group {
                    if event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Tap to add a note...")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(event.note)
                            .foregroundStyle(.primary)
                    }
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture {
                    draftNote = event.note
                    isEditingNote = true
                }
            }
        }
    }

    private func commitNote() {
        if var updated = event {
            updated.note = draftNote
            store.update(updated)
        }
        isEditingNote = false
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !event.tags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tags")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(event.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(eventColor.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if let deadline = event.deadline {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deadline")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(deadline, style: .date)
                        .font(.system(size: 15, weight: .medium))
                }
            }

            if event.priority > 0 {
                HStack(spacing: 4) {
                    Text("Priority")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(String(repeating: "!", count: event.priority))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
