//! Shared filesystem-identity predicates.
//!
//! Several validation paths open a file or directory through an
//! `O_NOFOLLOW`-style descriptor and must prove that the thing they inspected
//! is still the thing they opened (and, after reading, still the same thing).
//! On the platforms this project supports, a `(st_dev, st_ino)` pair is that
//! identity; uid/nlink/mode policy differs per call site and stays local.

/// True when both stats describe the same underlying file or directory.
pub(crate) fn same_file(
    observed: &rustix::fs::Stat,
    opened: &rustix::fs::Stat,
) -> bool {
    observed.st_dev == opened.st_dev && observed.st_ino == opened.st_ino
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_file_requires_both_device_and_inode() {
        let base = rustix::fs::stat(".").unwrap();
        let mut changed = base;
        changed.st_ino += 1;
        assert!(same_file(&base, &base));
        assert!(!same_file(&base, &changed));
        let mut other_device = base;
        other_device.st_dev += 1;
        assert!(!same_file(&base, &other_device));
    }
}
