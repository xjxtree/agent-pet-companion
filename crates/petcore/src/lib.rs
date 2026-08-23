pub mod adapter_contracts;
mod agent_environment;
pub mod agent_session_filters;
pub mod agent_state;
pub mod app_server;
pub mod connections;
pub mod daemon;
pub mod diagnostics;
pub mod event_envelope;
pub mod fs_identity;
pub mod generation;
pub mod interaction_attestation;
pub mod launch_agent;
pub mod metrics;
pub mod paths;
pub mod pet_revision;
pub mod petpack;
pub mod portable_skill;
pub mod process_runner;
pub mod reference_images;
pub mod rollback_checkpoint;
pub mod rpc;
pub mod runtime_manifest;
pub mod storage;

pub use storage as db;

use thiserror::Error;

pub type Result<T> = std::result::Result<T, PetCoreError>;

#[derive(Debug, Error)]
pub enum PetCoreError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("image error: {0}")]
    Image(#[from] image::ImageError),
    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    // The rendered form is the exact JSON-RPC wire message, so display and
    // wire stay byte-identical by construction.
    #[error("{0}")]
    InvalidParams(String),
    #[error("validation failed: {0}")]
    Validation(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("generation_active_conflict: {active_job}")]
    GenerationConflict { active_job: serde_json::Value },
}

impl PetCoreError {
    /// Classifies the error into the same coarse buckets that existed before
    /// `InvalidParams` and `GenerationConflict` were split out of
    /// `InvalidRequest` and `Conflict`.
    pub fn is_invalid_request_class(&self) -> bool {
        matches!(
            self,
            PetCoreError::InvalidRequest(_) | PetCoreError::InvalidParams(_)
        )
    }

    pub fn is_conflict_class(&self) -> bool {
        matches!(
            self,
            PetCoreError::Conflict(_) | PetCoreError::GenerationConflict { .. }
        )
    }
}

pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

pub fn new_id(prefix: &str) -> String {
    format!("{prefix}_{}", uuid::Uuid::now_v7().simple())
}

pub fn enum_name<T: serde::Serialize>(value: T) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .unwrap_or_else(|| "unknown".to_string())
}

pub fn enum_from_name<T: serde::de::DeserializeOwned>(name: &str) -> Result<T> {
    serde_json::from_value(serde_json::Value::String(name.to_string())).map_err(PetCoreError::from)
}
