//
//  TypeCatalogEditorView.swift
//  DoneMac
//
//  A2: manage the event-type catalog on Mac — create / rename / recolor /
//  reorder / delete the types that drive every block's color. Drives the
//  SHARED `EventTypeTemplateStore` (the same store iOS edits, backed by the
//  process-wide `EventTypeCatalog` + color history); the Mac only supplies a
//  native list UI. Color↔hex goes through `ColorHex`, whose AppKit path hops
//  sRGB before `getRed` (the dynamic-color trap the plan's B-3 shim fixed).
//
//  The store is TITLE-keyed (update(from:to:)/remove(title:)); the editor
//  addresses each row by its stable `id` and looks up the CURRENT title at
//  commit time, so a rename never leaves a color/delete acting on a stale
//  title (QA #5), and a name commit preserves whatever color was just set
//  (review #3). Name commits on submit/blur/teardown; color commits are
//  debounced so dragging the wheel is one write + one canvas rebuild, not
//  dozens (QA #4 — now that a catalog change rebuilds the canvas frame).
//

import SwiftUI

struct TypeCatalogEditorView: View {
    @ObservedObject var store: EventTypeTemplateStore
    var onClose: () -> Void = {}

    @State private var draftName = ""
    @State private var draftColor = Color.blue
    @State private var showResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Event Types").font(.title3.bold())
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }

            List {
                ForEach(store.templates) { template in
                    TypeCatalogRow(template: template, store: store)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .frame(minHeight: 220)

            Divider()

            HStack(spacing: 8) {
                ColorPicker("", selection: $draftColor, supportsOpacity: false)
                    .labelsHidden()
                TextField("New type", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Reset to defaults") { showResetConfirm = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .confirmationDialog("Reset all event types?",
                                    isPresented: $showResetConfirm, titleVisibility: .visible) {
                    Button("Reset to defaults", role: .destructive) { store.resetToDefaults() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This erases every custom type and its color history.")
                }
        }
        .padding(20)
        .frame(width: 380, height: 440)
    }

    private func addDraft() {
        let title = draftName.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        store.add(title, colorHex: ColorHex.fromColor(draftColor))
        draftName = ""
    }

    /// The title a rename should APPLY, or nil to reject: empty, unchanged,
    /// or a collision with a different existing type (a silent merge would
    /// steal that type's color and drop this row — review #3). Pure, so the
    /// guard is testable without a UI harness.
    static func resolvedRename(templates: [EventTypeTemplate], currentID: UUID, draft: String) -> String? {
        guard let current = templates.first(where: { $0.id == currentID }) else { return nil }
        let new = draft.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != current.title else { return nil }
        guard !templates.contains(where: { $0.id != currentID && $0.title == new }) else { return nil }
        return new
    }
}

private struct TypeCatalogRow: View {
    let template: EventTypeTemplate
    @ObservedObject var store: EventTypeTemplateStore

    @State private var nameDraft: String = ""
    @State private var draftColor: Color?
    @State private var colorCommit: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: { draftColor ?? ColorHex.toColor(template.colorHex) },
                set: { newColor in
                    draftColor = newColor
                    scheduleColorCommit(newColor)   // debounced (QA #4)
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 40)

            TextField("Name", text: $nameDraft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { nameDraft = template.title }
                .onChange(of: template.title) { _, newValue in
                    if !focused { nameDraft = newValue }
                }
                .onSubmit(commitName)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitName() }
                }

            Spacer()

            Button(role: .destructive, action: deleteRow) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete this type")
        }
        // Flush a pending rename/recolor if the sheet tears down before a
        // focus change fires the blur commit (review #4, mirroring
        // InspectorTextField's teardown flush).
        .onDisappear {
            colorCommit?.cancel()
            if let draftColor { commitColor(draftColor) }
            commitName()
        }
    }

    /// The row's current record — the store is title-keyed but rows are
    /// addressed by stable id, so every commit re-reads the CURRENT title +
    /// color (never the possibly-stale captured `template`).
    private var current: EventTypeTemplate? {
        store.templates.first { $0.id == template.id }
    }

    private func commitName() {
        guard let current else { return }
        guard let new = TypeCatalogEditorView.resolvedRename(
            templates: store.templates, currentID: template.id, draft: nameDraft
        ) else {
            nameDraft = current.title   // rejected (empty / no-op / collision)
            return
        }
        store.update(from: current.title, to: new, colorHex: current.colorHex)
    }

    private func scheduleColorCommit(_ color: Color) {
        colorCommit?.cancel()
        colorCommit = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            commitColor(color)
        }
    }

    private func commitColor(_ color: Color) {
        guard let current else { return }
        let hex = ColorHex.fromColor(color)
        guard hex != current.colorHex else { return }
        store.update(from: current.title, to: current.title, colorHex: hex)
    }

    private func deleteRow() {
        // Remove by the CURRENT title (a pending blur-rename may have changed
        // it), never the captured one (QA #5).
        guard let current else { return }
        store.remove(title: current.title)
    }
}
