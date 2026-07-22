use petcore::app_server::{
    probe_codex_app_server, read_codex_recent_thread_activities,
    read_codex_recent_thread_activities_cached, read_codex_thread_display, run_pet_studio_session,
    CodexRecentThreadActivityCache,
};
use petcore::paths::AppPaths;
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{AgentEventType, GenerationForm, QualityLevel};
use rustix::io::Errno;
use rustix::process::{kill_process, test_kill_process, Pid, Signal};
use serde_json::json;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn recent_thread_activity_uses_state_db_and_bounded_display_fields() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("recent-activity.sh");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"activity-test"}}}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      case "$request" in
        *\"useStateDbOnly\":true*) ;;
        *) exit 31 ;;
      esac
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"  Active task  ","preview":"fallback","source":"vscode","status":{{"type":"active","activeFlags":[]}},"updatedAt":{recent}}},{{"id":"019f5a6f-0c52-75e1-b652-004d4487c4ae","name":"Stale task","preview":"stale","source":"vscode","status":{{"type":"notLoaded"}},"updatedAt":{stale}}}]}}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Active task","updatedAt":{recent},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Latest prompt"}}]}},{{"type":"commandExecution","command":"do-not-expose --secret"}},{{"type":"agentMessage","text":"Latest agent update"}},{{"type":"reasoning","summary":["**Checking connector parity**"]}}]}}]}}}}}}'
      ;;
  esac
done
"#,
            recent = now.saturating_sub(2),
            stale = now.saturating_sub(3_600),
            started = now.saturating_sub(20),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let activities = read_codex_recent_thread_activities(Duration::from_secs(900), 8).unwrap();
    assert_eq!(activities.len(), 1);
    let activity = &activities[0];
    assert_eq!(activity.title.as_deref(), Some("Active task"));
    assert_eq!(activity.event_type, AgentEventType::Start);
    assert!(activity.session_active);
    assert_eq!(activity.session_surface, "chatgpt_app");
    assert_eq!(
        activity.latest_user_message.as_ref().unwrap().content,
        "Latest prompt"
    );
    assert_eq!(
        activity.latest_message.as_ref().unwrap().content,
        "Latest agent update"
    );
    assert_eq!(activity.latest_activity.as_ref().unwrap().kind, "thinking");
    assert_eq!(
        activity
            .latest_activity
            .as_ref()
            .unwrap()
            .content
            .as_deref(),
        Some("Checking connector parity")
    );
    assert!(!format!("{activity:?}").contains("do-not-expose"));
}

#[test]
fn recent_thread_activity_cache_reads_only_changed_candidates_and_evicts_ineligible_entries() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("cached-recent-activity.sh");
    let phase_file = temp.path().join("phase");
    let read_count_file = temp.path().join("read-count");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let first_updated = now.saturating_sub(2);
    let changed_updated = now.saturating_sub(1);
    let expired_updated = now.saturating_sub(3_600);
    let started = now.saturating_sub(20);
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  phase=$(cat "$APC_TEST_ACTIVITY_PHASE_FILE")
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"activity-cache-test"}}}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      case "$phase" in
        missing)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[]}}}}'
          ;;
        expired)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision two","source":"vscode","status":{{"type":"active"}},"updatedAt":{expired_updated}}}]}}}}'
          ;;
        changed)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision two","source":"vscode","status":{{"type":"active"}},"updatedAt":{changed_updated}}}]}}}}'
          ;;
        *)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision one","source":"vscode","status":{{"type":"active"}},"updatedAt":{first_updated}}}]}}}}'
          ;;
      esac
      ;;
    *\"method\":\"thread/read\"*)
      count=0
      if [ -f "$APC_TEST_ACTIVITY_READ_COUNT_FILE" ]; then
        count=$(cat "$APC_TEST_ACTIVITY_READ_COUNT_FILE")
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$APC_TEST_ACTIVITY_READ_COUNT_FILE"
      case "$phase" in
        expired|missing)
          exit 41
          ;;
        changed)
          printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision two","updatedAt":{changed_updated},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Prompt"}}]}},{{"type":"agentMessage","text":"Reply two"}}]}}]}}}}}}'
          ;;
        *)
          printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision one","updatedAt":{first_updated},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Prompt"}}]}},{{"type":"agentMessage","text":"Reply one"}}]}}]}}}}}}'
          ;;
      esac
      ;;
  esac
done
"#,
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(&phase_file, "same").unwrap();
    let _phase = EnvGuard::set("APC_TEST_ACTIVITY_PHASE_FILE", phase_file.as_os_str());
    let _count = EnvGuard::set(
        "APC_TEST_ACTIVITY_READ_COUNT_FILE",
        read_count_file.as_os_str(),
    );
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let read_count = || {
        std::fs::read_to_string(&read_count_file)
            .unwrap_or_else(|_| "0".to_string())
            .trim()
            .parse::<u64>()
            .unwrap()
    };
    let mut cache = CodexRecentThreadActivityCache::default();

    let first = read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache)
        .unwrap();
    assert_eq!(first[0].title.as_deref(), Some("Revision one"));
    assert_eq!(
        first[0].latest_message.as_ref().unwrap().content,
        "Reply one"
    );
    assert_eq!(read_count(), 1);

    let unchanged =
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache)
            .unwrap();
    assert_eq!(unchanged.len(), 1);
    assert_eq!(unchanged[0].title, first[0].title);
    assert_eq!(unchanged[0].latest_message, first[0].latest_message);
    assert_eq!(read_count(), 1, "unchanged revision must skip thread/read");

    std::fs::write(&phase_file, "changed").unwrap();
    let changed =
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache)
            .unwrap();
    assert_eq!(changed[0].title.as_deref(), Some("Revision two"));
    assert_eq!(
        changed[0].latest_message.as_ref().unwrap().content,
        "Reply two"
    );
    assert_eq!(
        read_count(),
        2,
        "advanced revision must refresh thread/read"
    );

    std::fs::write(&phase_file, "missing").unwrap();
    assert!(
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache,)
            .unwrap()
            .is_empty()
    );
    assert_eq!(read_count(), 2);
    std::fs::write(&phase_file, "changed").unwrap();
    assert_eq!(
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache,)
            .unwrap()[0]
            .latest_message
            .as_ref()
            .unwrap()
            .content,
        "Reply two"
    );
    assert_eq!(read_count(), 3, "a disappeared entry must be evicted");

    std::fs::write(&phase_file, "expired").unwrap();
    assert!(
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache,)
            .unwrap()
            .is_empty()
    );
    assert_eq!(read_count(), 3, "expired candidates must not be read");
    std::fs::write(&phase_file, "changed").unwrap();
    let reappeared =
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache)
            .unwrap();
    assert_eq!(reappeared.len(), 1);
    assert_eq!(read_count(), 4, "an expired entry must be evicted");
}

#[test]
fn recent_thread_activity_excludes_internal_pet_studio_threads() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("internal-studio-activity.sh");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"internal-studio-filter-test"}}}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Pet Studio prompt","cwd":"/Users/test/Library/Application Support/AgentPetCompanion/generation-jobs/job_test","status":{{"type":"active"}},"updatedAt":{now}}},{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951d","name":"List omitted cwd","status":{{"type":"active"}},"updatedAt":{now}}}]}}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951d","name":"List omitted cwd","cwd":"/private/tmp/apc-test/generation-jobs/job_hidden","updatedAt":{now},"turns":[{{"status":"inProgress","items":[{{"type":"userMessage","content":[{{"type":"text","text":"Internal generation instructions"}}]}}]}}]}}}}}}'
      ;;
  esac
done
"#,
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let activities = read_codex_recent_thread_activities(Duration::from_secs(900), 8).unwrap();
    assert!(activities.is_empty());
}

#[test]
fn daemon_activity_sync_surfaces_chatgpt_task_without_hook_event() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("activity-sync.sh");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"sync-test"}}}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Synced ChatGPT task","preview":"fallback","source":"vscode","status":{{"type":"notLoaded"}},"updatedAt":{updated}}}]}}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Synced ChatGPT task","updatedAt":{updated},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"completed","startedAt":{started},"completedAt":{updated},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Sync this task"}}]}},{{"type":"agentMessage","text":"Task result is ready"}},{{"type":"reasoning","summary":["Final verification"]}}]}}]}}}}}}'
      ;;
  esac
done
"#,
            updated = now.saturating_sub(2),
            started = now.saturating_sub(30),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths).with_codex_activity_sync(true);
    state.ensure_ready().unwrap();
    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("snapshot")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let synced = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("wait")),
            method: "state.wait".to_string(),
            params: json!({
                "after_revision": snapshot["revision"],
                "timeout_ms": 3_000
            }),
        },
    )
    .unwrap();
    let session = synced["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| {
            session["overlay_display"]["navigation"]["routable_session_id"]
                == "019f5b0f-88ff-7413-8953-29de4ed0951c"
        })
        .unwrap();
    assert!(session["session_id"].as_str().unwrap().starts_with("ses-"));
    assert_eq!(session["official_status"], "ready");
    assert_eq!(session["overlay_display"]["summary_kind"], "done");
    assert_eq!(
        session["overlay_display"]["navigation"]["surface"],
        "chatgpt_app"
    );
    assert_eq!(
        session["overlay_display"]["navigation"]["session_open"],
        true
    );
    let overlay_json = serde_json::to_string(session).unwrap();
    for private in [
        "Synced ChatGPT task",
        "Task result is ready",
        "Sync this task",
    ] {
        assert!(!overlay_json.contains(private));
    }
    assert_eq!(session["lease_seconds"], 900);
}

#[test]
fn thread_display_reads_only_bounded_user_facing_text() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("thread-display.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"thread-display-test"}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"name":"  Demo\u0007 task  ","turns":[{"items":[{"type":"userMessage","id":"u1","content":[{"type":"text","text":"Initial question"}]},{"type":"commandExecution","id":"tool1","command":"do-not-expose --secret","status":"completed"},{"type":"agentMessage","id":"a1","text":"Latest\nanswer\u0007"}]}]}}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let display = read_codex_thread_display("019f5a6f-0c52-75e1-b652-004d4487c4ae").unwrap();
    assert_eq!(display.title.as_deref(), Some("Demo  task"));
    let user_message = display.latest_user_message.as_ref().unwrap();
    assert_eq!(user_message.role, "user");
    assert_eq!(user_message.content, "Initial question");
    let message = display.latest_message.unwrap();
    assert_eq!(message.role, "assistant");
    assert_eq!(message.content, "Latest answer");
    assert!(!message.content.contains("do-not-expose"));
    assert!(display.latest_activity.is_none());
}

#[test]
fn thread_display_does_not_reuse_reply_from_before_latest_user_message() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("thread-display-turn-boundary.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"turn-boundary-test"}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"name":"Turn boundary","turns":[{"items":[{"type":"agentMessage","text":"Previous reply"},{"type":"userMessage","content":[{"type":"text","text":"New prompt"}]}]}]}}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let display = read_codex_thread_display("019f5a6f-0c52-75e1-b652-004d4487c4ae").unwrap();
    assert!(display.latest_message.is_none());
    assert_eq!(display.latest_user_message.unwrap().content, "New prompt");
}

struct EnvGuard {
    key: &'static str,
    original: Option<OsString>,
}

impl EnvGuard {
    fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
        let original = std::env::var_os(key);
        std::env::set_var(key, value);
        Self { key, original }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        if let Some(value) = &self.original {
            std::env::set_var(self.key, value);
        } else {
            std::env::remove_var(self.key);
        }
    }
}

struct TestOwnedPid(Option<Pid>);

impl Drop for TestOwnedPid {
    fn drop(&mut self) {
        if let Some(pid) = self.0.take() {
            // This PID is written by the test-only helper during this probe.
            // Keep a failing regression from leaving its own
            // synthetic process behind; production cleanup never uses a PID
            // discovered from an untrusted file.
            let _ = kill_process(pid, Signal::KILL);
        }
    }
}

fn test_process_is_alive(pid: Pid) -> bool {
    match test_kill_process(pid) {
        Ok(()) => true,
        Err(Errno::SRCH) => false,
        Err(_) => true,
    }
}

#[test]
fn app_server_timeout_drop_terminates_owned_shell_descendants() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("app-server-with-helper.sh");
    let helper_pid_file = temp.path().join("helper.pid");
    let helper_exit_file = temp.path().join("helper-terminated");
    std::fs::write(
        &script,
        r#"#!/bin/sh
(
  trap '' HUP
  trap 'printf "%s\n" terminated > "$APC_TEST_HELPER_EXIT_FILE"; exit 0' TERM
  while :; do
    sleep 30
  done
) </dev/null >/dev/null 2>&1 &
helper_pid=$!
printf '%s\n' "$helper_pid" > "$APC_TEST_HELPER_PID_FILE"

while IFS= read -r request; do
  # Keep the protocol request unread by design. The public probe reaches its
  # response timeout and relies on StdioSession::drop for cleanup.
  :
done

# Deliberately retain the helper after stdin closes. Before App Server
# sessions had a dedicated process group, killing only `sh -lc` orphaned this
# inner script and helper exactly like the generation fixtures seen in CI.
wait "$helper_pid"
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _pid_file = EnvGuard::set("APC_TEST_HELPER_PID_FILE", helper_pid_file.as_os_str());
    let _exit_file = EnvGuard::set("APC_TEST_HELPER_EXIT_FILE", helper_exit_file.as_os_str());
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let result = probe_codex_app_server();
    assert_eq!(result["initialized"], false, "{result}");
    assert_eq!(
        result.pointer("/error_info/kind").and_then(|v| v.as_str()),
        Some("timeout"),
        "{result}"
    );

    let helper_pid = std::fs::read_to_string(&helper_pid_file)
        .unwrap()
        .trim()
        .parse::<i32>()
        .ok()
        .and_then(Pid::from_raw)
        .expect("fake App Server must publish its helper PID");
    let mut cleanup = TestOwnedPid(Some(helper_pid));
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline
        && (!helper_exit_file.is_file() || test_process_is_alive(helper_pid))
    {
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(
        helper_exit_file.is_file(),
        "owned helper did not receive the App Server process-group TERM"
    );
    assert!(
        !test_process_is_alive(helper_pid),
        "owned helper process {helper_pid} survived StdioSession drop"
    );
    cleanup.0 = None;
}

#[test]
fn stdout_eof_fails_immediately_with_exit_diagnostics() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("exits-immediately.sh");
    std::fs::write(
        &script,
        "#!/bin/sh\necho 'synthetic app-server failure' >&2\nexit 17\n",
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let started = Instant::now();
    let result = probe_codex_app_server();
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_millis(700),
        "EOF was treated as a timeout and took {elapsed:?}: {result}"
    );
    assert_eq!(
        result.pointer("/error_info/kind").and_then(|v| v.as_str()),
        Some("stdout_eof"),
        "{result}"
    );
    let serialized = result.to_string();
    assert!(
        serialized.contains("synthetic app-server failure"),
        "{result}"
    );
    assert!(serialized.contains("17"), "{result}");
}

#[test]
fn turn_event_stdout_eof_fails_immediately() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("exits-during-turn.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"eof-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_eof","sessionId":"thread_eof"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_eof","status":"inProgress"}}}'
      echo 'turn stream ended unexpectedly' >&2
      exit 23
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let form = GenerationForm {
        description: "EOF transport pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let started = Instant::now();
    let result = petcore::app_server::run_pet_studio_session(&paths, "job_eof", &form);
    let elapsed = started.elapsed();

    assert!(elapsed < Duration::from_secs(1), "{elapsed:?}: {result}");
    assert_eq!(
        result.pointer("/error_info/kind").and_then(|v| v.as_str()),
        Some("stdout_eof"),
        "{result}"
    );
    let serialized = result.to_string();
    assert!(serialized.contains("23"), "{result}");
    assert!(
        serialized.contains("turn stream ended unexpectedly"),
        "{result}"
    );
}

#[test]
fn generation_sends_initialized_and_accepts_turn_completed_boundary() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("turn-completed.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
initialized=0
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"turn-completed-test"}}}'
      ;;
    *\"method\":\"initialized\"*) initialized=1 ;;
    *\"method\":\"thread/start\"*)
      [ "$initialized" = 1 ] || exit 31
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_completed","sessionId":"thread_completed"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_completed","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread_completed","turnId":"turn_completed","delta":"{\"name\":\"Protocol Pet\"}"}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_completed","turn":{"id":"turn_completed","status":"completed"}}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let form = GenerationForm {
        description: "Protocol completion pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let result = run_pet_studio_session(&paths, "job_turn_completed", &form);
    assert_eq!(result["completed"], true, "{result}");
    assert_eq!(
        result["assistant_text"], r#"{"name":"Protocol Pet"}"#,
        "{result}"
    );
    assert_eq!(result["error"], serde_json::Value::Null, "{result}");
}
