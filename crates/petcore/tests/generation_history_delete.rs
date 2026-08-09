use petcore::db::Database;
use petcore::generation::delete_studio_history;
use petcore::paths::AppPaths;
use petcore::petpack::{build_petpack, import_petpack, write_sample_petpack_dir};
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore::PetCoreError;
use petcore_types::{GenerationForm, GenerationJobStatus, QualityLevel};
use serde_json::{json, Value};
use std::os::unix::fs::symlink;

fn form(description: &str) -> GenerationForm {
    GenerationForm {
        description: description.to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    }
}

fn create_terminal_job(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    status: GenerationJobStatus,
    retry_of_job_id: Option<&str>,
) {
    let job_dir = paths.jobs_dir.join(job_id);
    std::fs::create_dir_all(&job_dir).unwrap();
    database
        .create_generation_job_with_retry(job_id, &form(job_id), &job_dir, retry_of_job_id)
        .unwrap();
    database
        .append_generation_message(
            job_id,
            "assistant",
            Some("generation_progress"),
            "bounded progress",
            0.5,
            None,
            None,
        )
        .unwrap();
    database
        .update_generation_job(job_id, status, None)
        .unwrap();
}

fn request(method: &str, params: Value) -> RpcRequest {
    RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("generation-history-delete")),
        method: method.to_string(),
        params,
    }
}

#[test]
fn database_delete_cascades_messages_relinks_retry_children_and_rejects_active_jobs() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();

    create_terminal_job(
        &paths,
        &database,
        "job_delete_root",
        GenerationJobStatus::Failed,
        None,
    );
    create_terminal_job(
        &paths,
        &database,
        "job_delete_middle",
        GenerationJobStatus::Failed,
        Some("job_delete_root"),
    );
    create_terminal_job(
        &paths,
        &database,
        "job_delete_leaf",
        GenerationJobStatus::Canceled,
        Some("job_delete_middle"),
    );
    let revision_before = database.state_revision().unwrap();

    let deleted = database
        .delete_generation_history_job("job_delete_middle")
        .unwrap();
    assert_eq!(deleted.status, GenerationJobStatus::Failed);
    assert_eq!(deleted.deleted_message_count, 1);
    assert_eq!(deleted.retry_children_relinked, 1);
    assert!(deleted.state_revision > revision_before);
    assert!(database
        .generation_job("job_delete_middle")
        .unwrap()
        .is_none());
    assert!(database
        .generation_messages("job_delete_middle")
        .unwrap()
        .is_empty());
    assert_eq!(
        database
            .generation_job("job_delete_leaf")
            .unwrap()
            .unwrap()
            .retry_of_job_id
            .as_deref(),
        Some("job_delete_root")
    );

    let active_dir = paths.jobs_dir.join("job_delete_active");
    std::fs::create_dir_all(&active_dir).unwrap();
    database
        .create_generation_job("job_delete_active", &form("active"), &active_dir)
        .unwrap();
    let error = database
        .delete_generation_history_job("job_delete_active")
        .unwrap_err();
    assert!(matches!(error, PetCoreError::Conflict(_)), "{error}");
    assert!(database
        .generation_job("job_delete_active")
        .unwrap()
        .is_some());
}

#[test]
fn service_delete_removes_only_the_owned_workspace_and_retains_the_published_pet() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();

    let source = temp.path().join("pet-source");
    let manifest =
        write_sample_petpack_dir(&source, QualityLevel::Standard, "Retained Pet", "半写实")
            .unwrap();
    let archive = temp.path().join("retained.petpack");
    build_petpack(&source, &archive).unwrap();
    let imported = import_petpack(&paths, &database, &archive).unwrap();
    assert_eq!(imported.id, manifest.id);
    let retained_package = imported.petpack_path.clone();

    let job_id = "job_delete_service";
    let job_dir = paths.jobs_dir.join(job_id);
    std::fs::create_dir_all(job_dir.join("nested/deeper")).unwrap();
    std::fs::write(job_dir.join("nested/deeper/artifact.txt"), "private").unwrap();
    let external = temp.path().join("must-remain.txt");
    std::fs::write(&external, "retained").unwrap();
    symlink(&external, job_dir.join("nested/external-link")).unwrap();
    database
        .create_generation_job_for_pet_instance(
            job_id,
            &form("completed"),
            &job_dir,
            &imported.id,
            "test-instance",
        )
        .unwrap();
    database
        .append_generation_message(
            job_id,
            "assistant",
            Some("generation_completed"),
            "complete",
            1.0,
            Some(GenerationJobStatus::Completed),
            Some(&imported.id),
        )
        .unwrap();

    let receipt = delete_studio_history(&paths, &database, job_id).unwrap();
    assert!(receipt.ok);
    assert_eq!(receipt.deleted_status, GenerationJobStatus::Completed);
    assert_eq!(receipt.deleted_message_count, 1);
    assert!(receipt.workspace_removed);
    assert_eq!(
        receipt.retained_result_pet_id.as_deref(),
        Some(imported.id.as_str())
    );
    assert!(!job_dir.exists());
    assert_eq!(std::fs::read_to_string(&external).unwrap(), "retained");
    assert!(database.get_pet(&imported.id).unwrap().is_some());
    assert!(std::path::Path::new(&retained_package).is_file());
    assert!(std::fs::read_dir(&paths.jobs_dir)
        .unwrap()
        .all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".apc-delete-")));
}

#[test]
fn service_delete_refuses_a_symlinked_job_root_without_deleting_history_or_target() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    let job_id = "job_delete_symlink_root";
    create_terminal_job(&paths, &database, job_id, GenerationJobStatus::Failed, None);
    let job_dir = paths.jobs_dir.join(job_id);
    std::fs::remove_dir_all(&job_dir).unwrap();
    let outside = temp.path().join("outside-workspace");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("must-remain.txt"), "retained").unwrap();
    symlink(&outside, &job_dir).unwrap();

    let error = delete_studio_history(&paths, &database, job_id).unwrap_err();
    assert!(
        error.to_string().contains("unowned or unsafe path"),
        "{error}"
    );
    assert!(database.generation_job(job_id).unwrap().is_some());
    assert_eq!(
        std::fs::read_to_string(outside.join("must-remain.txt")).unwrap(),
        "retained"
    );
    assert!(job_dir.symlink_metadata().unwrap().file_type().is_symlink());
}

#[test]
fn rpc_delete_has_a_typed_receipt_strict_params_and_terminal_guard() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths.clone());
    state.ensure_ready().unwrap();

    create_terminal_job(
        &paths,
        &state.database,
        "job_delete_rpc",
        GenerationJobStatus::Canceled,
        None,
    );
    let deleted = handle_request(
        &state,
        request(
            "generation.history.delete",
            json!({ "job_id": "job_delete_rpc" }),
        ),
    )
    .unwrap();
    assert_eq!(deleted["ok"], true);
    assert_eq!(deleted["job_id"], "job_delete_rpc");
    assert_eq!(deleted["deleted_status"], "canceled");
    assert_eq!(deleted["deleted_message_count"], 1);
    assert_eq!(deleted["workspace_removed"], true);
    assert!(deleted["state_revision"].as_str().is_some());

    let extra = handle_request(
        &state,
        request(
            "generation.history.delete",
            json!({ "job_id": "job_delete_rpc", "force": true }),
        ),
    )
    .unwrap_err();
    assert!(extra.to_string().contains("does not accept param force"));

    let active_dir = paths.jobs_dir.join("job_delete_rpc_active");
    std::fs::create_dir_all(&active_dir).unwrap();
    state
        .database
        .create_generation_job("job_delete_rpc_active", &form("active"), &active_dir)
        .unwrap();
    let active = handle_request(
        &state,
        request(
            "generation.history.delete",
            json!({ "job_id": "job_delete_rpc_active" }),
        ),
    )
    .unwrap_err();
    assert!(matches!(active, PetCoreError::Conflict(_)), "{active}");
    assert!(active_dir.is_dir());

    let unsafe_id = handle_request(
        &state,
        request(
            "generation.history.delete",
            json!({ "job_id": "../outside" }),
        ),
    )
    .unwrap_err();
    assert!(unsafe_id.to_string().contains("one bounded path component"));
}
