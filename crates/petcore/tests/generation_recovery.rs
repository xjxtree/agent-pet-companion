use image::{ImageBuffer, ImageFormat, Rgba};
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
use std::os::unix::fs::symlink;

fn form() -> GenerationForm {
    GenerationForm {
        description: "Recoverable generation".to_string(),
        style: "pixel".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
        native_fps: petcore_types::DEFAULT_NATIVE_FPS,
        state_durations_ms: petcore_types::default_state_durations_ms(),
    }
}

fn form_with_references(reference_images: Vec<String>) -> GenerationForm {
    GenerationForm {
        reference_images,
        ..form()
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
    create_owned_job_with_form(database, paths, job_id, owner_instance_id, &form());
}

fn create_owned_job_with_form(
    database: &Database,
    paths: &AppPaths,
    job_id: &str,
    owner_instance_id: &str,
    form: &GenerationForm,
) {
    let job_dir = paths.jobs_dir.join(job_id);
    fs::create_dir_all(&job_dir).unwrap();
    database
        .create_generation_job_for_instance(job_id, form, &job_dir, None, owner_instance_id)
        .unwrap();
}

fn png(path: &std::path::Path, color: [u8; 4]) {
    ImageBuffer::from_pixel(8, 8, Rgba(color))
        .save_with_format(path, ImageFormat::Png)
        .unwrap();
}

fn write_staged_form(paths: &AppPaths, job_id: &str, original: &GenerationForm) -> String {
    let reference_dir = paths.jobs_dir.join(job_id).join("input/references");
    fs::create_dir_all(&reference_dir).unwrap();
    let staged_reference = reference_dir.join("reference-00.png");
    fs::copy(&original.reference_images[0], &staged_reference).unwrap();
    let staged = GenerationForm {
        reference_images: vec![staged_reference.display().to_string()],
        ..original.clone()
    };
    fs::write(
        paths.jobs_dir.join(job_id).join("form.staged.json"),
        serde_json::to_vec_pretty(&staged).unwrap(),
    )
    .unwrap();
    staged_reference.display().to_string()
}

fn mkfifo(path: &std::path::Path) {
    let status = std::process::Command::new("/usr/bin/mkfifo")
        .arg(path)
        .status()
        .unwrap();
    assert!(status.success());
}

fn latest_with_timeout(state: CoreState) -> Value {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = sender.send(handle_request(
            &state,
            request("generation.latest", json!({})),
        ));
    });
    receiver
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("generation.latest must not block on a non-regular recovery file")
        .unwrap()
}

fn complete_job(database: &Database, job_id: &str, pet_id: &str) {
    database
        .append_generation_message(
            job_id,
            "assistant",
            Some("generation_completed"),
            "done",
            1.0,
            Some(GenerationJobStatus::Completed),
            Some(pet_id),
        )
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
        native_fps: petcore_types::DEFAULT_NATIVE_FPS,
        state_durations_ms: petcore_types::default_state_durations_ms(),
        petpack_path: package.display().to_string(),
        cover_path: cover.display().to_string(),
        origin: PetOrigin::GeneratedByPetcoreJob,
        generator: Some("codex".to_string()),
        provenance: Some("verified".to_string()),
        revision_id: None,
        revision_count: 0,
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
fn legacy_completed_job_without_structured_result_keeps_compatible_null_fields() {
    let (_temp, paths, database) = ready();
    create_owned_job(
        &database,
        &paths,
        "job-legacy-completed",
        "instance-current",
    );
    database
        .append_generation_message(
            "job-legacy-completed",
            "assistant",
            Some("generation_completed"),
            "done",
            1.0,
            Some(GenerationJobStatus::Completed),
            Some("pet-legacy"),
        )
        .unwrap();
    let state = CoreState::new(paths);

    let terminal = handle_request(
        &state,
        request(
            "generation.messages.wait",
            json!({
                "job_id": "job-legacy-completed",
                "after_revision": "",
                "timeout_ms": 250
            }),
        ),
    )
    .unwrap();
    assert_eq!(terminal["result_pet_id"], "pet-legacy");
    assert!(terminal["revision_id"].is_null());
    assert!(terminal["validation_summary"].is_null());

    let history = handle_request(
        &state,
        request("generation.for_pet", json!({ "pet_id": "pet-legacy" })),
    )
    .unwrap();
    assert_eq!(history["result_pet_id"], "pet-legacy");
    assert!(history["revision_id"].is_null());
    assert!(history["validation_summary"].is_null());
}

#[test]
fn latest_generation_recovers_a_canceled_create_without_a_result_pet_after_restart() {
    let (_temp, paths, database) = ready();
    let empty_state = CoreState::new(paths.clone());
    let empty = handle_request(&empty_state, request("generation.latest", json!({}))).unwrap();
    assert_eq!(empty["found"], false);
    assert_eq!(empty["messages"], json!([]));

    create_owned_job(
        &database,
        &paths,
        "job-canceled-without-pet",
        "instance-original",
    );
    generation::cancel_generation(&paths, &database, "job-canceled-without-pet").unwrap();
    drop(empty_state);
    drop(database);

    let restarted = CoreState::new(paths);
    restarted.ensure_ready().unwrap();
    let latest = handle_request(&restarted, request("generation.latest", json!({}))).unwrap();

    assert_eq!(latest["found"], true);
    assert_eq!(latest["job_id"], "job-canceled-without-pet");
    assert_eq!(latest["status"], "canceled");
    assert!(latest["pet_id"].is_null());
    assert!(latest["result_pet_id"].is_null());
    assert_eq!(latest["form"]["description"], "Recoverable generation");
    assert!(latest["message_revision"]
        .as_str()
        .is_some_and(|value| value.parse::<u64>().is_ok_and(|revision| revision > 0)));
    assert!(latest["messages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|message| message["kind"] == "generation_canceled"));
}

#[test]
fn latest_generation_rejects_unexpected_parameters() {
    let (_temp, paths, _database) = ready();
    let state = CoreState::new(paths);

    let error = handle_request(
        &state,
        request("generation.latest", json!({ "pet_id": "not-accepted" })),
    )
    .unwrap_err()
    .to_string();

    assert!(error.contains("does not accept param pet_id"), "{error}");
}

#[test]
fn recovery_snapshots_use_only_the_validated_staged_reference_copy() {
    let (temp, paths, database) = ready();
    let original_path = temp.path().join("ORIGINAL_REFERENCE_MUST_NOT_LEAK.png");
    png(&original_path, [20, 40, 60, 255]);
    let original = form_with_references(vec![original_path.display().to_string()]);
    create_owned_job_with_form(
        &database,
        &paths,
        "job-staged-reference",
        "instance-current",
        &original,
    );
    let staged_path = write_staged_form(&paths, "job-staged-reference", &original);
    let state = CoreState::new(paths.clone()).with_instance_id("instance-current");

    let active = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(
        active["active_generation"]["form"]["reference_images"],
        json!([staged_path.clone()])
    );
    assert_eq!(
        active["active_generation"]["reference_reselection_count"],
        0
    );
    assert!(!serde_json::to_string(&active)
        .unwrap()
        .contains(&original_path.display().to_string()));

    let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();
    assert_eq!(
        latest["form"]["reference_images"],
        json!([staged_path.clone()])
    );
    assert_eq!(latest["reference_reselection_count"], 0);
    assert!(!serde_json::to_string(&latest)
        .unwrap()
        .contains(&original_path.display().to_string()));

    complete_job(&database, "job-staged-reference", "pet-staged-reference");
    let by_pet = handle_request(
        &state,
        request(
            "generation.for_pet",
            json!({ "pet_id": "pet-staged-reference" }),
        ),
    )
    .unwrap();
    assert_eq!(by_pet["form"]["reference_images"], json!([staged_path]));
    assert_eq!(by_pet["reference_reselection_count"], 0);
    assert!(!serde_json::to_string(&by_pet)
        .unwrap()
        .contains(&original_path.display().to_string()));
}

#[test]
fn recovery_snapshots_require_reference_reselection_before_staging() {
    let (temp, paths, database) = ready();
    let original_path = temp.path().join("PRESTAGING_REFERENCE_MUST_NOT_LEAK.png");
    png(&original_path, [80, 100, 120, 255]);
    let original = form_with_references(vec![original_path.display().to_string()]);
    create_owned_job_with_form(
        &database,
        &paths,
        "job-prestaging-reference",
        "instance-current",
        &original,
    );
    let state = CoreState::new(paths).with_instance_id("instance-current");

    let active = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(
        active["active_generation"]["form"]["reference_images"],
        json!([])
    );
    assert_eq!(
        active["active_generation"]["reference_reselection_count"],
        1
    );
    assert!(!serde_json::to_string(&active)
        .unwrap()
        .contains(&original_path.display().to_string()));

    let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();
    assert_eq!(latest["form"]["reference_images"], json!([]));
    assert_eq!(latest["reference_reselection_count"], 1);
    assert!(!serde_json::to_string(&latest)
        .unwrap()
        .contains(&original_path.display().to_string()));
}

#[test]
fn recovery_snapshot_keeps_full_image_decode_off_the_state_wait_hot_path() {
    let (temp, paths, database) = ready();
    let original_path = temp.path().join("ORIGINAL_HEADER_ONLY_REFERENCE.png");
    png(&original_path, [30, 60, 90, 255]);
    let original = form_with_references(vec![original_path.display().to_string()]);
    create_owned_job_with_form(
        &database,
        &paths,
        "job-header-only-reference",
        "instance-current",
        &original,
    );
    let job_dir = paths.jobs_dir.join("job-header-only-reference");
    let reference_dir = job_dir.join("input/references");
    fs::create_dir_all(&reference_dir).unwrap();
    let staged_reference = reference_dir.join("reference-00.png");
    // This has a valid PNG signature but is intentionally not a decodable PNG.
    // Recovery should perform only its cheap descriptor/header gate; the real
    // generation/retry path remains responsible for complete image decoding.
    fs::write(
        &staged_reference,
        [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0],
    )
    .unwrap();
    let staged = GenerationForm {
        reference_images: vec![staged_reference.display().to_string()],
        ..original
    };
    fs::write(
        job_dir.join("form.staged.json"),
        serde_json::to_vec_pretty(&staged).unwrap(),
    )
    .unwrap();
    let state = CoreState::new(paths);

    let waited = handle_request(
        &state,
        request(
            "state.wait",
            json!({ "after_revision": "-1", "timeout_ms": 250 }),
        ),
    )
    .unwrap();

    assert_eq!(
        waited["active_generation"]["form"]["reference_images"],
        json!([staged_reference.display().to_string()])
    );
    assert_eq!(
        waited["active_generation"]["reference_reselection_count"],
        0
    );
}

#[test]
fn recovery_snapshot_degrades_unsafe_or_corrupt_staged_references_without_leaking() {
    enum InvalidStaging {
        StagedFormSymlink,
        StagedFormHardLink,
        CorruptStagedForm,
        MismatchedStagedForm,
        ReferenceSymlink,
        CorruptReference,
        HardLinkedReference,
    }

    for (case_index, invalid) in [
        InvalidStaging::StagedFormSymlink,
        InvalidStaging::StagedFormHardLink,
        InvalidStaging::CorruptStagedForm,
        InvalidStaging::MismatchedStagedForm,
        InvalidStaging::ReferenceSymlink,
        InvalidStaging::CorruptReference,
        InvalidStaging::HardLinkedReference,
    ]
    .into_iter()
    .enumerate()
    {
        let (temp, paths, database) = ready();
        let job_id = format!("job-invalid-staging-{case_index}");
        let original_path = temp
            .path()
            .join(format!("UNSAFE_REFERENCE_MUST_NOT_LEAK_{case_index}.png"));
        png(&original_path, [140, 160, 180, 255]);
        let original = form_with_references(vec![original_path.display().to_string()]);
        create_owned_job_with_form(&database, &paths, &job_id, "instance-current", &original);
        let job_dir = paths.jobs_dir.join(&job_id);
        let reference_dir = job_dir.join("input/references");
        fs::create_dir_all(&reference_dir).unwrap();
        let staged_reference = reference_dir.join("reference-00.png");
        let staged = GenerationForm {
            reference_images: vec![staged_reference.display().to_string()],
            ..original.clone()
        };
        let staged_form_path = job_dir.join("form.staged.json");

        match invalid {
            InvalidStaging::StagedFormSymlink => {
                fs::copy(&original_path, &staged_reference).unwrap();
                let outside_form = temp.path().join("outside-staged-form.json");
                fs::write(&outside_form, serde_json::to_vec_pretty(&staged).unwrap()).unwrap();
                symlink(outside_form, staged_form_path).unwrap();
            }
            InvalidStaging::StagedFormHardLink => {
                fs::copy(&original_path, &staged_reference).unwrap();
                let outside_form = temp.path().join("hard-linked-staged-form.json");
                fs::write(&outside_form, serde_json::to_vec_pretty(&staged).unwrap()).unwrap();
                fs::hard_link(outside_form, staged_form_path).unwrap();
            }
            InvalidStaging::CorruptStagedForm => {
                fs::copy(&original_path, &staged_reference).unwrap();
                fs::write(staged_form_path, b"{not-json").unwrap();
            }
            InvalidStaging::MismatchedStagedForm => {
                fs::copy(&original_path, &staged_reference).unwrap();
                let mismatched = GenerationForm {
                    description: "tampered description".to_string(),
                    ..staged
                };
                fs::write(
                    staged_form_path,
                    serde_json::to_vec_pretty(&mismatched).unwrap(),
                )
                .unwrap();
            }
            InvalidStaging::ReferenceSymlink => {
                symlink(&original_path, &staged_reference).unwrap();
                fs::write(
                    staged_form_path,
                    serde_json::to_vec_pretty(&staged).unwrap(),
                )
                .unwrap();
            }
            InvalidStaging::CorruptReference => {
                fs::write(&staged_reference, b"not-a-png").unwrap();
                fs::write(
                    staged_form_path,
                    serde_json::to_vec_pretty(&staged).unwrap(),
                )
                .unwrap();
            }
            InvalidStaging::HardLinkedReference => {
                fs::hard_link(&original_path, &staged_reference).unwrap();
                fs::write(
                    staged_form_path,
                    serde_json::to_vec_pretty(&staged).unwrap(),
                )
                .unwrap();
            }
        }

        let state = CoreState::new(paths).with_instance_id("instance-current");
        let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();
        assert_eq!(latest["form"]["reference_images"], json!([]));
        assert_eq!(latest["reference_reselection_count"], 1);
        assert!(!serde_json::to_string(&latest)
            .unwrap()
            .contains(&original_path.display().to_string()));
    }
}

#[test]
fn recovery_snapshot_rejects_fifo_staged_form_without_blocking() {
    let (temp, paths, database) = ready();
    let original_path = temp.path().join("FIFO_FORM_REFERENCE_MUST_NOT_LEAK.png");
    png(&original_path, [50, 100, 150, 255]);
    let original = form_with_references(vec![original_path.display().to_string()]);
    create_owned_job_with_form(
        &database,
        &paths,
        "job-fifo-staged-form",
        "instance-current",
        &original,
    );
    mkfifo(&paths.jobs_dir.join("job-fifo-staged-form/form.staged.json"));

    let latest = latest_with_timeout(CoreState::new(paths));

    assert_eq!(latest["form"]["reference_images"], json!([]));
    assert_eq!(latest["reference_reselection_count"], 1);
    assert!(!serde_json::to_string(&latest)
        .unwrap()
        .contains(&original_path.display().to_string()));
}

#[test]
fn recovery_snapshot_rejects_fifo_reference_without_blocking() {
    let (temp, paths, database) = ready();
    let original_path = temp.path().join("FIFO_STAGED_REFERENCE_MUST_NOT_LEAK.png");
    png(&original_path, [60, 120, 180, 255]);
    let original = form_with_references(vec![original_path.display().to_string()]);
    create_owned_job_with_form(
        &database,
        &paths,
        "job-fifo-reference",
        "instance-current",
        &original,
    );
    let job_dir = paths.jobs_dir.join("job-fifo-reference");
    let reference_dir = job_dir.join("input/references");
    fs::create_dir_all(&reference_dir).unwrap();
    let staged_reference = reference_dir.join("reference-00.png");
    mkfifo(&staged_reference);
    let staged = GenerationForm {
        reference_images: vec![staged_reference.display().to_string()],
        ..original
    };
    fs::write(
        job_dir.join("form.staged.json"),
        serde_json::to_vec_pretty(&staged).unwrap(),
    )
    .unwrap();

    let latest = latest_with_timeout(CoreState::new(paths));

    assert_eq!(latest["form"]["reference_images"], json!([]));
    assert_eq!(latest["reference_reselection_count"], 1);
    assert!(!serde_json::to_string(&latest)
        .unwrap()
        .contains(&original_path.display().to_string()));
}

#[test]
fn recovery_reference_reselection_count_is_bounded() {
    let (_temp, paths, database) = ready();
    let original_paths = (0..10)
        .map(|index| format!("/private/original-reference-{index}.png"))
        .collect::<Vec<_>>();
    let original = form_with_references(original_paths.clone());
    create_owned_job_with_form(
        &database,
        &paths,
        "job-too-many-references",
        "instance-current",
        &original,
    );
    let state = CoreState::new(paths);

    let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();

    assert_eq!(latest["form"]["reference_images"], json!([]));
    assert_eq!(latest["reference_reselection_count"], 4);
    let encoded = serde_json::to_string(&latest).unwrap();
    assert!(original_paths.iter().all(|path| !encoded.contains(path)));
}

#[test]
fn latest_generation_recovers_failed_create_without_result_pet() {
    let (_temp, paths, database) = ready();
    create_owned_job(
        &database,
        &paths,
        "job-failed-without-pet",
        "instance-current",
    );
    database
        .append_generation_message(
            "job-failed-without-pet",
            "assistant",
            Some("generation_failed"),
            "failed",
            1.0,
            Some(GenerationJobStatus::Failed),
            None,
        )
        .unwrap();
    let state = CoreState::new(paths);

    let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();

    assert_eq!(latest["found"], true);
    assert_eq!(latest["status"], "failed");
    assert!(latest["result_pet_id"].is_null());
    assert_eq!(latest["reference_reselection_count"], 0);
}

#[test]
fn latest_generation_recovers_completed_create_without_result_pet() {
    let (_temp, paths, database) = ready();
    create_owned_job(
        &database,
        &paths,
        "job-completed-without-pet",
        "instance-current",
    );
    database
        .append_generation_message(
            "job-completed-without-pet",
            "assistant",
            Some("generation_completed"),
            "completed",
            1.0,
            Some(GenerationJobStatus::Completed),
            None,
        )
        .unwrap();
    let state = CoreState::new(paths);

    let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();

    assert_eq!(latest["found"], true);
    assert_eq!(latest["status"], "completed");
    assert!(latest["result_pet_id"].is_null());
    assert!(latest["revision_id"].is_null());
    assert!(latest["validation_summary"].is_null());
}

#[test]
fn latest_generation_returns_durable_completed_result_metadata() {
    let (_temp, paths, database) = ready();
    create_owned_job(
        &database,
        &paths,
        "job-completed-metadata",
        "instance-current",
    );
    complete_job(
        &database,
        "job-completed-metadata",
        "pet-completed-metadata",
    );
    fs::write(
        paths
            .jobs_dir
            .join("job-completed-metadata")
            .join("result.json"),
        br#"{"result_pet_id":"pet-completed-metadata","revision_id":"rev_0123456789abcdef0123456789abcdef","validation_summary":{"ok":true,"state_count":7,"frame_count":120,"warning_count":2}}"#,
    )
    .unwrap();
    let state = CoreState::new(paths);

    let latest = handle_request(&state, request("generation.latest", json!({}))).unwrap();

    assert_eq!(latest["status"], "completed");
    assert_eq!(latest["result_pet_id"], "pet-completed-metadata");
    assert_eq!(
        latest["revision_id"],
        "rev_0123456789abcdef0123456789abcdef"
    );
    assert_eq!(
        latest["validation_summary"],
        json!({
            "ok": true,
            "state_count": 7,
            "frame_count": 120,
            "warning_count": 2
        })
    );
}

#[test]
fn completed_result_rejects_symlink_leaf() {
    let (temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-symlink-result", "instance-current");
    complete_job(&database, "job-symlink-result", "pet-symlink");
    let outside = temp.path().join("outside-result.json");
    fs::write(
        &outside,
        br#"{"result_pet_id":"pet-symlink","revision_id":"rev_0123456789abcdef0123456789abcdef","validation_summary":{"ok":true,"state_count":7,"frame_count":120,"warning_count":0}}"#,
    )
    .unwrap();
    symlink(
        &outside,
        paths
            .jobs_dir
            .join("job-symlink-result")
            .join("result.json"),
    )
    .unwrap();

    let error = generation::read_generation_result(&paths, &database, "job-symlink-result")
        .unwrap_err()
        .to_string();

    assert!(error.contains("bounded regular file"), "{error}");
}

#[test]
fn completed_result_rejects_oversized_file() {
    let (_temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-large-result", "instance-current");
    complete_job(&database, "job-large-result", "pet-large");
    fs::write(
        paths.jobs_dir.join("job-large-result").join("result.json"),
        vec![b' '; 64 * 1024 + 1],
    )
    .unwrap();

    let error = generation::read_generation_result(&paths, &database, "job-large-result")
        .unwrap_err()
        .to_string();

    assert!(error.contains("bounded regular file"), "{error}");
}

#[test]
fn completed_result_rejects_tampered_identity_and_shape() {
    let (_temp, paths, database) = ready();
    create_owned_job(&database, &paths, "job-tampered-result", "instance-current");
    complete_job(&database, "job-tampered-result", "pet-expected");
    fs::write(
        paths
            .jobs_dir
            .join("job-tampered-result")
            .join("result.json"),
        br#"{"result_pet_id":"pet-other","revision_id":"pet-other","validation_summary":{"ok":false,"state_count":999,"frame_count":0,"warning_count":99999}}"#,
    )
    .unwrap();

    let error = generation::read_generation_result(&paths, &database, "job-tampered-result")
        .unwrap_err()
        .to_string();

    assert!(error.contains("pet id does not match"), "{error}");
}

#[test]
fn completed_result_rejects_a_noncontract_total_frame_count() {
    let (_temp, paths, database) = ready();
    create_owned_job(
        &database,
        &paths,
        "job-invalid-frame-total",
        "instance-current",
    );
    complete_job(&database, "job-invalid-frame-total", "pet-expected");
    fs::write(
        paths
            .jobs_dir
            .join("job-invalid-frame-total")
            .join("result.json"),
        br#"{"result_pet_id":"pet-expected","revision_id":"rev_0123456789abcdef0123456789abcdef","validation_summary":{"ok":true,"state_count":7,"frame_count":168,"warning_count":0}}"#,
    )
    .unwrap();

    let error = generation::read_generation_result(&paths, &database, "job-invalid-frame-total")
        .unwrap_err()
        .to_string();

    assert!(error.contains("structural validation"), "{error}");
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
