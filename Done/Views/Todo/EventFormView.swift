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
    @State private var timeRanges: [EventFormRange]
    @State private var deadline: Date?
    @State private var expandedRangeID: UUID?
    @State private var gridExpanded: Bool = false
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
                        let tags = tagsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(
                            EventFormData(
                                title: trimmedTitle,
                                typeTitle: selectedTypeTitle,
                                gridWidth: gridWidth,
                                gridHeight: gridHeight,
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
        Section("Title") {
            TextField("Enter title", text: $title)
                .textInputAutocapitalization(.sentences)
        }
    }

    @ViewBuilder var typeSection: some View {
        Section("Type") {
            ForEach(templateStore.templates) { template in
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
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTypeTitle = template.title
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        templateStore.remove(title: template.title)
                        if selectedTypeTitle == template.title {
                            selectedTypeTitle = templateStore.templates.first?.title ?? ""
                        }
                    } label: {
                        Text("Delete")
                    }
                    Button("Edit") {
                        editorMode = TemplateEditorMode(
                            originalTitle: template.title,
                            initialTitle: template.title,
                            initialColorHex: template.colorHex
                        )
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
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.caption)
                    Text("Add Template")
                }
                .foregroundStyle(.blue.opacity(0.6))
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
                Text(String(repeating: "!", count: priority))
                    .foregroundStyle(.red)
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
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    gridExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Grid Size")
                    Spacer()
                    Text("\(gridWidth) × \(gridHeight)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(gridExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if gridExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([(4,4),(6,6),(8,8),(12,12)], id: \.0) { w, h in
                            let selected = gridWidth == w && gridHeight == h
                            Button {
                                gridWidth = w
                                gridHeight = h
                            } label: {
                                Text("\(w)×\(h)")
                                    .font(.subheadline.monospacedDigit())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                Stepper(value: $gridWidth, in: 3...64) {
                    Text("W: \(gridWidth)")
                }
                Stepper(value: $gridHeight, in: 3...64) {
                    Text("H: \(gridHeight)")
                }
            }
        }
    }

    @ViewBuilder var scheduleSection: some View {
        Section("Schedule") {
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
        }
    }

    @ViewBuilder var ddlSection: some View {
        Section("DDL") {
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
    let gridWidth: Int
    let gridHeight: Int
    let note: String
    let priority: Int
    let tags: [String]
    let timeRanges: [Event.TimeRange]
    let deadline: Date?

    func toEvent() -> Event {
        Event(
            title: title,
            note: note,
            startTime: timeRanges.first?.start,
            endTime: timeRanges.first?.end,
            timeRanges: timeRanges,
            deadline: deadline,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            priority: priority,
            tags: tags,
            type: typeTitle
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
        updated.gridWidth = gridWidth
        updated.gridHeight = gridHeight
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
