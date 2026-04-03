//
//  TemplateEditorView.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct TemplateEditorView: View {
    let title: String
    let onSave: (String, Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var templateTitle: String
    @State private var templateColor: Color

    private var trimmedTemplateTitle: String {
        templateTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                    ColorPicker("Pick color", selection: $templateColor, supportsOpacity: true)
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
                        guard !trimmedTemplateTitle.isEmpty else { return }
                        onSave(trimmedTemplateTitle, templateColor)
                        dismiss()
                    }
                    .disabled(trimmedTemplateTitle.isEmpty)
                }
            }
        }
    }
}
