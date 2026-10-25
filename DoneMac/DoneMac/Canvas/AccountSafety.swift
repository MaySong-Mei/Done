//
//  AccountSafety.swift
//  DoneMac
//
//  The account-safety prompts the iPhone's root view carries (gh#257, design
//  §6.6 / §10.7), on the Mac window: the account was erased on another
//  device (keep / upload into the next account / erase this Mac), a sign-in
//  held over another account's unsynced changes, the one recovery prompt
//  after a catch-up, and the erase confirmation — with the undecided-offers
//  warning in front of it, as on iOS. Same engine calls, same strings.
//

import SwiftUI

struct AccountSafetyModifier: ViewModifier {
    @ObservedObject var sync: SupabaseSyncService
    @ObservedObject var auth: AuthService
    /// Runs the shared erase, signed out (`keepingSession: false`).
    let erase: () -> Void
    @Binding var isConfirmingErase: Bool

    @State private var isPresentingAccountGoneChoice = false
    @State private var isWarningBeforeErase = false

    func body(content: Content) -> some View {
        content
            .onReceive(sync.$accountCheck) { check in
                if case .signedOut = check, sync.accountGoneChoice == nil {
                    isPresentingAccountGoneChoice = true
                }
            }
            .alert(L(.accountGoneTitle), isPresented: $isPresentingAccountGoneChoice) {
                // The design's three choices and no fourth; keeping the data
                // changes nothing, so it takes the cancel role (as on iOS).
                Button(L(.accountGoneKeepLocal), role: .cancel) {
                    sync.chooseAfterAccountGone(.keepLocalData)
                }
                Button(L(.accountGoneUploadNext)) {
                    sync.chooseAfterAccountGone(.uploadIntoNextAccount)
                }
                Button(L(.accountGoneErase), role: .destructive) {
                    sync.chooseAfterAccountGone(.eraseThisDevice)
                    isConfirmingErase = true
                }
            } message: {
                Text(L(.accountGoneBody))
            }
            .alert(L(.ownerSwitchConfirmTitle),
                   isPresented: Binding(get: { sync.heldSwitchAlert != nil },
                                        set: { if !$0 { sync.heldSwitchAlert = nil } }),
                   presenting: sync.heldSwitchAlert) { _ in
                Button(L(.ownerUnsyncedSwitchAnyway), role: .destructive) {
                    sync.switchAnyway()
                }
                Button(L(.cancel), role: .cancel) {
                    sync.deferSwitchUntilOwnerSyncs()
                    auth.signOut()
                }
            } message: { unsynced in
                Text(LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, unsynced))
            }
            .alert(L(.alertResetAllData), isPresented: $isConfirmingErase) {
                Button(L(.cancel), role: .cancel) {}
                Button(L(.reset), role: .destructive) {
                    // Design §6.6: undecided offers block the erase until the
                    // user confirms losing them.
                    if sync.hasUndecidedOffers {
                        isWarningBeforeErase = true
                    } else {
                        erase()
                    }
                }
            } message: {
                Text(L(.hintResetAllData))
            }
            .syncUndecidedOffersWarning(isPresented: $isWarningBeforeErase, count: sync.pendingPromptCount,
                                        action: .erase, syncService: sync) {
                erase()
            }
            // The one recovery prompt after a catch-up (design §6.6).
            .syncRecoveryPrompt(sync)
    }
}
