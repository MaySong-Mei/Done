//
//  TemplateManagementView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

struct TemplateManagementView: View {
    @StateObject private var dataManager = DataManager.shared
    @State private var showingAddTemplate = false
    @State private var editingTemplate: ActivityTemplate?

    var body: some View {
        NavigationStack {
            List {
                ForEach(dataManager.templates) { template in
                    TemplateRow(template: template)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingTemplate = template
                        }
                }
                .onDelete(perform: deleteTemplates)
                .onMove(perform: moveTemplates)
            }
            .navigationTitle("Activity Templates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddTemplate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showingAddTemplate) {
                TemplateEditView(template: nil)
            }
            .sheet(item: $editingTemplate) { template in
                TemplateEditView(template: template)
            }
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            dataManager.deleteTemplate(dataManager.templates[index])
        }
    }

    private func moveTemplates(from source: IndexSet, to destination: Int) {
        dataManager.reorderTemplates(from: source, to: destination)
    }
}

struct TemplateRow: View {
    let template: ActivityTemplate

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: template.icon)
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 50, height: 50)
                .background(template.color)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.headline)
                Text(template.colorHex)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct TemplateEditView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    let template: ActivityTemplate?

    @State private var name: String
    @State private var selectedColor: Color
    @State private var selectedIcon: String

    private let availableColors: [(String, Color)] = [
        ("#007AFF", .blue),
        ("#34C759", .green),
        ("#FF9500", .orange),
        ("#AF52DE", .purple),
        ("#FF3B30", .red),
        ("#5856D6", .indigo),
        ("#FF2D55", .pink),
        ("#FFCC00", .yellow),
        ("#5AC8FA", .cyan),
        ("#00C7BE", .teal)
    ]

    private let availableIcons = [
        "laptopcomputer", "person.3.fill", "figure.run", "book.fill",
        "cup.and.saucer.fill", "car.fill", "fork.knife", "music.note",
        "paintbrush.fill", "gamecontroller.fill", "tv.fill", "phone.fill",
        "message.fill", "envelope.fill", "house.fill", "cart.fill"
    ]

    init(template: ActivityTemplate?) {
        self.template = template
        _name = State(initialValue: template?.name ?? "")
        _selectedColor = State(initialValue: template?.color ?? .blue)
        _selectedIcon = State(initialValue: template?.icon ?? "laptopcomputer")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    TextField("Name", text: $name)

                    HStack {
                        Text("Preview")
                        Spacer()
                        Image(systemName: selectedIcon)
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(selectedColor)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(availableColors, id: \.0) { hex, color in
                            Circle()
                                .fill(color)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == color ? 3 : 0)
                                )
                                .onTapGesture {
                                    selectedColor = color
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(availableIcons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.title2)
                                .foregroundColor(selectedIcon == icon ? selectedColor : .secondary)
                                .frame(width: 44, height: 44)
                                .background(selectedIcon == icon ? selectedColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture {
                                    selectedIcon = icon
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(template == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTemplate()
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func saveTemplate() {
        let colorHex = selectedColor.toHex() ?? "#007AFF"

        if let template = template {
            var updated = template
            updated.name = name
            updated.colorHex = colorHex
            updated.icon = selectedIcon
            dataManager.updateTemplate(updated)
        } else {
            let newTemplate = ActivityTemplate(
                name: name,
                colorHex: colorHex,
                icon: selectedIcon,
                order: dataManager.templates.count
            )
            dataManager.addTemplate(newTemplate)
        }
    }
}

#Preview {
    TemplateManagementView()
}
