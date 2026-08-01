use petcore::db::{Database, DATABASE_SCHEMA_VERSION};
use petcore::paths::AppPaths;
use petcore::runtime_manifest::{validate_expected_manifest, RuntimeReleaseManifest};
use rusqlite::{params, Connection};
use serde_json::json;
use std::fs;
use std::process::Command;

#[test]
fn compiled_runtime_manifest_round_trips_and_rejects_mismatch() {
    let temp = tempfile::tempdir().expect("tempdir");
    let manifest_path = temp.path().join("runtime-manifest.json");
    let compiled = RuntimeReleaseManifest::compiled();
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&compiled).expect("encode manifest"),
    )
    .expect("write manifest");

    assert_eq!(
        validate_expected_manifest(&manifest_path).expect("valid manifest"),
        compiled
    );

    let mut mismatched = compiled;
    mismatched.petcore_cli_build_id = "different-cli-build".to_string();
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&mismatched).expect("encode mismatch"),
    )
    .expect("write mismatch");
    let error = validate_expected_manifest(&manifest_path).expect_err("mismatch must fail");
    assert!(error
        .to_string()
        .contains("does not match this PetCore build"));
}

#[test]
fn runtime_manifest_requires_explicit_v2_petpack_range() {
    let temp = tempfile::tempdir().expect("tempdir");
    let manifest_path = temp.path().join("runtime-manifest.json");
    let compiled = RuntimeReleaseManifest::compiled();
    let mut legacy = serde_json::to_value(&compiled)
        .expect("encode manifest")
        .as_object()
        .cloned()
        .expect("manifest object");
    legacy.remove("petpack_read_versions");
    legacy.remove("petpack_write_version");
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&legacy).expect("encode legacy manifest"),
    )
    .expect("write legacy manifest");

    let error = validate_expected_manifest(&manifest_path)
        .expect_err("missing V2 compatibility fields must fail closed");
    assert!(error.to_string().contains("runtime manifest is invalid"));
}

#[test]
fn newer_database_schema_is_rejected_without_downgrade() {
    let temp = tempfile::tempdir().expect("tempdir");
    let database_path = temp.path().join("agent-pet.sqlite");
    let future_version = DATABASE_SCHEMA_VERSION + 1;
    let connection = Connection::open(&database_path).expect("open database");
    connection
        .pragma_update(None, "user_version", future_version)
        .expect("set future schema");
    drop(connection);

    let error = Database::new(&database_path)
        .preflight_compatibility()
        .expect_err("future schema must fail");
    assert!(error.to_string().contains("downgrade is blocked"));

    let connection = Connection::open(&database_path).expect("reopen database");
    let persisted: u32 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("read schema");
    assert_eq!(persisted, future_version);
}

#[test]
fn runtime_manifest_advertises_the_additive_v2_database_contract() {
    assert_eq!(DATABASE_SCHEMA_VERSION, 6);
    assert_eq!(
        RuntimeReleaseManifest::compiled().maximum_database_schema_version,
        DATABASE_SCHEMA_VERSION
    );
}

#[test]
fn candidate_preflight_rejects_an_incompatible_active_generation_without_writing() {
    let temp = tempfile::tempdir().expect("tempdir");
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().expect("create private app paths");
    let database = Database::new(&paths.db_path);
    database.init().expect("initialize prior database");
    let manifest_path = temp.path().join("runtime-manifest.json");
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&RuntimeReleaseManifest::compiled()).expect("encode manifest"),
    )
    .expect("write manifest");

    let connection = Connection::open(&paths.db_path).expect("open database");
    let incompatible_form = json!({
        "description": "legacy waiting generation",
        "style": "legacy",
        "quality": "high",
        "native_fps": 10,
        "state_durations_ms": {
            "idle": 2000,
            "start": 1000,
            "tool": 2000,
            "waiting": 2000,
            "review": 2000,
            "done": 1000,
            "failed": 2000
        },
        "reference_images": []
    });
    connection
        .execute(
            r#"
            INSERT INTO generation_jobs (
              id, status, form_json, session_id, job_dir, result_pet_id,
              retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at
            )
            VALUES (
              'job_legacy_waiting', 'waiting_for_user', ?1, NULL, ?2, NULL,
              NULL, NULL, '2026-07-01T00:00:00Z',
              '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z'
            )
            "#,
            params![
                incompatible_form.to_string(),
                paths
                    .jobs_dir
                    .join("job_legacy_waiting")
                    .display()
                    .to_string()
            ],
        )
        .expect("insert legacy waiting generation");
    connection
        .pragma_update(None, "user_version", 6)
        .expect("simulate prior runtime schema");
    drop(connection);

    let run_preflight = || {
        Command::new(env!("CARGO_BIN_EXE_petcore"))
            .args(["preflight", "--home"])
            .arg(&paths.home)
            .arg("--manifest")
            .arg(&manifest_path)
            .output()
            .expect("run candidate preflight")
    };
    let rejected = run_preflight();
    assert!(!rejected.status.success());
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("active generation form"));

    let connection = Connection::open(&paths.db_path).expect("reopen database");
    let schema_version: u32 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("read unchanged schema");
    assert_eq!(
        schema_version, 6,
        "candidate preflight must remain read-only"
    );

    connection
        .execute(
            r#"
            UPDATE generation_jobs
            SET form_json = ?1
            WHERE id = 'job_legacy_waiting'
            "#,
            params![json!({
                "description": "current waiting generation",
                "style": "modern",
                "quality": "standard",
                "reference_images": []
            })
            .to_string()],
        )
        .expect("replace with current form");
    drop(connection);
    assert!(
        run_preflight().status.success(),
        "a current V2 waiting generation remains safely replaceable"
    );

    let connection = Connection::open(&paths.db_path).expect("reopen database");
    connection
        .execute(
            r#"
            UPDATE generation_jobs
            SET status = 'completed', form_json = ?1
            WHERE id = 'job_legacy_waiting'
            "#,
            params![incompatible_form.to_string()],
        )
        .expect("make legacy job terminal");
    drop(connection);
    assert!(
        run_preflight().status.success(),
        "terminal legacy history must not block a runtime update"
    );
}

#[test]
fn rollback_checkpoint_cli_restores_the_exact_pre_candidate_database() {
    let temp = tempfile::tempdir().expect("tempdir");
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().expect("create private app paths");
    Database::new(&paths.db_path)
        .init()
        .expect("initialize database");

    let run_checkpoint = |action: &str| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_petcore"));
        command
            .args(["rollback-checkpoint", action, "--home"])
            .arg(&paths.home);
        if action == "create" {
            command.args([
                "--source-build-id",
                "released-v1",
                "--candidate-build-id",
                "candidate-v2",
            ]);
        }
        command.output().expect("run rollback checkpoint command")
    };
    assert!(run_checkpoint("create").status.success());
    let status = run_checkpoint("status");
    assert!(status.status.success());
    let status: serde_json::Value =
        serde_json::from_slice(&status.stdout).expect("decode checkpoint status");
    assert_eq!(status["present"], true);
    assert_eq!(status["phase"], "ready");
    assert_eq!(status["source_build_id"], "released-v1");
    assert_eq!(status["candidate_build_id"], "candidate-v2");

    let connection = Connection::open(&paths.db_path).expect("open database");
    connection
        .execute_batch("CREATE TABLE candidate_only (id INTEGER PRIMARY KEY);")
        .expect("simulate candidate migration");
    drop(connection);

    let restore = run_checkpoint("restore");
    assert!(
        restore.status.success(),
        "{}",
        String::from_utf8_lossy(&restore.stderr)
    );
    let connection = Connection::open(&paths.db_path).expect("open restored database");
    let candidate_table_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'candidate_only'",
            [],
            |row| row.get(0),
        )
        .expect("inspect restored schema");
    assert_eq!(candidate_table_count, 0);
    drop(connection);
    let restored_status = run_checkpoint("status");
    assert!(restored_status.status.success());
    let restored_status: serde_json::Value =
        serde_json::from_slice(&restored_status.stdout).expect("decode restored status");
    assert_eq!(restored_status["phase"], "restored");

    assert!(run_checkpoint("discard").status.success());
    assert!(!paths.home.join("runtime/rollback-checkpoint").exists());
    let absent_status = run_checkpoint("status");
    assert!(absent_status.status.success());
    let absent_status: serde_json::Value =
        serde_json::from_slice(&absent_status.stdout).expect("decode absent status");
    assert_eq!(absent_status["present"], false);
}
