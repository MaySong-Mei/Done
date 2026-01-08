//
//  TemplateDetailView.swift
//  Done
//
//  Template detail and reminder list UI.
//

import SwiftUI

struct TemplateDetailView: View {
    let template: ActivityTemplate
    @State private var items: [TemplateTodoItem] = []
    @State private var newItemTitle = ""
    @State private var isAdding = false
    @State private var expandedItemID: UUID?
    @State private var suppressCollapse = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            header

            List {
                ForEach(sortedItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Button {
                                toggle(item)
                            } label: {
                                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            if expandedItemID == item.id {
                                TextField("Reminder", text: bindingForTitle(item))
                                    .textFieldStyle(.plain)
                                    .onTapGesture {
                                        suppressCollapse = true
                                    }
                            } else {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .strikethrough(item.isDone, color: .secondary)
                                    .onTapGesture {
                                        expandedItemID = item.id
                                        suppressCollapse = true
                                    }
                            }

                            Spacer()
                        }
                    }
                }
                .onDelete(perform: deleteItems)

                addRow
            }
            .listStyle(.plain)
        }
        .padding(.top, 10)
        .navigationTitle("Template")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadItems)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: template.icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(template.color)
                .frame(width: 44, height: 44)
                .background(template.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(template.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle")
                .foregroundStyle(Color.secondary)

            TextField("New Reminder", text: $newItemTitle)
                .focused($isInputFocused)
                .submitLabel(.done)
                .onSubmit { addItem() }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = true
            isAdding = true
        }
    }

    private func storageKey() -> String {
        "template.todo.\(template.id.uuidString)"
    }

    private var sortedItems: [TemplateTodoItem] {
        let pending = items.filter { !$0.isDone }
        let done = items.filter { $0.isDone }
        return pending + done
    }

    private func loadItems() {
        let key = storageKey()
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TemplateTodoItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func saveItems() {
        let key = storageKey()
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        items.append(TemplateTodoItem(title: title))
        newItemTitle = ""
        isInputFocused = true
        saveItems()
    }

    private func toggle(_ item: TemplateTodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        saveItems()
    }

    private func deleteItems(at offsets: IndexSet) {
        let ids = offsets.map { sortedItems[$0].id }
        items.removeAll { ids.contains($0.id) }
        saveItems()
    }

    private func updateItem(_ id: UUID, mutate: (inout TemplateTodoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        saveItems()
    }

    private func bindingForTitle(_ item: TemplateTodoItem) -> Binding<String> {
        Binding(
            get: { item.title },
            set: { newValue in
                updateItem(item.id) { entry in
                    entry.title = newValue
                }
            }
        )
    }
}

struct TemplateTodoItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var isDone: Bool
    var dueTime: Date?
    var priority: Int

    enum Priority: Int, CaseIterable {
        case none = 0
        case low = 1
        case medium = 2
        case high = 3
    }

    init(
        id: UUID = UUID(),
        title: String,
        isDone: Bool = false,
        dueTime: Date? = nil,
        priority: Int = Priority.none.rawValue
    ) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.dueTime = dueTime
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case isDone
        case dueTime
        case priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        dueTime = try container.decodeIfPresent(Date.self, forKey: .dueTime)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? Priority.none.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(isDone, forKey: .isDone)
        try container.encodeIfPresent(dueTime, forKey: .dueTime)
        try container.encode(priority, forKey: .priority)
    }
}
