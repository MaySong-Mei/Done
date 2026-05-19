import Foundation

/// Canonical list of `UserDefaults` keys that we sync to Supabase as part of
/// disaster-recovery / cross-device restore. Anything not listed here is
/// considered per-device transient state.
///
/// Keep this list aligned with `AppSettingsKeys` + the misc `@AppStorage`
/// keys used directly by views. Adding a key here automatically opts it into
/// the sync — no schema migration needed (it's a JSON blob).
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
        AppSettingsKeys.analysisShowProfileSummary,
        AppSettingsKeys.analysisAutoLoadSuggestions,

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
        CalendarOccurrenceKey.referenceTimeZoneDefaultsKey,
    ]

    private static let allowed: Set<String> = Set(allKeys)

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
            guard let raw = defaults.object(forKey: key) else { continue }
            dict[key] = sanitize(raw)
        }
        return dict
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
        for key in allKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in blob where allowed.contains(key) {
            if value is NSNull { continue }
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
