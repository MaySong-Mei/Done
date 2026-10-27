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
    /// Phone clock, taken before the command was applied: every snapshot the
    /// phone generates from then on reflects it (a plain `Date` value).
    static let repliedAtKey = "wrist.repliedAt"

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
    /// What the phone's day timeline lays overlapping blocks out by
    /// (`WristOverlapLayout`): the event's creation time, which orders
    /// blocks that start together; the series an exception instance belongs
    /// to; and the event an interrupt is embedded in, whatever its kind.
    /// Nil from a phone before the fields: the blocks then order by id and
    /// no interrupt is drawn on a parent.
    var createdAt: Date?
    var seriesID: UUID?
    var interruptParentID: UUID?

    init(
        id: String, eventID: UUID, title: String, type: String, colorHex: String,
        start: Date, end: Date, isInterrupt: Bool, quickActionsEnabled: Bool, isOpenEnded: Bool = false,
        createdAt: Date? = nil, seriesID: UUID? = nil, interruptParentID: UUID? = nil
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
        self.createdAt = createdAt
        self.seriesID = seriesID
        self.interruptParentID = interruptParentID
    }

    /// The event a series' occurrences and its exception instances share.
    var anchorID: UUID { seriesID ?? eventID }

    private enum CodingKeys: String, CodingKey {
        case id, eventID, title, type, colorHex, start, end, isInterrupt, quickActionsEnabled, isOpenEnded
        case createdAt, seriesID, interruptParentID
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
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        seriesID = try? c.decodeIfPresent(UUID.self, forKey: .seriesID)
        interruptParentID = try? c.decodeIfPresent(UUID.self, forKey: .interruptParentID)
    }

    /// A false flag is left out — it decodes as false, here and on every
    /// watch before — so a busy day spends its bytes on what it has.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(title, forKey: .title)
        try c.encode(type, forKey: .type)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        if isInterrupt { try c.encode(isInterrupt, forKey: .isInterrupt) }
        if quickActionsEnabled { try c.encode(quickActionsEnabled, forKey: .quickActionsEnabled) }
        if isOpenEnded { try c.encode(isOpenEnded, forKey: .isOpenEnded) }
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(seriesID, forKey: .seriesID)
        try c.encodeIfPresent(interruptParentID, forKey: .interruptParentID)
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
    /// In the order of the phone's store — the order focus mode reads
    /// them in, so "the first in progress" means the same on both — each
    /// event's ranges by start. (A phone before that order sent them by
    /// start.)
    var occurrences: [WristOccurrence]
    var receipts: [WristReceipt]
    /// The phone's category-time payload — the one the "Time by Category"
    /// widget and the Analysis tab read — trimmed to the current week. The
    /// watch's stats page reads it with the widget's own arithmetic
    /// (`CategoryStats.summary`), cutting running slices at its own clock.
    var stats: CategoryStatsPayload?
    /// Settings → Apple Watch on the phone: what the stats page counts and
    /// opens on. Missing (a phone before the section) reads as `.standard`,
    /// the page as it always was.
    var statsSettings: WristStatsSettings
    /// Names the user gives each start-grid type, keyed by the type's title,
    /// for the watch to offer when naming a new block (`WristTitles.swift`).
    /// Empty from a phone before the field: the watch offers none.
    var titleHints: [String: [WristTitleHint]]
    /// The phone applies `WristCommand.Kind.statsSettings`. False from a
    /// phone before the kind: the watch shows those settings read-only.
    var takesSettingsEdits: Bool
    /// The phone's timeline motions and their styles, for the watch's page
    /// to play the same ones (`WristMotion.swift`). Off from a phone before
    /// the field.
    var motions: WristMotionSettings

    init(
        version: Int = WristSnapshot.currentVersion,
        generatedAt: Date,
        language: String? = nil,
        types: [WristType],
        occurrences: [WristOccurrence],
        receipts: [WristReceipt],
        stats: CategoryStatsPayload? = nil,
        statsSettings: WristStatsSettings = .standard,
        titleHints: [String: [WristTitleHint]] = [:],
        takesSettingsEdits: Bool = false,
        motions: WristMotionSettings = .off
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.language = language
        self.types = types
        self.occurrences = occurrences
        self.receipts = receipts
        self.stats = stats
        self.statsSettings = statsSettings
        self.titleHints = titleHints
        self.takesSettingsEdits = takesSettingsEdits
        self.motions = motions
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, language, types, occurrences, receipts, stats, statsSettings, titleHints
        case takesSettingsEdits, motions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        language = try container.decodeIfPresent(String.self, forKey: .language)
        types = try container.decodeIfPresent([WristType].self, forKey: .types) ?? []
        occurrences = try container.decodeIfPresent([WristOccurrence].self, forKey: .occurrences) ?? []
        receipts = try container.decodeIfPresent([WristReceipt].self, forKey: .receipts) ?? []
        stats = try? container.decodeIfPresent(CategoryStatsPayload.self, forKey: .stats)
        statsSettings = (try? container.decodeIfPresent(WristStatsSettings.self, forKey: .statsSettings))
            .flatMap { $0 } ?? .standard
        titleHints = (try? container.decodeIfPresent([String: [WristTitleHint]].self, forKey: .titleHints))
            .flatMap { $0 } ?? [:]
        takesSettingsEdits = (try? container.decodeIfPresent(Bool.self, forKey: .takesSettingsEdits))
            .flatMap { $0 } ?? false
        motions = (try? container.decodeIfPresent(WristMotionSettings.self, forKey: .motions))
            .flatMap { $0 } ?? .off
    }

    /// No hints, no key: a snapshot that drops them to fit is byte for byte
    /// the one a phone without them would send.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(types, forKey: .types)
        try container.encode(occurrences, forKey: .occurrences)
        try container.encode(receipts, forKey: .receipts)
        try container.encodeIfPresent(stats, forKey: .stats)
        try container.encode(statsSettings, forKey: .statsSettings)
        if !titleHints.isEmpty {
            try container.encode(titleHints, forKey: .titleHints)
        }
        if takesSettingsEdits {
            try container.encode(takesSettingsEdits, forKey: .takesSettingsEdits)
        }
        if motions != .off {
            try container.encode(motions, forKey: .motions)
        }
    }

    /// Equality that ignores `generatedAt` — what the phone uses to skip a
    /// push whose payload the watch already holds.
    func hasSameContent(as other: WristSnapshot) -> Bool {
        version == other.version
            && language == other.language
            && types == other.types
            && occurrences == other.occurrences
            && receipts == other.receipts
            && stats?.withoutWriteStamp == other.stats?.withoutWriteStamp
            && statsSettings == other.statsSettings
            && titleHints == other.titleHints
            && takesSettingsEdits == other.takesSettingsEdits
            && motions == other.motions
    }
}

/// A wrist action. `id` makes delivery idempotent (the phone keeps a ledger
/// of ids it has seen); the watch mints `eventID` for a start so a redelivered
/// start cannot create a second event even if that ledger is lost.
///
/// `rangeStart` names the time range of a multi-range event the user was
/// looking at — the phone edits that range, not range 0. Nil means "the
/// event's only range".
///
/// A start's `title` is a name picked on the watch; nil names the event
/// after its type. It is optional so a phone that predates it still decodes
/// the start (an unknown key is ignored) and stores the type as the title,
/// and a start queued by an older watch still decodes here.
///
/// `statsSettings` is an edit made on the watch's settings page to the
/// phone-owned part of `WristStatsSettings`: each field it carries replaces
/// the phone's, a nil field is left alone. A phone that predates the kind
/// cannot decode the command at all and drops it (the reply is empty, the
/// transfer is discarded); the watch only offers the edit when the snapshot
/// says the phone takes it (`WristSnapshot.takesSettingsEdits`).
nonisolated struct WristCommand: Codable, Hashable, Identifiable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case start(eventID: UUID, typeTitle: String, start: Date, end: Date, title: String? = nil)
        case finish(eventID: UUID, rangeStart: Date?, at: Date)
        case extend(eventID: UUID, rangeStart: Date?, by: TimeInterval)
        case statsSettings(overlap: WristOverlapRule? = nil, excludesBackground: Bool? = nil)
    }

    var id: UUID
    var issuedAt: Date
    var kind: Kind

    /// The event the command is about. A settings edit is about no event:
    /// its own id, so it never waits behind, or holds up, an event's
    /// commands.
    var eventID: UUID {
        switch kind {
        case .start(let eventID, _, _, _, _), .finish(let eventID, _, _), .extend(let eventID, _, _):
            return eventID
        case .statsSettings:
            return id
        }
    }

    /// The title a start stores: the picked name, else the type.
    static func storedTitle(typeTitle: String, title: String?) -> String {
        let picked = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return picked.isEmpty ? typeTitle.trimmingCharacters(in: .whitespacesAndNewlines) : picked
    }

    var rangeStart: Date? {
        switch kind {
        case .start(_, _, let start, _, _): return start
        case .finish(_, let rangeStart, _), .extend(_, let rangeStart, _): return rangeStart
        case .statsSettings: return nil
        }
    }
}
