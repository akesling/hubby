use provium::methods::Crate;
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
                "enum-projection-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("Event::epoch")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
enum Event<T>{Open{epoch:u64,payload:T},Reply{epoch:u64,request:u64}}
impl<T> Event<T>{fn epoch(&self)->u64{match self{Self::Open{epoch,..}|Self::Reply{epoch,..}=>*epoch}}}
"#;
#[test]
fn complete_enum_projection_preserves_alternatives_and_field_identity() {
    let w = Work::new(SOURCE);
    let p = w.lower().unwrap().enum_projection.unwrap();
    assert_eq!(p.receiver, "Event");
    assert_eq!(p.branches.len(), 2);
    assert_eq!(p.branches[0].variant, "Open");
    assert_eq!(p.branches[1].variant, "Reply");
    assert!(p.branches.iter().all(|b| b.field == "epoch"));
    let changed =
        Work::new(&SOURCE.replace("Self::Reply{epoch,..}", "Self::Reply{request:epoch,..}"));
    assert_eq!(
        changed.lower().unwrap().enum_projection.unwrap().branches[1].field,
        "request"
    );
    for source in [
        SOURCE.replace("=>*epoch", "if true=>*epoch"),
        SOURCE.replace("=>*epoch", "=>{external();*epoch}"),
        SOURCE.replace("=>*epoch", "=>*epoch+1"),
        SOURCE.replace("|Self::Reply{epoch,..}", ""),
        SOURCE.replace("|Self::Reply{epoch,..}", "|Self::Open{epoch,..}"),
        SOURCE.replace("Self::Reply{epoch,..}", "Self::Reply{unknown:epoch,..}"),
        SOURCE.replace("epoch:u64,payload:T", "epoch:T,payload:T"),
        SOURCE.replace("enum Event<T>", "#[cfg(any())] enum Event<T>"),
        SOURCE.replace("Open{epoch:u64", "#[cfg(any())] Open{epoch:u64"),
        SOURCE.replace("Open{epoch:u64", "Open{#[cfg(any())] epoch:u64"),
        format!("type u64=u32;{SOURCE}"),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}");
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn native_enum_results_are_kernel_checked_and_changed_fields_rejected() {
    let w = Work::new(SOURCE);
    fs::write(
        w.0.join("native.rs"),
        format!(
            r#"{SOURCE}
fn main(){{for epoch in [0,1,u64::MAX]{{for request in [0,2,u64::MAX]{{
for message in [Event::Open{{epoch,payload:()}},Event::Reply{{epoch,request}}]{{
let variant=match message{{Event::Open{{..}}=>"Open",Event::Reply{{..}}=>"Reply"}};
println!("{{variant}} {{epoch}} {{request}} {{}}",message.epoch());
}}}}}}}}
"#
        ),
    )
    .unwrap();
    let binary = w.0.join("native");
    let built = std::process::Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(w.0.join("native.rs"))
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
    let mut proofs = String::from("import Generated\nopen Provium.State\n");
    let mut obligations = Vec::new();
    for (i, line) in String::from_utf8(native.stdout)
        .unwrap()
        .lines()
        .enumerate()
    {
        let parts = line.split_whitespace().collect::<Vec<_>>();
        assert_eq!(parts.len(), 4);
        let (variant, epoch, request, result) = (parts[0], parts[1], parts[2], parts[3]);
        proofs.push_str(&format!("theorem native_{i} : Subject.Event_epoch ⟨\"{variant}\",fun path => if path = [\"epoch\"] then .unsigned \"u64\" {epoch} else if path = [\"request\"] then .unsigned \"u64\" {request} else .absent⟩ = some {result} := by rfl\n"));
        obligations
            .push(serde_json::json!({"theorem":format!("native_{i}"),"function":"Event_epoch"}));
    }
    assert_eq!(obligations.len(), 18);
    proofs.push_str(r#"theorem all_values (variant : String) (fields : InitStore) (value : Nat)
    (known : variant = "Open" ∨ variant = "Reply")
    (read : recordWord fields ["epoch"] = some value) :
    Subject.Event_epoch ⟨variant,fields⟩ = some value := by
  rcases known with rfl | rfl <;> simp [Subject.Event_epoch,Subject.Event_epoch_ir,enumProjection,read,bind,Option.bind]
"#);
    obligations.push(serde_json::json!({"theorem":"all_values","function":"Event_epoch"}));
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,serde_json::to_vec(&serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["Event::epoch"],"proofs":"Proofs.lean","obligations":obligations})).unwrap()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    fs::write(
        w.0.join("lib.rs"),
        SOURCE.replace("Self::Reply{epoch,..}", "Self::Reply{request:epoch,..}"),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
}
