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

    /// The three EVENT kinds (design §7.1 (4) "窗口、快照、手动 run"): the
    /// retreat-to-background edge carries them without the daily throttle,
    /// and they sort ahead of the dailies. `dailyRollup` is the throttled
    /// daily; `metricKitDaily` is neither — a background edge never carries
    /// it, and it sorts with the dailies (Lean model decision d).
    var isEventRecord: Bool {
        switch self {
        case .window, .verdictSnapshot, .manualRun: return true
        case .dailyRollup, .metricKitDaily: return false
        }
    }

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

// MARK: - Last upload (the status row)

/// When the last batch landed and how many rows its trigger moved — what
/// the status row says, kept across relaunches (QA).
struct TelemetryUploadStatus: Codable, Equatable {
    let at: Date
    let rows: Int
}

// MARK: - Upload cursor (design §7.2, B·F9/F36)

/// `run_id → highest revision the server has acknowledged`. Advances only
/// on a 2xx and only forwards; a corrupt or missing file is an EMPTY
/// cursor (everything pending, idempotent upsert absorbs it), never
/// "everything uploaded".
struct UploadCursor: Codable, Equatable {
    var uploaded: [UUID: Int]
    /// `run_id → the revision the server REFUSED as a row` (review P1-2):
    /// a record at exactly that revision is not pending, so one bad row can
    /// never block the batch forever; the next revision of the same id
    /// (a re-append) is tried again on its own merits.
    var quarantined: [UUID: Int]
    /// Rows acknowledged over this install's lifetime — "累计" on the card.
    /// Monotonic and independent of `uploaded.count`, which `prune` trims
    /// (review P2-6).
    var totalAcknowledged: Int

    init(uploaded: [UUID: Int] = [:], quarantined: [UUID: Int] = [:], totalAcknowledged: Int = 0) {
        self.uploaded = uploaded
        self.quarantined = quarantined
        self.totalAcknowledged = totalAcknowledged
    }

    /// Records whose local revision is above what was acknowledged and is
    /// not the one the server refused. A record with no revision (a line
    /// older than the chassis) has nothing the server could order it by
    /// and is never pending.
    func pending<R>(_ records: [R], id: KeyPath<R, UUID>, revision: KeyPath<R, Int?>) -> [R] {
        records.filter { record in
            guard let revision = record[keyPath: revision] else { return false }
            let recordID = record[keyPath: id]
            if quarantined[recordID] == revision { return false }
            return revision > (uploaded[recordID] ?? 0)
        }
    }

    /// Takes the MAX of what is known and what was just acknowledged —
    /// a late answer to an older batch can never move a cursor backwards.
    mutating func acknowledge(ids: [(UUID, Int)]) {
        for (id, revision) in ids {
            uploaded[id] = max(uploaded[id] ?? 0, revision)
        }
        totalAcknowledged += ids.count
    }

    /// Drops entries for ids no longer in the pool (compaction evicted the
    /// record): a cursor is bookkeeping for records that exist, and an
    /// evicted record can never be pending again. Called after a batch
    /// landed with the id set the SAME read saw (review P2-6).
    mutating func prune(keeping ids: Set<UUID>) {
        uploaded = uploaded.filter { ids.contains($0.key) }
        quarantined = quarantined.filter { ids.contains($0.key) }
    }

    /// The server refused this row at this revision. Recorded as-is (not a
    /// max): a later, higher revision replaces it when it too is refused,
    /// and an acknowledged higher revision makes it moot via `uploaded`.
    mutating func quarantine(id: UUID, revision: Int) {
        quarantined[id] = revision
    }

    // Keyed by uuid string on disk: `[UUID: Int]` would otherwise encode
    // as a flat array of alternating keys and values, unreadable to a
    // human or an agent looking at the file. `quarantined` is optional on
    // decode so a cursor file written before it existed still loads.
    private enum CodingKeys: String, CodingKey { case uploaded, quarantined, totalAcknowledged }

    private static func parse(_ raw: [String: Int]?) -> [UUID: Int] {
        var parsed: [UUID: Int] = [:]
        for (key, value) in raw ?? [:] {
            if let id = UUID(uuidString: key) { parsed[id] = value }
        }
        return parsed
    }

    private static func serialize(_ map: [UUID: Int]) -> [String: Int] {
        var raw: [String: Int] = [:]
        for (id, revision) in map { raw[id.uuidString] = revision }
        return raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uploaded = Self.parse(try container.decode([String: Int].self, forKey: .uploaded))
        quarantined = Self.parse(try container.decodeIfPresent([String: Int].self, forKey: .quarantined))
        totalAcknowledged = try container.decodeIfPresent(Int.self, forKey: .totalAcknowledged) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.serialize(uploaded), forKey: .uploaded)
        try container.encode(Self.serialize(quarantined), forKey: .quarantined)
        try container.encode(totalAcknowledged, forKey: .totalAcknowledged)
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
    ///
    /// The watermark is compared at WHOLE-SECOND granularity — the consent
    /// second itself counts as consented. Records come back from disk at
    /// whole seconds (`SpikeRunStore` writes dates with the `.iso8601`
    /// strategy, which drops fractions) while the consent moment is a
    /// full-precision `Date`, so a record minted a few milliseconds AFTER
    /// consent read back as before it (device bug, build 17: the consent
    /// re-mint was filtered out for the rest of the day). Whole seconds are
    /// also the Lean model's instants, so the fixtures are unaffected.
    static func filter(_ records: [SpikeRun], consentAt: Date?, currentOwner: String?) -> [SpikeRun] {
        guard let consentAt, let currentOwner else { return [] }
        let watermark = Date(timeIntervalSince1970: consentAt.timeIntervalSince1970.rounded(.down))
        return records.filter { $0.startedAt >= watermark && $0.ownerUID == currentOwner }
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

    /// Whether the daily rollup may ride a background edge: never uploaded
    /// one, or the last one is at least `dailyEdgeInterval` ago (`>=`:
    /// 900 s rides, 899 s waits — Lean model decision c). Every pending
    /// daily is subject to it, today's or not (decision b).
    static func dailyGateOpen(lastDailyUploadAt: Date?, now: Date) -> Bool {
        guard let lastDailyUploadAt else { return true }
        return now.timeIntervalSince(lastDailyUploadAt) >= dailyEdgeInterval
    }

    /// Which pending records a trigger admits (wire contract §5): the
    /// background edge takes the event kinds, plus `dailyRollup` when the
    /// gate is open, and never `metricKitDaily`; the other three take all.
    static func admits(_ run: SpikeRun, trigger: TelemetryTrigger, lastDailyUploadAt: Date?, now: Date) -> Bool {
        switch trigger {
        case .launch, .dayRollover, .deckOpen:
            return true
        case .backgroundEdge:
            let kind = run.resolvedKind
            return kind.isEventRecord || (kind == .dailyRollup && dailyGateOpen(lastDailyUploadAt: lastDailyUploadAt, now: now))
        }
    }

    /// The admitted records in batch order — event kinds first, then the
    /// daily kinds, each by `startedAt` ascending, ties in INPUT order
    /// (decision g) — cut at `limit`. The input index is written out as the
    /// tie-break as insurance: Swift's `sorted` does not promise stability,
    /// and the Lean model is proved with an explicit tie-break; behaviourally
    /// no difference is observable today (QA: 0 reorders in 350 trials), so
    /// a mutant that drops it is equivalent, not caught.
    static func selectBatch(
        _ pending: [SpikeRun],
        trigger: TelemetryTrigger,
        lastDailyUploadAt: Date?,
        now: Date,
        limit: Int = batchLimit
    ) -> [SpikeRun] {
        let admitted = pending.enumerated().filter { admits($0.element, trigger: trigger, lastDailyUploadAt: lastDailyUploadAt, now: now) }
        let ordered = admitted.sorted { a, b in
            let rankA = a.element.resolvedKind.isEventRecord ? 0 : 1
            let rankB = b.element.resolvedKind.isEventRecord ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            if a.element.startedAt != b.element.startedAt { return a.element.startedAt < b.element.startedAt }
            return a.offset < b.offset
        }
        return ordered.prefix(max(0, limit)).map(\.element)
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
    /// field existed; `kind` likewise; a missing `dayKey` is derived by the
    /// caller's `fallbackDay` (the uploader passes the process calendar —
    /// this file keeps `Calendar` out of everything but `dayKey`). `note`
    /// is included here and gated by the Redactor, so the note switch has
    /// exactly one enforcement point. Never emitted: `locale_identifier`,
    /// `time_zone_identifier`, `owner_uid` (it IS `user_id`), legacy abort
    /// text.
    static func row(
        for run: SpikeRun,
        userID: String,
        installID: UUID,
        now: Date,
        fallbackDay: (Date) -> (dayKey: String, tzOffsetMin: Int)
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

        let day: (dayKey: String, tzOffsetMin: Int)
        if let dayKey = run.dayKey, let offset = run.dayTZOffsetMin {
            day = (dayKey, offset)
        } else {
            day = fallbackDay(run.startedAt)
        }
        var row: [String: Any] = [
            "user_id": userID,
            "run_id": run.id.uuidString.lowercased(),
            "install_id": (run.installID ?? installID).uuidString.lowercased(),
            "kind": run.resolvedKind.rawValue,
            "spike_id": run.spikeID,
            "scenario_id": run.scenarioID,
            "day_key": day.dayKey,
            "day_tz_offset_min": day.tzOffsetMin,
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
}

// MARK: - Redactor (design §4.3, B·F24/F37) — the last gate before the wire

/// A WHITELIST over the serialized row. It does not trust upstream: every
/// string leaf must be a known identifier, a fixed-format value, or (for
/// `note` alone, and only when opted in) the one free-text field. Anything
/// else is removed, never passed through "because it looked fine" — except
/// that a NOT NULL text column (wire contract §2) that fails the whitelist
/// is replaced by `"unknown"` rather than dropped (review P1-2): a dropped
/// column makes the whole bulk insert a 23502 that hides which row was at
/// fault, while a placeholder lets the server judge that one row on its own
/// (and quarantine it, see `UploadCursor.quarantined`).
enum TelemetryRedactor {
    /// Text columns the table declares NOT NULL; a value that fails the
    /// whitelist becomes `placeholder` instead of vanishing.
    static let notNullTextColumns: [String] = [
        "kind", "spike_id", "scenario_id", "day_key", "app_version", "os_version", "device_model", "build_configuration",
    ]
    static let placeholder = "unknown"

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
        for column in notNullTextColumns where out[column] == nil {
            out[column] = placeholder
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

// MARK: - TestFlight default (design §16 rule 2)

/// When a build may switch statistics on by itself: a TestFlight install
/// whose user has never flipped the switch. Its watermark is the distant
/// past — the user asked for the history this device keeps to go up too
/// ("可以补传") — which still leaves out what §16 does not adopt: records
/// with no account (signed-out stretches never match the current owner)
/// and lines older than the chassis (no `revision`, never pending).
/// Where this install came from, as far as the statistics default cares
/// (§16 rule 2, review P1-2).
enum TelemetryDistribution: Equatable {
    case testFlight
    case appStore
    /// Signed with a provisioning profile (Xcode, devicectl, ad hoc), or
    /// StoreKit's `.xcode`.
    case development
    /// StoreKit could not say: offline, an error, an unverified transaction.
    case unknown(reason: String)

    /// The token on the launch's `Telemetry environment=` trail line.
    var traceLabel: String {
        switch self {
        case .testFlight: return "testflight"
        case .appStore: return "appstore"
        case .development: return "development"
        case .unknown(let reason): return "unknown(\(reason))"
        }
    }
}

enum TelemetryDefaultPolicy {
    static let testFlightWatermark = Date.distantPast

    static func autoEnables(distribution: TelemetryDistribution, userHasDecided: Bool) -> Bool {
        distribution == .testFlight && !userHasDecided
    }

    /// Only a DEFINITE App Store answer withdraws a switch the default turned
    /// on (review P1-1): `unknown` leaves it alone, so an offline TestFlight
    /// launch cannot flip it off and on again.
    static func withdrawsDefault(distribution: TelemetryDistribution, enabledByDefault: Bool) -> Bool {
        distribution == .appStore && enabledByDefault
    }

    /// Whether an ON switch may upload: one the user turned on, always; one
    /// the default turned on, only once this launch has heard "TestFlight" —
    /// a batch that runs before StoreKit answers, or on any other answer,
    /// sends nothing.
    static func mayUpload(enabledByDefault: Bool, distribution: TelemetryDistribution?) -> Bool {
        !enabledByDefault || distribution == .testFlight
    }

    /// The watermark a batch filters against (decision 2026-10-27 ①): in
    /// TestFlight EVERY consent backfills — the default's and the user's own
    /// ON alike, build 17's included — so it is the distant past whatever
    /// moment is stored; elsewhere it is the stored consent moment, which
    /// is always a real one (review P1-1).
    static func watermark(consentAt: Date, isTestFlight: Bool) -> Date {
        isTestFlight ? testFlightWatermark : consentAt
    }
}

// MARK: - Wire row → record (design §16 rule 3: the observatory reads the cloud)

extension TelemetryWire {
    private static let fractionalTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let wholeSecondTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// PostgREST renders `timestamptz` as `…:48.813127+00:00` or, on a whole
    /// second, `…:48+00:00`; each needs its own formatter.
    static func parseTimestamp(_ text: String) -> Date? {
        fractionalTimestamp.date(from: text) ?? wholeSecondTimestamp.date(from: text)
    }

    /// A `v_my_spike_runs` row (the `spike_runs` columns minus `note` and
    /// the server's two upload stamps) as the record the evaluator reads.
    /// What the wire never carries — zone, locale, note — comes back empty;
    /// the owner is the row's `user_id`. nil when a column the evaluator or
    /// the merge depends on is missing or malformed: an unreadable row is
    /// left out, never guessed at.
    static func run(fromRow row: [String: Any]) -> SpikeRun? {
        guard let id = (row["run_id"] as? String).flatMap(UUID.init(uuidString:)),
              let spikeID = row["spike_id"] as? String,
              let scenarioID = row["scenario_id"] as? String,
              let startedAt = (row["started_at"] as? String).flatMap(parseTimestamp),
              let appVersion = row["app_version"] as? String,
              let appBuild = (row["app_build"] as? NSNumber)?.intValue,
              let deviceModel = row["device_model"] as? String,
              let osVersion = row["os_version"] as? String
        else { return nil }
        var metrics: [String: SpikeMetricValue] = [:]
        for (key, value) in row["metrics"] as? [String: Any] ?? [:] {
            if let number = value as? NSNumber {
                metrics[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
            } else if let text = value as? String {
                metrics[key] = .string(text)
            }
        }
        let context = row["context"] as? [String: Any] ?? [:]
        var run = SpikeRun(
            id: id, spikeID: spikeID, scenarioID: scenarioID,
            variantID: context["variant_id"] as? String,
            startedAt: startedAt,
            endedAt: (row["ended_at"] as? String).flatMap(parseTimestamp),
            appVersion: appVersion, appBuild: String(appBuild),
            appCommit: context["app_commit"] as? String,
            deviceModel: deviceModel, osVersion: osVersion,
            timeZoneIdentifier: "", localeIdentifier: "",
            buildConfiguration: row["build_configuration"] as? String,
            coActiveSpikeIDs: context["co_active_spike_ids"] as? [String],
            metrics: metrics, note: nil,
            outcome: (row["outcome"] as? String).flatMap(SpikeRunOutcome.init(rawValue:)),
            abortReason: (context["abort_reason"] as? String).map(SpikeAbortReason.init(storedText:))
        )
        run.installID = (row["install_id"] as? String).flatMap(UUID.init(uuidString:))
        run.ownerUID = row["user_id"] as? String
        run.dayKey = row["day_key"] as? String
        run.dayTZOffsetMin = (row["day_tz_offset_min"] as? NSNumber)?.intValue
        run.revision = (row["revision"] as? NSNumber)?.intValue
        run.kind = (row["kind"] as? String).flatMap(TelemetryRecordKind.init(rawValue:))
        return run
    }
}

// MARK: - Observatory merge (design §16 rule 3)

enum TelemetryObservatoryMerge {
    /// This device's records and this account's cloud rows as ONE set, one
    /// record per run id: the higher `revision` wins, and a tie goes to the
    /// local copy, which carries what the wire does not (zone, locale,
    /// note). Ordered by `startedAt`, then id — the evaluator does not care,
    /// a stable order keeps the deck from shuffling between reads.
    static func merge(local: [SpikeRun], cloud: [SpikeRun]) -> [SpikeRun] {
        var byID: [UUID: SpikeRun] = [:]
        for run in local {
            if let held = byID[run.id], (held.revision ?? 0) >= (run.revision ?? 0) { continue }
            byID[run.id] = run
        }
        for run in cloud {
            if let held = byID[run.id], (held.revision ?? 0) >= (run.revision ?? 0) { continue }
            byID[run.id] = run
        }
        return byID.values.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    /// Installs behind a set of records; a local line written before the
    /// `installID` stamp existed is this install's.
    static func installCount(_ runs: [SpikeRun], localInstall: UUID) -> Int {
        Set(runs.map { $0.installID ?? localInstall }).count
    }
}
