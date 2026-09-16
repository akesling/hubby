//! Original Rust behavior that the quorum frontend must preserve.
//! These are native regressions, not a source-linked Lean quorum theorem.
use super::Work;
use std::{fs, path::Path, process::Command};
#[test]
fn original_quorum_preserves_callback_order_short_circuiting_and_drop() {
    let w = Work::new();
    let source =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/membership.rs"))
            .unwrap();
    let native = format!(
        r#"
#[derive(Clone,Copy,Debug,Eq,PartialEq)]struct Id(u64);
#[derive(Debug)]enum Error{{Config,Reconfiguring,Full}}
mod membership{{
{source}
use std::{{cell::RefCell,rc::Rc}};
#[derive(Clone,Debug,PartialEq)]enum Event{{Call(u64,usize),Drop(usize,bool)}}
struct Probe{{events:Rc<RefCell<Vec<Event>>>,calls:usize,answers:Vec<bool>,panic_at:Option<usize>,panic_on_drop:bool}}
impl Probe{{fn answer(&mut self,id:Id)->bool{{
 let n=self.calls;self.calls+=1;self.events.borrow_mut().push(Event::Call(id.0,n));
 if self.panic_at==Some(n){{panic!("callback");}}
 self.answers.get(n).copied().unwrap_or(false)
}}}}
impl Drop for Probe{{fn drop(&mut self){{
 self.events.borrow_mut().push(Event::Drop(self.calls,std::thread::panicking()));
 if self.panic_on_drop{{panic!("drop");}}
}}}}
fn membership(joint:bool)->Membership<3>{{Membership{{members:[
 Some(Member{{id:Id(1),voter:true,old:false,learner:false}}),
 Some(Member{{id:Id(2),voter:true,old:joint,learner:false}}),
 Some(Member{{id:Id(3),voter:false,old:joint,learner:!joint}}),
]}}}}
fn check(joint:bool,answers:Vec<bool>,panic_at:Option<usize>,panic_on_drop:bool,expected:Result<bool,()>,trace:Vec<Event>){{
 let events=Rc::new(RefCell::new(vec![]));
 let mut probe=Probe{{events:events.clone(),calls:0,answers,panic_at,panic_on_drop}};
 let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||membership(joint).quorum(move |id|probe.answer(id)))).map_err(|_|());
 assert_eq!(result,expected);assert_eq!(*events.borrow(),trace);
}}
pub fn run(){{
 std::panic::set_hook(Box::new(|_|{{}}));
 let events=Rc::new(RefCell::new(vec![]));
 let mut probe=Probe{{events:events.clone(),calls:0,answers:vec![],panic_at:None,panic_on_drop:false}};
 assert!(!Membership::<0>{{members:[]}}.quorum(move |id|probe.answer(id)));
 assert_eq!(*events.borrow(),vec![Event::Drop(0,false)]);
 check(true,vec![true,true,false,false],None,false,Ok(false),vec![Event::Call(1,0),Event::Call(2,1),Event::Call(2,2),Event::Call(3,3),Event::Drop(4,false)]);
 check(true,vec![false,true,true,true],None,false,Ok(false),vec![Event::Call(1,0),Event::Call(2,1),Event::Drop(2,false)]);
 check(false,vec![true,true],None,false,Ok(true),vec![Event::Call(1,0),Event::Call(2,1),Event::Drop(2,false)]);
 check(true,vec![true,true,true,true],Some(1),false,Err(()),vec![Event::Call(1,0),Event::Call(2,1),Event::Drop(2,true)]);
 check(true,vec![true,true,true,true],Some(2),false,Err(()),vec![Event::Call(1,0),Event::Call(2,1),Event::Call(2,2),Event::Drop(3,true)]);
 check(false,vec![true,true],None,true,Err(()),vec![Event::Call(1,0),Event::Call(2,1),Event::Drop(2,false)]);
}}
}}
fn main(){{membership::run();}}
"#
    );
    let source = w.source(&native);
    let binary = w.0.join("native");
    let built = Command::new("rustc")
        .args([
            "--edition=2021",
            "-Adead_code",
            "-C",
            "panic=unwind",
            "-C",
            "overflow-checks=yes",
        ])
        .arg(source)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert!(Command::new(binary).status().unwrap().success());
}
