import Provium.Imperative
/- Write footprints of machine programs. A footprint is a list of field-name
   paths into the receiver (slot 0); a run of a program changes no field path
   that is disjoint from every path in its footprint (neither a prefix nor an
   extension of one). Footprints are computed syntactically, so a consumer
   proves that a function leaves a field unchanged by `decide`. -/
namespace Provium.Imperative
open Provium.State

/-- The value at a field-name path, through records and enum variants. -/
def get : List String → PureValue → Option PureValue
  | [], v => some v
  | f :: p, v => (pureField v f).bind (get p)

/-- The field-name prefix of an access path, up to its first index. -/
def names : List Access → List String
  | [] => []
  | .field f :: rest => f :: names rest
  | .index _ :: _ => []

/-- Neither path is a prefix of the other. -/
def Disjoint (p q : List String) : Prop := ¬ p <+: q ∧ ¬ q <+: p

instance (p q : List String) : Decidable (Disjoint p q) :=
  inferInstanceAs (Decidable (¬ p <+: q ∧ ¬ q <+: p))

theorem disjoint_nil (p : List String) : ¬ Disjoint p [] := fun h => h.2 (List.nil_prefix)

theorem disjoint_cons (f : String) (p q : List String) :
    Disjoint (f :: p) (f :: q) ↔ Disjoint p q := by
  simp [Disjoint, List.cons_prefix_cons]

theorem find_replace (change : PureValue → Except Exit PureValue) (name key : String) :
    ∀ (fields fields' : List (String × PureValue)), replaceField change name fields = .ok fields' →
      (key ≠ name → (fields'.find? (fun pair => pair.1 == key)).map (·.2) =
        (fields.find? (fun pair => pair.1 == key)).map (·.2)) ∧
      (key = name → ∃ old updated, (fields.find? (fun pair => pair.1 == key)).map (·.2) = some old ∧
        change old = .ok updated ∧ (fields'.find? (fun pair => pair.1 == key)).map (·.2) = some updated)
  | [], _, h => by simp [replaceField] at h
  | (n, old) :: rest, fields', h => by
    unfold replaceField at h
    by_cases same : n = name
    · subst same
      cases hc : change old with
      | error e => simp [hc, bind, Except.bind] at h
      | ok updated =>
        simp only [hc, ite_true, bind, Except.bind, pure, Except.pure] at h
        cases h
        constructor
        · intro other
          have : (n == key) = false := by simpa [beq_iff_eq] using fun h => other h.symm
          simp [List.find?, this]
        · intro same
          subst same
          exact ⟨old, updated, by simp [List.find?], hc, by simp [List.find?]⟩
    · cases hr : replaceField change name rest with
      | error e => simp [same, hr, bind, Except.bind] at h
      | ok rest' =>
        simp only [same, ite_false, hr, bind, Except.bind, pure, Except.pure] at h
        cases h
        have ih := find_replace change name key rest rest' hr
        by_cases hk : n = key
        · subst hk
          refine ⟨fun _ => by simp [List.find?], fun h => absurd h same⟩
        · have nk : (n == key) = false := by simpa [beq_iff_eq] using hk
          simp only [List.find?, nk]
          exact ih

theorem get_record (g : String) (p : List String) (name : String) (fields : List (String × PureValue)) :
    get (g :: p) (.record name fields) =
      ((fields.find? (fun pair => pair.1 == g)).map (·.2)).bind (get p) := by
  simp only [get, pureField, pureFields]
  cases h : List.find? (fun pair => pair.fst == g) fields <;> simp [h, bind, pure]

theorem get_variant (g : String) (p : List String) (owner tag : String) (fields : List (String × PureValue)) :
    get (g :: p) (.variant owner tag fields) =
      ((fields.find? (fun pair => pair.1 == g)).map (·.2)).bind (get p) := by
  simp only [get, pureField, pureFields]
  cases h : List.find? (fun pair => pair.fst == g) fields <;> simp [h, bind, pure]

/-- Replacing the place at `path` leaves every field path disjoint from its
    field-name prefix unchanged. -/
theorem update_get (env : PureEnv) :
    ∀ (path : List Access) (current value updated : PureValue) (p : List String),
      update env path current value = .ok updated → Disjoint p (names path) →
      get p updated = get p current
  | [], _, _, _, p, _, d => absurd d (disjoint_nil p)
  | .index _ :: _, _, _, _, p, _, d => absurd d (disjoint_nil p)
  | .field f :: rest, current, value, updated, p, h, d => by
    cases p with
    | nil => exact absurd List.nil_prefix d.1
    | cons g p =>
      cases current with
      | record name fields =>
        cases hr : replaceField (fun old => update env rest old value) f fields with
        | error e => simp [update, hr, bind, Except.bind] at h
        | ok fields' =>
          simp only [update, hr, bind, Except.bind, pure, Except.pure] at h
          cases h
          have facts := find_replace (fun old => update env rest old value) f g fields fields' hr
          by_cases same : g = f
          · subst same
            obtain ⟨old, new, before, step, after⟩ := facts.2 rfl
            have ih := update_get env rest old value new p step ((disjoint_cons g p (names rest)).mp d)
            rw [get_record, get_record, before, after]
            exact ih
          · rw [get_record, get_record, facts.1 same]
      | variant owner tag fields =>
        cases hr : replaceField (fun old => update env rest old value) f fields with
        | error e => simp [update, hr, bind, Except.bind] at h
        | ok fields' =>
          simp only [update, hr, bind, Except.bind, pure, Except.pure] at h
          cases h
          have facts := find_replace (fun old => update env rest old value) f g fields fields' hr
          by_cases same : g = f
          · subst same
            obtain ⟨old, new, before, step, after⟩ := facts.2 rfl
            have ih := update_get env rest old value new p step ((disjoint_cons g p (names rest)).mp d)
            rw [get_variant, get_variant, before, after]
            exact ih
          · rw [get_variant, get_variant, facts.1 same]
      | _ => simp [update] at h

/-- Whether a pattern may bind slot 0; `true` when `n` runs out. -/
def bindsReceiver : Nat → Pattern → Bool
  | 0, _ => true
  | _ + 1, .any | _ + 1, .absent => false
  | _ + 1, .bind slot => slot == 0
  | n + 1, .present p => bindsReceiver n p
  | n + 1, .variant _ _ fields | n + 1, .record _ fields => fields.any (fun f => bindsReceiver n f.2)
  | n + 1, .alternatives patterns => patterns.any (bindsReceiver n)

/-- The access path of a field-only place, if it is one. -/
def fieldPath : List Access → Option (List String)
  | [] => some []
  | .field f :: rest => (fieldPath rest).map (f :: ·)
  | .index _ :: _ => none

/-- The field-name path an expression reads from slot 0, if it is a plain
    chain of field projections of `.read 0`. -/
def readPathOf : Expr → Option (List String)
  | .read 0 => some []
  | .field e g => (readPathOf e).map (· ++ [g])
  | _ => none

/-- Field-name paths into slot 0 that a run of `e` may change. Called functions'
    footprints are expanded through `functions`; `n` bounds the expansion and
    the recursion, and running out yields the whole receiver (`[[]]`). -/
def footprint (functions : String → Option Expr) : Nat → Expr → List (List String)
  | 0, _ => [[]]
  | n + 1, e => match e with
    | .literal _ | .read _ | .panic _ => []
    | .field v _ | .present v | .negate v | .ret v | .scope v | .block _ v | .exit _ v
    | .loop v | .length v | .convert _ _ v => footprint functions n v
    | .index a b | .binary _ a b | .sequence a b | .replicate a b =>
      footprint functions n a ++ footprint functions n b
    | .record _ fields | .variant _ _ fields => fields.flatMap (fun f => footprint functions n f.2)
    | .external _ args => args.flatMap (footprint functions n)
    | .write slot v => (if slot = 0 then [[]] else []) ++ footprint functions n v
    | .assign slot path v =>
      footprint functions n v ++ (if slot = 0 then [names path] else [])
    | .branch c a b => footprint functions n c ++ footprint functions n a ++ footprint functions n b
    | .choose v arms =>
      footprint functions n v ++ (if arms.any (fun a => bindsReceiver n a.1) then [[]] else []) ++
        arms.flatMap (fun a => footprint functions n a.2)
    | .range slot a b body =>
      (if slot = 0 then [[]] else []) ++ footprint functions n a ++ footprint functions n b ++
        footprint functions n body
    | .rotate a b c d => footprint functions n a ++ footprint functions n b ++
        footprint functions n c ++ footprint functions n d
    | .sort a b c => footprint functions n a ++ footprint functions n b ++ footprint functions n c
    | .invoke name receiver writeBack args =>
      footprint functions n receiver ++ args.flatMap (footprint functions n) ++
        match writeBack with
        | none => []
        | some (slot, path) =>
          if slot ≠ 0 then [] else
          match fieldPath path, functions name with
          | some fields, some body =>
            -- The callee's receiver is the place's value when the receiver is
            -- read from that place and no argument writes the caller's receiver.
            if readPathOf receiver = some fields && (args.flatMap (footprint functions n)).isEmpty then
              match footprint functions n body with
              | [] => [names path]
              | callee => callee.map (fields ++ ·)
            else [names path]
          | _, _ => [names path]

/-! Soundness: a run that ends normally, by `return` or by a labeled exit
    leaves every slot-0 path disjoint from its footprint unchanged. -/

/-- The paths outside `fp` read the same in both environments' slot 0. -/
def Keeps (fp : List (List String)) (before after : PureEnv) : Prop :=
  ∀ p, (∀ q ∈ fp, Disjoint p q) → (after 0).bind (get p) = (before 0).bind (get p)

/-- A result ends with environment `env'`: normally, by `return`, or by exit. -/
def Ends (r : Except Exit (α × PureEnv)) (env' : PureEnv) : Prop :=
  (∃ v, r = .ok (v, env')) ∨ (∃ v, r = .error (.returned v env')) ∨
    ∃ l v, r = .error (.exit l v env')

/-- Every ending of `r` keeps the paths outside `fp` from `env`. -/
def Good (fp : List (List String)) (env : PureEnv) (r : Except Exit (α × PureEnv)) : Prop :=
  ∀ env', Ends r env' → Keeps fp env env'

theorem keeps_refl (fp : List (List String)) (env : PureEnv) : Keeps fp env env := fun _ _ => rfl

theorem keeps_trans {fp : List (List String)} {a b c : PureEnv} (first : Keeps fp a b)
    (second : Keeps fp b c) : Keeps fp a c := fun p d => (second p d).trans (first p d)

theorem keeps_mono {fp fp' : List (List String)} {a b : PureEnv} (k : Keeps fp a b)
    (sub : ∀ q ∈ fp, q ∈ fp') : Keeps fp' a b := fun p d => k p (fun q m => d q (sub q m))

theorem keeps_whole {fp : List (List String)} (whole : [] ∈ fp) (a b : PureEnv) : Keeps fp a b :=
  fun p d => absurd (d [] whole) (disjoint_nil p)

theorem keeps_set (fp : List (List String)) (env : PureEnv) {slot : Nat} (other : slot ≠ 0)
    (v : PureValue) : Keeps fp env (pureSet env slot v) := by
  intro p _
  have : (0 = slot) = False := by simp [Ne.symm other]
  simp [pureSet, this]

theorem good_mono {fp fp' : List (List String)} {env : PureEnv} {r : Except Exit (α × PureEnv)}
    (g : Good fp env r) (sub : ∀ q ∈ fp, q ∈ fp') : Good fp' env r :=
  fun e h => keeps_mono (g e h) sub

theorem good_whole {fp : List (List String)} (whole : [] ∈ fp) (env : PureEnv)
    (r : Except Exit (α × PureEnv)) : Good fp env r := fun e _ => keeps_whole whole env e

theorem good_ok {fp : List (List String)} {env env' : PureEnv} (v : α) (k : Keeps fp env env') :
    Good fp env (.ok (v, env')) := by
  intro e h
  rcases h with ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, _, h⟩ <;> cases h
  exact k

theorem good_fault (fp : List (List String)) (env : PureEnv) (f : Fault) :
    Good fp env (.error (.fault f) : Except Exit (α × PureEnv)) := by
  intro e h
  rcases h with ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, _, h⟩ <;> cases h

theorem good_returned {fp : List (List String)} {env env' : PureEnv} (v : PureValue)
    (k : Keeps fp env env') : Good fp env (.error (.returned v env') : Except Exit (α × PureEnv)) := by
  intro e h
  rcases h with ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, _, h⟩ <;> cases h
  exact k

theorem good_exit {fp : List (List String)} {env env' : PureEnv} (l : Nat) (v : PureValue)
    (k : Keeps fp env env') : Good fp env (.error (.exit l v env') : Except Exit (α × PureEnv)) := by
  intro e h
  rcases h with ⟨_, h⟩ | ⟨_, h⟩ | ⟨_, _, h⟩ <;> cases h
  exact k

theorem good_error_ends {fp : List (List String)} {env : PureEnv} {r : Except Exit (α × PureEnv)}
    (g : Good fp env r) (e : Exit) (h : r = .error e) : Good fp env (.error e : Except Exit (β × PureEnv)) := by
  intro env' ends
  apply g env'
  subst h
  rcases ends with ⟨_, h⟩ | ⟨v, h⟩ | ⟨l, v, h⟩
  · cases h
  · cases h
    exact Or.inr (Or.inl ⟨v, rfl⟩)
  · cases h
    exact Or.inr (Or.inr ⟨l, v, rfl⟩)

theorem good_bind {fp : List (List String)} {env : PureEnv} {A : Except Exit (α × PureEnv)}
    {f : α × PureEnv → Except Exit (β × PureEnv)} (first : Good fp env A)
    (rest : ∀ x e1, A = .ok (x, e1) → Good fp e1 (f (x, e1))) : Good fp env (A >>= f) := by
  cases hA : A with
  | error e =>
    have := good_error_ends (β := β) first e hA
    simpa [bind, Except.bind] using this
  | ok pair =>
    obtain ⟨x, e1⟩ := pair
    intro env' ends
    have k1 : Keeps fp env e1 := first e1 (by subst hA; exact Or.inl ⟨x, rfl⟩)
    have : Ends (f (x, e1)) env' := by simpa [bind, Except.bind] using ends
    exact keeps_trans k1 (rest x e1 hA env' this)

theorem good_foldlM {fp : List (List String)} (xs : List γ)
    (g : β × PureEnv → γ → Except Exit (β × PureEnv))
    (step : ∀ b e x, x ∈ xs → Good fp e (g (b, e) x)) :
    ∀ (b : β) (env : PureEnv), Good fp env (xs.foldlM g (b, env)) := by
  induction xs with
  | nil => intro b env; exact good_ok b (keeps_refl fp env)
  | cons x rest ih =>
    intro b env
    simp only [List.foldlM]
    apply good_bind (step b env x (by simp))
    intro b' e1 _
    exact ih (fun b e x m => step b e x (by simp [m])) b' e1

/-- Matching fields one by one keeps slot 0 when each match does. -/
theorem fields_keep (fuel : Nat) (fields : List (String × PureValue))
    (patterns : List (String × Pattern))
    (each : ∀ q ∈ patterns, ∀ value env env', matchPattern fuel q.2 value env = .ok (some env') →
      env' 0 = env 0) :
    ∀ (start : Option PureEnv) (env' : PureEnv) (env : PureEnv), (start = none ∨ start = some env) →
      patterns.foldlM (fun (found : Option PureEnv) (pair : String × Pattern) => match found with
        | none => (.ok none : Except PureFault (Option PureEnv))
        | some env => match fields.find? (fun (field : String × PureValue) => field.1 == pair.1) with
          | some field => matchPattern fuel pair.2 field.2 env
          | none => .error .representation) start = .ok (some env') → env' 0 = env 0 := by
  induction patterns with
  | nil =>
    intro start env' env hs h
    rcases hs with rfl | rfl <;> simp [List.foldlM, pure, Except.pure] at h
    subst h; rfl
  | cons q rest ih =>
    intro start env' env hs h
    simp only [List.foldlM, bind, Except.bind] at h
    rcases hs with rfl | rfl
    · simp only at h
      exact ih (fun q m => each q (by simp [m])) none env' env (Or.inl rfl) h
    · simp only at h
      cases hf : fields.find? (fun field => field.1 == q.1) with
      | none => simp [hf] at h
      | some field =>
        simp only [hf] at h
        cases hm : matchPattern fuel q.2 field.2 env with
        | error e => simp [hm] at h
        | ok r =>
          simp only [hm] at h
          cases r with
          | none => exact ih (fun q m => each q (by simp [m])) none env' env (Or.inl rfl) h
          | some mid =>
            have : mid 0 = env 0 := each q (by simp) field.2 env mid hm
            rw [← this]
            exact ih (fun q m => each q (by simp [m])) (some mid) env' mid (Or.inr rfl) h

theorem match_keeps : ∀ (fuel n : Nat) (pattern : Pattern) (value : PureValue) (env env' : PureEnv),
    bindsReceiver n pattern = false → matchPattern fuel pattern value env = .ok (some env') →
    env' 0 = env 0
  | 0, _, _, _, _, _, _, h => by simp [matchPattern] at h
  | _, 0, _, _, _, _, b, _ => by simp [bindsReceiver] at b
  | fuel + 1, n + 1, pattern, value, env, env', b, h => by
    cases pattern with
    | any => simp [matchPattern] at h; subst h; rfl
    | absent => cases value <;> simp [matchPattern] at h <;> (subst h; rfl)
    | bind slot =>
      simp [matchPattern] at h
      subst h
      simp [bindsReceiver] at b
      have : (0 = slot) = False := by simp [Ne.symm b]
      simp [pureSet, this]
    | present p =>
      cases value <;> simp [matchPattern] at h
      exact match_keeps fuel n p _ env env' (by simpa [bindsReceiver] using b) h
    | variant owner tag patterns =>
      cases value with
      | variant actual variant fields =>
        simp only [matchPattern] at h
        split at h
        · simp at h
        · split at h
          · simp at h
          · simp only [bindsReceiver, List.any_eq_false] at b
            exact fields_keep fuel fields patterns
              (fun q m v e e' hq => match_keeps fuel n q.2 v e e' (by simpa using b q m) hq)
              (some env) env' env (Or.inr rfl) h
      | _ => simp [matchPattern] at h
    | record owner patterns =>
      cases value with
      | record actual fields =>
        simp only [matchPattern] at h
        split at h
        · simp at h
        · split at h
          · simp at h
          · simp only [bindsReceiver, List.any_eq_false] at b
            exact fields_keep fuel fields patterns
              (fun q m v e e' hq => match_keeps fuel n q.2 v e e' (by simpa using b q m) hq)
              (some env) env' env (Or.inr rfl) h
      | _ => simp [matchPattern] at h
    | alternatives patterns =>
      simp only [bindsReceiver, List.any_eq_false] at b
      simp only [matchPattern] at h
      revert h
      suffices ∀ (start : Option PureEnv), (start = none ∨ start = some env) →
          patterns.foldlM (fun (found : Option PureEnv) (pattern : Pattern) => match found with
            | some env => (.ok (some env) : Except PureFault (Option PureEnv))
            | none => matchPattern fuel pattern value env) start = .ok (some env') → env' 0 = env 0 from
        this none (Or.inl rfl)
      induction patterns with
      | nil =>
        intro start hs h
        rcases hs with rfl | rfl <;> simp [List.foldlM, pure, Except.pure] at h
        subst h; rfl
      | cons q rest ih =>
        intro start hs h
        simp only [List.foldlM, bind, Except.bind] at h
        rcases hs with rfl | rfl
        · simp only at h
          cases hm : matchPattern fuel q value env with
          | error e => simp [hm] at h
          | ok r =>
            simp only [hm] at h
            cases r with
            | none => exact ih (fun x m => b x (by simp [m])) none (Or.inl rfl) h
            | some mid =>
              have : mid 0 = env 0 := match_keeps fuel n q value env mid (by simpa using b q (by simp)) hm
              have rest_some : ∀ (rest : List Pattern) (e : PureEnv),
                  rest.foldlM (fun (found : Option PureEnv) (pattern : Pattern) => match found with
                    | some env => (.ok (some env) : Except PureFault (Option PureEnv))
                    | none => matchPattern fuel pattern value env) (some e) = .ok (some env') → env' = e := by
                intro rest e h
                induction rest with
                | nil => simpa [List.foldlM, pure, Except.pure] using h.symm
                | cons _ _ ih' => exact ih' (by simpa [List.foldlM, bind, Except.bind] using h)
              rw [rest_some rest mid h, this]
        · have rest_some : ∀ (rest : List Pattern) (e : PureEnv),
              rest.foldlM (fun (found : Option PureEnv) (pattern : Pattern) => match found with
                | some env => (.ok (some env) : Except PureFault (Option PureEnv))
                | none => matchPattern fuel pattern value env) (some e) = .ok (some env') → env' = e := by
            intro rest e h
            induction rest with
            | nil => simpa [List.foldlM, pure, Except.pure] using h.symm
            | cons _ _ ih' => exact ih' (by simpa [List.foldlM, bind, Except.bind] using h)
          rw [rest_some (q :: rest) env (by simpa [List.foldlM, bind, Except.bind] using h)]

theorem select_keeps (fuel n : Nat) (value : PureValue) (env : PureEnv) :
    ∀ (arms : List (Pattern × Expr)) (body : Expr) (env' : PureEnv),
      arms.any (fun a => bindsReceiver n a.1) = false →
      select fuel arms value env = .ok (some (body, env')) → env' 0 = env 0 ∧ body ∈ arms.map (·.2) := by
  intro arms body env' b h
  unfold select at h
  suffices ∀ (start : Option (Expr × PureEnv)),
      (start = none ∨ ∃ e, start = some e ∧ e.2 0 = env 0 ∧ e.1 ∈ arms.map (·.2)) →
      ∀ (rest : List (Pattern × Expr)), (∀ a ∈ rest, a ∈ arms) →
      rest.foldlM (fun (found : Option (Expr × PureEnv)) (arm : Pattern × Expr) => match found with
        | some hit => (.ok (some hit) : Except PureFault (Option (Expr × PureEnv)))
        | none => match matchPattern fuel arm.1 value env with
          | .ok (some env) => .ok (some (arm.2, env))
          | .ok none => .ok none
          | .error reason => .error reason) start = .ok (some (body, env')) →
      env' 0 = env 0 ∧ body ∈ arms.map (·.2) from this none (Or.inl rfl) arms (fun _ m => m) h
  intro start hs rest sub
  induction rest generalizing start with
  | nil =>
    intro h
    simp [List.foldlM, pure, Except.pure] at h
    rcases hs with rfl | ⟨e, rfl, k, m⟩
    · simp at h
    · simp at h
      obtain ⟨rfl, rfl⟩ := h
      exact ⟨k, m⟩
  | cons a rest ih =>
    intro h
    simp only [List.foldlM, bind, Except.bind] at h
    rcases hs with rfl | ⟨e, rfl, k, m⟩
    · simp only at h
      cases hm : matchPattern fuel a.1 value env with
      | error r => simp [hm] at h
      | ok r =>
        cases r with
        | none =>
          simp only [hm] at h
          exact ih none (Or.inl rfl) (fun x mx => sub x (by simp [mx])) h
        | some mid =>
          simp only [hm] at h
          have keep := match_keeps fuel n a.1 value env mid
            (by simp only [List.any_eq_false] at b; simpa using b a (sub a (by simp))) hm
          exact ih (some (a.2, mid)) (Or.inr ⟨_, rfl, keep, by simpa using ⟨a.1, sub a (by simp)⟩⟩)
            (fun x mx => sub x (by simp [mx])) h
    · simp only at h
      exact ih (some e) (Or.inr ⟨e, rfl, k, m⟩) (fun x mx => sub x (by simp [mx])) h

theorem frame_receiver (self : PureValue) :
    ∀ (values : List PureValue) (start : Nat), 0 < start →
      ((values.zipIdx start).foldl (fun frame (value, slot) => pureSet frame slot value)
        (pureSet (fun _ => none) 0 self)) 0 = some self := by
  intro values
  suffices ∀ (start : Nat) (frame : PureEnv), 0 < start → frame 0 = some self →
      ((values.zipIdx start).foldl (fun frame (value, slot) => pureSet frame slot value) frame) 0 = some self by
    intro start pos
    exact this start _ pos (by simp [pureSet])
  induction values with
  | nil => intro start frame _ h; simpa using h
  | cons v rest ih =>
    intro start frame pos h
    simp only [List.zipIdx_cons, List.foldl_cons]
    apply ih (start + 1) _ (by omega)
    have : (0 = start) = False := by simp; omega
    simp [pureSet, this, h]

theorem get_append : ∀ (a b : List String) (v : PureValue), get (a ++ b) v = (get a v).bind (get b)
  | [], b, v => by simp [get]
  | f :: a, b, v => by
    simp only [List.cons_append, get]
    cases pureField v f <;> simp [get_append a b]

theorem names_of_fieldPath : ∀ (path : List Access) (fields : List String),
    fieldPath path = some fields → names path = fields
  | [], _, h => by simp [fieldPath] at h; simp [names, h]
  | .field f :: rest, fields, h => by
    simp only [fieldPath, Option.map_eq_some_iff] at h
    obtain ⟨tail, ht, rfl⟩ := h
    simp [names, names_of_fieldPath rest tail ht]
  | .index _ :: _, _, h => by simp [fieldPath] at h

/-- After replacing a field-only place, reading below it reads the new value. -/
theorem update_inside (env : PureEnv) : ∀ (path : List Access) (fields : List String)
    (current value updated : PureValue) (p : List String), fieldPath path = some fields →
    update env path current value = .ok updated → get (fields ++ p) updated = get p value
  | [], fields, current, value, updated, p, hp, h => by
    simp [fieldPath] at hp; subst hp
    simp [update] at h; subst h; rfl
  | .index _ :: _, _, _, _, _, _, hp, _ => by simp [fieldPath] at hp
  | .field f :: rest, fields, current, value, updated, p, hp, h => by
    simp only [fieldPath, Option.map_eq_some_iff] at hp
    obtain ⟨tail, ht, rfl⟩ := hp
    cases current with
    | record name fs =>
      cases hr : replaceField (fun old => update env rest old value) f fs with
      | error e => simp [update, hr, bind, Except.bind] at h
      | ok fs' =>
        simp only [update, hr, bind, Except.bind, pure, Except.pure] at h
        cases h
        obtain ⟨old, new, _, step, after⟩ := (find_replace _ f f fs fs' hr).2 rfl
        rw [List.cons_append, get_record, after]
        exact update_inside env rest tail old value new p ht step
    | variant owner tag fs =>
      cases hr : replaceField (fun old => update env rest old value) f fs with
      | error e => simp [update, hr, bind, Except.bind] at h
      | ok fs' =>
        simp only [update, hr, bind, Except.bind, pure, Except.pure] at h
        cases h
        obtain ⟨old, new, _, step, after⟩ := (find_replace _ f f fs fs' hr).2 rfl
        rw [List.cons_append, get_variant, after]
        exact update_inside env rest tail old value new p ht step
    | _ => simp [update] at h

/-- A pure read along a field path returns the value there and changes nothing. -/
theorem read_path (m : Machine) : ∀ (fuel : Nat) (e : Expr) (fields : List String) (env env' : PureEnv)
    (v : PureValue), readPathOf e = some fields → eval m fuel e env = .ok (v, env') →
    env' = env ∧ (env 0).bind (get fields) = some v
  | 0, _, _, _, _, _, _, h => by simp [eval] at h
  | fuel + 1, .read slot, fields, env, env', v, hr, h => by
    cases slot with
    | zero =>
      simp [readPathOf] at hr; subst hr
      simp only [eval] at h
      cases h0 : env 0 with
      | none => simp [h0] at h
      | some w => simp [h0] at h; obtain ⟨rfl, rfl⟩ := h; simp [get]
    | succ _ => simp [readPathOf] at hr
  | fuel + 1, .field e g, fields, env, env', v, hr, h => by
    simp only [readPathOf, Option.map_eq_some_iff] at hr
    obtain ⟨front, hf, rfl⟩ := hr
    simp only [eval, bind, Except.bind] at h
    cases he : eval m fuel e env with
    | error x => simp [he] at h
    | ok pair =>
      obtain ⟨w, e1⟩ := pair
      obtain ⟨rfl, hw⟩ := read_path m fuel e front env e1 w hf he
      simp only [he] at h
      cases hg : pureField w g with
      | none => simp [hg] at h
      | some u =>
        simp [hg, pure, Except.pure] at h
        obtain ⟨rfl, rfl⟩ := h
        refine ⟨rfl, ?_⟩
        cases h0 : e1 0 with
        | none => simp [h0] at hw
        | some r =>
          simp only [h0, Option.bind_some] at hw ⊢
          rw [get_append, hw]
          simp [get, hg]
  | fuel + 1, .literal _, _, _, _, _, hr, _ | fuel + 1, .index _ _, _, _, _, _, hr, _
  | fuel + 1, .present _, _, _, _, _, hr, _ | fuel + 1, .record _ _, _, _, _, _, hr, _
  | fuel + 1, .variant _ _ _, _, _, _, _, hr, _ | fuel + 1, .binary _ _ _, _, _, _, _, hr, _
  | fuel + 1, .negate _, _, _, _, _, hr, _ | fuel + 1, .sequence _ _, _, _, _, _, hr, _
  | fuel + 1, .write _ _, _, _, _, _, hr, _ | fuel + 1, .assign _ _ _, _, _, _, _, hr, _
  | fuel + 1, .branch _ _ _, _, _, _, _, hr, _ | fuel + 1, .choose _ _, _, _, _, _, hr, _
  | fuel + 1, .range _ _ _ _, _, _, _, _, hr, _ | fuel + 1, .ret _, _, _, _, _, hr, _
  | fuel + 1, .scope _, _, _, _, _, hr, _ | fuel + 1, .panic _, _, _, _, _, hr, _
  | fuel + 1, .block _ _, _, _, _, _, hr, _ | fuel + 1, .exit _ _, _, _, _, _, hr, _
  | fuel + 1, .loop _, _, _, _, _, hr, _ | fuel + 1, .length _, _, _, _, _, hr, _
  | fuel + 1, .external _ _, _, _, _, _, hr, _ | fuel + 1, .convert _ _ _, _, _, _, _, hr, _
  | fuel + 1, .rotate _ _ _ _, _, _, _, _, hr, _ | fuel + 1, .replicate _ _, _, _, _, _, hr, _
  | fuel + 1, .sort _ _ _, _, _, _, _, hr, _ | fuel + 1, .invoke _ _ _ _, _, _, _, _, hr, _ => by
    simp [readPathOf] at hr

/-- A computation whose only errors are faults. -/
def FaultsOnly (x : Except Exit α) : Prop := ∀ e, x = .error e → ∃ f, e = .fault f

theorem faults_ok (v : α) : FaultsOnly (.ok v : Except Exit α) := fun _ h => by cases h
theorem faults_fault (f : Fault) : FaultsOnly (.error (.fault f) : Except Exit α) := fun _ h => by
  cases h; exact ⟨f, rfl⟩
theorem faults_ite {c : Prop} [Decidable c] {a b : Except Exit α} (ha : FaultsOnly a) (hb : FaultsOnly b) :
    FaultsOnly (if c then a else b) := by
  split
  · exact ha
  · exact hb

/-- Proves `FaultsOnly` of a tree of `if`s, `match`es, values and faults. -/
macro "faults" : tactic => `(tactic| repeat' first
  | exact faults_ok _ | exact faults_fault _ | apply faults_ite | split)

theorem arithmetic_faults (bits : Nat) (checked : Bool) (op kind : String) (a b : Nat) :
    FaultsOnly (arithmetic bits checked op kind a b) := by
  unfold arithmetic word
  faults

theorem binary_faults (bits : Nat) (checked : Bool) (fuel : Nat) (op : String) (a b : PureValue) :
    FaultsOnly (binary bits checked fuel op a b) := by
  unfold binary
  repeat' first
    | exact faults_ok _ | exact faults_fault _ | apply faults_ite | exact arithmetic_faults _ _ _ _ _ _
    | split

theorem faults_bind {x : Except Exit α} {f : α → Except Exit β} (hx : FaultsOnly x)
    (hf : ∀ v, FaultsOnly (f v)) : FaultsOnly (x >>= f) := by
  intro e h
  cases hv : x with
  | error y => simp [hv, bind, Except.bind] at h; subst h; exact hx y hv
  | ok v => simp [hv, bind, Except.bind] at h; exact hf v e h

theorem faults_pure (v : α) : FaultsOnly (pure v : Except Exit α) := faults_ok v

theorem replace_faults (change : PureValue → Except Exit PureValue) (name : String)
    (hc : ∀ v, FaultsOnly (change v)) : ∀ fields, FaultsOnly (replaceField change name fields)
  | [] => by unfold replaceField; exact faults_fault _
  | (n, old) :: rest => by
    unfold replaceField
    apply faults_ite
    · exact faults_bind (hc old) (fun _ => faults_pure _)
    · exact faults_bind (replace_faults change name hc rest) (fun _ => faults_pure _)

theorem update_faults (env : PureEnv) : ∀ (path : List Access) (current value : PureValue),
    FaultsOnly (update env path current value)
  | [], _, _ => by unfold update; exact faults_ok _
  | .field f :: rest, current, value => by
    cases current <;> unfold update <;> first
      | exact faults_fault _
      | exact faults_bind (replace_faults _ f (fun old => update_faults env rest old value) _)
          (fun _ => faults_pure _)
  | .index slot :: rest, current, value => by
    cases current <;> unfold update <;> first
      | exact faults_fault _
      | (repeat' first | exact faults_fault _ | exact faults_ok _ | split | exact faults_bind (update_faults env rest _ value) (fun _ => faults_pure _))

/-- Binding a faults-only computation and returning its value. -/
theorem good_faults_bind {fp : List (List String)} {env : PureEnv} {x : Except Exit α}
    {f : α → Except Exit (β × PureEnv)} (faults : FaultsOnly x)
    (rest : ∀ v, x = .ok v → Good fp env (f v)) : Good fp env (x >>= f) := by
  cases hx : x with
  | error e =>
    obtain ⟨g, rfl⟩ := faults e hx
    simpa [bind, Except.bind] using good_fault fp env g
  | ok v => simpa [bind, Except.bind] using rest v hx

theorem good_pre {fp : List (List String)} {a b : PureEnv} {r : Except Exit (α × PureEnv)}
    (k : Keeps fp a b) (g : Good fp b r) : Good fp a r := fun e h => keeps_trans k (g e h)

theorem index_cases (values : List PureValue) (position : PureValue) :
    (∃ v, indexValue values position = .ok v) ∨ ∃ f, indexValue values position = .error (.fault f) := by
  unfold indexValue
  split
  · split
    · exact Or.inl ⟨_, rfl⟩
    · exact Or.inr ⟨_, rfl⟩
  · exact Or.inr ⟨_, rfl⟩

theorem disjoint_append (fields p q : List String) :
    Disjoint (fields ++ p) (fields ++ q) ↔ Disjoint p q := by
  simp [Disjoint, List.prefix_append_right_inj]

theorem not_disjoint (p q : List String) (h : ¬ Disjoint p q) : p <+: q ∨ q <+: p := by
  unfold Disjoint at h
  by_cases a : p <+: q
  · exact Or.inl a
  · exact Or.inr (by simpa [a] using h)

/-- Writing a callee's final receiver back to a field-only place keeps every
    path disjoint from the place-relative callee footprint, given that the
    callee started from the place's value and kept the paths outside its own
    nonempty footprint. -/
theorem writeback_keeps (env : PureEnv) (path : List Access) (fields : List String)
    (callee : List (List String)) (current self updated replaced : PureValue)
    (fp : fieldPath path = some fields) (nonempty : callee ≠ [])
    (at_place : get fields current = some self)
    (kept : ∀ p, (∀ q ∈ callee, Disjoint p q) → get p updated = get p self)
    (hu : update env path current updated = .ok replaced) :
    ∀ p, (∀ q ∈ callee.map (fields ++ ·), Disjoint p q) → get p replaced = get p current := by
  intro p d
  have hn := names_of_fieldPath path fields fp
  by_cases outside : Disjoint p fields
  · exact update_get env path current updated replaced p hu (hn ▸ outside)
  · rcases not_disjoint p fields outside with before | ⟨rest, rfl⟩
    · obtain ⟨q, hq⟩ := List.exists_mem_of_ne_nil callee nonempty
      have : p <+: fields ++ q := before.trans (List.prefix_append fields q)
      exact absurd this (d _ (List.mem_map_of_mem hq)).1
    · rw [update_inside env path fields current updated replaced rest fp hu, get_append, at_place]
      simp only [Option.bind_some]
      exact kept rest (fun q hq => (disjoint_append fields rest q).mp (d _ (List.mem_map_of_mem hq)))

theorem refined_member (functions : String → Option Expr) (n : Nat) (name : String) (receiver : Expr)
    (path : List Access) (args : List Expr) (fields : List String) (body : Expr)
    (h1 : fieldPath path = some fields) (h2 : functions name = some body)
    (h3 : readPathOf receiver = some fields)
    (h4 : (args.flatMap (footprint functions n)).isEmpty = true)
    (h5 : footprint functions n body ≠ []) :
    ∀ q ∈ (footprint functions n body).map (fields ++ ·),
      q ∈ footprint functions (n + 1) (.invoke name receiver (some (0, path)) args) := by
  intro q hq
  simp only [footprint, h1, h2, h3, h4, decide_true, Bool.and_self, ite_true, ne_eq,
    not_true_eq_false, ite_false, List.mem_append]
  exact Or.inr hq

theorem place_member (functions : String → Option Expr) (n : Nat) (name : String) (receiver : Expr)
    (path : List Access) (args : List Expr)
    (coarse : ¬ ∃ fields body, fieldPath path = some fields ∧ functions name = some body ∧
      readPathOf receiver = some fields ∧ (args.flatMap (footprint functions n)).isEmpty = true ∧
      footprint functions n body ≠ []) :
    names path ∈ footprint functions (n + 1) (.invoke name receiver (some (0, path)) args) := by
  simp only [footprint, ne_eq, not_true_eq_false, ite_false, List.mem_append]
  right
  cases hp : fieldPath path with
  | none => simp
  | some fields =>
    cases hb : functions name with
    | none => simp
    | some body =>
      simp only []
      split
      · rename_i cond
        split
        · simp
        · rename_i callee hcallee
          exfalso
          apply coarse
          refine ⟨fields, body, hp, hb, ?_, ?_, ?_⟩
          · simpa using (Bool.and_eq_true _ _).mp cond |>.1
          · exact ((Bool.and_eq_true _ _).mp cond).2
          · intro h; rw [h] at hcallee; exact hcallee rfl
      · simp

theorem good_refl_ok {fp : List (List String)} {env : PureEnv} (v : α) :
    Good fp env (.ok (v, env) : Except Exit (α × PureEnv)) := good_ok v (keeps_refl fp env)

theorem good_pure {fp : List (List String)} {env : PureEnv} (v : α) :
    Good fp env (pure (v, env) : Except Exit (α × PureEnv)) := good_ok v (keeps_refl fp env)

/-- Closes a goal whose result is a plain value, the unchanged environment or a fault. -/
macro "finish" : tactic => `(tactic| first
  | exact good_pure _ | exact good_refl_ok _ | exact good_fault _ _ _)

/-- Membership of a sub-footprint in the enclosing one. -/
macro "member" : tactic => `(tactic| (intro q h; simp [footprint, h]))

/-- The footprint is sound: every run of `e` that ends normally, by `return`
    or by a labeled exit changes no slot-0 field path disjoint from it. -/
theorem footprint_sound (m : Machine) : ∀ (fuel n : Nat) (e : Expr) (env : PureEnv),
    Good (footprint m.functions n e) env (eval m fuel e env)
  | 0, _, _, env => by simp only [eval]; exact good_fault _ env _
  | _ + 1, 0, e, env => good_whole (by simp [footprint]) env _
  | fuel + 1, n + 1, e, env => by
    have sub : ∀ (a : Expr) (env' : PureEnv), (∀ q ∈ footprint m.functions n a,
        q ∈ footprint m.functions (n + 1) e) →
        Good (footprint m.functions (n + 1) e) env' (eval m fuel a env') :=
      fun a env' h => good_mono (footprint_sound m fuel n a env') h
    cases e with
    | literal v => simp only [eval]; finish
    | read slot =>
      simp only [eval]
      split <;> finish
    | panic r => simp only [eval]; finish
    | field v g =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      simp only []
      split <;> finish
    | present v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      finish
    | negate v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      cases x <;> simp only [] <;> finish
    | ret v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      exact good_returned x (keeps_refl _ _)
    | exit l v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      exact good_exit l x (keeps_refl _ _)
    | scope body =>
      simp only [eval]
      have g := sub body env (by member)
      split
      · rename_i v e1 h
        rw [h] at g
        exact good_ok v (g e1 (Or.inr (Or.inl ⟨v, rfl⟩)))
      · exact g
    | block label body =>
      simp only [eval]
      have g := sub body env (by member)
      split
      · rename_i t v e1 h
        rw [h] at g
        have k := g e1 (Or.inr (Or.inr ⟨t, v, rfl⟩))
        split
        · exact good_ok v k
        · exact good_exit t v k
      · exact g
    | loop body =>
      simp only [eval]
      apply good_bind (sub body env (by member))
      intro x e1 _
      exact footprint_sound m fuel (n + 1) (.loop body) e1
    | length a =>
      simp only [eval]
      apply good_bind (sub a env (by member))
      intro x e1 _
      cases x <;> simp only [] <;> finish
    | convert kind checked v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      cases x <;> simp only [] <;> try finish
      split
      · finish
      · split <;> finish
    | sequence a b =>
      simp only [eval]
      apply good_bind (sub a env (by member))
      intro x e1 _
      exact sub b e1 (by member)
    | index a b =>
      simp only [eval]
      apply good_bind (sub a env (by member))
      intro x e1 hx
      clear hx
      apply good_bind (sub b e1 (by member))
      intro y e2 hy
      clear hy
      cases x
      case array values =>
        simp only []
        rcases index_cases values y with ⟨v, hv⟩ | ⟨f, hv⟩ <;> simp only [hv, bind, Except.bind] <;> finish
      all_goals (simp only []; finish)
    | record name fields =>
      simp only [eval]
      apply good_bind
      · apply good_foldlM
        intro b e x mx
        obtain ⟨f, v⟩ := x
        apply good_bind (sub v e (by
          intro q h; simp only [footprint, List.mem_flatMap]; exact ⟨(f, v), mx, h⟩))
        intro y e1 _
        finish
      · intro x e1 _
        finish
    | variant name tag fields =>
      simp only [eval]
      apply good_bind
      · apply good_foldlM
        intro b e x mx
        obtain ⟨f, v⟩ := x
        apply good_bind (sub v e (by
          intro q h; simp only [footprint, List.mem_flatMap]; exact ⟨(f, v), mx, h⟩))
        intro y e1 _
        finish
      · intro x e1 _
        finish
    | external name args =>
      simp only [eval]
      apply good_bind
      · apply good_foldlM
        intro b e x mx
        apply good_bind (sub x e (by
          intro q h; simp only [footprint, List.mem_flatMap]; exact ⟨x, mx, h⟩))
        intro y e1 _
        finish
      · intro x e1 _
        simp only []
        split <;> finish
    | binary op left right =>
      simp only [eval]
      apply good_bind (sub left env (by member))
      intro x e1 hx
      clear hx
      simp only []
      split
      · cases x <;> simp only [] <;> try finish
        split
        · finish
        · apply good_bind (sub right e1 (by member))
          intro y e2 hy
          clear hy
          cases y <;> simp only [] <;> finish
      · apply good_bind (sub right e1 (by member))
        intro y e2 hy
        clear hy
        exact good_faults_bind (binary_faults _ _ _ _ _ _) (fun _ _ => good_pure _)
    | write slot v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      by_cases zero : slot = 0
      · exact good_whole (by simp [footprint, zero]) _ _
      · exact good_ok _ (keeps_set _ e1 zero x)
    | assign slot path v =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      simp only []
      split
      · finish
      · rename_i current hc
        apply good_faults_bind (update_faults _ _ _ _)
        intro updated hu
        by_cases zero : slot = 0
        · subst zero
          apply good_ok
          intro p d
          have dp : Disjoint p (names path) := d _ (by simp [footprint])
          simp [pureSet, hc, update_get e1 path current x updated p hu dp]
        · exact good_ok _ (keeps_set _ e1 zero updated)
    | branch c yes no =>
      simp only [eval]
      apply good_bind (sub c env (by member))
      intro x e1 hx
      clear hx
      cases x <;> simp only [] <;> try finish
      rename_i b
      cases b
      · exact sub no e1 (by member)
      · exact sub yes e1 (by member)
    | choose v arms =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      simp only []
      split
      · rename_i body e2 hs
        by_cases binds : arms.any (fun a => bindsReceiver n a.1) = true
        · exact good_whole (by simp [footprint, binds]) _ _
        · obtain ⟨same, mem⟩ := select_keeps fuel n x e1 arms body e2 (by simpa using binds) hs
          have k : Keeps (footprint m.functions (n + 1) (.choose v arms)) e1 e2 := by
            intro p _; rw [same]
          apply good_pre k
          apply sub body e2
          intro q h
          simp only [List.mem_map] at mem
          obtain ⟨a, ma, rfl⟩ := mem
          simp only [footprint, List.mem_append, List.mem_flatMap]
          exact Or.inr ⟨a, ma, h⟩
      all_goals finish
    | range slot a b body =>
      simp only [eval]
      apply good_bind (sub a env (by member))
      intro x e1 hx
      clear hx
      cases x <;> simp only [] <;> try finish
      apply good_bind (sub b e1 (by member))
      intro y e2 hy
      clear hy
      cases y <;> simp only [] <;> try finish
      split
      · finish
      · apply good_foldlM
        intro u e i _
        by_cases zero : slot = 0
        · exact good_whole (by simp [footprint, zero]) _ _
        · exact good_pre (keeps_set _ e zero _) (sub body _ (by member))
    | rotate a b c d =>
      simp only [eval]
      apply good_bind (sub a env (by member))
      intro x e1 _
      apply good_bind (sub b e1 (by member))
      intro y e2 hy
      clear hy
      cases y <;> simp only [] <;> try finish
      apply good_bind (sub c e2 (by member))
      intro z e3 hz
      clear hz
      cases z <;> simp only [] <;> try finish
      apply good_bind (sub d e3 (by member))
      intro w e4 hw
      clear hw
      cases w <;> simp only [] <;> try finish
      cases x <;> simp only [] <;> try finish
      split
      · finish
      · split <;> finish
    | sort a b c =>
      simp only [eval]
      apply good_bind (sub a env (by member))
      intro x e1 _
      apply good_bind (sub b e1 (by member))
      intro y e2 hy
      clear hy
      cases y <;> simp only [] <;> try finish
      apply good_bind (sub c e2 (by member))
      intro z e3 hz
      clear hz
      cases z <;> simp only [] <;> try finish
      cases x <;> simp only [] <;> try finish
      split
      · finish
      · split <;> finish
    | replicate v count =>
      simp only [eval]
      apply good_bind (sub v env (by member))
      intro x e1 _
      apply good_bind (sub count e1 (by member))
      intro y e2 hy
      clear hy
      cases y <;> simp only [] <;> finish
    | invoke name receiver writeBack args =>
      simp only [eval]
      have gr := footprint_sound m fuel n receiver env
      apply good_bind (good_mono gr (by member))
      intro self e1 hself
      have ga : Good (args.flatMap (footprint m.functions n)) e1 (args.foldlM (fun (values, env) argument => do
          let (value, env) ← eval m fuel argument env
          return (values ++ [value], env)) ([], e1)) := by
        apply good_foldlM
        intro b e x mx
        apply good_bind (good_mono (footprint_sound m fuel n x e) (by
          intro q h; simp only [List.mem_flatMap]; exact ⟨x, mx, h⟩))
        intro y e' _
        exact good_pure _
      apply good_bind (good_mono ga (by member))
      intro values e2 hvalues
      simp only []
      split
      · finish
      · rename_i body hbody
        have gb := footprint_sound m fuel n body
          ((values.zipIdx 1).foldl (fun frame (value, slot) => pureSet frame slot value)
            (pureSet (fun _ => none) 0 self))
        have frame0 := frame_receiver self values 1 (by omega)
        -- The callee's outcome: a value and final environment, or a fault.
        cases hrun : eval m fuel body ((values.zipIdx 1).foldl
            (fun frame (value, slot) => pureSet frame slot value) (pureSet (fun _ => none) 0 self)) with
        | error x =>
          cases x with
          | fault f => simp only [bind, Except.bind]; finish
          | exit l v fin => simp only [bind, Except.bind]; finish
          | returned v fin =>
            have kept := gb fin (by rw [hrun]; exact Or.inr (Or.inl ⟨v, rfl⟩))
            simp only [bind, Except.bind]
            exact (by
              cases writeBack with
              | none => exact good_pure _
              | some w =>
                obtain ⟨slot, path⟩ := w
                simp only []
                split
                · rename_i updated current hfin hcur
                  apply good_faults_bind (update_faults _ _ _ _)
                  intro replaced hu
                  apply good_ok
                  by_cases zero : slot = 0
                  · subst zero
                    intro p d
                    simp only [pureSet, ite_true, hcur, Option.bind_some]
                    by_cases refined : ∃ fields body', fieldPath path = some fields ∧
                        m.functions name = some body' ∧ readPathOf receiver = some fields ∧
                        (args.flatMap (footprint m.functions n)).isEmpty = true ∧
                        footprint m.functions n body' ≠ []
                    · obtain ⟨fields, body', hpath, hb', hread, hargs, hne⟩ := refined
                      rw [hbody] at hb'
                      cases hb'
                      have inK := refined_member m.functions n name receiver path args fields body
                        hpath hbody hread hargs hne
                      obtain ⟨same, at_env⟩ := read_path m fuel receiver fields env e1 self hread hself
                      have argsKeep : e2 0 = e1 0 := by
                        have k := ga e2 (by rw [hvalues]; exact Or.inl ⟨values, rfl⟩)
                        have := k [] (fun q hq => by simp [List.isEmpty_iff.mp hargs] at hq)
                        simpa [get] using this
                      have cur : env 0 = some current := by rw [← same, ← argsKeep]; exact hcur
                      rw [cur] at at_env
                      simp only [Option.bind_some] at at_env
                      have kept' : ∀ p, (∀ q ∈ footprint m.functions n body, Disjoint p q) →
                          get p updated = get p self := by
                        intro p dp
                        have := kept p dp
                        rw [hfin, frame0] at this
                        simpa using this
                      exact writeback_keeps e2 path fields _ current self updated replaced hpath hne
                        at_env kept' hu p (fun q hq => d q (inK q hq))
                    · exact update_get e2 path current updated replaced p hu
                        (d _ (place_member m.functions n name receiver path args refined))
                  · exact keeps_set _ e2 zero replaced
                · finish)
        | ok pair =>
          obtain ⟨v, fin⟩ := pair
          have kept := gb fin (by rw [hrun]; exact Or.inl ⟨v, rfl⟩)
          simp only [bind, Except.bind]
          exact (by
              cases writeBack with
              | none => exact good_pure _
              | some w =>
                obtain ⟨slot, path⟩ := w
                simp only []
                split
                · rename_i updated current hfin hcur
                  apply good_faults_bind (update_faults _ _ _ _)
                  intro replaced hu
                  apply good_ok
                  by_cases zero : slot = 0
                  · subst zero
                    intro p d
                    simp only [pureSet, ite_true, hcur, Option.bind_some]
                    by_cases refined : ∃ fields body', fieldPath path = some fields ∧
                        m.functions name = some body' ∧ readPathOf receiver = some fields ∧
                        (args.flatMap (footprint m.functions n)).isEmpty = true ∧
                        footprint m.functions n body' ≠ []
                    · obtain ⟨fields, body', hpath, hb', hread, hargs, hne⟩ := refined
                      rw [hbody] at hb'
                      cases hb'
                      have inK := refined_member m.functions n name receiver path args fields body
                        hpath hbody hread hargs hne
                      obtain ⟨same, at_env⟩ := read_path m fuel receiver fields env e1 self hread hself
                      have argsKeep : e2 0 = e1 0 := by
                        have k := ga e2 (by rw [hvalues]; exact Or.inl ⟨values, rfl⟩)
                        have := k [] (fun q hq => by simp [List.isEmpty_iff.mp hargs] at hq)
                        simpa [get] using this
                      have cur : env 0 = some current := by rw [← same, ← argsKeep]; exact hcur
                      rw [cur] at at_env
                      simp only [Option.bind_some] at at_env
                      have kept' : ∀ p, (∀ q ∈ footprint m.functions n body, Disjoint p q) →
                          get p updated = get p self := by
                        intro p dp
                        have := kept p dp
                        rw [hfin, frame0] at this
                        simpa using this
                      exact writeback_keeps e2 path fields _ current self updated replaced hpath hne
                        at_env kept' hu p (fun q hq => d q (inK q hq))
                    · exact update_get e2 path current updated replaced p hu
                        (d _ (place_member m.functions n name receiver path args refined))
                  · exact keeps_set _ e2 zero replaced
                · finish)

/-- A successful run changes no receiver field path disjoint from the body's
    footprint, for any footprint bound `n`. -/
theorem run_keeps (m : Machine) (fuel n : Nat) (body : Expr) (receiver receiver' : PureValue)
    (arguments : List PureValue) (value : PureValue)
    (h : run m fuel body receiver arguments = .ok (value, receiver')) :
    ∀ p, (∀ q ∈ footprint m.functions n body, Disjoint p q) → get p receiver' = get p receiver := by
  intro p d
  have frame0 := frame_receiver receiver arguments 1 (by omega)
  unfold run at h
  dsimp only at h
  have g := footprint_sound m fuel n body
    ((arguments.zipIdx 1).foldl (fun env (value, slot) => pureSet env slot value)
      (pureSet (fun _ => none) 0 receiver))
  split at h
  · simp at h
  · rename_i v env hrun
    split at h
    · rename_i r hr
      simp only [Except.ok.injEq, Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      have := g env (by rw [hrun]; exact Or.inl ⟨v, rfl⟩) p d
      rw [hr, frame0] at this
      simpa using this
    · simp at h
  · rename_i v env hrun
    split at h
    · rename_i r hr
      simp only [Except.ok.injEq, Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      have := g env (by rw [hrun]; exact Or.inr (Or.inl ⟨v, rfl⟩)) p d
      rw [hr, frame0] at this
      simpa using this
    · simp at h
  · simp at h

end Provium.Imperative
