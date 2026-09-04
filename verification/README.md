# Civil-calendar formal verification (spike, gh#220)

A Lean 4 model of the civil-calendar core on `Done/Models/Event.swift`
(`endOfDay` / `allDayCivilEnd` / `legacyAllDayStraddleHealedEnd`), with the
load-bearing prose claims from those functions' doc comments restated as
machine-checked theorems, plus a differential-fixture seam that replays the
model's expectations against the real functions.

**Check the proofs:** `cd verification && lake build` (toolchain pinned in
`lean-toolchain`; install via [elan](https://github.com/leanprover/elan) —
no other dependencies, core Lean only).
**Regenerate fixtures:** `lake exe fixturegen` (rewrites `fixtures.json`).
**Replay against Foundation:** run `DoneTests/LeanCivilCalendarReplayTests`.

## The model

A calendar frame is its sequence of civil-day start instants
(`midnight : Int → Int`), strictly monotone, with `dayOf` the lookup it
induces (`CivilCalendar`, in `CivilCalendar/Basic.lean`). Day lengths are
otherwise **free**, so every theorem quantifies over all day-length
histories at once — 23h/25h DST days, Lord Howe's 23.5h, Santiago's
01:00-anchored short day — strictly stronger than any fixture set. The
executable definitions live on the law-free `CalFns` core; theorems and the
fixture generator share them, so the proved artifact and the evaluated
artifact cannot drift.

## What is proved (`Theorems.lean`, `Witness.lean`)

| Theorem | The prose claim it replaces |
| --- | --- |
| `allDayCivilEnd_lands` | anchor on any day start → last second of the last covered day, **any** day-length history |
| `dayCount_recovers` | "#188 rounding absorbs a DST hour" — with the real invariant made explicit: recovery is exact iff span drift from `86400·d` stays under **43 200 s** (the comment's "one hour" is 12× inside the actual cliff) |
| `allDayCivilEnd_roundtrip` | mint a `d`-day span in ANY frame, re-anchor in ANY frame → still `d` days (the #188→#211→#212 family's headline, stated once) |
| `normalized_end_not_healed` | conjunct 1's design: an `endOfDay`-shaped end (`midnight k − 1`) is never healed, for any start, in any ≥23h-day calendar |
| `healed_never_rematches` | the comment's one-line idempotence claim — a corollary: a healed end IS the normalized shape |
| `off_midnight_start_not_healed` | conjunct 3's design: composer open-time residue on the start is structurally safe |
| `legacy_straddle_heals` | the gh#207 signature fires and lands on `endOfDay` of the day the user picked (slip ∈ [2, 3600]; a 1-second slip would leave residue 0 and slip through — a boundary the prose never states) |
| `indistinguishability_witness` | "no stored byte can distinguish it, so no predicate can" — proved as existence: one byte pair, two lawful frames, opposite correct verdicts. The accepted false-positive class is a mathematical ceiling, not a missed refinement |
| `probe_span_exhaustive` (+`_allDay`, `allDay_residual_span_fits`) | the gh#209 prose proof on `seriesOccurrenceProbeDays`: containment forces the anchor into `[dayOf (t−dur), dayOf t]`, rule-independently; the all-day DST slack argument carries an explicit residual-span premise, discharged under a 3 h drift bound |
| `probe_count_bounded` | the 31-anchor cap's safety margin: durations ≤ 2 401 200 s (29 minimum days) span ≤ 31 anchors — beyond, the code truncates what the prose proves (the prose admits this; documented, not defended) |
| `daily_matches_iff` / `weekly_matches_iff` | the day/week arms exactly: matched days are the arithmetic progression, `afterCount` cuts precisely the first `count` positions, `endDate`/suppression guard as stated |
| `suppressed_never_matches` / `vacated_slot_uncovered` | the gh#209 three-way exclusion: 取消 silences the template; 脱离 leaves template and instance mutually exclusive; 空槽 — an instant outside the moved slot on the detached day is covered by nothing |
| `walker_upper` / `walker_misses_cross_midnight_witness` | the report walker's coverage: the upper bound is a theorem; the lower bound is FALSE, by constructive witness (finding 4 below) |

Hypotheses carry the assumptions the comments left implicit — that
surfacing is the point. `MinDayLen 82800` (days ≥ 23h) appears exactly
where the heal's residue window needs it; the 43 200 s drift cliff appears
exactly where rounding needs it.

## What is deliberately NOT proved

- The universal-negative claims ("no in-app writer derives an all-day end
  from raw seconds any more") are **code-coverage propositions** over Swift
  call sites. The model cannot see Swift; those stay grep + tests
  (gh#212 round 2's sweep).
- Foundation's own behavior. The model asserts what the civil arithmetic
  *should* be; the fixture seam measures where Foundation differs (below).
- `dayGap` is modeled as civil-day-index distance. Foundation's
  `dateComponents([.day])` counts elapsed full days — the two agree between
  true midnights (every US zone) and disagree on midnight-less-day frames
  (pinned below).
- gh#209 occurrence-expansion exhaustiveness — the natural next target,
  out of spike scope.

## Foundation fidelity — the Santiago findings (one healed, one pinned)

Chile (America/Santiago) springs forward AT midnight: civil 2026-09-06
starts at local 01:00 and runs 23h. The spike's fixtures surfaced two
findings on that live-zone family (gh#221):

1. **HEALED — `Event.endOfDay` overshot the civil day.** The
   `startOfDay + 1 day − 1 s` recipe preserved wall-clock time across the
   hop, landing one hour INTO the next civil day and minting 1-day all-day
   events already straddling. Fixed at gh#221 by re-normalizing the hop
   through `startOfDay` before subtracting — identity on every true
   midnight, heals the gap day. The two Santiago fixtures that pinned the
   divergence now assert agreement and stand as the regression guard.
2. **PINNED — the gh#207 heal cannot catch the legacy straddle shape on
   this frame.** `dateComponents([.day])` between the two day starts spans
   23h = 0 full days, so `dayGap ≥ 1` rejects it; the model's
   day-index reading says the heal should fire. Accepted: the shape is no
   longer minted in-app after (1), so the exposure is legacy rows synced
   from pre-fix builds in midnight-DST zones. The fixture asserts
   Foundation's ACTUAL nil and separately asserts the pin stays divergent,
   so any Foundation/tzdata change trips loudly. Touching the heal's
   `dayGap` semantics re-opens the gh#207 discrimination argument and
   wants its own verdict (recorded in gh#221's close).

## Foundation fidelity — slice-1 findings (recurrence expansion)

Calibrated 2026-09-04 (host probes; pins in the `recur PIN:` fixtures and
`LeanRecurrenceReplayTests`):

3. **End-of-day gap frames break the prose premise (America/Nuuk, live,
   annual).** Nuuk jumps DST at 23:00 local, so civil Mar 28 2026 runs 23 h
   and wall `[23:00, 24:00)` does not exist. `Event.dateByCombining`'s
   `bySettingHour` resolves a 23:30 series mint to the NEXT wall 23:30 — a
   full day past the anchor. The Mar 28 and Mar 29 anchors then mint
   byte-identical ranges under two occurrence ids: double render where day
   caches union, double count where the report window spans both anchors.
   The model keeps the premise explicit (`probe_span_exhaustive`'s
   `start < midnight (D+1)`); the pin records BOTH mints violating it —
   the model's offset time-of-day (84 600 s) overruns the 82 800 s day
   too, landing on Mar 29 00:30 while Foundation lands on Mar 29 23:30.
   The theorems are conditional, so soundness is untouched; the pin exists
   so neither violation is mistaken for the premise holding. Historical
   members of the class: Asia/Dhaka 2009, Asia/Pyongyang 2018.
4. **The report walker misses cross-midnight anchors (every zone).**
   `expandOccurrences` walks anchors from `startOfDay(windowStart)`, so a
   23:00→01:00 occurrence anchored the day before the window loses its
   00:00–01:00 spill from every report aggregate — the post-filter would
   have kept it, but the anchor is never probed. The canvas probes
   `offset − 1` for exactly this (`timelineCandidateDayOffsets`); the
   report walker does not. Lean witness
   `walker_misses_cross_midnight_witness`; Swift pin
   `testReportWalkerCrossMidnightAnchorPin`.
5. **`dateComponents(.day)` undercounts from a midnight-less anchor
   (Santiago/Cairo-class zones).** Between two true day starts the count
   equals civil-date distance even across a gap day; anchored ON the
   01:00-anchored day itself it reads the 23 h first step as 0 days and
   stays one short forever — an interval-2 series anchored there loses its
   parity, a count-terminated series runs one day long. Pinned as the
   `recur PIN: daily k=2 anchored ON the midnight-less day` fixture.
6. **Nonexistent-time mints clamp to the gap end (every spring-forward
   zone).** A 02:30 series on LA's gap day mints at 03:00 (Foundation's
   `.nextTime`), not at the offset the naive model predicts — benign
   (stays in-day), pinned for honesty in `recur PIN: 02:30 series`.

Fixture series times otherwise sit at 01:30 local — before the earliest
intra-day transition in every probed frame — so the model's offset
time-of-day, Foundation's wall-clock combination, and python's zoneinfo
agree by construction. The one carve-out is the Santiago pin, whose anchor
day starts at 01:00: its model channel carries offset semantics and is
cross-checked by nothing (Foundation rejects the match), which is recorded
on the fixture rather than smoothed over.

## Layout

```
verification/
  lean-toolchain              pinned Lean version (v4.33.1)
  lakefile.toml               lib CivilCalendar + exe fixturegen
  CivilCalendar/Basic.lean    model + ported functions (single source)
  CivilCalendar/Theorems.lean the eight theorems
  CivilCalendar/Witness.lean  indistinguishability existence proof
  CivilCalendar/Recurrence.lean the gh#209 expansion model + 9 theorems
  CivilCalendar/Fixtures.lean real tzdata midnight tables + 41 cases
  Main.lean                   window-checked JSON emitter
  fixtures.json               generated; committed so tests run without Lean
```

Midnight tables were sourced 2026-09-03 from python `zoneinfo` (system
tzdata) — a third implementation independent of both the model and
Foundation. The three `expectedFoundation` pins were measured the same day
with a host-Foundation probe (macOS).
