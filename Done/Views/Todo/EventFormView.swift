//
//  EventFormView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventFormView: View {
    let navigationTitle: String
    let onSave: (String, String, Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateStore = EventTypeTemplateStore()
    @State private var title: String
    @State private var selectedTypeTitle: String
    @State private var gridWidth: Int
    @State private var gridHeight: Int
    @State private var editorMode: TemplateEditorMode?

    init(
        navigationTitle: String,
        initialTitle: String,
        initialTypeTitle: String,
        initialGridWidth: Int,
        initialGridHeight: Int,
        onSave: @escaping (String, String, Int, Int) -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
        _selectedTypeTitle = State(initialValue: initialTypeTitle)
        _gridWidth = State(initialValue: initialGridWidth)
        _gridHeight = State(initialValue: initialGridHeight)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Enter title", text: $title)
                        .textInputAutocapitalization(.sentences)
                }
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
                Section("Grid") {
                    Stepper(value: $gridWidth, in: 1...64) {
                        Text("Grid Width: \(gridWidth)")
                    }
                    Stepper(value: $gridHeight, in: 1...64) {
                        Text("Grid Height: \(gridHeight)")
                    }
                }
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
                        onSave(trimmedTitle, selectedTypeTitle, gridWidth, gridHeight)
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

private struct TemplateEditorMode: Identifiable {
    let id = UUID()
    let originalTitle: String?
    let initialTitle: String
    let initialColorHex: String
}

private struct TemplateEditorView: View {
    let title: String
    let initialTitle: String
    let initialColor: Color
    let onSave: (String, Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var templateTitle: String
    @State private var templateColor: Color

    init(title: String, initialTitle: String, initialColor: Color, onSave: @escaping (String, Color) -> Void) {
        self.title = title
        self.initialTitle = initialTitle
        self.initialColor = initialColor
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
