import SwiftUI

/// Lets the user override the time zone the calendar grid is rendered in.
/// Stored as `String?` in UserDefaults under
/// `CalendarDisplayTimeZone.userDefaultsKey` (`@AppStorage`-friendly).
/// "Use System" maps to nil and clears the override.
struct CalendarTimeZonePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CalendarDisplayTimeZone.userDefaultsKey) private var overrideIdentifier: String = ""
    @State private var search: String = ""

    private var allIdentifiers: [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    private var filteredIdentifiers: [String] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allIdentifiers }
        let needle = trimmed.lowercased()
        return allIdentifiers.filter { $0.lowercased().contains(needle) }
    }

    private var selectedIdentifier: String? {
        overrideIdentifier.isEmpty ? nil : overrideIdentifier
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        // Empty string is how `@AppStorage(String?)` would
                        // model "no value"; we use a non-optional binding
                        // here for simplicity, so the sentinel for "use
                        // system" is the empty string.
                        overrideIdentifier = ""
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use System")
                                Text(TimeZone.current.identifier)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedIdentifier == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Selecting a different time zone changes how the calendar grid is laid out and how event times are rendered. Stored event data is unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(filteredIdentifiers, id: \.self) { identifier in
                        Button {
                            overrideIdentifier = identifier
                            dismiss()
                        } label: {
                            HStack {
                                Text(identifier)
                                Spacer()
                                if let abbrev = TimeZone(identifier: identifier)?.abbreviation() {
                                    Text(abbrev)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if selectedIdentifier == identifier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
