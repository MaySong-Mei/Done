//
//  AccountView.swift
//  DoneMac
//
//  Sign-in and sync controls. Google OAuth via the shared AuthService
//  (ASWebAuthenticationSession works natively on macOS; the callback
//  scheme is declared in Info.plist).
//

import SwiftUI

struct AccountView: View {
    let auth: AuthService
    let sync: MacSyncEngine
    var onDone: () -> Void

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
                        Task { await sync.syncNow(now: Date()) }
                    }
                    .disabled(sync.isBusy)
                    Spacer()
                    Button("Sign out") { auth.signOut() }
                }
            } else {
                Text("Sign in to pull your events from iPhone and push Mac edits back.")
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
        switch sync.phase {
        case .pulling: Text("Pulling…").font(.caption)
        case .pushing: Text("Pushing…").font(.caption)
        case .failed(let message):
            Text("Sync failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        case .idle:
            if let at = sync.lastSyncAt {
                Text("Last sync \(at.formatted(date: .omitted, time: .shortened)) — \(sync.lastSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .signedOut: EmptyView()
        }
    }
}
