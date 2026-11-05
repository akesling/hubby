import Contracts.MembershipQuorum

/-!
# Membership contracts (typed backend)

Port of the `membership` proof project onto Provium's typed translation. The
contracts live in:

* `Contracts.MembershipBase` — projections, finalization, identity queries;
* `Contracts.MembershipInclude` — `include`;
* `Contracts.MembershipPass`, `Contracts.MembershipSpec` — the insertion loops
  of `restore`/`with_learners`/`joint` as pure specifications;
* `Contracts.MembershipBuild` — `restore`, `new`, set interpretation,
  capacity acceptance, `peers`;
* `Contracts.MembershipReconfig` — `with_learners`, `joint`;
* `Contracts.MembershipQuorum` — `quorum`, `quorum_index`.
-/
