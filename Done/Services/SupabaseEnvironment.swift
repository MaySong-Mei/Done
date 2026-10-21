//
//  SupabaseEnvironment.swift
//  Done
//
//  Which Supabase project this process talks to. Design D8 as revised on
//  2026-10-21 (Docs/sync/00-realtime-sync-design.md): a staging project
//  exists now, the local `supabase start` stack is the test rig, and
//  production is the default everywhere a build could reach a user.
//
//  The selection is decided ONCE per process, on the first read of
//  `current`, and never changes afterwards: every client (`AuthService`,
//  `SupabaseREST`, the image storage, the doorbell) reads
//  `SupabaseSyncConfig.url` / `.publishableKey`, which forward here, and a
//  process that switched projects halfway would mix one project's session
//  with another's rows.
//

import Foundation

nonisolated enum SupabaseEnvironment: String, CaseIterable, Sendable {
    case production
    case staging
    case local

    var url: String {
        switch self {
        case .production: return "https://uqnvtzblppjblwgbpqhf.supabase.co"
        case .staging: return "https://gpxpvczmrezgzycypmsk.supabase.co"
        case .local: return "http://127.0.0.1:54321"
        }
    }

    /// The project's publishable key — the `apikey` header, which only
    /// names the project; the per-user JWT in `Authorization` is what RLS
    /// judges. Publishable keys are public by design and safe to commit
    /// (the service_role incident and its rotation checklist are gh#232).
    /// The local key is the CLI's fixed demo key, the one `supabase status`
    /// prints for every local stack.
    var publishableKey: String {
        switch self {
        case .production: return "sb_publishable_1Cd8-AKwVRLBI3RAmFziNg_guyoO3Cz"
        case .staging: return "sb_publishable_t0kVR9AnipT_UvzwEQNQxg_QMvYz3sQ"
        case .local: return "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
        }
    }

    var displayName: String {
        switch self {
        case .production: return "Production"
        case .staging: return "Staging"
        case .local: return "Local stack"
        }
    }

    // MARK: - Selection

    /// What the binary was compiled as. `Staging` is a build configuration
    /// of its own (a copy of Release with `STAGING` in the compilation
    /// conditions), so a staging binary is never also a DEBUG one.
    enum Build: Equatable, Sendable {
        case debug
        case release
        case staging
    }

    static let build: Build = {
        #if STAGING
        return .staging
        #elseif DEBUG
        return .debug
        #else
        return .release
        #endif
    }()

    /// The launch environment variable, also accepted as a launch argument
    /// of the same shape (`SYNC_ENV=local`). DEBUG only.
    static let launchVariable = "SYNC_ENV"

    /// The `UserDefaults` key consulted after the launch variable. DEBUG
    /// only. Deliberately NOT in `AppSettingsKeys.resettableUserDefaultsKeys`:
    /// it is a developer switch, not user content, and "reset all local
    /// data" in the middle of a harness run must not silently point the
    /// next launch at a different project.
    static let defaultsKey = "syncEnvironment"

    /// The selection rule, pure so a test can tabulate it:
    ///
    /// - a Staging build is `.staging`;
    /// - a Release build is `.production`;
    /// - a DEBUG build is `.production` unless overridden, in this order:
    ///   `SYNC_ENV` in the launch environment, `SYNC_ENV=<value>` among the
    ///   launch arguments, then the `syncEnvironment` defaults key. A value
    ///   that is not `local` / `staging` / `production` is treated as
    ///   absent, so an unknown value falls through to the default.
    ///
    /// Only the `.debug` branch reads any of the three sources; Release and
    /// Staging binaries cannot be steered at launch.
    static func resolve(
        build: Build,
        environment: [String: String],
        arguments: [String],
        defaults: UserDefaults?
    ) -> SupabaseEnvironment {
        switch build {
        case .staging:
            return .staging
        case .release:
            return .production
        case .debug:
            if let chosen = parse(environment[launchVariable]) { return chosen }
            let prefix = launchVariable + "="
            if let argument = arguments.first(where: { $0.hasPrefix(prefix) }),
               let chosen = parse(String(argument.dropFirst(prefix.count))) {
                return chosen
            }
            if let chosen = parse(defaults?.string(forKey: defaultsKey)) { return chosen }
            return .production
        }
    }

    private static func parse(_ raw: String?) -> SupabaseEnvironment? {
        guard let raw else { return nil }
        return SupabaseEnvironment(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Decided on first read, for the life of the process. The launch
    /// sources are handed over only in a DEBUG build; the other two builds
    /// resolve from the compilation condition alone.
    static let current: SupabaseEnvironment = {
        #if DEBUG
        let info = ProcessInfo.processInfo
        return resolve(build: build, environment: info.environment, arguments: info.arguments, defaults: .standard)
        #else
        return resolve(build: build, environment: [:], arguments: [], defaults: nil)
        #endif
    }()
}
