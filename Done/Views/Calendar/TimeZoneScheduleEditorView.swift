import SwiftUI

/// Lists existing time-zone schedule entries and lets the user add or
/// remove them. Entry semantics: "from this day onward (until the next
/// entry), my home time zone is X." See `TimeZoneScheduleEntry` and
/// `EventStore.upsertTimeZoneScheduleEntry` for the storage contract.
struct TimeZoneScheduleEditorView: View {
    /// The day the calendar is currently showing — used to pre-fill the
    /// "Add" form so the most common gesture ("switch tz starting today")
    /// is one tap away.
    let anchorDate: Date

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingAdd: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Label("Add Entry", systemImage: "plus")
                    }
                } footer: {
                    Text("From the chosen date onward, calendar columns and new events default to the selected time zone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if store.timeZoneSchedule.isEmpty {
                    Section {
                        Text("No schedule entries yet. The calendar uses your device's current time zone everywhere.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Entries") {
                        ForEach(store.timeZoneSchedule) { entry in
                            scheduleRow(entry)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.removeTimeZoneScheduleEntry(id: entry.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Time Zone Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingAdd) {
                TimeZoneScheduleAddForm(initialDate: anchorDate) { newEntry in
                    store.upsertTimeZoneScheduleEntry(newEntry)
                }
            }
        }
    }

    @ViewBuilder
    private func scheduleRow(_ entry: TimeZoneScheduleEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.timeZoneIdentifier)
                    .font(.body)
                Spacer()
                Text(entry.resolvedTimeZone.abbreviation() ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("From \(formatStartDate(entry.startDate))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatStartDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = CalendarOccurrenceKey.referenceTimeZone
        return formatter.string(from: date)
    }
}

private struct TimeZoneScheduleAddForm: View {
    let initialDate: Date
    let onSubmit: (TimeZoneScheduleEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var timeZoneIdentifier: String
    @State private var note: String = ""
    @State private var isPresentingTimeZonePicker: Bool = false

    init(initialDate: Date, onSubmit: @escaping (TimeZoneScheduleEntry) -> Void) {
        self.initialDate = initialDate
        self.onSubmit = onSubmit
        _startDate = State(initialValue: initialDate)
        _timeZoneIdentifier = State(initialValue: TimeZone.current.identifier)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Starts") {
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }

                Section("Time zone") {
                    Button {
                        isPresentingTimeZonePicker = true
                    } label: {
                        HStack {
                            Text(timeZoneIdentifier)
                                .foregroundStyle(.primary)
                            Spacer()
                            if let abbrev = TimeZone(identifier: timeZoneIdentifier)?.abbreviation() {
                                Text(abbrev)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Note (optional)") {
                    TextField("Shanghai trip, moved to NY...", text: $note)
                }
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = TimeZoneScheduleEntry(
                            startDate: startDate,
                            timeZoneIdentifier: timeZoneIdentifier,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onSubmit(entry)
                        dismiss()
                    }
                    .disabled(TimeZone(identifier: timeZoneIdentifier) == nil)
                }
            }
            .sheet(isPresented: $isPresentingTimeZonePicker) {
                TimeZonePickerSheet(
                    selectedIdentifier: timeZoneIdentifier,
                    defaultDisplay: TimeZone.current.identifier
                ) { picked in
                    if let picked {
                        timeZoneIdentifier = picked
                    }
                    // The schedule entry must have a concrete identifier;
                    // "Default" (nil) is rejected silently here.
                }
            }
        }
    }
}
