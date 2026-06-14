//
//  EventPeoplePickerView.swift
//  Done
//
//  Picker for binding people / friend groups to an event. Surfaces existing
//  people and groups for multi-select, and supports creating a new person
//  inline. Selecting a friend group toggles its current members — the group
//  itself is never stored on the event, only the resolved people ids.
//

import SwiftUI
import PhotosUI

// MARK: - Avatar image storage

/// Stores uploaded person avatars as downscaled JPEGs on disk (Application
/// Support/PersonAvatars), keyed by a unique filename held on `Person`. Keeps
/// image bytes out of UserDefaults. An in-memory `NSCache` avoids re-reading
/// from disk on every render.
enum PersonAvatarStore {
    private static let cache = NSCache<NSString, UIImage>()

    private static var directory: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("PersonAvatars", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func image(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = directory?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// Downscale + save as JPEG under a fresh unique filename; returns it.
    /// A new filename each time avoids stale `NSCache`/SwiftUI image reuse
    /// when a person's photo is replaced.
    static func save(_ image: UIImage) -> String? {
        let resized = image.resizedForAvatar()
        guard let data = resized.jpegData(compressionQuality: 0.85),
              let dir = directory else { return nil }
        let name = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            cache.setObject(resized, forKey: name as NSString)
            return name
        } catch {
            return nil
        }
    }

    static func delete(named name: String) {
        cache.removeObject(forKey: name as NSString)
        if let url = directory?.appendingPathComponent(name) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension UIImage {
    /// Cap the longest side so saved avatars stay small.
    func resizedForAvatar(maxDimension: CGFloat = 256) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Shared color / chip helpers

/// Maps a `Person`/`FriendGroup` `colorName` to a SwiftUI color, falling back
/// to a stable color derived from a seed string when no name is set. Kept in
/// one place so people chips read consistently across the form, picker, and
/// settings.
enum PersonColor {
    static let palette: [String: Color] = [
        "blue": .blue, "green": .green, "orange": .orange, "purple": .purple,
        "red": .red, "pink": .pink, "teal": .teal, "indigo": .indigo,
        "yellow": .yellow, "mint": .mint
    ]

    static func color(named name: String?, seed: String) -> Color {
        if let name, let resolved = palette[name] {
            return resolved
        }
        let names = Person.availableColors
        let index = abs(seed.hashValue) % names.count
        return palette[names[index]] ?? .blue
    }
}

extension Person {
    var displayColor: Color { PersonColor.color(named: colorName, seed: name) }

    /// Up to two uppercased initials for an avatar, falling back to "?".
    var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
        let letters = parts.prefix(2).compactMap { $0.first }
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }
}

/// Small circular avatar showing a person's initials over their color.
struct PersonAvatar: View {
    let person: Person
    var size: CGFloat = 28

    var body: some View {
        if let name = person.avatarImageName, let image = PersonAvatarStore.image(named: name) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(person.displayColor.opacity(0.22))
                .overlay(
                    Text(person.initials)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(person.displayColor)
                )
                .frame(width: size, height: size)
        }
    }
}

/// Compact name + avatar chip used in the event form's "With" row.
struct PersonChip: View {
    let person: Person
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            PersonAvatar(person: person, size: 22)
            Text(person.name)
                .font(.subheadline)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, onRemove == nil ? 10 : 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.001), in: Capsule())
        .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Picker

struct EventPeoplePickerView: View {
    @Binding var selectedPeopleIDs: [UUID]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @State private var newPersonName: String = ""
    @State private var searchText: String = ""
    @State private var showAddPerson: Bool = false
    @State private var editingPerson: Person?

    private var selectedSet: Set<UUID> { Set(selectedPeopleIDs) }

    private var filteredPeople: [Person] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.activePeople }
        return store.activePeople.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    searchCard
                    if groupSections.isEmpty {
                        emptyCard
                    } else {
                        ForEach(groupSections) { section in
                            groupCard(section)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                pickerHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .alert(L(.newPerson), isPresented: $showAddPerson) {
                TextField(L(.personNamePlaceholder), text: $newPersonName)
                    .textInputAutocapitalization(.words)
                Button(L(.add), action: commitNewPerson)
                    .disabled(trimmedNewName.isEmpty)
                Button(L(.cancel), role: .cancel) { newPersonName = "" }
            }
            .sheet(item: $editingPerson) { person in
                PersonEditSheet(person: person) {
                    // On archive, drop from the current selection so the
                    // composer doesn't keep an unselectable person.
                    selectedPeopleIDs.removeAll { $0 == person.id }
                }
                .environmentObject(store)
            }
        }
    }

    /// Custom sheet header matching the app's other composer sheets
    /// (`CalendarEventFormView`): centered bold title with glass-capsule
    /// buttons left (new person) and right (Done).
    private var pickerHeader: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            ZStack {
                Text(L(.selectPeople))
                    .font(.headline.weight(.bold))

                HStack(spacing: 10) {
                    Button {
                        newPersonName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        showAddPerson = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        dismiss()
                    } label: {
                        Text(L(.done))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct GroupSection: Identifiable {
        let id: String
        let title: String
        let people: [Person]
    }

    /// People split into one section per group, with an ungrouped "Default"
    /// section last. Empty groups are hidden. Respects the search filter.
    private var groupSections: [GroupSection] {
        var sections: [GroupSection] = []
        for group in store.friendGroups {
            let members = filteredPeople.filter { group.memberIDs.contains($0.id) }
            if !members.isEmpty {
                sections.append(GroupSection(id: group.id.uuidString, title: group.name, people: members))
            }
        }
        let grouped = Set(store.friendGroups.flatMap { $0.memberIDs })
        let defaultPeople = filteredPeople.filter { !grouped.contains($0.id) }
        if !defaultPeople.isEmpty {
            sections.append(GroupSection(id: "default", title: L(.defaultGroup), people: defaultPeople))
        }
        return sections
    }

    private var searchCard: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L(.search), text: $searchText)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.subheadline)
        }
    }

    private var emptyCard: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            Text(L(.noPeopleYet))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One group rendered as a form-style card: a header row (group select-all
    /// circle + title) and the member rows, matching the event form's cards.
    private func groupCard(_ section: GroupSection) -> some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        toggleAll(section.people)
                    } label: {
                        selectionCircle(isSelected: allSelected(section.people))
                    }
                    .buttonStyle(.plain)
                    Text(section.title)
                        .font(.headline)
                    Spacer()
                }
                ForEach(Array(section.people.enumerated()), id: \.element.id) { _, person in
                    Divider()
                    personRow(person)
                }
            }
        }
    }

    private func personRow(_ person: Person) -> some View {
        let isSelected = selectedSet.contains(person.id)
        return HStack(spacing: 12) {
            Button {
                toggle(person.id)
            } label: {
                selectionCircle(isSelected: isSelected)
            }
            .buttonStyle(.plain)

            Button {
                editingPerson = person
            } label: {
                HStack(spacing: 12) {
                    PersonAvatar(person: person)
                    Text(person.name)
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func allSelected(_ people: [Person]) -> Bool {
        !people.isEmpty && people.allSatisfy { selectedSet.contains($0.id) }
    }

    private func toggleAll(_ people: [Person]) {
        let ids = people.map(\.id)
        if allSelected(people) {
            selectedPeopleIDs.removeAll { ids.contains($0) }
        } else {
            for id in ids where !selectedSet.contains(id) {
                selectedPeopleIDs.append(id)
            }
        }
    }

    /// Leading checkbox-style selection indicator: a hollow circle when
    /// unselected, a filled accent check-circle when selected.
    private func selectionCircle(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .frame(width: 24, height: 24)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
    }

    private var trimmedNewName: String {
        newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewPerson() {
        guard let person = store.addPerson(named: trimmedNewName) else { return }
        if !selectedSet.contains(person.id) {
            selectedPeopleIDs.append(person.id)
        }
        newPersonName = ""
    }

    private func toggle(_ id: UUID) {
        if let index = selectedPeopleIDs.firstIndex(of: id) {
            selectedPeopleIDs.remove(at: index)
        } else {
            selectedPeopleIDs.append(id)
        }
    }

}

/// Edit a single person: rename, recolor, or remove (soft-archive). Reads the
/// person fresh from the store by id; commits name/color on change.
struct PersonEditSheet: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    let personID: UUID
    private let originalName: String
    var onArchive: () -> Void = {}

    @State private var name: String
    @State private var colorName: String?
    @State private var showNewGroup: Bool = false
    @State private var newGroupName: String = ""
    @State private var photoItem: PhotosPickerItem?

    private var currentGroupID: UUID? { store.groupID(forPerson: personID) }

    init(person: Person, onArchive: @escaping () -> Void = {}) {
        personID = person.id
        originalName = person.name
        self.onArchive = onArchive
        _name = State(initialValue: person.name)
        _colorName = State(initialValue: person.colorName)
    }

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    nameCard
                    colorCard
                    groupsCard
                    deleteButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                editHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .alert(L(.newGroup), isPresented: $showNewGroup) {
                TextField(L(.groupNamePlaceholder), text: $newGroupName)
                    .textInputAutocapitalization(.words)
                Button(L(.add)) {
                    let groupName = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !groupName.isEmpty else { return }
                    let group = FriendGroup(name: groupName)
                    store.addFriendGroup(group)
                    store.setGroup(group.id, forPerson: personID)
                    newGroupName = ""
                }
                Button(L(.cancel), role: .cancel) { newGroupName = "" }
            }
        }
    }

    /// Custom header matching the composer sheets: centered bold title +
    /// glass-capsule Done.
    private var editHeader: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            ZStack {
                Text(L(.editPerson))
                    .font(.headline.weight(.bold))
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        commit()
                        dismiss()
                    } label: {
                        Text(L(.done))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var nameCard: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    avatarPreview
                }
                .buttonStyle(.plain)

                TextField(L(.personNamePlaceholder), text: $name)
                    .font(.subheadline)
                    .textInputAutocapitalization(.words)
                    .onSubmit(commit)

                if store.person(id: personID)?.avatarImageName != nil {
                    Button(action: removeAvatar) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await applyPickedPhoto(item) }
        }
    }

    /// 40pt avatar (uploaded photo or initials circle) with a small camera
    /// badge hinting it's tappable to change.
    private var avatarPreview: some View {
        let current = store.person(id: personID)
        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let name = current?.avatarImageName, let image = PersonAvatarStore.image(named: name) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Circle()
                        .fill(PersonColor.color(named: colorName, seed: name))
                        .overlay(
                            Text(initials)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            Image(systemName: "camera.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
        }
    }

    @MainActor
    private func applyPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        if let old = store.person(id: personID)?.avatarImageName {
            PersonAvatarStore.delete(named: old)
        }
        guard let fileName = PersonAvatarStore.save(image),
              var person = store.person(id: personID) else { return }
        person.avatarImageName = fileName
        store.updatePerson(person)
        photoItem = nil
    }

    private func removeAvatar() {
        guard var person = store.person(id: personID) else { return }
        if let old = person.avatarImageName {
            PersonAvatarStore.delete(named: old)
        }
        person.avatarImageName = nil
        store.updatePerson(person)
    }

    private var colorCard: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(.color)).font(.headline)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Person.availableColors, id: \.self) { c in
                        let isSelected = colorName == c
                        Circle()
                            .fill(PersonColor.color(named: c, seed: name))
                            .frame(width: 34, height: 34)
                            .overlay {
                                if isSelected {
                                    Circle().strokeBorder(.primary, lineWidth: 2)
                                }
                            }
                            .onTapGesture {
                                colorName = c
                                commit()
                            }
                    }
                }
            }
        }
    }

    private var groupsCard: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(.friendGroups)).font(.headline)
                Divider()
                groupChoiceRow(title: L(.defaultGroup), isSelected: currentGroupID == nil) {
                    store.setGroup(nil, forPerson: personID)
                }
                ForEach(store.friendGroups) { group in
                    Divider()
                    groupChoiceRow(title: group.name, isSelected: currentGroupID == group.id) {
                        store.setGroup(group.id, forPerson: personID)
                    }
                }
                Divider()
                Button {
                    newGroupName = ""
                    showNewGroup = true
                } label: {
                    Label(L(.newGroup), systemImage: "plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let person = store.person(id: personID) {
                store.archivePerson(person)
            }
            onArchive()
            dismiss()
        } label: {
            Text(L(.delete))
                .font(.headline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .background(Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func groupChoiceRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var initials: String {
        store.person(id: personID).map(\.initials) ?? String(name.prefix(1)).uppercased()
    }

    private func commit() {
        guard var person = store.person(id: personID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        person.name = trimmed.isEmpty ? originalName : trimmed
        person.colorName = colorName
        store.updatePerson(person)
    }
}
