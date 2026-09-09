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
            Picker("Kind", selection: $composer.kind) {
                Text("Event").tag(Event.Kind.event)
                Text("Todo").tag(Event.Kind.todo)
            }
            .pickerStyle(.segmented)
            DatePicker("Starts", selection: $composer.start)
            DatePicker("Ends", selection: $composer.end)
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
                Button("Cancel", action: onDone)
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
