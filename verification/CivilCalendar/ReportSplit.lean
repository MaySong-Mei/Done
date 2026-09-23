import CivilCalendar.Recurrence

/-!
# Report day-split conservation (gh#220 slice 2)

Models the daily report's splitting arithmetic
(`ReportStatsBuilder.overlapSharedDayHours` / `Event.overlapSharedHours` /
`Event.elapsedWindowCut`) and proves the conservation laws the aggregates
lean on but no test pins.

The Swift implementation is a boundary sweep; its SEMANTICS is pointwise —
at every second, each of the `k` active contributors earns `1/k` of that
second. The model states the pointwise semantics directly with a GENERIC
integer weight `w : Nat → Int` of the active count, so no division appears
anywhere: instantiating `w k = scale / k` (with `k ∣ scale`) is the
consumer's one-line trivia, while the theorems carry the combinatorial
content — window additivity and the civil-day partition. The fixture seam
carries the sweep ≡ pointwise equivalence empirically, replaying
`ReportStatsBuilder.build` against pointwise-computed expectations.

Deliberately NOT stated: `sessionDaily ≡ dailyTotals` — the two aggregates
disagree by design for window-edge occurrences
(`ReportStatsBuilder.swift:863-869`); a conservation theorem equating them
would be false and the divergence is intentional.
-/

namespace Verification

/-- Number of integer seconds `t ∈ [lo, lo + n)` satisfying `p`. -/
def countP (p : Int → Bool) (lo : Int) : Nat → Nat
  | 0 => 0
  | n + 1 => (if p lo then 1 else 0) + countP p (lo + 1) n

/-- Pointwise credit for one contributor over `[lo, lo + n)`: each second
where `mine` holds earns `w (k t)`, where `k` is the frame-wide active
count. `w` is arbitrary — the theorems hold for every sharing rule. -/
def credit (mine : Int → Bool) (k : Int → Nat) (w : Nat → Int) (lo : Int) :
    Nat → Int
  | 0 => 0
  | n + 1 => (if mine lo then w (k lo) else 0) + credit mine k w (lo + 1) n

/-- Coverage never exceeds the window: at most one credited second per
second. -/
theorem countP_le (p : Int → Bool) (lo : Int) (n : Nat) :
    countP p lo n ≤ n := by
  induction n generalizing lo with
  | zero => simp [countP]
  | succ m ih =>
    have h := ih (lo + 1)
    unfold countP
    split <;> omega

/-- THEOREM 18 (window additivity): credit over `[lo, lo+m+n)` is the sum
of the credits over `[lo, lo+m)` and `[lo+m, lo+m+n)` — the sweep's
cut-invariance, pointwise. -/
theorem credit_add (mine : Int → Bool) (k : Int → Nat) (w : Nat → Int)
    (lo : Int) (m n : Nat) :
    credit mine k w lo (m + n)
      = credit mine k w lo m + credit mine k w (lo + m) n := by
  induction m generalizing lo with
  | zero => simp [credit]
  | succ j ih =>
    have h := ih (lo + 1)
    have hshift : lo + 1 + (j : Int) = lo + ((j : Int) + 1) := by omega
    calc credit mine k w lo (j + 1 + n)
        = credit mine k w lo (j + n + 1) := by
          have : j + 1 + n = j + n + 1 := by omega
          rw [this]
      _ = (if mine lo then w (k lo) else 0)
            + credit mine k w (lo + 1) (j + n) := rfl
      _ = (if mine lo then w (k lo) else 0)
            + (credit mine k w (lo + 1) j + credit mine k w (lo + 1 + (j : Int)) n) := by
          rw [h]
      _ = credit mine k w lo (j + 1) + credit mine k w (lo + ((j : Int) + 1)) n := by
          rw [hshift]
          show _ = (if mine lo then w (k lo) else 0) + credit mine k w (lo + 1) j + _
          omega

/-- Credit summed day by day, `m` civil days from day `a`. -/
def daySplitCredit (c : CivilCalendar) (mine : Int → Bool) (k : Int → Nat)
    (w : Nat → Int) (a : Int) : Nat → Int
  | 0 => 0
  | m + 1 =>
      credit mine k w (c.midnight a) (c.midnight (a + 1) - c.midnight a).toNat
        + daySplitCredit c mine k w (a + 1) m

/-- THEOREM 19 (civil-day partition conservation — the missing test): the
per-day credits sum to the whole-window credit, for EVERY day-length
history and EVERY sharing rule. This is what `dailyTotals` and
`perTypeHours` silently rely on when they re-derive the sharing
denominator per day (`ReportStatsBuilder.swift:829-856`): cutting the
sweep at civil midnights moves no value across the cuts. -/
theorem daySplit_conserves (c : CivilCalendar) (mine : Int → Bool)
    (k : Int → Nat) (w : Nat → Int) :
    ∀ (m : Nat) (a : Int),
      daySplitCredit c mine k w a m
        = credit mine k w (c.midnight a) (c.midnight (a + m) - c.midnight a).toNat := by
  intro m
  induction m with
  | zero => intro a; simp [daySplitCredit, credit]
  | succ j ih =>
    intro a
    have hlen0 : c.midnight a ≤ c.midnight (a + 1) := c.midnight_le_of_le (by omega)
    have hspan : c.midnight (a + 1) ≤ c.midnight (a + 1 + (j : Int)) :=
      c.midnight_le_of_le (by omega)
    have harg : a + 1 + (j : Int) = a + ((j : Int) + 1) := by omega
    rw [harg] at hspan
    have hsum : ((c.midnight (a + 1) - c.midnight a).toNat
          + (c.midnight (a + ((j : Int) + 1)) - c.midnight (a + 1)).toNat)
        = (c.midnight (a + ((j : Int) + 1)) - c.midnight a).toNat := by
      omega
    have hadd := credit_add mine k w (c.midnight a)
      (c.midnight (a + 1) - c.midnight a).toNat
      (c.midnight (a + ((j : Int) + 1)) - c.midnight (a + 1)).toNat
    have hmid : c.midnight a + ((c.midnight (a + 1) - c.midnight a).toNat : Int)
        = c.midnight (a + 1) := by omega
    rw [hmid] at hadd
    have hidx : a + ((j + 1 : Nat) : Int) = a + ((j : Int) + 1) := by omega
    unfold daySplitCredit
    rw [ih (a + 1), harg, hidx, ← hsum, hadd]

/-- THEOREM 20 (the ":845 ceiling", civil-corrected): a day's union
coverage never exceeds the day's OWN civil length — 23 h on a
spring-forward day, 25 h on a fall-back day. The Swift comment says "a day
can no longer exceed 24h through parallel events"; the true bound is the
day's length, and the fixtures pin the 82 800/90 000 s instances. -/
theorem day_total_le_civil_length (c : CivilCalendar) (p : Int → Bool)
    (a : Int) :
    countP p (c.midnight a) (c.midnight (a + 1) - c.midnight a).toNat
      ≤ (c.midnight (a + 1) - c.midnight a).toNat :=
  countP_le p _ _

/-- THEOREM 21 (elapsed-clamp bounds — `Event.elapsedWindowCut`): the cut
is the identity inside the window and clamps to the nearer edge outside;
in particular `start ≤ cut ≤ end` whenever `start ≤ end`, and the elapsed
span `cut − start` sits in `[0, end − start]`. Pinned empirically by
`AnalysisWeekStatsTests.testElapsedWindowCutBounds`; stated here so the
clamp's algebra is frozen with the rest of the family. -/
theorem elapsedWindowCut_bounds (windowStart windowEnd asOf : Int)
    (h : windowStart ≤ windowEnd) :
    windowStart ≤ min (max asOf windowStart) windowEnd
      ∧ min (max asOf windowStart) windowEnd ≤ windowEnd
      ∧ 0 ≤ min (max asOf windowStart) windowEnd - windowStart
      ∧ min (max asOf windowStart) windowEnd - windowStart
          ≤ windowEnd - windowStart := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> omega

/-- THEOREM 22 (renormalization conservation, scaled): however wrong the
segment lengths are — and on DST days
`ReportStatsBuilder.segmentSeconds`' `date(bySettingHour:)` arithmetic IS
wrong — the time-of-day shares sum back to exactly `net`, because each
share is `net · seg / gross` with `gross = Σ seg`. Stated scaled (multiply
through by `gross`) so no division appears: the numerators
`net · seg_j` sum to `net · gross`. The single division at the end is the
consumer's trivia; THIS is why the DST fragility is contained
(`ReportStatsBuilder.swift:1019-1024`). -/
theorem renormalization_conserves (net : Int) :
    ∀ (segs : List Int),
      (segs.map (net * ·)).foldl (· + ·) 0 = net * segs.foldl (· + ·) 0 := by
  have hgen : ∀ (segs : List Int) (acc : Int),
      (segs.map (net * ·)).foldl (· + ·) (net * acc)
        = net * segs.foldl (· + ·) acc := by
    intro segs
    induction segs with
    | nil => intro acc; simp
    | cons x xs ih =>
      intro acc
      have h := ih (acc + x)
      simp only [List.map, List.foldl]
      have hdist : net * acc + net * x = net * (acc + x) := by
        rw [Int.mul_add]
      rw [hdist, h]
  intro segs
  have := hgen segs 0
  simpa using this

/-- THEOREM 23 (baseline-slide mismatch — constructive witness): the
previous-window seed `previousStart = start − length`
(`ReportStatsBuilder.swift:63`) is ABSOLUTE arithmetic, so across a DST
transition the two windows touch different numbers of civil days: in
`dstCal`, the two-flat-day window `[86400, 259200)` touches three civil
days while its absolute-length predecessor `[-86400, 86400)` touches two.
Baseline day-vectors are therefore not length-aligned across transitions —
documented divergence, not a repair (the fix would be civil-length
windows, a product decision). -/
theorem baseline_slide_witness :
    (dstCal.dayOf 259199 - dstCal.dayOf 86400)
      ≠ (dstCal.dayOf 86399 - dstCal.dayOf (-86400)) := by
  decide

/-- Tail-recursive evaluator for `credit`, verified against the spec below —
the fixture generator runs THIS (a civil day's recursion depth would
otherwise ride the call stack). -/
def creditT (mine : Int → Bool) (k : Int → Nat) (w : Nat → Int) :
    Int → Nat → Int → Int
  | _, 0, acc => acc
  | lo, n + 1, acc =>
      creditT mine k w (lo + 1) n (acc + (if mine lo then w (k lo) else 0))

theorem creditT_eq (mine : Int → Bool) (k : Int → Nat) (w : Nat → Int) :
    ∀ (n : Nat) (lo acc : Int),
      creditT mine k w lo n acc = acc + credit mine k w lo n := by
  intro n
  induction n with
  | zero => intro lo acc; simp [creditT, credit]
  | succ j ih =>
    intro lo acc
    unfold creditT credit
    rw [ih]
    omega

end Verification
