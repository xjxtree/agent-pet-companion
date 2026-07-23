use petcore::paths::AppPaths;
use petcore::rpc::{handle_json_line, handle_request, CoreState, RpcRequest};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Barrier};
use time::{format_description::well_known::Rfc3339, Duration, OffsetDateTime};

fn ready() -> (tempfile::TempDir, CoreState) {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    state.ensure_ready().unwrap();
    (temp, state)
}

fn request(method: &str, params: Value) -> RpcRequest {
    RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: method.to_string(),
        params,
    }
}

fn snapshot(state: &CoreState) -> Value {
    handle_request(state, request("state.snapshot", json!({}))).unwrap()
}

fn timestamp(seconds_ago: i64) -> String {
    (OffsetDateTime::now_utc() - Duration::seconds(seconds_ago))
        .format(&Rfc3339)
        .unwrap()
}

fn projected_event_id(value: &str) -> String {
    projected_identity("event", "evt", value)
}

fn projected_session_id(value: &str) -> String {
    projected_identity("session", "ses", value)
}

fn projected_identity(domain: &str, prefix: &str, value: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"agent-pet-companion/overlay-identity/v1\0");
    digest.update(domain.as_bytes());
    digest.update([0]);
    digest.update(value.as_bytes());
    format!("{prefix}-{}", hex::encode(digest.finalize()))
}

fn ingest(state: &CoreState, id: &str, session_id: &str, event_type: &str, created_at: &str) {
    handle_request(
        state,
        request(
            "agent.ingest",
            json!({
                "id": id,
                "source": "codex",
                "session_id": session_id,
                "event_type": event_type,
                "title": id,
                "created_at": created_at,
            }),
        ),
    )
    .unwrap();
}

fn ingest_payload(
    state: &CoreState,
    id: &str,
    session_id: &str,
    event_type: &str,
    created_at: &str,
    payload_json: Value,
) -> Value {
    handle_request(
        state,
        request(
            "agent.ingest",
            json!({
                "id": id,
                "source": "codex",
                "session_id": session_id,
                "event_type": event_type,
                "title": id,
                "payload_json": payload_json,
                "created_at": created_at,
            }),
        ),
    )
    .unwrap()
}

fn ingest_source_payload(
    state: &CoreState,
    source: &str,
    id: &str,
    session_id: &str,
    event_type: &str,
    created_at: &str,
    payload_json: Value,
) -> Value {
    handle_request(
        state,
        request(
            "agent.ingest",
            json!({
                "id": id,
                "source": source,
                "session_id": session_id,
                "event_type": event_type,
                "title": id,
                "payload_json": payload_json,
                "created_at": created_at,
            }),
        ),
    )
    .unwrap()
}

fn patch(state: &CoreState, expected_revision: &str, changes: Value) -> petcore::Result<Value> {
    handle_request(
        state,
        request(
            "behavior.patch",
            json!({
                "expected_revision": expected_revision,
                "changes": changes,
            }),
        ),
    )
}

#[test]
fn blocked_attention_state_keeps_priority_over_newer_running_work() {
    let (_temp, state) = ready();
    ingest(
        &state,
        "failed-expired",
        "session-failed",
        "failed",
        &timestamp(6),
    );
    ingest(
        &state,
        "tool-current",
        "session-tool",
        "tool",
        &timestamp(1),
    );

    let current_snapshot = snapshot(&state);
    assert_eq!(
        current_snapshot["active_agent_state"]["event"]["id"],
        projected_event_id("failed-expired")
    );
    assert_eq!(current_snapshot["active_agent_state"]["state"], "failed");
    assert_eq!(
        current_snapshot["active_agent_state"]["lease_seconds"],
        Value::Null
    );
    assert_eq!(
        current_snapshot["active_agent_state"]["expires_at"],
        Value::Null
    );
}

#[test]
fn stale_event_does_not_override_current_state() {
    let (_temp, state) = ready();
    let current_time = timestamp(1);
    let stale_time = timestamp(10);
    ingest(
        &state,
        "tool-current",
        "same-session",
        "tool",
        &current_time,
    );
    // Arrives later, but its event timestamp is older and must not rewind the
    // source/session even though waiting has a higher global priority.
    ingest(
        &state,
        "waiting-stale",
        "same-session",
        "waiting",
        &stale_time,
    );

    let current_snapshot = snapshot(&state);
    assert_eq!(
        current_snapshot["active_agent_state"]["event"]["id"],
        projected_event_id("tool-current")
    );

    // Equal timestamps use the persisted source/session sequence, so a later
    // terminal event closes the session instead of restoring prior work.
    ingest(
        &state,
        "done-later-sequence",
        "same-session",
        "done",
        &current_time,
    );
    let snapshot = snapshot(&state);
    assert_eq!(
        snapshot["active_agent_state"]["event"]["id"],
        projected_event_id("done-later-sequence")
    );
}

#[test]
fn older_review_remains_in_the_bubble_without_overriding_newer_cross_session_states() {
    for (event_type, expected_status, expected_summary) in [
        ("tool", "running", "tool"),
        ("failed", "blocked", "failed"),
        ("waiting", "needs_input", "needs_input"),
    ] {
        let (_temp, state) = ready();
        ingest(
            &state,
            "ready-to-review",
            "completed-session",
            "review",
            &timestamp(2),
        );
        let newer_id = format!("new-{event_type}-work");
        ingest(
            &state,
            &newer_id,
            "active-session",
            event_type,
            &timestamp(1),
        );

        let current = snapshot(&state);
        assert_eq!(current["active_agent_state"]["state"], event_type);
        assert_eq!(
            current["active_agent_state"]["event"]["id"],
            projected_event_id(&newer_id)
        );
        assert_eq!(
            current["active_agent_state"]["official_status"],
            expected_status
        );
        assert_eq!(
            current["active_agent_state"]["overlay_display"]["summary_kind"],
            expected_summary
        );
        assert!(current["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|session| session["overlay_display"]["summary_kind"] == "review"));
    }
}

#[test]
fn codex_internal_suggestion_turns_are_removed_and_suppressed_as_a_session() {
    let (_temp, state) = ready();
    let normal_time = timestamp(3);
    ingest(
        &state,
        "normal-tool",
        "normal-session",
        "tool",
        &normal_time,
    );

    let internal_session = "019f6ed7-de50-7623-8462-6a857e367a96";
    let started = ingest_payload(
        &state,
        "internal-session-start",
        internal_session,
        "start",
        &timestamp(2),
        json!({
            "source_event": "SessionStart",
            "session_active": false,
            "session_open": null,
            "session_surface": "chatgpt_app",
            "diagnostic": false
        }),
    );
    assert_eq!(started["inserted"], true);

    let prompt = ingest_payload(
        &state,
        "internal-user-prompt",
        internal_session,
        "start",
        &timestamp(1),
        json!({
            "source_event": "UserPromptSubmit",
            "session_active": true,
            "message_role": "user",
            "message_content": "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project\n\n# Rules",
            "session_open": null,
            "session_surface": "chatgpt_app",
            "diagnostic": false
        }),
    );
    assert_eq!(prompt["inserted"], false);
    assert_eq!(prompt["suppressed"], true);
    assert_eq!(prompt["triggered"], false);
    assert_eq!(prompt["event"], Value::Null);

    let later_tool = ingest_payload(
        &state,
        "internal-tool",
        internal_session,
        "tool",
        &timestamp(0),
        json!({
            "source_event": "PreToolUse",
            "session_active": true,
            "activity_kind": "command",
            "session_open": null,
            "session_surface": "chatgpt_app",
            "diagnostic": false
        }),
    );
    assert_eq!(later_tool["suppressed"], true);
    assert_eq!(later_tool["triggered"], false);

    let current_snapshot = snapshot(&state);
    assert_eq!(
        current_snapshot["active_agent_state"]["event"]["id"],
        projected_event_id("normal-tool")
    );
    assert!(current_snapshot["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .all(|session| session["session_id"] != projected_session_id(internal_session)));
    assert!(current_snapshot["recent_events"]
        .as_array()
        .unwrap()
        .iter()
        .all(|event| event["session_id"] != projected_session_id(internal_session)));
}

#[test]
fn concurrent_behavior_patches_do_not_lose_fields() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    let revision = initial["behavior_revision"].as_str().unwrap().to_string();
    let barrier = Arc::new(Barrier::new(3));

    let left_state = state.clone();
    let left_revision = revision.clone();
    let left_barrier = barrier.clone();
    let left = std::thread::spawn(move || {
        left_barrier.wait();
        patch(&left_state, &left_revision, json!({ "enabled": false }))
    });
    let right_state = state.clone();
    let right_revision = revision;
    let right_barrier = barrier.clone();
    let right = std::thread::spawn(move || {
        right_barrier.wait();
        patch(&right_state, &right_revision, json!({ "auto_hide": true }))
    });
    barrier.wait();

    let left = left.join().unwrap();
    let right = right.join().unwrap();
    assert_ne!(
        left.is_ok(),
        right.is_ok(),
        "one same-revision CAS must win"
    );

    let after_first = snapshot(&state);
    let retry_revision = after_first["behavior_revision"].as_str().unwrap();
    if after_first["behavior"]["enabled"] == true {
        patch(&state, retry_revision, json!({ "enabled": false })).unwrap();
    } else {
        patch(&state, retry_revision, json!({ "auto_hide": true })).unwrap();
    }

    let final_snapshot = snapshot(&state);
    assert_eq!(final_snapshot["behavior"]["enabled"], false);
    assert_eq!(final_snapshot["behavior"]["auto_hide"], true);
    assert_eq!(final_snapshot["behavior"]["status_bubble"], true);
    assert_eq!(final_snapshot["behavior"]["fps_profile"], "standard");
}

#[test]
fn stale_revision_returns_conflict() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    let stale_revision = initial["behavior_revision"].as_str().unwrap().to_string();
    let behavior_get = handle_request(&state, request("behavior.get", json!({}))).unwrap();
    assert_eq!(behavior_get["revision"], stale_revision);
    assert_eq!(behavior_get["behavior"], initial["behavior"]);

    // An unrelated global state write must not cause a false behavior CAS
    // conflict.
    ingest(
        &state,
        "unrelated-agent-event",
        "unrelated-session",
        "tool",
        &timestamp(0),
    );
    patch(&state, &stale_revision, json!({ "click_menu": false })).unwrap();

    let encoded = serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": "conflict",
        "method": "behavior.patch",
        "params": {
            "expected_revision": stale_revision,
            "changes": { "mouse_passthrough": false }
        }
    }))
    .unwrap();
    let response: Value =
        serde_json::from_str(&handle_json_line(&state, &encoded).unwrap()).unwrap();

    assert_eq!(response["error"]["code"], -32009);
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("behavior revision conflict"));
    assert_eq!(snapshot(&state)["behavior"]["mouse_passthrough"], true);
}

#[test]
fn generic_settings_rpc_cannot_bypass_behavior_cas() {
    let (_temp, state) = ready();
    let error = handle_request(
        &state,
        request(
            "settings.update",
            json!({
                "key": "behavior",
                "value": { "enabled": false }
            }),
        ),
    )
    .unwrap_err();

    assert!(error
        .to_string()
        .contains("product settings use typed methods"));
    assert_eq!(snapshot(&state)["behavior"]["enabled"], true);
}

#[test]
fn idle_auto_hide_semantics_are_consistent() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    assert_eq!(initial["active_agent_state"], Value::Null);
    assert_eq!(initial["overlay_visibility"]["pet_visible"], true);
    assert_eq!(
        initial["overlay_visibility"]["status_bubble_visible"], true,
        "auto_hide=false keeps the configured idle status bubble visible"
    );

    let patched = patch(
        &state,
        initial["behavior_revision"].as_str().unwrap(),
        json!({ "auto_hide": true }),
    )
    .unwrap();
    let idle = snapshot(&state);
    assert_eq!(patched["behavior"]["auto_hide"], true);
    assert_eq!(idle["overlay_visibility"]["pet_visible"], true);
    assert_eq!(idle["overlay_visibility"]["status_bubble_visible"], false);

    ingest(
        &state,
        "active-tool",
        "visibility-session",
        "tool",
        &timestamp(0),
    );
    let active = snapshot(&state);
    assert_eq!(active["overlay_visibility"]["pet_visible"], true);
    assert_eq!(active["overlay_visibility"]["status_bubble_visible"], true);

    patch(
        &state,
        active["behavior_revision"].as_str().unwrap(),
        json!({ "enabled": false }),
    )
    .unwrap();
    let disabled = snapshot(&state);
    assert_eq!(disabled["active_agent_state"], Value::Null);
    assert_eq!(disabled["overlay_visibility"]["pet_visible"], false);
    assert_eq!(
        disabled["overlay_visibility"]["status_bubble_visible"],
        false
    );
}

#[test]
fn active_session_persists_with_bounded_user_context_for_the_overlay() {
    let (_temp, state) = ready();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "prompt-message",
                "source": "codex",
                "session_id": "persistent-session",
                "event_type": "start",
                "created_at": timestamp(7_200),
                "payload": {
                    "source_event": "UserPromptSubmit",
                    "session_active": true,
                    "message_role": "user",
                    "message_content": "保持当前会话信息",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "later-tool",
                "source": "codex",
                "session_id": "persistent-session",
                "event_type": "tool",
                "created_at": timestamp(3_600),
                "payload": {
                    "source_event": "PreToolUse",
                    "session_active": true,
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();

    let active = snapshot(&state);
    assert_eq!(
        active["active_agent_state"]["event"]["id"],
        projected_event_id("later-tool")
    );
    assert_eq!(active["active_agent_state"]["official_status"], "running");
    assert_eq!(active["active_agent_state"]["session_active"], true);
    assert_eq!(active["active_agent_state"]["lease_seconds"], Value::Null);
    assert_eq!(active["active_agent_state"]["expires_at"], Value::Null);
    assert_eq!(
        active["active_agent_state"]["overlay_display"]["summary_kind"],
        "tool"
    );
    assert_eq!(
        active["active_agent_state"]["session_title"],
        "保持当前会话信息"
    );
    assert_eq!(
        active["active_agent_state"]["session_user_message"],
        json!({"role": "user", "content": "保持当前会话信息"})
    );
    assert_eq!(active["active_agent_state"]["session_message"], Value::Null);
    assert!(active["active_agent_state"]
        .get("latest_user_message")
        .is_none());
    assert_eq!(active["active_agent_sessions"], json!([]));
    assert_eq!(active["overlay_visibility"]["status_bubble_visible"], false);

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "terminal-done",
                "source": "codex",
                "session_id": "persistent-session",
                "event_type": "done",
                "created_at": timestamp(6),
                "payload": {
                    "source_event": "Stop",
                    "session_active": false,
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();
    assert_eq!(snapshot(&state)["active_agent_state"], Value::Null);
}

#[test]
fn display_sessions_group_multiple_sessions_and_reactivate_after_timeout() {
    let (_temp, state) = ready();
    for (id, session_id, seconds_ago) in [
        ("codex-recent", "codex-session", 60),
        ("codex-stale", "stale-session", 16 * 60),
    ] {
        handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": id,
                    "source": "codex",
                    "session_id": session_id,
                    "event_type": "start",
                    "created_at": timestamp(seconds_ago),
                    "payload": {
                        "source_event": "UserPromptSubmit",
                        "session_active": true,
                        "message_role": "user",
                        "message_content": id,
                        "diagnostic": false
                    }
                }),
            ),
        )
        .unwrap();
    }
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "claude-recent",
                "source": "claude_code",
                "session_id": "claude-session",
                "event_type": "start",
                "created_at": timestamp(30),
                "payload": {
                    "source_event": "UserPromptSubmit",
                    "session_active": true,
                    "message_role": "user",
                    "message_content": "claude prompt",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();

    let before = snapshot(&state);
    let sessions = before["active_agent_sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 2);
    assert!(sessions.iter().any(|session| session["source"] == "codex"));
    assert!(sessions
        .iter()
        .any(|session| session["source"] == "claude_code"));
    assert!(!sessions
        .iter()
        .any(|session| session["session_id"] == projected_session_id("stale-session")));

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "codex-reactivated",
                "source": "codex",
                "session_id": "stale-session",
                "event_type": "start",
                "created_at": timestamp(0),
                "payload": {
                    "source_event": "UserPromptSubmit",
                    "session_active": true,
                    "message_role": "user",
                    "message_content": "reactivated",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();

    let after = snapshot(&state);
    assert!(after["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .any(|session| session["session_id"] == projected_session_id("stale-session")));
}

#[test]
fn display_session_order_changes_on_activation_but_not_tool_churn() {
    let (_temp, state) = ready();
    for (id, session_id, seconds_ago) in [
        ("start-older", "session-older", 30),
        ("start-newer", "session-newer", 20),
    ] {
        ingest_payload(
            &state,
            id,
            session_id,
            "start",
            &timestamp(seconds_ago),
            json!({
                "source_event": "UserPromptSubmit",
                "session_active": true,
                "message_role": "user",
                "message_content": id,
                "diagnostic": false
            }),
        );
    }

    let session_order = |value: &Value| {
        value["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|session| session["session_id"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("session-newer"),
            projected_session_id("session-older")
        ]
    );

    ingest_payload(
        &state,
        "older-tool-is-latest-event",
        "session-older",
        "tool",
        &timestamp(10),
        json!({
            "source_event": "PreToolUse",
            "session_active": true,
            "activity_kind": "tool",
            "diagnostic": false
        }),
    );
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("session-newer"),
            projected_session_id("session-older")
        ],
        "a tool event must not make rows trade places"
    );

    ingest_payload(
        &state,
        "older-new-turn",
        "session-older",
        "start",
        &timestamp(1),
        json!({
            "source_event": "UserPromptSubmit",
            "session_active": true,
            "message_role": "user",
            "message_content": "new turn",
            "diagnostic": false
        }),
    );
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("session-older"),
            projected_session_id("session-newer")
        ],
        "a new user activation may deliberately promote the session"
    );
}

#[test]
fn cross_agent_non_user_start_churn_does_not_reorder_display_sessions() {
    let (_temp, state) = ready();
    for (source, id, session_id, source_event, seconds_ago) in [
        (
            "claude_code",
            "claude-user",
            "claude-session",
            "UserPromptSubmit",
            30,
        ),
        ("pi", "pi-user", "pi-session", "input", 20),
        (
            "opencode",
            "opencode-user",
            "opencode-session",
            "message.user",
            10,
        ),
    ] {
        ingest_source_payload(
            &state,
            source,
            id,
            session_id,
            "start",
            &timestamp(seconds_ago),
            json!({
                "source_event": source_event,
                "session_active": true,
                "message_role": "user",
                "message_content": id,
                "affects_activity": true,
                "diagnostic": false
            }),
        );
    }

    let session_order = |value: &Value| {
        value["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|session| session["session_id"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("opencode-session"),
            projected_session_id("pi-session"),
            projected_session_id("claude-session")
        ]
    );

    for (source, id, session_id, source_event, seconds_ago) in [
        (
            "claude_code",
            "claude-post-compact",
            "claude-session",
            "PostCompact",
            3,
        ),
        ("pi", "pi-turn-end", "pi-session", "turn_end", 2),
        (
            "opencode",
            "opencode-assistant",
            "opencode-session",
            "message.assistant",
            1,
        ),
    ] {
        ingest_source_payload(
            &state,
            source,
            id,
            session_id,
            "start",
            &timestamp(seconds_ago),
            json!({
                "source_event": source_event,
                "session_active": true,
                "message_role": "assistant",
                "message_content": id,
                "affects_activity": true,
                "diagnostic": false
            }),
        );
    }
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("opencode-session"),
            projected_session_id("pi-session"),
            projected_session_id("claude-session")
        ],
        "assistant, compact, and completion start-shaped events must not reshuffle rows"
    );

    ingest_source_payload(
        &state,
        "claude_code",
        "claude-next-user",
        "claude-session",
        "start",
        &timestamp(0),
        json!({
            "source_event": "UserPromptSubmit",
            "session_active": true,
            "message_role": "user",
            "message_content": "next turn",
            "affects_activity": true,
            "diagnostic": false
        }),
    );
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("claude-session"),
            projected_session_id("opencode-session"),
            projected_session_id("pi-session")
        ],
        "a genuine next user activation may deliberately promote the session"
    );
}

#[test]
fn sessions_without_a_user_activation_keep_their_first_seen_order() {
    let (_temp, state) = ready();
    for (id, session_id, seconds_ago) in [
        ("first-seen-older", "session-older", 30),
        ("first-seen-newer", "session-newer", 20),
    ] {
        ingest_source_payload(
            &state,
            "opencode",
            id,
            session_id,
            "start",
            &timestamp(seconds_ago),
            json!({
                "source_event": "session.plan.updated",
                "session_active": true,
                "affects_activity": true,
                "diagnostic": false
            }),
        );
    }

    let session_order = |value: &Value| {
        value["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|session| session["session_id"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("session-newer"),
            projected_session_id("session-older")
        ]
    );

    ingest_source_payload(
        &state,
        "opencode",
        "older-plan-churn",
        "session-older",
        "start",
        &timestamp(0),
        json!({
            "source_event": "session.plan.updated",
            "session_active": true,
            "affects_activity": true,
            "diagnostic": false
        }),
    );
    assert_eq!(
        session_order(&snapshot(&state)),
        vec![
            projected_session_id("session-newer"),
            projected_session_id("session-older")
        ],
        "a session first discovered without a user message must not reorder on later metadata churn"
    );
}

#[test]
fn waiting_and_failed_sessions_ignore_the_ordinary_display_timeout() {
    let (_temp, state) = ready();
    for (id, event_type, session_active) in [
        ("waiting-old", "waiting", true),
        ("failed-old", "failed", false),
    ] {
        handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": id,
                    "source": "codex",
                    "session_id": id,
                    "event_type": event_type,
                    "created_at": timestamp(86_400),
                    "payload": {
                        "source_event": "PermissionRequest",
                        "session_active": session_active,
                        "diagnostic": false
                    }
                }),
            ),
        )
        .unwrap();
    }
    let current = snapshot(&state);
    let sessions = current["active_agent_sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 2);
    assert_eq!(
        sessions[0]["overlay_display"]["summary_kind"],
        "needs_input"
    );
    assert_eq!(sessions[1]["overlay_display"]["summary_kind"], "failed");
    assert!(sessions
        .iter()
        .all(|session| { session["lease_seconds"].is_null() && session["expires_at"].is_null() }));
    assert_eq!(current["active_agent_state"]["state"], "waiting");
    assert_eq!(current["active_agent_state"]["lease_seconds"], Value::Null);
    assert_eq!(current["active_agent_state"]["expires_at"], Value::Null);
    assert_eq!(current["behavior"]["session_message_timeout_minutes"], 15);
    assert_eq!(current["behavior"]["bubble_transparency"], 0.55);
    assert_eq!(current["behavior"]["appearance_theme"], "system");
}

#[test]
fn review_session_remains_visible_until_a_newer_event_replaces_it() {
    let (_temp, state) = ready();
    ingest_payload(
        &state,
        "review-old",
        "review-attention",
        "review",
        &timestamp(86_400),
        json!({
            "source_event": "PostToolUse",
            "session_active": false,
            "message_role": "assistant",
            "message_content": "private review result",
            "diagnostic": false
        }),
    );

    let retained = snapshot(&state);
    let session = retained["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["overlay_display"]["summary_kind"] == "review")
        .expect("review attention state should not expire on the ordinary timeout");
    assert_eq!(session["overlay_display"]["summary_kind"], "review");
    assert_eq!(retained["active_agent_state"]["state"], "review");
    assert_eq!(
        retained["active_agent_state"]["overlay_display"]["summary_kind"],
        "review"
    );
    assert_eq!(retained["active_agent_state"]["lease_seconds"], Value::Null);
    assert_eq!(retained["active_agent_state"]["expires_at"], Value::Null);
    assert_eq!(session["lease_seconds"], Value::Null);
    assert_eq!(session["expires_at"], Value::Null);

    ingest(
        &state,
        "review-advanced",
        "review-attention",
        "tool",
        &timestamp(0),
    );
    let advanced = snapshot(&state);
    let session = advanced["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["overlay_display"]["summary_kind"] == "tool")
        .unwrap();
    assert_eq!(session["overlay_display"]["summary_kind"], "tool");
    assert_eq!(advanced["active_agent_state"]["state"], "tool");
}

#[test]
fn display_projection_reports_sessions_omitted_by_the_eight_session_bound() {
    let (_temp, state) = ready();
    for index in 0..10 {
        ingest(
            &state,
            &format!("many-{index}"),
            &format!("many-session-{index}"),
            "tool",
            &timestamp(index),
        );
    }

    let current = snapshot(&state);
    let sessions = current["active_agent_sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 8);
    assert_eq!(current["active_agent_sessions_omitted_count"], 2);
    assert_eq!(
        sessions
            .iter()
            .filter_map(|session| session["session_id"].as_str())
            .collect::<std::collections::BTreeSet<_>>()
            .len(),
        8
    );
}

#[test]
fn same_agent_projects_share_one_session_projection_without_project_filtering() {
    let (_temp, state) = ready();
    let projects = [
        ("project-a-event", "project-a-session", "/tmp/project-a"),
        ("project-b-event", "project-b-session", "/tmp/project-b"),
    ];

    for (index, (id, session_id, project_path)) in projects.iter().enumerate() {
        handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": id,
                    "source": "codex",
                    "project_path": project_path,
                    "session_id": session_id,
                    "event_type": "tool",
                    "title": id,
                    "created_at": timestamp(index as i64 + 1),
                }),
            ),
        )
        .unwrap();
    }

    let current = snapshot(&state);
    let sessions = current["active_agent_sessions"].as_array().unwrap();
    for (_, session_id, _) in projects {
        assert!(sessions
            .iter()
            .any(|session| session["session_id"] == projected_session_id(session_id)));
    }

    let serialized = current.to_string();
    assert!(!serialized.contains("/tmp/project-a"));
    assert!(!serialized.contains("/tmp/project-b"));
}

#[test]
fn overlay_projection_allows_display_messages_but_excludes_private_event_fields() {
    let (_temp, state) = ready();
    let prompt = "Restore useful pet bubble context";
    let path = "/Users/alice/private/customer/launch-plan.md";
    let command = "COMMAND_DO_NOT_EXPORT /bin/sh -c 'curl -H Authorization:Bearer-secret'";
    let assistant = "The pet bubble now shows the latest result.";
    let hostile_event_id = "EVENT_ID_DO_NOT_EXPORT_/Users/alice/private_sk-live-id-secret";
    let hostile_session_id = "SESSION_ID_DO_NOT_EXPORT_/Users/alice/private/token.txt";
    let hostile_detail = "DETAIL_DO_NOT_EXPORT bearer-private-detail sk-live-super-secret";

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "privacy-user",
                "source": "codex",
                "project_path": path,
                "session_id": hostile_session_id,
                "event_type": "start",
                "created_at": timestamp(3),
                "payload": {
                    "source_event": "UserPromptSubmit",
                    "session_active": true,
                    "message_role": "user",
                    "message_content": prompt,
                    "project_label": path,
                    "session_title": prompt,
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": hostile_event_id,
                "source": "codex",
                "session_id": hostile_session_id,
                "event_type": "tool",
                "title": hostile_event_id,
                "detail": hostile_detail,
                "created_at": timestamp(2),
                "payload_json": {
                    "source_event": "PreToolUse",
                    "tool_name": "shell",
                    "session_active": true,
                    "activity_kind": "command",
                    "activity_content": command,
                    "session_open": true,
                    "session_surface": "cli_terminal",
                    "terminal_app": "warp",
                    "session_open_url": "warp://session/0123456789abcdef0123456789abcdef",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();
    ingest_payload(
        &state,
        "privacy-review-user",
        "privacy-review-session",
        "start",
        &timestamp(2),
        json!({
            "source_event": "UserPromptSubmit",
            "session_active": true,
            "message_role": "user",
            "message_content": "Review the completed bubble result",
            "diagnostic": false
        }),
    );
    ingest_payload(
        &state,
        "privacy-assistant",
        "privacy-review-session",
        "review",
        &timestamp(1),
        json!({
            "source_event": "PostToolUse",
            "session_active": false,
            "message_role": "assistant",
            "message_content": assistant,
            "diagnostic": false
        }),
    );

    let current = snapshot(&state);
    let serialized = serde_json::to_string(&current).unwrap();
    for forbidden in [
        path,
        command,
        hostile_event_id,
        hostile_session_id,
        hostile_detail,
        "sk-live-super-secret",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "overlay projection leaked forbidden content: {forbidden}"
        );
    }
    assert!(serialized.contains(prompt));
    assert!(serialized.contains(assistant));
    let sessions = current["active_agent_sessions"].as_array().unwrap();
    let tool = sessions
        .iter()
        .find(|session| session["overlay_display"]["summary_kind"] == "command")
        .unwrap();
    assert_eq!(tool["source"], "codex");
    assert!(tool["event"]["id"].as_str().unwrap().starts_with("evt-"));
    assert!(tool["session_id"].as_str().unwrap().starts_with("ses-"));
    assert_eq!(tool["overlay_display"]["summary_kind"], "command");
    assert_eq!(tool["session_title"], prompt);
    assert_eq!(
        tool["session_user_message"],
        json!({"role": "user", "content": prompt})
    );
    let review = sessions
        .iter()
        .find(|session| session["overlay_display"]["summary_kind"] == "review")
        .unwrap();
    assert_eq!(
        review["session_message"],
        json!({"role": "assistant", "content": assistant})
    );
    assert_eq!(
        tool["overlay_display"]["navigation"]["open_url"],
        "warp://session/0123456789abcdef0123456789abcdef"
    );
    assert_eq!(
        tool["overlay_display"]["navigation"]["routable_session_id"],
        Value::Null
    );
    assert!(tool["event"].get("payload_json").is_none());
    assert!(current["events"]
        .as_array()
        .unwrap()
        .iter()
        .all(|event| event.get("payload_json").is_none()));
    assert!(current["recent_events"]
        .as_array()
        .unwrap()
        .iter()
        .all(|event| event.get("payload_json").is_none()));
}

#[test]
fn overlay_projection_exposes_only_a_strict_codex_uuid_for_session_routing() {
    let (_temp, state) = ready();
    let codex_uuid = "019f5b0f-88ff-7413-8953-29de4ed0951c";
    for (source, id, session_id, seconds_ago) in [
        ("codex", "route-codex", codex_uuid, 2),
        (
            "codex",
            "route-invalid",
            "019f5b0f_88ff_7413_8953_29de4ed0951c",
            1,
        ),
        ("claude_code", "route-claude", codex_uuid, 0),
    ] {
        ingest_source_payload(
            &state,
            source,
            id,
            session_id,
            "tool",
            &timestamp(seconds_ago),
            json!({
                "source_event": "PreToolUse",
                "session_active": true,
                "session_open": true,
                "session_surface": "chatgpt_app",
                "diagnostic": false
            }),
        );
    }

    let current = snapshot(&state);
    let sessions = current["active_agent_sessions"].as_array().unwrap();
    let routable = sessions
        .iter()
        .filter_map(|session| {
            session["overlay_display"]["navigation"]["routable_session_id"].as_str()
        })
        .collect::<Vec<_>>();
    assert_eq!(routable, vec![codex_uuid]);
    assert!(sessions.iter().all(|session| {
        session["session_id"]
            .as_str()
            .is_some_and(|id| id.starts_with("ses-"))
    }));
}

#[test]
fn restart_restores_recent_and_stale_opencode_failures_until_the_session_advances() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let state = CoreState::new(paths.clone());
    state.ensure_ready().unwrap();

    for (session_id, seconds_ago) in [
        ("opencode-recent-failure", 30),
        ("opencode-stale-failure", 86_400),
    ] {
        ingest_source_payload(
            &state,
            "opencode",
            &format!("{session_id}-prompt"),
            session_id,
            "start",
            &timestamp(seconds_ago + 1),
            json!({
                "source_event": "message.user",
                "outcome": "message",
                "affects_activity": true,
                "session_active": true,
                "message_role": "user",
                "message_content": "trigger failure",
                "diagnostic": false
            }),
        );
        ingest_source_payload(
            &state,
            "opencode",
            &format!("{session_id}-failed"),
            session_id,
            "failed",
            &timestamp(seconds_ago),
            json!({
                "source_event": "session.error",
                "outcome": "session_failure",
                "affects_activity": true,
                "session_active": false,
                "diagnostic": false
            }),
        );
    }

    drop(state);
    let restarted = CoreState::new(paths);
    restarted.ensure_ready().unwrap();
    let restored = snapshot(&restarted);
    let sessions = restored["active_agent_sessions"].as_array().unwrap();

    assert_eq!(sessions.len(), 2);
    assert_eq!(
        sessions[0]["session_id"],
        projected_session_id("opencode-recent-failure")
    );
    assert_eq!(sessions[0]["official_status"], "blocked");
    assert_eq!(sessions[0]["event"]["event_type"], "failed");
    assert_eq!(sessions[0]["overlay_display"]["summary_kind"], "failed");
    assert_eq!(
        sessions[1]["session_id"],
        projected_session_id("opencode-stale-failure")
    );
    assert_eq!(sessions[1]["official_status"], "blocked");
    assert!(restored["recent_events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|event| { event["session_id"] == projected_session_id("opencode-stale-failure") }));
}

#[test]
fn inactive_waiting_session_persists_as_pending_work_until_the_session_advances() {
    let (_temp, state) = ready();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "closed-waiting",
                "source": "codex",
                "session_id": "closed-waiting",
                "event_type": "waiting",
                "created_at": timestamp(60),
                "payload": {
                    "source_event": "PermissionRequest",
                    "session_active": false,
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();
    let retained = snapshot(&state);
    assert_eq!(
        retained["active_agent_sessions"].as_array().unwrap().len(),
        1
    );
    assert_eq!(retained["active_agent_state"]["state"], "waiting");
    assert_eq!(
        retained["active_agent_sessions"][0]["overlay_display"]["summary_kind"],
        "needs_input"
    );

    ingest(
        &state,
        "waiting-advanced",
        "closed-waiting",
        "tool",
        &timestamp(0),
    );
    let advanced = snapshot(&state);
    assert_eq!(advanced["active_agent_state"]["state"], "tool");
    assert_eq!(
        advanced["active_agent_sessions"][0]["overlay_display"]["summary_kind"],
        "tool"
    );
}

#[test]
fn waiting_without_session_active_persists_beyond_the_activity_lease() {
    let (_temp, state) = ready();
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "waiting-missing-active",
                "source": "codex",
                "session_id": "waiting-missing-active",
                "event_type": "waiting",
                "created_at": timestamp(86_400),
                "payload": {
                    "source_event": "PermissionRequest",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();

    let retained = snapshot(&state);
    assert_eq!(retained["active_agent_state"]["state"], "waiting");
    assert_eq!(
        retained["active_agent_sessions"].as_array().unwrap().len(),
        1
    );
    assert_eq!(
        retained["active_agent_sessions"][0]["overlay_display"]["summary_kind"],
        "needs_input"
    );
}

#[test]
fn new_user_activation_hides_previous_turn_reply_until_agent_responds() {
    let (_temp, state) = ready();
    let ingest_message =
        |id: &str, event_type: &str, role: &str, content: &str, seconds_ago: i64| {
            handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": id,
                    "source": "claude_code",
                    "session_id": "turn-boundary",
                    "event_type": event_type,
                    "created_at": timestamp(seconds_ago),
                    "payload": {
                        "source_event": if role == "user" { "UserPromptSubmit" } else { "Stop" },
                        "session_active": true,
                        "message_role": role,
                        "message_content": content,
                        "diagnostic": false
                    }
                }),
            ),
        )
        .unwrap();
        };

    ingest_message("old-reply", "done", "assistant", "上一轮回复", 120);
    ingest_message("new-prompt", "start", "user", "新问题", 60);
    let thinking = snapshot(&state);
    let session = thinking["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id("turn-boundary"))
        .unwrap();
    assert_eq!(session["overlay_display"]["summary_kind"], "running");

    ingest_message("new-reply", "review", "assistant", "本轮回复", 0);
    let responded = snapshot(&state);
    let session = responded["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id("turn-boundary"))
        .unwrap();
    assert_eq!(session["event"]["id"], projected_event_id("new-reply"));
    assert_eq!(session["overlay_display"]["summary_kind"], "review");
}

#[test]
fn equal_timestamp_messages_follow_persisted_arrival_order() {
    let (_temp, state) = ready();
    let at = timestamp(0);
    let ingest_message =
        |id: &str, session_id: &str, event_type: &str, role: &str, content: &str| {
            handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": id,
                    "source": "claude_code",
                    "session_id": session_id,
                    "event_type": event_type,
                    "created_at": at.clone(),
                    "payload": {
                        "source_event": if role == "user" { "UserPromptSubmit" } else { "Stop" },
                        "session_active": true,
                        "message_role": role,
                        "message_content": content,
                        "diagnostic": false
                    }
                }),
            ),
        )
        .unwrap();
        };

    ingest_message(
        "same-time-user-first",
        "same-time-reply-after",
        "start",
        "user",
        "同时间问题",
    );
    ingest_message(
        "same-time-assistant-after",
        "same-time-reply-after",
        "review",
        "assistant",
        "后到回复",
    );
    let replied = snapshot(&state);
    let replied_session = replied["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id("same-time-reply-after"))
        .unwrap();
    assert_eq!(
        replied_session["event"]["id"],
        projected_event_id("same-time-assistant-after")
    );
    assert_eq!(replied_session["overlay_display"]["summary_kind"], "review");
    assert_eq!(
        replied_session["session_message"],
        json!({"role": "assistant", "content": "后到回复"})
    );

    ingest_message(
        "same-time-assistant-first",
        "same-time-user-after",
        "review",
        "assistant",
        "上一轮旧回复",
    );
    ingest_message(
        "same-time-user-after",
        "same-time-user-after",
        "start",
        "user",
        "后到的新问题",
    );
    let reactivated = snapshot(&state);
    let reactivated_session = reactivated["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id("same-time-user-after"))
        .unwrap();
    assert_eq!(
        reactivated_session["event"]["id"],
        projected_event_id("same-time-user-after")
    );
    assert_eq!(
        reactivated_session["overlay_display"]["summary_kind"],
        "running"
    );
    assert_eq!(
        reactivated_session["session_user_message"],
        json!({"role": "user", "content": "后到的新问题"})
    );
    assert_eq!(reactivated_session["session_message"], Value::Null);
}

#[test]
fn pi_settled_event_carries_reply_into_ready_bubble() {
    let (_temp, state) = ready();
    ingest_source_payload(
        &state,
        "pi",
        "pi-ready-message-prompt",
        "pi-ready-message",
        "start",
        &timestamp(1),
        json!({
            "source_event": "input",
            "session_active": true,
            "message_role": "user",
            "message_content": "你好",
            "diagnostic": false
        }),
    );
    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "pi-settled-with-reply",
                "source": "pi",
                "session_id": "pi-ready-message",
                "event_type": "done",
                "created_at": timestamp(0),
                "payload": {
                    "source_event": "agent_settled",
                    "turn_id": "pi-turn-ready-message",
                    "session_active": false,
                    "message_role": "assistant",
                    "message_content": "你好！有什么我可以帮你的吗？",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();

    let current = snapshot(&state);
    let session = current["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id("pi-ready-message"))
        .unwrap();
    assert_eq!(session["official_status"], "ready");
    assert_eq!(
        session["event"]["id"],
        projected_event_id("pi-settled-with-reply")
    );
    assert_eq!(session["overlay_display"]["summary_kind"], "done");
    assert_eq!(session["session_title"], "你好");
    assert_eq!(
        session["session_user_message"],
        json!({"role": "user", "content": "你好"})
    );
    assert_eq!(
        session["session_message"],
        json!({"role": "assistant", "content": "你好！有什么我可以帮你的吗？"})
    );
}

#[test]
fn production_terminal_edges_require_activation_and_close_legacy_active_work() {
    let terminal_cases = [
        ("codex-stop", "codex", "Stop", "done", "completed"),
        ("claude-stop", "claude_code", "Stop", "done", "completed"),
        (
            "claude-stop-failure",
            "claude_code",
            "StopFailure",
            "failed",
            "api_failure",
        ),
        (
            "claude-notification-idle",
            "claude_code",
            "Notification",
            "done",
            "idle",
        ),
        (
            "claude-notification-completed",
            "claude_code",
            "Notification",
            "done",
            "agent_completed",
        ),
        (
            "claude-session-end",
            "claude_code",
            "SessionEnd",
            "done",
            "session_closed",
        ),
        ("pi-settled", "pi", "agent_settled", "done", "settled"),
        (
            "pi-settled-failed",
            "pi",
            "agent_settled",
            "failed",
            "api_failure",
        ),
        (
            "pi-shutdown",
            "pi",
            "session_shutdown",
            "done",
            "session_closed",
        ),
        (
            "opencode-deleted",
            "opencode",
            "session.deleted",
            "done",
            "session_closed",
        ),
        ("opencode-idle", "opencode", "session.idle", "done", "idle"),
        (
            "opencode-status-idle",
            "opencode",
            "session.status",
            "done",
            "idle",
        ),
        (
            "opencode-error",
            "opencode",
            "session.error",
            "failed",
            "session_failure",
        ),
    ];
    let activation_source_event = |source| match source {
        "codex" | "claude_code" => "UserPromptSubmit",
        "pi" => "input",
        "opencode" => "message.user",
        _ => unreachable!(),
    };
    let ingest_terminal = |state: &CoreState,
                           id: &str,
                           source: &str,
                           session_id: &str,
                           source_event: &str,
                           event_type: &str,
                           outcome: &str,
                           affects_activity: bool,
                           seconds_ago: i64| {
        ingest_source_payload(
            state,
            source,
            id,
            session_id,
            event_type,
            &timestamp(seconds_ago),
            json!({
                "source_event": source_event,
                "outcome": outcome,
                "diagnostic": false,
                "affects_activity": affects_activity,
                "session_active": false
            }),
        );
    };

    for (label, source, source_event, event_type, outcome) in terminal_cases {
        let (_recent_temp, recent_state) = ready();
        let active_session = format!("{label}-active");
        ingest_source_payload(
            &recent_state,
            source,
            &format!("{label}-prompt"),
            &active_session,
            "start",
            &timestamp(2),
            json!({
                "source_event": activation_source_event(source),
                "outcome": "started",
                "diagnostic": false,
                "affects_activity": true,
                "session_active": true,
                "message_role": "user",
                "message_content": "real user activation"
            }),
        );
        // Simulate the pre-fix rows already persisted on disk. A known
        // terminal edge must still supersede the older active event even when
        // its historical payload said affects_activity=false.
        ingest_terminal(
            &recent_state,
            &format!("{label}-terminal"),
            source,
            &active_session,
            source_event,
            event_type,
            outcome,
            false,
            1,
        );

        for (suffix, affects_activity) in [("current", true), ("legacy", false)] {
            let close_only_session = format!("{label}-close-only-{suffix}");
            ingest_terminal(
                &recent_state,
                &format!("{label}-close-only-{suffix}-terminal"),
                source,
                &close_only_session,
                source_event,
                event_type,
                outcome,
                affects_activity,
                0,
            );
        }
        let recent = snapshot(&recent_state);
        let recent_sessions = recent["active_agent_sessions"].as_array().unwrap();
        assert_eq!(recent_sessions.len(), 1, "source_event={source_event}");
        let session = recent_sessions
            .iter()
            .find(|session| {
                session["session_id"] == projected_session_id(&format!("{label}-active"))
            })
            .unwrap_or_else(|| panic!("missing activated terminal session {label}"));
        assert_eq!(session["event"]["event_type"], event_type);
        assert_ne!(session["official_status"], "running");
        for suffix in ["current", "legacy"] {
            assert!(recent_sessions.iter().all(|session| {
                session["session_id"]
                    != projected_session_id(&format!("{label}-close-only-{suffix}"))
            }));
        }
    }

    for (label, source, source_event, event_type, outcome) in terminal_cases {
        let (_expired_temp, expired_state) = ready();
        let session_id = format!("{label}-expired");
        ingest_source_payload(
            &expired_state,
            source,
            &format!("{label}-expired-prompt"),
            &session_id,
            "start",
            &timestamp(8),
            json!({
                "source_event": activation_source_event(source),
                "outcome": "started",
                "diagnostic": false,
                "affects_activity": true,
                "session_active": true,
                "message_role": "user",
                "message_content": "older real user activation"
            }),
        );
        ingest_terminal(
            &expired_state,
            &format!("{label}-expired-terminal"),
            source,
            &session_id,
            source_event,
            event_type,
            outcome,
            false,
            7,
        );
        let expired = snapshot(&expired_state);
        if event_type == "failed" {
            assert_eq!(expired["active_agent_state"]["state"], "failed");
        } else {
            assert_eq!(expired["active_agent_state"], Value::Null);
        }
        let expired_sessions = expired["active_agent_sessions"].as_array().unwrap();
        assert_eq!(expired_sessions.len(), 1, "source_event={source_event}");
        let session = expired_sessions
            .iter()
            .find(|session| {
                session["session_id"] == projected_session_id(&format!("{label}-expired"))
            })
            .unwrap_or_else(|| panic!("missing expired terminal session {label}"));
        assert_eq!(session["event"]["event_type"], event_type);
        assert_ne!(session["official_status"], "running");
    }
}

#[test]
fn failed_terminal_state_is_latched_until_new_activity_epoch() {
    for (label, source, activation, failure, completed) in [
        (
            "claude",
            "claude_code",
            "UserPromptSubmit",
            ("StopFailure", "api_failure"),
            ("SessionEnd", "session_closed"),
        ),
        (
            "pi",
            "pi",
            "input",
            ("agent_settled", "api_failure"),
            ("session_shutdown", "session_closed"),
        ),
        (
            "opencode",
            "opencode",
            "message.user",
            ("session.error", "session_failure"),
            ("session.status", "idle"),
        ),
    ] {
        let (_temp, state) = ready();
        let session_id = format!("{label}-failure-latch");
        ingest_source_payload(
            &state,
            source,
            &format!("{label}-failure-prompt"),
            &session_id,
            "start",
            &timestamp(4),
            json!({
                "source_event": activation,
                "outcome": "started",
                "diagnostic": false,
                "affects_activity": true,
                "session_active": true,
                "message_role": "user",
                "message_content": "trigger failure"
            }),
        );
        ingest_source_payload(
            &state,
            source,
            &format!("{label}-failed"),
            &session_id,
            "failed",
            &timestamp(3),
            json!({
                "source_event": failure.0,
                "outcome": failure.1,
                "diagnostic": false,
                "affects_activity": true,
                "session_active": false
            }),
        );
        ingest_source_payload(
            &state,
            source,
            &format!("{label}-idle-tail"),
            &session_id,
            "done",
            &timestamp(2),
            json!({
                "source_event": completed.0,
                "outcome": completed.1,
                "diagnostic": false,
                "affects_activity": true,
                "session_active": false
            }),
        );
        if source == "opencode" {
            ingest_source_payload(
                &state,
                source,
                "opencode-idle-tail-legacy",
                &session_id,
                "done",
                &timestamp(1),
                json!({
                    "source_event": "session.idle",
                    "outcome": "idle",
                    "diagnostic": false,
                    "affects_activity": true,
                    "session_active": false
                }),
            );
        }

        let failed = snapshot(&state);
        let session = failed["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["session_id"] == projected_session_id(&session_id))
            .unwrap();
        assert_eq!(session["official_status"], "blocked", "source={source}");
        assert_eq!(session["event"]["event_type"], "failed", "source={source}");
        assert_eq!(
            session["overlay_display"]["summary_kind"], "failed",
            "source={source}"
        );

        ingest_source_payload(
            &state,
            source,
            &format!("{label}-reactivated"),
            &session_id,
            "start",
            &timestamp(0),
            json!({
                "source_event": activation,
                "outcome": "started",
                "diagnostic": false,
                "affects_activity": true,
                "session_active": true,
                "message_role": "user",
                "message_content": "retry"
            }),
        );
        let reactivated = snapshot(&state);
        let session = reactivated["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["session_id"] == projected_session_id(&session_id))
            .unwrap();
        assert_eq!(session["official_status"], "running", "source={source}");
        assert_eq!(
            session["event"]["id"],
            projected_event_id(&format!("{label}-reactivated")),
            "source={source}"
        );
        assert_eq!(
            session["overlay_display"]["summary_kind"], "running",
            "source={source}"
        );
    }
}

#[test]
fn failure_latch_ignores_completion_tails_but_explicit_epochs_restart_work() {
    let (_temp, state) = ready();
    let session_id = "opencode-explicit-epoch";
    for (id, event_type, source_event, seconds_ago, session_active) in [
        ("epoch-user", "start", "message.user", 12, true),
        ("epoch-failed", "failed", "session.error", 11, false),
        ("epoch-assistant", "start", "message.assistant", 10, true),
        ("epoch-tool-after", "tool", "tool.execute.after", 9, true),
        ("epoch-created", "start", "session.created", 8, false),
        ("epoch-plan", "start", "session.plan.updated", 7, true),
        (
            "epoch-compaction-tail",
            "start",
            "session.compaction.ended",
            6,
            true,
        ),
        (
            "epoch-reasoning-tail",
            "start",
            "session.next.reasoning.ended",
            5,
            true,
        ),
        (
            "epoch-text-tail",
            "start",
            "session.next.text.ended",
            4,
            true,
        ),
    ] {
        let mut payload = json!({
            "source_event": source_event,
            "outcome": if source_event == "session.error" { "session_failure" } else { "observed" },
            "diagnostic": false,
            "affects_activity": true,
            "session_active": session_active
        });
        if source_event == "message.user" {
            payload["message_role"] = json!("user");
        } else if source_event == "message.assistant" {
            payload["message_role"] = json!("assistant");
        }
        ingest_source_payload(
            &state,
            "opencode",
            id,
            session_id,
            event_type,
            &timestamp(seconds_ago),
            payload,
        );
    }
    let blocked = snapshot(&state);
    let session = blocked["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id(session_id))
        .unwrap();
    assert_eq!(session["official_status"], "blocked");
    assert_eq!(session["event"]["event_type"], "failed");
    assert_eq!(session["overlay_display"]["summary_kind"], "failed");

    ingest_source_payload(
        &state,
        "opencode",
        "epoch-retry",
        session_id,
        "start",
        &timestamp(0),
        json!({
            "source_event": "session.status",
            "outcome": "retry",
            "diagnostic": false,
            "affects_activity": true,
            "session_active": true
        }),
    );
    let restarted = snapshot(&state);
    let session = restarted["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id(session_id))
        .unwrap();
    assert_eq!(session["official_status"], "running");
    assert_eq!(session["event"]["id"], projected_event_id("epoch-retry"));
    assert_eq!(session["overlay_display"]["summary_kind"], "running");
}

#[test]
fn active_waiting_and_compaction_starts_open_epochs_without_faking_user_activation() {
    let (_temp, state) = ready();
    ingest_source_payload(
        &state,
        "claude_code",
        "permission-only",
        "permission-only-session",
        "waiting",
        &timestamp(3),
        json!({
            "source_event": "Notification",
            "outcome": "input_requested",
            "affects_activity": true,
            "session_active": true
        }),
    );
    ingest_source_payload(
        &state,
        "claude_code",
        "permission-only-end",
        "permission-only-session",
        "done",
        &timestamp(2),
        json!({
            "source_event": "SessionEnd",
            "outcome": "session_closed",
            "affects_activity": true,
            "session_active": false
        }),
    );
    assert!(snapshot(&state)["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .all(|session| {
            session["session_id"] != projected_session_id("permission-only-session")
        }));

    for (source, session_id, activation, restart) in [
        (
            "claude_code",
            "claude-waiting-restart",
            "UserPromptSubmit",
            "Notification",
        ),
        (
            "pi",
            "pi-compact-restart",
            "input",
            "session_before_compact",
        ),
        (
            "opencode",
            "opencode-compact-restart",
            "message.user",
            "session.compaction.started",
        ),
    ] {
        ingest_source_payload(
            &state,
            source,
            &format!("{session_id}-user"),
            session_id,
            "start",
            &timestamp(6),
            json!({
                "source_event": activation,
                "message_role": "user",
                "affects_activity": true,
                "session_active": true
            }),
        );
        ingest_source_payload(
            &state,
            source,
            &format!("{session_id}-failed"),
            session_id,
            "failed",
            &timestamp(5),
            json!({
                "source_event": if source == "claude_code" { "StopFailure" } else if source == "pi" { "agent_settled" } else { "session.error" },
                "outcome": "api_failure",
                "affects_activity": true,
                "session_active": false
            }),
        );
        ingest_source_payload(
            &state,
            source,
            &format!("{session_id}-restart"),
            session_id,
            if source == "claude_code" {
                "waiting"
            } else {
                "start"
            },
            &timestamp(4),
            json!({
                "source_event": restart,
                "outcome": if source == "claude_code" { "input_requested" } else { "started" },
                "affects_activity": true,
                "session_active": true
            }),
        );
    }
    let sessions = snapshot(&state)["active_agent_sessions"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(
        sessions
            .iter()
            .find(|session| {
                session["session_id"] == projected_session_id("claude-waiting-restart")
            })
            .unwrap()["official_status"],
        "needs_input"
    );
    for session_id in ["pi-compact-restart", "opencode-compact-restart"] {
        assert_eq!(
            sessions
                .iter()
                .find(|session| session["session_id"] == projected_session_id(session_id))
                .unwrap()["official_status"],
            "running"
        );
    }
    ingest_source_payload(
        &state,
        "claude_code",
        "claude-waiting-end",
        "claude-waiting-restart",
        "done",
        &timestamp(0),
        json!({
            "source_event": "SessionEnd",
            "outcome": "session_closed",
            "affects_activity": true,
            "session_active": false
        }),
    );
    let completed = snapshot(&state);
    assert_eq!(
        completed["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| {
                session["session_id"] == projected_session_id("claude-waiting-restart")
            })
            .unwrap()["official_status"],
        "ready"
    );
}

#[test]
fn latched_failure_keeps_status_but_merges_later_terminal_navigation() {
    let (_temp, state) = ready();
    for (source, session_id, activation, failure, close, expected_open) in [
        (
            "claude_code",
            "claude-failed-navigation",
            "UserPromptSubmit",
            "StopFailure",
            "SessionEnd",
            true,
        ),
        (
            "pi",
            "pi-failed-navigation",
            "input",
            "agent_settled",
            "session_shutdown",
            false,
        ),
        (
            "opencode",
            "opencode-failed-navigation",
            "message.user",
            "session.error",
            "session.deleted",
            false,
        ),
    ] {
        ingest_source_payload(
            &state,
            source,
            &format!("{session_id}-user"),
            session_id,
            "start",
            &timestamp(5),
            json!({
                "source_event": activation,
                "message_role": "user",
                "affects_activity": true,
                "session_active": true,
                "session_open": true,
                "session_surface": "cli_terminal"
            }),
        );
        ingest_source_payload(
            &state,
            source,
            &format!("{session_id}-failed"),
            session_id,
            "failed",
            &timestamp(4),
            json!({
                "source_event": failure,
                "outcome": "api_failure",
                "affects_activity": true,
                "session_active": false,
                "session_open": true,
                "session_surface": "cli_terminal",
                "terminal_app": "terminal"
            }),
        );
        ingest_source_payload(
            &state,
            source,
            &format!("{session_id}-close"),
            session_id,
            "done",
            &timestamp(3),
            json!({
                "source_event": close,
                "outcome": "session_closed",
                "affects_activity": true,
                "session_active": false,
                "session_open": expected_open,
                "session_surface": "cli_terminal",
                "terminal_app": "terminal"
            }),
        );
    }
    let snapshot = snapshot(&state);
    for (session_id, expected_open) in [
        ("claude-failed-navigation", true),
        ("pi-failed-navigation", false),
        ("opencode-failed-navigation", false),
    ] {
        let session = snapshot["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["session_id"] == projected_session_id(session_id))
            .unwrap();
        assert_eq!(session["official_status"], "blocked");
        assert_eq!(
            session["overlay_display"]["navigation"]["session_open"],
            expected_open
        );
        assert_eq!(session["overlay_display"]["summary_kind"], "failed");
    }
}

#[test]
fn every_agent_refreshes_reply_completion_and_next_user_turn() {
    let (_temp, state) = ready();
    for (source, session_id, user_event, reply_event, reply_type, followup_done_event) in [
        (
            "codex",
            "codex-lifecycle",
            "UserPromptSubmit",
            "Stop",
            "done",
            None,
        ),
        (
            "claude_code",
            "claude-lifecycle",
            "UserPromptSubmit",
            "Stop",
            "done",
            Some("Notification"),
        ),
        (
            "pi",
            "pi-lifecycle",
            "input",
            "agent_end",
            "done",
            Some("agent_settled"),
        ),
        (
            "opencode",
            "opencode-lifecycle",
            "message.user",
            "message.assistant",
            "start",
            Some("session.idle"),
        ),
    ] {
        let ingest_lifecycle = |id: &str,
                                event_type: &str,
                                source_event: &str,
                                role: Option<&str>,
                                content: Option<&str>,
                                session_active: bool,
                                seconds_ago: i64| {
            handle_request(
                &state,
                request(
                    "agent.ingest",
                    json!({
                        "id": id,
                        "source": source,
                        "session_id": session_id,
                        "event_type": event_type,
                        "created_at": timestamp(seconds_ago),
                        "payload": {
                            "source_event": source_event,
                            "session_active": session_active,
                            "message_role": role,
                            "message_content": content,
                            "diagnostic": false
                        }
                    }),
                ),
            )
            .unwrap();
        };

        ingest_lifecycle(
            &format!("{session_id}-prompt-1"),
            "start",
            user_event,
            Some("user"),
            Some("第一条问题"),
            true,
            40,
        );
        ingest_lifecycle(
            &format!("{session_id}-reply-1"),
            reply_type,
            reply_event,
            Some("assistant"),
            Some("第一条完整回复"),
            reply_type != "done",
            30,
        );
        if let Some(done_event) = followup_done_event {
            ingest_lifecycle(
                &format!("{session_id}-done-1"),
                "done",
                done_event,
                None,
                None,
                false,
                20,
            );
        }

        let completed = snapshot(&state);
        let session = completed["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|candidate| candidate["session_id"] == projected_session_id(session_id))
            .unwrap();
        assert_eq!(session["official_status"], "ready", "source={source}");
        assert!(matches!(
            session["overlay_display"]["summary_kind"].as_str(),
            Some("review" | "done")
        ));
        assert_eq!(session["session_title"], "第一条问题", "source={source}");
        assert_eq!(
            session["session_message"],
            json!({"role": "assistant", "content": "第一条完整回复"}),
            "source={source}"
        );

        ingest_lifecycle(
            &format!("{session_id}-prompt-2"),
            "start",
            user_event,
            Some("user"),
            Some("完成后发送的新问题"),
            true,
            0,
        );
        let reactivated = snapshot(&state);
        let session = reactivated["active_agent_sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|candidate| candidate["session_id"] == projected_session_id(session_id))
            .unwrap();
        assert_eq!(session["official_status"], "running", "source={source}");
        assert_eq!(
            session["overlay_display"]["summary_kind"], "running",
            "source={source}"
        );
        assert_eq!(
            session["session_user_message"],
            json!({"role": "user", "content": "完成后发送的新问题"}),
            "source={source}"
        );
        assert_eq!(session["session_message"], Value::Null, "source={source}");
    }
}

#[test]
fn cli_overlay_projection_uses_first_user_message_as_the_session_title() {
    let (_temp, state) = ready();
    for (source, session_id, first_message, later_message, terminal_source_event) in [
        (
            "pi",
            "pi-title-fallback",
            "Pi 第一条用户消息",
            "Pi 后续用户消息",
            "agent_settled",
        ),
        (
            "claude_code",
            "claude-title-fallback",
            "Claude 第一条用户消息",
            "Claude 后续用户消息",
            "Stop",
        ),
        (
            "opencode",
            "opencode-title-fallback",
            "OpenCode 第一条用户消息",
            "OpenCode 后续用户消息",
            "session.idle",
        ),
    ] {
        for (id_suffix, message, seconds_ago) in
            [("first", first_message, 30), ("later", later_message, 20)]
        {
            handle_request(
                &state,
                request(
                    "agent.ingest",
                    json!({
                        "id": format!("{session_id}-{id_suffix}"),
                        "source": source,
                        "session_id": session_id,
                        "event_type": "start",
                        "created_at": timestamp(seconds_ago),
                        "payload": {
                            "source_event": "before_agent_start",
                            "session_active": true,
                            "message_role": "user",
                            "message_content": message,
                            "diagnostic": false
                        }
                    }),
                ),
            )
            .unwrap();
        }
        handle_request(
            &state,
            request(
                "agent.ingest",
                json!({
                    "id": format!("{session_id}-done"),
                    "source": source,
                    "session_id": session_id,
                    "event_type": "done",
                    "created_at": timestamp(0),
                    "payload": {
                        "source_event": terminal_source_event,
                        "session_active": false,
                        "diagnostic": false
                    }
                }),
            ),
        )
        .unwrap();
    }

    let current = snapshot(&state);
    let sessions = current["active_agent_sessions"].as_array().unwrap();
    for (session_id, expected_title, expected_latest_user_message) in [
        ("pi-title-fallback", "Pi 第一条用户消息", "Pi 后续用户消息"),
        (
            "claude-title-fallback",
            "Claude 第一条用户消息",
            "Claude 后续用户消息",
        ),
        (
            "opencode-title-fallback",
            "OpenCode 第一条用户消息",
            "OpenCode 后续用户消息",
        ),
    ] {
        let session = sessions
            .iter()
            .find(|session| session["session_id"] == projected_session_id(session_id))
            .unwrap();
        assert_eq!(session["session_title"], expected_title);
        assert_eq!(
            session["session_user_message"],
            json!({"role": "user", "content": expected_latest_user_message})
        );
        assert_eq!(session["session_message"], Value::Null);
    }

    handle_request(
        &state,
        request(
            "agent.ingest",
            json!({
                "id": "pi-native-title",
                "source": "pi",
                "session_id": "pi-title-fallback",
                "event_type": "done",
                "created_at": timestamp(0),
                "payload": {
                    "source_event": "agent_settled",
                    "session_active": false,
                    "session_title": "Pi 原生会话标题",
                    "diagnostic": false
                }
            }),
        ),
    )
    .unwrap();
    let updated = snapshot(&state);
    let pi_session = updated["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == projected_session_id("pi-title-fallback"))
        .unwrap();
    assert_eq!(pi_session["session_title"], "Pi 原生会话标题");
    assert_eq!(pi_session["overlay_display"]["summary_kind"], "done");
}

#[test]
fn session_message_timeout_patch_is_typed_and_bounded() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    let revision = initial["behavior_revision"].as_str().unwrap();
    let updated = patch(
        &state,
        revision,
        json!({ "session_message_timeout_minutes": 30 }),
    )
    .unwrap();
    assert_eq!(updated["behavior"]["session_message_timeout_minutes"], 30);

    let next_revision = updated["revision"].as_str().unwrap();
    let error = patch(
        &state,
        next_revision,
        json!({ "session_message_timeout_minutes": 0 }),
    )
    .unwrap_err();
    assert!(error.to_string().contains("must be between 1 and 1440"));
}

#[test]
fn bubble_transparency_patch_is_typed_and_bounded() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    let revision = initial["behavior_revision"].as_str().unwrap();
    let updated = patch(&state, revision, json!({ "bubble_transparency": 0.8 })).unwrap();
    assert_eq!(updated["behavior"]["bubble_transparency"], 0.8);

    let next_revision = updated["revision"].as_str().unwrap();
    let error = patch(&state, next_revision, json!({ "bubble_transparency": 1.1 })).unwrap_err();
    assert!(error
        .to_string()
        .contains("bubble_transparency must be between 0 and 1"));
}

#[test]
fn appearance_theme_patch_is_typed_and_persisted() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    let revision = initial["behavior_revision"].as_str().unwrap();
    let updated = patch(&state, revision, json!({ "appearance_theme": "dark" })).unwrap();
    assert_eq!(updated["behavior"]["appearance_theme"], "dark");
    assert_eq!(updated["behavior"]["bubble_transparency"], 0.55);

    let next_revision = updated["revision"].as_str().unwrap();
    let error = patch(
        &state,
        next_revision,
        json!({ "appearance_theme": "sepia" }),
    )
    .unwrap_err();
    assert!(error.to_string().contains("unknown variant"));
}

#[test]
fn session_group_display_patch_is_typed_and_persisted() {
    let (_temp, state) = ready();
    let initial = snapshot(&state);
    assert_eq!(initial["behavior"]["session_group_display"], "stacked");

    let revision = initial["behavior_revision"].as_str().unwrap();
    let updated = patch(
        &state,
        revision,
        json!({ "session_group_display": "expanded" }),
    )
    .unwrap();
    assert_eq!(updated["behavior"]["session_group_display"], "expanded");
    assert_eq!(
        snapshot(&state)["behavior"]["session_group_display"],
        "expanded"
    );

    let next_revision = updated["revision"].as_str().unwrap();
    let error = patch(
        &state,
        next_revision,
        json!({ "session_group_display": "grid" }),
    )
    .unwrap_err();
    assert!(error.to_string().contains("unknown variant"));

    let error = patch(
        &state,
        next_revision,
        json!({ "session_group_layout": "stacked" }),
    )
    .unwrap_err();
    assert!(error.to_string().contains("unknown field"));
}

#[test]
fn official_pet_priority_prefers_needs_input_over_blocked() {
    let (_temp, state) = ready();
    ingest(
        &state,
        "blocked",
        "blocked-session",
        "failed",
        &timestamp(1),
    );
    ingest(
        &state,
        "needs-input",
        "waiting-session",
        "waiting",
        &timestamp(2),
    );

    let current = snapshot(&state);
    assert_eq!(
        current["active_agent_state"]["event"]["id"],
        projected_event_id("needs-input")
    );
    assert_eq!(
        current["active_agent_state"]["official_status"],
        "needs_input"
    );
}
