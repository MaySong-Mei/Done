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
    @State private var tagsText: String
    @State private var gridWidth: Int
    @State private var gridHeight: Int
    @State private var scheduleEnabled: Bool
    @State private var timeRanges: [EventFormRange]
    @State private var deadlineEnabled: Bool
    @State private var deadline: Date
    @State private var editorMode: TemplateEditorMode?

    init(
        navigationTitle: String,
        initialTitle: String,
        initialTypeTitle: String,
        initialNote: String,
        initialPriority: Int,
        initialTags: [String],
        initialTimeRanges: [Event.TimeRange],
        initialDeadline: Date?,
        initialGridWidth: Int,
        initialGridHeight: Int,
        onSave: @escaping (EventFormData) -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
        _selectedTypeTitle = State(initialValue: initialTypeTitle)
        _note = State(initialValue: initialNote)
        _priority = State(initialValue: initialPriority)
        _tagsText = State(initialValue: initialTags.joined(separator: ", "))
        _gridWidth = State(initialValue: initialGridWidth)
        _gridHeight = State(initialValue: initialGridHeight)
        _scheduleEnabled = State(initialValue: !initialTimeRanges.isEmpty)
        _timeRanges = State(
            initialValue: initialTimeRanges.map { EventFormRange(start: $0.start, end: $0.end) }
        )
        _deadlineEnabled = State(initialValue: initialDeadline != nil)
        _deadline = State(initialValue: initialDeadline ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                typeSection
                descriptionSection
                prioritySection
                tagsSection
                gridSection
                scheduleSection
                ddlSection
            }
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
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tags = tagsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let ranges = scheduleEnabled ? normalizedRanges(from: timeRanges) : []
                        let ddl = deadlineEnabled ? deadline : nil
                        onSave(
                            EventFormData(
                                title: trimmedTitle,
                                typeTitle: selectedTypeTitle,
                                gridWidth: gridWidth,
                                gridHeight: gridHeight,
                                note: note,
                                priority: priority,
                                tags: tags,
                                timeRanges: ranges,
                                deadline: ddl
                            )
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            templateStore.ensureIncludes(title: selectedTypeTitle)
            if selectedTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedTypeTitle = templateStore.templates.first?.title ?? selectedTypeTitle
            }
        }
        .onChange(of: scheduleEnabled) { enabled in
            if enabled && timeRanges.isEmpty {
                addTimeRange()
            } else if !enabled {
                timeRanges.removeAll()
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
        Section("Title") {
            TextField("Enter title", text: $title)
                .textInputAutocapitalization(.sentences)
        }
    }

    @ViewBuilder var typeSection: some View {
        Section("Type") {
            ForEach(templateStore.templates) { template in
                Button {
                    selectedTypeTitle = template.title
                    editorMode = TemplateEditorMode(
                        originalTitle: template.title,
                        initialTitle: template.title,
                        initialColorHex: template.colorHex
                    )
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ColorHex.toColor(template.colorHex))
                            .frame(width: 10, height: 10)
                        Text(template.title)
                        Spacer()
                        if selectedTypeTitle == template.title {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Button {
                editorMode = TemplateEditorMode(
                    originalTitle: nil,
                    initialTitle: "",
                    initialColorHex: "#8E8E93"
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Template")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var descriptionSection: some View {
        Section("Description") {
            TextEditor(text: $note)
                .frame(minHeight: 100)
        }
    }

    @ViewBuilder var prioritySection: some View {
        Section("Priority") {
            Stepper(value: $priority, in: 0...5) {
                HStack(spacing: 4) {
                    Text(String(repeating: "!", count: priority))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder var tagsSection: some View {
        Section("Tags") {
            TextField("Comma separated tags", text: $tagsText)
                .textInputAutocapitalization(.words)
        }
    }

    @ViewBuilder var gridSection: some View {
        Section("Grid") {
            Stepper(value: $gridWidth, in: 3...64) {
                Text("Grid Width: \(gridWidth)")
            }
            Stepper(value: $gridHeight, in: 3...64) {
                Text("Grid Height: \(gridHeight)")
            }
        }
    }

    @ViewBuilder var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Set schedule", isOn: $scheduleEnabled.animation(.easeInOut(duration: 0.2)))
            if scheduleEnabled {
                ForEach(timeRanges.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker("Start", selection: $timeRanges[index].start, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("End", selection: $timeRanges[index].end, displayedComponents: [.date, .hourAndMinute])
                        Button(role: .destructive) {
                            removeTimeRange(id: timeRanges[index].id)
                        } label: {
                            Text("Remove Range")
                        }
                    }
                }
                Button {
                    addTimeRange()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Time Range")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder var ddlSection: some View {
        Section("DDL") {
            Toggle("Set deadline", isOn: $deadlineEnabled.animation(.easeInOut(duration: 0.2)))
            if deadlineEnabled {
                DatePicker("Deadline", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
            }
        }
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
    let gridWidth: Int
    let gridHeight: Int
    let note: String
    let priority: Int
    let tags: [String]
    let timeRanges: [Event.TimeRange]
    let deadline: Date?
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

private struct TemplateEditorView: View {
    let title: String
    let onSave: (String, Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var templateTitle: String
    @State private var templateColor: Color

    init(title: String, initialTitle: String, initialColor: Color, onSave: @escaping (String, Color) -> Void) {
        self.title = title
        self.onSave = onSave
        _templateTitle = State(initialValue: initialTitle)
        _templateColor = State(initialValue: initialColor)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Template name", text: $templateTitle)
                        .textInputAutocapitalization(.words)
                }
                Section("Color") {
                    ColorPicker("Pick color", selection: $templateColor)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = templateTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(trimmed, templateColor)
                        dismiss()
                    }
                    .disabled(templateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
