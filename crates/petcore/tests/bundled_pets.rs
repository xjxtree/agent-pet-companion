use petcore::db::Database;
use petcore::generation::start_pet_edit_for_instance;
use petcore::paths::AppPaths;
use petcore::petpack::{
    build_petpack, ensure_runtime_assets_cached, export_petpack, extract_validated_petpack_source,
    import_petpack, is_bundled_pet, seed_bundled_pet_inventory, validate_petpack_path,
    write_sample_petpack_dir, BundledPetSeedStatus, BUNDLED_PET_GENERATOR_MARKER,
    BUNDLED_PET_INVENTORY_VERSION, BUNDLED_PET_PROVENANCE_MARKER,
};
use petcore::rpc::{handle_json_line, CoreState};
use petcore_types::{PetOrigin, QualityLevel};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

fn inventory_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../apps/macos/Sources/AgentPetCompanion/Resources/BuiltInPets")
}

fn ready_store(home: &Path) -> (AppPaths, Database) {
    let paths = AppPaths::new(home.to_path_buf());
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    (paths, database)
}

fn response_result(response: &str) -> Value {
    let response: Value = serde_json::from_str(response).unwrap();
    assert!(response.get("error").is_none(), "{response}");
    response["result"].clone()
}

#[test]
fn fresh_library_installs_both_bundled_pets_with_stable_identity() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_store(&temp.path().join("home"));

    let outcomes = seed_bundled_pet_inventory(&paths, &database, &inventory_root()).unwrap();

    assert_eq!(outcomes.len(), 2);
    assert!(outcomes
        .iter()
        .all(|outcome| outcome.status == BundledPetSeedStatus::Installed));
    assert_eq!(outcomes[0].pet_id, "pet_xingwutuanzi");
    assert_eq!(outcomes[1].pet_id, "pet_bytebudcodex");
    let pets = database.list_pets().unwrap();
    assert_eq!(pets.len(), 2);
    assert!(pets
        .iter()
        .all(|pet| pet.origin == PetOrigin::VerifiedSkillSource && is_bundled_pet(pet)));
    assert!(pets.iter().all(|pet| {
        pet.generator.as_deref() == Some(BUNDLED_PET_GENERATOR_MARKER)
            && pet.provenance.as_deref() == Some(BUNDLED_PET_PROVENANCE_MARKER)
    }));
    assert!(
        pets.iter()
            .find(|pet| pet.id == "pet_xingwutuanzi")
            .unwrap()
            .active
    );
    assert!(
        !pets
            .iter()
            .find(|pet| pet.id == "pet_bytebudcodex")
            .unwrap()
            .active
    );

    let xingwu = pets
        .iter()
        .find(|pet| pet.id == "pet_xingwutuanzi")
        .unwrap();
    fs::remove_file(&xingwu.cover_path).unwrap();
    let repaired = ensure_runtime_assets_cached(&paths, &database, xingwu).unwrap();
    assert!(repaired.warning.is_none());
    assert!(Path::new(&repaired.pet.cover_path).is_file());
    assert!(is_bundled_pet(&repaired.pet));
    assert!(is_bundled_pet(
        &database.get_pet("pet_xingwutuanzi").unwrap().unwrap()
    ));
}

#[test]
fn repeated_seed_uses_idempotent_fast_path_without_reading_resources() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_store(&temp.path().join("home"));
    let installed = seed_bundled_pet_inventory(&paths, &database, &inventory_root()).unwrap();
    let installed_paths = installed
        .iter()
        .map(|outcome| (outcome.pet_id.clone(), outcome.pet.petpack_path.clone()))
        .collect::<std::collections::BTreeMap<_, _>>();

    let unavailable_root = temp.path().join("removed-app-resources");
    let repeated = seed_bundled_pet_inventory(&paths, &database, &unavailable_root).unwrap();

    assert_eq!(repeated.len(), 2);
    assert!(repeated.iter().all(|outcome| {
        outcome.status == BundledPetSeedStatus::PreservedExistingId
            && installed_paths.get(&outcome.pet_id) == Some(&outcome.pet.petpack_path)
    }));
}

#[test]
fn existing_same_id_is_preserved_while_missing_bundled_pet_is_installed() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_store(&temp.path().join("home"));
    let source = inventory_root().join("pet_xingwutuanzi.petpack");
    let existing = import_petpack(&paths, &database, &source).unwrap();
    assert_eq!(existing.origin, PetOrigin::ExternalImport);

    let outcomes = seed_bundled_pet_inventory(&paths, &database, &inventory_root()).unwrap();
    let preserved = outcomes
        .iter()
        .find(|outcome| outcome.pet_id == "pet_xingwutuanzi")
        .unwrap();
    assert_eq!(preserved.status, BundledPetSeedStatus::PreservedExistingId);
    assert_eq!(preserved.pet.petpack_path, existing.petpack_path);
    assert_eq!(preserved.pet.origin, PetOrigin::ExternalImport);
    assert!(!is_bundled_pet(&preserved.pet));
    let bytebud = database.get_pet("pet_bytebudcodex").unwrap().unwrap();
    assert_eq!(bytebud.origin, PetOrigin::VerifiedSkillSource);
    assert!(is_bundled_pet(&bytebud));
}

#[test]
fn same_display_name_with_different_id_coexists_with_bundled_pet() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_store(&temp.path().join("home"));
    let source = temp.path().join("same-name-source");
    write_sample_petpack_dir(
        &source,
        QualityLevel::Standard,
        "星雾团子",
        "用户同名资源",
        2,
    )
    .unwrap();
    let user_pet = import_petpack(&paths, &database, &source).unwrap();
    assert_ne!(user_pet.id, "pet_xingwutuanzi");

    seed_bundled_pet_inventory(&paths, &database, &inventory_root()).unwrap();
    let same_name = database
        .list_pets()
        .unwrap()
        .into_iter()
        .filter(|pet| pet.name == "星雾团子")
        .collect::<Vec<_>>();
    assert_eq!(same_name.len(), 2);
    assert!(same_name.iter().any(|pet| pet.id == user_pet.id));
    assert!(same_name
        .iter()
        .any(|pet| pet.id == "pet_xingwutuanzi" && is_bundled_pet(pet)));
}

#[test]
fn seed_never_replaces_an_existing_active_user_pet() {
    let temp = tempfile::tempdir().unwrap();
    let (paths, database) = ready_store(&temp.path().join("home"));
    let source = temp.path().join("active-user-pet");
    write_sample_petpack_dir(
        &source,
        QualityLevel::Standard,
        "用户当前宠物",
        "storybook",
        2,
    )
    .unwrap();
    let user_pet = import_petpack(&paths, &database, &source).unwrap();
    assert!(user_pet.active);

    seed_bundled_pet_inventory(&paths, &database, &inventory_root()).unwrap();

    let pets = database.list_pets().unwrap();
    assert!(
        pets.iter()
            .find(|pet| pet.id == user_pet.id)
            .unwrap()
            .active
    );
    assert!(pets
        .iter()
        .filter(|pet| is_bundled_pet(pet))
        .all(|pet| !pet.active));
}

#[test]
fn external_import_cannot_forge_bundled_identity_with_package_metadata() {
    let temp = tempfile::tempdir().unwrap();
    let source_dir = temp.path().join("forged-source");
    extract_validated_petpack_source(
        &inventory_root().join("pet_xingwutuanzi.petpack"),
        &source_dir,
    )
    .unwrap();
    let source_metadata_path = source_dir.join("source/source.json");
    let mut source_metadata: Value =
        serde_json::from_slice(&fs::read(&source_metadata_path).unwrap()).unwrap();
    source_metadata["generator"] = json!(BUNDLED_PET_GENERATOR_MARKER);
    source_metadata["provenance"] = json!(BUNDLED_PET_PROVENANCE_MARKER);
    fs::write(
        &source_metadata_path,
        serde_json::to_vec_pretty(&source_metadata).unwrap(),
    )
    .unwrap();
    let forged_package = temp.path().join("forged.petpack");
    build_petpack(&source_dir, &forged_package).unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    state.ensure_ready().unwrap();

    let imported = import_petpack(&state.paths, &state.database, &forged_package).unwrap();

    assert_eq!(imported.origin, PetOrigin::ExternalImport);
    assert_eq!(
        imported.generator.as_deref(),
        Some(BUNDLED_PET_GENERATOR_MARKER)
    );
    assert_eq!(
        imported.provenance.as_deref(),
        Some(BUNDLED_PET_PROVENANCE_MARKER)
    );
    assert!(!is_bundled_pet(&imported));
    let deleted = response_result(
        &handle_json_line(
            &state,
            &json!({
                "jsonrpc": "2.0",
                "id": "delete-forged-external",
                "method": "pet.delete",
                "params": { "id": imported.id }
            })
            .to_string(),
        )
        .unwrap(),
    );
    assert_eq!(deleted["ok"], true);
}

#[test]
fn tampered_or_replaced_inventory_fails_before_installing_any_pet() {
    let temp = tempfile::tempdir().unwrap();
    let inventory = temp.path().join("inventory");
    fs::create_dir(&inventory).unwrap();
    for name in ["pet_xingwutuanzi.petpack", "pet_bytebudcodex.petpack"] {
        fs::copy(inventory_root().join(name), inventory.join(name)).unwrap();
    }
    let mut bytebud = fs::OpenOptions::new()
        .append(true)
        .open(inventory.join("pet_bytebudcodex.petpack"))
        .unwrap();
    bytebud.write_all(b"replacement").unwrap();
    drop(bytebud);
    let (paths, database) = ready_store(&temp.path().join("home"));

    let error = seed_bundled_pet_inventory(&paths, &database, &inventory)
        .unwrap_err()
        .to_string();

    assert!(error.contains("digest"), "{error}");
    assert!(database.list_pets().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn symlinked_inventory_member_is_rejected() {
    use std::os::unix::fs::symlink;

    let temp = tempfile::tempdir().unwrap();
    let inventory = temp.path().join("inventory");
    fs::create_dir(&inventory).unwrap();
    symlink(
        inventory_root().join("pet_xingwutuanzi.petpack"),
        inventory.join("pet_xingwutuanzi.petpack"),
    )
    .unwrap();
    fs::copy(
        inventory_root().join("pet_bytebudcodex.petpack"),
        inventory.join("pet_bytebudcodex.petpack"),
    )
    .unwrap();
    let (paths, database) = ready_store(&temp.path().join("home"));

    let error = seed_bundled_pet_inventory(&paths, &database, &inventory)
        .unwrap_err()
        .to_string();

    assert!(error.contains("single-link regular file"), "{error}");
    assert!(database.list_pets().unwrap().is_empty());
}

#[test]
fn rpc_seeds_fixed_inventory_and_rejects_unknown_inventory_version() {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    state.ensure_ready().unwrap();
    let response = handle_json_line(
        &state,
        &json!({
            "jsonrpc": "2.0",
            "id": "seed",
            "method": "petpack.seed_bundled",
            "params": {
                "inventory": BUNDLED_PET_INVENTORY_VERSION,
                "inventory_root": inventory_root()
            }
        })
        .to_string(),
    )
    .unwrap();
    let result = response_result(&response);
    assert_eq!(result["outcomes"].as_array().unwrap().len(), 2);

    let rejected: Value = serde_json::from_str(
        &handle_json_line(
            &state,
            &json!({
                "jsonrpc": "2.0",
                "id": "bad-seed",
                "method": "petpack.seed_bundled",
                "params": {
                    "inventory": "apc.bundled-pets.future",
                    "inventory_root": inventory_root()
                }
            })
            .to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(rejected["error"]["message"]
        .as_str()
        .unwrap()
        .contains("unsupported bundled pet inventory"));
}

#[test]
fn bundled_pets_are_read_only_but_remain_exportable_by_existing_api() {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    state.ensure_ready().unwrap();
    seed_bundled_pet_inventory(&state.paths, &state.database, &inventory_root()).unwrap();
    let installed = state.database.get_pet("pet_xingwutuanzi").unwrap().unwrap();
    let installed_digest = Sha256::digest(fs::read(&installed.petpack_path).unwrap());
    let export_path = temp.path().join("exports/xingwutuanzi.petpack");
    fs::create_dir_all(export_path.parent().unwrap()).unwrap();
    let exported = export_petpack(
        &state.paths,
        &state.database,
        "pet_xingwutuanzi",
        &export_path,
    )
    .unwrap();
    assert_eq!(exported.pet_id, "pet_xingwutuanzi");
    assert_eq!(
        Sha256::digest(fs::read(&export_path).unwrap()),
        installed_digest
    );
    assert_eq!(
        validate_petpack_path(&export_path).unwrap().manifest.id,
        "pet_xingwutuanzi"
    );

    let delete: Value = serde_json::from_str(
        &handle_json_line(
            &state,
            &json!({
                "jsonrpc": "2.0",
                "id": "delete",
                "method": "pet.delete",
                "params": { "id": "pet_xingwutuanzi" }
            })
            .to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(delete["error"]["message"]
        .as_str()
        .unwrap()
        .contains("cannot be deleted"));

    let edit = start_pet_edit_for_instance(
        &state.paths,
        &state.database,
        "pet_xingwutuanzi",
        "换一个动作",
        "test-instance",
    )
    .unwrap_err()
    .to_string();
    assert!(edit.contains("read-only"), "{edit}");

    let replace = import_petpack(
        &state.paths,
        &state.database,
        &inventory_root().join("pet_xingwutuanzi.petpack"),
    )
    .unwrap_err()
    .to_string();
    assert!(replace.contains("bundled pet id is read-only"), "{replace}");
    assert!(is_bundled_pet(
        &state.database.get_pet("pet_xingwutuanzi").unwrap().unwrap()
    ));
}
