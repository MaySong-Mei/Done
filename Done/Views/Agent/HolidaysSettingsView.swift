//
//  HolidaysSettingsView.swift
//  Done
//
//  Toggles for the lightweight calendar date annotations (Chinese 24 solar
//  terms + common Gregorian holidays) plus management of user-defined
//  anniversaries. See `CalendarAnnotation.swift`.
//

import SwiftUI

struct HolidaysSettingsView: View {
    @EnvironmentObject private var store: EventStore
    @AppStorage(AppSettingsKeys.holidaysShowSolarTerms) private var showSolarTerms = true
    @AppStorage(AppSettingsKeys.holidaysShowGregorianHolidays) private var showGregorianHolidays = true
    @AppStorage(AppSettingsKeys.customAnniversaries) private var anniversariesRaw = ""

    @State private var editing: CustomAnniversary?

    private var anniversaries: [CustomAnniversary] {
        CustomAnniversaryStore.decode(anniversariesRaw)
            .sorted { lhs, rhs in
                let l = Calendar.current.dateComponents([.month, .day], from: lhs.date)
                let r = Calendar.current.dateComponents([.month, .day], from: rhs.date)
                if l.month != r.month { return (l.month ?? 0) < (r.month ?? 0) }
                return (l.day ?? 0) < (r.day ?? 0)
            }
    }

    var body: some View {
        settingsPage(L(.holidaysAndTerms)) {
            settingsCard {
                Toggle(L(.solarTerms24), isOn: $showSolarTerms)
                Toggle(L(.gregorianHolidays), isOn: $showGregorianHolidays)
            }

            settingsCard(L(.anniversaries)) {
                ForEach(anniversaries) { anniversary in
                    Button {
                        editing = anniversary
                    } label: {
                        anniversaryRow(anniversary)
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                }

                Button {
                    editing = CustomAnniversary(title: "", date: Date())
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.caption2)
                        Text(L(.addAnniversary))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .foregroundStyle(.secondary)
                    .contentShape(Capsule())
                    .background(Color.black.opacity(0.001), in: Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            settingsHintCard(L(.hintAnniversaries))
        }
        .sheet(item: $editing) { anniversary in
            AnniversaryEditorView(
                anniversary: anniversary,
                people: store.activePeople,
                onSave: { saved in
                    upsert(saved)
                    editing = nil
                },
                onDelete: anniversaries.contains(where: { $0.id == anniversary.id })
                    ? {
                        remove(anniversary)
                        editing = nil
                    }
                    : nil,
                onCancel: { editing = nil }
            )
        }
    }

    @ViewBuilder
    private func anniversaryRow(_ anniversary: CustomAnniversary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(anniversary.title.isEmpty ? L(.addAnniversary) : anniversary.title)
                    .foregroundStyle(.primary)
                if let name = personName(anniversary.personID) {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(Self.dateLabel.string(from: anniversary.date))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    private func personName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return store.activePeople.first(where: { $0.id == id })?.name
    }

    private func upsert(_ anniversary: CustomAnniversary) {
        var list = CustomAnniversaryStore.decode(anniversariesRaw)
        if let index = list.firstIndex(where: { $0.id == anniversary.id }) {
            list[index] = anniversary
        } else {
            list.append(anniversary)
        }
        anniversariesRaw = CustomAnniversaryStore.encode(list)
    }

    private func remove(_ anniversary: CustomAnniversary) {
        var list = CustomAnniversaryStore.decode(anniversariesRaw)
        list.removeAll { $0.id == anniversary.id }
        anniversariesRaw = CustomAnniversaryStore.encode(list)
    }

    private static let dateLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}

/// Add / edit sheet for a single anniversary. Title + date are required;
/// linking a person is optional.
private struct AnniversaryEditorView: View {
    @State private var draft: CustomAnniversary
    let people: [Person]
    let onSave: (CustomAnniversary) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    init(
        anniversary: CustomAnniversary,
        people: [Person],
        onSave: @escaping (CustomAnniversary) -> Void,
        onDelete: (() -> Void)?,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: anniversary)
        self.people = people
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    private var trimmedTitle: String {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    settingsCard {
                        TextField(L(.title), text: $draft.title)
                            .font(.subheadline)

                        Divider()

                        DatePicker(
                            L(.time),
                            selection: $draft.date,
                            displayedComponents: .date
                        )
                        .font(.subheadline)
                    }

                    if !people.isEmpty {
                        settingsCard {
                            settingsPickerRow(
                                L(.withWhom),
                                selection: Binding(
                                    get: { draft.personID ?? Self.noneID },
                                    set: { draft.personID = ($0 == Self.noneID) ? nil : $0 }
                                ),
                                options: [(Self.noneID, L(.noPerson))]
                                    + people.map { ($0.id, $0.name) }
                            )
                        }
                    }

                    if let onDelete {
                        settingsDestructiveButton(L(.delete), action: onDelete)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(L(.addAnniversary))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(.cancel), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.save)) {
                        var saved = draft
                        saved.title = trimmedTitle
                        onSave(saved)
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    /// Sentinel tag for the "None" person option (UUID can't be nil in a Picker tag).
    private static let noneID = UUID(uuidString: "00000000-0000-0000-0000-00000000FFFF")!
}
