use crate::paths::AppPaths;
use crate::{PetCoreError, Result};
use rusqlite::backup::Backup;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

const CHECKPOINT_SCHEMA_VERSION: &str = "apc.runtime-rollback-checkpoint.v1";
const CHECKPOINT_DIRECTORY_NAME: &str = "rollback-checkpoint";
const CHECKPOINT_DATABASE_NAME: &str = "agent-pet.sqlite";
const CHECKPOINT_STATE_NAME: &str = "state.json";
const MAX_CHECKPOINT_STATE_BYTES: u64 = 4 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RollbackCheckpointPhase {
    Creating,
    Ready,
    Restored,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RollbackCheckpointState {
    schema_version: String,
    phase: RollbackCheckpointPhase,
    source_build_id: String,
    candidate_build_id: String,
    database_was_present: bool,
    database_sha256: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RollbackCheckpointStatus {
    schema_version: &'static str,
    present: bool,
    phase: Option<RollbackCheckpointPhase>,
    source_build_id: Option<String>,
    candidate_build_id: Option<String>,
}

pub fn create(paths: &AppPaths, source_build_id: &str, candidate_build_id: &str) -> Result<()> {
    validate_build_id(source_build_id)?;
    validate_build_id(candidate_build_id)?;
    if source_build_id == candidate_build_id {
        return Err(PetCoreError::Validation(
            "rollback checkpoint source and candidate builds must differ".to_string(),
        ));
    }

    let directory = checkpoint_directory(paths);
    ensure_private_directory(&directory)?;
    remove_recognized_temporary_state_files(&directory)?;
    reject_non_regular_checkpoint_entries(&directory)?;
    reject_unrecognized_checkpoint_entries(&directory)?;

    if checkpoint_state_path(paths).is_file() {
        let mut existing = read_checkpoint_state(paths)?;
        match existing.phase {
            RollbackCheckpointPhase::Creating => {
                discard(paths)?;
                ensure_private_directory(&directory)?;
            }
            RollbackCheckpointPhase::Ready if existing.source_build_id == source_build_id => {
                restore(paths)?;
                existing.candidate_build_id = candidate_build_id.to_string();
                existing.phase = RollbackCheckpointPhase::Ready;
                write_checkpoint_state(paths, &existing)?;
                return Ok(());
            }
            RollbackCheckpointPhase::Ready if existing.candidate_build_id == source_build_id => {
                discard(paths)?;
                ensure_private_directory(&directory)?;
            }
            RollbackCheckpointPhase::Restored if existing.source_build_id == source_build_id => {
                // The previous runtime may have accepted new writes after the
                // restore. The old checkpoint is now obsolete and must never
                // be replayed over that legitimate post-rollback state.
                discard(paths)?;
                ensure_private_directory(&directory)?;
            }
            RollbackCheckpointPhase::Restored => {
                return Err(PetCoreError::Validation(format!(
                    "restored rollback checkpoint source {} does not match requested source {}",
                    existing.source_build_id, source_build_id
                )));
            }
            RollbackCheckpointPhase::Ready => {
                return Err(PetCoreError::Validation(format!(
                    "existing rollback checkpoint {} -> {} does not match requested {} -> {}",
                    existing.source_build_id,
                    existing.candidate_build_id,
                    source_build_id,
                    candidate_build_id
                )));
            }
        }
    } else {
        // Without a committed state record the prior create command could not
        // have returned success, so the App could not have launched a
        // candidate. Any known database sidecars are an incomplete snapshot,
        // not rollback authority.
        for path in checkpoint_entry_paths(paths) {
            remove_regular_file_if_present(&path)?;
        }
    }

    let database_was_present = paths.db_path.is_file();
    write_checkpoint_state(
        paths,
        &RollbackCheckpointState {
            schema_version: CHECKPOINT_SCHEMA_VERSION.to_string(),
            phase: RollbackCheckpointPhase::Creating,
            source_build_id: source_build_id.to_string(),
            candidate_build_id: candidate_build_id.to_string(),
            database_was_present,
            database_sha256: None,
        },
    )?;
    let database_sha256 = if database_was_present {
        let source = Connection::open_with_flags(
            &paths.db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        let quick_check: String = source.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if !quick_check.eq_ignore_ascii_case("ok") {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint rejected source database integrity result: {quick_check}"
            )));
        }

        let checkpoint_path = checkpoint_database_path(paths);
        let mut destination = Connection::open(&checkpoint_path)?;
        {
            let backup = Backup::new(&source, &mut destination)?;
            backup.run_to_completion(64, Duration::from_millis(5), None)?;
        }
        let journal_mode: String =
            destination.query_row("PRAGMA journal_mode = DELETE", [], |row| row.get(0))?;
        if !journal_mode.eq_ignore_ascii_case("delete") {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint could not enter self-contained journal mode: {journal_mode}"
            )));
        }
        let copied_quick_check: String =
            destination.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if !copied_quick_check.eq_ignore_ascii_case("ok") {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint copy failed integrity validation: {copied_quick_check}"
            )));
        }
        drop(destination);
        drop(source);
        fs::set_permissions(&checkpoint_path, fs::Permissions::from_mode(0o600))?;
        Some(sha256_file(&checkpoint_path)?)
    } else {
        None
    };

    let state = RollbackCheckpointState {
        schema_version: CHECKPOINT_SCHEMA_VERSION.to_string(),
        phase: RollbackCheckpointPhase::Ready,
        source_build_id: source_build_id.to_string(),
        candidate_build_id: candidate_build_id.to_string(),
        database_was_present,
        database_sha256,
    };
    write_checkpoint_state(paths, &state)
}

pub fn restore(paths: &AppPaths) -> Result<()> {
    let mut state = read_checkpoint_state(paths)?;
    match state.phase {
        RollbackCheckpointPhase::Restored => return Ok(()),
        RollbackCheckpointPhase::Ready => {}
        RollbackCheckpointPhase::Creating => {
            return Err(PetCoreError::Validation(
                "rollback checkpoint is not ready".to_string(),
            ));
        }
    }
    if !state.database_was_present {
        remove_live_database_files(paths)?;
        state.phase = RollbackCheckpointPhase::Restored;
        write_checkpoint_state(paths, &state)?;
        return Ok(());
    }

    let expected_sha256 = state.database_sha256.as_deref().ok_or_else(|| {
        PetCoreError::Validation(
            "rollback checkpoint state is missing its database digest".to_string(),
        )
    })?;
    let checkpoint_path = checkpoint_database_path(paths);
    if sha256_file(&checkpoint_path)? != expected_sha256 {
        return Err(PetCoreError::Validation(
            "rollback checkpoint database digest mismatch".to_string(),
        ));
    }

    let source = Connection::open_with_flags(
        &checkpoint_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let source_quick_check: String =
        source.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if !source_quick_check.eq_ignore_ascii_case("ok") {
        return Err(PetCoreError::Validation(format!(
            "rollback checkpoint failed integrity validation: {source_quick_check}"
        )));
    }

    if let Some(parent) = paths.db_path.parent() {
        ensure_private_directory(parent)?;
    }
    let mut destination = Connection::open(&paths.db_path)?;
    destination.busy_timeout(Duration::from_secs(1))?;
    {
        let backup = Backup::new(&source, &mut destination)?;
        backup.run_to_completion(64, Duration::from_millis(5), None)?;
    }
    let restored_quick_check: String =
        destination.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if !restored_quick_check.eq_ignore_ascii_case("ok") {
        return Err(PetCoreError::Validation(format!(
            "restored rollback database failed integrity validation: {restored_quick_check}"
        )));
    }
    destination.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    drop(destination);
    drop(source);
    fs::set_permissions(&paths.db_path, fs::Permissions::from_mode(0o600))?;
    state.phase = RollbackCheckpointPhase::Restored;
    write_checkpoint_state(paths, &state)?;
    Ok(())
}

pub fn discard(paths: &AppPaths) -> Result<()> {
    let directory = checkpoint_directory(paths);
    if !directory.exists() {
        return Ok(());
    }
    remove_recognized_temporary_state_files(&directory)?;
    reject_non_regular_checkpoint_entries(&directory)?;
    reject_unrecognized_checkpoint_entries(&directory)?;
    for path in checkpoint_entry_paths(paths) {
        remove_regular_file_if_present(&path)?;
    }
    match fs::remove_dir(&directory) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

pub fn status(paths: &AppPaths) -> Result<RollbackCheckpointStatus> {
    let directory = checkpoint_directory(paths);
    if !directory.exists() {
        return Ok(absent_status());
    }
    let metadata = fs::symlink_metadata(&directory)?;
    if !metadata.file_type().is_dir() {
        return Err(PetCoreError::Validation(
            "rollback checkpoint path is not a directory".to_string(),
        ));
    }
    reject_non_regular_checkpoint_entries(&directory)?;
    reject_unrecognized_checkpoint_entries_allowing_state_temporary(&directory)?;
    if !checkpoint_state_path(paths).is_file() {
        let has_entries = fs::read_dir(&directory)?.next().transpose()?.is_some();
        if has_entries {
            return Err(PetCoreError::Validation(
                "rollback checkpoint is incomplete".to_string(),
            ));
        }
        return Ok(absent_status());
    }
    let state = read_checkpoint_state(paths)?;
    Ok(RollbackCheckpointStatus {
        schema_version: CHECKPOINT_SCHEMA_VERSION,
        present: true,
        phase: Some(state.phase),
        source_build_id: Some(state.source_build_id),
        candidate_build_id: Some(state.candidate_build_id),
    })
}

fn absent_status() -> RollbackCheckpointStatus {
    RollbackCheckpointStatus {
        schema_version: CHECKPOINT_SCHEMA_VERSION,
        present: false,
        phase: None,
        source_build_id: None,
        candidate_build_id: None,
    }
}

fn read_checkpoint_state(paths: &AppPaths) -> Result<RollbackCheckpointState> {
    let path = checkpoint_state_path(paths);
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.file_type().is_file() || metadata.len() > MAX_CHECKPOINT_STATE_BYTES {
        return Err(PetCoreError::Validation(
            "rollback checkpoint state must be one bounded regular file".to_string(),
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    File::open(&path)?
        .take(MAX_CHECKPOINT_STATE_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_CHECKPOINT_STATE_BYTES {
        return Err(PetCoreError::Validation(
            "rollback checkpoint state exceeds its size limit".to_string(),
        ));
    }
    let state: RollbackCheckpointState = serde_json::from_slice(&bytes)?;
    if state.schema_version != CHECKPOINT_SCHEMA_VERSION
        || validate_build_id(&state.source_build_id).is_err()
        || validate_build_id(&state.candidate_build_id).is_err()
        || state.source_build_id == state.candidate_build_id
        || (matches!(
            state.phase,
            RollbackCheckpointPhase::Ready | RollbackCheckpointPhase::Restored
        ) && state.database_was_present != state.database_sha256.is_some())
        || (state.phase == RollbackCheckpointPhase::Creating && state.database_sha256.is_some())
        || state
            .database_sha256
            .as_deref()
            .is_some_and(|digest| !is_lower_hex_sha256(digest))
    {
        return Err(PetCoreError::Validation(
            "rollback checkpoint state contract is invalid".to_string(),
        ));
    }
    Ok(state)
}

fn checkpoint_directory(paths: &AppPaths) -> PathBuf {
    paths.home.join("runtime").join(CHECKPOINT_DIRECTORY_NAME)
}

fn checkpoint_database_path(paths: &AppPaths) -> PathBuf {
    checkpoint_directory(paths).join(CHECKPOINT_DATABASE_NAME)
}

fn checkpoint_state_path(paths: &AppPaths) -> PathBuf {
    checkpoint_directory(paths).join(CHECKPOINT_STATE_NAME)
}

fn checkpoint_entry_paths(paths: &AppPaths) -> [PathBuf; 5] {
    let database = checkpoint_database_path(paths);
    [
        database.clone(),
        PathBuf::from(format!("{}-wal", database.display())),
        PathBuf::from(format!("{}-shm", database.display())),
        PathBuf::from(format!("{}-journal", database.display())),
        checkpoint_state_path(paths),
    ]
}

fn ensure_private_directory(path: &Path) -> Result<()> {
    if path.exists() {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_dir() {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint path is not a directory: {}",
                path.display()
            )));
        }
    } else {
        let mut builder = DirBuilder::new();
        builder.recursive(true).mode(0o700);
        builder.create(path)?;
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn reject_non_regular_checkpoint_entries(directory: &Path) -> Result<()> {
    let database = directory.join(CHECKPOINT_DATABASE_NAME);
    for path in [
        database.clone(),
        PathBuf::from(format!("{}-wal", database.display())),
        PathBuf::from(format!("{}-shm", database.display())),
        PathBuf::from(format!("{}-journal", database.display())),
        directory.join(CHECKPOINT_STATE_NAME),
    ] {
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => {}
            Ok(_) => {
                return Err(PetCoreError::Validation(format!(
                    "rollback checkpoint entry is not a regular file: {}",
                    path.display()
                )));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn remove_recognized_temporary_state_files(directory: &Path) -> Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(suffix) = name.strip_prefix(".state-") else {
            continue;
        };
        if suffix.len() != 32
            || !suffix
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path())?;
        if !metadata.file_type().is_file() {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint temporary state is not a regular file: {}",
                entry.path().display()
            )));
        }
        fs::remove_file(entry.path())?;
    }
    Ok(())
}

fn reject_unrecognized_checkpoint_entries(directory: &Path) -> Result<()> {
    let recognized = [
        CHECKPOINT_DATABASE_NAME.to_string(),
        format!("{CHECKPOINT_DATABASE_NAME}-wal"),
        format!("{CHECKPOINT_DATABASE_NAME}-shm"),
        format!("{CHECKPOINT_DATABASE_NAME}-journal"),
        CHECKPOINT_STATE_NAME.to_string(),
    ];
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let Some(name) = entry.file_name().to_str().map(ToOwned::to_owned) else {
            return Err(PetCoreError::Validation(
                "rollback checkpoint directory contains a non-UTF-8 entry".to_string(),
            ));
        };
        if !recognized.contains(&name) {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint directory contains an unrecognized entry: {name}"
            )));
        }
    }
    Ok(())
}

fn reject_unrecognized_checkpoint_entries_allowing_state_temporary(directory: &Path) -> Result<()> {
    let recognized = [
        CHECKPOINT_DATABASE_NAME.to_string(),
        format!("{CHECKPOINT_DATABASE_NAME}-wal"),
        format!("{CHECKPOINT_DATABASE_NAME}-shm"),
        format!("{CHECKPOINT_DATABASE_NAME}-journal"),
        CHECKPOINT_STATE_NAME.to_string(),
    ];
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let Some(name) = entry.file_name().to_str().map(ToOwned::to_owned) else {
            return Err(PetCoreError::Validation(
                "rollback checkpoint directory contains a non-UTF-8 entry".to_string(),
            ));
        };
        let state_temporary = name.strip_prefix(".state-").is_some_and(|suffix| {
            suffix.len() == 32
                && suffix
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        });
        if !recognized.contains(&name) && !state_temporary {
            return Err(PetCoreError::Validation(format!(
                "rollback checkpoint directory contains an unrecognized entry: {name}"
            )));
        }
    }
    Ok(())
}

fn remove_regular_file_if_present(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => {
            fs::remove_file(path)?;
            Ok(())
        }
        Ok(_) => Err(PetCoreError::Validation(format!(
            "refusing to remove non-regular rollback checkpoint entry: {}",
            path.display()
        ))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn remove_live_database_files(paths: &AppPaths) -> Result<()> {
    for path in [
        paths.db_path.clone(),
        PathBuf::from(format!("{}-wal", paths.db_path.display())),
        PathBuf::from(format!("{}-shm", paths.db_path.display())),
    ] {
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => fs::remove_file(path)?,
            Ok(_) => {
                return Err(PetCoreError::Validation(format!(
                    "refusing to remove non-regular live database entry: {}",
                    path.display()
                )));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn atomic_write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        PetCoreError::InvalidRequest("rollback checkpoint state has no parent".to_string())
    })?;
    let temporary = parent.join(format!(".state-{}", uuid::Uuid::now_v7().simple()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn write_checkpoint_state(paths: &AppPaths, state: &RollbackCheckpointState) -> Result<()> {
    atomic_write_private(
        &checkpoint_state_path(paths),
        &serde_json::to_vec_pretty(state)?,
    )
}

fn validate_build_id(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
    {
        return Err(PetCoreError::Validation(
            "rollback checkpoint build ID is invalid".to_string(),
        ));
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(PetCoreError::Validation(
            "rollback checkpoint database must be a regular file".to_string(),
        ));
    }
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn is_lower_hex_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;
    use rusqlite::params;

    #[test]
    fn failed_v2_candidate_can_restore_exact_v1_overlay_and_pet_rows() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        paths.ensure().unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE pets (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  style TEXT NOT NULL,
                  quality TEXT NOT NULL,
                  render_width INTEGER NOT NULL,
                  render_height INTEGER NOT NULL,
                  native_fps INTEGER NOT NULL DEFAULT 10,
                  state_durations_json TEXT NOT NULL,
                  petpack_path TEXT NOT NULL,
                  cover_path TEXT NOT NULL,
                  active INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL
                );
                CREATE TABLE settings (
                  key TEXT PRIMARY KEY,
                  value_json TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  revision INTEGER NOT NULL DEFAULT 0
                );
                PRAGMA user_version = 6;
                "#,
            )
            .unwrap();
        let legacy_timing = r#"{"idle":1000,"start":2000,"tool":1000,"waiting":2000,"review":1000,"done":2000,"failed":1000}"#;
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  native_fps, state_durations_json, petpack_path, cover_path,
                  active, created_at
                )
                VALUES (
                  'pet_v1', 'V1 Pet', 'legacy', 'standard', 192, 208,
                  20, ?1, '/owned/v1.petpack', '/owned/v1-cover.png',
                  1, '2026-07-01T00:00:00Z'
                )
                "#,
                params![legacy_timing],
            )
            .unwrap();
        let legacy_overlay = r#"{"x":123.5,"y":456.25,"scale":0.72,"display_id":"legacy-display"}"#;
        connection
            .execute(
                r#"
                INSERT INTO settings (key, value_json, updated_at, revision)
                VALUES ('overlay_placement', ?1, '2026-07-01T00:00:00Z', 7)
                "#,
                params![legacy_overlay],
            )
            .unwrap();
        drop(connection);

        create(&paths, "released-v1", "candidate-v2").unwrap();
        Database::new(&paths.db_path).init().unwrap();
        let mutated = Connection::open(&paths.db_path).unwrap();
        assert_eq!(
            mutated
                .query_row("SELECT COUNT(*) FROM pets", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        let current_overlay: String = mutated
            .query_row(
                "SELECT value_json FROM settings WHERE key = 'overlay_placement'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(current_overlay.contains("display_width_pt"));
        drop(mutated);

        restore(&paths).unwrap();
        let restored = Connection::open(&paths.db_path).unwrap();
        assert_eq!(
            restored
                .query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))
                .unwrap(),
            6
        );
        assert_eq!(
            restored
                .query_row("SELECT COUNT(*) FROM pets WHERE id = 'pet_v1'", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            1
        );
        assert_eq!(
            restored
                .query_row(
                    "SELECT native_fps FROM pets WHERE id = 'pet_v1'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            20
        );
        assert_eq!(
            restored
                .query_row(
                    "SELECT state_durations_json FROM pets WHERE id = 'pet_v1'",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .unwrap(),
            legacy_timing
        );
        assert_eq!(
            restored
                .query_row(
                    "SELECT value_json FROM settings WHERE key = 'overlay_placement'",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .unwrap(),
            legacy_overlay
        );
        drop(restored);
        discard(&paths).unwrap();
        assert!(!checkpoint_directory(&paths).exists());
    }

    #[test]
    fn absent_database_checkpoint_removes_candidate_created_database() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        paths.ensure().unwrap();
        create(&paths, "released-v1", "candidate-v2").unwrap();
        Database::new(&paths.db_path).init().unwrap();
        assert!(paths.db_path.exists());

        restore(&paths).unwrap();
        assert!(!paths.db_path.exists());
    }

    #[test]
    fn create_recovers_interrupted_candidates_without_overwriting_rollback_authority() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        paths.ensure().unwrap();
        Database::new(&paths.db_path).init().unwrap();

        create(&paths, "released-v1", "candidate-v2-a").unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch("CREATE TABLE uncommitted_a (id INTEGER PRIMARY KEY);")
            .unwrap();
        drop(connection);

        // A restarted App with the same source build must restore and reuse the
        // first snapshot, never back up the already-mutated candidate state.
        create(&paths, "released-v1", "candidate-v2-b").unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name = 'uncommitted_a'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        drop(connection);
        let state = read_checkpoint_state(&paths).unwrap();
        assert_eq!(state.source_build_id, "released-v1");
        assert_eq!(state.candidate_build_id, "candidate-v2-b");

        // If the recorded candidate became the current source, its successful
        // commit is authoritative. A later upgrade replaces the stale
        // checkpoint with a snapshot of that committed database.
        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch("CREATE TABLE committed_b (id INTEGER PRIMARY KEY);")
            .unwrap();
        drop(connection);
        create(&paths, "candidate-v2-b", "candidate-v2-c").unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch("CREATE TABLE uncommitted_c (id INTEGER PRIMARY KEY);")
            .unwrap();
        drop(connection);
        restore(&paths).unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name = 'committed_b'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name = 'uncommitted_c'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
    }

    #[test]
    fn restored_checkpoint_never_overwrites_post_rollback_writes() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        paths.ensure().unwrap();
        Database::new(&paths.db_path).init().unwrap();

        create(&paths, "released-v1", "candidate-v2-a").unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch("CREATE TABLE failed_candidate_write (id INTEGER PRIMARY KEY);")
            .unwrap();
        drop(connection);
        restore(&paths).unwrap();
        assert_eq!(
            read_checkpoint_state(&paths).unwrap().phase,
            RollbackCheckpointPhase::Restored
        );

        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch("CREATE TABLE post_rollback_write (id INTEGER PRIMARY KEY);")
            .unwrap();
        drop(connection);

        // Simulate cleanup failure plus an App crash. A later upgrade must
        // snapshot the current post-rollback database rather than replay the
        // obsolete original checkpoint.
        create(&paths, "released-v1", "candidate-v2-b").unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        connection
            .execute_batch("CREATE TABLE failed_candidate_b (id INTEGER PRIMARY KEY);")
            .unwrap();
        drop(connection);
        restore(&paths).unwrap();
        let connection = Connection::open(&paths.db_path).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name = 'post_rollback_write'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name = 'failed_candidate_b'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
    }
}
