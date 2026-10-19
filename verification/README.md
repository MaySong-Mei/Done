# Civil-calendar formal verification (spike, gh#220)

A Lean 4 model of the civil-calendar core on `Done/Models/Event.swift`
(`endOfDay` / `allDayCivilEnd` / `legacyAllDayStraddleHealedEnd`), with the
load-bearing prose claims from those functions' doc comments restated as
machine-checked theorems, plus a differential-fixture seam that replays the
model's expectations against the real functions.

**Check the proofs:** `cd verification && lake build` (toolchain pinned in
`lean-toolchain`; install via [elan](https://github.com/leanprover/elan) —
no other dependencies, core Lean only).
**Regenerate fixtures:** `lake exe fixturegen` (rewrites `fixtures.json`);
`lake exe syncfixturegen` (rewrites `sync-fixtures.json`, gh#257).
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

## Sync merge (gh#257) — the §6 apply table, proved and emitted

`CivilCalendar/SyncMerge.lean` models the realtime-sync design as it
stands on design/realtime-sync `34a7810` (v1.4 after review seven) PLUS
the uncommitted round-eight/nine edits of
`Docs/sync/00-realtime-sync-design.md` in the working tree. The design is
in flux; the model follows the working tree and names what it takes from
each layer. From the uncommitted edits: the §6 skip row is
`seq ≤ h_base.seq → 跳过` (`34a7810` has `==`); the conflict row and the
pending-delete row write the baseline `(h_in, seq)` (`34a7810` keeps the
old hash, "hash 不动保持脏" — kept in the model only as the variant
`decideRowKeepHash`, for the witnesses against it), so the baseline
column has three writings — skip keeps, tombstone removes, every other
row writes `(h_in, seq)` — and a baseline always names the version the
server held at its seq; the settings per-key baseline after a merge is
the remote key's hash on every key, conflict keys included; the
`skillAnalyzedEventIds` union is written back (and hashed) sorted; the
event_types winner ranges over live namesakes only; both settings sides
changing a key to the same bytes is not a conflict; a remote key
deletion overridden by a local change is shelved as
`{key, remote: absent}`. From `34a7810` over
`6a7e50b` (v1.3): the skip row itself; the pending-verify set
`(table, id, sentSeq, sentHash, pullIssue)`; the pending-delete row
(本地 absent 且基线有 id → 按 dirty 处理); the tombstone row removing a
present baseline entry when the local row is absent; the mandatory
`deleted_at` check on a `[row]` PATCH response; the singleton-table
tombstone rule. One model decision the text does not state yet
(reported in the gh#257 thread): a PATCH `[row]` response that arrives
after a pull moved the baseline is dropped — it writes
`(hash sent, row.seq)` only if the baseline seq is still the seq the
PATCH carried (`Replica.recv`); the text writes it unconditionally
(`recvUnguarded`, `late_row_response_regresses_witness`). One cost the
text does not state, with the table followed as written: our own push's
echo pulled BEFORE the push's response meets the pre-push baseline, so
the table files our own bytes as a conflict — or, if the user set the
row back to the baseline's bytes meanwhile, adopts our pushed bytes over
that revert; the "顺序敏感" guarantee holds only when the response is
applied first (`echo_before_response_shelves_own_push_witness`, both
orders reachable). `decideRowInflight` — the sent hash of the PATCH
outstanding for the id counts as an echo — is the variant under which
that race is the sequential order (`inflight_race_matches_sequential`).
The working tree has since moved to v1.5. Its §6 rule rows are
unchanged; what v1.5 adds around them and the model does not represent:
the `?` baseline hash of a write whose outcome is unknown (S4) —
`Replica.base` has no hash equal to none and no hash without a seq, so
`Reachable.lose` is the earlier "a throw keeps the baseline" reading S4
replaces (`lost_then_revert_reachable` is the hole S4 closes;
`unknown_marker_witness` checks S4's arithmetic on concrete runs with a
stand-in hash and does not model `?`); the epoch / floor reset (§6.6,
D10); the failure classes and `rejected` table (S1); the owner guard
(S5); cursor generations (S11). Its single-flight pulls (I9) agree with
the model's sequential pulls, and its restore replay (S6) is the writing
`restore_replay_local_hash_witness` argues for. Also modelled: the §4
invariants I3, I4, I6, I7 and I8 (I1 as the `Chain` of T5'), and the row-level semantics of migration 015
(seq assignment, content-identical short-circuit, I6 tombstone survival,
delete→tombstone rewrite, the request-filter stale-write guard). Core
Lean only, like the rest of the project. `Hash`/`Seq` are `Nat`; content
is a type parameter; the design's own "rowHash never collides" is the
explicit hypothesis `HashInjective`, stated only where a theorem needs it.

Not modelled, so that no theorem is read as covering it: I2 and the
outbound sink; I5 as a server property — it is instead what makes a
`sync_changes` page a snapshot, and every theorem that needs it says
`IsHeadFeed s₀ cursor page` (or the limit-cut `IsPageFeed`) for a server
state `s₀` the current one `Advances` from (a witness built on a page
that is a snapshot of no state proves nothing about the design, and the
one this module used to carry is kept only as the negative
`scenarioAPage_not_head`); client concurrency beyond a PATCH response
that arrives late or never — a POST's response applied late (two guards
the text could state for it are compared in
`late_post_response_guards_witness`, outside `Reachable`), two pulls
interleaved, a PATCH built before a pull and sent after it (operations
are otherwise sequential; `pullIssue` is modelled in its sequential form
only: `Reachable.verify` is a head page of the current server at the
moment the pass is APPLIED, so an eligible pull whose page goes stale
before it is applied — a peer's write or a push of ours landing between
the RPC and the apply, which the text's eligibility allows — is outside
`Reachable` and `reachable_sound` says nothing about it; `pullVerify` by
itself, which runs the pass after any page, is not the rule); the
singleton tables' `[]` closure (their pending-verify by `sentHash` /
`sentKeys`; `Singleton` has no verify pass,
`singleton_edit_to_dead_bytes_witness`); a second hash function — `Reachable` fixes one, so a build that
changes the row-hash encoding (T9a's starting state) is outside it;
restore's baseline replay (`markRestoreCompleted` → `replayBaseline`),
which the design names as a baseline writer (§4 I2, §6 上传形状) and
which is not a `Reachable` constructor, so nothing below covers a
replica after a restore (slice 1's writing, which the round-nine §13 row
describes, `(hash(local row), previous seq)`, is
`restore_replay_local_hash_witness`; v1.5's S6 writing is the cloud
row's);
the shelf row's seq and the `(uid, table, id, seq)` dedup (the shelf is a
list of `(id, content)`; re-application idempotence comes from the skip
row), §6.1's whole-page refusal when a shelf append fails and its
frozen-slot precheck, and the tombstone PATCH's throw-keeps-the-baseline
branch (`pushDelete` always succeeds); the `(table, id)` key — the
model keys by `Id`, so the cross-table collision the design warns about
is unrepresentable; the `pull` filter `cursor < seq` is client-side
where the design filters on the server, equivalent on a snapshot page
and the thing that makes Scenario A representable; I3's per-page,
per-slot persist unit — the row theorems are per row and the page fold
is proved for a page whose rows are all in one slot's
slot-written-baseline-unwritten state; the upgrade path's hash-only
baseline, which looks dirty here; the undelete RPC (not a `ClientOp`, so
T1 is scoped to ordinary writes by construction) and account erase
(outside `Advances.keep`); event_types attributes and the composition of
`resolve` with the row table and `pushDelete`; the `sentKeys` form of
pending-verify for user_settings; the settings time-zone key's projected
dirty test (the pusher's projection, server value first) and the
composition of the analyzed-ids rule into the settings row pass
(`mergeAnalyzedIds` is per key).

**Two models, not one.** `decideRow` / `applyRow` / `pushRow` are the
six id tables: the tombstone row removes the local row and the baseline
entry, the dead-row PATCH response is treated as an incoming tombstone.
The three singleton tables (user_settings, agent_preferences,
agent_conversations) never delete or reset locally and never shelve on a
tombstone; their rule is the `Singleton` namespace, and every tombstone
theorem on `applyRow` (T4, T5, the `Inv` family — whose `noDead` is
false on a singleton table by design — `Reachable`,
`clean_iff_matches_server`) is about the six id tables only. The
singleton tables' live-row rules (user_settings per key, the other two
whole row) are not composed with `Singleton`; nothing composes
`Settings.mergeRow` with it. The fixtures are the id tables only.

`decideRow` is the executable decision core — the §6 table in the
table's order: the `≤` skip row, tombstone, echo, same, the
pending-delete row, adopt, conflict, with every non-skip, non-tombstone
row writing the baseline `(h_in, seq)` — and `applyRow` is its effect on
a replica (`loc`, `(hash, seq)` baseline, append-only shelf, cursor).
`pull` folds it over a page past the cursor; `pushRow` is the
conditional-PATCH / ignore-duplicates-POST upload shape with the
baseline written from the SENT hash and the response's seq, the
`[row]`-with-`deleted_at` branch (`Replica.deadRowHit`: shelve the
dirty local version, remove the row and the entry, write no
`(hash, seq)`), and a `Pending (id, sentSeq, sentHash)` entry on a PATCH
`[]`; `pullVerify` is the pending-verify pass after a pull: a seen entry
is dropped, an unseen one rewrites the baseline hash to `sentHash` iff
`base.seq == sentSeq` and is otherwise dropped with the hash untouched.
The server is `rows : Id → Option Row` plus the `sync_seq` counter;
every client write shape, pre-015 included, is a `ClientOp`. `Inv` is
the reachability invariant (server well-formed; baseline seqs and the
cursor bounded by the counter; a baseline seq never names a dead row;
every baseline entry names a server row whose seq is at or above the
baseline's — `BaseAnchored`, what makes a head-page row never strictly
older than the baseline) and `BaseTracksFeed` the tracking property
pending-verify relies on; both are preserved by every operation of the
model, snapshot pages of an earlier server state included.
`Reachable` closes the model's operations from a fresh replica: a
peer's write of any shape; local edits and deletes; `push` (an upload
with its response applied at once); `send` then, after any other
operations, `recv` — a conditional PATCH whose response arrives late,
at most one upload per id outstanding, the `[row]` written under the
guard above; `lose` — a PATCH whose response never arrives, dropped
with nothing written or filed; pushed deletes; `pull` of a head or limit-cut page
(`IsPageFeed`) of a server state the run passed through, the current
one or an earlier one (a page fetched before our own push and applied
after it); and `verify`, the pull that clears pending-verify entries,
which must be a head page of the CURRENT server when the pass is applied
— the pull was issued after every `[]` it clears and nothing landed
between its fetch and its apply, the sequential form of `pullIssue`, so
it consumes every entry. An ineligible pass is not a `Reachable` step
(`ineligible_verify_loses_witness` is design interleaving (i): it loses
c1). On every reachable state (`reachable_sound`): `Inv`;
`BaseHashSound` (a baseline whose seq is the server row's seq carries
that row's hash) with no conflict-row exception; `BaseTracksFeed`;
`BaseHeld` — every baseline entry `(h, S)` is a live version some
server state of the run held at seq `S` with hash `h`, the past-tense
sentence of the design, with the history explicit; and every pending
entry is stale (`PendingStale`: the server row for the id carries a seq
above the sent one), hence sound. These are statements about the
baseline writers the model has; restore's replay is not one of them.
What the reachable set does not contain: `Reachable` fixes one `hash`,
so the hash-encoding-change state T9a starts from is outside it; on
reachable states a dirty PATCH's `[]` is always staleness
(`patch_empty_stale`, `reachable_patch_empty_is_stale`) and the verify
pass's confirm branch never fires (`reachable_verify_is_pull`) — the
`sentHash` rule is exercised by T9a and the interleaving witnesses, not
by `reachable_sound`, and `PendingSound`'s row clause is vacuous there.

| Theorem | The design claim it replaces |
| --- | --- |
| `tombstone_monotone` (T1) | I4 + I6 as the trigger enforces them: once a row is a tombstone, no PATCH, POST, delete, or pre-015 blind upsert brings it back (the undelete RPC is not a `ClientOp`) |
| `pull_idempotent` (T2a) | cursor discipline (§3 D1, I3's cursor write as the last step): a page pulled twice is applied once; the proof does not use the table — this is not the I3 crash case |
| `applyRow_idempotent` (T2b) · `applyRow_idempotent_loc_base` · `applyRow_idempotent_shelf_mem` (T2c) | the I3 crash BEFORE the cursor write, and §6.1's refused-page re-pull: re-applying a row is the identity on the replica AS A LIST — the skip row sees the seq the first application wrote. The v1.3 table doubled the shelf on a conflict row: `conflict_reapply_doubles_shelf_v13_witness` |
| `applyRow_skip` · `applyRow_seq_monotone` | the `≤` skip row as an effect: a row whose seq the baseline already names or exceeds is the identity; a baseline seq never moves backwards |
| `decideRowEq_eq_decideRow` | the `==` row (`34a7810`) and the `≤` row (working tree) agree on every input except a row strictly below the baseline seq — the stale-page row |
| `applyRow_after_slot_only_heals` · `pull_after_slot_only_heals` | the I3 crash between slot and baseline write (the baseline still names an OLDER seq): the re-pull fires echo/same, writes the lost baseline, shelves nothing — per row, and for a page whose rows are all in that state |
| `echo_inert` (T3) · `push_then_echo` · `push_then_echo_reachable` · `echo_after_local_edit` (T3b) | our own push coming back changes nothing and shelves nothing, whether or not the row was edited again in between (the "顺序敏感" C2 guarantee), composed with the real upload shape — ONCE THE PUSH'S RESPONSE HAS BEEN APPLIED (T3b's premise is the baseline the response writes); the own-push echo carries the baseline's seq and is absorbed by the skip row, the echo row's remaining job being a same-hash row at a newer seq; the baseline seq becomes the larger of the two; the live-row hypothesis is derived from `Inv` (`hlive_of_inv`). Pulled before the response, the echo is a conflict (`echo_before_response_shelves_own_push_witness`) |
| `inflight_race_matches_sequential` · `decideRowInflight_base` | the variant `decideRowInflight` (not the text's rule): an incoming live row whose hash is the sent hash of the PATCH outstanding for its id is an echo. Per row it writes exactly the table's baseline on every input, and differs only in the shelf (the conflict row's own-push line) and the local row (the adopt row's own-push overwrite); its echo-before-response order followed by the guarded response gives exactly the replica the response-then-echo order gives under the table, whatever the local row is by then — the race is the sequential order. The whole-run theorems are proved for the table and not re-proved for the variant |
| `pushRow_cases` | the six outcomes of an upload: nothing sent; `[row]` live; `[row]` dead (the third response); `[]`; POST `[row]`; POST `[]` |
| `inv_step` · `inv_pushRow` · `inv_pushDelete` · `inv_applyRow` · `inv_applyRow_snapshot` · `inv_pull` · `inv_pull_page` · `inv_pull_snapshot` · `inv_pullVerify` · `inv_initial` | `Inv` is preserved by a peer's write of any shape, our push (the dead-row branch is unreachable under it), our pushed delete, applying a row of a head page, of a limit-cut page, or of a page that is a snapshot of an EARLIER server state (Scenario A's page), the verify pass; and holds for a fresh replica |
| `baseTracksFeed_step` · `baseTracksFeed_pushRow` · `baseTracksFeed_pushDelete` · `baseTracksFeed_pull` · `baseTracksFeed_pullVerify` · `baseTracksFeed_initial` | `BaseTracksFeed` (a server row at or below the cursor has the baseline's seq) is an invariant — including under a stale snapshot page, where the skipped row keeps an entry that anchoring pins to the row's seq. Its limit-cut form is `baseTracksFeed_pull_page`; on reachable states it is part of `reachable_sound`, which discharges T9b's hypothesis |
| `decideRow_base_noskip` · `applyRow_base_noskip` · `decideRow_conflict_still_dirty` · `decideRow_conflict_facts` · `applyRow_conflict_base` | the baseline column (round nine): a row that is not skipped removes the entry on a tombstone and otherwise writes `(h_in, seq)` — echo, same, pending-delete, adopt and conflict alike; the conflict row is reached only when `h_loc ≠ h_in`, so the local side stays dirty and is uploaded (all that "hash 不动保持脏" protected); a conflict leaves the incoming row's `(hash, seq)`, the incoming row on the shelf, the local side untouched |
| `conflict_then_edit_is_pushed` · `conflict_then_revert_is_pushed` (+ `_instance`) | after a conflict (dirty row or pending delete), any local value whose hash is not the incoming one — an edit, a revert to the pre-conflict bytes, an undo re-adding a row whose delete had not been pushed — is dirty, and the next PATCH `seq=eq.<incoming seq>` lands it while the server still holds the incoming row; the revert case derives its premise from the conflict itself (the incoming row is not the old version). The instance applies the theorem to the witness state, so its premises are satisfiable |
| `decideRowKeepHash_agrees` | the superseded writing differs from the table on the conflict row's baseline HASH and nothing else (same row fires, same shelf flags, same seq, every other decision identical), so every PATCH the two send is the same PATCH; they differ only on which local values read clean |
| `reachable_sound` · `reachInv_of_reachable` · `baseHashSound_pull` · `baseHashSound_applyRow_snapshot` · `baseHashSound_pushRow` · `baseHashSound_pushDelete` · `baseHashSound_pullVerify` · `baseTracksFeed_pull_page` · `baseHeld_pull` · `baseHeld_applyRow` · `baseHeld_pushRow` · `flightSound_pull` · `flightSound_transfer` · `pendingStale_pushRow` · `pendingStale_advances` · `inv_pull_sound` · `inv_setBase_flight` | every baseline writer the model has keeps the baseline truthful: a peer's write of any shape, a pull of a head or limit-cut page of any state of the run (a stale one included), our push (`[row]` writes the sent hash for the row the server now holds; the dead-row branch removes the entry), a late `[row]` under the guard (`FlightSound`: the response row is live, held, carries the sent bytes at a seq above the filter's, and — while the baseline seq is still the PATCH's — no server row for the id at or below the cursor carries another seq, which survives any pull, `flightSound_pull`), our pushed delete, and the eligible verify pass. On every `Reachable` state: `Inv`, `BaseHashSound`, `BaseTracksFeed`, `BaseHeld` (every entry a live version some state of the run held at that seq), every pending entry stale and sound. Restore's baseline replay is not a writer the model has |
| `reachable_verify_is_pull` · `pullVerify_eq_pull_of_stale` · `patch_empty_stale` · `reachable_patch_empty_is_stale` · `pendingStale_sound` | the vacuity of the confirm branch on reachable states, stated as theorems: with one hash function a dirty PATCH that answers `[]` was stale (the server row carries a seq above the filter's), so every pending entry is stale, so after an eligible head pull an unseen entry's baseline seq is the server row's (tracking), never the sent one, and the verify pass drops every entry and changes nothing beyond the pull. The `sentHash` rule's own case — the hash-encoding change — is T9a's, outside `Reachable` |
| `clean_iff_matches_server` (+ `_instance`) | "本机脏 ⟺ 本地 ≠ 服务端", for the six id tables: on a reachable state, at an id whose server row still carries the baseline's seq, the id is clean exactly when the local row is the server's live content (needs injectivity). Both truth values occur on a reachable run (the instance: dirty-and-different right after a conflict, clean-and-equal after the guarded late response and the push). False under the superseded writing (`keep_hash_state_not_sound`) and under the restore replay's local-hash writing (`restore_replay_local_hash_witness`); `Singleton` has no live-row rule, so nothing here covers the singleton tables |
| `no_silent_loss` (T4) · `pending_delete_kept` (T4b) · `dirty_local_vs_tombstone_shelved` (T4c) | I7's law for the applier: local content that changes was either clean (its hash is the baseline's) or is now on the shelf — no third exit. What "clean" is worth: on every reachable state the baseline is a live version some state of the run held at that seq (`BaseHeld` in `reachable_sound`), for the writers the model has — an ineligible verify pass (`ineligible_verify_loses_witness`), an unguarded late `[row]` (`late_row_response_regresses_witness`) and the restore replay's local-hash writing (`restore_replay_local_hash_witness`) each break it; a pending local delete stays absent whatever arrives, and a live non-echo row it meets is shelved with the baseline on that row's `(h_in, seq)` (the pending-delete row — delete beats edit, `pushDelete`, which ignores the hash, then still lands); a dirty local edit meeting the server's tombstone is shelved, removed, and its entry dropped (§7's "A 离线改、B 删") |
| `clean_replica_page` (T5-page) · `clean_replica_converges` (T5) · `clean_replica_converges_reachable` · `applyRow_clean_full` | I1's payoff: a replica with no dirty id, in sync below its cursor, whose baselines are anchored and tell the truth (`BaseAnchored`, `BaseHashSound`, `NoDeadBase` — what a page row the baseline already names needs, since the skip row skips it), pulling one limit-cut page is again in sync below its cursor with its shelf untouched and every id clean; pulling one head page lands on the server's live content at every id (tombstones included); every page row's baseline on `(hash live, seq)` or removed; needs injectivity. On a `Reachable` replica the three truthfulness premises are theorems (`clean_replica_converges_reachable` takes only reachability, all-clean and `SyncedBelow`), so every reachable clean replica is covered, one that took a conflict and pushed since included — `clean_replica_converges_reachable_instance` discharges every premise on a run through a conflict, a late `[row]` dropped by the guard, and a push |
| `chain_step` · `chain_preserves` · `pull_pages_converge` (T5') · `pull_pages_converge_reachable` · `fresh_replica_premises` | the I1 loop over limit-cut snapshots: a run of pulls, each a page of the server as it then is cut at the seq of its last row (`page_limit`, the row clamp) with peers writing in between (`Chain`), carries `Inv`, all-clean, `SyncedBelow` and `BaseHashSound` and never touches the shelf; a run whose last pull is a head page (the short page) lands on that server's live content at every id (`pull_head_covers`). From a `Reachable` start the `BaseHashSound` premise is dropped (`pull_pages_converge_reachable`). A fresh install satisfies the premises against any well-formed server whose rows carry minted seqs |
| `stale_write_guard` (T6) · `identical_write_short_circuits` · `patch_empty_reasons` | I8: a PATCH whose base is not the server seq touches nothing and answers `[]`; so does an identical write; and `[]` has no third cause |
| `pushDelete_lands` · `pushDelete_unconditional` | the pushed delete: the server row is dead afterwards (flipped now or already) and the baseline entry is gone — and it lands whether or not the baseline seq was current, because the delete filter carries no seq |
| `pending_verify_recovers_identical` (T9a) | the `[]` closure on the short-circuit: baseline hash foreign, server holds the local bytes at the baseline seq, PATCH → `[]` with entry `(id, S, hash local)`, pull sees nothing → verify writes `(hash local, S)`, the id is clean, the next flush sends nothing |
| `pending_unseen_means_identical` (T9b) | the justification ("没见到就是服务端没取新号") with the eligibility check explicit: the PATCH went to `s₀` and answered `[]`, peers wrote since, the replica at verify time still holds `(_, sentSeq)`, the head pull of `s` did not see the id ⇒ the server HOLDS a row for the id and it IS the sent bytes, live, at `sentSeq`, so writing `sentHash` writes the truth. The drop branch is `verifyUnseen_ineligible` — its premises `Inv` and `BaseTracksFeed` hold on every reachable state (`reachable_sound`); with one hash function no reachable state reaches the confirm branch it justifies (`reachable_verify_is_pull`) |
| `winner_comm` / `winner_idem` / `winner_mem` / `winner_assoc` (T7a–d) | the event_types smallest-UUID rule is symmetric, idempotent, never mints a third UUID, and three holders agree in any discovery order; tautologies of `Nat.min` — `Nat` stands in for fixed-width LOWERCASE hex (asserted, not proved) |
| `winner_ranges_over_live_only` / `loser_never_in_base` / `both_holders_converge` (T7e–g) | the applier half of the rule, per normalized title: a tombstoned namesake takes no part in winner selection; the loser is never the UUID allowed a baseline entry and is the one tombstoned (by either of the text's two paths — one field here); A applying B's row and B applying A's row hold the same winner, tombstone the same loser, and the converged state is a fixed point. Attributes (colorHex …): the design takes the winner's and drops the loser's unshelved — a real I7 exception the text should state. A tombstone of the HELD type bypasses the shelf only in this abstraction (`resolve` is not composed with the table); in the design it goes through the id table's tombstone row, which shelves a dirty local version |
| `one_side_takes_that_side` / `both_changed_local_wins_remote_shelved` / `remote_deletion_overridden_is_shelved` / `unchanged_is_identity` / `deletion_propagates` / `local_deletion_wins_remote_shelved` (T8a–c) | the per-key settings merge: one side changed takes that side; both changed differently keeps local and flags the remote side as shelved — including a remote DELETION that lost; a deleted key propagates (also the §9.3 second window); a local deletion counts as a change and wins a both-changed conflict (model-stated; the text does not say) |
| `union_keeps_both` / `nil_vs_nonnil_base_deletes` / `deletion_shelves_moved_side` / `double_delete_shelves_nothing` (T8d–e) | `skillAnalyzedEventIds`: both non-nil → union loses no id; nil against a non-nil baseline → deletion wins even over an addition, the overridden side is flagged shelved iff it had moved (model-added), and a key deleted on both sides shelves nothing |
| `analyzed_union_order_free` (T8k) · `analyzed_union_settles` · `canonical_eq_of_mem_iff` · `eq_of_sorted_of_mem_iff` | the union is written back sorted (round nine): two merges whose sides hold the same ids between them write the SAME list, hence the same order-sensitive per-key hash; a device holding only ids the remote sorted list already has merges back to exactly that list and reads clean. Lowercase UUID order is `Nat` order here (asserted, as for event_types) |
| `upgrade_local_clean` / `upgrade_local_clean_bytes` / `upgrade_remote_is_ours` / `upgrade_empty_baseline` (T8f, keys under the general rule) | the §6 upgrade rule from today's row hash to a per-key baseline: local clean → remote everywhere (bytes under injectivity), nothing shelved; remote is our last upload → local everywhere, nothing shelved; neither → conflicts on both-present differing keys (the admitted one-time cost), one-side keys taken. `rowHash inRow` is the re-projected `h_in`, never a body hash |
| `mergeRow_reapply_skip` (T8g) · `mergeKeys_local_change_stays_dirty` (T8h) · `mergeKeys_remote_change_clean` (T8i) · `mergeKeys_same_bytes_clean` (T8j) · `mergeKeys_base_tracks_remote` · `mergeKeys_dirty_iff_differs_remote` | the settings ROW: the seq skip first, then the per-key pass, then the post-merge per-key baseline (round nine: row seq := incoming seq, EVERY key := the remote value's hash, conflict keys included): re-applying the same row is the identity; a key the local side changed stays dirty and is uploaded, whether the remote side was unchanged or conflicting; a key only the remote side changed reads clean; same bytes read clean; any later local value of a key reads dirty iff its hash is not the remote value's — a revert of a conflict key, or deleting one, is uploaded (`mergeKeys_base_tracks_remote` is definitional and `mergeKeys_dirty_iff_differs_remote` nearly so: they pin the writing; the semantic content is T8h and `settings_conflict_key_revert_witness`) |
| `tombstone_fixed_point` (T10a) · `naive_half_round` (T10b) · `base_removed_posts_forever` (T10c) · `tombstone_then_edit_one_dead_write` (T10d) | the singleton-table tombstone rule's arithmetic: after a tombstone that the skip row does not skip, `(hash local, seq)` reads clean and the next flush sends nothing, for any bytes on either device; `(h_in, seq)` — the id-table writing — lands a half round in the same ping-pong state with the roles swapped and one more seq minted, so by induction it never settles; removing the entry makes every flush an ignore-duplicates POST onto the dead row; a local edit after the tombstone is exactly one dead-row write (`[row]` dead, baseline `(hash sent, new seq)`), after which the next flush sends nothing and the other device, taking that dead row, sends nothing either — for a CLEAN other device that is §7's acceptance item; the conjunct holds for a DIRTY one too, and there it is the loss (`singleton_dead_period_edit_lost_witness`); an edit back to the dead row's own bytes is excluded (`v ≠ c0`: that PATCH answers `[]`, and the singleton `[]` closure is not modelled) |
| `applyTombstone_base_seq_monotone` | the skip row in front of the singleton rule: a tombstone never moves a singleton baseline seq backwards (without it a stale tombstone regresses the seq and the next PATCH answers `[]`: `singleton_stale_tombstone_skipped_witness`) |
| `applyTombstoneShelve_clean` · `applyTombstoneShelve_dirty_one_write` | the variant `applyTombstoneShelve` (not the text's writing): on a clean row, or one with no baseline, it IS the text's rule — so a tombstone never makes a clean row dirty, the step T10b's ping-pong runs on; on a dirty row whose bytes differ from the dead row's it writes `(h_in, seq)` (shelving the dead row's bytes unless they are the baseline's), and the next flush is exactly one dead-row write, then the fixed point |

Witnesses (constructive countermodels, `Nat` content, identity hash):

| Witness | What it refutes or exhibits |
| --- | --- |
| `conflict_reapply_doubles_shelf_v13_witness` · `eq_conflict_reapply_witness` | against the `6a7e50b` table only: re-applying a conflict row shelved the incoming row twice; the skip row (either form) applies it once |
| `slot_only_crash_then_edit_witness` | I3 crash between slot and baseline write, then a local edit of the adopted row before the re-pull: one spurious conflict entry, no byte lost, next PATCH passes I8; the skip row does not remove it (the baseline seq is still the old one, below the row's) |
| `dead_row_hit_is_tombstoned_witness` · `witness_outside_inv` · `tombstone_then_push_is_refused_witness` | the §6 third response handled: a PATCH onto a dead row at the base seq is accepted (I6, bench S7), `[row]` comes back dead, the upload rule shelves the dirty local version, removes the row and the entry, writes no `(hash, seq)`. The state violates `Inv` — no operation of the model produces it — and on the design's own path the PATCH is refused by I8 and the edit is shelved (I7): the cheap guard the design calls it |
| `stale_feed_row_regresses_witness` · `stalePage_head` | Scenario A: a page that is a snapshot of the server BEFORE the replica's own push, applied after it, carries a row strictly older than the baseline seq; the `==` row does not catch it and the table ADOPTS it (local v2 → v1, baseline seq 6 → 5, nothing shelved) until the next pull; the `≤` row makes it a no-op |
| `scenarioA_recovers_witness` · `consistentPage_head` · `scenarioAServer_advances` | Scenario A continued under `==`: the user edits to v3 in the window, the PATCH `seq=eq.5` is refused, the head pull from 5 SEES id 1 at seq 6 (I5: the cursor cannot pass 6 without a snapshot that contains it), the conflict row shelves our OWN v2 and sets base `(1, 6)`, v3's next PATCH lands. Cost: one transient regress and one spurious self-shelf entry — not divergence. Under `≤` neither happens |
| `scenarioAPage_not_head` | the page an earlier revision of this module used to derive a "silent, permanent divergence" is a snapshot of no server state (it shows seq 9 and id 1 at seq 5 — I5 forbids it). That finding is withdrawn |
| `identical_patch_pull_livelock_witness` · `identicalServer_head` | Scenario F, the v1.3 `[]` rule: PATCH → `[]` from the short-circuit, the head page is empty (proved to be the head page), the replica is unchanged, the next flush PATCHes again — "pull first" never reaches the three-way because the feed never carries the row |
| `verify_drops_when_base_moved_witness` | design interleaving (ii): the PATCH built with seq 5 arrives after a pull applied the peer's X@6 as a conflict; `[]`; unseen; the rule drops the entry with the hash untouched and the next flush PATCHes with seq 6 and lands. The refuted rule (`pullVerifyNaive`, hash from the live row, no seq check) marks c1 clean: never uploaded |
| `verify_writes_sent_not_live_witness` | design interleaving (iii): the user edits to c3 between the `[]` and the verify pass; the rule writes `sentHash`, c3 stays dirty and lands; recomputing from the live row marks c3 clean: never uploaded |
| `edit_beats_delete_without_row_witness` | the pending-delete row, composed: a pending local delete meets a peer's live edit — the row keeps the local side absent, shelves the edit, writes the edit's `(h_in, seq)`, and `pushDelete` then tombstones the server row. Without the row (the reading review seven rejected) the edit is inserted back, nothing is shelved, and `pushDelete` sends nothing: the delete is dropped without a trace |
| `delete_overrides_concurrent_peer_edit_witness` | the mirror: the delete PATCH has no seq filter, so a pending delete with a stale baseline flips a row the peer edited since, and the peer (clean) applies the tombstone unshelved; the same bytes as a PATCH are refused by I8. Delete beats edit on both paths, the direction the text chose |
| `post_onto_tombstone_never_lands_witness` · `deadServer_after_post_head` | an ignore-duplicates POST of a UUID the server holds as a TOMBSTONE is DO NOTHING every flush: a seq is burned, no row, no entry, the head pull is empty (proved), the next flush POSTs again; "等回声拉取补基线后走 PATCH" never terminates for that id and only `sync.push.orphan` fires. The undelete RPC is the only exit |
| `fresh_local_vs_remote_same_id_witness` | the M1 branch as a chain (a restore on two devices pushing the same UUID): the POST is swallowed, the pull files the peer's row as a conflict with baseline `(h_in, seq)`, the next flush is a PATCH against that seq and lands; with the same bytes the row is `same` and reads clean |
| `conflict_then_revert_reads_clean_witness` · `keep_hash_state_not_sound` · `revertServer_head` | against the superseded writing (`decideRowKeepHash`, `34a7810`'s "hash 不动保持脏"): after a conflict a local revert to the pre-conflict bytes reads CLEAN — nothing is sent, the head pull is empty (proved), the server and the peer hold the remote version at the baseline's own seq while this device shows the old one, the remote version only on this device's shelf; that state violates `BaseHashSound`. Under the table the baseline is the remote row's, the revert is dirty, and the next PATCH lands it |
| `keep_hash_echo_drops_peer_revert_witness` | against the superseded writing (I7): after the conflict the PEER reverts to the pre-conflict bytes; the kept old hash makes the echo row fire on them, they are not shelved, this device's PATCH lands over them and the peer (clean) adopts — the reverted version is on no device, server or shelf. Under the table it is a conflict and both versions are on the shelf |
| `keep_hash_undo_after_pending_delete_witness` | against the superseded writing: a pending local delete meets a peer's edit, then an undo re-adds the exact pre-delete bytes; the kept hash makes them read clean and the row is no longer absent, so neither a PATCH nor the tombstone goes out and the server keeps the peer's edit. Under the table, either the flush comes first and the tombstone lands (`pushDelete` ignores the hash; delete beats edit, the peer's edit on the shelf), or the undo comes first and the PATCH lands the re-added row — two alternative runs, not one |
| `lost_response_residual_witness` | a residual hole independent of the conflict writing, recorded and not closed: our PATCH landed, its `[row]` response was lost, and the user sets the row to exactly the baseline's version (under the table, the server's value at the baseline seq, already on the shelf after a conflict); it reads clean and the pull of our own push adopts over it. A revert to any other value in the same state is dirty, refused, filed against our own push as a conflict, and kept |
| `late_row_response_regresses_witness` · `late_unguarded_page_is_head` · `late_unguarded_breaks_tracking` · `late_guard_run_reachable` | a PATCH `[row]` response arriving after a pull moved the baseline ("两者并存是常态", §6 interleaving (ii)): A's PATCH `seq=eq.5` lands c1 at 6, the user types c3, the peer writes c2 at 7, A's pull files a conflict (baseline `(h2, 7)`, c2 shelved), then the response arrives. Under the guard it is dropped and the next PATCH `seq=eq.7` lands c3 — a `Reachable` run. Under the text's unconditional write the baseline regresses to `(h1, 6)`, c3's PATCH `seq=eq.6` answers `[]`, the ELIGIBLE head pull (proved to be the head page) sees nothing, `base.seq == sentSeq` holds and the confirm branch writes `(h3, 6)`: c3 reads clean, nothing is sent, the server and the peer hold c2, and the peer's next edit is adopted over c3, which is on no shelf and never reached the server: silent divergence (goal 2), then loss (goal 3, I7). That state breaks `BaseTracksFeed` |
| `echo_before_response_shelves_own_push_witness` · `echo_race_reachable` | the C2 shape with the response late (both orders reachable): A's PATCH `seq=eq.5` lands c1 at 6, the user types c3, and a pull shows our own c1 BEFORE the response is applied. The baseline is still `(h0, 5)`, so the decision is `conflict`: our own c1 on the shelf (a `sync.conflict` for a push of ours), baseline `(h1, 6)`, c3 kept; the guarded response is dropped (the unguarded one writes the same baseline) and c3's PATCH lands. Response first: the same baseline, local row and server, and an empty shelf. The revert form — the user sets the row back to c0 after the PATCH — is worse: the echo arriving first finds it clean and ADOPTS our own c1 over the revert, nothing shelved, nothing sent (I7 holds, c0 was clean; the user's last edit is gone); response first keeps c0 and lands it. Nothing is lost in the C2 form; T3b's premise does not hold on these states |
| `unknown_marker_witness` | v1.5's `?` baseline (S4) on concrete runs, with a stand-in hash no content on the run hashes to — a check of the text's arithmetic, not a model of `?`: after a lost response the revert is dirty, the resent PATCH answers `[]`, the verify pass applies a conflict (our own c1 shelved, c0 kept) and c0 lands — `lost_then_revert_reachable`'s hole closed at one self-shelf line. Read as `?` from send to response (S4's "在发送时写下"), it also keeps the revert in the echo-before-response race and lands it, but still shelves our own c1 in the C2 race |
| `inflight_echo_witness` | the variant `decideRowInflight` on both races: an empty shelf and c3 landed in the C2 form, c0 kept and landed in the revert form — the response-first outcomes |
| `lost_then_revert_reachable` | `lost_response_residual_witness`'s hole on a `Reachable` run, through `lose` and with no conflict: the PATCH lands c1, its response is lost, the user sets the row back to the baseline's bytes, which read clean; nothing is sent and the next pull adopts our own c1 over the revert, unshelved. `clean_iff_matches_server` is untouched: the server row's seq is not the baseline's |
| `recv_guard_passes_instance` · `pending_filed_and_verified_instance` · `pending_delete_run_instance` · `pull_pages_converge_reachable_instance` | the constructors the other runs do not take, each on a reachable run: the guard's PASS branch (`recv` with the baseline still on the PATCH's seq writes `(h1, 6)`); a nonempty pending set (`push` answering `[]`, the entry stale by `reachable_sound`) and the `verify` step that consumes it, applying the conflict; `deleteLocal`, the pending-delete row and `pushDelete`; and T5' through `Chain.cons` — a fresh replica, a page cut before the second row, a peer's write between pages, the head page landing every id on the server's live content |
| `ineligible_verify_not_held` · `unguarded_confirm_not_held` | `BaseHeld` is not vacuous: the ineligible verify pass and the unguarded late write followed by the confirm each leave a baseline naming a version no state of the run held at that seq |
| `late_post_response_guards_witness` | outside `Reachable` (no late POST): two guards the text could state for a POST `[row]` arriving late. The write must happen with the local row absent (a local delete before the response — dropping it lets the echo put the row back). "Entry still absent" leaves a phantom entry after a pulled tombstone — harmless (one no-op tombstone PATCH) unless an undo re-adds the bytes, which then read clean against a dead server row; "entry still absent and cursor below seq" drops it there, but after a limit-cut page that moved the cursor past the seq without showing the id it drops a response the sequential order writes, and files the peer's later edit as a conflict (nothing lost, c2 shelved, our older c1 uploaded over it). Neither cursor-free test reproduces the response-first order on all three runs |
| `ineligible_verify_loses_witness` | design interleaving (i): the verify pass run on a page fetched BEFORE the peer's write (empty from cursor 5; proved a head page of that earlier state and not of the server at verify time) confirms `(h1, 5)`, a pair the server never held, and the next pull adopts c2 over c1 with nothing shelved. Not a `Reachable.verify` step |
| `restore_replay_local_hash_witness` | restore's baseline replay as slice 1 has it (and the round-nine §13 row describes it; v1.5 S6 replaces it with the cloud-row writing), `(hash(local row), previous seq)`, on a keepLocal collision row (local c1, the cloud's c2 at 6): the row reads clean, nothing is uploaded, the server holds c2, and the state violates `BaseHashSound`; the cloud-row writing `(hash(cloud row), cloud seq)` reads dirty and the next PATCH lands c1. Not a `Reachable` constructor — the reason `reachable_sound` is about the writers the model has |
| `singleton_dirty_tombstone_lost_on_undelete_witness` · `singleton_dirty_keeps_hash_witness` · `singleton_concurrent_dirty_last_writer_witness` | the singleton tombstone rule on a DIRTY row: the text's `(hash(local), seq)` makes an unpushed edit clean, it is never uploaded, and an undelete (#140) brings the dead row's bytes back over it with nothing shelved — c1 on no device, server or shelf, contrary to the text's "不丢任何一方". The variant that keeps a dirty row's old hash (`applyTombstoneKeepDirty`) writes the edit into the dead row once, then reaches the fixed point on both devices, and the undelete restores it; two devices dirty at the same tombstone still keep only the last dead-row writer (the dead row is last-writer-wins with no shelf), where the text's writing loses both |
| `singleton_dead_period_edit_lost_witness` | the singleton loss is not limited to an edit dirty at the dashboard tombstone: A and B took the tombstone cleanly, then each edited during the dead-row period; A's PATCH writes c1 into the dead row, B's answers `[]`, B takes the dead row and the rule makes it clean over its unsent c2 — nothing sent; the undelete brings c1 back and B adopts it, unshelved. T10d's third conjunct holds for this dirty B |
| `singleton_stale_tombstone_skipped_witness` | the singleton skip row is load-bearing: after a dead-row write the baseline is `(h1, 8)` and the stale tombstone at 7 is skipped; without the skip row the baseline regresses to `(h1, 7)` and the next edit's PATCH `seq=eq.7` answers `[]` |
| `singleton_edit_to_dead_bytes_witness` | the case T10d's `v ≠ c0` leaves out: an edit back to the dead row's bytes is a content-identical PATCH, `[]`, nothing minted, still dirty, a pull wanted — closed in the design by the singleton pending-verify, which `Singleton` does not model |
| `singleton_shelve_variant_keeps_both_witness` | `applyTombstoneShelve` on both runs that lose under the text's writing: dirty at the dashboard tombstone (the echo case — nothing shelved, one dead-row write, the undelete restores the edit everywhere), and two edits in the dead-row period (the second device shelves the first's bytes and writes its own once, the first takes it clean; the undelete restores the second, the first is on a shelf) — nothing lost |
| `namesake_delete_order_witness` | event_types, A creates UUID 3, B creates 7, A deletes 3: if B saw 3 live first, B tombstones its own 7 and A's delete removes the type on both; if B first sees 3 dead, B keeps 7 and A adopts it — A's delete of the title is in effect undone. Both orders converge; which one happens depends on when B pulled, and no theorem composes `resolve` with the table |
| `conflict_then_revert_is_pushed_pending_delete_instance` | `conflict_then_revert_is_pushed` instantiated on its pending-delete form (design §6 case (c)): an unpushed delete meets the peer's edit, an undo re-adds the pre-delete bytes, and they read dirty |
| `settings_conflict_key_revert_witness` | against the superseded per-key baseline (`mergeKeysKeepHash`): a conflict key that kept its old hash reads clean when set back to the old value, and a conflict key deleted under an empty (upgrade branch three) baseline reads clean, while the server holds the remote value; under `mergeKeys` both are dirty |
| `union_literal_pingpong_witness` · `union_canonical_settles_witness` | the analyzed-ids union under an order-sensitive per-key hash: the literal union lets two devices that merged the same set in different orders PATCH each other's order every half round, forever (the four states recur); the sorted union settles after one push |
| `dirty_before_echo_shelves_own_push_witness` | the design's "echo before dirty detection" order: hoisting dirty detection files a same-hash row (a peer's write landing back on our bytes; the own-push echo at the same seq is the skip row's once the response is applied — before it, it is a conflict in either order, `echo_before_response_shelves_own_push_witness`) as a conflict |
| `echo_before_tombstone_keeps_deleted_row_witness` | the tombstone check must precede the echo check: otherwise every delete of a row we pushed reads as an echo and never deletes locally (`applyRow_clean_lands`, hence T5, fails). §6 already has tombstone first; this is a do-not-reorder guard |
| `naive_dead_namesake_erases_live_type_witness` | Scenario D: if a TOMBSTONED namesake competed for the smallest UUID, B pulling A's tombstone of the smaller UUID would replace its live type with a dead row and tombstone its own — the type vanishes on both devices unshelved. `resolve` ignores dead namesakes (adopted by the round-eight text) |
| `union_undoes_shrink_witness` | the literal analyzed-ids union: a side that SHRANK the set is unioned back. The restore paths (`SyncedSettings.apply` keep-cloud, `SyncedSettings.replace`) do shrink the set while keeping the key, so the next merge after such a restore undoes it for this key (adopted by the round-eight text) |

Modelling decisions, by status. Adopted by the round-eight/nine
working-tree text (model and working tree agree; `34a7810` is silent or
says otherwise): `mergeKey` treats "both sides changed to the same
bytes" as no conflict; a remote key deletion overridden locally is
shelved as `{key, remote: absent}`; the event_types winner ranges over
live namesakes only; the conflict and pending-delete rows write
`(h_in, seq)` (replacing `34a7810`'s `(h_base.hash, seq)`); the
settings per-key baseline after a merge is the remote value's hash on
every key, conflict keys included; the analyzed-ids union is written
back sorted. Decided by the model and NOT in the text yet: a late PATCH
`[row]` is written only if the baseline seq is still the PATCH's
(`Replica.recv`; the text's unconditional write is
`late_row_response_regresses_witness`). Kept as the text has it, with
the cost recorded: the singleton tombstone writes `(hash(local), seq)`
for a dirty row too — an edit dirty at the dashboard tombstone, or any
edit concurrent with another device's in the dead-row period, is erased
(`singleton_dirty_tombstone_lost_on_undelete_witness`,
`singleton_dead_period_edit_lost_witness`; the alternatives are
`applyTombstoneKeepDirty`, last dead-row writer wins unshelved, and
`applyTombstoneShelve`, nothing lost); and our own push's echo pulled
before its response is a conflict, or an adopt over a revert
(`echo_before_response_shelves_own_push_witness`; the alternative is
`decideRowInflight`). Matching
`34a7810` with no ambiguity: an incoming tombstone with the local row
absent and a baseline present REMOVES the entry ("基线若有 id 一并移除");
the pending-delete row decides as the dirty row with the local side
absent (`conflict`, local stays absent). Left open by the text and fixed
by the model (also reported in the gh#257 thread): the echo row writes
`(hIn, seq)`, equal to `(base hash, seq)` in that branch; a pushed delete
drops the baseline entry whether or not the PATCH flipped the row; the
skip row is checked before the tombstone row, as the text has it; the
analyzed-ids union fires whenever both sides are non-nil, literally; a
non-nil side that loses to a deletion is shelved iff it had moved from
the baseline, and a double deletion shelves nothing (model-added — the
text says only "传播"); one side nil with NO baseline falls to the
general rule and keeps the non-nil side; a local key deletion counts as
a change and wins a both-changed conflict; `pullVerify` counts an
entry as seen iff a row for its id was applied in that pull (past the
cursor), checks `base.seq == sentSeq` on the unseen ones, and does not
look at the local row; a POST miss sets `needsPull` (the id waits for
its echo) but files no pending entry; the dead-row PATCH branch files no
pending entry and asks for no pull. "Echo after a second edit within one
pull" is not a separate case: `sync_changes` returns one current row per
id, so a page cannot carry both versions, and the cases reduce to T3b
and Scenario A (`stale_feed_row_regresses_witness`: under `==` our own
v2 regresses to v1 when the page snapshotted between two of our pushes
is applied after both; under `≤` it is skipped).

### `sync-fixtures.json` — the replay contract

`cd verification && lake exe syncfixturegen` writes `sync-fixtures.json`
into the working directory (the generator refuses to run where
`lakefile.toml` is absent); it is committed so the Swift replay runs
without Lean. A JSON array; one object per decision-table case over the
full product of: tombstone or live; `h_in` from three tokens; `h_loc`
absent or one of the three; `h_base` absent or one of the three at
either of two seqs; `in_seq` from a range that, for each of the two
baseline seqs, holds a value strictly below it, the value equal to it,
and a value strictly above it. Every `expected` is `decideRow`'s output
— never hand-written. **The table and the fixtures are the six id
tables; the three singleton tables (user_settings, agent_preferences,
agent_conversations) take the §6 单行表 rule and are not in this file.**
No Swift consumer exists yet; the replay lands with Phase 1 and this
file is its contract.

```
{
  "label":     string        — human-readable; not part of the contract
  "tombstone": bool          — the incoming row has deleted_at ≠ null
  "h_in":      string        — rowHash of the incoming row (opaque token "A"|"B"|"C")
  "h_loc":     string|null   — rowHash of the local row; null = no local row
  "h_base":    string|null   — baseline hash for the id; null = no baseline entry
  "base_seq":  int|null      — baseline seq; null iff h_base is null
  "in_seq":    int           — the incoming row's seq
  "expected": {
    "action":       "skip"|"tombstone"|"echo"|"same"|"adopt"|"conflict"
                              — the §6 row that fired: FIRST match in table order
    "base_hash":    string|null — baseline hash after apply; null = entry removed
    "base_seq":     int|null    — baseline seq after apply; null iff base_hash is null
    "shelf_remote": bool        — the incoming row is appended to the shelf
    "shelf_local":  bool        — the local row is appended to the shelf (before any remote entry)
  }
}
```

Semantics the replay must implement, exactly:

- Hashes are compared for equality only. The three tokens are distinct
  opaque values; substitute any three distinct real `rowHash` strings
  consistently within a case.
- `dirty := h_loc ≠ h_base`, where `null` is a value: `null ≠ "A"`,
  `null = null`.
- Table order: `in_seq ≤ base_seq` (skip; never fires when `h_base` is
  null) → tombstone → `h_in = h_base` (echo) → `h_in = h_loc` (same) →
  `h_loc = null ∧ h_base ≠ null` (conflict — the pending-delete row,
  "按 dirty 处理") → `¬dirty ∨ h_loc = null` (adopt; after the previous
  row this is reachable with `h_loc = null` only when `h_base` is null
  too) → otherwise (conflict).
- Local content after apply is a function of `action`: tombstone →
  removed; adopt → replaced by the incoming row; skip, echo, same,
  conflict → unchanged. A `conflict` with `h_loc = null` keeps the local
  side ABSENT — the pending local delete is kept and its tombstone PATCH
  goes out on the next flush.
- `expected.base_hash`/`base_seq` is the whole new baseline entry:
  skip → `(h_base, base_seq)` unchanged; tombstone → `null`/`null`
  (entry removed, also when `h_loc` is null); echo, same, adopt and
  conflict — both conflict rows, with or without a baseline →
  `(h_in, in_seq)` (on echo `h_in = h_base`). So every non-skip case has
  `base_hash ∈ {h_in, null}`, `null` exactly on tombstone, and
  `base_seq = in_seq` whenever it is not null — a structural check the
  replay can assert on its own, before comparing case by case.
- `shelf_local` is true iff `action = tombstone ∧ h_loc ≠ null ∧ dirty`;
  `shelf_remote` is true iff `action = conflict`. A case never sets both.
- The cases are the table as the text states it: no input says whether a
  PATCH for the id is outstanding. If the design adopts the in-flight
  echo (`decideRowInflight`), the core gains that input (the outstanding
  PATCH's sent hash), the variant becomes `decideRow`, and this file is
  regenerated.
- The seq enters the decision in exactly one place, the skip row, and
  the skip row is `≤`: a case with `in_seq < base_seq` decides `skip`
  exactly like one with `in_seq = base_seq`, and `base_seq` after =
  `in_seq` whenever a non-skip row writes an entry. This pins the
  round-eight working-tree table. The replay must not be made to pass
  by special-casing the strictly-below cases; if the design reverts to
  `==`, `decideRow` takes `decideRowEq`'s row, the fixtures are
  regenerated, and those cases change.

The pre-commit hook's fixture-staleness check covers `fixtures.json`
only; regenerate `sync-fixtures.json` by hand after touching
`SyncMerge.lean` or `SyncMain.lean` until the hook learns the second
file (the hook's `lake build` does cover the generator, which is a
default target).

## Server restore and the epoch (gh#257) — bounded exhaustive search

`CivilCalendar/SyncRestore.lean` models design §5.7 item 7, §6.6, D10 and
§7 handoff (8) as written at 021860e: the `sync_epoch` row (`epoch`,
`floor`, cumulative `lost`, `paused`), `restore.sh` (setval stripped,
`lost := <restored row's lost> + (F, L]`), a restore that bypassed the
script, an aborted restore whose setval already ran, the standalone
`restore_with_epoch.sql`, rollback and re-enable, agent writes, and two
devices running the §6 table (`decideRowBody` from `SyncMerge.lean`, the
`?` hash as a reserved value) with the §6.6 reset, pending-verify and the
outbound pause gate. Instead of proofs it enumerates: breadth-first over
every action sequence up to a length bound, each distinct world settled to
quiescence and checked against P1 (converged), P2 (no protected version
lost — every version a device ever held, every agent version no restore
discarded, is live or shelved or an ancestor of one) and P3 (the final
value never reverts a version the restore kept); P3s (a revert onto a
version a restore discarded and a device resurrected — the restore-fork
cost) is reported, not required. The header of the file states each
definition and every modelling limit (no deletes, atomic pulls and
flushes, two devices, at most two rows).

**Build-time checks** (`lake build`): `#guard` replays of the reported
counterexamples, the positive controls (X4, X5, local-wins-after-any-epoch)
and one ablation per part of the recommended rule, plus a small exhaustive
search (`buildBounds`) that must find P2 under the current text and nothing but
P3s under the recommended rule.

**The large search:** `lake exe syncrestoresearch [depth1] [depth2]
[rule-name-prefix]` prints, per rule and per scenario family, the number of
distinct worlds checked, the violations by class, and a shortest witness
for each class. Families: one row with every operator action (bypass and
abort followed at once by the standalone step, ops/README R3), one row with
`restore.sh` only, two rows with every operator action, and one row with
the window after a bypass / abort left open (the §9.37 residual; it fails
for every rule).

## Pre-commit gate (opt-in, change-triggered)

`verification/githooks/pre-commit` is a shareable git hook that runs ONLY
the fast checks and ONLY when a commit actually touches formalized ground —
it is silent on the ~95% of commits that don't, so it stays trusted rather
than trained-around. Install once per clone:

```
bash verification/githooks/install.sh   # sets core.hooksPath
```

What it does, by staged-diff class:
- **Lean files changed** → `lake build` (BLOCKS on a broken proof).
- **Model / fixture-generator changed** → regenerates and BLOCKS if the
  committed `fixtures.json` is stale (model moved, fixtures not regenerated).
- **Mirrored Swift changed** (`Event`/`EventStore`/`EventZone`,
  `CalendarLayout`, the report builders, the Supabase sync seam) with no
  model/test update → **advisory only**: names the on-simulator replay/
  shadow/property suite that is the real model↔code drift gate. That suite
  is too slow for pre-commit, so the hook advises rather than pretends to
  run it.

Degrades gracefully: a developer without the Lean toolchain is never
blocked (lake stays a local gate; CI has no Lean). Bypass a single commit
with `git commit --no-verify` or `FV_GATE_SKIP=1 git commit`.

Deliberately NOT a blanket "run the prover / write a proof every commit"
rule — the campaign's own marginal-return data shows most code is
unformalizable and the civil-arithmetic yield is now near-exhausted;
forcing formalization per commit would only breed tautological models.
The standing regression gate is the differential test suite (already in
`xcodebuild test`); this hook is just the cheap, precise pre-commit
tripwire in front of it.

## Layout

```
verification/
  lean-toolchain              pinned Lean version (v4.33.1)
  lakefile.toml               lib CivilCalendar + exes fixturegen, syncfixturegen, syncrestoresearch
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
  CivilCalendar/SyncMerge.lean the gh#257 sync merge model (design v1.4 @ 34a7810 + rounds eight/nine): T1–T10, the reachability and tracking invariants, reachable states (late PATCH responses, eligible verify; BaseHashSound, BaseTracksFeed, BaseHeld), the limit-cut page chain, the singleton rule, witnesses
  CivilCalendar/SyncRestore.lean the gh#257 server-restore / epoch model: bounded exhaustive search, replays, controls, ablations
  Main.lean                   window-checked JSON emitter
  SyncMain.lean               sync decision-table emitter
  SyncRestoreMain.lean        restore-model search driver (prints state counts and witnesses)
  fixtures.json               generated; committed so tests run without Lean
  sync-fixtures.json          generated; committed so the Swift replay runs without Lean
```

Midnight tables were sourced 2026-09-03 from python `zoneinfo` (system
tzdata) — a third implementation independent of both the model and
Foundation. The three `expectedFoundation` pins were measured the same day
with a host-Foundation probe (macOS).
