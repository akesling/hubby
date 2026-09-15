use provium::methods::{
    buffers::{Run, State},
    Crate,
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "buffers-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("Buffer::push")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Debug)] enum Error {Full}
struct Buffer<T,const N:usize>{slots:[Option<T>;N],len:usize}
impl<T,const CAP:usize> Buffer<T,CAP>{
 fn full(&self)->bool{self.len==CAP}
 fn push(&mut self,input:T)->Result<(),Error>{
  if self.full(){return Err(Error::Full);}
  self.slots[self.len]=Some(input);
  self.len+=1;
  Ok(())
 }
}
"#;
#[test]
fn complete_append_exposes_drop_and_partial_failure_states() {
    let w = Work::new(SOURCE);
    let method = w.lower().unwrap();
    let mut append = method.buffer.unwrap();
    assert_eq!(append.capacity, "CAP");
    for bits in [32, 64] {
        let empty = State {
            slots: vec![None, None],
            len: 0,
        };
        assert_eq!(
            append.evaluate(bits, 2, empty, 7).unwrap(),
            Run::Returned(
                Ok(()),
                State {
                    slots: vec![Some(7), None],
                    len: 1
                }
            )
        );
        let full = State {
            slots: vec![Some(3)],
            len: 1,
        };
        assert_eq!(
            append.evaluate(bits, 1, full.clone(), 7).unwrap(),
            Run::Drop(
                7,
                full.clone(),
                Box::new(Run::Returned(Err("Error::Full".into()), full))
            )
        );
        let hole = State {
            slots: vec![Some(3)],
            len: 0,
        };
        assert_eq!(
            append.evaluate(bits, 1, hole.clone(), 7).unwrap(),
            Run::Drop(
                3,
                hole,
                Box::new(Run::Returned(
                    Ok(()),
                    State {
                        slots: vec![Some(7)],
                        len: 1
                    }
                ))
            )
        );
        let invalid = State {
            slots: vec![None],
            len: 2,
        };
        assert_eq!(
            append.evaluate(bits, 1, invalid.clone(), 7).unwrap(),
            Run::Drop(7, invalid.clone(), Box::new(Run::Bounds(invalid)))
        );
    }
    append.increment = u32::MAX.into();
    let before = State {
        slots: vec![Some(3), None],
        len: 1,
    };
    assert_eq!(
        append.evaluate(32, 2, before, 7).unwrap(),
        Run::Overflow(State {
            slots: vec![Some(3), Some(7)],
            len: 1
        })
    );
}
#[test]
fn hidden_effects_and_unresolved_operations_fail_closed() {
    for source in [
        SOURCE.replace("self.len+=1;", "self.len+=1; external();"),
        SOURCE.replace("self.len==CAP", "self.len==CAP || external()"),
        SOURCE.replace("self.slots[self.len]", "self.slots[self.len+1]"),
        SOURCE.replace("Some(input)", "None"),
        SOURCE.replace("self.len+=1;", "self.len-=1;"),
        SOURCE.replace("Error::Full);", "Error::Unknown);"),
        format!("{SOURCE} fn Some<T>(x:T)->Option<T>{{None}}"),
        SOURCE.replace("Buffer<T,CAP>", "Buffer<Option<T>,CAP>"),
    ] {
        let w = Work::new(&source);
        assert!(w.lower().is_err(), "accepted {source}");
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn independent_append_contract_rejects_source_drift() {
    let w = Work::new(SOURCE);
    fs::write(
        w.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
theorem advances (input : Nat) :
    Subject.Buffer_push 64 1 ⟨[none], 0⟩ input =
      .returned (.ok ()) ⟨[some input], 1⟩ := by
  simp [Subject.Buffer_push, Subject.Buffer_push_ir, appendBuffer]
"#,
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["Buffer::push"],"proofs":"Proofs.lean","obligations":[{"theorem":"advances","function":"Buffer_push"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for mutated in [
        SOURCE.replace("self.len+=1;", "self.len+=2;"),
        SOURCE.replace("self.len==CAP", "self.len!=CAP"),
    ] {
        fs::write(w.0.join("lib.rs"), mutated).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}

#[test]
fn native_append_matches_slots_lengths_drop_order_and_late_panics() {
    for increment in [1, usize::MAX as u64] {
        let source = SOURCE.replace("self.len+=1;", &format!("self.len+={increment};"));
        let w = Work::new(&source);
        let append = w.lower().unwrap().buffer.unwrap();
        let main = format!(
            r#"{source}
use std::cell::RefCell;
thread_local! {{ static DROPS:RefCell<Vec<usize>>=const {{RefCell::new(Vec::new())}}; }}
struct Payload(usize);
impl Drop for Payload {{fn drop(&mut self){{DROPS.with(|d|d.borrow_mut().push(self.0));}}}}
fn check<const N:usize>(){{
 for len in 0..=N+1 {{for mask in 0..(1usize<<N) {{
  let mut state:Buffer<Payload,N>=Buffer{{slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(Payload(i))}}),len}};
  DROPS.with(|d|d.borrow_mut().clear());
  let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||state.push(Payload(99))));
  let status=match result{{Ok(Ok(()))=>"ok",Ok(Err(_))=>"err",Err(_)=>"panic"}};
  let slots:Vec<_>=state.slots.iter().map(|s|s.as_ref().map(|p|p.0)).collect();
  DROPS.with(|d|println!("{{}} {{}} {{:?}} {{:?}}",status,state.len,slots,d.borrow()));
  std::mem::forget(state);
 }} }}
}}
fn main(){{check::<0>();check::<1>();check::<4>();}}
"#
        );
        let file = w.0.join("main.rs");
        fs::write(&file, main).unwrap();
        let binary = w.0.join("native");
        let built = std::process::Command::new("rustc")
            .args(["--edition=2021", "-C", "overflow-checks=yes"])
            .arg(file)
            .arg("-o")
            .arg(&binary)
            .output()
            .unwrap();
        assert!(
            built.status.success(),
            "{}",
            String::from_utf8_lossy(&built.stderr)
        );
        let native = std::process::Command::new(binary).output().unwrap();
        assert!(native.status.success());
        let mut expected = String::new();
        for capacity in [0, 1, 4] {
            for len in 0..=capacity + 1 {
                for mask in 0..1usize << capacity {
                    let state = State {
                        slots: (0..capacity)
                            .map(|i| if mask & (1 << i) == 0 { None } else { Some(i) })
                            .collect(),
                        len,
                    };
                    let mut run = append.evaluate(usize::BITS, capacity, state, 99).unwrap();
                    let mut drops = vec![];
                    loop {
                        match run {
                            Run::Drop(value, _, next) => {
                                drops.push(value);
                                run = *next;
                            }
                            Run::Returned(result, state) => {
                                expected.push_str(&format!(
                                    "{} {} {:?} {:?}\n",
                                    if result.is_ok() { "ok" } else { "err" },
                                    state.len,
                                    state.slots,
                                    drops
                                ));
                                break;
                            }
                            Run::Bounds(state) | Run::Overflow(state) => {
                                expected.push_str(&format!(
                                    "panic {} {:?} {:?}\n",
                                    state.len, state.slots, drops
                                ));
                                break;
                            }
                        }
                    }
                }
            }
        }
        assert_eq!(String::from_utf8(native.stdout).unwrap(), expected);
    }
}
