use provium::methods::Crate;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "array-tests-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }
    fn source(&self, s: &str) -> PathBuf {
        let p = self.0.join("lib.rs");
        fs::write(&p, s).unwrap();
        p
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy)] struct Member {old:bool,voter:bool,learner:bool}
#[derive(Clone,Copy)] struct Membership<const N:usize> {members:[Option<Member>;N]}
impl<const N:usize> Membership<N>{
 fn finalized(mut self)->Self {
  for slot in &mut self.members {if let Some(member)=slot {member.old=false;if !member.voter && !member.learner {*slot=None;}}}
  self
 }
 fn is_joint(&self)->bool {self.members.iter().flatten().any(|m| m.old)}
}
"#;
#[test]
fn arrays_require_complete_traversals_and_resolved_builtin_operations() {
    let w = Work::new();
    let krate = Crate::load(&w.source(SOURCE)).unwrap();
    let update = krate.lower("Membership::finalized").unwrap();
    assert_eq!(update.writes.len(), 2);
    assert_eq!(update.array.as_ref().unwrap().capacity, "N");
    assert!(krate
        .lower("Membership::is_joint")
        .unwrap()
        .array
        .unwrap()
        .predicate
        .is_some());
    for bad in [
        SOURCE.replace("member.old=false;", "member.old=false;external();"),
        SOURCE.replace("{*slot=None;}", "{*slot=None;} break;"),
        SOURCE.replace("&mut self.members", "&self.members"),
        SOURCE.replace(
            "member.old=false;",
            "member.old=false; self.members[0]=None;",
        ),
        SOURCE.replace("#[derive(Clone,Copy)] struct Member", "struct Member"),
        SOURCE.replace("self\n }", "self.members[0]=None; self\n }"),
        SOURCE.replace(
            "{*slot=None;}",
            "{*slot=Some(Member{old:false,voter:false,learner:false});}",
        ),
    ] {
        assert!(
            Crate::load(&w.source(&bad))
                .and_then(|c| c.lower("Membership::finalized"))
                .is_err(),
            "accepted {bad}"
        );
    }
    for bad in [SOURCE.replace(".iter()",".into_iter()"),SOURCE.replace("|m| m.old","|m| check(m)"),format!("{SOURCE} trait Shadow {{fn iter(&self)->std::iter::Empty<&Member>{{std::iter::empty()}}}} impl<T> Shadow for T {{}}") ] {
        assert!(Crate::load(&w.source(&bad)).and_then(|c|c.lower("Membership::is_joint")).is_err(),"accepted {bad}");
    }
}
