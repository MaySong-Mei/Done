//
//  AccountView.swift
//  DoneMac
//
//  Sign-in and sync status. The engine is the shared SupabaseSyncService:
//  uploads are debounced automatically and the realtime doorbell pulls
//  other devices' changes, so "Sync now" only asks the puller for an
//  immediate pull. Google OAuth via the shared AuthService
//  (ASWebAuthenticationSession works natively on macOS; the callback
//  scheme is declared in Info.plist).
//

import SwiftUI

struct AccountView: View {
    // ObservableObject-era services: without @ObservedObject a completed
    // sign-in would never refresh this sheet (round-5 review #2).
    @ObservedObject var auth: AuthService
    @ObservedObject var sync: SupabaseSyncService
    @ObservedObject var status: SyncStatusReporter
    /// Opens the window-level erase confirmation (AccountSafetyModifier).
    var onResetAll: () -> Void
    var onDone: () -> Void
    @State private var isWarningBeforeSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account & Sync")
                .font(.title3.bold())
            if auth.isSignedIn {
                Text("Signed in · \(auth.userId ?? "?")")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                syncStatus
                HStack {
                    Button("Sync now") {
                        sync.inbound?.requestPull(reason: "mac-manual")
                    }
                    .disabled(status.structured.isActive)
                    Spacer()
                    Button("Sign out") {
                        // Design §6.6: undecided offers block the sign-out
                        // until the user confirms losing them.
                        if sync.hasUndecidedOffers {
                            isWarningBeforeSignOut = true
                        } else {
                            auth.signOut()
                        }
                    }
                    .syncUndecidedOffersWarning(isPresented: $isWarningBeforeSignOut,
                                                count: sync.pendingPromptCount,
                                                action: .signOut, syncService: sync) {
                        auth.signOut()
                    }
                }
            } else {
                Text("Sign in to sync with your iPhone and iPad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Sign in with Google") {
                    Task { await auth.signInWithGoogle() }
                }
                if let message = auth.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Divider()
            Button(L(.alertResetAllData), role: .destructive, action: onResetAll)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var syncStatus: some View {
        let channel = status.structured
        if channel.isActive {
            Text("Syncing…").font(.caption)
        } else if let error = channel.lastError {
            Text("Sync failed: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        } else if let at = channel.lastCompletedAt {
            Text("Last sync \(at.formatted(date: .omitted, time: .shortened))"
                 + (channel.detail.map { " — \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
