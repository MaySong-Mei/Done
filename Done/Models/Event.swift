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
    var recurrenceExceptionDates: [Date]
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
        recurrenceExceptionDates = try container.decodeIfPresent([Date].self, forKey: .recurrenceExceptionDates) ?? []
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
        recurrenceExceptionDates: [Date] = [],
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
        self.recurrenceExceptionDates = recurrenceExceptionDates
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
        try container.encode(recurrenceExceptionDates, forKey: .recurrenceExceptionDates)
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

    var isRecurringSeries: Bool {
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

    var primaryTimeRange: TimeRange? {
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
    /// value-less or degenerate state, failing CLOSED so the seed occurrence is
    /// preserved and never rendered forever. A typed end (`.afterCount` /
    /// `.onDate`) carrying a nil or nonsensical bound would otherwise render on
    /// every pattern day forever (the render gate no-ops on a nil bound), and a
    /// non-positive interval or a `< seriesStart` end would erase even the seed.
    ///
    /// Normalizing to `.none` would be WRONG — `.none` means "Never ends", i.e.
    /// still renders forever. Instead keep the end TYPE and supply the tightest
    /// bound that renders exactly the seed:
    ///   - `interval <= 0` → `1` (a 0/negative step matches nothing).
    ///   - `.afterCount` with nil or `<= 0` count → count `1` (the seed only).
    ///   - `.onDate` with nil date, or a date before the series start → clamp the
    ///     end date to the series start day (the seed only).
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
            let startDay = calendar.startOfDay(for: seriesStart)
            guard let endDate, calendar.startOfDay(for: endDate) >= startDay else {
                return (repairedInterval, .onDate, startDay, endCount)
            }
            return (repairedInterval, .onDate, endDate, endCount)
        }
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

    /// Clear the one-to-one partner links + absorption ref on a recurrence split
    /// copy (the `.single` exception instance and the `.following` new series).
    /// `linkedCalendarEventId` / `linkedTodoEventId` are strictly one-to-one
    /// back-linked partners, so a copied link would forge a second, false owner
    /// of the same partner; `absorbedIntoEventID` is a one-way todo→parent ref
    /// that a copy would dangle onto a parent which never absorbed the copy.
    /// Latent today (no recurring event currently carries a partner link) —
    /// defense in depth.
    ///
    /// NOTE: recurring-todo absorption semantics are an OPEN invariant to decide
    /// later — `absorbTodoIntoEvent` does not currently enforce
    /// `!source.isRecurringSeries`. This only drops stale COPIED refs on a split;
    /// it does not change absorption behavior.
    private static func clearSplitCopyPartnerLinks(_ event: inout Event) {
        event.linkedCalendarEventId = nil
        event.linkedTodoEventId = nil
        event.absorbedIntoEventID = nil
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
            updatedSeries.recurrenceExceptionDates.append(occurrenceDay)

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
            instance.recurrenceExceptionDates = []
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
            newSeries.recurrenceExceptionDates = []
            clearSplitCopyPartnerLinks(&newSeries)
            // An `.afterCount(N)` series counts occurrences from its original
            // start. The occurrences before the split already used part of N,
            // so the split-off series must run only the REMAINING count — else
            // "this and following" resets the counter and inflates the total.
            if series.repeatEndType == .afterCount, let originalCount = series.repeatEndCount {
                let elapsed = Event.recurrenceOccurrenceIndex(
                    seriesStart: series.primaryTimeRange?.start ?? occurrenceStart,
                    day: occurrenceDay,
                    unit: series.repeatUnit,
                    interval: series.repeatInterval,
                    calendar: calendar
                )
                newSeries.repeatEndCount = max(1, originalCount - elapsed)
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

    /// `applyEdit(.following)` decrements an `.afterCount` series to its REMAINING
    /// count on split. The full edit sheet then re-stamps every field from the
    /// form — whose count was seeded with the series' ORIGINAL N — which would
    /// overwrite that remaining count and inflate the split-off series back to N
    /// (rendering phantom occurrences). Restore the remaining count, but only when
    /// the user didn't actually change it from the seed — so a deliberate count
    /// change is still honored. Mirrors the rule editor's `endChanged` guard.
    ///
    /// - Parameters:
    ///   - scope: the edit scope; only `.following` carries a decremented count.
    ///   - beforeApply: the split series as `applyEdit` produced it, BEFORE
    ///     `form.apply` re-stamped it — still holding the decremented count.
    ///   - edited: the split series after `form.apply` re-stamped it.
    ///   - seedCount: the count the form was seeded with (the series' original N).
    static func restoringFollowingRemainingCount(
        scope: RecurrenceEditScope,
        beforeApply: Event,
        edited: Event,
        seedCount: Int?
    ) -> Event {
        // Only a `.following` split of an `.afterCount` series has a decremented
        // remaining count worth protecting; read it off the pre-`form.apply` copy.
        let remaining = (scope == .following && beforeApply.repeatEndType == .afterCount)
            ? beforeApply.repeatEndCount : nil
        guard let remaining,
              edited.repeatEndType == .afterCount,
              edited.repeatEndCount == seedCount
        else { return edited }
        var result = edited
        result.repeatEndCount = remaining
        return result
    }

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
