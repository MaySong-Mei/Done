//
//  EventFormView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventFormView: View {
    let navigationTitle: String
    let onSave: (EventFormData) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateStore = EventTypeTemplateStore()
    @State private var title: String
    @State private var selectedTypeTitle: String
    @State private var note: String
    @State private var priority: Int
    @State private var tags: [String]
    @State private var currentTagInput: String = ""
    @State private var timeRanges: [EventFormRange]
    @State private var deadline: Date?
    @State private var expandedRangeID: UUID?
    @State private var editorMode: TemplateEditorMode?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deadlineEnabled: Binding<Bool> {
        Binding(
            get: { deadline != nil },
            set: { enabled in
                if enabled {
                    if deadline == nil {
                        deadline = Date()
                    }
                } else {
                    deadline = nil
                }
            }
        )
    }


    init(
        navigationTitle: String,
        initialTitle: String,
        initialTypeTitle: String,
        initialNote: String,
        initialPriority: Int,
        initialTags: [String],
        initialTimeRanges: [Event.TimeRange],
        initialDeadline: Date?,
        onSave: @escaping (EventFormData) -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
        _selectedTypeTitle = State(initialValue: initialTypeTitle)
        _note = State(initialValue: initialNote)
        _priority = State(initialValue: initialPriority)
        _tags = State(initialValue: initialTags)
        _timeRanges = State(
            initialValue: initialTimeRanges.map { EventFormRange(start: $0.start, end: $0.end) }
        )
        _deadline = State(initialValue: initialDeadline)
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                typeSection
                descriptionSection
                prioritySection
                tagsSection
                scheduleSection
                ddlSection
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
                            EventFormData(
                                title: trimmedTitle,
                                typeTitle: selectedTypeTitle,
                                note: note,
                                priority: priority,
                                tags: tags,
                                timeRanges: normalizedRanges(from: timeRanges),
                                deadline: deadline
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
        .sheet(item: $editorMode) { mode in
            TemplateEditorView(
                title: mode.originalTitle == nil ? "New Template" : "Edit Template",
                initialTitle: mode.initialTitle,
                initialColor: ColorHex.toColor(mode.initialColorHex)
            ) { newTitle, newColor in
                let colorHex = ColorHex.fromColor(newColor)
                if let originalTitle = mode.originalTitle {
                    templateStore.update(from: originalTitle, to: newTitle, colorHex: colorHex)
                    if selectedTypeTitle == originalTitle {
                        selectedTypeTitle = newTitle
                    }
                } else {
                    templateStore.add(newTitle, colorHex: colorHex)
                    selectedTypeTitle = newTitle
                }
            }
        }
    }
}

private extension EventFormView {
    @ViewBuilder var titleSection: some View {
        Section {
            TextField("Enter title", text: $title)
                .textInputAutocapitalization(.sentences)
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
                        .contextMenu {
                            Button("Edit") {
                                editorMode = TemplateEditorMode(
                                    originalTitle: template.title,
                                    initialTitle: template.title,
                                    initialColorHex: template.colorHex
                                )
                            }
                            Button("Delete", role: .destructive) {
                                templateStore.remove(title: template.title)
                                if selectedTypeTitle == template.title {
                                    selectedTypeTitle = templateStore.templates.first?.title ?? ""
                                }
                            }
                        }
                    }

                    Button {
                        editorMode = TemplateEditorMode(
                            originalTitle: nil,
                            initialTitle: "",
                            initialColorHex: "#8E8E93"
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.caption)
                            Text("Add")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Type")
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
        } footer: {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, -6)
        }
    }

    @ViewBuilder var prioritySection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([0, 1, 2, 3], id: \.self) { level in
                        let selected = priority == level
                        Button {
                            priority = level
                        } label: {
                            HStack(spacing: 4) {
                                Text(priorityLabel(level))
                                if selected && level > 0 {
                                    Text(String(repeating: "!", count: level))
                                        .foregroundStyle(.red)
                                }
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
            Text("Priority")
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

    func priorityLabel(_ level: Int) -> String {
        switch level {
        case 0: return "None"
        case 1: return "Low"
        case 2: return "Medium"
        case 3: return "High"
        default: return "None"
        }
    }

    @ViewBuilder var tagsSection: some View {
        Section {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button {
                                    tags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            TextField("Enter tag and press return", text: $currentTagInput)
                .textInputAutocapitalization(.words)
                .onSubmit {
                    let trimmed = currentTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !tags.contains(trimmed) {
                        tags.append(trimmed)
                        currentTagInput = ""
                    }
                }
        } header: {
            Text("Tags")
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

    @ViewBuilder var scheduleSection: some View {
        Section {
            ForEach($timeRanges) { $range in
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedRangeID = expandedRangeID == range.id ? nil : range.id
                            }
                        } label: {
                            HStack {
                                Text(rangeTimeSummary(range))
                                Spacer()
                                Text(rangeDateSummary(range))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(expandedRangeID == range.id ? 90 : 0))
                            }
                        }
                        .buttonStyle(.plain)

                        if expandedRangeID == range.id {
                            VStack(spacing: 8) {
                                DatePicker("Start", selection: $range.start, displayedComponents: [.date, .hourAndMinute])
                                DatePicker("End", selection: $range.end, displayedComponents: [.date, .hourAndMinute])
                            }
                            .padding(.top, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeTimeRange(id: range.id)
                        } label: {
                            Text("Delete")
                        }
                    }
                }

            Button {
                addTimeRange()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.caption)
                    Text("Add Range")
                }
                .foregroundStyle(.blue.opacity(0.6))
            }
        } header: {
            Text("Schedule")
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

    @ViewBuilder var ddlSection: some View {
        Section {
            Toggle("Set deadline", isOn: deadlineEnabled.animation(.easeInOut(duration: 0.2)))
            if deadline != nil {
                DatePicker(
                    "Deadline",
                    selection: Binding(
                        get: { deadline ?? Date() },
                        set: { deadline = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        } header: {
            Text("DDL")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.bottom, 2)
        }
    }

    func rangeTimeSummary(_ range: EventFormRange) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: range.start)) – \(fmt.string(from: range.end))"
    }

    func rangeDateSummary(_ range: EventFormRange) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        let startStr = fmt.string(from: range.start)
        let endStr = fmt.string(from: range.end)
        if startStr == endStr {
            return startStr
        }
        return "\(startStr) – \(endStr)"
    }

    func addTimeRange() {
        let start = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start
        timeRanges.append(EventFormRange(start: start, end: end))
    }

    func removeTimeRange(id: UUID) {
        timeRanges.removeAll { $0.id == id }
    }

    func normalizedRanges(from ranges: [EventFormRange]) -> [Event.TimeRange] {
        let calendar = Calendar.current
        return ranges.map { range in
            let start = range.start
            let end = range.end <= start
                ? calendar.date(byAdding: .hour, value: 1, to: start) ?? start
                : range.end
            return Event.TimeRange(start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }
}

struct EventFormData {
    let title: String
    let typeTitle: String
    let note: String
    let priority: Int
    let tags: [String]
    let timeRanges: [Event.TimeRange]
    let deadline: Date?
    var listID: UUID? = nil

    func toEvent() -> Event {
        Event(
            title: title,
            note: note,
            startTime: timeRanges.first?.start,
            endTime: timeRanges.first?.end,
            timeRanges: timeRanges,
            deadline: deadline,
            priority: priority,
            tags: tags,
            type: typeTitle,
            listID: listID
        )
    }

    func apply(to event: Event) -> Event {
        var updated = event
        updated.title = title
        updated.type = typeTitle
        updated.note = note
        updated.priority = priority
        updated.tags = tags
        updated.timeRanges = timeRanges
        updated.startTime = timeRanges.first?.start
        updated.endTime = timeRanges.first?.end
        updated.deadline = deadline
        return updated
    }
}

private struct EventFormRange: Identifiable {
    let id: UUID
    var start: Date
    var end: Date

    init(id: UUID = UUID(), start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

private struct TemplateEditorMode: Identifiable {
    let id = UUID()
    let originalTitle: String?
    let initialTitle: String
    let initialColorHex: String
}
