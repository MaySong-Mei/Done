//
//  SupabaseSyncService+AccountGone.swift
//  Done
//
//  Design §10.7 (2026-10-19, "让用户选择"), §6.4 终态之后: the account was
//  erased on another device — detected by a `user_id` foreign-key 23503 and
//  a forced token refresh that came back terminal (`accountCheck ==
//  .signedOut`). After that the engine syncs nothing (the session is gone)
//  and deletes nothing. The user is asked, once, to choose between three
//  outcomes; until they do, local data stays exactly as it is. Every
//  outcome reuses an existing path. The terminal state and the choice are
//  persisted (`accountGoneTableKey` / `accountGoneChoiceKey`), so a relaunch
//  shows the same card — and the prompt again while nothing was chosen —
//  with (c) still reachable from it (QA S6 found the card gone after a
//  relaunch). The next sign-in and the erase clear both.
//

import Foundation

/// The three outcomes of design §10.7.
enum SyncAccountGoneChoice: String, Equatable {
    /// (a) Keep the data on this device and do not sync it. Nothing
    /// happens: the owner guard (S5) keeps standing, so signing in with a
    /// new account is blocked until the user adopts explicitly.
    case keepLocalData
    /// (b) Erase this device. The UI runs the existing erase
    /// (`resetAllLocalData()`), which clears the owner key with the rest of
    /// the `syncHashes.` prefix; the choice itself removes nothing.
    case eraseThisDevice
    /// (c) Sign in to a new account and upload this device's data into it.
    /// The owner key is cleared now, so the next sign-in takes ownership and
    /// its first flush uploads — the S5 adopt action, chosen in advance.
    case uploadIntoNextAccount
}

extension SupabaseSyncService {
    /// Whether the terminal state is standing and the user has not chosen.
    /// The app presents the three-way prompt while this is true.
    var awaitsAccountGoneChoice: Bool {
        guard case .signedOut = accountCheck else { return false }
        return accountGoneChoice == nil
    }

    /// Record the user's choice. Only meaningful in the terminal state;
    /// otherwise ignored, so a stale prompt cannot clear the owner guard.
    func chooseAfterAccountGone(_ choice: SyncAccountGoneChoice) {
        guard case .signedOut = accountCheck else { return }
        accountGoneChoice = choice
        defaults.set(choice.rawValue, forKey: Self.accountGoneChoiceKey)
        switch choice {
        case .keepLocalData, .eraseThisDevice:
            break
        case .uploadIntoNextAccount:
            SyncOwnerGuard.clearOwner(defaults)
        }
        DiagnosticTrail.record("Sync", "sync.account.gone choice=\(choice.rawValue)")
        // Answered while already signed in to the next account (the prompt
        // comes back over a blocked sign-in when it was never answered): that
        // account is the next one, so the data goes into it now.
        if choice == .uploadIntoNextAccount, case .blocked = ownerState {
            adoptLocalDataForCurrentAccount()
        }
    }
}
