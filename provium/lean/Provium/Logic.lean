import Provium.Footprint
/- A partial-correctness program logic for the imperative machine. A triple
   `Triple m P e Q` says that every way a run of `e` from an environment
   satisfying `P` can end (normally, by `return`, or by a labeled exit)
   satisfies the matching part of `Q`; faults, including exhausted fuel, are
   not constrained, so freedom from panics is a separate obligation. Loops are
   verified with invariants; calls through the function table with
   per-function specifications. -/
namespace Provium.Imperative
open Provium.State

/-- What may hold after a run: one condition per way of ending. -/
structure Post where
  normal : PureValue → PureEnv → Prop
  returned : PureValue → PureEnv → Prop
  exited : Nat → PureValue → PureEnv → Prop

/-- The postcondition that a result's ending satisfies `Q`. -/
def Post.holds (Q : Post) : Except Exit (PureValue × PureEnv) → Prop
  | .ok (v, env) => Q.normal v env
  | .error (.returned v env) => Q.returned v env
  | .error (.exit l v env) => Q.exited l v env
  | .error (.fault _) => True

def Triple (m : Machine) (P : PureEnv → Prop) (e : Expr) (Q : Post) : Prop :=
  ∀ fuel env, P env → Q.holds (eval m fuel e env)

/-- `Q` with its normal ending replaced. -/
def Post.withNormal (Q : Post) (normal : PureValue → PureEnv → Prop) : Post :=
  { Q with normal := normal }

theorem Post.holds_fault (Q : Post) (f : Fault) : Q.holds (.error (.fault f)) := trivial

/-- Weakening: a stronger precondition and weaker postconditions. -/
theorem triple_consequence {m : Machine} {P P' : PureEnv → Prop} {e : Expr} {Q Q' : Post}
    (t : Triple m P e Q) (pre : ∀ env, P' env → P env)
    (normal : ∀ v env, Q.normal v env → Q'.normal v env)
    (returned : ∀ v env, Q.returned v env → Q'.returned v env)
    (exited : ∀ l v env, Q.exited l v env → Q'.exited l v env) : Triple m P' e Q' := by
  intro fuel env h
  have := t fuel env (pre env h)
  revert this
  cases eval m fuel e env with
  | ok r => obtain ⟨v, e'⟩ := r; exact normal v e'
  | error x => cases x with
    | returned v e' => exact returned v e'
    | exit l v e' => exact exited l v e'
    | fault f => intro _; trivial

theorem triple_literal (m : Machine) (P : PureEnv → Prop) (v : PureValue) (Q : Post)
    (h : ∀ env, P env → Q.normal v env) : Triple m P (.literal v) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel => simp only [eval, Post.holds]; exact h env hp

theorem triple_read (m : Machine) (P : PureEnv → Prop) (slot : Nat) (Q : Post)
    (h : ∀ env v, P env → env slot = some v → Q.normal v env) : Triple m P (.read slot) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval]
    cases hs : env slot with
    | none => simp [Post.holds]
    | some v => simp only [Post.holds]; exact h env v hp hs

/-- Sequencing through an intermediate condition on the first part's normal end. -/
theorem triple_sequence (m : Machine) (P : PureEnv → Prop) (R : PureEnv → Prop) (a b : Expr) (Q : Post)
    (first : Triple m P a { Q with normal := fun _ env => R env })
    (second : Triple m R b Q) : Triple m P (.sequence a b) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := first fuel env hp
    revert h1
    cases eval m fuel a env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h1
      exact second fuel e1 h1
    | error x => cases x <;> simp [Post.holds]

/-- A loop ends only by `return` or an exit; an invariant that each iteration
    re-establishes on its normal end carries those endings. -/
theorem triple_loop (m : Machine) (I : PureEnv → Prop) (body : Expr) (Q : Post)
    (step : Triple m I body { Q with normal := fun _ env => I env }) :
    Triple m I (.loop body) Q := by
  intro fuel
  induction fuel with
  | zero => intro env _; simp [eval, Post.holds]
  | succ fuel ih =>
    intro env hi
    simp only [eval, bind, Except.bind]
    have h1 := step fuel env hi
    revert h1
    cases eval m fuel body env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h1
      -- The next iteration runs at the remaining fuel.
      cases fuel with
      | zero => simp [eval, Post.holds]
      | succ fuel' => exact ih e1 h1
    | error x => cases x <;> simp [Post.holds]

/-- A block turns an exit to its own label into a normal end. -/
theorem triple_block (m : Machine) (P : PureEnv → Prop) (label : Nat) (body : Expr) (Q : Post)
    (inner : Triple m P body { Q with exited := fun l v env => if l = label then Q.normal v env else Q.exited l v env }) :
    Triple m P (.block label body) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval]
    have h := inner fuel env hp
    revert h
    cases eval m fuel body env with
    | ok r => obtain ⟨v, e1⟩ := r; intro h; exact h
    | error x =>
      cases x with
      | returned v e1 => intro h; exact h
      | fault f => intro _; trivial
      | exit l v e1 =>
        intro h
        simp only [Post.holds] at h
        by_cases same : l = label
        · simp only [same, ite_true] at h ⊢; exact h
        · simp only [same, ite_false] at h ⊢; exact h

/-- `return` ends the run with the value's normal end as a returned end. -/
theorem triple_ret (m : Machine) (P : PureEnv → Prop) (value : Expr) (Q : Post)
    (inner : Triple m P value { Q with normal := Q.returned }) : Triple m P (.ret value) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := inner fuel env hp
    revert h
    cases eval m fuel value env with
    | ok r => obtain ⟨v, e1⟩ := r; intro h; exact h
    | error x => cases x <;> simp [Post.holds]

/-- A scope turns a `return` into a normal end. -/
theorem triple_scope (m : Machine) (P : PureEnv → Prop) (body : Expr) (Q : Post)
    (inner : Triple m P body { Q with returned := Q.normal }) : Triple m P (.scope body) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval]
    have h := inner fuel env hp
    revert h
    cases eval m fuel body env with
    | ok r => obtain ⟨v, e1⟩ := r; intro h; exact h
    | error x => cases x <;> intro h <;> exact h

theorem triple_exit (m : Machine) (P : PureEnv → Prop) (label : Nat) (value : Expr) (Q : Post)
    (inner : Triple m P value { Q with normal := Q.exited label }) : Triple m P (.exit label value) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := inner fuel env hp
    revert h
    cases eval m fuel value env with
    | ok r => obtain ⟨v, e1⟩ := r; intro h; exact h
    | error x => cases x <;> simp [Post.holds]

/-- A write stores the value's result in the slot. -/
theorem triple_write (m : Machine) (P : PureEnv → Prop) (slot : Nat) (value : Expr) (Q : Post)
    (inner : Triple m P value { Q with normal := fun v env => Q.normal .unit (pureSet env slot v) }) :
    Triple m P (.write slot value) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := inner fuel env hp
    revert h
    cases eval m fuel value env with
    | ok r => obtain ⟨v, e1⟩ := r; intro h; exact h
    | error x => cases x <;> simp [Post.holds]

/-- A branch on a boolean condition. -/
theorem triple_branch (m : Machine) (P : PureEnv → Prop) (c yes no : Expr) (Q : Post)
    (T F : PureEnv → Prop)
    (cond : Triple m P c { Q with normal := fun v env => (v = .boolean true → T env) ∧ (v = .boolean false → F env) })
    (onYes : Triple m T yes Q) (onNo : Triple m F no Q) : Triple m P (.branch c yes no) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := cond fuel env hp
    revert h
    cases eval m fuel c env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h
      cases v with
      | boolean b =>
        cases b
        · exact onNo fuel e1 (h.2 rfl)
        · exact onYes fuel e1 (h.1 rfl)
      | _ => simp [Post.holds]
    | error x => cases x <;> simp [Post.holds]

/-- Projecting a field of the operand's value. -/
theorem triple_field (m : Machine) (P : PureEnv → Prop) (value : Expr) (name : String) (Q : Post)
    (inner : Triple m P value
      { Q with normal := (fun v env => ∀ w, pureField v name = some w → Q.normal w env) }) :
    Triple m P (.field value name) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := inner fuel env hp
    revert h
    cases eval m fuel value env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h
      simp only []
      cases hf : pureField v name with
      | none => simp [Post.holds]
      | some w => simp only [pure, Except.pure, Post.holds]; exact h w hf
    | error x => cases x <;> simp [Post.holds]

/-- A non-short-circuit binary operation: both operands, then `binary`. -/
theorem triple_binary (m : Machine) (P : PureEnv → Prop) (op : String) (left right : Expr) (Q : Post)
    (R : PureValue → PureEnv → Prop) (strict : op ≠ "&&" ∧ op ≠ "||")
    (first : Triple m P left { Q with normal := R })
    (second : ∀ a, Triple m (R a) right
      { Q with normal := (fun b env => ∀ c f, binary m.bits m.checked f op a b = .ok c → Q.normal c env) }) :
    Triple m P (.binary op left right) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have strictOp : (op = "&&" || op = "||") = false := by simp [strict.1, strict.2]
    simp only [strictOp, Bool.false_eq_true, ite_false]
    have h := first fuel env hp
    revert h
    cases eval m fuel left env with
    | ok r =>
      obtain ⟨a, e1⟩ := r
      intro h
      have h2 := second a fuel e1 h
      cases hr : eval m fuel right e1 with
      | ok r2 =>
        obtain ⟨b, e2⟩ := r2
        rw [hr] at h2
        simp only [hr]
        cases hb : binary m.bits m.checked fuel op a b with
        | error x =>
          obtain ⟨f, rfl⟩ := binary_faults _ _ _ _ _ _ x hb
          exact trivial
        | ok c =>
          simp only [pure, Except.pure, Post.holds]
          exact h2 c fuel hb
      | error x =>
        rw [hr] at h2
        simp only [hr]
        cases x <;> simp_all [Post.holds]
    | error x => cases x <;> simp [Post.holds]

/-- Assigning the value's result at a place inside a slot. -/
theorem triple_assign (m : Machine) (P : PureEnv → Prop) (slot : Nat) (path : List Access)
    (value : Expr) (Q : Post)
    (inner : Triple m P value { Q with normal := (fun v env => ∀ current updated,
      env slot = some current → update env path current v = .ok updated →
        Q.normal .unit (pureSet env slot updated)) }) :
    Triple m P (.assign slot path value) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := inner fuel env hp
    cases hv : eval m fuel value env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      rw [hv] at h
      simp only []
      cases hs : e1 slot with
      | none => exact trivial
      | some current =>
        simp only []
        cases hu : update e1 path current v with
        | error x =>
          obtain ⟨f, rfl⟩ := update_faults _ _ _ _ x hu
          exact trivial
        | ok updated =>
          simp only [pure, Except.pure, Post.holds]
          exact h current updated hs hu
    | error x =>
      rw [hv] at h
      cases x <;> simp_all [Post.holds]

theorem select_mem (fuel : Nat) (arms : List (Pattern × Expr)) (value : PureValue) (env : PureEnv)
    (body : Expr) (env' : PureEnv) (h : select fuel arms value env = .ok (some (body, env'))) :
    body ∈ arms.map (·.2) := by
  unfold select at h
  suffices ∀ (start : Option (Expr × PureEnv)), (start = none ∨ ∃ e, start = some e ∧ e.1 ∈ arms.map (·.2)) →
      ∀ (rest : List (Pattern × Expr)), (∀ a ∈ rest, a ∈ arms) →
      rest.foldlM (fun (found : Option (Expr × PureEnv)) (arm : Pattern × Expr) => match found with
        | some hit => (.ok (some hit) : Except PureFault (Option (Expr × PureEnv)))
        | none => match matchPattern fuel arm.1 value env with
          | .ok (some env) => .ok (some (arm.2, env))
          | .ok none => .ok none
          | .error reason => .error reason) start = .ok (some (body, env')) →
      body ∈ arms.map (·.2) from this none (Or.inl rfl) arms (fun _ m => m) h
  intro start hs rest sub
  induction rest generalizing start with
  | nil =>
    intro h
    simp [List.foldlM, pure, Except.pure] at h
    rcases hs with rfl | ⟨e, rfl, m⟩
    · simp at h
    · simp at h; obtain ⟨rfl, rfl⟩ := h; exact m
  | cons a rest ih =>
    intro h
    simp only [List.foldlM, bind, Except.bind] at h
    rcases hs with rfl | ⟨e, rfl, m⟩
    · simp only at h
      cases hm : matchPattern fuel a.1 value env with
      | error r => simp [hm] at h
      | ok r =>
        cases r with
        | none => simp only [hm] at h; exact ih none (Or.inl rfl) (fun x mx => sub x (by simp [mx])) h
        | some mid =>
          simp only [hm] at h
          exact ih (some (a.2, mid)) (Or.inr ⟨_, rfl, by simpa using ⟨a.1, sub a (by simp)⟩⟩)
            (fun x mx => sub x (by simp [mx])) h
    · simp only at h
      exact ih (some e) (Or.inr ⟨e, rfl, m⟩) (fun x mx => sub x (by simp [mx])) h

/-- A `match`: the value's normal end establishes, for whichever arm is
    selected, that arm's precondition `B body` in the bound environment. -/
theorem triple_choose (m : Machine) (P : PureEnv → Prop) (value : Expr) (arms : List (Pattern × Expr))
    (Q : Post) (B : Expr → PureEnv → Prop)
    (scrutinee : Triple m P value { Q with normal := (fun v env => ∀ f body env',
      select f arms v env = .ok (some (body, env')) → B body env') })
    (each : ∀ body ∈ arms.map (·.2), Triple m (B body) body Q) :
    Triple m P (.choose value arms) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := scrutinee fuel env hp
    cases hv : eval m fuel value env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      rw [hv] at h
      simp only []
      cases hs : select fuel arms v e1 with
      | ok r =>
        cases r with
        | none => exact trivial
        | some hit =>
          obtain ⟨body, e2⟩ := hit
          exact each body (select_mem fuel arms v e1 body e2 hs) fuel e2 (h fuel body e2 hs)
      | error x => cases x <;> exact trivial
    | error x =>
      rw [hv] at h
      cases x <;> simp_all [Post.holds]

end Provium.Imperative
