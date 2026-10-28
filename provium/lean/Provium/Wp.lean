import Provium.Logic
/- Weakest preconditions for the imperative machine. `Wp m e Q env` says that
   every ending of `e` run from `env`, at every fuel, satisfies `Q`; each rule
   below reduces it for one construct to conditions on the construct's parts,
   so a generated body is verified by applying the rules in syntax order
   (symbolic execution), with an invariant at each loop and a specification at
   each call. Faults are unconstrained, as in `Triple`. -/
namespace Provium.Imperative
open Provium.State

def Wp (m : Machine) (e : Expr) (Q : Post) (env : PureEnv) : Prop :=
  ∀ fuel, Q.holds (eval m fuel e env)

theorem Wp.triple {m : Machine} {P : PureEnv → Prop} {e : Expr} {Q : Post}
    (h : ∀ env, P env → Wp m e Q env) : Triple m P e Q :=
  fun fuel env hp => h env hp fuel

theorem Triple.wp {m : Machine} {P : PureEnv → Prop} {e : Expr} {Q : Post} {env : PureEnv}
    (t : Triple m P e Q) (hp : P env) : Wp m e Q env :=
  fun fuel => t fuel env hp

theorem triple_wp (m : Machine) (e : Expr) (Q : Post) : Triple m (Wp m e Q) e Q :=
  fun fuel _ h => h fuel

/-- The condition at `env` alone, as a precondition. -/
private theorem at_env {m : Machine} {e : Expr} {Q : Post} {env : PureEnv}
    (t : Triple m (· = env) e Q) : Wp m e Q env := t.wp rfl

theorem wp_consequence {m : Machine} {e : Expr} {Q Q' : Post} {env : PureEnv} (h : Wp m e Q env)
    (normal : ∀ v env, Q.normal v env → Q'.normal v env)
    (returned : ∀ v env, Q.returned v env → Q'.returned v env)
    (exited : ∀ l v env, Q.exited l v env → Q'.exited l v env) : Wp m e Q' env :=
  at_env (triple_consequence (P := (· = env)) (fun fuel e he => by subst he; exact h fuel)
    (fun _ h => h) normal returned exited)

theorem wp_literal {m : Machine} {v : PureValue} {Q : Post} {env : PureEnv}
    (h : Q.normal v env) : Wp m (.literal v) Q env :=
  at_env (triple_literal m _ v Q (fun e he => by subst he; exact h))

theorem wp_read {m : Machine} {slot : Nat} {Q : Post} {env : PureEnv}
    (h : ∀ v, env slot = some v → Q.normal v env) : Wp m (.read slot) Q env :=
  at_env (triple_read m _ slot Q (fun e v he hs => by subst he; exact h v hs))

theorem wp_sequence {m : Machine} {a b : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m a { Q with normal := (fun _ e => Wp m b Q e)} env) : Wp m (.sequence a b) Q env :=
  at_env (triple_sequence m _ (Wp m b Q) a b Q (fun fuel e he => by subst he; exact h fuel)
    (triple_wp m b Q))

theorem wp_write {m : Machine} {slot : Nat} {value : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := (fun v e => Q.normal .unit (pureSet e slot v))} env) :
    Wp m (.write slot value) Q env :=
  at_env (triple_write m _ slot value Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_assign {m : Machine} {slot : Nat} {path : List Access} {value : Expr} {Q : Post}
    {env : PureEnv}
    (h : Wp m value { Q with normal := (fun v e => ∀ current updated,
      e slot = some current → update e path current v = .ok updated →
        Q.normal .unit (pureSet e slot updated))} env) :
    Wp m (.assign slot path value) Q env :=
  at_env (triple_assign m _ slot path value Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_field {m : Machine} {value : Expr} {name : String} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := (fun v e => ∀ w, pureField v name = some w → Q.normal w e)} env) :
    Wp m (.field value name) Q env :=
  at_env (triple_field m _ value name Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_ret {m : Machine} {value : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := Q.returned } env) : Wp m (.ret value) Q env :=
  at_env (triple_ret m _ value Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_scope {m : Machine} {body : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m body { Q with returned := Q.normal } env) : Wp m (.scope body) Q env :=
  at_env (triple_scope m _ body Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_exit {m : Machine} {label : Nat} {value : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := Q.exited label } env) : Wp m (.exit label value) Q env :=
  at_env (triple_exit m _ label value Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_block {m : Machine} {label : Nat} {body : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m body { Q with exited := fun l v e => if l = label then Q.normal v e else Q.exited l v e } env) :
    Wp m (.block label body) Q env :=
  at_env (triple_block m _ label body Q (fun fuel e he => by subst he; exact h fuel))

theorem wp_branch {m : Machine} {c yes no : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m c { Q with normal := (fun v e => ∀ b, v = .boolean b → Wp m (if b then yes else no) Q e)} env) :
    Wp m (.branch c yes no) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel c env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h1
      cases v with
      | boolean b => exact h1 b rfl fuel
      | _ => exact trivial

theorem wp_choose {m : Machine} {value : Expr} {arms : List (Pattern × Expr)} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := (fun v e => ∀ f body e',
      select f arms v e = .ok (some (body, e')) → Wp m body Q e')} env) :
    Wp m (.choose value arms) Q env :=
  at_env (triple_choose m _ value arms Q (fun body e' => Wp m body Q e')
    (fun fuel e he => by subst he; exact h fuel) (fun body _ => triple_wp m body Q))

theorem foldlM_ok_mono {α β ε : Type} {F G : β → α → Except ε β}
    (h : ∀ b a r, F b a = .ok r → G b a = .ok r) :
    ∀ (xs : List α) (b r : β), xs.foldlM F b = .ok r → xs.foldlM G b = .ok r
  | [], b, r, hf => by simpa [List.foldlM] using hf
  | x :: xs, b, r, hf => by
    simp only [List.foldlM, bind, Except.bind] at hf ⊢
    cases hx : F b x with
    | error e => rw [hx] at hf; cases hf
    | ok c =>
      rw [hx] at hf
      rw [h b x c hx]
      exact foldlM_ok_mono h xs c r hf

/-- A successful match at some fuel succeeds identically with more fuel. -/
theorem matchPattern_succ : ∀ (f : Nat) (p : Pattern) (v : PureValue) (e : PureEnv) (r : Option PureEnv),
    matchPattern f p v e = .ok r → matchPattern (f + 1) p v e = .ok r
  | 0, _, _, _, _, h => by simp [matchPattern] at h
  | f + 1, p, v, e, r, h => by
    have ih := matchPattern_succ f
    cases p with
    | any => simpa [matchPattern] using h
    | bind slot => simpa [matchPattern] using h
    | absent => simpa [matchPattern] using h
    | present q =>
      unfold matchPattern at h ⊢
      cases v <;> simp only [] at h ⊢ <;> first | exact h | exact ih _ _ _ _ h
    | variant owner tag ps =>
      unfold matchPattern at h ⊢
      cases v with
      | variant actual variant fields =>
        simp only [] at h ⊢
        split at h
        · rename_i c1; rw [if_pos c1]; exact h
        · rename_i c1
          rw [if_neg c1]
          split at h
          · cases h
          · rename_i c2
            rw [if_neg c2]
            refine foldlM_ok_mono (fun found pair r' hstep => ?_) ps (some e) r h
            cases found with
            | none => exact hstep
            | some env =>
              cases hfind : List.find? (fun field => field.1 == pair.1) fields with
              | none => simp only [hfind] at hstep; cases hstep
              | some field => simp only [hfind] at hstep ⊢; exact ih _ _ _ _ hstep
      | _ => exact h
    | record owner ps =>
      unfold matchPattern at h ⊢
      cases v with
      | record actual fields =>
        simp only [] at h ⊢
        split at h
        · rename_i c1; rw [if_pos c1]; exact h
        · rename_i c1
          rw [if_neg c1]
          split at h
          · cases h
          · rename_i c2
            rw [if_neg c2]
            refine foldlM_ok_mono (fun found pair r' hstep => ?_) ps (some e) r h
            cases found with
            | none => exact hstep
            | some env =>
              cases hfind : List.find? (fun field => field.1 == pair.1) fields with
              | none => simp only [hfind] at hstep; cases hstep
              | some field => simp only [hfind] at hstep ⊢; exact ih _ _ _ _ hstep
      | _ => exact h
    | alternatives ps =>
      unfold matchPattern at h ⊢
      refine foldlM_ok_mono (fun found q r' hstep => ?_) ps none r h
      cases found with
      | some env => exact hstep
      | none => exact ih _ _ _ _ hstep

theorem select_succ (f : Nat) (arms : List (Pattern × Expr)) (v : PureValue) (e : PureEnv)
    (r : Option (Expr × PureEnv)) (h : select f arms v e = .ok r) : select (f + 1) arms v e = .ok r := by
  unfold select at h ⊢
  refine foldlM_ok_mono (fun found arm r' hstep => ?_) arms none r h
  cases found with
  | some hit => exact hstep
  | none =>
    simp only [] at hstep ⊢
    cases hm : matchPattern f arm.1 v e with
    | error x => rw [hm] at hstep; cases hstep
    | ok m =>
      rw [hm] at hstep
      rw [matchPattern_succ f arm.1 v e m hm]
      exact hstep

theorem select_add (f d : Nat) (arms : List (Pattern × Expr)) (v : PureValue) (e : PureEnv)
    (r : Option (Expr × PureEnv)) (h : select f arms v e = .ok r) : select (f + d) arms v e = .ok r := by
  induction d with
  | zero => exact h
  | succ d ih => exact select_succ _ arms v e r ih

/-- A strict binary operation: both operands, then `binary` at any fuel. -/
theorem wp_binary {m : Machine} {op : String} {left right : Expr} {Q : Post} {env : PureEnv}
    (strict : op ≠ "&&" ∧ op ≠ "||")
    (h : Wp m left { Q with normal := (fun a e => Wp m right { Q with normal := (fun b e' =>
      ∀ c f, binary m.bits m.checked f op a b = .ok c → Q.normal c e') } e)} env) :
    Wp m (.binary op left right) Q env :=
  at_env (triple_binary m _ op left right Q (fun a e => Wp m right { Q with normal := (fun b e' =>
      ∀ c f, binary m.bits m.checked f op a b = .ok c → Q.normal c e')} e) strict
    (fun fuel e he => by subst he; exact h fuel) (fun a => triple_wp m right _))

/-- `&&` evaluates its right operand only after a `true` left operand. -/
theorem wp_and {m : Machine} {left right : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m left { Q with normal := (fun a e => ∀ b, a = .boolean b →
      if b then Wp m right { Q with normal := fun v e' => ∀ c, v = .boolean c → Q.normal (.boolean c) e' } e
      else Q.normal (.boolean false) e)} env) :
    Wp m (.binary "&&" left right) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel left env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨a, e1⟩ := r
      intro h1
      simp only [Post.holds] at h1
      cases a with
      | boolean b =>
        have h2 := h1 b rfl
        cases b with
        | false => simpa [pure, Except.pure, Post.holds] using h2
        | true =>
          simp only [ite_true] at h2
          have h3 := h2 fuel
          simp only [decide_true, Bool.not_true, Bool.and_false]
          revert h3
          cases eval m fuel right e1 with
          | error x => cases x <;> simp [Post.holds]
          | ok r =>
            obtain ⟨v, e2⟩ := r
            intro h3
            cases v <;> simp_all [pure, Except.pure, Post.holds]
      | _ => simp [Post.holds]

/-- `||` evaluates its right operand only after a `false` left operand. -/
theorem wp_or {m : Machine} {left right : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m left { Q with normal := (fun a e => ∀ b, a = .boolean b →
      if b then Q.normal (.boolean true) e
      else Wp m right { Q with normal := fun v e' => ∀ c, v = .boolean c → Q.normal (.boolean c) e' } e)} env) :
    Wp m (.binary "||" left right) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel left env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨a, e1⟩ := r
      intro h1
      simp only [Post.holds] at h1
      cases a with
      | boolean b =>
        have h2 := h1 b rfl
        cases b with
        | true => simpa [pure, Except.pure, Post.holds] using h2
        | false =>
          simp only [Bool.false_eq_true, ite_false] at h2
          have h3 := h2 fuel
          simp only [decide_true, Bool.not_false, Bool.and_true, Bool.and_false, Bool.or_false]
          revert h3
          cases eval m fuel right e1 with
          | error x => cases x <;> simp [Post.holds]
          | ok r =>
            obtain ⟨v, e2⟩ := r
            intro h3
            cases v <;> simp_all [pure, Except.pure, Post.holds]
      | _ => simp [Post.holds]

theorem wp_negate {m : Machine} {value : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := (fun v e => ∀ b, v = .boolean b → Q.normal (.boolean !b) e)} env) :
    Wp m (.negate value) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel value env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h1
      cases v <;> simp_all [pure, Except.pure, Post.holds]

theorem wp_present {m : Machine} {value : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m value { Q with normal := (fun v e => Q.normal (.present v) e)} env) :
    Wp m (.present value) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel value env with
    | error x => cases x <;> simp [Post.holds]
    | ok r => obtain ⟨v, e1⟩ := r; intro h1; exact h1

theorem wp_length {m : Machine} {array : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m array { Q with normal := (fun a e => ∀ vs, a = .array vs →
      Q.normal (.number "usize" vs.length) e)} env) :
    Wp m (.length array) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel array env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨a, e1⟩ := r
      intro h1
      cases a <;> simp_all [pure, Except.pure, Post.holds]

theorem wp_index {m : Machine} {array position : Expr} {Q : Post} {env : PureEnv}
    (h : Wp m array { Q with normal := (fun a e => Wp m position { Q with normal := (fun p e' =>
      ∀ vs x, a = .array vs → indexValue vs p = .ok x → Q.normal x e') } e)} env) :
    Wp m (.index array position) Q env := by
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel array env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨a, e1⟩ := r
      intro h1
      have h2 := h1 fuel
      cases hp : eval m fuel position e1 with
      | error x => rw [hp] at h2; simp only [hp]; cases x <;> simp_all [Post.holds]
      | ok r =>
        obtain ⟨p, e2⟩ := r
        rw [hp] at h2
        simp only [hp]
        cases a with
        | array vs =>
          simp only []
          cases hx : indexValue vs p with
          | error f =>
            have : ∃ g, f = .fault g := by
              unfold indexValue at hx; split at hx <;> (try split at hx) <;> (cases hx; try exact ⟨_, rfl⟩)
            obtain ⟨g, rfl⟩ := this
            exact trivial
          | ok x => exact h2 vs x rfl hx
        | _ => exact trivial

/-- A loop with an invariant that each iteration's normal end re-establishes. -/
theorem wp_loop {m : Machine} {body : Expr} {Q : Post} {env : PureEnv} (I : PureEnv → Prop)
    (start : I env) (step : ∀ e, I e → Wp m body { Q with normal := (fun _ e' => I e')} e) :
    Wp m (.loop body) Q env :=
  (triple_loop m I body Q (Wp.triple step)).wp start

/-- A program chosen by a condition: one case per outcome. -/
theorem wp_ite {m : Machine} {c : Prop} [Decidable c] {a b : Expr} {Q : Post} {env : PureEnv}
    (yes : c → Wp m a Q env) (no : ¬c → Wp m b Q env) : Wp m (if c then a else b) Q env := by
  by_cases h : c
  · rw [if_pos h]; exact yes h
  · rw [if_neg h]; exact no h

/-- A panic is a fault, which a weakest precondition never constrains. -/
theorem wp_panic {m : Machine} {reason : String} {Q : Post} {env : PureEnv} :
    Wp m (.panic reason) Q env := by
  intro fuel
  cases fuel <;> simp [eval, Post.holds]

/-- An argument list, left to right, then `K` on the values. -/
def WpArgs (m : Machine) (Q : Post) (K : List PureValue → PureEnv → Prop) :
    List Expr → List PureValue → PureEnv → Prop
  | [], values, env => K values env
  | arg :: rest, values, env =>
    Wp m arg { Q with normal := (fun v e => WpArgs m Q K rest (values ++ [v]) e)} env

theorem wpArgs_fold (m : Machine) (fuel : Nat) (Q : Post) (K : List PureValue → PureEnv → Prop) :
    ∀ (args : List Expr) (values : List PureValue) (env : PureEnv), WpArgs m Q K args values env →
      ArgsEnd K Q (args.foldlM (fun (values, env) argument => do
          let (value, env) ← eval m fuel argument env
          return (values ++ [value], env)) (values, env))
  | [], values, env, h => by simpa [List.foldlM, pure, Except.pure, ArgsEnd, WpArgs] using h
  | arg :: rest, values, env, h => by
    simp only [WpArgs] at h
    have h1 := h fuel
    simp only [List.foldlM, bind, Except.bind]
    revert h1
    cases eval m fuel arg env with
    | error x => cases x <;> simp [Post.holds, ArgsEnd]
    | ok r =>
      obtain ⟨v, e1⟩ := r
      intro h1
      exact wpArgs_fold m fuel Q K rest (values ++ [v]) e1 h1

/-- What a call's continuation needs once the callee's specification gives a
    value `v` and final receiver `r`. -/
def WriteBack (Q : Post) (writeBack : Option (Nat × List Access)) (v r : PureValue) (env : PureEnv) : Prop :=
  match writeBack with
  | none => Q.normal v env
  | some (slot, path) => ∀ current replaced, env slot = some current →
      update env path current r = .ok replaced → Q.normal v (pureSet env slot replaced)

/-- A call through the function table under the callee's specification. -/
theorem wp_invoke {m : Machine} {name : String} {receiver : Expr} {writeBack : Option (Nat × List Access)}
    {args : List Expr} {Q : Post} {env : PureEnv} (spec : Spec) (sat : Satisfies m name spec)
    (h : Wp m receiver { Q with normal := (fun self e => WpArgs m Q (fun values e' =>
      spec.pre self values ∧ ∀ v r, spec.post self values v r → WriteBack Q writeBack v r e') args [] e)} env) :
    Wp m (.invoke name receiver writeBack args) Q env := by
  obtain ⟨body, hbody, bodyOk⟩ := sat
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel receiver env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨self, e1⟩ := r
      intro h1
      simp only []
      have folded := wpArgs_fold m fuel Q _ args [] e1 h1
      simp only [bind, Except.bind] at folded
      split
      · rename_i x hf
        rw [hf] at folded
        simpa [ArgsEnd] using folded
      · rename_i res hf
        obtain ⟨values, e2⟩ := res
        rw [hf] at folded
        simp only [ArgsEnd] at folded
        obtain ⟨pre, after⟩ := folded
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

theorem arithmetic_eq (bits : Nat) (checked : Bool) (kind : String) (a b : Nat) :
    arithmetic bits checked "==" kind a b =
      (if width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind then .error (.fault .representation)
       else .ok (.boolean (a == b))) := by
  by_cases h : (width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind)
  · unfold arithmetic; dsimp only; rw [if_pos h, if_pos h]
  · unfold arithmetic; dsimp only; rw [if_neg h, if_neg h]; rfl

theorem arithmetic_add (bits : Nat) (checked : Bool) (kind : String) (a b : Nat) :
    arithmetic bits checked "+" kind a b =
      (if width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind then .error (.fault .representation)
       else if checked then word bits kind (a + b) else .ok (.number kind ((a + b) % bound bits kind))) := by
  by_cases h : (width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind)
  · unfold arithmetic; dsimp only; rw [if_pos h, if_pos h]
  · unfold arithmetic; dsimp only; rw [if_neg h, if_neg h]; rfl

theorem binary_numbers (bits : Nat) (checked : Bool) (f : Nat) (op kind : String) (a b : Nat) :
    binary bits checked f op (.number kind a) (.number kind b) = arithmetic bits checked op kind a b := by
  unfold binary; simp only [ne_eq, not_true_eq_false, ite_false]

/-- A successful `==` on two numbers of one kind compares them, and both
    were words of that kind. -/
theorem binary_eq_numbers {bits : Nat} {checked : Bool} {f : Nat} {kind : String} {a b : Nat}
    {c : PureValue} (h : binary bits checked f "==" (.number kind a) (.number kind b) = .ok c) :
    c = .boolean (a == b) ∧ a < bound bits kind ∧ b < bound bits kind := by
  rw [binary_numbers, arithmetic_eq] at h
  by_cases g : (width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind)
  · rw [if_pos g] at h; cases h
  · rw [if_neg g] at h
    cases h
    exact ⟨rfl, by omega, by omega⟩

/-- A successful `+` on two numbers whose sum fits the kind is the sum. -/
theorem binary_add_numbers {bits : Nat} {checked : Bool} {f : Nat} {kind : String} {a b : Nat}
    {c : PureValue} (h : binary bits checked f "+" (.number kind a) (.number kind b) = .ok c)
    (fits : a + b < bound bits kind) : c = .number kind (a + b) := by
  rw [binary_numbers, arithmetic_add] at h
  by_cases g : (width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind)
  · rw [if_pos g] at h; cases h
  · rw [if_neg g] at h
    cases checked
    · simp only [Bool.false_eq_true, ite_false] at h; cases h; rw [Nat.mod_eq_of_lt fits]
    · simp only [ite_true, word, fits] at h; cases h; rfl

theorem ite_error_ok {p : Prop} [Decidable p] {x : Exit} {y c : PureValue} :
    ((if p then Except.error x else Except.ok y) = (Except.ok c : Except Exit PureValue)) ↔ (¬p ∧ y = c) := by
  by_cases h : p <;> simp [h]

/-- `+` whose sum fits the kind. -/
theorem binary_add_fits {bits : Nat} {checked : Bool} {f : Nat} {kind : String} {a b : Nat}
    (fits : a + b < bound bits kind) (wide : width bits kind ≠ 0) :
    binary bits checked f "+" (.number kind a) (.number kind b) = .ok (.number kind (a + b)) := by
  rw [binary_numbers, arithmetic_add]
  have g : ¬(width bits kind = 0 ∨ a ≥ bound bits kind ∨ b ≥ bound bits kind) := by omega
  rw [if_neg g]
  cases checked
  · simp only [Bool.false_eq_true, ite_false, Nat.mod_eq_of_lt fits]
  · simp only [ite_true, word, fits]

/-- The loop the frontend generates for a counted traversal: a cursor slot
    compared with a fixed stop slot at the head of each iteration, exiting to
    `exit` when they are equal. `Inv k` holds at the head with the cursor at
    `k`, at most `hi`; the rest of each iteration re-establishes it for some
    next cursor or ends otherwise. The cursor never passes `hi`, so its
    increment cannot wrap. -/
theorem wp_counted {m : Machine} {exit cursor stop : Nat} {rest : Expr} {Q : Post} {env : PureEnv}
    (kind : String) (hi : Nat) (Inv : Nat → PureEnv → Prop)
    (frame : ∀ k e, Inv k e → e cursor = some (.number kind k) ∧ e stop = some (.number kind hi) ∧ k ≤ hi)
    (k0 : Nat) (start : Inv k0 env)
    (step : ∀ k e, Inv k e → k < hi → hi < bound m.bits kind →
      Wp m rest { Q with normal := (fun _ e' => ∃ k', Inv k' e') } e)
    (done : ∀ e, Inv hi e → Q.exited exit .unit e) :
    Wp m (.loop (.sequence (.branch (.binary "==" (.read cursor) (.read stop))
      (.exit exit (.literal .unit)) (.literal .unit)) rest)) Q env := by
  apply wp_loop (fun e => ∃ k, Inv k e) ⟨k0, start⟩
  intro e ⟨k, hk⟩
  obtain ⟨hc, hs, le⟩ := frame k e hk
  apply wp_sequence
  apply wp_branch
  apply wp_binary (by decide)
  apply wp_read
  intro a ha
  rw [hc] at ha
  cases ha
  apply wp_read
  intro b hb
  rw [hs] at hb
  cases hb
  intro c f hb
  obtain ⟨rfl, _, bounded⟩ := binary_eq_numbers hb
  intro b hb'
  cases hb'
  by_cases same : k = hi
  · subst same
    simp only [beq_self_eq_true, ite_true]
    apply wp_exit
    apply wp_literal
    exact done e hk
  · have ne : (k == hi) = false := by simpa using same
    simp only [ne, Bool.false_eq_true, ite_false]
    apply wp_literal
    exact step k e hk (by omega) bounded

/-- A counted loop whose iterations write only the slots in `W` (the cursor
    among them): every other slot keeps its value from `e0`, the environment
    at the loop's head, so facts about them need no restating. `P` carries the
    accumulated facts at each cursor position. -/
theorem wp_scan {m : Machine} {exit cursor stop : Nat} {rest : Expr} {Q : Post} {env : PureEnv}
    (kind : String) (hi : Nat) (W : List Nat) (e0 : PureEnv) (P : Nat → PureEnv → Prop)
    (stopKept : stop ∉ W) (stopValue : e0 stop = some (.number kind hi))
    (k0 : Nat) (startCursor : env cursor = some (.number kind k0)) (startLe : k0 ≤ hi)
    (startKept : ∀ s, s ∉ W → env s = e0 s) (start : P k0 env)
    (step : ∀ k e, e cursor = some (.number kind k) → k < hi → hi < bound m.bits kind →
      (∀ s, s ∉ W → e s = e0 s) → P k e →
      Wp m rest { Q with normal := (fun _ e' => ∃ k', e' cursor = some (.number kind k') ∧ k' ≤ hi ∧
        (∀ s, s ∉ W → e' s = e0 s) ∧ P k' e') } e)
    (done : ∀ e, e cursor = some (.number kind hi) → (∀ s, s ∉ W → e s = e0 s) → P hi e →
      Q.exited exit .unit e) :
    Wp m (.loop (.sequence (.branch (.binary "==" (.read cursor) (.read stop))
      (.exit exit (.literal .unit)) (.literal .unit)) rest)) Q env :=
  wp_counted kind hi (fun k e => e cursor = some (.number kind k) ∧ k ≤ hi ∧
      (∀ s, s ∉ W → e s = e0 s) ∧ P k e)
    (fun k e ⟨hc, hle, hkept, _⟩ => ⟨hc, by rw [hkept stop stopKept, stopValue], hle⟩)
    k0 ⟨startCursor, startLe, startKept, start⟩
    (fun k e ⟨hc, _, hkept, hp⟩ lt bounded => step k e hc lt bounded hkept hp)
    (fun e ⟨hc, _, hkept, hp⟩ => done e hc hkept hp)

/-- `wp_scan` from the loop's own entry environment. -/
theorem wp_scan_here {m : Machine} {exit cursor stop : Nat} {rest : Expr} {Q : Post} {env : PureEnv}
    (kind : String) (hi : Nat) (W : List Nat) (P : Nat → PureEnv → Prop)
    (stopKept : stop ∉ W) (stopValue : env stop = some (.number kind hi))
    (k0 : Nat) (startCursor : env cursor = some (.number kind k0)) (startLe : k0 ≤ hi)
    (start : P k0 env)
    (step : ∀ k e, e cursor = some (.number kind k) → k < hi → hi < bound m.bits kind →
      (∀ s, s ∉ W → e s = env s) → P k e →
      Wp m rest { Q with normal := (fun _ e' => ∃ k', e' cursor = some (.number kind k') ∧ k' ≤ hi ∧
        (∀ s, s ∉ W → e' s = env s) ∧ P k' e') } e)
    (done : ∀ e, e cursor = some (.number kind hi) → (∀ s, s ∉ W → e s = env s) → P hi e →
      Q.exited exit .unit e) :
    Wp m (.loop (.sequence (.branch (.binary "==" (.read cursor) (.read stop))
      (.exit exit (.literal .unit)) (.literal .unit)) rest)) Q env :=
  wp_scan kind hi W env P stopKept stopValue k0 startCursor startLe (fun _ _ => rfl) start step done

/-- A write to a slot of `W` keeps the slots outside `W`. -/
theorem kept_set {e0 e : PureEnv} {W : List Nat} {x : Nat} (v : PureValue)
    (h : ∀ s, s ∉ W → e s = e0 s) (hx : x ∈ W) : ∀ s, s ∉ W → pureSet e x v s = e0 s := by
  intro s hs
  have : s ≠ x := fun eq => hs (eq ▸ hx)
  rw [set_other _ _ this]
  exact h s hs

theorem ite_ok_error {p : Prop} [Decidable p] {x : Exit} {y c : PureValue} :
    ((if p then Except.ok y else Except.error x) = (Except.ok c : Except Exit PureValue)) ↔ (p ∧ y = c) := by
  by_cases h : p <;> simp [h]

/-- A specification for calls that write the receiver back: a normal or
    returned end whose receiver slot is still defined satisfies `post`. -/
def SatisfiesBack (m : Machine) (name : String) (spec : Spec) : Prop :=
  ∃ body, m.functions name = some body ∧ ∀ self values, spec.pre self values →
    Triple m (fun env => env = frameOf self values) body
      { normal := fun v env => ∀ r, env 0 = some r → spec.post self values v r
        returned := fun v env => ∀ r, env 0 = some r → spec.post self values v r
        exited := fun _ _ _ => True }

theorem Satisfies.back {m : Machine} {name : String} {spec : Spec} (h : Satisfies m name spec) :
    SatisfiesBack m name spec := by
  obtain ⟨body, hbody, t⟩ := h
  exact ⟨body, hbody, fun self values pre => triple_consequence (t self values pre) (fun _ h => h)
    (fun v e ⟨r, hr, p⟩ r' hr' => by rw [hr] at hr'; cases hr'; exact p)
    (fun v e ⟨r, hr, p⟩ r' hr' => by rw [hr] at hr'; cases hr'; exact p) (fun _ _ _ _ => trivial)⟩

/-- Write-back specifications of one function combine. -/
theorem back_and {m : Machine} {name : String} {a b : Spec} (ha : SatisfiesBack m name a)
    (hb : SatisfiesBack m name b) :
    SatisfiesBack m name { pre := fun self values => a.pre self values ∧ b.pre self values,
                           post := fun self values v r => a.post self values v r ∧ b.post self values v r } := by
  obtain ⟨body, hbody, ta⟩ := ha
  obtain ⟨body', hbody', tb⟩ := hb
  rw [hbody] at hbody'
  cases hbody'
  refine ⟨body, hbody, fun self values ⟨pa, pb⟩ fuel env henv => ?_⟩
  have h1 := ta self values pa fuel env henv
  have h2 := tb self values pb fuel env henv
  revert h1 h2
  cases eval m fuel body env with
  | ok r => obtain ⟨v, e⟩ := r; exact fun p1 p2 r hr => ⟨p1 r hr, p2 r hr⟩
  | error x =>
    cases x with
    | returned v e => exact fun p1 p2 r hr => ⟨p1 r hr, p2 r hr⟩
    | exit => intro _ _; trivial
    | fault => intro _ _; trivial

/-- Weakening a write-back specification. -/
theorem back_weaken {m : Machine} {name : String} {a b : Spec} (ha : SatisfiesBack m name a)
    (pre : ∀ self values, b.pre self values → a.pre self values)
    (post : ∀ self values v r, b.pre self values → a.post self values v r → b.post self values v r) :
    SatisfiesBack m name b := by
  obtain ⟨body, hbody, ta⟩ := ha
  refine ⟨body, hbody, fun self values pb => ?_⟩
  exact triple_consequence (ta self values (pre self values pb)) (fun _ h => h)
    (fun v e p r hr => post self values v r pb (p r hr))
    (fun v e p r hr => post self values v r pb (p r hr)) (fun _ _ _ _ => trivial)

/-- Every function keeps the receiver paths outside its write footprint. -/
theorem back_frame (m : Machine) (name : String) (body : Expr) (hbody : m.functions name = some body)
    (n : Nat) :
    SatisfiesBack m name
      { pre := fun _ _ => True,
        post := fun self _ _ r => ∀ p, (∀ q ∈ footprint m.functions n body, Disjoint p q) →
          get p r = get p self } := by
  refine ⟨body, hbody, fun self values _ fuel env henv => ?_⟩
  subst henv
  have g := footprint_sound m fuel n body (frameOf self values)
  have f0 : frameOf self values 0 = some self := frame_receiver self values 1 (by omega)
  cases h : eval m fuel body (frameOf self values) with
  | ok r =>
    obtain ⟨v, e⟩ := r
    rw [h] at g
    intro r hr p d
    have := g e (Or.inl ⟨v, rfl⟩) p d
    rw [hr, f0] at this
    simpa using this
  | error x =>
    rw [h] at g
    cases x with
    | returned v e =>
      intro r hr p d
      have := g e (Or.inr (Or.inl ⟨v, rfl⟩)) p d
      rw [hr, f0] at this
      simpa using this
    | exit => trivial
    | fault => trivial

/-- A call that writes the callee's receiver back to a place in a slot. -/
theorem wp_invoke_back {m : Machine} {name : String} {receiver : Expr} {slot : Nat} {path : List Access}
    {args : List Expr} {Q : Post} {env : PureEnv} (spec : Spec) (sat : SatisfiesBack m name spec)
    (h : Wp m receiver { Q with normal := fun self e => WpArgs m Q (fun values e' =>
      spec.pre self values ∧ ∀ v r, spec.post self values v r →
        WriteBack Q (some (slot, path)) v r e') args [] e } env) :
    Wp m (.invoke name receiver (some (slot, path)) args) Q env := by
  obtain ⟨body, hbody, bodyOk⟩ := sat
  intro fuel
  cases fuel with
  | zero => simp [eval, Post.holds]
  | succ fuel =>
    simp only [eval, bind, Except.bind]
    have h1 := h fuel
    revert h1
    cases eval m fuel receiver env with
    | error x => cases x <;> simp [Post.holds]
    | ok r =>
      obtain ⟨self, e1⟩ := r
      intro h1
      simp only []
      have folded := wpArgs_fold m fuel Q _ args [] e1 h1
      simp only [bind, Except.bind] at folded
      split
      · rename_i x hf
        rw [hf] at folded
        simpa [ArgsEnd] using folded
      · rename_i res hf
        obtain ⟨values, e2⟩ := res
        rw [hf] at folded
        simp only [ArgsEnd] at folded
        obtain ⟨pre, after⟩ := folded
        simp only [hbody]
        have hb := bodyOk self values pre fuel (frameOf self values) rfl
        unfold frameOf at hb
        cases he : eval m fuel body ((values.zipIdx 1).foldl
            (fun frame (value, slot) => pureSet frame slot value) (pureSet (fun _ => none) 0 self)) with
        | ok res =>
          obtain ⟨v, final⟩ := res
          rw [he] at hb
          simp only []
          cases hr0 : final 0 with
          | none => exact trivial
          | some r =>
            have done := after v r (hb r hr0)
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
            simp only []
            cases hr0 : final 0 with
            | none => exact trivial
            | some r =>
              have done := after v r (hb r hr0)
              cases hc : e2 slot with
              | none => exact trivial
              | some current =>
                simp only []
                cases hu : update e2 path current r with
                | error x => obtain ⟨f, rfl⟩ := update_faults _ _ _ _ x hu; exact trivial
                | ok replaced => exact done current replaced hc hu

/-- Structural symbolic execution: sequencing, writes, literals, slot reads
    through `pureSet`, field reads of record literals (after unfolding the
    given definitions), scopes, blocks, exits and returns. -/
syntax "wp_walk" (" [" Lean.Parser.Tactic.simpLemma,* "]")? : tactic
macro_rules
  | `(tactic| wp_walk) => `(tactic| wp_walk [])
  | `(tactic| wp_walk [$lemmas,*]) => `(tactic| repeat' (first
    | (apply wp_sequence)
    | (apply wp_write)
    | (apply wp_literal; try dsimp only)
    | (apply wp_read; intro _v _hv;
       set_option linter.unusedSimpArgs false in
       simp (disch := first | decide | omega) only [set_same, set_other, Option.some.injEq, $lemmas,*] at _hv;
       subst _hv; try dsimp only)
    | (apply wp_field)
    | (apply wp_and)
    | (apply wp_or)
    | (apply wp_binary (by decide))
    | (apply wp_branch)
    | (apply wp_negate)
    | (apply wp_length)
    | (apply wp_index)
    | (apply wp_scope)
    | (apply wp_ret)
    | (apply wp_exit)
    | (apply wp_present)
    | (apply wp_block)
    | (exact wp_panic)
    | (apply wp_choose)
    -- A match's selected arm, at every fuel deep enough for its patterns.
    | (intro _f _body _env _hs;
       have _hs := select_add _f 6 _ _ _ _ _hs;
       set_option linter.unusedSimpArgs false in
       simp [select, matchPattern, List.foldlM, bind, Except.bind, pure, Except.pure, $lemmas,*] at _hs;
       obtain ⟨_h1, _h2⟩ := _hs; subst _h1; subst _h2)
    | (set_option linter.unusedSimpArgs false in
       simp (config := {decide := true}) only [↓reduceIte])
    | (apply wp_ite <;> intro _hite)
    | (split)
    -- A binary operation's result.
    | (intro _c _f _hc;
       try (set_option linter.unusedSimpArgs false in
         simp (disch := first | decide | omega) only [binary_add_fits, Except.ok.injEq] at _hc);
       try (set_option linter.unusedSimpArgs false in
         simp (config := {decide := true}) (disch := first | decide | omega) only [binary_numbers, arithmetic, String.reduceEq,
           ↓reduceIte, ite_error_ok, ite_ok_error, Except.ok.injEq, $lemmas,*] at _hc);
       first | subst _hc | (obtain ⟨_, _hc⟩ := _hc; subst _hc);
       try dsimp only)
    -- An indexed read's result.
    | (intro _vs _x _ha _hi;
       set_option linter.unusedSimpArgs false in
       simp only [PureValue.array.injEq] at _ha; subst _ha;
       set_option linter.unusedSimpArgs false in
       simp (disch := first | decide | omega) only [indexValue, List.getElem?_map, List.getElem?_eq_getElem,
         Option.map_some, Option.some.injEq, Except.ok.injEq, $lemmas,*] at _hi;
       subst _hi; try dsimp only)
    -- A field, condition or other single-value result.
    | (intro _w _hw;
       set_option linter.unusedSimpArgs false in
       simp (disch := first | decide | omega) only [field_record, List.find?, Option.map, String.reduceBEq,
         Option.some.injEq, PureValue.boolean.injEq, PureValue.array.injEq, $lemmas,*] at _hw;
       subst _hw;
       try set_option linter.unusedSimpArgs false in simp only [↓reduceIte, Bool.false_eq_true, decide_eq_true_eq,
         Nat.zero_le, Nat.le_refl, ite_true, ite_false, decide_true, decide_false])))

/-- Frames compose: an inner frame over `V ⊆ W` within an outer one over `W`. -/
theorem kept_via {x y z : PureEnv} {V W : List Nat} (inner : ∀ s, s ∉ V → x s = y s)
    (sub : ∀ s, s ∈ V → s ∈ W) (outer : ∀ s, s ∉ W → y s = z s) : ∀ s, s ∉ W → x s = z s :=
  fun s hs => (inner s (fun hv => hs (sub s hv))).trans (outer s hs)

/-- Close `∀ s, s ∉ W → e' s = e0 s` for `e'` built by writes to slots of `W`
    over an environment that the given hypothesis already relates to `e0`. -/
macro "wp_kept " h:term : tactic =>
  `(tactic| ((repeat (refine kept_set _ ?_ (by decide))); exact $h))

end Provium.Imperative
