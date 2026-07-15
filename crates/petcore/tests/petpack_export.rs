use petcore::db::Database;
use petcore::paths::AppPaths;
use petcore::petpack::{
    export_petpack, import_petpack, validate_petpack_path, write_sample_petpack_dir,
};
use petcore::rpc::{handle_json_line, CoreState};
use petcore_types::QualityLevel;
use serde_json::json;
use std::fs;
use std::path::Path;

fn ready_store(home: &Path) -> (AppPaths, Database) {
    let paths = AppPaths::new(home.to_path_buf());
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    (paths, database)
}

fn sample_source(root: &Path, name: &str) -> std::path::PathBuf {
    let source = root.join("source");
    write_sample_petpack_dir(&source, QualityLevel::Standard, name, "半写实", 2).unwrap();
    source
}

#[test]
fn export_preserves_exact_archive_bytes_and_reimports_with_same_id() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(&temp.path().join("fixture"), "Portable Pet");
    let (paths, database) = ready_store(&temp.path().join("first-home"));
    let installed = import_petpack(&paths, &database, &source).unwrap();
    let installed_bytes = fs::read(&installed.petpack_path).unwrap();

    let output = temp.path().join("exports/portable.petpack");
    fs::create_dir_all(output.parent().unwrap()).unwrap();
    fs::write(&output, b"previous export must be replaced atomically").unwrap();
    let exported = export_petpack(&paths, &database, &installed.id, &output).unwrap();

    assert!(exported.ok);
    assert_eq!(exported.pet_id, installed.id);
    assert_eq!(exported.byte_count as usize, installed_bytes.len());
    assert_eq!(fs::read(&output).unwrap(), installed_bytes);
    let validation = validate_petpack_path(&output).unwrap();
    assert_eq!(validation.manifest.id, installed.id);
    assert_eq!(validation.manifest, exported.validation.manifest);

    let (second_paths, second_database) = ready_store(&temp.path().join("second-home"));
    let reimported = import_petpack(&second_paths, &second_database, &output).unwrap();
    assert_eq!(reimported.id, installed.id);
    assert_eq!(reimported.name, installed.name);
    assert_eq!(
        validate_petpack_path(Path::new(&reimported.petpack_path))
            .unwrap()
            .manifest
            .id,
        installed.id
    );
}

#[test]
fn rpc_export_is_registered_and_rejects_unknown_params() {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    state.ensure_ready().unwrap();
    let source = sample_source(&temp.path().join("fixture"), "RPC Export Pet");
    let installed = import_petpack(&state.paths, &state.database, &source).unwrap();
    let output = temp.path().join("rpc-export.petpack");

    let response = handle_json_line(
        &state,
        &json!({
            "jsonrpc": "2.0",
            "id": "export",
            "method": "petpack.export",
            "params": {
                "id": installed.id,
                "path": output.display().to_string()
            }
        })
        .to_string(),
    )
    .unwrap();
    let response: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(response["result"]["ok"], true);
    assert_eq!(response["result"]["pet_id"], installed.id);
    assert!(output.is_file());

    let invalid = handle_json_line(
        &state,
        &json!({
            "jsonrpc": "2.0",
            "id": "invalid-export",
            "method": "petpack.export",
            "params": {
                "id": installed.id,
                "path": output.display().to_string(),
                "unexpected": true
            }
        })
        .to_string(),
    )
    .unwrap();
    let invalid: serde_json::Value = serde_json::from_str(&invalid).unwrap();
    assert_eq!(invalid["error"]["code"], -32602);
}

#[test]
fn corrupt_installed_package_does_not_replace_existing_export() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(&temp.path().join("fixture"), "Corrupt Export Pet");
    let (paths, database) = ready_store(&temp.path().join("home"));
    let installed = import_petpack(&paths, &database, &source).unwrap();
    fs::write(&installed.petpack_path, b"not a petpack").unwrap();

    let output = temp.path().join("existing.petpack");
    let previous = b"keep this destination unchanged";
    fs::write(&output, previous).unwrap();
    let error = export_petpack(&paths, &database, &installed.id, &output)
        .unwrap_err()
        .to_string();

    assert!(!error.is_empty());
    assert_eq!(fs::read(&output).unwrap(), previous);
}

#[test]
fn export_rejects_unknown_pet_and_owned_store_destination() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(&temp.path().join("fixture"), "Protected Export Pet");
    let (paths, database) = ready_store(&temp.path().join("home"));
    let installed = import_petpack(&paths, &database, &source).unwrap();

    let unknown = export_petpack(
        &paths,
        &database,
        "pet_missing",
        &temp.path().join("missing.petpack"),
    )
    .unwrap_err()
    .to_string();
    assert!(unknown.contains("pet not found"), "{unknown}");

    let protected_output = paths.pets_dir.join("must-not-export-here.petpack");
    let protected = export_petpack(&paths, &database, &installed.id, &protected_output)
        .unwrap_err()
        .to_string();
    assert!(
        protected.contains("outside the owned pet store"),
        "{protected}"
    );
    assert!(!protected_output.exists());
}
