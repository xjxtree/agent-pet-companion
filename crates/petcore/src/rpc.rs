use crate::connections;
use crate::db::Database;
use crate::generation;
use crate::metrics;
use crate::paths::AppPaths;
use crate::petpack;
use crate::{new_id, now_rfc3339, enum_from_name, PetCoreError, Result};
use petcore_types::{
    AgentEvent, AgentEventType, AgentSource, BehaviorSettings, FpsProfileName, GenerationForm,
    QualityLevel,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct CoreState {
    pub paths: AppPaths,
    pub database: Database,
}

impl CoreState {
    pub fn new(paths: AppPaths) -> Self {
        let database = Database::new(paths.db_path.clone());
        Self { paths, database }
    }

    pub fn ensure_ready(&self) -> Result<()> {
        self.paths.ensure()?;
        self.database.init()?;
        Ok(())
    }
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

pub fn handle_json_line(state: &CoreState, line: &str) -> String {
    let response = match serde_json::from_str::<RpcRequest>(line) {
        Ok(request) => {
            let id = request.id.clone();
            match handle_request(state, request) {
                Ok(result) => RpcResponse {
                    jsonrpc: "2.0",
                    id,
                    result: Some(result),
                    error: None,
                },
                Err(error) => RpcResponse {
                    jsonrpc: "2.0",
                    id,
                    result: None,
                    error: Some(RpcError {
                        code: -32000,
                        message: error.to_string(),
                    }),
                },
            }
        }
        Err(error) => RpcResponse {
            jsonrpc: "2.0",
            id: None,
            result: None,
            error: Some(RpcError {
                code: -32700,
                message: error.to_string(),
            }),
        },
    };
    serde_json::to_string(&response).unwrap_or_else(|_| {
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"serialization failed\"}}"
            .to_string()
    })
}

pub fn handle_request(state: &CoreState, request: RpcRequest) -> Result<Value> {
    if request.jsonrpc.as_deref().unwrap_or("2.0") != "2.0" {
        return Err(PetCoreError::InvalidRequest(
            "jsonrpc must be 2.0".to_string(),
        ));
    }

    match request.method.as_str() {
        "petcore.health" => Ok(json!({
            "ok": true,
            "version": env!("CARGO_PKG_VERSION"),
            "socket": state.paths.socket_path,
            "home": state.paths.home,
            "http_port": read_http_port(&state.paths),
        })),
        "state.snapshot" => Ok(json!({
            "behavior": state.database.behavior()?,
            "pets": state.database.list_pets()?,
            "events": state.database.recent_events(8)?,
            "connections": connections::check_all(&state.paths),
        })),
        "behavior.get" => Ok(json!(state.database.behavior()?)),
        "behavior.update" => {
            let settings: BehaviorSettings = serde_json::from_value(request.params)?;
            state.database.set_setting("behavior", &settings)?;
            Ok(json!({ "ok": true, "behavior": settings }))
        }
        "settings.get" => {
            let key = required_string(&request.params, "key")?;
            let value = state.database.get_raw_setting(&key)?;
            Ok(json!({ "key": key, "value_json": value }))
        }
        "settings.update" => {
            let key = required_string(&request.params, "key")?;
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
            let inserted = state.database.insert_event(&event)?;
            let behavior = state.database.behavior()?;
            let source_enabled = behavior.sources.get(&event.source).copied().unwrap_or(false);
            let event_enabled = behavior.events.get(&event.event_type).copied().unwrap_or(false);
            let triggered = inserted && behavior.enabled && source_enabled && event_enabled;
            Ok(json!({
                "ok": true,
                "inserted": inserted,
                "triggered": triggered,
                "state": event.event_type.pet_state(),
                "event": event,
            }))
        }
        "events.recent" => {
            let limit = request
                .params
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(20) as usize;
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
            state.database.delete_pet(&id)?;
            Ok(json!({ "ok": true }))
        }
        "petpack.validate" => {
            let path = required_string(&request.params, "path")?;
            Ok(json!(petpack::validate_petpack_path(&PathBuf::from(path))?))
        }
        "petpack.import" => {
            let path = required_string(&request.params, "path")?;
            Ok(json!(petpack::import_petpack(
                &state.paths,
                &state.database,
                &PathBuf::from(path)
            )?))
        }
        "generation.start" => {
            let form: GenerationForm = serde_json::from_value(request.params)?;
            let job_id = generation::start_generation(&state.paths, &state.database, form)?;
            Ok(json!({ "ok": true, "job_id": job_id }))
        }
        "generation.messages" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation::read_messages(&state.paths, &job_id)?))
        }
        "connections.check" => {
            if let Some(source) = optional_source(&request.params)? {
                Ok(json!(connections::check_source(&state.paths, source)))
            } else {
                Ok(json!(connections::check_all(&state.paths)))
            }
        }
        "connections.repair" => {
            let source = required_source(&request.params)?;
            Ok(json!(connections::repair_source(&state.paths, source)?))
        }
        "connections.uninstall" => {
            let source = required_source(&request.params)?;
            Ok(json!(connections::uninstall_source(&state.paths, source)?))
        }
        "renderer.budget" => {
            let quality = required_quality(&request.params)?;
            let fps_profile = required_fps_profile(&request.params)?;
            Ok(json!(metrics::renderer_budget(quality, fps_profile)))
        }
        "codex.app_server.probe" => Ok(json!(probe_codex_app_server())),
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}

pub fn normalize_event(params: &Value) -> Result<AgentEvent> {
    let source = required_source(params)?;
    let event_type = required_event_type(params)?;
    let created_at = params
        .get("created_at")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(now_rfc3339);
    let title = params
        .get("title")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| event_type.zh_label().to_string());
    let id = params
        .get("id")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| new_id("evt"));
    Ok(AgentEvent {
        id,
        source,
        project_path: params
            .get("project_path")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        session_id: params
            .get("session_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        event_type,
        title,
        detail: params
            .get("detail")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        payload_json: params.get("payload").cloned().unwrap_or_else(|| json!({})),
        created_at,
    })
}

fn required_string(params: &Value, key: &str) -> Result<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| PetCoreError::InvalidRequest(format!("missing string param {key}")))
}

fn optional_source(params: &Value) -> Result<Option<AgentSource>> {
    params
        .get("source")
        .and_then(Value::as_str)
        .map(enum_from_name)
        .transpose()
}

fn required_source(params: &Value) -> Result<AgentSource> {
    let value = required_string(params, "source")?;
    enum_from_name(&value)
}

fn required_event_type(params: &Value) -> Result<AgentEventType> {
    let value = required_string(params, "event_type")?;
    enum_from_name(&value)
}

fn required_quality(params: &Value) -> Result<QualityLevel> {
    let value = required_string(params, "quality")?;
    enum_from_name(&value)
}

fn required_fps_profile(params: &Value) -> Result<FpsProfileName> {
    if let Some(profile) = params.get("fps_profile").and_then(Value::as_str) {
        return enum_from_name(profile);
    }
    let fps = params.get("fps").and_then(Value::as_u64).unwrap_or(12);
    Ok(if fps >= 20 {
        FpsProfileName::Smooth
    } else {
        FpsProfileName::Standard
    })
}

fn read_http_port(paths: &AppPaths) -> Option<u16> {
    std::fs::read_to_string(&paths.http_port_path)
        .ok()
        .and_then(|value| value.trim().parse().ok())
}

fn probe_codex_app_server() -> Value {
    if let Ok(command) = std::env::var("CODEX_APP_SERVER_CMD") {
        json!({
            "initialized": true,
            "mode": "configured",
            "command": command,
            "transport": "stdio"
        })
    } else {
        json!({
            "initialized": true,
            "mode": "mock",
            "transport": "stdio",
            "detail": "CODEX_APP_SERVER_CMD is not configured; mock app-server probe is active for local validation."
        })
    }
}
