import Foundation

/// Canonical list of `UserDefaults` keys that we sync to Supabase as part of
/// disaster-recovery / cross-device restore. Anything not listed here is
/// considered per-device transient state.
///
/// Keep this list aligned with `AppSettingsKeys` + the misc `@AppStorage`
/// keys used directly by views. Adding a key here automatically opts it into
/// the sync — no schema migration needed (it's a JSON blob).
///
/// **Deliberately excluded — per-device by design:**
///
/// These UserDefaults keys MUST NOT enter `allKeys`. Each captures device-
/// local state that would cause cross-device interference if synced. When
/// adding a new per-device key elsewhere in the codebase, document it here.
///
///   - `AppSettingsKeys.syncUploadsEnabled` — the upload gate itself. If we
///     synced it, one device flipping it on would push that choice to every
///     other device on next restore, defeating the purpose of a per-device
///     gate. Each device must own its own upload posture.
///   - `agentAPIKey` — third-party provider credential (see note in line list).
///   - `syncHashes.<userId>.<table>` — diff-sync baselines (#30 hash
///     persistence). Per-device because each device tracks "what I last
///     pushed to cloud"; syncing them would mean cross-device confusion
///     about which rows are dirty.
///   - `lastSyncedAvatarVersion.<userId>` — per-device marker of which
///     avatar version this device has already uploaded. Paired with the
///     synced `meAvatarVersion` to detect "device needs to push".
///   - `hasOfferedAutoRestore.<userId>` — one-shot prompt flag for the
///     auto-restore-on-fresh-install nudge. Per-device because each
///     device has its own first-launch experience.
///   - `supabaseAuthSession` — LEGACY key of the current device's Supabase
///     session; the session now lives in the Keychain (gh#249) and this key
///     only survives until the migration has verified. Per-device (each
///     device signs in independently). See `AuthService`.
///   - `calendar.timeline.hourHeight` — pinch-to-zoom remembered cell
///     height. Per-device because screen sizes differ.
///   - `verboseImageLogging` — debug toggle for noisy image-upload logs.
///     Per-device because it's a developer affordance, not a preference.
///   - `AppSettingsKeys.lastSelectedTab` — the tab this device was last on,
///     written by every tab tap. Synced, each tap was a cloud write and a
///     doorbell (gh#257 staging QA round 6), and an account switch read the
///     previous account as having an unsynced change. `rememberLastTab` and
///     `defaultTab`, the user's choices, stay synced.
enum SyncedSettings {
    static let allKeys: [String] = [
        // ── General / tab behavior ──
        AppSettingsKeys.rememberLastTab,
        AppSettingsKeys.defaultTab,
        AppSettingsKeys.showTimerBanner,

        // ── Workflow / focus ──
        AppSettingsKeys.landscapeFocusMode,
        AppSettingsKeys.landscapeFocusKeepAwake,
        AppSettingsKeys.focusConfirmBeforeTracking,

        // ── Analysis ──
        AppSettingsKeys.analysisDefaultPeriod,
        AppSettingsKeys.analysisAutoLoadSuggestions,

        // ── Skill analysis dedup ──
        // The set of event IDs we've already run skill-analysis over. Without
        // syncing, restore on a fresh device sees an empty set → re-analyzes
        // every restored event → burns LLM tokens AND can duplicate insights
        // into the freshly-restored `skill_insights` row. Stored as
        // `[String]` (UUID strings), JSON-native, so it fits the settings blob.
        "skillAnalyzedEventIds",

        // ── Event-type color memory ──
        // `EventTypeTemplateStore.colorHistoryKey`. Remembers color choices
        // for deleted types so re-creating them restores the original color
        // (small UX polish, lost on restore without this). Stored as plain
        // `[String: String]` dict, JSON-native.
        //
        // BRIDGED (see `bridgedKeys`): the key stays on the wire, but it no
        // longer lives in `UserDefaults` — it is read from and written to
        // `EventTypeCatalog`. Reading it from `defaults` here would upload
        // whatever the pre-migration blob happened to hold, forever.
        "eventTypeColorHistory",

        // ── Calendar look & feel ──
        AppSettingsKeys.effortOpacityEnabled,
        AppSettingsKeys.calendarHeaderExposedTools,
        AppSettingsKeys.detailHeaderExposedTools,
        AppSettingsKeys.calendarLastRangeMode,
        AppSettingsKeys.calendarRememberViewMode,
        AppSettingsKeys.calendarAutoReturnToToday,
        AppSettingsKeys.calendarAdjacentEventSnapEnabled,
        AppSettingsKeys.calendarEventFontSize,
        AppSettingsKeys.calendarEventShowTimeBelowTitle,
        // `nearFutureHorizonDays` intentionally excluded — it's part of
        // the experimental calendar/todo unification feature (issue #38
        // tracks the related sync gap). Add back once the feature ships.

        // ── Experimental ──
        AppSettingsKeys.experimentalMultiTypeEvents,
        AppSettingsKeys.experimentalMultiTypeMaxCount,

        // ── Agent / AI configuration ──
        "agentProvider",
        // NOTE: `agentAPIKey` is intentionally NOT synced. It's a third-party
        // provider credential (Anthropic / OpenAI / DeepSeek) belonging to the
        // user; uploading it to Supabase as plaintext jsonb would widen its
        // attack surface (Postgres backups, log leaks, future service-role
        // compromise) for marginal restore-convenience. After restore on a new
        // device, the user is expected to re-enter the key — same pattern as
        // most native apps with provider credentials.
        "calendarAgenticCreateEnabled",
        "agentAskBeforeCreatingEventTypeTemplates",
        "mcpURL",

        // ── Personalization (Me / profile / share) ──
        "meDisplayName",
        "meAvatarHue",
        "meAvatarVersion",
        "meBackgroundTypes",
        "meReflectionLog",
        "calendarShareStyle",

        // ── Locale ──
        AppSettingsLocale.languageKey,
        AppSettingsLocale.timeFormatKey,

        // ── Time-zone freeze (correctness-critical for cross-device dayKey) ──
        //
        // BRIDGED (see `bridgedKeys`): the key stays on the wire — every device
        // must agree on which zone `dayKey` is derived in, which is the entire
        // reason it is synced — but the truth moved to
        // `OccurrenceKeyMetadataStore`. Reading it from `defaults` here would
        // upload the pre-migration value forever.
        CalendarOccurrenceKey.referenceTimeZoneDefaultsKey,
    ]

    private static let allowed: Set<String> = Set(allKeys)

    /// Keys whose value is a set carried as an array and merged by union
    /// across devices (design §6 user_settings 段). The local value is
    /// `Array(Set)`, whose order changes from process to process.
    static let unionKeys: Set<String> = ["skillAnalyzedEventIds"]

    /// The form a settings blob is hashed and sent in: every union key's
    /// array sorted. Without it, devices holding the same set in different
    /// orders each read the other's value as a change and PATCH their orders
    /// back and forth forever; sorted, the orders cannot differ and the
    /// exchange settles. A value that is not an array of strings is left as
    /// it is. The local `UserDefaults` value is not rewritten.
    static func canonicalForm(_ blob: [String: Any]) -> [String: Any] {
        var out = blob
        for key in unionKeys {
            if let ids = blob[key] as? [String] { out[key] = ids.sorted() }
        }
        return out
    }

    /// Keys that are still SYNCED under their historical name but no longer
    /// LIVE in `UserDefaults`. Each is read and written through its durable
    /// owner instead, so the settings blob keeps carrying the same key while
    /// the truth moved to a file.
    ///
    /// Bridging rather than dropping the key is what keeps a device on the old
    /// build and a device on the new one exchanging the same blob: the wire
    /// format never changed, only where this side reads it from.
    private static let bridgedKeys: Set<String> = [
        EventTypeTemplateStore.colorHistoryKey,
        CalendarOccurrenceKey.referenceTimeZoneDefaultsKey,
    ]

    /// Read all synced keys from UserDefaults into a JSON-safe dictionary.
    /// Missing keys are omitted so the blob stays compact. The keys in
    /// `allKeys` are all `Bool` / `Int` / `Double` / `String` / `Date`, all of
    /// which survive the `JSONSerialization` round trip (`Date` via the
    /// `sanitize` helper). If a future key uses `Data` or a non-JSON-native
    /// type, extend `sanitize` to handle it — `JSONSerialization` rejects
    /// `Data` and would silently fail the upload at the catch in `syncSettings`.
    static func currentSnapshot(_ defaults: UserDefaults = .standard) -> [String: Any] {
        var dict: [String: Any] = [:]
        for key in allKeys {
            if bridgedKeys.contains(key) {
                if let value = bridgedValue(key, defaults) { dict[key] = value }
                continue
            }
            guard let raw = defaults.object(forKey: key) else { continue }
            dict[key] = sanitize(raw)
        }
        return dict
    }

    /// Read a bridged key from its durable owner. Absent (or empty) is omitted
    /// from the blob, exactly as a missing `UserDefaults` key would be.
    ///
    /// An UNREADABLE owner also lands here as nil — it has nothing to report —
    /// and that nil is indistinguishable from "the user has no history yet".
    /// The blob cannot express the difference (see `hasUnreadableBridgedOwner`),
    /// so the fix is upstream: the upload is suppressed rather than sent with
    /// the key silently missing.
    private static func bridgedValue(_ key: String, _ defaults: UserDefaults) -> Any? {
        switch key {
        case EventTypeTemplateStore.colorHistoryKey:
            let history = EventTypeCatalog.forDefaults(defaults).colorHistory
            return history.isEmpty ? nil : history
        case CalendarOccurrenceKey.referenceTimeZoneDefaultsKey:
            // `establishedIdentifier`, NOT `referenceTimeZone`: reading the
            // latter freezes a zone on first access, and this runs on every
            // settings upload and every local snapshot. A device that had not
            // yet drawn a calendar would freeze — and then broadcast — whatever
            // zone it happened to be in at sync time. `object(forKey:)` did not
            // write, and neither may this.
            return OccurrenceKeyMetadataStore.forDefaults(defaults).establishedIdentifier
        default:
            return nil
        }
    }

    /// A bridged key's durable owner could not be READ.
    ///
    /// This is not a nicety. `user_settings` is one row per user and
    /// `syncSettings` upserts the WHOLE blob — there is no per-key diff — so a
    /// key missing from the blob DELETES the cloud's copy of it. A frozen
    /// color-history file empties `colorHistory` in memory, `bridgedValue`
    /// then omits the key, and the next unrelated settings write (any
    /// `UserDefaults.didChangeNotification`, 5 s later) would erase the cloud's
    /// history — at precisely the moment the cloud was one of the two
    /// surviving copies. Callers that upload the blob must consult this first;
    /// it is the settings-shaped half of the judgement
    /// `eventTypeExportSuppressed` already encodes for the templates.
    static func hasUnreadableBridgedOwner(_ defaults: UserDefaults = .standard) -> Bool {
        if EventTypeCatalog.forDefaults(defaults).isColorHistoryFrozen { return true }
        // The frozen time zone reaches the same conclusion from the opposite
        // direction: it always has SOMETHING to serve, so the danger is not an
        // omitted key but a wrong one. When the local file is unreadable (or
        // holds an identifier this system does not know) the value being served
        // is a guess, and the cloud is holding the answer — so neither omitting
        // the key nor uploading the guess is acceptable, and the whole blob
        // waits.
        return OccurrenceKeyMetadataStore.forDefaults(defaults).suppressesSettingsUpload
    }

    /// Write a bridged key back to its durable owner. A frozen owner refuses
    /// and says so by returning false; the caller does NOT fall back to
    /// `UserDefaults`, because two writable copies of one fact is the bug this
    /// migration exists to remove.
    @discardableResult
    private static func applyBridged(_ key: String, _ value: Any?, _ defaults: UserDefaults) -> Bool {
        switch key {
        case EventTypeTemplateStore.colorHistoryKey:
            let history = (value as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            return EventTypeCatalog.forDefaults(defaults).setColorHistory(history)
        case CalendarOccurrenceKey.referenceTimeZoneDefaultsKey:
            // A restore is allowed to overwrite an established — even a
            // frozen — zone: agreeing with the other devices on which zone
            // `dayKey` is derived in is the entire reason this key is synced.
            //
            // An ABSENT value is a no-op, not a clear (see
            // `applyRestoredIdentifier`). This deviates from the generic
            // "keys not in the blob are cleared" rule of `replace`, on purpose:
            // clearing an established zone lets the next access freeze wherever
            // the device happens to be, while every restored occurrence record
            // keeps a `dayKey` derived under the old one. A snapshot that does
            // not carry the key is silent about the zone, not an instruction to
            // forget it.
            return OccurrenceKeyMetadataStore.forDefaults(defaults)
                .applyRestoredIdentifier(value as? String)
        default:
            return false
        }
    }

    /// Whether a bridged key already holds something locally — the bridged
    /// equivalent of `defaults.object(forKey:) != nil`, which `.keepLocal`
    /// resolution turns on.
    private static func bridgedIsSet(_ key: String, _ defaults: UserDefaults) -> Bool {
        bridgedValue(key, defaults) != nil
    }

    /// Apply a settings blob to UserDefaults. Only writes keys in `allKeys`
    /// (defensive against server-side schema drift). Resolution decides
    /// whether to overwrite keys already set locally.
    static func apply(
        _ blob: [String: Any],
        resolution: ConflictResolution,
        to defaults: UserDefaults = .standard
    ) {
        for (key, value) in blob where allowed.contains(key) {
            if bridgedKeys.contains(key) {
                if bridgedIsSet(key, defaults) && resolution == .keepLocal { continue }
                applyBridged(key, value is NSNull ? nil : value, defaults)
                continue
            }
            let alreadySet = defaults.object(forKey: key) != nil
            if alreadySet && resolution == .keepLocal { continue }
            if value is NSNull {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Force-replace local UserDefaults with the cloud blob (used by the
    /// `cloudOverwritesLocal` restore strategy). Keys not in the blob are
    /// cleared so the result is exactly the cloud snapshot.
    static func replace(with blob: [String: Any], to defaults: UserDefaults = .standard) {
        for key in allKeys where !bridgedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
        // Bridged keys are cleared through their owner in the same pass that
        // sets them, so a frozen owner refuses BOTH halves rather than
        // clearing and then failing to restore.
        for key in bridgedKeys where blob[key] == nil || blob[key] is NSNull {
            applyBridged(key, nil, defaults)
        }
        for (key, value) in blob where allowed.contains(key) {
            if value is NSNull { continue }
            if bridgedKeys.contains(key) {
                applyBridged(key, value, defaults)
                continue
            }
            defaults.set(value, forKey: key)
        }
    }

    /// The remote applier's write (design §6 user_settings 段): `merged` is
    /// the per-key merge's result, `local` the snapshot it was merged from.
    /// Every key whose value changed is set (bridged keys through their
    /// owners), every key the merge dropped is removed. The reference-zone
    /// key is never written here — §6.2 decides it, before the merge runs —
    /// and an unknown key is ignored, as `apply` ignores it. "Changed" is
    /// judged on the outbound per-key hash, so a union set that only came
    /// back in another order is not rewritten. Returns the keys written and
    /// whether every write landed: a bridged owner that refused or failed its
    /// file write makes `landed` false (the other keys are still written).
    @discardableResult
    static func applyMerged(
        _ merged: [String: Any],
        over local: [String: Any],
        to defaults: UserDefaults
    ) -> (written: [String], landed: Bool) {
        let zoneKey = CalendarOccurrenceKey.referenceTimeZoneDefaultsKey
        let mergedHashes = SupabaseSyncService.settingsKeyHashes(merged)
        let localHashes = SupabaseSyncService.settingsKeyHashes(local)
        var written: [String] = []
        var landed = true
        for key in allKeys where key != zoneKey && mergedHashes[key] != localHashes[key] {
            let value = merged[key]
            if bridgedKeys.contains(key) {
                if !applyBridged(key, value, defaults) { landed = false }
            } else if let value, !(value is NSNull) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            written.append(key)
        }
        return (written, landed)
    }

    /// `JSONSerialization` rejects `Date`, so convert it to an ISO-8601 string.
    /// Everything else we sync is already JSON-native.
    private static func sanitize(_ value: Any) -> Any {
        if let date = value as? Date {
            return Self.iso.string(from: date)
        }
        return value
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - App Settings Keys
// Lives here (not ContentView) so UIKit-free targets compile it.

enum AppSettingsKeys {
    static let rememberLastTab = "generalRememberLastTab"
    static let appearanceMode = "generalAppearanceMode"
    static let defaultTab = "generalDefaultTab"
    static let lastSelectedTab = "generalLastSelectedTab"
    static let showTimerBanner = "generalShowTimerBanner"
    static let landscapeFocusMode = "workflowEnableLandscapeFocusMode"
    static let landscapeFocusKeepAwake = "workflowLandscapeFocusKeepAwake"
    static let analysisDefaultPeriod = "analysisDefaultPeriod"
    static let analysisAutoLoadSuggestions = "analysisAutoLoadSuggestions"
    /// When true, calendar event blocks are rendered with effort-based
    /// opacity: events without an effort log are drawn at medium opacity
    /// (~0.7), high-effort events are fully opaque, low-effort events are
    /// more transparent.  When false, all events render at full opacity.
    static let effortOpacityEnabled = "calendarEffortOpacityEnabled"
    /// Experimental: when ON, events can carry more than one event type and
    /// the calendar block color is a perceptual blend of those types' colors.
    /// This is a Labs feature; data is preserved when toggled off.
    static let experimentalMultiTypeEvents = "experimentalMultiTypeEvents"
    /// Experimental: maximum number of types (including the primary) allowed
    /// when `experimentalMultiTypeEvents` is on. Range 2...4.
    static let experimentalMultiTypeMaxCount = "experimentalMultiTypeMaxCount"

    /// Comma-separated list of header tool IDs to show exposed (not in "..." menu).
    /// Available IDs: "create", "search", "agent"
    /// Default: "create" (only create button exposed, rest in menu)
    static let calendarHeaderExposedTools = "calendarHeaderExposedTools"
    /// Comma-separated list of detail header tool IDs to show exposed.
    /// Available IDs: "add", "chat", "edit", "delete"
    /// Default: "add" (only add button exposed, rest in menu)
    static let detailHeaderExposedTools = "detailHeaderExposedTools"
    /// Persisted calendar view mode (day/threeDay/week).
    static let calendarLastRangeMode = "calendarLastRangeMode"
    /// Whether to restore the last used view mode on launch.
    static let calendarRememberViewMode = "calendarRememberViewMode"
    /// Timeline zoom, in points per hour, as the user last pinched it.
    /// Written by `CalendarViewState.commitTimelineHourHeight()`.
    ///
    /// Declared here rather than as a local literal in `CalendarViewState`
    /// because the erase sweep removes keys BY NAME from
    /// `resettableUserDefaultsKeys`, and a key whose only spelling lives
    /// inside the type that writes it cannot be put on that list without
    /// duplicating the string. It spent its whole life unswept for exactly
    /// that reason.
    static let calendarTimelineHourHeight = "calendar.timeline.hourHeight"
    /// When true, returning to the calendar tab resets to today's date.
    static let calendarAutoReturnToToday = "calendarAutoReturnToToday"
    /// When true, the Chinese 24 solar terms (二十四节气) are shown as
    /// lightweight labels on calendar dates. Default ON.
    static let holidaysShowSolarTerms = "calendarHolidaysShowSolarTerms"
    /// When true, common Gregorian-fixed holidays (元旦/劳动节/国庆节 …) are
    /// shown as lightweight labels on calendar dates. Default ON.
    static let holidaysShowGregorianHolidays = "calendarHolidaysShowGregorianHolidays"
    /// User-defined anniversaries, persisted as a JSON array string of
    /// `CustomAnniversary`. Shown as lightweight labels on their yearly
    /// month/day, like holidays. See `CalendarAnnotation.swift`.
    static let customAnniversaries = "calendarCustomAnniversaries"
    /// Comma-separated achievement IDs whose unlock has already been
    /// celebrated (confetti shown), so we only celebrate each badge once.
    static let celebratedAchievements = "meCelebratedAchievements"
    /// Cached AI-generated personality profile (JSON of `PersonalityProfile`),
    /// regenerated only on explicit refresh so we don't burn tokens per render.
    static let personalityProfile = "mePersonalityProfile"
    /// Whether the celebrated-achievements set has been seeded on first run.
    /// Prevents a confetti storm for badges earned before this feature shipped.
    static let achievementCelebrationSeeded = "meAchievementCelebrationSeeded"
    /// When true, drag-to-create snaps the new event's start/end to nearby
    /// existing event edges within an 8pt magnetic threshold. Designed for
    /// users who keep continuous back-to-back records; users who log
    /// non-aligned moments should turn it off.
    static let calendarAdjacentEventSnapEnabled = "calendarAdjacentEventSnapEnabled"
    /// Title font size (in points) used for text inside calendar event
    /// blocks. Time-range font scales proportionally. Default 12 matches
    /// the historical hard-coded value; clamped to 9...16 in the UI.
    static let calendarEventFontSize = "calendarEventFontSize"
    /// When true, the event time range renders below the title in event
    /// blocks whenever it geometrically fits. When false, time only shows
    /// in tall blocks (the legacy 88x42pt gate).
    static let calendarEventShowTimeBelowTitle = "calendarEventShowTimeBelowTitle"
    /// Number of days into the future that defines the "near future" zone —
    /// the user's processing capacity beyond NOW. Items inside this window
    /// are user-controlled (system never mutates their date); items beyond
    /// are in the "future" zone and subject to HORIZON-driven domino push-
    /// back when the horizon advances. Default 7. See `EventZone`.
    static let nearFutureHorizonDays = "calendarNearFutureHorizonDays"
    /// When true, tapping a type pill from focus mode's idle clock surfaces
    /// a brief preview ("entry ceremony") before creating the event — title
    /// can be edited, range can be confirmed, and the user crosses into the
    /// inhabiting state deliberately. When false, the type tap creates the
    /// event immediately (quick path).
    static let focusConfirmBeforeTracking = "focusConfirmBeforeTracking"
    /// Experimental: when true, the time axis (hour labels + now-time legend
    /// + drag-preview pills) is rendered through a CALayer-backed UIView
    /// instead of the SwiftUI `TimeAxisLabels` tree. Strictly parity-first;
    /// the SwiftUI path remains the default until A/B verification settles.
    /// See `TimeAxisLayerView.swift` (issue #60).
    static let calendarUseCALayerAxisMarkers = "calendarUseCALayerAxisMarkers"
    /// Experimental: when true, the event-detail mini-day timeline
    /// (`miniDayTimelineVisual` in `CalendarEventDetailView`) is rendered
    /// through a CALayer-backed UIView instead of the SwiftUI tree. Same
    /// strict-parity stance as `calendarUseCALayerAxisMarkers`; the SwiftUI
    /// path remains the default until A/B verification settles. See
    /// `MiniDayTimelineLayerView.swift` (issue #71).
    static let calendarUseCALayerMiniDayTimeline = "calendarUseCALayerMiniDayTimeline"
    /// Experimental: when true, the calendar's vertical timeline scroll
    /// uses a `UIScrollView`-backed host (`TimelineScrollHost`) instead of
    /// the SwiftUI `ScrollView`. The new host can atomically co-commit
    /// `contentSize` + `contentOffset` in a single `CATransaction`, so the
    /// boundary-extension close path (today covered by the
    /// `timelineCollapseDim` opacity dip) collapses without a 1-frame
    /// layout flash. Strict parity, default OFF until on-device A/B
    /// settles. See `TimelineScrollHost.swift` (issue #57).
    static let calendarUseUIScrollViewTimeline = "calendarUseUIScrollViewTimeline"

    /// Issue #57 / spec 07: when ON (and the UIScrollView timeline is also ON),
    /// single-day mode drives the day-layer with a 48h-CONSTANT coordinate
    /// model (12h leading + 24h + 12h trailing). Band open/close mutates only
    /// `contentInset`, never `contentSize` — removing the two-write-surface
    /// race the co-commit path papers over. The all-day pill row is pinned to
    /// the scroll frame top so the negative leading inset can hide the band
    /// without scrolling the pills off. Strict-parity, default OFF until
    /// on-device A/B settles. See `docs/calayer-rewrite/07-day-layer-imperative.md`.
    static let calendarUseImperativeDayLayer = "calendarUseImperativeDayLayer"

    // MARK: - Agent / LLM

    static let agentProvider = "agentProvider"
    static let agentAPIKey = "agentAPIKey"
    static let agentAskBeforeCreatingEventTypeTemplates = "agentAskBeforeCreatingEventTypeTemplates"
    /// When true, calendar forms can preselect a type while typing using
    /// existing event history and local heuristics, then ask AI after save.
    static let calendarAgenticCreateEnabled = "calendarAgenticCreateEnabled"
    /// Default LLM provider used by every service-layer read.
    static let agentProviderDefault = "claude"
    /// Experimental: when ON, the token-inference engine (hypothesis OS,
    /// Discussion #111) runs its LLM loop on every calendar event add/edit and
    /// log/feedback save. Default OFF: the engine's output currently has no UI
    /// surface (`TokenAnalysisAssembler.build` has no callers), while the loop
    /// was the dominant share of API spend — one agentic run per upcoming
    /// occurrence per event mutation. Deterministic bootstrap projections are
    /// still written when OFF, so learned-state sync/restore keep working.
    static let tokenInferenceLLMEnabled = "agentTokenInferenceLLMEnabled"
    /// Daily cache for the AI splash greeting: the text plus the `Date` it
    /// was generated. At most one automatic LLM call per day — later cold
    /// launches the same day reuse the cached text (fallback greetings are
    /// never cached). See #122.
    static let splashWelcomeMessage = "splashWelcomeMessage"
    static let splashWelcomeMessageDate = "splashWelcomeMessageDate"

    // MARK: - MCP

    /// Permanent MCP connector URL (with token) that lets external AI apps
    /// read this user's Done data.
    static let mcpURL = "mcpURL"
    /// `UIPasteboard.general.changeCount` at the moment the user tapped
    /// "Copy" on the MCP URL. Not a preference — the erase's only way to
    /// tell whether the system clipboard still holds that credential.
    ///
    /// A changeCount comparison rather than reading the clipboard back:
    /// reading `UIPasteboard.general.string` can raise iOS's "Allow Paste?"
    /// alert, and an erase is the worst possible moment for a modal that
    /// explains nothing. If the count still matches, nothing has replaced
    /// our string and clearing is safe; if it has moved, the URL is already
    /// gone from the clipboard and there is nothing to clear. The count
    /// resets across a device restart, which makes the comparison fail
    /// closed — we skip rather than clear a clipboard we no longer own.
    static let mcpURLPasteboardChangeCount = "mcpURLPasteboardChangeCount"

    /// Whether "erase all local data" should clear the system clipboard.
    ///
    /// A pure decision, deliberately separated from the `UIPasteboard` write
    /// it guards, for two reasons. The write itself cannot appear in a test —
    /// `DoneTests` runs inside Done.app and clearing the clipboard would
    /// clear the real one, on this device and, with Universal Clipboard, on
    /// the user's others. And a predicate that lives inline in a `private`
    /// view method can only ever be read as source; here each of its three
    /// conditions is a case a test can state.
    ///
    /// All three must hold: a connector URL exists (so there was something
    /// worth copying), a Copy was recorded (so the clipboard was ours at
    /// some point), and the count still matches (so nothing has replaced it
    /// since). Any mismatch means the credential is already gone from the
    /// clipboard, and the erase must not clear a clipboard it no longer owns.
    static func shouldClearPasteboardOnErase(
        defaults: UserDefaults,
        currentChangeCount: Int
    ) -> Bool {
        guard defaults.string(forKey: mcpURL)?.isEmpty == false else { return false }
        guard let recorded = defaults.object(forKey: mcpURLPasteboardChangeCount) as? Int
        else { return false }
        return recorded == currentChangeCount
    }

    // MARK: - Me profile

    static let meDisplayName = "meDisplayName"
    static let meAvatarHue = "meAvatarHue"
    /// Cache-buster bumped after each avatar image save so views that load
    /// `MeAvatarStore.load()` refresh without a stored equality check.
    static let meAvatarVersion = "meAvatarVersion"
    /// Comma-separated list of type names treated as background time
    /// (sleep / meals / commute) — counted in totals but excluded from
    /// identity visuals on the Me tab.
    static let meBackgroundTypes = "meBackgroundTypes"
    /// Multi-line free-form reflection log persisted across launches.
    static let meReflectionLog = "meReflectionLog"
    /// Default background-types list when the user hasn't customized one.
    /// Mixes EN/中 names to cover both interface languages out of the box.
    static let meBackgroundTypesDefault = "Sleep,睡眠,睡觉,Rest,Eat,Meal,吃饭,Commute,Transit,通勤"

    // MARK: - Calendar share

    /// Raw value of `CalendarDailyShareStyle` chosen most recently from the
    /// daily share sheet.
    static let calendarShareStyle = "calendarShareStyle"

    // MARK: - Sync upload gate

    /// The master switch (design D9): when ON this device syncs both ways —
    /// it uploads its changes and pulls everyone else's. When OFF it does
    /// neither (restore from the cloud still works). Defaults to ON through
    /// `registerLaunchDefaults` — an unset key reads true, an explicit OFF
    /// stays OFF — and every interactive sign-in turns it on. Independent of
    /// the DEBUG safety net, which blocks uploads to production regardless.
    ///
    /// **DO NOT add to `SyncedSettings.allKeys`.** This key is per-device by
    /// design — syncing it to the cloud would let one device override another
    /// device's upload preference, which defeats the whole point of the toggle.
    static let syncUploadsEnabled = "syncUploadsEnabled"

    /// What an unset key reads as (design D9: sync is on by default). Only
    /// the registration domain: nothing is written, so a value the user
    /// set — the OFF they chose, the OFF the erase writes — stands.
    static let launchRegisteredDefaults: [String: Any] = [syncUploadsEnabled: true]

    /// Called once at launch, before any service reads the switch
    /// (sim QA round 2: a reinstall that found a session in the keychain
    /// read the unset key as OFF, and the device neither pulled nor pushed).
    static func registerLaunchDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: launchRegisteredDefaults)
    }

    static let resettableUserDefaultsKeys: [String] = [
        agentProvider,
        agentAPIKey,
        calendarAgenticCreateEnabled,
        agentAskBeforeCreatingEventTypeTemplates,
        rememberLastTab,
        appearanceMode,
        defaultTab,
        lastSelectedTab,
        showTimerBanner,
        landscapeFocusMode,
        landscapeFocusKeepAwake,
        analysisDefaultPeriod,
        analysisAutoLoadSuggestions,
        effortOpacityEnabled,
        experimentalMultiTypeEvents,
        experimentalMultiTypeMaxCount,
        calendarAdjacentEventSnapEnabled,
        calendarEventFontSize,
        calendarEventShowTimeBelowTitle,
        nearFutureHorizonDays,
        focusConfirmBeforeTracking,
        calendarUseCALayerMiniDayTimeline,
        calendarUseUIScrollViewTimeline,
        calendarUseImperativeDayLayer,
        // Me-tab achievement-celebration state. Resettable so corruption
        // (e.g. empty celebrated set + seeded=true, which replays every
        // unlocked badge as new) has a local escape hatch. Deliberately NOT
        // in `SyncedSettings.allKeys`: syncing celebration state across
        // devices is a product decision nobody has made — don't add it
        // there without that decision.
        celebratedAchievements,
        achievementCelebrationSeeded,
        // AI-derived caches (gh#217). Each is generated FROM the user's own
        // event data, so a "Reset all local data" that erases the source must
        // erase the derivative too — otherwise a personality profile / greeting
        // describing the just-erased data survives the reset. None of these is
        // in `SyncedSettings.allKeys`, and none has an owning store with its
        // own reset path (unlike `skillInsights`, which
        // `SkillInsightStore.clearAll()` clears in the same reset flow), so
        // this list is their ONLY exit.
        personalityProfile,
        splashWelcomeMessage,
        splashWelcomeMessageDate,
        // gh#234. Set when a terminal refresh failure signed this device out;
        // it drives an explanatory banner on the sign-in page. A wiped device
        // that came back still showing a banner about a session that no
        // longer exists in any sense would be its own small bug, and the
        // sweep only removes keys it is told by name.
        AuthService.needsReauthKey,
        // gh#249. The session's LEGACY location; it now lives in the Keychain,
        // which this sweep cannot reach. The live session is ended by
        // `AuthService.signOut()` in the same reset flow — the one write point
        // that deletes the Keychain item, this key, and the in-memory copy.
        // Listing the key here is for the copy an interrupted migration may
        // have left behind, which a sweep that only knows names would miss.
        AuthService.sessionDefaultsKey,
        // gh#258. Found by the review of the snapshot deletion: the DR
        // snapshot was only the courier. These six survived "erase all local
        // data" on their own, and the rewritten snapshot carried them back
        // because it reads `SyncedSettings.currentSnapshot`.
        //
        // `mcpURL` is the serious one and is not merely user data: its own
        // declaration above calls it a permanent connector URL WITH TOKEN
        // that lets external AI apps read this user's Done data. Left behind,
        // an erased device keeps a live third-party read credential on disk,
        // in a backed-up location.
        //
        // ⚠️ Removing the key does NOT revoke anything. The `api_keys` row
        // lives server-side and stays valid, so anyone already holding the
        // URL keeps access — and the user can no longer see it here to
        // revoke it. "Reset all" is local-scoped by name (see the uploads
        // flag at the top of `resetAllLocalData`), so revocation is a
        // separate decision, not something to smuggle in here. Tracked
        // separately; do not read this line as "the credential is dead".
        mcpURL,
        // Me-tab identity and content. `meReflectionLog` is free-form user
        // writing; all five are in `SyncedSettings.allKeys`, which is this
        // project's own classification of what counts as user data.
        meDisplayName,
        meAvatarHue,
        meAvatarVersion,
        meBackgroundTypes,
        meReflectionLog,
        // gh#265's census found this one before the census was even finished:
        // its own declaration says "User-defined anniversaries, persisted as a
        // JSON array string" — user-AUTHORED content, not a preference, and it
        // was surviving the erase.
        customAnniversaries,
        // Calendar view state the user set by hand. The sweep already takes
        // `appearanceMode`, `defaultTab` and `lastSelectedTab`, so remembered
        // UI state is in scope here by this list's own precedent; these three
        // were omissions, not exclusions.
        //
        // `calendarTimelineHourHeight` is the one a review caught. Both
        // censuses were blind to it and one of them actively certified it as
        // covered — it is a bare string literal on a `private let` inside
        // `CalendarViewState`, reachable by neither a path scan nor an
        // `AppSettingsKeys` scan. That is the finding that retired the census
        // in favour of a registry.
        calendarTimelineHourHeight,
        calendarLastRangeMode,
        calendarRememberViewMode,
        // The rest of this list's own declarations. Round 2's QA counted
        // them: 50 `static let`s here, two of which are default *values*
        // (`agentProviderDefault`, `meBackgroundTypesDefault`) and one of
        // which the erase deliberately SETS rather than removes
        // (`syncUploadsEnabled`) — leaving eight keys this file declares and
        // never swept. Six are the same shape as the three above, so the
        // precedent argument that admitted those admits these; adding only
        // the three a review happened to be looking at is how this list has
        // failed six times. `calendarUseCALayerAxisMarkers` is the sharpest:
        // its three sibling render flags are all on the list and it was not.
        calendarHeaderExposedTools,
        detailHeaderExposedTools,
        calendarAutoReturnToToday,
        holidaysShowSolarTerms,
        holidaysShowGregorianHolidays,
        calendarUseCALayerAxisMarkers,
        tokenInferenceLLMEnabled,
        calendarShareStyle,
        // Declared in `AppSettingsLocale`, not here, which is the only
        // reason they were missed: `appearanceMode` is swept, and the
        // interface language and clock format the user chose are the same
        // kind of fact about them. Both are read fresh from
        // `UserDefaults.standard` on every access (`AppLanguage.current`,
        // `AppTimeFormat.current`), so there is no live owner to tell —
        // unlike `calendarState` and `authService` above.
        AppSettingsLocale.languageKey,
        AppSettingsLocale.timeFormatKey,
        // Bookkeeping for the clipboard clear in `resetAllLocalData`, which
        // reads it just before this sweep runs.
        mcpURLPasteboardChangeCount,
        // gh#257 (sim QA S6): "the account was erased on another device"
        // and what the user chose. Account state, so the erase ends it.
        SupabaseSyncService.accountGoneTableKey,
        SupabaseSyncService.accountGoneChoiceKey,
    ]

    /// The loop "Reset all local data" drives over `resettableUserDefaultsKeys`
    /// (see `DataPrivacySettingsView.resetAllLocalData()`). Kept next to the list and
    /// parameterized over `defaults` so tests can drive the production loop
    /// against a scoped suite: membership in the list is exactly what reset clears.
    static func removeResettableKeys(from defaults: UserDefaults) {
        for key in resettableUserDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
