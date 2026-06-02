# Handoff — "Bind people / friend groups to events"

**Status:** Feature implemented end-to-end and **builds clean** (`** BUILD SUCCEEDED **`). Not yet smoke-tested in a full manual flow by the user. A few UI-polish items remain (see **Open items**).
**Branch:** `king-of-rubbish-bin`
**Date:** 2026-06-02
**Build:** `xcodebuild -project Done.xcodeproj -scheme Done -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -quiet build`

---

## What the feature does

An event can optionally bind **people** ("with whom"), so an event records what + when + with whom.

Product decisions (from the user, locked in):
- **People are app-local entities** — NOT synced from system Contacts.
- An event can have **zero / one / many** people.
- **Friend groups are quick-select templates** (e.g. Family, Coworkers). Picking a group **expands its current members into the event at bind time**; the group itself is NOT stored on the event, so editing the group later never rewrites past events' history.
- **Deleting a person = soft-archive** (`Person.isArchived`). Past events still resolve the name; the person just disappears from pickers/lists/group memberships. (User's exact words: deleted people should still be referenced normally on old events, just gone from the list.)
- The "With" row shows for **both events and todos** (the form is shared; field lives on the shared `Event`).
- UI surface for v1 = the **event editor "With" row + picker** and a **settings management page**. (Deferred surfaces below.)

---

## Files changed (7 modified, 3 new)

### New files (registered in `project.pbxproj`: PBXBuildFile + PBXFileReference + PBXGroup + PBXSourcesBuildPhase, IDs prefixed `PEOP…`)
- **`Done/Models/People.swift`** — `Person { id, name, colorName?, isArchived, createdAt }` (+ `availableColors`), `FriendGroup { id, name, memberIDs, colorName?, createdAt }`. Plain `Codable`/`Hashable`, `Foundation` only.
- **`Done/Views/Calendar/EventPeoplePickerView.swift`** — the picker sheet (List of people + groups, multi-select, inline "create new person"). Also defines **shared helpers reused elsewhere**: `enum PersonColor` (name→`Color` + stable fallback), `Person.displayColor`, `Person.initials`, `PersonAvatar`, `PersonChip`.
- **`Done/Views/Agent/PeopleSettingsView.swift`** — settings page to manage people (inline rename, trash=archive) and groups (`FriendGroupEditorView`: name + member multi-select + delete). Uses the `settingsPage`/`settingsCard`/`settingsHintCard`/`settingsDestructiveButton` helpers (never `Form`).

### Modified
- **`Done/Models/Event.swift`** — added `var peopleIDs: [UUID]?` threaded through all 5 touch points: property, `CodingKeys`, `init(from:)` (`decodeIfPresent`), memberwise `init(...)` param + assignment, `encode(to:)` (`encodeIfPresent`). Legacy data decodes as `nil`.
- **`Done/Models/EventStore.swift`** — mirrored the `todoLists` **local** persistence pattern for two new `@Published` collections:
  - `people: [Person]`, `friendGroups: [FriendGroup]`; storage keys `"people"` / `"friendGroups"`; wired into `load()` and `clearAllLocalData()`.
  - Save helpers `savePeople()` / `saveFriendGroups()`.
  - CRUD + lookups: `activePeople`, `person(id:)`, `people(for:)` (skips unknown ids), `addPerson(_:)`, `addPerson(named:colorName:)` (case-insensitive dedupe), `updatePerson`, `archivePerson` (soft-delete + strips from group memberships), `addFriendGroup`/`updateFriendGroup`/`deleteFriendGroup`.
- **`Done/Models/AppLocalization.swift`** — added `LKey` cases + en/zh strings: `withWhom, people, friendGroups, peopleAndGroups, selectPeople, addPerson, newPerson, newGroup, personNamePlaceholder, groupNamePlaceholder, members, noPeopleYet, managePeopleAndGroups`.
- **`Done/Views/Calendar/CalendarEventFormView.swift`** —
  - New `@State selectedPeopleIDs` + `showPeoplePicker`, new `initialPeopleIDs` init param.
  - New `peopleSection` ("With" row: header + "+ Add" glass button + `FlowLayout` of `PersonChip`s, `.sheet` → `EventPeoplePickerView`), inserted in `body` **between `typeSection` and `timeSection`**.
  - `CalendarEventFormData` gained `var peopleIDs: [UUID] = []`; wired into `toEvent()` and `apply(to:)` (empty → `nil`).
  - The Done button's `CalendarEventFormData(...)` now passes `peopleIDs: selectedPeopleIDs`.
  - **`kindSection` restyled** (per user request) from a `.segmented` Picker to a row matching the `Repeat` row: `Text("Kind").font(.headline)` + `Spacer()` + `Menu { Picker("", selection: $kind) } label: { Text(value).font(.subheadline).foregroundStyle(.primary) }` — label left, plain-text value right, no ⇅ chevron.
- **`Done/Views/Calendar/CalendarEventSheets.swift`** — `EditCalendarEventView` passes `initialPeopleIDs: event.peopleIDs ?? []` so edits don't drop bound people.

### Settings entry point
`AgentSettingsView.swift` (the settings **root**, `settingsPage(L(.settings))`) — added a `NavigationLink` to `PeopleSettingsView()` in the General/Calendar/Workflow card, summary `"<n> people • <m> groups"`.

---

## Why other edit paths are safe (don't re-break these)
- `EventGridSheets.swift` `EditEventView` uses a **different** form (`EventFormView` / its own form-data). Its `apply(to:)` starts from the existing `event` and never touches `peopleIDs`, so it **preserves** people automatically — intentionally left unchanged.
- The two `CalendarEventFormData(...)` builds in `CalendarEventDetailView.swift` (~3360, ~3530) and the one in `CalendarPageView.swift` (~3802) and `AgenticCalendarIntakeService.swift` (~56) are **creation/type-inference** sites for new events — default `peopleIDs: []` is correct there.

---

## Open items / TODO for next session

1. ~~Kind picker UI polish~~ **DONE** — `kindSection` now matches the `Repeat` row exactly: `HStack { Text("Kind").headline; Spacer; Menu { Picker } label: { Text(value).subheadline.primary } }`. Plain-text value, no ⇅ chevron. If the user still wants changes, get specifics.
2. **People picker / "With" row visual polish** — earlier the user called the form cards "ugly". Note: the flat-white look is the **existing `GlassCardView`** rendering in the iOS 26 *simulator* (glass/blur is simplified there) — verify on a real device before restyling. The "+ Add" pill + sheet is functional but a candidate for restyle if they want.
3. **Cloud sync gap (important)** — people & friendGroups are **local-only (UserDefaults)**. They are NOT in the Supabase backup/restore path (`RestoreSnapshot` in `Done/Services/SupabaseSyncService+Restore.swift`, `PerRowDecisions` in `RestoreCoordinator.swift`, `mergeByID`/`applyRestore` in `EventStore.swift`, and `RestoreSheet.swift`). They survive app relaunch but NOT a cloud restore / device migration. Wiring this needs server-side tables + mirroring the `todoLists` plumbing across all those files.
4. **Deferred display surfaces** (only the editor was in v1 scope):
   - Show bound people (avatars/initials) on the calendar `EventBlock`.
   - Show bound people in the event **detail** view (`CalendarEventDetailView`).
   - A "filter / view all events with this person" surface.
   `PersonAvatar` / `PersonChip` / `PersonColor` in `EventPeoplePickerView.swift` are ready to reuse for these.

---

## Quick orientation for the next Claude
- Event model + persistence pattern: `Done/Models/Event.swift`, `Done/Models/EventStore.swift` (mirror `todoLists` for any new local collection).
- New files must be added to `project.pbxproj` in 4 places (this repo uses explicit refs; existing `PEOP…` IDs show the format).
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`: any file using `@Published` must explicitly `import Combine`.
- Live SourceKit "Cannot find type 'Event'/'EventStore'…" diagnostics during edits are **cross-file index noise** in this project — trust `xcodebuild`, not the inline indexer.
- Related memory note: `memory/project_people_binding.md`.
