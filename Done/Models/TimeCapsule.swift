//
//  TimeCapsule.swift
//  Done
//
//  "Time capsule" letters: write a note to your future self today and seal it
//  until a chosen future date. Until that date the message stays hidden; once
//  it arrives, it becomes readable. Persisted locally as JSON, like custom
//  anniversaries — display-only, not events.
//

import SwiftUI

struct TimeCapsuleLetter: Codable, Identifiable, Hashable {
    var id = UUID()
    var message: String
    var sealedAt: Date
    var revealAt: Date
    /// Optional (not just Bool) so letters saved before this field existed still
    /// decode — a missing key would otherwise fail the whole array decode.
    var read: Bool?

    /// Whether the reveal date has arrived.
    func isDelivered(now: Date = Date()) -> Bool { revealAt <= now }

    var isRead: Bool { read ?? false }

    /// Just arrived today and not yet opened — surfaces as an inbox banner.
    func isFreshlyArrived(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        isDelivered(now: now) && calendar.isDate(revealAt, inSameDayAs: now) && !isRead
    }
}

/// Load/save helper for the persisted letters, mirroring CustomAnniversaryStore.
enum TimeCapsuleStore {
    static func decode(_ raw: String) -> [TimeCapsuleLetter] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([TimeCapsuleLetter].self, from: data)
        else { return [] }
        return list
    }

    static func encode(_ list: [TimeCapsuleLetter]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let raw = String(data: data, encoding: .utf8) else { return "" }
        return raw
    }
}

// MARK: - Compose

/// Sheet to write a new letter and pick when it unseals (default: one year out).
struct TimeCapsuleComposeView: View {
    @State private var message: String = ""
    @State private var revealAt: Date
    let onSeal: (TimeCapsuleLetter) -> Void
    let onCancel: () -> Void

    private let earliest: Date
    private let latest: Date

    init(onSeal: @escaping (TimeCapsuleLetter) -> Void, onCancel: @escaping () -> Void) {
        self.onSeal = onSeal
        self.onCancel = onCancel
        let cal = Calendar.current
        let now = Date()
        self.earliest = cal.date(byAdding: .day, value: 1, to: now) ?? now
        self.latest = cal.date(byAdding: .year, value: 50, to: now) ?? now
        _revealAt = State(initialValue: cal.date(byAdding: .year, value: 1, to: now) ?? now)
    }

    private var trimmed: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    settingsCard {
                        ZStack(alignment: .topLeading) {
                            if trimmed.isEmpty {
                                Text(L(.timeCapsulePlaceholder))
                                    .font(.system(size: 15))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                            }
                            TextEditor(text: $message)
                                .font(.system(size: 15))
                                .frame(minHeight: 160)
                                .scrollContentBackground(.hidden)
                        }
                    }

                    settingsCard {
                        DatePicker(
                            L(.timeCapsuleOpenOn),
                            selection: $revealAt,
                            in: earliest...latest,
                            displayedComponents: .date
                        )
                        .font(.subheadline)
                    }

                    settingsHintCard(L(.timeCapsuleHint))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(L(.timeCapsule))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(.cancel), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.timeCapsuleSeal)) {
                        onSeal(TimeCapsuleLetter(message: trimmed, sealedAt: Date(), revealAt: revealAt))
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
    }
}

// MARK: - Read

/// Sheet shown when opening a delivered letter.
struct TimeCapsuleReadView: View {
    let letter: TimeCapsuleLetter
    let onClose: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.dateStyle = .long
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "envelope.open.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)

                    Text(letter.message)
                        .font(.system(size: 17))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(String(format: L(.timeCapsuleWrittenOn), Self.dateFormatter.string(from: letter.sealedAt)))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle(L(.timeCapsule))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.done), action: onClose)
                }
            }
        }
    }
}
