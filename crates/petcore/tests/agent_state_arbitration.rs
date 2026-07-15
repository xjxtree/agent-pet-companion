use petcore::paths::AppPaths;
use petcore::rpc::{handle_json_line, handle_request, CoreState, RpcRequest};
use serde_json::{json, Value};
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
fn newer_lower_priority_event_replaces_expired_state() {
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
        "tool-current"
    );
    assert_eq!(current_snapshot["active_agent_state"]["state"], "tool");
    assert_eq!(current_snapshot["active_agent_state"]["lease_seconds"], 30);
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
        "tool-current"
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
        "done-later-sequence"
    );
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
fn active_session_persists_and_keeps_latest_user_message_until_terminal_event() {
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
    assert_eq!(active["active_agent_state"]["event"]["id"], "later-tool");
    assert_eq!(active["active_agent_state"]["official_status"], "running");
    assert_eq!(active["active_agent_state"]["session_active"], true);
    assert_eq!(active["active_agent_state"]["lease_seconds"], Value::Null);
    assert_eq!(active["active_agent_state"]["expires_at"], Value::Null);
    assert_eq!(
        active["active_agent_state"]["latest_user_message"]["id"],
        "prompt-message"
    );
    assert_eq!(
        active["active_agent_state"]["latest_user_message"]["payload_json"]["message_content"],
        "保持当前会话信息"
    );
    assert_eq!(active["active_agent_state"]["latest_message"], Value::Null);
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
        .any(|session| session["session_id"] == "stale-session"));

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
        .any(|session| session["session_id"] == "stale-session"));
}

#[test]
fn waiting_and_failed_sessions_ignore_normal_display_timeout() {
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
    assert_eq!(current["behavior"]["session_message_timeout_minutes"], 15);
}

#[test]
fn closed_waiting_session_does_not_persist_as_pending_work() {
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
    assert_eq!(snapshot(&state)["active_agent_sessions"], json!([]));
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
        .find(|session| session["session_id"] == "turn-boundary")
        .unwrap();
    assert_eq!(session["latest_message"], Value::Null);

    ingest_message("new-reply", "review", "assistant", "本轮回复", 0);
    let responded = snapshot(&state);
    let session = responded["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == "turn-boundary")
        .unwrap();
    assert_eq!(session["latest_message"]["id"], "new-reply");
}

#[test]
fn pi_settled_event_carries_reply_into_ready_bubble() {
    let (_temp, state) = ready();
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
        .find(|session| session["session_id"] == "pi-ready-message")
        .unwrap();
    assert_eq!(session["official_status"], "ready");
    assert_eq!(session["session_message"]["role"], "assistant");
    assert_eq!(
        session["session_message"]["content"],
        "你好！有什么我可以帮你的吗？"
    );
    assert_eq!(session["latest_message"]["id"], "pi-settled-with-reply");
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
            .find(|candidate| candidate["session_id"] == session_id)
            .unwrap();
        assert_eq!(session["official_status"], "ready", "source={source}");
        assert_eq!(
            session["session_message"]["content"], "第一条完整回复",
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
            .find(|candidate| candidate["session_id"] == session_id)
            .unwrap();
        assert_eq!(session["official_status"], "running", "source={source}");
        assert_eq!(
            session["session_user_message"]["content"], "完成后发送的新问题",
            "source={source}"
        );
        assert_eq!(session["session_message"], Value::Null, "source={source}");
    }
}

#[test]
fn cli_session_title_falls_back_to_first_user_message() {
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
            .find(|session| session["session_id"] == session_id)
            .unwrap();
        assert_eq!(session["session_title"], expected_title);
        assert_eq!(
            session["session_user_message"]["content"],
            expected_latest_user_message
        );
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
        .find(|session| session["session_id"] == "pi-title-fallback")
        .unwrap();
    assert_eq!(pi_session["session_title"], "Pi 原生会话标题");
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
    assert_eq!(current["active_agent_state"]["event"]["id"], "needs-input");
    assert_eq!(
        current["active_agent_state"]["official_status"],
        "needs_input"
    );
}
