//! Directed schedules for election safety: at most one leader per term.
use jarl::{
    Checkpoint, Cluster, ClusterState, Envelope, Id, Membership, Message, Record, Role, Settings,
};

const MAX: usize = 5;
const CAP: usize = 8;
type Peer = Cluster<u64, u64, MAX, CAP>;
type Wire = Envelope<Record<u64, MAX>, Checkpoint<u64, MAX>>;

struct World {
    nodes: Vec<Peer>,
}
impl World {
    fn new() -> Self {
        let ids = [Id(0), Id(1), Id(2), Id(3), Id(4)];
        let genesis = Membership::new(&ids, &[]).unwrap();
        let nodes = (0..MAX)
            .map(|i| {
                Cluster::new(
                    Settings {
                        seed: i as u64 + 1,
                        ..Settings::default()
                    },
                    ClusterState::new(Id(i as u64), genesis).unwrap(),
                )
                .unwrap()
            })
            .collect();
        Self { nodes }
    }
    /// Acknowledge pending storage and take every outgoing message.
    fn settle(&mut self, i: usize) -> Vec<Wire> {
        if let Some(ready) = self.nodes[i].ready() {
            ready.persisted();
        }
        let mut sent = vec![];
        while let Some(message) = self.nodes[i].next_message() {
            sent.push(message.cloned());
        }
        sent
    }
    fn deliver(&mut self, message: &Wire) -> Vec<Wire> {
        let to = message.to.0 as usize;
        self.nodes[to].step(message).unwrap();
        self.settle(to)
    }
    /// Tick one node until it emits messages of the selected kind.
    fn time_out(&mut self, i: usize, kind: fn(&Wire) -> bool) -> Vec<Wire> {
        for _ in 0..1000 {
            self.nodes[i].tick().unwrap();
            let sent = self.settle(i);
            if sent.iter().any(kind) {
                return sent;
            }
        }
        panic!("node {i} never timed out");
    }
    fn deliver_to(&mut self, messages: &[Wire], recipients: &[u64]) -> Vec<Wire> {
        messages
            .iter()
            .filter(|m| recipients.contains(&m.to.0))
            .flat_map(|m| self.deliver(m))
            .collect()
    }
    fn term(&self, i: usize) -> u64 {
        self.nodes[i].status().term
    }
}
fn prevote(m: &Wire) -> bool {
    matches!(m.message, Message::PreVote { .. })
}

/// A candidate whose election times out probes the next term with pre-votes.
/// Those grants are not votes for its current term, and a delayed real vote
/// from that term must not combine with them into a quorum.
#[test]
fn prevote_grants_never_count_as_votes_for_the_current_term() {
    let mut w = World::new();
    // Node 0 wins pre-votes from 2 and 3 and campaigns in term 1.
    let probes = w.time_out(0, prevote);
    let grants = w.deliver_to(&probes, &[2, 3]);
    let requests = w.deliver_to(&grants, &[0]);
    assert_eq!((w.nodes[0].role(), w.term(0)), (Role::Candidate, 1));
    // Only node 2 receives the vote request; its grant is delayed.
    let delayed = w.deliver_to(&requests, &[2]);
    assert!(matches!(
        delayed[..],
        [Envelope {
            message: Message::Voted { term: 1, granted: true },
            ..
        }]
    ));
    // Node 1 is elected in term 1 by nodes 3 and 4.
    let probes = w.time_out(1, prevote);
    let grants = w.deliver_to(&probes, &[3, 4]);
    let requests = w.deliver_to(&grants, &[1]);
    let votes = w.deliver_to(&requests, &[3, 4]);
    w.deliver_to(&votes, &[1]);
    assert_eq!((w.nodes[1].role(), w.term(1)), (Role::Leader, 1));
    // Node 0's election times out; node 3 has not yet heard from the leader
    // and grants node 0's pre-vote for term 2.
    let probes = w.time_out(0, prevote);
    let grants = w.deliver_to(&probes, &[3]);
    w.deliver_to(&grants, &[0]);
    // The delayed term-1 vote arrives. Two term-1 votes plus a term-2
    // pre-vote grant are not a term-1 quorum.
    w.deliver_to(&delayed, &[0]);
    assert!(
        !(w.nodes[0].role() == Role::Leader && w.term(0) == 1),
        "two leaders were elected in term 1"
    );
}
