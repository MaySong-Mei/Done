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
            settingsPage(title) {
                settingsCard(L(.name)) {
                    TextField(L(.templateName), text: $templateTitle)
                        .textInputAutocapitalization(.words)
                }
                settingsCard("Color") {
                    ColorPicker(L(.pickColor), selection: $templateColor, supportsOpacity: true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L(.cancel)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L(.save)) {
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
