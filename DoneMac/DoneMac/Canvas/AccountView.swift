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
import AuthenticationServices

struct AccountView: View {
    // ObservableObject-era services: without @ObservedObject a completed
    // sign-in would never refresh this sheet (round-5 review #2).
    @ObservedObject var auth: AuthService
    @ObservedObject var sync: SupabaseSyncService
    @ObservedObject var status: SyncStatusReporter
    /// Opens the window-level erase confirmation (AccountSafetyModifier).
    var onResetAll: () -> Void
    /// The shared erase keeping this session, then a fresh sync of it —
    /// `SupabaseSyncService.switchToCurrentAccount` (the iPhone's card).
    var onSwitchToThisAccount: () -> Void
    /// Closes this sheet and brings the recovery prompt back once it is gone.
    var onShowRecovery: () -> Void
    var onDone: () -> Void
    @State private var isWarningBeforeSignOut = false
    /// The raw nonce of the Apple request in flight; its SHA-256 goes to Apple.
    @State private var currentNonce: String?
    @State private var adoptConfirmationCount: Int?
    @State private var switchConfirmationCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account & Sync")
                .font(.title3.bold())
            if auth.isSignedIn {
                Text("Signed in · \(auth.userId ?? "?")")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if case .blocked = sync.ownerState {
                    ownerMismatchSection
                }
                syncStatus
                // The quiet badge of the recovery prompt (design §6.6): offers
                // not yet decided, across relaunches — the way back to the
                // prompt after "Later". The sheet closes first so the prompt
                // is not requested under it.
                if sync.pendingPromptCount > 0 {
                    Button {
                        onShowRecovery()
                    } label: {
                        Label(LCount(.syncPendingWriteBackFormat, one: .syncPendingWriteBackOne, sync.pendingPromptCount),
                              systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                }
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
                SignInWithAppleButton(.signIn) { request in
                    let nonce = AuthService.randomNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.email]
                    request.nonce = AuthService.sha256(nonce)
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .frame(height: 30)
                .disabled(auth.isLoading)
                Button("Sign in with Google") {
                    Task { await auth.signInWithGoogle() }
                }
                .disabled(auth.isLoading)
                if let message = auth.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Divider()
            Button(L(.resetAllData), role: .destructive, action: onResetAll)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// The iPhone's owner-mismatch card (gh#257, design §10.7): this Mac holds
    /// another account's data. Without it, "Keep" in the account-erased alert
    /// followed by a new sign-in would leave the Mac blocked with no way out
    /// (review 2026-10-24 #4).
    @ViewBuilder
    private var ownerMismatchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ownerMismatchBodyText, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                // Only for data whose account was erased elsewhere (design
                // §10.7 (c)); while that account exists its rows cannot land
                // in this one.
                if sync.canAdoptLocalData {
                    Button(L(.ownerMismatchAdopt)) {
                        adoptConfirmationCount = sync.localIdRowCount
                    }
                }
                if unsyncedChangesHeld {
                    Button(L(.ownerUnsyncedSwitchAnyway), role: .destructive) {
                        sync.switchAnyway()
                    }
                    Button(L(.cancel)) {
                        sync.deferSwitchUntilOwnerSyncs()
                        auth.signOut()
                    }
                } else {
                    Button(L(.ownerMismatchSwitch)) {
                        switchConfirmationCount = sync.localIdRowCount
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .alert(L(.ownerAdoptConfirmTitle),
               isPresented: Binding(get: { adoptConfirmationCount != nil },
                                    set: { if !$0 { adoptConfirmationCount = nil } })) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.ownerAdoptConfirmAction)) {
                sync.adoptLocalDataForCurrentAccount()
            }
        } message: {
            Text(LCount(.ownerAdoptConfirmFormat, one: .ownerAdoptConfirmOne, adoptConfirmationCount ?? 0))
        }
        .alert(L(.ownerSwitchConfirmTitle),
               isPresented: Binding(get: { switchConfirmationCount != nil },
                                    set: { if !$0 { switchConfirmationCount = nil } })) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.ownerSwitchConfirmAction), role: .destructive) {
                onSwitchToThisAccount()
            }
        } message: {
            Text(LCount(.ownerSwitchConfirmFormat, one: .ownerSwitchConfirmOne, switchConfirmationCount ?? 0))
        }
    }

    /// The sign-in did not switch on its own: the owner still has changes
    /// not in the cloud. Not the "erased elsewhere" state.
    private var unsyncedChangesHeld: Bool {
        !sync.canAdoptLocalData && sync.ownerUnsyncedChanges != nil
    }

    private var ownerMismatchBodyText: String {
        if sync.canAdoptLocalData { return L(.ownerMismatchGoneBody) }
        if let unsynced = sync.ownerUnsyncedChanges {
            return LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, unsynced)
        }
        return L(.ownerMismatchBody)
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

    /// Same handling as the iPhone's AccountView: the identity token and the
    /// raw nonce go to Supabase; a user cancel is not an error.
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = credential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let nonce = currentNonce
            else {
                auth.errorMessage = "Failed to get Apple ID token"
                return
            }
            Task { await auth.signInWithApple(idToken: idToken, nonce: nonce) }
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                auth.errorMessage = error.localizedDescription
            }
        }
    }
}
