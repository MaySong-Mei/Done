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
| `walker_upper` / `walker_misses_cross_midnight_witness` | the report walker's coverage: the upper bound is a theorem; the lower bound is FALSE, by constructive witness (finding 4 below, filed as #222) |
| `credit_add` / `daySplit_conserves` | the report split's conservation: cutting the sweep at civil midnights moves no value across the cuts — for EVERY day-length history and EVERY sharing rule (generic weight, division-free); what `dailyTotals`/`perTypeHours` silently rely on |
| `day_total_le_civil_length` | the ":845 ceiling" civil-corrected: a day's union coverage is bounded by the day's OWN length (23 h/25 h on transition days), not by 24 h |
| `elapsedWindowCut_bounds` / `renormalization_conserves` | the clamp's algebra frozen; time-of-day shares sum back to `net` exactly BECAUSE of renormalization — which is why the segment arithmetic's DST fragility is contained |
| `baseline_slide_witness` | `previousStart = start − length` is absolute arithmetic: constructive witness that the two windows can touch different civil-day counts across a transition — documented divergence, the fix would be a product decision |
| `creditT_eq` | the fixture generator's tail-recursive evaluator, verified against the pointwise spec — single-sourceness proved, not claimed |
| `never_touch` / `outward_only` | the bedrock laws (`DominoAbsolute.lean`, absolute time by design): every row outside the mutation domain — `.event`, absorbed, recurring, dateless, `.pass`/`.nearFuture` — comes back IDENTICAL; nothing ever moves backwards |
| `push_additive` / `horizon_distance_invariant` | skipped intervals are sound: two pushes against advancing horizons equal one whole-span push, and an eligible row's distance past the horizon is exactly preserved (the comment's own equation) |
| `duration_preserved` / `frame_condition` | the push slides, never reshapes; `deadline` and every eligibility field survive verbatim — "auto-defer moves the preferred time, never the commitment", literally |
| `horizon_linear` | why `horizonDate` must ignore its `calendar` parameter: the horizon advances by exactly the elapsed seconds, keeping filter and shift in lockstep — a civil-day horizon would desync them across every transition |
| `clampAdd_exact` / `clamped_landing_day_lt` | the month/year arms' bridge (gh#224): a step lands unclamped exactly when it realizes — so day-of-month equality IS realization, clamped landings can never fake a match, and Foundation's clamp-credit distances are consumed only where they equal ordinal arithmetic |
| `gate_budget` | "skipped steps must not consume the afterCount budget", as arithmetic: below any horizon the gate admits exactly `min count realized` — the Jan-31 and Feb-29 prose claims for every month-length assignment at once |
| `capped_walk_sound` / `split_conserves` | the `cappedAt` early exit decides `≥ count` identically to the uncapped walk (the value saturates, the verdict never lies); `elapsed + remaining = N` on every rendered occurrence, with the `max(1,·)` floor scoped to the unreachable case |
| `year_step_month_inert` | the `.year` arm's `monthMatches` check is provably redundant — yearly steps never change the month-of-year; the belt-and-suspenders guards nothing |
| `memberDay_iff` | cross-midnight membership (gh#224 slice 2): a range's member days are exactly `[dayOf s, dayOf (e−1)]` — the half-open edge semantics frozen, degenerate shapes included (midnight-anchored zero-length belongs nowhere; interior zero-length to its one day — the seam settled this empirically) |
| `credit_interval` / `interval_daySplit_conserves` | segment conservation, the #53/#55 family's missing law: civil midnight splitting loses and duplicates nothing — an INSTANCE of the pointwise partition machinery, replacing the four deleted dead geometry decoys |
| `allday_mint_memberDays` / `extension_candidates_cover` | the all-day mint occupies exactly its `dc` anchor days; the ±12 h boundary extension can show nothing outside the three pulled day caches (the canvas twin of the probe span) |
| `clampedCell_in_day` / `clampedCells_disjoint` / `civil_elapsed_days_nonneg` | the clue battery's window algebra (gh#227): the elapsed-clamped history cell stays inside its civil day and cells stay disjoint ONCE the `min` guard is present, and the absence gate's elapsed-day count is a valid civil distance — with `clamped_cell_spill_witness` and `elapsed_fullDays_undercount_witness` exhibiting the two live bugs this slice fixed as constructive `dstCal` countermodels |
| `strictly_shrinking_halts` / `peek_strip_contained` | the overlap recursion's skeleton (gh#224 slice 3): termination within cluster size — a bound NO prose in the codebase claimed — and exact-dyadic strip containment: no slot the recursion can mint leaves the unit column |
| `equal_split_partitions` / `lexLT_*` | columns tile the span exactly in scaled integers (the CGFloat widths are this arithmetic's shadow); the 7-key comparator is a strict total order exactly when occurrence ids are unique — the flagged hypothesis, now a stated cost |

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

3. **HEALED (gh#223) — end-of-day gap frames broke the prose premise.**
   Nuuk jumps DST at 23:00 local, so civil Mar 28 2026 runs 23 h and wall
   `[23:00, 24:00)` does not exist; `dateByCombining`'s `.nextTime`
   resolution sent a 23:30 mint a full day past its anchor, and two
   anchors minted byte-identical ranges. The mint now clamps into the
   anchor day (`min(combined, endOfDay(day))` — `endOfDay` civil-correct
   since gh#221): the escape and the double-mint are gone and the
   `probe_span_exhaustive` premise holds for Foundation again. The pin
   stays divergent for the MODEL's half: the offset time-of-day (84 600 s)
   still overruns the 82 800 s day — a model-side representation limit,
   recorded, with the theorems conditional as ever.
4. **HEALED (gh#222) — the report walker missed cross-midnight anchors.**
   `expandOccurrences` walked anchors from `startOfDay(windowStart)`, so a
   23:00→01:00 occurrence anchored the day before the window lost its
   00:00–01:00 spill from every report aggregate. Fixed by a
   duration-adaptive look-back — the walk now starts at
   `startOfDay(windowStart − duration)`, the `probe_span_exhaustive`
   arithmetic, hard-capped at 31 days like `seriesOccurrenceProbeDays`.
   The Lean witness `walker_misses_cross_midnight_witness` stays as the
   reason the look-back is required;
   `testReportWalkerCatchesCrossMidnightAnchors` and the
   `recur report:` fixtures hold the healed behavior.
5. **HEALED (gh#223) — `dateComponents(.day)` undercounted from a
   midnight-less anchor.** Anchored ON the 01:00-anchored day the 23 h
   first step counted as 0 days forever — interval parity lost, counts ran
   long. `Event.civilComponentDistance` now anchors BOTH sides at wall
   noon before counting; the matcher arms and the index derivation share
   it (day/week/month/year). The noon claim is BOUNDED, not universal: a
   QA scan of all zones 1900–2028 found 21 historical noon-covering gaps
   (only post-1968 member: Africa/Khartoum family, 2000-01-15), where
   from-side distances come up one short — accepted collateral, pinned by
   `testKhartoumNoonGapAcceptedCollateral`; all modern frames are exact. The pin's
   match is restored; its residual divergence is the mint's time-of-day
   semantics (wall-clock 01:30 vs the model's offset 1800 s from the
   01:00 day start) — the slice-1 QA observation, now the pin's whole
   content. The gh#207 heal's `dayGap` keeps its own semantics untouched,
   per the gh#221 verdict.
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

## Not in Lean, by design

gh#227 slice 2 (Supabase `eventToRow`/`rowToEvent` round-trip) is a
randomized SWIFT property seam (`DoneTests/SupabaseRoundTripPropertyTests`),
not a Lean model — the season survey judged the round trip "better as
property tests than theorems" (it is Codable/dictionary plumbing, not
civil arithmetic) and it is honored as such: 700 seeded trials asserting
a normalized `Event` survives the round trip under its own synthesized
`Equatable`, plus pinned divergences for the two documented lossy shapes
(empty `wannaNotes`/`typeWeights` collapse to nil, sub-second date
precision). No `verification/` module covers it.

## Layout

```
verification/
  lean-toolchain              pinned Lean version (v4.33.1)
  lakefile.toml               lib CivilCalendar + exe fixturegen
  CivilCalendar/Basic.lean    model + ported functions (single source)
  CivilCalendar/Theorems.lean the eight theorems
  CivilCalendar/Witness.lean  indistinguishability existence proof
  CivilCalendar/Recurrence.lean the gh#209 expansion model + 9 theorems
  CivilCalendar/ReportSplit.lean pointwise split semantics + 7 theorems
  CivilCalendar/DominoAbsolute.lean the bedrock laws + 7 theorems (absolute axis)
  CivilCalendar/MonthYear.lean  the clamped step algebra + 8 theorems (gh#224)
  CivilCalendar/CrossMidnight.lean membership + segment conservation + 5 theorems
  CivilCalendar/OverlapCore.lean overlap recursion skeleton + 6 theorems
  CivilCalendar/ClueWindows.lean clue window algebra + 3 theorems + 2 bug witnesses
  CivilCalendar/Fixtures.lean real tzdata midnight tables + 53 cases
  Main.lean                   window-checked JSON emitter
  fixtures.json               generated; committed so tests run without Lean
```

Midnight tables were sourced 2026-09-03 from python `zoneinfo` (system
tzdata) — a third implementation independent of both the model and
Foundation. The three `expectedFoundation` pins were measured the same day
with a host-Foundation probe (macOS).
