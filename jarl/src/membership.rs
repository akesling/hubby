use crate::{Error, Id};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Member {
    id: Id,
    voter: bool,
    old: bool,
    learner: bool,
}

/// Runtime membership within a fixed maximum number of simultaneous peers.
///
/// Construct stable configurations with [`Self::new`]. Joint configurations
/// require both voting majorities. Each identity occupies one slot even if it
/// votes in both configurations. Never reuse an identity after losing its state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Membership<const MAX: usize> {
    members: [Option<Member>; MAX],
}

impl<const MAX: usize> Membership<MAX> {
    /// Create a stable, nonempty voter set with optional nonvoting learners.
    /// All identities must be distinct and their total must fit `MAX`.
    pub fn new(voters: &[Id], learners: &[Id]) -> Result<Self, Error> {
        Self::restore(voters, &[], learners)
    }

    /// Decode a stable or joint configuration from a host-defined format.
    /// This validates structure and union capacity, not authorization.
    pub fn restore(voters: &[Id], old_voters: &[Id], learners: &[Id]) -> Result<Self, Error> {
        if voters.is_empty() {
            return Err(Error::Config);
        }
        let mut result = Self {
            members: [None; MAX],
        };
        for (set, kind) in [(voters, 0), (learners, 1), (old_voters, 2)] {
            for (i, id) in set.iter().enumerate() {
                if set[..i].contains(id) || (kind == 1 && voters.contains(id)) {
                    return Err(Error::Config);
                }
                result.include(*id, kind)?;
            }
        }
        Ok(result)
    }
    fn include(&mut self, id: Id, kind: u8) -> Result<(), Error> {
        let slot = self
            .members
            .iter()
            .position(|m| m.is_some_and(|m| m.id == id))
            .or_else(|| self.members.iter().position(Option::is_none))
            .ok_or(Error::Config)?;
        let member = self.members[slot].get_or_insert(Member {
            id,
            voter: false,
            old: false,
            learner: false,
        });
        match kind {
            0 => member.voter = true,
            1 => member.learner = true,
            _ => member.old = true,
        }
        Ok(())
    }
    /// Target voters (the entire voting set in a stable configuration).
    pub fn voters(&self) -> impl Iterator<Item = Id> + '_ {
        self.members
            .iter()
            .flatten()
            .filter(|m| m.voter)
            .map(|m| m.id)
    }
    /// Previous voters while joint consensus is active.
    pub fn old_voters(&self) -> impl Iterator<Item = Id> + '_ {
        self.members
            .iter()
            .flatten()
            .filter(|m| m.old)
            .map(|m| m.id)
    }
    /// Target learners. A demoted voter still votes in the old joint quorum.
    pub fn learners(&self) -> impl Iterator<Item = Id> + '_ {
        self.members
            .iter()
            .flatten()
            .filter(|m| m.learner)
            .map(|m| m.id)
    }
    /// Whether separate old and new majorities are required.
    pub fn is_joint(&self) -> bool {
        self.members.iter().flatten().any(|m| m.old)
    }
    /// Whether an identity votes in either active set.
    pub fn is_voter(&self, id: Id) -> bool {
        self.members
            .iter()
            .flatten()
            .any(|m| m.id == id && (m.voter || m.old))
    }
    /// Whether an identity participates as a voter or learner.
    pub fn contains(&self, id: Id) -> bool {
        self.members.iter().flatten().any(|m| m.id == id)
    }
    pub(crate) fn peers(&self) -> [Option<Id>; MAX] {
        self.members.map(|m| m.map(|m| m.id))
    }
    pub(crate) fn with_learners(&self, learners: &[Id]) -> Result<Self, Error> {
        let mut next = Self {
            members: [None; MAX],
        };
        for id in self.voters() {
            next.include(id, 0)?;
        }
        for (i, id) in learners.iter().enumerate() {
            if self.is_voter(*id) || learners[..i].contains(id) {
                return Err(Error::Config);
            }
            next.include(*id, 1)?;
        }
        Ok(next)
    }
    pub(crate) fn joint(self, mut target: Self) -> Result<Self, Error> {
        if self.is_joint() || target.is_joint() {
            return Err(Error::Reconfiguring);
        }
        for id in self.voters() {
            target.include(id, 2).map_err(|_| Error::Full)?;
        }
        Ok(target)
    }
    pub(crate) fn finalized(mut self) -> Self {
        for slot in &mut self.members {
            if let Some(member) = slot {
                member.old = false;
                if !member.voter && !member.learner {
                    *slot = None;
                }
            }
        }
        self
    }
    pub(crate) fn quorum_index(&self, mut matched: impl FnMut(Id) -> u64) -> u64 {
        let mut positions = [0; MAX];
        let mut count = 0;
        for id in self.voters() {
            positions[count] = matched(id);
            count += 1;
        }
        positions[..count].sort_unstable();
        let new = positions[count - (count / 2 + 1)];
        if !self.is_joint() {
            return new;
        }
        count = 0;
        for id in self.old_voters() {
            positions[count] = matched(id);
            count += 1;
        }
        positions[..count].sort_unstable();
        let old = positions[count - (count / 2 + 1)];
        new.min(old)
    }

    pub(crate) fn quorum(&self, mut acknowledged: impl FnMut(Id) -> bool) -> bool {
        let majority = |old: bool, acknowledged: &mut dyn FnMut(Id) -> bool| {
            let voters = self
                .members
                .iter()
                .flatten()
                .filter(|m| if old { m.old } else { m.voter });
            let total = voters.clone().count();
            let count = voters.filter(|m| acknowledged(m.id)).count();
            count > total / 2
        };
        majority(false, &mut acknowledged)
            && (!self.is_joint() || majority(true, &mut acknowledged))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;
    #[test]
    fn quorums_match_independent_counts_for_every_three_peer_configuration() {
        for old in 1u8..8 {
            for new in 1u8..8 {
                let ids = |mask: u8| {
                    (0..3)
                        .filter(|i| mask & (1 << i) != 0)
                        .map(Id)
                        .collect::<Vec<_>>()
                };
                let membership = Membership::<3>::restore(&ids(new), &ids(old), &[]).unwrap();
                for values in 0..27 {
                    let positions = [values % 3, values / 3 % 3, values / 9];
                    for threshold in 0..=3 {
                        let expected = |mask: u8| {
                            (0..3)
                                .filter(|i| mask & (1 << i) != 0 && positions[*i] >= threshold)
                                .count()
                                * 2
                                > mask.count_ones() as usize
                        };
                        let expected = expected(old) && expected(new);
                        assert_eq!(
                            membership.quorum(|id| positions[id.0 as usize] >= threshold),
                            expected
                        );
                        assert_eq!(
                            membership.quorum_index(|id| positions[id.0 as usize]) >= threshold,
                            expected
                        );
                    }
                }
            }
        }
    }
}
