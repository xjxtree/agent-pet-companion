use petcore::app_server::{
    archive_pet_studio_thread, inspect_pet_studio_thread, probe_codex_app_server,
    read_codex_recent_thread_activities, read_codex_recent_thread_activities_cached,
    read_codex_thread_display, run_pet_studio_session,
    run_pet_studio_session_with_updates_and_cancel, unarchive_pet_studio_thread,
    CodexRecentThreadActivityCache, PetStudioSessionUpdateKind,
};
use petcore::paths::AppPaths;
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{
    AgentEventType, GenerationForm, GenerationStudioSessionAvailability, QualityLevel,
};
use rustix::io::Errno;
use rustix::process::{kill_process, test_kill_process, Pid, Signal};
use serde_json::json;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn pet_studio_thread_inspection_routes_only_the_exact_live_thread() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("inspect-studio-thread.sh");
    let job_dir = temp.path().join("generation-jobs/job_history");
    std::fs::create_dir_all(&job_dir).unwrap();
    let thread_id = "019f5b0f-88ff-7413-8953-29de4ed0951c";
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"inspection-test"}}}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      case "$request" in
        *\"archived\":false*)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"{thread_id}","name":null,"source":"appServer","cwd":"'"$APC_TEST_JOB_CWD"'","ephemeral":false,"archived":false}}]}}}}'
          ;;
        *)
          printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"data":[]}}}}'
          ;;
      esac
      ;;
    *\"method\":\"thread/name/set\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":4,"result":{{}}}}'
      ;;
  esac
done
"#,
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _job_cwd = EnvGuard::set("APC_TEST_JOB_CWD", job_dir.as_os_str());
    let form = GenerationForm {
        description: "A calm fox with a glowing data-stream tail".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let navigation = inspect_pet_studio_thread(thread_id, &job_dir, &form).unwrap();
    assert_eq!(
        navigation.availability,
        GenerationStudioSessionAvailability::Available
    );
    assert!(navigation.can_open);
    assert_eq!(navigation.routable_session_id.as_deref(), Some(thread_id));
    assert!(navigation
        .name
        .as_deref()
        .is_some_and(|name| name.starts_with("Agent Pet Studio · ")));
}

#[test]
fn pet_studio_thread_inspection_withholds_archived_thread_routes() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("inspect-archived-studio-thread.sh");
    let job_dir = temp.path().join("generation-jobs/job_archived");
    std::fs::create_dir_all(&job_dir).unwrap();
    let thread_id = "019f5b0f-88ff-7413-8953-29de4ed0951d";
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"inspection-test"}}}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      case "$request" in
        *\"archived\":false*)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[]}}}}'
          ;;
        *)
          printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"data":[{{"id":"{thread_id}","name":"Archived Studio task","source":"appServer","cwd":"'"$APC_TEST_JOB_CWD"'","ephemeral":false,"archived":true}}]}}}}'
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
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _job_cwd = EnvGuard::set("APC_TEST_JOB_CWD", job_dir.as_os_str());
    let form = GenerationForm {
        description: "Archived pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let navigation = inspect_pet_studio_thread(thread_id, &job_dir, &form).unwrap();
    assert_eq!(
        navigation.availability,
        GenerationStudioSessionAvailability::Archived
    );
    assert!(!navigation.can_open);
    assert!(navigation.routable_session_id.is_none());
    assert_eq!(navigation.name.as_deref(), Some("Archived Studio task"));
}

#[test]
fn pet_studio_archive_treats_an_already_missing_exact_thread_as_closed() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("archive-missing-studio-thread.sh");
    let job_dir = temp.path().join("generation-jobs/job_missing");
    std::fs::create_dir_all(&job_dir).unwrap();
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"archive-missing-test"}}}'
      ;;
    *\"method\":\"thread/archive\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"thread not found"}}'
      ;;
    *\"method\":\"thread/list\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"data":[]}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    archive_pet_studio_thread("019f5b0f-88ff-7413-8953-29de4ed0951e", &job_dir).unwrap();
}

#[test]
fn pet_studio_unarchive_releases_the_exact_stopped_thread() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("unarchive-studio-thread.sh");
    let job_dir = temp.path().join("generation-jobs/job_released");
    std::fs::create_dir_all(&job_dir).unwrap();
    let thread_id = "019f5b0f-88ff-7413-8953-29de4ed0951f";
    std::fs::write(
        &script,
        format!(
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"serverInfo":{{"name":"unarchive-test"}}}}}}'
      ;;
    *\"method\":\"thread/unarchive\"*)
      case "$request" in
        *\"threadId\":\"{thread_id}\"*)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{}}}}'
          ;;
        *) exit 41 ;;
      esac
      ;;
  esac
done
"#,
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    unarchive_pet_studio_thread(thread_id, &job_dir).unwrap();
}

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
    *\"sourceKinds\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"data":[]}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      case "$request" in
        *\"useStateDbOnly\":true*) ;;
        *) exit 31 ;;
      esac
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"  Active task  ","preview":"fallback","source":"vscode","status":{{"type":"active","activeFlags":[]}},"updatedAt":{recent}}},{{"id":"019f5a6f-0c52-75e1-b652-004d4487c4ae","name":"Stale task","preview":"stale","source":"vscode","status":{{"type":"notLoaded"}},"updatedAt":{stale}}}]}}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":4,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Active task","updatedAt":{recent},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Latest prompt"}}]}},{{"type":"commandExecution","command":"do-not-expose --secret"}},{{"type":"agentMessage","text":"Latest agent update"}},{{"type":"reasoning","summary":["**Checking connector parity**"]}}]}}]}}}}}}'
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
    assert_eq!(activity.event_type, AgentEventType::Thinking);
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
    *\"sourceKinds\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951e","parentThreadId":"019f5b0f-88ff-7413-8953-29de4ed0951c","source":{{"subAgent":{{}}}},"updatedAt":{first_updated}}}]}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      case "$phase" in
        paged)
          printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[],"nextCursor":"remaining-page"}}}}'
          ;;
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
          printf '%s\n' '{{"jsonrpc":"2.0","id":4,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision two","updatedAt":{changed_updated},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Prompt"}}]}},{{"type":"agentMessage","text":"Reply two"}}]}}]}}}}}}'
          ;;
        *)
          printf '%s\n' '{{"jsonrpc":"2.0","id":4,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Revision one","updatedAt":{first_updated},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Prompt"}}]}},{{"type":"agentMessage","text":"Reply one"}}]}}]}}}}}}'
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
    assert!(cache
        .child_thread_ids()
        .contains("019f5b0f-88ff-7413-8953-29de4ed0951e"));

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
    assert!(cache
        .listed_thread_ids()
        .contains("019f5b0f-88ff-7413-8953-29de4ed0951c"));
    assert_eq!(
        cache
            .listed_thread_surfaces()
            .get("019f5b0f-88ff-7413-8953-29de4ed0951c")
            .map(String::as_str),
        Some("chatgpt_app")
    );
    assert!(cache.listing_complete());

    std::fs::write(&phase_file, "paged").unwrap();
    assert!(
        read_codex_recent_thread_activities_cached(Duration::from_secs(900), 8, &mut cache,)
            .unwrap()
            .is_empty()
    );
    assert!(cache.listed_thread_ids().is_empty());
    assert!(
        !cache.listing_complete(),
        "a continuation cursor cannot prove that an omitted task disappeared"
    );

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
    *\"sourceKinds\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"data":[]}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Pet Studio prompt","cwd":"/Users/test/Library/Application Support/AgentPetCompanion/generation-jobs/job_test","status":{{"type":"active"}},"updatedAt":{now}}},{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951d","name":"List omitted cwd","status":{{"type":"active"}},"updatedAt":{now}}}]}}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":4,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951d","name":"List omitted cwd","cwd":"/private/tmp/apc-test/generation-jobs/job_hidden","updatedAt":{now},"turns":[{{"status":"inProgress","items":[{{"type":"userMessage","content":[{{"type":"text","text":"Internal generation instructions"}}]}}]}}]}}}}}}'
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
fn daemon_activity_sync_surfaces_stopped_chatgpt_task_without_hook_event() {
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
    *\"sourceKinds\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"data":[]}}}}'
      ;;
    *\"method\":\"thread/list\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"data":[{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Synced ChatGPT task","preview":"fallback","source":"vscode","status":{{"type":"notLoaded"}},"updatedAt":{updated}}}]}}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{{"jsonrpc":"2.0","id":4,"result":{{"thread":{{"id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Synced ChatGPT task","updatedAt":{updated},"turns":[{{"id":"019f5f7c-ed41-76f2-bd7a-94ef01b580b1","status":"interrupted","startedAt":{started},"completedAt":{updated},"durationMs":10310,"items":[{{"type":"userMessage","content":[{{"type":"text","text":"Sync this task"}}]}},{{"type":"agentMessage","text":"Task result is ready"}},{{"type":"reasoning","summary":["Final verification"]}}]}}]}}}}}}'
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
    assert_eq!(
        session["overlay_display"]["navigation"]["capability"],
        "exact_session"
    );
    assert_eq!(session["session_title"], "Synced ChatGPT task");
    assert_eq!(
        session["session_user_message"],
        json!({"role": "user", "content": "Sync this task"})
    );
    assert_eq!(
        session["session_message"],
        json!({"role": "assistant", "content": "Task result is ready"})
    );
    let overlay_json = serde_json::to_string(session).unwrap();
    assert!(!overlay_json.contains("Final verification"));
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

    // On a saturated integration-test host the shell may not reach its helper
    // fork before the probe's own three-second response timeout. Establish the
    // descendant precondition with a bounded retry; every attempt must still
    // exercise the real timeout path.
    for attempt in 1..=3 {
        let result = probe_codex_app_server();
        assert_eq!(result["initialized"], false, "{result}");
        assert_eq!(
            result.pointer("/error_info/kind").and_then(|v| v.as_str()),
            Some("timeout"),
            "{result}"
        );
        if helper_pid_file.is_file() {
            break;
        }
        assert!(
            attempt < 3,
            "fake App Server did not publish its helper PID after {attempt} timeout attempts"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

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

    // The typed stdout_eof result below is the authoritative assertion that
    // this did not become a probe timeout. Keep only a broad wall-clock guard
    // here so temporary CI scheduler pressure cannot make the transport test
    // flaky.
    assert!(
        elapsed < Duration::from_secs(5),
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
    // Bound the failure case independently of the production 25-minute image
    // turn while still letting the typed stdout_eof assertion distinguish EOF
    // from the synthetic five-second timeout.
    let _turn_timeout = EnvGuard::set("APC_TEST_PET_STUDIO_TURN_TIMEOUT_MS", "5000");
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

    assert!(elapsed < Duration::from_secs(8), "{elapsed:?}: {result}");
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
fn pet_studio_initialization_tolerates_interactive_startup_scheduling() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("delayed-studio-initialize.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      sleep 4
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"delayed-studio-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_delayed","sessionId":"thread_delayed"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_delayed","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread_delayed","turnId":"turn_delayed","item":{"type":"agentMessage","id":"message_delayed","text":"{\"name\":\"Delayed Pet\"}"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_delayed","turn":{"id":"turn_delayed","status":"completed"}}}'
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
        description: "Interactive startup budget".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let result = run_pet_studio_session(&paths, "job_delayed_initialize", &form);
    assert_eq!(result["completed"], true, "{result}");
    assert_eq!(result["ai_brief"]["name"], "Delayed Pet", "{result}");
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

#[test]
fn generation_cancel_interrupts_the_active_codex_turn() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("cancel-active-turn.sh");
    let interrupt_file = temp.path().join("interrupt-request");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"cancel-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_cancel","sessionId":"thread_cancel"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_cancel","status":"inProgress"}}}'
      ;;
    *\"method\":\"turn/interrupt\"*)
      printf '%s' "$request" > "$APC_TEST_INTERRUPT_FILE"
      printf '%s\n' '{"jsonrpc":"2.0","id":9001,"result":{}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_cancel","turn":{"id":"turn_cancel","status":"interrupted"}}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _interrupt_file = EnvGuard::set("APC_TEST_INTERRUPT_FILE", interrupt_file.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let form = GenerationForm {
        description: "Cancelable pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let result = run_pet_studio_session_with_updates_and_cancel(
        &paths,
        "job_cancel_active_turn",
        &form,
        |_| {},
        || true,
    );

    assert_eq!(result["completed"], false, "{result}");
    assert_eq!(result["error"], "generation canceled", "{result}");
    let interrupt = std::fs::read_to_string(interrupt_file).unwrap();
    assert!(interrupt.contains("thread_cancel"), "{interrupt}");
    assert!(interrupt.contains("turn_cancel"), "{interrupt}");
    assert_eq!(
        result.pointer("/events/0/acknowledged"),
        Some(&json!(true)),
        "{result}"
    );
    assert_eq!(
        result.pointer("/events/0/completion_observed"),
        Some(&json!(true)),
        "{result}"
    );
}

#[test]
fn native_user_input_request_is_returned_with_options_and_stops_the_turn() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("native-user-input.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"input-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_input","sessionId":"thread_input"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_input","status":"inProgress"}}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":"request_palette","method":"item/tool/requestUserInput","params":{"threadId":"thread_input","turnId":"turn_input","itemId":"input_item","isBlocking":true,"questions":[{"id":"palette","header":"Palette","question":"Choose a palette","isOther":true,"options":[{"label":"Warm","description":"Amber and coral"},{"label":"Cool","description":"Cyan and violet"}]}]}}'
      ;;
    *\"method\":\"turn/interrupt\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":9002,"result":{}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_input","turn":{"id":"turn_input","status":"interrupted"}}}'
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
        description: "Input request pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let result = run_pet_studio_session(&paths, "job_native_input", &form);

    assert_eq!(result["needs_input"], true, "{result}");
    assert_eq!(result["completed"], false, "{result}");
    assert_eq!(result["input_request"]["payload_type"], "input_request");
    assert_eq!(result["input_request"]["request_id"], "request_palette");
    assert_eq!(result["input_request"]["questions"][0]["id"], "palette");
    assert_eq!(
        result["input_request"]["questions"][0]["options"][1]["label"],
        "Cool"
    );
    assert_eq!(
        result.pointer("/events/0/completion_observed"),
        Some(&json!(true)),
        "{result}"
    );
}

#[test]
fn generation_waits_through_transient_app_server_reconnects() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("transient-reconnect.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"transient-reconnect-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_reconnect","sessionId":"thread_reconnect"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_reconnect","status":"inProgress"}}}'
      printf '%s\n' '{"method":"error","params":{"error":{"message":"Reconnecting... 1/5"},"threadId":"thread_reconnect","turnId":"turn_reconnect","willRetry":true}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread_reconnect","turnId":"turn_reconnect","item":{"type":"agentMessage","id":"message_reconnect","text":"{\"name\":\"Recovered Pet\"}"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_reconnect","turn":{"id":"turn_reconnect","status":"completed"}}}'
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
        description: "Transient reconnect pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };
    let mut updates = Vec::new();

    let result = petcore::app_server::run_pet_studio_session_with_updates(
        &paths,
        "job_transient_reconnect",
        &form,
        |update| updates.push(update),
    );

    assert_eq!(result["completed"], true, "{result}");
    assert_eq!(result["ai_brief"]["name"], "Recovered Pet", "{result}");
    assert_eq!(result["error"], serde_json::Value::Null, "{result}");
    assert!(
        updates
            .iter()
            .any(|update| update.content.contains("自动重连")),
        "{updates:?}"
    );
    assert!(
        updates
            .iter()
            .filter(|update| {
                !matches!(
                    update.kind,
                    PetStudioSessionUpdateKind::SessionStarted
                        | PetStudioSessionUpdateKind::TurnStarted
                )
            })
            .all(|update| !update.content.contains("thread_reconnect")
                && !update.content.contains("turn_reconnect")),
        "user-visible Studio progress leaked an internal thread/turn id: {updates:?}"
    );
}

#[test]
fn generation_waits_past_intermediate_agent_message_for_turn_completion() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("intermediate-agent-message.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"intermediate-message-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_intermediate","sessionId":"thread_intermediate"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_intermediate","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread_intermediate","turnId":"turn_intermediate","item":{"type":"agentMessage","id":"message_progress","text":"{\"name\":\"Too Early\"}"}}}'
      sleep 1
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread_intermediate","turnId":"turn_intermediate","item":{"type":"agentMessage","id":"message_final","text":"{\"name\":\"Finished Pet\"}"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_intermediate","turn":{"id":"turn_intermediate","status":"completed"}}}'
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
        description: "Intermediate Agent message pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let started = Instant::now();
    let result = run_pet_studio_session(&paths, "job_intermediate_message", &form);

    assert!(started.elapsed() >= Duration::from_millis(900), "{result}");
    assert_eq!(result["completed"], true, "{result}");
    assert_eq!(result["ai_brief"]["name"], "Finished Pet", "{result}");
    assert_eq!(result["error"], serde_json::Value::Null, "{result}");
}

#[test]
fn generation_does_not_start_helper_turn_after_permanent_error() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("permanent-turn-error.sh");
    let count_file = temp.path().join("turn-count");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"permanent-error-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_permanent","sessionId":"thread_permanent"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      count=0
      [ ! -f "$APC_TEST_TURN_COUNT_FILE" ] || count=$(cat "$APC_TEST_TURN_COUNT_FILE")
      count=$((count + 1))
      printf '%s' "$count" > "$APC_TEST_TURN_COUNT_FILE"
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_permanent","status":"inProgress"}}}'
      printf '%s\n' '{"method":"turn/error","params":{"error":{"message":"Permanent failure"},"threadId":"thread_permanent","turnId":"turn_permanent","willRetry":false}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _strict = EnvGuard::set("APC_REQUIRE_EXTERNAL_SKILL_SOURCE", "1");
    let _count = EnvGuard::set("APC_TEST_TURN_COUNT_FILE", count_file.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let form = GenerationForm {
        description: "Permanent failure pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let result = run_pet_studio_session(&paths, "job_permanent_error", &form);

    assert_eq!(result["completed"], false, "{result}");
    assert!(result["error"]
        .as_str()
        .unwrap()
        .contains("Permanent failure"));
    assert_eq!(std::fs::read_to_string(count_file).unwrap(), "1");
    assert_eq!(result["helper_turn_started"], false, "{result}");
}

#[test]
fn external_generation_continues_past_six_hours_and_checkpoints_while_workspace_progresses() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("checkpoint-resume.sh");
    let turn_count_file = temp.path().join("turn-count");
    let interrupt_count_file = temp.path().join("interrupt-count");
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let job_id = "job_checkpoint_resume";
    let job_dir = paths.jobs_dir.join(job_id);

    std::fs::write(
        &script,
        r#"#!/bin/sh
turn_count=0
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"checkpoint-resume-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_checkpoint","sessionId":"thread_checkpoint"}}}'
      ;;
    *\"method\":\"turn/interrupt\"*)
      interrupt_count=0
      [ ! -f "$APC_TEST_INTERRUPT_COUNT_FILE" ] || interrupt_count=$(cat "$APC_TEST_INTERRUPT_COUNT_FILE")
      interrupt_count=$((interrupt_count + 1))
      printf '%s' "$interrupt_count" > "$APC_TEST_INTERRUPT_COUNT_FILE"
      printf '%s\n' '{"jsonrpc":"2.0","id":102,"result":{}}'
      ;;
    *\"method\":\"turn/start\"*)
      turn_count=$((turn_count + 1))
      printf '%s' "$turn_count" > "$APC_TEST_TURN_COUNT_FILE"
      request_id="${request#*\"id\":}"
      request_id="${request_id%%,*}"
      if [ "$turn_count" = 1 ]; then
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_checkpoint_0","status":"inProgress"}}}'
        continue
      fi

      if [ "$turn_count" -lt 8 ]; then
        mkdir -p "$APC_TEST_JOB_DIR/checkpoint-progress"
        printf '%s' "$turn_count" > "$APC_TEST_JOB_DIR/checkpoint-progress/segment-$turn_count"
        printf '%s\n' '{"jsonrpc":"2.0","id":'"$request_id"',"result":{"turn":{"id":"turn_checkpoint_'"$turn_count"'","status":"inProgress"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread_checkpoint","turnId":"turn_checkpoint_'"$turn_count"'","item":{"type":"agentMessage","id":"message_checkpoint_'"$turn_count"'","text":"work remains"}}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_checkpoint","turn":{"id":"turn_checkpoint_'"$turn_count"'","status":"completed"}}}'
        continue
      fi

      source_dir="$APC_TEST_JOB_DIR/petpack-source"
      mkdir -p "$source_dir/build" "$source_dir/assets/frames" \
        "$APC_TEST_JOB_DIR/motion-qa"
      printf '%s\n' '{"schema_version":"apc.petpack.v3","id":"pet_checkpoint","name":"Checkpoint Pet","style":"storybook","quality":"standard","render_size":{"width":384,"height":416},"states":[{"name":"idle","frames_dir":"assets/frames/idle","frame_durations_ms":[300,260,300,640],"playback":{"mode":"periodic","cooldown_ms":[2500,5000]},"reduced_motion_frame_index":2},{"name":"thinking","frames_dir":"assets/frames/thinking","frame_durations_ms":[120,140,160,180],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"tool","frames_dir":"assets/frames/tool","frame_durations_ms":[150,150,170,330],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"waiting","frames_dir":"assets/frames/waiting","frame_durations_ms":[150,150,150,150,170,230],"playback":{"mode":"burst_then_settle","entry_repeat_count":2,"settle_frame_index":5},"reduced_motion_frame_index":4},{"name":"done","frames_dir":"assets/frames/done","frame_durations_ms":[120,140,160,230],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"failed","frames_dir":"assets/frames/failed","frame_durations_ms":[150,170,190,290],"playback":{"mode":"burst_then_settle","entry_repeat_count":3,"settle_frame_index":3},"reduced_motion_frame_index":2},{"name":"acknowledge","frames_dir":"assets/frames/acknowledge","frame_durations_ms":[180,140,180,300],"playback":{"mode":"once_then_return"},"reduced_motion_frame_index":1},{"name":"drag_left","frames_dir":"assets/frames/drag_left","frame_durations_ms":[100,90,100,110,100,200],"playback":{"mode":"loop"},"reduced_motion_frame_index":2},{"name":"drag_right","frames_dir":"assets/frames/drag_right","frame_durations_ms":[100,90,100,110,100,200],"playback":{"mode":"loop"},"reduced_motion_frame_index":2}],"created_at":"2026-07-31T00:00:00Z"}' > "$source_dir/manifest.json"
      for state_count in idle:4 thinking:4 tool:4 waiting:6 done:4 failed:4 acknowledge:4 drag_left:6 drag_right:6; do
        state=${state_count%%:*}
        count=${state_count##*:}
        state_dir="$source_dir/assets/frames/$state"
        mkdir -p "$state_dir"
        index=1
        while [ "$index" -le "$count" ]; do
          touch "$state_dir/$(printf '%03d' "$index").png"
          index=$((index + 1))
        done
      done
      printf '%s\n' '{"ok":true}' > "$source_dir/build/validation.json"
      printf '%s\n' '{"ok":true}' > "$APC_TEST_JOB_DIR/motion-qa/report.json"
      printf '%s\n' '{"status":"approved"}' > "$APC_TEST_JOB_DIR/motion-review.json"

      printf '%s\n' '{"jsonrpc":"2.0","id":'"$request_id"',"result":{"turn":{"id":"turn_checkpoint_8","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread_checkpoint","turnId":"turn_checkpoint_8","item":{"type":"agentMessage","id":"message_checkpoint","text":"{\"petpack_source\":\"petpack-source\",\"mode\":\"external_full_source\",\"timing_changed\":false,\"authored_timing\":[]}"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread_checkpoint","turn":{"id":"turn_checkpoint_8","status":"completed"}}}'
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let _strict = EnvGuard::set("APC_REQUIRE_EXTERNAL_SKILL_SOURCE", "1");
    let _timeout = EnvGuard::set("APC_TEST_PET_STUDIO_TURN_TIMEOUT_MS", "200");
    let _elapsed = EnvGuard::set(
        "APC_TEST_EXTERNAL_CHECKPOINT_ELAPSED_MS",
        (6 * 60 * 60 * 1_000 + 1).to_string(),
    );
    let _job = EnvGuard::set("APC_TEST_JOB_DIR", job_dir.as_os_str());
    let _turn_count = EnvGuard::set("APC_TEST_TURN_COUNT_FILE", turn_count_file.as_os_str());
    let _interrupt_count = EnvGuard::set(
        "APC_TEST_INTERRUPT_COUNT_FILE",
        interrupt_count_file.as_os_str(),
    );
    let form = GenerationForm {
        description: "Checkpoint resume pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };
    let mut updates = Vec::new();

    let result =
        petcore::app_server::run_pet_studio_session_with_updates(&paths, job_id, &form, |update| {
            updates.push(update.content)
        });

    assert_eq!(result["completed"], true, "{result}");
    assert_eq!(result["error"], serde_json::Value::Null, "{result}");
    assert_eq!(result["checkpoint_turns_started"], 7, "{result}");
    assert_eq!(
        result["checkpoint_turn_ids"],
        json!([
            "turn_checkpoint_2",
            "turn_checkpoint_3",
            "turn_checkpoint_4",
            "turn_checkpoint_5",
            "turn_checkpoint_6",
            "turn_checkpoint_7",
            "turn_checkpoint_8"
        ]),
        "{result}"
    );
    assert_eq!(result["helper_turn_started"], false, "{result}");
    assert_eq!(std::fs::read_to_string(turn_count_file).unwrap(), "8");
    assert_eq!(std::fs::read_to_string(interrupt_count_file).unwrap(), "1");
    assert!(
        updates.iter().any(|message| message.contains("保存进度")),
        "{updates:?}"
    );
    assert!(
        updates
            .iter()
            .any(|message| message.contains("只处理尚未通过")),
        "{updates:?}"
    );
}
