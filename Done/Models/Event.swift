//
//  Event.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation

enum AgenticCreateSource: String, Codable, Hashable {
    case quickAdd
    case dragCreate
    case classicFallback
}

enum AgenticIntakeProcessingPhase: String, Codable, Hashable {
    case queued
    case analyzing
    case completed
    case failed
}

enum SuggestedLogTemplateSource: String, Codable, Hashable {
    case agent
    case heuristic
    case manualFallback
}

enum EventDisplayKind: String, Codable, Hashable {
    case regular
    case interrupt
}

enum EventInterruptRelationState: String, Codable, Hashable {
    case embedded
    case detached
    case orphaned
}

struct EventInterruptRelation: Codable, Hashable {
    var parentEventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var state: EventInterruptRelationState
    var createdAt: Date

    init(
        parentEventID: UUID,
        baseSeriesEventID: UUID? = nil,
        occurrenceDate: Date,
        state: EventInterruptRelationState = .embedded,
        createdAt: Date = Date()
    ) {
        self.parentEventID = parentEventID
        self.baseSeriesEventID = baseSeriesEventID
        self.occurrenceDate = occurrenceDate
        self.state = state
        self.createdAt = createdAt
    }
}

struct AgenticIntakeImageRef: Codable, Hashable, Identifiable {
    var id: UUID
    var relativePath: String
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSizeBytes: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        relativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
    }
}

struct AgenticProviderMetadata: Codable, Hashable {
    var provider: String
    var model: String?
    var usedVision: Bool
    var createdAt: Date

    init(
        provider: String,
        model: String? = nil,
        usedVision: Bool,
        createdAt: Date = Date()
    ) {
        self.provider = provider
        self.model = model
        self.usedVision = usedVision
        self.createdAt = createdAt
    }
}

struct AgenticIntakeRecord: Codable, Hashable {
    var rawText: String
    var images: [AgenticIntakeImageRef]
    var source: AgenticCreateSource
    var providerMetadata: AgenticProviderMetadata?
    var warnings: [String]
    var createdAt: Date
    var processingPhase: AgenticIntakeProcessingPhase
    var processingUpdatedAt: Date
    var failureMessage: String?

    private enum CodingKeys: String, CodingKey {
        case rawText
        case images
        case source
        case providerMetadata
        case warnings
        case createdAt
        case processingPhase
        case processingUpdatedAt
        case failureMessage
    }

    init(
        rawText: String,
        images: [AgenticIntakeImageRef] = [],
        source: AgenticCreateSource,
        providerMetadata: AgenticProviderMetadata? = nil,
        warnings: [String] = [],
        createdAt: Date = Date(),
        processingPhase: AgenticIntakeProcessingPhase = .completed,
        processingUpdatedAt: Date? = nil,
        failureMessage: String? = nil
    ) {
        self.rawText = rawText
        self.images = images
        self.source = source
        self.providerMetadata = providerMetadata
        self.warnings = warnings
        self.createdAt = createdAt
        self.processingPhase = processingPhase
        self.processingUpdatedAt = processingUpdatedAt ?? createdAt
        self.failureMessage = failureMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawText = try container.decode(String.self, forKey: .rawText)
        images = try container.decodeIfPresent([AgenticIntakeImageRef].self, forKey: .images) ?? []
        source = try container.decode(AgenticCreateSource.self, forKey: .source)
        providerMetadata = try container.decodeIfPresent(AgenticProviderMetadata.self, forKey: .providerMetadata)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        processingPhase = try container.decodeIfPresent(AgenticIntakeProcessingPhase.self, forKey: .processingPhase) ?? .completed
        processingUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .processingUpdatedAt) ?? createdAt
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(images, forKey: .images)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(processingPhase, forKey: .processingPhase)
        try container.encode(processingUpdatedAt, forKey: .processingUpdatedAt)
        try container.encodeIfPresent(failureMessage, forKey: .failureMessage)
    }
}

struct Event: Identifiable, Codable, Hashable {
    struct TimeRange: Codable, Hashable {
        var start: Date
        var end: Date
    }
    enum RepeatUnit: String, Codable, Hashable {
        case none
        case day
        case week
        case month
        case year
    }

    enum RepeatEndType: String, Codable, Hashable {
        case none
        case onDate
        case afterCount
    }

    enum Status: String, Codable, Hashable {
        case active
        case completed
        case archived
    }

    /// Behavioral discriminator within Event's unified data shape.
    ///
    /// - `.event`: scheduled commitment (default; legacy events decode as this).
    ///             Time is meaningful; missing the time becomes history.
    /// - `.todo`:  intent without commitment to a specific moment. Completion
    ///             is explicit (user marks done); date is still owned by user.
    ///             See `calendar-todo-unification` and `calendar-design-bedrock`.
    enum Kind: String, Codable, Hashable, CaseIterable {
        case event
        case todo
    }

    struct WannaNote: Codable, Hashable, Identifiable {
        var id: UUID
        var text: String
        var createdAt: Date

        init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    enum RecurrenceEditScope {
        case single
        case following
        case all
    }

    struct RecurrenceEditResult {
        var updatedSeries: Event?
        var newSeries: Event?
        var exceptionInstance: Event?
    }

    var id: UUID
    var title: String
    var note: String
    var location: String
    var timeRanges: [TimeRange] = []
    var deadline: Date?
    var repeatUnit: RepeatUnit
    var isAllDay: Bool
    var isDone: Bool
    var repeatInterval: Int
    var repeatEndType: RepeatEndType
    var repeatEndDate: Date?
    var repeatEndCount: Int?
    var priority: Int
    var status: Status
    var createdAt: Date
    var completeAt: Date?
    var tags: [String]
    var type: String
    /// Behavioral kind — `.event` is the legacy default; `.todo` opts into
    /// the explicit-completion / soft-time behavior of the calendar/todo
    /// unification design. Existing data decodes as `.event`.
    var kind: Kind = .event
    /// Optional additional event types for the experimental multi-type
    /// feature. The primary type lives in `type`; this collection holds any
    /// extra types layered on top so that single-type call sites stay
    /// untouched. `nil` means "no extras".
    var additionalTypes: [String]?
    /// Optional weight per type for the experimental multi-type feature.
    /// Keys are type names (matching `type` and entries in `additionalTypes`),
    /// values are unnormalized weights ≥ 0. nil means "split equally" between
    /// the types in `effectiveTypes`. Reads should always go through
    /// `effectiveTypeWeights` which handles missing entries, fallback, and
    /// renormalization.
    var typeWeights: [String: Double]?
    var colorDepth: Double
    var recurrenceParentId: UUID?
    var recurrenceInstanceDate: Date?
    /// Time-zone-stable day identity of a detached exception instance: the
    /// `YYYYMMDD` key of the occurrence day this instance REPLACES — the same
    /// key its parent series holds in `recurrenceExceptionDayKeys` for that
    /// day. `recurrenceInstanceDate` (the legacy pointer, a creation-frame
    /// midnight) stays untouched as the rollback mirror; classification —
    /// `.following` re-parenting, delete sweeps, detail resolution — compares
    /// this key, because reinterpreting the mirror through the CURRENT
    /// calendar drifts a day after travel and then disagrees with the
    /// exception-key carry inside the very same split (gh#127 item 1
    /// follow-up).
    var recurrenceInstanceDayKey: Int?
    /// Legacy exception representation: absolute midnight `Date`s minted with
    /// whatever `Calendar.current` was at write time. NOT identity anymore —
    /// suppression reads `recurrenceExceptionDayKeys`. Still written on every
    /// encode as the rollback net (pre-migration builds decode and suppress
    /// from this field alone), and still appended in step with the day keys.
    /// Never rewritten, never dropped.
    var recurrenceExceptionDates: [Date]
    /// Time-zone-stable exception identity: one `YYYYMMDD` integer per
    /// suppressed occurrence day (same wire shape as
    /// `CalendarOccurrenceKey.dayKey`). Minted from the nominal calendar day
    /// the user acted on, in the calendar that named it — so a later system
    /// time-zone change cannot re-bucket the exception into an adjacent day
    /// (gh#127 item 1: the suppressed day reappeared next to its detached
    /// replacement after travel). Maintained in step with
    /// `recurrenceExceptionDates`; all writers go through
    /// `appendRecurrenceException(onDay:calendar:)`.
    var recurrenceExceptionDayKeys: [Int]
    var timerStartedAt: Date?
    var linkedCalendarEventId: UUID?
    var linkedTodoEventId: UUID?
    var listID: UUID?
    var agenticIntake: AgenticIntakeRecord?
    var suggestedLogTemplateID: String?
    var suggestedLogTemplateConfidence: Double?
    var suggestedLogTemplateUpdatedAt: Date?
    var suggestedLogTemplateSource: SuggestedLogTemplateSource?
    var displayKind: EventDisplayKind
    var interruptRelation: EventInterruptRelation?
    /// When set on a `.todo`, this todo has been absorbed into the
    /// event with this id and no longer renders independently on the
    /// canvas — it appears as a subitem inside that parent event's
    /// detail. Closes the user-logic loop: done todo doesn't linger as
    /// an orphan, it becomes part of the event it belonged to.
    /// `.event` items don't set this (assertion-level, not enforced at
    /// type level for now).
    var absorbedIntoEventID: UUID?
    var wannaNotes: [WannaNote]?
    /// People bound to this event — the answer to "with whom". Holds `Person`
    /// ids. When the user picks a friend group, that group's members are
    /// expanded into this list at bind time (the group itself is not stored),
    /// so later edits to the group never rewrite this event's history. `nil`
    /// means "no one bound" (legacy data decodes as `nil`).
    var peopleIDs: [UUID]?

    var isTimerActive: Bool {
        timerStartedAt != nil
    }

    /// All event types associated with this event, primary first. Always
    /// returns at least one entry (the primary `type`). Used by the
    /// experimental multi-type events feature; ordinary call sites can keep
    /// reading `type` directly.
    var effectiveTypes: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let primary = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            seen.insert(primary)
            result.append(primary)
        }
        for extra in additionalTypes ?? [] {
            let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        if result.isEmpty {
            result.append(type)
        }
        return result
    }

    /// Append `name` as a non-primary additional type. No-op if `name` is
    /// blank or already present (case/whitespace-insensitive). Does not
    /// touch `typeWeights` — `effectiveTypeWeights` will fall back to equal
    /// split until something else writes weights.
    mutating func appendAdditionalType(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let alreadyPresent = effectiveTypes.contains { existing in
            existing.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !alreadyPresent else { return }
        var extras = additionalTypes ?? []
        extras.append(trimmed)
        additionalTypes = extras
    }

    /// Remove `name` from the type list. If `name` is the primary, the
    /// first remaining additional type is promoted. No-op if removing
    /// `name` would leave the event without any type. Prunes the matching
    /// `typeWeights` entry but does not renormalize — `effectiveTypeWeights`
    /// renormalizes on read.
    mutating func removeType(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isPrimary = type.caseInsensitiveCompare(trimmed) == .orderedSame
        var extras = additionalTypes ?? []

        if isPrimary {
            guard !extras.isEmpty else { return }
            type = extras.removeFirst()
        } else {
            let before = extras.count
            extras.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            guard extras.count != before else { return }
        }
        additionalTypes = extras.isEmpty ? nil : extras

        if var weights = typeWeights {
            for key in weights.keys
            where key.caseInsensitiveCompare(trimmed) == .orderedSame {
                weights.removeValue(forKey: key)
            }
            typeWeights = weights.isEmpty ? nil : weights
        }
    }

    /// Move `name` to the front of the type list, making it the primary.
    /// No-op if `name` is already primary or not present in the type list.
    /// `typeWeights` keys are unchanged because they're keyed by name.
    mutating func promoteTypeToPrimary(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              type.caseInsensitiveCompare(trimmed) != .orderedSame else { return }
        var extras = additionalTypes ?? []
        guard let idx = extras.firstIndex(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return }
        let promoted = extras.remove(at: idx)
        let oldPrimary = type
        type = promoted
        extras.insert(oldPrimary, at: 0)
        additionalTypes = extras
    }

    var isInterrupt: Bool {
        displayKind == .interrupt
    }

    // Explicit CodingKeys — includes legacy grid fields so old data can still decode
    private enum CodingKeys: String, CodingKey {
        case id, title, note, location, startTime, endTime, timeRanges, deadline
        case repeatUnit, isAllDay, isDone, repeatInterval
        case repeatEndType, repeatEndDate, repeatEndCount
        case gridWidth, gridHeight, gridOrder, gridX, gridY // legacy, ignored
        case priority, status, createdAt, completeAt, tags, type, additionalTypes, typeWeights, colorDepth
        case recurrenceParentId, recurrenceInstanceDate, recurrenceExceptionDates
        case recurrenceExceptionDayKeys
        case recurrenceInstanceDayKey
        case timerStartedAt, linkedCalendarEventId, linkedTodoEventId, listID
        case agenticIntake
        case suggestedLogTemplateID, suggestedLogTemplateConfidence, suggestedLogTemplateUpdatedAt, suggestedLogTemplateSource
        case displayKind, interruptRelation, wannaNotes
        case kind
        case absorbedIntoEventID
        case peopleIDs
    }

    // Custom Decodable init for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decode(String.self, forKey: .note)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        let decodedRanges = try container.decodeIfPresent([TimeRange].self, forKey: .timeRanges) ?? []
        if decodedRanges.isEmpty,
           let legacyStart = try container.decodeIfPresent(Date.self, forKey: .startTime),
           let legacyEnd = try container.decodeIfPresent(Date.self, forKey: .endTime) {
            timeRanges = [TimeRange(start: legacyStart, end: legacyEnd)]
        } else {
            timeRanges = decodedRanges
        }
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        repeatUnit = try container.decode(RepeatUnit.self, forKey: .repeatUnit)
        isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        isDone = try container.decode(Bool.self, forKey: .isDone)
        repeatInterval = try container.decode(Int.self, forKey: .repeatInterval)
        repeatEndType = try container.decode(RepeatEndType.self, forKey: .repeatEndType)
        repeatEndDate = try container.decodeIfPresent(Date.self, forKey: .repeatEndDate)
        repeatEndCount = try container.decodeIfPresent(Int.self, forKey: .repeatEndCount)
        // Legacy grid fields — skip during decoding (old data may contain them)
        priority = try container.decode(Int.self, forKey: .priority)
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completeAt = try container.decodeIfPresent(Date.self, forKey: .completeAt)
        tags = try container.decode([String].self, forKey: .tags)
        type = try container.decode(String.self, forKey: .type)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .event
        additionalTypes = try container.decodeIfPresent([String].self, forKey: .additionalTypes)
        typeWeights = try container.decodeIfPresent([String: Double].self, forKey: .typeWeights)
        colorDepth = try container.decode(Double.self, forKey: .colorDepth)
        recurrenceParentId = try container.decodeIfPresent(UUID.self, forKey: .recurrenceParentId)
        recurrenceInstanceDate = try container.decodeIfPresent(Date.self, forKey: .recurrenceInstanceDate)
        recurrenceInstanceDayKey = Event.resolvedRecurrenceInstanceDayKey(
            dayKey: try container.decodeIfPresent(Int.self, forKey: .recurrenceInstanceDayKey),
            legacyDate: recurrenceInstanceDate
        )
        recurrenceExceptionDates = try container.decodeIfPresent([Date].self, forKey: .recurrenceExceptionDates) ?? []
        // Ingress seam 1 of 2 (see SupabaseSyncService+Restore for the other):
        // the day-key identity materializes lazily, per event, as it decodes —
        // no eager launch-time rewrite of every stored blob. The one
        // precedence rule lives in `resolvedRecurrenceExceptionDayKeys`.
        recurrenceExceptionDayKeys = Event.resolvedRecurrenceExceptionDayKeys(
            dayKeys: try container.decodeIfPresent([Int].self, forKey: .recurrenceExceptionDayKeys),
            legacyDates: recurrenceExceptionDates
        )
        timerStartedAt = try container.decodeIfPresent(Date.self, forKey: .timerStartedAt)
        linkedCalendarEventId = try container.decodeIfPresent(UUID.self, forKey: .linkedCalendarEventId)
        linkedTodoEventId = try container.decodeIfPresent(UUID.self, forKey: .linkedTodoEventId)
        listID = try container.decodeIfPresent(UUID.self, forKey: .listID)
        agenticIntake = try container.decodeIfPresent(AgenticIntakeRecord.self, forKey: .agenticIntake)
        suggestedLogTemplateID = try container.decodeIfPresent(String.self, forKey: .suggestedLogTemplateID)
        suggestedLogTemplateConfidence = try container.decodeIfPresent(Double.self, forKey: .suggestedLogTemplateConfidence)
        suggestedLogTemplateUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .suggestedLogTemplateUpdatedAt)
        suggestedLogTemplateSource = try container.decodeIfPresent(SuggestedLogTemplateSource.self, forKey: .suggestedLogTemplateSource)
        displayKind = try container.decodeIfPresent(EventDisplayKind.self, forKey: .displayKind) ?? .regular
        interruptRelation = try container.decodeIfPresent(EventInterruptRelation.self, forKey: .interruptRelation)
        absorbedIntoEventID = try container.decodeIfPresent(UUID.self, forKey: .absorbedIntoEventID)
        wannaNotes = try container.decodeIfPresent([WannaNote].self, forKey: .wannaNotes)
        peopleIDs = try container.decodeIfPresent([UUID].self, forKey: .peopleIDs)

        // Repair a value-less / degenerate recurrence rule at ingress so a
        // corrupt record (e.g. `.afterCount` with a null count) can't render
        // forever or erase its seed. Fails closed to the seed — see
        // `normalizedRecurrenceRule`.
        let normalizedRule = Event.normalizedRecurrenceRule(
            interval: repeatInterval,
            endType: repeatEndType,
            endDate: repeatEndDate,
            endCount: repeatEndCount,
            seriesStart: timeRanges.first?.start
        )
        repeatInterval = normalizedRule.interval
        repeatEndType = normalizedRule.endType
        repeatEndDate = normalizedRule.endDate
        repeatEndCount = normalizedRule.endCount
    }

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        location: String = "",
        timeRanges: [TimeRange] = [],
        deadline: Date? = nil,
        repeatUnit: RepeatUnit = .none,
        isAllDay: Bool = false,
        isDone: Bool = false,
        repeatInterval: Int = 1,
        repeatEndType: RepeatEndType = .none,
        repeatEndDate: Date? = nil,
        repeatEndCount: Int? = nil,
        priority: Int = 0,
        status: Status = .active,
        createdAt: Date = Date(),
        completeAt: Date? = nil,
        tags: [String] = [],
        type: String = "",
        kind: Kind = .event,
        additionalTypes: [String]? = nil,
        typeWeights: [String: Double]? = nil,
        colorDepth: Double = 0.0,
        recurrenceParentId: UUID? = nil,
        recurrenceInstanceDate: Date? = nil,
        recurrenceInstanceDayKey: Int? = nil,
        recurrenceExceptionDates: [Date] = [],
        recurrenceExceptionDayKeys: [Int]? = nil,
        timerStartedAt: Date? = nil,
        linkedCalendarEventId: UUID? = nil,
        linkedTodoEventId: UUID? = nil,
        listID: UUID? = nil,
        agenticIntake: AgenticIntakeRecord? = nil,
        suggestedLogTemplateID: String? = nil,
        suggestedLogTemplateConfidence: Double? = nil,
        suggestedLogTemplateUpdatedAt: Date? = nil,
        suggestedLogTemplateSource: SuggestedLogTemplateSource? = nil,
        displayKind: EventDisplayKind = .regular,
        interruptRelation: EventInterruptRelation? = nil,
        absorbedIntoEventID: UUID? = nil,
        wannaNotes: [WannaNote]? = nil,
        peopleIDs: [UUID]? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.location = location
        self.timeRanges = timeRanges
        self.deadline = deadline
        self.repeatUnit = repeatUnit
        self.isAllDay = isAllDay
        self.isDone = isDone
        self.repeatInterval = repeatInterval
        self.repeatEndType = repeatEndType
        self.repeatEndDate = repeatEndDate
        self.repeatEndCount = repeatEndCount
        self.priority = priority
        self.status = status
        self.createdAt = createdAt
        self.completeAt = completeAt
        self.tags = tags
        self.type = type
        self.kind = kind
        self.additionalTypes = additionalTypes
        self.typeWeights = typeWeights
        self.colorDepth = colorDepth
        self.recurrenceParentId = recurrenceParentId
        self.recurrenceInstanceDate = recurrenceInstanceDate
        self.recurrenceInstanceDayKey = Event.resolvedRecurrenceInstanceDayKey(
            dayKey: recurrenceInstanceDayKey,
            legacyDate: recurrenceInstanceDate
        )
        self.recurrenceExceptionDates = recurrenceExceptionDates
        // Ingress seam 2: memberwise construction (Supabase restore, tests,
        // fixtures). `nil` means "no day keys supplied" and routes through the
        // SAME single precedence rule as decode, so a caller that only has
        // legacy dates gets a lazily backfilled identity — never a mass
        // rewrite, never a second rule.
        self.recurrenceExceptionDayKeys = Event.resolvedRecurrenceExceptionDayKeys(
            dayKeys: recurrenceExceptionDayKeys,
            legacyDates: recurrenceExceptionDates
        )
        self.timerStartedAt = timerStartedAt
        self.linkedCalendarEventId = linkedCalendarEventId
        self.linkedTodoEventId = linkedTodoEventId
        self.listID = listID
        self.agenticIntake = agenticIntake
        self.suggestedLogTemplateID = suggestedLogTemplateID
        self.suggestedLogTemplateConfidence = suggestedLogTemplateConfidence
        self.suggestedLogTemplateUpdatedAt = suggestedLogTemplateUpdatedAt
        self.suggestedLogTemplateSource = suggestedLogTemplateSource
        self.displayKind = displayKind
        self.interruptRelation = interruptRelation
        self.absorbedIntoEventID = absorbedIntoEventID
        self.wannaNotes = wannaNotes
        self.peopleIDs = peopleIDs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(note, forKey: .note)
        try container.encode(location, forKey: .location)
        try container.encode(timeRanges, forKey: .timeRanges)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encode(repeatUnit, forKey: .repeatUnit)
        try container.encode(isAllDay, forKey: .isAllDay)
        try container.encode(isDone, forKey: .isDone)
        try container.encode(repeatInterval, forKey: .repeatInterval)
        try container.encode(repeatEndType, forKey: .repeatEndType)
        try container.encodeIfPresent(repeatEndDate, forKey: .repeatEndDate)
        try container.encodeIfPresent(repeatEndCount, forKey: .repeatEndCount)
        // grid fields intentionally omitted
        try container.encode(priority, forKey: .priority)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completeAt, forKey: .completeAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(type, forKey: .type)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(additionalTypes, forKey: .additionalTypes)
        try container.encodeIfPresent(typeWeights, forKey: .typeWeights)
        try container.encode(colorDepth, forKey: .colorDepth)
        try container.encodeIfPresent(recurrenceParentId, forKey: .recurrenceParentId)
        try container.encodeIfPresent(recurrenceInstanceDate, forKey: .recurrenceInstanceDate)
        try container.encodeIfPresent(recurrenceInstanceDayKey, forKey: .recurrenceInstanceDayKey)
        // Write-both: the legacy absolute dates stay on disk as the rollback
        // net (a pre-migration build decodes them and suppresses as before —
        // to it the day-key field is just an unknown key), the day keys are
        // the identity every reader on this build uses.
        try container.encode(recurrenceExceptionDates, forKey: .recurrenceExceptionDates)
        try container.encode(recurrenceExceptionDayKeys, forKey: .recurrenceExceptionDayKeys)
        try container.encodeIfPresent(timerStartedAt, forKey: .timerStartedAt)
        try container.encodeIfPresent(linkedCalendarEventId, forKey: .linkedCalendarEventId)
        try container.encodeIfPresent(linkedTodoEventId, forKey: .linkedTodoEventId)
        try container.encodeIfPresent(listID, forKey: .listID)
        try container.encodeIfPresent(agenticIntake, forKey: .agenticIntake)
        try container.encodeIfPresent(suggestedLogTemplateID, forKey: .suggestedLogTemplateID)
        try container.encodeIfPresent(suggestedLogTemplateConfidence, forKey: .suggestedLogTemplateConfidence)
        try container.encodeIfPresent(suggestedLogTemplateUpdatedAt, forKey: .suggestedLogTemplateUpdatedAt)
        try container.encodeIfPresent(suggestedLogTemplateSource, forKey: .suggestedLogTemplateSource)
        try container.encode(displayKind, forKey: .displayKind)
        try container.encodeIfPresent(interruptRelation, forKey: .interruptRelation)
        try container.encodeIfPresent(absorbedIntoEventID, forKey: .absorbedIntoEventID)
        try container.encodeIfPresent(wannaNotes, forKey: .wannaNotes)
        try container.encodeIfPresent(peopleIDs, forKey: .peopleIDs)
    }

    /// `nonisolated` (gh#150 review): the zombie predicates
    /// (`zombieRecurrenceSignatureDayGap` and friends) are declared
    /// `nonisolated` so the sweep, its tests, and any future reporting
    /// surface share one predicate — but under the project's default
    /// MainActor isolation a computed property is MainActor unless it says
    /// otherwise, which made that contract a diagnostic today and a compile
    /// error under the Swift 6 language mode. Stored-property reads are
    /// nonisolated within the module (SE-0434); this and `primaryTimeRange`
    /// only reduce stored fields, so marking them makes the contract real.
    nonisolated var isRecurringSeries: Bool {
        repeatUnit != .none && recurrenceParentId == nil && recurrenceInstanceDate == nil
    }

    var isExceptionInstance: Bool {
        recurrenceParentId != nil && recurrenceInstanceDate != nil
    }

    var duration: TimeInterval {
        guard let range = primaryTimeRange else {
            return 0
        }
        return range.end.timeIntervalSince(range.start)
    }

    /// Duration breakdown for an occurrence that may contain embedded
    /// interrupt children.
    ///
    /// - `full`: the scheduled length of the parent occurrence (what the user
    ///   booked). Always surfaced so the calendar stays truthful about the
    ///   slot it reserved.
    /// - `interrupt`: time consumed by embedded interrupts, after clamping each
    ///   child to the parent range and merging overlapping children so two
    ///   overlapping interrupts are never subtracted twice.
    /// - `net`: active time the parent actually ran = full − interrupt
    ///   (clamped to ≥ 0). This is the "active" figure shown beside the
    ///   scheduled one and the default we feed downstream (logs, analysis,
    ///   token inference) — see `Event.interruptedDuration(parentRange:childRanges:)`.
    struct InterruptedDuration: Equatable {
        var fullSeconds: TimeInterval
        var interruptSeconds: TimeInterval

        var netSeconds: TimeInterval { max(0, fullSeconds - interruptSeconds) }
        var hasInterrupts: Bool { interruptSeconds > 0 }

        var fullMinutes: Int { Int((fullSeconds / 60).rounded()) }
        var interruptMinutes: Int { Int((interruptSeconds / 60).rounded()) }
        /// Rounded from `netSeconds` (not `fullMinutes − interruptMinutes`) so
        /// the figure tracks the real remaining wall-clock; the two can differ
        /// by a minute when both sides round.
        var netMinutes: Int { Int((netSeconds / 60).rounded()) }
    }

    /// Computes full / interrupt / net duration for a parent occurrence.
    /// Each child is clamped to `parentRange`, the clamped ranges are merged
    /// (overlaps unioned), and the merged total is the subtracted interrupt
    /// time. Children that don't overlap the parent (a live interrupt that
    /// outlasted its parent, or one nudged out of range by an edit) clamp to
    /// nothing and subtract nothing.
    static func interruptedDuration(
        parentRange: TimeRange,
        childRanges: [TimeRange]
    ) -> InterruptedDuration {
        let fullSeconds = max(0, parentRange.end.timeIntervalSince(parentRange.start))

        let clamped: [TimeRange] = childRanges.compactMap { child in
            let start = max(child.start, parentRange.start)
            let end = min(child.end, parentRange.end)
            return end > start ? TimeRange(start: start, end: end) : nil
        }

        // Merge overlapping/touching ranges so overlapping interrupts subtract
        // once, not twice.
        let merged = clamped
            .sorted { $0.start < $1.start }
            .reduce(into: [TimeRange]()) { acc, range in
                if var last = acc.last, range.start <= last.end {
                    if range.end > last.end {
                        last.end = range.end
                        acc[acc.count - 1] = last
                    }
                } else {
                    acc.append(range)
                }
            }

        let interruptSeconds = merged.reduce(0.0) {
            $0 + $1.end.timeIntervalSince($1.start)
        }
        return InterruptedDuration(fullSeconds: fullSeconds, interruptSeconds: interruptSeconds)
    }

    /// Clamps `range` to `[windowStart, windowEnd)`, subtracts the (merged)
    /// `excluding` ranges, and returns the remaining sub-intervals.
    ///
    /// This is the interval-shaped counterpart to `interruptedDuration` (which
    /// only returns a net figure): the overlap-sharing sweep needs the actual
    /// geometry left after an occurrence's embedded interrupt children are cut
    /// out. Exclusions are merged first so an overlapping pair isn't
    /// subtracted twice — the same rule `interruptedDuration` applies.
    static func remainingIntervals(
        _ range: TimeRange,
        excluding: [TimeRange],
        windowStart: Date,
        windowEnd: Date
    ) -> [TimeRange] {
        let start = max(range.start, windowStart)
        let end = min(range.end, windowEnd)
        guard end > start else { return [] }

        let clamped = excluding
            .compactMap { exclusion -> TimeRange? in
                let s = max(exclusion.start, start)
                let e = min(exclusion.end, end)
                return e > s ? TimeRange(start: s, end: e) : nil
            }
            .sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for exclusion in clamped {
            if let last = merged.last, exclusion.start <= last.end {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, exclusion.end))
            } else {
                merged.append(exclusion)
            }
        }

        var remaining: [TimeRange] = []
        var cursor = start
        for exclusion in merged {
            if exclusion.start > cursor {
                remaining.append(TimeRange(start: cursor, end: exclusion.start))
            }
            cursor = max(cursor, exclusion.end)
        }
        if cursor < end {
            remaining.append(TimeRange(start: cursor, end: end))
        }
        return remaining
    }

    /// Splits wall-clock time evenly among overlapping contributions: a window
    /// covered by n of them credits each 1/n, so the summed result equals the
    /// union coverage instead of over-counting parallel occurrences.
    ///
    /// Input is one interval list per contribution (already netted/clamped,
    /// e.g. via `remainingIntervals`); the result is hours per contribution,
    /// index-aligned with the input. Both the Analysis charts and the report
    /// stats run their hour totals through this single sweep so the two can
    /// never disagree about the same window (#116).
    static func overlapSharedHours(contributions: [[TimeRange]]) -> [Double] {
        var shared = Array(repeating: 0.0, count: contributions.count)
        var boundaries: Set<Date> = []
        for intervals in contributions {
            for interval in intervals {
                boundaries.insert(interval.start)
                boundaries.insert(interval.end)
            }
        }

        // Sweep the elementary slices between consecutive boundaries; each
        // slice's wall-clock hours are split evenly among the contributions
        // covering it. Every interval endpoint is a boundary, so a slice is
        // either fully inside or fully outside any given interval.
        let sortedBoundaries = boundaries.sorted()
        guard sortedBoundaries.count > 1 else { return shared }
        for index in 0..<(sortedBoundaries.count - 1) {
            let sliceStart = sortedBoundaries[index]
            let sliceEnd = sortedBoundaries[index + 1]
            let covering = contributions.indices.filter { i in
                contributions[i].contains { $0.start <= sliceStart && sliceEnd <= $0.end }
            }
            guard !covering.isEmpty else { continue }
            let sliceHours = sliceEnd.timeIntervalSince(sliceStart) / 3600 / Double(covering.count)
            for i in covering {
                shared[i] += sliceHours
            }
        }
        return shared
    }

    /// Elapsed-clamp cut for a stats window observed at `asOf`: the instant up
    /// to which the window's occurrences count as *spent* time.  Result is
    /// `asOf` clamped into `[windowStart, windowEnd]` — a window that hasn't
    /// started yet cuts to its own start (nothing elapsed → zero hours), a
    /// finished window cuts to its end (fully counted).
    ///
    /// Single source of truth for the elapsed-clamp rule (#111 hard
    /// precondition, applied to the Me page by #121): the Me-page hour
    /// aggregations (`AnalysisViewModel`) and the report clue battery
    /// (`ReportClueBuilder`) both derive their partial-window accounting from
    /// this one function, so the two surfaces can't drift the way the
    /// overlap-sharing fix once did (#116).
    static func elapsedWindowCut(windowStart: Date, windowEnd: Date, asOf: Date) -> Date {
        min(max(asOf, windowStart), windowEnd)
    }

    var effectiveTimeRanges: [TimeRange] {
        timeRanges
    }

    /// `nonisolated` for the same reason as `isRecurringSeries` — the
    /// off-main zombie predicates read it, and a pure reduction of a stored
    /// field has no business being actor-isolated.
    nonisolated var primaryTimeRange: TimeRange? {
        timeRanges.first
    }

    /// Renders as an independent block on the timeline canvas. Absorbed todos
    /// (`absorbedIntoEventID != nil`) live as subitems inside their parent
    /// event's detail view and have no block of their own. Single source of
    /// truth for the canvas-render filter: `EventStore.canvasRenderableCalendarEvents`
    /// and `WidgetSnapshotBuilder.snapshots` must never disagree on membership —
    /// the widget mirrors the canvas, so a clause added here has to reach both.
    /// (gh#142 was precisely a consumer that missed this filter.)
    var isCanvasRenderable: Bool {
        absorbedIntoEventID == nil
    }

    /// A "stack todo" — a want captured without a time, living in the Todo
    /// stack drawer: dateless, unabsorbed, not done. Single source of truth
    /// for the stack predicate; the drawer (`EventStore.datelessTodos`) and
    /// the report stagnation line must never disagree on membership.
    var isStackTodo: Bool {
        kind == .todo
            && timeRanges.isEmpty
            && !isDone
            && absorbedIntoEventID == nil
    }

    /// A scheduled todo that can be returned to the Todo stack (the inverse
    /// of the drag-out slice): drop its time and it becomes an `isStackTodo`
    /// again. Single source of truth for the put-back gate — the detail
    /// page's "Put back to Todo" section, the canvas drag put-back peek,
    /// and `EventStore.putTodoBackToStack` must never disagree. Recurring
    /// shapes are excluded: a series' seed ranges are its identity, not a
    /// schedule the stack can absorb.
    var canReturnToStack: Bool {
        kind == .todo
            && !timeRanges.isEmpty
            && !isDone
            && absorbedIntoEventID == nil
            && !isRecurringSeries
            && recurrenceParentId == nil
    }

    /// Repairs a decomposed recurrence rule that decoded/reconstructed into a
    /// VALUE-LESS state, failing CLOSED so the seed occurrence is preserved and
    /// never rendered forever. A typed end (`.afterCount` / `.onDate`) carrying
    /// a nil bound would otherwise render on every pattern day forever (the
    /// render gate no-ops on a nil bound), and a non-positive interval would
    /// erase even the seed.
    ///
    /// Normalizing to `.none` would be WRONG — `.none` means "Never ends", i.e.
    /// still renders forever. Instead keep the end TYPE and supply the tightest
    /// bound that renders exactly the seed:
    ///   - `interval <= 0` → `1` (a 0/negative step matches nothing).
    ///   - `.afterCount` with nil or `<= 0` count → count `1` (the seed only).
    ///   - `.onDate` with a nil date → clamp the end date to the series start
    ///     day (the seed only).
    ///
    /// A PRESENT `.onDate` end date before the series start is deliberately NOT
    /// repaired. That shape is not value-less corruption — it is precisely the
    /// gh#124 zombie (`repeatEndDate == seriesStart − 1`) that pre-fix
    /// first-occurrence ".following" edits and deletes persisted, and gh#124's
    /// landed scope explicitly defers touching existing zombies to a separate
    /// cleanup migration. Clamping it up to the seed day would (a) resurrect an
    /// occurrence the user deleted, (b) render a duplicate block beside the
    /// split-off sibling series the old bug minted, and (c) — because this
    /// normalizer also runs on the persisted ingress paths — write the repaired
    /// date back on the next save/sync, permanently erasing the
    /// `repeatEndDate < seriesStart` predicate that migration needs to find
    /// these rows. Passing it through renders nothing, which is safe for both
    /// corrupt data and zombies.
    ///
    /// Valid rules pass through untouched. Pure so both decode ingress paths
    /// (`init(from:)`, `SupabaseSyncService+Restore.rowToEvent`) and the render
    /// gate (`CalendarLayout.recurrenceOccurrence`) can single-source it.
    static func normalizedRecurrenceRule(
        interval: Int,
        endType: RepeatEndType,
        endDate: Date?,
        endCount: Int?,
        seriesStart: Date?,
        calendar: Calendar = .current
    ) -> (interval: Int, endType: RepeatEndType, endDate: Date?, endCount: Int?) {
        let repairedInterval = interval > 0 ? interval : 1
        switch endType {
        case .none:
            return (repairedInterval, .none, endDate, endCount)
        case .afterCount:
            let repairedCount = (endCount ?? 0) > 0 ? endCount! : 1
            return (repairedInterval, .afterCount, endDate, repairedCount)
        case .onDate:
            // Without a seed instant there's nothing to clamp against; leave the
            // date as-is (the render gate still bails on a missing seriesStart).
            guard let seriesStart else {
                return (repairedInterval, .onDate, endDate, endCount)
            }
            // Only a MISSING date is the value-less gh#125 case. A present end
            // date — including one before the series start — passes through
            // unmodified: `endDate < seriesStart` is the gh#124 zombie
            // signature the deferred cleanup migration keys on, and repairing
            // it would resurrect deleted occurrences / mint visible duplicates
            // (see the doc comment above).
            guard endDate == nil else {
                return (repairedInterval, .onDate, endDate, endCount)
            }
            return (repairedInterval, .onDate, calendar.startOfDay(for: seriesStart), endCount)
        }
    }

    /// How many DAYS a series' `.onDate` end sits before its own start, or
    /// `nil` when the row is not a gh#124 zombie at all.
    ///
    /// The signature the gh#150 cleanup sweep keys on, and the only thing it
    /// keys on. Both mint sites cap the old series to
    /// `startOfDay(occurrenceDay) − 1 day` — the edit split (`applyEdit`, the
    /// `.following` branch below) and the delete split
    /// (`EventStore.deleteRecurringCalendarEvent`, its `.following` branch) —
    /// so a freshly minted zombie is exactly one day of gap, and `e0b62bd`
    /// guarantees no ingress seam launders that date on the way in or out.
    /// `testZombieSignatureMatchesWhatTheSplitActuallyMints` feeds the real
    /// mint's own output back through here, so this cannot drift into a
    /// lookalike of the shape it is supposed to match.
    ///
    /// Three deliberate choices:
    ///
    /// 1. **Day-level `<`, not `== −1 day`.** The end date is a stored
    ///    INSTANT — midnight of `seriesStart − 1` in whatever zone the device
    ///    held when the bug fired. Reinterpreted in another zone (the user
    ///    traveled, or restored onto a device elsewhere) that instant lands on
    ///    a different wall-clock day than it was written for, and the series
    ///    start drifts with it. An exact `−1 day` test would miss every zombie
    ///    that crossed a time zone. Comparing START-OF-DAY values absorbs the
    ///    drift and reports it as a widened gap, which the caller bounds.
    /// 2. **Day-level, not raw instants.** `repeatEndDate < seriesStart` on the
    ///    instants is true for a legitimate rule too: "ends on the start day"
    ///    stores midnight of D while the seed starts 09:00 of D. That series
    ///    renders exactly one occurrence and is a normal thing to own. Reduced
    ///    to days it is a gap of zero — **in the zone that wrote it, and only
    ///    there.** Both values are absolute instants, so the day reduction is a
    ///    function of the READING zone as much as of the data: read anywhere
    ///    1–9 h west of the authoring zone, that same legitimate pair straddles
    ///    a midnight and reports a gap of 1. Measured, not argued —
    ///    `testProbeLegitSingleDaySeriesAcrossEveryIANAZone` mints one row in
    ///    Asia/Shanghai and gets a positive gap in 200 of the 443 IANA zones.
    ///    So a positive day gap is a CANDIDATE FILTER, never a licence to
    ///    delete: `zombieMintShapeRefusal` is what authorizes that, and it is
    ///    built out of quantities no reading zone can move.
    /// 3. **Series only.** `isRecurringSeries` excludes materialized exception
    ///    instances and plain events, whose `repeatEndDate` is nil-or-inert
    ///    anyway; a `.none` / `.afterCount` end type carries no date to compare.
    ///
    /// Pure and `nonisolated` so the sweep, its tests, and any future reporting
    /// surface share one predicate instead of three lookalikes.
    nonisolated static func zombieRecurrenceSignatureDayGap(
        _ event: Event,
        calendar: Calendar = .current
    ) -> Int? {
        guard event.isRecurringSeries,
              event.repeatEndType == .onDate,
              let end = event.repeatEndDate,
              let start = event.primaryTimeRange?.start else { return nil }
        let endDay = calendar.startOfDay(for: end)
        let startDay = calendar.startOfDay(for: start)
        guard endDay < startDay else { return nil }
        return calendar.dateComponents([.day], from: endDay, to: startDay).day
    }

    /// The raw end→seed separation of a signature match, in seconds, or `nil`
    /// when the row carries no such pair.
    ///
    /// The ONE quantity in this classification that the reading zone cannot
    /// move: re-reading the pair anywhere else shifts both instants by the same
    /// offset. Everything the sweep is allowed to DELETE on is expressed in
    /// this, because a day gap is not — see `zombieRecurrenceSignatureDayGap`.
    nonisolated static func zombieRecurrenceEndToSeedSeparation(_ event: Event) -> TimeInterval? {
        guard event.isRecurringSeries,
              event.repeatEndType == .onDate,
              let end = event.repeatEndDate,
              let start = event.primaryTimeRange?.start,
              end < start else { return nil }
        return start.timeIntervalSince(end)
    }

    /// The end→seed separation window a gh#124 mint provably falls in.
    ///
    /// A mint's end is `startOfDay_mint(D) − 1 day` and its seed sits somewhere
    /// inside day D, so the separation is `timeOfDay(seed) + length(D−1)` —
    /// bounded below by the shortest possible day and above by the two longest
    /// consecutive ones. Sweeping every IANA zone over 2015–2040 (443 zone ids,
    /// the tz database as this app ships against it) gives a shortest day of
    /// 21 h and a longest of 27 h, both Antarctica/Casey, whose transitions are
    /// 3 h: a mint's separation therefore lies in **[21 h, 51 h)**, and a
    /// legitimate "ends on its own start day" rule's lies in **[0 h, 27 h)** —
    /// it is one day's time-of-day and nothing more.
    ///
    /// The bounds are deliberately NOT that full mint range:
    ///
    /// - **Floor 24 h, not 21 h.** Below a full day the two shapes overlap, and
    ///   an end less than 24 h before its seed is far more likely a legitimate
    ///   single-occurrence rule read from a zone west of the one that wrote it
    ///   than a mint. Mints in [21 h, 24 h) — a seed in the first hour of the
    ///   day after a spring-forward — land on the KEPT side, which is the
    ///   direction the whole sweep errs in.
    /// - **Ceiling 51 h, not "2 days".** Expressing the ceiling in DAYS was the
    ///   original bug of this predicate: the day gap of a fixed pair of instants
    ///   is a function of the reading zone, so no constant in days can bound it
    ///   (`testProbeMintShapeGapCeilingAcrossEveryIANAZone` reads a real
    ///   Pacific/Chatham mint from Pacific/Apia and gets a gap of 3). In
    ///   seconds the bound holds in every zone at once.
    ///
    /// Anything wider is NOT a mint, and is far more likely a user-authored end
    /// date (neither date picker clamps end to start), so the sweep reports it
    /// and leaves it alone.
    nonisolated static let zombieMintShapeSeparation: ClosedRange<TimeInterval> =
        (24 * 3600)...(51 * 3600)

    /// The zone in the tz database that reads this row's end date as the START
    /// OF THE DAY its own seed falls in — i.e. as a legitimate "repeats once,
    /// on its start day" rule authored there — or `nil` when no zone does.
    ///
    /// The proof half of the mint test, and the reason a legitimate row cannot
    /// be swept from ANY reading zone. Every writer of that legitimate shape
    /// mints `calendar.startOfDay(for: seriesStart)` in whatever zone the
    /// device held at the time — `normalizedRecurrenceRule`'s gh#125 repair,
    /// and both `.following` splits when the cut falls on the occurrence right
    /// after the seed — so the authoring zone is always its own witness, and a
    /// row that was legitimate when written stays un-sweepable forever, no
    /// matter how far the device travels. That is a guarantee about the shape,
    /// not a bound on how far the drift can go.
    ///
    /// It costs a real mint almost nothing: a mint's end is midnight of the day
    /// BEFORE its seed's day, so a witness would need a zone whose day that date
    /// is long enough to swallow the whole gap — impossible above 27 h, and in
    /// practice only reachable for a seed in the first minutes after midnight
    /// on a DST transition date (5 of a 1680-mint grid, all at 00:00–00:30).
    /// Those fall on the kept side, and are re-reported every launch.
    ///
    /// Runs only on rows that already matched the signature AND the separation
    /// window, which is zero rows on the overwhelming majority of launches.
    nonisolated static func zombieEndsOnStartDayWitness(_ event: Event) -> String? {
        guard event.repeatEndType == .onDate,
              let end = event.repeatEndDate,
              let start = event.primaryTimeRange?.start else { return nil }
        for candidate in zombieWitnessCalendars where candidate.calendar.startOfDay(for: start) == end {
            return candidate.id
        }
        return nil
    }

    /// One Gregorian calendar per IANA zone, sorted by id so the witness a trail
    /// line names is the same one on every device. Built once.
    private nonisolated static let zombieWitnessCalendars: [(id: String, calendar: Calendar)] = {
        TimeZone.knownTimeZoneIdentifiers.sorted().compactMap { id in
            guard let zone = TimeZone(identifier: id) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return (id, calendar)
        }
    }()

    /// Why this row is NOT provably a gh#124 mint — the string the sweep logs as
    /// its reason for keeping it — or `nil` when it provably is one.
    ///
    /// The single-source predicate for "auto-deletable shape". The sweep, the
    /// store's per-series blocker and the probes all ask THIS, so the frame the
    /// question is asked in cannot drift between them.
    ///
    /// Order matters, cheapest and most decisive first:
    /// 1. the signature itself (a day gap in the reading zone — the issue's
    ///    literal `repeatEndDate < seriesStart` requirement);
    /// 2. the separation window, which no reading zone can move;
    /// 3. the ends-on-start-day witness, which no reading zone can move either
    ///    and which is what makes "a legitimate single-occurrence series is
    ///    never touched" a proof rather than a tolerance.
    nonisolated static func zombieMintShapeRefusal(
        _ event: Event,
        calendar: Calendar = .current
    ) -> String? {
        guard let gap = zombieRecurrenceSignatureDayGap(event, calendar: calendar),
              let separation = zombieRecurrenceEndToSeedSeparation(event) else {
            return "not a zombie signature"
        }
        let hours = String(format: "%.2f", separation / 3600)
        if separation < zombieMintShapeSeparation.lowerBound {
            return "end sits \(hours)h before the seed, inside one day"
                + " — an ends-on-start-day rule read from another zone, not a mint (gap=\(gap)d)"
        }
        if separation > zombieMintShapeSeparation.upperBound {
            return "end sits \(hours)h before the seed, beyond the mint shape (gap=\(gap)d)"
        }
        if let witness = zombieEndsOnStartDayWitness(event) {
            return "\(witness) reads the end as the start of the seed's own day (\(hours)h, gap=\(gap)d)"
        }
        return nil
    }

    /// Resolve a requested recurrence edit/delete scope against the tapped
    /// occurrence's actual position. A `.following` ("this and following") from
    /// the series' FIRST realized occurrence (index 0 — nothing realized
    /// precedes it) is degenerate: it caps the old series to `seriesStart − 1`
    /// (a zombie that renders nothing yet lingers as `isRecurringSeries` in the
    /// Settings list) AND mints a duplicate new series. It is semantically
    /// identical to `.all`, so collapse it. Every other scope/position passes
    /// through unchanged.
    ///
    /// Pure so the canvas scope dialog (dispatch) and the store mutations
    /// (domain defense) single-source the same decision — a model-only coercion
    /// would desync from the edit sheet's own `scope`-branching save closure.
    static func resolvedRecurrenceEditScope(
        requested: RecurrenceEditScope,
        series: Event,
        occurrenceDate: Date,
        calendar: Calendar = .current
    ) -> RecurrenceEditScope {
        guard requested == .following,
              series.isRecurringSeries,
              let seriesStart = series.primaryTimeRange?.start else { return requested }
        let index = recurrenceOccurrenceIndex(
            seriesStart: seriesStart,
            day: occurrenceDate,
            unit: series.repeatUnit,
            interval: series.repeatInterval,
            calendar: calendar
        )
        return index == 0 ? .all : requested
    }

    /// The `.afterCount` count the "this and following" split-off series runs:
    /// the occurrences REMAINING at (and including) `occurrenceDate`. An
    /// `.afterCount(N)` series counts from its own start, so the occurrences
    /// before the split already spent part of N — a fresh N on the split-off
    /// series would inflate the schedule to `elapsed + N`.
    ///
    /// THE single source of this arithmetic (gh#126): `applyEdit(.following)`
    /// writes it, and both editing surfaces seed their "After N occurrences"
    /// field from it, so what the user sees is exactly what gets rendered. A
    /// second, divergent computation — one surface showing the whole-series N
    /// while the store persisted the remaining count — is precisely the bug
    /// class this issue was.
    ///
    /// `nil` when the series has no count to split (an unbounded or
    /// `.onDate` rule); the caller keeps whatever it already had.
    static func splitOffRemainingCount(
        series: Event,
        occurrenceDate: Date,
        calendar: Calendar = .current
    ) -> Int? {
        guard series.repeatEndType == .afterCount,
              let originalCount = series.repeatEndCount else { return nil }
        let occurrenceDay = calendar.startOfDay(for: occurrenceDate)
        // The SAME realized-occurrence index the render gate and the split use,
        // so month/year series that skip nonexistent dates (Jan 31 → Feb) agree.
        let elapsed = recurrenceOccurrenceIndex(
            seriesStart: series.primaryTimeRange?.start ?? occurrenceDay,
            day: occurrenceDay,
            unit: series.repeatUnit,
            interval: series.repeatInterval,
            calendar: calendar
        )
        return max(1, originalCount - elapsed)
    }

    /// The `.afterCount` value an editor should DISPLAY and EDIT for a given
    /// requested scope — the meaning of the "After N occurrences" field.
    ///
    /// In a `.following` edit the tapped occurrence becomes the FIRST
    /// occurrence of a newly split series, so the field means "N occurrences of
    /// the new series, starting here" → the remaining count. In `.all` (and
    /// `.single`) it still means the original series total. Routed through
    /// `resolvedRecurrenceEditScope` rather than an `elapsed == 0` special case,
    /// so a first-occurrence `.following` — which the store COERCES to `.all`
    /// (gh#124) — reads the total the whole-series edit will actually write.
    ///
    /// A nil scope / occurrence (the plain, non-recurring edit path) is the
    /// series' own count.
    static func scopedRepeatEndCount(
        series: Event,
        occurrenceDate: Date?,
        requestedScope: RecurrenceEditScope?,
        calendar: Calendar = .current
    ) -> Int? {
        guard let occurrenceDate, let requestedScope else { return series.repeatEndCount }
        let resolved = resolvedRecurrenceEditScope(
            requested: requestedScope,
            series: series,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        )
        guard resolved == .following else { return series.repeatEndCount }
        return splitOffRemainingCount(
            series: series,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        ) ?? series.repeatEndCount
    }

    /// Clear the one-to-one partner links on a recurrence split copy (the
    /// `.single` exception instance and the `.following` new series).
    /// `linkedCalendarEventId` / `linkedTodoEventId` are strictly one-to-one
    /// back-linked partners, so a copied link would forge a second, false owner
    /// of the same partner. Latent today (no recurring event currently carries
    /// a partner link) — defense in depth.
    ///
    /// `absorbedIntoEventID` is deliberately NOT cleared. It is a one-way
    /// todo→parent relation whose recurring-series semantics are an OPEN
    /// invariant (gh#127 third audit: clearing the two partner links is
    /// approved; touching `absorbedIntoEventID` is not, until recurring-todo
    /// absorption is decided and locked by a test —
    /// `absorbTodoIntoEvent` does not currently enforce
    /// `!source.isRecurringSeries`). Clearing it here would flip
    /// `isCanvasRenderable` on the copy: a `.single` edit of an absorbed
    /// recurring todo's occurrence would pop that day out of its absorbing
    /// parent onto the canvas while the series' other days stay hidden — an
    /// absorption behavior change nobody chose. Until the invariant lands, a
    /// split copy keeps the absorption state of the series it was copied from.
    private static func clearSplitCopyPartnerLinks(_ event: inout Event) {
        event.linkedCalendarEventId = nil
        event.linkedTodoEventId = nil
    }

    // MARK: Recurrence exception day-key identity (gh#127 item 1)

    /// THE precedence rule between the two stored exception representations —
    /// the only place it exists. Both ingress seams (`init(from:)` decode and
    /// the memberwise init that Supabase restore builds through) resolve here.
    ///
    /// - Day keys present (even empty): they ARE the identity; the legacy
    ///   dates are ignored. A count mismatch in favor of the dates cannot
    ///   persist: pre-migration code — the only writer that appends a date
    ///   without a key — re-encodes through CodingKeys that don't know the
    ///   day-key field, so its rewrite drops the field entirely and the blob
    ///   degrades wholesale to legacy, never to a mixed state.
    /// - Day keys absent (legacy blob): backfill from the absolute dates via
    ///   the frozen REFERENCE calendar (`CalendarOccurrenceKey.dayKey(from:)`).
    ///   DETERMINISM is the contract: the same stored blob must resolve to
    ///   the same keys no matter where the device happens to sit when it
    ///   decodes. A `Calendar.current` backfill freezes whatever zone the
    ///   user was passing through on migration day into a PERMANENT identity
    ///   — a temporary trip turned the pre-migration read's self-healing
    ///   drift (wrong abroad, right again at home) into a day that stays
    ///   wrong at home forever. The reference zone is frozen at first launch,
    ///   i.e. the home frame that minted the mirror midnights for every user
    ///   who hadn't traveled — and it is the same zone regardless of when or
    ///   where the backfill runs.
    ///   HONEST LIMITATION: the minting zone itself was never stored, so for
    ///   exceptions minted away from the reference zone (travel before this
    ///   build, or a permanent relocation since first launch) the backfilled
    ///   day can sit one off the day originally named — deterministically,
    ///   from migration onward. The paired instance-day backfill below
    ///   reduces the SAME mirror instant the same way, so the suppression day
    ///   and its detached replacement at least re-bucket together. Minted
    ///   keys themselves are never re-derived: they ride the Supabase wire
    ///   (`recurrence_exception_day_keys` / `recurrence_instance_day_key`),
    ///   so this backfill runs once per legacy blob — not on every pull.
    static func resolvedRecurrenceExceptionDayKeys(
        dayKeys: [Int]?,
        legacyDates: [Date]
    ) -> [Int] {
        if let dayKeys { return dayKeys }
        return legacyDates.map { CalendarOccurrenceKey.dayKey(from: $0) }
    }

    /// The instance-day twin of `resolvedRecurrenceExceptionDayKeys`, and the
    /// same precedence rule: a present key IS the identity; a legacy blob
    /// backfills from the `recurrenceInstanceDate` mirror via the frozen
    /// reference calendar — the same deterministic reduction, of the same
    /// creation-frame midnight, as the parent series' exception backfill, so
    /// a legacy (exception day, detached instance) pair can never split
    /// across two days.
    static func resolvedRecurrenceInstanceDayKey(
        dayKey: Int?,
        legacyDate: Date?
    ) -> Int? {
        if let dayKey { return dayKey }
        return legacyDate.map { CalendarOccurrenceKey.dayKey(from: $0) }
    }

    /// Nominal-day key for a recurrence identity (an exception day, a
    /// detached instance's day, a `.following` split boundary): `YYYYMMDD`
    /// for the civil day `date` falls on in the naming calendar's TIME ZONE,
    /// reduced through the Gregorian-pinned `dayKey(from:in:)`. The canvas
    /// expands recurrences in `Calendar.current` day arithmetic (see
    /// `EventStore.syncWidgetSnapshots` for why canvas day boundaries are
    /// deliberately NOT the frozen reference calendar), so "suppress this
    /// day" reduces the day in that same zone — an identity no later
    /// time-zone change can shift, and (because the reduction pins the
    /// calendar identifier) no region-calendar setting can either: a key
    /// minted on a th_TH (Buddhist) device must equal the key a Gregorian
    /// backfill produced for the same day, and `YYYYMMDD` keys must order
    /// like the days they name for the `>=` split carry.
    static func recurrenceDayKey(for date: Date, calendar: Calendar) -> Int {
        CalendarOccurrenceKey.dayKey(from: date, in: calendar)
    }

    /// The one writer: appends the day key (identity) and the legacy midnight
    /// date (rollback mirror) in step, so the two arrays stay parallel.
    mutating func appendRecurrenceException(onDay day: Date, calendar: Calendar) {
        recurrenceExceptionDates.append(calendar.startOfDay(for: day))
        recurrenceExceptionDayKeys.append(
            Event.recurrenceDayKey(for: day, calendar: calendar)
        )
    }

    /// The one reader: does this series suppress its occurrence on `day`?
    /// Compares nominal day keys only — never `isDate(_:inSameDayAs:)` on the
    /// stored dates, which is exactly the read that drifted after travel.
    func suppressesRecurrenceOccurrence(onDay day: Date, calendar: Calendar) -> Bool {
        recurrenceExceptionDayKeys.contains(
            Event.recurrenceDayKey(for: day, calendar: calendar)
        )
    }

    /// Does this detached instance replace the series occurrence on `day`?
    /// The key-identity twin of the old
    /// `recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: day) }`
    /// read — which reinterpreted a creation-frame midnight through the
    /// CURRENT calendar and, after a tz change, disagreed with the exception
    /// key carried inside the very same `.following` split (zombie instances
    /// on `.all` delete, one-day-off sweeps, dark detail lookups). The date
    /// fallback only serves events mutated behind the minting seams; every
    /// ingress path resolves a key when a mirror exists.
    func recurrenceInstanceMatches(day: Date, calendar: Calendar) -> Bool {
        guard let key = Event.resolvedRecurrenceInstanceDayKey(
            dayKey: recurrenceInstanceDayKey,
            legacyDate: recurrenceInstanceDate
        ) else { return false }
        return key == Event.recurrenceDayKey(for: day, calendar: calendar)
    }

    /// Render-frame time ranges (gh#127 items 2/5): a detached exception
    /// instance is placed relative to the CURRENT frame's midnight of its
    /// nominal day, not by its raw stored instants. Suppression of the
    /// series' own occurrence became nominal (day-key identity), so the
    /// replacement must land on the same nominal day, or a tz change larger
    /// than the occurrence's time-of-day re-buckets the replacement's instant
    /// into the neighboring day: the canvas then shows it BESIDE the series'
    /// legitimate occurrence there (duplicate) while the suppressed day
    /// renders empty (hole) — the literal gh#127 symptom, reintroduced by the
    /// nominal-suppression fix for the exact scenario it was built for.
    ///
    /// Projection: each range keeps its whole-day offset from the instance's
    /// own day (`floor((start − mirror) / 24h)`, so a replacement deliberately
    /// moved to another day stays moved) and its CURRENT-frame time-of-day —
    /// the same `dateByCombining` reduction the series expander uses, so the
    /// replacement sits at the same wall-clock as its sibling occurrences.
    /// An ALL-DAY range instead snaps to the current frame's midnight of its
    /// shifted day, keeping only the duration — time-of-day on an all-day
    /// range is mint-frame residue, and projecting it makes the whole-day
    /// block straddle two days of the strip's overlap test.
    ///
    /// When the stored mirror midnight IS the current frame's midnight of the
    /// nominal day — every device that never changed time zone — this returns
    /// the stored ranges bit-for-bit.
    ///
    /// This is a read-side projection; the stored ranges stay in their
    /// creation frame (rewriting them at ingress would be a sync storm —
    /// every device would re-frame every restore). A write that commits NEW
    /// current-frame ranges for a traveled instance (drag, sheet re-lock)
    /// would re-project here one day/hours off, so every instance-range
    /// write is paired with a mirror rebase — see
    /// `rebasedExceptionInstanceAfterRangeWrite`, applied inside
    /// `EventStore.mutateCalendarEvent`. The pairing cannot live here
    /// because a read must not guess which frame a caller's ranges were
    /// minted in.
    func renderTimeRanges(calendar: Calendar) -> [TimeRange] {
        guard isExceptionInstance,
              let mirror = recurrenceInstanceDate,
              let key = Event.resolvedRecurrenceInstanceDayKey(
                  dayKey: recurrenceInstanceDayKey,
                  legacyDate: mirror
              ),
              let nominalStart = CalendarOccurrenceKey.dayStart(forDayKey: key, in: calendar),
              nominalStart != mirror
        else { return effectiveTimeRanges }
        return effectiveTimeRanges.map { range in
            let dayShift = Int(floor(range.start.timeIntervalSince(mirror) / 86_400))
            let base = calendar.date(byAdding: .day, value: dayShift, to: nominalStart) ?? nominalStart
            let day = calendar.startOfDay(for: base)
            let duration = range.end.timeIntervalSince(range.start)
            // ALL-DAY: the stored shape is [startOfDay, startOfDay + 86_399]
            // in the MINT frame (see the composer's save). Its time-of-day is
            // frame residue, not content — carrying it across a tz change
            // projects [nominal 07:00, nominal+1 06:59:59], and the all-day
            // strip's pure overlap test then renders the instance on BOTH
            // days (gh#127 review findings 2/4: the literal duplicate, moved
            // one day over). Snap to the current frame's own midnight and
            // keep only the duration — the exact all-day shape this frame's
            // composer would have written.
            if isAllDay {
                return TimeRange(start: day, end: day.addingTimeInterval(duration))
            }
            let start = Event.dateByCombining(
                day: day,
                timeFrom: range.start,
                calendar: calendar
            )
            return TimeRange(
                start: start,
                end: start.addingTimeInterval(duration)
            )
        }
    }

    /// First render-frame range — the day-view/detail counterpart of
    /// `primaryTimeRange` for anything that places a detached instance on a
    /// calendar day.
    func renderPrimaryTimeRange(calendar: Calendar) -> TimeRange? {
        renderTimeRanges(calendar: calendar).first
    }

    /// The WRITE-side pairing of `renderTimeRanges` (its former KNOWN
    /// RESIDUAL): a write that commits new ranges onto a detached instance is
    /// minting CURRENT-frame instants — every ranged write path is UI-local
    /// (drag drop, edit-sheet re-lock, detail edits, timer stop) and computes
    /// from what the canvas is showing. Leaving the mirror in its mint frame
    /// then re-projects those fresh instants through a stale midnight:
    /// `dayShift` goes -1 for a mint frame west of here (drop lands a full
    /// day EARLIER than the finger), +1 for one east (a day LATER), and the
    /// nominal day the series still suppresses by key renders empty — the
    /// literal gh#127 duplicate+hole, reintroduced by a user edit. A naive
    /// `dayShift >= 0` clamp in the read would instead break deliberate
    /// moves to an earlier day, so the mirror moves WITH the write:
    /// `recurrenceInstanceDate = current-frame midnight of
    /// recurrenceInstanceDayKey`, the day key stamped first so identity
    /// cannot shift (a legacy row backfills its key from the OLD mirror
    /// before the mirror moves).
    ///
    /// A range this write did NOT touch is still a mint-frame instant, so it
    /// commits at its PROJECTION — exactly where `renderTimeRanges` was
    /// already placing it — and nothing moves on screen. After this, mirror
    /// == current-frame nominal midnight, and the projection is the identity
    /// until the device travels again.
    ///
    /// Deliberately NOT applied when the write also moved the recurrence
    /// identity fields (parent / mirror / key): a caller re-minting identity
    /// knows its own frame, and second-guessing it here would fight
    /// `applyEdit`. Ingress (restore/sync merge) replaces whole arrays and
    /// never routes through the mutate seam, so foreign-frame rows are never
    /// re-framed — exactly the boundary the read-side doc above demands.
    static func rebasedExceptionInstanceAfterRangeWrite(
        _ updated: Event,
        previous: Event,
        calendar: Calendar = .current
    ) -> Event {
        guard updated.isExceptionInstance,
              updated.timeRanges != previous.timeRanges,
              updated.recurrenceParentId == previous.recurrenceParentId,
              updated.recurrenceInstanceDate == previous.recurrenceInstanceDate,
              updated.recurrenceInstanceDayKey == previous.recurrenceInstanceDayKey,
              let key = resolvedRecurrenceInstanceDayKey(
                  dayKey: updated.recurrenceInstanceDayKey,
                  legacyDate: updated.recurrenceInstanceDate
              ),
              let nominalStart = CalendarOccurrenceKey.dayStart(forDayKey: key, in: calendar),
              nominalStart != updated.recurrenceInstanceDate
        else { return updated }
        var result = updated
        let projected = Dictionary(
            zip(previous.timeRanges, previous.renderTimeRanges(calendar: calendar)),
            uniquingKeysWith: { first, _ in first }
        )
        result.timeRanges = updated.timeRanges.map { projected[$0] ?? $0 }
        result.recurrenceInstanceDayKey = key
        result.recurrenceInstanceDate = nominalStart
        return result
    }

    /// Paired (legacy date, day key) rows whose day key is on/after
    /// `splitKey` — the `.following` split's carry filter. Classification is
    /// by day key alone (`YYYYMMDD` integers order like the days they name);
    /// the paired legacy date rides along untouched as the rollback mirror.
    /// If a key has no paired date (impossible through the writers above,
    /// defensive only), the key still carries — identity outranks the mirror.
    func recurrenceExceptions(onOrAfterDayKey splitKey: Int) -> (dates: [Date], dayKeys: [Int]) {
        var dates: [Date] = []
        var keys: [Int] = []
        for (index, key) in recurrenceExceptionDayKeys.enumerated() where key >= splitKey {
            keys.append(key)
            if index < recurrenceExceptionDates.count {
                dates.append(recurrenceExceptionDates[index])
            }
        }
        return (dates, keys)
    }

    static func applyEdit(
        series: Event,
        occurrenceDate: Date,
        scope: RecurrenceEditScope,
        edit: (inout Event) -> Void,
        calendar: Calendar = .current
    ) -> RecurrenceEditResult {
        guard series.isRecurringSeries else {
            var updated = series
            edit(&updated)
            return RecurrenceEditResult(updatedSeries: updated, newSeries: nil, exceptionInstance: nil)
        }

        let occurrenceDay = calendar.startOfDay(for: occurrenceDate)
        let occurrenceStart = dateByCombining(
            day: occurrenceDay,
            timeFrom: series.primaryTimeRange?.start,
            calendar: calendar
        )
        let occurrenceEnd = occurrenceStart.addingTimeInterval(series.duration)

        switch scope {
        case .all:
            var updated = series
            edit(&updated)
            return RecurrenceEditResult(updatedSeries: updated, newSeries: nil, exceptionInstance: nil)

        case .single:
            var updatedSeries = series
            // Day key + legacy date in step (gh#127 item 1) — the key is what
            // suppresses; the date is the pre-migration rollback mirror.
            updatedSeries.appendRecurrenceException(onDay: occurrenceDay, calendar: calendar)

            var instance = series
            instance.id = UUID()
            instance.timeRanges = [TimeRange(start: occurrenceStart, end: occurrenceEnd)]
            instance.repeatUnit = .none
            instance.repeatInterval = 1
            instance.repeatEndType = .none
            instance.repeatEndDate = nil
            instance.repeatEndCount = nil
            instance.recurrenceParentId = series.id
            instance.recurrenceInstanceDate = occurrenceDay
            // Minted from the SAME (day, calendar) as the exception key the
            // series just gained, so the pair shares one nominal identity —
            // classification and rendering can never split them across days.
            instance.recurrenceInstanceDayKey = recurrenceDayKey(for: occurrenceDay, calendar: calendar)
            instance.recurrenceExceptionDates = []
            instance.recurrenceExceptionDayKeys = []
            clearSplitCopyPartnerLinks(&instance)
            edit(&instance)

            return RecurrenceEditResult(
                updatedSeries: updatedSeries,
                newSeries: nil,
                exceptionInstance: instance
            )

        case .following:
            var updatedSeries = series
            let endCutoff = calendar.date(byAdding: .day, value: -1, to: occurrenceDay)
            updatedSeries.repeatEndType = .onDate
            updatedSeries.repeatEndDate = endCutoff

            var newSeries = series
            newSeries.id = UUID()
            newSeries.timeRanges = [TimeRange(start: occurrenceStart, end: occurrenceEnd)]
            newSeries.createdAt = Date()
            newSeries.recurrenceParentId = nil
            newSeries.recurrenceInstanceDate = nil
            newSeries.recurrenceInstanceDayKey = nil
            newSeries.recurrenceExceptionDates = []
            newSeries.recurrenceExceptionDayKeys = []
            clearSplitCopyPartnerLinks(&newSeries)
            // An `.afterCount(N)` series counts occurrences from its original
            // start, so the split-off series runs only the REMAINING count —
            // else "this and following" resets the counter and inflates the
            // total. Shared with the editors' seed so the field the user nudges
            // and the count that renders are the same number (gh#126).
            if let remaining = splitOffRemainingCount(
                series: series,
                occurrenceDate: occurrenceDay,
                calendar: calendar
            ) {
                newSeries.repeatEndCount = remaining
            }
            edit(&newSeries)

            return RecurrenceEditResult(
                updatedSeries: updatedSeries,
                newSeries: newSeries,
                exceptionInstance: nil
            )
        }
    }

    /// 0-based occurrence index of `day` within a series that starts at
    /// `seriesStart` — i.e. how many REALIZED occurrences precede `day`. Used
    /// both as the `.afterCount` cutoff (so "5 times" means five rendered days,
    /// not five calendar steps) and to split an `.afterCount` series at "this and
    /// following" so the new series keeps the remaining count. For month/year it
    /// skips calendar steps that land on a nonexistent date (Jan 31 → Feb has no
    /// 31), so it stays in lock-step with `CalendarLayout.recurrenceOccurrence`.
    /// `cappedAt` lets the afterCount render gate stop the month/year realized
    /// count once it reaches the limit (it only needs `>= count`), keeping the
    /// scan O(count) instead of O(age-of-series). The split's exact-index caller
    /// passes nil (a split day's index is always < count, so the cap is inert).
    static func recurrenceOccurrenceIndex(
        seriesStart: Date,
        day: Date,
        unit: RepeatUnit,
        interval: Int,
        calendar: Calendar = .current,
        cappedAt: Int? = nil
    ) -> Int {
        let seriesDay = calendar.startOfDay(for: seriesStart)
        let targetDay = calendar.startOfDay(for: day)
        let step = max(interval, 1)
        switch unit {
        case .none:
            return 0
        case .day:
            let days = calendar.dateComponents([.day], from: seriesDay, to: targetDay).day ?? 0
            return max(0, days / step)
        case .week:
            let days = calendar.dateComponents([.day], from: seriesDay, to: targetDay).day ?? 0
            return max(0, (days / 7) / step)
        case .month:
            let months = calendar.dateComponents([.month], from: seriesDay, to: targetDay).month ?? 0
            return realizedStepCount(seriesDay: seriesDay, component: .month, step: step, beforeStep: max(0, months / step), calendar: calendar, cappedAt: cappedAt)
        case .year:
            let years = calendar.dateComponents([.year], from: seriesDay, to: targetDay).year ?? 0
            return realizedStepCount(seriesDay: seriesDay, component: .year, step: step, beforeStep: max(0, years / step), calendar: calendar, cappedAt: cappedAt)
        }
    }

    /// Of the candidate steps `0..<beforeStep`, how many actually land on the
    /// series' day-of-month (and, for year, month-of-year) rather than being
    /// clamped by a nonexistent date. `Calendar.date(byAdding:)` clamps Jan 31 +
    /// 1 month to Feb 28, so the clamped day-of-month `!= seriesDayOfMonth`
    /// marks a skipped (non-rendered) step.
    private static func realizedStepCount(
        seriesDay: Date,
        component: Calendar.Component,
        step: Int,
        beforeStep: Int,
        calendar: Calendar,
        cappedAt: Int?
    ) -> Int {
        guard beforeStep > 0 else { return 0 }
        let seriesDayOfMonth = calendar.component(.day, from: seriesDay)
        let seriesMonth = calendar.component(.month, from: seriesDay)
        var realized = 0
        for k in 0..<beforeStep {
            guard let candidate = calendar.date(byAdding: component, value: k * step, to: seriesDay) else { continue }
            let dayMatches = calendar.component(.day, from: candidate) == seriesDayOfMonth
            let monthMatches = component == .year ? (calendar.component(.month, from: candidate) == seriesMonth) : true
            if dayMatches && monthMatches {
                realized += 1
                if let cap = cappedAt, realized >= cap { return realized }
            }
        }
        return realized
    }

    /// Normalize a single-occurrence exception built for `occDay`: strip the
    /// series repeat fields (an exception is a one-off) and lock its time ranges
    /// to `occDay`, preserving each range's time-of-day and duration. The full
    /// edit sheet is shared across scopes, so moving the day via its date picker
    /// must not relocate the exception off the occurrence it represents — only
    /// the time-of-day is editable; moving to another day is the drag gesture's
    /// job. (Locking is deliberately confined to the `.single` scope.)
    static func normalizedSingleOccurrenceException(
        _ instance: Event,
        lockedTo occDay: Date,
        calendar: Calendar = .current
    ) -> Event {
        var result = instance
        result.repeatUnit = .none
        result.repeatInterval = 1
        result.repeatEndType = .none
        result.repeatEndDate = nil
        result.repeatEndCount = nil
        result.timeRanges = result.timeRanges.map { range in
            let start = dateByCombining(day: occDay, timeFrom: range.start, calendar: calendar)
            return TimeRange(start: start, end: start.addingTimeInterval(range.end.timeIntervalSince(range.start)))
        }
        return result
    }

    // NOTE (gh#126): `restoringFollowingRemainingCount` lived here. It re-applied
    // `applyEdit`'s decremented count whenever the edit sheet's value still
    // EQUALLED its seed — a value-equality exception that only papered over the
    // seed being the wrong number. The sheet now seeds the remaining count
    // itself (`scopedRepeatEndCount`), so `form.apply` re-stamps that same value
    // and there is nothing left to restore; a nudged stepper is honored as the
    // new series' count instead of jumping by `elapsed`.

    static func dateByCombining(
        day: Date,
        timeFrom: Date?,
        calendar: Calendar
    ) -> Date {
        guard let timeFrom else {
            return day
        }
        let time = calendar.dateComponents([.hour, .minute, .second], from: timeFrom)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day
        ) ?? day
    }
}

extension Event {
    private static let minimumEffortOpacityMultiplier: Double = 0.4
    /// Default normalized depth used for events without an effort log
    /// when `effortOpacityEnabled` is true.  Maps to opacity ≈ 0.7
    /// (medium transparency) so unlogged events sit visually between
    /// low-effort (most transparent) and high-effort (fully opaque).
    private static let unloggedEffortDefaultDepth: Double = 0.5

    static func colorDepth(forEffort effort: Int?) -> Double {
        guard let effort else { return 0 }
        let clampedEffort = min(max(effort, CalendarEffortRating.one.rawValue), CalendarEffortRating.five.rawValue)
        return Double(clampedEffort) / Double(CalendarEffortRating.five.rawValue)
    }

    /// Convenience: read the effort-opacity setting from UserDefaults.
    /// Defaults to `true` (enabled) when the user hasn't changed it.
    static var effortOpacityEnabledFromDefaults: Bool {
        let key = "calendarEffortOpacityEnabled"
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else {
            return true
        }
        return value
    }

    var colorOpacityMultiplier: Double {
        return colorOpacityMultiplier(effortOpacityEnabled: Self.effortOpacityEnabledFromDefaults)
    }

    /// Pure-function variant for tests / explicit setting injection.
    func colorOpacityMultiplier(effortOpacityEnabled: Bool) -> Double {
        guard effortOpacityEnabled else { return 1 }
        let normalizedDepth = min(max(colorDepth, 0), 1)
        // Events without an explicit effort log default to medium opacity
        // so high-effort events visually stand out and low-effort events
        // recede into the background.
        let effectiveDepth = normalizedDepth > 0 ? normalizedDepth : Self.unloggedEffortDefaultDepth
        let range = 1 - Self.minimumEffortOpacityMultiplier
        return Self.minimumEffortOpacityMultiplier + range * effectiveDepth
    }
}
