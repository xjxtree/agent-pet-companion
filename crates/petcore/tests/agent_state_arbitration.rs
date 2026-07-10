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
