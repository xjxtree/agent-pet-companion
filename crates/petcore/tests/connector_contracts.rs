use petcore::adapter_contracts::parse_contract_event;
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
fn codex_and_claude_official_hooks_map_without_raw_payload() {
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
    for secret in ["TOKEN=", "command", "tool_input", "tool_response", "error"] {
        assert!(!serialized.contains(secret), "raw field leaked: {secret}");
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
    assert_eq!(end.kind, AgentEventType::Done);
    assert!(!end.session_active);
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
    assert!(claude.contains("\"async\":true"));
    assert!(claude.contains("\"timeout\":5"));

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
    assert!(pi.contains("pi-extension-20260714-message-v5"));
    assert!(pi.contains("pi.on(\"input\""));
    assert!(pi.contains("await sendEvent(allowlisted)"));
    assert!(pi.contains("turn_id: activeTurnIds.get(id)"));
    assert!(pi.contains("event?.isError === true"));
    assert!(pi.contains("assistant?.stopReason === \"error\""));
    assert!(pi.contains("agent_error: agentError"));
    assert!(pi.contains("diagnostic: event?.diagnostic === true"));
    assert!(pi.contains("structured-extension-events"));
    assert!(pi.contains("pi.on(\"agent_end\""));
    assert!(pi.contains("session_open: event?.type !== \"session_shutdown\""));

    let opencode =
        std::fs::read_to_string(root.join("plugins/opencode/agent-pet-companion.js.tpl")).unwrap();
    assert!(opencode.contains("opencode-v1.17.18-activity-v4"));
    assert!(opencode.contains("event?.properties"));
    assert!(opencode.contains("input?.sessionID"));
    assert!(opencode.contains("output?.args"));
    assert!(opencode.contains("diagnostic: properties?.diagnostic"));
    assert!(opencode.contains("diagnostic: input?.diagnostic"));
    assert!(opencode.contains("\"chat.message\""));
    assert!(opencode.contains("message.assistant"));
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
    assert_eq!(claude_closed.session_open, Some(false));
}
