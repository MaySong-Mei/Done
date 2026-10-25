//
//  TelemetryModel.swift
//  Done
//
//  gh#273 — the telemetry chassis's PURE half (Docs/telemetry/
//  00-telemetry-chassis-design.md §4, §7, §8; 01-wire-contract.md).
//
//  Everything here is arithmetic over values the caller already holds:
//  no file I/O, no UserDefaults, no URLSession, no UIKit, no publishing —
//  the uploader (TelemetryUploader.swift) is the impure shell, the store
//  (SpikeRunStore.swift) owns the bytes. A source-scan test pins the ban.
//  The ONE function that needs calendar math (`TelemetryClaimKey.dayKey`)
//  takes the Calendar as a parameter — the same discipline
//  `ResidentDayBounds.compute` follows — and the center calls it at
//  mint time only, never per signal.
//
//  Also deliberately here and not in the uploader: `TelemetryServerModel`,
//  the reference implementation of the server's `revision` guard, so the
//  in-memory fake server and the SQL checks are judged against one rule.
//

import Foundation

// MARK: - Record kind (wire contract §2 `kind`)

enum TelemetryRecordKind: String, Codable, Equatable, CaseIterable {
    case dailyRollup = "daily_rollup"
    case window
    case manualRun = "manual_run"
    case verdictSnapshot = "verdict_snapshot"
    case metricKitDaily = "metrickit_daily"

    /// The kinds the retreat-to-background edge may carry without the
    /// 15-minute daily throttle (wire contract §5).
    var isEventRecord: Bool { self != .dailyRollup }

    /// For lines written before `kind` existed. Resident dailies and
    /// auto-windows are recognised by their registry ids; anything else
    /// was a manual run.
    static func inferred(spikeID: String, scenarioID: String) -> TelemetryRecordKind {
        if spikeID == FixObservationRegistry.residentDailySpikeID { return .dailyRollup }
        if scenarioID == FixObservationRegistry.windowScenarioID { return .window }
        return .manualRun
    }
}

// MARK: - Abort reason (closes the second free-text outlet, B·F24)

/// Why a run ended early. An ENUM, not a `String`: the wire carries only
/// the known tokens (`wireValue`), so a future reason that is typed as
/// prose cannot leave the device.
///
/// `legacyUnknown` is the decode of a line written before this type
/// existed whose text is none of the five literals that existed then. The
/// text is kept LOCALLY (the record is still readable on the device) and
/// has no `wireValue`, so the uploader's context never contains it.
enum SpikeAbortReason: Equatable {
    case processEnded
    case manualRunTookOver
    case residentDeactivated
    case stoppedBeforeTarget
    case noGestureRecorded
    case legacyUnknown(String)

    /// The token on the wire and on disk for a known case; nil for legacy.
    var wireValue: String? {
        switch self {
        case .processEnded: return "process_ended"
        case .manualRunTookOver: return "manual_run_took_over"
        case .residentDeactivated: return "resident_deactivated"
        case .stoppedBeforeTarget: return "stopped_before_target"
        case .noGestureRecorded: return "no_gesture_recorded"
        case .legacyUnknown: return nil
        }
    }

    static let known: [SpikeAbortReason] = [
        .processEnded, .manualRunTookOver, .residentDeactivated, .stoppedBeforeTarget, .noGestureRecorded,
    ]

    /// Every token the Redactor lets through as `context.abort_reason`.
    static let wireValues: Set<String> = Set(known.compactMap(\.wireValue))

    /// The five literals that were on disk when this type replaced
    /// `abortReason: String?`, so those lines decode to their real case
    /// rather than to `legacyUnknown`.
    static let legacyLiterals: [String: SpikeAbortReason] = [
        "process ended before the scenario finished": .processEnded,
        "manual #201 run took over": .manualRunTookOver,
        "resident deactivated": .residentDeactivated,
        "stopped manually before 40 characters": .stoppedBeforeTarget,
        "stopped with no effort-scrubber gesture recorded": .noGestureRecorded,
    ]

    /// Whatever text a line carries: a wire token, a legacy literal, or
    /// prose nobody registered.
    init(storedText text: String) {
        if let known = Self.known.first(where: { $0.wireValue == text }) {
            self = known
        } else if let legacy = Self.legacyLiterals[text] {
            self = legacy
        } else {
            self = .legacyUnknown(text)
        }
    }

    /// The text kept on disk for a legacy reason; nil for a known case.
    var legacyText: String? {
        if case .legacyUnknown(let text) = self { return text }
        return nil
    }
}

extension SpikeAbortReason: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storedText: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue ?? legacyText ?? "")
    }
}

// MARK: - Claim key (design §4.2, B·F15/F16/F17)

/// What today's daily run id is adopted under. ALL four must match for a
/// relaunch to re-append the same id; any difference mints a new same-day
/// id, and the server's views sum same-day records per install. The
/// effect: a TestFlight build that updates at noon keeps the morning's
/// counts under the old build; a second account on the same phone gets its
/// own record; a signed-out stretch (owner nil) never merges into an
/// account's record.
struct TelemetryClaimKey: Equatable {
    let buildConfiguration: String?
    let appBuild: String
    let osVersion: String
    let ownerUID: String?

    init(buildConfiguration: String?, appBuild: String, osVersion: String, ownerUID: String?) {
        self.buildConfiguration = buildConfiguration
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.ownerUID = ownerUID
    }

    /// The key a record on disk was written under.
    init(run: SpikeRun) {
        self.init(buildConfiguration: run.buildConfiguration, appBuild: run.appBuild,
                  osVersion: run.osVersion, ownerUID: run.ownerUID)
    }

    /// Written out rather than synthesized so the rule reads as what it
    /// is: full equality, nil included (nil == nil is the signed-out
    /// partition claiming its own record, never an account's).
    static func == (lhs: TelemetryClaimKey, rhs: TelemetryClaimKey) -> Bool {
        lhs.buildConfiguration == rhs.buildConfiguration
            && lhs.appBuild == rhs.appBuild
            && lhs.osVersion == rhs.osVersion
            && lhs.ownerUID == rhs.ownerUID
    }

    /// The civil day a record belongs to, formatted ONCE at mint time in
    /// the day boundary's own time zone (B·F17: the boundary calendar is
    /// the center's init snapshot, never `TimeZone.current` at flush), plus
    /// that zone's offset on that day — what the server stores instead of
    /// a zone identifier (B·F23).
    static func dayKey(forDayStart dayStart: Date, calendar: Calendar) -> (dayKey: String, tzOffsetMin: Int) {
        let parts = calendar.dateComponents([.year, .month, .day], from: dayStart)
        let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let offset = calendar.timeZone.secondsFromGMT(for: dayStart) / 60
        return (key, offset)
    }
}

// MARK: - Upload cursor (design §7.2, B·F9/F36)

/// `run_id → highest revision the server has acknowledged`. Advances only
/// on a 2xx and only forwards; a corrupt or missing file is an EMPTY
/// cursor (everything pending, idempotent upsert absorbs it), never
/// "everything uploaded".
struct UploadCursor: Codable, Equatable {
    var uploaded: [UUID: Int]

    init(uploaded: [UUID: Int] = [:]) {
        self.uploaded = uploaded
    }

    /// Records whose local revision is above what was acknowledged. A
    /// record with no revision (a line older than the chassis) has
    /// nothing the server could order it by and is never pending.
    func pending<R>(_ records: [R], id: KeyPath<R, UUID>, revision: KeyPath<R, Int?>) -> [R] {
        records.filter { record in
            guard let revision = record[keyPath: revision] else { return false }
            return revision > (uploaded[record[keyPath: id]] ?? 0)
        }
    }

    /// Takes the MAX of what is known and what was just acknowledged —
    /// a late answer to an older batch can never move a cursor backwards.
    mutating func acknowledge(ids: [(UUID, Int)]) {
        for (id, revision) in ids {
            uploaded[id] = max(uploaded[id] ?? 0, revision)
        }
    }

    // Keyed by uuid string on disk: `[UUID: Int]` would otherwise encode
    // as a flat array of alternating keys and values, unreadable to a
    // human or an agent looking at the file.
    private enum CodingKeys: String, CodingKey { case uploaded }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: Int].self, forKey: .uploaded)
        var parsed: [UUID: Int] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { parsed[id] = value }
        }
        uploaded = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: Int] = [:]
        for (id, revision) in uploaded { raw[id.uuidString] = revision }
        try container.encode(raw, forKey: .uploaded)
    }
}

// MARK: - Server guard (design §9.2) — the reference the fake server runs

enum TelemetryServerModel {
    /// BEFORE UPDATE: `new.revision <= old.revision` → skip. An insert
    /// (no existing row) always applies. The client sees 2xx either way,
    /// which is correct: a higher local revision is sent eventually.
    static func apply(existing: Int?, incoming: Int) -> Bool {
        guard let existing else { return true }
        return incoming > existing
    }
}

// MARK: - Consent watermark (design §8.2)

enum TelemetryConsent {
    /// Only records minted at or after the moment the switch was turned on,
    /// and only the current account's. No consent, or no account, means
    /// nothing — a nil owner is the signed-out partition and never equals
    /// "whoever is signed in now".
    static func filter(_ records: [SpikeRun], consentAt: Date?, currentOwner: String?) -> [SpikeRun] {
        guard let consentAt, let currentOwner else { return [] }
        return records.filter { $0.startedAt >= consentAt && $0.ownerUID == currentOwner }
    }
}

// MARK: - Triggers and batch selection (design §7.1, wire contract §5)

enum TelemetryTrigger: Equatable {
    case launch
    case dayRollover
    case deckOpen
    case backgroundEdge

    static let batchLimit = 32
    /// A daily rollup rides a background edge only this long after the
    /// last time one was uploaded (B·F5: every edge used to resend it).
    static let dailyEdgeInterval: TimeInterval = 15 * 60

    /// Which of the pending records this trigger sends, in a stable
    /// order: event records first (windows, snapshots, manual runs), then
    /// dailies, each by `startedAt`, cut at `limit`. The background edge
    /// carries event records always and dailies only past the throttle.
    static func selectBatch(
        _ pending: [SpikeRun],
        trigger: TelemetryTrigger,
        lastDailyUploadAt: Date?,
        now: Date,
        limit: Int = batchLimit
    ) -> [SpikeRun] {
        let dailiesAllowed: Bool
        switch trigger {
        case .launch, .dayRollover, .deckOpen:
            dailiesAllowed = true
        case .backgroundEdge:
            if let lastDailyUploadAt {
                dailiesAllowed = now.timeIntervalSince(lastDailyUploadAt) >= dailyEdgeInterval
            } else {
                dailiesAllowed = true
            }
        }
        let events = pending.filter { $0.resolvedKind.isEventRecord }.sorted { $0.startedAt < $1.startedAt }
        let dailies = dailiesAllowed
            ? pending.filter { !$0.resolvedKind.isEventRecord }.sorted { $0.startedAt < $1.startedAt }
            : []
        return Array((events + dailies).prefix(max(0, limit)))
    }
}

extension SpikeRun {
    /// The stamped kind, or the one inferred from the registry ids for a
    /// line written before `kind` existed.
    var resolvedKind: TelemetryRecordKind {
        kind ?? TelemetryRecordKind.inferred(spikeID: spikeID, scenarioID: scenarioID)
    }
}

// MARK: - Wire row (wire contract §2)

enum TelemetryWire {
    static let table = "spike_runs"
    static let onConflict = ["user_id", "run_id"]

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func timestamp(_ date: Date) -> String { iso.string(from: date) }

    /// One record as the server's row, BEFORE redaction. `install_id`
    /// falls back to the current install for a line stamped before the
    /// field existed; `kind` likewise. `note` is included here and gated
    /// by the Redactor, so the note switch has exactly one enforcement
    /// point. Never emitted: `locale_identifier`, `time_zone_identifier`,
    /// `owner_uid` (it IS `user_id`), `legacy` abort text.
    static func row(
        for run: SpikeRun,
        userID: String,
        installID: UUID,
        now: Date
    ) -> [String: Any] {
        var metrics: [String: Any] = [:]
        for (key, value) in run.metrics {
            switch value {
            case .number(let number): metrics[key] = number
            case .string(let text): metrics[key] = text
            case .bool(let flag): metrics[key] = flag
            }
        }
        var context: [String: Any] = [:]
        if let ids = run.coActiveSpikeIDs { context["co_active_spike_ids"] = ids }
        if let reason = run.abortReason?.wireValue { context["abort_reason"] = reason }
        if let variant = run.variantID { context["variant_id"] = variant }
        if let commit = run.appCommit { context["app_commit"] = commit }

        let day = run.dayKey ?? Self.fallbackDayKey(run.startedAt)
        var row: [String: Any] = [
            "user_id": userID,
            "run_id": run.id.uuidString.lowercased(),
            "install_id": (run.installID ?? installID).uuidString.lowercased(),
            "kind": run.resolvedKind.rawValue,
            "spike_id": run.spikeID,
            "scenario_id": run.scenarioID,
            "day_key": day,
            "day_tz_offset_min": run.dayTZOffsetMin ?? 0,
            "app_build": Int(run.appBuild) ?? 0,
            "app_version": run.appVersion,
            "build_configuration": run.buildConfiguration ?? "debug",
            "device_model": run.deviceModel,
            "os_version": run.osVersion,
            "revision": run.revision ?? 0,
            "started_at": timestamp(run.startedAt),
            "metrics": metrics,
            "context": context,
            "client_updated_at": timestamp(now),
        ]
        if let endedAt = run.endedAt { row["ended_at"] = timestamp(endedAt) }
        if let outcome = run.outcome { row["outcome"] = outcome.rawValue }
        if let note = run.note { row["note"] = note }
        return row
    }

    /// A record minted before `dayKey` existed: UTC civil date of its
    /// start, offset 0 — labelled as such by the zero offset rather than
    /// guessed from a zone the record never carried.
    private static func fallbackDayKey(_ date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return TelemetryClaimKey.dayKey(forDayStart: date, calendar: utc).dayKey
    }
}

// MARK: - Redactor (design §4.3, B·F24/F37) — the last gate before the wire

/// A WHITELIST over the serialized row. It does not trust upstream: every
/// string leaf must be a known identifier, a fixed-format value, or (for
/// `note` alone, and only when opted in) the one free-text field. Anything
/// else is removed, never passed through "because it looked fine".
enum TelemetryRedactor {
    /// Metric keys whose `.string` value is a fixed-format histogram or
    /// list (observatory: `"0 3 9 …"`, `"12.3 45.6"`), named by the model
    /// that writes them so this set cannot drift from the writer.
    static let observatoryFixedFormatStringKeys: Set<String> =
        ResidentCounterSet.fixedFormatStringKeys.union(ResidentWindowAggregates.fixedFormatStringKeys)

    /// Digits, dots and dashes: version strings and civil dates.
    private static let versionLike = CharacterSet(charactersIn: "0123456789.-")
    /// Hardware identifiers (`iPhone17,2`) and version-ish text.
    private static let identifierLike = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",._-"))
    private static let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    private static let isoLike = CharacterSet(charactersIn: "0123456789-:.TZ+")

    private static func matches(_ text: String, _ allowed: CharacterSet, maxLength: Int = 64) -> Bool {
        !text.isEmpty && text.count <= maxLength && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isUUID(_ text: String) -> Bool { UUID(uuidString: text) != nil }

    static func redact(row: [String: Any], noteOptIn: Bool, allowedStringKeys: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in row {
            switch key {
            case "user_id", "run_id", "install_id":
                if let text = value as? String, isUUID(text) { out[key] = text }
            case "kind":
                if let text = value as? String, TelemetryRecordKind(rawValue: text) != nil { out[key] = text }
            case "spike_id", "scenario_id":
                // Registry ids: short dotted/dashed identifiers, never prose.
                if let text = value as? String, matches(text, identifierLike) { out[key] = text }
            case "day_key":
                if let text = value as? String, text.count == 10, matches(text, versionLike) { out[key] = text }
            case "app_version", "os_version":
                if let text = value as? String, matches(text, versionLike) { out[key] = text }
            case "device_model":
                if let text = value as? String, matches(text, identifierLike) { out[key] = text }
            case "build_configuration":
                if let text = value as? String, text == "debug" || text == "release" { out[key] = text }
            case "outcome":
                if let text = value as? String, SpikeRunOutcome(rawValue: text) != nil { out[key] = text }
            case "started_at", "ended_at", "client_updated_at":
                if let text = value as? String, matches(text, isoLike) { out[key] = text }
            case "day_tz_offset_min", "app_build", "revision":
                if let number = value as? NSNumber, !isBoolean(number) { out[key] = number }
            case "metrics":
                out[key] = redactMetrics(value as? [String: Any] ?? [:], allowedStringKeys: allowedStringKeys)
            case "context":
                out[key] = redactContext(value as? [String: Any] ?? [:])
            case "note":
                if noteOptIn, let text = value as? String { out[key] = text }
            default:
                // An unknown column is not forwarded, whatever its type.
                continue
            }
        }
        return out
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func redactMetrics(_ metrics: [String: Any], allowedStringKeys: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in metrics {
            if let number = value as? NSNumber {
                out[key] = number
            } else if let text = value as? String, allowedStringKeys.contains(key) {
                out[key] = text
            }
            // Any other string, and any nested structure, is dropped.
        }
        return out
    }

    private static func redactContext(_ context: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let ids = context["co_active_spike_ids"] as? [String] {
            out["co_active_spike_ids"] = ids.filter { matches($0, identifierLike) }
        }
        if let reason = context["abort_reason"] as? String, SpikeAbortReason.wireValues.contains(reason) {
            out["abort_reason"] = reason
        }
        if let variant = context["variant_id"] as? String, matches(variant, identifierLike) {
            out["variant_id"] = variant
        }
        if let commit = context["app_commit"] as? String, matches(commit, hex, maxLength: 40), commit.count >= 7 {
            out["app_commit"] = commit
        }
        return out
    }
}
