use petcore::daemon::instance_lock::{RuntimeMarker, RUNTIME_MARKER_SCHEMA_VERSION};
use petcore::db::Database;
use petcore::generation;
use petcore::paths::AppPaths;
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{
    GenerationForm, GenerationJobStatus, PetOrigin, PetSummary, QualityLevel, RenderSize,
};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::fs;
use std::io::Write;

fn form() -> GenerationForm {
    GenerationForm {
        description: "Recoverable generation".to_string(),
        style: "pixel".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    }
}

fn ready() -> (tempfile::TempDir, AppPaths, Database) {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    (temp, paths, database)
}

fn create_owned_job(database: &Database, paths: &AppPaths, job_id: &str, owner_instance_id: &str) {
    let job_dir = paths.jobs_dir.join(job_id);
    fs::create_dir_all(&job_dir).unwrap();
    database
        .create_generation_job_for_instance(job_id, &form(), &job_dir, None, owner_instance_id)
        .unwrap();
}

fn request(method: &str, params: Value) -> RpcRequest {
    RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    }
}

fn set_owner_and_heartbeat(
    database: &Database,
    job_id: &str,
    owner_instance_id: &str,
    heartbeat_at: &str,
) {
    Connection::open(database.path())
        .unwrap()
        .execute(
            r#"
            UPDATE generation_jobs
            SET owner_instance_id = ?2, heartbeat_at = ?3
            WHERE id = ?1
            "#,
            params![job_id, owner_instance_id, heartbeat_at],
        )
        .unwrap();
}

#[test]
fn cancel_revision_preserves_existing_pet() {
    let (_temp, paths, database) = ready();
    let pet_dir = paths.pets_dir.join("pet-existing");
    fs::create_dir_all(&pet_dir).unwrap();
    let package = pet_dir.join("existing.petpack");
    let cover = pet_dir.join("cover.png");
    fs::write(&package, b"existing package").unwrap();
    fs::write(&cover, b"existing cover").unwrap();
    let pet = PetSummary {
        id: "pet-existing".to_string(),
        name: "Existing".to_string(),
        style: "pixel".to_string(),
        quality: QualityLevel::Standard,
        render_size: RenderSize {
            width: 256,
            height: 288,
        },
        petpack_path: package.display().to_string(),
        cover_path: cover.display().to_string(),
        origin: PetOrigin::GeneratedByPetcoreJob,
        generator: Some("codex".to_string()),
        provenance: Some("verified".to_string()),
        active: true,
        created_at: "2026-07-10T00:00:00Z".to_string(),
    };
    database.upsert_pet(&pet).unwrap();
    create_owned_job(&database, &paths, "job-cancel-existing", "instance-current");

    generation::cancel_generation(&paths, &database, "job-cancel-existing").unwrap();

    let stored = database.get_pet("pet-existing").unwrap().unwrap();
    assert_eq!(stored.petpack_path, pet.petpack_path);
    assert_eq!(stored.cover_path, pet.cover_path);
    assert!(package.exists());
    assert!(cover.exists());
}

#[test]
fn second_generation_is_rejected_while_one_is_active() {
    let (_temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-first", "instance-current");
    let second_dir = paths.jobs_dir.join("job-second");
    fs::create_dir_all(&second_dir).unwrap();

    let error = database
        .create_generation_job_for_instance(
            "job-second",
            &form(),
            &second_dir,
            None,
            "instance-current",
        )
        .unwrap_err()
        .to_string();

    assert!(error.contains("active generation"), "{error}");
    assert_eq!(database.generation_job_status("job-second").unwrap(), None);
}

#[test]
fn completed_job_cannot_resume_while_another_job_is_active() {
    let (_temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-completed", "instance-current");
    database
        .append_generation_message(
            "job-completed",
            "assistant",
            Some("generation_completed"),
            "done",
            1.0,
            Some(GenerationJobStatus::Completed),
            Some("pet-completed"),
        )
        .unwrap();
    create_owned_job(&database, &paths, "job-active", "instance-current");

    let error = database
        .append_generation_message(
            "job-completed",
            "user",
            None,
            "revise",
            0.03,
            Some(GenerationJobStatus::Running),
            None,
        )
        .unwrap_err()
        .to_string();

    assert!(error.contains("active generation"), "{error}");
    assert_eq!(
        database.generation_job_status("job-completed").unwrap(),
        Some(GenerationJobStatus::Completed)
    );
    assert_eq!(
        database.generation_job_status("job-active").unwrap(),
        Some(GenerationJobStatus::Pending)
    );
}

#[test]
fn snapshot_includes_running_and_waiting_job() {
    let (_temp, paths, database) = ready();
    let instance_id = "instance-snapshot";
    create_owned_job(&database, &paths, "job-snapshot", instance_id);
    database
        .update_generation_job("job-snapshot", GenerationJobStatus::Running, None)
        .unwrap();
    let state = CoreState::new(paths.clone()).with_instance_id(instance_id);

    let running = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(running["active_generation"]["job_id"], "job-snapshot");
    assert_eq!(running["active_generation"]["status"], "running");
    assert_eq!(
        running["active_generation"]["form"]["description"],
        "Recoverable generation"
    );

    let input_request = json!({
        "id": "legacy-input-request",
        "role": "assistant",
        "kind": "input_request",
        "content": "Choose a palette",
        "progress": 0.2,
        "created_at": "2026-07-10T00:00:01Z"
    });
    fs::write(
        paths.jobs_dir.join("job-snapshot").join("messages.jsonl"),
        format!("{input_request}\n"),
    )
    .unwrap();
    database
        .update_generation_job("job-snapshot", GenerationJobStatus::WaitingForUser, None)
        .unwrap();

    let waiting = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(waiting["active_generation"]["status"], "waiting_for_user");
    assert_eq!(
        waiting["active_generation"]["input_request"]["content"],
        "Choose a palette"
    );
    assert_eq!(
        waiting["active_generation"]["messages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(waiting["active_generation"]["message_revision"]
        .as_str()
        .is_some_and(|value| value.parse::<u64>().is_ok()));
}

#[test]
fn message_ids_survive_restart() {
    let (_temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-stable-messages", "instance-current");
    generation::cancel_generation(&paths, &database, "job-stable-messages").unwrap();
    let before = generation::read_messages(&paths, "job-stable-messages").unwrap();
    assert_eq!(before.len(), 1);
    let ids = before
        .iter()
        .map(|message| message["id"].clone())
        .collect::<Vec<_>>();
    fs::remove_file(
        paths
            .jobs_dir
            .join("job-stable-messages")
            .join("messages.jsonl"),
    )
    .unwrap();

    let reopened = Database::new(paths.db_path.clone());
    reopened.init().unwrap();
    let after = generation::read_messages(&paths, "job-stable-messages").unwrap();

    assert_eq!(
        after
            .iter()
            .map(|message| message["id"].clone())
            .collect::<Vec<_>>(),
        ids
    );
}

#[test]
fn truncated_jsonl_tail_does_not_hide_committed_messages() {
    let (_temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-torn-tail", "instance-current");
    generation::cancel_generation(&paths, &database, "job-torn-tail").unwrap();
    let path = paths.jobs_dir.join("job-torn-tail").join("messages.jsonl");
    let secret = "TORN_SECRET_MUST_NOT_LEAK_991d";
    fs::write(&path, format!("{{\"content\":\"{secret}")).unwrap();

    let messages = generation::read_messages(&paths, "job-torn-tail").unwrap();
    let encoded = serde_json::to_string(&messages).unwrap();

    assert!(messages
        .iter()
        .any(|message| message["kind"] == "generation_canceled"));
    assert!(messages
        .iter()
        .any(|message| message["kind"] == "jsonl_diagnostic"));
    assert!(!encoded.contains(secret));
}

#[test]
fn recovery_marks_only_jobs_owned_by_dead_instance() {
    let (_temp, paths, database) = ready();
    let current_instance = "instance-current";
    create_owned_job(&database, &paths, "job-current-owner", current_instance);
    set_owner_and_heartbeat(
        &database,
        "job-current-owner",
        current_instance,
        "2000-01-01T00:00:00Z",
    );

    assert_eq!(
        generation::recover_interrupted_jobs_for_instance(&paths, &database, current_instance,)
            .unwrap(),
        0
    );
    assert_eq!(
        database.generation_job_status("job-current-owner").unwrap(),
        Some(GenerationJobStatus::Pending)
    );
    database
        .update_generation_job("job-current-owner", GenerationJobStatus::Completed, None)
        .unwrap();

    create_owned_job(&database, &paths, "job-dead-owner", "instance-dead");
    set_owner_and_heartbeat(
        &database,
        "job-dead-owner",
        "instance-dead",
        "2000-01-01T00:00:00Z",
    );
    let marker = RuntimeMarker {
        schema_version: RUNTIME_MARKER_SCHEMA_VERSION.to_string(),
        pid: std::process::id(),
        process_start: "2026-07-10T00:00:00Z".to_string(),
        instance_id: current_instance.to_string(),
        http_port: 1,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&marker).unwrap(),
    )
    .unwrap();

    assert_eq!(
        generation::recover_interrupted_jobs_for_instance(&paths, &database, current_instance,)
            .unwrap(),
        1
    );
    assert_eq!(
        database.generation_job_status("job-dead-owner").unwrap(),
        Some(GenerationJobStatus::Failed)
    );
    let messages = generation::read_messages(&paths, "job-dead-owner").unwrap();
    assert_eq!(
        messages
            .iter()
            .filter(|message| message["kind"] == "generation_failed")
            .count(),
        1
    );
}

#[test]
fn message_wait_revision_uses_database_sequence() {
    let (_temp, paths, database) = ready();
    create_owned_job(
        &database,
        &paths,
        "job-message-revision",
        "instance-current",
    );
    generation::cancel_generation(&paths, &database, "job-message-revision").unwrap();
    let state = CoreState::new(paths.clone()).with_instance_id("instance-current");
    let first = handle_request(
        &state,
        request(
            "generation.messages.wait",
            json!({
                "job_id": "job-message-revision",
                "after_revision": "0",
                "timeout_ms": 250
            }),
        ),
    )
    .unwrap();
    assert_eq!(first["changed"], true);
    let revision = first["revision"].as_str().unwrap().to_string();

    let path = paths
        .jobs_dir
        .join("job-message-revision")
        .join("messages.jsonl");
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    writeln!(file).unwrap();
    let unchanged = handle_request(
        &state,
        request(
            "generation.messages.wait",
            json!({
                "job_id": "job-message-revision",
                "after_revision": revision,
                "timeout_ms": 250
            }),
        ),
    )
    .unwrap();

    assert_eq!(unchanged["changed"], false);
    assert_eq!(unchanged["revision"], revision);
}
