use petcore::db::{Database, DATABASE_SCHEMA_VERSION};
use petcore::runtime_manifest::{validate_expected_manifest, RuntimeReleaseManifest};
use rusqlite::Connection;
use std::fs;

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
fn legacy_v1_manifest_without_petpack_range_reconstructs_single_version_contract() {
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

    let decoded = validate_expected_manifest(&manifest_path).expect("legacy v1 manifest");
    assert_eq!(decoded.petpack_read_versions, ["apc.petpack.v1"]);
    assert_eq!(decoded.petpack_write_version, "apc.petpack.v1");
    assert_eq!(decoded, compiled);
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
fn bundled_pet_identity_remains_schema_five_rollback_compatible() {
    assert_eq!(DATABASE_SCHEMA_VERSION, 5);
    assert_eq!(
        RuntimeReleaseManifest::compiled().maximum_database_schema_version,
        5
    );
}
