import Foundation

/// Lightweight event snapshot shared between the main app and widget via App Group UserDefaults.
///
/// One value = one **occurrence**, not one event: a recurring series expands to
/// one snapshot per rendered day, and a multi-range (cross-midnight) event to
/// one snapshot per range.  `id` is therefore per-occurrence — see
/// `occurrenceID(eventID:occurrenceStart:)` — while `eventID` carries the
/// underlying `Event.id` so the widget can still group occurrences back onto
/// their event (interrupt → parent lookup today, deep links later).
///
/// Codable compatibility matters in BOTH directions: the App Group blob outlives
/// an app upgrade (a freshly-installed widget can read a blob the previous app
/// version wrote, and vice versa), so every field added here must be optional
/// (missing key decodes to nil) and every reader must degrade instead of
/// failing.  `resolvedEventID` is that degradation for `eventID`.
struct SharedEventSnapshot: Codable, Hashable {
    /// Identity of THIS occurrence. Unique within one snapshot payload.
    var id: UUID
    /// `Event.id` of the event this occurrence came from. Optional only for
    /// backwards decode of blobs written before per-occurrence ids existed —
    /// read it through `resolvedEventID`.
    var eventID: UUID?
    var title: String
    var type: String
    var colorHex: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var isDone: Bool
    var isInterrupt: Bool?
    var parentEventID: UUID?

    /// The underlying event id, with a fallback for legacy blobs where `id`
    /// *was* the event id.
    var resolvedEventID: UUID { eventID ?? id }

    /// Deterministic per-occurrence identity: `(event, occurrence start,
    /// ordinal)` always maps to the same UUID.  Deterministic (not `UUID()`) so
    /// a snapshot rewrite that changes nothing keeps the same ids — SwiftUI's
    /// `ForEach` identity in the widget then animates in place instead of
    /// tearing the row down.
    ///
    /// The end date is deliberately NOT mixed in: stretching an occurrence
    /// should keep its identity.  That leaves `(event, start)` non-unique for
    /// one reachable shape — two ranges of the SAME event starting at the same
    /// instant.  `calendarUpdatedRangesAfterDrop` is the live producer: it
    /// replaces the dragged range of a multi-range (cross-midnight) event in
    /// place, never checking whether the dropped start already belongs to a
    /// sibling range, and `CalendarPageView` writes the result straight into
    /// `rawCalendarEvents` — the array this projection reads.  The canvas draws
    /// both blocks (`CalendarLayout.occurrencesForDate` mixes the end into its
    /// id), so the widget must carry both too — `ordinal` is the tiebreaker
    /// that keeps them distinct without making a resize churn identity.
    ///
    /// `ordinal == 0` (the only value any non-degenerate payload uses) is
    /// exactly the `(resolvedEventID, startDate)` composite, so an ordinary
    /// snapshot's id stays recomputable from the snapshot itself. Only the
    /// duplicate-start siblings need their position to be reproduced, and the
    /// builder is the single place that assigns it.
    static func occurrenceID(eventID: UUID, occurrenceStart: Date, ordinal: Int = 0) -> UUID {
        // Millisecond resolution — below the granularity any UI can produce,
        // above the float noise of `timeIntervalSince1970`.
        let millis = (occurrenceStart.timeIntervalSince1970 * 1000).rounded()
        // Clamp rather than trap. `Date.distantFuture` is ~6.4e13 ms, five
        // orders of magnitude short of `Int64.max` — the real hazards are a
        // NaN/infinite interval out of a corrupt decode and the absurd dates a
        // hand-edited blob can carry, both of which would trap the `Int64` init.
        let clamped = millis.isFinite ? min(max(millis, -9.0e18), 9.0e18) : 0
        var z = UInt64(bitPattern: Int64(clamped)) &+ 0x9E37_79B9_7F4A_7C15
        // Odd multiplier so a nonzero ordinal always perturbs the seed, and
        // `ordinal == 0` leaves it byte-identical to the two-argument form.
        z = z &+ (UInt64(bitPattern: Int64(ordinal)) &* 0xD6E8_FEB8_6659_FD93)
        // splitmix64 finalizer — avalanches adjacent timestamps into unrelated
        // bit patterns so consecutive days can't alias.
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= (z >> 31)

        var bytes = eventID.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            withUnsafeBytes(of: z.bigEndian) { mix in
                // Keep the event's high 8 bytes intact so the id stays visibly
                // derived from its event when eyeballing a dumped blob.
                for i in 0..<8 { raw[8 + i] ^= mix[i] }
            }
        }
        return UUID(uuid: bytes)
    }
}

enum SharedWidgetData {
    static let appGroupID = "group.wordless.shiqiliuyifanmei.app"
    static let snapshotKey = "widgetEventSnapshots"
    static let lastUpdatedKey = "widgetLastUpdated"

    /// Whether THIS process is actually entitled to the App Group.
    ///
    /// `UserDefaults(suiteName:)` is not a membership check.  It returns nil
    /// only for the process' own bundle id and the global domain; for any other
    /// string — including a group id the target has no
    /// `com.apple.security.application-groups` entitlement for — it hands back a
    /// perfectly usable suite that quietly lands in the process' OWN
    /// `Library/Preferences`.  That is exactly how gh#142 stayed invisible: the
    /// app wrote, every call reported success, and the widget (which reads the
    /// real shared container) saw an empty payload forever.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil
    /// without the entitlement, so it is the honest probe.  Cached because it
    /// hits the filesystem and membership cannot change while the process runs.
    static let isMemberOfAppGroup: Bool =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil

    static var sharedDefaults: UserDefaults? {
        guard isMemberOfAppGroup else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }

    static let timeFormatKey = "widgetTimeFormat"
    static let languageKey = "widgetLanguage"

    /// Returns false when the payload never reached the App Group: this target
    /// is not entitled to the group (see `isMemberOfAppGroup` — the silent
    /// failure this guards), the suite could not be opened, or the payload did
    /// not encode.  Callers that cache "what was last written" must only update
    /// that cache on `true` — otherwise a one-off failure is remembered as a
    /// success and the identical payload is never retried.
    ///
    /// It does NOT promise the bytes are durable on disk: `UserDefaults` flushes
    /// the container plist asynchronously (observed lag of tens of seconds), so
    /// a `true` means "handed to the right suite", not "readable by the widget
    /// this instant".
    @discardableResult
    static func write(events: [SharedEventSnapshot], timeFormat: String = "24h", language: String = "en") -> Bool {
        guard let defaults = sharedDefaults else { return false }
        guard let data = try? JSONEncoder().encode(events) else { return false }
        defaults.set(data, forKey: snapshotKey)
        defaults.set(Date(), forKey: lastUpdatedKey)
        defaults.set(timeFormat, forKey: timeFormatKey)
        defaults.set(language, forKey: languageKey)
        return true
    }

    static func read() -> [SharedEventSnapshot] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: snapshotKey),
              let events = try? JSONDecoder().decode([SharedEventSnapshot].self, from: data) else {
            return []
        }
        return events
    }
}
