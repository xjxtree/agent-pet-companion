use crate::agent_state;
use crate::connections;
use crate::db::{BehaviorSettingsPatch, Database, InsertEventOutcome};
use crate::event_envelope::{NormalizedAgentEvent, MAX_RECENT_EVENTS};
use crate::generation;
use crate::metrics;
use crate::paths::AppPaths;
use crate::petpack;
use crate::runtime_manifest::RuntimeReleaseManifest;
use crate::{app_server, enum_from_name, enum_name, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentEvent, AgentEventType, AgentSource, BehaviorSettings,
    FpsProfileName, GenerationForm, OverlayPlacement, QualityLevel,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const SNAPSHOT_EVENT_SCAN_LIMIT: usize = 256;
const SNAPSHOT_RECENT_EVENT_LIMIT: usize = 8;
const SNAPSHOT_OVERLAY_EVENT_LIMIT: usize = 8;
const FUTURE_EVENT_GRACE_SECONDS: i64 = 60;
const MAX_RPC_BATCH_ITEMS: usize = 64;
const MAX_RPC_ENCODED_RESPONSE_BYTES: usize = 256 * 1024;
const MAX_RPC_ERROR_MESSAGE_BYTES: usize = 512;
pub use crate::runtime_manifest::{PETCORE_BUILD_ID, PETCORE_RPC_PROTOCOL_VERSION};
const MIN_OVERLAY_SCALE: f64 = 0.10;
const MAX_OVERLAY_SCALE: f64 = 1.8;
const CODEX_THREAD_DISPLAY_REFRESH_SECONDS: u64 = 30;
const CODEX_ACTIVE_THREAD_DISPLAY_REFRESH_SECONDS: u64 = 3;
const MAX_CODEX_THREAD_DISPLAY_CACHE_ENTRIES: usize = 64;
const CODEX_ACTIVITY_REFRESH_SECONDS: u64 = 1;
const MAX_FALLBACK_SESSION_TITLE_CHARS: usize = 80;
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

#[derive(Debug, Clone)]
pub struct CoreState {
    pub paths: AppPaths,
    pub database: Database,
    instance_id: String,
    codex_thread_display_cache: Arc<Mutex<CodexThreadDisplayCache>>,
    codex_activity_sync_enabled: bool,
    codex_activity_sync: Arc<Mutex<CodexActivitySyncState>>,
    shutdown_requested: Arc<AtomicBool>,
}

#[derive(Debug, Default)]
struct CodexThreadDisplayCache {
    entries: BTreeMap<String, CachedCodexThreadDisplay>,
    in_flight: BTreeSet<String>,
}

#[derive(Debug, Clone)]
struct CachedCodexThreadDisplay {
    event_marker: String,
    fetched_at: Instant,
    display: Option<app_server::CodexThreadDisplay>,
}

#[derive(Debug, Default)]
struct CodexActivitySyncState {
    in_flight: bool,
    last_started_at: Option<Instant>,
    observations: BTreeMap<String, CodexActivityObservation>,
}

#[derive(Debug, Clone)]
struct CodexActivityObservation {
    turn_id: Option<String>,
    updated_at_unix: i64,
    display_revision: String,
    inferred_activity: Option<app_server::CodexThreadDisplayActivity>,
}

impl CoreState {
    pub fn new(paths: AppPaths) -> Self {
        let database = Database::new(paths.db_path.clone());
        Self {
            paths,
            database,
            instance_id: new_id("embedded_instance"),
            codex_thread_display_cache: Arc::new(Mutex::new(CodexThreadDisplayCache::default())),
            codex_activity_sync_enabled: false,
            codex_activity_sync: Arc::new(Mutex::new(CodexActivitySyncState::default())),
            shutdown_requested: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn with_instance_id(mut self, instance_id: impl Into<String>) -> Self {
        self.instance_id = instance_id.into();
        self
    }

    pub fn with_codex_activity_sync(mut self, enabled: bool) -> Self {
        self.codex_activity_sync_enabled = enabled;
        self
    }

    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    pub fn shutdown_requested(&self) -> bool {
        self.shutdown_requested.load(Ordering::Acquire)
    }

    fn request_shutdown(&self) {
        self.shutdown_requested.store(true, Ordering::Release);
    }

    pub fn ensure_ready(&self) -> Result<()> {
        self.paths.ensure()?;
        self.database.init()?;
        generation::recover_interrupted_jobs_for_instance(
            &self.paths,
            &self.database,
            &self.instance_id,
        )?;
        Ok(())
    }

    fn codex_thread_display(
        &self,
        session_id: &str,
        event_marker: &str,
        refresh_seconds: u64,
    ) -> Option<app_server::CodexThreadDisplay> {
        let now = Instant::now();
        let mut cache = self.codex_thread_display_cache.lock().ok()?;
        let cached = cache.entries.get(session_id).cloned();
        let needs_refresh = cached.as_ref().is_none_or(|entry| {
            entry.event_marker != event_marker
                || now.duration_since(entry.fetched_at) >= Duration::from_secs(refresh_seconds)
        });
        if needs_refresh && cache.in_flight.insert(session_id.to_string()) {
            let shared_cache = Arc::clone(&self.codex_thread_display_cache);
            let session_id = session_id.to_string();
            let event_marker = event_marker.to_string();
            thread::spawn(move || {
                let fetched = app_server::read_codex_thread_display(&session_id).ok();
                let Ok(mut cache) = shared_cache.lock() else {
                    return;
                };
                cache.in_flight.remove(&session_id);
                let previous = cache
                    .entries
                    .get(&session_id)
                    .filter(|entry| entry.event_marker == event_marker)
                    .and_then(|entry| entry.display.clone());
                if cache.entries.len() >= MAX_CODEX_THREAD_DISPLAY_CACHE_ENTRIES
                    && !cache.entries.contains_key(&session_id)
                {
                    if let Some(oldest_key) = cache
                        .entries
                        .iter()
                        .min_by_key(|(_, entry)| entry.fetched_at)
                        .map(|(key, _)| key.clone())
                    {
                        cache.entries.remove(&oldest_key);
                    }
                }
                cache.entries.insert(
                    session_id,
                    CachedCodexThreadDisplay {
                        event_marker,
                        fetched_at: Instant::now(),
                        display: fetched.or(previous),
                    },
                );
            });
        }
        cached
            .filter(|entry| entry.event_marker == event_marker)
            .and_then(|entry| entry.display)
    }

    fn refresh_codex_activity(&self, behavior: &BehaviorSettings) {
        if !self.codex_activity_sync_enabled
            || !behavior.enabled
            || !behavior
                .sources
                .get(&AgentSource::Codex)
                .copied()
                .unwrap_or(false)
        {
            return;
        }
        let now = Instant::now();
        let Ok(mut sync) = self.codex_activity_sync.lock() else {
            return;
        };
        if sync.in_flight
            || sync.last_started_at.is_some_and(|started_at| {
                now.duration_since(started_at) < Duration::from_secs(CODEX_ACTIVITY_REFRESH_SECONDS)
            })
        {
            return;
        }
        sync.in_flight = true;
        sync.last_started_at = Some(now);
        drop(sync);

        let database = self.database.clone();
        let shared_sync = Arc::clone(&self.codex_activity_sync);
        let maximum_age = Duration::from_secs(
            u64::from(behavior.session_message_timeout_minutes).saturating_mul(60),
        );
        thread::spawn(move || {
            let mut activities = app_server::read_codex_recent_thread_activities(
                maximum_age,
                app_server::MAX_RECENT_CODEX_ACTIVITY_THREADS,
            )
            .unwrap_or_default();
            let Ok(mut sync) = shared_sync.lock() else {
                return;
            };
            let observed_threads = activities
                .iter()
                .map(|activity| activity.thread_id.clone())
                .collect::<BTreeSet<_>>();
            for activity in &mut activities {
                reconcile_codex_activity_observation(&mut sync.observations, activity);
            }
            sync.observations
                .retain(|thread_id, _| observed_threads.contains(thread_id));
            sync.in_flight = false;
            drop(sync);

            let existing = database
                .latest_sequenced_events_by_session(SNAPSHOT_EVENT_SCAN_LIMIT)
                .unwrap_or_default();
            for activity in activities {
                let preserve_exact_state = should_preserve_exact_codex_state(&existing, &activity);
                for event in codex_activity_events(activity) {
                    if preserve_exact_state && event.id.starts_with("evt_codex_app_server_status_")
                    {
                        continue;
                    }
                    let _ = database.upsert_codex_activity_event(&event);
                }
            }
        });
    }
}

fn reconcile_codex_activity_observation(
    observations: &mut BTreeMap<String, CodexActivityObservation>,
    activity: &mut app_server::CodexThreadActivity,
) {
    let previous = observations.get(&activity.thread_id);
    let same_visible_revision = previous.is_some_and(|previous| {
        previous.turn_id == activity.turn_id
            && previous.display_revision == activity.display_revision
    });
    let visible_clock_advanced = previous.is_some_and(|previous| {
        same_visible_revision && activity.updated_at_unix > previous.updated_at_unix
    });
    let running = matches!(
        activity.event_type,
        AgentEventType::Start | AgentEventType::Tool
    );
    let raw_activity = activity.latest_activity.clone();
    let inferred_activity = if running && visible_clock_advanced {
        // A separately spawned App Server sees the thread timestamp advance,
        // but persisted turns intentionally omit some live interactions (most
        // notably command executions). Do not keep showing the preceding
        // reasoning/file-change item as if it were still current.
        Some(hidden_codex_activity(raw_activity.as_ref()))
    } else if running && same_visible_revision {
        previous.and_then(|previous| previous.inferred_activity.clone())
    } else if running
        && previous.is_some()
        && raw_activity
            .as_ref()
            .is_some_and(|candidate| !candidate.is_current)
    {
        // A newly persisted completed operation proves the previous public
        // activity ended. Use a neutral processing state until App Server
        // persists the following reasoning/message, rather than reviving an
        // older assistant reply.
        Some(generic_codex_activity("thinking"))
    } else {
        None
    };

    activity.latest_activity = if !running {
        None
    } else if let Some(inferred) = inferred_activity.clone() {
        Some(inferred)
    } else {
        raw_activity.filter(|candidate| candidate.is_current)
    };
    if running {
        activity.event_type = if activity
            .latest_activity
            .as_ref()
            .is_some_and(|candidate| codex_activity_kind_is_tool(&candidate.kind))
        {
            AgentEventType::Tool
        } else {
            AgentEventType::Start
        };
    }

    observations.insert(
        activity.thread_id.clone(),
        CodexActivityObservation {
            turn_id: activity.turn_id.clone(),
            updated_at_unix: activity.updated_at_unix,
            display_revision: activity.display_revision.clone(),
            inferred_activity,
        },
    );
}

fn hidden_codex_activity(
    previous_visible: Option<&app_server::CodexThreadDisplayActivity>,
) -> app_server::CodexThreadDisplayActivity {
    let kind = if previous_visible.is_none() {
        "thinking"
    } else {
        "tool"
    };
    generic_codex_activity(kind)
}

fn generic_codex_activity(kind: &str) -> app_server::CodexThreadDisplayActivity {
    app_server::CodexThreadDisplayActivity {
        kind: kind.to_string(),
        content: None,
        is_current: true,
    }
}

fn codex_activity_kind_is_tool(kind: &str) -> bool {
    matches!(
        kind,
        "command" | "file" | "file_change" | "tool" | "subagent" | "search" | "network" | "image"
    )
}

fn should_preserve_exact_codex_state(
    existing: &[agent_state::SequencedAgentEvent],
    activity: &app_server::CodexThreadActivity,
) -> bool {
    // App Server activity categories such as command/file/search are rendered
    // as Tool, but they are still only an inferred Running state. A newer
    // hook-backed interaction or terminal state remains authoritative.
    if !matches!(
        activity.event_type,
        AgentEventType::Start | AgentEventType::Tool
    ) {
        return false;
    }
    let Some(exact) = existing.iter().find(|candidate| {
        candidate.event.source == AgentSource::Codex
            && candidate.event.session_id.as_deref() == Some(activity.thread_id.as_str())
            && event_payload_text(&candidate.event, "source_event").as_deref()
                != Some("app_server_activity")
            && matches!(
                candidate.event.event_type,
                AgentEventType::Waiting
                    | AgentEventType::Review
                    | AgentEventType::Done
                    | AgentEventType::Failed
            )
    }) else {
        return false;
    };
    let Ok(exact_at) = OffsetDateTime::parse(&exact.event.created_at, &Rfc3339) else {
        return true;
    };
    activity
        .turn_started_at_unix
        .and_then(|timestamp| OffsetDateTime::from_unix_timestamp(timestamp).ok())
        .is_none_or(|turn_started_at| exact_at >= turn_started_at)
}

fn codex_activity_events(activity: app_server::CodexThreadActivity) -> Vec<AgentEvent> {
    let Some(updated_at) = unix_timestamp_rfc3339(activity.updated_at_unix) else {
        return Vec::new();
    };
    let turn_marker = activity
        .turn_id
        .clone()
        .unwrap_or_else(|| "thread".to_string());
    let mut events = Vec::with_capacity(2);
    if let Some(message) = activity.latest_user_message.as_ref() {
        let created_at = activity
            .turn_started_at_unix
            .and_then(unix_timestamp_rfc3339)
            .unwrap_or_else(|| updated_at.clone());
        events.push(AgentEvent {
            id: format!(
                "evt_codex_app_server_user_{}_{}",
                activity.thread_id, turn_marker
            ),
            source: AgentSource::Codex,
            project_path: None,
            session_id: Some(activity.thread_id.clone()),
            event_type: AgentEventType::Start,
            title: AgentEventType::Start.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "source_event": "app_server_activity",
                "turn_id": activity.turn_id.as_deref(),
                "session_active": false,
                "message_role": "user",
                "message_content": message.content,
                "activity_kind": null,
                "activity_content": null,
                "session_title": activity.title.as_deref(),
                "session_open": true,
                "session_surface": activity.session_surface.as_str(),
                "diagnostic": false
            }),
            created_at,
        });
    }

    let mut payload = json!({
        "source_event": "app_server_activity",
        "turn_id": activity.turn_id.as_deref(),
        "session_active": activity.session_active,
        "session_title": activity.title.as_deref(),
        "session_open": true,
        "session_surface": activity.session_surface.as_str(),
        "interaction_kind": activity.interaction_kind.as_deref(),
        "diagnostic": false
    });
    if let Some(message) = activity.latest_message {
        payload["message_role"] = Value::String(message.role);
        payload["message_content"] = Value::String(message.content);
    }
    if let Some(current_activity) = activity.latest_activity {
        payload["activity_kind"] = Value::String(current_activity.kind);
        if let Some(content) = current_activity.content {
            payload["activity_content"] = Value::String(content);
        }
    }
    events.push(AgentEvent {
        id: format!(
            "evt_codex_app_server_status_{}_{}",
            activity.thread_id, turn_marker
        ),
        source: AgentSource::Codex,
        project_path: None,
        session_id: Some(activity.thread_id),
        event_type: activity.event_type,
        title: activity.event_type.zh_label().to_string(),
        detail: None,
        payload_json: payload,
        created_at: updated_at,
    });
    events
}

fn unix_timestamp_rfc3339(timestamp: i64) -> Option<String> {
    OffsetDateTime::from_unix_timestamp(timestamp)
        .ok()?
        .format(&Rfc3339)
        .ok()
}

#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub jsonrpc: Option<String>,
    pub id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct RpcResponse {
    pub jsonrpc: &'static str,
    pub id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

pub fn handle_json_line(state: &CoreState, line: &str) -> Option<String> {
    let value = match serde_json::from_str::<Value>(line) {
        Ok(value) => value,
        Err(error) => {
            return Some(encode_rpc_value(rpc_error_value(
                Value::Null,
                -32700,
                &error.to_string(),
            )));
        }
    };

    match value {
        Value::Array(values) if values.is_empty() => Some(encode_rpc_value(rpc_error_value(
            Value::Null,
            -32600,
            "batch must not be empty",
        ))),
        Value::Array(values) if values.len() > MAX_RPC_BATCH_ITEMS => {
            Some(encode_rpc_value(rpc_error_value(
                Value::Null,
                -32600,
                &format!("batch exceeds {MAX_RPC_BATCH_ITEMS} requests"),
            )))
        }
        Value::Array(values) => {
            let responses = values
                .into_iter()
                .filter_map(|value| handle_rpc_value(state, value))
                .collect::<Vec<_>>();
            (!responses.is_empty()).then(|| encode_rpc_value(Value::Array(responses)))
        }
        value => handle_rpc_value(state, value).map(encode_rpc_value),
    }
}

pub(crate) fn encoded_error_response(code: i64, message: &str) -> String {
    encode_rpc_value(rpc_error_value(Value::Null, code, message))
}

fn handle_rpc_value(state: &CoreState, value: Value) -> Option<Value> {
    let Some(object) = value.as_object() else {
        return Some(rpc_error_value(
            Value::Null,
            -32600,
            "request must be an object",
        ));
    };
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Some(rpc_error_value(
            Value::Null,
            -32600,
            "jsonrpc must be exactly 2.0",
        ));
    }
    let Some(method) = object.get("method").and_then(Value::as_str) else {
        return Some(rpc_error_value(
            Value::Null,
            -32600,
            "method must be a string",
        ));
    };

    let has_id = object.contains_key("id");
    let response_id = if has_id {
        let id = object.get("id").cloned().unwrap_or(Value::Null);
        if !matches!(id, Value::Null | Value::String(_) | Value::Number(_)) {
            return Some(rpc_error_value(
                Value::Null,
                -32600,
                "id must be a string, number, or null",
            ));
        }
        Some(id)
    } else {
        None
    };
    let notification = !has_id;
    let params = object.get("params").cloned().unwrap_or(Value::Null);

    let response = if !matches!(params, Value::Null | Value::Array(_) | Value::Object(_)) {
        rpc_error_value(
            response_id.clone().unwrap_or(Value::Null),
            -32602,
            "params must be an object or array",
        )
    } else if !known_rpc_method(method) {
        rpc_error_value(
            response_id.clone().unwrap_or(Value::Null),
            -32601,
            &format!("method not found: {method}"),
        )
    } else {
        let request = RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: response_id.clone(),
            method: method.to_string(),
            params,
        };
        match handle_request(state, request) {
            Ok(result) => json!({
                "jsonrpc": "2.0",
                "id": response_id.clone().unwrap_or(Value::Null),
                "result": result,
            }),
            Err(error) => {
                let (code, message) = rpc_error_for_core(error);
                rpc_error_value(response_id.clone().unwrap_or(Value::Null), code, &message)
            }
        }
    };

    (!notification).then_some(response)
}

fn known_rpc_method(method: &str) -> bool {
    matches!(
        method,
        "petcore.health"
            | "petcore.shutdown"
            | "state.snapshot"
            | "state.wait"
            | "behavior.get"
            | "behavior.patch"
            | "overlay.placement.get"
            | "overlay.placement.update"
            | "settings.get"
            | "settings.update"
            | "agent.ingest"
            | "events.recent"
            | "pet.list"
            | "pet.activate"
            | "pet.delete"
            | "petpack.validate"
            | "petpack.import"
            | "petpack.export"
            | "generation.start"
            | "generation.retry"
            | "generation.messages"
            | "generation.for_pet"
            | "generation.edit"
            | "generation.messages.wait"
            | "generation.reply"
            | "generation.cancel"
            | "connections.check"
            | "connections.repair"
            | "connections.uninstall"
            | "connections.test"
            | "renderer.budget"
            | "codex.app_server.probe"
    )
}

fn validate_method_params(method: &str, params: &Value) -> Result<()> {
    let allowed: &[&str] = match method {
        "petcore.health"
        | "state.snapshot"
        | "behavior.get"
        | "overlay.placement.get"
        | "pet.list"
        | "codex.app_server.probe" => &[],
        "petcore.shutdown" => &["expected_instance_id"],
        "state.wait" => &["after_revision", "timeout_ms"],
        "behavior.patch" => &["expected_revision", "changes"],
        "overlay.placement.update" => &["x", "y", "scale", "display_id"],
        "settings.get" => &["key"],
        "settings.update" => &["key", "value"],
        "agent.ingest" => AGENT_EVENT_ALLOWED_FIELDS,
        "events.recent" => &["limit"],
        "pet.activate" | "pet.delete" => &["id"],
        "petpack.validate" => &["path"],
        "petpack.import" => &["path", "expect_absent"],
        "petpack.export" => &["id", "path"],
        "generation.start" => &["description", "style", "quality", "reference_images"],
        "generation.retry" => &["job_id", "form"],
        "generation.messages" | "generation.cancel" => &["job_id"],
        "generation.for_pet" => &["pet_id"],
        "generation.edit" => &["pet_id", "instruction"],
        "generation.messages.wait" => &["job_id", "after_revision", "timeout_ms"],
        "generation.reply" => &["job_id", "content"],
        "connections.check" => &["source"],
        "connections.repair" | "connections.uninstall" | "connections.test" => &["source"],
        "renderer.budget" => &["quality", "fps_profile", "fps"],
        _ => return Ok(()),
    };

    let object = match params {
        Value::Null => return Ok(()),
        Value::Object(object) => object,
        _ => {
            return Err(invalid_params(format!("{method} params must be an object")));
        }
    };
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(invalid_params(format!(
                "{method} does not accept param {key}"
            )));
        }
    }
    Ok(())
}

fn rpc_error_for_core(error: PetCoreError) -> (i64, String) {
    match error {
        PetCoreError::Json(error) => (-32602, error.to_string()),
        PetCoreError::InvalidRequest(message) if invalid_params_message(&message) => {
            (-32602, message)
        }
        PetCoreError::InvalidRequest(message) | PetCoreError::Validation(message) => {
            (-32000, message)
        }
        PetCoreError::Conflict(message) => (-32009, message),
        PetCoreError::Io(_)
        | PetCoreError::Sqlite(_)
        | PetCoreError::Image(_)
        | PetCoreError::Zip(_) => (-32603, "internal error".to_string()),
    }
}

fn invalid_params_message(message: &str) -> bool {
    message.starts_with("invalid params: ")
        || message.starts_with("missing string param ")
        || message == "missing value"
        || message.starts_with("agent event ")
        || message.starts_with("jsonrpc ")
}

fn rpc_error_value(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": bounded_rpc_error_message(message),
        }
    })
}

fn bounded_rpc_error_message(message: &str) -> String {
    if message.len() <= MAX_RPC_ERROR_MESSAGE_BYTES {
        return message.to_string();
    }
    const ELLIPSIS: &str = "…";
    let mut end = MAX_RPC_ERROR_MESSAGE_BYTES - ELLIPSIS.len();
    while !message.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{ELLIPSIS}", &message[..end])
}

fn encode_rpc_value(value: Value) -> String {
    let response_id = value.get("id").cloned().unwrap_or(Value::Null);
    match serde_json::to_string(&value) {
        Ok(encoded) if encoded.len() <= MAX_RPC_ENCODED_RESPONSE_BYTES => encoded,
        Ok(_) => serde_json::to_string(&rpc_error_value(
            response_id,
            -32000,
            &format!("response exceeds {MAX_RPC_ENCODED_RESPONSE_BYTES} encoded bytes"),
        ))
        .unwrap_or_else(|_| internal_serialization_error()),
        Err(_) => internal_serialization_error(),
    }
}

fn internal_serialization_error() -> String {
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"serialization failed\"}}"
        .to_string()
}

pub fn handle_request(state: &CoreState, request: RpcRequest) -> Result<Value> {
    if request.jsonrpc.as_deref() != Some("2.0") {
        return Err(PetCoreError::InvalidRequest(
            "jsonrpc must be 2.0".to_string(),
        ));
    }
    validate_method_params(&request.method, &request.params)?;

    match request.method.as_str() {
        "petcore.health" => Ok(json!({
            "ok": true,
            "version": env!("CARGO_PKG_VERSION"),
            "build_id": PETCORE_BUILD_ID,
            "rpc_protocol": PETCORE_RPC_PROTOCOL_VERSION,
            "runtime_manifest": RuntimeReleaseManifest::compiled(),
            "codex_hooks_contract": crate::adapter_contracts::CODEX_HOOKS_CONTRACT_VERSION,
            "instance_id": state.instance_id,
            "socket": state.paths.socket_path,
            "home": state.paths.home,
            "http_port": read_http_port(&state.paths),
        })),
        "petcore.shutdown" => {
            let expected_instance_id = required_string(&request.params, "expected_instance_id")?;
            if expected_instance_id != state.instance_id {
                return Err(PetCoreError::Conflict(
                    "petcore shutdown target no longer matches the active instance".to_string(),
                ));
            }
            state.request_shutdown();
            Ok(json!({
                "ok": true,
                "instance_id": state.instance_id,
                "build_id": PETCORE_BUILD_ID,
            }))
        }
        "state.snapshot" => state_snapshot(state, false),
        "state.wait" => wait_for_state_change(state, &request.params),
        "behavior.get" => Ok(json!(state.database.behavior_with_revision()?)),
        "behavior.patch" => {
            let expected_revision = required_string(&request.params, "expected_revision")?
                .parse::<u64>()
                .map_err(|_| invalid_params("expected_revision must be a decimal string"))?;
            let changes = request
                .params
                .get("changes")
                .cloned()
                .ok_or_else(|| invalid_params("missing behavior changes"))?;
            let changes: BehaviorSettingsPatch = serde_json::from_value(changes)
                .map_err(|error| invalid_params(format!("invalid behavior changes: {error}")))?;
            Ok(json!(state
                .database
                .patch_behavior(expected_revision, &changes)?))
        }
        "overlay.placement.get" => Ok(json!(state.database.overlay_placement()?)),
        "overlay.placement.update" => {
            let placement: OverlayPlacement = serde_json::from_value(request.params)?;
            validate_overlay_placement(&placement)?;
            state
                .database
                .set_setting("overlay_placement", &placement)?;
            Ok(json!({ "ok": true, "overlay_placement": placement }))
        }
        "settings.get" => {
            let key = required_string(&request.params, "key")?;
            validate_client_setting_key(&key)?;
            let value = state.database.get_raw_setting(&key)?;
            Ok(json!({ "key": key, "value_json": value }))
        }
        "settings.update" => {
            let key = required_string(&request.params, "key")?;
            validate_client_setting_key(&key)?;
            let value = request
                .params
                .get("value")
                .cloned()
                .ok_or_else(|| PetCoreError::InvalidRequest("missing value".to_string()))?;
            state.database.set_setting(&key, &value)?;
            Ok(json!({ "ok": true }))
        }
        "agent.ingest" => {
            let event = normalize_event(&request.params)?;
            ingest_event(state, event)
        }
        "events.recent" => {
            let limit = optional_u64_param(&request.params, "limit")?
                .unwrap_or(20)
                .min(MAX_RECENT_EVENTS as u64) as usize;
            Ok(json!(state.database.recent_events(limit)?))
        }
        "pet.list" => Ok(json!(state.database.list_pets()?)),
        "pet.activate" => {
            let id = required_string(&request.params, "id")?;
            state.database.activate_pet(&id)?;
            Ok(json!({ "ok": true }))
        }
        "pet.delete" => {
            let id = required_string(&request.params, "id")?;
            let pet = state
                .database
                .get_pet(&id)?
                .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {id}")))?;
            let staged_assets = petpack::stage_imported_pet_assets_for_removal(&state.paths, &pet)?;
            let next_active_pet_id =
                match state.database.delete_pet_and_activate_next(&id, pet.active) {
                    Ok(next_active_pet_id) => next_active_pet_id,
                    Err(error) => {
                        staged_assets.rollback()?;
                        return Err(error);
                    }
                };
            let deleted_assets = staged_assets.commit();
            Ok(json!({
                "ok": true,
                "deleted_assets": deleted_assets,
                "next_active_pet_id": next_active_pet_id
            }))
        }
        "petpack.validate" => {
            let path = required_string(&request.params, "path")?;
            Ok(json!(petpack::validate_petpack_path(&PathBuf::from(path))?))
        }
        "petpack.import" => {
            let path = required_string(&request.params, "path")?;
            let expect_absent = match request.params.get("expect_absent") {
                None => false,
                Some(Value::Bool(value)) => *value,
                Some(_) => return Err(invalid_params("expect_absent must be a boolean")),
            };
            let path = PathBuf::from(path);
            let pet = if expect_absent {
                petpack::import_petpack_expecting_absent(&state.paths, &state.database, &path)?
            } else {
                petpack::import_petpack(&state.paths, &state.database, &path)?
            };
            Ok(json!(pet))
        }
        "petpack.export" => {
            let id = required_string(&request.params, "id")?;
            let path = required_string(&request.params, "path")?;
            Ok(json!(petpack::export_petpack(
                &state.paths,
                &state.database,
                &id,
                &PathBuf::from(path)
            )?))
        }
        "generation.start" => {
            let form: GenerationForm = serde_json::from_value(request.params)?;
            let job_id = generation::start_generation_for_instance(
                &state.paths,
                &state.database,
                form,
                state.instance_id(),
            )?;
            Ok(json!({ "ok": true, "job_id": job_id }))
        }
        "generation.retry" => {
            let retry_of_job_id = required_string(&request.params, "job_id")?;
            let form = request
                .params
                .get("form")
                .cloned()
                .map(serde_json::from_value::<GenerationForm>)
                .transpose()?;
            let job_id = generation::retry_generation_for_instance(
                &state.paths,
                &state.database,
                &retry_of_job_id,
                form,
                state.instance_id(),
            )?;
            let operation = state
                .database
                .generation_job(&job_id)?
                .as_ref()
                .map(generation::generation_job_operation)
                .unwrap_or(generation::GENERATION_OPERATION_CREATE);
            Ok(json!({
                "ok": true,
                "job_id": job_id,
                "retry_of_job_id": retry_of_job_id,
                "operation": operation
            }))
        }
        "generation.messages" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation::read_messages_with_database(
                &state.paths,
                &state.database,
                &job_id
            )?))
        }
        "generation.for_pet" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let Some(job) = state.database.generation_job_for_pet(&pet_id)? else {
                return Ok(json!({
                    "ok": true,
                    "found": false,
                    "pet_id": pet_id,
                    "messages": []
                }));
            };
            let form: Value = serde_json::from_str(&job.form_json)?;
            let operation = generation::generation_job_operation(&job);
            Ok(json!({
                "ok": true,
                "found": true,
                "pet_id": pet_id,
                "job_id": job.id,
                "status": enum_name(job.status),
                "session_id": job.session_id,
                "result_pet_id": job.result_pet_id,
                "retry_of_job_id": job.retry_of_job_id,
                "operation": operation,
                "created_at": job.created_at,
                "updated_at": job.updated_at,
                "form": form,
                "messages": generation::read_messages_with_database(
                    &state.paths,
                    &state.database,
                    &job.id
                )?
            }))
        }
        "generation.edit" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let instruction = required_string(&request.params, "instruction")?;
            let job_id = generation::start_pet_edit_for_instance(
                &state.paths,
                &state.database,
                &pet_id,
                &instruction,
                state.instance_id(),
            )?;
            Ok(json!({
                "ok": true,
                "job_id": job_id,
                "pet_id": pet_id,
                "operation": generation::GENERATION_OPERATION_MODIFY
            }))
        }
        "generation.messages.wait" => {
            let job_id = required_string(&request.params, "job_id")?;
            let after_revision = required_string(&request.params, "after_revision")?;
            let timeout_ms = bounded_u64_param(&request.params, "timeout_ms", 30_000, 250, 30_000)?;
            generation::wait_messages_with_database(
                &state.paths,
                &state.database,
                &job_id,
                &after_revision,
                timeout_ms,
            )
        }
        "generation.reply" => {
            let job_id = required_string(&request.params, "job_id")?;
            let content = required_string(&request.params, "content")?;
            Ok(json!(generation::append_user_reply_for_instance(
                &state.paths,
                &state.database,
                &job_id,
                &content,
                state.instance_id(),
            )?))
        }
        "generation.cancel" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation::cancel_generation(
                &state.paths,
                &state.database,
                &job_id
            )?))
        }
        "connections.check" => {
            if let Some(source) = optional_source(&request.params)? {
                let status = connections::check_source(&state.paths, source);
                state.database.upsert_connection_status(&status)?;
                Ok(json!(status))
            } else {
                let statuses = connections::check_all(&state.paths);
                state.database.upsert_connection_statuses(&statuses)?;
                Ok(json!(statuses))
            }
        }
        "connections.repair" => {
            let source = required_source(&request.params)?;
            let status = connections::repair_source(&state.paths, source)?;
            state.database.upsert_connection_status(&status)?;
            Ok(json!(status))
        }
        "connections.uninstall" => {
            let source = required_source(&request.params)?;
            let status = connections::uninstall_source(&state.paths, source)?;
            state.database.upsert_connection_status(&status)?;
            Ok(json!(status))
        }
        "connections.test" => {
            let source = required_source(&request.params)?;
            let event = AgentEvent {
                id: new_id("evt_connection_test"),
                source,
                project_path: None,
                session_id: Some("agent-pet-connection-test".to_string()),
                event_type: AgentEventType::Start,
                title: AgentEventType::Start.zh_label().to_string(),
                detail: None,
                payload_json: json!({
                    "schema_version": "apc.agent-event.v1",
                    "external_event_id": null,
                    "source_event": "connection.test",
                    "tool_name": null,
                    "outcome": "started",
                    "diagnostic": true
                }),
                created_at: now_rfc3339(),
            };
            ingest_event(state, event)
        }
        "renderer.budget" => {
            let quality = required_quality(&request.params)?;
            let fps_profile = required_fps_profile(&request.params)?;
            Ok(json!(metrics::renderer_budget(quality, fps_profile)))
        }
        "codex.app_server.probe" => Ok(json!(app_server::probe_codex_app_server())),
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}

fn ingest_event(state: &CoreState, event: AgentEvent) -> Result<Value> {
    let inserted = state.database.insert_event(&event)? == InsertEventOutcome::Inserted;
    let behavior = state.database.behavior()?;
    let triggered = inserted && event_drives_overlay(&behavior, &event);
    let active_agent_state = canonical_agent_state(state, &behavior)?;
    Ok(json!({
        "ok": true,
        "inserted": inserted,
        "triggered": triggered,
        "state": event.event_type.pet_state(),
        "event": event,
        "active_agent_state": active_agent_state,
    }))
}

fn canonical_agent_state(
    state: &CoreState,
    behavior: &BehaviorSettings,
) -> Result<Option<agent_state::ActiveAgentState>> {
    let events = state
        .database
        .latest_sequenced_events_by_session(SNAPSHOT_EVENT_SCAN_LIMIT)?;
    let mut active =
        agent_state::select_active_agent_state(behavior, &events, OffsetDateTime::now_utc());
    if let Some(active) = &mut active {
        hydrate_agent_session_display(state, active)?;
    }
    Ok(active)
}

fn state_snapshot(state: &CoreState, changed: bool) -> Result<Value> {
    let mut pets = state.database.list_pets()?;
    let mut pet_asset_warnings = Vec::new();
    for pet in &mut pets {
        let outcome = petpack::ensure_runtime_assets_cached(&state.paths, &state.database, pet)?;
        *pet = outcome.pet;
        if let Some(warning) = outcome.warning {
            pet_asset_warnings.push(warning);
        }
    }
    let versioned_behavior = state.database.behavior_with_revision()?;
    let behavior = versioned_behavior.behavior;
    state.refresh_codex_activity(&behavior);
    let sequenced_events = state
        .database
        .latest_sequenced_events_by_session(SNAPSHOT_EVENT_SCAN_LIMIT)?;
    let scanned_events = sequenced_events
        .iter()
        .map(|candidate| candidate.event.clone())
        .collect::<Vec<_>>();
    let recent_events = recent_non_diagnostic_events(
        &state.database.recent_events(SNAPSHOT_RECENT_EVENT_LIMIT)?,
        SNAPSHOT_RECENT_EVENT_LIMIT,
    );
    let events = current_overlay_events(&behavior, &scanned_events);
    let mut active_agent_state = agent_state::select_active_agent_state(
        &behavior,
        &sequenced_events,
        OffsetDateTime::now_utc(),
    );
    if let Some(active) = &mut active_agent_state {
        hydrate_agent_session_display(state, active)?;
    }
    let mut active_agent_sessions = agent_state::select_display_agent_states(
        &behavior,
        &sequenced_events,
        OffsetDateTime::now_utc(),
    );
    for session in &mut active_agent_sessions {
        hydrate_agent_session_display(state, session)?;
    }
    let overlay_visibility = agent_state::overlay_visibility_for_sessions(
        &behavior,
        !active_agent_sessions.is_empty(),
        active_agent_state.is_some(),
    );
    let connections = merge_cached_connection_statuses(
        connections::check_all_light(&state.paths),
        state.database.connection_statuses()?,
    );
    let active_generation = active_generation_snapshot(state)?;
    Ok(json!({
        "revision": state.database.state_revision()?.to_string(),
        "changed": changed,
        "behavior": behavior,
        "behavior_revision": versioned_behavior.revision,
        "overlay_placement": state.database.overlay_placement()?,
        "pets": pets,
        "pet_asset_warnings": pet_asset_warnings,
        "events": events,
        "active_agent_state": active_agent_state,
        "active_agent_sessions": active_agent_sessions,
        "overlay_visibility": overlay_visibility,
        "recent_events": recent_events,
        "connections": connections,
        "active_generation": active_generation,
    }))
}

fn hydrate_agent_session_display(
    state: &CoreState,
    active: &mut agent_state::ActiveAgentState,
) -> Result<()> {
    active.latest_message = state.database.latest_session_message_for_role(
        active.source,
        active.session_id.as_deref(),
        Some("assistant"),
    )?;
    active.latest_user_message = state.database.latest_session_message_for_role(
        active.source,
        active.session_id.as_deref(),
        Some("user"),
    )?;
    let first_user_message = state.database.first_session_message_for_role(
        active.source,
        active.session_id.as_deref(),
        Some("user"),
    )?;
    let response_cutoff = active
        .latest_user_message
        .as_ref()
        .map(|event| event.created_at.as_str())
        .or(active.session_activated_at.as_deref());
    if active.latest_message.as_ref().is_some_and(|message| {
        response_cutoff.is_some_and(|cutoff| !event_happened_after(&message.created_at, cutoff))
    }) {
        active.latest_message = None;
    }
    active.session_title = event_payload_text(&active.event, "session_title")
        .or_else(|| {
            active
                .latest_user_message
                .as_ref()
                .and_then(|event| event_payload_text(event, "session_title"))
        })
        .or_else(|| {
            active
                .latest_message
                .as_ref()
                .and_then(|event| event_payload_text(event, "session_title"))
        })
        .or_else(|| {
            first_user_message
                .as_ref()
                .and_then(|event| event_payload_text(event, "session_title"))
        })
        .or_else(|| first_user_message.as_ref().and_then(fallback_session_title));
    active.session_message = active
        .latest_message
        .as_ref()
        .and_then(event_display_message);
    active.session_user_message = active
        .latest_user_message
        .as_ref()
        .and_then(event_display_message);
    if event_payload_text(&active.event, "source_event").as_deref() == Some("app_server_activity") {
        return Ok(());
    }
    if active.source != AgentSource::Codex {
        return Ok(());
    }
    let Some(session_id) = active.session_id.as_deref() else {
        return Ok(());
    };
    let event_marker = active
        .session_activated_at
        .clone()
        .unwrap_or_else(|| format!("{}:{}", active.event.id, active.source_session_sequence));
    let refresh_seconds = if matches!(
        active.event.event_type,
        AgentEventType::Start | AgentEventType::Tool
    ) {
        CODEX_ACTIVE_THREAD_DISPLAY_REFRESH_SECONDS
    } else {
        CODEX_THREAD_DISPLAY_REFRESH_SECONDS
    };
    let Some(display) = state.codex_thread_display(session_id, &event_marker, refresh_seconds)
    else {
        return Ok(());
    };
    if display.title.is_some() {
        active.session_title = display.title;
    }
    if let Some(message) = display.latest_message {
        active.session_message = Some(agent_state::SessionDisplayMessage {
            role: message.role,
            content: message.content,
        });
    }
    if let Some(message) = display.latest_user_message {
        active.session_user_message = Some(agent_state::SessionDisplayMessage {
            role: message.role,
            content: message.content,
        });
    }
    if let Some(activity) = display
        .latest_activity
        .filter(|activity| activity.is_current)
    {
        let fills_missing_public_summary =
            active.session_activity.as_ref().is_some_and(|current| {
                current.content.is_none()
                    && activity.content.is_some()
                    && current.kind == activity.kind
                    && matches!(current.kind.as_str(), "thinking" | "plan")
            });
        if active.session_activity.is_none() || fills_missing_public_summary {
            active.session_activity = Some(agent_state::SessionActivity {
                kind: activity.kind,
                content: activity.content,
            });
        }
    }
    Ok(())
}

fn event_payload_text(event: &AgentEvent, key: &str) -> Option<String> {
    event
        .payload_json
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn event_display_message(event: &AgentEvent) -> Option<agent_state::SessionDisplayMessage> {
    Some(agent_state::SessionDisplayMessage {
        role: event_payload_text(event, "message_role")?,
        content: event_payload_text(event, "message_content")?,
    })
}

fn fallback_session_title(event: &AgentEvent) -> Option<String> {
    let message = event_payload_text(event, "message_content")?;
    let normalized = message.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() {
        return None;
    }
    let mut characters = normalized.chars();
    let prefix = characters
        .by_ref()
        .take(MAX_FALLBACK_SESSION_TITLE_CHARS)
        .collect::<String>();
    if characters.next().is_some() {
        let mut shortened = prefix
            .chars()
            .take(MAX_FALLBACK_SESSION_TITLE_CHARS.saturating_sub(1))
            .collect::<String>();
        shortened.push('…');
        Some(shortened)
    } else {
        Some(prefix)
    }
}

fn event_happened_after(candidate: &str, cutoff: &str) -> bool {
    let candidate = OffsetDateTime::parse(candidate, &Rfc3339);
    let cutoff = OffsetDateTime::parse(cutoff, &Rfc3339);
    matches!((candidate, cutoff), (Ok(candidate), Ok(cutoff)) if candidate > cutoff)
}

fn active_generation_snapshot(state: &CoreState) -> Result<Option<Value>> {
    let Some(job) = state.database.active_generation_job()? else {
        return Ok(None);
    };
    let form: GenerationForm = serde_json::from_str(&job.form_json)?;
    let operation = generation::generation_job_operation(&job);
    let messages = generation::read_messages_with_database(&state.paths, &state.database, &job.id)?;
    let input_request = messages
        .iter()
        .rev()
        .find(|message| message.get("kind").and_then(Value::as_str) == Some("input_request"))
        .cloned();
    Ok(Some(json!({
        "job_id": job.id,
        "status": enum_name(job.status),
        "form": form,
        "session_id": job.session_id,
        "result_pet_id": job.result_pet_id,
        "operation": operation,
        "owner_instance_id": job.owner_instance_id,
        "heartbeat_at": job.heartbeat_at,
        "message_revision": state.database.generation_message_revision(&job.id)?.to_string(),
        "messages": messages,
        "input_request": input_request,
    })))
}

fn merge_cached_connection_statuses(
    light_statuses: Vec<AgentConnectionStatus>,
    cached_statuses: Vec<AgentConnectionStatus>,
) -> Vec<AgentConnectionStatus> {
    light_statuses
        .into_iter()
        .map(|light| {
            let light_found_no_issues = light.items.iter().all(|item| !item.status.is_blocking());
            if light_found_no_issues {
                if let Some(cached) = cached_statuses
                    .iter()
                    .find(|cached| cached.source == light.source)
                {
                    return cached.clone();
                }
            }
            light
        })
        .collect()
}

fn wait_for_state_change(state: &CoreState, params: &Value) -> Result<Value> {
    let after_revision = required_string(params, "after_revision")?;
    let timeout_ms = bounded_u64_param(params, "timeout_ms", 3_000, 250, 30_000)?;
    let poll_interval = Duration::from_millis(120);
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let behavior = state.database.behavior()?;

    loop {
        state.refresh_codex_activity(&behavior);
        let current_revision = state.database.state_revision()?.to_string();
        if current_revision != after_revision {
            return state_snapshot(state, true);
        }
        if Instant::now() >= deadline {
            return state_snapshot(state, false);
        }
        thread::sleep(poll_interval);
    }
}

pub fn normalize_event(params: &Value) -> Result<AgentEvent> {
    validate_agent_event_shape(params)?;
    let source = required_source(params)?;
    NormalizedAgentEvent::from_external(source, params.clone(), &now_rfc3339())
}

fn validate_agent_event_shape(params: &Value) -> Result<()> {
    let object = params.as_object().ok_or_else(|| {
        PetCoreError::InvalidRequest("agent event params must be an object".to_string())
    })?;
    for key in object.keys() {
        if !AGENT_EVENT_ALLOWED_FIELDS.contains(&key.as_str()) {
            return Err(PetCoreError::InvalidRequest(format!(
                "agent event field is not supported: {key}"
            )));
        }
    }
    if let Some(id) = object.get("id") {
        if !(id.is_null() || id.as_str().is_some()) {
            return Err(PetCoreError::InvalidRequest(
                "agent event id must be a string or null".to_string(),
            ));
        }
    }
    if let Some(title) = object.get("title") {
        if let Some(title) = title.as_str() {
            if title.is_empty() {
                return Err(PetCoreError::InvalidRequest(
                    "agent event title must not be empty".to_string(),
                ));
            }
        } else if !title.is_null() {
            return Err(PetCoreError::InvalidRequest(
                "agent event title must be a string or null".to_string(),
            ));
        }
    }
    for field in ["payload", "payload_json"] {
        if let Some(value) = object.get(field) {
            if !value.is_object() {
                return Err(PetCoreError::InvalidRequest(format!(
                    "agent event {field} must be an object"
                )));
            }
        }
    }
    Ok(())
}

fn required_string(params: &Value, key: &str) -> Result<String> {
    match params.get(key) {
        Some(Value::String(value)) => Ok(value.clone()),
        Some(_) => Err(invalid_params(format!("{key} must be a string"))),
        None => Err(invalid_params(format!("missing string param {key}"))),
    }
}

fn validate_client_setting_key(key: &str) -> Result<()> {
    if key.starts_with("diagnostic.")
        && key.len() <= 128
        && key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Ok(());
    }
    Err(invalid_params(
        "settings RPC accepts only diagnostic.* keys; product settings use typed methods",
    ))
}

fn optional_string_param<'a>(params: &'a Value, key: &str) -> Result<Option<&'a str>> {
    match params.get(key) {
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(invalid_params(format!("{key} must be a string"))),
        None => Ok(None),
    }
}

fn optional_u64_param(params: &Value, key: &str) -> Result<Option<u64>> {
    match params.get(key) {
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid_params(format!("{key} must be an unsigned integer"))),
        Some(_) => Err(invalid_params(format!("{key} must be an unsigned integer"))),
        None => Ok(None),
    }
}

fn bounded_u64_param(
    params: &Value,
    key: &str,
    default: u64,
    minimum: u64,
    maximum: u64,
) -> Result<u64> {
    let value = optional_u64_param(params, key)?.unwrap_or(default);
    if !(minimum..=maximum).contains(&value) {
        return Err(invalid_params(format!(
            "{key} must be between {minimum} and {maximum}"
        )));
    }
    Ok(value)
}

fn invalid_params(message: impl Into<String>) -> PetCoreError {
    PetCoreError::InvalidRequest(format!("invalid params: {}", message.into()))
}

fn validate_overlay_placement(placement: &OverlayPlacement) -> Result<()> {
    if !(MIN_OVERLAY_SCALE..=MAX_OVERLAY_SCALE).contains(&placement.scale) {
        return Err(invalid_params(format!(
            "scale must be between {MIN_OVERLAY_SCALE:.2} and {MAX_OVERLAY_SCALE:.1}"
        )));
    }
    if placement.display_id.trim().is_empty() {
        return Err(invalid_params("display_id must not be empty"));
    }
    Ok(())
}

fn should_trigger_event(behavior: &BehaviorSettings, event: &AgentEvent) -> bool {
    behavior.enabled
        && !event_is_diagnostic(event)
        && behavior
            .sources
            .get(&event.source)
            .copied()
            .unwrap_or(false)
        && behavior
            .events
            .get(&event.event_type)
            .copied()
            .unwrap_or(false)
}

fn event_drives_overlay(behavior: &BehaviorSettings, event: &AgentEvent) -> bool {
    should_trigger_event(behavior, event) && !event_expired(event)
}

fn recent_non_diagnostic_events(events: &[AgentEvent], limit: usize) -> Vec<AgentEvent> {
    events
        .iter()
        .filter(|event| !event_is_diagnostic(event))
        .take(limit)
        .cloned()
        .collect()
}

fn current_overlay_events(behavior: &BehaviorSettings, events: &[AgentEvent]) -> Vec<AgentEvent> {
    if !behavior.enabled {
        return Vec::new();
    }

    let mut seen_groups = BTreeSet::new();
    let mut current_events = Vec::new();
    for event in events {
        if event_is_diagnostic(event) {
            continue;
        }

        if !seen_groups.insert(event.source) {
            continue;
        }

        if event_drives_overlay(behavior, event) {
            current_events.push(event.clone());
            if current_events.len() >= SNAPSHOT_OVERLAY_EVENT_LIMIT {
                break;
            }
        }
    }
    current_events
}

fn event_is_diagnostic(event: &AgentEvent) -> bool {
    event
        .payload_json
        .get("diagnostic")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn event_expired(event: &AgentEvent) -> bool {
    if agent_state::event_session_active(event) == Some(true) {
        return false;
    }
    let Ok(created_at) = OffsetDateTime::parse(&event.created_at, &Rfc3339) else {
        return false;
    };
    let age = OffsetDateTime::now_utc() - created_at;
    if age.whole_seconds() < -FUTURE_EVENT_GRACE_SECONDS {
        return true;
    }
    age.whole_seconds() > overlay_event_ttl_seconds(event.event_type)
}

fn overlay_event_ttl_seconds(event_type: AgentEventType) -> i64 {
    agent_state::event_lease_seconds(event_type)
}

fn optional_source(params: &Value) -> Result<Option<AgentSource>> {
    optional_string_param(params, "source")?
        .map(enum_from_name)
        .transpose()
}

fn required_source(params: &Value) -> Result<AgentSource> {
    let value = required_string(params, "source")?;
    enum_from_name(&value)
}

fn required_quality(params: &Value) -> Result<QualityLevel> {
    let value = required_string(params, "quality")?;
    enum_from_name(&value)
}

fn required_fps_profile(params: &Value) -> Result<FpsProfileName> {
    let profile = optional_string_param(params, "fps_profile")?;
    let fps = optional_u64_param(params, "fps")?;
    match (profile, fps) {
        (Some(_), Some(_)) => Err(invalid_params(
            "fps_profile and fps must not be provided together",
        )),
        (Some(profile), None) => enum_from_name(profile),
        (None, Some(12)) => Ok(FpsProfileName::Standard),
        (None, Some(20)) => Ok(FpsProfileName::Smooth),
        (None, Some(_)) => Err(invalid_params("fps must be exactly 12 or 20")),
        (None, None) => Ok(FpsProfileName::Standard),
    }
}

fn read_http_port(paths: &AppPaths) -> Option<u16> {
    if let Some(marker) = crate::daemon::instance_lock::read_runtime_marker(paths)
        .ok()
        .flatten()
    {
        return Some(marker.http_port);
    }
    std::fs::read_to_string(&paths.http_port_path)
        .ok()
        .and_then(|value| value.trim().parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exact_codex_state(
        event_type: AgentEventType,
        created_at: &str,
    ) -> agent_state::SequencedAgentEvent {
        agent_state::SequencedAgentEvent {
            event: AgentEvent {
                id: "exact-hook-state".to_string(),
                source: AgentSource::Codex,
                project_path: None,
                session_id: Some("00000000-0000-0000-0000-000000000001".to_string()),
                event_type,
                title: event_type.zh_label().to_string(),
                detail: None,
                payload_json: json!({
                    "source_event": "PermissionRequest",
                    "session_active": true
                }),
                created_at: created_at.to_string(),
            },
            source_session_sequence: 1,
            session_activated_at: None,
        }
    }

    fn inferred_codex_tool(turn_started_at_unix: i64) -> app_server::CodexThreadActivity {
        app_server::CodexThreadActivity {
            thread_id: "00000000-0000-0000-0000-000000000001".to_string(),
            title: None,
            event_type: AgentEventType::Tool,
            updated_at_unix: turn_started_at_unix,
            turn_id: Some("turn-1".to_string()),
            turn_started_at_unix: Some(turn_started_at_unix),
            session_active: true,
            session_surface: "chatgpt_app".to_string(),
            interaction_kind: None,
            latest_message: None,
            latest_user_message: None,
            latest_activity: Some(app_server::CodexThreadDisplayActivity {
                kind: "command".to_string(),
                content: None,
                is_current: true,
            }),
            display_revision: "turn-1:command-1:inProgress".to_string(),
        }
    }

    #[test]
    fn inferred_tool_activity_does_not_replace_newer_exact_interaction_state() {
        let activity = inferred_codex_tool(1_752_409_560);
        let newer_waiting = exact_codex_state(AgentEventType::Waiting, "2025-07-13T12:27:00Z");
        assert!(should_preserve_exact_codex_state(
            &[newer_waiting],
            &activity
        ));

        let older_waiting = exact_codex_state(AgentEventType::Waiting, "2025-07-13T12:25:00Z");
        assert!(!should_preserve_exact_codex_state(
            &[older_waiting],
            &activity
        ));
    }

    #[test]
    fn lossy_codex_updates_replace_stale_reasoning_with_generic_tool_activity() {
        let mut observations = BTreeMap::new();
        let mut activity = inferred_codex_tool(1_752_409_560);
        activity.event_type = AgentEventType::Start;
        activity.latest_activity = Some(app_server::CodexThreadDisplayActivity {
            kind: "thinking".to_string(),
            content: Some("Assessing manual length and detail".to_string()),
            is_current: true,
        });
        activity.display_revision = "turn-1:reasoning-1:first".to_string();

        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .map(|value| value.kind.as_str()),
            Some("thinking")
        );
        assert_eq!(activity.event_type, AgentEventType::Start);

        activity.updated_at_unix += 1;
        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .map(|value| value.kind.as_str()),
            Some("tool")
        );
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .and_then(|value| value.content.as_ref()),
            None
        );
        assert_eq!(activity.event_type, AgentEventType::Tool);

        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .map(|value| value.kind.as_str()),
            Some("tool")
        );
    }

    #[test]
    fn newly_completed_file_change_does_not_remain_an_editing_activity() {
        let mut observations = BTreeMap::new();
        let mut activity = inferred_codex_tool(1_752_409_560);
        activity.event_type = AgentEventType::Start;
        activity.latest_activity = Some(app_server::CodexThreadDisplayActivity {
            kind: "file_change".to_string(),
            content: None,
            is_current: false,
        });
        activity.display_revision = "turn-1:patch-1:completed".to_string();

        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(activity.latest_activity, None);
        assert_eq!(activity.event_type, AgentEventType::Start);

        activity.updated_at_unix += 1;
        activity.latest_activity = Some(app_server::CodexThreadDisplayActivity {
            kind: "file_change".to_string(),
            content: None,
            is_current: false,
        });
        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .map(|value| value.kind.as_str()),
            Some("tool")
        );
        assert_eq!(activity.event_type, AgentEventType::Tool);
    }

    #[test]
    fn codex_status_event_id_is_stable_when_activity_kind_changes() {
        let mut activity = inferred_codex_tool(1_752_409_560);
        let tool_id = codex_activity_events(activity.clone())
            .last()
            .expect("tool status")
            .id
            .clone();
        activity.event_type = AgentEventType::Start;
        activity.latest_activity = Some(generic_codex_activity("thinking"));
        let thinking_id = codex_activity_events(activity)
            .last()
            .expect("thinking status")
            .id
            .clone();
        assert_eq!(tool_id, thinking_id);
    }
}
