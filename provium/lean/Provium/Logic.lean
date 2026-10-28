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

/-- The frame `invoke` builds: the receiver in slot 0 and the arguments after it. -/
def frameOf (self : PureValue) (values : List PureValue) : PureEnv :=
  (values.zipIdx 1).foldl (fun frame (value, slot) => pureSet frame slot value)
    (pureSet (fun _ => none) 0 self)

/-- A specification of a function of the table: from a receiver and arguments
    satisfying `pre`, a normal or returned end yields a value and a final
    receiver satisfying `post`. -/
structure Spec where
  pre : PureValue → List PureValue → Prop
  post : PureValue → List PureValue → PureValue → PureValue → Prop

def Satisfies (m : Machine) (name : String) (spec : Spec) : Prop :=
  ∃ body, m.functions name = some body ∧ ∀ self values, spec.pre self values →
    Triple m (fun env => env = frameOf self values) body
      { normal := fun v env => ∃ r, env 0 = some r ∧ spec.post self values v r
        returned := fun v env => ∃ r, env 0 = some r ∧ spec.post self values v r
        exited := fun _ _ _ => True }

/-- Evaluating an argument list left to right: `A acc values env` holds after
    each prefix, starting from `A [] env₀`. -/
def ArgsTriple (m : Machine) (args : List Expr) (A : List PureValue → PureEnv → Prop) (Q : Post) : Prop :=
  ∀ fuel (values : List PureValue) env, A values env →
    ∀ arg ∈ args, Q.holds (eval m fuel arg env) ∧
      ∀ v env', eval m fuel arg env = .ok (v, env') → A (values ++ [v]) env'

/-- The argument fold ends with `A` on its values, or with an ending `Q` accepts. -/
def ArgsEnd (A : List PureValue → PureEnv → Prop) (Q : Post) :
    Except Exit (List PureValue × PureEnv) → Prop
  | .ok (values, env) => A values env
  | .error x => Q.holds (.error x)

theorem args_fold (m : Machine) (fuel : Nat) (A : List PureValue → PureEnv → Prop) (Q : Post) :
    ∀ (args : List Expr) (values : List PureValue) (env : PureEnv),
      (∀ (vs : List PureValue) e, A vs e → ∀ arg ∈ args, Q.holds (eval m fuel arg e) ∧
        ∀ v e', eval m fuel arg e = .ok (v, e') → A (vs ++ [v]) e') →
      A values env →
      ArgsEnd A Q (args.foldlM (fun (values, env) argument => do
          let (value, env) ← eval m fuel argument env
          return (values ++ [value], env)) (values, env))
  | [], values, env, _, a => by simpa [List.foldlM, pure, Except.pure, ArgsEnd] using a
  | arg :: rest, values, env, step, a => by
    have ⟨here, next⟩ := step values env a arg (by simp)
    simp only [List.foldlM, bind, Except.bind]
    cases hv : eval m fuel arg env with
    | ok r =>
      obtain ⟨v, e1⟩ := r
      simp only [pure, Except.pure]
      exact args_fold m fuel A Q rest (values ++ [v]) e1
        (fun vs e h arg' m' => step vs e h arg' (by simp [m'])) (next v e1 hv)
    | error x =>
      rw [hv] at here
      simpa [ArgsEnd] using here

/-- A call through the function table: the receiver, then the arguments, then
    the callee's specification, then the write-back to the caller's place. -/
theorem triple_invoke (m : Machine) (P : PureEnv → Prop) (name : String) (receiver : Expr)
    (writeBack : Option (Nat × List Access)) (args : List Expr) (Q : Post) (spec : Spec)
    (sat : Satisfies m name spec) (R : PureValue → PureEnv → Prop)
    (recv : Triple m P receiver { Q with normal := R })
    (A : PureValue → List PureValue → PureEnv → Prop)
    (start : ∀ self env, R self env → A self [] env)
    (argsOk : ∀ self fuel values env, A self values env → ∀ arg ∈ args,
      Q.holds (eval m fuel arg env) ∧ ∀ v env', eval m fuel arg env = .ok (v, env') →
        A self (values ++ [v]) env')
    (call : ∀ self values env, A self values env → spec.pre self values ∧
      ∀ v r, spec.post self values v r → match writeBack with
        | none => Q.normal v env
        | some (slot, path) => ∀ current replaced, env slot = some current →
            update env path current r = .ok replaced → Q.normal v (pureSet env slot replaced)) :
    Triple m P (.invoke name receiver writeBack args) Q := by
  obtain ⟨body, hbody, bodyOk⟩ := sat
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h := recv fuel env hp
    cases hr : eval m fuel receiver env with
    | error x => rw [hr] at h; cases x <;> simp_all [Post.holds]
    | ok r =>
      obtain ⟨self, e1⟩ := r
      rw [hr] at h
      simp only []
      have folded := args_fold m fuel (A self) Q args [] e1
        (fun vs e a arg ma => argsOk self fuel vs e a arg ma) (start self e1 h)
      simp only [bind, Except.bind] at folded
      split
      · rename_i x hf
        rw [hf] at folded
        simpa [ArgsEnd] using folded
      · rename_i res hf
        obtain ⟨values, e2⟩ := res
        rw [hf] at folded
        simp only [ArgsEnd] at folded
        obtain ⟨pre, after⟩ := call self values e2 folded
        simp only [hbody]
        have hb := bodyOk self values pre fuel (frameOf self values) rfl
        unfold frameOf at hb
        cases he : eval m fuel body ((values.zipIdx 1).foldl
            (fun frame (value, slot) => pureSet frame slot value) (pureSet (fun _ => none) 0 self)) with
        | ok res =>
          obtain ⟨v, final⟩ := res
          rw [he] at hb
          obtain ⟨r, hr0, post⟩ := hb
          have done := after v r post
          cases writeBack with
          | none => exact done
          | some w =>
            obtain ⟨slot, path⟩ := w
            simp only [hr0]
            cases hc : e2 slot with
            | none => exact trivial
            | some current =>
              simp only []
              cases hu : update e2 path current r with
              | error x => obtain ⟨f, rfl⟩ := update_faults _ _ _ _ x hu; exact trivial
              | ok replaced => exact done current replaced hc hu
        | error x =>
          rw [he] at hb
          cases x with
          | fault f => exact trivial
          | exit l v fin => exact trivial
          | returned v final =>
            obtain ⟨r, hr0, post⟩ := hb
            have done := after v r post
            cases writeBack with
            | none => exact done
            | some w =>
              obtain ⟨slot, path⟩ := w
              simp only [hr0]
              cases hc : e2 slot with
              | none => exact trivial
              | some current =>
                simp only []
                cases hu : update e2 path current r with
                | error x => obtain ⟨f, rfl⟩ := update_faults _ _ _ _ x hu; exact trivial
                | ok replaced => exact done current replaced hc hu

/-- A counted loop `for i in start..stop` over a fresh slot: an invariant
    `I i env` from the first index, re-established by each iteration's body. -/
theorem triple_range (m : Machine) (P : PureEnv → Prop) (slot : Nat) (start stop body : Expr)
    (Q : Post) (S : PureValue → PureEnv → Prop) (E : PureValue → PureValue → PureEnv → Prop)
    (I : Nat → PureEnv → Prop)
    (first : Triple m P start { Q with normal := S })
    (second : ∀ a, Triple m (S a) stop { Q with normal := E a })
    (enter : ∀ kind lo hi env, E (.number kind lo) (.number kind hi) env → I lo env)
    (iteration : ∀ kind i, Triple m (fun env => ∃ e, I i e ∧ env = pureSet e slot (.number kind i)) body
      { Q with normal := fun _ env => I (i + 1) env })
    (done : ∀ n env v, I n env → Q.normal v env) :
    Triple m P (.range slot start stop body) Q := by
  intro fuel env hp
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := first fuel env hp
    cases ha : eval m fuel start env with
    | error x => rw [ha] at h1; cases x <;> simp_all [Post.holds]
    | ok r =>
      obtain ⟨a, e1⟩ := r
      rw [ha] at h1
      simp only []
      have h2 := second a fuel e1 h1
      cases a with
      | number kind lo =>
        simp only []
        cases hb : eval m fuel stop e1 with
        | error x => rw [hb] at h2; cases x <;> simp_all [Post.holds]
        | ok r =>
          obtain ⟨b, e2⟩ := r
          rw [hb] at h2
          simp only []
          cases b with
          | number other hi =>
            simp only []
            split
            · exact trivial
            · rename_i same
              have same : kind = other := by simpa using same
              subst same
              have start' := enter kind lo hi e2 h2
              -- Iterate over the indices lo, lo+1, ..., hi-1.
              suffices ∀ (count n : Nat) (e : PureEnv) (u : PureValue), I n e →
                  Q.holds ((List.range' n count).foldlM (fun (_, env) i =>
                    eval m fuel body (pureSet env slot (.number kind i))) (u, e)) by
                exact this (hi - lo) lo e2 .unit start'
              intro count
              induction count with
              | zero =>
                intro n e u hi'
                simp only [List.range', List.foldlM, pure, Except.pure, Post.holds]
                exact done n e u hi'
              | succ count ih =>
                intro n e u hi'
                simp only [List.range'_succ, List.foldlM, bind, Except.bind]
                have hb' := iteration kind n fuel (pureSet e slot (.number kind n)) ⟨e, hi', rfl⟩
                cases hbody : eval m fuel body (pureSet e slot (.number kind n)) with
                | error x => rw [hbody] at hb'; cases x <;> simp_all [Post.holds]
                | ok r =>
                  obtain ⟨w, e3⟩ := r
                  rw [hbody] at hb'
                  exact ih (n + 1) e3 w hb'
          | _ => exact trivial
      | _ => exact trivial

end Provium.Imperative
