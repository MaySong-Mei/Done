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

## UI polish pass (done 2026-06-02, second session)

All of the people UI was iterated to match the app's design language (`feedback_ui_spec.md` — the UI spec is the ground truth; READ IT before any further UI work):
- **`GlassCardView` shadow removed** (`Components/GlassCardView.swift`) — was `.shadow(black 0.12, r12, y8)`; user wanted flatter. App-wide.
- **`kindSection`** restyled to the `Repeat` row pattern (`Menu { Picker } label: { Text }`).
- **`EventPeoplePickerView` fully rebuilt to card style** (no more system `List`): custom glass header (`GlassEffectContainer`, centered bold title + capsule buttons) via `.safeAreaInset(.top)` + `.toolbar(.hidden,…)`; hand-written search card (replaced `.searchable`); people shown as **`GlassCardView` cards grouped by FriendGroup** with a "Default" bucket; selection is a **leading circle** (`checkmark.circle.fill`/`circle`, size 22 / frame 24); group header has a select-all circle (leading); `Divider()` between header and rows and between rows; tap a person row → `PersonEditSheet`. Body text `.subheadline`, card titles `.headline` (per spec §1).
- **`PersonEditSheet`** also rebuilt to cards + custom header (name/photo card, Color card, Groups card single-select with leading circles, full-width red glass Delete button matching the form's `deleteSection`).
- **Single-group membership**: a person is in ≤1 group; `EventStore.groupID(forPerson:)` / `setGroup(_:forPerson:)` / `ungroupedPeople` enforce it. `FriendGroupEditorView` (settings) routes through `setGroup` too.
- **Avatar upload** — `Person.avatarImageName: String?`; images saved downscaled (256px JPEG) to `Application Support/PersonAvatars` via **`PersonAvatarStore`** (NSCache, fresh UUID filename per upload). `PhotosPicker` in `PersonEditSheet` (tap avatar; ✕ to remove). `PersonAvatar` shows the photo when present, else initials.
- **"With" row** in `CalendarEventFormView`: title + chips + a **plus-only** button on one line, **right-aligned, horizontally scrollable** (`ScrollView(.horizontal)` + `.defaultScrollAnchor(.trailing)`).
- **Calendar `EventBlock` badge** now shows bound people (top-right, photo or initials, gated `!isWeekMode`), padded to align with the title (`.padding(.top, insets.vertical)` / `.padding(.trailing, insets.leading)`).

## Open items / TODO for next session

1. **Cloud sync gap (important)** — people & friendGroups & avatar files are **local-only**. NOT in the Supabase backup/restore path (`RestoreSnapshot` in `SupabaseSyncService+Restore.swift`, `PerRowDecisions` in `RestoreCoordinator.swift`, `mergeByID`/`applyRestore` in `EventStore.swift`, `RestoreSheet.swift`). Survive app relaunch but NOT a cloud restore / device migration. Needs server-side tables + mirroring the `todoLists` plumbing (and a plan for avatar image bytes).
2. **Remaining display surfaces** (not yet done): bound people in the event **detail** view (`CalendarEventDetailView`); a "filter / view all events with this person" surface. `PersonAvatar` / `PersonChip` / `PersonColor` / `PersonAvatarStore` are ready to reuse.
3. **Avatar disk cleanup** — archived people keep their avatar files (intentional, preserves history). No GC of orphaned files yet.

---

## Quick orientation for the next Claude
- Event model + persistence pattern: `Done/Models/Event.swift`, `Done/Models/EventStore.swift` (mirror `todoLists` for any new local collection).
- New files must be added to `project.pbxproj` in 4 places (this repo uses explicit refs; existing `PEOP…` IDs show the format).
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`: any file using `@Published` must explicitly `import Combine`.
- Live SourceKit "Cannot find type 'Event'/'EventStore'…" diagnostics during edits are **cross-file index noise** in this project — trust `xcodebuild`, not the inline indexer.
- Related memory note: `memory/project_people_binding.md`.
