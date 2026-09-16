#[derive(Clone, Copy, Debug, PartialEq)]
struct Key(u64);
#[derive(Clone, Copy, Debug, PartialEq)]
struct Row { key: Key, active: bool, old: bool, learner: bool }
#[derive(Clone, Copy, Debug, PartialEq)]
struct Table<const N: usize> { rows: [Option<Row>; N] }
#[derive(Clone, Copy, Debug, PartialEq)]
enum Error { Invalid, Full }
impl<const N: usize> Table<N> {
    fn stable(active: &[Key], learners: &[Key]) -> Result<Self, Error> {
        Self::from_sets(active, &[], learners)
    }
    fn from_sets(active: &[Key], old: &[Key], learners: &[Key]) -> Result<Self, Error> {
        if active.is_empty() { return Err(Error::Invalid); }
        let mut result = Self { rows: [None; N] };
        for (set, tag) in [(active, 0), (learners, 1), (old, 2)] {
            for (i, key) in set.iter().enumerate() {
                if set[..i].contains(key) || (tag == 1 && active.contains(key)) {
                    return Err(Error::Invalid);
                }
                result.include(*key, tag)?;
            }
        }
        Ok(result)
    }
    fn include(&mut self, key: Key, tag: u8) -> Result<(), Error> {
        let slot = self.rows.iter().position(|row| row.is_some_and(|row| row.key == key))
            .or_else(|| self.rows.iter().position(Option::is_none)).ok_or(Error::Full)?;
        let row = self.rows[slot].get_or_insert(Row { key, active: false, old: false, learner: false });
        match tag { 0 => row.active = true, 1 => row.learner = true, _ => row.old = true }
        Ok(())
    }
}
