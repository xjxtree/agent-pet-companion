use crate::{enum_from_name, enum_name, PetCoreError, Result};
use petcore_types::{AgentEvent, AgentEventType, AgentSource};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

pub const EVENT_ENVELOPE_SCHEMA_VERSION: &str = "apc.agent-event.v1";
pub const MAX_EVENT_TITLE_BYTES: usize = 160;
pub const MAX_EVENT_DETAIL_BYTES: usize = 512;
pub const MAX_RECENT_EVENTS: usize = 200;
pub const MAX_MESSAGE_CONTENT_BYTES: usize = 4_096;
pub const MAX_ACTIVITY_CONTENT_BYTES: usize = 1_024;

const MAX_EVENT_ID_BYTES: usize = 256;
const MAX_SESSION_ID_BYTES: usize = 256;
const MAX_PROJECT_PATH_BYTES: usize = 1_024;
const MAX_TURN_ID_BYTES: usize = 256;
pub(crate) const MAX_PROJECT_LABEL_BYTES: usize = 128;
pub(crate) const MAX_SESSION_TITLE_BYTES: usize = 160;
const MAX_SESSION_OPEN_URL_BYTES: usize = 256;
const MAX_CONTRACT_VERSION_BYTES: usize = 128;

pub fn event_affects_activity(event: &AgentEvent) -> bool {
    event
        .payload_json
        .get("affects_activity")
        .and_then(Value::as_bool)
        .unwrap_or(true)
}

/// Returns whether a supported connector event is a production terminal edge
/// that may close previously activated work. This closed set is deliberately
/// source-, type-, and (where needed) outcome-aware: similarly named metadata
/// or non-terminal events must not suppress a real active session.
pub(crate) fn event_requires_prior_user_activation(event: &AgentEvent) -> bool {
    let source_event = event
        .payload_json
        .get("source_event")
        .and_then(Value::as_str);
    let outcome = event.payload_json.get("outcome").and_then(Value::as_str);

    match (event.source, event.event_type, source_event) {
        (AgentSource::Codex, AgentEventType::Done, Some("Stop")) => true,
        (AgentSource::ClaudeCode, AgentEventType::Done, Some("Stop" | "SessionEnd")) => true,
        (AgentSource::ClaudeCode, AgentEventType::Failed, Some("StopFailure")) => true,
        (AgentSource::ClaudeCode, AgentEventType::Done, Some("Notification")) => {
            matches!(outcome, Some("idle" | "agent_completed"))
        }
        (AgentSource::Pi, AgentEventType::Done | AgentEventType::Failed, Some("agent_settled")) => {
            true
        }
        (AgentSource::Pi, AgentEventType::Done, Some("session_shutdown")) => true,
        (AgentSource::Opencode, AgentEventType::Done, Some("session.deleted" | "session.idle")) => {
            true
        }
        (AgentSource::Opencode, AgentEventType::Done, Some("session.status")) => {
            outcome == Some("idle")
        }
        (AgentSource::Opencode, AgentEventType::Failed, Some("session.error")) => true,
        (
            AgentSource::Opencode,
            AgentEventType::Done | AgentEventType::Failed,
            Some("session.next.step.ended"),
        ) => true,
        (AgentSource::Opencode, AgentEventType::Failed, Some("session.next.step.failed")) => true,
        _ => false,
    }
}

/// Returns whether an event proves that a new/continued active execution epoch
/// began after a latched failure. Completion tails such as assistant messages,
/// tool-after, compaction completion, idle, and close are intentionally absent.
pub(crate) fn event_starts_new_activity_epoch(event: &AgentEvent) -> bool {
    if matches!(
        event.event_type,
        AgentEventType::Done | AgentEventType::Failed
    ) {
        return false;
    }
    let source_event = event
        .payload_json
        .get("source_event")
        .and_then(Value::as_str);
    let outcome = event.payload_json.get("outcome").and_then(Value::as_str);
    if event
        .payload_json
        .get("message_role")
        .and_then(Value::as_str)
        == Some("user")
    {
        return true;
    }
    if event.event_type == AgentEventType::Waiting {
        let active = event
            .payload_json
            .get("session_active")
            .and_then(Value::as_bool)
            == Some(true);
        if active || matches!(source_event, Some("waiting" | "legacy" | "unclassified")) {
            return true;
        }
    }

    match event.source {
        AgentSource::Codex => {
            matches!(
                source_event,
                Some(
                    "UserPromptSubmit"
                        | "PreToolUse"
                        | "PermissionRequest"
                        | "PreCompact"
                        | "SubagentStart"
                )
            ) || (source_event == Some("app_server_activity")
                && event
                    .payload_json
                    .get("session_active")
                    .and_then(Value::as_bool)
                    == Some(true))
        }
        AgentSource::ClaudeCode => {
            matches!(
                source_event,
                Some(
                    "UserPromptSubmit"
                        | "PreToolUse"
                        | "PermissionRequest"
                        | "PreCompact"
                        | "SubagentStart"
                        | "TaskCreated"
                        | "Elicitation"
                )
            ) || (source_event == Some("Stop") && outcome == Some("background_active"))
        }
        AgentSource::Pi => matches!(
            source_event,
            Some(
                "input"
                    | "before_agent_start"
                    | "agent_start"
                    | "turn_start"
                    | "session_before_compact"
                    | "tool_call"
                    | "tool_execution_start"
            )
        ),
        AgentSource::Opencode => {
            matches!(
                source_event,
                Some(
                    "message.user"
                        | "session.next.prompt.admitted"
                        | "session.compaction.started"
                        | "tool.execute.before"
                        | "command.execute.before"
                        | "permission.asked"
                        | "permission.updated"
                        | "permission.v2.asked"
                        | "question.asked"
                        | "question.v2.asked"
                )
            ) || (source_event == Some("session.status")
                && matches!(outcome, Some("busy" | "retry")))
        }
    }
}

/// Returns whether a connector event can prove that an ordinary Agent task
/// reached PetCore. `affects_activity` is the adapter's primary semantic
/// signal; the explicit lifecycle exclusions are a defense in depth for old
/// or malformed connector payloads that marked a host open/close edge active.
pub(crate) fn source_event_proves_ordinary_activity(
    source_event: &str,
    affects_activity: bool,
) -> bool {
    affects_activity
        && !matches!(
            source_event,
            "SessionStart"
                | "SessionEnd"
                | "session_start"
                | "session_shutdown"
                | "session.created"
                | "session.deleted"
                | "session.idle"
                | "session.status"
                | "session.error"
                | "session.next.step.ended"
                | "session.next.step.failed"
                | "connector.probe"
                | "connection.test"
                | "app_server_activity"
                | "legacy"
                | "unclassified"
        )
}
const FUTURE_EVENT_GRACE_SECONDS: i64 = 60;

const AGENT_EVENT_ALLOWED_FIELDS: &[&str] = &[
    "id",
    "source",
    "project_path",
    "session_id",
    "event_type",
    "title",
    "detail",
    "payload",
    "payload_json",
    "created_at",
];

const EVENT_ENVELOPE_ALLOWED_FIELDS: &[&str] = &[
    "schema_version",
    "external_event_id",
    "source_event",
    "contract_version",
    "tool_name",
    "outcome",
    "diagnostic",
    "affects_activity",
    "turn_id",
    "session_active",
    "message_role",
    "message_content",
    "activity_kind",
    "activity_content",
    "interaction_kind",
    "project_label",
    "session_title",
    "session_open",
    "session_surface",
    "terminal_app",
    "session_open_url",
];

pub struct NormalizedAgentEvent;

impl NormalizedAgentEvent {
    pub fn from_external(
        source: AgentSource,
        value: Value,
        received_at: &str,
    ) -> Result<AgentEvent> {
        let object = value
            .as_object()
            .ok_or_else(|| invalid_event("agent event params must be a JSON object"))?;
        validate_event_fields(object)?;
        validate_declared_source(source, object)?;
        let payload = external_payload(object)?;
        validate_payload_fields(payload)?;
        let event_type = required_event_type(object)?;
        let session_id = optional_bounded_string(object, "session_id", MAX_SESSION_ID_BYTES)?
            .and_then(normalize_optional_identity);
        let external_event_id = external_event_id(source, object, payload, &value)?;
        // `title` and `detail` are deprecated compatibility aliases. Validate
        // their types, but never persist external display text. Visible copy is
        // derived only from the closed event type vocabulary.
        let _ = optional_bounded_string(object, "title", usize::MAX)?;
        let _ = optional_bounded_string(object, "detail", usize::MAX)?;
        let title = event_type.zh_label().to_string();
        let detail = None;
        let project_path = optional_bounded_string(object, "project_path", usize::MAX)?
            .map(|value| truncate_utf8(&value, MAX_PROJECT_PATH_BYTES));
        let created_at = normalized_created_at(
            optional_bounded_string(object, "created_at", 128)?.as_deref(),
            received_at,
        );
        let payload_json = strict_payload(&external_event_id, payload, Some(enum_name(event_type)));

        Ok(AgentEvent {
            id: external_event_id,
            source,
            project_path,
            session_id,
            event_type,
            title,
            detail,
            payload_json,
            created_at,
        })
    }
}

pub(crate) fn normalized_session_key(session_id: Option<&str>) -> String {
    match session_id.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => format!("1:{value}"),
        None => "0:".to_string(),
    }
}

pub(crate) fn normalized_session_id(session_id: Option<&str>) -> Option<String> {
    session_id.and_then(|value| normalize_optional_identity(value.to_string()))
}

pub(crate) fn persisted_payload(event: &AgentEvent) -> Value {
    strict_payload(
        &event.id,
        event.payload_json.as_object(),
        Some(enum_name(event.event_type)),
    )
}

pub(crate) fn minimal_legacy_payload(external_event_id: &str) -> Value {
    json!({
        "schema_version": EVENT_ENVELOPE_SCHEMA_VERSION,
        "external_event_id": external_event_id,
        "source_event": "legacy",
        "contract_version": null,
        "tool_name": null,
        "outcome": null,
        "diagnostic": false,
        "affects_activity": true,
        "turn_id": null,
        "session_active": false,
        "message_role": null,
        "message_content": null,
        "activity_kind": null,
        "activity_content": null,
        "interaction_kind": null,
        "project_label": null,
        "session_title": null,
        "session_open": null,
        "session_surface": null,
        "terminal_app": null,
        "session_open_url": null,
    })
}

fn validate_event_fields(object: &Map<String, Value>) -> Result<()> {
    if let Some(key) = object
        .keys()
        .find(|key| !AGENT_EVENT_ALLOWED_FIELDS.contains(&key.as_str()))
    {
        return Err(invalid_event(format!(
            "agent event field is not supported: {key}"
        )));
    }
    Ok(())
}

fn validate_declared_source(
    expected_source: AgentSource,
    object: &Map<String, Value>,
) -> Result<()> {
    let Some(value) = object.get("source") else {
        return Ok(());
    };
    let declared = value
        .as_str()
        .ok_or_else(|| invalid_event("agent event source must be a string"))?;
    let declared = enum_from_name::<AgentSource>(declared)
        .map_err(|_| invalid_event("agent event source is not supported"))?;
    if declared != expected_source {
        return Err(invalid_event(
            "agent event source does not match the trusted transport source",
        ));
    }
    Ok(())
}

fn external_payload(object: &Map<String, Value>) -> Result<Option<&Map<String, Value>>> {
    if object.contains_key("payload") && object.contains_key("payload_json") {
        return Err(invalid_event(
            "agent event accepts only one of payload or payload_json",
        ));
    }
    let payload = object.get("payload").or_else(|| object.get("payload_json"));
    match payload {
        Some(Value::Object(payload)) => Ok(Some(payload)),
        Some(_) => Err(invalid_event("agent event payload must be a JSON object")),
        None => Ok(None),
    }
}

fn validate_payload_fields(payload: Option<&Map<String, Value>>) -> Result<()> {
    let Some(payload) = payload else {
        return Ok(());
    };
    if let Some(key) = payload
        .keys()
        .find(|key| !EVENT_ENVELOPE_ALLOWED_FIELDS.contains(&key.as_str()))
    {
        return Err(invalid_event(format!(
            "agent event payload field is not supported: {key}"
        )));
    }
    if let Some(version) = payload.get("schema_version") {
        if version.as_str() != Some(EVENT_ENVELOPE_SCHEMA_VERSION) {
            return Err(invalid_event(format!(
                "agent event payload schema_version must be {EVENT_ENVELOPE_SCHEMA_VERSION}"
            )));
        }
    }
    for key in [
        "external_event_id",
        "source_event",
        "contract_version",
        "tool_name",
        "outcome",
    ] {
        if let Some(value) = payload.get(key) {
            if !(value.is_null() || value.as_str().is_some()) {
                return Err(invalid_event(format!(
                    "agent event payload {key} must be a string or null"
                )));
            }
        }
    }
    if let Some(value) = payload.get("diagnostic") {
        if !value.is_boolean() {
            return Err(invalid_event(
                "agent event payload diagnostic must be a boolean",
            ));
        }
    }
    if let Some(value) = payload.get("affects_activity") {
        if !value.is_boolean() {
            return Err(invalid_event(
                "agent event payload affects_activity must be a boolean",
            ));
        }
    }
    if let Some(value) = payload.get("session_active") {
        if !value.is_boolean() {
            return Err(invalid_event(
                "agent event payload session_active must be a boolean",
            ));
        }
    }
    if let Some(value) = payload.get("session_open") {
        if !(value.is_null() || value.is_boolean()) {
            return Err(invalid_event(
                "agent event payload session_open must be a boolean or null",
            ));
        }
    }
    for (key, maximum_bytes) in [
        ("external_event_id", MAX_EVENT_ID_BYTES),
        ("contract_version", MAX_CONTRACT_VERSION_BYTES),
        ("turn_id", MAX_TURN_ID_BYTES),
        ("message_content", MAX_MESSAGE_CONTENT_BYTES),
        ("activity_content", MAX_ACTIVITY_CONTENT_BYTES),
        ("project_label", MAX_PROJECT_LABEL_BYTES),
        ("session_title", MAX_SESSION_TITLE_BYTES),
        ("session_open_url", MAX_SESSION_OPEN_URL_BYTES),
    ] {
        if let Some(value) = payload.get(key) {
            match value {
                Value::Null => {}
                Value::String(value) if value.len() <= maximum_bytes => {}
                Value::String(_) => {
                    return Err(invalid_event(format!(
                        "agent event payload {key} exceeds {maximum_bytes} UTF-8 bytes"
                    )));
                }
                _ => {
                    return Err(invalid_event(format!(
                        "agent event payload {key} must be a string or null"
                    )));
                }
            }
        }
    }
    if payload
        .get("external_event_id")
        .and_then(Value::as_str)
        .is_some_and(|value| value.trim().is_empty())
    {
        return Err(invalid_event(
            "agent event payload external_event_id must be 1-256 UTF-8 bytes",
        ));
    }
    validate_optional_enum(payload, "message_role", &["user", "assistant"])?;
    validate_optional_enum(
        payload,
        "activity_kind",
        &[
            "thinking",
            "plan",
            "command",
            "file",
            "file_change",
            "tool",
            "subagent",
            "search",
            "network",
            "image",
            "compaction",
        ],
    )?;
    validate_optional_enum(
        payload,
        "interaction_kind",
        &["approval_required", "input_required", "review_required"],
    )?;
    validate_optional_enum(
        payload,
        "session_surface",
        &["chatgpt_app", "cli_terminal", "unknown"],
    )?;
    validate_optional_enum(
        payload,
        "terminal_app",
        &["warp", "terminal", "iterm2", "ghostty", "unknown"],
    )?;
    if let Some(Value::String(value)) = payload.get("session_open_url") {
        if validated_warp_focus_url(value).is_none() {
            return Err(invalid_event(
                "agent event payload session_open_url is not a supported session URL",
            ));
        }
    }
    Ok(())
}

fn required_event_type(object: &Map<String, Value>) -> Result<AgentEventType> {
    let value = object
        .get("event_type")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_event("agent event event_type must be a string"))?;
    enum_from_name(value).map_err(|_| invalid_event("agent event event_type is not supported"))
}

fn external_event_id(
    source: AgentSource,
    object: &Map<String, Value>,
    payload: Option<&Map<String, Value>>,
    canonical_input: &Value,
) -> Result<String> {
    let supplied = optional_bounded_string(object, "id", MAX_EVENT_ID_BYTES)?.or_else(|| {
        payload
            .and_then(|payload| payload.get("external_event_id"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    });
    if let Some(supplied) = supplied {
        let supplied = supplied.trim();
        if supplied.is_empty() || supplied.len() > MAX_EVENT_ID_BYTES {
            return Err(invalid_event("agent event id must be 1-256 UTF-8 bytes"));
        }
        return Ok(supplied.to_string());
    }

    let mut digest = Sha256::new();
    digest.update(enum_name(source));
    digest.update([0]);
    digest.update(serde_json::to_vec(canonical_input)?);
    Ok(format!("evt_external_{:x}", digest.finalize()))
}

fn strict_payload(
    external_event_id: &str,
    payload: Option<&Map<String, Value>>,
    default_source_event: Option<String>,
) -> Value {
    let source_event = payload
        .and_then(|payload| payload.get("source_event"))
        .and_then(Value::as_str)
        .map(normalized_source_event)
        .or_else(|| default_source_event.as_deref().map(normalized_source_event))
        .unwrap_or("unclassified");
    let tool_name = payload
        .and_then(|payload| payload.get("tool_name"))
        .and_then(Value::as_str)
        .map(normalized_tool_category)
        .map(Value::String)
        .unwrap_or(Value::Null);
    let outcome = payload
        .and_then(|payload| payload.get("outcome"))
        .and_then(Value::as_str)
        .map(normalized_outcome)
        .map(Value::String)
        .unwrap_or(Value::Null);
    let contract_version =
        normalized_optional_payload_string(payload, "contract_version", MAX_CONTRACT_VERSION_BYTES);
    let diagnostic = payload
        .and_then(|payload| payload.get("diagnostic"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let affects_activity = !diagnostic
        && payload
            .and_then(|payload| payload.get("affects_activity"))
            .and_then(Value::as_bool)
            .unwrap_or(true);
    let turn_id = normalized_optional_payload_string(payload, "turn_id", MAX_TURN_ID_BYTES);
    let session_active = payload
        .and_then(|payload| payload.get("session_active"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let message_role = payload
        .and_then(|payload| payload.get("message_role"))
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "user" | "assistant"))
        .map(|value| Value::String(value.to_string()))
        .unwrap_or(Value::Null);
    let message_content =
        normalized_optional_payload_string(payload, "message_content", MAX_MESSAGE_CONTENT_BYTES);
    let activity_kind = normalized_optional_payload_enum(
        payload,
        "activity_kind",
        &[
            "thinking",
            "plan",
            "command",
            "file",
            "file_change",
            "tool",
            "subagent",
            "search",
            "network",
            "image",
            "compaction",
        ],
    );
    let activity_content =
        normalized_optional_payload_string(payload, "activity_content", MAX_ACTIVITY_CONTENT_BYTES);
    let interaction_kind = payload
        .and_then(|payload| payload.get("interaction_kind"))
        .and_then(Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "approval_required" | "input_required" | "review_required"
            )
        })
        .map(|value| Value::String(value.to_string()))
        .unwrap_or(Value::Null);
    let project_label =
        normalized_optional_payload_string(payload, "project_label", MAX_PROJECT_LABEL_BYTES);
    let session_title =
        normalized_optional_payload_string(payload, "session_title", MAX_SESSION_TITLE_BYTES);
    let session_open = payload
        .and_then(|payload| payload.get("session_open"))
        .and_then(Value::as_bool)
        .map(Value::Bool)
        .unwrap_or(Value::Null);
    let session_surface = normalized_optional_payload_enum(
        payload,
        "session_surface",
        &["chatgpt_app", "cli_terminal", "unknown"],
    );
    let terminal_app = normalized_optional_payload_enum(
        payload,
        "terminal_app",
        &["warp", "terminal", "iterm2", "ghostty", "unknown"],
    );
    let session_open_url = payload
        .and_then(|payload| payload.get("session_open_url"))
        .and_then(Value::as_str)
        .and_then(validated_warp_focus_url)
        .map(Value::String)
        .unwrap_or(Value::Null);

    json!({
        "schema_version": EVENT_ENVELOPE_SCHEMA_VERSION,
        "external_event_id": external_event_id,
        "source_event": source_event,
        "contract_version": contract_version,
        "tool_name": tool_name,
        "outcome": outcome,
        "diagnostic": diagnostic,
        "affects_activity": affects_activity,
        "turn_id": turn_id,
        "session_active": session_active,
        "message_role": message_role,
        "message_content": message_content,
        "activity_kind": activity_kind,
        "activity_content": activity_content,
        "interaction_kind": interaction_kind,
        "project_label": project_label,
        "session_title": session_title,
        "session_open": session_open,
        "session_surface": session_surface,
        "terminal_app": terminal_app,
        "session_open_url": session_open_url,
    })
}

fn validate_optional_enum(payload: &Map<String, Value>, key: &str, allowed: &[&str]) -> Result<()> {
    let Some(value) = payload.get(key) else {
        return Ok(());
    };
    match value {
        Value::Null => Ok(()),
        Value::String(value) if allowed.contains(&value.as_str()) => Ok(()),
        Value::String(_) => Err(invalid_event(format!(
            "agent event payload {key} is not supported"
        ))),
        _ => Err(invalid_event(format!(
            "agent event payload {key} must be a string or null"
        ))),
    }
}

fn normalized_optional_payload_string(
    payload: Option<&Map<String, Value>>,
    key: &str,
    maximum_bytes: usize,
) -> Value {
    payload
        .and_then(|payload| payload.get(key))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| Value::String(truncate_utf8(value, maximum_bytes)))
        .unwrap_or(Value::Null)
}

fn normalized_optional_payload_enum(
    payload: Option<&Map<String, Value>>,
    key: &str,
    allowed: &[&str],
) -> Value {
    payload
        .and_then(|payload| payload.get(key))
        .and_then(Value::as_str)
        .filter(|value| allowed.contains(value))
        .map(|value| Value::String(value.to_string()))
        .unwrap_or(Value::Null)
}

pub(crate) fn validated_warp_focus_url(value: &str) -> Option<String> {
    if value.trim() != value {
        return None;
    }
    let uuid = value
        .strip_prefix("warp://session/")
        .or_else(|| value.strip_prefix("warppreview://session/"))?;
    (uuid.len() == 32 && uuid.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| value.to_string())
}

fn normalized_source_event(value: &str) -> &'static str {
    match value {
        "start" => "start",
        "tool" => "tool",
        "waiting" => "waiting",
        "review" => "review",
        "done" => "done",
        "failed" => "failed",
        "SessionStart" => "SessionStart",
        "Setup" => "Setup",
        "InstructionsLoaded" => "InstructionsLoaded",
        "UserPromptSubmit" => "UserPromptSubmit",
        "UserPromptExpansion" => "UserPromptExpansion",
        "PreToolUse" => "PreToolUse",
        "PermissionRequest" => "PermissionRequest",
        "PostToolUse" => "PostToolUse",
        "PostToolUseFailure" => "PostToolUseFailure",
        "Stop" => "Stop",
        "StopFailure" => "StopFailure",
        "SessionEnd" => "SessionEnd",
        "Notification" => "Notification",
        "Elicitation" => "Elicitation",
        "ElicitationResult" => "ElicitationResult",
        "PostToolBatch" => "PostToolBatch",
        "PermissionDenied" => "PermissionDenied",
        "PreCompact" => "PreCompact",
        "PostCompact" => "PostCompact",
        "SubagentStart" => "SubagentStart",
        "SubagentStop" => "SubagentStop",
        "TaskCreated" => "TaskCreated",
        "TaskCompleted" => "TaskCompleted",
        "TeammateIdle" => "TeammateIdle",
        "ConfigChange" => "ConfigChange",
        "CwdChanged" => "CwdChanged",
        "WorktreeRemove" => "WorktreeRemove",
        "session_start" => "session_start",
        "input" => "input",
        "before_agent_start" => "before_agent_start",
        "agent_start" => "agent_start",
        "turn_start" => "turn_start",
        "turn_end" => "turn_end",
        "tool_call" => "tool_call",
        "tool_execution_start" => "tool_execution_start",
        "tool_execution_end" => "tool_execution_end",
        "message_end" => "message_end",
        "session_before_compact" => "session_before_compact",
        "session_compact" => "session_compact",
        "agent_settled" => "agent_settled",
        "agent_end" => "agent_end",
        "session_shutdown" => "session_shutdown",
        "session.created" => "session.created",
        "session.deleted" => "session.deleted",
        "session.status" => "session.status",
        "session.idle" => "session.idle",
        "session.error" => "session.error",
        "permission.asked" => "permission.asked",
        "permission.updated" => "permission.updated",
        "permission.replied" => "permission.replied",
        "permission.v2.asked" => "permission.v2.asked",
        "permission.v2.replied" => "permission.v2.replied",
        "question.asked" => "question.asked",
        "question.replied" => "question.replied",
        "question.rejected" => "question.rejected",
        "question.v2.asked" => "question.v2.asked",
        "question.v2.replied" => "question.v2.replied",
        "question.v2.rejected" => "question.v2.rejected",
        "session.next.prompt.admitted" => "session.next.prompt.admitted",
        "session.next.step.ended" => "session.next.step.ended",
        "session.next.step.failed" => "session.next.step.failed",
        "message.user" => "message.user",
        "message.assistant" => "message.assistant",
        "tool.execute.before" => "tool.execute.before",
        "tool.execute.after" => "tool.execute.after",
        "command.execute.before" => "command.execute.before",
        "command.execute.after" => "command.execute.after",
        "session.compaction.started" => "session.compaction.started",
        "session.compaction.ended" => "session.compaction.ended",
        "session.plan.updated" => "session.plan.updated",
        "connector.probe" => "connector.probe",
        "connection.test" => "connection.test",
        "app_server_activity" => "app_server_activity",
        "legacy" => "legacy",
        _ => "unclassified",
    }
}

fn normalized_tool_category(value: &str) -> String {
    let name = value.trim().to_ascii_lowercase();
    let category = match name.as_str() {
        "bash" | "shell" | "terminal" | "command" | "cmd" | "powershell" => "shell",
        "read" | "write" | "file" | "files" | "filesystem" | "ls" | "glob" => "filesystem",
        "edit" | "patch" | "apply_patch" | "replace" => "editor",
        "grep" | "rg" | "find" | "search" | "code_search" => "search",
        "web" | "http" | "fetch" | "browser" | "curl" | "wget" => "network",
        "task" | "agent" | "subagent" => "agent",
        _ => "other",
    };
    category.to_string()
}

fn normalized_outcome(value: &str) -> String {
    let value = value.trim();
    match value {
        "started"
        | "completed"
        | "permission_requested"
        | "tool_failure"
        | "api_failure"
        | "settled"
        | "created"
        | "idle"
        | "busy"
        | "retry"
        | "permission_replied"
        | "permission_replied_once"
        | "permission_replied_always"
        | "permission_replied_allow"
        | "permission_replied_deny"
        | "permission_replied_reject"
        | "started_without_args"
        | "session_failure"
        | "observed"
        | "auto_denied"
        | "background_active"
        | "agent_completed" => value.to_string(),
        "session_closed" | "input_requested" | "message" | "continued" | "prompt_admitted" => {
            value.to_string()
        }
        _ => "unknown".to_string(),
    }
}

fn optional_bounded_string(
    object: &Map<String, Value>,
    key: &str,
    maximum_bytes: usize,
) -> Result<Option<String>> {
    match object.get(key) {
        Some(Value::String(value)) if value.len() <= maximum_bytes => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid_event(format!(
            "agent event {key} exceeds {maximum_bytes} UTF-8 bytes"
        ))),
        Some(Value::Null) | None => Ok(None),
        Some(_) => Err(invalid_event(format!(
            "agent event {key} must be a string or null"
        ))),
    }
}

fn normalize_optional_identity(value: String) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn normalized_created_at(value: Option<&str>, received_at: &str) -> String {
    let Ok(received) = OffsetDateTime::parse(received_at, &Rfc3339) else {
        return received_at.to_string();
    };
    let Some(value) = value else {
        return received_at.to_string();
    };
    let Ok(created) = OffsetDateTime::parse(value, &Rfc3339) else {
        return received_at.to_string();
    };
    if created - received > time::Duration::seconds(FUTURE_EVENT_GRACE_SECONDS) {
        received_at.to_string()
    } else {
        value.to_string()
    }
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

fn invalid_event(message: impl Into<String>) -> PetCoreError {
    PetCoreError::InvalidRequest(format!("invalid params: {}", message.into()))
}
