//
//  SupabaseCore.swift
//  Done
//
//  Platform-neutral Supabase seam (gh#219 DoneMac plan, B-6). Holds the
//  pieces both app targets need; SupabaseREST and the row codec join it
//  when the Mac sync phase lands. The key literal lives ONLY here so the
//  Stage-3 rotation (#28) is a one-file fix.
//

import Foundation

// MARK: - Configuration

enum SupabaseSyncConfig {
    nonisolated static let url = "https://uqnvtzblppjblwgbpqhf.supabase.co"
    /// Project key for the `apikey` HTTP header. As of Stage 2 of #28
    /// this is ONLY used to identify the Supabase project — the
    /// `Authorization` header now carries the per-user JWT, so RLS
    /// enforces row access.
    ///
    /// **TODO(Stage 3 of #28): rotation hazard.** This constant is
    /// misnamed: decoding the JWT shows `role: service_role`, valid
    /// until 2036. Stage 3 must:
    ///   1. Generate the project's actual `anon` key in the Supabase
    ///      dashboard.
    ///   2. Replace this string with that anon key + push a new app
    ///      build.
    ///   3. Wait until that build has propagated to ~all active
    ///      installs (TestFlight + AppStore release cohort).
    ///   4. ONLY THEN rotate the service_role key in the dashboard.
    ///      Rotating earlier leaves every pre-Stage-3 binary
    ///      permanently 401'd because the bundled key it sends in
    ///      `apikey` is rejected.
    ///   5. Coordinate same-time env-var rollover in `done-mcp`
    ///      backend (whose service_role key is from the same project).
    nonisolated static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjE2MzA5MiwiZXhwIjoyMDkxNzM5MDkyfQ.LUwM3Kq6UbPiPeucHfn5iKaNh1RhEY5X1dU61BRS4Ng"
    nonisolated static let debounceSeconds: TimeInterval = 2.0
}
