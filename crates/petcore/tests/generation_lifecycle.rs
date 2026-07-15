use petcore::paths::AppPaths;
use petcore::petpack::{build_petpack, write_sample_petpack_dir};
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{GenerationForm, GenerationJobStatus, QualityLevel};
use serde_json::{json, Value};
use std::ffi::OsString;
use std::io::Write;
use std::os::unix::prelude::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ENV_LOCK: Mutex<()> = Mutex::new(());

struct EnvVarGuard {
    key: &'static str,
    original: Option<OsString>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
        let original = std::env::var_os(key);
        std::env::set_var(key, value);
        Self { key, original }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        if let Some(value) = &self.original {
            std::env::set_var(self.key, value);
        } else {
            std::env::remove_var(self.key);
        }
    }
}

fn write_fake_app_server_script(path: &Path, thread_id: &str) {
    let mut file = std::fs::File::create(path).unwrap();
    writeln!(
        file,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *initialize*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"fake-codex-app-server","petcoreCli":"'"$APC_PETCORE_CLI"'"}}}}}}'
      ;;
    *thread/start*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"thread":{{"id":"{thread_id}","sessionId":"{thread_id}","ephemeral":false,"status":{{"type":"idle"}},"cwd":"/tmp","turns":[]}},"model":"fake-model","modelProvider":"fake","cwd":"/tmp","approvalPolicy":"never","sandbox":{{"type":"workspaceWrite"}}}}}}'
      ;;
    *thread/resume*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"thread":{{"id":"{thread_id}","sessionId":"{thread_id}","ephemeral":false,"status":{{"type":"idle"}},"cwd":"/tmp","turns":[{{"id":"turn_fake_pet_studio","status":"completed"}}]}},"model":"fake-model","modelProvider":"fake","cwd":"/tmp","approvalPolicy":"never","sandbox":{{"type":"readOnly"}}}}}}'
      ;;
    *turn/start*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"turn":{{"id":"turn_fake_pet_studio","items":[],"itemsView":"notLoaded","status":"inProgress","error":null}}}}}}'
      printf '%s\n' '{{"method":"turn/started","params":{{"threadId":"{thread_id}","turn":{{"id":"turn_fake_pet_studio","status":"inProgress"}}}}}}'
      printf '%s\n' '{{"method":"item/agentMessage/delta","params":{{"threadId":"{thread_id}","turnId":"turn_fake_pet_studio","itemId":"msg_fake","delta":"{{\"name\":\"生命周期宠物\",\"visual_brief\":\"stable lifecycle pet brief\",\"palette\":[\"pearl\",\"ink\",\"cyan\"],\"states\":[{{\"name\":\"idle\",\"motion\":\"breathing\"}}],\"render_notes\":\"transparent PNG\"}}"}}}}'
      if [ -n "${{APC_FAKE_APP_SERVER_WAIT_FILE:-}}" ]; then
        while [ ! -f "$APC_FAKE_APP_SERVER_WAIT_FILE" ]; do
          sleep 0.05
        done
      fi
      printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"{thread_id}","turnId":"turn_fake_pet_studio","item":{{"type":"agentMessage","id":"msg_fake","text":"{{\"name\":\"生命周期宠物\",\"visual_brief\":\"stable lifecycle pet brief\",\"palette\":[\"pearl\",\"ink\",\"cyan\"],\"states\":[{{\"name\":\"idle\",\"motion\":\"breathing\"}}],\"render_notes\":\"transparent PNG\"}}","phase":"final_answer"}}}}}}'
      ;;
  esac
done
"#
    )
    .unwrap();
    let mut permissions = std::fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).unwrap();
}

fn request(method: &str, params: Value) -> RpcRequest {
    RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    }
}

fn start_generation(state: &CoreState, description: &str) -> String {
    let value = handle_request(
        state,
        request(
            "generation.start",
            json!({
                "description": description,
                "style": "半写实",
                "quality": "standard",
                "reference_images": []
            }),
        ),
    )
    .unwrap();
    value["job_id"].as_str().unwrap().to_string()
}

fn generation_messages(state: &CoreState, job_id: &str) -> Vec<Value> {
    handle_request(
        state,
        request("generation.messages", json!({ "job_id": job_id })),
    )
    .unwrap()
    .as_array()
    .unwrap()
    .clone()
}

fn wait_for_message(state: &CoreState, job_id: &str, needle: &str) {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if generation_messages(state, job_id).iter().any(|message| {
            message["content"]
                .as_str()
                .unwrap_or_default()
                .contains(needle)
        }) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for message containing {needle}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_terminal_message(state: &CoreState, job_id: &str, kind: &str) {
    // A same-ID edit validates both the generated revision and the installed
    // baseline before committing. PNG decoding/validation is deliberately
    // synchronous and can take noticeably longer on a cold or contended CI
    // runner than it does on a developer machine. Keep this as a bounded wait,
    // but leave enough headroom that scheduler load is not reported as a
    // lifecycle failure.
    let deadline = Instant::now() + Duration::from_secs(45);
    loop {
        let messages = generation_messages(state, job_id);
        if messages
            .iter()
            .any(|message| message["kind"].as_str() == Some(kind))
        {
            return;
        }
        if Instant::now() >= deadline {
            let status = state.database.generation_job_status(job_id).unwrap();
            panic!(
                "timed out waiting for terminal message {kind}; status={status:?}; messages={messages:?}"
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn terminal_count(messages: &[Value], kind: &str) -> usize {
    messages
        .iter()
        .filter(|message| message["kind"].as_str() == Some(kind))
        .count()
}

#[test]
fn generation_lifecycle_cancel_is_idempotent_and_thread_cannot_complete() {
    let _env_lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-complete");
    write_fake_app_server_script(&fake_app_server, "thread_lifecycle_cancel");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let job_id = start_generation(&state, "取消中的生命周期桌宠。");
    wait_for_message(&state, &job_id, "Pet Studio brief turn 已启动");

    handle_request(
        &state,
        request("generation.cancel", json!({ "job_id": job_id })),
    )
    .unwrap();
    handle_request(
        &state,
        request("generation.cancel", json!({ "job_id": job_id })),
    )
    .unwrap();
    assert_eq!(
        state.database.generation_job_status(&job_id).unwrap(),
        Some(GenerationJobStatus::Canceled)
    );

    std::fs::write(&wait_file, "ok").unwrap();
    std::thread::sleep(Duration::from_millis(900));

    let messages = generation_messages(&state, &job_id);
    assert_eq!(terminal_count(&messages, "generation_canceled"), 1);
    assert_eq!(terminal_count(&messages, "generation_completed"), 0);
    assert_eq!(terminal_count(&messages, "generation_failed"), 0);
    assert!(state.database.list_pets().unwrap().is_empty());
}

#[test]
fn generation_lifecycle_reply_sets_running_and_cancel_keeps_previous_pet() {
    let _env_lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-complete");
    std::fs::write(&wait_file, "initial").unwrap();
    write_fake_app_server_script(&fake_app_server, "thread_lifecycle_revision");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let job_id = start_generation(&state, "先完成再调整的生命周期桌宠。");
    wait_for_terminal_message(&state, &job_id, "generation_completed");
    assert_eq!(
        state.database.generation_job_status(&job_id).unwrap(),
        Some(GenerationJobStatus::Completed)
    );
    assert_eq!(state.database.list_pets().unwrap().len(), 1);

    std::fs::remove_file(&wait_file).unwrap();
    let reply_messages = handle_request(
        &state,
        request(
            "generation.reply",
            json!({
                "job_id": job_id,
                "content": "等待确认动作再明显一点"
            }),
        ),
    )
    .unwrap();
    assert!(reply_messages.as_array().unwrap().iter().any(|message| {
        message["role"].as_str() == Some("user")
            && message["content"]
                .as_str()
                .unwrap_or_default()
                .contains("等待确认动作")
    }));
    assert_eq!(
        state.database.generation_job_status(&job_id).unwrap(),
        Some(GenerationJobStatus::Running)
    );

    handle_request(
        &state,
        request("generation.cancel", json!({ "job_id": job_id })),
    )
    .unwrap();
    std::fs::write(&wait_file, "revision").unwrap();
    std::thread::sleep(Duration::from_millis(900));

    let messages = generation_messages(&state, &job_id);
    assert_eq!(
        state.database.generation_job_status(&job_id).unwrap(),
        Some(GenerationJobStatus::Canceled)
    );
    assert_eq!(terminal_count(&messages, "generation_canceled"), 1);
    assert_eq!(terminal_count(&messages, "generation_failed"), 0);
    assert_eq!(state.database.list_pets().unwrap().len(), 1);
}

#[test]
fn imported_pet_can_start_codex_edit_as_same_id_revision() {
    let _env_lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    write_fake_app_server_script(&fake_app_server, "thread_imported_pet_edit");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths.clone());
    state.ensure_ready().unwrap();

    let source = temp.path().join("imported-source");
    let manifest =
        write_sample_petpack_dir(&source, QualityLevel::Standard, "外部导入宠物", "半写实", 2)
            .unwrap();
    let package = temp.path().join("external.petpack");
    build_petpack(&source, &package).unwrap();
    let imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": package.display().to_string() }),
        ),
    )
    .unwrap();
    assert_eq!(imported["id"], manifest.id);
    let original_path = imported["petpack_path"].as_str().unwrap().to_string();

    let edit = handle_request(
        &state,
        request(
            "generation.edit",
            json!({
                "pet_id": manifest.id,
                "instruction": "让工作状态的动作更有力量，其他状态保持不变"
            }),
        ),
    )
    .unwrap();
    let job_id = edit["job_id"].as_str().unwrap();
    wait_for_terminal_message(&state, job_id, "generation_completed");

    let pets = state.database.list_pets().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0].id, manifest.id);
    assert!(pets[0].active);
    assert_ne!(pets[0].petpack_path, original_path);
    assert!(paths
        .jobs_dir
        .join(job_id)
        .join("base-petpack-source/manifest.json")
        .is_file());
    assert_eq!(
        state
            .database
            .generation_job(job_id)
            .unwrap()
            .unwrap()
            .result_pet_id
            .as_deref(),
        Some(manifest.id.as_str())
    );
}

#[test]
fn pet_edit_rejects_commit_when_base_revision_changes() {
    let _env_lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-edit-complete");
    write_fake_app_server_script(&fake_app_server, "thread_edit_conflict");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let source = temp.path().join("base-source");
    let manifest =
        write_sample_petpack_dir(&source, QualityLevel::Standard, "冲突基线", "半写实", 2).unwrap();
    let package = temp.path().join("base.petpack");
    build_petpack(&source, &package).unwrap();
    handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": package.display().to_string() }),
        ),
    )
    .unwrap();

    let edit = handle_request(
        &state,
        request(
            "generation.edit",
            json!({ "pet_id": manifest.id, "instruction": "修改 tool 状态" }),
        ),
    )
    .unwrap();
    let job_id = edit["job_id"].as_str().unwrap();
    wait_for_message(&state, job_id, "Pet Studio brief turn 已启动");

    let replacement_source = temp.path().join("replacement-source");
    let mut replacement_manifest = write_sample_petpack_dir(
        &replacement_source,
        QualityLevel::Standard,
        "用户刚导入的新版本",
        "半写实",
        2,
    )
    .unwrap();
    replacement_manifest.id = manifest.id.clone();
    std::fs::write(
        replacement_source.join("manifest.json"),
        serde_json::to_vec_pretty(&replacement_manifest).unwrap(),
    )
    .unwrap();
    let replacement = temp.path().join("replacement.petpack");
    build_petpack(&replacement_source, &replacement).unwrap();
    let manually_imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": replacement.display().to_string() }),
        ),
    )
    .unwrap();
    let manual_path = manually_imported["petpack_path"]
        .as_str()
        .unwrap()
        .to_string();

    std::fs::write(&wait_file, "continue").unwrap();
    wait_for_terminal_message(&state, job_id, "generation_failed");
    let pets = state.database.list_pets().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0].id, manifest.id);
    assert_eq!(pets[0].name, "用户刚导入的新版本");
    assert_eq!(pets[0].petpack_path, manual_path);
    assert!(generation_messages(&state, job_id).iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap_or_default()
            .contains("base pet changed")
    }));

    let retry = handle_request(
        &state,
        request("generation.retry", json!({ "job_id": job_id })),
    )
    .unwrap();
    assert_eq!(retry["operation"], "modify");
    let retry_id = retry["job_id"].as_str().unwrap();
    let retry_job = state.database.generation_job(retry_id).unwrap().unwrap();
    assert_eq!(
        retry_job.result_pet_id.as_deref(),
        Some(manifest.id.as_str())
    );
    assert_eq!(retry_job.retry_of_job_id.as_deref(), Some(job_id));

    let retry_context: Value = serde_json::from_slice(
        &std::fs::read(
            state
                .paths
                .jobs_dir
                .join(retry_id)
                .join("edit-context.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(retry_context["pet_id"], manifest.id);
    assert_eq!(retry_context["base_manifest"]["name"], "用户刚导入的新版本");
    assert_eq!(retry_context["instruction"], "修改 tool 状态");

    wait_for_terminal_message(&state, retry_id, "generation_completed");
    let pets = state.database.list_pets().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0].id, manifest.id);
    let history = handle_request(
        &state,
        request("generation.for_pet", json!({ "pet_id": manifest.id })),
    )
    .unwrap();
    assert_eq!(history["job_id"], retry_id);
    assert_eq!(history["operation"], "modify");
}

#[test]
fn generation_lifecycle_interrupted_recovery_appends_one_failed_terminal() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths.clone());
    state.ensure_ready().unwrap();
    let form = GenerationForm {
        description: "中断恢复生命周期测试".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };
    let job_dir = paths.jobs_dir.join("job_lifecycle_interrupted");
    std::fs::create_dir_all(&job_dir).unwrap();
    state
        .database
        .create_generation_job("job_lifecycle_interrupted", &form, &job_dir)
        .unwrap();
    state
        .database
        .update_generation_job(
            "job_lifecycle_interrupted",
            GenerationJobStatus::Running,
            None,
        )
        .unwrap();
    rusqlite::Connection::open(state.database.path())
        .unwrap()
        .execute(
            "UPDATE generation_jobs SET heartbeat_at = '2000-01-01T00:00:00Z' WHERE id = ?1",
            ["job_lifecycle_interrupted"],
        )
        .unwrap();

    let restarted = CoreState::new(paths);
    restarted.ensure_ready().unwrap();
    restarted.ensure_ready().unwrap();

    assert_eq!(
        restarted
            .database
            .generation_job_status("job_lifecycle_interrupted")
            .unwrap(),
        Some(GenerationJobStatus::Failed)
    );
    let messages = generation_messages(&restarted, "job_lifecycle_interrupted");
    assert_eq!(terminal_count(&messages, "generation_failed"), 1);
}

#[test]
fn generation_lifecycle_cancel_is_noop_for_failed_terminal_job() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    let form = GenerationForm {
        description: "失败终态取消测试".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };
    let job_id = "job_lifecycle_failed";
    let job_dir = state.paths.jobs_dir.join(job_id);
    std::fs::create_dir_all(&job_dir).unwrap();
    state
        .database
        .create_generation_job(job_id, &form, &job_dir)
        .unwrap();
    state
        .database
        .update_generation_job(job_id, GenerationJobStatus::Failed, None)
        .unwrap();

    handle_request(
        &state,
        request("generation.cancel", json!({ "job_id": job_id })),
    )
    .unwrap();

    assert_eq!(
        state.database.generation_job_status(job_id).unwrap(),
        Some(GenerationJobStatus::Failed)
    );
    assert!(!state.paths.jobs_dir.join(job_id).join("canceled").exists());
    assert_eq!(
        terminal_count(&generation_messages(&state, job_id), "generation_canceled"),
        0
    );
}
