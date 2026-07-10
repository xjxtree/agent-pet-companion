use crate::db::Database;
use crate::paths::AppPaths;
use crate::pet_revision::rollback_imported_revision;
use crate::petpack::{
    build_petpack, import_petpack_with_origin, validate_petpack_path, write_generated_petpack_dir,
    write_skill_generated_petpack_dir, GENERATED_FRAMES_PER_STATE,
};
use crate::reference_images::validate_reference_inputs;
use crate::{app_server, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    GenerationForm, GenerationJobStatus, GenerationMessageRecord, PetManifest, PetOrigin,
    PetSummary, PETPACK_SCHEMA_VERSION, REQUIRED_STATES,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const KIND_GENERATION_COMPLETED: &str = "generation_completed";
const KIND_GENERATION_FAILED: &str = "generation_failed";
const KIND_GENERATION_CANCELED: &str = "generation_canceled";
const KIND_INPUT_REQUEST: &str = "input_request";
static GENERATION_LIFECYCLE_LOCK: Mutex<()> = Mutex::new(());
static MESSAGE_LOG_LOCK: Mutex<()> = Mutex::new(());
const GENERATION_OWNER_STALE_SECONDS: i64 = 30;

pub fn start_generation(
    paths: &AppPaths,
    database: &Database,
    form: GenerationForm,
) -> Result<String> {
    start_generation_for_instance(paths, database, form, "standalone")
}

pub fn start_generation_for_instance(
    paths: &AppPaths,
    database: &Database,
    form: GenerationForm,
    owner_instance_id: &str,
) -> Result<String> {
    recover_interrupted_jobs_for_instance(paths, database, owner_instance_id)?;
    start_generation_with_retry(paths, database, form, None, owner_instance_id)
}

pub fn retry_generation(
    paths: &AppPaths,
    database: &Database,
    retry_of_job_id: &str,
    form: Option<GenerationForm>,
) -> Result<String> {
    retry_generation_for_instance(paths, database, retry_of_job_id, form, "standalone")
}

pub fn retry_generation_for_instance(
    paths: &AppPaths,
    database: &Database,
    retry_of_job_id: &str,
    form: Option<GenerationForm>,
    owner_instance_id: &str,
) -> Result<String> {
    recover_interrupted_jobs_for_instance(paths, database, owner_instance_id)?;
    let Some(original) = database.generation_job(retry_of_job_id)? else {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job not found: {retry_of_job_id}"
        )));
    };
    if matches!(
        original.status,
        GenerationJobStatus::Pending
            | GenerationJobStatus::Running
            | GenerationJobStatus::WaitingForUser
    ) {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job {retry_of_job_id} is not retryable while status is {}",
            crate::enum_name(original.status)
        )));
    }
    let retry_form = match form {
        Some(form) => form,
        None => serde_json::from_str(&original.form_json)?,
    };
    start_generation_with_retry(
        paths,
        database,
        retry_form,
        Some(retry_of_job_id),
        owner_instance_id,
    )
}

fn start_generation_with_retry(
    paths: &AppPaths,
    database: &Database,
    form: GenerationForm,
    retry_of_job_id: Option<&str>,
    owner_instance_id: &str,
) -> Result<String> {
    let job_id = new_id("job");
    let job_dir = paths.jobs_dir.join(&job_id);
    fs::create_dir_all(&job_dir)?;
    fs::write(job_dir.join("form.json"), serde_json::to_vec_pretty(&form)?)?;
    if let Err(error) = database.create_generation_job_for_instance(
        &job_id,
        &form,
        &job_dir,
        retry_of_job_id,
        owner_instance_id,
    ) {
        let _ = fs::remove_dir_all(&job_dir);
        return Err(error);
    }

    let paths = paths.clone();
    let database = database.clone();
    let job_id_for_thread = job_id.clone();
    thread::spawn(move || {
        if let Err(error) =
            run_local_petpack_generation(&paths, &database, &job_id_for_thread, &form)
        {
            let _ = fail_generation(
                &paths,
                &database,
                &job_id_for_thread,
                &format!("生成失败：{error}"),
            );
        }
    });

    Ok(job_id)
}

pub fn recover_interrupted_jobs(paths: &AppPaths, database: &Database) -> Result<usize> {
    recover_interrupted_jobs_for_instance(paths, database, "standalone")
}

pub fn recover_interrupted_jobs_for_instance(
    paths: &AppPaths,
    database: &Database,
    current_instance_id: &str,
) -> Result<usize> {
    let mut recovered = 0;
    for job in database.interrupted_generation_job_records()? {
        if !generation_heartbeat_is_stale(&job.heartbeat_at) {
            continue;
        }
        if job.owner_instance_id.as_deref() == Some(current_instance_id) {
            continue;
        }
        if job.owner_instance_id.as_deref().is_some_and(|owner| {
            crate::daemon::instance_lock::runtime_owner_is_healthy(paths, owner)
        }) {
            continue;
        }
        fs::create_dir_all(&job.job_dir)?;
        fail_generation(
            paths,
            database,
            &job.id,
            "生成已中断：PetCore 上次退出时该任务仍在运行，已标记失败。请重新发起生成。",
        )?;
        recovered += 1;
    }
    Ok(recovered)
}

fn generation_heartbeat_is_stale(heartbeat_at: &str) -> bool {
    let Ok(heartbeat_at) = OffsetDateTime::parse(heartbeat_at, &Rfc3339) else {
        return true;
    };
    OffsetDateTime::now_utc() - heartbeat_at
        >= time::Duration::seconds(GENERATION_OWNER_STALE_SECONDS)
}

pub fn read_messages(paths: &AppPaths, job_id: &str) -> Result<Vec<serde_json::Value>> {
    let database = Database::new(paths.db_path.clone());
    database.init()?;
    read_messages_with_database(paths, &database, job_id)
}

pub fn read_messages_with_database(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<Vec<Value>> {
    let path = paths.jobs_dir.join(job_id).join("messages.jsonl");
    let _log = message_log_lock();
    sync_legacy_messages_unlocked(database, &path, job_id)?;
    database
        .generation_messages(job_id)?
        .into_iter()
        .map(|message| serde_json::to_value(message).map_err(Into::into))
        .collect()
}

fn sync_legacy_messages_unlocked(database: &Database, path: &Path, job_id: &str) -> Result<()> {
    if database.generation_job(job_id)?.is_none() || !path.exists() {
        return Ok(());
    }
    let migrated = database.generation_messages_migrated(job_id)?;
    for message in read_messages_unlocked(path, job_id)? {
        let kind = message.get("kind").and_then(Value::as_str);
        if migrated && kind != Some("jsonl_diagnostic") {
            continue;
        }
        let id = message.get("id").and_then(Value::as_str).ok_or_else(|| {
            PetCoreError::Validation(
                "legacy generation message is missing its stable id".to_string(),
            )
        })?;
        database.import_generation_message(
            id,
            job_id,
            message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("system"),
            kind,
            message.get("content").and_then(Value::as_str).unwrap_or(""),
            message
                .get("progress")
                .and_then(Value::as_f64)
                .unwrap_or(0.0),
            message
                .get("created_at")
                .and_then(Value::as_str)
                .unwrap_or(""),
            message.get("diagnostic"),
        )?;
    }
    database.mark_generation_messages_migrated(job_id)
}

fn read_messages_unlocked(path: &Path, job_id: &str) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let bytes = fs::read(path)?;
    let mut messages = Vec::new();
    for (index, line) in bytes.split(|byte| *byte == b'\n').enumerate() {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        match serde_json::from_slice::<Value>(line) {
            Ok(mut message) if message.is_object() => {
                ensure_message_id(&mut message, job_id, index, line);
                messages.push(message);
            }
            Ok(_) => messages.push(jsonl_shape_diagnostic(job_id, index, line)),
            Err(error) => messages.push(jsonl_diagnostic(job_id, index, line, &error)),
        }
    }
    Ok(messages)
}

fn ensure_message_id(message: &mut Value, job_id: &str, index: usize, raw: &[u8]) {
    let Some(object) = message.as_object_mut() else {
        return;
    };
    if object
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.trim().is_empty())
    {
        return;
    }
    object.insert(
        "id".to_string(),
        json!(stable_message_id(job_id, index, raw)),
    );
}

fn stable_message_id(job_id: &str, index: usize, raw: &[u8]) -> String {
    let mut digest = Sha256::new();
    digest.update(job_id.as_bytes());
    digest.update(b"\0");
    digest.update(index.to_le_bytes());
    digest.update(b"\0");
    digest.update(raw);
    format!("msg_legacy_{}", hex::encode(digest.finalize()))
}

fn jsonl_diagnostic(job_id: &str, index: usize, raw: &[u8], error: &serde_json::Error) -> Value {
    let digest = Sha256::digest(raw);
    json!({
        "id": stable_message_id(job_id, index, raw),
        "role": "system",
        "kind": "jsonl_diagnostic",
        "content": format!("已隔离损坏的生成消息记录（第 {} 行）", index + 1),
        "progress": 0.0,
        "created_at": "",
        "diagnostic": {
            "line": index + 1,
            "sha256": hex::encode(digest),
            "error_category": format!("{:?}", error.classify()).to_ascii_lowercase()
        }
    })
}

fn jsonl_shape_diagnostic(job_id: &str, index: usize, raw: &[u8]) -> Value {
    let digest = Sha256::digest(raw);
    json!({
        "id": stable_message_id(job_id, index, raw),
        "role": "system",
        "kind": "jsonl_diagnostic",
        "content": format!("已隔离格式无效的生成消息记录（第 {} 行）", index + 1),
        "progress": 0.0,
        "created_at": "",
        "diagnostic": {
            "line": index + 1,
            "sha256": hex::encode(digest),
            "error_category": "shape"
        }
    })
}

pub fn wait_messages(
    paths: &AppPaths,
    job_id: &str,
    after_revision: &str,
    timeout_ms: u64,
) -> Result<Value> {
    let database = Database::new(paths.db_path.clone());
    database.init()?;
    wait_messages_with_database(paths, &database, job_id, after_revision, timeout_ms)
}

pub fn wait_messages_with_database(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    after_revision: &str,
    timeout_ms: u64,
) -> Result<Value> {
    let timeout_ms = timeout_ms.clamp(250, 30_000);
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let poll_interval = Duration::from_millis(80);

    loop {
        // Discover a legacy JSONL file exactly once before comparing the
        // authoritative database sequence. Subsequent mirror-only changes do
        // not advance the revision.
        let _ = read_messages_with_database(paths, database, job_id)?;
        let revision = messages_revision(database, job_id)?;
        if revision != after_revision {
            return messages_payload(paths, database, job_id, true);
        }
        if Instant::now() >= deadline {
            return messages_payload(paths, database, job_id, false);
        }
        thread::sleep(poll_interval);
    }
}

fn messages_payload(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    changed: bool,
) -> Result<Value> {
    Ok(json!({
        "revision": messages_revision(database, job_id)?,
        "changed": changed,
        "messages": read_messages_with_database(paths, database, job_id)?,
    }))
}

fn messages_revision(database: &Database, job_id: &str) -> Result<String> {
    Ok(database.generation_message_revision(job_id)?.to_string())
}

pub fn cancel_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<Vec<serde_json::Value>> {
    let job_dir = paths.jobs_dir.join(job_id);
    if !job_dir.is_dir() {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job not found: {job_id}"
        )));
    }

    let _lifecycle = lifecycle_lock();
    let status = database.generation_job_status(job_id)?.ok_or_else(|| {
        PetCoreError::InvalidRequest(format!("generation job not found: {job_id}"))
    })?;
    match status {
        GenerationJobStatus::Completed | GenerationJobStatus::Failed => {
            return read_messages(paths, job_id);
        }
        GenerationJobStatus::Canceled => {
            if !is_generation_canceled(paths, job_id) {
                fs::write(cancel_marker_path(paths, job_id), now_rfc3339())?;
            }
            mark_canceled_locked(paths, database, job_id)?;
        }
        GenerationJobStatus::Pending
        | GenerationJobStatus::Running
        | GenerationJobStatus::WaitingForUser => {
            fs::write(cancel_marker_path(paths, job_id), now_rfc3339())?;
            mark_canceled_locked(paths, database, job_id)?;
        }
    }
    read_messages(paths, job_id)
}

pub fn append_user_reply(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    content: &str,
) -> Result<Vec<serde_json::Value>> {
    append_user_reply_for_instance(paths, database, job_id, content, "standalone")
}

pub fn append_user_reply_for_instance(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    content: &str,
    owner_instance_id: &str,
) -> Result<Vec<serde_json::Value>> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return read_messages(paths, job_id);
    }

    let job_dir = paths.jobs_dir.join(job_id);
    if !job_dir.is_dir() {
        return Err(crate::PetCoreError::InvalidRequest(format!(
            "generation job not found: {job_id}"
        )));
    }

    let status = {
        let _lifecycle = lifecycle_lock();
        if is_generation_canceled(paths, job_id) {
            mark_canceled_locked(paths, database, job_id)?;
            return Err(PetCoreError::InvalidRequest(
                "generation was canceled; start a new generation job before sending revision feedback"
                    .to_string(),
            ));
        }
        let status = database.generation_job_status(job_id)?.ok_or_else(|| {
            PetCoreError::InvalidRequest(format!("generation job not found: {job_id}"))
        })?;
        match status {
            GenerationJobStatus::Completed | GenerationJobStatus::WaitingForUser => {}
            GenerationJobStatus::Canceled => {
                return Err(PetCoreError::InvalidRequest(
                    "generation was canceled; start a new generation job before sending revision feedback"
                        .to_string(),
                ));
            }
            GenerationJobStatus::Failed => {
                return Err(PetCoreError::InvalidRequest(
                    "generation failed; start a new generation job before sending revision feedback"
                        .to_string(),
                ));
            }
            GenerationJobStatus::Pending | GenerationJobStatus::Running => {
                return Err(PetCoreError::InvalidRequest(
                    "generation is still running; wait for completion before sending revision feedback"
                        .to_string(),
                ));
            }
        }

        let messages = read_messages(paths, job_id)?;
        let progress = messages
            .last()
            .and_then(|message| message.get("progress").and_then(serde_json::Value::as_f64))
            .unwrap_or(0.0);
        if status == GenerationJobStatus::Completed && progress < 1.0 {
            return Err(PetCoreError::InvalidRequest(
                "generation is still running; wait for completion before sending revision feedback"
                    .to_string(),
            ));
        }

        database.claim_generation_job(job_id, owner_instance_id)?;
        append_message_with_kind(
            paths,
            database,
            job_id,
            "user",
            trimmed,
            0.03,
            None,
            Some(GenerationJobStatus::Running),
            None,
        )?;
        status
    };
    let assistant_message = if status == GenerationJobStatus::WaitingForUser {
        "已收到补充信息，正在恢复 Codex 会话继续生成。"
    } else {
        "已发送调整意见，正在恢复 Codex 会话生成新版本。"
    };
    append_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        assistant_message,
        0.04,
    )?;
    let messages = read_messages(paths, job_id)?;
    let paths = paths.clone();
    let database = database.clone();
    let job_id = job_id.to_string();
    let content = trimmed.to_string();
    thread::spawn(move || {
        if let Err(error) = run_reply_revision(&paths, &database, &job_id, &content) {
            let _ = fail_generation(
                &paths,
                &database,
                &job_id,
                &format!("调整失败：{error}。已保留当前版本。"),
            );
        }
    });
    Ok(messages)
}

fn append_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
) -> Result<()> {
    append_message_with_kind(
        paths, database, job_id, role, content, progress, None, None, None,
    )
}

fn append_completed_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    result_pet_id: &str,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        1.0,
        Some(KIND_GENERATION_COMPLETED),
        Some(GenerationJobStatus::Completed),
        Some(result_pet_id),
    )
}

fn append_failed_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        1.0,
        Some(KIND_GENERATION_FAILED),
        Some(GenerationJobStatus::Failed),
        None,
    )
}

fn append_canceled_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        1.0,
        Some(KIND_GENERATION_CANCELED),
        Some(GenerationJobStatus::Canceled),
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn append_message_with_kind(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
    kind: Option<&str>,
    status_transition: Option<GenerationJobStatus>,
    result_pet_id: Option<&str>,
) -> Result<()> {
    let _log = message_log_lock();
    let job_dir = paths.jobs_dir.join(job_id);
    fs::create_dir_all(&job_dir)?;
    let message_path = job_dir.join("messages.jsonl");
    sync_legacy_messages_unlocked(database, &message_path, job_id)?;
    repair_truncated_message_tail(&message_path, job_id)?;
    let message = database.append_generation_message(
        job_id,
        role,
        kind,
        content,
        progress,
        status_transition,
        result_pet_id,
    )?;
    database.mark_generation_messages_migrated(job_id)?;
    // SQLite is authoritative. The JSONL file remains a best-effort diagnostic
    // mirror, so a mirror write failure must not roll back a committed message.
    let _ = append_message_mirror_unlocked(&message_path, job_id, &message);
    Ok(())
}

fn append_message_mirror_unlocked(
    path: &Path,
    job_id: &str,
    message: &GenerationMessageRecord,
) -> Result<()> {
    if path.exists()
        && read_messages_unlocked(path, job_id)?
            .iter()
            .any(|value| value.get("id").and_then(Value::as_str) == Some(message.id.as_str()))
    {
        return Ok(());
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{}", serde_json::to_string(message)?)?;
    file.flush()?;
    Ok(())
}

fn append_message_if_active(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
) -> Result<()> {
    if is_generation_canceled(paths, job_id) || is_terminal_job(database, job_id)? {
        return Ok(());
    }
    append_message(paths, database, job_id, role, content, progress)
}

fn repair_truncated_message_tail(path: &Path, job_id: &str) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let bytes = fs::read(path)?;
    if bytes.is_empty() || bytes.ends_with(b"\n") {
        return Ok(());
    }
    let boundary = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    let tail = &bytes[boundary..];
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    if serde_json::from_slice::<Value>(tail).is_ok() {
        file.seek(SeekFrom::End(0))?;
        file.write_all(b"\n")?;
        file.flush()?;
        return Ok(());
    }

    file.set_len(boundary as u64)?;
    file.seek(SeekFrom::Start(boundary as u64))?;
    let line_index = bytes[..boundary]
        .iter()
        .filter(|byte| **byte == b'\n')
        .count();
    let parse_error = serde_json::from_slice::<Value>(tail).unwrap_err();
    let diagnostic = jsonl_diagnostic(job_id, line_index, tail, &parse_error);
    writeln!(file, "{}", serde_json::to_string(&diagnostic)?)?;
    file.flush()?;
    Ok(())
}

fn message_log_lock() -> MutexGuard<'static, ()> {
    MESSAGE_LOG_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn cancel_marker_path(paths: &AppPaths, job_id: &str) -> PathBuf {
    paths.jobs_dir.join(job_id).join("canceled")
}

fn is_generation_canceled(paths: &AppPaths, job_id: &str) -> bool {
    cancel_marker_path(paths, job_id).exists()
}

fn lifecycle_lock() -> MutexGuard<'static, ()> {
    GENERATION_LIFECYCLE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn is_terminal_status(status: GenerationJobStatus) -> bool {
    matches!(
        status,
        GenerationJobStatus::Completed
            | GenerationJobStatus::Failed
            | GenerationJobStatus::Canceled
    )
}

fn is_terminal_job(database: &Database, job_id: &str) -> Result<bool> {
    Ok(database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status))
}

fn mark_canceled_locked(paths: &AppPaths, database: &Database, job_id: &str) -> Result<()> {
    append_canceled_message(paths, database, job_id, "assistant", "已取消生成。")?;
    Ok(())
}

fn finish_if_canceled(paths: &AppPaths, database: &Database, job_id: &str) -> Result<bool> {
    if !is_generation_canceled(paths, job_id) {
        return Ok(false);
    }
    let _lifecycle = lifecycle_lock();
    mark_canceled_locked(paths, database, job_id)?;
    Ok(true)
}

fn fail_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    content: &str,
) -> Result<()> {
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(());
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(|status| {
            matches!(
                status,
                GenerationJobStatus::Completed | GenerationJobStatus::Canceled
            )
        })
    {
        return Ok(());
    }
    append_failed_message(paths, database, job_id, "assistant", content)?;
    Ok(())
}

fn mark_running_if_active(paths: &AppPaths, database: &Database, job_id: &str) -> Result<bool> {
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(false);
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status)
    {
        return Ok(false);
    }
    database.update_generation_job(job_id, GenerationJobStatus::Running, None)?;
    Ok(true)
}

fn run_local_petpack_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    form: &GenerationForm,
) -> Result<()> {
    if !mark_running_if_active(paths, database, job_id)? {
        return Ok(());
    }
    let staged_form = stage_reference_images(paths, job_id, form)?;
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let app_server_session = app_server::run_pet_studio_session_with_updates_and_cancel(
        paths,
        job_id,
        &staged_form,
        |update| {
            let _ = append_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                &update.content,
                update.progress,
            );
        },
        || is_generation_canceled(paths, job_id),
    );
    write_app_server_session(paths, job_id, &app_server_session)?;
    if let Some(session_id) = app_server_session
        .get("session_id")
        .and_then(serde_json::Value::as_str)
    {
        database.update_generation_job_session(job_id, session_id)?;
    }
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    if pause_generation_for_input_request(paths, database, job_id, &app_server_session, 0.18)? {
        return Ok(());
    }
    if app_server_session
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        append_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            "AI brief 已进入本次 petpack 元数据。",
            0.145,
        )?;
        append_ai_brief_normalization_message(paths, database, job_id, &app_server_session, 0.146)?;
    } else {
        if skill_full_source_required() {
            ensure_skill_full_source_metadata(paths, job_id, &staged_form, &app_server_session)?;
            match try_import_skill_petpack_source(paths, database, job_id)? {
                SkillPetpackImport::Imported { pet, previous_pet } => {
                    complete_imported_pet(
                        paths,
                        database,
                        job_id,
                        &pet,
                        previous_pet.as_ref(),
                        false,
                        Some((
                            "Codex App Server final response 未完成，但 Pet Studio Skill 已写出可校验 petpack-source，已采用该产物加入宠物库。",
                            0.95,
                        )),
                        "完成，可在宠物库启用。",
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Canceled => return Ok(()),
                SkillPetpackImport::Invalid(error) => {
                    fail_generation(
                        paths,
                        database,
                        job_id,
                        &format!("Pet Studio Skill 已写出 petpack-source，但校验失败：{error}。"),
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Missing => {}
            }
        }
        let detail = app_server_failure_detail(&app_server_session);
        if !local_pet_studio_fallback_enabled() {
            fail_generation(
                paths,
                database,
                job_id,
                &format!("Codex App Server brief turn 未完成：{detail}。请在 Agent 连接中修复 Codex App Server 后重试。"),
            )?;
            return Ok(());
        }

        append_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            &format!("Codex App Server brief turn 未完成：{detail}。已显式启用开发本地 Pet Studio runner，将继续完成打包与校验。"),
            0.12,
        )?;
    }

    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    ensure_skill_full_source_metadata(paths, job_id, &staged_form, &app_server_session)?;
    match try_import_skill_petpack_source(paths, database, job_id)? {
        SkillPetpackImport::Imported { pet, previous_pet } => {
            complete_imported_pet(
                paths,
                database,
                job_id,
                &pet,
                previous_pet.as_ref(),
                false,
                Some((
                    "已采用 Pet Studio Skill 输出的 petpack-source，校验通过并加入宠物库。",
                    0.95,
                )),
                "完成，可在宠物库启用。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Canceled => {
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) if !local_pet_studio_fallback_enabled() => {
            fail_generation(
                paths,
                database,
                job_id,
                &format!("Pet Studio Skill 输出的 petpack-source 不可用：{error}。请在 Agent 连接中修复 Codex App Server / Skill 后重试。"),
            )?;
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) => {
            append_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                &format!("Pet Studio Skill 输出的 petpack-source 不可用：{error}。已显式启用开发本地 Pet Studio materializer。"),
                0.16,
            )?;
        }
        SkillPetpackImport::Missing if external_skill_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在 App Server turn 中创建外部 petpack-source；当前验证要求 external full source mode，因此不会使用内置 Pet Studio materializer。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing
            if skill_full_source_required() && app_server_completed(&app_server_session) =>
        {
            append_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                "Codex App Server 已返回结构化 brief，正在由内置 Pet Studio Skill 写出完整 petpack-source。",
                0.18,
            )?;
            if let Some((pet, previous_pet)) = materialize_internal_skill_petpack(
                paths,
                database,
                job_id,
                &staged_form,
                &app_server_session,
            )? {
                complete_imported_pet(
                    paths,
                    database,
                    job_id,
                    &pet,
                    previous_pet.as_ref(),
                    false,
                    Some((
                        "内置 Pet Studio Skill 已写出 full-source，校验通过并加入宠物库。",
                        0.9,
                    )),
                    "完成，可在宠物库启用。",
                )?;
            }
            return Ok(());
        }
        SkillPetpackImport::Missing if skill_full_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在 App Server turn 中创建 petpack-source；当前验证要求 full source mode，因此不会回退到 Codex brief materializer。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing => {}
    }

    append_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "PetCore 正在根据 Codex AI brief 生成 petpack-source 与动作方案。",
        0.15,
    )?;
    thread::sleep(Duration::from_millis(120));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    append_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "已根据描述、风格和参考图生成 7 个状态动作。",
        0.35,
    )?;
    thread::sleep(Duration::from_millis(120));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    append_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "正在渲染实机 PNG 帧并写入 .petpack source 元数据。",
        0.62,
    )?;

    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let pet_name = derive_pet_name(&staged_form, app_server_session.get("ai_brief"));
    let manifest = write_generated_petpack_dir(
        &source_dir,
        &staged_form,
        &pet_name,
        app_server_session.get("ai_brief"),
        GENERATED_FRAMES_PER_STATE,
    )?;
    write_skill_session(
        paths,
        job_id,
        &source_dir,
        &staged_form,
        &manifest,
        &app_server_session,
    )?;
    let output = paths
        .jobs_dir
        .join(job_id)
        .join(format!("{}.petpack", manifest.id));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let validation = build_petpack(&source_dir, &output)?;
    let Some((pet, previous_pet)) = import_petpack_if_active(
        paths,
        database,
        job_id,
        &output,
        Some(&validation.manifest.id),
        PetOrigin::GeneratedByPetcoreJob,
    )?
    else {
        return Ok(());
    };
    complete_imported_pet(
        paths,
        database,
        job_id,
        &pet,
        previous_pet.as_ref(),
        false,
        Some(("校验通过，已保存 .petpack 并加入宠物库。", 0.9)),
        "完成，可在宠物库启用。",
    )?;
    Ok(())
}

fn run_reply_revision(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    user_message: &str,
) -> Result<()> {
    if !mark_running_if_active(paths, database, job_id)? {
        return Ok(());
    }
    let form = read_generation_form(paths, job_id)?;
    let staged_form = stage_reference_images(paths, job_id, &form)?;
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let previous_session = read_app_server_session(paths, job_id)?.unwrap_or(Value::Null);

    let thread_id = previous_session
        .get("thread_id")
        .and_then(serde_json::Value::as_str);
    let mut render_form = staged_form.clone();
    let mut app_server_session = if let Some(thread_id) = thread_id {
        app_server::run_pet_studio_follow_up_with_updates_and_cancel(
            paths,
            job_id,
            thread_id,
            &staged_form,
            previous_session.get("ai_brief"),
            user_message,
            |update| {
                let _ = append_message_if_active(
                    paths,
                    database,
                    job_id,
                    "assistant",
                    &update.content,
                    update.progress,
                );
            },
            || is_generation_canceled(paths, job_id),
        )
    } else {
        json!({
            "initialized": false,
            "started": false,
            "resumed": false,
            "turn_started": false,
            "completed": false,
            "follow_up": true,
            "checked_at": now_rfc3339(),
            "error": "previous Codex App Server thread id is missing"
        })
    };

    if app_server_session
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        != Some(true)
        && should_retry_revision_with_new_session(&app_server_session)
    {
        append_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            "原 Codex 会话无法恢复，正在基于调整意见开启新的 Pet Studio brief turn。",
            0.06,
        )?;
        render_form = form_with_revision_feedback(&staged_form, user_message);
        app_server_session = app_server::run_pet_studio_session_with_updates_and_cancel(
            paths,
            job_id,
            &render_form,
            |update| {
                let _ = append_message_if_active(
                    paths,
                    database,
                    job_id,
                    "assistant",
                    &update.content,
                    update.progress,
                );
            },
            || is_generation_canceled(paths, job_id),
        );
    }

    write_app_server_session(paths, job_id, &app_server_session)?;
    if let Some(session_id) = app_server_session
        .get("session_id")
        .and_then(serde_json::Value::as_str)
    {
        database.update_generation_job_session(job_id, session_id)?;
    }
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    if pause_generation_for_input_request(paths, database, job_id, &app_server_session, 0.18)? {
        return Ok(());
    }

    if app_server_session
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        != Some(true)
    {
        if skill_full_source_required() {
            ensure_skill_full_source_metadata(paths, job_id, &render_form, &app_server_session)?;
            match try_import_skill_petpack_source(paths, database, job_id)? {
                SkillPetpackImport::Imported { pet, previous_pet } => {
                    complete_imported_pet(
                        paths,
                        database,
                        job_id,
                        &pet,
                        previous_pet.as_ref(),
                        true,
                        None,
                        "Codex App Server final response 未完成，但 Pet Studio Skill 已写出可校验调整版 petpack-source，并已启用。",
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Canceled => return Ok(()),
                SkillPetpackImport::Invalid(error) => {
                    fail_generation(
                        paths,
                        database,
                        job_id,
                        &format!("Pet Studio Skill 已写出调整版 petpack-source，但校验失败：{error}。已保留当前版本。"),
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Missing => {}
            }
        }
        let detail = app_server_session
            .get("error")
            .or_else(|| app_server_session.get("detail"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Codex App Server 暂不可用");
        fail_generation(
            paths,
            database,
            job_id,
            &format!("Codex 调整未完成：{detail}。已保留当前版本。"),
        )?;
        return Ok(());
    }

    append_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "Codex 已完成调整方案，正在重新渲染 petpack。",
        0.35,
    )?;
    append_ai_brief_normalization_message(paths, database, job_id, &app_server_session, 0.36)?;
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    ensure_skill_full_source_metadata(paths, job_id, &render_form, &app_server_session)?;
    match try_import_skill_petpack_source(paths, database, job_id)? {
        SkillPetpackImport::Imported { pet, previous_pet } => {
            complete_imported_pet(
                paths,
                database,
                job_id,
                &pet,
                previous_pet.as_ref(),
                true,
                None,
                "已采用 Pet Studio Skill 输出的调整版 petpack-source，并已启用。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Canceled => {
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) if !local_pet_studio_fallback_enabled() => {
            fail_generation(
                paths,
                database,
                job_id,
                &format!("Pet Studio Skill 输出的调整版 petpack-source 不可用：{error}。已保留当前版本，请在 Agent 连接中修复 Codex App Server / Skill 后重试。"),
            )?;
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) => {
            append_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                &format!("Pet Studio Skill 输出的调整版 petpack-source 不可用：{error}。已显式启用开发本地 Pet Studio materializer。"),
                0.37,
            )?;
        }
        SkillPetpackImport::Missing if external_skill_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在调整 turn 中创建外部 petpack-source；当前验证要求 external full source mode，因此已保留当前版本。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing
            if skill_full_source_required() && app_server_completed(&app_server_session) =>
        {
            append_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                "Codex App Server 已返回调整 brief，正在由内置 Pet Studio Skill 写出完整调整版 petpack-source。",
                0.38,
            )?;
            if let Some((pet, previous_pet)) = materialize_internal_skill_petpack(
                paths,
                database,
                job_id,
                &render_form,
                &app_server_session,
            )? {
                complete_imported_pet(
                    paths,
                    database,
                    job_id,
                    &pet,
                    previous_pet.as_ref(),
                    true,
                    None,
                    "内置 Pet Studio Skill 已写出调整版 full-source，并已启用。",
                )?;
            }
            return Ok(());
        }
        SkillPetpackImport::Missing if skill_full_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在调整 turn 中创建 petpack-source；当前验证要求 full source mode，因此已保留当前版本。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing => {}
    }

    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let pet_name = derive_pet_name(&render_form, app_server_session.get("ai_brief"));
    let manifest = write_generated_petpack_dir(
        &source_dir,
        &render_form,
        &pet_name,
        app_server_session.get("ai_brief"),
        GENERATED_FRAMES_PER_STATE,
    )?;
    write_skill_session(
        paths,
        job_id,
        &source_dir,
        &render_form,
        &manifest,
        &app_server_session,
    )?;
    let output = paths
        .jobs_dir
        .join(job_id)
        .join(format!("{}.petpack", manifest.id));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let validation = build_petpack(&source_dir, &output)?;
    let Some((pet, previous_pet)) = import_petpack_if_active(
        paths,
        database,
        job_id,
        &output,
        Some(&validation.manifest.id),
        PetOrigin::GeneratedByPetcoreJob,
    )?
    else {
        return Ok(());
    };
    complete_imported_pet(
        paths,
        database,
        job_id,
        &pet,
        previous_pet.as_ref(),
        true,
        None,
        "调整版本已保存入库并已启用。",
    )?;
    Ok(())
}

fn read_generation_form(paths: &AppPaths, job_id: &str) -> Result<GenerationForm> {
    let path = paths.jobs_dir.join(job_id).join("form.json");
    if !path.is_file() {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation form not found for job: {job_id}"
        )));
    }
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

#[allow(clippy::large_enum_variant)] // Success carries rollback state; other variants intentionally stay allocation-free.
enum SkillPetpackImport {
    Imported {
        pet: PetSummary,
        previous_pet: Option<PetSummary>,
    },
    Canceled,
    Missing,
    Invalid(String),
}

fn try_import_skill_petpack_source(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<SkillPetpackImport> {
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if !source_dir.join("manifest.json").is_file() {
        return Ok(SkillPetpackImport::Missing);
    }
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(SkillPetpackImport::Canceled);
    }

    match validate_petpack_path(&source_dir) {
        Ok(validation) => {
            if let Err(error) = validate_skill_source_identity(&source_dir) {
                return Ok(SkillPetpackImport::Invalid(error.to_string()));
            }
            write_petcore_validation_artifact(&source_dir, &validation)?;
            let output = paths
                .jobs_dir
                .join(job_id)
                .join(format!("{}.petpack", validation.manifest.id));
            if finish_if_canceled(paths, database, job_id)? {
                return Ok(SkillPetpackImport::Canceled);
            }
            build_petpack(&source_dir, &output)?;
            if let Some((pet, previous_pet)) = import_petpack_if_active(
                paths,
                database,
                job_id,
                &output,
                Some(&validation.manifest.id),
                PetOrigin::VerifiedSkillSource,
            )? {
                Ok(SkillPetpackImport::Imported { pet, previous_pet })
            } else {
                Ok(SkillPetpackImport::Canceled)
            }
        }
        Err(error) => Ok(SkillPetpackImport::Invalid(error.to_string())),
    }
}

fn validate_skill_source_identity(source_dir: &Path) -> Result<()> {
    let metadata_path = source_dir.join("source").join("source.json");
    let metadata: Value = serde_json::from_slice(&fs::read(&metadata_path)?).map_err(|error| {
        PetCoreError::Validation(format!("invalid Skill source/source.json: {error}"))
    })?;
    let generator = metadata
        .get("generator")
        .and_then(Value::as_str)
        .unwrap_or("");
    let provenance = metadata
        .get("provenance")
        .and_then(Value::as_str)
        .unwrap_or("");
    if metadata
        .get("materialized_by")
        .and_then(Value::as_str)
        .is_some()
    {
        return Err(PetCoreError::Validation(
            "Skill petpack-source must be written by the App Server Skill, not a PetCore or CLI materializer"
                .to_string(),
        ));
    }
    if generator != "codex-app-server-skill" || provenance != "skill-full-source" {
        return Err(PetCoreError::Validation(format!(
            "Skill petpack-source must declare generator=codex-app-server-skill and provenance=skill-full-source, got generator={generator:?}, provenance={provenance:?}"
        )));
    }
    if external_skill_source_required() {
        let preview_only = metadata.get("preview_only").and_then(Value::as_bool);
        if preview_only != Some(false) {
            return Err(PetCoreError::Validation(format!(
                "external full source mode requires preview_only=false, got {preview_only:?}"
            )));
        }
        let visual_source = metadata.get("visual_source").and_then(Value::as_str);
        if !matches!(
            visual_source,
            Some("image-generation" | "user-reference-derived")
        ) {
            return Err(PetCoreError::Validation(format!(
                "external full source mode requires visual_source=image-generation or user-reference-derived, got {visual_source:?}"
            )));
        }
        let frames_per_state = metadata
            .get("frames_per_state")
            .and_then(Value::as_u64)
            .unwrap_or_default();
        if frames_per_state < 2 {
            return Err(PetCoreError::Validation(
                "external full source mode requires at least two frames per state".to_string(),
            ));
        }
        if visual_source == Some("user-reference-derived") {
            let visibly_applied = metadata
                .get("reference_visual_influence")
                .and_then(Value::as_bool)
                == Some(true);
            let has_reference = fs::read_dir(source_dir.join("source/references"))
                .ok()
                .into_iter()
                .flatten()
                .filter_map(std::result::Result::ok)
                .any(|entry| entry.path().is_file());
            if !visibly_applied || !has_reference {
                return Err(PetCoreError::Validation(
                    "user-reference-derived source must copy a reference and declare reference_visual_influence=true"
                        .to_string(),
                ));
            }
        }
        validate_external_frame_diversity(source_dir)?;
    }
    Ok(())
}

fn validate_external_frame_diversity(source_dir: &Path) -> Result<()> {
    let mut state_first_frames = std::collections::BTreeSet::new();
    for state in REQUIRED_STATES {
        let state_dir = source_dir.join("assets/frames").join(state.as_str());
        let mut frames = fs::read_dir(&state_dir)?
            .filter_map(std::result::Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
            })
            .collect::<Vec<_>>();
        frames.sort();
        if frames.len() < 2 {
            return Err(PetCoreError::Validation(format!(
                "external full source state {} must contain at least two PNG frames",
                state.as_str()
            )));
        }
        let first = decoded_frame_digest(&frames[0])?;
        let mut state_digests = std::collections::BTreeSet::from([first.clone()]);
        for path in frames.iter().skip(1) {
            state_digests.insert(decoded_frame_digest(path)?);
            if state_digests.len() >= 2 {
                break;
            }
        }
        if state_digests.len() < 2 {
            return Err(PetCoreError::Validation(format!(
                "external full source state {} has no visible frame-to-frame change",
                state.as_str()
            )));
        }
        state_first_frames.insert(first);
    }
    if state_first_frames.len() < 4 {
        return Err(PetCoreError::Validation(
            "external full source states are not visually distinct".to_string(),
        ));
    }
    Ok(())
}

fn decoded_frame_digest(path: &Path) -> Result<String> {
    let image = image::open(path)?.to_rgba8();
    let mut hasher = Sha256::new();
    hasher.update(image.width().to_le_bytes());
    hasher.update(image.height().to_le_bytes());
    hasher.update(image.as_raw());
    Ok(hex::encode(hasher.finalize()))
}

fn ensure_skill_full_source_metadata(
    paths: &AppPaths,
    job_id: &str,
    form: &GenerationForm,
    app_server_session: &Value,
) -> Result<()> {
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if !source_dir.join("manifest.json").is_file() {
        return Ok(());
    }

    if skill_full_source_required() {
        validate_petpack_path(&source_dir)?;
    } else {
        let _ = normalize_skill_manifest(&source_dir, form);
    }

    let metadata_dir = source_dir.join("source");
    fs::create_dir_all(metadata_dir.join("references"))?;

    let metadata_path = metadata_dir.join("source.json");
    let mut metadata = fs::read(&metadata_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();

    metadata
        .entry("created_at".to_string())
        .or_insert_with(|| json!(now_rfc3339()));
    metadata
        .entry("form".to_string())
        .or_insert_with(|| json!(form));
    metadata
        .entry("reference_files".to_string())
        .or_insert_with(|| json!([]));
    metadata
        .entry("codex_app_server".to_string())
        .or_insert_with(|| {
            json!({
                "thread_id": app_server_session.get("thread_id"),
                "turn_id": app_server_session.get("turn_id"),
                "session_id": app_server_session.get("session_id"),
                "completed": app_server_session.get("completed"),
                "command_source": app_server_session.get("command_source")
            })
        });

    fs::write(
        metadata_path,
        serde_json::to_vec_pretty(&Value::Object(metadata))?,
    )?;

    let skill_session_path = metadata_dir.join("skill_session.jsonl");
    if !skill_session_path.is_file() {
        fs::write(
            skill_session_path,
            serde_json::to_string(&json!({
                "event": "skill.loaded",
                "skill": "agent-pet-studio",
                "runner": "codex-app-server",
                "created_at": now_rfc3339()
            }))? + "\n",
        )?;
    }

    Ok(())
}

fn write_petcore_validation_artifact(
    source_dir: &Path,
    validation: &crate::petpack::PetpackValidation,
) -> Result<()> {
    let build_dir = source_dir.join("build");
    fs::create_dir_all(&build_dir)?;
    fs::write(
        build_dir.join("validation.json"),
        serde_json::to_vec_pretty(validation)?,
    )?;
    Ok(())
}

fn normalize_skill_manifest(source_dir: &Path, form: &GenerationForm) -> Result<()> {
    let manifest_path = source_dir.join("manifest.json");
    let mut manifest_json: Value = serde_json::from_slice(&fs::read(&manifest_path)?)?;
    let Some(manifest) = manifest_json.as_object_mut() else {
        return Ok(());
    };

    manifest.insert("schema_version".to_string(), json!(PETPACK_SCHEMA_VERSION));
    let existing_id = manifest
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("pet")
        .to_string();
    manifest.insert("id".to_string(), json!(normalized_pet_id(&existing_id)));
    if manifest
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
    {
        manifest.insert("name".to_string(), json!(derive_pet_name(form, None)));
    }
    if manifest
        .get("style")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
    {
        manifest.insert("style".to_string(), json!(form.style.clone()));
    }
    manifest.insert("quality".to_string(), json!(form.quality));
    manifest.insert("render_size".to_string(), json!(form.quality.render_size()));
    manifest.insert(
        "fps_profiles".to_string(),
        json!({
            "standard": 12,
            "smooth": 20
        }),
    );
    manifest.insert("default_fps_profile".to_string(), json!("standard"));
    if manifest
        .get("created_at")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
    {
        manifest.insert("created_at".to_string(), json!(now_rfc3339()));
    }

    let raw_states = manifest.remove("states");
    manifest.insert("states".to_string(), normalize_manifest_states(raw_states));

    fs::write(manifest_path, serde_json::to_vec_pretty(&manifest_json)?)?;
    Ok(())
}

fn normalized_pet_id(raw_id: &str) -> String {
    let mut suffix = raw_id
        .trim()
        .trim_start_matches("pet_")
        .chars()
        .filter_map(|character| {
            let lowercase = character.to_ascii_lowercase();
            lowercase.is_ascii_alphanumeric().then_some(lowercase)
        })
        .take(48)
        .collect::<String>();
    if suffix.is_empty() {
        return new_id("pet");
    }
    suffix.insert_str(0, "pet_");
    suffix
}

fn normalize_manifest_states(raw_states: Option<Value>) -> Value {
    Value::Array(
        REQUIRED_STATES
            .iter()
            .map(|state| {
                let source = state_value(raw_states.as_ref(), state.as_str());
                let frames_dir = source
                    .and_then(|value| value.get("frames_dir").or_else(|| value.get("framesDir")))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| default_frames_dir(state.as_str()));
                let looped = source
                    .and_then(|value| value.get("loop").or_else(|| value.get("looped")))
                    .and_then(Value::as_bool)
                    .unwrap_or_else(|| default_state_loop(state.as_str()));
                json!({
                    "name": state.as_str(),
                    "frames_dir": frames_dir,
                    "loop": looped
                })
            })
            .collect(),
    )
}

fn state_value<'a>(states: Option<&'a Value>, state_name: &str) -> Option<&'a Value> {
    match states {
        Some(Value::Object(map)) => map.get(state_name),
        Some(Value::Array(values)) => values.iter().find(|value| {
            value
                .get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| name == state_name)
        }),
        _ => None,
    }
}

fn default_frames_dir(state_name: &str) -> &'static str {
    match state_name {
        "idle" => "assets/frames/idle",
        "start" => "assets/frames/start",
        "tool" => "assets/frames/tool",
        "waiting" => "assets/frames/waiting",
        "review" => "assets/frames/review",
        "done" => "assets/frames/done",
        "failed" => "assets/frames/failed",
        _ => "assets/frames/idle",
    }
}

fn default_state_loop(state_name: &str) -> bool {
    !matches!(state_name, "start" | "done")
}

fn materialize_internal_skill_petpack(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    form: &GenerationForm,
    app_server_session: &Value,
) -> Result<Option<(PetSummary, Option<PetSummary>)>> {
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(None);
    }
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let pet_name = derive_pet_name(form, app_server_session.get("ai_brief"));
    let manifest = write_skill_generated_petpack_dir(
        &source_dir,
        form,
        &pet_name,
        app_server_session.get("ai_brief"),
        GENERATED_FRAMES_PER_STATE,
    )?;
    mark_internal_skill_materializer(&source_dir)?;
    write_skill_session(
        paths,
        job_id,
        &source_dir,
        form,
        &manifest,
        app_server_session,
    )?;
    let output = paths
        .jobs_dir
        .join(job_id)
        .join(format!("{}.petpack", manifest.id));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(None);
    }
    let validation = build_petpack(&source_dir, &output)?;
    import_petpack_if_active(
        paths,
        database,
        job_id,
        &output,
        Some(&validation.manifest.id),
        PetOrigin::GeneratedByPetcoreJob,
    )
}

fn mark_internal_skill_materializer(source_dir: &Path) -> Result<()> {
    let source_path = source_dir.join("source").join("source.json");
    let mut source = fs::read(&source_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    source.insert(
        "materialized_by".to_string(),
        json!("petcore-internal-skill-materializer"),
    );
    fs::write(
        source_path,
        serde_json::to_vec_pretty(&Value::Object(source))?,
    )?;

    let validation_path = source_dir.join("build").join("validation.json");
    if validation_path.is_file() {
        let mut validation = fs::read(&validation_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|value| value.as_object().cloned())
            .unwrap_or_default();
        validation.insert(
            "materialized_by".to_string(),
            json!("petcore-internal-skill-materializer"),
        );
        fs::write(
            validation_path,
            serde_json::to_vec_pretty(&Value::Object(validation))?,
        )?;
    }
    Ok(())
}

fn import_petpack_if_active(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    source_path: &Path,
    pet_id_hint: Option<&str>,
    origin: PetOrigin,
) -> Result<Option<(PetSummary, Option<PetSummary>)>> {
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(None);
    }
    let previous_pet = match pet_id_hint {
        Some(pet_id) => database.get_pet(pet_id)?,
        None => None,
    };
    let pet = import_petpack_with_origin(paths, database, source_path, origin)?;
    if finish_if_canceled(paths, database, job_id)? {
        cleanup_canceled_import(paths, database, &pet, previous_pet.as_ref())?;
        return Ok(None);
    }
    Ok(Some((pet, previous_pet)))
}

fn cleanup_canceled_import(
    paths: &AppPaths,
    database: &Database,
    pet: &PetSummary,
    previous_pet: Option<&PetSummary>,
) -> Result<()> {
    rollback_imported_revision(paths, database, pet, previous_pet)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)] // Atomic completion keeps lifecycle and rollback inputs explicit.
fn complete_imported_pet(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    pet: &PetSummary,
    previous_pet: Option<&PetSummary>,
    activate: bool,
    pre_completion_message: Option<(&str, f64)>,
    completion_message: &str,
) -> Result<()> {
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        cleanup_canceled_import(paths, database, pet, previous_pet)?;
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(());
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status)
    {
        cleanup_canceled_import(paths, database, pet, previous_pet)?;
        return Ok(());
    }
    if activate {
        database.activate_pet(&pet.id)?;
    }
    if let Some((content, progress)) = pre_completion_message {
        append_message(paths, database, job_id, "assistant", content, progress)?;
    }
    append_completed_message(
        paths,
        database,
        job_id,
        "assistant",
        completion_message,
        &pet.id,
    )?;
    Ok(())
}

fn stage_reference_images(
    paths: &AppPaths,
    job_id: &str,
    form: &GenerationForm,
) -> Result<GenerationForm> {
    let job_dir = paths.jobs_dir.join(job_id);
    let reference_dir = job_dir.join("input").join("references");
    fs::create_dir_all(&reference_dir)?;

    let references = validate_reference_inputs(&form.reference_images)?;
    let mut staged_paths = Vec::with_capacity(references.len());
    for (index, reference) in references.iter().enumerate() {
        let target = reference_dir.join(format!("reference-{index:02}.{}", reference.extension));
        if !same_file(&reference.source, &target) {
            fs::copy(&reference.source, &target)?;
        }
        staged_paths.push(target.display().to_string());
    }

    let mut staged = form.clone();
    staged.reference_images = staged_paths;
    fs::write(
        job_dir.join("form.staged.json"),
        serde_json::to_vec_pretty(&staged)?,
    )?;
    Ok(staged)
}

fn same_file(left: &Path, right: &Path) -> bool {
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

fn app_server_session_path(paths: &AppPaths, job_id: &str) -> std::path::PathBuf {
    paths.jobs_dir.join(job_id).join("app_server_session.json")
}

fn read_app_server_session(paths: &AppPaths, job_id: &str) -> Result<Option<Value>> {
    let path = app_server_session_path(paths, job_id);
    if !path.is_file() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_slice(&fs::read(path)?)?))
}

fn write_app_server_session(paths: &AppPaths, job_id: &str, session: &Value) -> Result<()> {
    let path = app_server_session_path(paths, job_id);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    write_json_atomic(&path, session)?;
    Ok(())
}

fn write_json_atomic(path: &Path, value: &Value) -> Result<()> {
    let temporary_path = path.with_extension(format!(
        "{}.tmp.{}",
        path.extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("json"),
        std::process::id()
    ));
    fs::write(&temporary_path, serde_json::to_vec_pretty(value)?)?;
    fs::rename(&temporary_path, path).inspect_err(|_error| {
        let _ = fs::remove_file(&temporary_path);
    })?;
    Ok(())
}

fn append_ai_brief_normalization_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    session: &Value,
    progress: f64,
) -> Result<()> {
    let warning_count = session
        .get("ai_brief_warnings")
        .and_then(serde_json::Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    if warning_count > 0 {
        append_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            &format!("Codex brief 缺少 {warning_count} 项约束，已按固定 7 状态 petpack 契约补齐后继续渲染。"),
            progress,
        )?;
    }
    Ok(())
}

fn pause_generation_for_input_request(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    session: &Value,
    progress: f64,
) -> Result<bool> {
    let Some(question) = app_server::input_request_question(session) else {
        return Ok(false);
    };
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(true);
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status)
    {
        return Ok(true);
    }
    append_message_with_kind(
        paths,
        database,
        job_id,
        "assistant",
        &question,
        progress,
        Some(KIND_INPUT_REQUEST),
        Some(GenerationJobStatus::WaitingForUser),
        None,
    )?;
    Ok(true)
}

fn should_retry_revision_with_new_session(session: &Value) -> bool {
    if session
        .get("thread_id")
        .and_then(serde_json::Value::as_str)
        .is_none()
    {
        return true;
    }
    let error = session
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    error.contains("thread/resume")
        || error.contains("thread not found")
        || error.contains("no rollout found")
}

fn app_server_failure_detail(session: &Value) -> &str {
    session
        .get("error")
        .or_else(|| session.get("detail"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("Codex App Server 暂不可用")
}

fn app_server_completed(session: &Value) -> bool {
    session.get("completed").and_then(Value::as_bool) == Some(true)
}

fn local_pet_studio_fallback_enabled() -> bool {
    std::env::var("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn skill_full_source_required() -> bool {
    std::env::var("APC_REQUIRE_SKILL_FULL_SOURCE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn external_skill_source_required() -> bool {
    std::env::var("APC_REQUIRE_EXTERNAL_SKILL_SOURCE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn form_with_revision_feedback(form: &GenerationForm, user_message: &str) -> GenerationForm {
    let mut adjusted = form.clone();
    adjusted.description = format!(
        "{}\n\n用户调整意见：{}",
        form.description.trim(),
        user_message.trim()
    );
    adjusted
}

fn write_skill_session(
    paths: &AppPaths,
    job_id: &str,
    source_dir: &std::path::Path,
    form: &GenerationForm,
    manifest: &PetManifest,
    app_server_session: &serde_json::Value,
) -> Result<()> {
    let source_dir_path = source_dir.join("source");
    fs::create_dir_all(&source_dir_path)?;
    let skill_session_path = source_dir_path.join("skill_session.jsonl");
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&skill_session_path)?;
    let states = REQUIRED_STATES
        .iter()
        .map(|state| state.as_str())
        .collect::<Vec<_>>();
    let messages = read_messages(paths, job_id)?;
    let runner = if app_server_session
        .get("started")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        "codex-app-server"
    } else {
        "local-pet-studio-runner"
    };
    let source_form = form_with_petpack_reference_paths(form, source_dir)?;
    let mut events = vec![
        json!({
            "event": "skill.loaded",
            "skill": "agent-pet-studio",
            "skill_path": "skills/agent-pet-studio/SKILL.md",
            "runner": runner,
            "codex_app_server": app_server_session,
            "created_at": now_rfc3339()
        }),
        json!({
            "event": "form.read",
            "skill": "agent-pet-studio",
            "form": source_form,
            "created_at": now_rfc3339()
        }),
        json!({
            "event": "brief.generated",
            "skill": "agent-pet-studio",
            "manifest_id": manifest.id,
            "name": manifest.name,
            "style": manifest.style,
            "quality": manifest.quality,
            "render_size": manifest.render_size,
            "created_at": now_rfc3339()
        }),
        json!({
            "event": "states.rendered",
            "skill": "agent-pet-studio",
            "states": states,
            "frames_per_state": GENERATED_FRAMES_PER_STATE,
            "fps_profiles": manifest.fps_profiles,
            "created_at": now_rfc3339()
        }),
        json!({
            "event": "petpack.validated",
            "skill": "agent-pet-studio",
            "schema_version": manifest.schema_version,
            "created_at": now_rfc3339()
        }),
        json!({
            "event": "studio.messages",
            "skill": "agent-pet-studio",
            "messages": messages,
            "created_at": now_rfc3339()
        }),
    ];

    if app_server_session
        .get("started")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        events.insert(
            1,
            json!({
                "event": "codex_thread.started",
                "skill": "agent-pet-studio",
                "thread_id": app_server_session.get("thread_id"),
                "session_id": app_server_session.get("session_id"),
                "command_source": app_server_session.get("command_source"),
                "created_at": now_rfc3339()
            }),
        );
    }

    if app_server_session
        .get("turn_started")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        let event_name = if app_server_session
            .get("follow_up")
            .and_then(serde_json::Value::as_bool)
            == Some(true)
        {
            "codex_followup_turn.completed"
        } else {
            "codex_turn.completed"
        };
        events.insert(
            2,
            json!({
                "event": event_name,
                "skill": "agent-pet-studio",
                "thread_id": app_server_session.get("thread_id"),
                "turn_id": app_server_session.get("turn_id"),
                "completed": app_server_session.get("completed"),
                "ai_brief": app_server_session.get("ai_brief"),
                "created_at": now_rfc3339()
            }),
        );
    }

    for event in events {
        writeln!(file, "{}", serde_json::to_string(&event)?)?;
    }

    Ok(())
}

fn form_with_petpack_reference_paths(
    form: &GenerationForm,
    source_dir: &std::path::Path,
) -> Result<GenerationForm> {
    let mut source_form = form.clone();
    source_form.reference_images = petpack_reference_files(source_dir)?;
    Ok(source_form)
}

fn petpack_reference_files(source_dir: &std::path::Path) -> Result<Vec<String>> {
    let source_json_path = source_dir.join("source").join("source.json");
    if !source_json_path.is_file() {
        return Ok(Vec::new());
    }
    let source_json: Value = serde_json::from_slice(&fs::read(source_json_path)?)?;
    Ok(source_json
        .get("reference_files")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default())
}

fn derive_pet_name(form: &GenerationForm, ai_brief: Option<&serde_json::Value>) -> String {
    if let Some(name) = ai_brief
        .and_then(|brief| brief.get("name"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
    {
        return name.chars().take(16).collect();
    }

    let trimmed = form.description.trim();
    if trimmed.is_empty() {
        return "自定义桌宠".to_string();
    }

    let stop_chars = ['，', '。', ',', '.', '、', '\n', '\r', ';', '；'];
    let first_phrase = trimmed
        .split(|character| stop_chars.contains(&character))
        .next()
        .unwrap_or(trimmed)
        .trim();
    let name: String = first_phrase
        .chars()
        .filter(|character| !character.is_whitespace())
        .take(12)
        .collect();
    if name.is_empty() {
        "自定义桌宠".to_string()
    } else {
        name
    }
}
