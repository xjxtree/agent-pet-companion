use crate::{
    event_envelope::{MAX_PROJECT_LABEL_BYTES, MAX_SESSION_TITLE_BYTES},
    PetCoreError, Result,
};
use petcore_types::{AgentEventType, AgentSource};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

pub const CODEX_HOOKS_CONTRACT_VERSION: &str = "codex-hooks-2026-07-17-schema-v6";
pub const CLAUDE_HOOKS_CONTRACT_VERSION: &str = "claude-hooks-2026-07-17-activity-v5";
pub const PI_EXTENSION_CONTRACT_VERSION: &str = "pi-extension-0.80.10-activity-v7";
pub const OPENCODE_CONTRACT_VERSION: &str = "opencode-v1.18.0-activity-v8";
const MAX_MESSAGE_BYTES: usize = 4_096;
const MAX_IDENTITY_BYTES: usize = 256;

/// The complete set of adapter fields allowed to cross into PetCore. Raw hook
/// payloads, tool arguments, commands, tool output, transcripts, and errors are
/// intentionally absent. User prompts and final assistant messages are copied
/// only through the bounded, display-only fields below.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ContractEvent {
    pub source: AgentSource,
    /// Stable one-way identity derived from an official opaque tool-call ID.
    /// The raw invocation ID never crosses the adapter boundary.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub external_event_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub kind: AgentEventType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    pub source_event: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contract_version: Option<String>,
    pub diagnostic: bool,
    pub affects_activity: bool,
    pub session_active: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity_kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity_content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interaction_kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_open: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_surface: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_open_url: Option<String>,
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
    let (kind, outcome, session_active) = match event {
        // Opening or resuming the host is not user work. Waiting for
        // UserPromptSubmit also prevents short-lived internal background
        // sessions from flashing in the overlay before they can be classified.
        "SessionStart" => return Ok(None),
        "UserPromptSubmit" => (AgentEventType::Start, "started", true),
        "PreToolUse" => (AgentEventType::Tool, "started", true),
        "PermissionRequest" => (AgentEventType::Waiting, "permission_requested", true),
        // A completed tool call proves tool activity, not a user-review state.
        "PostToolUse" => (AgentEventType::Tool, "completed", true),
        "PreCompact" => (AgentEventType::Start, "started", true),
        "PostCompact" => (AgentEventType::Start, "completed", true),
        "SubagentStart" => (AgentEventType::Tool, "started", true),
        "SubagentStop" => (AgentEventType::Start, "completed", true),
        "Stop" => (AgentEventType::Done, "completed", false),
        _ => return Ok(None),
    };
    let mut contract = contract_event(
        source,
        string_at(input, &[&["session_id"]]),
        event,
        kind,
        string_at(input, &[&["tool_name"]]),
        outcome,
        session_active,
    );
    // Hook delivery proves that a Codex process ran, but it does not prove the
    // session has a persisted rollout that `codex://threads/<id>` can open.
    // App Server thread/list + thread/read events set this to true only after
    // the task is confirmed as a durable desktop thread.
    contract.session_open = None;
    contract.turn_id = bounded_string_at(input, &[&["turn_id"]], MAX_IDENTITY_BYTES);
    contract.diagnostic = bool_at(input, &[&["diagnostic"]]);
    contract.project_label = project_label(input);
    contract.activity_kind = match event {
        "UserPromptSubmit" | "PostToolUse" | "PostCompact" | "SubagentStop" => {
            Some("thinking".to_string())
        }
        "PreToolUse" => Some(activity_kind_for_tool(contract.tool_name.as_deref())),
        "PreCompact" => Some("compaction".to_string()),
        "SubagentStart" => Some("subagent".to_string()),
        _ => None,
    };
    match event {
        "UserPromptSubmit" => {
            contract.message_role = Some("user".to_string());
            contract.message_content = display_message_at(input, &[&["prompt"]]);
        }
        "PermissionRequest" => {
            contract.interaction_kind = Some("approval_required".to_string());
        }
        "Stop" => {
            contract.message_role = Some("assistant".to_string());
            contract.message_content = display_message_at(input, &[&["last_assistant_message"]]);
        }
        _ => {}
    }
    assign_opaque_invocation_event_id(&mut contract, input);
    Ok(Some(contract))
}

fn parse_claude(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = hook_name(input)?;
    let notification_type = string_at(input, &[&["notification_type"]]);
    let stop_has_background_work =
        event == "Stop" && nonempty_value_at(input, &[&["background_tasks"], &["session_crons"]]);
    let (kind, outcome, session_active) = match event {
        "SessionStart"
        | "Setup"
        | "InstructionsLoaded"
        | "UserPromptExpansion"
        | "TeammateIdle"
        | "ConfigChange"
        | "CwdChanged"
        | "WorktreeRemove" => (AgentEventType::Start, "observed", false),
        "UserPromptSubmit" => (AgentEventType::Start, "started", true),
        "PreToolUse" => (AgentEventType::Tool, "started", true),
        "PermissionRequest" => (AgentEventType::Waiting, "permission_requested", true),
        "PostToolUse" => (AgentEventType::Tool, "completed", true),
        // A failed tool call is fed back to Claude and the agent can recover.
        // Only StopFailure proves that the turn itself is blocked.
        "PostToolUseFailure" => (AgentEventType::Tool, "tool_failure", true),
        "PostToolBatch" => (AgentEventType::Start, "completed", true),
        "PermissionDenied" => (AgentEventType::Tool, "auto_denied", true),
        "PreCompact" => (AgentEventType::Start, "started", true),
        "PostCompact" => (AgentEventType::Start, "completed", true),
        "SubagentStart" | "TaskCreated" => (AgentEventType::Tool, "started", true),
        "SubagentStop" | "TaskCompleted" => (AgentEventType::Start, "completed", true),
        "Stop" if stop_has_background_work => (AgentEventType::Start, "background_active", true),
        "Stop" => (AgentEventType::Done, "completed", false),
        "StopFailure" => (AgentEventType::Failed, "api_failure", false),
        // Claude emits idle_prompt after a completed turn when the terminal is
        // simply sitting at the prompt. It is a ready/idle signal, not a request
        // for approval or an answer from the user.
        "Notification" if notification_type.as_deref() == Some("idle_prompt") => {
            (AgentEventType::Done, "idle", false)
        }
        "Notification"
            if notification_type.as_deref().is_some_and(|kind| {
                matches!(
                    kind,
                    "permission_prompt" | "elicitation_dialog" | "agent_needs_input"
                )
            }) =>
        {
            (AgentEventType::Waiting, "input_requested", true)
        }
        "Notification"
            if notification_type.as_deref().is_some_and(|kind| {
                matches!(kind, "elicitation_complete" | "elicitation_response")
            }) =>
        {
            (AgentEventType::Tool, "permission_replied", true)
        }
        "Notification" if notification_type.as_deref() == Some("agent_completed") => {
            (AgentEventType::Done, "agent_completed", false)
        }
        "Notification" if notification_type.as_deref() == Some("auth_success") => {
            (AgentEventType::Start, "observed", false)
        }
        "Elicitation" => (AgentEventType::Waiting, "input_requested", true),
        "ElicitationResult" => (AgentEventType::Tool, "permission_replied", true),
        "SessionEnd" => (AgentEventType::Done, "session_closed", false),
        _ => return Ok(None),
    };
    let mut contract = contract_event(
        source,
        string_at(input, &[&["session_id"]]),
        event,
        kind,
        string_at(input, &[&["tool_name"]]),
        outcome,
        session_active,
    );
    contract.turn_id =
        bounded_string_at(input, &[&["prompt_id"], &["turn_id"]], MAX_IDENTITY_BYTES);
    contract.diagnostic = bool_at(input, &[&["diagnostic"]]);
    contract.affects_activity = !(matches!(
        event,
        "SessionStart"
            | "Setup"
            | "InstructionsLoaded"
            | "UserPromptExpansion"
            | "TeammateIdle"
            | "ConfigChange"
            | "CwdChanged"
            | "WorktreeRemove"
    ) || (event == "Notification"
        && notification_type.as_deref() == Some("auth_success")));
    contract.project_label = project_label(input);
    contract.session_title = session_title(input);
    // SessionEnd closes a Claude process, but the durable conversation remains
    // resumable with `claude --resume <session-id>`.
    contract.session_open = Some(true);
    contract.activity_kind = match event {
        "UserPromptSubmit" | "PostToolUse" | "PostToolUseFailure" | "PostToolBatch"
        | "PermissionDenied" | "PostCompact" | "SubagentStop" | "TaskCompleted"
        | "ElicitationResult" => Some("thinking".to_string()),
        "Notification"
            if notification_type.as_deref().is_some_and(|kind| {
                matches!(kind, "elicitation_complete" | "elicitation_response")
            }) =>
        {
            Some("thinking".to_string())
        }
        "PreToolUse" => Some(activity_kind_for_tool(contract.tool_name.as_deref())),
        "PreCompact" => Some("compaction".to_string()),
        "SubagentStart" | "TaskCreated" => Some("subagent".to_string()),
        _ => None,
    };
    match event {
        "UserPromptSubmit" => {
            contract.message_role = Some("user".to_string());
            contract.message_content = display_message_at(input, &[&["prompt"]]);
        }
        "PermissionRequest" => {
            contract.interaction_kind = Some("approval_required".to_string());
        }
        "Notification"
            if notification_type.as_deref().is_some_and(|kind| {
                matches!(
                    kind,
                    "permission_prompt" | "elicitation_dialog" | "agent_needs_input"
                )
            }) =>
        {
            contract.interaction_kind = Some("input_required".to_string());
        }
        "Elicitation" => {
            contract.interaction_kind = Some("input_required".to_string());
        }
        "Stop" => {
            contract.message_role = Some("assistant".to_string());
            contract.message_content = display_message_at(input, &[&["last_assistant_message"]]);
        }
        _ => {}
    }
    assign_opaque_invocation_event_id(&mut contract, input);
    Ok(Some(contract))
}

fn parse_pi(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = event_type(input)?;
    let agent_error = bool_at(input, &[&["agent_error"]]);
    let (kind, outcome, session_active) = match event {
        // Opening or resuming a Pi page does not mean the agent is working.
        "session_start" => return Ok(None),
        "input" | "before_agent_start" | "agent_start" | "turn_start" => {
            (AgentEventType::Start, "started", true)
        }
        "turn_end" => (AgentEventType::Start, "completed", true),
        "tool_call" | "tool_execution_start" => (AgentEventType::Tool, "started", true),
        "tool_execution_end" if bool_at(input, &[&["isError"], &["is_error"]]) => {
            // Pi's isError belongs to one tool result. The agent loop may recover,
            // call another tool, and still produce a normal assistant response.
            (AgentEventType::Tool, "tool_failure", true)
        }
        "tool_execution_end" => (AgentEventType::Tool, "completed", true),
        // Pi exposes each finalized AgentMessage through message_end. Capturing
        // assistant text here avoids depending on a later lifecycle event.
        "message_end" => (AgentEventType::Start, "message", true),
        // agent_end can be followed by an automatic retry, compaction, or a
        // queued continuation. Only agent_settled is a stable terminal edge.
        "agent_end" if agent_error => (AgentEventType::Start, "retry", true),
        "agent_end" => (AgentEventType::Start, "completed", true),
        "agent_settled" if agent_error => (AgentEventType::Failed, "api_failure", false),
        "agent_settled" => (AgentEventType::Done, "settled", false),
        "session_before_compact" => (AgentEventType::Start, "started", true),
        "session_compact" => (AgentEventType::Start, "completed", true),
        "session_shutdown" => (AgentEventType::Done, "session_closed", false),
        "connector.probe" => (AgentEventType::Start, "observed", false),
        _ => return Ok(None),
    };
    let mut contract = contract_event(
        source,
        string_at(input, &[&["session_id"], &["sessionId"]]),
        event,
        kind,
        string_at(input, &[&["toolName"], &["tool_name"]]),
        outcome,
        session_active,
    );
    contract.turn_id = bounded_string_at(input, &[&["turn_id"], &["turnId"]], MAX_IDENTITY_BYTES);
    contract.diagnostic = bool_at(input, &[&["diagnostic"]]);
    contract.affects_activity = event != "connector.probe";
    contract.session_title = session_title(input);
    contract.session_open = Some(event != "session_shutdown");
    contract.activity_kind = match event {
        "input" | "before_agent_start" | "agent_start" | "turn_start" | "turn_end"
        | "tool_execution_end" | "session_compact" => Some("thinking".to_string()),
        "tool_call" | "tool_execution_start" => {
            Some(activity_kind_for_tool(contract.tool_name.as_deref()))
        }
        "session_before_compact" => Some("compaction".to_string()),
        _ => None,
    };
    match event {
        "input" | "before_agent_start" => {
            contract.message_role = Some("user".to_string());
            contract.message_content =
                display_message_at(input, &[&["text"], &["prompt"], &["message_content"]]);
        }
        "message_end" | "agent_end" | "agent_settled" => {
            contract.message_content =
                display_message_at(input, &[&["message_content"], &["last_assistant_message"]]);
            if contract.message_content.is_some() {
                contract.message_role = Some("assistant".to_string());
            }
        }
        _ => {}
    }
    assign_opaque_invocation_event_id(&mut contract, input);
    Ok(Some(contract))
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
    // Every accepted OpenCode event is session-scoped. Some SDK lifecycle
    // shapes make the identity optional, but an unattributed event must never
    // create or close a synthetic global session when the CLI is invoked
    // directly and bypasses the Plugin's first-line guard.
    if session_id.is_none() {
        return Ok(None);
    }

    let (kind, outcome, session_active) = match event {
        "session.created" => (AgentEventType::Start, "created".to_string(), false),
        "session.deleted" => (AgentEventType::Done, "session_closed".to_string(), false),
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
                Some("idle") => (AgentEventType::Done, "idle".to_string(), false),
                Some("busy") => (AgentEventType::Start, "busy".to_string(), true),
                Some("retry") => (AgentEventType::Start, "retry".to_string(), true),
                _ => return Ok(None),
            }
        }
        "session.idle" => (AgentEventType::Done, "idle".to_string(), false),
        "session.error" => (AgentEventType::Failed, "session_failure".to_string(), false),
        "session.next.step.failed" => {
            (AgentEventType::Failed, "session_failure".to_string(), false)
        }
        "session.next.step.ended" => {
            let normalized_outcome = string_at(input, &[&["outcome"]]);
            let finish = string_at(input, &[&["properties", "finish"], &["finish"]]);
            match normalized_outcome.as_deref() {
                Some("continued") => (AgentEventType::Start, "continued".to_string(), true),
                Some("completed") => (AgentEventType::Done, "completed".to_string(), false),
                Some("session_failure") => {
                    (AgentEventType::Failed, "session_failure".to_string(), false)
                }
                _ => match finish.as_deref() {
                    Some("tool-calls" | "tool_calls" | "tool_use") => {
                        (AgentEventType::Start, "continued".to_string(), true)
                    }
                    Some("stop" | "length" | "other" | "unknown") => {
                        (AgentEventType::Done, "completed".to_string(), false)
                    }
                    Some("content-filter" | "error") => {
                        (AgentEventType::Failed, "session_failure".to_string(), false)
                    }
                    _ => return Ok(None),
                },
            }
        }
        "permission.asked" | "permission.updated" | "permission.v2.asked" => (
            AgentEventType::Waiting,
            "permission_requested".to_string(),
            true,
        ),
        "permission.replied" | "permission.v2.replied" => {
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
            (AgentEventType::Tool, outcome, true)
        }
        "question.asked" | "question.v2.asked" => {
            (AgentEventType::Waiting, "input_requested".to_string(), true)
        }
        "question.replied"
        | "question.rejected"
        | "question.v2.replied"
        | "question.v2.rejected" => (AgentEventType::Tool, "permission_replied".to_string(), true),
        "session.next.prompt.admitted" => {
            (AgentEventType::Start, "prompt_admitted".to_string(), true)
        }
        "message.user" => (AgentEventType::Start, "message".to_string(), true),
        // The assistant text can complete before OpenCode declares the session
        // idle. Keep Running until session.idle/session.status(idle).
        "message.assistant" => (AgentEventType::Start, "message".to_string(), true),
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
                true,
            )
        }
        "tool.execute.after" if bool_at(input, &[&["is_error"], &["isError"]]) => {
            (AgentEventType::Tool, "tool_failure".to_string(), true)
        }
        "tool.execute.after" => (AgentEventType::Tool, "completed".to_string(), true),
        "command.execute.before" => (AgentEventType::Tool, "started".to_string(), true),
        "command.execute.after" => (AgentEventType::Tool, "completed".to_string(), true),
        "session.compaction.started" => (AgentEventType::Start, "started".to_string(), true),
        "session.compaction.ended" => (AgentEventType::Start, "completed".to_string(), true),
        "session.plan.updated" => (AgentEventType::Start, "observed".to_string(), true),
        "connector.probe" => (AgentEventType::Start, "observed".to_string(), false),
        // Metadata-only updates do not prove that work started or completed.
        "session.updated" => return Ok(None),
        _ => return Ok(None),
    };

    let message_role = match event {
        "message.user" => Some("user".to_string()),
        "message.assistant" => Some("assistant".to_string()),
        _ => None,
    };
    let message_content = message_role.as_ref().and_then(|_| {
        display_message_at(
            input,
            &[
                &["message_content"],
                &["properties", "message_content"],
                &["properties", "content"],
            ],
        )
    });

    let activity_kind = match event {
        "session.next.step.ended" if kind == AgentEventType::Start => Some("thinking".to_string()),
        "session.status"
        | "session.next.prompt.admitted"
        | "message.user"
        | "tool.execute.after"
        | "permission.replied"
        | "permission.v2.replied"
        | "question.replied"
        | "question.rejected"
        | "question.v2.replied"
        | "question.v2.rejected" => Some("thinking".to_string()),
        "tool.execute.before" | "command.execute.before" => {
            Some(activity_kind_for_tool(tool_name.as_deref()))
        }
        "session.compaction.started" | "session.compaction.ended" => Some("compaction".to_string()),
        "session.plan.updated" => Some("plan".to_string()),
        _ => None,
    };

    let mut contract = ContractEvent {
        source,
        external_event_id: None,
        session_id,
        kind,
        tool_name,
        outcome: Some(outcome),
        source_event: event.to_string(),
        contract_version: Some(OPENCODE_CONTRACT_VERSION.to_string()),
        diagnostic: bool_at(
            input,
            &[
                &["diagnostic"],
                &["properties", "diagnostic"],
                &["event", "properties", "diagnostic"],
            ],
        ),
        // Creating an empty session is passive metadata. A close edge must
        // remain activity-affecting so it supersedes older work in that same
        // session; canonical projection suppresses close-only sessions that
        // never had a user activation.
        affects_activity: !matches!(event, "connector.probe" | "session.created"),
        session_active,
        turn_id: bounded_string_at(input, &[&["turn_id"], &["turnID"]], MAX_IDENTITY_BYTES),
        message_role,
        message_content,
        activity_kind,
        activity_content: None,
        interaction_kind: match event {
            "question.asked" | "question.v2.asked" => Some("input_required".to_string()),
            _ if kind == AgentEventType::Waiting => Some("approval_required".to_string()),
            _ => None,
        },
        project_label: project_label(input),
        session_title: session_title(input),
        session_open: Some(event != "session.deleted"),
        session_surface: None,
        terminal_app: None,
        session_open_url: None,
    };
    assign_opaque_invocation_event_id(&mut contract, input);
    Ok(Some(contract))
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
    source_event: &str,
    kind: AgentEventType,
    tool_name: Option<String>,
    outcome: &str,
    session_active: bool,
) -> ContractEvent {
    ContractEvent {
        source,
        external_event_id: None,
        session_id,
        kind,
        tool_name,
        outcome: Some(outcome.to_string()),
        source_event: source_event.to_string(),
        contract_version: Some(contract_version(source).to_string()),
        diagnostic: false,
        affects_activity: true,
        session_active,
        turn_id: None,
        message_role: None,
        message_content: None,
        activity_kind: None,
        activity_content: None,
        interaction_kind: (kind == AgentEventType::Waiting)
            .then(|| "approval_required".to_string()),
        project_label: None,
        session_title: None,
        session_open: Some(true),
        session_surface: None,
        terminal_app: None,
        session_open_url: None,
    }
}

fn contract_version(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => CODEX_HOOKS_CONTRACT_VERSION,
        AgentSource::ClaudeCode => CLAUDE_HOOKS_CONTRACT_VERSION,
        AgentSource::Pi => PI_EXTENSION_CONTRACT_VERSION,
        AgentSource::Opencode => OPENCODE_CONTRACT_VERSION,
    }
}

fn assign_opaque_invocation_event_id(contract: &mut ContractEvent, input: &Value) {
    let Some(invocation_id) = string_at(
        input,
        &[
            &["tool_use_id"],
            &["toolUseId"],
            &["tool_call_id"],
            &["toolCallId"],
            &["call_id"],
            &["callID"],
            &["input", "tool_use_id"],
            &["input", "toolUseId"],
            &["input", "tool_call_id"],
            &["input", "toolCallId"],
            &["input", "call_id"],
            &["input", "callID"],
            &["eventID"],
        ],
    ) else {
        return;
    };

    let mut digest = Sha256::new();
    digest.update(b"apc.hook-invocation-event.v1");
    hash_identity_component(&mut digest, source_identity(contract.source));
    hash_identity_component(
        &mut digest,
        contract.session_id.as_deref().unwrap_or_default(),
    );
    hash_identity_component(&mut digest, contract.turn_id.as_deref().unwrap_or_default());
    hash_identity_component(&mut digest, &contract.source_event);
    hash_identity_component(&mut digest, invocation_id.trim());
    contract.external_event_id = Some(format!("evt_hook_{:x}", digest.finalize()));
}

fn hash_identity_component(digest: &mut Sha256, value: &str) {
    digest.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    digest.update(value.as_bytes());
}

fn source_identity(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "codex",
        AgentSource::ClaudeCode => "claude_code",
        AgentSource::Pi => "pi",
        AgentSource::Opencode => "opencode",
    }
}

fn activity_kind_for_tool(tool_name: Option<&str>) -> String {
    let name = tool_name.unwrap_or_default().trim().to_ascii_lowercase();
    match name.as_str() {
        "bash" | "shell" | "terminal" | "command" | "cmd" | "powershell" => "command",
        "read" | "write" | "file" | "files" | "filesystem" | "ls" | "glob" => "file",
        "edit" | "patch" | "apply_patch" | "replace" => "file_change",
        "grep" | "rg" | "find" | "search" | "code_search" => "search",
        "web" | "http" | "fetch" | "browser" | "curl" | "wget" => "network",
        "task" | "agent" | "subagent" => "subagent",
        _ => "tool",
    }
    .to_string()
}

fn session_title(value: &Value) -> Option<String> {
    bounded_string_at(
        value,
        &[
            &["session_title"],
            &["sessionTitle"],
            &["title"],
            &["properties", "session_title"],
            &["properties", "info", "title"],
        ],
        MAX_SESSION_TITLE_BYTES,
    )
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

fn bounded_string_at(value: &Value, paths: &[&[&str]], maximum_bytes: usize) -> Option<String> {
    string_at(value, paths).map(|value| truncate_utf8(value.trim(), maximum_bytes))
}

fn display_message_at(value: &Value, paths: &[&[&str]]) -> Option<String> {
    let raw = string_at(value, paths)?;
    let sanitized = raw
        .chars()
        .map(|character| match character {
            '\n' | '\t' => character,
            character if character.is_control() => ' ',
            character => character,
        })
        .collect::<String>();
    let trimmed = sanitized.trim();
    (!trimmed.is_empty()).then(|| truncate_utf8(trimmed, MAX_MESSAGE_BYTES))
}

fn project_label(value: &Value) -> Option<String> {
    let cwd = string_at(value, &[&["cwd"]])?;
    let label = Path::new(&cwd).file_name()?.to_str()?.trim();
    (!label.is_empty()).then(|| truncate_utf8(label, MAX_PROJECT_LABEL_BYTES))
}

fn truncate_utf8(value: &str, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value.to_string();
    }
    let mut end = maximum_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
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

fn nonempty_value_at(value: &Value, paths: &[&[&str]]) -> bool {
    paths.iter().any(|path| {
        let mut current = value;
        for segment in *path {
            let Some(next) = current.get(*segment) else {
                return false;
            };
            current = next;
        }
        match current {
            Value::Array(values) => !values.is_empty(),
            Value::Object(values) => !values.is_empty(),
            Value::String(value) => !value.trim().is_empty(),
            Value::Bool(value) => *value,
            Value::Number(value) => value.as_u64().is_some_and(|value| value > 0),
            Value::Null => false,
        }
    })
}
