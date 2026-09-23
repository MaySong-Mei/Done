/-!
# Domino push — the bedrock laws (gh#220 slice 3)

Models `EventStore.dominoPushTodosPastHorizon` and `EventZone.horizonDate`
on the ABSOLUTE time axis — deliberately without `CivilCalendar`: the push
is pure-seconds arithmetic by design (`EventZone.swift:38-48` explains why
mixing civil arithmetic into the filter would desync it from the shift by
an hour on DST days and silently abandon events). The bedrock prose this
freezes (`EventZone.swift:15-23`, `ContentView.swift:148-153`,
`EventStore.swift:392-409`):

* ".nearFuture — system never modifies date here. User has full control."
* ".future — the only zone where the system may mutate the date."
* "kind == .todo (events are user commitments, never moved)"
* "new_start − new_horizon = old_start − old_horizon"

No test pins the never-touch half today (`DominoPushIntervalTests` covers
thresholds and losslessness only); `LeanDominoBedrockTests` adds the
empirical shadow of every theorem here.
-/

namespace Verification

/-- The push-relevant projection of an `Event`: the eligibility fields the
guard chain reads (`EventStore.swift:518-522`), the moved field (`start`,
standing for every range endpoint — the shift is uniform), the length, and
one representative untouched field (`deadline`, standing for the whole
frame condition). -/
structure TodoModel where
  isTodo : Bool
  absorbed : Bool
  recurring : Bool
  hasDate : Bool
  start : Int
  dur : Int
  deadline : Option Int
deriving DecidableEq

/-- `EventZone.horizonDate`: `now + 86 400·horizonDays`, pure seconds — the
`calendar` parameter is accepted and IGNORED in Swift; THEOREM 30 below is
why that must stay so. -/
def horizon (horizonDays now : Int) : Int := now + 86400 * horizonDays

/-- The guard chain: todo, unabsorbed, non-recurring, dated, and at-or-past
the horizon AS OF THE LAST PUSH (`firstStart >= horizonAtLast`, with the
zone boundary's `≥` matching `EventZone.classify`'s "horizon is the first
moment of future"). -/
def eligible (hzLast : Int) (e : TodoModel) : Bool :=
  (e.isTodo && !e.absorbed && !e.recurring && e.hasDate)
    && decide (hzLast ≤ e.start)

/-- The push: a uniform forward translation of eligible rows, nothing else.
`δ = now − last`, guarded positive (`EventStore.swift:472`). -/
def push (δ hzLast : Int) (e : TodoModel) : TodoModel :=
  if 0 < δ ∧ eligible hzLast e then { e with start := e.start + δ } else e

/-- THEOREM 24 (never-touch — the bedrock's load-bearing half): every row
outside the mutation domain comes back IDENTICAL. Stated per clause so
each bedrock sentence is its own law: an `.event` is never moved; an
absorbed or recurring or dateless row is never moved; and a row before the
horizon — `.pass` or `.nearFuture` — is never moved, whatever `δ`. -/
theorem never_touch (δ hzLast : Int) (e : TodoModel)
    (h : e.isTodo = false ∨ e.absorbed = true ∨ e.recurring = true
        ∨ e.hasDate = false ∨ e.start < hzLast) :
    push δ hzLast e = e := by
  unfold push eligible
  rcases h with h | h | h | h | h <;> simp [h] <;> omega

/-- THEOREM 25 (outward-only): the push never moves a start backwards, and
it moves a start at all exactly when the row is eligible and time actually
elapsed. With `δ ≤ 0` nothing moves — a backwards clock cannot pull dates
(`testAStampInTheFutureDoesNotPushBackwards`'s law). -/
theorem outward_only (δ hzLast : Int) (e : TodoModel) :
    e.start ≤ (push δ hzLast e).start
      ∧ ((push δ hzLast e).start = e.start
          ↔ ¬(0 < δ ∧ eligible hzLast e = true)) := by
  unfold push
  by_cases h : 0 < δ ∧ eligible hzLast e = true
  · simp [h]
    omega
  · simp [h]

/-- Eligibility is invariant under the joint advance of row and horizon. -/
theorem eligible_shift (hzLast δ : Int) (t a r hd : Bool) (st du : Int)
    (dl : Option Int) :
    eligible (hzLast + δ) ⟨t, a, r, hd, st + δ, du, dl⟩
      = eligible hzLast ⟨t, a, r, hd, st, du, dl⟩ := by
  unfold eligible
  have h : (hzLast + δ ≤ st + δ) = (hzLast ≤ st) := by
    apply propext
    omega
  simp only [h]

/-- Ineligibility survives the joint advance: a row the push refused stays
refused against every later horizon (`δ > 0`). -/
theorem ineligible_stays (hzLast δ : Int) (t a r hd : Bool) (st du : Int)
    (dl : Option Int) (hδ : 0 < δ)
    (h : ¬ eligible hzLast ⟨t, a, r, hd, st, du, dl⟩ = true) :
    ¬ eligible (hzLast + δ) ⟨t, a, r, hd, st, du, dl⟩ = true := by
  intro habs
  unfold eligible at h habs
  by_cases hb : (t && !a && !r && hd) = true
  · simp only [hb, Bool.true_and, decide_eq_true_eq] at h habs
    omega
  · rw [Bool.not_eq_true] at hb
    simp [hb] at habs

/-- THEOREM 26 (additivity / path-independence): pushing by `δ₁` against
the last horizon and then by `δ₂` against the ADVANCED horizon equals one
push over the whole span — the formal content of
`testManySkipsEqualOneWholeSpanPush`, and the reason the skipped-interval
design (never stamp without moving) is sound. The proof turns on
eligibility being INVARIANT under the joint advance (`eligible_shift` /
`ineligible_stays`) — which is exactly what horizon linearity (THEOREM 30)
buys. QA note: the STALE-horizon variant of this statement is also a
theorem (eligibility is upward-closed in `start`), so additivity alone
cannot detect an implementation that forgets to advance `horizonAtLast`;
that duty is `horizon_distance_invariant`'s `hzLast + δ`. Credit the set,
not this line. -/
theorem push_additive (δ₁ δ₂ hzLast : Int) (e : TodoModel)
    (h1 : 0 < δ₁) (h2 : 0 < δ₂) :
    push δ₂ (hzLast + δ₁) (push δ₁ hzLast e) = push (δ₁ + δ₂) hzLast e := by
  obtain ⟨t, a, r, hd, st, du, dl⟩ := e
  unfold push
  split
  · rename_i hc1
    split
    · rename_i hc2
      split
      · rename_i hc3
        show (⟨t, a, r, hd, st + δ₁ + δ₂, du, dl⟩ : TodoModel)
            = ⟨t, a, r, hd, st + (δ₁ + δ₂), du, dl⟩
        have : st + δ₁ + δ₂ = st + (δ₁ + δ₂) := by omega
        rw [this]
      · rename_i hc3
        exact absurd ⟨by omega, hc1.2⟩ hc3
    · rename_i hc2
      exfalso
      apply hc2
      refine ⟨h2, ?_⟩
      show eligible (hzLast + δ₁) ⟨t, a, r, hd, st + δ₁, du, dl⟩ = true
      rw [eligible_shift]
      exact hc1.2
  · rename_i hc1
    have hEfalse : ¬ eligible hzLast ⟨t, a, r, hd, st, du, dl⟩ = true :=
      fun hE => hc1 ⟨h1, hE⟩
    split
    · rename_i hc2
      exact absurd hc2.2 (ineligible_stays hzLast δ₁ t a r hd st du dl h1 hEfalse)
    · split
      · rename_i hc3
        exact absurd hc3.2 hEfalse
      · rfl

/-- THEOREM 27 (horizon-distance invariance — the comment's own equation,
`EventStore.swift:503`): an eligible row's distance past the horizon is
exactly preserved. -/
theorem horizon_distance_invariant (δ hzLast : Int) (e : TodoModel)
    (hδ : 0 < δ) (he : eligible hzLast e = true) :
    (push δ hzLast e).start - (hzLast + δ) = e.start - hzLast := by
  unfold push
  simp [hδ, he]
  omega

/-- THEOREM 28 (duration preservation): both endpoints translate together,
so the length is untouched — a push can never reshape a range, only slide
it. (The bridge to the civil theorems: sliding preserves absolute
duration, and reshaping is what mints straddles.) -/
theorem duration_preserved (δ hzLast : Int) (e : TodoModel) :
    (push δ hzLast e).dur = e.dur := by
  unfold push
  split <;> rfl

/-- THEOREM 29 (frame condition): the push touches `start` and NOTHING
else — `deadline` (the user's hard commitment) and every eligibility field
survive verbatim. "Auto-defer moves the preferred time, never the
commitment", literally. -/
theorem frame_condition (δ hzLast : Int) (e : TodoModel) :
    (push δ hzLast e).deadline = e.deadline
      ∧ (push δ hzLast e).isTodo = e.isTodo
      ∧ (push δ hzLast e).absorbed = e.absorbed
      ∧ (push δ hzLast e).recurring = e.recurring
      ∧ (push δ hzLast e).hasDate = e.hasDate := by
  unfold push
  split <;> exact ⟨rfl, rfl, rfl, rfl, rfl⟩

/-- THEOREM 30 (horizon linearity — why `horizonDate` must ignore its
`calendar` parameter): the horizon advances by exactly the elapsed
seconds, which is what makes the filter and the shift move in lockstep
(THEOREM 26's `hzLast + δ`). A civil-day horizon would advance 23 h or
25 h across a transition while the shift advances δ — the desync the
Swift doc warns about, here as the failed equation it would break. -/
theorem horizon_linear (d now δ : Int) :
    horizon d (now + δ) = horizon d now + δ := by
  unfold horizon
  omega

/-- Boundary witness (QA M3): a row sitting EXACTLY on the horizon is
eligible — the `≥` reading of "horizon is the first moment of future"
(`EventZone.classify:32-36`), pinned so a strict-`<` drift cannot build
green. Together with `never_touch`'s `start < hzLast` clause this pins the
boundary from both sides. -/
theorem boundary_row_eligible (hzLast du : Int) (dl : Option Int) :
    eligible hzLast ⟨true, false, false, true, hzLast, du, dl⟩ = true := by
  unfold eligible
  simp

/-- Zero-day horizon law (QA M6): with no near-future window the horizon
IS now — the one non-tautological value pin the constant admits. -/
theorem horizon_zero (now : Int) : horizon 0 now = now := by
  unfold horizon
  omega

end Verification
