use crate::{
    agent_session_filters::AGENT_CHILD_SESSION_SOURCE_EVENT,
    diagnostics::{AgentParseFailure, AgentParseField, AgentParseWarning},
    event_envelope::{
        MAX_ACTIVITY_CONTENT_BYTES, MAX_PROJECT_LABEL_BYTES, MAX_SESSION_TITLE_BYTES,
    },
    PetCoreError, Result,
};
use petcore_types::{AgentEventType, AgentSource};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

pub const CODEX_HOOKS_CONTRACT_VERSION: &str = "codex-hooks-2026-08-01-events-v9";
pub const CLAUDE_HOOKS_CONTRACT_VERSION: &str = "claude-hooks-2026-08-01-events-v9";
pub const PI_EXTENSION_CONTRACT_VERSION: &str = "pi-extension-0.80.10-events-v15";
pub const OPENCODE_CONTRACT_VERSION: &str = "opencode-v1.18.4-events-v16";
pub const DSH_PLUGIN_CONTRACT_VERSION: &str = "dsh-v0.1.0-rc.6-events-v1";
const MAX_MESSAGE_BYTES: usize = 4_096;
const MAX_IDENTITY_BYTES: usize = 256;

/// The complete set of adapter fields allowed to cross into PetCore. Commands,
/// tool input/output, provider-visible reasoning, and raw activity details are
/// normalized into the bounded display-only `activity_content` field. Complete
/// transcripts, credential stores, auth headers, and environment dumps remain
/// outside the event contract; where a host names its own transcript and
/// delivers no message hook, only the same bounded display strings this struct
/// already carries may be recovered from it — see
/// [`claude_transcript_display`].
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

    if let Some(contract) = child_session_contract(source, input) {
        return Ok(Some(contract));
    }

    match source {
        AgentSource::Codex => parse_codex(source, input),
        AgentSource::ClaudeCode => parse_claude(source, input),
        AgentSource::Pi => parse_pi(source, input),
        AgentSource::Opencode => parse_opencode(source, input),
        // T2 lands the full dsh mapping; until then no dsh hook input is
        // recognized (fail-open no-op, never an error).
        AgentSource::Dsh => Ok(None),
    }
}

/// Returns bounded, content-free warnings for data that reached the adapter
/// boundary but could not be interpreted. These warnings are reported through
/// the dedicated diagnostics RPC and are never persisted with Agent events.
pub fn contract_parse_warnings(input: &Value, contract: &ContractEvent) -> Vec<AgentParseWarning> {
    const MAX_WARNINGS: usize = 8;
    let mut warnings = input
        .get("parse_warnings")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_WARNINGS)
        .filter_map(|warning| serde_json::from_value(warning.clone()).ok())
        .collect::<Vec<AgentParseWarning>>();

    for (paths, field) in [
        (
            &[&["session_id"][..], &["sessionId"][..]][..],
            AgentParseField::SessionId,
        ),
        (
            &[&["session_title"][..], &["sessionTitle"][..]][..],
            AgentParseField::SessionTitle,
        ),
        (
            &[&["tool_name"][..], &["toolName"][..]][..],
            AgentParseField::ToolName,
        ),
        (
            &[&["message_content"][..], &["last_assistant_message"][..]][..],
            AgentParseField::MessageContent,
        ),
        (
            &[&["activity_content"][..]][..],
            AgentParseField::ActivityContent,
        ),
    ] {
        if paths
            .iter()
            .find_map(|path| value_at(input, path))
            .is_some_and(|value| {
                !value.is_null() && !matches!(value, Value::String(text) if !text.trim().is_empty())
            })
        {
            push_parse_warning(
                &mut warnings,
                AgentParseWarning {
                    field,
                    failure: AgentParseFailure::InvalidType,
                },
                MAX_WARNINGS,
            );
        }
    }

    if matches!(contract.source, AgentSource::Pi)
        && matches!(
            contract.source_event.as_str(),
            "tool_call" | "tool_execution_start"
        )
        && contract.activity_content.is_none()
        && ["activity_content", "input", "args"]
            .into_iter()
            .any(|key| input.get(key).is_some_and(|value| !value.is_null()))
    {
        push_parse_warning(
            &mut warnings,
            AgentParseWarning {
                field: AgentParseField::ToolArguments,
                failure: AgentParseFailure::UnsupportedShape,
            },
            MAX_WARNINGS,
        );
    }

    warnings
}

fn push_parse_warning(
    warnings: &mut Vec<AgentParseWarning>,
    warning: AgentParseWarning,
    maximum: usize,
) {
    if warnings.len() < maximum && !warnings.contains(&warning) {
        warnings.push(warning);
    }
}

/// Converts only explicit host lineage into a suppression marker. Parent IDs
/// are correlation data: they are inspected locally but never cross the
/// normalized event boundary. Title text and display order are never used to
/// guess that a session is a child.
fn child_session_contract(source: AgentSource, input: &Value) -> Option<ContractEvent> {
    let source_event = input
        .get("type")
        .or_else(|| input.get("hook_event_name"))
        .and_then(Value::as_str);
    let explicit_marker = source_event == Some(AGENT_CHILD_SESSION_SOURCE_EVENT);
    let has_common_parent_identity = string_at(
        input,
        &[
            &["parent_session_id"],
            &["parentSessionID"],
            &["parent_thread_id"],
            &["parentThreadId"],
        ],
    )
    .is_some();
    // OpenCode message objects also have a parentID for message-chain
    // ancestry. Only Session lifecycle payloads carry Session.parentID.
    let has_opencode_parent_identity = source == AgentSource::Opencode
        && matches!(
            source_event,
            Some("session.created" | "session.updated" | "session.deleted")
        )
        && string_at(
            input,
            &[
                &["properties", "parentID"],
                &["properties", "info", "parentID"],
                &["event", "properties", "parentID"],
                &["event", "properties", "info", "parentID"],
            ],
        )
        .is_some();
    let is_sidechain = bool_at(
        input,
        &[
            &["isSidechain"],
            &["is_sidechain"],
            &["properties", "isSidechain"],
            &["properties", "info", "isSidechain"],
        ],
    );
    if !explicit_marker
        && !has_common_parent_identity
        && !has_opencode_parent_identity
        && !is_sidechain
    {
        return None;
    }

    let session_id = string_at(
        input,
        &[
            &["session_id"],
            &["sessionId"],
            &["thread_id"],
            &["threadId"],
            &["properties", "sessionID"],
            &["properties", "info", "id"],
            &["event", "properties", "sessionID"],
            &["event", "properties", "info", "id"],
            &["input", "sessionID"],
        ],
    )?;
    let mut contract = contract_event(
        source,
        Some(session_id),
        AGENT_CHILD_SESSION_SOURCE_EVENT,
        AgentEventType::Start,
        None,
        "suppressed",
        false,
    );
    contract.diagnostic = bool_at(
        input,
        &[
            &["diagnostic"],
            &["properties", "diagnostic"],
            &["properties", "info", "diagnostic"],
        ],
    );
    contract.affects_activity = false;
    contract.session_open = Some(false);
    assign_opaque_invocation_event_id(&mut contract, input);
    Some(contract)
}

fn parse_codex(source: AgentSource, input: &Value) -> Result<Option<ContractEvent>> {
    let event = hook_name(input)?;
    let (kind, outcome, session_active) = match event {
        // Opening or resuming the host is not user work, but its bounded
        // runtime-surface marker must remain durable so later App Server polls
        // cannot confuse a creation source with the current process host.
        "SessionStart" => (AgentEventType::Start, "observed", false),
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
    contract.affects_activity = !matches!(
        event,
        "SessionStart" | "PreCompact" | "PostCompact" | "SubagentStop"
    );
    contract.turn_id = bounded_string_at(input, &[&["turn_id"]], MAX_IDENTITY_BYTES);
    contract.diagnostic = bool_at(input, &[&["diagnostic"]]);
    contract.project_label = project_label(input);
    contract.activity_kind = match event {
        "PreToolUse" => Some(activity_kind_for_tool(contract.tool_name.as_deref())),
        "PreCompact" => Some("compaction".to_string()),
        "SubagentStart" => Some("subagent".to_string()),
        _ => None,
    };
    contract.activity_content = activity_content(event, input);
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
        "PostToolBatch" => (AgentEventType::Tool, "completed", true),
        "PermissionDenied" => (AgentEventType::Start, "auto_denied", true),
        "PreCompact" => (AgentEventType::Start, "started", true),
        "PostCompact" => (AgentEventType::Start, "completed", true),
        "SubagentStart" | "TaskCreated" => (AgentEventType::Tool, "started", true),
        "SubagentStop" | "TaskCompleted" => (AgentEventType::Tool, "completed", true),
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
            (AgentEventType::Start, "permission_replied", true)
        }
        "Notification" if notification_type.as_deref() == Some("agent_completed") => {
            (AgentEventType::Done, "agent_completed", false)
        }
        "Notification" if notification_type.as_deref() == Some("auth_success") => {
            (AgentEventType::Start, "observed", false)
        }
        "Elicitation" => (AgentEventType::Waiting, "input_requested", true),
        "ElicitationResult" => (AgentEventType::Start, "permission_replied", true),
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
            | "PreCompact"
            | "PostCompact"
    ) || (event == "Notification"
        && notification_type.as_deref() == Some("auth_success")));
    contract.project_label = project_label(input);
    contract.session_title = claude_session_title(input);
    // SessionEnd closes a Claude process, but the durable conversation remains
    // resumable with `claude --resume <session-id>`.
    contract.session_open = Some(true);
    contract.activity_kind = match event {
        "PreToolUse" => Some(activity_kind_for_tool(contract.tool_name.as_deref())),
        "PreCompact" => Some("compaction".to_string()),
        "SubagentStart" | "TaskCreated" => Some("subagent".to_string()),
        _ => None,
    };
    contract.activity_content = claude_activity_content(event, input);
    match event {
        "UserPromptSubmit" => {
            contract.message_role = Some("user".to_string());
            contract.message_content = display_claude_prompt_at(input, &[&["prompt"]]);
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
    let model_unavailable = event == "input"
        && agent_error
        && string_at(input, &[&["reason"]]).as_deref() == Some("model_unavailable");
    let normalized_activity_content = activity_content(event, input);
    let explicit_thinking = event == "message_end"
        && string_at(input, &[&["activity_kind"]]).as_deref() == Some("thinking")
        && normalized_activity_content.is_some();
    let (kind, outcome, session_active) = match event {
        // Opening or resuming a Pi page does not mean the agent is working.
        "session_start" => return Ok(None),
        "input" if model_unavailable => (AgentEventType::Failed, "model_unavailable", false),
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
        "message_end" if explicit_thinking => (AgentEventType::Thinking, "reasoning", true),
        "message_end" => (AgentEventType::Start, "message", true),
        // agent_end can be followed by an automatic retry, compaction, or a
        // queued continuation. Only agent_settled is a stable terminal edge.
        "agent_end" if agent_error => (AgentEventType::Start, "retry", true),
        "agent_end" => (AgentEventType::Start, "completed", true),
        "agent_settled" if agent_error => (AgentEventType::Failed, "api_failure", false),
        "agent_settled" => (AgentEventType::Done, "settled", false),
        "session_before_compact" => (AgentEventType::Start, "started", true),
        "session_compact" => (AgentEventType::Start, "completed", true),
        // Pi publishes a later human-readable session name independently of
        // the first prompt. Persist it without changing the pet lifecycle.
        "session_info_changed" => (AgentEventType::Start, "metadata_updated", false),
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
    contract.affects_activity = explicit_thinking
        || !matches!(
            event,
            "connector.probe"
                | "session_info_changed"
                | "agent_start"
                | "turn_start"
                | "turn_end"
                | "message_end"
                | "session_before_compact"
                | "session_compact"
        );
    contract.session_title = session_title(input);
    contract.session_open = Some(event != "session_shutdown");
    contract.activity_kind = match event {
        "tool_call" | "tool_execution_start" => {
            Some(activity_kind_for_tool(contract.tool_name.as_deref()))
        }
        "session_before_compact" => Some("compaction".to_string()),
        "message_end" if explicit_thinking => Some("thinking".to_string()),
        _ => None,
    };
    contract.activity_content = normalized_activity_content;
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
            (AgentEventType::Start, outcome, true)
        }
        "question.asked" | "question.v2.asked" => {
            (AgentEventType::Waiting, "input_requested".to_string(), true)
        }
        "question.replied"
        | "question.rejected"
        | "question.v2.replied"
        | "question.v2.rejected" => (
            AgentEventType::Start,
            "permission_replied".to_string(),
            true,
        ),
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
        "session.next.reasoning.ended" => (AgentEventType::Thinking, "observed".to_string(), true),
        "session.plan.updated" => (AgentEventType::Plan, "observed".to_string(), true),
        "connector.probe" => (AgentEventType::Start, "observed".to_string(), false),
        // OpenCode publishes a generated session title after the first prompt.
        // Persist the bounded title without changing the pet lifecycle.
        "session.updated" => (AgentEventType::Start, "metadata_updated".to_string(), false),
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
        "tool.execute.before" | "command.execute.before" => {
            Some(activity_kind_for_tool(tool_name.as_deref()))
        }
        "session.compaction.started" | "session.compaction.ended" => Some("compaction".to_string()),
        "session.next.reasoning.ended" => Some("thinking".to_string()),
        "session.plan.updated" => Some("plan".to_string()),
        _ => None,
    };

    let affects_activity = !(matches!(
        event,
        "connector.probe"
            | "session.created"
            | "session.updated"
            | "message.assistant"
            | "session.compaction.started"
            | "session.compaction.ended"
    ) || (event == "session.next.step.ended" && outcome == "continued"));
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
        affects_activity,
        session_active,
        turn_id: bounded_string_at(input, &[&["turn_id"], &["turnID"]], MAX_IDENTITY_BYTES),
        message_role,
        message_content,
        activity_kind,
        activity_content: activity_content(event, input),
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
        AgentSource::Dsh => DSH_PLUGIN_CONTRACT_VERSION,
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
        AgentSource::Dsh => "dsh",
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

fn claude_session_title(value: &Value) -> Option<String> {
    bounded_string_at(
        value,
        &[
            &["session_title"],
            &["sessionTitle"],
            &["properties", "session_title"],
        ],
        MAX_SESSION_TITLE_BYTES,
    )
}

/// The transcript file a Claude hook names for its own session. The path is
/// part of the hook payload the host supplies deliberately; it is still
/// untrusted input and the caller is responsible for validating and bounding
/// what it reads.
pub fn claude_transcript_path(value: &Value) -> Option<String> {
    string_at(
        value,
        &[
            &["transcript_path"],
            &["transcriptPath"],
            &["properties", "transcript_path"],
        ],
    )
}

/// The same closed, bounded display fields the hook contract already carries,
/// recovered from the Agent's own transcript when its host does not deliver
/// them through hooks.
///
/// Claude's desktop host emits session and tool lifecycle hooks but no
/// `UserPromptSubmit` or `Stop`, and those are the only hooks carrying a
/// message; its `session_title` likewise only rides `SessionStart`, which fires
/// before a title exists. Such a session would otherwise stay anonymous and
/// contextless no matter how long it runs. This recovers exactly the three
/// display strings the projection needs — nothing else from the transcript
/// crosses the adapter boundary, and every value passes the same sanitization
/// and length bounds as a hook-supplied one.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TranscriptDisplayProjection {
    pub session_title: Option<String>,
    pub latest_user_message: Option<String>,
    pub latest_agent_message: Option<String>,
    /// Which of the two messages appeared later in the transcript. Transcript
    /// records are append-ordered, so this is what makes a new user prompt
    /// take over from the previous turn's Agent text and vice versa — without
    /// it, one side would permanently shadow the other.
    pub latest_message_role: Option<String>,
}

impl TranscriptDisplayProjection {
    pub fn is_empty(&self) -> bool {
        self.session_title.is_none()
            && self.latest_user_message.is_none()
            && self.latest_agent_message.is_none()
    }
}

/// Projects one Claude transcript slice. `text` may begin mid-line because
/// callers read a bounded tail rather than a whole transcript; unparsable lines
/// are skipped rather than failing the projection. Records are newest-last, so
/// the last match of each kind wins.
pub fn claude_transcript_display(
    text: &str,
    session_id: Option<&str>,
) -> TranscriptDisplayProjection {
    let session_id = session_id.map(str::trim).filter(|value| !value.is_empty());
    let mut projection = TranscriptDisplayProjection::default();

    // Newest-first, so the first real conversation record is the current one
    // and the scan can stop as soon as it and the title are found. Claude may
    // append a `last-prompt` bookkeeping record after the Agent response; that
    // record is only a bounded fallback when the tail contains no conversation
    // record and must not make an older prompt look newer than the response.
    // This runs inside a hook on every tool call, so parsing the whole window
    // when the answer is in its last few records would be the dominant cost of
    // the adapter.
    for line in text.lines().rev() {
        if projection.session_title.is_some() && projection.latest_message_role.is_some() {
            break;
        }
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(record) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if !record.is_object() {
            continue;
        }
        // A transcript may interleave records from a resumed or forked
        // conversation. Only the addressed session may contribute display text.
        if let (Some(expected), Some(actual)) = (
            session_id,
            string_at(&record, &[&["sessionId"], &["session_id"]]),
        ) {
            if actual.trim() != expected {
                continue;
            }
        }
        // Subagent turns are not the session's own visible conversation.
        if bool_at(&record, &[&["isSidechain"]]) {
            continue;
        }

        match record.get("type").and_then(Value::as_str) {
            Some("custom-title") if projection.session_title.is_none() => {
                projection.session_title =
                    bounded_string_at(&record, &[&["customTitle"]], MAX_SESSION_TITLE_BYTES);
            }
            Some("last-prompt")
                if projection.latest_message_role.is_none()
                    && projection.latest_user_message.is_none() =>
            {
                if let Some(prompt) = string_at(&record, &[&["lastPrompt"]])
                    .and_then(|raw| normalize_claude_display_message(&raw))
                {
                    projection.latest_user_message = Some(prompt);
                }
            }
            Some("user") if projection.latest_message_role.is_none() => {
                // A `user` record carrying a tool result is transport, not a
                // message the user wrote, and array content is a tool-result
                // envelope rather than prompt text.
                if record.get("toolUseResult").is_some() {
                    continue;
                }
                if let Some(content) = string_at(&record, &[&["message", "content"]])
                    .and_then(|raw| normalize_claude_display_message(&raw))
                {
                    projection.latest_user_message = Some(content);
                    projection.latest_message_role = Some("user".to_string());
                }
            }
            Some("assistant") if projection.latest_message_role.is_none() => {
                if let Some(content) = claude_transcript_assistant_text(&record) {
                    projection.latest_agent_message = Some(content);
                    projection.latest_message_role = Some("assistant".to_string());
                }
            }
            _ => {}
        }
    }

    if projection.latest_message_role.is_none() && projection.latest_user_message.is_some() {
        projection.latest_message_role = Some("user".to_string());
    }

    projection
}

/// Joins the visible text blocks of one assistant record. Tool calls and
/// reasoning blocks are deliberately excluded: the bubble shows what the Agent
/// said, and raw tool payloads already have their own bounded activity field.
fn claude_transcript_assistant_text(record: &Value) -> Option<String> {
    let content = record.get("message")?.get("content")?;
    if let Some(text) = content.as_str() {
        return display_message(text);
    }
    let blocks = content.as_array()?;
    let mut joined = String::new();
    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("text") {
            continue;
        }
        let Some(text) = block.get("text").and_then(Value::as_str) else {
            continue;
        };
        if text.trim().is_empty() {
            continue;
        }
        if !joined.is_empty() {
            joined.push('\n');
        }
        joined.push_str(text);
        if joined.len() >= MAX_MESSAGE_BYTES {
            break;
        }
    }
    display_message(&joined)
}

/// Fills only the display fields the host left absent. A value the host did
/// supply always wins, so recovering from a transcript can never override the
/// hook contract.
pub fn apply_transcript_display(
    contract: &mut ContractEvent,
    projection: &TranscriptDisplayProjection,
) {
    if contract.session_title.is_none() {
        contract.session_title = projection.session_title.clone();
    }
    if contract.message_content.is_some() {
        return;
    }
    // Report whichever side spoke most recently. A turn that is still calling
    // tools has no Agent text yet, so the prompt that started it is the honest
    // context; once the Agent has spoken, that text is the current-turn
    // message, and the next prompt takes over again.
    let (role, content) = match projection.latest_message_role.as_deref() {
        Some("assistant") => ("assistant", projection.latest_agent_message.clone()),
        Some("user") => ("user", projection.latest_user_message.clone()),
        _ => return,
    };
    let Some(content) = content else { return };
    contract.message_role = Some(role.to_string());
    contract.message_content = Some(content);
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
    display_message(&raw)
}

fn display_claude_prompt_at(value: &Value, paths: &[&[&str]]) -> Option<String> {
    let raw = string_at(value, paths)?;
    normalize_claude_display_message(&raw)
}

fn display_message(raw: &str) -> Option<String> {
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

fn strip_leading_claude_attachment_references(value: &str) -> &str {
    let mut remainder = value;
    let mut stripped_any = false;
    loop {
        let candidate = remainder.trim_start();
        let Some(after_reference) = strip_quoted_claude_attachment_reference(candidate) else {
            break;
        };
        remainder = after_reference;
        stripped_any = true;
    }
    if stripped_any {
        remainder.trim_start()
    } else {
        value
    }
}

fn strip_quoted_claude_attachment_reference(value: &str) -> Option<&str> {
    let path_and_remainder = value.strip_prefix("@\"")?;
    let mut escaped = false;
    for (index, character) in path_and_remainder.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match character {
            '\\' => escaped = true,
            '"' => {
                let path = &path_and_remainder[..index];
                if !looks_like_claude_attachment_path(path) {
                    return None;
                }
                return Some(&path_and_remainder[index + character.len_utf8()..]);
            }
            _ => {}
        }
    }
    None
}

fn looks_like_claude_attachment_path(value: &str) -> bool {
    value.starts_with('/')
        || value.starts_with("~/")
        || value.starts_with("./")
        || value.starts_with("../")
        || value.starts_with("file://")
}

/// Applies the Claude attachment cleanup at both ingest and read-only display
/// projection so existing persisted audit envelopes do not need rewriting.
pub(crate) fn normalize_claude_display_message(value: &str) -> Option<String> {
    display_message(strip_leading_claude_attachment_references(value))
}

fn activity_content(source_event: &str, value: &Value) -> Option<String> {
    const EXPLICIT_OR_REASONING_PATHS: &[&[&str]] = &[
        &["activity_content"],
        &["reasoning_summary"],
        &["reasoning"],
        &["summary"],
        &["detail"],
        &["reason"],
        &["properties", "activity_content"],
        &["properties", "reasoning_summary"],
        &["properties", "reasoning"],
        &["properties", "summary"],
        &["properties", "detail"],
        &["properties", "reason"],
    ];
    const TOOL_INPUT_PATHS: &[&[&str]] = &[
        &["activity_content"],
        &["tool_input"],
        &["args"],
        &["input", "args"],
        &["output", "args"],
        &["input", "command"],
        &["command"],
        &["arguments"],
        &["properties", "input"],
        &["properties", "command"],
        &["properties", "arguments"],
    ];
    const TOOL_OUTPUT_PATHS: &[&[&str]] = &[
        &["activity_content"],
        &["tool_response"],
        &["tool_output"],
        &["result"],
        &["output", "output"],
        &["output", "content"],
        &["error", "message"],
        &["error"],
        &["properties", "tool_output"],
        &["properties", "result"],
        &["properties", "output"],
        &["properties", "error", "message"],
        &["properties", "error"],
    ];

    let input_event = matches!(
        source_event,
        "PreToolUse"
            | "tool_call"
            | "tool_execution_start"
            | "tool.execute.before"
            | "command.execute.before"
            | "session.next.tool.input.started"
            | "session.next.tool.called"
            | "session.next.shell.started"
    );
    let paths = if input_event {
        TOOL_INPUT_PATHS
    } else if matches!(
        source_event,
        "PostToolUse"
            | "PostToolUseFailure"
            | "tool_execution_end"
            | "tool.execute.after"
            | "command.execute.after"
            | "session.next.tool.success"
            | "session.next.tool.failed"
            | "session.next.shell.ended"
    ) {
        TOOL_OUTPUT_PATHS
    } else {
        EXPLICIT_OR_REASONING_PATHS
    };

    let tool_name = string_at(
        value,
        &[
            &["tool_name"],
            &["toolName"],
            &["input", "tool"],
            &["properties", "tool"],
        ],
    );
    let command_context = matches!(
        source_event,
        "command.execute.before" | "session.next.shell.started"
    ) || activity_kind_for_tool(tool_name.as_deref()) == "command";

    paths
        .iter()
        .filter_map(|path| value_at(value, path).map(|candidate| (*path, candidate)))
        .find_map(|(path, candidate)| {
            let explicit_command_path = path.last() == Some(&"command");
            let policy = if input_event && (explicit_command_path || command_context) {
                ActivityScalarPolicy::Command
            } else {
                ActivityScalarPolicy::Safe
            };
            normalize_agent_activity_value_with_policy(candidate, policy)
        })
}

fn claude_activity_content(source_event: &str, value: &Value) -> Option<String> {
    match source_event {
        "PreToolUse" | "PostToolUse" => claude_tool_input_content(value).or_else(|| {
            (source_event == "PostToolUse")
                .then(|| claude_tool_output_content(value))
                .flatten()
        }),
        "PostToolUseFailure" => display_activity_at_paths(
            value,
            &[
                &["error"],
                &["tool_response", "error"],
                &["tool_response", "stderr"],
            ],
        )
        .or_else(|| claude_tool_input_content(value))
        .or_else(|| claude_tool_output_content(value)),
        _ => activity_content(source_event, value),
    }
}

fn claude_tool_input_content(value: &Value) -> Option<String> {
    display_activity_at_paths_with_policy(
        value,
        &[&["tool_input", "description"]],
        ActivityScalarPolicy::Safe,
    )
    .or_else(|| {
        display_activity_at_paths_with_policy(
            value,
            &[&["tool_input", "command"]],
            ActivityScalarPolicy::Command,
        )
    })
    .or_else(|| {
        display_activity_at_paths(
            value,
            &[
                &["tool_input", "file_path"],
                &["tool_input", "filePath"],
                &["tool_input", "path"],
                &["tool_input", "pattern"],
                &["tool_input", "query"],
                &["tool_input", "url"],
                &["tool_input", "prompt"],
                &["tool_input"],
            ],
        )
    })
}

fn claude_tool_output_content(value: &Value) -> Option<String> {
    display_activity_at_paths(
        value,
        &[
            &["tool_response", "message"],
            &["tool_response", "summary"],
            &["tool_response", "content"],
            &["tool_response", "output"],
            &["tool_response", "result"],
            &["tool_response", "stdout"],
            &["tool_response", "stderr"],
            &["tool_response", "file_path"],
            &["tool_response", "filePath"],
            &["tool_response", "path"],
            &["tool_response", "plan"],
            &["tool_output"],
            &["result"],
        ],
    )
}

fn display_activity_at_paths(value: &Value, paths: &[&[&str]]) -> Option<String> {
    display_activity_at_paths_with_policy(value, paths, ActivityScalarPolicy::Safe)
}

fn display_activity_at_paths_with_policy(
    value: &Value,
    paths: &[&[&str]],
    policy: ActivityScalarPolicy,
) -> Option<String> {
    paths
        .iter()
        .filter_map(|path| value_at(value, path))
        .find_map(|candidate| normalize_agent_activity_value_with_policy(candidate, policy))
}

/// Normalizes every Agent's activity detail at both ingest and read-only
/// projection boundaries. Legacy connectors sometimes serialized a structured
/// tool envelope into this string. Structured values are never rendered as raw
/// JSON; only bounded scalar values under the closed semantic-key vocabulary
/// may cross into display content.
pub(crate) fn normalize_agent_activity_content_for_kind(
    value: &str,
    activity_kind: Option<&str>,
) -> Option<String> {
    let mut remaining_nodes = MAX_ACTIVITY_STRUCTURE_NODES;
    normalize_activity_node(
        &Value::String(value.to_string()),
        0,
        &mut remaining_nodes,
        if activity_kind == Some("command") {
            ActivityScalarPolicy::Command
        } else {
            ActivityScalarPolicy::Safe
        },
        0,
    )
}

const ACTIVITY_SEMANTIC_KEYS: [&str; 18] = [
    "description",
    "command",
    "file_path",
    "filePath",
    "path",
    "pattern",
    "query",
    "url",
    "prompt",
    "message",
    "summary",
    "content",
    "output",
    "result",
    "stdout",
    "stderr",
    "plan",
    "error",
];
const MAX_ACTIVITY_STRUCTURE_DEPTH: usize = 8;
const MAX_ACTIVITY_STRUCTURE_NODES: usize = 256;
const MAX_ACTIVITY_ARRAY_ITEMS: usize = 64;
const MAX_ACTIVITY_JSON_STRING_BYTES: usize = 16 * 1024;
const MAX_ACTIVITY_JSON_DECODE_LAYERS: usize = MAX_ACTIVITY_STRUCTURE_DEPTH;

#[derive(Clone, Copy, PartialEq, Eq)]
enum ActivityScalarPolicy {
    Safe,
    Command,
}

pub(crate) fn normalize_agent_activity_value(value: &Value) -> Option<String> {
    normalize_agent_activity_value_with_policy(value, ActivityScalarPolicy::Safe)
}

fn normalize_agent_activity_value_with_policy(
    value: &Value,
    policy: ActivityScalarPolicy,
) -> Option<String> {
    let mut remaining_nodes = MAX_ACTIVITY_STRUCTURE_NODES;
    normalize_activity_node(value, 0, &mut remaining_nodes, policy, 0)
}

fn value_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    Some(current)
}

fn semantic_activity_scalar(
    value: &Value,
    depth: usize,
    remaining_nodes: &mut usize,
) -> Option<String> {
    if depth > MAX_ACTIVITY_STRUCTURE_DEPTH || *remaining_nodes == 0 {
        return None;
    }
    *remaining_nodes -= 1;
    match value {
        Value::Array(values) => values
            .iter()
            .take(MAX_ACTIVITY_ARRAY_ITEMS)
            .filter(|value| value.is_array() || value.is_object())
            .find_map(|value| semantic_activity_scalar(value, depth + 1, remaining_nodes)),
        Value::Object(values) => {
            for key in ACTIVITY_SEMANTIC_KEYS {
                let Some(candidate) = values.get(key) else {
                    continue;
                };
                if key == "error" {
                    let content = display_activity_scalar(
                        candidate,
                        ActivityScalarPolicy::Safe,
                        depth + 1,
                        remaining_nodes,
                        0,
                    )
                    .or_else(|| {
                        candidate.get("message").and_then(|message| {
                            display_activity_scalar(
                                message,
                                ActivityScalarPolicy::Safe,
                                depth + 1,
                                remaining_nodes,
                                0,
                            )
                        })
                    });
                    if let Some(content) = content {
                        return Some(content);
                    }
                    continue;
                }
                let policy = if key == "command" {
                    ActivityScalarPolicy::Command
                } else {
                    ActivityScalarPolicy::Safe
                };
                if let Some(content) =
                    normalize_activity_node(candidate, depth + 1, remaining_nodes, policy, 0)
                {
                    return Some(content);
                }
            }
            values
                .iter()
                .filter(|(key, value)| {
                    !ACTIVITY_SEMANTIC_KEYS.contains(&key.as_str())
                        && !is_credential_field(key)
                        && (value.is_array() || value.is_object())
                })
                .find_map(|(_, value)| semantic_activity_scalar(value, depth + 1, remaining_nodes))
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => None,
    }
}

fn normalize_activity_node(
    value: &Value,
    depth: usize,
    remaining_nodes: &mut usize,
    policy: ActivityScalarPolicy,
    json_decode_layers: usize,
) -> Option<String> {
    match value {
        Value::Null => None,
        Value::Bool(_) | Value::Number(_) | Value::String(_) => {
            display_activity_scalar(value, policy, depth, remaining_nodes, json_decode_layers)
        }
        Value::Array(_) | Value::Object(_) => {
            semantic_activity_scalar(value, depth, remaining_nodes)
        }
    }
}

fn display_activity_scalar(
    value: &Value,
    policy: ActivityScalarPolicy,
    depth: usize,
    remaining_nodes: &mut usize,
    json_decode_layers: usize,
) -> Option<String> {
    let raw = match value {
        Value::Null => return None,
        Value::String(value) => value.clone(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        Value::Array(_) | Value::Object(_) => return None,
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if matches!(value, Value::String(_))
        && json_decode_layers < MAX_ACTIVITY_JSON_DECODE_LAYERS
        && trimmed.len() <= MAX_ACTIVITY_JSON_STRING_BYTES
    {
        match serde_json::from_str::<Value>(trimmed) {
            Ok(decoded) => {
                if depth >= MAX_ACTIVITY_STRUCTURE_DEPTH || *remaining_nodes == 0 {
                    return None;
                }
                *remaining_nodes -= 1;
                return normalize_activity_node(
                    &decoded,
                    depth + 1,
                    remaining_nodes,
                    policy,
                    json_decode_layers + 1,
                );
            }
            Err(_) if encoded_json_prefix(trimmed) => return None,
            Err(_) => {}
        }
    } else if matches!(value, Value::String(_)) && encoded_json_prefix(trimmed) {
        return None;
    }
    if policy == ActivityScalarPolicy::Safe && contains_sensitive_dump_line(trimmed) {
        return None;
    }
    let sanitized = raw
        .chars()
        .map(|character| match character {
            '\n' | '\t' => character,
            character if character.is_control() => ' ',
            character => character,
        })
        .collect::<String>();
    let sanitized = sanitized.trim();
    (!sanitized.is_empty()).then(|| truncate_utf8(sanitized, MAX_ACTIVITY_CONTENT_BYTES))
}

fn structured_json_prefix(value: &str) -> bool {
    matches!(value.as_bytes().first(), Some(b'{') | Some(b'['))
}

fn encoded_json_prefix(value: &str) -> bool {
    structured_json_prefix(value) || value.as_bytes().first() == Some(&b'"')
}

fn contains_sensitive_dump_line(value: &str) -> bool {
    value.lines().any(|line| {
        line.char_indices()
            .filter(|(_, character)| matches!(character, ':' | '='))
            .any(|(separator, _)| {
                let prefix = &line[..separator];
                let key_start = prefix
                    .char_indices()
                    .rev()
                    .nth(127)
                    .map_or(0, |(index, _)| index);
                let key = prefix[key_start..].trim();
                !key.is_empty() && is_credential_field(key)
            })
    })
}

fn is_credential_field(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    if matches!(normalized.as_str(), "tokencount" | "tokencounts") {
        return false;
    }
    const SENSITIVE_TOKENS: &[&str] = &[
        "env",
        "environment",
        "header",
        "headers",
        "auth",
        "oauth",
        "authentication",
        "authorization",
        "secret",
        "secrets",
        "password",
        "passphrase",
        "credential",
        "credentials",
        "cookie",
        "cookies",
        "token",
        "tokens",
        "keychain",
        "keystore",
        "pem",
    ];
    const KEY_QUALIFIERS: &[&str] = &[
        "private",
        "api",
        "ssh",
        "signing",
        "encryption",
        "access",
        "client",
    ];
    const GLUED_SENSITIVE_FRAGMENTS: &[&str] = &[
        "clientsecret",
        "sessiontoken",
        "privatekey",
        "apikey",
        "sshkey",
        "signingkey",
        "encryptionkey",
        "accesskey",
        "clientkey",
        "accesstoken",
        "refreshtoken",
        "bearertoken",
        "authtoken",
        "requestheader",
        "processenv",
        "processenvironment",
        "clientauth",
        "clientauthentication",
    ];

    let tokens = identifier_tokens(key);
    tokens
        .iter()
        .any(|token| SENSITIVE_TOKENS.contains(&token.as_str()))
        || (tokens.iter().any(|token| token == "key")
            && tokens
                .iter()
                .any(|token| KEY_QUALIFIERS.contains(&token.as_str())))
        || GLUED_SENSITIVE_FRAGMENTS
            .iter()
            .any(|fragment| normalized.contains(fragment))
}

fn identifier_tokens(key: &str) -> Vec<String> {
    let characters = key.chars().collect::<Vec<_>>();
    let mut tokens = Vec::new();
    let mut current = String::new();
    for (index, character) in characters.iter().copied().enumerate() {
        if !character.is_ascii_alphanumeric() {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            continue;
        }
        let previous = index.checked_sub(1).and_then(|index| characters.get(index));
        let next = characters.get(index + 1);
        let camel_boundary = character.is_ascii_uppercase()
            && !current.is_empty()
            && (previous.is_some_and(|previous| {
                previous.is_ascii_lowercase() || previous.is_ascii_digit()
            }) || (previous.is_some_and(|previous| previous.is_ascii_uppercase())
                && next.is_some_and(|next| next.is_ascii_lowercase())));
        if camel_boundary {
            tokens.push(std::mem::take(&mut current));
        }
        current.push(character.to_ascii_lowercase());
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
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

#[cfg(test)]
mod claude_transcript_tests {
    use super::*;
    use serde_json::json;

    /// The shapes observed in a real Claude transcript: bookkeeping records for
    /// the title and latest prompt, plus conversation records whose assistant
    /// content is a block array.
    fn transcript(session: &str) -> Vec<String> {
        vec![
            json!({"type": "custom-title", "customTitle": "宠物拖动动画与气泡跟随优化", "sessionId": session})
                .to_string(),
            json!({
                "type": "user",
                "sessionId": session,
                "isSidechain": false,
                "message": {"role": "user", "content": "参考看下 ChatGPT 内置宠物"}
            })
            .to_string(),
            json!({"type": "last-prompt", "lastPrompt": "参考看下 ChatGPT 内置宠物", "sessionId": session})
                .to_string(),
        ]
    }

    fn assistant_record(session: &str, text: &str) -> String {
        json!({
            "type": "assistant",
            "sessionId": session,
            "isSidechain": false,
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "thinking", "thinking": "internal reasoning"},
                    {"type": "text", "text": text},
                    {"type": "tool_use", "name": "Read", "input": {"file_path": "/tmp/x"}}
                ]
            }
        })
        .to_string()
    }

    #[test]
    fn recovers_title_and_prompt_when_the_host_sends_neither() {
        let session = "308b79e0-bbc0-491b-984a-950d6aa4bbab";
        let projection = claude_transcript_display(&transcript(session).join("\n"), Some(session));
        assert_eq!(
            projection.session_title.as_deref(),
            Some("宠物拖动动画与气泡跟随优化")
        );
        assert_eq!(
            projection.latest_user_message.as_deref(),
            Some("参考看下 ChatGPT 内置宠物")
        );
        assert_eq!(projection.latest_message_role.as_deref(), Some("user"));
    }

    #[test]
    fn trailing_last_prompt_is_bookkeeping_but_a_real_new_prompt_takes_over() {
        let session = "session-a";
        let mut lines = transcript(session);
        lines.push(assistant_record(session, "Found the root cause."));
        lines.push(
            json!({"type": "last-prompt", "lastPrompt": "参考看下 ChatGPT 内置宠物", "sessionId": session})
                .to_string(),
        );
        let after_agent = claude_transcript_display(&lines.join("\n"), Some(session));
        assert_eq!(
            after_agent.latest_message_role.as_deref(),
            Some("assistant")
        );
        assert_eq!(
            after_agent.latest_agent_message.as_deref(),
            Some("Found the root cause.")
        );

        lines.push(
            json!({
                "type": "user",
                "sessionId": session,
                "message": {"role": "user", "content": "继续修复"}
            })
            .to_string(),
        );
        lines.push(
            json!({"type": "last-prompt", "lastPrompt": "继续修复", "sessionId": session})
                .to_string(),
        );
        let after_prompt = claude_transcript_display(&lines.join("\n"), Some(session));
        assert_eq!(after_prompt.latest_message_role.as_deref(), Some("user"));
        assert_eq!(
            after_prompt.latest_user_message.as_deref(),
            Some("继续修复")
        );
    }

    #[test]
    fn tool_transport_and_subagent_turns_never_become_display_messages() {
        let session = "session-b";
        let lines = [
            json!({"type": "custom-title", "customTitle": "Real title", "sessionId": session})
                .to_string(),
            // A tool result is delivered as a `user` record.
            json!({
                "type": "user",
                "sessionId": session,
                "toolUseResult": {"stdout": "secret output"},
                "message": {"role": "user", "content": "secret output"}
            })
            .to_string(),
            // Array content is a tool-result envelope, not prompt text.
            json!({
                "type": "user",
                "sessionId": session,
                "message": {
                    "role": "user",
                    "content": [{"type": "tool_result", "content": "more output"}]
                }
            })
            .to_string(),
            // A subagent turn is not the session's own conversation.
            json!({
                "type": "assistant",
                "sessionId": session,
                "isSidechain": true,
                "message": {"role": "assistant", "content": [{"type": "text", "text": "subagent"}]}
            })
            .to_string(),
        ];
        let projection = claude_transcript_display(&lines.join("\n"), Some(session));
        assert_eq!(projection.session_title.as_deref(), Some("Real title"));
        assert_eq!(projection.latest_message_role, None);
        assert_eq!(projection.latest_user_message, None);
        assert_eq!(projection.latest_agent_message, None);
    }

    #[test]
    fn another_session_and_a_truncated_leading_record_contribute_nothing() {
        let session = "session-c";
        let mut lines = vec![
            // A bounded tail can begin mid-record.
            r#"e": "custom-title", "customTitle": "Truncated", "sessionId": "session-c"}"#
                .to_string(),
            json!({"type": "custom-title", "customTitle": "Other session", "sessionId": "other"})
                .to_string(),
            json!({"type": "last-prompt", "lastPrompt": "other prompt", "sessionId": "other"})
                .to_string(),
        ];
        let projection = claude_transcript_display(&lines.join("\n"), Some(session));
        assert_eq!(projection, TranscriptDisplayProjection::default());
        assert!(projection.is_empty());

        // Without an addressed session the transcript still speaks for itself.
        lines.push(assistant_record(session, "own text"));
        let unscoped = claude_transcript_display(&lines.join("\n"), None);
        assert_eq!(unscoped.latest_agent_message.as_deref(), Some("own text"));
    }

    #[test]
    fn recovery_only_fills_fields_the_host_left_absent() {
        let session = "session-d";
        let mut lines = transcript(session);
        lines.push(assistant_record(session, "recovered agent text"));
        let projection = claude_transcript_display(&lines.join("\n"), Some(session));

        let mut host_supplied = parse_contract_event(
            AgentSource::ClaudeCode,
            &json!({
                "hook_event_name": "UserPromptSubmit",
                "session_id": session,
                "session_title": "Host title",
                "prompt": "Host prompt"
            }),
        )
        .expect("parsed")
        .expect("contract");
        apply_transcript_display(&mut host_supplied, &projection);
        assert_eq!(host_supplied.session_title.as_deref(), Some("Host title"));
        assert_eq!(
            host_supplied.message_content.as_deref(),
            Some("Host prompt")
        );
        assert_eq!(host_supplied.message_role.as_deref(), Some("user"));

        // A tool hook carries neither, which is the desktop-host case.
        let mut tool_hook = parse_contract_event(
            AgentSource::ClaudeCode,
            &json!({
                "hook_event_name": "PreToolUse",
                "session_id": session,
                "tool_name": "Read"
            }),
        )
        .expect("parsed")
        .expect("contract");
        assert_eq!(tool_hook.session_title, None);
        assert_eq!(tool_hook.message_content, None);
        apply_transcript_display(&mut tool_hook, &projection);
        assert_eq!(
            tool_hook.session_title.as_deref(),
            Some("宠物拖动动画与气泡跟随优化")
        );
        assert_eq!(
            tool_hook.message_content.as_deref(),
            Some("recovered agent text")
        );
        assert_eq!(tool_hook.message_role.as_deref(), Some("assistant"));
    }

    #[test]
    fn transcript_text_obeys_the_same_bounds_as_a_hook_supplied_field() {
        let session = "session-e";
        let long_title = "标".repeat(MAX_SESSION_TITLE_BYTES);
        let long_text = "x".repeat(MAX_MESSAGE_BYTES * 4);
        let lines = [
            json!({"type": "custom-title", "customTitle": long_title, "sessionId": session})
                .to_string(),
            assistant_record(session, &long_text),
        ];
        let projection = claude_transcript_display(&lines.join("\n"), Some(session));
        assert!(projection.session_title.expect("title").len() <= MAX_SESSION_TITLE_BYTES);
        assert!(projection.latest_agent_message.expect("message").len() <= MAX_MESSAGE_BYTES);
    }

    /// Claude needed transcript recovery because its desktop host delivers no
    /// message-carrying hook at all. Pi and OpenCode publish the title and both
    /// message roles on their own events, so they need no such recovery — this
    /// pins that difference so a future change cannot quietly remove the fields
    /// that make their bubbles readable.
    #[test]
    fn pi_and_opencode_publish_title_and_both_message_roles_directly() {
        let pi_title = parse_contract_event(
            AgentSource::Pi,
            &json!({
                "type": "session_info_changed",
                "session_id": "pi-1",
                "session_title": "检查下代码工程质量"
            }),
        )
        .expect("parsed")
        .expect("contract");
        assert_eq!(
            pi_title.session_title.as_deref(),
            Some("检查下代码工程质量")
        );

        let pi_user = parse_contract_event(
            AgentSource::Pi,
            &json!({"type": "input", "session_id": "pi-1", "text": "检查下代码工程质量"}),
        )
        .expect("parsed")
        .expect("contract");
        assert_eq!(pi_user.message_role.as_deref(), Some("user"));
        assert_eq!(
            pi_user.message_content.as_deref(),
            Some("检查下代码工程质量")
        );

        let pi_missing_model = parse_contract_event(
            AgentSource::Pi,
            &json!({
                "type": "input",
                "session_id": "pi-no-model",
                "text": "检查下代码工程质量",
                "agent_error": true,
                "reason": "model_unavailable"
            }),
        )
        .expect("parsed")
        .expect("contract");
        assert_eq!(pi_missing_model.kind, AgentEventType::Failed);
        assert_eq!(
            pi_missing_model.outcome.as_deref(),
            Some("model_unavailable")
        );
        assert!(!pi_missing_model.session_active);

        let pi_agent = parse_contract_event(
            AgentSource::Pi,
            &json!({
                "type": "message_end",
                "session_id": "pi-1",
                "message_content": "我来检查一下这个项目的代码工程质量。"
            }),
        )
        .expect("parsed")
        .expect("contract");
        assert_eq!(pi_agent.message_role.as_deref(), Some("assistant"));
        assert_eq!(
            pi_agent.message_content.as_deref(),
            Some("我来检查一下这个项目的代码工程质量。")
        );

        let opencode_title = parse_contract_event(
            AgentSource::Opencode,
            &json!({
                "type": "session.updated",
                "properties": {"sessionID": "oc-1", "session_title": "Refactor the parser"}
            }),
        )
        .expect("parsed")
        .expect("contract");
        assert_eq!(
            opencode_title.session_title.as_deref(),
            Some("Refactor the parser")
        );

        for (event, role) in [("message.user", "user"), ("message.assistant", "assistant")] {
            let contract = parse_contract_event(
                AgentSource::Opencode,
                &json!({
                    "type": event,
                    "properties": {"sessionID": "oc-1", "message_content": "bounded text"}
                }),
            )
            .expect("parsed")
            .expect("contract");
            assert_eq!(contract.message_role.as_deref(), Some(role));
            assert_eq!(contract.message_content.as_deref(), Some("bounded text"));
        }
    }

    #[test]
    fn explicit_host_lineage_becomes_a_content_free_child_suppression_marker() {
        let cases = [
            (
                AgentSource::Codex,
                json!({
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "codex-child",
                    "parentThreadId": "codex-root",
                    "prompt": "must not cross"
                }),
                "codex-child",
            ),
            (
                AgentSource::ClaudeCode,
                json!({
                    "hook_event_name": "PreToolUse",
                    "session_id": "claude-child",
                    "isSidechain": true,
                    "tool_name": "Read"
                }),
                "claude-child",
            ),
            (
                AgentSource::Pi,
                json!({
                    "type": "input",
                    "session_id": "pi-child",
                    "parent_session_id": "pi-root",
                    "text": "must not cross"
                }),
                "pi-child",
            ),
            (
                AgentSource::Opencode,
                json!({
                    "type": "session.created",
                    "properties": {
                        "info": {
                            "id": "opencode-child",
                            "parentID": "opencode-root",
                            "title": "must not cross"
                        }
                    }
                }),
                "opencode-child",
            ),
            (
                AgentSource::Opencode,
                json!({
                    "type": "session.child",
                    "properties": {"sessionID": "opencode-known-child"}
                }),
                "opencode-known-child",
            ),
        ];

        for (source, input, expected_session) in cases {
            let contract = parse_contract_event(source, &input)
                .expect("parsed")
                .expect("child marker");
            assert_eq!(contract.session_id.as_deref(), Some(expected_session));
            assert_eq!(contract.source_event, AGENT_CHILD_SESSION_SOURCE_EVENT);
            assert!(!contract.affects_activity);
            assert!(!contract.session_active);
            assert_eq!(contract.session_open, Some(false));
            assert_eq!(contract.message_content, None);
            assert_eq!(contract.session_title, None);
            assert_eq!(contract.activity_content, None);
        }
    }

    #[test]
    fn opencode_message_parent_identity_is_not_session_lineage() {
        let input = json!({
            "type": "message.updated",
            "properties": {
                "info": {
                    "id": "assistant-message",
                    "sessionID": "root-session",
                    "parentID": "user-message",
                    "role": "assistant"
                }
            }
        });
        assert!(child_session_contract(AgentSource::Opencode, &input).is_none());
    }

    /// Transcript recovery is Claude-scoped on purpose: no other host names a
    /// local transcript in its hook payload, so no other source may read one.
    #[test]
    fn transcript_recovery_never_applies_to_another_source() {
        for source in [AgentSource::Codex, AgentSource::Pi, AgentSource::Opencode] {
            let payload = json!({"transcript_path": "/tmp/anything.jsonl"});
            // The extractor itself is source-agnostic; the adapter boundary is
            // what scopes it, and every caller checks the source first.
            assert!(claude_transcript_path(&payload).is_some());
            assert_ne!(source, AgentSource::ClaudeCode);
        }
    }

    #[test]
    fn transcript_path_is_read_from_the_hook_payload() {
        assert_eq!(
            claude_transcript_path(&json!({"transcript_path": "/a/b.jsonl"})).as_deref(),
            Some("/a/b.jsonl")
        );
        assert_eq!(
            claude_transcript_path(&json!({"transcriptPath": "/a/b.jsonl"})).as_deref(),
            Some("/a/b.jsonl")
        );
        assert_eq!(
            claude_transcript_path(&json!({"transcript_path": ""})),
            None
        );
        assert_eq!(claude_transcript_path(&json!({})), None);
    }
}

#[cfg(test)]
mod activity_normalization_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn structured_activity_uses_only_bounded_semantic_scalars() {
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "transport": {"opaque": true},
                "payload": [{"command": "cargo test"}]
            }))
            .as_deref(),
            Some("cargo test")
        );
        assert_eq!(
            normalize_agent_activity_content_for_kind(
                r#"{"transport":{"opaque":true},"error":{"message":"build failed"}}"#,
                None,
            )
            .as_deref(),
            Some("build failed")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!(["raw", "array"])),
            None
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({"transport": "raw envelope"})),
            None
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({"error": "readable failure"})).as_deref(),
            Some("readable failure")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({"file_path": "Sources/App.swift"})).as_deref(),
            Some("Sources/App.swift")
        );
        for sensitive in [
            json!({"headers": {"content": "secret header"}}),
            json!({"environment": {"message": "secret environment"}}),
            json!({"tokens": {"output": "secret token"}}),
            json!({"client_secret": {"message": "secret client"}}),
            json!({"sessionToken": {"output": "secret session"}}),
            json!({"privateKey": {"content": "secret private key"}}),
            json!({"Authorization": {"message": "secret authorization"}}),
            json!({"customBearerToken": {"result": "secret bearer"}}),
            json!({"processEnv": {"message": "secret process environment"}}),
            json!({"requestHeader": {"content": "secret request header"}}),
            json!({"requestHeaders": {"content": "secret request headers"}}),
            json!({"clientAuth": {"output": "secret client auth"}}),
            json!({"oauth": {"result": "secret oauth"}}),
            json!({"processEnvironment": {"message": "secret process environment"}}),
            json!({"clientAuthentication": {"content": "secret client authentication"}}),
            json!({"authConfig": {"output": "secret auth config"}}),
            json!({"token_value": {"message": "secret token underscore"}}),
            json!({"token-value": {"output": "secret token hyphen"}}),
            json!({"tokenValue": {"content": "secret token camel case"}}),
        ] {
            assert_eq!(normalize_agent_activity_value(&sensitive), None);
        }
        let sensitive_tokens = [
            "env",
            "environment",
            "header",
            "headers",
            "auth",
            "oauth",
            "authentication",
            "authorization",
            "secret",
            "password",
            "passphrase",
            "credential",
            "credentials",
            "cookie",
            "cookies",
            "token",
            "tokens",
            "keychain",
            "keystore",
            "pem",
        ];
        for sensitive in sensitive_tokens {
            for separator in ["_", "-", ".", " "] {
                assert!(is_credential_field(&format!("{sensitive}{separator}value")));
                assert!(is_credential_field(&format!("value{separator}{sensitive}")));
            }
            let mut characters = sensitive.chars();
            let capitalized = characters
                .next()
                .map(|first| first.to_ascii_uppercase().to_string() + characters.as_str())
                .unwrap();
            assert!(is_credential_field(&format!("{sensitive}Value")));
            assert!(is_credential_field(&format!("value{capitalized}")));
        }
        for qualifier in [
            "private",
            "api",
            "ssh",
            "signing",
            "encryption",
            "access",
            "client",
        ] {
            assert!(is_credential_field(&format!("{qualifier}_key")));
            assert!(is_credential_field(&format!("key-{qualifier}")));
            let mut characters = qualifier.chars();
            let capitalized = characters
                .next()
                .map(|first| first.to_ascii_uppercase().to_string() + characters.as_str())
                .unwrap();
            assert!(is_credential_field(&format!("{qualifier}Key")));
            assert!(is_credential_field(&format!("key{capitalized}")));
        }
        for glued in [
            "clientsecret",
            "sessiontoken",
            "privatekey",
            "apikey",
            "accesstoken",
            "refreshtoken",
        ] {
            assert!(is_credential_field(glued));
        }
        for ordinary in ["envelope", "authorMetadata", "token_count", "token_counts"] {
            assert!(!is_credential_field(ordinary));
        }
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "token_count": {"message": "42 tokens processed"}
            }))
            .as_deref(),
            Some("42 tokens processed")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "token_counts": {"message": "42 input, 17 output"}
            }))
            .as_deref(),
            Some("42 input, 17 output")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "authorMetadata": {"message": "Ada Lovelace"}
            }))
            .as_deref(),
            Some("Ada Lovelace")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "envelope": {"message": "ordinary transport envelope"}
            }))
            .as_deref(),
            Some("ordinary transport envelope")
        );

        let encoded_safe_object = serde_json::to_string(&json!({
            "path": "README.md",
            "headers": {"Authorization": "Bearer private"}
        }))
        .unwrap();
        let encoded_safe_array = serde_json::to_string(&json!([{
            "file_path": "Sources/App.swift"
        }]))
        .unwrap();
        let double_encoded_safe = serde_json::to_string(&encoded_safe_object).unwrap();
        assert_eq!(
            normalize_agent_activity_value(&json!({"output": encoded_safe_object})).as_deref(),
            Some("README.md")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({"result": encoded_safe_array})).as_deref(),
            Some("Sources/App.swift")
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({"content": double_encoded_safe})).as_deref(),
            Some("README.md")
        );

        let encoded_credentials = serde_json::to_string(&json!({
            "headers": {"message": "secret header"},
            "credentials": {"output": "secret credential"}
        }))
        .unwrap();
        let encoded_credential_array = serde_json::to_string(&json!([{
            "client_secret": {"content": "secret array credential"}
        }]))
        .unwrap();
        let double_encoded_credentials = serde_json::to_string(&encoded_credentials).unwrap();
        let triple_encoded_credentials =
            serde_json::to_string(&double_encoded_credentials).unwrap();
        let oversized_encoded_credentials = serde_json::to_string(&json!({
            "headers": {"message": "x".repeat(MAX_ACTIVITY_JSON_STRING_BYTES * 2)}
        }))
        .unwrap();
        let oversized_double_encoded_credentials =
            serde_json::to_string(&oversized_encoded_credentials).unwrap();
        for encoded in [
            encoded_credentials,
            encoded_credential_array,
            double_encoded_credentials,
            triple_encoded_credentials,
            oversized_encoded_credentials,
            oversized_double_encoded_credentials,
        ] {
            assert_eq!(
                normalize_agent_activity_value(&json!({"output": encoded})),
                None
            );
        }
        for unsafe_text in [
            "Authorization: Bearer private",
            "API_KEY=private\nPATH=/usr/bin",
            "PATH=/usr/bin API_KEY=private",
            "Content-Type: text/plain Authorization: Bearer private",
            "PATH=/usr/bin\u{0}API_KEY=private",
            "  {\"path\":\"README.md\"",
            " \n [ {\"path\":\"README.md\"}",
            "  \"{\\\"headers\\\":{\\\"message\\\":\\\"secret\\\"}",
        ] {
            assert_eq!(
                normalize_agent_activity_value(&json!({"stdout": unsafe_text})),
                None
            );
        }
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "summary": "Planning includes {draft} markers"
            }))
            .as_deref(),
            Some("Planning includes {draft} markers")
        );
        let quoted_prose = serde_json::to_string("Planning includes {draft} markers").unwrap();
        assert_eq!(
            normalize_agent_activity_value(&json!({"summary": quoted_prose})).as_deref(),
            Some("Planning includes {draft} markers")
        );
        let double_encoded_truncated =
            serde_json::to_string(r#"{"headers":{"message":"secret"}"#).unwrap();
        assert_eq!(
            normalize_agent_activity_value(&json!({"output": double_encoded_truncated})),
            None
        );
        assert_eq!(
            normalize_agent_activity_value(&json!({
                "command": "TOKEN=secret-command"
            }))
            .as_deref(),
            Some("TOKEN=secret-command")
        );
        assert_eq!(
            normalize_agent_activity_content_for_kind("TOKEN=secret-command", Some("command"))
                .as_deref(),
            Some("TOKEN=secret-command")
        );
        assert_eq!(
            normalize_agent_activity_content_for_kind(
                "PATH=/usr/bin API_KEY=secret-command",
                Some("command")
            )
            .as_deref(),
            Some("PATH=/usr/bin API_KEY=secret-command")
        );
        assert_eq!(
            normalize_agent_activity_content_for_kind("TOKEN=secret-command", None),
            None
        );

        let mut too_deep = json!({"command": "must not escape depth bound"});
        for _ in 0..=MAX_ACTIVITY_STRUCTURE_DEPTH {
            too_deep = json!({"transport": too_deep});
        }
        assert_eq!(normalize_agent_activity_value(&too_deep), None);
    }

    #[test]
    fn direct_command_paths_use_command_policy_without_weakening_safe_content() {
        let claude = parse_contract_event(
            AgentSource::ClaudeCode,
            &json!({
                "hook_event_name": "PreToolUse",
                "session_id": "claude-direct-command",
                "tool_name": "Bash",
                "tool_input": {"command": "TOKEN=secret-command"}
            }),
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            claude.activity_content.as_deref(),
            Some("TOKEN=secret-command")
        );

        assert_eq!(
            activity_content(
                "tool_call",
                &json!({
                    "toolName": "bash",
                    "tool_input": "TOKEN=secret-command"
                })
            )
            .as_deref(),
            Some("TOKEN=secret-command")
        );
        assert_eq!(
            activity_content(
                "tool_call",
                &json!({"toolName": "read", "tool_input": "TOKEN=private"})
            ),
            None
        );
        assert_eq!(
            activity_content(
                "tool_call",
                &json!({
                    "activity_content": "Authorization: Bearer private",
                    "command": "TOKEN=secret-command"
                })
            )
            .as_deref(),
            Some("TOKEN=secret-command")
        );
        assert_eq!(
            claude_tool_input_content(&json!({
                "tool_input": {
                    "description": "Authorization: Bearer private",
                    "command": "TOKEN=secret-command"
                }
            }))
            .as_deref(),
            Some("TOKEN=secret-command")
        );

        for rejected in [
            activity_content(
                "PostToolUse",
                &json!({"tool_output": "Authorization: Bearer private"}),
            ),
            activity_content(
                "reasoning",
                &json!({"detail": "API_KEY=private\nPATH=/usr/bin"}),
            ),
            claude_tool_output_content(&json!({
                "tool_response": {"output": "requestHeaders: private"}
            })),
        ] {
            assert_eq!(rejected, None);
        }
    }
}
