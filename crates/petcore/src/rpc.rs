use crate::adapter_contracts::normalize_claude_display_message;
use crate::agent_environment::connector_identity_environment;
use crate::agent_session_filters::AGENT_CHILD_SESSION_SOURCE_EVENT;
use crate::agent_state;
use crate::connections;
use crate::db::{
    BehaviorSettingsPatch, CodexRuntimeSurfaceHistory, Database, InsertEventOutcome,
    OverlayPlacementProjection, OverlayPlacementWriteResult, ProductConvergenceConnectorSummary,
    ProductConvergenceReceipt, RevisionChecked, SessionMessageProjection,
    PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION,
};
use crate::diagnostics::{
    self, AgentParseFailure, AgentParseField, AgentParseWarning, DiagnosticIngestOutcome,
    DiagnosticLogger, DiagnosticRejection,
};
use crate::event_envelope::{
    event_affects_activity, validated_warp_focus_url, NormalizedAgentEvent, MAX_RECENT_EVENTS,
    MAX_SESSION_TITLE_BYTES,
};
use crate::generation;
use crate::metrics;
use crate::paths::AppPaths;
use crate::pet_revision;
use crate::petpack;
use crate::runtime_manifest::RuntimeReleaseManifest;
use crate::{app_server, enum_from_name, enum_name, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentEvent, AgentEventType, AgentSource, BehaviorSettings,
    GenerationForm, GenerationJobStatus, OnboardingProgress, OverlayPlacement,
    OverlayPlacementIntent, QualityLevel,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
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
const MAX_PRODUCT_CONVERGENCE_REPORT_BYTES: usize = 64 * 1024;
const MAX_PRODUCT_CONVERGENCE_DETAIL_BYTES: usize = 1024;
const MAX_PRODUCT_CONVERGENCE_ERROR_BYTES: usize = 512;
const MAX_PRODUCT_CONVERGENCE_IDENTITY_BYTES: usize = 128;
pub use crate::runtime_manifest::{PETCORE_BUILD_ID, PETCORE_RPC_PROTOCOL_VERSION};
const CODEX_THREAD_DISPLAY_REFRESH_SECONDS: u64 = 30;
const CODEX_ACTIVE_THREAD_DISPLAY_REFRESH_SECONDS: u64 = 1;
const MAX_CODEX_THREAD_DISPLAY_CACHE_ENTRIES: usize = 64;
const CODEX_ACTIVITY_REFRESH_SECONDS: u64 = 1;
const CONNECTION_LIGHT_STATUS_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW: Duration = Duration::from_secs(5);
const MAX_CACHED_CONNECTION_STATUSES: usize = 4;
const MAX_CACHED_SESSION_DISPLAY_ENTRIES: usize = 16;
const MAX_SNAPSHOT_REVISION_RETRIES: usize = 8;
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
    pub diagnostics: DiagnosticLogger,
    instance_id: String,
    codex_thread_display_cache: Arc<Mutex<CodexThreadDisplayCache>>,
    codex_display_epoch: Arc<AtomicU64>,
    codex_activity_sync_enabled: bool,
    codex_activity_sync: Arc<Mutex<CodexActivitySyncState>>,
    codex_recent_activity_cache: Arc<Mutex<app_server::CodexRecentThreadActivityCache>>,
    connection_light_status_cache: Arc<ConnectionLightStatusCache>,
    connection_evidence_projection_cache: Arc<ConnectionEvidenceProjectionCache>,
    snapshot_sequenced_event_cache: Arc<SnapshotSequencedEventCache>,
    snapshot_persisted_display_cache: Arc<SnapshotPersistedDisplayCache>,
    agent_host_process_gate: Arc<Mutex<()>>,
    connection_operation_active: Arc<AtomicBool>,
    shutdown_requested: Arc<AtomicBool>,
}

struct ConnectionOperationPermit {
    active: Arc<AtomicBool>,
}

impl Drop for ConnectionOperationPermit {
    fn drop(&mut self) {
        self.active.store(false, Ordering::Release);
    }
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

#[derive(Debug, Clone)]
struct CachedConnectionLightStatuses {
    refreshed_at: Instant,
    artifact_revision: u64,
    statuses: Vec<AgentConnectionStatus>,
}

/// Process-local cache for the bounded, UI-safe connection status projection.
/// The mutex intentionally remains held during a cold refresh so concurrent
/// snapshots share one filesystem scan instead of starting duplicates.
#[derive(Debug, Default)]
struct ConnectionLightStatusCache {
    entry: Mutex<Option<CachedConnectionLightStatuses>>,
}

#[derive(Debug, Clone)]
struct CachedConnectionEvidenceProjection {
    refreshed_at: Instant,
    artifact_revision: u64,
    base_status_json: String,
    status: AgentConnectionStatus,
    dirty: bool,
}

/// Evidence is deliberately isolated from the five-minute filesystem cache.
/// Entries are bounded by the four supported sources and are dirtied for only
/// the source whose event stream changed. Event-driven dirtiness is coalesced
/// for a short window so a busy hook stream cannot make every `state.wait`
/// snapshot reparse the complete retained history. Explicit checks and exact
/// base/artifact changes still invalidate immediately.
#[derive(Debug, Default)]
struct ConnectionEvidenceProjectionCache {
    entries: Mutex<BTreeMap<AgentSource, CachedConnectionEvidenceProjection>>,
}

#[derive(Debug, Clone)]
struct SnapshotSequencedEvents {
    state_revision: u64,
    events: Arc<Vec<agent_state::SequencedAgentEvent>>,
}

/// Process-local cache for the normalized event projection used by snapshots.
/// Holding the mutex through a cold refresh prevents concurrent `state.wait`
/// timeouts from repeating the same JSON parsing and session ordering query.
#[derive(Debug, Default)]
struct SnapshotSequencedEventCache {
    entry: Mutex<Option<SnapshotSequencedEvents>>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct SessionDisplayCacheKey {
    source: AgentSource,
    session_id: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct PersistedSessionDisplay {
    latest_message: Option<agent_state::SequencedAgentEvent>,
    latest_user_message: Option<agent_state::SequencedAgentEvent>,
    first_user_message: Option<AgentEvent>,
    latest_title: Option<AgentEvent>,
}

#[derive(Debug)]
struct SnapshotPersistedDisplay {
    state_revision: u64,
    sessions: BTreeMap<SessionDisplayCacheKey, PersistedSessionDisplay>,
    recent_events: Option<Arc<Vec<AgentEvent>>>,
}

/// Process-local, single-revision cache for display-only projections loaded
/// from persisted, typed agent events. The mutex remains held during each cold
/// load so concurrent snapshot timeouts cannot duplicate the same DB queries.
/// Codex App Server overlays are deliberately applied after this cache on every
/// hydration and never enter it.
#[derive(Debug, Default)]
struct SnapshotPersistedDisplayCache {
    entry: Mutex<Option<SnapshotPersistedDisplay>>,
}

impl SnapshotSequencedEventCache {
    fn get_or_try_refresh<R, F>(
        &self,
        current_revision: R,
        refresh: F,
    ) -> Result<SnapshotSequencedEvents>
    where
        R: FnOnce() -> Result<u64>,
        F: FnOnce() -> Result<SnapshotSequencedEvents>,
    {
        let mut entry = self
            .entry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let revision = current_revision()?;
        if let Some(cached) = entry
            .as_ref()
            .filter(|cached| cached.state_revision == revision)
        {
            return Ok(cached.clone());
        }

        let refreshed = refresh()?;
        *entry = Some(refreshed.clone());
        Ok(refreshed)
    }
}

impl SnapshotPersistedDisplayCache {
    fn session_display<F>(
        &self,
        state_revision: u64,
        key: SessionDisplayCacheKey,
        refresh: F,
    ) -> Result<Option<PersistedSessionDisplay>>
    where
        F: FnOnce() -> Result<RevisionChecked<SessionMessageProjection>>,
    {
        let mut entry = self
            .entry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let cache = persisted_display_revision_entry(&mut entry, state_revision);
        if let Some(cached) = cache.sessions.get(&key) {
            return Ok(Some(cached.clone()));
        }

        let refreshed = match refresh()? {
            RevisionChecked::Matched {
                state_revision: matched_revision,
                value,
            } if matched_revision == state_revision => PersistedSessionDisplay {
                latest_message: value.latest_assistant,
                latest_user_message: value.latest_user,
                first_user_message: value.first_user,
                latest_title: value.latest_title,
            },
            RevisionChecked::Matched { .. } | RevisionChecked::Mismatch { .. } => {
                return Ok(None);
            }
        };
        if cache.sessions.len() >= MAX_CACHED_SESSION_DISPLAY_ENTRIES {
            if let Some(oldest_key) = cache.sessions.keys().next().cloned() {
                cache.sessions.remove(&oldest_key);
            }
        }
        cache.sessions.insert(key, refreshed.clone());
        Ok(Some(refreshed))
    }

    fn recent_events<F>(
        &self,
        state_revision: u64,
        refresh: F,
    ) -> Result<Option<Arc<Vec<AgentEvent>>>>
    where
        F: FnOnce() -> Result<RevisionChecked<Vec<AgentEvent>>>,
    {
        let mut entry = self
            .entry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let cache = persisted_display_revision_entry(&mut entry, state_revision);
        if let Some(cached) = &cache.recent_events {
            return Ok(Some(Arc::clone(cached)));
        }

        let refreshed = match refresh()? {
            RevisionChecked::Matched {
                state_revision: matched_revision,
                value,
            } if matched_revision == state_revision => Arc::new(value),
            RevisionChecked::Matched { .. } | RevisionChecked::Mismatch { .. } => {
                return Ok(None);
            }
        };
        cache.recent_events = Some(Arc::clone(&refreshed));
        Ok(Some(refreshed))
    }
}

fn persisted_display_revision_entry(
    entry: &mut Option<SnapshotPersistedDisplay>,
    state_revision: u64,
) -> &mut SnapshotPersistedDisplay {
    if entry
        .as_ref()
        .is_none_or(|cached| cached.state_revision != state_revision)
    {
        *entry = Some(SnapshotPersistedDisplay {
            state_revision,
            sessions: BTreeMap::new(),
            recent_events: None,
        });
    }
    entry
        .as_mut()
        .expect("snapshot display cache was initialized")
}

impl ConnectionLightStatusCache {
    fn get_or_try_refresh<F>(
        &self,
        now: Instant,
        ttl: Duration,
        artifact_revision: u64,
        refresh: F,
    ) -> Result<Vec<AgentConnectionStatus>>
    where
        F: FnOnce() -> Result<Vec<AgentConnectionStatus>>,
    {
        let mut entry = self
            .entry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(cached) = entry.as_ref().filter(|cached| {
            cached.artifact_revision == artifact_revision
                && now.saturating_duration_since(cached.refreshed_at) < ttl
        }) {
            return Ok(cached.statuses.clone());
        }

        let mut statuses = refresh()?;
        statuses.truncate(MAX_CACHED_CONNECTION_STATUSES);
        *entry = Some(CachedConnectionLightStatuses {
            refreshed_at: now,
            artifact_revision,
            statuses: statuses.clone(),
        });
        Ok(statuses)
    }

    fn invalidate(&self) {
        *self
            .entry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }
}

impl ConnectionEvidenceProjectionCache {
    fn get_or_try_refresh<F>(
        &self,
        now: Instant,
        dirty_coalesce_window: Duration,
        artifact_revision: u64,
        base: &AgentConnectionStatus,
        refresh: F,
    ) -> Result<AgentConnectionStatus>
    where
        F: FnOnce() -> Result<AgentConnectionStatus>,
    {
        let base_status_json = serde_json::to_string(base)?;
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(cached) = entries.get(&base.source).filter(|cached| {
            cached.artifact_revision == artifact_revision
                && cached.base_status_json == base_status_json
                && (!cached.dirty
                    || now.saturating_duration_since(cached.refreshed_at) < dirty_coalesce_window)
        }) {
            return Ok(cached.status.clone());
        }

        let status = refresh()?;
        entries.insert(
            base.source,
            CachedConnectionEvidenceProjection {
                refreshed_at: now,
                artifact_revision,
                base_status_json,
                status: status.clone(),
                dirty: false,
            },
        );
        Ok(status)
    }

    fn mark_dirty(&self, source: AgentSource) {
        if let Some(cached) = self
            .entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get_mut(&source)
        {
            cached.dirty = true;
        }
    }

    fn invalidate(&self, source: AgentSource) {
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&source);
    }

    fn invalidate_all(&self) {
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clear();
    }
}

impl CoreState {
    pub fn new(paths: AppPaths) -> Self {
        let diagnostics = DiagnosticLogger::new(&paths);
        Self::new_with_diagnostics(paths, diagnostics)
    }

    pub fn new_with_diagnostics(paths: AppPaths, diagnostics: DiagnosticLogger) -> Self {
        let database = Database::new(paths.db_path.clone());
        Self {
            paths,
            database,
            diagnostics,
            instance_id: new_id("embedded_instance"),
            codex_thread_display_cache: Arc::new(Mutex::new(CodexThreadDisplayCache::default())),
            codex_display_epoch: Arc::new(AtomicU64::new(0)),
            codex_activity_sync_enabled: false,
            codex_activity_sync: Arc::new(Mutex::new(CodexActivitySyncState::default())),
            codex_recent_activity_cache: Arc::new(Mutex::new(
                app_server::CodexRecentThreadActivityCache::default(),
            )),
            connection_light_status_cache: Arc::new(ConnectionLightStatusCache::default()),
            connection_evidence_projection_cache: Arc::new(
                ConnectionEvidenceProjectionCache::default(),
            ),
            snapshot_sequenced_event_cache: Arc::new(SnapshotSequencedEventCache::default()),
            snapshot_persisted_display_cache: Arc::new(SnapshotPersistedDisplayCache::default()),
            agent_host_process_gate: Arc::new(Mutex::new(())),
            connection_operation_active: Arc::new(AtomicBool::new(false)),
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

    fn write_overlay_placement(
        &self,
        placement: &OverlayPlacement,
        intent: Option<OverlayPlacementIntent>,
        expected_revision: Option<u64>,
    ) -> Result<OverlayPlacementWriteResult> {
        self.database
            .set_overlay_placement(placement, intent, expected_revision)
    }

    fn snapshot_overlay_placement(
        &self,
        snapshot_state_revision: u64,
    ) -> Result<Option<OverlayPlacementProjection>> {
        match self
            .database
            .overlay_placement_at_revision(snapshot_state_revision)?
        {
            RevisionChecked::Matched { value, .. } => Ok(Some(value)),
            RevisionChecked::Mismatch { .. } => Ok(None),
        }
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

    fn begin_connection_operation(&self) -> Result<ConnectionOperationPermit> {
        self.connection_operation_active
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| {
                PetCoreError::Conflict(
                    "another Agent connection operation is already running; wait for it to finish"
                        .to_string(),
                )
            })?;
        Ok(ConnectionOperationPermit {
            active: Arc::clone(&self.connection_operation_active),
        })
    }

    fn agent_host_process_guard(&self) -> MutexGuard<'_, ()> {
        self.agent_host_process_gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn ensure_generation_admission_open(&self) -> Result<()> {
        if self.connection_operation_active.load(Ordering::Acquire) {
            return Err(PetCoreError::Conflict(
                "Agent capabilities are being updated; wait before starting new generation work"
                    .to_string(),
            ));
        }
        Ok(())
    }

    fn snapshot_connection_statuses(&self) -> Result<Vec<AgentConnectionStatus>> {
        let artifact_revision = connections::connection_light_cache_revision(&self.paths);
        let light_statuses = self.connection_light_status_cache.get_or_try_refresh(
            Instant::now(),
            CONNECTION_LIGHT_STATUS_CACHE_TTL,
            artifact_revision,
            || Ok(connections::check_all_light(&self.paths)),
        )?;
        // Runtime checks and their absolute `checked_at` expiry are evaluated
        // on every snapshot. They are never kept alive by the five-minute
        // filesystem cache above.
        let statuses = merge_cached_connection_statuses(
            &self.paths,
            light_statuses,
            self.database.connection_statuses()?,
        );
        statuses
            .into_iter()
            .map(|status| {
                self.connection_evidence_projection_cache
                    .get_or_try_refresh(
                        Instant::now(),
                        CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                        artifact_revision,
                        &status,
                        || {
                            Ok(connections::project_connection_evidence(
                                &self.paths,
                                &status,
                            ))
                        },
                    )
            })
            .collect()
    }

    fn invalidate_connection_light_status_cache(&self) {
        self.connection_light_status_cache.invalidate();
    }

    fn invalidate_connection_evidence_projection(&self, source: AgentSource) {
        self.connection_evidence_projection_cache.invalidate(source);
    }

    fn mark_connection_evidence_projection_dirty(&self, source: AgentSource) {
        self.connection_evidence_projection_cache.mark_dirty(source);
    }

    fn invalidate_all_connection_evidence_projections(&self) {
        self.connection_evidence_projection_cache.invalidate_all();
    }

    fn snapshot_sequenced_events(&self) -> Result<SnapshotSequencedEvents> {
        snapshot_sequenced_events_cached(
            &self.database,
            self.snapshot_sequenced_event_cache.as_ref(),
        )
    }

    fn persisted_session_display(
        &self,
        state_revision: u64,
        source: AgentSource,
        session_id: Option<&str>,
    ) -> Result<Option<PersistedSessionDisplay>> {
        let key = SessionDisplayCacheKey {
            source,
            session_id: session_id.map(ToOwned::to_owned),
        };
        self.snapshot_persisted_display_cache
            .session_display(state_revision, key, || {
                self.database.session_message_projection_at_revision(
                    state_revision,
                    source,
                    session_id,
                )
            })
    }

    fn snapshot_recent_events(&self, state_revision: u64) -> Result<Option<Arc<Vec<AgentEvent>>>> {
        self.snapshot_persisted_display_cache
            .recent_events(state_revision, || {
                match self
                    .database
                    .recent_events_at_revision(state_revision, SNAPSHOT_RECENT_EVENT_LIMIT)?
                {
                    RevisionChecked::Matched {
                        state_revision,
                        value,
                    } => Ok(RevisionChecked::Matched {
                        state_revision,
                        value: recent_non_diagnostic_events(&value, SNAPSHOT_RECENT_EVENT_LIMIT),
                    }),
                    RevisionChecked::Mismatch {
                        expected_revision,
                        actual_revision,
                    } => Ok(RevisionChecked::Mismatch {
                        expected_revision,
                        actual_revision,
                    }),
                }
            })
    }

    pub fn ensure_ready(&self) -> Result<()> {
        self.diagnostics.core_ready_started();
        let result = (|| {
            if let Err(error) = self.paths.ensure() {
                self.diagnostics.startup_failed("paths", &error);
                return Err(error);
            }
            if let Err(error) = self.database.init() {
                self.diagnostics.startup_failed("database", &error);
                return Err(error);
            }
            if let Err(error) = generation::recover_interrupted_jobs_for_instance(
                &self.paths,
                &self.database,
                &self.instance_id,
            ) {
                self.diagnostics
                    .startup_failed("generation_recovery", &error);
                return Err(error);
            }
            Ok(())
        })();
        match &result {
            Ok(()) => self.diagnostics.core_ready_completed(),
            Err(error) => self.diagnostics.core_ready_failed(error),
        }
        result
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
            let display_epoch = Arc::clone(&self.codex_display_epoch);
            let session_id = session_id.to_string();
            let event_marker = event_marker.to_string();
            thread::spawn(move || {
                // This is a bounded read-only display hydration. It must not
                // queue behind a background recent-thread scan or an unrelated
                // connection check that owns the mutation/admission gate.
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
                let next_display = fetched.or_else(|| previous.clone());
                let display_changed = next_display != previous;
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
                        display: next_display,
                    },
                );
                drop(cache);
                if display_changed {
                    display_epoch.fetch_add(1, Ordering::Release);
                }
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
        let recent_activity_cache = Arc::clone(&self.codex_recent_activity_cache);
        let snapshot_sequenced_event_cache = Arc::clone(&self.snapshot_sequenced_event_cache);
        let agent_host_process_gate = Arc::clone(&self.agent_host_process_gate);
        let maximum_age = Duration::from_secs(
            u64::from(behavior.session_message_timeout_minutes).saturating_mul(60),
        );
        thread::spawn(move || {
            let activity_round = {
                let _host_guard = agent_host_process_gate
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let mut cache = recent_activity_cache
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let result = app_server::read_codex_recent_thread_activities_cached(
                    maximum_age,
                    app_server::MAX_RECENT_CODEX_ACTIVITY_THREADS,
                    &mut cache,
                );
                result.map(|activities| {
                    (
                        activities,
                        cache.listed_thread_ids(),
                        cache.listed_thread_surfaces(),
                        cache.child_thread_ids(),
                        cache.listing_complete(),
                    )
                })
            };
            let Ok((
                mut activities,
                listed_threads,
                listed_thread_surfaces,
                child_threads,
                listing_complete,
            )) = activity_round
            else {
                if let Ok(mut sync) = shared_sync.lock() {
                    sync.in_flight = false;
                }
                return;
            };
            let Ok(mut sync) = shared_sync.lock() else {
                return;
            };
            for activity in &mut activities {
                reconcile_codex_activity_observation(&mut sync.observations, activity);
            }
            let closed_at_unix = OffsetDateTime::now_utc().unix_timestamp();
            let disappeared_events = if listing_complete {
                disappeared_codex_activity_events(
                    &sync.observations,
                    &listed_threads,
                    closed_at_unix,
                )
            } else {
                // A bounded page with a continuation cursor cannot prove that
                // an omitted task was archived. Forget ambiguous observations
                // and let their finite leases expire naturally.
                Vec::new()
            };
            sync.observations
                .retain(|thread_id, _| listed_threads.contains(thread_id));
            sync.in_flight = false;
            drop(sync);

            // A marker deletes any hook-backed child projection already in
            // the database and permanently suppresses later events for the
            // same bounded session identity. Parent lineage itself is never
            // persisted.
            for thread_id in child_threads {
                let marker = child_session_suppression_event(AgentSource::Codex, &thread_id);
                let _ = database.insert_event(&marker);
            }

            // Raw unarchived-list membership is authoritative even when a task
            // has aged out of bounded detail hydration. This also repairs
            // synthetic closures written by an earlier runtime that conflated
            // the message-age window with task disappearance.
            if database
                .reconcile_listed_codex_activity_sessions(&listed_thread_surfaces)
                .is_err()
            {
                return;
            }

            let existing = snapshot_sequenced_events_cached(
                &database,
                snapshot_sequenced_event_cache.as_ref(),
            )
            .map(|snapshot| snapshot.events)
            .unwrap_or_default();
            let runtime_surface_queries = activities
                .iter()
                .map(|activity| (activity.thread_id.clone(), activity.turn_id.clone()))
                .collect::<Vec<_>>();
            let Ok(runtime_surface_history) =
                database.codex_runtime_surface_history(&runtime_surface_queries)
            else {
                return;
            };
            for event in disappeared_events {
                let _ = database.upsert_codex_activity_event(&event);
            }
            for activity in activities {
                let preserve_exact_state =
                    should_preserve_exact_codex_state(existing.as_slice(), &activity);
                let navigation_history = runtime_surface_history
                    .get(&activity.thread_id)
                    .cloned()
                    .unwrap_or_default();
                for event in codex_activity_events(activity, &navigation_history) {
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

fn child_session_suppression_event(source: AgentSource, session_id: &str) -> AgentEvent {
    AgentEvent {
        id: new_id("evt_child_session"),
        source,
        project_path: None,
        session_id: Some(session_id.to_string()),
        event_type: AgentEventType::Start,
        title: AgentEventType::Start.zh_label().to_string(),
        detail: None,
        payload_json: json!({
            "source_event": AGENT_CHILD_SESSION_SOURCE_EVENT,
            "session_active": false,
            "session_open": false,
            "diagnostic": false
        }),
        created_at: now_rfc3339(),
    }
}

fn snapshot_sequenced_events_cached(
    database: &Database,
    cache: &SnapshotSequencedEventCache,
) -> Result<SnapshotSequencedEvents> {
    cache.get_or_try_refresh(
        || database.state_revision(),
        || {
            let (state_revision, events) = database
                .latest_sequenced_events_by_session_with_revision(SNAPSHOT_EVENT_SCAN_LIMIT)?;
            Ok(SnapshotSequencedEvents {
                state_revision,
                events: Arc::new(events),
            })
        },
    )
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
        AgentEventType::Start
            | AgentEventType::Thinking
            | AgentEventType::Plan
            | AgentEventType::Tool
    );
    let raw_activity = activity.latest_activity.clone();
    let inferred_activity = if running && visible_clock_advanced {
        // A separately spawned App Server sees the thread timestamp advance,
        // but persisted turns intentionally omit some live interactions (most
        // notably command executions). Keep the newest concrete host-exposed
        // detail until a newer one arrives. Timestamp movement alone is not
        // evidence of thinking and must never turn `start` into `thinking`.
        latest_known_codex_activity(raw_activity.as_ref())
            .or_else(|| previous.and_then(|previous| previous.inferred_activity.clone()))
    } else if running && same_visible_revision {
        previous.and_then(|previous| previous.inferred_activity.clone())
    } else if running
        && previous.is_some()
        && raw_activity
            .as_ref()
            .is_some_and(|candidate| !candidate.is_current)
    {
        // A completed operation remains the latest useful activity detail
        // while the turn continues. Keep concrete host text, but use a neutral
        // category when the lossy persisted item has no displayable content.
        latest_known_codex_activity(raw_activity.as_ref())
            .or_else(|| previous.and_then(|previous| previous.inferred_activity.clone()))
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
        activity.event_type = activity
            .latest_activity
            .as_ref()
            .map(|candidate| codex_activity_event_type(&candidate.kind))
            .unwrap_or(AgentEventType::Start);
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

fn disappeared_codex_activity_events(
    observations: &BTreeMap<String, CodexActivityObservation>,
    observed_threads: &BTreeSet<String>,
    closed_at_unix: i64,
) -> Vec<AgentEvent> {
    let Some(created_at) = unix_timestamp_rfc3339(closed_at_unix) else {
        return Vec::new();
    };
    observations
        .iter()
        .filter(|(thread_id, _)| !observed_threads.contains(*thread_id))
        .map(|(thread_id, observation)| {
            let turn_marker = observation.turn_id.as_deref().unwrap_or("thread");
            AgentEvent {
                id: format!("evt_codex_app_server_status_{}_{}", thread_id, turn_marker),
                source: AgentSource::Codex,
                project_path: None,
                session_id: Some(thread_id.clone()),
                event_type: AgentEventType::Done,
                title: AgentEventType::Done.zh_label().to_string(),
                detail: None,
                payload_json: json!({
                    "source_event": "app_server_activity",
                    "outcome": "session_closed",
                    "turn_id": observation.turn_id.as_deref(),
                    "session_active": false,
                    "session_open": false,
                    "diagnostic": false
                }),
                created_at: created_at.clone(),
            }
        })
        .collect()
}

fn latest_known_codex_activity(
    candidate: Option<&app_server::CodexThreadDisplayActivity>,
) -> Option<app_server::CodexThreadDisplayActivity> {
    if let Some(candidate) = candidate.filter(|candidate| {
        candidate
            .content
            .as_deref()
            .is_some_and(|content| !content.trim().is_empty())
    }) {
        let mut activity = candidate.clone();
        activity.is_current = true;
        return Some(activity);
    }
    None
}

#[cfg(test)]
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

fn codex_activity_event_type(kind: &str) -> AgentEventType {
    match kind {
        "thinking" => AgentEventType::Thinking,
        "plan" => AgentEventType::Plan,
        _ if codex_activity_kind_is_tool(kind) => AgentEventType::Tool,
        _ => AgentEventType::Start,
    }
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
        AgentEventType::Start
            | AgentEventType::Thinking
            | AgentEventType::Plan
            | AgentEventType::Tool
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
                AgentEventType::Start
                    | AgentEventType::Thinking
                    | AgentEventType::Plan
                    | AgentEventType::Tool
                    | AgentEventType::Waiting
                    | AgentEventType::Done
                    | AgentEventType::Failed
            )
    }) else {
        return false;
    };
    let exact_turn = event_payload_text(&exact.event, "turn_id");
    if exact_turn.is_some()
        && activity.turn_id.is_some()
        && exact_turn.as_deref() != activity.turn_id.as_deref()
    {
        return false;
    }
    let current_public_activity_supersedes_running_hook =
        matches!(
            exact.event.event_type,
            AgentEventType::Start
                | AgentEventType::Thinking
                | AgentEventType::Plan
                | AgentEventType::Tool
        ) && activity.latest_activity.as_ref().is_some_and(|candidate| {
            candidate.is_current
                && candidate
                    .content
                    .as_deref()
                    .is_some_and(|content| !content.trim().is_empty())
        });
    if current_public_activity_supersedes_running_hook {
        // `thread/read` is a later observation of the same live turn. Once it
        // exposes concrete content, that current reasoning/tool item is more
        // recent than the hook-backed running edge. Content-free inferred
        // activity still preserves the exact hook, and waiting/terminal hooks
        // remain authoritative.
        return false;
    }
    let Ok(exact_at) = OffsetDateTime::parse(&exact.event.created_at, &Rfc3339) else {
        return true;
    };
    activity
        .turn_started_at_unix
        .and_then(|timestamp| OffsetDateTime::from_unix_timestamp(timestamp).ok())
        .is_none_or(|turn_started_at| exact_at >= turn_started_at)
}

fn codex_activity_events(
    activity: app_server::CodexThreadActivity,
    navigation_history: &CodexRuntimeSurfaceHistory,
) -> Vec<AgentEvent> {
    let Some(updated_at) = unix_timestamp_rfc3339(activity.updated_at_unix) else {
        return Vec::new();
    };
    let turn_marker = activity
        .turn_id
        .clone()
        .unwrap_or_else(|| "thread".to_string());
    let navigation = codex_activity_navigation(navigation_history, &activity);
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
                "session_surface": navigation.surface.as_str(),
                "terminal_app": navigation.terminal_app.as_deref(),
                "session_open_url": navigation.session_open_url.as_deref(),
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
        "session_surface": navigation.surface.as_str(),
        "terminal_app": navigation.terminal_app.as_deref(),
        "session_open_url": navigation.session_open_url.as_deref(),
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

struct CodexActivityNavigation {
    surface: String,
    terminal_app: Option<String>,
    session_open_url: Option<String>,
}

fn codex_activity_navigation(
    history: &CodexRuntimeSurfaceHistory,
    activity: &app_server::CodexThreadActivity,
) -> CodexActivityNavigation {
    let unknown = || CodexActivityNavigation {
        surface: "unknown".to_string(),
        terminal_app: None,
        session_open_url: None,
    };
    let Some(candidate) = history.latest_current_turn_marker.as_ref() else {
        if history.has_any_trusted_marker {
            return unknown();
        }
        return match activity.session_surface.as_str() {
            "chatgpt_app" => CodexActivityNavigation {
                surface: "chatgpt_app".to_string(),
                terminal_app: None,
                session_open_url: None,
            },
            "cli_terminal" => CodexActivityNavigation {
                surface: "cli_terminal".to_string(),
                terminal_app: None,
                session_open_url: None,
            },
            _ => unknown(),
        };
    };
    let Some(surface) = event_payload_text(&candidate.event, "session_surface") else {
        return unknown();
    };
    if surface == "chatgpt_app" {
        if event_payload_text(&candidate.event, "terminal_app").is_some()
            || event_payload_text(&candidate.event, "session_open_url").is_some()
        {
            return unknown();
        }
        return CodexActivityNavigation {
            surface,
            terminal_app: None,
            session_open_url: None,
        };
    }
    if surface != "cli_terminal" {
        return unknown();
    }
    let terminal_app = event_payload_text(&candidate.event, "terminal_app")
        .filter(|value| matches!(value.as_str(), "warp" | "terminal" | "iterm2" | "ghostty"));
    let session_open_url = (terminal_app.as_deref() == Some("warp"))
        .then(|| {
            event_payload_text(&candidate.event, "session_open_url")
                .and_then(|value| validated_warp_focus_url(&value))
        })
        .flatten();
    CodexActivityNavigation {
        surface,
        terminal_app,
        session_open_url,
    }
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

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProductConvergenceUpdateParams {
    schema_version: String,
    build_id: String,
    app_version: String,
    connector_report: connections::InstalledSourcesRefreshReport,
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
            state
                .diagnostics
                .rpc_rejected(None, DiagnosticRejection::InvalidJson);
            return Some(encode_rpc_value(rpc_error_value(
                Value::Null,
                -32700,
                &error.to_string(),
            )));
        }
    };

    match value {
        Value::Array(values) if values.is_empty() => {
            state
                .diagnostics
                .rpc_rejected(None, DiagnosticRejection::BadRequest);
            Some(encode_rpc_value(rpc_error_value(
                Value::Null,
                -32600,
                "batch must not be empty",
            )))
        }
        Value::Array(values) if values.len() > MAX_RPC_BATCH_ITEMS => {
            state
                .diagnostics
                .rpc_rejected(None, DiagnosticRejection::BadRequest);
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
        state
            .diagnostics
            .rpc_rejected(None, DiagnosticRejection::BadRequest);
        return Some(rpc_error_value(
            Value::Null,
            -32600,
            "request must be an object",
        ));
    };
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        state
            .diagnostics
            .rpc_rejected(None, DiagnosticRejection::BadRequest);
        return Some(rpc_error_value(
            Value::Null,
            -32600,
            "jsonrpc must be exactly 2.0",
        ));
    }
    let Some(method) = object.get("method").and_then(Value::as_str) else {
        state
            .diagnostics
            .rpc_rejected(None, DiagnosticRejection::BadRequest);
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
            state
                .diagnostics
                .rpc_rejected(Some(method), DiagnosticRejection::BadRequest);
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
        state
            .diagnostics
            .rpc_rejected(Some(method), DiagnosticRejection::BadRequest);
        rpc_error_value(
            response_id.clone().unwrap_or(Value::Null),
            -32602,
            "params must be an object or array",
        )
    } else if !known_rpc_method(method) {
        state
            .diagnostics
            .rpc_rejected(Some(method), DiagnosticRejection::BadRequest);
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
            | "onboarding.get"
            | "onboarding.update"
            | "overlay.placement.get"
            | "overlay.placement.update"
            | "overlay.placement.reposition"
            | "overlay.placement.reset"
            | "settings.get"
            | "settings.update"
            | "agent.ingest"
            | "agent.parse_warnings"
            | "agent.session.acknowledge"
            | "events.recent"
            | "pet.list"
            | "pet.history"
            | "pet.activate"
            | "pet.delete"
            | "pet.assets.repair"
            | "petpack.validate"
            | "petpack.import"
            | "petpack.seed_bundled"
            | "petpack.export"
            | "generation.start"
            | "generation.retry"
            | "generation.resume"
            | "generation.messages"
            | "generation.messages.list"
            | "generation.for_pet"
            | "generation.latest"
            | "generation.history.list"
            | "generation.history.detail"
            | "generation.history.delete"
            | "generation.edit"
            | "generation.messages.wait"
            | "generation.reply"
            | "generation.cancel"
            | "connections.check"
            | "connections.receipts"
            | "connections.repair"
            | "connections.refresh_installed"
            | "connections.uninstall"
            | "connections.test"
            | "product.convergence.get"
            | "product.convergence.update"
            | "product.convergence.preflight"
            | "renderer.budget"
            | "codex.app_server.probe"
            | "diagnostics.export"
    )
}

fn validate_method_params(method: &str, params: &Value) -> Result<()> {
    let allowed: &[&str] = match method {
        "petcore.health"
        | "state.snapshot"
        | "behavior.get"
        | "onboarding.get"
        | "overlay.placement.get"
        | "pet.list"
        | "generation.latest"
        | "codex.app_server.probe"
        | "connections.receipts"
        | "connections.refresh_installed"
        | "product.convergence.get"
        | "product.convergence.preflight" => &[],
        "petcore.shutdown" => &["expected_instance_id"],
        "state.wait" => &["after_revision", "timeout_ms"],
        "behavior.patch" => &["expected_revision", "changes"],
        "onboarding.update" => &["expected_revision", "progress"],
        "overlay.placement.update" => &[
            "x",
            "y",
            "display_width_pt",
            "display_id",
            "expected_revision",
        ],
        "overlay.placement.reposition" => &["x", "y", "display_width_pt", "display_id"],
        "overlay.placement.reset" => &[],
        "settings.get" => &["key"],
        "settings.update" => &["key", "value"],
        "agent.ingest" => AGENT_EVENT_ALLOWED_FIELDS,
        "agent.parse_warnings" => &["source", "warnings"],
        "agent.session.acknowledge" => &["acknowledgement_id"],
        "events.recent" => &["limit"],
        "pet.activate" | "pet.delete" | "pet.assets.repair" => &["id"],
        "pet.history" => &["pet_id", "limit"],
        "petpack.validate" => &["path"],
        "petpack.import" => &["path", "expect_absent"],
        "petpack.seed_bundled" => &["inventory", "inventory_root"],
        "petpack.export" => &["id", "path"],
        "generation.start" => &["description", "style", "quality", "reference_images"],
        "generation.retry" => &["job_id", "form"],
        "generation.resume" => &["job_id", "instruction", "request_id"],
        "generation.messages"
        | "generation.cancel"
        | "generation.history.detail"
        | "generation.history.delete" => &["job_id"],
        "generation.messages.list" => &["job_id", "before_sequence", "limit"],
        "generation.for_pet" => &["pet_id"],
        "generation.history.list" => &["limit"],
        "generation.edit" => &["pet_id", "instruction", "baseline_revision_id"],
        "generation.messages.wait" => &["job_id", "after_revision", "timeout_ms"],
        "generation.reply" => &["job_id", "content", "request_id"],
        "connections.check" => &["source", "cwd"],
        "connections.repair" => &["source", "cwd"],
        "connections.uninstall" | "connections.test" => &["source"],
        "product.convergence.update" => &[
            "schema_version",
            "build_id",
            "app_version",
            "connector_report",
        ],
        "renderer.budget" => &["quality", "frame_count"],
        "diagnostics.export" => &["app_environment"],
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
    let mut value = json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": bounded_rpc_error_message(message),
        }
    });
    if let Some(payload) = message
        .strip_prefix("generation_active_conflict: ")
        .and_then(|payload| serde_json::from_str::<Value>(payload).ok())
    {
        value["error"]["data"] = json!({
            "kind": "generation_active_conflict",
            "active_job": payload
        });
    }
    value
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

fn validated_product_convergence_receipt(
    state: &CoreState,
    params: ProductConvergenceUpdateParams,
) -> Result<ProductConvergenceReceipt> {
    if params.schema_version != PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION {
        return Err(invalid_params(format!(
            "product convergence schema_version must be {PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION}"
        )));
    }
    if params.build_id.is_empty()
        || params.build_id.len() > MAX_PRODUCT_CONVERGENCE_IDENTITY_BYTES
        || params.app_version.is_empty()
        || params.app_version.len() > MAX_PRODUCT_CONVERGENCE_IDENTITY_BYTES
    {
        return Err(invalid_params(format!(
            "product convergence build_id and app_version must each contain 1..={MAX_PRODUCT_CONVERGENCE_IDENTITY_BYTES} bytes"
        )));
    }

    let runtime = RuntimeReleaseManifest::compiled();
    if params.build_id != runtime.build_id || params.app_version != runtime.app_version {
        return Err(PetCoreError::Conflict(format!(
            "product convergence identity does not match the active runtime (expected build_id={} app_version={})",
            runtime.build_id, runtime.app_version
        )));
    }

    let encoded_report = serde_json::to_vec(&params.connector_report)?;
    if encoded_report.len() > MAX_PRODUCT_CONVERGENCE_REPORT_BYTES {
        return Err(invalid_params(format!(
            "connector_report exceeds {MAX_PRODUCT_CONVERGENCE_REPORT_BYTES} encoded bytes"
        )));
    }
    if !params.connector_report.ok {
        return Err(invalid_params(
            "connector_report must be successful before convergence can be recorded",
        ));
    }

    let expected_sources = [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ];
    if params.connector_report.results.len() != expected_sources.len() {
        return Err(invalid_params(
            "connector_report must contain exactly four source results",
        ));
    }

    let mut managed_sources = 0_u32;
    let mut verified_sources = 0_u32;
    let mut skipped_sources = 0_u32;
    let mut codex_skills_sha256 = None;
    let mut codex_content_sha256 = None;

    for (index, (result, expected_source)) in params
        .connector_report
        .results
        .iter()
        .zip(expected_sources)
        .enumerate()
    {
        if result.source != expected_source {
            return Err(invalid_params(format!(
                "connector_report result {index} must be for {}",
                enum_name(expected_source)
            )));
        }
        if result.detail.is_empty() || result.detail.len() > MAX_PRODUCT_CONVERGENCE_DETAIL_BYTES {
            return Err(invalid_params(format!(
                "{} connector detail must contain 1..={MAX_PRODUCT_CONVERGENCE_DETAIL_BYTES} bytes",
                enum_name(result.source)
            )));
        }
        if result
            .error
            .as_ref()
            .is_some_and(|error| error.len() > MAX_PRODUCT_CONVERGENCE_ERROR_BYTES)
        {
            return Err(invalid_params(format!(
                "{} connector error exceeds {MAX_PRODUCT_CONVERGENCE_ERROR_BYTES} bytes",
                enum_name(result.source)
            )));
        }
        for (name, value) in [
            ("expected_version", result.expected_version.as_deref()),
            ("active_version", result.active_version.as_deref()),
        ] {
            if value.is_some_and(|value| {
                value.is_empty() || value.len() > MAX_PRODUCT_CONVERGENCE_IDENTITY_BYTES
            }) {
                return Err(invalid_params(format!(
                    "{} connector {name} must contain 1..={MAX_PRODUCT_CONVERGENCE_IDENTITY_BYTES} bytes",
                    enum_name(result.source)
                )));
            }
        }
        for (name, value) in [
            (
                "expected_skills_sha256",
                result.expected_skills_sha256.as_deref(),
            ),
            (
                "active_skills_sha256",
                result.active_skills_sha256.as_deref(),
            ),
            (
                "expected_content_sha256",
                result.expected_content_sha256.as_deref(),
            ),
            (
                "managed_source_content_sha256",
                result.managed_source_content_sha256.as_deref(),
            ),
            (
                "active_content_sha256",
                result.active_content_sha256.as_deref(),
            ),
        ] {
            if value.is_some_and(|digest| !is_lowercase_sha256(digest)) {
                return Err(invalid_params(format!(
                    "{} connector {name} must be a lowercase SHA-256 digest",
                    enum_name(result.source)
                )));
            }
        }

        match result.status {
            connections::InstalledSourceRefreshStatus::SkippedNotManaged => {
                if result.managed
                    || result.refreshed
                    || !result.ok
                    || result.verified
                    || result.error.is_some()
                    || connector_result_has_version_or_digest(result)
                {
                    return Err(invalid_params(format!(
                        "{} skipped connector result is internally inconsistent",
                        enum_name(result.source)
                    )));
                }
                skipped_sources += 1;
            }
            connections::InstalledSourceRefreshStatus::Current
            | connections::InstalledSourceRefreshStatus::Updated => {
                if !result.managed
                    || !result.refreshed
                    || !result.ok
                    || !result.verified
                    || result.error.is_some()
                {
                    return Err(invalid_params(format!(
                        "{} managed connector result is not completely verified",
                        enum_name(result.source)
                    )));
                }
                managed_sources += 1;
                verified_sources += 1;
            }
            connections::InstalledSourceRefreshStatus::PendingHost
            | connections::InstalledSourceRefreshStatus::Conflict
            | connections::InstalledSourceRefreshStatus::Failed => {
                return Err(invalid_params(format!(
                    "{} connector result is incomplete",
                    enum_name(result.source)
                )));
            }
        }

        if result.source == AgentSource::Codex && result.managed {
            let (compiled_version, compiled_skills_sha256, compiled_content_sha256) =
                connections::compiled_codex_plugin_identity(&state.paths)?;
            let expected_version = result.expected_version.as_deref();
            if expected_version.is_none() || expected_version != result.active_version.as_deref() {
                return Err(invalid_params(
                    "managed Codex connector versions must be present and equal",
                ));
            }
            if expected_version != Some(compiled_version.as_str()) {
                return Err(invalid_params(
                    "managed Codex connector version does not match this runtime",
                ));
            }
            let expected_skills = result.expected_skills_sha256.as_deref();
            if expected_skills.is_none()
                || expected_skills != result.active_skills_sha256.as_deref()
            {
                return Err(invalid_params(
                    "managed Codex connector Skills digests must be present and equal",
                ));
            }
            if expected_skills != Some(compiled_skills_sha256.as_str()) {
                return Err(invalid_params(
                    "managed Codex connector Skills digest does not match this runtime",
                ));
            }
            let expected_content = result.expected_content_sha256.as_deref();
            if expected_content.is_none()
                || expected_content != result.managed_source_content_sha256.as_deref()
                || expected_content != result.active_content_sha256.as_deref()
            {
                return Err(invalid_params(
                    "managed Codex connector content digests must be present and equal",
                ));
            }
            if expected_content != Some(compiled_content_sha256.as_str()) {
                return Err(invalid_params(
                    "managed Codex connector content digest does not match this runtime",
                ));
            }
            codex_skills_sha256 = result.expected_skills_sha256.clone();
            codex_content_sha256 = result.expected_content_sha256.clone();
        } else if result.source != AgentSource::Codex && result.managed {
            let expected_version = result.expected_version.as_deref();
            if expected_version.is_none() || expected_version != result.active_version.as_deref() {
                return Err(invalid_params(format!(
                    "managed {} connector versions must be present and equal",
                    enum_name(result.source)
                )));
            }
            if expected_version != Some(runtime.app_version.as_str()) {
                return Err(invalid_params(format!(
                    "managed {} connector version does not match this runtime",
                    enum_name(result.source)
                )));
            }
            if connector_result_has_digest(result) {
                return Err(invalid_params(format!(
                    "{} connector must not report Codex-only digest fields",
                    enum_name(result.source)
                )));
            }
        }
    }

    let report_sha256 = hex::encode(Sha256::digest(&encoded_report));
    Ok(ProductConvergenceReceipt {
        schema_version: PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION.to_string(),
        build_id: runtime.build_id,
        app_version: runtime.app_version,
        completed_at: now_rfc3339(),
        connector_report_summary: ProductConvergenceConnectorSummary {
            total_sources: expected_sources.len() as u32,
            managed_sources,
            verified_sources,
            skipped_sources,
            report_sha256,
            codex_skills_sha256,
            codex_content_sha256,
        },
    })
}

fn connector_result_has_version_or_digest(
    result: &connections::InstalledSourceRefreshResult,
) -> bool {
    result.expected_version.is_some()
        || result.active_version.is_some()
        || connector_result_has_digest(result)
}

fn connector_result_has_digest(result: &connections::InstalledSourceRefreshResult) -> bool {
    result.expected_skills_sha256.is_some()
        || result.active_skills_sha256.is_some()
        || result.expected_content_sha256.is_some()
        || result.managed_source_content_sha256.is_some()
        || result.active_content_sha256.is_some()
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn handle_request(state: &CoreState, request: RpcRequest) -> Result<Value> {
    let started = Instant::now();
    let method = request.method.clone();
    let result = handle_request_inner(state, request);
    state.diagnostics.rpc_finished(&method, &result, started);
    result
}

fn handle_request_inner(state: &CoreState, request: RpcRequest) -> Result<Value> {
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
            "connector_environment": connector_environment_snapshot(),
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
        "onboarding.get" => Ok(json!(state.database.onboarding_with_revision()?)),
        "onboarding.update" => {
            let expected_revision = required_string(&request.params, "expected_revision")?
                .parse::<u64>()
                .map_err(|_| invalid_params("expected_revision must be a decimal string"))?;
            let progress = request
                .params
                .get("progress")
                .cloned()
                .ok_or_else(|| invalid_params("missing onboarding progress"))?;
            let progress: OnboardingProgress = serde_json::from_value(progress)
                .map_err(|error| invalid_params(format!("invalid onboarding progress: {error}")))?;
            Ok(json!(state
                .database
                .update_onboarding(expected_revision, &progress)?))
        }
        "overlay.placement.get" => {
            let projection = state.database.overlay_placement_projection()?;
            Ok(json!({
                "overlay_placement": projection.placement,
                "overlay_placement_revision": projection.revision.to_string(),
                "overlay_placement_intent": projection.intent,
            }))
        }
        "overlay.placement.update" => {
            let expected_revision =
                required_canonical_decimal_u64(&request.params, "expected_revision")?;
            let mut placement_params = request.params;
            placement_params
                .as_object_mut()
                .expect("validated RPC params are an object")
                .remove("expected_revision");
            let placement: OverlayPlacement = serde_json::from_value(placement_params)?;
            persist_overlay_placement(state, placement, None, Some(expected_revision))
        }
        "overlay.placement.reposition" => {
            let placement: OverlayPlacement = serde_json::from_value(request.params)?;
            persist_overlay_placement(
                state,
                placement,
                Some(OverlayPlacementIntent::ExternalReposition),
                None,
            )
        }
        "overlay.placement.reset" => persist_overlay_placement(
            state,
            OverlayPlacement::default(),
            Some(OverlayPlacementIntent::Reset),
            None,
        ),
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
            let event = match normalize_event(&request.params) {
                Ok(event) => event,
                Err(error) => {
                    if let Ok(source) = required_source(&request.params) {
                        state.diagnostics.agent_parse_warning(
                            source,
                            AgentParseWarning {
                                field: AgentParseField::NormalizedEvent,
                                failure: AgentParseFailure::NormalizationFailed,
                            },
                        );
                    }
                    return Err(error);
                }
            };
            ingest_event(state, event)
        }
        "agent.parse_warnings" => record_agent_parse_warnings(state, &request.params),
        "agent.session.acknowledge" => acknowledge_agent_session(state, &request.params),
        "events.recent" => {
            let limit = optional_u64_param(&request.params, "limit")?
                .unwrap_or(20)
                .min(MAX_RECENT_EVENTS as u64) as usize;
            Ok(json!(state.database.recent_events(limit)?))
        }
        "pet.list" => Ok(json!(list_pets_with_revision_metadata(state)?)),
        "pet.history" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let limit = bounded_u64_param(
                &request.params,
                "limit",
                generation::DEFAULT_PET_HISTORY_LIMIT as u64,
                1,
                generation::MAX_PET_HISTORY_LIMIT as u64,
            )? as usize;
            Ok(json!(generation::pet_history(
                &state.paths,
                &state.database,
                &pet_id,
                limit,
            )?))
        }
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
            if petpack::is_bundled_pet(&pet) {
                return Err(PetCoreError::Conflict(
                    "bundled pets are part of the App and cannot be deleted".to_string(),
                ));
            }
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
        "pet.assets.repair" => {
            let id = required_string(&request.params, "id")?;
            let pet = state
                .database
                .get_pet(&id)?
                .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {id}")))?;
            Ok(json!(petpack::repair_runtime_assets(
                &state.paths,
                &state.database,
                &pet
            )?))
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
        "petpack.seed_bundled" => {
            let inventory = required_string(&request.params, "inventory")?;
            if inventory != petpack::BUNDLED_PET_INVENTORY_VERSION {
                return Err(invalid_params("unsupported bundled pet inventory"));
            }
            let inventory_root = required_string(&request.params, "inventory_root")?;
            Ok(json!({
                "inventory": petpack::BUNDLED_PET_INVENTORY_VERSION,
                "outcomes": petpack::seed_bundled_pet_inventory(
                    &state.paths,
                    &state.database,
                    &PathBuf::from(inventory_root),
                )?
            }))
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
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
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
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let job_id = generation::retry_generation_for_instance(
                &state.paths,
                &state.database,
                &retry_of_job_id,
                form,
                state.instance_id(),
            )?;
            let retry_job = state.database.generation_job(&job_id)?;
            let operation = retry_job
                .as_ref()
                .map(generation::generation_job_operation)
                .unwrap_or(generation::GENERATION_OPERATION_CREATE);
            let baseline_revision_id = retry_job
                .as_ref()
                .map(|job| generation::generation_job_baseline_revision_id(&state.paths, job))
                .transpose()?
                .flatten();
            Ok(json!({
                "ok": true,
                "job_id": job_id,
                "retry_of_job_id": retry_of_job_id,
                "operation": operation,
                "baseline_revision_id": baseline_revision_id
            }))
        }
        "generation.resume" => {
            let job_id = required_string(&request.params, "job_id")?;
            let instruction = optional_string_param(&request.params, "instruction")?;
            let request_id = optional_string_param(&request.params, "request_id")?;
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let resumed_job_id = generation::resume_generation_with_instruction_for_instance(
                &state.paths,
                &state.database,
                &job_id,
                instruction,
                request_id,
                state.instance_id(),
            )?;
            let resumed_job = state.database.generation_job(&resumed_job_id)?;
            let operation = resumed_job
                .as_ref()
                .map(generation::generation_job_operation)
                .unwrap_or(generation::GENERATION_OPERATION_CREATE);
            let baseline_revision_id = resumed_job
                .as_ref()
                .map(|job| generation::generation_job_baseline_revision_id(&state.paths, job))
                .transpose()?
                .flatten();
            Ok(json!({
                "ok": true,
                "job_id": resumed_job_id,
                "resumed": true,
                "operation": operation,
                "baseline_revision_id": baseline_revision_id
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
        "generation.messages.list" => {
            let job_id = required_string(&request.params, "job_id")?;
            let before_sequence = optional_u64_param(&request.params, "before_sequence")?;
            let limit = bounded_u64_param(&request.params, "limit", 50, 1, 200)? as usize;
            Ok(json!(generation::studio_messages_page(
                &state.paths,
                &state.database,
                &job_id,
                before_sequence,
                limit,
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
            generation_session_recovery_snapshot(state, &job, Some(&pet_id))
        }
        "generation.latest" => {
            let Some(job) = state.database.latest_generation_job()? else {
                return Ok(json!({
                    "ok": true,
                    "found": false,
                    "messages": []
                }));
            };
            generation_session_recovery_snapshot(state, &job, None)
        }
        "generation.history.list" => {
            let limit = bounded_u64_param(
                &request.params,
                "limit",
                generation::DEFAULT_STUDIO_HISTORY_LIMIT as u64,
                1,
                generation::MAX_STUDIO_HISTORY_LIMIT as u64,
            )? as usize;
            Ok(json!(generation::studio_history(&state.database, limit)?))
        }
        "generation.history.detail" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation::studio_history_detail(
                &state.paths,
                &state.database,
                &job_id,
            )?))
        }
        "generation.history.delete" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation::delete_studio_history(
                &state.paths,
                &state.database,
                &job_id,
            )?))
        }
        "generation.edit" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let instruction = required_string(&request.params, "instruction")?;
            let baseline_revision_id =
                optional_string_param(&request.params, "baseline_revision_id")?;
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let job_id = generation::start_pet_edit_from_revision_for_instance(
                &state.paths,
                &state.database,
                &pet_id,
                &instruction,
                baseline_revision_id,
                state.instance_id(),
            )?;
            let created_job = state.database.generation_job(&job_id)?.ok_or_else(|| {
                PetCoreError::Validation(
                    "created pet edit job could not be loaded for its receipt".to_string(),
                )
            })?;
            let baseline_revision_id =
                generation::generation_job_baseline_revision_id(&state.paths, &created_job)?;
            Ok(json!({
                "ok": true,
                "job_id": job_id,
                "pet_id": pet_id,
                "baseline_revision_id": baseline_revision_id,
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
            let request_id = optional_string_param(&request.params, "request_id")?;
            Ok(json!(
                generation::append_user_reply_with_request_for_instance(
                    &state.paths,
                    &state.database,
                    &job_id,
                    &content,
                    request_id,
                    state.instance_id(),
                )?
            ))
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
            let probe_cwd = optional_probe_cwd(&request.params)?;
            let source = optional_source(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            if let Some(source) = source {
                let status = match probe_cwd.as_deref() {
                    Some(cwd) => connections::check_source_at(&state.paths, source, cwd),
                    None => connections::check_source(&state.paths, source),
                };
                state.invalidate_connection_light_status_cache();
                state.invalidate_connection_evidence_projection(source);
                let persisted = state.database.upsert_connection_status(&status);
                state.invalidate_connection_light_status_cache();
                state.invalidate_connection_evidence_projection(source);
                persisted?;
                Ok(json!(status))
            } else {
                let statuses = match probe_cwd.as_deref() {
                    Some(cwd) => connections::check_all_at(&state.paths, cwd),
                    None => connections::check_all(&state.paths),
                };
                state.invalidate_connection_light_status_cache();
                state.invalidate_all_connection_evidence_projections();
                let persisted = state.database.upsert_connection_statuses(&statuses);
                state.invalidate_connection_light_status_cache();
                state.invalidate_all_connection_evidence_projections();
                persisted?;
                Ok(json!(statuses))
            }
        }
        "connections.receipts" => {
            let receipts = [
                AgentSource::Codex,
                AgentSource::ClaudeCode,
                AgentSource::Pi,
                AgentSource::Opencode,
            ]
            .into_iter()
            .map(|source| {
                let contract_version = connections::contract_version_for_source(source);
                let ordinary = state
                    .database
                    .latest_connector_ordinary_receipt_for_contract(source, contract_version)?
                    .map(|receipt| connector_receipt_status(&state.paths, source, receipt));
                let diagnostic = state
                    .database
                    .latest_connector_event_receipt_for_contract(source, true, contract_version)?
                    .map(|receipt| connector_receipt_status(&state.paths, source, receipt));
                let (task_starts, task_activities, task_completions) =
                    connections::task_evidence_events(source);
                let task = state
                    .database
                    .latest_connector_task_receipt_for_contract(
                        source,
                        contract_version,
                        task_starts,
                        task_activities,
                        task_completions,
                    )?
                    .map(|receipt| connector_task_receipt_status(&state.paths, source, receipt));
                let latest_observed_ordinary = state
                    .database
                    .latest_connector_event_receipt(source, false)?;
                let latest_observed_diagnostic = state
                    .database
                    .latest_connector_event_receipt(source, true)?;
                Ok(json!({
                    "source": source,
                    "ordinary": ordinary,
                    "diagnostic": diagnostic,
                    "task": task,
                    "latest_observed": {
                        "ordinary": latest_observed_ordinary,
                        "diagnostic": latest_observed_diagnostic,
                    },
                }))
            })
            .collect::<Result<Vec<_>>>()?;
            Ok(json!(receipts))
        }
        "connections.repair" => {
            let source = required_source(&request.params)?;
            let probe_cwd = optional_probe_cwd(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = match probe_cwd.as_deref() {
                Some(cwd) => connections::repair_source_at(&state.paths, source, cwd),
                None => connections::repair_source(&state.paths, source),
            };
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = status?;
            let persisted = state.database.upsert_connection_status(&status);
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            persisted?;
            Ok(json!(status))
        }
        "connections.refresh_installed" => {
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            if state.database.active_generation_job()?.is_some() {
                return Err(PetCoreError::Conflict(
                    "generation work is active; wait before updating Agent capabilities"
                        .to_string(),
                ));
            }
            state.invalidate_connection_light_status_cache();
            state.invalidate_all_connection_evidence_projections();
            let refreshed = connections::refresh_installed_sources(&state.paths);
            state.invalidate_connection_light_status_cache();
            state.invalidate_all_connection_evidence_projections();
            Ok(json!(refreshed))
        }
        "product.convergence.get" => Ok(json!(state.database.product_convergence_receipt()?)),
        "product.convergence.update" => {
            let params: ProductConvergenceUpdateParams = serde_json::from_value(request.params)
                .map_err(|error| {
                    invalid_params(format!("invalid product convergence receipt: {error}"))
                })?;
            let receipt = validated_product_convergence_receipt(state, params)?;
            state
                .database
                .upsert_product_convergence_receipt(&receipt)?;
            Ok(json!(receipt))
        }
        "product.convergence.preflight" => {
            let active_generation = state.database.active_generation_job()?;
            let active_generation_status =
                active_generation.as_ref().map(|job| enum_name(job.status));
            let connection_operation_active =
                state.connection_operation_active.load(Ordering::Acquire);
            let runtime_replacement_safe = active_generation.as_ref().is_none_or(|job| {
                matches!(
                    job.status,
                    GenerationJobStatus::WaitingForUser | GenerationJobStatus::Failed
                )
            }) && !connection_operation_active;
            Ok(json!({
                "safe": active_generation.is_none() && !connection_operation_active,
                "active_generation": active_generation.is_some(),
                "active_generation_status": active_generation_status,
                "connection_operation_active": connection_operation_active,
                "runtime_replacement_safe": runtime_replacement_safe,
            }))
        }
        "connections.uninstall" => {
            let source = required_source(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = connections::uninstall_source(&state.paths, source);
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = status?;
            let persisted = state.database.upsert_connection_status(&status);
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            persisted?;
            Ok(json!(status))
        }
        "connections.test" => {
            let source = required_source(&request.params)?;
            let _operation = state.begin_connection_operation()?;
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
            let frame_count = optional_u64_param(&request.params, "frame_count")?.unwrap_or(8);
            if !(petcore_types::MIN_FRAMES_PER_STATE as u64
                ..=petcore_types::MAX_FRAMES_PER_STATE as u64)
                .contains(&frame_count)
            {
                return Err(invalid_params(format!(
                    "frame_count must be between {} and {}",
                    petcore_types::MIN_FRAMES_PER_STATE,
                    petcore_types::MAX_FRAMES_PER_STATE
                )));
            }
            Ok(json!(metrics::renderer_budget(quality, frame_count as u32)))
        }
        "codex.app_server.probe" => {
            let _host_guard = state.agent_host_process_guard();
            Ok(json!(app_server::probe_codex_app_server()))
        }
        "diagnostics.export" => {
            let app_environment = request
                .params
                .get("app_environment")
                .ok_or_else(|| invalid_params("missing app_environment"))?;
            Ok(json!(diagnostics::export_diagnostics(
                &state.paths,
                &state.diagnostics,
                app_environment,
            )?))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}

fn connector_environment_snapshot() -> BTreeMap<String, String> {
    connector_identity_environment()
}

fn connector_receipt_status(
    paths: &AppPaths,
    source: AgentSource,
    receipt: crate::db::ConnectorEventReceipt,
) -> Value {
    json!({
        "current": connections::connector_receipt_is_current(paths, source, &receipt),
        "receipt": receipt,
    })
}

fn connector_task_receipt_status(
    paths: &AppPaths,
    source: AgentSource,
    receipt: crate::db::ConnectorTaskReceipt,
) -> Value {
    let current = connections::connector_receipt_is_current(paths, source, &receipt.start)
        && connections::connector_receipt_is_current(paths, source, &receipt.activity)
        && connections::connector_receipt_is_current(paths, source, &receipt.completion);
    json!({
        "current": current,
        "receipt": receipt,
    })
}

fn ingest_event(state: &CoreState, event: AgentEvent) -> Result<Value> {
    let insert_outcome = state.database.insert_event(&event)?;
    let inserted = insert_outcome == InsertEventOutcome::Inserted;
    let suppressed = insert_outcome == InsertEventOutcome::Suppressed;
    if inserted {
        // Receipts, ordinary activity, and complete task evidence are all
        // derived from this source's event stream. Refresh only that evidence
        // projection; the static filesystem scan remains reusable.
        state.mark_connection_evidence_projection_dirty(event.source);
    }
    let behavior = state.database.behavior()?;
    let triggered = inserted && event_drives_overlay(&behavior, &event);
    let diagnostic_outcome = match insert_outcome {
        InsertEventOutcome::Inserted => DiagnosticIngestOutcome::Inserted,
        InsertEventOutcome::Duplicate => DiagnosticIngestOutcome::Duplicate,
        InsertEventOutcome::Suppressed => DiagnosticIngestOutcome::Suppressed,
    };
    state.diagnostics.agent_activity(
        event.source,
        event.event_type,
        diagnostic_outcome,
        triggered,
    );
    let active_agent_state = canonical_agent_state(state, &behavior)?;
    Ok(json!({
        "ok": true,
        "inserted": inserted,
        "suppressed": suppressed,
        "triggered": triggered,
        "state": event.event_type.pet_state(),
        "event": (!suppressed).then_some(event),
        "active_agent_state": active_agent_state,
    }))
}

fn record_agent_parse_warnings(state: &CoreState, params: &Value) -> Result<Value> {
    const MAX_WARNINGS: usize = 8;
    let source = required_source(params)?;
    let warnings = params
        .get("warnings")
        .cloned()
        .ok_or_else(|| invalid_params("missing warnings"))?;
    let warnings: Vec<AgentParseWarning> = serde_json::from_value(warnings)
        .map_err(|_| invalid_params("warnings must use the closed parse-warning schema"))?;
    if warnings.is_empty() || warnings.len() > MAX_WARNINGS {
        return Err(invalid_params(format!(
            "warnings must contain between 1 and {MAX_WARNINGS} entries"
        )));
    }
    for warning in warnings.iter().copied() {
        state.diagnostics.agent_parse_warning(source, warning);
    }
    Ok(json!({ "ok": true, "recorded": warnings.len() }))
}

fn acknowledge_agent_session(state: &CoreState, params: &Value) -> Result<Value> {
    let acknowledgement_id = required_string(params, "acknowledgement_id")?;
    if !agent_state::is_valid_session_acknowledgement_id(&acknowledgement_id) {
        return Err(invalid_params("acknowledgement_id is invalid"));
    }
    let behavior = state.database.behavior()?;
    let snapshot = state.snapshot_sequenced_events()?;
    let visible = agent_state::select_display_agent_states(
        &behavior,
        snapshot.events.as_slice(),
        OffsetDateTime::now_utc(),
    );
    if !visible.states.iter().any(|session| {
        session.event.event_type == AgentEventType::Done
            && agent_state::session_acknowledgement_id(&session.event) == acknowledgement_id
    }) {
        return Err(PetCoreError::Conflict(
            "Agent session is no longer available to acknowledge".to_string(),
        ));
    }
    let changed = state
        .database
        .acknowledge_agent_session(&acknowledgement_id)?;
    Ok(json!({
        "ok": true,
        "acknowledged": true,
        "changed": changed,
        "acknowledgement_id": acknowledgement_id,
    }))
}

fn canonical_agent_state(
    state: &CoreState,
    behavior: &BehaviorSettings,
) -> Result<Option<agent_state::ActiveAgentState>> {
    let mut latest_consistent_event_state = None;
    for _ in 0..MAX_SNAPSHOT_REVISION_RETRIES {
        let snapshot = state.snapshot_sequenced_events()?;
        let state_revision = snapshot.state_revision;
        let events = snapshot.events;
        let acknowledged_session_activations = match state
            .database
            .acknowledged_agent_sessions_at_revision(state_revision)?
        {
            RevisionChecked::Matched { value, .. } => value,
            RevisionChecked::Mismatch { .. } => {
                thread::yield_now();
                continue;
            }
        };
        let mut active = agent_state::select_active_agent_state_with_acknowledgements(
            behavior,
            events.as_slice(),
            OffsetDateTime::now_utc(),
            &acknowledged_session_activations,
        );
        latest_consistent_event_state = active.clone();
        if let Some(active) = &mut active {
            if !hydrate_agent_session_display(state, state_revision, active)? {
                thread::yield_now();
                continue;
            }
        }
        return Ok(active);
    }
    // Event ingestion already committed successfully. Under a write burst,
    // returning the latest event-only state is honest and keeps Hook delivery
    // successful; a later state snapshot hydrates messages once the revision
    // is stable. Never turn a committed Agent event into an RPC failure merely
    // because optional display enrichment raced another event.
    Ok(latest_consistent_event_state)
}

fn state_snapshot(state: &CoreState, changed: bool) -> Result<Value> {
    let mut pets = list_pets_with_revision_metadata(state)?;
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
    for _ in 0..MAX_SNAPSHOT_REVISION_RETRIES {
        let sequenced_event_snapshot = state.snapshot_sequenced_events()?;
        let snapshot_state_revision = sequenced_event_snapshot.state_revision;
        let sequenced_events = sequenced_event_snapshot.events;
        let scanned_events = sequenced_events
            .iter()
            .map(|candidate| candidate.event.clone())
            .collect::<Vec<_>>();
        let Some(recent_events) = state.snapshot_recent_events(snapshot_state_revision)? else {
            thread::yield_now();
            continue;
        };
        let acknowledged_session_activations = match state
            .database
            .acknowledged_agent_sessions_at_revision(snapshot_state_revision)?
        {
            RevisionChecked::Matched { value, .. } => value,
            RevisionChecked::Mismatch { .. } => {
                thread::yield_now();
                continue;
            }
        };
        let events = current_overlay_events(&behavior, &scanned_events)
            .iter()
            .map(agent_state::overlay_event_projection)
            .collect::<Vec<_>>();
        let recent_event_projections = recent_events
            .iter()
            .map(agent_state::overlay_event_projection)
            .collect::<Vec<_>>();
        let mut active_agent_state = agent_state::select_active_agent_state_with_acknowledgements(
            &behavior,
            sequenced_events.as_slice(),
            OffsetDateTime::now_utc(),
            &acknowledged_session_activations,
        );
        if let Some(active) = &mut active_agent_state {
            if !hydrate_agent_session_display(state, snapshot_state_revision, active)? {
                thread::yield_now();
                continue;
            }
        }
        let display_agent_states = agent_state::select_display_agent_states_with_acknowledgements(
            &behavior,
            sequenced_events.as_slice(),
            OffsetDateTime::now_utc(),
            &acknowledged_session_activations,
        );
        let active_agent_sessions_omitted_count = display_agent_states.omitted_count;
        let mut active_agent_sessions = display_agent_states.states;
        let mut display_revision_changed = false;
        for session in &mut active_agent_sessions {
            if !hydrate_agent_session_display(state, snapshot_state_revision, session)? {
                display_revision_changed = true;
                break;
            }
        }
        if display_revision_changed {
            thread::yield_now();
            continue;
        }
        agent_state::assign_anonymous_session_aliases(&mut active_agent_sessions);
        if let Some(active) = &mut active_agent_state {
            active.anonymous_session_alias = active_agent_sessions
                .iter()
                .find(|session| {
                    session.source == active.source
                        && session.source_session_sequence == active.source_session_sequence
                })
                .and_then(|session| session.anonymous_session_alias.clone());
        }
        let overlay_visibility = agent_state::overlay_visibility_for_sessions(
            &behavior,
            !active_agent_sessions.is_empty(),
            active_agent_state.is_some(),
        );
        let connections = state.snapshot_connection_statuses()?;
        let active_generation = active_generation_snapshot(state)?;
        let onboarding = state.database.onboarding_with_revision()?;
        let Some(overlay_placement_projection) =
            state.snapshot_overlay_placement(snapshot_state_revision)?
        else {
            thread::yield_now();
            continue;
        };
        let OverlayPlacementProjection {
            placement: overlay_placement,
            intent: overlay_placement_intent,
            revision: overlay_placement_revision,
        } = overlay_placement_projection;
        let mut snapshot = json!({
            // Use the revision that atomically identifies the event projection.
            // If a new event commits while the rest of this snapshot is assembled,
            // the client's next state.wait observes that later revision immediately.
            "revision": snapshot_state_revision.to_string(),
            "changed": changed,
            "behavior": behavior,
            "behavior_revision": versioned_behavior.revision,
            "onboarding": onboarding,
            "overlay_placement": overlay_placement,
            "overlay_placement_revision": overlay_placement_revision.to_string(),
            "pets": pets,
            "pet_asset_warnings": pet_asset_warnings,
            "events": events,
            "active_agent_state": active_agent_state,
            "active_agent_sessions": active_agent_sessions,
            "active_agent_sessions_omitted_count": active_agent_sessions_omitted_count,
            "overlay_visibility": overlay_visibility,
            "recent_events": recent_event_projections,
            "connections": connections,
            "active_generation": active_generation,
            "connection_operation_active": state
                .connection_operation_active
                .load(Ordering::Acquire),
        });
        if let Some(intent) = overlay_placement_intent {
            snapshot
                .as_object_mut()
                .expect("state snapshot is an object")
                .insert(
                    "overlay_placement_intent".to_string(),
                    serde_json::to_value(intent)?,
                );
        }
        return Ok(snapshot);
    }
    Err(PetCoreError::Conflict(
        "state changed while hydrating session displays; retry the snapshot".to_string(),
    ))
}

fn list_pets_with_revision_metadata(state: &CoreState) -> Result<Vec<petcore_types::PetSummary>> {
    let mut pets = state.database.list_pets()?;
    pet_revision::enrich_pet_revision_metadata(&state.paths, &mut pets)?;
    Ok(pets)
}

fn hydrate_agent_session_display(
    state: &CoreState,
    state_revision: u64,
    active: &mut agent_state::ActiveAgentState,
) -> Result<bool> {
    let Some(persisted) = state.persisted_session_display(
        state_revision,
        active.source,
        active.session_id.as_deref(),
    )?
    else {
        return Ok(false);
    };
    let latest_message = persisted.latest_message;
    let latest_user_message = persisted.latest_user_message;
    let first_user_message = persisted.first_user_message;
    let latest_title = persisted.latest_title;
    let latest_message = latest_message.filter(|message| {
        if let Some(user) = latest_user_message.as_ref() {
            sequenced_event_happened_after(message, user)
        } else if let Some(cutoff) = active.session_activated_at.as_deref() {
            event_happened_after(&message.event.created_at, cutoff)
        } else {
            true
        }
    });
    active.latest_message = latest_message.map(|sequenced| sequenced.event);
    active.latest_user_message = latest_user_message.map(|sequenced| sequenced.event);
    active.session_title = latest_title
        .as_ref()
        .and_then(projected_session_title)
        .or_else(|| first_user_message.as_ref().and_then(fallback_session_title));
    active.session_message = active
        .latest_message
        .as_ref()
        .and_then(event_display_message);
    active.session_user_message = active
        .latest_user_message
        .as_ref()
        .and_then(event_display_message);
    if !should_hydrate_codex_thread_display(active.source, active.session_id.as_deref()) {
        return Ok(true);
    }
    let Some(session_id) = active.session_id.as_deref() else {
        return Ok(true);
    };
    let event_marker = active
        .session_activated_at
        .clone()
        .unwrap_or_else(|| format!("{}:{}", active.event.id, active.source_session_sequence));
    let refresh_seconds = if matches!(
        active.event.event_type,
        AgentEventType::Start
            | AgentEventType::Thinking
            | AgentEventType::Plan
            | AgentEventType::Tool
    ) {
        CODEX_ACTIVE_THREAD_DISPLAY_REFRESH_SECONDS
    } else {
        CODEX_THREAD_DISPLAY_REFRESH_SECONDS
    };
    let Some(display) = state.codex_thread_display(session_id, &event_marker, refresh_seconds)
    else {
        return Ok(true);
    };
    if event_payload_text(&active.event, "session_surface").as_deref() == Some("chatgpt_app") {
        // A successful explicit thread/read is the confirmation that a hook
        // alone cannot provide. Expose it only in the hydrated snapshot; the
        // persisted hook event remains an honest `session_open = null` record.
        active.event.payload_json["session_open"] = Value::Bool(true);
        active.overlay_display.navigation = agent_state::overlay_navigation(&active.event);
    }
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
        if should_replace_hydrated_codex_activity(active.session_activity.as_ref(), &activity) {
            if matches!(
                active.event.event_type,
                AgentEventType::Start
                    | AgentEventType::Thinking
                    | AgentEventType::Plan
                    | AgentEventType::Tool
            ) {
                if let Some(summary_kind) =
                    agent_state::overlay_activity_summary_kind(&activity.kind)
                {
                    active.overlay_display.summary_kind = summary_kind;
                }
            }
            active.session_activity = Some(agent_state::SessionActivity {
                kind: activity.kind,
                content: activity.content,
            });
        }
    }
    Ok(true)
}

fn should_hydrate_codex_thread_display(source: AgentSource, session_id: Option<&str>) -> bool {
    source == AgentSource::Codex && session_id.is_some()
}

fn should_replace_hydrated_codex_activity(
    current: Option<&agent_state::SessionActivity>,
    incoming: &app_server::CodexThreadDisplayActivity,
) -> bool {
    current.is_none()
        || incoming
            .content
            .as_deref()
            .is_some_and(|content| !content.trim().is_empty())
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
        content: projected_message_content(event)?,
    })
}

fn projected_session_title(event: &AgentEvent) -> Option<String> {
    let title = event_payload_text(event, "session_title")?;
    if event.source == AgentSource::ClaudeCode {
        normalize_claude_display_message(&title)
    } else {
        Some(title)
    }
}

fn projected_message_content(event: &AgentEvent) -> Option<String> {
    let message = event_payload_text(event, "message_content")?;
    if event.source == AgentSource::ClaudeCode {
        normalize_claude_display_message(&message)
    } else {
        Some(message)
    }
}

fn fallback_session_title(event: &AgentEvent) -> Option<String> {
    let message = projected_message_content(event)?;
    let normalized = message.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() {
        return None;
    }
    if normalized.chars().count() <= MAX_FALLBACK_SESSION_TITLE_CHARS
        && normalized.len() <= MAX_SESSION_TITLE_BYTES
    {
        return Some(normalized);
    }

    let ellipsis = '…';
    let max_prefix_chars = MAX_FALLBACK_SESSION_TITLE_CHARS.saturating_sub(1);
    let max_prefix_bytes = MAX_SESSION_TITLE_BYTES.saturating_sub(ellipsis.len_utf8());
    let mut shortened = String::new();
    for character in normalized.chars().take(max_prefix_chars) {
        if shortened.len() + character.len_utf8() > max_prefix_bytes {
            break;
        }
        shortened.push(character);
    }
    shortened.push(ellipsis);
    Some(shortened)
}

fn event_happened_after(candidate: &str, cutoff: &str) -> bool {
    let candidate = OffsetDateTime::parse(candidate, &Rfc3339);
    let cutoff = OffsetDateTime::parse(cutoff, &Rfc3339);
    matches!((candidate, cutoff), (Ok(candidate), Ok(cutoff)) if candidate > cutoff)
}

fn sequenced_event_happened_after(
    candidate: &agent_state::SequencedAgentEvent,
    cutoff: &agent_state::SequencedAgentEvent,
) -> bool {
    let candidate_at = OffsetDateTime::parse(&candidate.event.created_at, &Rfc3339);
    let cutoff_at = OffsetDateTime::parse(&cutoff.event.created_at, &Rfc3339);
    matches!(
        (candidate_at, cutoff_at),
        (Ok(candidate_at), Ok(cutoff_at))
            if candidate_at > cutoff_at
                || (candidate_at == cutoff_at
                    && candidate.source_session_sequence > cutoff.source_session_sequence)
    )
}

fn active_generation_snapshot(state: &CoreState) -> Result<Option<Value>> {
    let Some(job) = state.database.active_generation_job()? else {
        return Ok(None);
    };
    let recovery_form = generation::generation_recovery_form(&state.paths, &job)?;
    let operation = generation::generation_job_operation(&job);
    let baseline_revision_id = generation::generation_job_baseline_revision_id(&state.paths, &job)?;
    let messages = generation::read_messages_with_database(&state.paths, &state.database, &job.id)?;
    let input_request = messages
        .iter()
        .rev()
        .find(|message| message.get("kind").and_then(Value::as_str) == Some("input_request"))
        .cloned();
    let cancellation_pending =
        job.cancel_requested_at.is_some() && job.thread_archived_at.is_none();
    let capabilities = generation::generation_job_capabilities(&job, false);
    Ok(Some(json!({
        "job_id": job.id,
        "status": enum_name(job.status),
        "form": recovery_form.form,
        "reference_reselection_count": recovery_form.reference_reselection_count,
        "session_id": job.session_id,
        "result_pet_id": job.result_pet_id,
        "operation": operation,
        "baseline_revision_id": baseline_revision_id,
        "owner_instance_id": job.owner_instance_id,
        "heartbeat_at": job.heartbeat_at,
        "started_at": job.started_at,
        "ended_at": job.ended_at,
        "recoverable": job.recoverable,
        "failure_code": job.failure_code,
        "pause_reason": job.pause_reason,
        "cancellation_pending": cancellation_pending,
        "capabilities": capabilities,
        "message_revision": state.database.generation_message_revision(&job.id)?.to_string(),
        "messages": messages,
        "input_request": input_request,
    })))
}

fn generation_session_recovery_snapshot(
    state: &CoreState,
    job: &crate::db::GenerationJobRecord,
    requested_pet_id: Option<&str>,
) -> Result<Value> {
    let recovery_form = generation::generation_recovery_form(&state.paths, job)?;
    let operation = generation::generation_job_operation(job);
    let baseline_revision_id = generation::generation_job_baseline_revision_id(&state.paths, job)?;
    let result = generation::read_generation_result(&state.paths, &state.database, &job.id)?;
    let cancellation_pending =
        job.cancel_requested_at.is_some() && job.thread_archived_at.is_none();
    let capabilities = generation::generation_job_capabilities(job, false);
    Ok(json!({
        "ok": true,
        "found": true,
        "pet_id": requested_pet_id,
        "job_id": job.id,
        "status": enum_name(job.status),
        "session_id": job.session_id,
        "result_pet_id": job.result_pet_id,
        "retry_of_job_id": job.retry_of_job_id,
        "operation": operation,
        "baseline_revision_id": baseline_revision_id,
        "revision_id": result.as_ref().map(|result| &result.revision_id),
        "validation_summary": result.as_ref().map(|result| &result.validation_summary),
        "created_at": job.created_at,
        "updated_at": job.updated_at,
        "heartbeat_at": job.heartbeat_at,
        "started_at": job.started_at,
        "ended_at": job.ended_at,
        "recoverable": job.recoverable,
        "failure_code": job.failure_code,
        "pause_reason": job.pause_reason,
        "cancellation_pending": cancellation_pending,
        "capabilities": capabilities,
        "form": recovery_form.form,
        "reference_reselection_count": recovery_form.reference_reselection_count,
        "message_revision": state.database.generation_message_revision(&job.id)?.to_string(),
        "messages": generation::read_messages_with_database(
            &state.paths,
            &state.database,
            &job.id
        )?
    }))
}

fn merge_cached_connection_statuses(
    paths: &AppPaths,
    light_statuses: Vec<AgentConnectionStatus>,
    cached_statuses: Vec<AgentConnectionStatus>,
) -> Vec<AgentConnectionStatus> {
    light_statuses
        .into_iter()
        .map(|light| {
            let light_found_no_issues = light.items.iter().all(|item| !item.status.is_blocking());
            if light_found_no_issues {
                if let Some(cached) = cached_statuses.iter().find(|cached| {
                    cached.source == light.source
                        && connections::cached_connection_status_is_current_for_light_projection(
                            paths, cached,
                        )
                }) {
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
    let starting_display_epoch = state.codex_display_epoch.load(Ordering::Acquire);
    // One connection for the whole wait. Opening a fresh SQLite connection on
    // every tick dominated this loop's cost: a 30 second idle wait re-opened
    // the database ~250 times purely to re-read a single revision row.
    let revision_connection = state.database.open_reusable_read_connection()?;

    loop {
        state.refresh_codex_activity(&behavior);
        let current_revision = state
            .database
            .state_revision_using(&revision_connection)?
            .to_string();
        let current_display_epoch = state.codex_display_epoch.load(Ordering::Acquire);
        if current_revision != after_revision || current_display_epoch != starting_display_epoch {
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

fn optional_probe_cwd(params: &Value) -> Result<Option<PathBuf>> {
    let Some(value) = optional_string_param(params, "cwd")? else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(invalid_params("cwd must be an absolute directory"));
    }
    // Existence, directory type, physical-path resolution and TCC access are
    // intentionally checked by the bounded PetCore child preflight. Doing any
    // of those filesystem calls in this RPC thread can itself block before the
    // user-facing "检查目录访问" result can be produced.
    Ok(Some(path))
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

fn required_canonical_decimal_u64(params: &Value, key: &str) -> Result<u64> {
    let value = required_string(params, key)?;
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(invalid_params(format!(
            "{key} must be a canonical decimal string"
        )));
    }
    value.parse::<u64>().map_err(|_| {
        invalid_params(format!(
            "{key} must be a canonical decimal string within the u64 range"
        ))
    })
}

fn validate_overlay_placement(placement: &OverlayPlacement) -> Result<()> {
    placement.validate().map_err(invalid_params)
}

fn persist_overlay_placement(
    state: &CoreState,
    placement: OverlayPlacement,
    intent: Option<OverlayPlacementIntent>,
    expected_revision: Option<u64>,
) -> Result<Value> {
    validate_overlay_placement(&placement)?;
    match state.write_overlay_placement(&placement, intent, expected_revision)? {
        OverlayPlacementWriteResult::Updated {
            state_revision,
            projection,
        } => Ok(json!({
            "ok": true,
            "changed": true,
            "revision": state_revision.to_string(),
            "overlay_placement_revision": projection.revision.to_string(),
            "overlay_placement": projection.placement,
            "overlay_placement_intent": projection.intent,
        })),
        OverlayPlacementWriteResult::Unchanged {
            state_revision,
            projection,
        } => Ok(json!({
            "ok": true,
            "changed": false,
            "revision": state_revision.to_string(),
            "overlay_placement_revision": projection.revision.to_string(),
            "overlay_placement": projection.placement,
            "overlay_placement_intent": projection.intent,
        })),
        OverlayPlacementWriteResult::Conflict { projection } => Ok(json!({
            "ok": false,
            "conflict": true,
            "overlay_placement_revision": projection.revision.to_string(),
            "overlay_placement": projection.placement,
            "overlay_placement_intent": projection.intent,
        })),
    }
}

fn should_trigger_event(behavior: &BehaviorSettings, event: &AgentEvent) -> bool {
    behavior.enabled
        && !event_is_diagnostic(event)
        && event_affects_activity(event)
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
        if event_is_diagnostic(event) || !event_affects_activity(event) {
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

    static APP_SERVER_ENV_LOCK: Mutex<()> = Mutex::new(());

    struct RpcEnvGuard {
        key: &'static str,
        original: Option<std::ffi::OsString>,
    }

    impl RpcEnvGuard {
        fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
            let original = std::env::var_os(key);
            std::env::set_var(key, value);
            Self { key, original }
        }
    }

    impl Drop for RpcEnvGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    fn empty_sequenced_event_snapshot(state_revision: u64) -> SnapshotSequencedEvents {
        SnapshotSequencedEvents {
            state_revision,
            events: Arc::new(Vec::new()),
        }
    }

    fn empty_session_projection(state_revision: u64) -> RevisionChecked<SessionMessageProjection> {
        RevisionChecked::Matched {
            state_revision,
            value: SessionMessageProjection::default(),
        }
    }

    fn empty_recent_projection(state_revision: u64) -> RevisionChecked<Vec<AgentEvent>> {
        RevisionChecked::Matched {
            state_revision,
            value: Vec::new(),
        }
    }

    #[test]
    fn snapshot_event_cache_queries_once_per_state_revision() {
        let cache = SnapshotSequencedEventCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);

        let first = cache
            .get_or_try_refresh(
                || Ok(7),
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(empty_sequenced_event_snapshot(7))
                },
            )
            .unwrap();
        let same_revision = cache
            .get_or_try_refresh(
                || Ok(7),
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(empty_sequenced_event_snapshot(7))
                },
            )
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(Arc::ptr_eq(&first.events, &same_revision.events));

        let next_revision = cache
            .get_or_try_refresh(
                || Ok(8),
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(empty_sequenced_event_snapshot(8))
                },
            )
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(next_revision.state_revision, 8);
        assert!(!Arc::ptr_eq(&first.events, &next_revision.events));
    }

    #[test]
    fn core_state_event_snapshot_cache_refreshes_after_persisted_event_revision() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();

        let first = state.snapshot_sequenced_events().unwrap();
        let reused = state.snapshot_sequenced_events().unwrap();
        assert!(Arc::ptr_eq(&first.events, &reused.events));

        let event = exact_codex_state(AgentEventType::Start, &now_rfc3339()).event;
        assert_eq!(
            state.database.insert_event(&event).unwrap(),
            InsertEventOutcome::Inserted
        );
        let refreshed = state.snapshot_sequenced_events().unwrap();
        assert!(refreshed.state_revision > first.state_revision);
        assert!(!Arc::ptr_eq(&first.events, &refreshed.events));
        assert_eq!(refreshed.events[0].event.id, event.id);
    }

    #[test]
    fn fallback_session_title_obeys_character_and_utf8_byte_bounds() {
        let title_for = |message: String| {
            let mut event = exact_codex_state(AgentEventType::Start, &now_rfc3339()).event;
            event.payload_json["message_content"] = json!(message);
            fallback_session_title(&event).expect("fallback title")
        };

        let exact_bytes = "😀".repeat(40);
        assert_eq!(exact_bytes.len(), MAX_SESSION_TITLE_BYTES);
        assert_eq!(title_for(exact_bytes.clone()), exact_bytes);

        let over_bytes = title_for("😀".repeat(41));
        assert!(over_bytes.len() <= MAX_SESSION_TITLE_BYTES);
        assert!(over_bytes.chars().count() <= MAX_FALLBACK_SESSION_TITLE_CHARS);
        assert!(over_bytes.ends_with('…'));
        assert!(std::str::from_utf8(over_bytes.as_bytes()).is_ok());

        let exact_characters = "a".repeat(MAX_FALLBACK_SESSION_TITLE_CHARS);
        assert_eq!(title_for(exact_characters.clone()), exact_characters);

        let over_characters = title_for("a".repeat(MAX_FALLBACK_SESSION_TITLE_CHARS + 1));
        assert_eq!(
            over_characters.chars().count(),
            MAX_FALLBACK_SESSION_TITLE_CHARS
        );
        assert!(over_characters.ends_with('…'));
    }

    #[test]
    fn snapshot_event_cache_deduplicates_concurrent_cold_queries() {
        let cache = Arc::new(SnapshotSequencedEventCache::default());
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let workers = (0..8)
            .map(|_| {
                let cache = Arc::clone(&cache);
                let barrier = Arc::clone(&barrier);
                let calls = Arc::clone(&calls);
                thread::spawn(move || {
                    barrier.wait();
                    cache
                        .get_or_try_refresh(
                            || Ok(11),
                            || {
                                calls.fetch_add(1, Ordering::SeqCst);
                                thread::sleep(Duration::from_millis(25));
                                Ok(empty_sequenced_event_snapshot(11))
                            },
                        )
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();

        let snapshots = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(snapshots
            .windows(2)
            .all(|pair| Arc::ptr_eq(&pair[0].events, &pair[1].events)));
    }

    #[test]
    fn persisted_display_cache_reuses_session_and_recent_events_per_revision() {
        let cache = SnapshotPersistedDisplayCache::default();
        let session_calls = std::sync::atomic::AtomicUsize::new(0);
        let recent_calls = std::sync::atomic::AtomicUsize::new(0);
        let key = SessionDisplayCacheKey {
            source: AgentSource::Opencode,
            session_id: Some("session-1".to_string()),
        };

        cache
            .session_display(7, key.clone(), || {
                session_calls.fetch_add(1, Ordering::SeqCst);
                Ok(empty_session_projection(7))
            })
            .unwrap();
        cache
            .session_display(7, key, || {
                session_calls.fetch_add(1, Ordering::SeqCst);
                Ok(empty_session_projection(7))
            })
            .unwrap();

        let first_recent = cache
            .recent_events(7, || {
                recent_calls.fetch_add(1, Ordering::SeqCst);
                Ok(empty_recent_projection(7))
            })
            .unwrap()
            .unwrap();
        let reused_recent = cache
            .recent_events(7, || {
                recent_calls.fetch_add(1, Ordering::SeqCst);
                Ok(empty_recent_projection(7))
            })
            .unwrap()
            .unwrap();

        assert_eq!(session_calls.load(Ordering::SeqCst), 1);
        assert_eq!(recent_calls.load(Ordering::SeqCst), 1);
        assert!(Arc::ptr_eq(&first_recent, &reused_recent));
    }

    #[test]
    fn persisted_display_cache_refreshes_after_state_revision_changes() {
        let cache = SnapshotPersistedDisplayCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let key = SessionDisplayCacheKey {
            source: AgentSource::Codex,
            session_id: Some("session-1".to_string()),
        };

        for revision in [7, 8] {
            cache
                .session_display(revision, key.clone(), || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(empty_session_projection(revision))
                })
                .unwrap();
        }

        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn persisted_display_cache_deduplicates_concurrent_cold_session_queries() {
        let cache = Arc::new(SnapshotPersistedDisplayCache::default());
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let workers = (0..8)
            .map(|_| {
                let cache = Arc::clone(&cache);
                let barrier = Arc::clone(&barrier);
                let calls = Arc::clone(&calls);
                thread::spawn(move || {
                    barrier.wait();
                    cache
                        .session_display(
                            11,
                            SessionDisplayCacheKey {
                                source: AgentSource::Pi,
                                session_id: Some("session-1".to_string()),
                            },
                            || {
                                calls.fetch_add(1, Ordering::SeqCst);
                                thread::sleep(Duration::from_millis(25));
                                Ok(empty_session_projection(11))
                            },
                        )
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();

        for worker in workers {
            worker.join().unwrap();
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn persisted_display_cache_never_stores_a_revision_mismatch() {
        let cache = SnapshotPersistedDisplayCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let key = SessionDisplayCacheKey {
            source: AgentSource::ClaudeCode,
            session_id: Some("session-1".to_string()),
        };

        let mismatched = cache
            .session_display(7, key.clone(), || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(RevisionChecked::Mismatch {
                    expected_revision: 7,
                    actual_revision: 8,
                })
            })
            .unwrap();
        assert!(mismatched.is_none());

        let matched = cache
            .session_display(7, key, || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(empty_session_projection(7))
            })
            .unwrap();
        assert!(matched.is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn connection_light_status_cache_reuses_until_expiry_and_invalidation() {
        let cache = ConnectionLightStatusCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let started_at = Instant::now();
        let refresh = || {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(Vec::new())
        };

        assert!(cache
            .get_or_try_refresh(started_at, CONNECTION_LIGHT_STATUS_CACHE_TTL, 7, refresh)
            .unwrap()
            .is_empty());
        assert!(cache
            .get_or_try_refresh(
                started_at + Duration::from_secs(299),
                CONNECTION_LIGHT_STATUS_CACHE_TTL,
                7,
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(Vec::new())
                },
            )
            .unwrap()
            .is_empty());
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        cache
            .get_or_try_refresh(
                started_at + Duration::from_secs(299),
                CONNECTION_LIGHT_STATUS_CACHE_TTL,
                8,
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(Vec::new())
                },
            )
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        cache
            .get_or_try_refresh(
                started_at + Duration::from_secs(599),
                CONNECTION_LIGHT_STATUS_CACHE_TTL,
                8,
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(Vec::new())
                },
            )
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 3);

        cache.invalidate();
        cache
            .get_or_try_refresh(
                started_at + Duration::from_secs(600),
                CONNECTION_LIGHT_STATUS_CACHE_TTL,
                8,
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(Vec::new())
                },
            )
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn connection_light_status_cache_deduplicates_concurrent_cold_refreshes() {
        let cache = Arc::new(ConnectionLightStatusCache::default());
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let started_at = Instant::now();
        let workers = (0..8)
            .map(|_| {
                let cache = Arc::clone(&cache);
                let barrier = Arc::clone(&barrier);
                let calls = Arc::clone(&calls);
                thread::spawn(move || {
                    barrier.wait();
                    cache
                        .get_or_try_refresh(
                            started_at,
                            CONNECTION_LIGHT_STATUS_CACHE_TTL,
                            1,
                            || {
                                calls.fetch_add(1, Ordering::SeqCst);
                                thread::sleep(Duration::from_millis(25));
                                Ok(Vec::new())
                            },
                        )
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();

        for worker in workers {
            assert!(worker.join().unwrap().is_empty());
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn agent_parse_warning_rpc_logs_only_closed_categories() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let result = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!(1)),
                method: "agent.parse_warnings".to_string(),
                params: json!({
                    "source": "pi",
                    "warnings": [{
                        "field": "message_content",
                        "failure": "unsupported_shape"
                    }]
                }),
            },
        )
        .unwrap();
        assert_eq!(result["recorded"], 1);
        state.diagnostics.sync();

        let records = std::fs::read_to_string(state.paths.logs_dir.join("petcore.jsonl")).unwrap();
        let warning = records
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|record| record.get("event").and_then(Value::as_str) == Some("parse_warning"))
            .expect("parse warning log");
        assert_eq!(warning["metadata"]["source"], "pi");
        assert_eq!(warning["metadata"]["field"], "message_content");
        assert_eq!(warning["metadata"]["failure"], "unsupported_shape");
        assert_eq!(warning["metadata"].as_object().unwrap().len(), 3);
    }

    #[test]
    fn inserted_evidence_is_coalesced_without_dirtying_the_static_scan() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: Vec::new(),
            install_paths: Vec::new(),
            connector_installed: false,
            verification: petcore_types::AgentVerification::default(),
            capabilities: petcore_types::AgentConnectorCapabilities::default(),
            check_mode: petcore_types::ConnectionCheckMode::Light,
            checked_at: now_rfc3339(),
        };
        let static_calls = std::sync::atomic::AtomicUsize::new(0);
        let evidence_calls = std::sync::atomic::AtomicUsize::new(0);
        let started_at = Instant::now();

        state
            .connection_light_status_cache
            .get_or_try_refresh(started_at, CONNECTION_LIGHT_STATUS_CACHE_TTL, 7, || {
                static_calls.fetch_add(1, Ordering::SeqCst);
                Ok(vec![status.clone()])
            })
            .unwrap();
        state
            .connection_evidence_projection_cache
            .get_or_try_refresh(
                started_at,
                CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                7,
                &status,
                || {
                    evidence_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(status.clone())
                },
            )
            .unwrap();

        let event = AgentEvent {
            id: "evt_pi_evidence_cache_dirty".to_string(),
            source: AgentSource::Pi,
            project_path: None,
            session_id: Some("pi-evidence-cache".to_string()),
            event_type: AgentEventType::Start,
            title: AgentEventType::Start.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "source_event": "input",
                "contract_version": connections::contract_version_for_source(AgentSource::Pi),
                "diagnostic": false,
                "affects_activity": true,
                "session_active": true
            }),
            created_at: now_rfc3339(),
        };
        ingest_event(&state, event).unwrap();

        state
            .connection_light_status_cache
            .get_or_try_refresh(
                started_at + Duration::from_secs(1),
                CONNECTION_LIGHT_STATUS_CACHE_TTL,
                7,
                || {
                    static_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(vec![status.clone()])
                },
            )
            .unwrap();
        state
            .connection_evidence_projection_cache
            .get_or_try_refresh(
                started_at + Duration::from_secs(1),
                CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                7,
                &status,
                || {
                    evidence_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(status.clone())
                },
            )
            .unwrap();

        assert_eq!(static_calls.load(Ordering::SeqCst), 1);
        assert_eq!(evidence_calls.load(Ordering::SeqCst), 1);

        state
            .connection_evidence_projection_cache
            .get_or_try_refresh(
                started_at + CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                7,
                &status,
                || {
                    evidence_calls.fetch_add(1, Ordering::SeqCst);
                    Ok(status.clone())
                },
            )
            .unwrap();
        assert_eq!(evidence_calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn evidence_projection_coalesces_a_ten_thousand_event_burst() {
        let cache = ConnectionEvidenceProjectionCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let started_at = Instant::now();
        let status = AgentConnectionStatus {
            source: AgentSource::Codex,
            items: Vec::new(),
            install_paths: Vec::new(),
            connector_installed: true,
            verification: petcore_types::AgentVerification::default(),
            capabilities: petcore_types::AgentConnectorCapabilities::default(),
            check_mode: petcore_types::ConnectionCheckMode::Runtime,
            checked_at: now_rfc3339(),
        };

        cache
            .get_or_try_refresh(
                started_at,
                CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                1,
                &status,
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(status.clone())
                },
            )
            .unwrap();

        for offset in 0..10_000_u64 {
            cache.mark_dirty(AgentSource::Codex);
            cache
                .get_or_try_refresh(
                    started_at + Duration::from_micros(offset % 1_000),
                    CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                    1,
                    &status,
                    || {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Ok(status.clone())
                    },
                )
                .unwrap();
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        cache
            .get_or_try_refresh(
                started_at + CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                CONNECTION_EVIDENCE_REFRESH_COALESCE_WINDOW,
                1,
                &status,
                || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(status.clone())
                },
            )
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn cold_evidence_projection_performs_one_strict_freshness_load_after_fast_merge() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let light = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: Vec::new(),
            install_paths: Vec::new(),
            connector_installed: false,
            verification: petcore_types::AgentVerification::default(),
            capabilities: petcore_types::AgentConnectorCapabilities::default(),
            check_mode: petcore_types::ConnectionCheckMode::Light,
            checked_at: now_rfc3339(),
        };

        connections::reset_connector_receipt_freshness_load_count();
        let mut merged = merge_cached_connection_statuses(&state.paths, vec![light], Vec::new());
        assert_eq!(merged.len(), 1);
        let status = merged.pop().unwrap();
        assert_eq!(connections::connector_receipt_freshness_load_count(), 0);

        let _projected = connections::project_connection_evidence(&state.paths, &status);
        assert_eq!(
            connections::connector_receipt_freshness_load_count(),
            1,
            "a dirty/cold evidence projection must perform exactly one strict artifact load after metadata-gated merge"
        );
    }

    #[test]
    fn connection_operations_and_host_processes_share_cross_clone_gates() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        let clone = state.clone();

        let operation = state.begin_connection_operation().unwrap();
        assert!(clone.begin_connection_operation().is_err());
        drop(operation);
        let next_operation = clone.begin_connection_operation().unwrap();
        drop(next_operation);

        let host = state.agent_host_process_guard();
        assert!(clone.agent_host_process_gate.try_lock().is_err());
        drop(host);
        assert!(clone.agent_host_process_gate.try_lock().is_ok());
    }

    #[test]
    fn live_codex_display_read_does_not_wait_behind_background_host_work() {
        use std::os::unix::fs::PermissionsExt;

        let _environment = APP_SERVER_ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join("live-display.sh");
        std::fs::write(
            &script,
            r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"live-display-test"}}}'
      ;;
    *\"method\":\"thread/read\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"name":"Live task","turns":[{"items":[{"type":"reasoning","summary":["Fresh reasoning"]}]}]}}}'
      ;;
  esac
done
"#,
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _command = RpcEnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();

        let background_host_work = state.agent_host_process_guard();
        assert!(state
            .codex_thread_display("019f5a6f-0c52-75e1-b652-004d4487c4ae", "turn-1", 0,)
            .is_none());

        // The host-process gate remains held for this entire budget, so a
        // serialized refresh still cannot pass; the wider bound only absorbs
        // App Server process startup contention in the full parallel suite.
        let deadline = Instant::now() + Duration::from_secs(4);
        let mut completed_while_background_work_was_blocked = false;
        while Instant::now() < deadline {
            completed_while_background_work_was_blocked = state
                .codex_thread_display_cache
                .lock()
                .unwrap()
                .entries
                .get("019f5a6f-0c52-75e1-b652-004d4487c4ae")
                .and_then(|entry| entry.display.as_ref())
                .is_some_and(|display| {
                    display.latest_activity.as_ref().is_some_and(|activity| {
                        activity.content.as_deref() == Some("Fresh reasoning")
                    })
                });
            if completed_while_background_work_was_blocked {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        drop(background_host_work);
        assert!(
            completed_while_background_work_was_blocked,
            "live session display was serialized behind unrelated background App Server work"
        );
    }

    #[test]
    fn state_wait_wakes_immediately_for_a_completed_display_refresh() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let after_revision = state.database.state_revision().unwrap().to_string();
        let display_epoch = Arc::clone(&state.codex_display_epoch);
        let refresh = thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            display_epoch.fetch_add(1, Ordering::Release);
        });

        let started_at = Instant::now();
        let result = wait_for_state_change(
            &state,
            &json!({
                "after_revision": after_revision,
                "timeout_ms": 600
            }),
        )
        .unwrap();
        let elapsed = started_at.elapsed();
        refresh.join().unwrap();

        assert_eq!(result["changed"], true);
        assert!(
            elapsed < Duration::from_millis(400),
            "display refresh remained hidden until the state wait timeout: {elapsed:?}"
        );
    }

    fn skipped_refresh_result(source: AgentSource) -> connections::InstalledSourceRefreshResult {
        connections::InstalledSourceRefreshResult {
            source,
            status: connections::InstalledSourceRefreshStatus::SkippedNotManaged,
            managed: false,
            refreshed: false,
            ok: true,
            verified: false,
            expected_version: None,
            active_version: None,
            expected_skills_sha256: None,
            active_skills_sha256: None,
            expected_content_sha256: None,
            managed_source_content_sha256: None,
            active_content_sha256: None,
            detail: "not managed".to_string(),
            error: None,
        }
    }

    fn managed_static_refresh_result(
        source: AgentSource,
    ) -> connections::InstalledSourceRefreshResult {
        let version = RuntimeReleaseManifest::compiled().app_version;
        connections::InstalledSourceRefreshResult {
            source,
            status: connections::InstalledSourceRefreshStatus::Current,
            managed: true,
            refreshed: true,
            ok: true,
            verified: true,
            expected_version: Some(version.clone()),
            active_version: Some(version),
            expected_skills_sha256: None,
            active_skills_sha256: None,
            expected_content_sha256: None,
            managed_source_content_sha256: None,
            active_content_sha256: None,
            detail: "current and verified".to_string(),
            error: None,
        }
    }

    fn complete_convergence_report(paths: &AppPaths) -> connections::InstalledSourcesRefreshReport {
        let (version, skills_digest, content_digest) =
            connections::compiled_codex_plugin_identity(paths).unwrap();
        let codex = connections::InstalledSourceRefreshResult {
            source: AgentSource::Codex,
            status: connections::InstalledSourceRefreshStatus::Updated,
            managed: true,
            refreshed: true,
            ok: true,
            verified: true,
            expected_version: Some(version.clone()),
            active_version: Some(version),
            expected_skills_sha256: Some(skills_digest.clone()),
            active_skills_sha256: Some(skills_digest),
            expected_content_sha256: Some(content_digest.clone()),
            managed_source_content_sha256: Some(content_digest.clone()),
            active_content_sha256: Some(content_digest),
            detail: "updated and verified".to_string(),
            error: None,
        };
        connections::InstalledSourcesRefreshReport {
            ok: true,
            results: vec![
                codex,
                skipped_refresh_result(AgentSource::ClaudeCode),
                skipped_refresh_result(AgentSource::Pi),
                skipped_refresh_result(AgentSource::Opencode),
            ],
        }
    }

    fn convergence_update_request(
        connector_report: connections::InstalledSourcesRefreshReport,
    ) -> RpcRequest {
        let runtime = RuntimeReleaseManifest::compiled();
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("product-convergence")),
            method: "product.convergence.update".to_string(),
            params: json!({
                "schema_version": PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION,
                "build_id": runtime.build_id,
                "app_version": runtime.app_version,
                "connector_report": connector_report,
            }),
        }
    }

    #[test]
    fn product_convergence_update_persists_only_a_complete_current_runtime_receipt() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();

        let empty = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("product-convergence-get-empty")),
                method: "product.convergence.get".to_string(),
                params: json!({}),
            },
        )
        .unwrap();
        assert_eq!(empty, Value::Null);

        let updated = handle_request(
            &state,
            convergence_update_request(complete_convergence_report(&state.paths)),
        )
        .unwrap();
        assert_eq!(
            updated["schema_version"],
            PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION
        );
        assert_eq!(
            updated["build_id"],
            RuntimeReleaseManifest::compiled().build_id
        );
        assert_eq!(updated["connector_report_summary"]["total_sources"], 4);
        assert_eq!(updated["connector_report_summary"]["managed_sources"], 1);
        assert_eq!(updated["connector_report_summary"]["verified_sources"], 1);
        assert_eq!(updated["connector_report_summary"]["skipped_sources"], 3);
        assert_eq!(
            updated["connector_report_summary"]["codex_skills_sha256"],
            connections::compiled_codex_plugin_identity(&state.paths)
                .unwrap()
                .1
        );
        assert_eq!(
            updated["connector_report_summary"]["codex_content_sha256"],
            connections::compiled_codex_plugin_identity(&state.paths)
                .unwrap()
                .2
        );

        let loaded = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("product-convergence-get")),
                method: "product.convergence.get".to_string(),
                params: json!({}),
            },
        )
        .unwrap();
        assert_eq!(loaded, updated);
    }

    #[test]
    fn product_convergence_accepts_current_release_for_managed_static_connectors() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let mut report = complete_convergence_report(&state.paths);
        report.results[1] = managed_static_refresh_result(AgentSource::ClaudeCode);
        report.results[2] = managed_static_refresh_result(AgentSource::Pi);
        report.results[3] = managed_static_refresh_result(AgentSource::Opencode);

        let updated =
            handle_request(&state, convergence_update_request(report)).expect("current report");

        assert_eq!(updated["connector_report_summary"]["managed_sources"], 4);
        assert_eq!(updated["connector_report_summary"]["verified_sources"], 4);
        assert_eq!(updated["connector_report_summary"]["skipped_sources"], 0);
    }

    #[test]
    fn product_convergence_update_rejects_stale_identity_and_incomplete_reports() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();

        let mut stale = convergence_update_request(complete_convergence_report(&state.paths));
        stale.params["build_id"] = json!("stale-build");
        assert!(matches!(
            handle_request(&state, stale),
            Err(PetCoreError::Conflict(_))
        ));

        let mut wrong_digest = complete_convergence_report(&state.paths);
        let forged = Some("d".repeat(64));
        wrong_digest.results[0].expected_content_sha256 = forged.clone();
        wrong_digest.results[0].managed_source_content_sha256 = forged.clone();
        wrong_digest.results[0].active_content_sha256 = forged;
        assert!(matches!(
            handle_request(&state, convergence_update_request(wrong_digest)),
            Err(PetCoreError::InvalidRequest(_))
        ));

        let mut wrong_static_version = complete_convergence_report(&state.paths);
        wrong_static_version.results[1] = managed_static_refresh_result(AgentSource::ClaudeCode);
        wrong_static_version.results[1].active_version = Some("0.0.0".to_string());
        assert!(matches!(
            handle_request(&state, convergence_update_request(wrong_static_version)),
            Err(PetCoreError::InvalidRequest(_))
        ));

        let mut static_digest = complete_convergence_report(&state.paths);
        static_digest.results[2] = managed_static_refresh_result(AgentSource::Pi);
        static_digest.results[2].expected_content_sha256 = Some("d".repeat(64));
        assert!(matches!(
            handle_request(&state, convergence_update_request(static_digest)),
            Err(PetCoreError::InvalidRequest(_))
        ));

        let mut incomplete = complete_convergence_report(&state.paths);
        incomplete.results[0].status = connections::InstalledSourceRefreshStatus::PendingHost;
        incomplete.results[0].ok = false;
        incomplete.results[0].verified = false;
        incomplete.results[0].error = Some("host unavailable".to_string());
        assert!(matches!(
            handle_request(&state, convergence_update_request(incomplete)),
            Err(PetCoreError::InvalidRequest(_))
        ));
        assert_eq!(state.database.product_convergence_receipt().unwrap(), None);
    }

    #[test]
    fn product_convergence_update_denies_unknown_nested_report_fields() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();

        let mut request = convergence_update_request(complete_convergence_report(&state.paths));
        request.params["connector_report"]["results"][0]["unexpected"] = json!(true);
        assert!(matches!(
            handle_request(&state, request),
            Err(PetCoreError::InvalidRequest(_))
        ));
    }

    #[test]
    fn product_convergence_preflight_reads_generation_and_connection_activity_without_host_gate() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let preflight = || {
            handle_request(
                &state,
                RpcRequest {
                    jsonrpc: Some("2.0".to_string()),
                    id: Some(json!("product-convergence-preflight")),
                    method: "product.convergence.preflight".to_string(),
                    params: json!({}),
                },
            )
            .unwrap()
        };

        assert_eq!(
            preflight(),
            json!({
                "safe": true,
                "active_generation": false,
                "active_generation_status": null,
                "connection_operation_active": false,
                "runtime_replacement_safe": true,
            })
        );

        let host_guard = state.agent_host_process_guard();
        assert_eq!(preflight()["safe"], true);
        drop(host_guard);

        let operation = state.begin_connection_operation().unwrap();
        assert_eq!(
            preflight(),
            json!({
                "safe": false,
                "active_generation": false,
                "active_generation_status": null,
                "connection_operation_active": true,
                "runtime_replacement_safe": false,
            })
        );
        drop(operation);

        let form = GenerationForm {
            description: "preflight".to_string(),
            style: "pixel".to_string(),
            quality: QualityLevel::Standard,
            reference_images: Vec::new(),
        };
        let job_dir = state.paths.jobs_dir.join("preflight-active-generation");
        std::fs::create_dir_all(&job_dir).unwrap();
        state
            .database
            .create_generation_job("preflight-active-generation", &form, &job_dir)
            .unwrap();
        assert_eq!(
            preflight(),
            json!({
                "safe": false,
                "active_generation": true,
                "active_generation_status": "pending",
                "connection_operation_active": false,
                "runtime_replacement_safe": false,
            })
        );
        state
            .database
            .update_generation_job(
                "preflight-active-generation",
                GenerationJobStatus::WaitingForUser,
                None,
            )
            .unwrap();
        assert_eq!(
            preflight(),
            json!({
                "safe": false,
                "active_generation": true,
                "active_generation_status": "waiting_for_user",
                "connection_operation_active": false,
                "runtime_replacement_safe": true,
            })
        );
        state
            .database
            .mark_generation_recoverable_failure(
                "preflight-active-generation",
                "checkpoint_paused",
                "recoverable checkpoint",
            )
            .unwrap();
        assert_eq!(
            preflight(),
            json!({
                "safe": false,
                "active_generation": true,
                "active_generation_status": "failed",
                "connection_operation_active": false,
                "runtime_replacement_safe": true,
            })
        );
    }

    #[test]
    fn capability_refresh_and_new_generation_admission_are_mutually_exclusive() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();
        let generation_request = || RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("generation-during-refresh")),
            method: "generation.start".to_string(),
            params: json!({
                "description": "admission gate",
                "style": "pixel",
                "quality": "standard",
                "reference_images": [],
            }),
        };

        let connection_operation = state.begin_connection_operation().unwrap();
        assert!(matches!(
            handle_request(&state, generation_request()),
            Err(PetCoreError::Conflict(_))
        ));
        drop(connection_operation);

        let form = GenerationForm {
            description: "active before refresh".to_string(),
            style: "pixel".to_string(),
            quality: QualityLevel::Standard,
            reference_images: Vec::new(),
        };
        let job_dir = state.paths.jobs_dir.join("active-before-refresh");
        std::fs::create_dir_all(&job_dir).unwrap();
        state
            .database
            .create_generation_job("active-before-refresh", &form, &job_dir)
            .unwrap();
        assert!(matches!(
            handle_request(
                &state,
                RpcRequest {
                    jsonrpc: Some("2.0".to_string()),
                    id: Some(json!("refresh-during-generation")),
                    method: "connections.refresh_installed".to_string(),
                    params: json!({}),
                },
            ),
            Err(PetCoreError::Conflict(_))
        ));
    }

    #[test]
    fn connection_test_uses_the_same_serial_operation_gate() {
        let temp = tempfile::tempdir().unwrap();
        let state = CoreState::new(AppPaths::new(temp.path().join("app-home")));
        state.ensure_ready().unwrap();

        let active = state.begin_connection_operation().unwrap();
        let error = handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("connection-test-gate")),
                method: "connections.test".to_string(),
                params: json!({ "source": "codex" }),
            },
        )
        .unwrap_err();
        assert!(matches!(error, PetCoreError::Conflict(_)));

        drop(active);
        assert!(handle_request(
            &state,
            RpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!("connection-test-after-gate")),
                method: "connections.test".to_string(),
                params: json!({ "source": "codex" }),
            },
        )
        .is_ok());
    }

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
            session_alias_sequence: Some(1),
            session_activated_at: None,
            session_first_seen_at: None,
            latest_terminal_navigation_payload: None,
            completion_epoch_event_ids: Vec::new(),
            preferred_app_navigation_payload: None,
            tool_activity_run_marker: None,
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

    fn codex_navigation_hook(
        surface: &str,
        terminal_app: Option<&str>,
        open_url: Option<&str>,
        turn_id: &str,
    ) -> agent_state::SequencedAgentEvent {
        let mut event = exact_codex_state(AgentEventType::Tool, "2025-07-13T12:26:30Z");
        event.event.payload_json = json!({
            "source_event": "PreToolUse",
            "turn_id": turn_id,
            "session_active": true,
            "session_open": true,
            "session_surface": surface,
            "terminal_app": terminal_app,
            "session_open_url": open_url,
            "activity_kind": "command",
            "activity_content": "swift test"
        });
        event
    }

    fn codex_navigation_history(
        marker: Option<agent_state::SequencedAgentEvent>,
        has_any_trusted_marker: bool,
    ) -> CodexRuntimeSurfaceHistory {
        CodexRuntimeSurfaceHistory {
            has_any_trusted_marker,
            latest_current_turn_marker: marker,
        }
    }

    #[test]
    fn cli_app_server_activity_preserves_same_turn_hook_navigation_provenance() {
        let mut activity = inferred_codex_tool(1_752_409_560);
        activity.session_surface = "cli_terminal".to_string();
        activity.latest_activity = Some(app_server::CodexThreadDisplayActivity {
            kind: "command".to_string(),
            content: Some("cargo test --workspace".to_string()),
            is_current: true,
        });
        let warp_url = "warp://session/0123456789abcdef0123456789abcdef";
        let hook = codex_navigation_hook("cli_terminal", Some("warp"), Some(warp_url), "turn-1");
        let events = codex_activity_events(activity, &codex_navigation_history(Some(hook), true));
        let status = events.last().unwrap();

        assert_eq!(status.payload_json["session_surface"], "cli_terminal");
        assert_eq!(status.payload_json["terminal_app"], "warp");
        assert_eq!(status.payload_json["session_open_url"], warp_url);
        assert_eq!(
            status.payload_json["activity_content"],
            "cargo test --workspace"
        );
        let navigation = agent_state::overlay_navigation(status);
        assert_eq!(
            navigation.capability,
            agent_state::OverlayNavigationCapability::ExactSession
        );
        assert_eq!(navigation.open_url.as_deref(), Some(warp_url));
    }

    #[test]
    fn codex_app_and_cli_surface_transitions_never_cross_inherit_navigation() {
        let cli_hook = codex_navigation_hook("cli_terminal", Some("iterm2"), None, "turn-1");
        let mut app_activity = inferred_codex_tool(1_752_409_560);
        app_activity.session_surface = "chatgpt_app".to_string();
        let app_status = codex_activity_events(
            app_activity,
            &codex_navigation_history(Some(cli_hook.clone()), true),
        )
        .pop()
        .unwrap();
        assert_eq!(app_status.payload_json["session_surface"], "cli_terminal");
        assert_eq!(app_status.payload_json["terminal_app"], "iterm2");
        assert!(app_status.payload_json["session_open_url"].is_null());

        let mut app_hook = codex_navigation_hook("chatgpt_app", None, None, "turn-1");
        app_hook.source_session_sequence = 2;
        let mut cli_activity = inferred_codex_tool(1_752_409_560);
        cli_activity.session_surface = "cli_terminal".to_string();
        let cli_status = codex_activity_events(
            cli_activity,
            &codex_navigation_history(Some(app_hook), true),
        )
        .pop()
        .unwrap();
        assert_eq!(cli_status.payload_json["session_surface"], "chatgpt_app");
        assert!(cli_status.payload_json["terminal_app"].is_null());
        assert!(cli_status.payload_json["session_open_url"].is_null());
        assert_eq!(
            agent_state::overlay_navigation(&cli_status).capability,
            agent_state::OverlayNavigationCapability::ExactSession
        );
    }

    #[test]
    fn codex_runtime_navigation_is_stable_for_ambiguous_polls_and_new_hooks_override() {
        let mut activity = inferred_codex_tool(1_752_409_560);
        activity.session_surface = "cli_terminal".to_string();
        let warp_url = "warp://session/0123456789abcdef0123456789abcdef";
        let hook = codex_navigation_hook("cli_terminal", Some("warp"), Some(warp_url), "turn-1");
        let current = codex_navigation_history(Some(hook), true);
        let first_status = codex_activity_events(activity.clone(), &current)
            .pop()
            .unwrap();
        assert_eq!(first_status.payload_json["session_surface"], "cli_terminal");
        assert_eq!(first_status.payload_json["terminal_app"], "warp");
        assert_eq!(first_status.payload_json["session_open_url"], warp_url);
        assert!(first_status
            .payload_json
            .get("runtime_surface_origin")
            .is_none());

        let mut app_hook = codex_navigation_hook("chatgpt_app", None, None, "turn-1");
        app_hook.source_session_sequence = 3;
        let overridden = codex_activity_events(
            activity.clone(),
            &codex_navigation_history(Some(app_hook), true),
        )
        .pop()
        .unwrap();
        assert_eq!(overridden.payload_json["session_surface"], "chatgpt_app");
        assert!(overridden.payload_json["terminal_app"].is_null());
        assert!(overridden.payload_json["session_open_url"].is_null());

        activity.turn_id = Some("turn-2".to_string());
        let ambiguous = codex_navigation_history(None, true);
        for _ in 0..3 {
            let status = codex_activity_events(activity.clone(), &ambiguous)
                .pop()
                .unwrap();
            assert_eq!(status.payload_json["session_surface"], "unknown");
            assert!(status.payload_json["terminal_app"].is_null());
            assert!(status.payload_json["session_open_url"].is_null());
            assert_eq!(
                agent_state::overlay_navigation(&status).capability,
                agent_state::OverlayNavigationCapability::Unavailable
            );
        }

        let new_hook = codex_navigation_hook("cli_terminal", Some("iterm2"), None, "turn-2");
        let recovered =
            codex_activity_events(activity, &codex_navigation_history(Some(new_hook), true))
                .pop()
                .unwrap();
        assert_eq!(recovered.payload_json["session_surface"], "cli_terminal");
        assert_eq!(recovered.payload_json["terminal_app"], "iterm2");
        assert_eq!(
            agent_state::overlay_navigation(&recovered).capability,
            agent_state::OverlayNavigationCapability::AgentHost
        );
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
    fn lossy_thinking_does_not_replace_current_pre_tool_command() {
        let mut activity = inferred_codex_tool(1_752_409_560);
        activity.event_type = AgentEventType::Start;
        activity.latest_activity = Some(generic_codex_activity("thinking"));
        let mut command = exact_codex_state(AgentEventType::Tool, "2025-07-13T12:27:00Z");
        command.event.payload_json = json!({
            "source_event": "PreToolUse",
            "turn_id": "turn-1",
            "activity_kind": "command",
            "session_active": true
        });
        assert!(should_preserve_exact_codex_state(&[command], &activity));
    }

    #[test]
    fn current_concrete_reasoning_supersedes_an_older_same_turn_tool_hook() {
        let mut activity = inferred_codex_tool(1_752_409_560);
        activity.event_type = AgentEventType::Start;
        activity.latest_activity = Some(app_server::CodexThreadDisplayActivity {
            kind: "thinking".to_string(),
            content: Some("Planning hover-based visibility control".to_string()),
            is_current: true,
        });
        activity.display_revision = "turn-1:reasoning-2:inProgress".to_string();
        let mut command = exact_codex_state(AgentEventType::Tool, "2025-07-13T12:27:00Z");
        command.event.payload_json = json!({
            "source_event": "PreToolUse",
            "turn_id": "turn-1",
            "activity_kind": "command",
            "activity_content": "{\"command\":\"swift test\"}",
            "session_active": true
        });

        assert!(!should_preserve_exact_codex_state(&[command], &activity));
    }

    #[test]
    fn app_server_status_still_requires_direct_live_display_hydration() {
        let mut active = exact_codex_state(AgentEventType::Start, "2025-07-13T12:27:00Z");
        active.event.payload_json = json!({
            "source_event": "app_server_activity",
            "turn_id": "turn-1",
            "session_active": true
        });

        assert!(should_hydrate_codex_thread_display(
            active.event.source,
            active.event.session_id.as_deref()
        ));
        assert_eq!(CODEX_ACTIVE_THREAD_DISPLAY_REFRESH_SECONDS, 1);
    }

    #[test]
    fn hydrated_current_reasoning_replaces_older_tool_but_not_with_empty_inference() {
        let current = agent_state::SessionActivity {
            kind: "tool".to_string(),
            content: Some("swift test".to_string()),
        };
        let concrete_reasoning = app_server::CodexThreadDisplayActivity {
            kind: "thinking".to_string(),
            content: Some("Planning hover-based visibility control".to_string()),
            is_current: true,
        };
        let inferred_reasoning = app_server::CodexThreadDisplayActivity {
            kind: "thinking".to_string(),
            content: None,
            is_current: true,
        };

        assert!(should_replace_hydrated_codex_activity(
            Some(&current),
            &concrete_reasoning
        ));
        assert!(!should_replace_hydrated_codex_activity(
            Some(&current),
            &inferred_reasoning
        ));
    }

    #[test]
    fn lossy_codex_updates_preserve_the_latest_concrete_activity_detail() {
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
        assert_eq!(activity.event_type, AgentEventType::Thinking);

        activity.updated_at_unix += 1;
        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .map(|value| value.kind.as_str()),
            Some("thinking")
        );
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .and_then(|value| value.content.as_ref()),
            Some(&"Assessing manual length and detail".to_string())
        );
        assert_eq!(activity.event_type, AgentEventType::Thinking);

        reconcile_codex_activity_observation(&mut observations, &mut activity);
        assert_eq!(
            activity
                .latest_activity
                .as_ref()
                .map(|value| value.kind.as_str()),
            Some("thinking")
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
        assert_eq!(activity.latest_activity, None);
        assert_eq!(activity.event_type, AgentEventType::Start);
    }

    #[test]
    fn codex_status_event_id_is_stable_when_activity_kind_changes() {
        let mut activity = inferred_codex_tool(1_752_409_560);
        let tool_id =
            codex_activity_events(activity.clone(), &CodexRuntimeSurfaceHistory::default())
                .last()
                .expect("tool status")
                .id
                .clone();
        activity.event_type = AgentEventType::Start;
        activity.latest_activity = Some(generic_codex_activity("thinking"));
        let thinking_id = codex_activity_events(activity, &CodexRuntimeSurfaceHistory::default())
            .last()
            .expect("thinking status")
            .id
            .clone();
        assert_eq!(tool_id, thinking_id);
    }

    #[test]
    fn disappearing_unarchived_codex_thread_closes_its_stale_active_projection() {
        let mut observations = BTreeMap::new();
        let mut activity = inferred_codex_tool(1_752_409_560);
        reconcile_codex_activity_observation(&mut observations, &mut activity);

        let events =
            disappeared_codex_activity_events(&observations, &BTreeSet::new(), 1_752_409_600);

        assert_eq!(events.len(), 1);
        let event = &events[0];
        assert_eq!(event.event_type, AgentEventType::Done);
        assert_eq!(
            event.session_id.as_deref(),
            Some("00000000-0000-0000-0000-000000000001")
        );
        assert_eq!(
            event
                .payload_json
                .get("session_active")
                .and_then(Value::as_bool),
            Some(false)
        );
        assert_eq!(
            event
                .payload_json
                .get("session_open")
                .and_then(Value::as_bool),
            Some(false)
        );
    }

    #[test]
    fn listed_codex_thread_is_not_closed_when_its_detail_refresh_is_partial() {
        let mut observations = BTreeMap::new();
        let mut activity = inferred_codex_tool(1_752_409_560);
        reconcile_codex_activity_observation(&mut observations, &mut activity);
        let listed_threads = BTreeSet::from([activity.thread_id]);

        let events =
            disappeared_codex_activity_events(&observations, &listed_threads, 1_752_409_600);

        assert!(events.is_empty());
    }
}
