import CivilCalendar.Recurrence

/-!
# Month/year arms — the clamped step algebra (gh#224 slice 1)

The part `Recurrence.lean` deliberately left out, now modeled on its own
civil-DATE layer: month/year matching never touches midnights or day
indices, so the algebra lives on (month ordinal, day-of-month) pairs with
one axiomatized Foundation behavior — `date(byAdding:)`'s SINGLE-HOP
min-clamp, host-probed at exploration (Jan 31 + 1 mo = Feb 28;
Jan 31 + 2 mo = Mar 31, NOT Feb 28 + 1 mo; step sequence strictly
monotone over an 8-base × 60-month sweep). The fidelity claim is BOUNDED
to `k ≥ 0` — the only domain the walk uses: QA's 8154-case month-end
sweep found Foundation is NOT single-hop min-clamp for a characterized
negative-`k` family (leap-year base, `.month` unit, landing in the
February two years back with day ≥ 29 resolves to Mar 1, ten measured
cases). Nothing in the app steps a series backwards; the bound is stated
so the claim cannot rot universal (the Khartoum lesson, again).

The prose claims these theorems replace (verbatim sites in the
exploration record, gh#224):

* "Count REALIZED occurrences, not calendar months — a Jan-31 monthly
  series skips Feb/Apr/… so those steps must not consume the afterCount
  budget" (`CalendarLayout.swift:117`);
* "a Feb-29 yearly series skips non-leap years" (`:130`);
* the `cappedAt` gate-soundness gloss (`Event.swift:1938`);
* the split's `elapsed + remaining` agreement (`Event.swift:1349`).

Foundation's `dateComponents` month/year DISTANCE credits a clamped
landing as a full unit (Jan 31 → Feb 28 reads 1 month) — NOT ordinal
difference. The matcher only consumes distances on day-of-month-MATCHED
days, where `clampAdd_exact` collapses clamp-credit to plain ordinal
arithmetic; the fixtures therefore probe matched days, and the model
never states a distance claim for unmatched ones.
-/

namespace Verification

/-- A month-length assignment: month ordinal → day count, with only the
Gregorian-shaped bounds assumed. Theorems quantify over every such
assignment; `gregorian` below instantiates the real rule for fixtures. -/
structure MonthAlgebra where
  monthLen : Int → Int
  len_lo : ∀ m, 28 ≤ monthLen m
  len_hi : ∀ m, monthLen m ≤ 31

/-- A civil date: month ordinal (months since a fixed epoch month) and
1-based day-of-month. -/
structure CivilDate where
  month : Int
  day : Int
deriving DecidableEq

namespace MonthAlgebra

variable (A : MonthAlgebra)

/-- The date is well-formed in the algebra. -/
def Valid (a : CivilDate) : Prop := 1 ≤ a.day ∧ a.day ≤ A.monthLen a.month

/-- `calendar.date(byAdding: .month, value: k, to:)` as measured: advance
the month ordinal by `k`, min-clamp the day into the landing month.
SINGLE-HOP — clamping never accumulates. -/
def clampAdd (a : CivilDate) (k : Int) : CivilDate :=
  ⟨a.month + k, min a.day (A.monthLen (a.month + k))⟩

/-- Step `k` REALIZES: the landing month is long enough for the series'
day-of-month to survive the clamp. -/
def Realizes (a : CivilDate) (k : Int) : Prop :=
  a.day ≤ A.monthLen (a.month + k)

instance (a : CivilDate) (k : Int) : Decidable (A.Realizes a k) := by
  unfold Realizes; infer_instance

/-- THEOREM 34 (matched-day exactness — the divergence trap defused): a
step lands UNCLAMPED exactly when it realizes, and then the landing is
plain ordinal arithmetic. Everywhere the matcher consumes a distance, the
day-of-month equality has already forced this case. -/
theorem clampAdd_exact (a : CivilDate) (k : Int) (h : A.Realizes a k) :
    A.clampAdd a k = ⟨a.month + k, a.day⟩ := by
  unfold clampAdd
  unfold Realizes at h
  congr 1
  omega

/-- THEOREM 35 (clamped landings never fake a match): when a step does NOT
realize, the landed day-of-month is strictly below the series' — so the
matcher's `targetDayOfMonth == seriesDayOfMonth` test refuses every
clamped landing. Day-of-month equality IS realization. -/
theorem clamped_landing_day_lt (a : CivilDate) (k : Int)
    (_hv : A.Valid a) (h : ¬ A.Realizes a k) :
    (A.clampAdd a k).day < a.day := by
  unfold clampAdd
  unfold Realizes at h
  simp only []
  omega

/-- THEOREM 36 (step monotonicity, the probe's zero-violation sweep as
arithmetic): month ordinals advance strictly with `k`, so the candidate
sequence can never reorder or collide. -/
theorem clampAdd_month_strict_mono (a : CivilDate) {k k' : Int}
    (h : k < k') :
    (A.clampAdd a k).month < (A.clampAdd a k').month := by
  unfold clampAdd
  simp only []
  omega

/-- Realized candidates among steps `0·step, 1·step, …, (n−1)·step` — the
model of `realizedStepCount`'s walk (uncapped). -/
def realizedCount (a : CivilDate) (step : Int) : Nat → Nat
  | 0 => 0
  | n + 1 =>
      realizedCount a step n
        + (if a.day ≤ A.monthLen (a.month + (n : Int) * step) then 1 else 0)

/-- The capped walk: stops counting at `cap` (the `cappedAt` early
exit). Shape-faithful to `realizedStepCount` for `cap ≥ 1` — Swift's
post-increment early RETURN differs only at `cappedAt: 0` (it returns 1
when the first candidate realizes, this model returns 0); no Swift caller
passes 0, and the encoding of the fixture seam reserves 0 for "nil". -/
def realizedCountCapped (a : CivilDate) (step : Int) (cap : Nat) :
    Nat → Nat
  | 0 => 0
  | n + 1 =>
      if realizedCountCapped a step cap n ≥ cap then
        realizedCountCapped a step cap n
      else
        realizedCountCapped a step cap n
          + (if a.day ≤ A.monthLen (a.month + (n : Int) * step) then 1 else 0)

theorem realizedCount_mono (a : CivilDate) (step : Int) {n n' : Nat}
    (h : n ≤ n') : A.realizedCount a step n ≤ A.realizedCount a step n' := by
  induction n' with
  | zero =>
    have hz : n = 0 := by omega
    subst hz
    exact Nat.le_refl _
  | succ j ih =>
    by_cases hn : n = j + 1
    · subst hn
      exact Nat.le_refl _
    · have hj : n ≤ j := by omega
      have hle := ih hj
      have hstep : A.realizedCount a step (j + 1)
          = A.realizedCount a step j
            + (if a.day ≤ A.monthLen (a.month + (j : Int) * step) then 1
               else 0) := rfl
      rw [hstep]
      split <;> omega

theorem realizedCount_le (a : CivilDate) (step : Int) (n : Nat) :
    A.realizedCount a step n ≤ n := by
  induction n with
  | zero => simp [realizedCount]
  | succ j ih =>
    have hstep : A.realizedCount a step (j + 1)
        = A.realizedCount a step j
          + (if a.day ≤ A.monthLen (a.month + (j : Int) * step) then 1
             else 0) := rfl
    rw [hstep]
    split <;> omega

/-- THEOREM 37 (cap saturation is sound — `Event.swift:1938`'s gloss): the
capped walk agrees with the uncapped one below the cap, saturates AT the
cap, and therefore decides `≥ cap` identically. The returned VALUE above
the cap is not the true count; the GATE VERDICT always is. -/
theorem capped_walk_sound (a : CivilDate) (step : Int) (cap : Nat) :
    ∀ n, A.realizedCountCapped a step cap n
        = min (A.realizedCount a step n) cap
      ∧ (A.realizedCountCapped a step cap n ≥ cap
          ↔ A.realizedCount a step n ≥ cap) := by
  intro n
  induction n with
  | zero =>
    constructor
    · simp [realizedCountCapped, realizedCount]
    · simp [realizedCountCapped, realizedCount]
  | succ j ih =>
    obtain ⟨heq, _⟩ := ih
    have hcap : A.realizedCountCapped a step cap (j + 1)
        = if A.realizedCountCapped a step cap j ≥ cap then
            A.realizedCountCapped a step cap j
          else
            A.realizedCountCapped a step cap j
              + (if a.day ≤ A.monthLen (a.month + (j : Int) * step) then 1
                 else 0) := rfl
    have hrc : A.realizedCount a step (j + 1)
        = A.realizedCount a step j
          + (if a.day ≤ A.monthLen (a.month + (j : Int) * step) then 1
             else 0) := rfl
    rw [hcap, hrc, heq]
    refine ⟨?_, ?_⟩ <;> (split <;> split <;> omega)

/-- The render gate for a candidate at step `n·step`: it must realize, and
fewer than `count` candidates realized before it. Tied to the budget count
by `admittedCount_succ_gate` — this definition IS what `gate_budget`
counts, not an advertisement. -/
def GateAdmits (a : CivilDate) (step : Int) (count : Nat) (n : Nat) : Prop :=
  A.Realizes a ((n : Int) * step) ∧ A.realizedCount a step n < count

instance (a : CivilDate) (step : Int) (count n : Nat) :
    Decidable (A.GateAdmits a step count n) := by
  unfold GateAdmits; infer_instance

/-- Steps admitted below `N`. -/
def admittedCount (a : CivilDate) (step : Int) (count : Nat) : Nat → Nat
  | 0 => 0
  | n + 1 =>
      admittedCount a step count n
        + (if a.day ≤ A.monthLen (a.month + (n : Int) * step)
              ∧ A.realizedCount a step n < count then 1 else 0)

/-- `admittedCount`'s increment is exactly the `GateAdmits` verdict — the
gate definition and the budget count cannot drift apart. -/
theorem admittedCount_succ_gate (a : CivilDate) (step : Int)
    (count n : Nat) :
    A.admittedCount a step count (n + 1)
      = A.admittedCount a step count n
        + (if A.GateAdmits a step count n then 1 else 0) := by
  simp only [admittedCount, GateAdmits, Realizes]
  congr 1

/-- THEOREM 38 (the afterCount budget — "skipped steps must not consume
it", as arithmetic): below any horizon `N`, the gate admits exactly
`min count (realized-below-N)` candidates. A Jan-31 monthly ×5 admits its
first five REALIZED months, however many clamped Februaries sit between
them; a Feb-29 yearly ×N behaves identically across non-leap years. -/
theorem gate_budget (a : CivilDate) (step : Int) (count : Nat) :
    ∀ N, A.admittedCount a step count N
      = min count (A.realizedCount a step N) := by
  intro N
  induction N with
  | zero => simp [admittedCount, realizedCount]
  | succ j ih =>
    have hadm : A.admittedCount a step count (j + 1)
        = A.admittedCount a step count j
          + (if a.day ≤ A.monthLen (a.month + (j : Int) * step)
                ∧ A.realizedCount a step j < count then 1 else 0) := rfl
    have hrc : A.realizedCount a step (j + 1)
        = A.realizedCount a step j
          + (if a.day ≤ A.monthLen (a.month + (j : Int) * step) then 1
             else 0) := rfl
    rw [hadm, hrc, ih]
    split <;> split <;> omega

/-- THEOREM 39 (year arm month-inertia — the Swift belt-and-suspenders
check is inert): yearly stepping is 12-month stepping, and the landing
month-of-year is the anchor's own, always. `monthMatches` in
`realizedStepCount` can never fire for `.year`; it guards nothing. -/
theorem year_step_month_inert (a : CivilDate) (k : Int) :
    (A.clampAdd a (12 * k)).month % 12 = a.month % 12 := by
  unfold clampAdd
  simp only []
  omega

/-- THEOREM 40 (split conservation — `Event.swift:1349`): for an
occurrence the render gate actually admits (`elapsed < N`), the
`.following` split's `remaining = max(1, N − elapsed)` satisfies
`elapsed + remaining = N` exactly; the `max(1, ·)` floor only fires for
`elapsed ≥ N`, which no rendered occurrence can carry. -/
theorem split_conserves (elapsed N : Nat) (h : elapsed < N) :
    elapsed + max 1 (N - elapsed) = N := by
  omega

end MonthAlgebra

/-- The real Gregorian rule, for fixture evaluation: month ordinal `m`
counts months since January of year 0 (`y = m / 12` euclidean,
`mo = m % 12` with 0 = January). -/
def gregorianIsLeap (y : Int) : Bool :=
  y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)

def gregorianMonthLen (m : Int) : Int :=
  if m % 12 = 1 then (if gregorianIsLeap (m / 12) then 29 else 28)
  else if m % 12 = 3 ∨ m % 12 = 5 ∨ m % 12 = 8 ∨ m % 12 = 10 then 30
  else 31

def gregorian : MonthAlgebra where
  monthLen := gregorianMonthLen
  len_lo := by
    intro m
    unfold gregorianMonthLen
    split
    · split <;> omega
    · split <;> omega
  len_hi := by
    intro m
    unfold gregorianMonthLen
    split
    · split <;> omega
    · split <;> omega

end Verification
