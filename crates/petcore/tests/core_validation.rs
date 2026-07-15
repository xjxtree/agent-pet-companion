use image::{ImageBuffer, Rgba};
use petcore::connections;
use petcore::daemon;
use petcore::db::Database;
use petcore::generation;
use petcore::launch_agent::{self, LaunchAgentConfig};
use petcore::paths::AppPaths;
use petcore::petpack::{build_petpack, validate_petpack_path, write_sample_petpack_dir};
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{
    AgentEventType, AgentSource, BehaviorSettings, CheckStatus, FpsProfileName, GenerationForm,
    GenerationJobStatus, PetSummary, QualityLevel,
};
use serde_json::json;
use std::ffi::OsString;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixListener;
use std::os::unix::prelude::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use time::{format_description::well_known::Rfc3339, Duration as TimeDuration, OffsetDateTime};

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

    fn remove(key: &'static str) -> Self {
        let original = std::env::var_os(key);
        std::env::remove_var(key);
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

fn lock_env() -> std::sync::MutexGuard<'static, ()> {
    ENV_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
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
      printf '%s\n' '{{"method":"remoteControl/status/changed","params":{{"status":"disabled"}}}}'
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"thread":{{"id":"{thread_id}","sessionId":"{thread_id}","ephemeral":false,"status":{{"type":"idle"}},"cwd":"/tmp","turns":[]}},"model":"fake-model","modelProvider":"fake","cwd":"/tmp","approvalPolicy":"never","sandbox":{{"type":"workspaceWrite"}}}}}}'
      ;;
    *thread/resume*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"thread":{{"id":"{thread_id}","sessionId":"{thread_id}","ephemeral":false,"status":{{"type":"idle"}},"cwd":"/tmp","turns":[{{"id":"turn_fake_pet_studio","status":"completed"}}]}},"model":"fake-model","modelProvider":"fake","cwd":"/tmp","approvalPolicy":"never","sandbox":{{"type":"readOnly"}}}}}}'
      ;;
    *turn/start*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"turn":{{"id":"turn_fake_pet_studio","items":[],"itemsView":"notLoaded","status":"inProgress","error":null}}}}}}'
      printf '%s\n' '{{"method":"turn/started","params":{{"threadId":"{thread_id}","turn":{{"id":"turn_fake_pet_studio","status":"inProgress"}}}}}}'
      printf '%s\n' '{{"method":"item/agentMessage/delta","params":{{"threadId":"{thread_id}","turnId":"turn_fake_pet_studio","itemId":"msg_fake","delta":"{{\"name\":\"AI 云袖\",\"visual_brief\":\"AI brief\",\"palette\":[\"pearl\",\"ink\",\"cyan\"],\"states\":[{{\"name\":\"idle\",\"motion\":\"breathing\"}}],\"render_notes\":\"transparent PNG\"}}"}}}}'
      if [ -n "${{APC_FAKE_APP_SERVER_WAIT_FILE:-}}" ]; then
        while [ ! -f "$APC_FAKE_APP_SERVER_WAIT_FILE" ]; do
          sleep 0.05
        done
      fi
      printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"{thread_id}","turnId":"turn_fake_pet_studio","item":{{"type":"agentMessage","id":"msg_fake","text":"{{\"name\":\"AI 云袖\",\"visual_brief\":\"AI brief\",\"palette\":[\"pearl\",\"ink\",\"cyan\"],\"states\":[{{\"name\":\"idle\",\"motion\":\"breathing\"}}],\"render_notes\":\"transparent PNG\"}}","phase":"final_answer"}}}}}}'
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

fn write_fake_app_server_input_request_script(path: &Path, thread_id: &str) {
    let mut file = std::fs::File::create(path).unwrap();
    writeln!(
        file,
        r#"#!/bin/sh
resumed=0
while IFS= read -r request; do
  case "$request" in
    *initialize*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"fake-codex-app-server","petcoreCli":"'"$APC_PETCORE_CLI"'"}}}}}}'
      ;;
    *thread/start*)
      resumed=0
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"thread":{{"id":"{thread_id}","sessionId":"{thread_id}","ephemeral":false,"status":{{"type":"idle"}},"cwd":"/tmp","turns":[]}},"model":"fake-model","modelProvider":"fake","cwd":"/tmp","approvalPolicy":"never","sandbox":{{"type":"workspaceWrite"}}}}}}'
      ;;
    *thread/resume*)
      resumed=1
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"thread":{{"id":"{thread_id}","sessionId":"{thread_id}","ephemeral":false,"status":{{"type":"idle"}},"cwd":"/tmp","turns":[{{"id":"turn_input_request","status":"completed"}}]}},"model":"fake-model","modelProvider":"fake","cwd":"/tmp","approvalPolicy":"never","sandbox":{{"type":"readOnly"}}}}}}'
      ;;
    *turn/start*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"turn":{{"id":"turn_fake_pet_studio","items":[],"itemsView":"notLoaded","status":"inProgress","error":null}}}}}}'
      printf '%s\n' '{{"method":"turn/started","params":{{"threadId":"{thread_id}","turn":{{"id":"turn_fake_pet_studio","status":"inProgress"}}}}}}'
      if [ "$resumed" = "1" ]; then
        printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"{thread_id}","turnId":"turn_fake_pet_studio","item":{{"type":"agentMessage","id":"msg_fake","text":"{{\"name\":\"追问完成宠物\",\"visual_brief\":\"补充后的 coherent pet brief\",\"palette\":[\"pearl\",\"ink\",\"cyan\"],\"states\":[{{\"name\":\"idle\",\"motion\":\"breathing\"}}],\"render_notes\":\"transparent PNG\"}}","phase":"final_answer"}}}}}}'
      else
        printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"{thread_id}","turnId":"turn_fake_pet_studio","item":{{"type":"agentMessage","id":"msg_fake","text":"{{\"needs_input\":true,\"question\":\"请补充这个桌宠的主体外观。\"}}","phase":"final_answer"}}}}}}'
      fi
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

fn write_fake_cli(path: &Path) {
    let mut file = std::fs::File::create(path).unwrap();
    writeln!(
        file,
        r#"#!/bin/sh
set -eu
: "${{APC_FAKE_CLI_CAPTURE:?}}"
{{
  printf 'ARGV:%s\n' "$*"
  printf 'STDIN:'
  cat
  printf '\n---\n'
}} >> "$APC_FAKE_CLI_CAPTURE"
"#
    )
    .unwrap();
    let mut permissions = std::fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).unwrap();
}

fn node_available() -> bool {
    Command::new("node")
        .arg("--version")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn run_node_module_smoke(script: &str, capture_path: &Path) {
    if !node_available() {
        eprintln!("node is not available; skipping connector runtime smoke");
        return;
    }

    let output = Command::new("node")
        .arg("--input-type=module")
        .arg("--eval")
        .arg(script)
        .env("APC_FAKE_CLI_CAPTURE", capture_path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "node smoke failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn run_shell_hook_smoke(command: &str, stdin: &str, capture_path: &Path) {
    let mut child = Command::new("sh")
        .arg("-lc")
        .arg(command)
        .env("APC_FAKE_CLI_CAPTURE", capture_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(mut child_stdin) = child.stdin.take() {
        child_stdin.write_all(stdin.as_bytes()).unwrap();
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "shell hook failed\ncommand:\n{command}\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn wait_for_capture(path: &Path, needle: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let content = std::fs::read_to_string(path).unwrap_or_default();
        if content.contains(needle) {
            return content;
        }
        assert!(
            Instant::now() < deadline,
            "connector capture did not contain {needle:?}; current capture:\n{content}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if path.exists() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "expected file was not created: {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn http_post_agent_event(
    port: u16,
    token: Option<&str>,
    body: &serde_json::Value,
) -> (u16, serde_json::Value) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let body = serde_json::to_string(body).unwrap();
    let token_header = token
        .map(|token| format!("X-Agent-Pet-Token: {token}\r\n"))
        .unwrap_or_default();
    write!(
        stream,
        "POST /agent-events HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{}Connection: close\r\n\r\n{}",
        body.len(),
        token_header,
        body
    )
    .unwrap();

    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let (headers, body) = response
        .split_once("\r\n\r\n")
        .expect("HTTP response should include headers and body");
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok())
        .expect("HTTP response should include status code");
    let body = serde_json::from_str(body).unwrap();
    (status, body)
}

#[test]
fn petpack_validation_rejects_missing_state() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 1).unwrap();
    std::fs::remove_dir_all(temp.path().join("assets/frames/tool")).unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("tool"));
}

#[test]
fn petpack_validation_rejects_missing_animated_preview() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 2).unwrap();
    std::fs::remove_file(temp.path().join("assets/preview/animated_preview.webp")).unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("animated_preview.webp"));
}

#[test]
fn petpack_validation_rejects_missing_source_metadata() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 2).unwrap();
    std::fs::remove_file(temp.path().join("source/source.json")).unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("source/source.json"));
}

#[test]
fn petpack_validation_rejects_missing_skill_session_metadata() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 2).unwrap();
    std::fs::remove_file(temp.path().join("source/skill_session.jsonl")).unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("source/skill_session.jsonl"));
}

#[test]
fn petpack_validation_rejects_failed_build_metadata() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 2).unwrap();
    std::fs::write(
        temp.path().join("build/validation.json"),
        serde_json::to_vec_pretty(&json!({ "ok": false })).unwrap(),
    )
    .unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("build/validation.json"));
}

#[test]
fn petpack_validation_rejects_escaping_asset_paths() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 1).unwrap();
    let manifest_path = temp.path().join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    manifest["states"][0]["frames_dir"] = serde_json::Value::String("../outside".to_string());
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("inside the package"));
}

#[test]
fn petpack_validation_rejects_codex_compatibility_package_markers() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 2).unwrap();
    std::fs::write(temp.path().join("codex-pet.json"), "{}").unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("must not include Codex compatibility package marker"));
}

#[test]
fn petpack_build_rejects_source_symlink() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Cloud Maiden", "半写实", 2).unwrap();
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(
            source.join("manifest.json"),
            source.join("source").join("manifest-link.json"),
        )
        .unwrap();
        let error = build_petpack(&source, &temp.path().join("unsafe.petpack"))
            .unwrap_err()
            .to_string();
        assert!(error.contains("must not contain symlink"));
    }
}

#[test]
fn rpc_ingest_deduplicates_and_filters_events() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    assert!(state.database.behavior().unwrap().mouse_passthrough);

    let request = |params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: "agent.ingest".to_string(),
        params,
    };

    let first = handle_request(
        &state,
        request(json!({
            "id": "evt_test_same",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(first["inserted"], true);
    assert_eq!(first["triggered"], true);

    let duplicate = handle_request(
        &state,
        request(json!({
            "id": "evt_test_same",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(duplicate["inserted"], false);
    assert_eq!(duplicate["triggered"], false);

    let database = Database::new(state.paths.db_path.clone());
    let mut behavior = BehaviorSettings::default();
    behavior.sources.insert(AgentSource::Codex, false);
    database.set_setting("behavior", &behavior).unwrap();

    let filtered = handle_request(
        &state,
        request(json!({
            "id": "evt_test_filtered",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(filtered["inserted"], true);
    assert_eq!(filtered["triggered"], false);

    behavior.sources.insert(AgentSource::Codex, true);
    behavior.events.insert(AgentEventType::Tool, false);
    database.set_setting("behavior", &behavior).unwrap();

    let event_filtered = handle_request(
        &state,
        request(json!({
            "id": "evt_test_event_filtered",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(event_filtered["inserted"], true);
    assert_eq!(event_filtered["triggered"], false);

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert_eq!(snapshot["events"].as_array().unwrap().len(), 0);

    let recent = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "events.recent".to_string(),
            params: json!({ "limit": 10 }),
        },
    )
    .unwrap();
    assert_eq!(recent.as_array().unwrap().len(), 3);

    database
        .set_setting("behavior", &BehaviorSettings::default())
        .unwrap();
    let diagnostic = handle_request(
        &state,
        request(json!({
            "id": "evt_test_diagnostic",
            "source": "codex",
            "event_type": "review",
            "title": "连接自检",
            "payload": {
                "diagnostic": true
            }
        })),
    )
    .unwrap();
    assert_eq!(diagnostic["inserted"], true);
    assert_eq!(diagnostic["triggered"], false);

    let diagnostic_snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let overlay_events = diagnostic_snapshot["events"].as_array().unwrap();
    assert!(overlay_events
        .iter()
        .all(|event| event["id"] != "evt_test_diagnostic"));

    let recent_with_diagnostic = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "events.recent".to_string(),
            params: json!({ "limit": 10 }),
        },
    )
    .unwrap();
    let history = recent_with_diagnostic.as_array().unwrap();
    assert_eq!(history.len(), 4);
    assert!(history
        .iter()
        .any(|event| event["id"] == "evt_test_diagnostic"));
}

#[test]
fn agent_event_ingest_rejects_sensitive_unknown_payload_fields() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let error = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "agent.ingest".to_string(),
            params: json!({
                "id": "evt_sensitive_payload",
                "source": "codex",
                "event_type": "tool",
                "title": "curl --token APC_SECRET_SENTINEL_TITLE",
                "detail": "Authorization: Bearer APC_SECRET_SENTINEL_DETAIL",
                "project_path": "/tmp/apc-safe-project",
                "session_id": "session=normal",
                "payload": {
                    "source_event": "PostToolUse",
                    "tool_name": "shell",
                    "outcome": "completed",
                    "diagnostic": false,
                    "command": "curl --api-key APC_SECRET_SENTINEL_INLINE",
                    "token": "APC_SECRET_SENTINEL_TOKEN",
                    "nested": {
                        "access_token": "APC_SECRET_SENTINEL_ACCESS",
                        "safe": "visible"
                    },
                    "headers": {
                        "Authorization": "Bearer APC_SECRET_SENTINEL_AUTH",
                        "x-debug": "ok"
                    },
                    "array": [
                        {"cookie": "APC_SECRET_SENTINEL_COOKIE"},
                        "Bearer APC_SECRET_SENTINEL_ARRAY"
                    ]
                }
            }),
        },
    )
    .unwrap_err();
    let error_text = error.to_string();
    assert!(error_text.contains("payload field is not supported"));
    assert!(!error_text.contains("APC_SECRET_SENTINEL_"));

    let recent = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "events.recent".to_string(),
            params: json!({ "limit": 1 }),
        },
    )
    .unwrap();
    assert!(recent.as_array().unwrap().is_empty());

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert!(snapshot["events"].as_array().unwrap().is_empty());
    assert!(snapshot["recent_events"].as_array().unwrap().is_empty());
}

#[test]
fn agent_event_ingest_accepts_payload_json_alias() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let event = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "agent.ingest".to_string(),
            params: json!({
                "id": "evt_payload_json_alias",
                "source": "codex",
                "event_type": "tool",
                "title": "RAW_TITLE_ALIAS_SENTINEL",
                "detail": "RAW_DETAIL_ALIAS_SENTINEL",
                "payload_json": {
                    "source_event": "RAW_SOURCE_EVENT_ALIAS_SENTINEL",
                    "tool_name": "RAW_TOOL_NAME_ALIAS_SENTINEL",
                    "outcome": "RAW_OUTCOME_ALIAS_SENTINEL",
                    "diagnostic": true
                }
            }),
        },
    )
    .unwrap();

    assert_eq!(event["inserted"], true);
    assert_eq!(event["event"]["title"], "执行工具");
    assert!(event["event"]["detail"].is_null());
    assert_eq!(
        event["event"]["payload_json"]["source_event"],
        "unclassified"
    );
    assert_eq!(event["event"]["payload_json"]["tool_name"], "other");
    assert_eq!(event["event"]["payload_json"]["outcome"], "unknown");
    assert_eq!(event["event"]["payload_json"]["diagnostic"], true);

    let event_text = serde_json::to_string(&event).unwrap();
    for sentinel in [
        "RAW_TITLE_ALIAS_SENTINEL",
        "RAW_DETAIL_ALIAS_SENTINEL",
        "RAW_SOURCE_EVENT_ALIAS_SENTINEL",
        "RAW_TOOL_NAME_ALIAS_SENTINEL",
        "RAW_OUTCOME_ALIAS_SENTINEL",
    ] {
        assert!(!event_text.contains(sentinel));
    }

    let recent = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "events.recent".to_string(),
            params: json!({ "limit": 1 }),
        },
    )
    .unwrap();
    let recent_text = serde_json::to_string(&recent).unwrap();
    for sentinel in [
        "RAW_TITLE_ALIAS_SENTINEL",
        "RAW_DETAIL_ALIAS_SENTINEL",
        "RAW_SOURCE_EVENT_ALIAS_SENTINEL",
        "RAW_TOOL_NAME_ALIAS_SENTINEL",
        "RAW_OUTCOME_ALIAS_SENTINEL",
    ] {
        assert!(!recent_text.contains(sentinel));
    }
}

#[test]
fn behavior_settings_decode_legacy_sparse_json_with_defaults() {
    let legacy = json!({
        "enabled": true,
        "sources": {
            "codex": false
        },
        "events": {
            "tool": false
        }
    });

    let decoded: BehaviorSettings = serde_json::from_value(legacy.clone()).unwrap();
    assert!(decoded.status_bubble);
    assert!(decoded.click_menu);
    assert!(decoded.mouse_passthrough);
    assert!(!decoded.auto_hide);
    assert_eq!(decoded.fps_profile, FpsProfileName::Standard);
    assert_eq!(decoded.sources.get(&AgentSource::Codex), Some(&false));
    assert_eq!(decoded.sources.get(&AgentSource::ClaudeCode), Some(&true));
    assert_eq!(decoded.sources.get(&AgentSource::Pi), Some(&true));
    assert_eq!(decoded.sources.get(&AgentSource::Opencode), Some(&true));
    assert_eq!(decoded.events.get(&AgentEventType::Tool), Some(&false));
    assert_eq!(decoded.events.get(&AgentEventType::Start), Some(&true));
    assert_eq!(decoded.events.get(&AgentEventType::Waiting), Some(&true));

    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("settings.sqlite"));
    database.init().unwrap();
    database.set_setting("behavior", &legacy).unwrap();
    let stored = database.behavior().unwrap();
    assert!(stored.mouse_passthrough);
    assert_eq!(stored.sources.get(&AgentSource::Codex), Some(&false));
    assert_eq!(stored.sources.get(&AgentSource::ClaudeCode), Some(&true));
    assert_eq!(stored.events.get(&AgentEventType::Tool), Some(&false));
    assert_eq!(stored.events.get(&AgentEventType::Done), Some(&true));
}

#[test]
fn connection_test_event_drives_overlay_when_enabled() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let test_event = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "connections.test".to_string(),
            params: json!({ "source": "opencode" }),
        },
    )
    .unwrap();

    assert_eq!(test_event["ok"], true);
    assert_eq!(test_event["inserted"], true);
    assert_eq!(test_event["triggered"], true);
    assert_eq!(test_event["state"], "start");
    assert_eq!(test_event["event"]["source"], "opencode");
    assert_eq!(test_event["event"]["event_type"], "start");
    assert_eq!(test_event["event"]["title"], "开始处理");
    assert!(test_event["event"]["detail"].is_null());
    assert_eq!(
        test_event["event"]["payload_json"]["source_event"],
        "connection.test"
    );
    assert_eq!(test_event["event"]["payload_json"]["diagnostic"], false);

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let overlay_events = snapshot["events"].as_array().unwrap();
    assert_eq!(overlay_events.len(), 1);
    assert_eq!(overlay_events[0]["id"], test_event["event"]["id"]);
    assert_eq!(overlay_events[0]["source"], "opencode");
}

#[test]
fn snapshot_separates_overlay_events_from_recent_agent_history() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let initial = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "behavior.patch".to_string(),
            params: json!({
                "expected_revision": initial["behavior_revision"],
                "changes": {
                    "enabled": false
                }
            }),
        },
    )
    .unwrap();

    let real_event = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "agent.ingest".to_string(),
            params: json!({
                "id": "evt_recent_history_real",
                "source": "codex",
                "event_type": "tool",
                "title": "执行工具"
            }),
        },
    )
    .unwrap();
    assert_eq!(real_event["triggered"], false);

    handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "agent.ingest".to_string(),
            params: json!({
                "id": "evt_recent_history_diagnostic",
                "source": "codex",
                "event_type": "review",
                "title": "连接自检",
                "payload": {
                    "diagnostic": true
                }
            }),
        },
    )
    .unwrap();

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert!(
        snapshot["events"].as_array().unwrap().is_empty(),
        "disabled behavior should not expose overlay-driving events"
    );
    let recent_events = snapshot["recent_events"].as_array().unwrap();
    assert!(recent_events
        .iter()
        .any(|event| event["id"] == "evt_recent_history_real"));
    assert!(!recent_events
        .iter()
        .any(|event| event["id"] == "evt_recent_history_diagnostic"));
}

#[test]
fn state_wait_returns_snapshot_when_revision_changes() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let initial = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let initial_revision = initial["revision"].as_str().unwrap().to_string();
    assert!(!initial_revision.is_empty());

    let wait_state = state.clone();
    let wait_revision = initial_revision.clone();
    let (started_tx, started_rx) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        handle_request(
            &wait_state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "state.wait".to_string(),
                params: json!({
                    "after_revision": wait_revision,
                    "timeout_ms": 2_000
                }),
            },
        )
        .unwrap()
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_state_wait",
                "source": "codex",
                "event_type": "tool",
                "title": "执行工具"
            }),
        ),
    )
    .unwrap();

    let waited = waiter.join().unwrap();
    assert_eq!(waited["changed"], true);
    assert_ne!(waited["revision"], initial_revision);
    assert!(waited["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|event| event["id"] == "evt_state_wait"));
}

#[test]
fn generation_messages_wait_returns_when_message_file_changes() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    let job_id = "job_messages_wait";
    let job_dir = state.paths.jobs_dir.join(job_id);
    std::fs::create_dir_all(&job_dir).unwrap();
    state
        .database
        .create_generation_job(
            job_id,
            &GenerationForm {
                description: "legacy message migration".to_string(),
                style: "半写实".to_string(),
                quality: QualityLevel::Standard,
                reference_images: Vec::new(),
            },
            &job_dir,
        )
        .unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let initial = handle_request(
        &state,
        request(
            "generation.messages.wait",
            json!({
                "job_id": job_id,
                "after_revision": "",
                "timeout_ms": 250
            }),
        ),
    )
    .unwrap();
    let initial_revision = initial["revision"].as_str().unwrap().to_string();
    assert!(initial["messages"].as_array().unwrap().is_empty());

    let wait_state = state.clone();
    let wait_revision = initial_revision.clone();
    let (started_tx, started_rx) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        handle_request(
            &wait_state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages.wait".to_string(),
                params: json!({
                    "job_id": job_id,
                    "after_revision": wait_revision,
                    "timeout_ms": 2_000
                }),
            },
        )
        .unwrap()
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    std::fs::write(
        job_dir.join("messages.jsonl"),
        r#"{"role":"assistant","content":"生成消息已追加","progress":0.4,"created_at":"2026-07-08T00:00:00Z"}"#,
    )
    .unwrap();

    let waited = waiter.join().unwrap();
    assert_eq!(waited["changed"], true);
    assert_ne!(waited["revision"], initial_revision);
    let messages = waited["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["content"], "生成消息已追加");
}

#[test]
fn snapshot_expires_old_overlay_events_without_deleting_history() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let expired_created_at = (OffsetDateTime::now_utc() - TimeDuration::minutes(1))
        .format(&Rfc3339)
        .unwrap();
    let expired_done = handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_expired_done",
                "source": "codex",
                "event_type": "done",
                "title": "完成",
                "created_at": expired_created_at
            }),
        ),
    )
    .unwrap();
    assert_eq!(expired_done["inserted"], true);
    assert_eq!(expired_done["triggered"], false);

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(snapshot["events"].as_array().unwrap().len(), 0);

    let recent = handle_request(&state, request("events.recent", json!({ "limit": 5 }))).unwrap();
    assert_eq!(recent.as_array().unwrap().len(), 1);
    assert_eq!(recent[0]["id"], "evt_expired_done");

    let waiting = handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_current_waiting",
                "source": "codex",
                "event_type": "waiting",
                "title": "等待确认"
            }),
        ),
    )
    .unwrap();
    assert_eq!(waiting["triggered"], true);

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(snapshot["events"][0]["id"], "evt_current_waiting");

    let done = handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_current_done",
                "source": "codex",
                "event_type": "done",
                "title": "完成"
            }),
        ),
    )
    .unwrap();
    assert_eq!(done["triggered"], true);

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(snapshot["events"][0]["id"], "evt_current_done");
}

#[test]
fn snapshot_overlay_events_keep_only_latest_message_per_agent() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };
    let older_codex_time = (OffsetDateTime::now_utc() - TimeDuration::seconds(20))
        .format(&Rfc3339)
        .unwrap();
    let claude_time = (OffsetDateTime::now_utc() - TimeDuration::seconds(10))
        .format(&Rfc3339)
        .unwrap();
    let newer_codex_time = (OffsetDateTime::now_utc() - TimeDuration::seconds(5))
        .format(&Rfc3339)
        .unwrap();

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_codex_old_session",
                "source": "codex",
                "session_id": "codex-old",
                "event_type": "tool",
                "title": "旧 Codex 会话",
                "created_at": older_codex_time
            }),
        ),
    )
    .unwrap();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_claude_current",
                "source": "claude_code",
                "session_id": "claude-current",
                "event_type": "waiting",
                "title": "Claude 当前会话",
                "created_at": claude_time
            }),
        ),
    )
    .unwrap();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_codex_new_session",
                "source": "codex",
                "session_id": "codex-new",
                "event_type": "review",
                "title": "Codex 新会话",
                "created_at": newer_codex_time
            }),
        ),
    )
    .unwrap();

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let events = snapshot["events"].as_array().unwrap();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0]["id"], "evt_codex_new_session");
    assert_eq!(events[1]["id"], "evt_claude_current");
    assert!(events
        .iter()
        .all(|event| event["id"] != "evt_codex_old_session"));
}

#[test]
fn snapshot_does_not_restore_old_work_event_after_terminal_expires() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };
    let active_work_time = (OffsetDateTime::now_utc() - TimeDuration::seconds(60))
        .format(&Rfc3339)
        .unwrap();
    let expired_terminal_time = (OffsetDateTime::now_utc() - TimeDuration::seconds(9))
        .format(&Rfc3339)
        .unwrap();

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_session_waiting_before_done",
                "source": "codex",
                "session_id": "session-terminal-order",
                "event_type": "waiting",
                "title": "等待确认",
                "created_at": active_work_time
            }),
        ),
    )
    .unwrap();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_session_done_expired",
                "source": "codex",
                "session_id": "session-terminal-order",
                "event_type": "done",
                "title": "完成",
                "created_at": expired_terminal_time
            }),
        ),
    )
    .unwrap();

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let events = snapshot["events"].as_array().unwrap();
    assert!(
        events
            .iter()
            .all(|event| event["id"] != "evt_session_waiting_before_done"),
        "expired terminal event should close the session instead of restoring old work: {events:?}"
    );
}

#[test]
fn snapshot_overlay_events_survive_diagnostic_noise() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "evt_real_survives_diagnostics",
                "source": "claude_code",
                "session_id": "session-diagnostic-noise",
                "event_type": "tool",
                "title": "执行工具"
            }),
        ),
    )
    .unwrap();

    for index in 0..24 {
        handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": format!("evt_diagnostic_noise_{index}"),
                    "source": "codex",
                    "event_type": "review",
                    "title": "连接自检",
                    "payload": {
                        "diagnostic": true
                    }
                }),
            ),
        )
        .unwrap();
    }

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert!(snapshot["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|event| event["id"] == "evt_real_survives_diagnostics"));
    assert!(snapshot["recent_events"]
        .as_array()
        .unwrap()
        .iter()
        .all(|event| !event["id"]
            .as_str()
            .unwrap_or("")
            .starts_with("evt_diagnostic_noise_")));
}

#[test]
fn future_agent_event_created_at_is_clamped() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let future = "2099-01-01T00:00:00Z";
    handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "agent.ingest".to_string(),
            params: json!({
                "id": "evt_future_created_at",
                "source": "opencode",
                "event_type": "tool",
                "title": "执行工具",
                "created_at": future
            }),
        },
    )
    .unwrap();

    let recent = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "events.recent".to_string(),
            params: json!({ "limit": 1 }),
        },
    )
    .unwrap();
    assert_eq!(recent[0]["id"], "evt_future_created_at");
    assert_ne!(recent[0]["created_at"], future);
}

#[test]
fn overlay_placement_persists_through_snapshot() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let initial = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(initial["overlay_placement"]["scale"], 0.12);

    handle_request(
        &state,
        request(
            "overlay.placement.update",
            json!({
                "x": 321.0,
                "y": 654.0,
                "scale": 0.82,
                "display_id": "display-test"
            }),
        ),
    )
    .unwrap();

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(snapshot["overlay_placement"]["x"], 321.0);
    assert_eq!(snapshot["overlay_placement"]["y"], 654.0);
    assert_eq!(snapshot["overlay_placement"]["scale"], 0.82);
    assert_eq!(snapshot["overlay_placement"]["display_id"], "display-test");
}

#[test]
fn database_recovers_corrupt_sqlite_without_touching_petpacks() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    paths.ensure().unwrap();

    let petpack_path = paths.pets_dir.join("keep.petpack");
    std::fs::write(&petpack_path, b"petpack-bytes").unwrap();
    std::fs::write(&paths.db_path, b"this is not sqlite").unwrap();
    let wal_path = std::path::PathBuf::from(format!("{}-wal", paths.db_path.display()));
    let shm_path = std::path::PathBuf::from(format!("{}-shm", paths.db_path.display()));
    std::fs::write(&wal_path, b"stale wal").unwrap();
    std::fs::write(&shm_path, b"stale shm").unwrap();

    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();

    assert!(paths.db_path.is_file());
    assert_eq!(std::fs::read(&petpack_path).unwrap(), b"petpack-bytes");
    assert!(database.behavior().unwrap().enabled);

    let backup = std::fs::read_dir(&paths.home)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("agent-pet.sqlite.corrupt-"))
                && !path.to_string_lossy().ends_with("-wal")
                && !path.to_string_lossy().ends_with("-shm")
        })
        .expect("corrupt sqlite backup should exist");
    assert_eq!(std::fs::read(&backup).unwrap(), b"this is not sqlite");
    assert!(std::path::PathBuf::from(format!("{}-wal", backup.display())).is_file());
    assert!(std::path::PathBuf::from(format!("{}-shm", backup.display())).is_file());
    assert!(!wal_path.exists());
    assert!(!shm_path.exists());
}

#[test]
fn database_migrates_pet_generation_source_columns() {
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("legacy.sqlite");
    {
        let connection = rusqlite::Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE pets (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  style TEXT NOT NULL,
                  quality TEXT NOT NULL,
                  render_width INTEGER NOT NULL,
                  render_height INTEGER NOT NULL,
                  petpack_path TEXT NOT NULL,
                  cover_path TEXT NOT NULL,
                  active INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL
                );
                INSERT INTO pets
                  (id, name, style, quality, render_width, render_height, petpack_path, cover_path, active, created_at)
                VALUES
                  ('pet_legacy', 'Legacy Pet', '半写实', 'high', 384, 416, '/tmp/legacy.petpack', '/tmp/legacy-cover.png', 1, '2026-07-09T00:00:00Z');
                "#,
            )
            .unwrap();
    }

    let database = Database::new(&db_path);
    database.init().unwrap();
    let mut pet = database.get_pet("pet_legacy").unwrap().unwrap();
    assert_eq!(pet.origin, petcore_types::PetOrigin::ExternalImport);
    assert_eq!(pet.generator, None);
    assert_eq!(pet.provenance, None);

    pet.generator = Some("codex-app-server-brief-petpack-v1".to_string());
    pet.provenance = Some("codex_app_server_brief".to_string());
    database.upsert_pet(&pet).unwrap();

    let stored = database.get_pet("pet_legacy").unwrap().unwrap();
    assert_eq!(stored.origin, petcore_types::PetOrigin::ExternalImport);
    assert_eq!(
        stored.generator.as_deref(),
        Some("codex-app-server-brief-petpack-v1")
    );
    assert_eq!(stored.provenance.as_deref(), Some("codex_app_server_brief"));
}

#[test]
fn renderer_budget_reports_original_ring_cache_window() {
    let original_smooth =
        petcore::metrics::renderer_budget(QualityLevel::Original, FpsProfileName::Smooth);
    assert!(original_smooth.uses_ring_cache);
    assert_eq!(original_smooth.fps, 20);
    assert_eq!(original_smooth.frame_count_for_two_seconds, 40);
    assert_eq!(original_smooth.runtime_cache_frame_limit, 9);
    assert!(original_smooth.estimated_runtime_cache_mb < original_smooth.decoded_state_mb);
    assert!(original_smooth.estimated_runtime_cache_mb < 90.0);

    let high_standard =
        petcore::metrics::renderer_budget(QualityLevel::High, FpsProfileName::Standard);
    assert!(!high_standard.uses_ring_cache);
    assert_eq!(
        high_standard.runtime_cache_frame_limit,
        high_standard.frame_count_for_two_seconds
    );
}

#[test]
fn deleting_active_pet_removes_assets_and_reactivates_remaining_pet() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let first_source = temp.path().join("first");
    let second_source = temp.path().join("second");
    write_sample_petpack_dir(&first_source, QualityLevel::High, "First Pet", "半写实", 1).unwrap();
    write_sample_petpack_dir(
        &second_source,
        QualityLevel::High,
        "Second Pet",
        "半写实",
        1,
    )
    .unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let first = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": first_source.display().to_string() }),
        ),
    )
    .unwrap();
    let second = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": second_source.display().to_string() }),
        ),
    )
    .unwrap();

    let first_id = first["id"].as_str().unwrap();
    let first_petpack = std::path::PathBuf::from(first["petpack_path"].as_str().unwrap());
    let first_cover = std::path::PathBuf::from(first["cover_path"].as_str().unwrap());
    let first_frames = first_petpack
        .parent()
        .unwrap()
        .join(format!("{first_id}-frames"));
    assert!(first_petpack.is_file());
    assert!(first_cover.is_file());
    assert!(first_frames.join("idle/0000.png").is_file());
    assert!(first_frames.join("tool/0000.png").is_file());

    handle_request(&state, request("pet.activate", json!({ "id": first_id }))).unwrap();
    let deleted = handle_request(&state, request("pet.delete", json!({ "id": first_id }))).unwrap();
    assert_eq!(deleted["deleted_assets"], true);
    assert!(!first_petpack.exists());
    assert!(!first_cover.exists());
    assert!(!first_frames.exists());

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0]["id"], second["id"]);
    assert_eq!(pets[0]["active"], true);
}

#[test]
fn pet_delete_keeps_database_row_when_asset_staging_fails() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let source = temp.path().join("broken-delete");
    write_sample_petpack_dir(&source, QualityLevel::High, "Broken Delete", "半写实", 1).unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": source.display().to_string() }),
        ),
    )
    .unwrap();
    let pet_id = imported["id"].as_str().unwrap();
    let cover_path = std::path::PathBuf::from(imported["cover_path"].as_str().unwrap());
    std::fs::remove_file(&cover_path).unwrap();
    std::fs::create_dir(&cover_path).unwrap();

    let error = handle_request(&state, request("pet.delete", json!({ "id": pet_id })))
        .unwrap_err()
        .to_string();
    assert!(error.contains("not a file"));

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0]["id"], pet_id);
    assert_eq!(pets[0]["active"], true);
}

#[test]
fn activating_or_deleting_unknown_pet_does_not_clear_active_pet() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let source = temp.path().join("known");
    write_sample_petpack_dir(&source, QualityLevel::High, "Known Pet", "半写实", 1).unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": source.display().to_string() }),
        ),
    )
    .unwrap();
    let pet_id = imported["id"].as_str().unwrap();
    assert_eq!(imported["active"], true);

    let activate_error = handle_request(
        &state,
        request("pet.activate", json!({ "id": "pet_missing" })),
    )
    .unwrap_err()
    .to_string();
    assert!(activate_error.contains("pet not found"));

    let delete_error = handle_request(
        &state,
        request("pet.delete", json!({ "id": "pet_missing" })),
    )
    .unwrap_err()
    .to_string();
    assert!(delete_error.contains("pet not found"));

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0]["id"], pet_id);
    assert_eq!(pets[0]["active"], true);
}

#[test]
fn reimporting_petpack_preserves_active_state_and_owned_package() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let source = temp.path().join("reimport-source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Reimport Pet", "半写实", 1).unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": source.display().to_string() }),
        ),
    )
    .unwrap();
    let pet_id = imported["id"].as_str().unwrap();
    let owned_petpack = imported["petpack_path"].as_str().unwrap();
    handle_request(&state, request("pet.activate", json!({ "id": pet_id }))).unwrap();

    let reimported_from_source = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": source.display().to_string() }),
        ),
    )
    .unwrap();
    assert_eq!(reimported_from_source["id"], pet_id);
    assert_eq!(reimported_from_source["active"], true);

    let reimported_from_owned_package = handle_request(
        &state,
        request("petpack.import", json!({ "path": owned_petpack })),
    )
    .unwrap();
    assert_eq!(reimported_from_owned_package["id"], pet_id);
    assert_eq!(reimported_from_owned_package["active"], true);
    assert!(std::path::Path::new(owned_petpack).is_file());

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0]["id"], pet_id);
    assert_eq!(pets[0]["active"], true);
}

#[test]
fn snapshot_repairs_legacy_relative_cover_path_from_petpack() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let source = temp.path().join("legacy-cover");
    write_sample_petpack_dir(&source, QualityLevel::High, "Legacy Cover Pet", "半写实", 1).unwrap();

    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    };

    let imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({ "path": source.display().to_string() }),
        ),
    )
    .unwrap();
    let mut legacy_pet: PetSummary = serde_json::from_value(imported).unwrap();
    let original_cover = std::path::PathBuf::from(&legacy_pet.cover_path);
    assert!(original_cover.is_file());
    std::fs::remove_file(&original_cover).unwrap();
    legacy_pet.cover_path = "assets/preview/cover.png".to_string();
    state.database.upsert_pet(&legacy_pet).unwrap();

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    let repaired_cover = pets[0]["cover_path"].as_str().unwrap();
    assert_ne!(repaired_cover, "assets/preview/cover.png");
    assert!(std::path::Path::new(repaired_cover).is_file());
}

#[test]
fn snapshot_exposes_cached_pet_asset_repair_failure() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    let source = temp.path().join("snapshot-warning-source");
    write_sample_petpack_dir(&source, QualityLevel::High, "Snapshot Warning", "半写实", 2).unwrap();
    let request = |method: &str, params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("snapshot-warning")),
        method: method.to_string(),
        params,
    };
    let imported = handle_request(
        &state,
        request(
            "petpack.import",
            json!({"path": source.display().to_string()}),
        ),
    )
    .unwrap();
    handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let petpack = std::path::PathBuf::from(imported["petpack_path"].as_str().unwrap());
    let frames = petpack
        .parent()
        .unwrap()
        .join(format!("{}-frames", imported["id"].as_str().unwrap()));
    std::fs::remove_dir_all(frames).unwrap();
    std::fs::write(&petpack, b"corrupt package").unwrap();

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    let warnings = snapshot["pet_asset_warnings"].as_array().unwrap();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0]["pet_id"], imported["id"]);
    assert_eq!(warnings[0]["code"], "pet_assets_invalid");
    assert!(warnings[0]["message"]
        .as_str()
        .is_some_and(|value| !value.is_empty()));
    assert_eq!(snapshot["pets"].as_array().unwrap().len(), 1);
}

#[test]
fn daemon_does_not_remove_active_socket() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    paths.ensure().unwrap();
    let _listener = UnixListener::bind(&paths.socket_path).unwrap();

    let error = daemon::serve(paths, None).unwrap_err().to_string();
    assert!(error.contains("already active"));
}

#[test]
fn http_agent_events_require_capability_token() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let ready_file = temp.path().join("daemon-ready");
    let serve_paths = paths.clone();
    std::thread::spawn(move || daemon::serve(serve_paths, Some(&ready_file)).unwrap());
    wait_for_file(&paths.http_port_path);
    wait_for_file(&paths.token_path);

    let token = std::fs::read_to_string(&paths.token_path)
        .unwrap()
        .trim()
        .to_string();
    let token_permissions = std::fs::metadata(&paths.token_path)
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(token_permissions, 0o600);
    let port = std::fs::read_to_string(&paths.http_port_path)
        .unwrap()
        .trim()
        .parse::<u16>()
        .unwrap();
    let event = json!({
        "id": "evt_http_token",
        "source": "codex",
        "project_path": "/tmp/http-project",
        "session_id": "sess_http",
        "event_type": "tool",
        "title": "执行工具",
        "detail": "Bash"
    });

    let (unauthorized_status, unauthorized_body) = http_post_agent_event(port, None, &event);
    assert_eq!(unauthorized_status, 401);
    assert_eq!(unauthorized_body["error"], "missing capability token");

    let (authorized_status, authorized_body) = http_post_agent_event(port, Some(&token), &event);
    assert_eq!(authorized_status, 200);
    assert_eq!(authorized_body["inserted"], true);
    assert_eq!(authorized_body["triggered"], true);

    let recent = daemon::request(&paths, "events.recent", json!({ "limit": 1 })).unwrap();
    assert_eq!(recent[0]["id"], "evt_http_token");
    assert_eq!(recent[0]["source"], "codex");
    assert_eq!(recent[0]["event_type"], "tool");
    let snapshot = daemon::request(&paths, "state.snapshot", json!({})).unwrap();
    assert_eq!(snapshot["events"][0]["id"], "evt_http_token");

    std::fs::remove_file(&paths.token_path).unwrap();
    let (stale_status, stale_body) = http_post_agent_event(port, Some(&token), &event);
    assert_eq!(stale_status, 401);
    assert_eq!(stale_body["error"], "missing capability token");
    wait_for_file(&paths.token_path);
    let healed_token = std::fs::read_to_string(&paths.token_path)
        .unwrap()
        .trim()
        .to_string();
    assert!(!healed_token.is_empty());
    assert_ne!(healed_token, token);
    let healed_permissions = std::fs::metadata(&paths.token_path)
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(healed_permissions, 0o600);
    let mut healed_event = event.clone();
    healed_event["id"] = json!("evt_http_token_healed");
    let (healed_status, healed_body) =
        http_post_agent_event(port, Some(&healed_token), &healed_event);
    assert_eq!(healed_status, 200);
    assert_eq!(healed_body["inserted"], true);
}

#[test]
fn capability_token_rebuilds_empty_and_expired_files() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    paths.ensure().unwrap();

    std::fs::write(&paths.token_path, "").unwrap();
    std::fs::set_permissions(&paths.token_path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let rebuilt = daemon::write_capability_token(&paths).unwrap();
    assert!(rebuilt.starts_with("cap_"));
    assert_eq!(
        std::fs::metadata(&paths.token_path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    let fresh = daemon::write_capability_token(&paths).unwrap();
    assert_eq!(fresh, rebuilt);

    let old_time = SystemTime::now() - Duration::from_secs(48 * 60 * 60);
    let token_file = std::fs::File::options()
        .read(true)
        .write(true)
        .open(&paths.token_path)
        .unwrap();
    token_file
        .set_times(
            std::fs::FileTimes::new()
                .set_accessed(old_time)
                .set_modified(old_time),
        )
        .unwrap();
    let rotated = daemon::write_capability_token(&paths).unwrap();
    assert_ne!(rotated, rebuilt);
    assert!(rotated.starts_with("cap_"));
}

#[test]
fn launch_agent_plist_can_be_installed_and_uninstalled_without_loading() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let launch_agents_dir = temp.path().join("LaunchAgents");
    let program = temp.path().join("bin/petcore");
    let home = temp.path().join("home");
    let _launch_dir = EnvVarGuard::set("APC_LAUNCH_AGENT_DIR", &launch_agents_dir);
    let _skip_launchctl = EnvVarGuard::set("APC_SKIP_LAUNCHCTL", "1");

    let config = LaunchAgentConfig::new(program.clone(), home.clone());
    let plist = config.plist_xml();
    assert!(plist.contains("<key>Label</key>"));
    assert!(plist.contains("<string>dev.agentpet.petcore</string>"));
    assert!(plist.contains("<key>RunAtLoad</key>"));
    assert!(plist.contains("<key>KeepAlive</key>"));
    assert!(plist.contains(&format!("<string>{}</string>", program.display())));
    assert!(plist.contains(&format!("<string>{}</string>", home.display())));

    let installed = launch_agent::install(&config, false).unwrap();
    assert_eq!(installed.label, launch_agent::DEFAULT_LABEL);
    assert!(installed.installed);
    assert_eq!(installed.loaded, None);
    let plist_path = launch_agents_dir.join("dev.agentpet.petcore.plist");
    assert!(plist_path.is_file());
    let written = std::fs::read_to_string(&plist_path).unwrap();
    assert_eq!(written, plist);

    let status = launch_agent::status(false);
    assert!(status.installed);
    assert_eq!(status.loaded, None);

    let uninstalled = launch_agent::uninstall(launch_agent::DEFAULT_LABEL, false).unwrap();
    assert!(!uninstalled.installed);
    assert!(!plist_path.exists());
}

#[test]
fn generation_fails_without_app_server_when_local_fallback_is_not_enabled() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", "");
    let _disable_app_server_auto = EnvVarGuard::set("APC_DISABLE_CODEX_APP_SERVER_AUTO", "1");
    let _disable_local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "0");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "必须由真实 Codex App Server 生成。",
                "style": "半写实",
                "quality": "high",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let messages = loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let failed = messages.as_array().unwrap().iter().any(|message| {
            message["content"]
                .as_str()
                .unwrap_or("")
                .contains("请在 Agent 连接中修复 Codex App Server 后重试")
        });
        if failed {
            break messages;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not fail when App Server was unavailable"
        );
        std::thread::sleep(Duration::from_millis(50));
    };

    assert!(messages.as_array().unwrap().iter().any(|message| {
        message["progress"].as_f64() == Some(1.0)
            && message["kind"].as_str() == Some("generation_failed")
            && message["content"]
                .as_str()
                .unwrap_or("")
                .contains("Codex App Server brief turn 未完成")
    }));
    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert_eq!(snapshot["pets"].as_array().unwrap().len(), 0);
}

#[test]
fn generation_fails_when_skill_petpack_source_is_invalid_without_local_fallback() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-invalid-source-complete");
    write_fake_app_server_script(&fake_app_server, "thread_fake_invalid_petpack_source");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let _disable_local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "0");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "Skill 写出的 petpack-source 无效时必须失败。",
                "style": "半写实",
                "quality": "high",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();
    let invalid_source = state.paths.jobs_dir.join(job_id).join("petpack-source");
    std::fs::create_dir_all(&invalid_source).unwrap();
    std::fs::write(invalid_source.join("manifest.json"), "{ invalid json").unwrap();
    std::fs::write(&wait_file, "ok").unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let messages = loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let failed = messages.as_array().unwrap().iter().any(|message| {
            message["content"]
                .as_str()
                .unwrap_or("")
                .contains("Pet Studio Skill 输出的 petpack-source 不可用")
        });
        if failed {
            break messages;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not fail when Skill produced invalid petpack-source"
        );
        std::thread::sleep(Duration::from_millis(50));
    };

    assert!(messages.as_array().unwrap().iter().any(|message| {
        message["progress"].as_f64() == Some(1.0)
            && message["kind"].as_str() == Some("generation_failed")
            && message["content"]
                .as_str()
                .unwrap_or("")
                .contains("修复 Codex App Server / Skill 后重试")
    }));
    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert_eq!(snapshot["pets"].as_array().unwrap().len(), 0);
}

#[test]
fn generation_external_full_source_rejects_brief_only_materialization() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    write_fake_app_server_script(&fake_app_server, "thread_fake_brief_only_external_source");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _disable_local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "0");
    let _strict_full_source = EnvVarGuard::set("APC_REQUIRE_SKILL_FULL_SOURCE", "1");
    let _strict_external_source = EnvVarGuard::set("APC_REQUIRE_EXTERNAL_SKILL_SOURCE", "1");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "App Server 只返回 brief 时必须不能冒充外部 full source。",
                "style": "半写实",
                "quality": "standard",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let messages = loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let failed = messages.as_array().unwrap().iter().any(|message| {
            message["kind"].as_str() == Some("generation_failed")
                && message["content"]
                    .as_str()
                    .unwrap_or("")
                    .contains("external full source mode")
        });
        if failed {
            break messages;
        }
        assert!(
            Instant::now() < deadline,
            "external full-source generation did not reject brief-only App Server output: {}",
            serde_json::to_string_pretty(&messages).unwrap()
        );
        std::thread::sleep(Duration::from_millis(50));
    };

    assert!(messages.as_array().unwrap().iter().any(|message| {
        message["kind"].as_str() == Some("generation_failed")
            && message["content"]
                .as_str()
                .unwrap_or("")
                .contains("不会使用内置 Pet Studio materializer")
    }));
    let source_dir = state.paths.jobs_dir.join(job_id).join("petpack-source");
    assert!(!source_dir.join("manifest.json").exists());
    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert_eq!(snapshot["pets"].as_array().unwrap().len(), 0);
}

#[test]
fn generation_external_full_source_rejects_deterministic_preview_helper() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-helper-source-complete");
    write_fake_app_server_script(&fake_app_server, "thread_fake_external_helper_source");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let _disable_local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "0");
    let _strict_full_source = EnvVarGuard::set("APC_REQUIRE_SKILL_FULL_SOURCE", "1");
    let _strict_external_source = EnvVarGuard::set("APC_REQUIRE_EXTERNAL_SKILL_SOURCE", "1");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "App Server 调用 Skill helper 写出完整外部 source。",
                "style": "半写实",
                "quality": "standard",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();
    let job_dir = state.paths.jobs_dir.join(job_id);
    let helper_path = job_dir.join("apc_write_skill_source.py");

    let deadline = Instant::now() + Duration::from_secs(5);
    while !helper_path.is_file() {
        assert!(
            Instant::now() < deadline,
            "external Skill helper was not staged in the job workspace"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let helper_output = Command::new("python3")
        .arg("apc_write_skill_source.py")
        .current_dir(&job_dir)
        .output()
        .unwrap();
    assert!(
        helper_output.status.success(),
        "helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&helper_output.stdout),
        String::from_utf8_lossy(&helper_output.stderr)
    );
    std::fs::write(&wait_file, "ok").unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let rejected = messages.as_array().unwrap().iter().any(|message| {
            message["kind"].as_str() == Some("generation_failed")
                && message["content"]
                    .as_str()
                    .unwrap_or("")
                    .contains("deterministic_preview")
        });
        if rejected {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "deterministic preview helper was not rejected: {}",
            serde_json::to_string_pretty(&messages).unwrap()
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let source_path = job_dir
        .join("petpack-source")
        .join("source")
        .join("source.json");
    let source: serde_json::Value =
        serde_json::from_slice(&std::fs::read(source_path).unwrap()).unwrap();
    assert_eq!(source["generator"], "agent-pet-studio-preview-helper");
    assert_eq!(source["provenance"], "deterministic_preview");
    assert_eq!(source["skill_helper"], "agent-pet-studio-preview-helper-v2");
    assert_eq!(source["preview_only"], true);
    assert_eq!(source["frames_per_state"], 12);
    assert!(source.get("materialized_by").is_none());

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert!(snapshot["pets"].as_array().unwrap().is_empty());
}

#[test]
fn generation_builtin_full_source_marks_internal_materializer() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    write_fake_app_server_script(&fake_app_server, "thread_fake_builtin_full_source");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _disable_local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "0");
    let _strict_full_source = EnvVarGuard::set("APC_REQUIRE_SKILL_FULL_SOURCE", "1");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "App 默认 full source 模式允许内置 materializer 写出完整 source。",
                "style": "半写实",
                "quality": "standard",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let completed = messages
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["kind"].as_str() == Some("generation_completed"));
        if completed {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "built-in full-source materializer did not complete: {}",
            serde_json::to_string_pretty(&messages).unwrap()
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let source_path = state
        .paths
        .jobs_dir
        .join(job_id)
        .join("petpack-source")
        .join("source")
        .join("source.json");
    let source: serde_json::Value =
        serde_json::from_slice(&std::fs::read(source_path).unwrap()).unwrap();
    assert_eq!(source["generator"], "petcore-deterministic-preview");
    assert_eq!(source["provenance"], "deterministic_preview");
    assert_eq!(
        source["materialized_by"],
        "petcore-internal-skill-materializer"
    );

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0]["origin"], "generated_by_petcore_job");
}

#[test]
fn generation_fails_when_all_reference_images_are_unusable() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    write_fake_app_server_script(&fake_app_server, "thread_fake_unusable_reference");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    let missing_reference = temp.path().join("missing-reference.png");

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "需要参考图的宠物。",
                "style": "半写实",
                "quality": "high",
                "reference_images": [missing_reference.display().to_string()]
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let failed = messages.as_array().unwrap().iter().any(|message| {
            message["content"]
                .as_str()
                .unwrap_or("")
                .contains("参考图不可用")
        });
        if failed {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not report unusable reference image"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    assert_eq!(
        state.database.generation_job_status(job_id).unwrap(),
        Some(GenerationJobStatus::Failed)
    );
    assert!(state.database.list_pets().unwrap().is_empty());
}

#[test]
fn generation_cancel_stops_running_job_without_importing_pet() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-app-server-complete");
    write_fake_app_server_script(&fake_app_server, "thread_fake_cancel");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "取消中的桌宠生成。",
                "style": "半写实",
                "quality": "high",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let turn_started = messages.as_array().unwrap().iter().any(|message| {
            message["content"]
                .as_str()
                .unwrap_or("")
                .contains("Pet Studio brief turn 已启动")
        });
        if turn_started {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not reach running turn"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let cancel_messages = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.cancel".to_string(),
            params: json!({ "job_id": job_id }),
        },
    )
    .unwrap();
    assert!(cancel_messages.as_array().unwrap().iter().any(|message| {
        message["progress"].as_f64() == Some(1.0)
            && message["kind"].as_str() == Some("generation_canceled")
            && message["content"].as_str().unwrap_or("") == "已取消生成。"
    }));
    assert!(state.paths.jobs_dir.join(job_id).join("canceled").is_file());
    let reply_after_cancel = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.reply".to_string(),
            params: json!({
                "job_id": job_id,
                "content": "取消后的回复不能触发调整"
            }),
        },
    )
    .unwrap_err()
    .to_string();
    assert!(reply_after_cancel.contains("generation was canceled"));

    std::fs::write(&wait_file, "ok").unwrap();
    std::thread::sleep(Duration::from_millis(600));
    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert_eq!(snapshot["pets"].as_array().unwrap().len(), 0);
}

#[test]
fn generation_reply_is_rejected_while_job_is_running() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-app-server-complete");
    write_fake_app_server_script(&fake_app_server, "thread_fake_running_reply");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "运行中回复应被拒绝。",
                "style": "半写实",
                "quality": "high",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let turn_started = messages.as_array().unwrap().iter().any(|message| {
            message["content"]
                .as_str()
                .unwrap_or("")
                .contains("Pet Studio brief turn 已启动")
        });
        if turn_started {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not reach running turn"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let error = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.reply".to_string(),
            params: json!({
                "job_id": job_id,
                "content": "这条运行中回复不能静默记录"
            }),
        },
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("generation is still running"));

    let messages = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.messages".to_string(),
            params: json!({ "job_id": job_id }),
        },
    )
    .unwrap();
    assert!(!messages.as_array().unwrap().iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap_or("")
            .contains("这条运行中回复不能静默记录")
    }));

    handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.cancel".to_string(),
            params: json!({ "job_id": job_id }),
        },
    )
    .unwrap();
    std::fs::write(&wait_file, "ok").unwrap();
}

#[test]
fn generation_retry_creates_tracked_job_from_previous_form() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let database = Database::new(paths.db_path.clone());
    paths.ensure().unwrap();
    database.init().unwrap();
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", temp.path().join("missing-server"));
    let _disable_auto = EnvVarGuard::set("APC_DISABLE_CODEX_APP_SERVER_AUTO", "1");

    let form = GenerationForm {
        description: "可重试的宠物".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::High,
        reference_images: vec![],
    };

    let failed_dir = paths.jobs_dir.join("job_retry_source");
    std::fs::create_dir_all(&failed_dir).unwrap();
    database
        .create_generation_job("job_retry_source", &form, &failed_dir)
        .unwrap();
    database
        .update_generation_job("job_retry_source", GenerationJobStatus::Failed, None)
        .unwrap();

    let retry_id = generation::retry_generation(&paths, &database, "job_retry_source", None)
        .expect("failed job should be retryable");
    let retry_job = database.generation_job(&retry_id).unwrap().unwrap();
    assert_eq!(retry_job.session_id, None);
    assert_eq!(
        retry_job.retry_of_job_id.as_deref(),
        Some("job_retry_source")
    );
    let retry_form: GenerationForm = serde_json::from_str(&retry_job.form_json).unwrap();
    assert_eq!(retry_form.description, form.description);
    generation::cancel_generation(&paths, &database, &retry_id).unwrap();

    let running_dir = paths.jobs_dir.join("job_running_source");
    std::fs::create_dir_all(&running_dir).unwrap();
    database
        .create_generation_job("job_running_source", &form, &running_dir)
        .unwrap();
    database
        .update_generation_job("job_running_source", GenerationJobStatus::Running, None)
        .unwrap();
    let error = generation::retry_generation(&paths, &database, "job_running_source", None)
        .unwrap_err()
        .to_string();
    assert!(error.contains("not retryable"));
}

#[test]
fn generation_waits_for_user_input_and_resumes_after_reply() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server_input_request.sh");
    write_fake_app_server_input_request_script(&fake_app_server, "thread_fake_input_request");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "1");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "需要追问的桌宠。",
                "style": "半写实",
                "quality": "high",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let waiting = messages.as_array().unwrap().iter().any(|message| {
            message["kind"].as_str() == Some("input_request")
                && message["content"]
                    .as_str()
                    .unwrap_or("")
                    .contains("请补充这个桌宠的主体外观")
        });
        if waiting {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not reach input request state"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(
        state.database.generation_job_status(job_id).unwrap(),
        Some(GenerationJobStatus::WaitingForUser)
    );

    let reply_messages = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.reply".to_string(),
            params: json!({
                "job_id": job_id,
                "content": "主体是粉白长裙的东方幻想少女，动作轻盈。"
            }),
        },
    )
    .unwrap();
    assert!(reply_messages.as_array().unwrap().iter().any(|message| {
        message["role"].as_str() == Some("user")
            && message["content"]
                .as_str()
                .unwrap_or("")
                .contains("粉白长裙")
    }));

    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let completed = messages
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["kind"].as_str() == Some("generation_completed"));
        if completed {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "generation did not complete after user input; messages={messages}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(
        state.database.generation_job_status(job_id).unwrap(),
        Some(GenerationJobStatus::Completed)
    );
    assert_eq!(state.database.list_pets().unwrap().len(), 1);
}

#[test]
fn ensure_ready_marks_stale_interrupted_generation_job_failed() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths.clone());
    state.ensure_ready().unwrap();

    let form = GenerationForm {
        description: "中断恢复测试".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::High,
        reference_images: Vec::new(),
    };
    let running_dir = paths.jobs_dir.join("job_interrupted_running");
    std::fs::create_dir_all(&running_dir).unwrap();
    state
        .database
        .create_generation_job("job_interrupted_running", &form, &running_dir)
        .unwrap();
    state
        .database
        .update_generation_job(
            "job_interrupted_running",
            GenerationJobStatus::Running,
            None,
        )
        .unwrap();
    rusqlite::Connection::open(state.database.path())
        .unwrap()
        .execute(
            "UPDATE generation_jobs SET heartbeat_at = '2000-01-01T00:00:00Z' WHERE id = ?1",
            ["job_interrupted_running"],
        )
        .unwrap();

    let restarted = CoreState::new(paths);
    restarted.ensure_ready().unwrap();

    let job_id = "job_interrupted_running";
    assert_eq!(
        restarted.database.generation_job_status(job_id).unwrap(),
        Some(GenerationJobStatus::Failed)
    );
    let messages = petcore::generation::read_messages(&restarted.paths, job_id).unwrap();
    assert!(messages.iter().any(|message| {
        message["progress"].as_f64() == Some(1.0)
            && message["kind"].as_str() == Some("generation_failed")
            && message["content"]
                .as_str()
                .unwrap_or("")
                .contains("生成已中断")
    }));
    assert!(restarted
        .database
        .interrupted_generation_jobs()
        .unwrap()
        .is_empty());
    assert_eq!(restarted.database.list_pets().unwrap().len(), 0);
}

#[test]
fn generation_builds_form_driven_petpack_with_cover_and_source() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    write_fake_app_server_script(&fake_app_server, "thread_fake_pet_studio");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _local_fallback = EnvVarGuard::set("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK", "1");
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    let reference_path = temp.path().join("reference.png");
    ImageBuffer::from_pixel(12, 12, Rgba([240u8, 210, 220, 255]))
        .save(&reference_path)
        .unwrap();
    let original_reference_path = reference_path.display().to_string();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "安静陪伴的东方幻想角色，工作时衣摆发光。",
                "style": "半写实",
                "quality": "high",
                "reference_images": [original_reference_path.clone()]
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();
    wait_for_file(
        &state
            .paths
            .jobs_dir
            .join(job_id)
            .join("input/references/reference-00.png"),
    );

    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        if messages
            .as_array()
            .and_then(|items| items.last())
            .and_then(|message| message.get("progress"))
            .and_then(|progress| progress.as_f64())
            == Some(1.0)
        {
            break;
        }
        assert!(Instant::now() < deadline, "generation did not complete");
        std::thread::sleep(Duration::from_millis(50));
    }

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    let pet = &pets[0];
    assert_eq!(pet["name"], "AI 云袖");
    assert_eq!(pet["origin"], "generated_by_petcore_job");
    assert_eq!(pet["generator"], "codex-app-server-brief-petpack-v1");
    assert_eq!(pet["provenance"], "codex_app_server_brief");
    assert!(std::path::Path::new(pet["cover_path"].as_str().unwrap()).is_file());

    let petpack_path = std::path::Path::new(pet["petpack_path"].as_str().unwrap());
    let frames_dir = petpack_path
        .parent()
        .unwrap()
        .join(format!("{}-frames", pet["id"].as_str().unwrap()));
    assert!(frames_dir.join("idle/0000.png").is_file());
    assert!(frames_dir.join("tool/0023.png").is_file());
    std::fs::remove_dir_all(&frames_dir).unwrap();
    handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert!(frames_dir.join("idle/0000.png").is_file());
    assert!(frames_dir.join("tool/0023.png").is_file());
    let idle_frame = image::open(frames_dir.join("idle/0000.png"))
        .unwrap()
        .to_rgba8();
    assert_eq!(idle_frame.get_pixel(192, 208).0, [240, 210, 220, 255]);
    let validation = validate_petpack_path(petpack_path).unwrap();
    assert_eq!(validation.manifest.name, "AI 云袖");

    let final_messages = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.messages".to_string(),
            params: json!({ "job_id": job_id }),
        },
    )
    .unwrap();
    let final_items = final_messages.as_array().unwrap();
    assert!(final_items.iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap()
            .contains("Pet Studio brief turn 已启动")
    }));
    assert!(final_items.iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap()
            .contains("Codex 正在生成宠物 brief")
    }));
    assert!(final_items.iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap()
            .contains("已收到 Codex 回复")
    }));
    assert!(final_items.iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap()
            .contains("已按固定 7 状态 petpack 契约补齐")
    }));

    let file = std::fs::File::open(petpack_path).unwrap();
    let mut archive = zip::ZipArchive::new(file).unwrap();
    assert!(archive.by_name("assets/preview/cover.png").is_ok());
    assert!(archive
        .by_name("assets/preview/animated_preview.webp")
        .is_ok());
    assert!(archive.by_name("source/prompt.md").is_ok());
    assert!(archive.by_name("source/source.json").is_ok());
    assert!(archive
        .by_name("source/references/reference-00.png")
        .is_ok());
    let mut prompt = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("source/prompt.md").unwrap(),
        &mut prompt,
    )
    .unwrap();
    assert!(prompt.contains("source/references/reference-00.png"));
    assert!(!prompt.contains(&original_reference_path));
    let mut skill_session = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("source/skill_session.jsonl").unwrap(),
        &mut skill_session,
    )
    .unwrap();
    assert!(skill_session.contains("agent-pet-studio"));
    assert!(skill_session.contains("codex_thread.started"));
    assert!(skill_session.contains("codex_turn.completed"));
    assert!(skill_session.contains("thread_fake_pet_studio"));
    assert!(skill_session.contains("turn_fake_pet_studio"));
    assert!(skill_session.contains("states.rendered"));
    assert!(skill_session.contains("\"frames_per_state\":24"));
    assert!(skill_session.contains("source/references/reference-00.png"));
    assert!(!skill_session.contains(&original_reference_path));
    let brief: serde_json::Value =
        serde_json::from_reader(archive.by_name("brief.json").unwrap()).unwrap();
    assert_eq!(
        brief["description"],
        "安静陪伴的东方幻想角色，工作时衣摆发光。"
    );
    assert_eq!(brief["ai_brief"]["name"], "AI 云袖");
    assert_eq!(brief["ai_brief"]["visual_brief"], "AI brief");
    assert_eq!(brief["ai_brief"]["states"].as_array().unwrap().len(), 7);
    assert_eq!(
        brief["generation"]["generator"],
        "codex-app-server-brief-petpack-v1"
    );
    assert_eq!(brief["generation"]["provenance"], "codex_app_server_brief");
    assert_eq!(brief["states"][0]["motion"], "breathing");
    assert_eq!(brief["states"][1]["state"], "start");
    assert_eq!(brief["states"][1]["motion"], "抬头进入工作状态");
    let source: serde_json::Value =
        serde_json::from_reader(archive.by_name("source/source.json").unwrap()).unwrap();
    assert_eq!(source["generator"], "codex-app-server-brief-petpack-v1");
    assert_eq!(source["provenance"], "codex_app_server_brief");
    assert_eq!(source["palette_source"], "codex-ai-brief");
    assert_eq!(source["palette"]["source"], "codex-ai-brief");
    assert_eq!(source["visual_source"], "reference-image");
    assert_eq!(source["frames_per_state"], 24);
    assert_eq!(
        source["form"]["reference_images"][0],
        "source/references/reference-00.png"
    );
    assert_eq!(
        source["reference_files"][0],
        "source/references/reference-00.png"
    );
    assert_eq!(source["input_reference_count"], 1);
    assert_eq!(source["copied_reference_count"], 1);
    assert!(!source.to_string().contains(&original_reference_path));
    let mut cover_bytes = Vec::new();
    std::io::Read::read_to_end(
        &mut archive.by_name("assets/preview/cover.png").unwrap(),
        &mut cover_bytes,
    )
    .unwrap();
    let cover = image::load_from_memory(&cover_bytes).unwrap().to_rgba8();
    assert_eq!(cover.get_pixel(192, 208).0, [240, 210, 220, 255]);
    let validation_metadata: serde_json::Value =
        serde_json::from_reader(archive.by_name("build/validation.json").unwrap()).unwrap();
    assert_eq!(
        validation_metadata["generator"],
        "codex-app-server-brief-petpack-v1"
    );
    assert_eq!(validation_metadata["provenance"], "codex_app_server_brief");
    assert_eq!(validation_metadata["frames_per_state"], 24);

    let reply_messages = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.reply".to_string(),
            params: json!({
                "job_id": job_id,
                "content": "等待确认动作再明显一点"
            }),
        },
    )
    .unwrap();
    let reply_items = reply_messages.as_array().unwrap();
    assert!(reply_items.iter().any(|message| {
        message["role"] == "user" && message["content"] == "等待确认动作再明显一点"
    }));
    assert!(reply_items.iter().any(|message| {
        message["role"] == "assistant"
            && message["content"]
                .as_str()
                .unwrap()
                .contains("正在恢复 Codex 会话")
    }));

    let revision_deadline = Instant::now() + Duration::from_secs(20);
    let reply_message_count = reply_items.len();
    let revision_messages = loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let completed = messages
            .as_array()
            .unwrap()
            .iter()
            .skip(reply_message_count)
            .any(|message| message["kind"].as_str() == Some("generation_completed"));
        if completed {
            break messages;
        }
        assert!(
            Instant::now() < revision_deadline,
            "revision did not complete"
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    let revision_items = revision_messages.as_array().unwrap();
    assert!(revision_items.iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap()
            .contains("已恢复 Codex App Server 会话")
    }));
    assert!(revision_items.iter().any(|message| {
        message["content"]
            .as_str()
            .unwrap()
            .contains("调整 turn 已启动")
    }));

    let revised_snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let revised_pets = revised_snapshot["pets"].as_array().unwrap();
    assert_eq!(revised_pets.len(), 2);
    let active_pet = revised_pets
        .iter()
        .find(|pet| pet["active"] == true)
        .expect("revised pet should be active");
    assert_ne!(active_pet["id"], pet["id"]);
    assert_eq!(active_pet["name"], "AI 云袖");
}

#[test]
fn generation_imports_codex_skill_petpack_source_when_present() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_app_server = temp.path().join("fake_app_server.sh");
    let wait_file = temp.path().join("allow-app-server-complete");
    write_fake_app_server_script(&fake_app_server, "thread_fake_skill_petpack");
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", fake_app_server.as_os_str());
    let _wait_file = EnvVarGuard::set("APC_FAKE_APP_SERVER_WAIT_FILE", wait_file.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let start = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "由 Skill 写出的完整 petpack source。",
                "style": "现代",
                "quality": "high",
                "reference_images": []
            }),
        },
    )
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap();
    let source_dir = state.paths.jobs_dir.join(job_id).join("petpack-source");
    let manifest = write_sample_petpack_dir(
        &source_dir,
        QualityLevel::High,
        "Skill Rendered Pet",
        "现代",
        2,
    )
    .unwrap();
    let source_metadata_dir = source_dir.join("source");
    std::fs::create_dir_all(&source_metadata_dir).unwrap();
    std::fs::write(
        source_metadata_dir.join("source.json"),
        serde_json::to_vec_pretty(&json!({
            "generator": "codex-app-server-skill",
            "provenance": "skill-full-source",
            "manifest_id": manifest.id,
            "pet_name": "Skill Rendered Pet"
        }))
        .unwrap(),
    )
    .unwrap();
    std::fs::write(
        source_metadata_dir.join("skill_session.jsonl"),
        serde_json::to_string(&json!({
            "event": "skill.petpack_source.written",
            "runner": "codex-app-server"
        }))
        .unwrap(),
    )
    .unwrap();
    std::fs::write(&wait_file, "ok").unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let messages = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("test")),
                method: "generation.messages".to_string(),
                params: json!({ "job_id": job_id }),
            },
        )
        .unwrap();
        let completed = messages
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["kind"].as_str() == Some("generation_completed"));
        if completed {
            break;
        }
        let failed = messages
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["kind"].as_str() == Some("generation_failed"));
        assert!(
            !failed,
            "skill petpack source import failed: {}",
            serde_json::to_string_pretty(&messages).unwrap()
        );
        assert!(
            Instant::now() < deadline,
            "skill petpack source was not imported: {}",
            serde_json::to_string_pretty(&messages).unwrap()
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let pets = snapshot["pets"].as_array().unwrap();
    assert_eq!(pets.len(), 1);
    assert_eq!(pets[0]["name"], "Skill Rendered Pet");
    assert_eq!(pets[0]["origin"], "verified_skill_source");
    assert_eq!(pets[0]["generator"], "codex-app-server-skill");
    assert_eq!(pets[0]["provenance"], "skill-full-source");
    let petpack_path = std::path::Path::new(pets[0]["petpack_path"].as_str().unwrap());
    let validation = validate_petpack_path(petpack_path).unwrap();
    assert_eq!(validation.manifest.id, manifest.id);

    let file = std::fs::File::open(petpack_path).unwrap();
    let mut archive = zip::ZipArchive::new(file).unwrap();
    assert!(archive
        .by_name("assets/preview/animated_preview.webp")
        .is_ok());
    let source: serde_json::Value =
        serde_json::from_reader(archive.by_name("source/source.json").unwrap()).unwrap();
    assert_eq!(source["generator"], "codex-app-server-skill");
    assert_eq!(source["provenance"], "skill-full-source");
    let mut skill_session = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("source/skill_session.jsonl").unwrap(),
        &mut skill_session,
    )
    .unwrap();
    assert!(skill_session.contains("skill.petpack_source.written"));
}

#[test]
fn repair_generates_real_pi_and_opencode_connectors() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_agent_home = temp.path().join("agent-home");
    let fake_cli = temp.path().join("petcore-cli");
    let capture_path = temp.path().join("connector-capture.log");
    write_fake_cli(&fake_cli);
    let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", fake_agent_home.as_os_str());
    let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", fake_cli.as_os_str());
    let _app_server_cmd = EnvVarGuard::set("CODEX_APP_SERVER_CMD", "");
    let _disable_app_server_auto = EnvVarGuard::set("APC_DISABLE_CODEX_APP_SERVER_AUTO", "1");
    let paths = AppPaths::new(temp.path().to_path_buf());
    paths.ensure().unwrap();

    let codex_status = connections::repair_source(&paths, AgentSource::Codex).unwrap();
    let codex_plugin = fake_agent_home
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
        .join(".codex-plugin")
        .join("plugin.json");
    let codex_hooks = fake_agent_home
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
        .join("hooks")
        .join("hooks.json");
    let codex_skill = fake_agent_home
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
        .join("skills")
        .join("agent-pet-studio")
        .join("SKILL.md");
    let codex_marketplace = fake_agent_home
        .join(".agents")
        .join("plugins")
        .join("marketplace.json");
    let codex_marketplace_content = std::fs::read_to_string(&codex_marketplace).unwrap();
    let codex_marketplace_json: serde_json::Value =
        serde_json::from_str(&codex_marketplace_content).unwrap();
    let codex_skill_content = std::fs::read_to_string(&codex_skill).unwrap();
    assert!(codex_plugin.is_file());
    assert!(codex_skill_content.contains("Generate Agent Pet Companion .petpack assets"));
    assert!(codex_skill_content.contains("APC_PETCORE_CLI"));
    assert!(codex_marketplace_content.contains("agent-pet-companion"));
    let codex_marketplace_plugin = codex_marketplace_json["plugins"]
        .as_array()
        .unwrap()
        .iter()
        .find(|plugin| plugin["name"] == "agent-pet-companion")
        .unwrap();
    let expected_codex_plugin_path = fake_agent_home
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
        .display()
        .to_string();
    assert_eq!(
        codex_marketplace_plugin["source"]["path"].as_str(),
        Some(expected_codex_plugin_path.as_str())
    );
    assert!(codex_status
        .items
        .iter()
        .any(|item| item.name == "插件源" && item.status == CheckStatus::Ok));
    assert!(codex_status
        .items
        .iter()
        .any(|item| item.name == "Codex marketplace" && item.status == CheckStatus::Ok));
    let codex_hooks_json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&codex_hooks).unwrap()).unwrap();
    let codex_session_start_command = codex_hooks_json["hooks"]["SessionStart"][0]["hooks"][0]
        ["command"]
        .as_str()
        .unwrap();
    run_shell_hook_smoke(
        codex_session_start_command,
        r#"{"hook_event_name":"SessionStart","session_id":"sess_codex_runtime","cwd":"/tmp/codex-project"}"#,
        &capture_path,
    );
    let codex_capture = wait_for_capture(&capture_path, "--source codex");
    assert!(codex_capture.contains("--event-type auto"));
    assert!(codex_capture.contains("sess_codex_runtime"));

    let claude_status = connections::repair_source(&paths, AgentSource::ClaudeCode).unwrap();
    let claude_settings = fake_agent_home.join(".claude").join("settings.json");
    let claude_settings_content = std::fs::read_to_string(&claude_settings).unwrap();
    assert!(claude_settings_content.contains("agent hook --source claude_code"));
    assert!(claude_status
        .items
        .iter()
        .any(|item| item.name == "Claude settings.json" && item.status == CheckStatus::Ok));
    let claude_settings_json: serde_json::Value =
        serde_json::from_str(&claude_settings_content).unwrap();
    let claude_tool_command = claude_settings_json["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        .as_str()
        .unwrap();
    run_shell_hook_smoke(
        claude_tool_command,
        r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"sess_claude_runtime"}"#,
        &capture_path,
    );
    let claude_settings_capture = wait_for_capture(&capture_path, "--source claude_code");
    assert!(claude_settings_capture.contains("--event-type auto"));
    assert!(claude_settings_capture.contains("sess_claude_runtime"));
    let claude_hook_script = paths
        .connectors_dir
        .join("claude-code")
        .join("agent-pet-companion-hook.sh");
    let claude_hook_output = Command::new(&claude_hook_script)
        .env("APC_FAKE_CLI_CAPTURE", &capture_path)
        .env("APC_EVENT_TYPE", "waiting")
        .env("APC_EVENT_TITLE", "等待确认")
        .output()
        .unwrap();
    assert!(
        claude_hook_output.status.success(),
        "Claude hook helper failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&claude_hook_output.stdout),
        String::from_utf8_lossy(&claude_hook_output.stderr)
    );
    let claude_helper_capture = wait_for_capture(&capture_path, "--event-type waiting");
    assert!(claude_helper_capture.contains("--source claude_code"));

    let pi_status = connections::repair_source(&paths, AgentSource::Pi).unwrap();
    let pi_extension = fake_agent_home
        .join(".pi")
        .join("agent")
        .join("extensions")
        .join("agent-pet-companion.ts");
    let pi_script = std::fs::read_to_string(&pi_extension).unwrap();
    assert!(pi_script.contains("export default function agentPetCompanion(pi)"));
    assert!(pi_script.contains("pi.on(\"agent_settled\""));
    assert!(pi_script.contains("event?.isError === true"));
    assert!(pi_script.contains("\"--event-type\", \"auto\""));
    assert!(!pi_script.contains("permission_request"));
    assert!(!pi_script.contains("tool_execution_failed"));
    assert!(pi_status
        .items
        .iter()
        .any(|item| item.name == "Extension" && item.status == CheckStatus::Ok));
    assert!(pi_status
        .items
        .iter()
        .any(|item| item.name == "RPC" && item.status == CheckStatus::Ok));
    assert!(pi_status.items.iter().any(|item| {
        item.name == "Extension 运行时"
            && item.status == CheckStatus::Ok
            && item.detail.contains("外部事件 CLI 覆盖")
    }));
    assert!(!fake_agent_home
        .join(".pi")
        .join("agent")
        .join("extensions")
        .join("rpc-check.json")
        .exists());
    let pi_module = temp.path().join("pi-connector.mjs");
    std::fs::write(&pi_module, &pi_script).unwrap();
    run_node_module_smoke(
        &format!(
            r#"
const mod = await import('file://{module_path}');
const handlers = new Map();
mod.default({{ on: (name, callback) => handlers.set(name, callback) }});
if (!handlers.has('tool_call')) throw new Error('Pi tool_call handler missing');
if (!handlers.has('tool_execution_end')) throw new Error('Pi tool_execution_end handler missing');
if (!handlers.has('agent_settled')) throw new Error('Pi agent_settled handler missing');
await handlers.get('tool_call')(
  {{ type: 'tool_call', toolName: 'bash', toolCallId: 'secret-call', input: {{ command: 'secret' }} }},
  {{ sessionManager: {{ getSessionId: () => 'sess_pi_runtime' }}, cwd: '/tmp/pi-project' }}
);
await handlers.get('tool_execution_end')(
  {{ type: 'tool_execution_end', toolName: 'bash', toolCallId: 'secret-call', result: 'secret-output', isError: true }},
  {{ sessionManager: {{ getSessionId: () => 'sess_pi_failed' }}, cwd: '/tmp/pi-project' }}
);
await handlers.get('agent_settled')(
  {{ type: 'agent_settled' }},
  {{ sessionManager: {{ getSessionId: () => 'sess_pi_done' }}, cwd: '/tmp/pi-project' }}
);
await new Promise((resolve) => setTimeout(resolve, 500));
"#,
            module_path = pi_module.display()
        ),
        &capture_path,
    );
    let pi_capture = wait_for_capture(&capture_path, "--source pi");
    assert!(pi_capture.contains("--event-type auto"));
    assert!(pi_capture.contains("\"type\":\"tool_call\""));
    assert!(pi_capture.contains("\"session_id\":\"sess_pi_runtime\""));
    assert!(pi_capture.contains("\"is_error\":true"));
    assert!(pi_capture.contains("\"type\":\"agent_settled\""));
    assert!(!pi_capture.contains("secret-output"));

    let opencode_status = connections::repair_source(&paths, AgentSource::Opencode).unwrap();
    let opencode_plugin = fake_agent_home
        .join(".config")
        .join("opencode")
        .join("plugins")
        .join("agent-pet-companion.js");
    let opencode_script = std::fs::read_to_string(&opencode_plugin).unwrap();
    assert!(opencode_script.contains("export const AgentPetCompanion"));
    assert!(opencode_script.contains("event: async ({ event })"));
    assert!(opencode_script.contains("\"tool.execute.before\""));
    assert!(opencode_script.contains("\"--event-type\", \"auto\""));
    assert!(opencode_script.contains("output?.args"));
    assert!(!opencode_script.contains("session.done"));
    assert!(!opencode_script.contains("tool.execute.failed"));
    assert!(opencode_status
        .items
        .iter()
        .any(|item| item.name == "Plugin" && item.status == CheckStatus::Ok));
    assert!(opencode_status
        .items
        .iter()
        .any(|item| item.name == "OpenCode Server" && item.status == CheckStatus::Ok));
    assert!(opencode_status.items.iter().any(|item| {
        item.name == "Plugin 运行时"
            && item.status == CheckStatus::Ok
            && item.detail.contains("外部事件 CLI 覆盖")
    }));
    assert!(!fake_agent_home
        .join(".config")
        .join("opencode")
        .join("plugins")
        .join("server-check.json")
        .exists());
    let opencode_module = temp.path().join("opencode-connector.mjs");
    std::fs::write(&opencode_module, &opencode_script).unwrap();
    run_node_module_smoke(
        &format!(
            r#"
const mod = await import('file://{module_path}');
const plugin = await mod.AgentPetCompanion({{
  project: 'demo',
  directory: '/tmp/opencode-project',
  worktree: '/tmp/opencode-worktree'
}});
if (!plugin['tool.execute.before']) throw new Error('OpenCode tool.execute.before handler missing');
await plugin['tool.execute.before'](
  {{ tool: 'bash', sessionID: 'sess_opencode_runtime', callID: 'secret-call-id' }},
  {{ args: {{ command: 'TOKEN=secret-command' }} }}
);
await new Promise((resolve) => setTimeout(resolve, 500));
"#,
            module_path = opencode_module.display()
        ),
        &capture_path,
    );
    let opencode_capture = wait_for_capture(&capture_path, "--source opencode");
    assert!(opencode_capture.contains("--event-type auto"));
    assert!(opencode_capture.contains("\"type\":\"tool.execute.before\""));
    assert!(opencode_capture.contains("\"sessionID\":\"sess_opencode_runtime\""));
    assert!(!opencode_capture.contains("secret-command"));

    let codex_uninstall = connections::uninstall_source(&paths, AgentSource::Codex).unwrap();
    let codex_marketplace_after = std::fs::read_to_string(&codex_marketplace).unwrap();
    assert!(!codex_plugin.exists());
    assert!(!codex_marketplace_after.contains("agent-pet-companion"));
    assert!(codex_uninstall
        .items
        .iter()
        .any(|item| item.name == "插件源" && item.status != CheckStatus::Ok));

    connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();
    let claude_settings_after = std::fs::read_to_string(&claude_settings).unwrap();
    assert!(!claude_settings_after.contains("agent hook --source claude_code"));

    connections::uninstall_source(&paths, AgentSource::Pi).unwrap();
    assert!(!pi_extension.exists());

    connections::uninstall_source(&paths, AgentSource::Opencode).unwrap();
    assert!(!opencode_plugin.exists());
}

#[test]
fn codex_repair_reports_plugin_install_failure_as_needs_fix() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_home = temp.path().join("home");
    let fake_cli = temp.path().join("petcore-cli");
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let codex = bin_dir.join("codex");
    std::fs::write(
        &codex,
        r#"#!/bin/sh
if [ "$1" = "plugin" ] && [ "$2" = "add" ]; then
  printf '%s\n' '{"error":"install failed"}' >&2
  exit 42
fi
if [ "$1" = "plugin" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
  printf '%s\n' '{"installed":[]}'
  exit 0
fi
exit 0
"#,
    )
    .unwrap();
    let mut permissions = std::fs::metadata(&codex).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&codex, permissions).unwrap();
    write_fake_cli(&fake_cli);

    let _home = EnvVarGuard::set("HOME", fake_home.as_os_str());
    // This test deliberately exercises the real Codex installation branch inside
    // a temporary HOME. Do not let a caller's isolation override turn that branch
    // into the APC_AGENT_CONFIG_HOME dry-run path.
    let _agent_config_home = EnvVarGuard::remove("APC_AGENT_CONFIG_HOME");
    let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", fake_cli.as_os_str());
    let _path = EnvVarGuard::set(
        "PATH",
        format!(
            "{}:{}",
            bin_dir.display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    );
    let _disable_app_server_auto = EnvVarGuard::set("APC_DISABLE_CODEX_APP_SERVER_AUTO", "1");
    let _app_server_cmd = EnvVarGuard::set("CODEX_APP_SERVER_CMD", "");
    let paths = AppPaths::new(temp.path().join("apc-home"));
    paths.ensure().unwrap();

    let status = connections::repair_source(&paths, AgentSource::Codex).unwrap();
    let install_item = status
        .items
        .iter()
        .find(|item| item.name == "Codex 插件安装")
        .expect("Codex plugin install item should exist");
    assert_eq!(install_item.status, CheckStatus::NeedsFix);

    let result_path = fake_home
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
        .join("codex-install-result.json");
    let install_result: serde_json::Value =
        serde_json::from_slice(&std::fs::read(result_path).unwrap()).unwrap();
    assert_eq!(install_result["status"], "failed");
    assert_eq!(install_result["code"], 42);
    assert_eq!(install_result["timed_out"], false);
    assert!(install_result.get("stdout").is_none());
    assert!(install_result.get("stderr").is_none());
}

#[test]
fn connection_check_reports_event_channel_when_socket_is_reachable() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_cli = temp.path().join("petcore-cli");
    write_fake_cli(&fake_cli);
    let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", fake_cli.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let _listener = UnixListener::bind(&paths.socket_path).unwrap();

    let status = connections::check_source(&paths, AgentSource::Pi);
    let event_channel = status
        .items
        .iter()
        .find(|item| item.name == "事件回传")
        .expect("event channel check should be present");

    assert_eq!(event_channel.status, CheckStatus::Ok);
    assert!(event_channel.detail.contains("socket 已连接"));
}

#[test]
fn snapshot_connection_status_does_not_spawn_codex_app_server_probe() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_home = temp.path().join("user-home");
    std::fs::create_dir_all(&fake_home).unwrap();
    let _home = EnvVarGuard::set("HOME", fake_home.as_os_str());
    let _agent_config_home = EnvVarGuard::remove("APC_AGENT_CONFIG_HOME");
    let app_server_marker = temp.path().join("app-server-spawned");
    let codex_marker = temp.path().join("codex-cli-spawned");
    let script = temp.path().join("marker_app_server.sh");
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
touch '{}'
while IFS= read -r request; do
  case "$request" in
    *initialize*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"marker-app-server"}}}}}}'
      ;;
  esac
done
"#,
            app_server_marker.display()
        ),
    )
    .unwrap();
    let mut permissions = std::fs::metadata(&script).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&script, permissions).unwrap();

    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let codex_script = bin_dir.join("codex");
    std::fs::write(
        &codex_script,
        format!(
            r#"#!/bin/sh
touch '{}'
printf '%s\n' '{{"installed":[]}}'
"#,
            codex_marker.display()
        ),
    )
    .unwrap();
    let mut codex_permissions = std::fs::metadata(&codex_script).unwrap().permissions();
    codex_permissions.set_mode(0o755);
    std::fs::set_permissions(&codex_script, codex_permissions).unwrap();

    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _path = EnvVarGuard::set(
        "PATH",
        format!(
            "{}:{}",
            bin_dir.display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    );
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert!(
        !app_server_marker.exists(),
        "state.snapshot spawned Codex App Server"
    );
    assert!(!codex_marker.exists(), "state.snapshot invoked codex CLI");
    let codex_status = snapshot["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|status| status["source"] == "codex")
        .unwrap();
    let app_server_item = codex_status["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == "Codex App Server")
        .unwrap();
    assert_eq!(app_server_item["status"], "ok");
    assert!(app_server_item["detail"]
        .as_str()
        .unwrap()
        .contains("点击检查验证"));

    let checked = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "connections.check".to_string(),
            params: json!({ "source": "codex" }),
        },
    )
    .unwrap();
    assert!(
        app_server_marker.exists(),
        "manual connection check did not probe App Server"
    );
    assert!(
        codex_marker.exists(),
        "manual connection check did not invoke codex CLI"
    );
    assert!(checked["items"].as_array().unwrap().iter().any(|item| {
        item["name"] == "Codex App Server"
            && item["status"] == "ok"
            && item["detail"]
                .as_str()
                .unwrap_or("")
                .contains("stdio 初始化成功")
    }));

    let cached_snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let cached_codex_status = cached_snapshot["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|status| status["source"] == "codex")
        .unwrap();
    assert_eq!(cached_codex_status["check_mode"], "light");
}

#[test]
fn snapshot_preserves_cached_runtime_connection_status_when_light_check_is_clean() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let fake_agent_home = temp.path().join("agent-home");
    let fake_cli = temp.path().join("petcore-cli");
    write_fake_cli(&fake_cli);
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let pi_command = bin_dir.join("pi");
    std::fs::write(&pi_command, "#!/bin/sh\nexit 0\n").unwrap();
    let mut pi_permissions = std::fs::metadata(&pi_command).unwrap().permissions();
    pi_permissions.set_mode(0o755);
    std::fs::set_permissions(&pi_command, pi_permissions).unwrap();

    let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", fake_agent_home.as_os_str());
    let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", fake_cli.as_os_str());
    let _path = EnvVarGuard::set(
        "PATH",
        format!(
            "{}:{}",
            bin_dir.display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    );

    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();
    let _listener = UnixListener::bind(&state.paths.socket_path).unwrap();

    let checked = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "connections.repair".to_string(),
            params: json!({ "source": "pi" }),
        },
    )
    .unwrap();
    assert_eq!(checked["check_mode"], "runtime");
    assert!(checked["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|item| { item["status"] == "ok" }));

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let pi_status = snapshot["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|status| status["source"] == "pi")
        .unwrap();
    assert_eq!(pi_status["check_mode"], "runtime");
    assert!(pi_status["items"].as_array().unwrap().iter().any(|item| {
        item["name"] == "事件自检"
            && item["status"] == "ok"
            && item["detail"]
                .as_str()
                .unwrap_or("")
                .contains("跳过自动写入自检")
    }));
}

#[test]
fn codex_app_server_probe_uses_configured_stdio_command() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("fake_app_server.sh");
    let fake_cli = temp.path().join("petcore-cli");
    write_fake_app_server_script(&script, "thread_fake_pet_studio");
    write_fake_cli(&fake_cli);
    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", fake_cli.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let probe = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "codex.app_server.probe".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    assert_eq!(probe["initialized"], true);
    assert_eq!(probe["mode"], "configured");
    assert_eq!(
        probe["response"]["result"]["serverInfo"]["name"],
        "fake-codex-app-server"
    );
    assert_eq!(
        probe["response"]["result"]["serverInfo"]["petcoreCli"],
        fake_cli.display().to_string()
    );

    let thread = petcore::app_server::start_pet_studio_thread(
        &state.paths,
        "job_fake",
        &petcore_types::GenerationForm {
            description: "测试".to_string(),
            style: "半写实".to_string(),
            quality: QualityLevel::High,
            reference_images: vec![],
        },
    );
    assert_eq!(thread["started"], true);
    assert_eq!(thread["thread_id"], "thread_fake_pet_studio");

    let session = petcore::app_server::run_pet_studio_session(
        &state.paths,
        "job_fake_turn",
        &petcore_types::GenerationForm {
            description: "测试".to_string(),
            style: "半写实".to_string(),
            quality: QualityLevel::High,
            reference_images: vec![],
        },
    );
    assert_eq!(session["completed"], true);
    assert_eq!(session["turn_id"], "turn_fake_pet_studio");
    assert_eq!(session["ai_brief"]["name"], "AI 云袖");
    assert_eq!(session["ai_brief"]["states"].as_array().unwrap().len(), 7);
    assert!(session["ai_brief_warnings"].as_array().unwrap().len() >= 6);
}

#[test]
fn codex_app_server_probe_reports_structured_stdio_errors() {
    let _env_lock = lock_env();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("failing_app_server.sh");
    let mut file = std::fs::File::create(&script).unwrap();
    writeln!(
        file,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *initialize*)
      printf '%s\n' 'fatal initialize diagnostic' >&2
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"error":{{"code":-32000,"message":"initialize boom"}}}}'
      ;;
  esac
done
"#
    )
    .unwrap();
    let mut permissions = std::fs::metadata(&script).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&script, permissions).unwrap();

    let _app_server = EnvVarGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let probe = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("test")),
            method: "codex.app_server.probe".to_string(),
            params: json!({}),
        },
    )
    .unwrap();

    assert_eq!(probe["initialized"], false);
    assert_eq!(probe["mode"], "configured");
    assert_eq!(probe["error_info"]["kind"], "server_error");
    assert_eq!(probe["error_info"]["stage"], "initialize");
    assert_eq!(probe["error_info"]["method"], "initialize");
    assert!(probe["error"].as_str().unwrap().contains("initialize boom"));
    assert!(probe["error_info"]["stderr_tail"]
        .as_array()
        .unwrap()
        .iter()
        .any(|line| line.as_str() == Some("fatal initialize diagnostic")));
}
