use petcore::db::Database;
use petcore::generation::{cancel_generation, read_messages};
use petcore::paths::AppPaths;
use petcore_types::{GenerationForm, QualityLevel};
use serde_json::json;
use std::fs;

fn ready_job() -> (tempfile::TempDir, AppPaths, Database, String) {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    let job_id = "job_jsonl_recovery".to_string();
    let job_dir = paths.jobs_dir.join(&job_id);
    fs::create_dir_all(&job_dir).unwrap();
    database
        .create_generation_job(
            &job_id,
            &GenerationForm {
                description: "JSONL recovery".to_string(),
                style: "半写实".to_string(),
                quality: QualityLevel::Standard,
                reference_images: Vec::new(),
            },
            &job_dir,
        )
        .unwrap();
    (temp, paths, database, job_id)
}

fn message(content: &str) -> String {
    json!({
        "role": "assistant",
        "content": content,
        "progress": 0.25,
        "created_at": "2026-07-10T00:00:00Z"
    })
    .to_string()
}

#[test]
fn corrupt_complete_line_becomes_bounded_diagnostic_and_keeps_later_records() {
    let (_temp, paths, _database, job_id) = ready_job();
    let secret = "SECRET-PROMPT-MUST-NOT-LEAK";
    fs::write(
        paths.jobs_dir.join(&job_id).join("messages.jsonl"),
        format!(
            "{}\n{{broken:{secret}}}\n{}\n",
            message("before"),
            message("after")
        ),
    )
    .unwrap();

    let messages = read_messages(&paths, &job_id).unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[0]["content"], "before");
    assert_eq!(messages[1]["kind"], "jsonl_diagnostic");
    assert_eq!(messages[2]["content"], "after");
    assert!(!serde_json::to_string(&messages).unwrap().contains(secret));
}

#[test]
fn append_after_truncated_tail_repairs_framing_before_new_message() {
    let (_temp, paths, database, job_id) = ready_job();
    let path = paths.jobs_dir.join(&job_id).join("messages.jsonl");
    fs::write(
        &path,
        format!("{}\n{{\"role\":\"assistant\"", message("before")),
    )
    .unwrap();

    cancel_generation(&paths, &database, &job_id).unwrap();

    let content = fs::read_to_string(&path).unwrap();
    assert!(content.ends_with('\n'));
    assert!(
        content
            .lines()
            .all(|line| serde_json::from_str::<serde_json::Value>(line).is_ok()),
        "repaired log still contains malformed framing: {content}"
    );
    let messages = read_messages(&paths, &job_id).unwrap();
    assert_eq!(messages.last().unwrap()["kind"], "generation_canceled");
    assert!(messages
        .iter()
        .any(|message| message["kind"] == "jsonl_diagnostic"));
}

#[test]
fn legacy_messages_receive_stable_ids() {
    let (_temp, paths, _database, job_id) = ready_job();
    fs::write(
        paths.jobs_dir.join(&job_id).join("messages.jsonl"),
        format!("{}\n{}\n", message("one"), message("two")),
    )
    .unwrap();

    let first = read_messages(&paths, &job_id).unwrap();
    let second = read_messages(&paths, &job_id).unwrap();
    assert!(first.iter().all(|message| message["id"].as_str().is_some()));
    assert_eq!(
        first
            .iter()
            .map(|message| message["id"].clone())
            .collect::<Vec<_>>(),
        second
            .iter()
            .map(|message| message["id"].clone())
            .collect::<Vec<_>>()
    );
}

#[test]
fn non_object_jsonl_record_is_quarantined_without_echoing_content() {
    let (_temp, paths, _database, job_id) = ready_job();
    let secret = "VALID_JSON_SECRET_MUST_NOT_LEAK";
    fs::write(
        paths.jobs_dir.join(&job_id).join("messages.jsonl"),
        format!("[\"{secret}\"]\n"),
    )
    .unwrap();

    let messages = read_messages(&paths, &job_id).unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["kind"], "jsonl_diagnostic");
    assert_eq!(messages[0]["diagnostic"]["error_category"], "shape");
    assert!(!serde_json::to_string(&messages).unwrap().contains(secret));
}
