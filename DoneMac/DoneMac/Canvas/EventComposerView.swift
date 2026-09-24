//
//  EventComposerView.swift
//  DoneMac
//
//  Create/edit sheet over ComposerModel. Keystrokes live entirely in the
//  composer's observation island (budget assertion 5).
//

import SwiftUI

struct EventComposerView: View {
    @Bindable var composer: ComposerModel
    var onDone: () -> Void

    private var isEditing: Bool { composer.editingEventID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit" : "New")
                .font(.title3.bold())
            TextField("Title", text: $composer.title)
                .textFieldStyle(.roundedBorder)
            if composer.allowsTimeEditing {
                Picker("Kind", selection: $composer.kind) {
                    Text("Event").tag(Event.Kind.event)
                    Text("Todo").tag(Event.Kind.todo)
                }
                .pickerStyle(.segmented)
                DatePicker("Starts", selection: $composer.start)
                DatePicker("Ends", selection: $composer.end)
                Divider()
                RecurrenceRuleControl(
                    unit: $composer.repeatUnit,
                    interval: $composer.repeatInterval,
                    endType: $composer.repeatEndType,
                    endDate: $composer.repeatEndDate,
                    endCount: $composer.repeatEndCount
                )
            } else {
                Text("Recurring series: title-only edits on Mac for now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if isEditing {
                    Button(role: .destructive) {
                        composer.delete(now: Date())
                        onDone()
                    } label: { Text("Delete") }
                    if composer.kind == .todo {
                        Button("Back to stack") {
                            composer.returnToStack(now: Date())
                            onDone()
                        }
                    }
                }
                Spacer()
                Button("Cancel") {
                    composer.cancel(now: Date())
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    composer.save(now: Date())
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
