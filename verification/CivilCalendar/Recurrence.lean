import CivilCalendar.Theorems
import CivilCalendar.Witness

/-!
# Occurrence expansion — the gh#209 prose proof and its neighbors (gh#220 slice 1)

Models `CalendarLayout.recurrenceOccurrence`'s day/week arms and the probe
span `EventStore.seriesOccurrenceProbeDays` derives, and restates the prose
claims as theorems:

* the probe-span exhaustiveness argument (`EventStore.swift` doc on
  `seriesOccurrenceProbeDays`), timed and all-day branches;
* the 31-anchor cap's safety margin (the one place the prose admits the code
  truncates what the proof covers);
* the day/week arms' exact characterization — matched days are precisely an
  arithmetic progression under the end/count guards;
* the three-way exclusion (取消 / 脱离 / 空槽) from the gh#209 battery;
* the report walker's coverage: the upper bound holds, and the LOWER bound
  has a counterexample witness — a cross-midnight occurrence anchored the
  day before the window overlaps it without its anchor being probed.

Foundation-fidelity premises are stated, not assumed silently: the mint
hypothesis (`midnight d ≤ start < midnight (d+1)`) is exactly the prose's
"an occurrence anchored on D starts inside D's civil day", and the fixture
seam pins the live zones where BOTH mints violate it — on America/Nuuk's
end-of-day gap frame Foundation's wall-clock mint resolves onto the NEXT
day's 23:30 and the model's offset mint overruns the 23-hour day as well
(the theorems are conditional, so the violations are recorded, never
silently assumed away) — or where Foundation diverges from day-index
distance (`dateComponents(.day)` anchored on a midnight-less day).
-/

namespace Verification

namespace CivilCalendar

variable (c : CivilCalendar)

theorem le_dayOf_of_midnight_le {n t : Int} (h : c.midnight n ≤ t) :
    n ≤ c.dayOf t := by
  have hi := c.dayOf_hi t
  by_cases hc : n ≤ c.dayOf t
  · exact hc
  · have hle : c.dayOf t + 1 ≤ n := by omega
    have := c.midnight_le_of_le hle
    omega

theorem dayOf_le_of_lt_midnight {n t : Int} (h : t < c.midnight (n + 1)) :
    c.dayOf t ≤ n := by
  have lo := c.dayOf_lo t
  by_cases hc : c.dayOf t ≤ n
  · exact hc
  · have hle : n + 1 ≤ c.dayOf t := by omega
    have := c.midnight_le_of_le hle
    omega

theorem dayOf_mono {s t : Int} (h : s ≤ t) : c.dayOf s ≤ c.dayOf t := by
  have lo := c.dayOf_lo s
  exact c.le_dayOf_of_midnight_le (by omega)

/-- Chained day-length bound: `m` consecutive civil days cover at least
`82 800·m` seconds. -/
theorem midnight_add_ge_82800 (hmin : c.toCalFns.MinDayLen 82800) :
    ∀ (m : Nat) (n : Int),
      82800 * (m : Int) ≤ c.midnight (n + (m : Int)) - c.midnight n := by
  intro m
  induction m with
  | zero => intro n; simp
  | succ k ih =>
    intro n
    have h1 := ih n
    have h2 := hmin (n + (k : Int))
    have harg : n + ((k + 1 : Nat) : Int) = (n + (k : Int)) + 1 := by omega
    rw [harg]
    omega

/-- THEOREM 9 (probe-span exhaustiveness, timed — the gh#209 prose proof):
an occurrence anchored on day `D` whose start lands inside `D`'s civil day
contains `t` only if `D` lies in the probe span
`[dayOf (t − dur), dayOf t]`. Rule-independent: nothing about HOW `D` was
matched enters the argument. The start-lands-inside-`D` premise is the
prose's own; the Nuuk fixtures pin where Foundation breaks it. -/
theorem probe_span_exhaustive {D start dur t : Int}
    (hs1 : c.midnight D ≤ start) (hs2 : start < c.midnight (D + 1))
    (h1 : start ≤ t) (h2 : t ≤ start + dur) :
    c.dayOf (t - dur) ≤ D ∧ D ≤ c.dayOf t :=
  ⟨c.dayOf_le_of_lt_midnight (by omega),
   c.le_dayOf_of_midnight_le (by omega)⟩

/-- THEOREM 10 (probe-span exhaustiveness, all-day branch): an all-day
occurrence's civil end can exceed `start + raw` by the DST slip inside the
span; the walk still probes `D` provided the residual span
`midnight (D+dc) − midnight (D+1)` fits inside `raw` — the premise the
prose calls "a full civil day of slack". -/
theorem probe_span_exhaustive_allDay {D dc raw t : Int}
    (hspan : c.midnight (D + dc) - c.midnight (D + 1) ≤ raw)
    (h1 : c.midnight D ≤ t) (h2 : t ≤ c.midnight (D + dc) - 1) :
    c.dayOf (t - raw) ≤ D ∧ D ≤ c.dayOf t :=
  ⟨c.dayOf_le_of_lt_midnight (by omega),
   c.le_dayOf_of_midnight_le h1⟩

/-- The slack premise of THEOREM 10 discharged: for the recovered day count
`dc = max 1 ⌈(raw+1)/86400⌋`, any history whose in-span fall-back drift
stays under 3 h (`hdrift`) satisfies it. A single-day mint needs nothing;
multi-day mints lean on the 43 200 s recovery cliff (`dayCount_recovers`). -/
theorem allDay_residual_span_fits (c : CivilCalendar) {D dc raw : Int}
    (hdc : dc = max 1 (CalFns.roundHalfUpDiv (raw + 1) 86400)) (hraw : 0 ≤ raw)
    (hdrift : c.midnight (D + dc) - c.midnight (D + 1)
        ≤ 86400 * (dc - 1) + 10800) :
    c.midnight (D + dc) - c.midnight (D + 1) ≤ raw := by
  simp only [CalFns.roundHalfUpDiv] at hdc
  rw [show (2 : Int) * 86400 = 172800 by decide] at hdc
  by_cases h1 : dc = 1
  · subst h1
    omega
  · omega

/-- THEOREM 11 (the 31-anchor cap never truncates a real span): with civil
days of at least 23 h, a duration up to 2 484 000 s (30 minimum-length
days) spans at most 31 anchors — the `days.count < 31` cap in
`seriesOccurrenceProbeDays` sits strictly outside every drawable block.
The bound is tight: 2 484 001 is unprovable (QA-pinned). Beyond it the
code truncates what the prose proves; that gap is documented, not
defended. -/
theorem probe_count_bounded (hmin : c.toCalFns.MinDayLen 82800) {t dur : Int}
    (h0 : 0 ≤ dur) (hcap : dur ≤ 2484000) :
    c.dayOf t - c.dayOf (t - dur) ≤ 30 := by
  have hab : c.dayOf (t - dur) ≤ c.dayOf t := c.dayOf_mono (by omega)
  by_cases hk : c.dayOf t - c.dayOf (t - dur) ≤ 30
  · exact hk
  · exfalso
    have hlo := c.dayOf_lo t
    have hhi := c.dayOf_hi (t - dur)
    have hm := c.midnight_add_ge_82800 hmin
      (c.dayOf t - c.dayOf (t - dur) - 1).toNat (c.dayOf (t - dur) + 1)
    have hcast : (((c.dayOf t - c.dayOf (t - dur) - 1).toNat : Int))
        = c.dayOf t - c.dayOf (t - dur) - 1 := by omega
    rw [hcast] at hm
    have harg : c.dayOf (t - dur) + 1 + (c.dayOf t - c.dayOf (t - dur) - 1)
        = c.dayOf t := by omega
    rw [harg] at hm
    omega

/-- Distinct anchor days mint distinct, ordered starts — the disjointness
half of expansion: day intervals partition the line, so per-day occurrence
identity cannot collide across anchors. -/
theorem mint_ordered {d d' s s' : Int}
    (h : d < d')
    (hs : c.midnight d ≤ s ∧ s < c.midnight (d + 1))
    (hs' : c.midnight d' ≤ s' ∧ s' < c.midnight (d' + 1)) : s < s' := by
  have := c.midnight_le_of_le (show d + 1 ≤ d' by omega)
  omega

end CivilCalendar

/-! ## The day/week arms in day-index space -/

/-- The two arithmetic recurrence arms. Month/year step through Foundation's
clamping `date(byAdding:)` ("realized count", `Event.swift:1942`) and stay
outside this model by design — no clamping axioms. -/
inductive RecurArm
  | daily (interval : Int)
  | weekly (interval : Int)

/-- Occurrence index for a day-index distance `diff` from the series day —
the port of `recurrenceOccurrence`'s pattern match plus
`recurrenceOccurrenceIndex`'s pure-division day/week arms. `dateComponents`
distance is modeled as day-INDEX distance; the fixture seam pins the one
live divergence (a series anchored ON a midnight-less day undercounts by
one in Foundation, permanently). -/
def RecurArm.index : RecurArm → Int → Option Int
  | .daily k, diff =>
      if 0 < k ∧ 0 ≤ diff ∧ diff % k = 0 then some (diff / k) else none
  | .weekly k, diff =>
      if 0 < k ∧ 0 ≤ diff ∧ diff % 7 = 0 ∧ (diff / 7) % k = 0 then
        some ((diff / 7) / k)
      else none

/-- THEOREM 13a (daily arm, exact characterization at the index level):
a distance matches with index `i` iff it is exactly the `i`-th step of the
progression. -/
theorem daily_index_iff (k diff i : Int) :
    RecurArm.index (.daily k) diff = some i ↔
      0 < k ∧ 0 ≤ i ∧ diff = k * i := by
  simp only [RecurArm.index]
  constructor
  · intro h
    split at h
    · rename_i hcond
      obtain ⟨hk, hd0, hmod⟩ := hcond
      have hi : diff / k = i := Option.some.inj h
      have heq := Int.emod_def diff k
      rw [hmod, hi] at heq
      refine ⟨hk, ?_, by omega⟩
      rw [← hi]
      exact Int.ediv_nonneg hd0 (by omega)
    · simp at h
  · rintro ⟨hk, hi0, rfl⟩
    have hd0 : 0 ≤ k * i := Int.mul_nonneg (by omega) hi0
    have hmod : (k * i) % k = 0 := Int.mul_emod_right k i
    have hdiv : (k * i) / k = i := Int.mul_ediv_cancel_left i (by omega)
    simp [hk, hd0, hmod, hdiv]

/-- THEOREM 14a (weekly arm, exact characterization at the index level). -/
theorem weekly_index_iff (k diff i : Int) :
    RecurArm.index (.weekly k) diff = some i ↔
      0 < k ∧ 0 ≤ i ∧ diff = 7 * (k * i) := by
  simp only [RecurArm.index]
  constructor
  · intro h
    split at h
    · rename_i hcond
      obtain ⟨hk, hd0, hmod7, hmodk⟩ := hcond
      have hi : (diff / 7) / k = i := Option.some.inj h
      have heqk := Int.emod_def (diff / 7) k
      rw [hmodk, hi] at heqk
      have heq7 := Int.emod_def diff 7
      rw [hmod7] at heq7
      have hq0 : 0 ≤ diff / 7 := Int.ediv_nonneg hd0 (by omega)
      have hi0 : 0 ≤ i := by
        rw [← hi]
        exact Int.ediv_nonneg hq0 (by omega)
      refine ⟨hk, hi0, by omega⟩
    · simp at h
  · rintro ⟨hk, hi0, rfl⟩
    have hki0 : 0 ≤ k * i := Int.mul_nonneg (by omega) hi0
    have hd0 : 0 ≤ 7 * (k * i) := by omega
    have hmod7 : (7 * (k * i)) % 7 = 0 := Int.mul_emod_right 7 (k * i)
    have hdiv7 : (7 * (k * i)) / 7 = k * i := Int.mul_ediv_cancel_left (k * i) (by omega)
    have hmodk : (k * i) % k = 0 := Int.mul_emod_right k i
    have hdivk : (k * i) / k = i := Int.mul_ediv_cancel_left i (by omega)
    simp [hk, hd0, hmod7, hdiv7, hmodk, hdivk]

/-- A recurring series after `normalizedRecurrenceRule` repair, in day-index
space: the anchor day, the arm, the gh#127 day-key suppression set
(carrying both 取消 and 脱离), and the end bounds. -/
structure SeriesModel where
  seriesDay : Int
  arm : RecurArm
  suppressed : Int → Bool
  endDay : Option Int
  count : Option Int

namespace SeriesModel

def endOK (s : SeriesModel) (d : Int) : Bool :=
  match s.endDay with
  | some e => decide (d ≤ e)
  | none => true

def countOK (s : SeriesModel) (i : Int) : Bool :=
  match s.count with
  | some n => decide (i < n)
  | none => true

/-- Port of the `recurrenceOccurrence` guard chain (day/week arms),
collapsed to the matched occurrence index. Guard ORDER does not affect the
value, only which guard exits first. -/
def matchIndex (s : SeriesModel) (d : Int) : Option Int :=
  if s.suppressed d then none
  else if s.endOK d then
    match s.arm.index (d - s.seriesDay) with
    | none => none
    | some i => if s.countOK i then some i else none
  else none

/-- THEOREM 12 (取消, and 脱离's template half): a suppressed day never
matches — whatever the arm, bounds, or count say. -/
theorem suppressed_never_matches (s : SeriesModel) (d : Int)
    (h : s.suppressed d = true) : s.matchIndex d = none := by
  unfold matchIndex
  simp [h]

/-- THEOREM 13 (daily arm through the full guard chain): the matched days
are precisely `seriesDay + k·i` for indices `i ≥ 0` passing the guards; the
`afterCount` semantics fall out — indices are progression positions, so
`count` cuts exactly the first `count` occurrences. -/
theorem daily_matches_iff (s : SeriesModel) (k : Int)
    (harm : s.arm = .daily k) (d i : Int) :
    s.matchIndex d = some i ↔
      s.suppressed d = false ∧ s.endOK d = true ∧ s.countOK i = true ∧
      0 < k ∧ 0 ≤ i ∧ d = s.seriesDay + k * i := by
  unfold matchIndex
  rw [harm]
  constructor
  · intro h
    by_cases hsup : s.suppressed d
    · simp [hsup] at h
    · by_cases hend : s.endOK d
      · cases hidx : RecurArm.index (.daily k) (d - s.seriesDay) with
        | none => simp [hsup, hend, hidx] at h
        | some j =>
          by_cases hcnt : s.countOK j
          · simp [hsup, hend, hidx, hcnt] at h
            subst h
            obtain ⟨hk, hi0, hd⟩ := (daily_index_iff k (d - s.seriesDay) j).mp hidx
            exact ⟨by simpa using hsup, hend, hcnt, hk, hi0, by omega⟩
          · simp [hsup, hend, hidx, hcnt] at h
      · simp [hsup, hend] at h
  · rintro ⟨hsup, hend, hcnt, hk, hi0, hd⟩
    have hidx : RecurArm.index (.daily k) (d - s.seriesDay) = some i :=
      (daily_index_iff k (d - s.seriesDay) i).mpr ⟨hk, hi0, by omega⟩
    simp [hsup, hend, hidx, hcnt]

/-- THEOREM 14 (weekly arm through the full guard chain): matched days are
precisely `seriesDay + 7·k·i`. -/
theorem weekly_matches_iff (s : SeriesModel) (k : Int)
    (harm : s.arm = .weekly k) (d i : Int) :
    s.matchIndex d = some i ↔
      s.suppressed d = false ∧ s.endOK d = true ∧ s.countOK i = true ∧
      0 < k ∧ 0 ≤ i ∧ d = s.seriesDay + 7 * (k * i) := by
  unfold matchIndex
  rw [harm]
  constructor
  · intro h
    by_cases hsup : s.suppressed d
    · simp [hsup] at h
    · by_cases hend : s.endOK d
      · cases hidx : RecurArm.index (.weekly k) (d - s.seriesDay) with
        | none => simp [hsup, hend, hidx] at h
        | some j =>
          by_cases hcnt : s.countOK j
          · simp [hsup, hend, hidx, hcnt] at h
            subst h
            obtain ⟨hk, hi0, hd⟩ := (weekly_index_iff k (d - s.seriesDay) j).mp hidx
            exact ⟨by simpa using hsup, hend, hcnt, hk, hi0, by omega⟩
          · simp [hsup, hend, hidx, hcnt] at h
      · simp [hsup, hend] at h
  · rintro ⟨hsup, hend, hcnt, hk, hi0, hd⟩
    have hidx : RecurArm.index (.weekly k) (d - s.seriesDay) = some i :=
      (weekly_index_iff k (d - s.seriesDay) i).mpr ⟨hk, hi0, by omega⟩
    simp [hsup, hend, hidx, hcnt]

end SeriesModel

/-! ## 脱离 and 空槽 -/

/-- A detached occurrence: the nominal day it replaces (suppressed on the
template, gh#127 day-key) and the slot its instance renders — projected
onto the nominal day by the gh#187 read-side projection. -/
structure DetachmentModel where
  nominalDay : Int
  slotStart : Int
  slotEnd : Int

/-- What an instant `t` can be covered by, for one series plus at most one
detachment: a template occurrence on some matched day (single-day mint,
range inside its anchor day), or the detached instance's slot. -/
def coveredBy (s : SeriesModel) (det : Option DetachmentModel)
    (mint : Int → Int × Int) (t : Int) : Prop :=
  (∃ d, (s.matchIndex d).isSome ∧ (mint d).1 ≤ t ∧ t ≤ (mint d).2) ∨
  (∃ dm, det = some dm ∧ dm.slotStart ≤ t ∧ t ≤ dm.slotEnd)

/-- THEOREM 15 (脱离 mutual exclusion + 空槽): on the detached day, with the
template suppressed there and every template mint staying inside its anchor
day, an instant OUTSIDE the moved instance's slot is covered by nothing —
the old slot is genuinely empty, and no instant is ever covered by template
and instance both (the template contributes nothing on that day at all). -/
theorem vacated_slot_uncovered (c : CivilCalendar) (s : SeriesModel)
    (dm : DetachmentModel) (mint : Int → Int × Int)
    (hsup : s.suppressed dm.nominalDay = true)
    (hmint : ∀ d, c.midnight d ≤ (mint d).1 ∧ (mint d).2 < c.midnight (d + 1))
    {t : Int} (hday : c.dayOf t = dm.nominalDay)
    (hout : t < dm.slotStart ∨ dm.slotEnd < t) :
    ¬ coveredBy s (some dm) mint t := by
  rintro (⟨d, hmatch, hlo, hhi⟩ | ⟨dm', hdm, hlo, hhi⟩)
  · have hm := hmint d
    have hdt : c.dayOf t = d := c.dayOf_eq (by omega) (by omega)
    rw [hday] at hdt
    rw [← hdt] at hmatch
    rw [s.suppressed_never_matches dm.nominalDay hsup] at hmatch
    simp at hmatch
  · obtain rfl : dm = dm' := Option.some.inj hdm
    omega

/-! ## The report walker's coverage -/

namespace CivilCalendar

/-- THEOREM 16 (walker upper coverage): `ReportStatsBuilder.expandOccurrences`
walks anchors `dayOf wS … dayOf wE`. Any occurrence whose start lies inside
its anchor day and before the window's end has its anchor within the upper
bound. -/
theorem walker_upper (c : CivilCalendar) {D start wE : Int}
    (hs : c.midnight D ≤ start) (hoverlap : start < wE) :
    D ≤ c.dayOf wE := by
  exact c.le_dayOf_of_midnight_le (by omega)

end CivilCalendar

/-- THEOREM 17 (walker LOWER coverage fails — constructive witness): a
cross-midnight occurrence anchored the day BEFORE the window overlaps the
window without its anchor day being walked: in the flat frame, an
occurrence anchored on day 0 at 23:00 running 2 h (range `[82800, 90000]`)
overlaps the window `[86400, 172800)`, yet its anchor 0 is strictly below
`dayOf 86400 = 1` — `expandOccurrences` starts its walk at
`startOfDay(windowStart)` and never probes it. The canvas's
`timelineCandidateDayOffsets` probes `offset − 1` for exactly this reason;
the report walker does not. Pinned against the real builder by
`LeanRecurrenceReplayTests.testReportWalkerCrossMidnightAnchorPin`. -/
theorem walker_misses_cross_midnight_witness :
    flatCal.midnight 0 ≤ 82800 ∧ (82800 : Int) < flatCal.midnight 1 ∧
    (86400 : Int) < 82800 + 7200 ∧ (82800 : Int) < 172800 ∧
    (0 : Int) < flatCal.dayOf 86400 := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> decide

end Verification
