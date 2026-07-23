use petcore::daemon::instance_lock::InstanceGuard;
use petcore::paths::AppPaths;
use petcore::petpack::write_sample_petpack_dir;
use petcore_types::QualityLevel;
use std::process::Command;

fn cli() -> &'static str {
    env!("CARGO_BIN_EXE_petcore-cli")
}

fn sample(root: &std::path::Path) -> std::path::PathBuf {
    let source = root.join("source");
    write_sample_petpack_dir(&source, QualityLevel::Standard, "CLI Routing", "半写实").unwrap();
    source
}

#[test]
fn default_import_requires_daemon_and_does_not_mutate_offline() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let source = sample(temp.path());
    let output = Command::new(cli())
        .env("APC_HOME", &home)
        .args(["petpack", "import"])
        .arg(&source)
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(!home.join("agent-pet.sqlite").exists());
    assert!(!home.join("pets").exists());
}

#[test]
fn explicit_offline_import_uses_singleton_and_revision_writer() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let source = sample(temp.path());
    let output = Command::new(cli())
        .env("APC_HOME", &home)
        .args(["petpack", "import", "--offline"])
        .arg(&source)
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let pet: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let package = std::path::Path::new(pet["petpack_path"].as_str().unwrap());
    assert!(package.is_file());
    assert!(package.to_string_lossy().contains("/revisions/rev_"));
    assert!(home
        .join("pets")
        .join(pet["id"].as_str().unwrap())
        .join("active.json")
        .is_file());
}

#[test]
fn offline_import_cannot_bypass_a_held_daemon_instance_lock() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let paths = AppPaths::new(home.clone());
    let _guard = InstanceGuard::acquire(&paths).unwrap();
    let source = sample(temp.path());
    let output = Command::new(cli())
        .env("APC_HOME", &home)
        .args(["petpack", "import", "--offline"])
        .arg(&source)
        .output()
        .unwrap();

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("instance lock is held"), "{stderr}");
    assert!(!home.join("agent-pet.sqlite").exists());
}
