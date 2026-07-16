use petcore::db::Database;
use petcore::paths::AppPaths;
use petcore::pet_revision::rollback_imported_revision;
use petcore::petpack::{
    ensure_runtime_assets, import_petpack, import_petpack_expecting_absent,
    write_sample_petpack_dir,
};
use petcore_types::{PetManifest, PetOrigin, QualityLevel, REQUIRED_STATES};
use sha2::{Digest, Sha256};
use std::fs;

const RUNTIME_ASSETS_MARKER: &str = ".apc-runtime-assets.json";

fn ready_state(home: &std::path::Path) -> (AppPaths, Database) {
    let paths = AppPaths::new(home.to_path_buf());
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    (paths, database)
}

fn read_manifest(source: &std::path::Path) -> PetManifest {
    serde_json::from_slice(&fs::read(source.join("manifest.json")).unwrap()).unwrap()
}

fn write_manifest(source: &std::path::Path, manifest: &PetManifest) {
    fs::write(
        source.join("manifest.json"),
        serde_json::to_vec_pretty(manifest).unwrap(),
    )
    .unwrap();
}

/// Renames a strict producer fixture without bypassing the cross-metadata
/// consistency gate exercised by imports.  A real producer must publish the
/// same user-facing identity in the manifest, brief, and source provenance.
fn rename_petpack_source(source: &std::path::Path, name: &str) {
    let mut manifest = read_manifest(source);
    manifest.name = name.to_string();
    write_manifest(source, &manifest);

    let brief_path = source.join("brief.json");
    let mut brief: serde_json::Value =
        serde_json::from_slice(&fs::read(&brief_path).unwrap()).unwrap();
    brief["name"] = serde_json::Value::String(name.to_string());
    fs::write(&brief_path, serde_json::to_vec_pretty(&brief).unwrap()).unwrap();

    let source_path = source.join("source/source.json");
    let mut source_metadata: serde_json::Value =
        serde_json::from_slice(&fs::read(&source_path).unwrap()).unwrap();
    source_metadata["pet_name"] = serde_json::Value::String(name.to_string());
    fs::write(
        &source_path,
        serde_json::to_vec_pretty(&source_metadata).unwrap(),
    )
    .unwrap();
}

#[test]
fn petpack_import_atomic_rejects_unsafe_manifest_id_without_writing_assets() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("unsafe-id-source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Unsafe Pet", "半写实", 2).unwrap();

    let mut manifest = read_manifest(&source);
    manifest.id = "../escape".to_string();
    write_manifest(&source, &manifest);

    let error = import_petpack(&paths, &database, &source)
        .unwrap_err()
        .to_string();
    assert!(error.contains("safe file name"));
    assert!(database.list_pets().unwrap().is_empty());
    assert!(!paths.home.join("escape.petpack").exists());
    assert!(!paths.pets_dir.join("../escape.petpack").exists());
}

#[test]
fn petpack_import_rejects_cross_metadata_name_mismatch_without_publishing_revision() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("mismatched-name-source");
    write_sample_petpack_dir(
        &source,
        QualityLevel::High,
        "Consistent Fixture",
        "半写实",
        2,
    )
    .unwrap();

    let mut manifest = read_manifest(&source);
    let pet_id = manifest.id.clone();
    manifest.name = "Manifest Only Rename".to_string();
    write_manifest(&source, &manifest);

    let error = import_petpack(&paths, &database, &source)
        .unwrap_err()
        .to_string();
    assert!(
        error.contains("brief.json field name does not match manifest.json"),
        "{error}"
    );
    assert!(database.list_pets().unwrap().is_empty());
    assert!(revision_directories(&paths.pets_dir.join(pet_id)).is_empty());
}

#[test]
fn petpack_import_atomic_failed_reimport_keeps_existing_owned_assets() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Original Pet", "半写实", 2).unwrap();
    let pet = import_petpack(&paths, &database, &source).unwrap();
    assert_eq!(pet.origin, PetOrigin::ExternalImport);
    assert_eq!(pet.generator.as_deref(), Some("sample-petpack"));
    assert_eq!(pet.provenance.as_deref(), Some("test_fixture"));
    let petpack_path = std::path::PathBuf::from(&pet.petpack_path);
    let cover_path = std::path::PathBuf::from(&pet.cover_path);
    let frames_dir = petpack_path
        .parent()
        .unwrap()
        .join(format!("{}-frames", pet.id));
    let original_package = fs::read(&petpack_path).unwrap();

    let bad_source = temp.path().join("bad-source");
    copy_dir_all(&source, &bad_source);
    fs::remove_file(bad_source.join("assets/preview/cover.png")).unwrap();

    let error = import_petpack(&paths, &database, &bad_source)
        .unwrap_err()
        .to_string();
    assert!(error.contains("missing preview asset"));
    assert_eq!(database.list_pets().unwrap().len(), 1);
    assert_eq!(fs::read(&petpack_path).unwrap(), original_package);
    assert!(cover_path.is_file());
    assert!(frames_dir.join(RUNTIME_ASSETS_MARKER).is_file());
    assert!(frames_dir.join("idle/0001.png").is_file());
}

#[test]
fn petpack_import_atomic_repairs_partial_runtime_dir_without_marker() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Runtime Pet", "半写实", 2).unwrap();
    let pet = import_petpack(&paths, &database, &source).unwrap();
    let frames_dir = std::path::Path::new(&pet.petpack_path)
        .parent()
        .unwrap()
        .join(format!("{}-frames", pet.id));

    fs::remove_dir_all(&frames_dir).unwrap();
    for state in REQUIRED_STATES {
        let state_dir = frames_dir.join(state.as_str());
        fs::create_dir_all(&state_dir).unwrap();
        fs::copy(
            source
                .join("assets/frames")
                .join(state.as_str())
                .join("0000.png"),
            state_dir.join("0000.png"),
        )
        .unwrap();
    }
    fs::write(frames_dir.join("partial-sentinel.txt"), "partial").unwrap();

    let repaired = ensure_runtime_assets(&paths, &database, &pet).unwrap();
    assert_eq!(repaired.id, pet.id);
    assert!(frames_dir.join(RUNTIME_ASSETS_MARKER).is_file());
    assert!(frames_dir.join("idle/0001.png").is_file());
    assert!(!frames_dir.join("partial-sentinel.txt").exists());
}

#[test]
fn petpack_import_database_failure_preserves_previous_revision_bytes() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("source-v1");
    write_sample_petpack_dir(&source, QualityLevel::High, "Original Pet", "半写实", 2).unwrap();
    let original = import_petpack(&paths, &database, &source).unwrap();
    let original_package = Sha256::digest(fs::read(&original.petpack_path).unwrap());
    let original_cover = Sha256::digest(fs::read(&original.cover_path).unwrap());
    let pet_root = paths.pets_dir.join(&original.id);
    let active_pointer = fs::read(pet_root.join("active.json")).unwrap();
    let revision_count = revision_directories(&pet_root).len();

    let replacement = temp.path().join("source-v2");
    copy_dir_all(&source, &replacement);
    rename_petpack_source(&replacement, "Replacement Pet");

    let connection = rusqlite::Connection::open(database.path()).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TRIGGER fail_pet_update
            BEFORE UPDATE ON pets
            BEGIN
              SELECT RAISE(ABORT, 'forced pet update failure');
            END;
            "#,
        )
        .unwrap();
    drop(connection);

    let error = import_petpack(&paths, &database, &replacement)
        .unwrap_err()
        .to_string();
    assert!(error.contains("forced pet update failure"), "{error}");

    let stored = database.get_pet(&original.id).unwrap().unwrap();
    assert_eq!(stored.name, "Original Pet");
    assert_eq!(
        Sha256::digest(fs::read(&stored.petpack_path).unwrap()),
        original_package
    );
    assert_eq!(
        Sha256::digest(fs::read(&stored.cover_path).unwrap()),
        original_cover
    );
    assert_eq!(
        fs::read(pet_root.join("active.json")).unwrap(),
        active_pointer
    );
    assert_eq!(revision_directories(&pet_root).len(), revision_count);
    ensure_runtime_assets(&paths, &database, &stored).unwrap();
}

#[test]
fn petpack_import_publishes_immutable_revision_and_atomic_pointer() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("source-v1");
    write_sample_petpack_dir(&source, QualityLevel::High, "Revision One", "半写实", 2).unwrap();

    let first = import_petpack(&paths, &database, &source).unwrap();
    let first_path = std::path::PathBuf::from(&first.petpack_path);
    let first_bytes = Sha256::digest(fs::read(&first_path).unwrap());
    let pet_root = paths.pets_dir.join(&first.id);
    assert!(first_path.starts_with(pet_root.join("revisions")));
    let first_revision = first_path.parent().unwrap().to_path_buf();
    let first_pointer: serde_json::Value =
        serde_json::from_slice(&fs::read(pet_root.join("active.json")).unwrap()).unwrap();
    assert_eq!(first_pointer["pet_id"], first.id);
    assert_eq!(first_pointer["petpack_path"], first.petpack_path);

    let replacement = temp.path().join("source-v2");
    copy_dir_all(&source, &replacement);
    rename_petpack_source(&replacement, "Revision Two");
    let second = import_petpack(&paths, &database, &replacement).unwrap();

    assert_ne!(second.petpack_path, first.petpack_path);
    assert!(first_revision.is_dir());
    assert_eq!(Sha256::digest(fs::read(&first_path).unwrap()), first_bytes);
    assert_eq!(revision_directories(&pet_root).len(), 2);
    let second_pointer: serde_json::Value =
        serde_json::from_slice(&fs::read(pet_root.join("active.json")).unwrap()).unwrap();
    assert_eq!(second_pointer["petpack_path"], second.petpack_path);
    assert_eq!(
        database.get_pet(&first.id).unwrap().unwrap().name,
        "Revision Two"
    );
}

#[test]
fn expect_absent_rejects_same_id_without_publishing_a_revision() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("source-v1");
    write_sample_petpack_dir(&source, QualityLevel::High, "Revision One", "半写实", 2).unwrap();

    let first = import_petpack_expecting_absent(&paths, &database, &source).unwrap();
    let pet_root = paths.pets_dir.join(&first.id);
    let first_pointer = fs::read(pet_root.join("active.json")).unwrap();
    let revision_count = revision_directories(&pet_root).len();

    let replacement = temp.path().join("source-v2");
    copy_dir_all(&source, &replacement);
    rename_petpack_source(&replacement, "Revision Two");
    let error = import_petpack_expecting_absent(&paths, &database, &replacement)
        .unwrap_err()
        .to_string();

    assert!(error.contains("pet id already exists"), "{error}");
    assert_eq!(revision_directories(&pet_root).len(), revision_count);
    assert_eq!(
        fs::read(pet_root.join("active.json")).unwrap(),
        first_pointer
    );
    assert_eq!(
        database.get_pet(&first.id).unwrap().unwrap().name,
        "Revision One"
    );
}

#[test]
fn petpack_first_insert_failure_removes_uncommitted_revision_and_pointer() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Rejected Pet", "半写实", 2).unwrap();
    let pet_id = read_manifest(&source).id;

    let connection = rusqlite::Connection::open(database.path()).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TRIGGER fail_pet_insert
            BEFORE INSERT ON pets
            BEGIN
              SELECT RAISE(ABORT, 'forced pet insert failure');
            END;
            "#,
        )
        .unwrap();
    drop(connection);

    let error = import_petpack(&paths, &database, &source)
        .unwrap_err()
        .to_string();
    assert!(error.contains("forced pet insert failure"), "{error}");
    assert!(database.list_pets().unwrap().is_empty());
    let pet_root = paths.pets_dir.join(pet_id);
    assert!(!pet_root.join("active.json").exists());
    assert!(revision_directories(&pet_root).is_empty());
}

#[test]
fn concurrent_imports_leave_only_complete_revisions() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let (paths, database) = ready_state(&home);
    let first_source = temp.path().join("concurrent-v1");
    write_sample_petpack_dir(
        &first_source,
        QualityLevel::High,
        "Concurrent One",
        "半写实",
        2,
    )
    .unwrap();
    let second_source = temp.path().join("concurrent-v2");
    copy_dir_all(&first_source, &second_source);
    rename_petpack_source(&second_source, "Concurrent Two");
    let second_manifest = read_manifest(&second_source);
    let pet_id = second_manifest.id;

    let paths_one = paths.clone();
    let home_one = home.clone();
    let first = std::thread::spawn(move || {
        let database = Database::new(home_one.join("agent-pet.sqlite"));
        import_petpack(&paths_one, &database, &first_source)
    });
    let paths_two = paths.clone();
    let home_two = home.clone();
    let second = std::thread::spawn(move || {
        let database = Database::new(home_two.join("agent-pet.sqlite"));
        import_petpack(&paths_two, &database, &second_source)
    });
    first.join().unwrap().unwrap();
    second.join().unwrap().unwrap();

    let revisions = revision_directories(&paths.pets_dir.join(&pet_id));
    assert_eq!(revisions.len(), 2);
    assert!(revisions.iter().all(|revision| !revision
        .file_name()
        .unwrap()
        .to_string_lossy()
        .starts_with('.')));
    for revision in revisions {
        assert!(revision.join(format!("{pet_id}.petpack")).is_file());
        assert!(revision.join(format!("{pet_id}-cover.png")).is_file());
        assert!(revision
            .join(format!("{pet_id}-frames/idle/0000.png"))
            .is_file());
    }
    let stored = database.get_pet(&pet_id).unwrap().unwrap();
    assert!(matches!(
        stored.name.as_str(),
        "Concurrent One" | "Concurrent Two"
    ));
}

#[test]
fn canceled_revision_restores_previous_pet_without_deleting_its_assets() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("cancel-v1");
    write_sample_petpack_dir(&source, QualityLevel::High, "Stable Pet", "半写实", 2).unwrap();
    let previous = import_petpack(&paths, &database, &source).unwrap();
    let previous_bytes = Sha256::digest(fs::read(&previous.petpack_path).unwrap());

    let replacement = temp.path().join("cancel-v2");
    copy_dir_all(&source, &replacement);
    rename_petpack_source(&replacement, "Canceled Pet");
    let current = import_petpack(&paths, &database, &replacement).unwrap();
    let current_revision = std::path::Path::new(&current.petpack_path)
        .parent()
        .unwrap()
        .to_path_buf();

    assert!(rollback_imported_revision(&paths, &database, &current, Some(&previous)).unwrap());
    let stored = database.get_pet(&previous.id).unwrap().unwrap();
    assert_eq!(stored.name, "Stable Pet");
    assert_eq!(stored.petpack_path, previous.petpack_path);
    assert_eq!(
        Sha256::digest(fs::read(&stored.petpack_path).unwrap()),
        previous_bytes
    );
    assert!(!current_revision.exists());
    let pointer: serde_json::Value = serde_json::from_slice(
        &fs::read(paths.pets_dir.join(&previous.id).join("active.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(pointer["petpack_path"], previous.petpack_path);
}

#[test]
fn late_cancellation_does_not_undo_a_newer_manual_import() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("late-v1");
    write_sample_petpack_dir(&source, QualityLevel::High, "First", "半写实", 2).unwrap();
    let first = import_petpack(&paths, &database, &source).unwrap();

    let second_source = temp.path().join("late-v2");
    copy_dir_all(&source, &second_source);
    rename_petpack_source(&second_source, "Second");
    let second = import_petpack(&paths, &database, &second_source).unwrap();

    let third_source = temp.path().join("late-v3");
    copy_dir_all(&source, &third_source);
    rename_petpack_source(&third_source, "Third");
    let third = import_petpack(&paths, &database, &third_source).unwrap();

    assert!(!rollback_imported_revision(&paths, &database, &second, Some(&first)).unwrap());
    let stored = database.get_pet(&third.id).unwrap().unwrap();
    assert_eq!(stored.name, "Third");
    assert_eq!(stored.petpack_path, third.petpack_path);
    assert!(std::path::Path::new(&second.petpack_path).is_file());
}

#[test]
fn unchanged_asset_fingerprint_reuses_cached_validation() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("cached-assets");
    write_sample_petpack_dir(&source, QualityLevel::High, "Cached Pet", "半写实", 2).unwrap();
    let pet = import_petpack(&paths, &database, &source).unwrap();

    let first = petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    assert!(first.warning.is_none());
    let first_record = database.pet_asset_validation(&pet.id).unwrap().unwrap();
    let second = petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    assert!(second.warning.is_none());
    let second_record = database.pet_asset_validation(&pet.id).unwrap().unwrap();
    assert_eq!(first_record, second_record);
}

#[test]
fn fingerprint_change_revalidates_and_repairs_runtime_frames() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("repair-cache");
    write_sample_petpack_dir(&source, QualityLevel::High, "Repair Cache", "半写实", 2).unwrap();
    let pet = import_petpack(&paths, &database, &source).unwrap();
    petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    let before = database.pet_asset_validation(&pet.id).unwrap().unwrap();
    let frames = std::path::Path::new(&pet.petpack_path)
        .parent()
        .unwrap()
        .join(format!("{}-frames", pet.id));
    std::thread::sleep(std::time::Duration::from_millis(2));
    fs::remove_file(frames.join("idle/0001.png")).unwrap();

    let outcome = petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    assert!(outcome.warning.is_none());
    assert!(frames.join("idle/0001.png").is_file());
    let after = database.pet_asset_validation(&pet.id).unwrap().unwrap();
    assert_ne!(before.fingerprint, after.fingerprint);
    assert!(after.valid);
}

#[test]
fn unchanged_repair_failure_is_cached_and_exposed_without_retry() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_state(&temp.path().join("home"));
    let source = temp.path().join("failed-repair-cache");
    write_sample_petpack_dir(&source, QualityLevel::High, "Broken Cache", "半写实", 2).unwrap();
    let pet = import_petpack(&paths, &database, &source).unwrap();
    petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    let frames = std::path::Path::new(&pet.petpack_path)
        .parent()
        .unwrap()
        .join(format!("{}-frames", pet.id));
    fs::remove_dir_all(&frames).unwrap();
    fs::write(&pet.petpack_path, b"not a zip").unwrap();

    let first = petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    let warning = first.warning.expect("repair failure must be visible");
    assert_eq!(warning.code, "pet_assets_invalid");
    let first_record = database.pet_asset_validation(&pet.id).unwrap().unwrap();
    assert!(!first_record.valid);
    std::thread::sleep(std::time::Duration::from_millis(2));
    let second = petcore::petpack::ensure_runtime_assets_cached(&paths, &database, &pet).unwrap();
    assert!(second.warning.is_some());
    let second_record = database.pet_asset_validation(&pet.id).unwrap().unwrap();
    assert_eq!(first_record, second_record);
}

fn revision_directories(pet_root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let revisions = pet_root.join("revisions");
    let mut entries = match fs::read_dir(revisions) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| {
                entry
                    .file_type()
                    .ok()
                    .filter(|kind| kind.is_dir())
                    .map(|_| entry.path())
            })
            .collect::<Vec<_>>(),
        Err(_) => Vec::new(),
    };
    entries.sort();
    entries
}

fn copy_dir_all(source: &std::path::Path, target: &std::path::Path) {
    fs::create_dir_all(target).unwrap();
    for entry in fs::read_dir(source).unwrap() {
        let entry = entry.unwrap();
        let source_path = entry.path();
        let target_path = target.join(entry.file_name());
        if source_path.is_dir() {
            copy_dir_all(&source_path, &target_path);
        } else {
            fs::copy(source_path, target_path).unwrap();
        }
    }
}
