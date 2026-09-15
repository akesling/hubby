use provium::methods::{buffers::State, relocations::Outcome, Crate};
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
                "relocations-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("Buffer::grow")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
struct Buffer<T,const N:usize>{stamp:u64,snapshot:Option<T>,slots:[Option<T>;N],len:usize}
impl<T,const OLD:usize> Buffer<T,OLD>{
 fn grow<const NEW:usize>(mut self)->Buffer<T,NEW>{
  const {assert!(NEW>=OLD,"cannot shrink");}
  Buffer{
   stamp:self.stamp,
   snapshot:self.snapshot.take(),
   slots:core::array::from_fn(|i|{if i<self.len{self.slots[i].take()}else{None}}),
   len:self.len,
  }
 }
}
"#;
#[test]
fn all_metadata_and_move_effects_are_checked() {
    let w = Work::new(SOURCE);
    let method = w.lower().unwrap();
    let grow = method.relocation.unwrap();
    assert_eq!(grow.old_capacity, "OLD");
    assert_eq!(grow.new_capacity, "NEW");
    assert_eq!(
        grow.metadata,
        [
            ("stamp".into(), "transfer".into()),
            ("snapshot".into(), "take".into()),
            ("len".into(), "transfer".into())
        ]
    );
    assert_eq!(
        grow.evaluate(
            2,
            4,
            State {
                slots: vec![Some(7), None],
                len: 1
            },
            42
        ),
        Outcome::Returned(
            State {
                slots: vec![Some(7), None, None, None],
                len: 1
            },
            42
        )
    );
    assert_eq!(
        grow.evaluate(
            2,
            4,
            State {
                slots: vec![Some(7), Some(8)],
                len: 1
            },
            42
        ),
        Outcome::Drop(
            8,
            Box::new(Outcome::Returned(
                State {
                    slots: vec![Some(7), None, None, None],
                    len: 1
                },
                42
            ))
        )
    );
    assert_eq!(
        grow.evaluate(
            2,
            1,
            State {
                slots: vec![Some(7), None],
                len: 1
            },
            42
        ),
        Outcome::InvalidInstantiation
    );
}
#[test]
fn dropped_fields_custom_callbacks_and_ambiguous_types_are_rejected() {
    for source in [
        SOURCE.replace("snapshot:self.snapshot.take(),", "snapshot:None,"),
        SOURCE.replace("stamp:self.stamp", "stamp:0"),
        SOURCE.replace("self.slots[i].take()", "self.slots[i].clone()"),
        SOURCE.replace("if i<self.len", "external(); if i<self.len"),
        SOURCE.replace("self.slots[i].take()", "self.slots[i+1].take()"),
        SOURCE.replace("const {assert!", "external(); const {assert!"),
        format!("{SOURCE} impl<T,const N:usize> Drop for Buffer<T,N>{{fn drop(&mut self){{}}}}"),
        format!("{SOURCE} struct core;"),
        SOURCE.replace("Buffer<T,NEW>", "Buffer<Option<T>,NEW>"),
    ] {
        let w = Work::new(&source);
        assert!(w.lower().is_err(), "accepted {source}");
    }
}
#[test]
fn native_growth_preserves_payload_identity_metadata_and_disposal_order() {
    for owned_metadata in [false, true] {
        let source = if owned_metadata {
            SOURCE.replace("stamp:u64", "stamp:T")
        } else {
            SOURCE.to_owned()
        };
        let w = Work::new(&source);
        let grow = w.lower().unwrap().relocation.unwrap();
        let main = format!(
            r#"{source}
use std::cell::RefCell;
thread_local!{{static DROPS:RefCell<Vec<usize>>=const{{RefCell::new(Vec::new())}};}}
struct Payload(usize);
impl Drop for Payload{{fn drop(&mut self){{DROPS.with(|d|d.borrow_mut().push(self.0));}}}}
fn check<const OLD:usize,const NEW:usize>(){{
 for len in 0..=OLD{{for mask in 0..1usize<<OLD{{
  let before:Buffer<Payload,OLD>=Buffer{{stamp:73,snapshot:Some(Payload(99)),slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(Payload(i))}}),len}};
  DROPS.with(|d|d.borrow_mut().clear());
  let after:Buffer<Payload,NEW>=before.grow();
  let slots:Vec<_>=after.slots.iter().map(|s|s.as_ref().map(|p|p.0)).collect();
  DROPS.with(|d|println!("{{}} {{:?}} {{}} {{:?}} {{:?}}",after.stamp,after.snapshot.as_ref().map(|p|p.0),after.len,slots,d.borrow()));
  std::mem::forget(after);
 }}}}
}}
fn main(){{check::<0,0>();check::<0,4>();check::<1,1>();check::<1,4>();check::<4,4>();check::<4,7>();}}
"#
        );
        let main = if owned_metadata {
            main.replace("stamp:73", "stamp:Payload(73)")
                .replace("after.stamp,", "after.stamp.0,")
        } else {
            main
        };
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
        for (old, new) in [(0, 0), (0, 4), (1, 1), (1, 4), (4, 4), (4, 7)] {
            for len in 0..=old {
                for mask in 0..1usize << old {
                    let state = State {
                        slots: (0..old)
                            .map(|i| if mask & (1 << i) == 0 { None } else { Some(i) })
                            .collect(),
                        len: len as u64,
                    };
                    let mut run = grow.evaluate(old, new, state, (73, Some(99)));
                    let mut drops = vec![];
                    loop {
                        match run {
                            Outcome::Drop(value, next) => {
                                drops.push(value);
                                run = *next;
                            }
                            Outcome::Returned(state, (stamp, snapshot)) => {
                                expected.push_str(&format!(
                                    "{stamp} {snapshot:?} {} {:?} {drops:?}\n",
                                    state.len, state.slots
                                ));
                                break;
                            }
                            other => panic!("unexpected {other:?}"),
                        }
                    }
                }
            }
        }
        assert_eq!(String::from_utf8(native.stdout).unwrap(), expected);
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn independent_growth_contract_rejects_source_drift() {
    let w = Work::new(SOURCE);
    fs::write(
        w.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
theorem preserves (input : Nat) (metadata : Nat) :
    Subject.Buffer_grow 1 2 ⟨[some input],1⟩ metadata =
      .returned ⟨[some input,none],1⟩ metadata := by
  simp [Subject.Buffer_grow,Subject.Buffer_grow_ir,relocate,moveSlots,disposeSlots]
"#,
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["Buffer::grow"],"proofs":"Proofs.lean","obligations":[{"theorem":"preserves","function":"Buffer_grow"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace("i<self.len", "i<=self.len"),
        SOURCE.replace("NEW>=OLD", "NEW<=OLD"),
    ] {
        fs::write(w.0.join("lib.rs"), source).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
