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

    private var selectedSet: Set<UUID> { Set(selectedPeopleIDs) }

    var body: some View {
        NavigationStack {
            List {
                addPersonSection
                if !store.friendGroups.isEmpty {
                    groupsSection
                }
                peopleSection
            }
            .navigationTitle(L(.selectPeople))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.done)) { dismiss() }
                }
            }
        }
    }

    private var addPersonSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField(L(.personNamePlaceholder), text: $newPersonName)
                    .textInputAutocapitalization(.words)
                    .onSubmit(commitNewPerson)
                Button(action: commitNewPerson) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(trimmedNewName.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(trimmedNewName.isEmpty)
            }
        } header: {
            Text(L(.addPerson))
        }
    }

    private var groupsSection: some View {
        Section(L(.friendGroups)) {
            ForEach(store.friendGroups) { group in
                let members = store.people(for: group.memberIDs).filter { !$0.isArchived }
                let memberIDs = members.map(\.id)
                let allSelected = !memberIDs.isEmpty && memberIDs.allSatisfy { selectedSet.contains($0) }
                Button {
                    toggleGroup(memberIDs: memberIDs, allSelected: allSelected)
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(PersonColor.color(named: group.colorName, seed: group.name))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                            Text("\(members.count) \(L(.members))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if allSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(memberIDs.isEmpty)
            }
        }
    }

    private var peopleSection: some View {
        Section(L(.people)) {
            if store.activePeople.isEmpty {
                Text(L(.noPeopleYet))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.activePeople) { person in
                    let isSelected = selectedSet.contains(person.id)
                    Button {
                        toggle(person.id)
                    } label: {
                        HStack(spacing: 10) {
                            PersonAvatar(person: person)
                            Text(person.name)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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

    private func toggleGroup(memberIDs: [UUID], allSelected: Bool) {
        if allSelected {
            selectedPeopleIDs.removeAll { memberIDs.contains($0) }
        } else {
            for id in memberIDs where !selectedSet.contains(id) {
                selectedPeopleIDs.append(id)
            }
        }
    }
}
