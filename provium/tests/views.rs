use provium::methods::Crate;
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "views-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn load(&self, source: &str) -> Crate {
        let path = self.0.join("source.rs");
        fs::write(&path, source).unwrap();
        Crate::load(&path).unwrap()
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone, Copy, Default)] struct Position { index: u64 }
struct Snapshot { last: Position }
struct Buffer { snapshot: Option<Snapshot>, len: usize }
impl Buffer {
    fn base(&self) -> Position { self.snapshot.as_ref().map_or(Position::default(), |s| s.last) }
    fn offset(&self, from: Option<u64>) -> usize {
        let offset = from.map_or(self.len, |index| {
            usize::try_from(index.saturating_sub(self.base().index).saturating_sub(1))
                .unwrap_or(self.len).min(self.len)
        });
        offset
    }
}
"#;

#[test]
fn suffix_component_retains_the_complete_conversion_and_callback() {
    let work = Work::new();
    let offset = work
        .load(SOURCE)
        .inspect_suffix_offset("Buffer::offset")
        .unwrap();
    assert_eq!(offset.length, ["len"]);
    assert_eq!(offset.base_method, "Buffer::base");
    assert_eq!(offset.bias, 1);
    assert!(offset.base_rust.contains("map_or"));
    for source in [
        SOURCE.replace(".min(self.len)", ".min(0)"),
        SOURCE.replace(".unwrap_or(self.len)", ".unwrap_or(0)"),
        SOURCE.replace("saturating_sub(1)", "wrapping_sub(1)"),
        SOURCE.replace("usize::try_from", "u32::try_from"),
        SOURCE.replace("|index| {", "|index| { panic!();"),
        SOURCE.replace("|index|", "move |index|"),
        SOURCE.replace("self.base().index", "self.len"),
        SOURCE.replace(
            "fn base(&self) -> Position {",
            "fn base(&self) -> Position { panic!();",
        ),
        format!("{SOURCE}\ntrait Sneaky {{ fn min(self, value: usize) -> usize; }}"),
    ] {
        assert!(
            work.load(&source)
                .inspect_suffix_offset("Buffer::offset")
                .is_err(),
            "accepted {source}"
        );
    }
    let renamed = SOURCE
        .replace("offset", "start")
        .replace("from", "first")
        .replace("len", "used")
        .replace("saturating_sub(1)", "saturating_sub(2)");
    // Replacing `from` also changes the associated function name: retain the
    // builtin spelling while independently renaming the method input.
    let renamed = renamed.replace("try_first", "try_from");
    let offset = work
        .load(&renamed)
        .inspect_suffix_offset("Buffer::start")
        .unwrap();
    assert_eq!(offset.bias, 2);
    assert_eq!(offset.length, ["used"]);
}

#[test]
fn suffix_offsets_agree_with_original_native_rust_and_checked_32_bit_conversion() {
    let work = Work::new();
    let offset = work
        .load(SOURCE)
        .inspect_suffix_offset("Buffer::offset")
        .unwrap();
    let mut harness = format!("{SOURCE}\nfn main() {{\n");
    let indices = [
        0,
        1,
        2,
        9,
        u32::MAX as u64,
        1u64 << 32,
        (1u64 << 32) + 1,
        u64::MAX,
    ];
    for base in indices {
        for length in [0, 1, 7, 31] {
            for first in std::iter::once(None).chain(indices.into_iter().map(Some)) {
                for bits in [32, 64] {
                    let expected = first.map_or(length, |i| {
                        let relative = i.saturating_sub(base).saturating_sub(1);
                        if bits == 32 {
                            u32::try_from(relative)
                                .map(u64::from)
                                .unwrap_or(length)
                                .min(length)
                        } else {
                            relative.min(length)
                        }
                    });
                    assert_eq!(
                        offset.evaluate(bits, length, base, first).unwrap(),
                        expected
                    );
                }
                let expected = offset.evaluate(usize::BITS, length, base, first).unwrap();
                harness.push_str(&format!("assert_eq!(Buffer {{ snapshot: Some(Snapshot {{ last: Position {{ index: {base} }} }}), len: {length} }}.offset({first:?}), {expected});\n"));
            }
        }
    }
    assert!(offset.evaluate(32, 1 << 32, 0, None).is_err());
    assert!(offset.evaluate(16, 0, 0, None).is_err());
    harness.push_str("}\n");
    let source = work.0.join("native.rs");
    fs::write(&source, harness).unwrap();
    let binary = work.0.join("native");
    let result = Command::new("rustc")
        .args(["--edition=2021", "-Dwarnings"])
        .arg(&source)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(Command::new(binary).status().unwrap().success());
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_checks_suffix_bounds_and_generated_component() {
    let work = Work::new();
    let offset = work
        .load(SOURCE)
        .inspect_suffix_offset("Buffer::offset")
        .unwrap();
    fs::create_dir(work.0.join("Provium")).unwrap();
    fs::write(
        work.0.join("Provium/State.lean"),
        include_str!("../lean/Provium/State.lean"),
    )
    .unwrap();
    let proof = format!("import Provium.State\nopen Provium.State\n{}\ntheorem checked (success : suffixOffset inspected bits state first = .ok result) : result ≤ state.lengths inspected.lengthPath := suffixOffset_bounded success\nexample : suffixOffsetValue 32 7 0 1 (2^32 + 1) = 7 := by decide\nexample : borrowSlice [\"slots\"] 4 3 5 = .error .bounds := by rfl\nexample : borrowSlice [\"slots\"] 4 3 2 = .error .bounds := by rfl\n#print axioms checked\n", offset.lean_definition("inspected").unwrap());
    fs::write(work.0.join("Check.lean"), proof).unwrap();
    for arguments in [
        vec!["-o", "Provium/State.olean", "Provium/State.lean"],
        vec!["Check.lean"],
    ] {
        let result = Command::new("elan")
            .args([
                "run",
                provium::project::TOOLCHAIN,
                "lean",
                "--trust=0",
                "--threads=1",
                "-DwarningAsError=true",
            ])
            .arg(format!(
                "--memory={}",
                provium::project::lean_memory_limit_mb().unwrap()
            ))
            .args(arguments)
            .current_dir(&work.0)
            .env("LEAN_PATH", &work.0)
            .env_remove("LEAN_SRC_PATH")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
}

fn whole_source() -> String {
    SOURCE.replace("struct Buffer { snapshot: Option<Snapshot>, len: usize }", "struct Buffer { snapshot: Option<Snapshot>, len: usize, slots: [Option<u64>; 8], copied: Position }\nstruct View<'a> { copied: Position, optional: Option<&'a Snapshot>, first: Option<u64>, slice: &'a [Option<u64>] }")
        .replace("fn offset(&self, from: Option<u64>) -> usize", "fn offset(&self, from: Option<u64>, changed: bool) -> View<'_>")
        .replace("        offset\n", "        View { copied: self.copied, optional: self.snapshot.as_ref().filter(|_| changed), first: from, slice: &self.slots[offset..self.len] }\n")
}

#[test]
fn complete_shared_view_checks_every_returned_field_and_statement() {
    let work = Work::new();
    let source = whole_source();
    let method = work.load(&source).lower("Buffer::offset").unwrap();
    let view = method.view.unwrap();
    assert_eq!(view.output_fields, ["copied", "optional", "first", "slice"]);
    assert_eq!(view.copied, ["copied"]);
    assert_eq!(view.optional, ["snapshot"]);
    assert_eq!(view.slots, ["slots"]);
    for changed in [
        source.replace("offset..self.len", "0..self.len"),
        source.replace("offset..self.len", "offset..=self.len"),
        source.replace("filter(|_| changed)", "filter(|_| !changed)"),
        source.replace("first: from", "first: None"),
        source.replace("&self.slots", "&mut self.slots"),
        source.replace("View { copied:", "panic!(); View { copied:"),
        source.replace("copied: self.copied", "copied: self.base()"),
    ] {
        assert!(
            work.load(&changed).lower("Buffer::offset").is_err(),
            "accepted {changed}"
        );
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn complete_shared_view_has_checked_correspondence_and_bounds() {
    let work = Work::new();
    work.load(&whole_source());
    fs::write(
        work.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
 theorem metadata_only (bits : Nat) (state : SharedSuffixStore α)
    (word : state.view.lengths ["len"] < 2^bits)
    (capacity : state.view.lengths ["len"] ≤ state.capacities ["slots"]) :
    Subject.Buffer_offset bits state none false = .ok
      ⟨state.copied ["copied"], none, none,
       ⟨["slots"], state.view.lengths ["len"], state.view.lengths ["len"]⟩, ["copied", "optional", "first", "slice"]⟩ := by
  have offset := suffixOffset_none Subject.Buffer_offset_offset bits state.view word
  have result := sharedSuffix_success (program := Subject.Buffer_offset_ir)
    (changed := false) offset capacity
  simpa [Subject.Buffer_offset, Subject.Buffer_offset_ir, Subject.Buffer_offset_offset] using result
"#,
    )
    .unwrap();
    let config = serde_json::json!({"crate_root":"source.rs", "namespace":"Subject", "methods":["Buffer::offset"], "proofs":"Proofs.lean", "obligations":[{"theorem":"metadata_only", "function":"Buffer_offset"}]});
    let path = work.0.join("project.json");
    fs::write(&path, config.to_string()).unwrap();
    provium::methods::verify(&path, &work.0.join("out")).unwrap();
    let changed = whole_source()
        .replace("struct View<'a> { copied:", "struct View<'a> { renamed:")
        .replace("View { copied:", "View { renamed:");
    work.load(&changed);
    let error = provium::methods::verify(&path, &work.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!work.0.join("out/verified.json").exists());
}

#[test]
fn complete_view_matches_native_borrowed_locations_and_bounds_panics() {
    let work = Work::new();
    let source = whole_source();
    let view = work
        .load(&source)
        .lower("Buffer::offset")
        .unwrap()
        .view
        .unwrap();
    let mut harness = format!("{source}\nfn main() {{\n");
    for length in [0, 1, 7, 8] {
        for first in [
            None,
            Some(0),
            Some(1),
            Some(6),
            Some((1u64 << 32) + 1),
            Some(u64::MAX),
        ] {
            for present in [false, true] {
                for changed in [false, true] {
                    let base = if present { 5 } else { 0 };
                    let offset = view
                        .offset
                        .evaluate(usize::BITS, length, base, first)
                        .unwrap();
                    harness.push_str(&format!("{{ let buffer = Buffer {{ snapshot: if {present} {{ Some(Snapshot {{ last: Position {{ index: 5 }} }}) }} else {{ None }}, len: {length}, slots: [Some(42); 8], copied: Position {{ index: 91 }} }}; let view = buffer.offset({first:?}, {changed}); assert_eq!(view.copied.index, 91); assert_eq!(view.first, {first:?}); assert_eq!(view.optional.is_some(), {present} && {changed}); if let Some(snapshot) = view.optional {{ assert!(core::ptr::eq(snapshot, buffer.snapshot.as_ref().unwrap())); }} assert_eq!(view.slice.len(), {length} - {offset}); assert_eq!(view.slice.as_ptr(), buffer.slots[{offset}..{length}].as_ptr()); }}\n"));
                }
            }
        }
    }
    harness.push_str("let bad = Buffer { snapshot: None, len: 9, slots: [None; 8], copied: Position { index: 0 } }; assert!(std::panic::catch_unwind(|| bad.offset(None, false)).is_err());\n}\n");
    let path = work.0.join("native_view.rs");
    fs::write(&path, harness).unwrap();
    let binary = work.0.join("native_view");
    let compile = Command::new("rustc")
        .args(["--edition=2021", "-Dwarnings"])
        .arg(path)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compile.status.success(),
        "{}",
        String::from_utf8_lossy(&compile.stderr)
    );
    let run = Command::new(binary).output().unwrap();
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
}
