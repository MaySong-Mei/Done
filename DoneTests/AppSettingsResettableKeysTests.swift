//
//  AppSettingsResettableKeysTests.swift
//  DoneTests
//
//  Recoverability guard for the Me-tab achievement-celebration state.
//  The two celebration keys (`meCelebratedAchievements`,
//  `meAchievementCelebrationSeeded`) are in no cloud-restore path — they are
//  kept out of `SyncedSettings.allKeys` deliberately, because syncing
//  celebration state across devices is a product decision nobody has made —
//  so "Reset all local data" is the ONLY way to clear them if corrupted
//  (an empty celebrated set + seeded=true replays every unlocked badge as
//  new, 2.4s of confetti each). These tests pin that escape hatch.
//

import XCTest
@testable import Done

final class AppSettingsResettableKeysTests: XCTestCase {

    // MARK: - Membership (one test per key so a removed key names its victim)

    func testCelebratedAchievementsKeyIsResettable() {
        XCTAssertTrue(
            AppSettingsKeys.resettableUserDefaultsKeys
                .contains(AppSettingsKeys.celebratedAchievements),
            "meCelebratedAchievements left resettableUserDefaultsKeys — corrupted celebration state becomes unrecoverable (not synced, not reset)"
        )
    }

    func testAchievementCelebrationSeededKeyIsResettable() {
        XCTAssertTrue(
            AppSettingsKeys.resettableUserDefaultsKeys
                .contains(AppSettingsKeys.achievementCelebrationSeeded),
            "meAchievementCelebrationSeeded left resettableUserDefaultsKeys — corrupted celebration state becomes unrecoverable (not synced, not reset)"
        )
    }

    // MARK: - Membership: AI-derived caches (gh#217)

    func testPersonalityProfileKeyIsResettable() {
        XCTAssertTrue(
            AppSettingsKeys.resettableUserDefaultsKeys
                .contains(AppSettingsKeys.personalityProfile),
            "mePersonalityProfile left resettableUserDefaultsKeys — an AI personality profile derived from the just-erased events survives \"Reset all local data\" (not synced, no owning store, this list is its only exit)"
        )
    }

    func testSplashWelcomeMessageKeyIsResettable() {
        XCTAssertTrue(
            AppSettingsKeys.resettableUserDefaultsKeys
                .contains(AppSettingsKeys.splashWelcomeMessage),
            "splashWelcomeMessage left resettableUserDefaultsKeys — an AI greeting generated from pre-reset task counts (\"N active tasks\") survives \"Reset all local data\" and replays on next launch"
        )
    }

    func testSplashWelcomeMessageDateKeyIsResettable() {
        XCTAssertTrue(
            AppSettingsKeys.resettableUserDefaultsKeys
                .contains(AppSettingsKeys.splashWelcomeMessageDate),
            "splashWelcomeMessageDate left resettableUserDefaultsKeys — the daily-cache stamp for the AI greeting survives reset, so a same-day relaunch would treat any lingering greeting as fresh"
        )
    }

    // MARK: - Behaviour: the production reset loop clears seeded junk

    /// Seeds junk celebration state and drives `removeResettableKeys(from:)`,
    /// the exact loop `DataPrivacySettingsView.resetAllLocalData()` calls. The full
    /// `resetAllLocalData()` is a private method on a SwiftUI view with
    /// @EnvironmentObject store dependencies that wipes the host app's live
    /// data — not XCTest-drivable — so this extracted loop is the strongest
    /// reachable layer; the untested remainder is the one-line call site.
    /// Uses a scoped suite: DoneTests is a host-app bundle and must not wipe
    /// the live app's standard defaults.
    func testRemoveResettableKeysClearsCelebrationJunk() {
        let suiteName = "AppSettingsResettableKeysTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create scoped UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("junk-badge-1,junk-badge-2", forKey: AppSettingsKeys.celebratedAchievements)
        defaults.set(true, forKey: AppSettingsKeys.achievementCelebrationSeeded)
        XCTAssertNotNil(defaults.object(forKey: AppSettingsKeys.celebratedAchievements), "seed failed")
        XCTAssertNotNil(defaults.object(forKey: AppSettingsKeys.achievementCelebrationSeeded), "seed failed")

        AppSettingsKeys.removeResettableKeys(from: defaults)

        XCTAssertNil(
            defaults.object(forKey: AppSettingsKeys.celebratedAchievements),
            "reset loop left celebrated-achievements junk behind"
        )
        XCTAssertNil(
            defaults.object(forKey: AppSettingsKeys.achievementCelebrationSeeded),
            "reset loop left celebration-seeded junk behind"
        )
    }

    // MARK: - Behaviour: the production reset loop clears AI-derived caches (gh#217)

    /// Seeds the three AI-derived caches with recognizable pre-reset content
    /// and drives `removeResettableKeys(from:)`, the loop
    /// `resetAllLocalData()` calls. Same scoped-suite rationale as the
    /// celebration test above: DoneTests is a host-app bundle and must not
    /// touch the live app's standard defaults.
    func testRemoveResettableKeysClearsAIDerivedCaches() {
        let suiteName = "AppSettingsResettableKeysTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create scoped UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            #"{"tags":["night owl","deep worker"]}"#,
            forKey: AppSettingsKeys.personalityProfile
        )
        defaults.set(
            "Good evening — 42 active tasks are waiting for you!",
            forKey: AppSettingsKeys.splashWelcomeMessage
        )
        defaults.set(Date(), forKey: AppSettingsKeys.splashWelcomeMessageDate)
        XCTAssertNotNil(defaults.object(forKey: AppSettingsKeys.personalityProfile), "seed failed")
        XCTAssertNotNil(defaults.object(forKey: AppSettingsKeys.splashWelcomeMessage), "seed failed")
        XCTAssertNotNil(defaults.object(forKey: AppSettingsKeys.splashWelcomeMessageDate), "seed failed")

        AppSettingsKeys.removeResettableKeys(from: defaults)

        XCTAssertNil(
            defaults.object(forKey: AppSettingsKeys.personalityProfile),
            "reset loop left the AI personality profile behind — it describes the just-erased events"
        )
        XCTAssertNil(
            defaults.object(forKey: AppSettingsKeys.splashWelcomeMessage),
            "reset loop left the AI splash greeting behind — it quotes pre-reset task counts"
        )
        XCTAssertNil(
            defaults.object(forKey: AppSettingsKeys.splashWelcomeMessageDate),
            "reset loop left the splash-greeting cache stamp behind"
        )
    }
}

// MARK: - QA hardening (reset-sweep-217 independent QA)

/// Adversarial-QA additions for the gh#217 sweep. Deliberately does NOT pin
/// any keep-classified key out of the resettable list: which keys a future
/// product decision sweeps in is not this suite's business, and a
/// NOT-contains pin would make that decision fail tests it never met.
final class ResetSweepQATests: XCTestCase {

    /// The gh#217 list comment claims the three AI-derived caches are "not in
    /// `SyncedSettings.allKeys`" — that claim is load-bearing (a synced key
    /// would be re-seeded by the next settings restore, making the reset a
    /// lie), so it gets an executable form instead of trusting the comment.
    /// `SyncedSettings.apply`/`replace` both filter on `allKeys`, so absence
    /// here is also proof restore cannot resurrect the wiped values.
    func testAIDerivedCacheKeysAreNotResurrectableBySettingsRestore() {
        for key in [
            AppSettingsKeys.personalityProfile,
            AppSettingsKeys.splashWelcomeMessage,
            AppSettingsKeys.splashWelcomeMessageDate,
        ] {
            XCTAssertFalse(
                SyncedSettings.allKeys.contains(key),
                "\(key) is reset-classified AND synced — the next settings restore re-seeds what reset just erased; pick one classification"
            )
        }
    }

    /// Whole-list behavioural coverage: every key in
    /// `resettableUserDefaultsKeys` — current and future — actually dies when
    /// the production loop runs. The per-key tests above cover named keys;
    /// this one means a key added to the list next year is behaviour-covered
    /// on arrival. (Iterates the list itself, so it can never wrongly pin a
    /// keep-key; membership pins are the per-key tests' job.)
    func testRemoveResettableKeysClearsEveryListedKey() {
        let suiteName = "ResetSweepQATests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create scoped UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for key in AppSettingsKeys.resettableUserDefaultsKeys {
            defaults.set("sentinel.\(key)", forKey: key)
            XCTAssertNotNil(defaults.object(forKey: key), "seed failed for \(key)")
        }

        AppSettingsKeys.removeResettableKeys(from: defaults)

        for key in AppSettingsKeys.resettableUserDefaultsKeys {
            XCTAssertNil(
                defaults.object(forKey: key),
                "\(key) is in resettableUserDefaultsKeys but survived removeResettableKeys — the reset loop and the list disagree"
            )
        }
    }

    /// List hygiene: a duplicate entry is harmless at runtime (removeObject
    /// twice) but means two comments/rationales can drift over one key.
    func testResettableKeysHaveNoDuplicates() {
        let keys = AppSettingsKeys.resettableUserDefaultsKeys
        XCTAssertEqual(
            keys.count, Set(keys).count,
            "resettableUserDefaultsKeys contains duplicate entries"
        )
    }
}
