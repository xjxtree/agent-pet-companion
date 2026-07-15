use petcore::daemon::instance_lock::InstanceGuard;
use petcore::db::Database;
use petcore::paths::AppPaths;
use petcore::petpack::{import_petpack, write_sample_petpack_dir};
use petcore_types::QualityLevel;
use std::process::Command;

fn cli() -> &'static str {
    env!("CARGO_BIN_EXE_petcore-cli")
}

fn installed_pet(home: &std::path::Path, fixture_root: &std::path::Path) -> String {
    let source = fixture_root.join("source");
    write_sample_petpack_dir(
        &source,
        QualityLevel::Standard,
        "CLI Export Routing",
        "半写实",
        2,
    )
    .unwrap();
    let paths = AppPaths::new(home.to_path_buf());
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    import_petpack(&paths, &database, &source).unwrap().id
}

#[test]
fn default_export_requires_daemon_and_does_not_write_output() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let id = installed_pet(&home, &temp.path().join("fixture"));
    let output_path = temp.path().join("default.petpack");
    let output = Command::new(cli())
        .env("APC_HOME", &home)
        .args(["petpack", "export", "--id"])
        .arg(&id)
        .arg("--output")
        .arg(&output_path)
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(!output_path.exists());
}

#[test]
fn explicit_offline_export_writes_valid_portable_package() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let id = installed_pet(&home, &temp.path().join("fixture"));
    let output_path = temp.path().join("offline.petpack");
    let output = Command::new(cli())
        .env("APC_HOME", &home)
        .args(["petpack", "export", "--offline", "--id"])
        .arg(&id)
        .arg("--output")
        .arg(&output_path)
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["ok"], true);
    assert_eq!(result["pet_id"], id);
    assert_eq!(
        petcore::petpack::validate_petpack_path(&output_path)
            .unwrap()
            .manifest
            .id,
        id
    );
}

#[test]
fn offline_export_cannot_bypass_held_daemon_instance_lock() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let id = installed_pet(&home, &temp.path().join("fixture"));
    let paths = AppPaths::new(home.clone());
    let _guard = InstanceGuard::acquire(&paths).unwrap();
    let output_path = temp.path().join("blocked.petpack");
    let output = Command::new(cli())
        .env("APC_HOME", &home)
        .args(["petpack", "export", "--offline", "--id"])
        .arg(&id)
        .arg("--output")
        .arg(&output_path)
        .output()
        .unwrap();

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("instance lock is held"), "{stderr}");
    assert!(!output_path.exists());
}
