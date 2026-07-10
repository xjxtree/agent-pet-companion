use crate::{PetCoreError, Result};
use petcore_types::{AgentEventType, AgentSource};
use serde::Serialize;
use serde_json::Value;

pub const CODEX_HOOKS_CONTRACT_VERSION: &str = "codex-hooks-2026-07-10";
pub const CLAUDE_HOOKS_CONTRACT_VERSION: &str = "claude-hooks-2026-07-10";
pub const PI_EXTENSION_CONTRACT_VERSION: &str = "pi-extension-34582ef3";
pub const OPENCODE_CONTRACT_VERSION: &str = "opencode-v1.17.18";

/// The complete set of adapter fields allowed to cross into PetCore. Raw hook
/// payloads, tool arguments, commands, model output, prompts, and errors are
/// intentionally absent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ContractEvent {
    pub source: AgentSource,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub kind: AgentEventType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
}

pub fn parse_contract_event(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    if !input.is_object() {
        return Err(PetCoreError::InvalidRequest(
            "agent hook payload must be a JSON object".to_string(),
        ));
    }

    match source {
        AgentSource::Codex => parse_codex(source, input),
        AgentSource::ClaudeCode => parse_claude(source, input),
        AgentSource::Pi => parse_pi(source, input),
        AgentSource::Opencode => parse_opencode(source, input),
    }
}

fn parse_codex(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = hook_name(input)?;
    let (kind, outcome) = match event {
        "SessionStart" | "UserPromptSubmit" => (AgentEventType::Start, "started"),
        "PreToolUse" => (AgentEventType::Tool, "started"),
        "PermissionRequest" => (AgentEventType::Waiting, "permission_requested"),
        // A completed tool call proves tool activity, not a user-review state.
        "PostToolUse" => (AgentEventType::Tool, "completed"),
        "Stop" => (AgentEventType::Done, "completed"),
        _ => return Ok(None),
    };
    Ok(Some(contract_event(
        source,
        string_at(input, &[&["session_id"]]),
        kind,
        string_at(input, &[&["tool_name"]]),
        outcome,
    )))
}

fn parse_claude(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = hook_name(input)?;
    let (kind, outcome) = match event {
        "SessionStart" | "UserPromptSubmit" => (AgentEventType::Start, "started"),
        "PreToolUse" => (AgentEventType::Tool, "started"),
        "PermissionRequest" => (AgentEventType::Waiting, "permission_requested"),
        "PostToolUse" => (AgentEventType::Tool, "completed"),
        "PostToolUseFailure" => (AgentEventType::Failed, "tool_failure"),
        "Stop" => (AgentEventType::Done, "completed"),
        "StopFailure" => (AgentEventType::Failed, "api_failure"),
        _ => return Ok(None),
    };
    Ok(Some(contract_event(
        source,
        string_at(input, &[&["session_id"]]),
        kind,
        string_at(input, &[&["tool_name"]]),
        outcome,
    )))
}

fn parse_pi(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = event_type(input)?;
    let (kind, outcome) = match event {
        "session_start" | "before_agent_start" | "agent_start" => {
            (AgentEventType::Start, "started")
        }
        "tool_call" | "tool_execution_start" => (AgentEventType::Tool, "started"),
        "tool_execution_end" if bool_at(input, &[&["isError"], &["is_error"]]) => {
            (AgentEventType::Failed, "tool_failure")
        }
        "tool_execution_end" => (AgentEventType::Tool, "completed"),
        "agent_settled" => (AgentEventType::Done, "settled"),
        // shutdown may mean reload/new/resume/fork and is never a completion signal.
        "session_shutdown" | "agent_end" => return Ok(None),
        _ => return Ok(None),
    };
    Ok(Some(contract_event(
        source,
        string_at(input, &[&["session_id"], &["sessionId"]]),
        kind,
        string_at(input, &[&["toolName"], &["tool_name"]]),
        outcome,
    )))
}

fn parse_opencode(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = event_type(input)?;
    let session_id = string_at(
        input,
        &[
            &["properties", "sessionID"],
            &["properties", "info", "id"],
            &["event", "properties", "sessionID"],
            &["event", "properties", "info", "id"],
            &["input", "sessionID"],
            &["session_id"],
        ],
    );
    let tool_name = string_at(input, &[&["input", "tool"], &["tool_name"]]);

    let (kind, outcome) = match event {
        "session.created" => (AgentEventType::Start, "created".to_string()),
        "session.status" => {
            let status = string_at(
                input,
                &[
                    &["properties", "status", "type"],
                    &["properties", "status"],
                    &["event", "properties", "status", "type"],
                ],
            );
            match status.as_deref() {
                Some("idle") => (AgentEventType::Done, "idle".to_string()),
                Some("busy") => (AgentEventType::Start, "busy".to_string()),
                Some("retry") => (AgentEventType::Start, "retry".to_string()),
                _ => return Ok(None),
            }
        }
        "session.idle" => (AgentEventType::Done, "idle".to_string()),
        "session.error" => (AgentEventType::Failed, "session_failure".to_string()),
        "permission.asked" | "permission.updated" => {
            (AgentEventType::Waiting, "permission_requested".to_string())
        }
        "permission.replied" => {
            let response = string_at(
                input,
                &[
                    &["properties", "response"],
                    &["event", "properties", "response"],
                ],
            );
            let outcome = match response.as_deref() {
                Some("once" | "always" | "allow" | "deny" | "reject") => {
                    format!(
                        "permission_replied_{}",
                        response.as_deref().unwrap_or_default()
                    )
                }
                _ => "permission_replied".to_string(),
            };
            (AgentEventType::Tool, outcome)
        }
        "tool.execute.before" => {
            let supplied = input
                .get("output")
                .and_then(|value| value.get("args"))
                .is_some()
                || input.get("outcome").and_then(Value::as_str) == Some("started");
            (
                AgentEventType::Tool,
                if supplied {
                    "started".to_string()
                } else {
                    "started_without_args".to_string()
                },
            )
        }
        "tool.execute.after" => (AgentEventType::Tool, "completed".to_string()),
        // Metadata-only updates do not prove that work started or completed.
        "session.updated" => return Ok(None),
        _ => return Ok(None),
    };

    Ok(Some(ContractEvent {
        source,
        session_id,
        kind,
        tool_name,
        outcome: Some(outcome),
    }))
}

fn hook_name(input: &Value) -> Result<&str> {
    input
        .get("hook_event_name")
        .or_else(|| input.get("type"))
        .and_then(Value::as_str)
        .ok_or_else(|| PetCoreError::InvalidRequest("hook event name is missing".to_string()))
}

fn event_type(input: &Value) -> Result<&str> {
    input
        .get("type")
        .or_else(|| input.get("event").and_then(|event| event.get("type")))
        .and_then(Value::as_str)
        .ok_or_else(|| PetCoreError::InvalidRequest("adapter event type is missing".to_string()))
}

fn contract_event(
    source: AgentSource,
    session_id: Option<String>,
    kind: AgentEventType,
    tool_name: Option<String>,
    outcome: &str,
) -> ContractEvent {
    ContractEvent {
        source,
        session_id,
        kind,
        tool_name,
        outcome: Some(outcome.to_string()),
    }
}

fn string_at(value: &Value, paths: &[&[&str]]) -> Option<String> {
    paths.iter().find_map(|path| {
        let mut current = value;
        for segment in *path {
            current = current.get(*segment)?;
        }
        current
            .as_str()
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn bool_at(value: &Value, paths: &[&[&str]]) -> bool {
    paths.iter().any(|path| {
        let mut current = value;
        for segment in *path {
            let Some(next) = current.get(*segment) else {
                return false;
            };
            current = next;
        }
        current.as_bool() == Some(true)
    })
}
