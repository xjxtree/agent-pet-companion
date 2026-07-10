use crate::db::Database;
use crate::paths::AppPaths;
use crate::{new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::PetSummary;
use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

const ACTIVE_POINTER_SCHEMA_VERSION: &str = "apc.pet-active-revision.v1";

/// Serializes pet-library mutations across daemon requests and explicit offline
/// maintenance processes. The lock is intentionally separate from the daemon
/// singleton lock: reads remain available while a revision is being prepared.
pub struct PetStoreGuard {
    file: File,
}

impl PetStoreGuard {
    pub fn acquire(paths: &AppPaths) -> Result<Self> {
        fs::create_dir_all(&paths.pets_dir)?;
        let lock_path = paths.pets_dir.join(".pet-store.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&lock_path)?;
        rustix::fs::flock(&file, rustix::fs::FlockOperation::LockExclusive)
            .map_err(std::io::Error::from)?;
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
