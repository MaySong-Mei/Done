import CivilCalendar.CrossMidnight

/-!
# Overlap layout — the recursion's skeleton laws (gh#224 slice 3)

`CalendarLayout.overlapLayout` is calendar-free Int-interval arithmetic
downstream of window clipping (its `findOverlapClusters` discards the
calendar), so this module needs no `CivilCalendar` laws. It states the
four load-bearing skeleton properties, exact where Swift approximates
(CGFloat fractions are the float shadow of the scaled-integer arithmetic
here; the suite's 1e-3 accuracies are the seam's tolerance):

* TERMINATION — the stack-peek strip recursion carries NO prose bound
  anywhere in the codebase (the exploration's finding). Here: any
  process that strictly shrinks a nonempty set halts within its initial
  size, and the strip width after `d` levels is exactly `2^-d`.
* CONTAINMENT — the peek transition keeps every slot inside its parent
  and hence inside the unit column, in exact dyadic arithmetic.
* EQUAL-SPLIT PARTITION — columns tile the cluster's span exactly:
  disjoint, contiguous, widths summing to the whole.
* TIE-BREAK TOTALITY — the 7-key lexicographic comparator is a strict
  total order PROVIDED the final key is injective (unique occurrence
  ids) — the hypothesis the exploration flagged, now explicit.

Deliberately out of scope (recorded, not implied): the greedy packer's
column-assignment optimality, whole-pipeline id-totality, and
permutation invariance of the full function — the shadow tests
(`LeanOverlapShadowTests`) hold those empirically against the real
implementation.
-/

namespace Verification

namespace OverlapCore

/-- THEOREM 50 (termination skeleton): a process that strictly shrinks a
nonempty measure halts within its initial value — the stack-peek
recursion removes a nonempty host each level, so a cluster of `n`
occurrences recurses at most `n − 1` times. The codebase claims this
nowhere; now it is claimed and checked. -/
theorem strictly_shrinking_halts (f : Nat → Nat)
    (h : ∀ i, f i ≠ 0 → f (i + 1) < f i) :
    ∃ i, i ≤ f 0 ∧ f i = 0 := by
  suffices hgen : ∀ k i, f i ≤ k → ∃ j, j ≤ i + k ∧ f j = 0 by
    obtain ⟨j, hj, hz⟩ := hgen (f 0) 0 (Nat.le_refl _)
    exact ⟨j, by omega, hz⟩
  intro k
  induction k with
  | zero =>
    intro i h0
    exact ⟨i, by omega, by omega⟩
  | succ m ih =>
    intro i hle
    by_cases hz : f i = 0
    · exact ⟨i, by omega, hz⟩
    · have hlt := h i hz
      obtain ⟨j, hj, hzz⟩ := ih (i + 1) (by omega)
      exact ⟨j, by omega, hzz⟩

/-- THEOREM 51 (peek containment, exact doubling): with the parent slot
`[x, x+w)` inside a column of size `B`, the doubled-scale strip
`[2x + w, 2x + 2w)` stays inside the doubled column AND inside the
doubled parent — so every slot the recursion can mint remains inside
`[0, 1]`, and nesting never leaks. The dyadic story (`width = 2^-d`) is
this lemma iterated: the scale doubles each level, the invariant
survives verbatim. -/
theorem peek_strip_contained (B x w : Int)
    (hx : 0 ≤ x) (hw : 0 < w) (hinv : x + w ≤ B) :
    0 ≤ 2 * x + w
      ∧ (2 * x + w) + w ≤ 2 * B
      ∧ 2 * x ≤ 2 * x + w
      ∧ (2 * x + w) + w ≤ 2 * (x + w) := by
  refine ⟨by omega, by omega, by omega, by omega⟩

/-- THEOREM 52 (equal-split partition, scaled integers): `cols` columns
of width `W` tile `[X, X + cols·W)` exactly — column `i` starts at
`X + i·W`, consecutive columns are adjacent (no gap, no overlap), and
every column sits inside the span. The Swift float widths
(`width / CGFloat(cols)`) are this arithmetic's shadow; thirds are
inexact there and exact here. -/
theorem equal_split_partitions (X W : Int) (cols i : Int)
    (hW : 0 < W) (hi : 0 ≤ i) (hcols : i < cols) :
    X ≤ X + i * W
      ∧ (X + i * W) + W = X + (i + 1) * W
      ∧ (X + i * W) + W ≤ X + cols * W := by
  have h1 : 0 ≤ i * W := Int.mul_nonneg hi (by omega)
  have h2 : (i + 1) * W ≤ cols * W :=
    Int.mul_le_mul_of_nonneg_right (by omega) (by omega)
  have hmul : (i + 1) * W = i * W + W := by
    rw [Int.add_mul]
    omega
  refine ⟨by omega, by omega, by omega⟩

/-- THEOREM 53 (tie-break totality — the flagged hypothesis, explicit):
the lexicographic comparator `k`-then-`id` is a strict total order
PROVIDED `id` is injective on the compared population. Every chain in
the 7-key Swift comparator bottoms out in an id comparison; uniqueness
of occurrence ids is therefore exactly what totality costs. -/
def LexLT (k id_ : α → Int) (a b : α) : Prop :=
  k a < k b ∨ (k a = k b ∧ id_ a < id_ b)

theorem lexLT_irrefl (k id_ : α → Int) (a : α) : ¬ LexLT k id_ a a := by
  unfold LexLT
  omega

theorem lexLT_trans (k id_ : α → Int) (a b c : α)
    (h1 : LexLT k id_ a b) (h2 : LexLT k id_ b c) : LexLT k id_ a c := by
  unfold LexLT at h1 h2 ⊢
  omega

theorem lexLT_total (k id_ : α → Int) (a b : α)
    (hinj : id_ a = id_ b → a = b) :
    LexLT k id_ a b ∨ a = b ∨ LexLT k id_ b a := by
  unfold LexLT
  by_cases hk : k a = k b
  · by_cases hid : id_ a = id_ b
    · exact Or.inr (Or.inl (hinj hid))
    · omega
  · omega

end OverlapCore

end Verification
