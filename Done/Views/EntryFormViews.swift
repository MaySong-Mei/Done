//
//  EntryFormViews.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

// MARK: - Entry Form
struct EntryFormView: View {
    let title: String
    let initialStart: Date
    let initialEnd: Date
    let initialTemplateId: UUID?
    let initialTemplateName: String?
    let showsTemplatePlaceholder: Bool
    let showsDelete: Bool
    let showsSyncedLabel: Bool
    let onCancel: () -> Void
    let onSave: (Date, Date, ActivityTemplate) -> Void
    let onDelete: (() -> Void)?

    @StateObject private var dataManager = DataManager.shared
    @State private var selectedTemplate: ActivityTemplate?
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDeleteConfirmation = false

    init(
        title: String,
        initialStart: Date,
        initialEnd: Date,
        initialTemplateId: UUID?,
        initialTemplateName: String?,
        showsTemplatePlaceholder: Bool,
        showsDelete: Bool,
        showsSyncedLabel: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Date, Date, ActivityTemplate) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.initialTemplateId = initialTemplateId
        self.initialTemplateName = initialTemplateName
        self.showsTemplatePlaceholder = showsTemplatePlaceholder
        self.showsDelete = showsDelete
        self.showsSyncedLabel = showsSyncedLabel
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _startTime = State(initialValue: initialStart)
        _endTime = State(initialValue: initialEnd)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(dataManager.wordlessMode ? "" : "Activity") {
                    if dataManager.templates.isEmpty {
                        if !dataManager.wordlessMode {
                            Text("No templates available")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        if dataManager.wordlessMode {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(dataManager.templates) { template in
                                        Circle()
                                            .fill(Color(hex: template.colorHex) ?? .blue)
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(Color.primary, lineWidth: selectedTemplate?.id == template.id ? 3 : 0)
                                            )
                                            .onTapGesture {
                                                selectedTemplate = template
                                            }
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        } else {
                            Picker("Template", selection: $selectedTemplate) {
                                if showsTemplatePlaceholder {
                                    Text("Select an activity").tag(nil as ActivityTemplate?)
                                }
                                ForEach(dataManager.templates) { template in
                                    HStack {
                                        Circle()
                                            .fill(Color(hex: template.colorHex) ?? .blue)
                                            .frame(width: 12, height: 12)
                                        Text(template.name)
                                    }
                                    .tag(template as ActivityTemplate?)
                                }
                            }
                        }
                    }
                }

                Section("Time") {
                    DatePicker("Start", selection: $startTime)
                    DatePicker("End", selection: $endTime)

                    if let duration = calculateDuration() {
                        LabeledContent("Duration", value: duration.formatAsHoursMinutes())
                            .foregroundColor(.secondary)
                    }
                }

                if showsSyncedLabel {
                    Section("Sync") {
                        Label("Synced to Google Calendar", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                if showError {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                if showsDelete {
                    Section {
                        Button("Delete Entry", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEntry() }
                        .disabled(selectedTemplate == nil)
                }
            }
            .onAppear {
                if selectedTemplate == nil {
                    selectedTemplate = dataManager.templates.first { $0.id == initialTemplateId }
                        ?? dataManager.templates.first { $0.name == initialTemplateName }
                }
            }
            .onChange(of: startTime) { _, _ in
                validateTimes()
            }
            .onChange(of: endTime) { _, _ in
                validateTimes()
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) { onDelete?() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }

    private func calculateDuration() -> TimeInterval? {
        guard endTime > startTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    private func validateTimes() {
        if endTime <= startTime {
            showError = true
            errorMessage = "End time must be after start time"
        } else {
            showError = false
            errorMessage = ""
        }
    }

    private func saveEntry() {
        guard let template = selectedTemplate else { return }
        guard endTime > startTime else {
            showError = true
            errorMessage = "End time must be after start time"
            return
        }
        onSave(startTime, endTime, template)
    }
}

// MARK: - Time Entry Edit View
struct TimeEntryEditView: View {
    let entry: TimeEntry
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    var body: some View {
        EntryFormView(
            title: "Edit Entry",
            initialStart: entry.startTime,
            initialEnd: entry.endTime ?? Date(),
            initialTemplateId: entry.templateId,
            initialTemplateName: entry.templateName,
            showsTemplatePlaceholder: false,
            showsDelete: true,
            showsSyncedLabel: entry.syncedToCalendar,
            onCancel: { dismiss() },
            onSave: { start, end, template in
                let updatedEntry = TimeEntry(
                    id: entry.id,
                    templateId: template.id,
                    templateName: template.name,
                    startTime: start,
                    endTime: end,
                    colorHex: template.colorHex,
                    syncedToCalendar: entry.syncedToCalendar,
                    calendarEventId: entry.calendarEventId
                )
                dataManager.updateTimeEntry(updatedEntry)
                dismiss()
            },
            onDelete: {
                dataManager.deleteTimeEntry(entry)
                dismiss()
            }
        )
    }
}

// MARK: - Time Entry Create View
struct TimeEntryCreateView: View {
    let selectedDate: Date
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    private let initialStart: Date
    private let initialEnd: Date

    init(selectedDate: Date) {
        self.selectedDate = selectedDate

        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(selectedDate) {
            initialStart = now
            initialEnd = calendar.date(byAdding: .hour, value: 1, to: now)!
        } else {
            let dayStart = calendar.startOfDay(for: selectedDate)
            let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart)!
            initialStart = start
            initialEnd = calendar.date(byAdding: .hour, value: 1, to: start)!
        }
    }

    var body: some View {
        EntryFormView(
            title: "New Entry",
            initialStart: initialStart,
            initialEnd: initialEnd,
            initialTemplateId: nil,
            initialTemplateName: nil,
            showsTemplatePlaceholder: true,
            showsDelete: false,
            showsSyncedLabel: false,
            onCancel: { dismiss() },
            onSave: { start, end, template in
                let entry = TimeEntry(
                    templateId: template.id,
                    templateName: template.name,
                    startTime: start,
                    endTime: end,
                    colorHex: template.colorHex,
                    syncedToCalendar: false,
                    calendarEventId: nil
                )
                dataManager.addTimeEntry(entry)
                dismiss()
            }
        )
    }
}

