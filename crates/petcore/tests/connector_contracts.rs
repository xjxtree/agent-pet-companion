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

    let post_tool = parsed(AgentSource::Codex, "codex/post_tool_use.json");
    assert_eq!(post_tool.kind, AgentEventType::Tool);
    assert_eq!(post_tool.tool_name.as_deref(), Some("Bash"));
    assert_eq!(post_tool.outcome.as_deref(), Some("completed"));

    let prompt = parsed(
        AgentSource::ClaudeCode,
        "claude-code/user_prompt_submit.json",
    );
    assert_eq!(prompt.kind, AgentEventType::Start);
    assert_eq!(prompt.session_id.as_deref(), Some("claude-session-prompt"));

    let tool_failure = parsed(
        AgentSource::ClaudeCode,
        "claude-code/post_tool_use_failure.json",
    );
    assert_eq!(tool_failure.kind, AgentEventType::Failed);
    assert_eq!(tool_failure.outcome.as_deref(), Some("tool_failure"));

    let api_failure = parsed(AgentSource::ClaudeCode, "claude-code/stop_failure.json");
    assert_eq!(api_failure.kind, AgentEventType::Failed);
    assert_eq!(api_failure.outcome.as_deref(), Some("api_failure"));

    let serialized =
        serde_json::to_string(&[stop, post_tool, prompt, tool_failure, api_failure]).unwrap();
    for secret in ["secret", "command", "tool_input", "tool_response", "error"] {
        assert!(!serialized.contains(secret), "raw field leaked: {secret}");
    }
}

#[test]
fn pi_uses_settled_and_is_error_without_treating_shutdown_as_done() {
    let settled = parsed(AgentSource::Pi, "pi/agent_settled.json");
    assert_eq!(settled.kind, AgentEventType::Done);
    assert_eq!(settled.session_id.as_deref(), Some("pi-session-settled"));

    let failed = parsed(AgentSource::Pi, "pi/tool_execution_end_error.json");
    assert_eq!(failed.kind, AgentEventType::Failed);
    assert_eq!(failed.tool_name.as_deref(), Some("bash"));
    assert_eq!(failed.outcome.as_deref(), Some("tool_failure"));
    assert!(!serde_json::to_string(&failed)
        .unwrap()
        .contains("pi-secret"));

    let shutdown =
        parse_contract_event(AgentSource::Pi, &fixture("pi/session_shutdown_reload.json")).unwrap();
    assert!(shutdown.is_none(), "reload shutdown must not become Done");
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
    assert!(pi.contains("event?.isError === true"));
    assert!(pi.contains("requires-interactive-extension-ui-bridge"));

    let opencode =
        std::fs::read_to_string(root.join("plugins/opencode/agent-pet-companion.js.tpl")).unwrap();
    assert!(opencode.contains("opencode-v1.17.18"));
    assert!(opencode.contains("event?.properties"));
    assert!(opencode.contains("input?.sessionID"));
    assert!(opencode.contains("output?.args"));
    assert!(!opencode.contains("session.done"));
    assert!(!opencode.contains("tool.execute.failed"));
    assert!(!opencode.contains("output?.error"));
}
