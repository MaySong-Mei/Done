//
//  TodoDrawerView.swift
//  DoneMac
//
//  The todo stack sidebar: view, quick-add, open-in-composer.
//

import SwiftUI

struct TodoDrawerView: View {
    let todos: TodoSurfaceModel
    var onEditTodo: (UUID) -> Void = { _ in }
    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Todos")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            HStack(spacing: 6) {
                TextField("Add a todo…", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            List(todos.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title.isEmpty ? "Untitled" : row.title)
                        .lineLimit(2)
                    if let deadline = row.deadline {
                        Text(deadline, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onEditTodo(row.id) }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 200, idealWidth: 230)
    }

    private func addDraft() {
        // Same gate as the Add button (review round-3 F19): Return in an
        // empty field must not mint records. Data preservation protects
        // typed input, not the absence of any.
        guard !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        todos.addTodo(title: draftTitle, now: Date())
        draftTitle = ""
    }
}
