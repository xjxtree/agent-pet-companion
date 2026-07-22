use crate::paths::AppPaths;
use crate::runtime_manifest::RuntimeReleaseManifest;
use crate::{now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentEventType, AgentSource, AppearanceTheme, ConnectionCheckMode, FpsProfileName,
    PetStateName, SessionGroupDisplay,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use zip::write::SimpleFileOptions;

pub const DIAGNOSTIC_LOG_SCHEMA_VERSION: &str = "apc.diagnostic-log.v1";
pub const DIAGNOSTIC_EXPORT_SCHEMA_VERSION: &str = "apc.diagnostics-bundle.v1";
const DIAGNOSTIC_ENVIRONMENT_SCHEMA_VERSION: &str = "apc.diagnostic-environment.v1";
const APP_ENVIRONMENT_SCHEMA_VERSION: &str = "apc.app-environment.v1";
const DIAGNOSTIC_ARCHIVE_ROOT: &str = "AgentPetCompanion-Diagnostics";
const CURRENT_LOG_MAX_BYTES: u64 = 2 * 1024 * 1024;
const LOG_BACKUP_COUNT: usize = 4;
const LOG_RETENTION: Duration = Duration::from_secs(14 * 24 * 60 * 60);
const EXPORT_RETENTION: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_RETAINED_EXPORTS: usize = 3;
const MAX_RETAINED_EXPORT_BYTES: u64 = 128 * 1024 * 1024;
const MAX_APP_ENVIRONMENT_BYTES: usize = 64 * 1024;
const MAX_APP_ENVIRONMENT_STRING_BYTES: usize = 2 * 1024;
const MAX_LOG_SOURCE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_LEGACY_LOG_SOURCE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_EXPORTED_LOG_BYTES: u64 = 32 * 1024 * 1024;
const TRANSPORT_LOG_THROTTLE: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticErrorCode {
    Io,
    Sqlite,
    Json,
    Image,
    Zip,
    InvalidRequest,
    Validation,
    Conflict,
}

impl DiagnosticErrorCode {
    pub fn from_error(error: &PetCoreError) -> Self {
        match error {
            PetCoreError::Io(_) => Self::Io,
            PetCoreError::Sqlite(_) => Self::Sqlite,
            PetCoreError::Json(_) => Self::Json,
            PetCoreError::Image(_) => Self::Image,
            PetCoreError::Zip(_) => Self::Zip,
            PetCoreError::InvalidRequest(_) => Self::InvalidRequest,
            PetCoreError::Validation(_) => Self::Validation,
            PetCoreError::Conflict(_) => Self::Conflict,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticTransport {
    Unix,
    Http,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticRejection {
    Busy,
    FrameTooLarge,
    ReadTimeout,
    InvalidUtf8,
    InvalidJson,
    Unauthorized,
    NotFound,
    BadRequest,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticIngestOutcome {
    Inserted,
    Duplicate,
    Suppressed,
}

#[derive(Clone)]
pub struct DiagnosticLogger {
    inner: Arc<Mutex<LogState>>,
    degraded: Arc<AtomicBool>,
    export_lock: Arc<Mutex<()>>,
}

struct LogState {
    logs_dir: PathBuf,
    file: Option<File>,
    current_bytes: u64,
    current_started_at: SystemTime,
    last_transport_emission: [Option<Instant>; 18],
}

impl std::fmt::Debug for DiagnosticLogger {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DiagnosticLogger")
            .field("degraded", &self.is_degraded())
            .finish_non_exhaustive()
    }
}

impl DiagnosticLogger {
    pub fn new(paths: &AppPaths) -> Self {
        let degraded = Arc::new(AtomicBool::new(false));
        let state = match initialize_log_state(&paths.logs_dir) {
            Ok(state) => state,
            Err(_) => {
                degraded.store(true, Ordering::Release);
                LogState {
                    logs_dir: paths.logs_dir.clone(),
                    file: None,
                    current_bytes: 0,
                    current_started_at: SystemTime::now(),
                    last_transport_emission: [None; 18],
                }
            }
        };
        let logger = Self {
            inner: Arc::new(Mutex::new(state)),
            degraded,
            export_lock: Arc::new(Mutex::new(())),
        };
        let exports_dir = paths.home.join("diagnostic-exports");
        if ensure_private_directory(&exports_dir).is_ok() {
            cleanup_expired_exports(&exports_dir, None);
        } else {
            logger.degraded.store(true, Ordering::Release);
        }
        logger.runtime_environment();
        logger.write_record(
            "info",
            "logger.lifecycle",
            [("phase", json!("initialized"))],
        );
        logger
    }

    pub fn is_degraded(&self) -> bool {
        self.degraded.load(Ordering::Acquire)
    }

    fn runtime_environment(&self) {
        let manifest = RuntimeReleaseManifest::compiled();
        self.write_record(
            "info",
            "runtime.environment",
            [
                ("petcore_version", json!(env!("CARGO_PKG_VERSION"))),
                ("app_version", json!(manifest.app_version)),
                ("app_build", json!(manifest.app_build)),
                ("build_id", json!(manifest.build_id)),
                ("rpc_protocol", json!(manifest.petcore_rpc_protocol)),
                ("release_channel", json!(manifest.release_channel)),
                ("operating_system", json!(std::env::consts::OS)),
                ("architecture", json!(std::env::consts::ARCH)),
                (
                    "available_parallelism",
                    json!(std::thread::available_parallelism()
                        .map(|value| value.get())
                        .unwrap_or(1)),
                ),
                (
                    "log_retention_days",
                    json!(LOG_RETENTION.as_secs() / 86_400),
                ),
                ("log_current_max_bytes", json!(CURRENT_LOG_MAX_BYTES)),
                ("log_backup_count", json!(LOG_BACKUP_COUNT)),
            ],
        );
    }

    pub fn sync(&self) {
        let mut state = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state
            .file
            .as_mut()
            .is_some_and(|file| file.sync_data().is_err())
        {
            self.degraded.store(true, Ordering::Release);
        }
    }

    pub fn core_ready_started(&self) {
        self.write_record("info", "core.readiness", [("phase", json!("started"))]);
    }

    pub fn core_ready_completed(&self) {
        self.write_record("info", "core.readiness", [("phase", json!("completed"))]);
    }

    pub fn core_ready_failed(&self, error: &PetCoreError) {
        self.write_record(
            "error",
            "core.readiness",
            [
                ("phase", json!("failed")),
                ("error_code", json!(DiagnosticErrorCode::from_error(error))),
            ],
        );
    }

    pub fn daemon_phase(&self, phase: &'static str) {
        let phase = match phase {
            "starting" | "ready" | "shutdown_requested" | "stopped" => phase,
            _ => "unknown",
        };
        self.write_record("info", "daemon.lifecycle", [("phase", json!(phase))]);
    }

    pub fn daemon_failed(&self, error: &PetCoreError) {
        self.write_record(
            "error",
            "daemon.lifecycle",
            [
                ("phase", json!("failed")),
                ("error_code", json!(DiagnosticErrorCode::from_error(error))),
            ],
        );
    }

    pub fn startup_failed(&self, stage: &'static str, error: &PetCoreError) {
        let stage = match stage {
            "manifest"
            | "build_identity"
            | "paths"
            | "database"
            | "generation_recovery"
            | "capability_token"
            | "socket_bind"
            | "http_bind"
            | "runtime_publish" => stage,
            _ => "unknown",
        };
        self.write_record(
            "error",
            "daemon.startup",
            [
                ("stage", json!(stage)),
                ("error_code", json!(DiagnosticErrorCode::from_error(error))),
            ],
        );
    }

    pub fn transport_failed(&self, transport: DiagnosticTransport, error: &PetCoreError) {
        if !self.should_emit_transport(transport_failure_throttle_index(transport)) {
            return;
        }
        self.write_record(
            "warning",
            "transport.failure",
            [
                ("transport", json!(transport)),
                ("error_code", json!(DiagnosticErrorCode::from_error(error))),
            ],
        );
    }

    pub fn transport_rejected(&self, transport: DiagnosticTransport, reason: DiagnosticRejection) {
        if !self.should_emit_transport(transport_rejection_throttle_index(transport, reason)) {
            return;
        }
        self.write_record(
            "warning",
            "transport.rejected",
            [("transport", json!(transport)), ("reason", json!(reason))],
        );
    }

    pub fn rpc_finished(&self, method: &str, result: &Result<Value>, started: Instant) {
        let method = safe_rpc_method(method);
        let duration_ms = started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
        match result {
            Ok(_) if rpc_success_is_diagnostic(method) => self.write_record(
                "info",
                "rpc.boundary",
                [
                    ("method", json!(method)),
                    ("outcome", json!("succeeded")),
                    ("duration_ms", json!(duration_ms)),
                ],
            ),
            Ok(_) => {}
            Err(error) => self.write_record(
                "warning",
                "rpc.boundary",
                [
                    ("method", json!(method)),
                    ("outcome", json!("failed")),
                    ("error_code", json!(DiagnosticErrorCode::from_error(error))),
                    ("duration_ms", json!(duration_ms)),
                ],
            ),
        }
    }

    pub fn rpc_rejected(&self, method: Option<&str>, reason: DiagnosticRejection) {
        self.write_record(
            "warning",
            "rpc.rejected",
            [
                (
                    "method",
                    json!(method.map(safe_rpc_method).unwrap_or("invalid")),
                ),
                ("reason", json!(reason)),
            ],
        );
    }

    pub fn export_started(&self) {
        self.write_record(
            "info",
            "diagnostics.export",
            [("outcome", json!("started"))],
        );
    }

    pub fn agent_activity(
        &self,
        source: AgentSource,
        event_type: AgentEventType,
        outcome: DiagnosticIngestOutcome,
        triggered: bool,
    ) {
        self.write_record(
            "info",
            "agent.activity",
            [
                ("source", json!(source)),
                ("event_type", json!(event_type)),
                ("outcome", json!(outcome)),
                ("triggered", json!(triggered)),
            ],
        );
    }

    fn should_emit_transport(&self, index: usize) -> bool {
        let now = Instant::now();
        let mut state = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.last_transport_emission[index]
            .is_some_and(|previous| now.duration_since(previous) < TRANSPORT_LOG_THROTTLE)
        {
            return false;
        }
        state.last_transport_emission[index] = Some(now);
        true
    }

    fn write_record<const N: usize>(
        &self,
        level: &'static str,
        event: &'static str,
        fields: [(&'static str, Value); N],
    ) {
        let (category, event) = event.split_once('.').unwrap_or(("petcore", event));
        let mut metadata = Map::new();
        for (key, value) in fields {
            metadata.insert(key.to_string(), value);
        }
        let mut record = Map::new();
        record.insert(
            "schema_version".to_string(),
            Value::String(DIAGNOSTIC_LOG_SCHEMA_VERSION.to_string()),
        );
        record.insert("timestamp".to_string(), Value::String(now_rfc3339()));
        record.insert("process".to_string(), Value::String("petcore".to_string()));
        record.insert("level".to_string(), Value::String(level.to_string()));
        record.insert("category".to_string(), Value::String(category.to_string()));
        record.insert("event".to_string(), Value::String(event.to_string()));
        record.insert("metadata".to_string(), Value::Object(metadata));
        let Ok(mut encoded) = serde_json::to_vec(&Value::Object(record)) else {
            self.degraded.store(true, Ordering::Release);
            return;
        };
        encoded.push(b'\n');

        let mut state = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if write_log_line(&mut state, &encoded).is_err() {
            state.file = None;
            self.degraded.store(true, Ordering::Release);
        }
    }
}

fn initialize_log_state(logs_dir: &Path) -> std::io::Result<LogState> {
    ensure_private_directory(logs_dir)?;
    prune_expired_backups(logs_dir);
    let current_path = logs_dir.join("petcore.jsonl");
    if let Some(metadata) = validated_regular_file_metadata(&current_path)? {
        let expired = metadata
            .created()
            .or_else(|_| metadata.modified())
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
            .is_some_and(|age| age > LOG_RETENTION);
        if expired {
            rotate_log_files(logs_dir)?;
            prune_expired_backups(logs_dir);
        } else if metadata.len() >= CURRENT_LOG_MAX_BYTES {
            rotate_log_files(logs_dir)?;
        }
    }
    let (file, current_bytes, current_started_at) = open_private_append_file(&current_path)?;
    Ok(LogState {
        logs_dir: logs_dir.to_path_buf(),
        file: Some(file),
        current_bytes,
        current_started_at,
        last_transport_emission: [None; 18],
    })
}

fn transport_failure_throttle_index(transport: DiagnosticTransport) -> usize {
    match transport {
        DiagnosticTransport::Unix => 0,
        DiagnosticTransport::Http => 1,
    }
}

fn transport_rejection_throttle_index(
    transport: DiagnosticTransport,
    reason: DiagnosticRejection,
) -> usize {
    let transport_offset = match transport {
        DiagnosticTransport::Unix => 0,
        DiagnosticTransport::Http => 8,
    };
    let reason_offset = match reason {
        DiagnosticRejection::Busy => 0,
        DiagnosticRejection::FrameTooLarge => 1,
        DiagnosticRejection::ReadTimeout => 2,
        DiagnosticRejection::InvalidUtf8 => 3,
        DiagnosticRejection::InvalidJson => 4,
        DiagnosticRejection::Unauthorized => 5,
        DiagnosticRejection::NotFound => 6,
        DiagnosticRejection::BadRequest => 7,
    };
    2 + transport_offset + reason_offset
}

fn ensure_private_directory(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == rustix::process::geteuid().as_raw() => {}
        Ok(_) => {
            return Err(std::io::Error::other(
                "diagnostic directory is not privately owned",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(path)?;
            let metadata = fs::symlink_metadata(path)?;
            if !metadata.file_type().is_dir()
                || metadata.file_type().is_symlink()
                || metadata.uid() != rustix::process::geteuid().as_raw()
            {
                return Err(std::io::Error::other(
                    "diagnostic directory creation was not private",
                ));
            }
        }
        Err(error) => return Err(error),
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

fn open_private_append_file(path: &Path) -> std::io::Result<(File, u64, SystemTime)> {
    let before = validated_regular_file_metadata(path)?;
    let descriptor = rustix::fs::open(
        path,
        rustix::fs::OFlags::CREATE
            | rustix::fs::OFlags::APPEND
            | rustix::fs::OFlags::RDWR
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
    )?;
    let file = File::from(descriptor);
    rustix::fs::fchmod(&file, rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR)?;
    let opened = file.metadata()?;
    if opened.uid() != rustix::process::geteuid().as_raw() || opened.nlink() != 1 {
        return Err(std::io::Error::other(
            "diagnostic log is not privately owned",
        ));
    }
    if let Some(before) = before {
        if before.dev() != opened.dev() || before.ino() != opened.ino() {
            return Err(std::io::Error::other("diagnostic log identity changed"));
        }
    }
    let started_at = opened
        .created()
        .or_else(|_| opened.modified())
        .unwrap_or_else(|_| SystemTime::now());
    Ok((file, opened.len(), started_at))
}

fn validated_regular_file_metadata(path: &Path) -> std::io::Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.file_type().is_file()
                && !metadata.file_type().is_symlink()
                && metadata.nlink() == 1
                && metadata.uid() == rustix::process::geteuid().as_raw() =>
        {
            Ok(Some(metadata))
        }
        Ok(_) => Err(std::io::Error::other(
            "diagnostic path is not a private regular file",
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn write_log_line(state: &mut LogState, encoded: &[u8]) -> std::io::Result<()> {
    let expired = SystemTime::now()
        .duration_since(state.current_started_at)
        .is_ok_and(|age| age > LOG_RETENTION);
    let oversized =
        state.current_bytes.saturating_add(encoded.len() as u64) > CURRENT_LOG_MAX_BYTES;
    if state.current_bytes > 0 && (expired || oversized) {
        state.file.take();
        rotate_log_files(&state.logs_dir)?;
        prune_expired_backups(&state.logs_dir);
        let (file, bytes, started_at) =
            open_private_append_file(&state.logs_dir.join("petcore.jsonl"))?;
        state.file = Some(file);
        state.current_bytes = bytes;
        state.current_started_at = started_at;
    }
    let file = state
        .file
        .as_mut()
        .ok_or_else(|| std::io::Error::other("diagnostic log is unavailable"))?;
    file.write_all(encoded)?;
    state.current_bytes = state.current_bytes.saturating_add(encoded.len() as u64);
    Ok(())
}

fn backup_log_path(logs_dir: &Path, index: usize) -> PathBuf {
    logs_dir.join(format!("petcore.{index}.jsonl"))
}

fn rotate_log_files(logs_dir: &Path) -> std::io::Result<()> {
    prune_expired_backups(logs_dir);
    let oldest = backup_log_path(logs_dir, LOG_BACKUP_COUNT);
    remove_log_entry_if_present(&oldest)?;
    for index in (1..LOG_BACKUP_COUNT).rev() {
        let source = backup_log_path(logs_dir, index);
        let destination = backup_log_path(logs_dir, index + 1);
        if validated_regular_file_metadata(&source)?.is_some() {
            fs::rename(source, destination)?;
        }
    }
    let current = logs_dir.join("petcore.jsonl");
    if validated_regular_file_metadata(&current)?.is_some() {
        fs::rename(current, backup_log_path(logs_dir, 1))?;
    }
    Ok(())
}

fn remove_log_entry_if_present(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() || metadata.file_type().is_symlink() => {
            fs::remove_file(path)
        }
        Ok(_) => Err(std::io::Error::other(
            "diagnostic backup path is not removable",
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn prune_expired_backups(logs_dir: &Path) {
    let now = SystemTime::now();
    for index in 1..=LOG_BACKUP_COUNT {
        let path = backup_log_path(logs_dir, index);
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            let _ = fs::remove_file(path);
            continue;
        }
        if !metadata.file_type().is_file() {
            continue;
        }
        let expired = metadata
            .created()
            .or_else(|_| metadata.modified())
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age > LOG_RETENTION);
        if expired {
            let _ = fs::remove_file(path);
        }
    }
}

fn safe_rpc_method(method: &str) -> &'static str {
    match method {
        "petcore.health" => "petcore.health",
        "petcore.shutdown" => "petcore.shutdown",
        "state.snapshot" => "state.snapshot",
        "state.wait" => "state.wait",
        "behavior.get" => "behavior.get",
        "behavior.patch" => "behavior.patch",
        "overlay.placement.get" => "overlay.placement.get",
        "overlay.placement.update" => "overlay.placement.update",
        "settings.get" => "settings.get",
        "settings.update" => "settings.update",
        "agent.ingest" => "agent.ingest",
        "events.recent" => "events.recent",
        "pet.list" => "pet.list",
        "pet.activate" => "pet.activate",
        "pet.delete" => "pet.delete",
        "petpack.validate" => "petpack.validate",
        "petpack.import" => "petpack.import",
        "petpack.seed_bundled" => "petpack.seed_bundled",
        "petpack.export" => "petpack.export",
        "generation.start" => "generation.start",
        "generation.retry" => "generation.retry",
        "generation.messages" => "generation.messages",
        "generation.for_pet" => "generation.for_pet",
        "generation.latest" => "generation.latest",
        "generation.edit" => "generation.edit",
        "generation.messages.wait" => "generation.messages.wait",
        "generation.reply" => "generation.reply",
        "generation.cancel" => "generation.cancel",
        "connections.check" => "connections.check",
        "connections.receipts" => "connections.receipts",
        "connections.repair" => "connections.repair",
        "connections.refresh_installed" => "connections.refresh_installed",
        "connections.uninstall" => "connections.uninstall",
        "connections.test" => "connections.test",
        "renderer.budget" => "renderer.budget",
        "codex.app_server.probe" => "codex.app_server.probe",
        "diagnostics.export" => "diagnostics.export",
        _ => "invalid",
    }
}

fn rpc_success_is_diagnostic(method: &str) -> bool {
    matches!(
        method,
        "petcore.shutdown"
            | "behavior.patch"
            | "overlay.placement.update"
            | "settings.update"
            | "pet.activate"
            | "pet.delete"
            | "petpack.import"
            | "petpack.seed_bundled"
            | "petpack.export"
            | "generation.start"
            | "generation.retry"
            | "generation.edit"
            | "generation.reply"
            | "generation.cancel"
            | "connections.check"
            | "connections.repair"
            | "connections.refresh_installed"
            | "connections.uninstall"
            | "connections.test"
            | "diagnostics.export"
    )
}

#[derive(Debug, Clone, Serialize)]
pub struct DiagnosticExportResult {
    pub path: String,
    pub file_name: String,
    pub file_count: usize,
    pub archive_bytes: u64,
}

#[derive(Debug, Serialize)]
struct ExportedLogFile {
    archive_name: String,
    source_bytes: u64,
    included_bytes: u64,
    truncated: bool,
    sha256: String,
    content: Vec<u8>,
}

#[derive(Debug, Serialize)]
struct ExportManifest {
    schema_version: &'static str,
    created_at: String,
    mode: &'static str,
    privacy_profile: &'static str,
    log_schema_version: &'static str,
    log_current_max_bytes: u64,
    log_backup_count: usize,
    log_retention_days: u64,
    runtime_manifest: RuntimeReleaseManifest,
    files: Vec<ExportManifestFile>,
    omitted_files: Vec<ExportManifestOmission>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ExportOmissionReason {
    AggregateLimit,
    Expired,
    InvalidJson,
    NoCompleteRecords,
    ReadFailed,
    UnsafeFile,
}

#[derive(Debug, Serialize)]
struct ExportManifestOmission {
    name: String,
    reason: ExportOmissionReason,
}

#[derive(Debug, Serialize)]
struct ExportManifestFile {
    name: String,
    source_bytes: u64,
    included_bytes: u64,
    truncated: bool,
    sha256: String,
}

pub fn export_diagnostics(
    paths: &AppPaths,
    logger: &DiagnosticLogger,
    app_environment: &Value,
) -> Result<DiagnosticExportResult> {
    let safe_app_environment = sanitize_app_environment(app_environment)?;
    let _export_guard = logger
        .export_lock
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    logger.export_started();
    logger.sync();

    ensure_private_directory(&paths.logs_dir)?;
    let exports_dir = paths.home.join("diagnostic-exports");
    ensure_private_directory(&exports_dir)?;
    cleanup_expired_exports(&exports_dir, None);

    let mut omitted_files = Vec::new();
    let logs = collect_allowlisted_logs(paths, &mut omitted_files)?;
    let created_at = now_rfc3339();
    let environment = serde_json::to_vec_pretty(&json!({
        "schema_version": DIAGNOSTIC_ENVIRONMENT_SCHEMA_VERSION,
        "created_at": created_at,
        "app": safe_app_environment,
        "petcore": {
            "operating_system": std::env::consts::OS,
            "architecture": std::env::consts::ARCH,
            "family": std::env::consts::FAMILY,
            "available_parallelism": std::thread::available_parallelism()
                .map(|value| value.get())
                .unwrap_or(1),
            "logging_degraded": logger.is_degraded(),
            "runtime_manifest": RuntimeReleaseManifest::compiled(),
        }
    }))?;

    const README: &str = "Agent Pet Companion diagnostic bundle\n\
This archive contains bounded, redacted application and PetCore diagnostics for troubleshooting.\n\
It intentionally excludes databases, pets, generation workspaces, connector configuration, runtime tokens, prompts, messages, commands, and tool output.\n\
\n\
Agent Pet Companion 诊断包\n\
此压缩包包含经过容量限制和脱敏处理的 App 与 PetCore 诊断信息，用于问题排查。\n\
其中不包含数据库、宠物资源、生成工作区、连接器配置、运行令牌、提示词、消息、命令或工具输出。\n";
    let readme = README.as_bytes();
    let mut manifest_files = vec![
        ExportManifestFile {
            name: "environment.json".to_string(),
            source_bytes: environment.len() as u64,
            included_bytes: environment.len() as u64,
            truncated: false,
            sha256: hex::encode(Sha256::digest(&environment)),
        },
        ExportManifestFile {
            name: "README.txt".to_string(),
            source_bytes: readme.len() as u64,
            included_bytes: readme.len() as u64,
            truncated: false,
            sha256: hex::encode(Sha256::digest(readme)),
        },
    ];
    manifest_files.extend(
        logs.iter()
            .map(|file| ExportManifestFile {
                name: file.archive_name.clone(),
                source_bytes: file.source_bytes,
                included_bytes: file.included_bytes,
                truncated: file.truncated,
                sha256: file.sha256.clone(),
            })
            .collect::<Vec<_>>(),
    );
    let manifest = serde_json::to_vec_pretty(&ExportManifest {
        schema_version: DIAGNOSTIC_EXPORT_SCHEMA_VERSION,
        created_at: created_at.clone(),
        mode: "petcore_rpc",
        privacy_profile: "apc.diagnostic-redaction.v1",
        log_schema_version: DIAGNOSTIC_LOG_SCHEMA_VERSION,
        log_current_max_bytes: CURRENT_LOG_MAX_BYTES,
        log_backup_count: LOG_BACKUP_COUNT,
        log_retention_days: LOG_RETENTION.as_secs() / (24 * 60 * 60),
        runtime_manifest: RuntimeReleaseManifest::compiled(),
        files: manifest_files,
        omitted_files,
    })?;

    let file_name = unique_export_file_name(&exports_dir, &created_at);
    let final_path = exports_dir.join(&file_name);
    let mut temporary = tempfile::Builder::new()
        .prefix(".diagnostic-export-")
        .tempfile_in(&exports_dir)?;
    rustix::fs::fchmod(
        temporary.as_file(),
        rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
    )
    .map_err(std::io::Error::from)?;
    {
        let mut zip = zip::ZipWriter::new(temporary.as_file_mut());
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .unix_permissions(0o600);
        write_zip_entry(
            &mut zip,
            &format!("{DIAGNOSTIC_ARCHIVE_ROOT}/manifest.json"),
            &manifest,
            options,
        )?;
        write_zip_entry(
            &mut zip,
            &format!("{DIAGNOSTIC_ARCHIVE_ROOT}/environment.json"),
            &environment,
            options,
        )?;
        write_zip_entry(
            &mut zip,
            &format!("{DIAGNOSTIC_ARCHIVE_ROOT}/README.txt"),
            readme,
            options,
        )?;
        for log in &logs {
            write_zip_entry(
                &mut zip,
                &format!("{DIAGNOSTIC_ARCHIVE_ROOT}/{}", log.archive_name),
                &log.content,
                options,
            )?;
        }
        zip.finish()?;
    }
    temporary.as_file().sync_all()?;
    temporary
        .persist_noclobber(&final_path)
        .map_err(|error| PetCoreError::Io(error.error))?;
    File::open(&exports_dir)?.sync_all()?;
    let archive_bytes = fs::metadata(&final_path)?.len();
    cleanup_expired_exports(&exports_dir, Some(&file_name));
    let path = final_path
        .to_str()
        .ok_or_else(|| {
            PetCoreError::InvalidRequest("diagnostic export path is not valid UTF-8".to_string())
        })?
        .to_string();

    Ok(DiagnosticExportResult {
        path,
        file_name,
        file_count: logs.len() + 3,
        archive_bytes,
    })
}

fn write_zip_entry(
    zip: &mut zip::ZipWriter<&mut File>,
    name: &str,
    content: &[u8],
    options: SimpleFileOptions,
) -> Result<()> {
    zip.start_file(name, options)?;
    zip.write_all(content)?;
    Ok(())
}

fn cleanup_expired_exports(exports_dir: &Path, protected_file_name: Option<&str>) {
    let Ok(entries) = fs::read_dir(exports_dir) else {
        return;
    };
    let now = SystemTime::now();
    let mut completed = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(file_name) = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
        else {
            continue;
        };
        let is_completed = file_name.ends_with(".zip")
            && (file_name.starts_with("AgentPetCompanion-Diagnostics-")
                || file_name.starts_with("offline-"));
        let strict_staging = file_name
            .strip_prefix(".staging-")
            .is_some_and(|suffix| uuid::Uuid::parse_str(suffix).is_ok());
        let temporary = file_name.starts_with(".diagnostic-export-") || strict_staging;
        let recognized = is_completed || temporary;
        if !recognized {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        let expired = metadata
            .created()
            .or_else(|_| metadata.modified())
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age > EXPORT_RETENTION);
        if strict_staging {
            if expired
                && metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == rustix::process::geteuid().as_raw()
                && metadata.permissions().mode() & 0o777 == 0o700
            {
                let _ = fs::remove_dir_all(path);
            }
            continue;
        }
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.nlink() != 1
            || metadata.uid() != rustix::process::geteuid().as_raw()
        {
            continue;
        }
        if expired {
            let _ = fs::remove_file(path);
        } else if is_completed {
            completed.push((
                path,
                file_name,
                metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                metadata.len(),
            ));
        }
    }
    completed.sort_by(|left, right| {
        let left_protected = protected_file_name == Some(left.1.as_str());
        let right_protected = protected_file_name == Some(right.1.as_str());
        right_protected
            .cmp(&left_protected)
            .then_with(|| right.2.cmp(&left.2))
            .then_with(|| right.1.cmp(&left.1))
    });
    let mut retained_count = 0_usize;
    let mut retained_bytes = 0_u64;
    for (path, file_name, _, bytes) in completed {
        let protected = protected_file_name == Some(file_name.as_str());
        let fits = retained_count < MAX_RETAINED_EXPORTS
            && retained_bytes.saturating_add(bytes) <= MAX_RETAINED_EXPORT_BYTES;
        if protected || fits {
            retained_count = retained_count.saturating_add(1);
            retained_bytes = retained_bytes.saturating_add(bytes);
        } else {
            let _ = fs::remove_file(path);
        }
    }
}

fn unique_export_file_name(exports_dir: &Path, created_at: &str) -> String {
    let stamp = created_at
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .collect::<String>();
    let base = format!("AgentPetCompanion-Diagnostics-{stamp}");
    for suffix in 0..10_000_u32 {
        let name = if suffix == 0 {
            format!("{base}.zip")
        } else {
            format!("{base}-{suffix}.zip")
        };
        if !exports_dir.join(&name).exists() {
            return name;
        }
    }
    format!("{base}-overflow.zip")
}

fn allowlisted_log_names() -> Vec<String> {
    let mut names = [
        "app.jsonl",
        "petcore.jsonl",
        "petcore-launch.log",
        "petcore.launchd.out.log",
        "petcore.launchd.err.log",
    ]
    .into_iter()
    .map(ToOwned::to_owned)
    .collect::<Vec<_>>();
    for index in 1..=LOG_BACKUP_COUNT {
        names.push(format!("app.{index}.jsonl"));
        names.push(format!("petcore.{index}.jsonl"));
    }
    names.push("petcore-launch.1.log".to_string());
    names.push("petcore-launch.2.log".to_string());
    names
}

fn collect_allowlisted_logs(
    paths: &AppPaths,
    omitted_files: &mut Vec<ExportManifestOmission>,
) -> Result<Vec<ExportedLogFile>> {
    let mut result = Vec::new();
    let mut remaining = MAX_EXPORTED_LOG_BYTES;
    for file_name in allowlisted_log_names() {
        let path = paths.logs_dir.join(&file_name);
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                omit_log(omitted_files, &file_name, ExportOmissionReason::ReadFailed);
                continue;
            }
        };
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.nlink() != 1
            || metadata.uid() != rustix::process::geteuid().as_raw()
        {
            omit_log(omitted_files, &file_name, ExportOmissionReason::UnsafeFile);
            continue;
        }
        let expired = file_name.starts_with("petcore")
            && file_name.ends_with(".jsonl")
            && metadata
                .created()
                .or_else(|_| metadata.modified())
                .ok()
                .and_then(|modified| SystemTime::now().duration_since(modified).ok())
                .is_some_and(|age| age > LOG_RETENTION);
        if expired {
            omit_log(omitted_files, &file_name, ExportOmissionReason::Expired);
            continue;
        }
        if remaining == 0 {
            omit_log(
                omitted_files,
                &file_name,
                ExportOmissionReason::AggregateLimit,
            );
            continue;
        }
        let descriptor = match rustix::fs::open(
            &path,
            rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        ) {
            Ok(descriptor) => descriptor,
            Err(_) => {
                omit_log(omitted_files, &file_name, ExportOmissionReason::ReadFailed);
                continue;
            }
        };
        let mut file = File::from(descriptor);
        let opened = match file.metadata() {
            Ok(metadata) => metadata,
            Err(_) => {
                omit_log(omitted_files, &file_name, ExportOmissionReason::ReadFailed);
                continue;
            }
        };
        if metadata.dev() != opened.dev()
            || metadata.ino() != opened.ino()
            || opened.uid() != rustix::process::geteuid().as_raw()
            || opened.nlink() != 1
        {
            omit_log(omitted_files, &file_name, ExportOmissionReason::UnsafeFile);
            continue;
        }
        let per_file_limit = if file_name.ends_with(".jsonl") {
            MAX_LOG_SOURCE_BYTES
        } else {
            MAX_LEGACY_LOG_SOURCE_BYTES
        };
        let read_limit = metadata.len().min(per_file_limit).min(remaining);
        let mut bytes = match read_file_tail(&mut file, metadata.len(), read_limit) {
            Ok(bytes) => bytes,
            Err(_) => {
                omit_log(omitted_files, &file_name, ExportOmissionReason::ReadFailed);
                continue;
            }
        };
        let mut truncated = read_limit < metadata.len();
        if truncated {
            discard_partial_first_line(&mut bytes);
        }
        let mut redacted = if file_name.ends_with(".jsonl") {
            let redaction = redact_structured_log_content(&bytes, paths);
            truncated |= redaction.dropped_records;
            if metadata.len() > 0 && redaction.content.is_empty() {
                let reason = if bytes.is_empty() || redaction.parsed_json_objects > 0 {
                    ExportOmissionReason::NoCompleteRecords
                } else {
                    ExportOmissionReason::InvalidJson
                };
                omit_log(omitted_files, &file_name, reason);
                continue;
            }
            redaction.content
        } else {
            redact_legacy_log_content(&bytes, paths)
        };
        let mut aggregate_truncated = false;
        if redacted.len() as u64 > remaining {
            truncate_to_complete_lines(&mut redacted, remaining as usize);
            truncated = true;
            aggregate_truncated = true;
        }
        if metadata.len() > 0 && redacted.is_empty() {
            omit_log(
                omitted_files,
                &file_name,
                if aggregate_truncated {
                    ExportOmissionReason::AggregateLimit
                } else {
                    ExportOmissionReason::NoCompleteRecords
                },
            );
            continue;
        }
        remaining = remaining.saturating_sub(redacted.len() as u64);
        let sha256 = hex::encode(Sha256::digest(&redacted));
        result.push(ExportedLogFile {
            archive_name: format!("logs/{file_name}"),
            source_bytes: metadata.len(),
            included_bytes: redacted.len() as u64,
            truncated,
            sha256,
            content: redacted,
        });
    }
    Ok(result)
}

fn omit_log(
    omitted_files: &mut Vec<ExportManifestOmission>,
    name: &str,
    reason: ExportOmissionReason,
) {
    omitted_files.push(ExportManifestOmission {
        name: name.to_string(),
        reason,
    });
}

fn read_file_tail(file: &mut File, file_bytes: u64, limit: u64) -> std::io::Result<Vec<u8>> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    file.seek(SeekFrom::Start(file_bytes.saturating_sub(limit)))?;
    let mut bytes = Vec::with_capacity(limit as usize);
    file.take(limit).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn discard_partial_first_line(bytes: &mut Vec<u8>) {
    if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
        bytes.drain(..=newline);
    } else {
        bytes.clear();
    }
}

fn truncate_to_complete_lines(bytes: &mut Vec<u8>, maximum_bytes: usize) {
    if bytes.len() <= maximum_bytes {
        return;
    }
    bytes.truncate(maximum_bytes);
    if let Some(last_newline) = bytes.iter().rposition(|byte| *byte == b'\n') {
        bytes.truncate(last_newline + 1);
    } else {
        bytes.clear();
    }
}

struct StructuredLogRedaction {
    content: Vec<u8>,
    parsed_json_objects: usize,
    dropped_records: bool,
}

fn redact_structured_log_content(bytes: &[u8], paths: &AppPaths) -> StructuredLogRedaction {
    let mut output = Vec::with_capacity(bytes.len());
    let mut parsed_json_objects = 0_usize;
    let mut dropped_records = false;
    for line in bytes.split(|byte| *byte == b'\n') {
        if line.is_empty() {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
            dropped_records = true;
            continue;
        };
        parsed_json_objects = parsed_json_objects.saturating_add(1);
        if record.get("schema_version").and_then(Value::as_str)
            != Some(DIAGNOSTIC_LOG_SCHEMA_VERSION)
        {
            dropped_records = true;
            continue;
        }
        let Some(timestamp) = record.get("timestamp").and_then(Value::as_str) else {
            dropped_records = true;
            continue;
        };
        if time::OffsetDateTime::parse(timestamp, &time::format_description::well_known::Rfc3339)
            .is_err()
        {
            dropped_records = true;
            continue;
        }
        let Some(process) = record
            .get("process")
            .and_then(Value::as_str)
            .filter(|value| matches!(*value, "app" | "petcore"))
        else {
            dropped_records = true;
            continue;
        };
        let Some(level) = record
            .get("level")
            .and_then(Value::as_str)
            .filter(|value| matches!(*value, "debug" | "info" | "notice" | "warning" | "error"))
        else {
            dropped_records = true;
            continue;
        };
        let Some(category) = record
            .get("category")
            .and_then(Value::as_str)
            .filter(|value| safe_structured_token(value, 64))
        else {
            dropped_records = true;
            continue;
        };
        let Some(event) = record
            .get("event")
            .and_then(Value::as_str)
            .filter(|value| safe_structured_token(value, 96))
        else {
            dropped_records = true;
            continue;
        };
        let Some(metadata_value @ Value::Object(_)) = record.get("metadata") else {
            dropped_records = true;
            continue;
        };
        let metadata = sanitize_structured_log_value(metadata_value, "metadata", 0, paths)
            .unwrap_or_else(|| Value::Object(Map::new()));
        let sanitized = json!({
            "schema_version": DIAGNOSTIC_LOG_SCHEMA_VERSION,
            "timestamp": timestamp,
            "process": process,
            "level": level,
            "category": category,
            "event": event,
            "metadata": metadata,
        });
        if let Ok(mut encoded) = serde_json::to_vec(&sanitized) {
            encoded.push(b'\n');
            output.extend_from_slice(&encoded);
        } else {
            dropped_records = true;
        }
    }
    StructuredLogRedaction {
        content: output,
        parsed_json_objects,
        dropped_records,
    }
}

fn sanitize_structured_log_value(
    value: &Value,
    key: &str,
    depth: usize,
    paths: &AppPaths,
) -> Option<Value> {
    if depth > 6 || structured_sensitive_key(key) {
        return None;
    }
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => Some(value.clone()),
        Value::String(value) if structured_safe_identifier_key(key) => {
            safe_structured_token(value, 128).then(|| Value::String(value.clone()))
        }
        Value::String(value) => {
            let redacted = redact_free_text(
                value,
                std::env::var("HOME").ok().as_deref(),
                paths.home.to_str(),
            );
            Some(Value::String(truncate_utf8(&redacted, 256)))
        }
        Value::Array(values) => Some(Value::Array(
            values
                .iter()
                .take(64)
                .filter_map(|value| sanitize_structured_log_value(value, key, depth + 1, paths))
                .collect(),
        )),
        Value::Object(values) => {
            let mut sanitized = Map::new();
            for (nested_key, nested_value) in values.iter().take(128) {
                if !safe_structured_token(nested_key, 64) {
                    continue;
                }
                if let Some(value) =
                    sanitize_structured_log_value(nested_value, nested_key, depth + 1, paths)
                {
                    sanitized.insert(nested_key.clone(), value);
                }
            }
            Some(Value::Object(sanitized))
        }
    }
}

fn safe_structured_token(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        && !contains_identity_signal(value)
}

fn structured_safe_identifier_key(key: &str) -> bool {
    matches!(
        key,
        "build_id"
            | "bundle_id"
            | "petcore_build_id"
            | "active_session_count"
            | "session_message_timeout_minutes"
            | "session_group_display"
    )
}

fn structured_sensitive_key(key: &str) -> bool {
    if structured_safe_identifier_key(key) {
        return false;
    }
    let key = key.to_ascii_lowercase();
    key == "id"
        || key.ends_with("_id")
        || key == "ip"
        || key.starts_with("ip_")
        || key.ends_with("_ip")
        || [
            "authorization",
            "address",
            "command",
            "computer",
            "content",
            "cookie",
            "credential",
            "cwd",
            "detail",
            "directory",
            "email",
            "home",
            "host",
            "identifier",
            "message",
            "name",
            "output",
            "password",
            "path",
            "peer",
            "prompt",
            "reasoning",
            "secret",
            "serial",
            "session",
            "thread",
            "token",
            "transcript",
            "url",
            "user",
            "user_content",
            "username",
            "uuid",
        ]
        .iter()
        .any(|marker| key == *marker || key.contains(marker))
}

fn redact_legacy_log_content(bytes: &[u8], paths: &AppPaths) -> Vec<u8> {
    let text = String::from_utf8_lossy(bytes);
    let home = std::env::var("HOME").ok();
    let app_home = paths.home.to_str();
    let mut output = String::with_capacity(text.len());
    for line in text.split_inclusive('\n') {
        let has_newline = line.ends_with('\n');
        let line = line.strip_suffix('\n').unwrap_or(line);
        let mut redacted = redact_free_text(line, home.as_deref(), app_home);
        if redacted.len() > MAX_APP_ENVIRONMENT_STRING_BYTES * 2 {
            redacted = truncate_utf8(&redacted, MAX_APP_ENVIRONMENT_STRING_BYTES * 2);
        }
        output.push_str(&redacted);
        if has_newline {
            output.push('\n');
        }
    }
    output.into_bytes()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentSnapshot {
    schema_version: String,
    captured_at: String,
    app: AppEnvironmentApp,
    device: AppEnvironmentDevice,
    behavior: AppEnvironmentBehavior,
    runtime: AppEnvironmentRuntime,
    connections: Vec<AppEnvironmentConnection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentApp {
    version: String,
    build: String,
    build_id: String,
    channel: String,
    bundle_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentDevice {
    operating_system: String,
    operating_system_version: String,
    operating_system_build: String,
    architecture: String,
    translated: bool,
    processor_count: u32,
    physical_memory_bytes: u64,
    screens: Vec<AppEnvironmentScreen>,
    locale: String,
    timezone: String,
    accessibility: AppEnvironmentAccessibility,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentScreen {
    width_pixels: u32,
    height_pixels: u32,
    scale: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentAccessibility {
    reduce_motion: bool,
    reduce_transparency: bool,
    voice_over_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentBehavior {
    enabled: bool,
    status_bubble: bool,
    appearance_theme: AppearanceTheme,
    bubble_transparency: f64,
    click_menu: bool,
    mouse_passthrough: bool,
    auto_hide: bool,
    session_message_timeout_minutes: u16,
    session_group_display: SessionGroupDisplay,
    fps_profile: FpsProfileName,
    sources: AppEnvironmentSources,
    events: AppEnvironmentEvents,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentSources {
    codex: bool,
    claude_code: bool,
    pi: bool,
    opencode: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentEvents {
    start: bool,
    tool: bool,
    waiting: bool,
    review: bool,
    done: bool,
    failed: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AppEnvironmentRuntimePhase {
    Checking,
    Running,
    Failed,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum AppEnvironmentGenerationState {
    Idle,
    Starting,
    Running,
    WaitingForInput,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AppEnvironmentServiceFailureCode {
    None,
    PetcoreBinaryMissing,
    CliMissing,
    LaunchAgentDisabled,
    RuntimePathsFailed,
    LaunchctlFailed,
    CandidateHealthFailed,
    DirectLaunchFailed,
    UpdateRollbackFailed,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentRuntime {
    pet_core_phase: AppEnvironmentRuntimePhase,
    pet_core_version: Option<String>,
    pet_core_app_build: Option<String>,
    pet_core_build_id: Option<String>,
    pet_core_rpc_protocol: Option<String>,
    release_channel: Option<String>,
    database_schema_range: Option<String>,
    active_pet_present: bool,
    pet_count: u32,
    active_agent_source: Option<AgentSource>,
    active_agent_state: Option<PetStateName>,
    active_session_count: u32,
    recent_event_count: u32,
    generation_state: AppEnvironmentGenerationState,
    overlay_visible: bool,
    last_service_failure_code: AppEnvironmentServiceFailureCode,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppEnvironmentConnection {
    source: AgentSource,
    check_mode: ConnectionCheckMode,
    connector_installed: Option<bool>,
    blocking_count: u32,
    unverified_count: u32,
    unsupported_count: u32,
}

fn sanitize_app_environment(value: &Value) -> Result<Value> {
    if serde_json::to_vec(value)?.len() > MAX_APP_ENVIRONMENT_BYTES {
        return Err(invalid_app_environment(
            "app_environment exceeds the diagnostic export size limit",
        ));
    }
    let environment: AppEnvironmentSnapshot =
        serde_json::from_value(value.clone()).map_err(|_| {
            invalid_app_environment("app_environment does not match apc.app-environment.v1")
        })?;
    validate_app_environment(&environment)?;
    Ok(serde_json::to_value(environment)?)
}

fn validate_app_environment(environment: &AppEnvironmentSnapshot) -> Result<()> {
    if environment.schema_version != APP_ENVIRONMENT_SCHEMA_VERSION {
        return Err(invalid_app_environment(
            "app_environment schema_version is unsupported",
        ));
    }
    if time::OffsetDateTime::parse(
        &environment.captured_at,
        &time::format_description::well_known::Rfc3339,
    )
    .is_err()
    {
        return Err(invalid_app_environment(
            "app_environment captured_at is invalid",
        ));
    }

    for (label, value) in [
        ("app.version", environment.app.version.as_str()),
        ("app.build", environment.app.build.as_str()),
        ("app.build_id", environment.app.build_id.as_str()),
        ("app.channel", environment.app.channel.as_str()),
        ("app.bundle_id", environment.app.bundle_id.as_str()),
        (
            "device.operating_system_version",
            environment.device.operating_system_version.as_str(),
        ),
        (
            "device.operating_system_build",
            environment.device.operating_system_build.as_str(),
        ),
        (
            "device.architecture",
            environment.device.architecture.as_str(),
        ),
    ] {
        validate_safe_token(label, value, 128, b"._-")?;
    }
    if environment.device.operating_system != "macOS" {
        return Err(invalid_app_environment(
            "app_environment operating_system is unsupported",
        ));
    }
    validate_safe_token("device.locale", &environment.device.locale, 64, b"._-@=;")?;
    validate_safe_token(
        "device.timezone",
        &environment.device.timezone,
        128,
        b"._-/+",
    )?;
    if !(1..=4_096).contains(&environment.device.processor_count)
        || environment.device.physical_memory_bytes == 0
        || environment.device.physical_memory_bytes > (1_u64 << 60)
        || environment.device.screens.len() > 16
    {
        return Err(invalid_app_environment(
            "app_environment device limits are invalid",
        ));
    }
    if environment.device.screens.iter().any(|screen| {
        screen.width_pixels == 0
            || screen.width_pixels > 200_000
            || screen.height_pixels == 0
            || screen.height_pixels > 200_000
            || !screen.scale.is_finite()
            || !(0.5..=8.0).contains(&screen.scale)
    }) {
        return Err(invalid_app_environment(
            "app_environment screen values are invalid",
        ));
    }
    if !environment.behavior.bubble_transparency.is_finite()
        || !(0.0..=1.0).contains(&environment.behavior.bubble_transparency)
        || !(1..=1_440).contains(&environment.behavior.session_message_timeout_minutes)
    {
        return Err(invalid_app_environment(
            "app_environment behavior values are invalid",
        ));
    }

    for (label, value) in [
        (
            "runtime.pet_core_version",
            environment.runtime.pet_core_version.as_deref(),
        ),
        (
            "runtime.pet_core_app_build",
            environment.runtime.pet_core_app_build.as_deref(),
        ),
        (
            "runtime.pet_core_build_id",
            environment.runtime.pet_core_build_id.as_deref(),
        ),
        (
            "runtime.pet_core_rpc_protocol",
            environment.runtime.pet_core_rpc_protocol.as_deref(),
        ),
        (
            "runtime.release_channel",
            environment.runtime.release_channel.as_deref(),
        ),
    ] {
        if let Some(value) = value {
            validate_safe_token(label, value, 128, b"._-")?;
        }
    }
    if let Some(value) = environment.runtime.database_schema_range.as_deref() {
        if value.is_empty()
            || value.len() > 128
            || !value.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-' | '–')
            })
        {
            return Err(invalid_app_environment(
                "app_environment database_schema_range is invalid",
            ));
        }
    }
    if environment.runtime.pet_count > 1_000_000
        || environment.runtime.active_session_count > 1_000_000
        || environment.runtime.recent_event_count > 1_000_000
        || environment.connections.len() > 4
    {
        return Err(invalid_app_environment(
            "app_environment runtime limits are invalid",
        ));
    }
    let mut seen_sources = [false; 4];
    for connection in &environment.connections {
        let index = match connection.source {
            AgentSource::Codex => 0,
            AgentSource::ClaudeCode => 1,
            AgentSource::Pi => 2,
            AgentSource::Opencode => 3,
        };
        if std::mem::replace(&mut seen_sources[index], true)
            || connection.blocking_count > 10_000
            || connection.unverified_count > 10_000
            || connection.unsupported_count > 10_000
        {
            return Err(invalid_app_environment(
                "app_environment connection values are invalid",
            ));
        }
    }
    Ok(())
}

fn validate_safe_token(
    label: &'static str,
    value: &str,
    maximum_bytes: usize,
    punctuation: &[u8],
) -> Result<()> {
    if value.is_empty()
        || value.len() > maximum_bytes
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || punctuation.contains(&byte))
    {
        return Err(invalid_app_environment(match label {
            "app.version" => "app_environment app.version is invalid",
            "app.build" => "app_environment app.build is invalid",
            "app.build_id" => "app_environment app.build_id is invalid",
            "app.channel" => "app_environment app.channel is invalid",
            "app.bundle_id" => "app_environment app.bundle_id is invalid",
            "device.operating_system_version" => {
                "app_environment operating_system_version is invalid"
            }
            "device.operating_system_build" => "app_environment operating_system_build is invalid",
            "device.architecture" => "app_environment architecture is invalid",
            "device.locale" => "app_environment locale is invalid",
            "device.timezone" => "app_environment timezone is invalid",
            _ => "app_environment runtime identifier is invalid",
        }));
    }
    Ok(())
}

fn invalid_app_environment(message: &'static str) -> PetCoreError {
    PetCoreError::InvalidRequest(message.to_string())
}

fn redact_free_text(value: &str, user_home: Option<&str>, app_home: Option<&str>) -> String {
    let lower = value.to_ascii_lowercase();
    if [
        "authorization",
        "bearer ",
        "api_key",
        "api-key",
        "apikey",
        "access_token",
        "refresh_token",
        "password",
        "private_key",
        "cookie:",
        "secret=",
        "token=",
        "\"token\"",
        "\"secret\"",
        "\"password\"",
        "\"cookie\"",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
    {
        return "[REDACTED]".to_string();
    }

    if contains_identity_signal(value) {
        return "[REDACTED_IDENTITY]".to_string();
    }

    if value.split_whitespace().any(|token| {
        token
            .split_once(['=', ':'])
            .map(|(key, _)| {
                let key = key.trim_matches(|character: char| {
                    matches!(character, '"' | '\'' | '(' | '[' | '{')
                });
                structured_sensitive_key(key)
            })
            .unwrap_or(false)
    }) {
        return "[REDACTED]".to_string();
    }
    if contains_path_signal(value) {
        return "[REDACTED_PATH]".to_string();
    }
    if app_home
        .into_iter()
        .chain(user_home)
        .filter(|path| !path.is_empty())
        .any(|path| value.contains(path))
    {
        return "[REDACTED_PATH]".to_string();
    }
    redact_tokens(value)
}

fn contains_identity_signal(value: &str) -> bool {
    value
        .split(|character: char| {
            character.is_whitespace()
                || matches!(character, ',' | ';' | '"' | '\'' | '(' | ')' | '{' | '}')
        })
        .filter(|token| !token.is_empty())
        .any(|token| {
            let raw_candidate = token
                .rsplit_once('=')
                .map(|(_, value)| value)
                .unwrap_or(token);
            let candidate = raw_candidate.trim_matches('.');
            let unbracketed =
                candidate.trim_matches(|character: char| matches!(character, '[' | ']'));
            let hostname = candidate
                .split_once(':')
                .map(|(host, _)| host)
                .unwrap_or(candidate)
                .trim_matches(|character: char| matches!(character, '[' | ']'));
            raw_candidate.parse::<std::net::IpAddr>().is_ok()
                || raw_candidate.parse::<std::net::SocketAddr>().is_ok()
                || candidate.parse::<std::net::IpAddr>().is_ok()
                || candidate.parse::<std::net::SocketAddr>().is_ok()
                || unbracketed.parse::<std::net::IpAddr>().is_ok()
                || hostname.parse::<std::net::IpAddr>().is_ok()
                || candidate.to_ascii_lowercase().ends_with(".local")
                || hostname.to_ascii_lowercase().ends_with(".local")
        })
}

fn contains_path_signal(value: &str) -> bool {
    value.contains("/Users/")
        || value.contains("/Volumes/")
        || value.contains("=/")
        || value.split_whitespace().any(|token| {
            let token = token.trim_start_matches(|character: char| {
                matches!(character, '"' | '\'' | '(' | '[' | '{')
            });
            token.starts_with('/') || token.starts_with("~/")
        })
}

fn redact_tokens(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut token = String::new();
    let flush = |token: &mut String, output: &mut String| {
        if token.is_empty() {
            return;
        }
        let replacement = if token.starts_with('/')
            || token.starts_with("~/")
            || token.contains("/Users/")
            || token.contains("=/")
        {
            Some("[REDACTED_PATH]")
        } else if token.contains("://") {
            Some("[REDACTED_URL]")
        } else if token.contains('@') && token.contains('.') {
            Some("[REDACTED_EMAIL]")
        } else if looks_like_private_identifier(token) {
            Some("[REDACTED_ID]")
        } else {
            None
        };
        output.push_str(replacement.unwrap_or(token));
        token.clear();
    };
    for character in value.chars() {
        if character.is_whitespace()
            || matches!(
                character,
                '"' | '\'' | ',' | ';' | '(' | ')' | '[' | ']' | '{' | '}'
            )
        {
            flush(&mut token, &mut output);
            output.push(character);
        } else {
            token.push(character);
        }
    }
    flush(&mut token, &mut output);
    output
}

fn looks_like_private_identifier(token: &str) -> bool {
    let trimmed = token.trim_matches(|character: char| matches!(character, ':' | '=' | '.'));
    let lower = trimmed.to_ascii_lowercase();
    if [
        "evt_", "job_", "sess_", "session_", "thread_", "turn_", "call_", "cap_",
    ]
    .iter()
    .any(|prefix| lower.starts_with(prefix) && lower.len() > prefix.len() + 4)
    {
        return true;
    }
    let bytes = trimmed.as_bytes();
    if bytes.len() == 36
        && [8, 13, 18, 23]
            .into_iter()
            .all(|index| bytes.get(index) == Some(&b'-'))
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| [8, 13, 18, 23].contains(&index) || byte.is_ascii_hexdigit())
    {
        return true;
    }
    bytes.len() >= 24 && bytes.iter().all(u8::is_ascii_hexdigit)
}

fn truncate_utf8(value: &str, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value.to_string();
    }
    const ELLIPSIS: &str = "…";
    let mut end = maximum_bytes.saturating_sub(ELLIPSIS.len());
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{ELLIPSIS}", &value[..end])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn valid_app_environment() -> Value {
        json!({
            "schema_version": "apc.app-environment.v1",
            "captured_at": "2026-07-20T08:00:00.123Z",
            "app": {
                "version": "1.2.3",
                "build": "42",
                "build_id": "release-42",
                "channel": "release",
                "bundle_id": "dev.agentpet.companion"
            },
            "device": {
                "operating_system": "macOS",
                "operating_system_version": "15.5.0",
                "operating_system_build": "24F74",
                "architecture": "arm64",
                "translated": false,
                "processor_count": 10,
                "physical_memory_bytes": 17_179_869_184_u64,
                "locale": "en_US@calendar=gregorian;hours=h23",
                "timezone": "America/Los_Angeles",
                "screens": [{
                    "width_pixels": 3024,
                    "height_pixels": 1964,
                    "scale": 2.0
                }],
                "accessibility": {
                    "reduce_motion": false,
                    "reduce_transparency": false,
                    "voice_over_enabled": false
                }
            },
            "behavior": {
                "enabled": true,
                "status_bubble": true,
                "appearance_theme": "system",
                "bubble_transparency": 0.55,
                "click_menu": true,
                "mouse_passthrough": false,
                "auto_hide": true,
                "session_message_timeout_minutes": 15,
                "session_group_display": "stacked",
                "fps_profile": "standard",
                "sources": {
                    "codex": true,
                    "claude_code": true,
                    "pi": true,
                    "opencode": true
                },
                "events": {
                    "start": true,
                    "tool": true,
                    "waiting": true,
                    "review": true,
                    "done": true,
                    "failed": true
                }
            },
            "runtime": {
                "pet_core_phase": "running",
                "pet_core_version": "0.1.0",
                "pet_core_app_build": "42",
                "pet_core_build_id": "release-42",
                "pet_core_rpc_protocol": "apc.petcore-rpc.v2",
                "release_channel": "release",
                "database_schema_range": "1–20",
                "active_pet_present": true,
                "pet_count": 2,
                "active_agent_source": "codex",
                "active_agent_state": "tool",
                "active_session_count": 3,
                "recent_event_count": 20,
                "generation_state": "waitingForInput",
                "overlay_visible": true,
                "last_service_failure_code": "none"
            },
            "connections": [{
                "source": "codex",
                "check_mode": "runtime",
                "connector_installed": true,
                "blocking_count": 0,
                "unverified_count": 1,
                "unsupported_count": 0
            }]
        })
    }

    #[test]
    fn logger_rotates_with_private_permissions_and_bounded_backups() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let logger = DiagnosticLogger::new(&paths);
        let large = vec![b'x'; CURRENT_LOG_MAX_BYTES as usize - 128];
        fs::write(paths.logs_dir.join("petcore.jsonl"), large).unwrap();
        drop(logger);

        let logger = DiagnosticLogger::new(&paths);
        for _ in 0..8 {
            logger.daemon_phase("ready");
        }
        logger.sync();

        assert_eq!(
            fs::metadata(&paths.logs_dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(paths.logs_dir.join("petcore.jsonl"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(paths.logs_dir.join("petcore.1.jsonl").is_file());
        assert!(!paths.logs_dir.join("petcore.5.jsonl").exists());
    }

    #[test]
    fn logger_starts_with_safe_runtime_environment() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let logger = DiagnosticLogger::new(&paths);
        logger.sync();
        let content = fs::read_to_string(paths.logs_dir.join("petcore.jsonl")).unwrap();
        let first: Value = serde_json::from_str(content.lines().next().unwrap()).unwrap();
        assert_eq!(first["schema_version"], DIAGNOSTIC_LOG_SCHEMA_VERSION);
        assert_eq!(first["process"], "petcore");
        assert_eq!(first["category"], "runtime");
        assert_eq!(first["event"], "environment");
        assert!(first["metadata"]["build_id"].is_string());
        assert!(first["metadata"]["available_parallelism"].is_number());
        assert!(first.get("path").is_none());
    }

    #[test]
    fn long_running_logger_rotates_on_age_during_write() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let logger = DiagnosticLogger::new(&paths);
        {
            let mut state = logger
                .inner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.current_started_at = SystemTime::now()
                .checked_sub(LOG_RETENTION + Duration::from_secs(1))
                .unwrap();
        }
        logger.daemon_phase("ready");
        logger.sync();
        assert!(paths.logs_dir.join("petcore.1.jsonl").is_file());
        assert!(paths.logs_dir.join("petcore.jsonl").is_file());
    }

    #[test]
    fn app_environment_accepts_only_the_bounded_typed_contract() {
        let sanitized = sanitize_app_environment(&valid_app_environment()).unwrap();
        assert_eq!(sanitized["app"]["build_id"], "release-42");
        assert_eq!(sanitized["runtime"]["active_session_count"], 3);
        assert_eq!(
            sanitized["device"]["locale"],
            "en_US@calendar=gregorian;hours=h23"
        );

        let mut unknown = valid_app_environment();
        unknown["api_token"] = json!("must-not-be-accepted");
        assert!(sanitize_app_environment(&unknown).is_err());

        let mut wrong_enum = valid_app_environment();
        wrong_enum["behavior"]["appearance_theme"] = json!("neon");
        assert!(sanitize_app_environment(&wrong_enum).is_err());

        let mut wrong_failure_code = valid_app_environment();
        wrong_failure_code["runtime"]["last_service_failure_code"] = json!("raw_error_text");
        assert!(sanitize_app_environment(&wrong_failure_code).is_err());

        let mut over_limit = valid_app_environment();
        over_limit["device"]["processor_count"] = json!(4_097);
        assert!(sanitize_app_environment(&over_limit).is_err());
    }

    #[test]
    fn transport_diagnostics_are_throttled_by_reason() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let logger = DiagnosticLogger::new(&paths);
        for _ in 0..20 {
            logger.transport_rejected(DiagnosticTransport::Unix, DiagnosticRejection::BadRequest);
        }
        logger.transport_rejected(DiagnosticTransport::Unix, DiagnosticRejection::InvalidUtf8);
        logger.sync();
        let records = fs::read_to_string(paths.logs_dir.join("petcore.jsonl")).unwrap();
        let rejection_count = records
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|record| record["category"] == "transport" && record["event"] == "rejected")
            .count();
        assert_eq!(rejection_count, 2);
    }

    #[test]
    fn export_includes_only_allowlisted_regular_logs_and_redacts_plaintext() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let logger = DiagnosticLogger::new(&paths);
        fs::write(
            paths.logs_dir.join("app.jsonl"),
            concat!(
                "{\"schema_version\":\"apc.diagnostic-log.v1\",",
                "\"timestamp\":\"2026-07-20T08:00:00Z\",",
                "\"process\":\"app\",\"level\":\"info\",",
                "\"category\":\"service\",\"event\":\"sentinel\",",
                "\"metadata\":{\"outcome\":\"safe\",",
                "\"session_id\":\"session-private-sentinel\",",
                "\"cwd\":\"/private/app-cwd-sentinel\"}}\n",
                "not-json\n"
            ),
        )
        .unwrap();
        fs::write(
            paths.logs_dir.join("petcore-launch.log"),
            "safe line\nAuthorization: Bearer top-secret\ncwd=/private/legacy-cwd-sentinel\ncwd=/Volumes/Acme Secret/project\npath /Users/alice/Client Repo/file\nuser=alice ip=192.168.1.42 peer=alice-mac.local\npeer_address=[fe80::1]:53782\n",
        )
        .unwrap();
        fs::write(paths.logs_dir.join("not-allowed.log"), "must not ship").unwrap();
        let secret = temp.path().join("secret.log");
        fs::write(&secret, "symlink secret").unwrap();
        symlink(&secret, paths.logs_dir.join("petcore.launchd.err.log")).unwrap();

        let exported = export_diagnostics(&paths, &logger, &valid_app_environment()).unwrap();
        assert_eq!(
            fs::metadata(&exported.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let file = File::open(&exported.path).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let names = (0..archive.len())
            .map(|index| archive.by_index(index).unwrap().name().to_string())
            .collect::<Vec<_>>();
        assert!(names.contains(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/manifest.json")));
        assert!(names.contains(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/environment.json")));
        assert!(names.contains(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/README.txt")));
        assert!(names.contains(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/logs/app.jsonl")));
        assert!(!names.iter().any(|name| name.contains("not-allowed")));
        assert!(!names.contains(&format!(
            "{DIAGNOSTIC_ARCHIVE_ROOT}/logs/petcore.launchd.err.log"
        )));

        let mut app_log = String::new();
        archive
            .by_name(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/logs/app.jsonl"))
            .unwrap()
            .read_to_string(&mut app_log)
            .unwrap();
        assert!(app_log.contains("\"outcome\":\"safe\""));
        assert!(!app_log.contains("session-private-sentinel"));
        assert!(!app_log.contains("app-cwd-sentinel"));

        let mut legacy_log = String::new();
        archive
            .by_name(&format!(
                "{DIAGNOSTIC_ARCHIVE_ROOT}/logs/petcore-launch.log"
            ))
            .unwrap()
            .read_to_string(&mut legacy_log)
            .unwrap();
        assert!(legacy_log.contains("safe line"));
        assert!(!legacy_log.contains("legacy-cwd-sentinel"));
        assert!(!legacy_log.contains("Acme Secret"));
        assert!(!legacy_log.contains("Client Repo"));
        assert!(!legacy_log.contains("alice"));
        assert!(!legacy_log.contains("192.168.1.42"));
        assert!(!legacy_log.contains("fe80::1"));
        assert!(!legacy_log.contains("alice-mac.local"));
        assert!(!app_log.contains("top-secret"));
        assert!(!legacy_log.contains("top-secret"));
        assert!(!legacy_log.contains("/Users/example"));

        let mut manifest = String::new();
        archive
            .by_name(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/manifest.json"))
            .unwrap()
            .read_to_string(&mut manifest)
            .unwrap();
        let manifest: Value = serde_json::from_str(&manifest).unwrap();
        assert_eq!(manifest["schema_version"], DIAGNOSTIC_EXPORT_SCHEMA_VERSION);
        assert_eq!(manifest["mode"], "petcore_rpc");
        assert!(manifest["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|file| file["name"] == "environment.json"));
        let app_manifest = manifest["files"]
            .as_array()
            .unwrap()
            .iter()
            .find(|file| file["name"] == "logs/app.jsonl")
            .unwrap();
        assert_eq!(app_manifest["truncated"], true);
        assert!(manifest["omitted_files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|file| {
                file["name"] == "petcore.launchd.err.log" && file["reason"] == "unsafe_file"
            }));
    }

    #[test]
    fn diagnostics_export_is_registered_as_a_bounded_rpc() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let state = crate::rpc::CoreState::new(paths);
        state.ensure_ready().unwrap();
        let result = crate::rpc::handle_request(
            &state,
            crate::rpc::RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("diagnostics-test")),
                method: "diagnostics.export".to_string(),
                params: json!({ "app_environment": valid_app_environment() }),
            },
        )
        .unwrap();
        assert!(result["path"]
            .as_str()
            .is_some_and(|path| path.ends_with(".zip")));
        assert!(result["archive_bytes"]
            .as_u64()
            .is_some_and(|bytes| bytes > 0));
    }

    #[test]
    fn post_redaction_truncation_preserves_complete_lines() {
        let mut content = "first\nsecond\nthird\n".as_bytes().to_vec();
        truncate_to_complete_lines(&mut content, 14);
        assert_eq!(content, b"first\nsecond\n");
    }

    #[test]
    fn structured_redaction_drops_sensitive_keys_recursively() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let input = br#"{"schema_version":"apc.diagnostic-log.v1","timestamp":"2026-07-20T08:00:00Z","process":"petcore","level":"info","category":"runtime","event":"sentinel","metadata":{"build_id":"release-42","session_id":"session-private-sentinel","user":"alice","ip":"192.168.1.42","peer_address":"192.168.1.42:53782","computer":"alice-mac.local","nested":{"cwd":"/private/cwd-sentinel","outcome":"safe","status":"[fe80::1]:53782","endpoint":"alice-mac.local:443"}}}
"#;
        let redaction = redact_structured_log_content(input, &paths);
        assert!(!redaction.dropped_records);
        let output = String::from_utf8(redaction.content).unwrap();
        assert!(output.contains("release-42"));
        assert!(output.contains("safe"));
        assert!(!output.contains("session-private-sentinel"));
        assert!(!output.contains("cwd-sentinel"));
        assert!(!output.contains("alice"));
        assert!(!output.contains("192.168.1.42"));
        assert!(!output.contains("fe80::1"));
        assert!(!output.contains("alice-mac.local"));
        let record: Value = serde_json::from_str(output.trim()).unwrap();
        assert!(record["metadata"].get("session_id").is_none());
        assert!(record["metadata"]["nested"].get("cwd").is_none());
        assert_eq!(
            record["metadata"]["nested"]["status"],
            "[REDACTED_IDENTITY]"
        );
        assert_eq!(
            record["metadata"]["nested"]["endpoint"],
            "[REDACTED_IDENTITY]"
        );
    }

    #[test]
    fn structured_identity_values_cannot_hide_in_category_or_event() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let input = concat!(
            "{\"schema_version\":\"apc.diagnostic-log.v1\",",
            "\"timestamp\":\"2026-07-20T08:00:00Z\",",
            "\"process\":\"app\",\"level\":\"info\",",
            "\"category\":\"192.168.1.42\",\"event\":\"safe\",\"metadata\":{}}\n",
            "{\"schema_version\":\"apc.diagnostic-log.v1\",",
            "\"timestamp\":\"2026-07-20T08:00:01Z\",",
            "\"process\":\"app\",\"level\":\"info\",",
            "\"category\":\"safe\",\"event\":\"alice-mac.local\",\"metadata\":{}}\n"
        );
        let redaction = redact_structured_log_content(input.as_bytes(), &paths);
        assert!(redaction.dropped_records);
        assert_eq!(redaction.parsed_json_objects, 2);
        assert!(redaction.content.is_empty());
    }

    #[test]
    fn nonempty_structured_sources_without_records_are_omitted() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let _logger = DiagnosticLogger::new(&paths);
        fs::write(paths.logs_dir.join("app.jsonl"), "not-json\n").unwrap();
        let mut omissions = Vec::new();
        let files = collect_allowlisted_logs(&paths, &mut omissions).unwrap();
        assert!(!files
            .iter()
            .any(|file| file.archive_name == "logs/app.jsonl"));
        assert!(omissions.iter().any(|omission| {
            omission.name == "app.jsonl" && omission.reason == ExportOmissionReason::InvalidJson
        }));

        fs::write(
            paths.logs_dir.join("app.jsonl"),
            "{\"schema_version\":\"unsupported\"}\n",
        )
        .unwrap();
        omissions.clear();
        let files = collect_allowlisted_logs(&paths, &mut omissions).unwrap();
        assert!(!files
            .iter()
            .any(|file| file.archive_name == "logs/app.jsonl"));
        assert!(omissions.iter().any(|omission| {
            omission.name == "app.jsonl"
                && omission.reason == ExportOmissionReason::NoCompleteRecords
        }));
    }

    #[test]
    fn export_manifest_marks_source_tail_truncation() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let logger = DiagnosticLogger::new(&paths);
        let mut legacy = Vec::new();
        while legacy.len() <= MAX_LEGACY_LOG_SOURCE_BYTES as usize + 64 {
            legacy.extend_from_slice(b"bounded legacy line\n");
        }
        fs::write(paths.logs_dir.join("petcore-launch.log"), legacy).unwrap();
        let exported = export_diagnostics(&paths, &logger, &valid_app_environment()).unwrap();
        let file = File::open(exported.path).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let mut manifest = String::new();
        archive
            .by_name(&format!("{DIAGNOSTIC_ARCHIVE_ROOT}/manifest.json"))
            .unwrap()
            .read_to_string(&mut manifest)
            .unwrap();
        let manifest: Value = serde_json::from_str(&manifest).unwrap();
        let launch = manifest["files"]
            .as_array()
            .unwrap()
            .iter()
            .find(|file| file["name"] == "logs/petcore-launch.log")
            .unwrap();
        assert_eq!(launch["truncated"], true);
        let mut content = Vec::new();
        archive
            .by_name(&format!(
                "{DIAGNOSTIC_ARCHIVE_ROOT}/logs/petcore-launch.log"
            ))
            .unwrap()
            .read_to_end(&mut content)
            .unwrap();
        assert!(content.ends_with(b"\n"));
        assert!(content.len() <= MAX_LEGACY_LOG_SOURCE_BYTES as usize);
    }

    #[test]
    fn export_cleanup_enforces_count_and_total_byte_caps() {
        let temp = tempfile::tempdir().unwrap();
        let exports = temp.path().join("diagnostic-exports");
        ensure_private_directory(&exports).unwrap();
        for index in 0..4 {
            let path = exports.join(format!(
                "AgentPetCompanion-Diagnostics-20260720T08000{index}Z.zip"
            ));
            let file = File::create(path).unwrap();
            file.set_len(50 * 1024 * 1024).unwrap();
        }
        let temporary = exports.join(".diagnostic-export-orphan");
        File::create(&temporary)
            .unwrap()
            .set_len(50 * 1024 * 1024)
            .unwrap();
        let staging = exports.join(".staging-123e4567-e89b-12d3-a456-426614174000");
        ensure_private_directory(&staging).unwrap();
        let malformed_staging = exports.join(".staging-not-a-uuid");
        ensure_private_directory(&malformed_staging).unwrap();

        cleanup_expired_exports(&exports, None);
        let retained = fs::read_dir(&exports)
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.ends_with(".zip"))
            })
            .filter_map(|entry| entry.metadata().ok())
            .collect::<Vec<_>>();
        assert!(retained.len() <= MAX_RETAINED_EXPORTS);
        assert!(retained.iter().map(fs::Metadata::len).sum::<u64>() <= MAX_RETAINED_EXPORT_BYTES);
        assert!(
            temporary.exists(),
            "recent staging files must not be deleted"
        );
        assert!(
            staging.exists(),
            "recent staging directories must not be deleted"
        );
        assert!(
            malformed_staging.exists(),
            "non-contract staging names must never be deleted"
        );
    }
}
