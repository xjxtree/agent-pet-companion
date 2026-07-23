use petcore::adapter_contracts::parse_contract_event;
use petcore::event_envelope::NormalizedAgentEvent;
use petcore_types::{AgentEventType, AgentSource};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn fixture(path: &str) -> Value {
    serde_json::from_slice(
        &std::fs::read(repository_root().join("fixtures/contracts").join(path)).unwrap(),
    )
    .unwrap()
}

fn parsed(source: AgentSource, path: &str) -> petcore::adapter_contracts::ContractEvent {
    parse_contract_event(source, &fixture(path))
        .unwrap()
        .unwrap_or_else(|| panic!("fixture {path} should emit a state event"))
}

#[test]
fn adapter_session_title_and_project_label_match_envelope_utf8_limits() {
    let exact_title = format!("{}a", "界".repeat(53));
    let oversized_title = format!("{exact_title}b");
    let exact_project_label = format!("{}ab", "界".repeat(42));
    let oversized_project_label = format!("{exact_project_label}c");
    assert_eq!(exact_title.len(), 160);
    assert_eq!(oversized_title.len(), 161);
    assert_eq!(exact_project_label.len(), 128);
    assert_eq!(oversized_project_label.len(), 129);

    let parse = |title: &str, project_label: &str| {
        parse_contract_event(
            AgentSource::ClaudeCode,
            &serde_json::json!({
                "hook_event_name": "UserPromptSubmit",
                "session_id": "utf8-adapter-session",
                "session_title": title,
                "cwd": format!("/tmp/{project_label}"),
                "prompt": "verify adapter byte bounds"
            }),
        )
        .unwrap()
        .unwrap()
    };

    let exact = parse(&exact_title, &exact_project_label);
    assert_eq!(exact.session_title.as_deref(), Some(exact_title.as_str()));
    assert_eq!(
        exact.project_label.as_deref(),
        Some(exact_project_label.as_str())
    );

    let truncated = parse(&oversized_title, &oversized_project_label);
    assert_eq!(
        truncated.session_title.as_deref(),
        Some(exact_title.as_str()),
        "session titles use the 160-byte envelope boundary"
    );
    assert_eq!(
        truncated.project_label.as_deref(),
        Some(exact_project_label.as_str()),
        "project labels remain capped at 128 bytes"
    );

    let normalized = NormalizedAgentEvent::from_external(
        AgentSource::ClaudeCode,
        serde_json::json!({
            "source": "claude_code",
            "session_id": truncated.session_id,
            "event_type": "start",
            "payload": {
                "source_event": truncated.source_event,
                "contract_version": truncated.contract_version,
                "diagnostic": truncated.diagnostic,
                "affects_activity": truncated.affects_activity,
                "session_active": truncated.session_active,
                "project_label": truncated.project_label,
                "session_title": truncated.session_title
            }
        }),
        "2026-07-10T00:00:00Z",
    )
    .expect("adapter output must remain valid at the runtime envelope boundary");
    assert_eq!(
        normalized.payload_json["session_title"]
            .as_str()
            .unwrap()
            .len(),
        160
    );
    assert_eq!(
        normalized.payload_json["project_label"]
            .as_str()
            .unwrap()
            .len(),
        128
    );
}

#[test]
fn codex_and_claude_official_hooks_map_without_raw_payload() {
    let codex_session_start = parse_contract_event(
        AgentSource::Codex,
        &serde_json::json!({
            "hook_event_name": "SessionStart",
            "session_id": "codex-passive-session"
        }),
    )
    .unwrap();
    assert!(codex_session_start.is_none());

    let stop = parsed(AgentSource::Codex, "codex/stop.json");
    assert_eq!(stop.session_id.as_deref(), Some("codex-session-stop"));
    assert_eq!(stop.kind, AgentEventType::Done);
    assert_eq!(stop.source_event, "Stop");
    assert!(!stop.session_active);
    assert_eq!(stop.message_role.as_deref(), Some("assistant"));
    assert_eq!(
        stop.message_content.as_deref(),
        Some("修复已完成，测试全部通过。")
    );

    let codex_prompt = parsed(AgentSource::Codex, "codex/user_prompt_submit.json");
    assert_eq!(codex_prompt.kind, AgentEventType::Start);
    assert!(codex_prompt.session_active);
    assert_eq!(codex_prompt.source_event, "UserPromptSubmit");
    assert_eq!(codex_prompt.activity_kind.as_deref(), Some("thinking"));
    assert_eq!(codex_prompt.session_open, None);
    assert_eq!(codex_prompt.message_role.as_deref(), Some("user"));
    assert_eq!(
        codex_prompt.message_content.as_deref(),
        Some("修复宠物气泡，让活跃会话持续显示。")
    );
    assert_eq!(
        codex_prompt.project_label.as_deref(),
        Some("agent-pet-companion")
    );

    let post_tool = parsed(AgentSource::Codex, "codex/post_tool_use.json");
    assert_eq!(post_tool.kind, AgentEventType::Tool);
    assert_eq!(post_tool.tool_name.as_deref(), Some("Bash"));
    assert_eq!(post_tool.outcome.as_deref(), Some("completed"));
    assert_eq!(post_tool.activity_kind.as_deref(), Some("thinking"));
    assert!(post_tool
        .external_event_id
        .as_deref()
        .is_some_and(|id| id.starts_with("evt_hook_")));

    let prompt = parsed(
        AgentSource::ClaudeCode,
        "claude-code/user_prompt_submit.json",
    );
    assert_eq!(prompt.kind, AgentEventType::Start);
    assert_eq!(prompt.session_id.as_deref(), Some("claude-session-prompt"));
    assert_eq!(
        prompt.message_content.as_deref(),
        Some("请修复当前测试失败")
    );

    let tool_failure = parsed(
        AgentSource::ClaudeCode,
        "claude-code/post_tool_use_failure.json",
    );
    assert_eq!(tool_failure.kind, AgentEventType::Tool);
    assert!(tool_failure.session_active);
    assert_eq!(tool_failure.outcome.as_deref(), Some("tool_failure"));
    assert_eq!(tool_failure.activity_kind.as_deref(), Some("thinking"));

    let api_failure = parsed(AgentSource::ClaudeCode, "claude-code/stop_failure.json");
    assert_eq!(api_failure.kind, AgentEventType::Failed);
    assert_eq!(api_failure.outcome.as_deref(), Some("api_failure"));

    let serialized = serde_json::to_string(&[
        stop,
        codex_prompt,
        post_tool,
        prompt,
        tool_failure,
        api_failure,
    ])
    .unwrap();
    for secret in [
        "TOKEN=",
        "command",
        "tool_input",
        "tool_response",
        "tool-secret-id",
        "error",
    ] {
        assert!(!serialized.contains(secret), "raw field leaked: {secret}");
    }
}

#[test]
fn opaque_tool_invocation_identity_prevents_same_turn_collisions_without_leaking_raw_ids() {
    let codex_tool = |source_event: &str, invocation_id: &str| {
        parse_contract_event(
            AgentSource::Codex,
            &serde_json::json!({
                "hook_event_name": source_event,
                "session_id": "codex-repeat-session",
                "turn_id": "codex-repeat-turn",
                "tool_name": "Bash",
                "tool_use_id": invocation_id,
                "tool_input": { "command": "TOKEN=must-not-cross" }
            }),
        )
        .unwrap()
        .unwrap()
    };

    let first = codex_tool("PreToolUse", "raw-call-one");
    let first_retry = codex_tool("PreToolUse", "raw-call-one");
    let second = codex_tool("PreToolUse", "raw-call-two");
    let first_completed = codex_tool("PostToolUse", "raw-call-one");
    assert_eq!(first.external_event_id, first_retry.external_event_id);
    assert_ne!(first.external_event_id, second.external_event_id);
    assert_ne!(first.external_event_id, first_completed.external_event_id);

    let claude = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "PreToolUse",
            "session_id": "claude-repeat-session",
            "turn_id": "claude-repeat-turn",
            "tool_name": "Bash",
            "tool_use_id": "raw-claude-call"
        }),
    )
    .unwrap()
    .unwrap();
    let pi = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "tool_execution_start",
            "session_id": "pi-repeat-session",
            "turn_id": "pi-repeat-turn",
            "toolName": "bash",
            "tool_call_id": "raw-pi-call"
        }),
    )
    .unwrap()
    .unwrap();
    let opencode_before = parsed(
        AgentSource::Opencode,
        "opencode-v1.17.18/tool_execute_before.json",
    );
    let opencode_after = parsed(
        AgentSource::Opencode,
        "opencode-v1.17.18/tool_execute_after.json",
    );
    for event in [&claude, &pi, &opencode_before, &opencode_after] {
        assert!(event
            .external_event_id
            .as_deref()
            .is_some_and(|id| id.starts_with("evt_hook_")));
    }
    assert_ne!(
        opencode_before.external_event_id,
        opencode_after.external_event_id
    );

    let serialized = serde_json::to_string(&[
        first,
        first_retry,
        second,
        first_completed,
        claude,
        pi,
        opencode_before,
        opencode_after,
    ])
    .unwrap();
    for forbidden in [
        "raw-call",
        "raw-claude-call",
        "raw-pi-call",
        "opencode-secret-call-id",
        "must-not-cross",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "raw invocation data leaked: {forbidden}"
        );
    }
}

#[test]
fn claude_idle_prompt_is_ready_not_needs_input() {
    let idle = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "Notification",
            "notification_type": "idle_prompt",
            "session_id": "claude-idle-after-stop"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(idle.kind, AgentEventType::Done);
    assert_eq!(idle.outcome.as_deref(), Some("idle"));
    assert!(!idle.session_active);
    assert_eq!(idle.interaction_kind, None);

    let permission = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "session_id": "claude-permission"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(permission.kind, AgentEventType::Waiting);
    assert_eq!(
        permission.interaction_kind.as_deref(),
        Some("input_required")
    );
}

#[test]
fn passive_session_open_and_activity_affecting_close_edges_are_distinct() {
    let claude_start = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "SessionStart",
            "session_id": "claude-passive-start"
        }),
    )
    .unwrap()
    .unwrap();
    let claude_end = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "SessionEnd",
            "session_id": "claude-passive-end"
        }),
    )
    .unwrap()
    .unwrap();
    let pi_shutdown = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "session_shutdown",
            "session_id": "pi-passive-shutdown"
        }),
    )
    .unwrap()
    .unwrap();
    let opencode_created = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.created",
            "properties": { "info": { "id": "opencode-passive-created" } }
        }),
    )
    .unwrap()
    .unwrap();
    let opencode_deleted = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.deleted",
            "properties": { "info": { "id": "opencode-passive-deleted" } }
        }),
    )
    .unwrap()
    .unwrap();

    for event in [claude_start, opencode_created] {
        assert!(
            !event.affects_activity,
            "{} must remain passive",
            event.source_event
        );
    }
    for event in [claude_end, pi_shutdown, opencode_deleted] {
        assert!(
            event.affects_activity,
            "{} must supersede older active work in its session",
            event.source_event
        );
        assert_eq!(event.kind, AgentEventType::Done);
        assert!(!event.session_active);
    }
}

#[test]
fn opencode_terminal_events_close_work_without_misclassifying_host_disposal() {
    for (input, expected_kind, expected_open) in [
        (
            serde_json::json!({
                "type": "session.deleted",
                "properties": { "info": { "id": "opencode-deleted" } }
            }),
            AgentEventType::Done,
            false,
        ),
        (
            serde_json::json!({
                "type": "session.idle",
                "properties": { "sessionID": "opencode-idle" }
            }),
            AgentEventType::Done,
            true,
        ),
        (
            serde_json::json!({
                "type": "session.status",
                "properties": {
                    "sessionID": "opencode-status-idle",
                    "status": { "type": "idle" }
                }
            }),
            AgentEventType::Done,
            true,
        ),
        (
            serde_json::json!({
                "type": "session.error",
                "properties": { "sessionID": "opencode-error" }
            }),
            AgentEventType::Failed,
            true,
        ),
    ] {
        let event = parse_contract_event(AgentSource::Opencode, &input)
            .unwrap()
            .unwrap();
        assert!(
            event.affects_activity,
            "source_event={}",
            event.source_event
        );
        assert!(!event.session_active, "source_event={}", event.source_event);
        assert_eq!(event.kind, expected_kind);
        assert_eq!(event.session_open, Some(expected_open));
    }

    for disposed in ["server.instance.disposed", "global.disposed"] {
        assert!(parse_contract_event(
            AgentSource::Opencode,
            &serde_json::json!({ "type": disposed })
        )
        .unwrap()
        .is_none());
    }
    assert!(parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.error",
            "properties": { "error": { "name": "UnknownError" } }
        })
    )
    .unwrap()
    .is_none());

    for session_scoped in [
        serde_json::json!({ "type": "session.created", "properties": {} }),
        serde_json::json!({ "type": "session.deleted", "properties": {} }),
        serde_json::json!({ "type": "session.status", "properties": { "status": { "type": "idle" } } }),
        serde_json::json!({ "type": "session.idle", "properties": {} }),
        serde_json::json!({ "type": "session.next.step.ended", "properties": { "finish": "stop" } }),
        serde_json::json!({ "type": "session.next.step.failed", "properties": {} }),
    ] {
        assert!(parse_contract_event(AgentSource::Opencode, &session_scoped)
            .unwrap()
            .is_none());
    }
}

#[test]
fn opencode_v2_step_outcomes_are_terminal_only_when_execution_settles() {
    for (finish, expected_kind, expected_outcome, expected_active) in [
        ("tool-calls", AgentEventType::Start, "continued", true),
        ("tool_calls", AgentEventType::Start, "continued", true),
        ("tool_use", AgentEventType::Start, "continued", true),
        ("stop", AgentEventType::Done, "completed", false),
        ("length", AgentEventType::Done, "completed", false),
        ("other", AgentEventType::Done, "completed", false),
        ("unknown", AgentEventType::Done, "completed", false),
        (
            "content-filter",
            AgentEventType::Failed,
            "session_failure",
            false,
        ),
        ("error", AgentEventType::Failed, "session_failure", false),
    ] {
        let event = parse_contract_event(
            AgentSource::Opencode,
            &serde_json::json!({
                "type": "session.next.step.ended",
                "properties": { "sessionID": format!("step-{finish}"), "finish": finish }
            }),
        )
        .unwrap()
        .unwrap();
        assert_eq!(event.kind, expected_kind, "finish={finish}");
        assert_eq!(event.outcome.as_deref(), Some(expected_outcome));
        assert_eq!(event.session_active, expected_active);
    }

    for (outcome, expected_kind, expected_active) in [
        ("continued", AgentEventType::Start, true),
        ("completed", AgentEventType::Done, false),
        ("session_failure", AgentEventType::Failed, false),
    ] {
        let event = parse_contract_event(
            AgentSource::Opencode,
            &serde_json::json!({
                "type": "session.next.step.ended",
                "properties": { "sessionID": format!("normalized-{outcome}"), "finish": "tool-calls" },
                "outcome": outcome
            }),
        )
        .unwrap()
        .unwrap();
        assert_eq!(event.kind, expected_kind, "outcome={outcome}");
        assert_eq!(event.session_active, expected_active);
    }

    let failed = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.next.step.failed",
            "properties": {
                "sessionID": "failed-step",
                "error": { "message": "must-not-cross" }
            }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(failed.kind, AgentEventType::Failed);
    assert_eq!(failed.outcome.as_deref(), Some("session_failure"));
    assert!(!failed.session_active);
    assert!(parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.next.step.ended",
            "properties": { "sessionID": "future-finish", "finish": "future-value" }
        })
    )
    .unwrap()
    .is_none());
}

#[test]
fn claude_metadata_prompt_fence_and_background_events_are_semantic() {
    let setup = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "Setup",
            "session_id": "claude-metadata"
        }),
    )
    .unwrap()
    .unwrap();
    assert!(!setup.affects_activity);
    assert_eq!(setup.outcome.as_deref(), Some("observed"));

    let prompt = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-prompt",
            "prompt_id": "prompt-authoritative",
            "turn_id": "legacy-turn"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(prompt.turn_id.as_deref(), Some("prompt-authoritative"));

    let denied = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "PermissionDenied",
            "session_id": "claude-prompt",
            "prompt_id": "prompt-authoritative"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(denied.outcome.as_deref(), Some("auto_denied"));
    assert_eq!(denied.kind, AgentEventType::Tool);

    let background = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "Stop",
            "session_id": "claude-prompt",
            "prompt_id": "prompt-authoritative",
            "background_tasks": [{"status": "running", "command": "must-not-cross"}]
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(background.kind, AgentEventType::Start);
    assert!(background.session_active);
    assert_eq!(background.outcome.as_deref(), Some("background_active"));

    let needs_input = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "Notification",
            "notification_type": "agent_needs_input",
            "session_id": "claude-prompt"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(needs_input.kind, AgentEventType::Waiting);

    let completed = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "Notification",
            "notification_type": "agent_completed",
            "session_id": "claude-prompt"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(completed.kind, AgentEventType::Done);
}

#[test]
fn pi_uses_settled_and_marks_shutdown_navigation_closed() {
    let input = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "input",
            "session_id": "pi-session-input",
            "turn_id": "pi-turn-input",
            "text": "完成后发送的新问题"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(input.kind, AgentEventType::Start);
    assert!(input.session_active);
    assert_eq!(input.message_role.as_deref(), Some("user"));
    assert_eq!(input.message_content.as_deref(), Some("完成后发送的新问题"));

    let settled = parsed(AgentSource::Pi, "pi/agent_settled.json");
    assert_eq!(settled.kind, AgentEventType::Done);
    assert_eq!(settled.session_id.as_deref(), Some("pi-session-settled"));

    let end = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "agent_end",
            "session_id": "pi-session-settling",
            "message_content": "Final response"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(end.kind, AgentEventType::Start);
    assert!(end.session_active);
    assert_eq!(end.message_role.as_deref(), Some("assistant"));

    let message_end = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "message_end",
            "session_id": "pi-session-message",
            "turn_id": "pi-turn-message",
            "message_role": "assistant",
            "message_content": "你好！有什么我可以帮你的吗？"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(message_end.kind, AgentEventType::Start);
    assert!(message_end.session_active);
    assert_eq!(message_end.outcome.as_deref(), Some("message"));
    assert_eq!(message_end.turn_id.as_deref(), Some("pi-turn-message"));
    assert_eq!(
        message_end.message_content.as_deref(),
        Some("你好！有什么我可以帮你的吗？")
    );

    let settled_with_message = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "agent_settled",
            "session_id": "pi-session-message",
            "turn_id": "pi-turn-message",
            "message_role": "assistant",
            "message_content": "你好！有什么我可以帮你的吗？"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(settled_with_message.kind, AgentEventType::Done);
    assert_eq!(
        settled_with_message.message_role.as_deref(),
        Some("assistant")
    );
    assert_eq!(
        settled_with_message.message_content.as_deref(),
        Some("你好！有什么我可以帮你的吗？")
    );

    let recoverable_tool_error = parsed(AgentSource::Pi, "pi/tool_execution_end_error.json");
    assert_eq!(recoverable_tool_error.kind, AgentEventType::Tool);
    assert!(recoverable_tool_error.session_active);
    assert_eq!(recoverable_tool_error.tool_name.as_deref(), Some("bash"));
    assert_eq!(
        recoverable_tool_error.outcome.as_deref(),
        Some("tool_failure")
    );
    assert!(!serde_json::to_string(&recoverable_tool_error)
        .unwrap()
        .contains("pi-secret"));

    let final_agent_error = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "agent_settled",
            "session_id": "pi-session-error",
            "agent_error": true
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(final_agent_error.kind, AgentEventType::Failed);
    assert_eq!(final_agent_error.outcome.as_deref(), Some("api_failure"));
    assert!(!final_agent_error.session_active);

    let shutdown = parsed(AgentSource::Pi, "pi/session_shutdown_reload.json");
    assert_eq!(shutdown.kind, AgentEventType::Done);
    assert_eq!(shutdown.outcome.as_deref(), Some("session_closed"));
    assert_eq!(shutdown.session_open, Some(false));
}

#[test]
fn opencode_v1_17_18_reads_discriminated_and_direct_payloads() {
    let idle = parsed(AgentSource::Opencode, "opencode-v1.17.18/session_idle.json");
    assert_eq!(idle.kind, AgentEventType::Done);
    assert_eq!(idle.session_id.as_deref(), Some("opencode-session-idle"));

    let error = parsed(
        AgentSource::Opencode,
        "opencode-v1.17.18/session_error.json",
    );
    assert_eq!(error.kind, AgentEventType::Failed);
    assert_eq!(error.session_id.as_deref(), Some("opencode-session-error"));

    let asked = parsed(
        AgentSource::Opencode,
        "opencode-v1.17.18/permission_updated.json",
    );
    assert_eq!(asked.kind, AgentEventType::Waiting);
    assert_eq!(
        asked.session_id.as_deref(),
        Some("opencode-session-permission")
    );

    let replied = parsed(
        AgentSource::Opencode,
        "opencode-v1.17.18/permission_replied.json",
    );
    assert_eq!(replied.kind, AgentEventType::Tool);
    assert_eq!(replied.outcome.as_deref(), Some("permission_replied_once"));

    for fixture_name in ["tool_execute_before.json", "tool_execute_after.json"] {
        let event = parsed(
            AgentSource::Opencode,
            &format!("opencode-v1.17.18/{fixture_name}"),
        );
        assert_eq!(event.kind, AgentEventType::Tool);
        assert_eq!(event.session_id.as_deref(), Some("opencode-session-tool"));
        assert_eq!(event.tool_name.as_deref(), Some("bash"));
        let serialized = serde_json::to_string(&event).unwrap();
        assert!(!serialized.contains("opencode-secret"));
        assert!(!serialized.contains("TOKEN="));
    }

    let allowlisted_before = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "tool.execute.before",
            "input": {
                "tool": "bash",
                "sessionID": "opencode-session-sanitized"
            },
            "outcome": "started"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(allowlisted_before.outcome.as_deref(), Some("started"));
}

#[test]
fn opencode_v1_18_maps_v2_waiting_and_prompt_events_without_private_content() {
    let permission_asked = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "permission.v2.asked",
            "eventID": "opaque-host-event-digest",
            "properties": {
                "sessionID": "opencode-v2-session",
                "permission": "must-not-be-forwarded",
                "resources": ["must-not-be-forwarded"]
            }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(permission_asked.kind, AgentEventType::Waiting);
    assert_eq!(
        permission_asked.interaction_kind.as_deref(),
        Some("approval_required")
    );
    assert!(permission_asked
        .external_event_id
        .as_deref()
        .is_some_and(|id| id.starts_with("evt_hook_")));

    let permission_replied = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "permission.v2.replied",
            "properties": {
                "sessionID": "opencode-v2-session",
                "response": "once"
            }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(permission_replied.kind, AgentEventType::Tool);
    assert_eq!(
        permission_replied.outcome.as_deref(),
        Some("permission_replied_once")
    );

    let question_asked = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "question.v2.asked",
            "properties": { "sessionID": "opencode-v2-session" }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(question_asked.kind, AgentEventType::Waiting);
    assert_eq!(
        question_asked.interaction_kind.as_deref(),
        Some("input_required")
    );

    let prompt_admitted = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.next.prompt.admitted",
            "eventID": "opaque-prompt-event-digest",
            "turn_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "properties": { "sessionID": "opencode-v2-session" }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(prompt_admitted.kind, AgentEventType::Start);
    assert_eq!(prompt_admitted.outcome.as_deref(), Some("prompt_admitted"));
    assert_eq!(prompt_admitted.activity_kind.as_deref(), Some("thinking"));
    assert_eq!(
        prompt_admitted.turn_id.as_deref(),
        Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    );
    assert!(prompt_admitted
        .external_event_id
        .as_deref()
        .is_some_and(|id| id.starts_with("evt_hook_")));

    let serialized = serde_json::to_string(&[
        permission_asked,
        permission_replied,
        question_asked,
        prompt_admitted,
    ])
    .unwrap();
    assert!(!serialized.contains("must-not-be-forwarded"));
    assert!(!serialized.contains("opaque-host-event-digest"));
    assert!(!serialized.contains("opaque-prompt-event-digest"));
}

#[test]
fn versioned_templates_only_claim_supported_contracts() {
    let root = repository_root();
    let codex = std::fs::read_to_string(root.join("plugins/codex/hooks/hooks.json.tpl")).unwrap();
    let codex_json: Value = serde_json::from_str(&codex).unwrap();
    assert!(codex_json
        .as_object()
        .unwrap()
        .keys()
        .all(|key| matches!(key.as_str(), "description" | "hooks")));
    assert!(!codex.contains("StopFailure"));
    assert!(!codex.contains("--event-type review"));

    let claude =
        std::fs::read_to_string(root.join("plugins/claude-code/settings.fragment.json.tpl"))
            .unwrap();
    assert!(claude.contains("PostToolUseFailure"));
    assert!(claude.contains("claude-hooks-2026-07-17-activity-v5"));
    assert!(claude.contains("\"async\":false"));
    assert!(claude.contains("\"timeout\":2"));
    for excluded in ["MessageDisplay", "FileChanged", "WorktreeCreate"] {
        assert!(!claude.contains(excluded));
    }

    let pi = std::fs::read_to_string(root.join("plugins/pi/agent-pet-companion.ts.tpl")).unwrap();
    for invalid in [
        "tool_execution_failed",
        "permission_request",
        "approval_request",
        "session_error",
    ] {
        assert!(
            !pi.contains(invalid),
            "invalid Pi event registered: {invalid}"
        );
    }
    assert!(pi.contains("pi.on(\"agent_settled\""));
    assert!(pi.contains("pi.on(\"message_end\""));
    assert!(pi.contains("pi-extension-0.80.10-activity-v7"));
    assert!(pi.contains("APC_PI_EVENT_INVENTORY"));
    assert!(pi.contains("pi.on(\"project_trust\""));
    assert!(pi.contains("pi.on(\"input\""));
    assert!(pi.contains("await sendEvent(allowlisted)"));
    assert!(pi.contains("turn_id: activeTurnIds.get(id)"));
    assert!(pi.contains("tool_call_id: event?.toolCallId"));
    assert!(pi.contains("event?.isError === true"));
    assert!(pi.contains("assistant?.stopReason === \"error\""));
    assert!(pi.contains("agent_error: agentError"));
    assert!(pi.contains("connectorDiagnostic || event?.diagnostic === true"));
    assert!(pi.contains("type: \"connector.probe\""));
    assert!(pi.contains("structured-extension-events"));
    assert!(pi.contains("pi.on(\"agent_end\""));
    assert!(pi.contains("session_open: event?.type !== \"session_shutdown\""));

    let opencode =
        std::fs::read_to_string(root.join("plugins/opencode/agent-pet-companion.js.tpl")).unwrap();
    assert!(opencode.contains("opencode-v1.18.0-activity-v8"));
    assert!(opencode.contains("APC_OPENCODE_EVENT_INVENTORY"));
    assert!(opencode.contains("event?.properties"));
    assert!(opencode.contains("input?.sessionID"));
    assert!(!opencode.contains("output?.args"));
    assert!(opencode.contains("connectorDiagnostic"));
    assert!(opencode.contains("\"permission.ask\""));
    assert!(opencode.contains("\"command.execute.before\""));
    assert!(opencode.contains("type: \"connector.probe\""));
    assert!(opencode.contains("\"chat.message\""));
    assert!(opencode.contains("message.assistant"));
    assert!(opencode.contains("const MAX_PENDING_DELIVERIES = 96"));
    assert!(opencode.contains("async function drainDeliveriesForDispose()"));
    assert!(opencode.contains("await forward({"));
    assert!(!opencode.contains("child.unref"));
    assert!(!opencode.contains("session.done"));
    assert!(!opencode.contains("tool.execute.failed"));
    assert!(!opencode.contains("output?.error"));
}

#[test]
fn connector_diagnostics_survive_allowlisting_without_raw_payloads() {
    let pi = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "before_agent_start",
            "session_id": "pi-diagnostic",
            "diagnostic": true,
            "secret": "must-not-cross"
        }),
    )
    .unwrap()
    .unwrap();
    assert!(pi.diagnostic);

    let opencode = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "session.created",
            "properties": {
                "sessionID": "opencode-diagnostic",
                "diagnostic": true
            },
            "secret": "must-not-cross"
        }),
    )
    .unwrap()
    .unwrap();
    assert!(opencode.diagnostic);
    assert!(!opencode.affects_activity);
    assert!(!serde_json::to_string(&(pi, opencode))
        .unwrap()
        .contains("must-not-cross"));
}

#[test]
fn every_cli_connector_exposes_display_and_navigation_lifecycle_fields() {
    let pi_prompt = parse_contract_event(
        AgentSource::Pi,
        &serde_json::json!({
            "type": "before_agent_start",
            "session_id": "pi-display",
            "session_title": "Pi title",
            "message_content": "Pi user prompt"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(pi_prompt.session_title.as_deref(), Some("Pi title"));
    assert_eq!(pi_prompt.message_role.as_deref(), Some("user"));
    assert_eq!(pi_prompt.message_content.as_deref(), Some("Pi user prompt"));

    let opencode_reply = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "message.assistant",
            "properties": {
                "sessionID": "oc-display",
                "session_title": "OpenCode title",
                "message_content": "OpenCode assistant reply"
            }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(
        opencode_reply.session_title.as_deref(),
        Some("OpenCode title")
    );
    assert_eq!(opencode_reply.message_role.as_deref(), Some("assistant"));
    assert_eq!(
        opencode_reply.message_content.as_deref(),
        Some("OpenCode assistant reply")
    );
    assert_eq!(opencode_reply.kind, AgentEventType::Start);
    assert!(opencode_reply.session_active);

    let question = parse_contract_event(
        AgentSource::Opencode,
        &serde_json::json!({
            "type": "question.asked",
            "properties": { "sessionID": "oc-display" }
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(question.kind, AgentEventType::Waiting);
    assert_eq!(question.interaction_kind.as_deref(), Some("input_required"));

    let claude_closed = parse_contract_event(
        AgentSource::ClaudeCode,
        &serde_json::json!({
            "hook_event_name": "SessionEnd",
            "session_id": "claude-display",
            "cwd": "/tmp/project"
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(claude_closed.outcome.as_deref(), Some("session_closed"));
    assert_eq!(claude_closed.session_open, Some(true));
}
