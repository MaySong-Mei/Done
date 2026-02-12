//
//  CalendarEventFormView.swift
//  Done
//
//  Calendar event form - Google Calendar content with Todo visual style
//

import SwiftUI

struct CalendarEventFormView: View {
    let navigationTitle: String
    let onSave: (CalendarEventFormData) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateStore = EventTypeTemplateStore()
    @State private var title: String
    @State private var selectedTypeTitle: String
    @State private var isAllDay: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var location: String
    @State private var note: String
    @State private var showMoreOptions: Bool = false

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        navigationTitle: String,
        initialTitle: String,
        initialTypeTitle: String,
        initialNote: String,
        initialStartTime: Date,
        initialEndTime: Date,
        onSave: @escaping (CalendarEventFormData) -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
        _selectedTypeTitle = State(initialValue: initialTypeTitle)
        _note = State(initialValue: initialNote)
        _startTime = State(initialValue: initialStartTime)
        _endTime = State(initialValue: initialEndTime)
        _isAllDay = State(initialValue: false)
        _location = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                allDaySection
                timeSection
                locationSection
                typeSection
                moreOptionsSection
                if showMoreOptions {
                    descriptionSection
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .listSectionSpacing(-10)
            .listRowSpacing(0)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onSave(
                            CalendarEventFormData(
                                title: trimmedTitle.isEmpty ? "Untitled Event" : trimmedTitle,
                                typeTitle: selectedTypeTitle,
                                note: note,
                                location: location,
                                startTime: isAllDay ? Calendar.current.startOfDay(for: startTime) : startTime,
                                endTime: isAllDay ? Calendar.current.startOfDay(for: endTime) : normalizedEndTime,
                                isAllDay: isAllDay
                            )
                        )
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
        .onAppear {
            templateStore.ensureIncludes(title: selectedTypeTitle)
            if selectedTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedTypeTitle = templateStore.templates.first?.title ?? selectedTypeTitle
            }
        }
    }

    private var normalizedEndTime: Date {
        let calendar = Calendar.current
        return endTime <= startTime
            ? calendar.date(byAdding: .hour, value: 1, to: startTime) ?? startTime
            : endTime
    }
}

private extension CalendarEventFormView {
    @ViewBuilder var titleSection: some View {
        Section {
            TextField("Event title", text: $title)
        } header: {
            Text("Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.bottom, 2)
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var allDaySection: some View {
        Section {
            Toggle("All-day", isOn: $isAllDay)
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var timeSection: some View {
        Section {
            if isAllDay {
                DatePicker("Starts", selection: $startTime, displayedComponents: [.date])
                DatePicker("Ends", selection: $endTime, displayedComponents: [.date])
            } else {
                DatePicker("Starts", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Ends", selection: $endTime, displayedComponents: [.date, .hourAndMinute])
            }
        } header: {
            Text("Time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.bottom, 2)
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var locationSection: some View {
        Section {
            TextField("Add location", text: $location)
        } header: {
            Text("Location")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.bottom, 2)
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var typeSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(templateStore.templates) { template in
                        let selected = selectedTypeTitle == template.title
                        Button {
                            selectedTypeTitle = template.title
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(ColorHex.toColor(template.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(template.title)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Calendar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.bottom, 2)
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var moreOptionsSection: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMoreOptions.toggle()
                }
            } label: {
                HStack {
                    Text("More options")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showMoreOptions ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var descriptionSection: some View {
        Section {
            TextEditor(text: $note)
                .frame(minHeight: 100)
        } header: {
            Text("Description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.bottom, 2)
        }
    }
}

struct CalendarEventFormData {
    let title: String
    let typeTitle: String
    let note: String
    let location: String
    let startTime: Date
    let endTime: Date
    let isAllDay: Bool

    func toEvent() -> Event {
        Event(
            title: title,
            note: note,
            startTime: startTime,
            endTime: endTime,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            type: typeTitle
        )
    }

    func apply(to event: Event) -> Event {
        var updated = event
        updated.title = title
        updated.type = typeTitle
        updated.note = note
        updated.timeRanges = [Event.TimeRange(start: startTime, end: endTime)]
        updated.startTime = startTime
        updated.endTime = endTime
        return updated
    }
}
