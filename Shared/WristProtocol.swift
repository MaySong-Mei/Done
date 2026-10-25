//
//  WristProtocol.swift
//  Shared (Done + DoneWatch)
//
//  The wire contract between the iPhone app and the watch app. The phone is
//  the only authority: it owns the EventStore, the account and the sync
//  engine. The watch holds no events and no credentials — it renders the
//  latest `WristSnapshot` the phone pushed and sends `WristCommand`s back.
//
//  Transport (WatchConnectivity):
//    phone → watch  `WristSnapshot`  as the session's application context:
//                   latest value wins, delivered even while the watch app is
//                   not running, and readable at launch from
//                   `receivedApplicationContext`.
//    watch → phone  `WristCommand`   as a `sendMessage` while the phone is
//                   reachable (immediate, and the reply carries the receipt),
//                   else as a user-info transfer: a durable FIFO queue that
//                   survives the watch app being killed and wakes the iPhone
//                   app in the background to deliver. The simulator never
//                   delivers user-info transfers; devices do.
//  Both ride as one JSON `Data` value under a single dictionary key
//  (`WristWire`), so nothing here depends on property-list type coercion.
//
//  Compatibility: the watch app ships inside the iOS app bundle, so the two
//  sides update together — but the application context persists across
//  updates, so a freshly updated watch can read a snapshot the previous phone
//  build wrote. Every snapshot field is therefore defaulted on decode
//  (`WristSnapshot.init(from:)`); add new fields the same way.
//
//  Every type here is `nonisolated`: both apps compile with main-actor
//  default isolation, and the WatchConnectivity delegate decodes these on
//  its own queue.
//

import Foundation

nonisolated enum WristWire {
    static let snapshotKey = "wrist.snapshot"
    static let commandKey = "wrist.command"
    /// The phone's immediate answer to a command sent over `sendMessage`.
    static let receiptKey = "wrist.receipt"

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// One tappable type on the watch's start grid. `id` is the phone's
/// `EventTypeTemplate.id`; `title` is what a started event's `type` becomes.
nonisolated struct WristType: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var colorHex: String
}

/// One timed occurrence the phone projected for the watch's window
/// (yesterday through the day after tomorrow). The watch resolves "what is
/// happening now" from these itself — the phone pushes on data changes, not
/// on the clock, so an event that simply *starts* must become current
/// without a push.
nonisolated struct WristOccurrence: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var eventID: UUID
    var title: String
    var type: String
    var colorHex: String
    var start: Date
    var end: Date
    /// An embedded interrupt ("phone rang") takes precedence over the parent
    /// it overlaps when both cover `now` — same rule as focus mode.
    var isInterrupt: Bool
    /// False when the phone cannot apply a direct end edit to this event (a
    /// recurring occurrence needs scope-aware editing; a running todo timer
    /// is stopped on the phone); the watch then hides Finish and +15 for it.
    var quickActionsEnabled: Bool
    /// A running phone-side timer: `end` is a placeholder far in the future
    /// and the watch shows no "until" time.
    var isOpenEnded: Bool

    init(
        id: String, eventID: UUID, title: String, type: String, colorHex: String,
        start: Date, end: Date, isInterrupt: Bool, quickActionsEnabled: Bool, isOpenEnded: Bool = false
    ) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.type = type
        self.colorHex = colorHex
        self.start = start
        self.end = end
        self.isInterrupt = isInterrupt
        self.quickActionsEnabled = quickActionsEnabled
        self.isOpenEnded = isOpenEnded
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventID, title, type, colorHex, start, end, isInterrupt, quickActionsEnabled, isOpenEnded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decode(UUID.self, forKey: .eventID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#8E8E93"
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        isInterrupt = try c.decodeIfPresent(Bool.self, forKey: .isInterrupt) ?? false
        quickActionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .quickActionsEnabled) ?? false
        isOpenEnded = try c.decodeIfPresent(Bool.self, forKey: .isOpenEnded) ?? false
    }
}

/// The phone's answer to one command, carried in the next snapshot so the
/// watch can drop the matching optimistic state.
nonisolated struct WristReceipt: Codable, Hashable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case applied
        case duplicate
        case rejected
    }

    /// The command's id.
    var id: UUID
    var outcome: Outcome
    var reason: String?
}

nonisolated struct WristSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var generatedAt: Date
    /// `AppLanguage` raw value ("en" / "zh"); nil lets the watch follow the
    /// device locale.
    var language: String?
    var types: [WristType]
    var occurrences: [WristOccurrence]
    var receipts: [WristReceipt]

    init(
        version: Int = WristSnapshot.currentVersion,
        generatedAt: Date,
        language: String? = nil,
        types: [WristType],
        occurrences: [WristOccurrence],
        receipts: [WristReceipt]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.language = language
        self.types = types
        self.occurrences = occurrences
        self.receipts = receipts
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, language, types, occurrences, receipts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        language = try container.decodeIfPresent(String.self, forKey: .language)
        types = try container.decodeIfPresent([WristType].self, forKey: .types) ?? []
        occurrences = try container.decodeIfPresent([WristOccurrence].self, forKey: .occurrences) ?? []
        receipts = try container.decodeIfPresent([WristReceipt].self, forKey: .receipts) ?? []
    }

    /// Equality that ignores `generatedAt` — what the phone uses to skip a
    /// push whose payload the watch already holds.
    func hasSameContent(as other: WristSnapshot) -> Bool {
        version == other.version
            && language == other.language
            && types == other.types
            && occurrences == other.occurrences
            && receipts == other.receipts
    }
}

/// A wrist action. `id` makes delivery idempotent (the phone keeps a ledger
/// of ids it has seen); the watch mints `eventID` for a start so a redelivered
/// start cannot create a second event even if that ledger is lost.
///
/// `rangeStart` names the time range of a multi-range event the user was
/// looking at — the phone edits that range, not range 0. Nil means "the
/// event's only range".
nonisolated struct WristCommand: Codable, Hashable, Identifiable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case start(eventID: UUID, typeTitle: String, start: Date, end: Date)
        case finish(eventID: UUID, rangeStart: Date?, at: Date)
        case extend(eventID: UUID, rangeStart: Date?, by: TimeInterval)
    }

    var id: UUID
    var issuedAt: Date
    var kind: Kind

    var eventID: UUID {
        switch kind {
        case .start(let eventID, _, _, _), .finish(let eventID, _, _), .extend(let eventID, _, _):
            return eventID
        }
    }

    var rangeStart: Date? {
        switch kind {
        case .start(_, _, let start, _): return start
        case .finish(_, let rangeStart, _), .extend(_, let rangeStart, _): return rangeStart
        }
    }
}
