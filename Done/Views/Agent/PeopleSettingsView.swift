//
//  PeopleSettingsView.swift
//  Done
//
//  Manage the app-local people and friend groups that can be bound to events.
//  People are renamed inline and "deleted" by archiving (so historical events
//  keep their names). Groups are quick-select templates edited as a name plus
//  a member multi-select.
//

import SwiftUI

struct PeopleSettingsView: View {
    @EnvironmentObject private var store: EventStore
    @State private var newPersonName: String = ""

    var body: some View {
        settingsPage(L(.peopleAndGroups)) {
            peopleCard
            groupsCard
            settingsHintCard(peopleHint)
        }
    }

    private var peopleHint: String {
        L(.people) == "People"
            ? "People are stored only on this device. Removing a person keeps them on past events — it just hides them from the lists."
            : "人员只保存在本机。删除某人不会影响过去的事件记录，只是从列表里隐藏。"
    }

    private var peopleCard: some View {
        settingsCard(L(.people)) {
            HStack(spacing: 8) {
                TextField(L(.newPerson), text: $newPersonName)
                    .textInputAutocapitalization(.words)
                    .onSubmit(commitNewPerson)
                Button(action: commitNewPerson) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(trimmedNewName.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(trimmedNewName.isEmpty)
            }

            if store.activePeople.isEmpty {
                Text(L(.noPeopleYet))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.activePeople) { person in
                    Divider()
                    PersonSettingsRow(person: person)
                }
            }
        }
    }

    private var groupsCard: some View {
        settingsCard(L(.friendGroups)) {
            ForEach(store.friendGroups) { group in
                NavigationLink {
                    FriendGroupEditorView(groupID: group.id)
                        .environmentObject(store)
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(PersonColor.color(named: group.colorName, seed: group.name))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .foregroundStyle(.primary)
                            Text("\(group.memberIDs.count) \(L(.members))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowButtonStyle())
                Divider()
            }

            Button(action: addGroup) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text(L(.newGroup))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var trimmedNewName: String {
        newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewPerson() {
        store.addPerson(named: trimmedNewName)
        newPersonName = ""
    }

    private func addGroup() {
        let name = L(.newGroup)
        store.addFriendGroup(FriendGroup(name: name))
    }
}

/// One person row: inline-editable name + archive button.
private struct PersonSettingsRow: View {
    @EnvironmentObject private var store: EventStore
    let person: Person
    @State private var name: String

    init(person: Person) {
        self.person = person
        _name = State(initialValue: person.name)
    }

    var body: some View {
        HStack(spacing: 10) {
            PersonAvatar(person: person)
            TextField(L(.personNamePlaceholder), text: $name)
                .onSubmit(commit)
            Button {
                store.archivePerson(person)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != person.name else {
            name = person.name
            return
        }
        var updated = person
        updated.name = trimmed
        store.updatePerson(updated)
    }
}

/// Edit a friend group's name and members. Reads the group fresh from the
/// store by id so external changes stay in sync.
private struct FriendGroupEditorView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID
    @State private var name: String = ""
    @State private var didLoad = false

    private var group: FriendGroup? {
        store.friendGroups.first(where: { $0.id == groupID })
    }

    var body: some View {
        settingsPage(L(.newGroup)) {
            settingsCard {
                TextField(L(.groupNamePlaceholder), text: $name)
                    .textInputAutocapitalization(.words)
                    .font(.subheadline)
                    .onSubmit(commitName)
            }

            settingsCard(L(.members)) {
                if store.activePeople.isEmpty {
                    Text(L(.noPeopleYet))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.activePeople) { person in
                        let isMember = group?.memberIDs.contains(person.id) ?? false
                        Button {
                            toggleMember(person.id, isMember: isMember)
                        } label: {
                            HStack(spacing: 10) {
                                PersonAvatar(person: person)
                                Text(person.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isMember {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .font(.subheadline)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }

            settingsDestructiveButton(L(.delete)) {
                if let group { store.deleteFriendGroup(group) }
                dismiss()
            }
        }
        .onAppear {
            guard !didLoad else { return }
            name = group?.name ?? ""
            didLoad = true
        }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        guard var current = group else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current.name else { return }
        current.name = trimmed
        store.updateFriendGroup(current)
    }

    private func toggleMember(_ id: UUID, isMember: Bool) {
        // Route through setGroup so a person ends up in at most one group:
        // adding here removes them from any other group; removing returns
        // them to Default (ungrouped).
        store.setGroup(isMember ? nil : groupID, forPerson: id)
    }
}
