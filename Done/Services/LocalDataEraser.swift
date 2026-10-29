//
//  LocalDataEraser.swift
//  Done
//
//  Moved verbatim out of AgentSettingsView.swift so the Mac target runs the
//  same erase (account switch, "account erased elsewhere", reset). The
//  clipboard clear uses NSPasteboard on macOS.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The one local erase ("Reset all local data", design §6.4 擦除接线). Data &
/// Privacy runs it signed out; the account card's "switch to this account"
/// (gh#257: data belongs to its account) runs it keeping the session it is
/// switching to and then starts sync (`SupabaseSyncService.switchToCurrentAccount`).
/// One body for both, so a purge added for one is a purge for the other.
@MainActor
struct LocalDataEraser {
    let store: EventStore
    let skillStore: SkillInsightStore
    let agentRuntime: AgentRuntime
    let authService: AuthService
    let calendarState: CalendarViewState
    let syncService: SupabaseSyncService
    let imageBackupCoordinator: ImageBackupCoordinator
    let backupSnapshotService: BackupSnapshotService
    #if canImport(UIKit)
    /// gh#273: the telemetry uploader's in-memory state is the previous
    /// owner's too. Optional because the eraser is also built in contexts
    /// (and tests) that have no uploader. Phone-only: the uploader is
    /// UIKit-bound and the Mac uploads no statistics.
    var telemetryUploader: TelemetryUploader? = nil
    #endif

    func resetAllLocalData(keepingSession: Bool) {
        // FIRST — before the uploads flag, before any purge. Three paths in
        // this app await a network round trip and then write user content to
        // a backed-up directory; deleting files cannot stop a write that has
        // not happened yet. This marks the boundary those writers check on
        // their way back. See `LocalDataEraseEpoch`.
        LocalDataEraseEpoch.bump()

        // Disable uploads first. Without this, the debounced sinks fired
        // by the wipes below (EventStore @Published; and, for the keys that
        // still live in UserDefaults, didChangeNotification) would fire 2-5s
        // later, see canUpload
        // still true, hash now-empty rows against just-wiped hash maps,
        // and push an essentially-empty state to cloud — bulldozing the
        // user's existing cloud data right when they may want it preserved
        // for a future restore. "Reset all" is local-scoped by name; the
        // user re-enables uploads explicitly if they want fresh-cloud too.
        UserDefaults.standard.set(false, forKey: AppSettingsKeys.syncUploadsEnabled)

        store.clearAllLocalData()
        skillStore.clearAll()
        TokenInferenceRepository.shared.clearAll()
        agentRuntime.preferenceStore.clearRules()
        agentRuntime.preferenceStore.clearDecisionHistory()
        agentRuntime.eventTypeTemplateStore.resetToDefaults()

        let defaults = UserDefaults.standard
        // BEFORE the sweep, which removes both keys this reads.
        //
        // The MCP connector URL carries a live read token, and the Account
        // page has a Copy button whose whole purpose is to put it in the
        // system clipboard. Removing `mcpURL` from `UserDefaults` left the
        // credential one paste away — and, with Universal Clipboard, on the
        // user's other devices too. Cleared only when the clipboard still
        // holds our copy; see `mcpURLPasteboardChangeCount` for why this is
        // a counter comparison and not a read.
        #if canImport(UIKit)
        if AppSettingsKeys.shouldClearPasteboardOnErase(
            defaults: defaults,
            currentChangeCount: UIPasteboard.general.changeCount
        ) {
            UIPasteboard.general.items = []
        }
        #else
        if AppSettingsKeys.shouldClearPasteboardOnErase(
            defaults: defaults,
            currentChangeCount: NSPasteboard.general.changeCount
        ) {
            NSPasteboard.general.clearContents()
        }
        #endif
        AppSettingsKeys.removeResettableKeys(from: defaults)
        // The sweep just reset the interface language and clock format, and
        // `store.clearAllLocalData()` above stamped the widget's mirror of
        // both BEFORE the sweep, from the pre-erase values. The widget now
        // renders its chrome from that mirror (gh#239 F5), so without this
        // second flush an erased phone shows an English app beside a
        // Chinese "no events" widget until the next calendar save. The
        // payload hash includes both values, so this is one real write.
        store.flushWidgetSnapshotSync()
        // Sign out, not just clear the notice.
        //
        // `supabaseAuthSession` was the seventh store found surviving this
        // function. It was a JSON blob in `UserDefaults.standard` — so in
        // device and iCloud backup — holding `accessToken`, `refreshToken`,
        // `expiresAt` and `AuthUser { id, email, createdAt }`. It is in no
        // by-name list and matches no prefix scan, so an "erased" phone
        // handed to the next person showed them the previous owner's email
        // address in Me → Account, and the refresh token was still live:
        // "restore from cloud" pulled back every event this function had
        // just deleted. Exactly the shape the `mcpURL` comment in
        // `ContentView` describes — a live credential left on disk in a
        // backed-up location by the act that promises to remove it.
        //
        // gh#249 moved the session into the Keychain, which no `UserDefaults`
        // sweep reaches at all, and the live object holds a copy in memory.
        // Sign-out is the single write point that ends all three (Keychain
        // item, legacy `UserDefaults` key, in-memory session); a reset that
        // left any of them would come back signed in as the account whose
        // data it just erased. The legacy key stays on the sweep's list only
        // for the copy an interrupted migration may have left behind.
        //
        // The cloud side is deliberately untouched (this function is
        // local-scoped by name), so the cost is one sign-in, not any loss of
        // restore capability — and the sweep already removes
        // `hasOfferedAutoRestore.<userID>` below, which re-arms the restore
        // offer for exactly that next sign-in.
        //
        // `signOut()` subsumes `forgetReauthenticationNotice()`: it routes
        // through `clearSession(reason: .userInitiated)`, which nils the
        // published `session`, removes the session key, and removes
        // `authNeedsReauthentication` plus its `@Published` copy. That last
        // part is still load-bearing for gh#234 — the sweep above removes
        // that key by name, behind the live `AuthService`'s back, and
        // without telling the owner the re-auth card and the orange Me-tab
        // row survive the wipe until relaunch.
        //
        // `keepingSession` is "switch to this account" (gh#257): the session
        // on this phone is the account the user is switching TO, signed in a
        // moment ago; what is erased is the other account's data. Everything
        // else below runs the same.
        if !keepingSession {
            authService.signOut()
        }
        // The by-name sweep removes `calendar.timeline.hourHeight` and
        // `calendarLastRangeMode`, which this object holds in memory and
        // writes back — the zoom from a geometry pass, the range mode from
        // the next view-mode tap. Same rule as the sign-out above and the
        // coordinator below.
        calendarState.forgetPersistedViewState()
        // Sync diff-hash maps are keyed per-userId, so they aren't in the
        // static resettable list — wipe them with a prefix scan instead.
        SupabaseSyncService.wipeAllPersistedHashes()
        // The owner guard's copy beside the data (`owner.json`). The shelf's
        // wipe below removes its directory too; named here so the record
        // does not depend on where the shelf keeps its file.
        SyncOwnerRecord.production.remove()
        // "Erased on another device" and the choice: the sweep above took
        // the two keys; this ends the state the live engine holds, so the
        // account card does not keep describing data that is gone.
        syncService.forgetAccountGone()
        // The conflict shelf holds the losing versions of synced rows — the
        // user's own account data, in its own Application Support directory
        // that no prefix scan reaches.
        ConflictShelf.wipe()

        // Additional UserDefaults blobs that aren't in the static
        // resettable list but ARE user-owned state per the full-backup
        // audit. Missing these meant "Reset all" kept conversations /
        // avatar slot / log-template preferences / etc. across the reset.
        // The chat history moved to `AgentConversationRepository`; wipe the file
        // as well as the two legacy keys. Both removals belong to the same
        // "only place allowed to purge" rule as the event-type keys below: they
        // are the rollback net everywhere else, and here leaving them would let
        // a downgraded binary resurrect the conversations the user just erased.
        AgentConversationRepository.shared.wipe()
        defaults.removeObject(forKey: AgentConversationsStorageKey)
        defaults.removeObject(forKey: AgentConversationRepository.legacyMessagesKey)
        defaults.removeObject(forKey: EventLogTemplatePreferenceStore.storageKey)
        // The event types moved to `EventTypeCatalog`, and `resetToDefaults()`
        // above already wiped the files. These two removals are the ONLY place
        // in the app allowed to purge the legacy keys — everywhere else they
        // are left untouched as the rollback safety net. Here the opposite is
        // true: leaving them would let a downgraded binary resurrect the very
        // types the user just asked to erase.
        defaults.removeObject(forKey: EventTypeTemplateStore.storageKey)
        defaults.removeObject(forKey: EventTypeTemplateStore.colorHistoryKey)
        defaults.removeObject(forKey: "skillAnalyzedEventIds")
        // The frozen reference time zone is user data too — every occurrence
        // record's `dayKey` was derived in it, and those records were just
        // erased above. Wiping it is ALSO the only local exit from the store's
        // `.unusable` state, which otherwise suppresses every settings upload
        // and every local DR snapshot until a cloud restore happens to carry
        // the key. The legacy key falls under the same "only place allowed to
        // purge" rule as the event-type keys above: leaving it would let a
        // downgraded binary resurrect the zone the user just asked to erase.
        OccurrenceKeyMetadataStore.shared.wipe()
        defaults.removeObject(forKey: CalendarOccurrenceKey.referenceTimeZoneDefaultsKey)
        // Composer rescue drafts. These used to be written only on a scene
        // departure, so the slots were almost always empty at reset time;
        // now that they're written continuously while typing, any session
        // the user ever typed into leaves one behind — and surviving a
        // "reset all local data" it would resurface as a resume banner
        // carrying pre-reset content.
        CalendarComposerDraftStore.clear()
        CalendarEditDraftStore.clear()
        CalendarDetailComposerDraftStore.clear()
        // Per-user keys (prefix scan, same shape as wipeAllPersistedHashes):
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("lastSyncedAvatarVersion.") || key.hasPrefix("hasOfferedAutoRestore.") {
            defaults.removeObject(forKey: key)
        }
        // Two more per-user key families, handled here rather than added to
        // the scan above. (This comment used to say the scan "has two
        // prefixes and needed four", which was wrong twice: the scan still
        // has its original two, and counting every per-user family on the
        // device gives five — the two above, these two, and `syncHashes.`,
        // swept by `wipeAllPersistedHashes` earlier. The set is complete;
        // the sentence was arithmetic nobody could check.)
        //
        // These hold `<eventID>/<imageID>` pairs — the user's own event ids,
        // never pruned, in a backed-up domain — and survived the erase
        // completely:
        // per-user keys are not in the by-name list, and the scan did not
        // know about them. Told rather than swept here because the
        // coordinator keeps the same set in memory behind a dirty flag and
        // would write it back (the `forgetReauthenticationNotice` rule).
        imageBackupCoordinator.forgetConfirmedUploads()
        // Avatar file on disk (UserDefaults-only reset won't catch it).
        MeAvatarStore.delete()
        // The position is load-bearing (gh#258), but the constraint is
        // "after everything the snapshot READS", not "last" — five disk
        // purges follow it below and are none of its business. This comment
        // said "LAST" and went on saying it after those five were appended
        // directly underneath; the ordering assertion that actually holds
        // the line is
        // `testResetAllLocalDataCallsTheSnapshotWipeAfterTheStoreErasures`,
        // which compares this call's position against
        // `MeAvatarStore.delete()` and deliberately claims no more.
        //
        // What must precede it is every component of
        // `SnapshotComponents`: the event slots, event types, skills, agent
        // rules and decision history, the settings sweep, the conversation
        // repository, and the avatar bytes — that last one is why
        // `MeAvatarStore.delete()` sits immediately above and is the anchor.
        //
        // The local DR snapshot is a plaintext JSON of every slot plus event
        // types, skills, conversations and settings, and it lives in `Documents/`
        // precisely so iOS Device Backup — and so iCloud — picks it up. Every
        // erase above has to have happened first: `wipe()` rebuilds the
        // service's trigger subscriptions to discard the 30 s debounce that
        // this function's own store mutations just armed, and that rebuild
        // re-arms `attach`'s `dropFirst(5)`, which swallows the five
        // emissions the stores send on subscribe. Called any earlier, it
        // would swallow PRE-wipe values and let the wipe's own emissions
        // through to a write — recreating the file ~30 s later.
        //
        // Told, not deleted around: same rule as `forgetReauthenticationNotice`
        // above. The owner knows where its file is and what else has to
        // settle; this function does not.
        backupSnapshotService.wipe()
        // Disk copies the sweep above does not reach, each with its own
        // store and its own backed-up directory. Every one of these was
        // found by a REVIEW happening to look, not by anything in the tree
        // noticing.
        //
        // ⚠️ THAT IS STILL TRUE. Nothing here makes the next one fail on
        // arrival. A census test was written for this spot and withdrawn
        // (gh#266): it could only approximate "writes user data" by scanning
        // for syntax, it was defeated four review rounds running by a
        // storage medium its needles did not cover, and it ended up
        // CERTIFYING a key that really was unswept
        // (`calendar.timeline.hourHeight`, a bare literal on a private let).
        // A detector that emits false green is worse than none.
        //
        // The fix is a registry — an `ErasableLocalStore` the store conforms
        // to AT ITS POINT OF DEFINITION, so this list is derived instead of
        // remembered and "forgot to add it" becomes a compile error. gh#266.
        // Until then this block is maintained by hand and by review, and
        // `EraseDiskWitnessQATests` only witnesses that the calls below do
        // what they say — not that the list is complete.
        //
        // gh#260 — attached event/log photos. `Library/Application Support/
        // AgenticIntakeAssets/`, deliberately backed up per the store's own
        // doc. The window was erase → next launch's background sweep, not
        // forever: an earlier comment here said the sweep refuses
        // permanently post-erase, and it does not — the wiped slots are
        // seeded, so the arrays are not empty. See `removeAllAssets`.
        AgenticIntakeAssetStore().removeAllAssets()
        // gh#263 — contact avatars. Must come AFTER `store.clearAllLocalData()`
        // for correctness of the erase, but note the cost of that order: it
        // destroys `Person.avatarImageName` first, which is the only thing
        // that said which JPEG belonged to whom. Photographs of other people,
        // so leaving them unidentifiable was worse than leaving them.
        PersonAvatarStore.removeAll()
        // gh#261 — reports. Same `Documents/` directory, so the same backup
        // path as the snapshot above. Carries `userNote`: the user's own words.
        ReportStore().wipe()
        // gh#263 — per-day/model activity counters. `clearAll()` already
        // existed but was wired only to a Developer-page button.
        LLMUsageStore.shared.clearAll()
        // gh#263 — spike run records, including user-entered notes.
        // `FixWatchView` tells the user these are backed up with the device.
        SpikeRunStore.wipe()
        // gh#273 — the uploader's memory of those files: status row, sample,
        // last outcome, throttle clock. Told, not reached around (the owner
        // knows its fields); the files themselves went with the wipe above.
        #if canImport(UIKit)
        telemetryUploader?.forgetAfterErase()
        // The resident observer's day in memory: its counters, open window
        // and daily id are the erased owner's, and its next flush would
        // write them back into the directory the wipe above just removed.
        // After the sign-out and the uploader's reset, because it mints the
        // next id under the owner that holds from here on. Phone-only: the
        // Mac has no resident observer.
        ResidentObservationCenter.shared?.forgetAfterErase()
        // Manual spike runs armed from the Developer page: each began before
        // the erase, and its closing record would carry its pre-erase id and
        // gestures. The store refuses that record whatever happens here
        // (`SpikeRun.eraseEpoch`); this ends the run, so the page does not
        // keep showing one that will never be written. Phone-only, like the
        // runners.
        SpikeSessionCoordinator.shared?.forgetAfterErase()
        #endif
        // Round 2. MetricKit payloads in `Diagnostics/MetricKit/` and the
        // legacy `Documents/Diagnostics` pile. `DiagnosticTrail.clear()`
        // already empties the trail in the same directory and left this
        // sibling folder standing — see `MetricPayloadStore.wipe`.
        MetricPayloadStore.standard().wipe()
    }
}
