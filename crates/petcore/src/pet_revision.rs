use crate::db::Database;
use crate::paths::AppPaths;
use crate::{new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::PetSummary;
use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

const ACTIVE_POINTER_SCHEMA_VERSION: &str = "apc.pet-active-revision.v1";
const MAX_REVISION_METADATA_DIRECTORY_ENTRIES: usize = 4_096;

/// Serializes pet-library mutations across daemon requests and explicit offline
/// maintenance processes. The lock is intentionally separate from the daemon
/// singleton lock: reads remain available while a revision is being prepared.
pub struct PetStoreGuard {
    file: File,
}

impl PetStoreGuard {
    pub fn acquire(paths: &AppPaths) -> Result<Self> {
        Self::acquire_with(paths, rustix::fs::FlockOperation::LockExclusive)
    }

    pub(crate) fn acquire_shared(paths: &AppPaths) -> Result<Self> {
        Self::acquire_with(paths, rustix::fs::FlockOperation::LockShared)
    }

    fn acquire_with(paths: &AppPaths, operation: rustix::fs::FlockOperation) -> Result<Self> {
        fs::create_dir_all(&paths.pets_dir)?;
        let lock_path = paths.pets_dir.join(".pet-store.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&lock_path)?;
        rustix::fs::flock(&file, operation).map_err(std::io::Error::from)?;
        Ok(Self { file })
    }
}

impl Drop for PetStoreGuard {
    fn drop(&mut self) {
        let _ = rustix::fs::flock(&self.file, rustix::fs::FlockOperation::Unlock);
    }
}

#[derive(Debug, Clone)]
pub struct PetRevisionLayout {
    pub pet_id: String,
    pub revision_id: String,
    pub pet_root: PathBuf,
    pub revisions_root: PathBuf,
    pub revision_dir: PathBuf,
    pub petpack_path: PathBuf,
    pub cover_path: PathBuf,
    pub frames_dir: PathBuf,
    pub active_pointer_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct OwnedPetRevision {
    pub revision_id: String,
    pub petpack_path: PathBuf,
    pub cover_path: Option<PathBuf>,
    pub current: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct OwnedPetRevisionScan {
    pub current_revision_id: Option<String>,
    pub revisions: Vec<OwnedPetRevision>,
    pub truncated: bool,
}

impl PetRevisionLayout {
    fn new(paths: &AppPaths, pet_id: &str, revision_id: String) -> Self {
        let pet_root = paths.pets_dir.join(pet_id);
        let revisions_root = pet_root.join("revisions");
        let revision_dir = revisions_root.join(&revision_id);
        Self {
            pet_id: pet_id.to_string(),
            revision_id,
            petpack_path: revision_dir.join(format!("{pet_id}.petpack")),
            cover_path: revision_dir.join(format!("{pet_id}-cover.png")),
            frames_dir: revision_dir.join(format!("{pet_id}-frames")),
            active_pointer_path: pet_root.join("active.json"),
            pet_root,
            revisions_root,
            revision_dir,
        }
    }
}

#[derive(Serialize)]
struct ActiveRevisionPointer<'a> {
    schema_version: &'static str,
    pet_id: &'a str,
    revision_id: &'a str,
    petpack_path: String,
    cover_path: String,
    updated_at: String,
}

/// Owns one not-yet-visible revision. Dropping an uncommitted transaction
/// removes only its staging/final revision and restores the prior pointer.
pub struct PetRevisionTransaction {
    stage_dir: PathBuf,
    stage_petpack_path: PathBuf,
    stage_cover_path: PathBuf,
    stage_frames_dir: PathBuf,
    layout: PetRevisionLayout,
    previous_pointer: Option<Vec<u8>>,
    published: bool,
    finalized: bool,
}

impl PetRevisionTransaction {
    pub fn stage(paths: &AppPaths, pet_id: &str) -> Result<Self> {
        let revision_id = new_id("rev");
        let layout = PetRevisionLayout::new(paths, pet_id, revision_id);
        fs::create_dir_all(&layout.revisions_root)?;
        let stage_dir = layout
            .revisions_root
            .join(format!(".staging-{}", new_id("revision")));
        fs::create_dir(&stage_dir)?;
        let previous_pointer = match fs::read(&layout.active_pointer_path) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.into()),
        };
        Ok(Self {
            stage_petpack_path: stage_dir.join(format!("{pet_id}.petpack")),
            stage_cover_path: stage_dir.join(format!("{pet_id}-cover.png")),
            stage_frames_dir: stage_dir.join(format!("{pet_id}-frames")),
            stage_dir,
            layout,
            previous_pointer,
            published: false,
            finalized: false,
        })
    }

    pub fn layout(&self) -> &PetRevisionLayout {
        &self.layout
    }

    pub fn stage_petpack_path(&self) -> &Path {
        &self.stage_petpack_path
    }

    pub fn stage_cover_path(&self) -> &Path {
        &self.stage_cover_path
    }

    pub fn stage_frames_dir(&self) -> &Path {
        &self.stage_frames_dir
    }

    /// Publishes the immutable directory and pointer, then commits the DB row.
    /// The old revision is never renamed or overwritten.
    pub fn commit(mut self, database: &Database, mut pet: PetSummary) -> Result<PetSummary> {
        sync_tree(&self.stage_dir)?;
        fs::rename(&self.stage_dir, &self.layout.revision_dir)?;
        sync_directory(&self.layout.revisions_root)?;
        self.published = true;

        let pointer = ActiveRevisionPointer {
            schema_version: ACTIVE_POINTER_SCHEMA_VERSION,
            pet_id: &self.layout.pet_id,
            revision_id: &self.layout.revision_id,
            petpack_path: self.layout.petpack_path.display().to_string(),
            cover_path: self.layout.cover_path.display().to_string(),
            updated_at: now_rfc3339(),
        };
        atomic_write(
            &self.layout.active_pointer_path,
            &serde_json::to_vec_pretty(&pointer)?,
        )?;

        match database.upsert_pet_and_activate_if_first(&pet) {
            Ok(active) => pet.active = active,
            Err(error) => {
                let rollback_error = self.rollback_internal().err();
                return match rollback_error {
                    Some(rollback_error) => Err(PetCoreError::Validation(format!(
                        "pet database commit failed ({error}); revision rollback also failed ({rollback_error})"
                    ))),
                    None => Err(error),
                };
            }
        }

        self.finalized = true;
        Ok(pet)
    }

    pub fn rollback(mut self) -> Result<()> {
        let result = self.rollback_internal();
        self.finalized = true;
        result
    }

    fn rollback_internal(&mut self) -> Result<()> {
        if self.published {
            restore_pointer(
                &self.layout.active_pointer_path,
                self.previous_pointer.as_deref(),
            )?;
            remove_if_exists(&self.layout.revision_dir)?;
            sync_directory(&self.layout.revisions_root)?;
            self.published = false;
        } else {
            remove_if_exists(&self.stage_dir)?;
        }
        Ok(())
    }
}

impl Drop for PetRevisionTransaction {
    fn drop(&mut self) {
        if !self.finalized {
            let _ = self.rollback_internal();
        }
    }
}

pub fn revision_pet_root(paths: &AppPaths, pet: &PetSummary) -> Result<Option<PathBuf>> {
    let expected_root = paths.pets_dir.join(&pet.id);
    if !expected_root.is_dir() {
        return Ok(None);
    }
    let canonical_root = fs::canonicalize(&expected_root)?;
    let petpack = match fs::canonicalize(&pet.petpack_path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if petpack.starts_with(canonical_root.join("revisions")) {
        Ok(Some(canonical_root))
    } else {
        Ok(None)
    }
}

/// Adds read-only revision metadata to database projections without changing
/// the schema or immutable revision publication protocol. The shared pet-store
/// lock keeps the current revision and sibling count from racing a publish or
/// rollback. Only direct, structurally owned revision directories are counted;
/// staging directories, symlinks, and unrelated files are ignored.
pub fn enrich_pet_revision_metadata(paths: &AppPaths, pets: &mut [PetSummary]) -> Result<()> {
    if pets.is_empty() {
        return Ok(());
    }

    let _guard = PetStoreGuard::acquire_shared(paths)?;
    for pet in pets {
        pet.revision_id = None;
        pet.revision_count = 0;

        let Some((revision_id, revisions_root)) = current_owned_revision(paths, pet)? else {
            continue;
        };
        pet.revision_id = Some(revision_id);
        pet.revision_count = scan_owned_revision_count(
            &revisions_root,
            &pet.id,
            MAX_REVISION_METADATA_DIRECTORY_ENTRIES,
        )?
        .unwrap_or(0);
    }
    Ok(())
}

/// Enumerates only direct, structurally owned immutable revisions while the
/// caller holds the shared pet-store lock. The scan and output are both
/// bounded so a locally modified directory cannot turn a library RPC into an
/// unbounded filesystem walk.
pub(crate) fn owned_pet_revisions_guarded(
    paths: &AppPaths,
    pet: &PetSummary,
    limit: usize,
    _guard: &PetStoreGuard,
) -> Result<OwnedPetRevisionScan> {
    let limit = limit.min(32);
    let Some((current_revision_id, revisions_root)) = current_owned_revision(paths, pet)? else {
        return Ok(OwnedPetRevisionScan {
            current_revision_id: None,
            revisions: Vec::new(),
            truncated: false,
        });
    };

    let canonical_revisions_root = fs::canonicalize(&revisions_root)?;
    let mut scanned_entries = 0usize;
    let mut truncated = false;
    let mut candidates = Vec::new();
    for entry in fs::read_dir(&revisions_root)? {
        scanned_entries += 1;
        if scanned_entries > MAX_REVISION_METADATA_DIRECTORY_ENTRIES {
            truncated = true;
            break;
        }
        let entry = entry?;
        let Some(revision_id) = entry.file_name().to_str().map(ToOwned::to_owned) else {
            continue;
        };
        if !is_revision_id(&revision_id) || !is_owned_revision_directory(&entry.path(), &pet.id)? {
            continue;
        }
        let canonical_revision = fs::canonicalize(entry.path())?;
        if canonical_revision.parent() != Some(canonical_revisions_root.as_path()) {
            continue;
        }
        let modified = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        let cover_path = owned_revision_cover_path(&canonical_revision, &pet.id)?;
        candidates.push((
            revision_id == current_revision_id,
            modified,
            OwnedPetRevision {
                petpack_path: canonical_revision.join(format!("{}.petpack", pet.id)),
                cover_path,
                current: revision_id == current_revision_id,
                revision_id,
            },
        ));
    }

    candidates.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.1.cmp(&left.1))
            .then_with(|| right.2.revision_id.cmp(&left.2.revision_id))
    });
    if candidates.len() > limit {
        truncated = true;
    }
    let revisions = candidates
        .into_iter()
        .take(limit)
        .map(|(_, _, revision)| revision)
        .collect();
    Ok(OwnedPetRevisionScan {
        current_revision_id: Some(current_revision_id),
        revisions,
        truncated,
    })
}

/// Resolves one caller-selected revision without accepting traversal,
/// symlinked roots, detached stores, or another pet's package.
pub(crate) fn owned_pet_revision_path_guarded(
    paths: &AppPaths,
    pet: &PetSummary,
    revision_id: &str,
    _guard: &PetStoreGuard,
) -> Result<Option<PathBuf>> {
    if !is_revision_id(revision_id) || !pet_root_is_directly_owned(paths, &pet.id)? {
        return Ok(None);
    }
    // A detached revision tree is not a selectable baseline. Requiring the
    // current database package to belong to this tree binds the lookup to the
    // installed logical pet rather than merely to a matching directory name.
    if current_owned_revision(paths, pet)?.is_none() {
        return Ok(None);
    }
    let revisions_root = paths.pets_dir.join(&pet.id).join("revisions");
    let revision_dir = revisions_root.join(revision_id);
    if !is_owned_revision_directory(&revision_dir, &pet.id)? {
        return Ok(None);
    }
    let canonical_root = fs::canonicalize(revisions_root)?;
    let canonical_revision = fs::canonicalize(revision_dir)?;
    if canonical_revision.parent() != Some(canonical_root.as_path()) {
        return Ok(None);
    }
    Ok(Some(canonical_revision.join(format!("{}.petpack", pet.id))))
}

fn owned_revision_cover_path(revision_dir: &Path, pet_id: &str) -> Result<Option<PathBuf>> {
    let cover = revision_dir.join(format!("{pet_id}-cover.png"));
    let metadata = match fs::symlink_metadata(&cover) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() {
        return Ok(None);
    }
    let canonical_cover = fs::canonicalize(cover)?;
    if canonical_cover.parent() != Some(revision_dir) {
        return Ok(None);
    }
    Ok(Some(canonical_cover))
}

fn current_owned_revision(paths: &AppPaths, pet: &PetSummary) -> Result<Option<(String, PathBuf)>> {
    if !pet_root_is_directly_owned(paths, &pet.id)? {
        return Ok(None);
    }
    let Some(revision_dir) = revision_directory(paths, pet)? else {
        return Ok(None);
    };
    let Some(revision_id) = revision_dir
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|id| is_revision_id(id))
    else {
        return Ok(None);
    };
    if !is_owned_revision_directory(&revision_dir, &pet.id)? {
        return Ok(None);
    }

    let current_petpack = fs::canonicalize(&pet.petpack_path)?;
    let expected_petpack = fs::canonicalize(revision_dir.join(format!("{}.petpack", pet.id)))?;
    if current_petpack != expected_petpack {
        return Ok(None);
    }

    let Some(revisions_root) = revision_dir.parent() else {
        return Ok(None);
    };
    Ok(Some((
        revision_id.to_string(),
        revisions_root.to_path_buf(),
    )))
}

fn pet_root_is_directly_owned(paths: &AppPaths, pet_id: &str) -> Result<bool> {
    let expected_root = paths.pets_dir.join(pet_id);
    let root_metadata = match fs::symlink_metadata(&expected_root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if !root_metadata.file_type().is_dir() {
        return Ok(false);
    }

    let canonical_pets_root = fs::canonicalize(&paths.pets_dir)?;
    let canonical_pet_root = fs::canonicalize(expected_root)?;
    Ok(canonical_pet_root.parent() == Some(canonical_pets_root.as_path()))
}

fn scan_owned_revision_count(
    revisions_root: &Path,
    pet_id: &str,
    maximum_entries: usize,
) -> Result<Option<u32>> {
    let mut scanned_entries = 0usize;
    let mut revision_count = 0u32;
    for entry in fs::read_dir(revisions_root)? {
        scanned_entries += 1;
        if scanned_entries > maximum_entries {
            // Revision metadata is informational. If an externally modified
            // directory exceeds the bound, keep the verified current ID but
            // report the count as unavailable (zero) rather than block RPC.
            return Ok(None);
        }
        let entry = entry?;
        let revision_id_is_valid = entry.file_name().to_str().is_some_and(is_revision_id);
        if revision_id_is_valid && is_owned_revision_directory(&entry.path(), pet_id)? {
            revision_count = revision_count.checked_add(1).ok_or_else(|| {
                PetCoreError::Validation("pet revision count overflow".to_string())
            })?;
        }
    }
    Ok(Some(revision_count))
}

fn is_owned_revision_directory(revision_dir: &Path, pet_id: &str) -> Result<bool> {
    let directory_metadata = match fs::symlink_metadata(revision_dir) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if !directory_metadata.file_type().is_dir() {
        return Ok(false);
    }

    let petpack_path = revision_dir.join(format!("{pet_id}.petpack"));
    let petpack_metadata = match fs::symlink_metadata(&petpack_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if !petpack_metadata.file_type().is_file() {
        return Ok(false);
    }

    let canonical_revision = fs::canonicalize(revision_dir)?;
    let canonical_petpack = fs::canonicalize(petpack_path)?;
    Ok(canonical_petpack.parent() == Some(canonical_revision.as_path()))
}

fn is_revision_id(candidate: &str) -> bool {
    candidate.strip_prefix("rev_").is_some_and(|suffix| {
        suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}

/// Reverts a generation import only when the database still points at that
/// exact revision. This prevents a late cancellation from undoing a newer
/// manual import of the same pet id.
pub fn rollback_imported_revision(
    paths: &AppPaths,
    database: &Database,
    current: &PetSummary,
    previous: Option<&PetSummary>,
) -> Result<bool> {
    let _guard = PetStoreGuard::acquire(paths)?;
    let Some(stored) = database.get_pet(&current.id)? else {
        return Ok(false);
    };
    if stored.petpack_path != current.petpack_path {
        return Ok(false);
    }

    let current_root = revision_pet_root(paths, current)?.ok_or_else(|| {
        PetCoreError::Validation(
            "generation import does not point at an owned immutable revision".to_string(),
        )
    })?;
    let current_revision = revision_directory(paths, current)?.ok_or_else(|| {
        PetCoreError::Validation("generation import revision directory is invalid".to_string())
    })?;

    if let Some(previous) = previous {
        if previous.id != current.id {
            return Err(PetCoreError::Validation(
                "cannot restore a revision from a different pet".to_string(),
            ));
        }
        database.upsert_pet(previous)?;
        if let Some(previous_revision) = revision_directory(paths, previous)? {
            write_pointer_for_revision(paths, previous, &previous_revision)?;
        } else {
            restore_pointer(&current_root.join("active.json"), None)?;
        }
        remove_if_exists(&current_revision)?;
        if let Some(revisions_root) = current_revision.parent() {
            sync_directory(revisions_root)?;
        }
    } else {
        database.delete_pet(&current.id)?;
        remove_if_exists(&current_root)?;
        sync_directory(&paths.pets_dir)?;
    }
    Ok(true)
}

fn revision_directory(paths: &AppPaths, pet: &PetSummary) -> Result<Option<PathBuf>> {
    let Some(root) = revision_pet_root(paths, pet)? else {
        return Ok(None);
    };
    let canonical_petpack = fs::canonicalize(&pet.petpack_path)?;
    let Some(parent) = canonical_petpack.parent() else {
        return Ok(None);
    };
    let revisions_root = root.join("revisions");
    if parent.parent() == Some(revisions_root.as_path()) {
        Ok(Some(parent.to_path_buf()))
    } else {
        Ok(None)
    }
}

fn write_pointer_for_revision(
    paths: &AppPaths,
    pet: &PetSummary,
    revision_dir: &Path,
) -> Result<()> {
    let revision_id = revision_dir
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| PetCoreError::Validation("revision id is not valid UTF-8".to_string()))?;
    let root = paths.pets_dir.join(&pet.id);
    let pointer = ActiveRevisionPointer {
        schema_version: ACTIVE_POINTER_SCHEMA_VERSION,
        pet_id: &pet.id,
        revision_id,
        petpack_path: pet.petpack_path.clone(),
        cover_path: pet.cover_path.clone(),
        updated_at: now_rfc3339(),
    };
    atomic_write(
        &root.join("active.json"),
        &serde_json::to_vec_pretty(&pointer)?,
    )
}

fn restore_pointer(path: &Path, previous: Option<&[u8]>) -> Result<()> {
    if let Some(previous) = previous {
        atomic_write(path, previous)
    } else {
        match fs::remove_file(path) {
            Ok(()) => {
                if let Some(parent) = path.parent() {
                    sync_directory(parent)?;
                }
                Ok(())
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        PetCoreError::InvalidRequest(format!("path has no parent: {}", path.display()))
    })?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".active-{}.tmp", new_id("pointer")));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(bytes)?;
        if !bytes.ends_with(b"\n") {
            file.write_all(b"\n")?;
        }
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        sync_directory(parent)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn sync_tree(root: &Path) -> Result<()> {
    for entry in fs::read_dir(root)? {
        let path = entry?.path();
        if path.is_dir() {
            sync_tree(&path)?;
        } else {
            File::open(&path)?.sync_all()?;
        }
    }
    sync_directory(root)
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

fn remove_if_exists(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => Ok(fs::remove_dir_all(path)?),
        Ok(_) => Ok(fs::remove_file(path)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PET_ID: &str = "pet_revisionmetadata";
    const REVISION_ONE: &str = "rev_00000000000000000000000000000001";
    const REVISION_TWO: &str = "rev_00000000000000000000000000000002";

    #[test]
    fn revision_count_scan_is_bounded_without_returning_a_partial_count() {
        let temp = tempfile::tempdir().unwrap();
        let revisions_root = temp.path().join("revisions");
        write_owned_revision(&revisions_root, REVISION_ONE);
        write_owned_revision(&revisions_root, REVISION_TWO);

        assert_eq!(
            scan_owned_revision_count(&revisions_root, PET_ID, 2).unwrap(),
            Some(2)
        );
        assert_eq!(
            scan_owned_revision_count(&revisions_root, PET_ID, 1).unwrap(),
            None
        );
    }

    #[test]
    fn revision_count_ignores_staging_directories_and_symlinked_packages() {
        let temp = tempfile::tempdir().unwrap();
        let revisions_root = temp.path().join("revisions");
        write_owned_revision(&revisions_root, REVISION_ONE);

        let staging = revisions_root.join(".staging-revision_pending");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join(format!("{PET_ID}.petpack")), b"staging").unwrap();

        let symlinked_revision = revisions_root.join(REVISION_TWO);
        fs::create_dir_all(&symlinked_revision).unwrap();
        let outside = temp.path().join("outside.petpack");
        fs::write(&outside, b"outside").unwrap();
        std::os::unix::fs::symlink(
            &outside,
            symlinked_revision.join(format!("{PET_ID}.petpack")),
        )
        .unwrap();

        assert_eq!(
            scan_owned_revision_count(&revisions_root, PET_ID, 8).unwrap(),
            Some(1)
        );
    }

    #[test]
    fn symlinked_pet_root_is_not_owned_revision_storage() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        paths.ensure().unwrap();
        let outside = temp.path().join("outside-pet-root");
        fs::create_dir_all(outside.join("revisions")).unwrap();
        std::os::unix::fs::symlink(&outside, paths.pets_dir.join(PET_ID)).unwrap();

        assert!(!pet_root_is_directly_owned(&paths, PET_ID).unwrap());
    }

    #[test]
    fn owned_revision_history_keeps_current_first_and_resolves_only_safe_ids() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        paths.ensure().unwrap();
        let revisions_root = paths.pets_dir.join(PET_ID).join("revisions");
        write_owned_revision(&revisions_root, REVISION_ONE);
        write_owned_revision(&revisions_root, REVISION_TWO);
        fs::write(
            revisions_root
                .join(REVISION_ONE)
                .join(format!("{PET_ID}-cover.png")),
            b"cover",
        )
        .unwrap();
        let pet = PetSummary {
            id: PET_ID.to_string(),
            name: "Revision history fixture".to_string(),
            style: "test".to_string(),
            quality: petcore_types::QualityLevel::Standard,
            render_size: petcore_types::RenderSize {
                width: 384,
                height: 416,
            },
            native_fps: petcore_types::DEFAULT_NATIVE_FPS,
            state_durations_ms: petcore_types::default_state_durations_ms(),
            petpack_path: revisions_root
                .join(REVISION_ONE)
                .join(format!("{PET_ID}.petpack"))
                .display()
                .to_string(),
            cover_path: String::new(),
            origin: petcore_types::PetOrigin::ExternalImport,
            generator: None,
            provenance: None,
            revision_id: None,
            revision_count: 0,
            active: true,
            created_at: "2026-07-21T00:00:00Z".to_string(),
        };
        let guard = PetStoreGuard::acquire_shared(&paths).unwrap();

        let scan = owned_pet_revisions_guarded(&paths, &pet, 1, &guard).unwrap();
        assert_eq!(scan.current_revision_id.as_deref(), Some(REVISION_ONE));
        assert_eq!(scan.revisions.len(), 1);
        assert_eq!(scan.revisions[0].revision_id, REVISION_ONE);
        assert!(scan.revisions[0].current);
        assert!(scan.revisions[0].cover_path.is_some());
        assert!(scan.truncated);

        assert!(
            owned_pet_revision_path_guarded(&paths, &pet, REVISION_TWO, &guard)
                .unwrap()
                .is_some()
        );
        assert!(
            owned_pet_revision_path_guarded(&paths, &pet, "../escape", &guard)
                .unwrap()
                .is_none()
        );
    }

    fn write_owned_revision(revisions_root: &Path, revision_id: &str) {
        let revision = revisions_root.join(revision_id);
        fs::create_dir_all(&revision).unwrap();
        fs::write(revision.join(format!("{PET_ID}.petpack")), b"petpack").unwrap();
    }
}
