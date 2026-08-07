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
///   - `supabaseAuthSession` — current device's Supabase session JWT.
///     Per-device (each device signs in independently). See `AuthService`.
///   - `calendar.timeline.hourHeight` — pinch-to-zoom remembered cell
///     height. Per-device because screen sizes differ.
///   - `verboseImageLogging` — debug toggle for noisy image-upload logs.
///     Per-device because it's a developer affordance, not a preference.
enum SyncedSettings {
    static let allKeys: [String] = [
        // ── General / tab behavior ──
        AppSettingsKeys.rememberLastTab,
        AppSettingsKeys.defaultTab,
        AppSettingsKeys.lastSelectedTab,
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
