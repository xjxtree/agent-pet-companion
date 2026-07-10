use crate::{enum_from_name, enum_name, PetCoreError, Result};
use petcore_types::{AgentEvent, AgentEventType, AgentSource};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

pub const EVENT_ENVELOPE_SCHEMA_VERSION: &str = "apc.agent-event.v1";
pub const MAX_EVENT_TITLE_BYTES: usize = 160;
pub const MAX_EVENT_DETAIL_BYTES: usize = 512;
pub const MAX_RECENT_EVENTS: usize = 200;

const MAX_EVENT_ID_BYTES: usize = 256;
const MAX_SESSION_ID_BYTES: usize = 256;
const MAX_PROJECT_PATH_BYTES: usize = 1_024;
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
    "tool_name",
    "outcome",
    "diagnostic",
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
        "tool_name": null,
        "outcome": null,
        "diagnostic": false,
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
    for key in ["external_event_id", "source_event", "tool_name", "outcome"] {
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
    let diagnostic = payload
        .and_then(|payload| payload.get("diagnostic"))
        .and_then(Value::as_bool)
        .unwrap_or(false);

    json!({
        "schema_version": EVENT_ENVELOPE_SCHEMA_VERSION,
        "external_event_id": external_event_id,
        "source_event": source_event,
        "tool_name": tool_name,
        "outcome": outcome,
        "diagnostic": diagnostic,
    })
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
        "UserPromptSubmit" => "UserPromptSubmit",
        "PreToolUse" => "PreToolUse",
        "PermissionRequest" => "PermissionRequest",
        "PostToolUse" => "PostToolUse",
        "PostToolUseFailure" => "PostToolUseFailure",
        "Stop" => "Stop",
        "StopFailure" => "StopFailure",
        "session_start" => "session_start",
        "before_agent_start" => "before_agent_start",
        "agent_start" => "agent_start",
        "tool_call" => "tool_call",
        "tool_execution_start" => "tool_execution_start",
        "tool_execution_end" => "tool_execution_end",
        "agent_settled" => "agent_settled",
        "session.created" => "session.created",
        "session.status" => "session.status",
        "session.idle" => "session.idle",
        "session.error" => "session.error",
        "permission.asked" => "permission.asked",
        "permission.updated" => "permission.updated",
        "permission.replied" => "permission.replied",
        "tool.execute.before" => "tool.execute.before",
        "tool.execute.after" => "tool.execute.after",
        "connection.test" => "connection.test",
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
        | "session_failure" => value.to_string(),
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
