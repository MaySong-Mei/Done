import CivilCalendar.Basic

/-!
# The prose claims as theorems

Each theorem here is a claim that today lives in a doc comment on the king
branch (`Event.endOfDay` / `Event.allDayCivilEnd` /
`Event.legacyAllDayStraddleHealedEnd`), restated over the model and proved
for EVERY day-length history at once. Where a comment glossed over a bound,
the bound appears here as an explicit hypothesis — that surfacing is the
point of the exercise.
-/

namespace Verification

open CalFns

/-- Inversion: a fired heal means the signature held and the healed value is
the pre-day-start instant of the end's day. -/
theorem isStraddle_of_healedEnd_some {c : CalFns} {s e v : Int}
    (h : c.healedEnd s e = some v) :
    c.IsStraddle s e ∧ v = c.midnight (c.dayOf e) - 1 := by
  unfold CalFns.healedEnd at h
  split at h
  · rename_i hs
    exact ⟨hs, (Option.some.inj h).symm⟩
  · simp at h

theorem healedEnd_eq_none_of_not {c : CalFns} {s e : Int}
    (h : ¬ c.IsStraddle s e) : c.healedEnd s e = none := by
  unfold CalFns.healedEnd
  split
  · rename_i hs; exact absurd hs h
  · rfl

/-- The residue of a pre-day-start instant `midnight k − 1` is its previous
day's full length minus one second — the comment's "its residue becomes a
full civil day minus one second", made exact. -/
theorem residue_of_midnight_sub_one (c : CivilCalendar) (k : Int) :
    c.midnight k - 1 - c.toCalFns.startOfDay (c.midnight k - 1)
      = (c.midnight k - c.midnight (k - 1)) - 1 := by
  unfold CalFns.startOfDay
  rw [c.dayOf_midnight_sub_one k]
  omega

/-- THEOREM 1 (`allDayCivilEnd` correctness, gh#188/#211): anchored on ANY
civil day start, in ANY day-length history — no DST hypothesis at all — the
result is exactly the last second of the last covered day, where the
covered-day count is the rounded raw-duration recovery. -/
theorem allDayCivilEnd_lands (c : CivilCalendar) (n raw : Int) :
    c.toCalFns.allDayCivilEnd (c.midnight n) raw
      = c.midnight (n + max 1 (roundHalfUpDiv (raw + 1) 86400)) - 1 := by
  simp only [CalFns.allDayCivilEnd, CalFns.endOfDay]
  generalize max 1 (roundHalfUpDiv (raw + 1) 86400) = D
  rw [c.dayOf_midnight n, c.dayOf_midnight (n + (D - 1))]
  have h : n + (D - 1) + 1 = n + D := by omega
  rw [h]

/-- THEOREM 2 (the gh#188 rounding claim, made precise): a stored ABSOLUTE
span `S` recovers the civil-day count `d` exactly — PROVIDED the span's
total drift from `86 400·d` stays under half a flat day. The comment says
"the rounding absorbs a DST hour hiding inside the span"; this is the
actual load-bearing line: one transition drifts ≤ 3 600 s, so real spans
sit far inside 43 200 s, but the 43 200 s cliff — not the DST hour — is
the invariant. -/
theorem dayCount_recovers (d S : Int) (hd : 1 ≤ d)
    (hlo : 86400 * d - 43200 ≤ S) (hhi : S < 86400 * d + 43200) :
    max 1 (roundHalfUpDiv S 86400) = d := by
  simp only [CalFns.roundHalfUpDiv]
  rw [show (2 : Int) * 86400 = 172800 by decide]
  omega

/-- THEOREM 3 (cross-frame roundtrip — the projection family's headline): an
all-day range minted as a `d`-civil-day span in ANY minting frame,
re-anchored on ANY civil day start of ANY reading frame, covers exactly `d`
civil days there and ends on the last covered day's final second. This is
what gh#188 + gh#211 + gh#212 collectively enforce, stated once. -/
theorem allDayCivilEnd_roundtrip
    (cRead : CivilCalendar) (cMint : CalFns) (n m d : Int) (hd : 1 ≤ d)
    (hlo : 86400 * d - 43200 ≤ cMint.midnight (m + d) - cMint.midnight m)
    (hhi : cMint.midnight (m + d) - cMint.midnight m < 86400 * d + 43200) :
    cRead.toCalFns.allDayCivilEnd (cRead.midnight n)
        (cMint.midnight (m + d) - cMint.midnight m - 1)
      = cRead.midnight (n + d) - 1 := by
  rw [allDayCivilEnd_lands]
  have hS : cMint.midnight (m + d) - cMint.midnight m - 1 + 1
      = cMint.midnight (m + d) - cMint.midnight m := by omega
  rw [hS, dayCount_recovers d _ hd hlo hhi]

/-- THEOREM 4 (discrimination, conjunct 1's design): an end anchored the way
every NORMALIZED writer anchors it — `midnight k − 1`, the `endOfDay`
shape — is never healed, whatever start accompanies it, in any calendar
whose days run at least 23 h. -/
theorem normalized_end_not_healed (c : CivilCalendar)
    (hmin : c.toCalFns.MinDayLen 82800) (k s' : Int) :
    c.toCalFns.healedEnd s' (c.midnight k - 1) = none := by
  apply healedEnd_eq_none_of_not
  intro hs
  obtain ⟨h1, h2, h3, h4, h5⟩ := hs
  have hres := residue_of_midnight_sub_one c k
  rw [hres] at h2
  have hlen := hmin (k - 1)
  have hk : k - 1 + 1 = k := by omega
  rw [hk] at hlen
  omega

/-- THEOREM 5 (heal idempotence): whatever the heal returns can never match
the signature again — for ANY start, not just the original one. The
comment's one-line idempotence claim is this corollary of THEOREM 4,
because a healed end IS the normalized shape. -/
theorem healed_never_rematches (c : CivilCalendar)
    (hmin : c.toCalFns.MinDayLen 82800) {s e v : Int}
    (h : c.toCalFns.healedEnd s e = some v) (s' : Int) :
    c.toCalFns.healedEnd s' v = none := by
  obtain ⟨_, hv⟩ := isStraddle_of_healedEnd_some h
  rw [hv]
  exact normalized_end_not_healed c hmin _ s'

/-- THEOREM 6 (discrimination, conjunct 3's design): an off-day-start start
is never healed — the create-flow seed with composer open-time residue on
its start is structurally safe, in any calendar. -/
theorem off_midnight_start_not_healed (c : CivilCalendar) {s : Int}
    (h : s ≠ c.toCalFns.startOfDay s) (e : Int) :
    c.toCalFns.healedEnd s e = none := by
  apply healedEnd_eq_none_of_not
  intro hs
  exact h hs.2.2.1

/-- THEOREM 7 (the gh#207 signature heals to the day the user picked): a
legacy whole-86 400 s mint of `d` days anchored at day `n`'s start, read in
a frame where the span lost `slip ∈ [2, 3600]` seconds to spring-forward,
fires the heal and lands on the last second of day `n + d − 1` — the
`endOfDay` of the intended last covered day. (A 1-second slip — never
produced by real transitions — would leave residue 0 and slip through;
that boundary is why `slip ≥ 2` appears here and nowhere in the prose.) -/
theorem legacy_straddle_heals (c : CivilCalendar)
    (hmin : c.toCalFns.MinDayLen 82800) (n d slip : Int) (hd : 1 ≤ d)
    (hs2 : 2 ≤ slip) (hs36 : slip ≤ 3600)
    (hspan : c.midnight (n + d) - c.midnight n = 86400 * d - slip) :
    c.toCalFns.healedEnd (c.midnight n) (c.midnight n + 86400 * d - 1)
      = some (c.midnight (n + d) - 1) := by
  have hlen := hmin (n + d)
  have hde : c.dayOf (c.midnight n + 86400 * d - 1) = n + d := by
    apply c.dayOf_eq
    · omega
    · omega
  have hstr : c.toCalFns.IsStraddle (c.midnight n)
      (c.midnight n + 86400 * d - 1) := by
    unfold CalFns.IsStraddle CalFns.startOfDay
    rw [hde, c.dayOf_midnight n]
    refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> omega
  unfold CalFns.healedEnd
  split
  · rw [hde]
  · rename_i hno; exact absurd hstr hno

end Verification
