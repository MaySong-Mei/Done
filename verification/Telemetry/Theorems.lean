import Telemetry.Basic

/-!
# The telemetry prose as theorems (gh#273)

Each theorem names the sentence of `Docs/telemetry/00-telemetry-chassis-design.md`
(§4.2, §7.2, §8.2, §11) or `01-wire-contract.md` (§1, §3, §5) it replaces,
restated over `Telemetry/Basic.lean` and proved for every record list, every
cursor and every delivery order at once. Where the prose is silent, the
hypothesis that was needed is stated — that surfacing is the point.
-/

namespace Verification.Telemetry

open List

/-! ## 1. The cursor (§7.2 游标) -/

namespace Cursor

variable {Id : Type} [DecidableEq Id]

omit [DecidableEq Id] in
theorem ext {c₁ c₂ : Cursor Id} (h : ∀ i, c₁.uploaded i = c₂.uploaded i) : c₁ = c₂ := by
  cases c₁; cases c₂
  simp only [Cursor.mk.injEq]
  funext i
  exact h i

theorem uploaded_bump (c : Cursor Id) (id : Id) (rev : Nat) (i : Id) :
    (c.bump id rev).uploaded i = if i = id then max (c.uploaded i) rev else c.uploaded i := rfl

/-- `revMax`'s fold is a `max` in its seed. -/
theorem revMax_fold_shift (acks : List (Id × Nat)) (id : Id) (a b : Nat) :
    acks.foldl (fun m p => if p.1 = id then max m p.2 else m) (max a b)
      = max a (acks.foldl (fun m p => if p.1 = id then max m p.2 else m) b) := by
  induction acks generalizing a b with
  | nil => rfl
  | cons p acks ih =>
    simp only [List.foldl_cons]
    by_cases h : p.1 = id
    · simp only [if_pos h]
      rw [show max (max a b) p.2 = max a (max b p.2) by omega]
      exact ih a (max b p.2)
    · simp only [if_neg h]
      exact ih a b

theorem revMax_nil (id : Id) : revMax ([] : List (Id × Nat)) id = 0 := rfl

theorem revMax_cons (p : Id × Nat) (acks : List (Id × Nat)) (id : Id) :
    revMax (p :: acks) id = max (if p.1 = id then p.2 else 0) (revMax acks id) := by
  unfold revMax
  simp only [List.foldl_cons]
  rw [← revMax_fold_shift acks id (if p.1 = id then p.2 else 0) 0]
  congr 1
  by_cases h : p.1 = id
  · simp only [if_pos h]; omega
  · simp only [if_neg h]; omega

/-- The cursor after `acknowledge`, per id: the old value or the batch's
largest revision for that id, whichever is bigger. Everything below is a
corollary. -/
theorem uploaded_acknowledge (c : Cursor Id) (acks : List (Id × Nat)) (i : Id) :
    (c.acknowledge acks).uploaded i = max (c.uploaded i) (revMax acks i) := by
  induction acks generalizing c with
  | nil => simp [acknowledge, revMax_nil]
  | cons p acks ih =>
    have step : (c.acknowledge (p :: acks)) = (c.bump p.1 p.2).acknowledge acks := rfl
    rw [step, ih, revMax_cons, uploaded_bump]
    by_cases h : i = p.1
    · have h' : p.1 = i := h.symm
      simp only [if_pos h, if_pos h']
      omega
    · have h' : p.1 ≠ i := fun e => h e.symm
      simp only [if_neg h, if_neg h']
      omega

theorem le_revMax_of_mem {acks : List (Id × Nat)} {i : Id} {r : Nat} (h : (i, r) ∈ acks) :
    r ≤ revMax acks i := by
  induction acks with
  | nil => simp at h
  | cons p acks ih =>
    rw [revMax_cons]
    rcases List.mem_cons.mp h with h | h
    · subst h
      simp only
      exact Nat.le_max_left _ _
    · exact Nat.le_trans (ih h) (Nat.le_max_right _ _)

theorem revMax_perm {a₁ a₂ : List (Id × Nat)} (h : a₁ ~ a₂) (i : Id) :
    revMax a₁ i = revMax a₂ i := by
  unfold revMax
  apply h.foldl_eq'
  intro x _ y _ z
  by_cases hx : x.1 = i <;> by_cases hy : y.1 = i
  · simp only [if_pos hx, if_pos hy]; omega
  · simp only [if_pos hx, if_neg hy]
  · simp only [if_neg hx, if_pos hy]
  · simp only [if_neg hx, if_neg hy]

/-- THEOREM 1a — §7.2 "绝不回退": after `acknowledge` every id reads at
least what it read before. -/
theorem acknowledge_mono (c : Cursor Id) (acks : List (Id × Nat)) (i : Id) :
    c.uploaded i ≤ (c.acknowledge acks).uploaded i := by
  rw [uploaded_acknowledge]
  exact Nat.le_max_left _ _

/-- THEOREM 1b — acknowledging the same batch twice is acknowledging it once
(the 2xx-after-2xx of a retried request moves nothing). -/
theorem acknowledge_idem (c : Cursor Id) (acks : List (Id × Nat)) :
    (c.acknowledge acks).acknowledge acks = c.acknowledge acks := by
  apply ext
  intro i
  rw [uploaded_acknowledge, uploaded_acknowledge]
  omega

/-- THEOREM 1c — the acknowledgement is order-free: any permutation of the
batch's `(id, revision)` pairs yields the same cursor (the fold is
commutative and associative per id, so the response's row order and the
request's row order need not agree). -/
theorem acknowledge_perm (c : Cursor Id) {a₁ a₂ : List (Id × Nat)} (h : a₁ ~ a₂) :
    c.acknowledge a₁ = c.acknowledge a₂ := by
  apply ext
  intro i
  rw [uploaded_acknowledge, uploaded_acknowledge, revMax_perm h]

/-- THEOREM 1d — a revision at or below the cursor is a no-op: the cursor
never regresses to a lower revision a late response might carry. -/
theorem acknowledge_low_noop (c : Cursor Id) (id : Id) (rev : Nat) (h : rev ≤ c.uploaded id) :
    c.acknowledge [(id, rev)] = c := by
  apply ext
  intro i
  rw [uploaded_acknowledge]
  by_cases hi : id = i
  · subst hi
    have hr : revMax [(id, rev)] id = rev := by simp [revMax]
    rw [hr]
    omega
  · have hr : revMax [(id, rev)] i = 0 := by simp [revMax, hi]
    rw [hr]
    omega

omit [DecidableEq Id] in
theorem pending_iff (c : Cursor Id) (records : List (Record Id)) (r : Record Id) :
    r ∈ c.pending records ↔ r ∈ records ∧ c.uploaded r.id < r.revision := by
  simp [pending, isPending]

/-- THEOREM 1e — §7.2 "只有本地 revision > uploadedRevision 的记录进批", after
an acknowledgement: a record whose id was acknowledged at a revision at
least its own is no longer pending. -/
theorem not_pending_after_acknowledge (c : Cursor Id) (records : List (Record Id))
    (acks : List (Id × Nat)) {r : Record Id} {rev : Nat}
    (hmem : (r.id, rev) ∈ acks) (hle : r.revision ≤ rev) :
    r ∉ (c.acknowledge acks).pending records := by
  intro h
  rw [pending_iff, uploaded_acknowledge] at h
  have := le_revMax_of_mem hmem
  omega

/-- Acknowledging only ever shrinks the pending set. -/
theorem pending_acknowledge_subset (c : Cursor Id) (records : List (Record Id))
    (acks : List (Id × Nat)) :
    (c.acknowledge acks).pending records ⊆ c.pending records := by
  intro r h
  rw [pending_iff] at *
  have := acknowledge_mono c acks r.id
  exact ⟨h.1, by omega⟩

omit [DecidableEq Id] in
/-- The wire contract starts revisions at 1; the cursor's default is 0. A
record carrying revision 0 (a legacy row decoded without the field, say) is
below the default and is NEVER pending — stated so the gap is visible. -/
theorem revision_zero_never_pending (c : Cursor Id) (records : List (Record Id))
    {r : Record Id} (h : r.revision = 0) : r ∉ c.pending records := by
  intro hm
  rw [pending_iff] at hm
  omega

end Cursor

/-! ## 2. The server guard (wire §3 / design §7.2, §9.2) -/

namespace Server

theorem step_none (r : Nat) : step none r = some r := rfl

theorem step_some (e r : Nat) : step (some e) r = some (max e r) := by
  by_cases h : e < r
  · simp only [step, accepts, h, decide_true, if_true]
    congr 1
    omega
  · simp only [step, accepts, h, decide_false, Bool.false_eq_true, if_false]
    congr 1
    omega

/-- THEOREM 2a — §7.2 "重传任意次 = 一次" / §11.2 "同 revision 两次 → 1 行":
redelivering a revision leaves the row where the first delivery put it. -/
theorem step_idem (s : Option Nat) (r : Nat) : step (step s r) r = step s r := by
  cases s with
  | none => rw [step_none, step_some]; congr 1; omega
  | some e => rw [step_some, step_some]; congr 1; omega

/-- THEOREM 2c — §7.2 "挂起的旧请求晚到不覆盖" / §11.2 "先 7 后 5 → 行仍是 7":
a revision at or below the held one never wins. -/
theorem stale_never_wins (e r : Nat) (h : r ≤ e) : step (some e) r = some e := by
  rw [step_some]
  congr 1
  omega

theorem fold_nil (s : Option Nat) : fold s [] = s := rfl

theorem fold_some (e : Nat) (rs : List Nat) : fold (some e) rs = some (rs.foldl max e) := by
  induction rs generalizing e with
  | nil => rfl
  | cons r rs ih =>
    show fold (step (some e) r) rs = some (rs.foldl max (max e r))
    rw [step_some]
    exact ih (max e r)

theorem fold_none_cons (r : Nat) (rs : List Nat) : fold none (r :: rs) = some (rs.foldl max r) := by
  show fold (step none r) rs = _
  rw [step_none]
  exact fold_some r rs

/-- THEOREM 2b — the terminal row of ANY delivery sequence into an empty slot
is the largest revision delivered (`List.max?`), whatever the order. -/
theorem fold_none_eq_max? (rs : List Nat) : fold none rs = rs.max? := by
  cases rs with
  | nil => rfl
  | cons r rs => rw [fold_none_cons]; rfl

/-- THEOREM 2b' — order independence: two arrival orders of the same
deliveries leave the same row. -/
theorem fold_perm {r₁ r₂ : List Nat} (h : r₁ ~ r₂) (s : Option Nat) : fold s r₁ = fold s r₂ := by
  unfold fold
  apply h.foldl_eq'
  intro x _ y _ z
  cases z with
  | none => simp only [step_none, step_some, Option.some.injEq]; omega
  | some e => simp only [step_some, Option.some.injEq]; omega

theorem le_foldl_max (e : Nat) (rs : List Nat) : e ≤ rs.foldl max e := by
  induction rs generalizing e with
  | nil => exact Nat.le_refl _
  | cons r rs ih =>
    simp only [List.foldl_cons]
    exact Nat.le_trans (Nat.le_max_left e r) (ih _)

theorem mem_le_foldl_max {e : Nat} {rs : List Nat} {r : Nat} (h : r ∈ rs) : r ≤ rs.foldl max e := by
  induction rs generalizing e with
  | nil => simp at h
  | cons x rs ih =>
    simp only [List.foldl_cons]
    rcases List.mem_cons.mp h with h | h
    · subst h
      exact Nat.le_trans (Nat.le_max_right e r) (le_foldl_max _ _)
    · exact ih h

theorem foldl_max_of_le {e : Nat} {rs : List Nat} (h : ∀ r ∈ rs, r ≤ e) : rs.foldl max e = e := by
  induction rs with
  | nil => rfl
  | cons r rs ih =>
    simp only [List.foldl_cons]
    have hr : r ≤ e := h r (List.mem_cons_self ..)
    rw [show max e r = e by omega]
    exact ih (fun x hx => h x (List.mem_cons_of_mem _ hx))

/-- THEOREM 2c' — a whole batch of stale revisions changes nothing. -/
theorem fold_stale (e : Nat) (rs : List Nat) (h : ∀ r ∈ rs, r ≤ e) : fold (some e) rs = some e := by
  rw [fold_some, foldl_max_of_le h]

/-- THEOREM 2d — §7.2 "重传任意次 = 一次" for a whole body: redelivering a
delivery sequence after itself leaves the row unchanged. -/
theorem fold_idem (s : Option Nat) (rs : List Nat) : fold (fold s rs) rs = fold s rs := by
  cases s with
  | some e =>
    rw [fold_some, fold_some]
    congr 1
    exact foldl_max_of_le (fun r hr => mem_le_foldl_max hr)
  | none =>
    cases rs with
    | nil => rfl
    | cons r rs =>
      rw [fold_none_cons, fold_some]
      congr 1
      simp only [List.foldl_cons]
      rw [show max (rs.foldl max r) r = rs.foldl max r by
        have := le_foldl_max r rs; omega]
      exact foldl_max_of_le (fun x hx => mem_le_foldl_max hx)

end Server

/-! ## 3. The consent watermark (§8.2 / wire §5) -/

section Consent

variable {Id : Type}

/-- THEOREM 3a — the filter only ever removes: the upload body is drawn from
the local pool, never synthesized. -/
theorem consentFilter_subset (rs : List (Record Id)) (t : Option Int) (o : Option String) :
    consentFilter rs t o ⊆ rs := by
  unfold consentFilter
  split
  · exact List.filter_sublist.subset
  · exact List.nil_subset _

/-- THEOREM 3c — §8.2 "打开记 consent_at": with no watermark nothing is eligible. -/
theorem consentFilter_none (rs : List (Record Id)) (o : Option String) :
    consentFilter rs none o = [] := by
  cases o <;> rfl

/-- §4.1 "`nil` = 签出期,永不上传": with no current owner nothing is eligible. -/
theorem consentFilter_signedOut (rs : List (Record Id)) (t : Option Int) :
    consentFilter rs t none = [] := by
  cases t <;> rfl

theorem mem_consentFilter {rs : List (Record Id)} {t : Int} {owner : String} {r : Record Id} :
    r ∈ consentFilter rs (some t) (some owner)
      ↔ r ∈ rs ∧ t ≤ r.startedAt ∧ r.ownerUID = some owner := by
  simp [consentFilter]

/-- THEOREM 3d — §11.6 "开于 t → 首批无 startedAt < t 的记录". -/
theorem consentFilter_startedAt {rs : List (Record Id)} {t : Int} {o : Option String}
    {r : Record Id} (h : r ∈ consentFilter rs (some t) o) : t ≤ r.startedAt := by
  cases o with
  | none => rw [consentFilter_signedOut] at h; simp at h
  | some owner => exact (mem_consentFilter.mp h).2.1

/-- THEOREM 3e — wire §5 "ownerUID == 当前 uid": every eligible record was
minted by the current owner, and that owner is a signed-in one. -/
theorem consentFilter_owner {rs : List (Record Id)} {t : Option Int} {o : Option String}
    {r : Record Id} (h : r ∈ consentFilter rs t o) : r.ownerUID = o ∧ o ≠ none := by
  cases t with
  | none => rw [consentFilter_none] at h; simp at h
  | some t =>
    cases o with
    | none => rw [consentFilter_signedOut] at h; simp at h
    | some owner =>
      refine ⟨(mem_consentFilter.mp h).2.2, ?_⟩
      simp

/-- THEOREM 3b — monotone in the watermark: a later `consent_at` uploads a
subset of what an earlier one would (turning the switch off and on again
can only narrow the history that leaves the device). -/
theorem consentFilter_mono {rs : List (Record Id)} {t₁ t₂ : Int} (h : t₁ ≤ t₂) (o : Option String) :
    consentFilter rs (some t₂) o ⊆ consentFilter rs (some t₁) o := by
  intro r hr
  cases o with
  | none => rw [consentFilter_signedOut] at hr; simp at hr
  | some owner =>
    rw [mem_consentFilter] at *
    exact ⟨hr.1, by omega, hr.2.2⟩

end Consent

/-! ## 4. The claim key (§4.2 认领键) -/

namespace ClaimKey

/-- THEOREM 4a — `adopts` is `==` on the four fields, exactly. -/
theorem adopts_iff (a b : ClaimKey) :
    a.adopts b = true
      ↔ a.buildConfiguration = b.buildConfiguration ∧ a.appBuild = b.appBuild
        ∧ a.osVersion = b.osVersion ∧ a.ownerUID = b.ownerUID := by
  simp only [adopts, decide_eq_true_eq]
  constructor
  · intro h; subst h; exact ⟨rfl, rfl, rfl, rfl⟩
  · intro ⟨h1, h2, h3, h4⟩
    cases a; cases b
    simp only at h1 h2 h3 h4
    subst h1 h2 h3 h4
    rfl

/-- THEOREM 4b — reflexive: a key always adopts its own record. -/
theorem adopts_refl (k : ClaimKey) : k.adopts k = true := by
  simp [adopts]

/-- THEOREM 4b — symmetric. -/
theorem adopts_symm (a b : ClaimKey) : a.adopts b = b.adopts a := by
  by_cases h : a = b
  · subst h; rfl
  · have h' : b ≠ a := fun e => h e.symm
    simp [adopts, h, h']

/-- THEOREM 4b — transitive: so "today's record" is a well-defined class. -/
theorem adopts_trans {a b c : ClaimKey} (h₁ : a.adopts b = true) (h₂ : b.adopts c = true) :
    a.adopts c = true := by
  simp only [adopts, decide_eq_true_eq] at *
  exact h₁.trans h₂

/-- THEOREM 4c — §4.2 "任一不同就为同一天铸新 run id": one differing field
refuses the takeover (§11.9: build 10→11 → two dailies; qa-a→qa-b → two
dailies with distinct owners). -/
theorem not_adopts_of_field_ne {a b : ClaimKey}
    (h : a.buildConfiguration ≠ b.buildConfiguration ∨ a.appBuild ≠ b.appBuild
        ∨ a.osVersion ≠ b.osVersion ∨ a.ownerUID ≠ b.ownerUID) :
    a.adopts b = false := by
  simp only [adopts, decide_eq_false_iff_not]
  intro e
  subst e
  rcases h with h | h | h | h <;> exact h rfl

end ClaimKey

/-! ## 5. Batch selection (§7.1 (4) / wire §5) -/

section Batch

variable {Id : Type}

theorem admits_of_ne_edge {t : Trigger} (h : t ≠ .backgroundEdge) (l : Option Int) (n : Int)
    (r : Record Id) : admits t l n r = true := by
  cases t <;> first | rfl | exact absurd rfl h

theorem mem_orderBatch {p : List (Record Id)} {t : Trigger} {l : Option Int} {n : Int}
    {r : Record Id} : r ∈ orderBatch p t l n ↔ r ∈ p ∧ admits t l n r = true := by
  simp [orderBatch, List.mem_mergeSort, List.mem_filter]

/-- THEOREM 5a — the batch is drawn from the pending set. -/
theorem selectBatch_subset (p : List (Record Id)) (t : Trigger) (l : Option Int) (n : Int)
    (lim : Nat) : selectBatch p t l n lim ⊆ p := by
  intro r h
  exact (mem_orderBatch.mp (List.mem_of_mem_take h)).1

/-- THEOREM 5b — wire §5 "每批 ≤32 行": never more than `limit`. -/
theorem selectBatch_length_le (p : List (Record Id)) (t : Trigger) (l : Option Int) (n : Int)
    (lim : Nat) : (selectBatch p t l n lim).length ≤ lim := by
  simp only [selectBatch, List.length_take]
  exact Nat.min_le_left _ _

theorem mem_selectBatch_admits {p : List (Record Id)} {t : Trigger} {l : Option Int} {n : Int}
    {lim : Nat} {r : Record Id} (h : r ∈ selectBatch p t l n lim) : admits t l n r = true :=
  (mem_orderBatch.mp (List.mem_of_mem_take h)).2

/-- THEOREM 5c — §7.1 (4) "距上次上传 ≥15 分钟的今日 daily": inside the
15-minute window a background edge carries no daily rollup. -/
theorem edge_no_daily_within_gap {p : List (Record Id)} {last now : Int}
    (hgap : now - last < dailyGapSeconds) {lim : Nat} {r : Record Id}
    (h : r ∈ selectBatch p .backgroundEdge (some last) now lim) : r.kind ≠ .dailyRollup := by
  have ha := mem_selectBatch_admits h
  intro hk
  simp only [admits, hk, Kind.isEvent, dailyGateOpen, dailyGapSeconds, Bool.false_or,
    decide_true, Bool.true_and] at ha
  have ha' : (900 : Int) ≤ now - last := of_decide_eq_true ha
  simp only [dailyGapSeconds] at hgap
  omega

/-- THEOREM 5c' — the gate's other side: at or past 15 minutes (or with no
daily upload ever), a pending daily rollup that fits rides the edge. -/
theorem edge_daily_when_gate_open {p : List (Record Id)} {l : Option Int} {n : Int}
    (hgate : dailyGateOpen l n = true) {lim : Nat}
    (hfit : (p.filter (admits .backgroundEdge l n)).length ≤ lim)
    {r : Record Id} (hr : r ∈ p) (hk : r.kind = .dailyRollup) :
    r ∈ selectBatch p .backgroundEdge l n lim := by
  have hadm : admits .backgroundEdge l n r = true := by
    simp [admits, hk, hgate]
  have hmem : r ∈ orderBatch p .backgroundEdge l n := mem_orderBatch.mpr ⟨hr, hadm⟩
  have hlen : (orderBatch p .backgroundEdge l n).length ≤ lim := by
    simp only [orderBatch, List.length_mergeSort]; exact hfit
  unfold selectBatch
  rw [List.take_of_length_le hlen]
  exact hmem

/-- THEOREM 5d — §7.1 (4) "上传只带事件记录(窗口、快照、手动 run)+ … 今日
daily": a background edge carries an event or the daily rollup, nothing
else — in particular never a `metricKitDaily`. -/
theorem edge_kinds {p : List (Record Id)} {l : Option Int} {n : Int} {lim : Nat}
    {r : Record Id} (h : r ∈ selectBatch p .backgroundEdge l n lim) :
    r.kind.isEvent = true ∨ r.kind = .dailyRollup := by
  have ha := mem_selectBatch_admits h
  simp only [admits, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at ha
  rcases ha with ha | ⟨ha, _⟩
  · exact Or.inl ha
  · exact Or.inr ha

theorem edge_never_metricKit {p : List (Record Id)} {l : Option Int} {n : Int} {lim : Nat}
    {r : Record Id} (h : r ∈ selectBatch p .backgroundEdge l n lim) :
    r.kind ≠ .metricKitDaily := by
  intro hk
  rcases edge_kinds h with h' | h' <;> rw [hk] at h' <;> simp [Kind.isEvent] at h'

/-- Off the edge, with the pending set inside the limit, the batch IS the
pending set up to order. -/
theorem selectBatch_perm_of_fits {t : Trigger} (h : t ≠ .backgroundEdge) (p : List (Record Id))
    (l : Option Int) (n : Int) {lim : Nat} (hl : p.length ≤ lim) :
    selectBatch p t l n lim ~ p := by
  unfold selectBatch orderBatch
  have hf : p.filter (admits t l n) = p :=
    List.filter_eq_self.mpr (fun r _ => admits_of_ne_edge h l n r)
  rw [hf]
  have hlen : (p.mergeSort before).length ≤ lim := by
    rw [List.length_mergeSort]; exact hl
  rw [List.take_of_length_le hlen]
  exact List.mergeSort_perm p before

/-- THEOREM 5e — §7.1 (1)–(3): launch, day rollover and deck open take
everything that fits — every pending daily rollup included. -/
theorem nonEdge_keeps_all {t : Trigger} (ht : t ≠ .backgroundEdge) {p : List (Record Id)}
    (l : Option Int) (n : Int) {lim : Nat} (hfit : p.length ≤ lim) {r : Record Id} (hr : r ∈ p) :
    r ∈ selectBatch p t l n lim :=
  (selectBatch_perm_of_fits ht p l n hfit).mem_iff.mpr hr

theorem before_trans (a b c : Record Id) (h₁ : before a b = true) (h₂ : before b c = true) :
    before a c = true := by
  simp only [before, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at *
  omega

theorem before_total (a b : Record Id) : (before a b || before b a) = true := by
  simp only [before, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  omega

/-- THEOREM 5f — the order: events before dailies, `startedAt` ascending. -/
theorem orderBatch_sorted (p : List (Record Id)) (t : Trigger) (l : Option Int) (n : Int) :
    (orderBatch p t l n).Pairwise (fun a b => before a b = true) :=
  List.pairwise_mergeSort before_trans before_total _

theorem selectBatch_sorted (p : List (Record Id)) (t : Trigger) (l : Option Int) (n : Int)
    (lim : Nat) : (selectBatch p t l n lim).Pairwise (fun a b => before a b = true) :=
  (orderBatch_sorted p t l n).take

/-- THEOREM 5g — stability: two admitted records the order cannot separate
(same rank, same `startedAt`, so `before` holds both ways) keep their input
order; more generally `before a b` with `a` ahead of `b` keeps `a` ahead. -/
theorem orderBatch_stable {p : List (Record Id)} {t : Trigger} {l : Option Int} {n : Int}
    {a b : Record Id} (hab : before a b = true) (hsub : [a, b] <+ p)
    (ha : admits t l n a = true) (hb : admits t l n b = true) :
    [a, b] <+ orderBatch p t l n := by
  unfold orderBatch
  apply List.pair_sublist_mergeSort before_trans before_total hab
  have := hsub.filter (admits t l n)
  simpa [List.filter_cons, ha, hb] using this

/-- THEOREM 5h — idempotent: selecting from a selection returns it unchanged
(it is already admitted, sorted and within the limit); with purity this is
the "同输入同输出" of the prose. -/
theorem selectBatch_idem (p : List (Record Id)) (t : Trigger) (l : Option Int) (n : Int)
    (lim : Nat) : selectBatch (selectBatch p t l n lim) t l n lim = selectBatch p t l n lim := by
  have hadm : (selectBatch p t l n lim).filter (admits t l n) = selectBatch p t l n lim :=
    List.filter_eq_self.mpr (fun _ hr => mem_selectBatch_admits hr)
  have hsorted := selectBatch_sorted p t l n lim
  have hlen := selectBatch_length_le p t l n lim
  show (((selectBatch p t l n lim).filter (admits t l n)).mergeSort before).take lim = _
  rw [hadm, List.mergeSort_of_pairwise hsorted, List.take_of_length_le hlen]

end Batch

/-! ## 6. One round, end to end (§7.2) -/

namespace ServerState

variable {Id : Type} [DecidableEq Id]

omit [DecidableEq Id] in
theorem ext {s₁ s₂ : ServerState Id} (h : ∀ i, s₁.held i = s₂.held i) : s₁ = s₂ := by
  cases s₁; cases s₂
  simp only [ServerState.mk.injEq]
  funext i
  exact h i

theorem held_upsert (s : ServerState Id) (r : Record Id) (i : Id) :
    (s.upsert r).held i = if i = r.id then Server.step (s.held i) r.revision else s.held i := rfl

/-- The bulk upsert, per id: the row sees exactly the batch's revisions for
that id, in body order, through the guard. -/
theorem held_applyBatch (s : ServerState Id) (batch : List (Record Id)) (i : Id) :
    (s.applyBatch batch).held i
      = Server.fold (s.held i) ((batch.filter (fun r => decide (r.id = i))).map Record.revision) := by
  induction batch generalizing s with
  | nil => rfl
  | cons r batch ih =>
    have step : s.applyBatch (r :: batch) = (s.upsert r).applyBatch batch := rfl
    rw [step, ih, held_upsert]
    by_cases h : i = r.id
    · have h' : r.id = i := h.symm
      simp only [List.filter_cons, h', decide_true]
      rfl
    · have h' : ¬ r.id = i := fun e => h e.symm
      simp only [if_neg h, List.filter_cons, h', decide_false]
      rfl

/-- THEOREM 6c — the server half of "重传任意次 = 一次" for a whole body. -/
theorem applyBatch_idem (s : ServerState Id) (b : List (Record Id)) :
    (s.applyBatch b).applyBatch b = s.applyBatch b := by
  apply ext
  intro i
  simp only [held_applyBatch]
  exact Server.fold_idem _ _

end ServerState

namespace World

variable {Id : Type} [DecidableEq Id]

/-- THEOREM 6a — convergence: a round that fits in one batch and gets its
2xx leaves nothing pending — the next round sends nothing (§7.2's cursor
"迟早" made exact for the one-batch case; larger pools converge batch by
batch via `pending_acknowledge_subset`). -/
theorem roundOK_converges (w : World Id) (records : List (Record Id)) {t : Trigger}
    (ht : t ≠ .backgroundEdge) (l : Option Int) (n : Int) {lim : Nat}
    (hfit : (w.cursor.pending records).length ≤ lim) :
    (w.roundOK records t l n lim).cursor.pending records = [] := by
  have hperm := selectBatch_perm_of_fits ht (w.cursor.pending records) l n hfit
  apply List.filter_eq_nil_iff.mpr
  intro r hr hpend
  have hpend' : (w.roundOK records t l n lim).cursor.uploaded r.id < r.revision :=
    of_decide_eq_true hpend
  simp only [World.roundOK] at hpend'
  rw [Cursor.uploaded_acknowledge] at hpend'
  by_cases hp : w.cursor.uploaded r.id < r.revision
  · have hin : r ∈ w.batch records t l n lim :=
      hperm.mem_iff.mpr ((Cursor.pending_iff _ _ _).mpr ⟨hr, hp⟩)
    have hack : (r.id, r.revision) ∈ (w.batch records t l n lim).map (fun r => (r.id, r.revision)) :=
      List.mem_map.mpr ⟨r, hin, rfl⟩
    have := Cursor.le_revMax_of_mem hack
    omega
  · omega

/-- THEOREM 6b — no loss: a round without a 2xx moves no cursor, so the next
round's pending set is this round's (§7.2 "只在 2xx 后写回"; §11.3). -/
theorem roundFailed_pending_unchanged (w : World Id) (records : List (Record Id)) (t : Trigger)
    (l : Option Int) (n : Int) (lim : Nat) (applied : Bool) :
    (w.roundFailed records t l n lim applied).cursor.pending records = w.cursor.pending records :=
  rfl

/-- THEOREM 6c — retry after a lost response: whether or not the failed
round's body landed on the server, the retry ends in the state ONE
successful round would have produced (§7.2 "重传任意次 = 一次", end to end). -/
theorem retry_equals_once (w : World Id) (records : List (Record Id)) (t : Trigger)
    (l : Option Int) (n : Int) (lim : Nat) (applied : Bool) :
    (w.roundFailed records t l n lim applied).roundOK records t l n lim
      = w.roundOK records t l n lim := by
  cases applied with
  | false => rfl
  | true =>
    simp only [World.roundOK, World.roundFailed, World.batch, if_true, World.mk.injEq, true_and]
    exact ServerState.applyBatch_idem _ _

end World

end Verification.Telemetry
