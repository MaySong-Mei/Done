//
//  MacTemplateEditorView.swift
//  DoneMac
//
//  The phone's TemplateEditorView (name + color) for the shared event
//  form's "New type" / "Edit type" sheet. Same initializer and save
//  contract; the phone's settings-page chrome is iOS-only, so this is a
//  plain macOS sheet.
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
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(L(.templateName), text: $templateTitle)
                .textFieldStyle(.roundedBorder)
            ColorPicker(L(.pickColor), selection: $templateColor, supportsOpacity: true)
            HStack {
                Spacer()
                Button(L(.cancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L(.save)) {
                    guard !trimmedTemplateTitle.isEmpty else { return }
                    onSave(trimmedTemplateTitle, templateColor)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTemplateTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
