mod agents;
mod connection;
mod generation;
mod migrations;
mod pets;
mod settings;

use crate::adapter_contracts::CODEX_HOOKS_CONTRACT_VERSION;
use crate::agent_session_filters::{
    is_codex_internal_suggestions_payload, suppressed_agent_session_reason,
    CODEX_INTERNAL_SUGGESTIONS_REASON, PET_STUDIO_INTERNAL_SESSION_REASON,
};
use crate::agent_state::{is_valid_session_acknowledgement_id, SequencedAgentEvent};
use crate::event_envelope::{
    minimal_legacy_payload, normalized_session_id, normalized_session_key, persisted_payload,
    source_event_proves_ordinary_activity, validated_warp_focus_url, MAX_RECENT_EVENTS,
};
use crate::{enum_from_name, enum_name, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentEvent, AgentEventType, AgentSource, AppearanceTheme,
    BehaviorSettings, BubbleFontScale, GenerationForm, GenerationJobStatus,
    GenerationMessagePayload, GenerationMessageRecord, InterfaceLanguage, OnboardingProgress,
    OnboardingStage, OverlayPlacement, OverlayPlacementIntent, PetOrigin, PetState, PetSummary,
    QualityLevel, RenderSize, SessionGroupDisplay, DEFAULT_OVERLAY_DISPLAY_WIDTH_PT,
    MAX_SESSION_MESSAGE_TIMEOUT_MINUTES, MIN_OVERLAY_DISPLAY_WIDTH_PT,
    MIN_SESSION_MESSAGE_TIMEOUT_MINUTES, ONBOARDING_PROGRESS_SCHEMA_VERSION, REQUIRED_STATES,
};
use rusqlite::{params, Connection, ErrorCode, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DATABASE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const PET_REVISION_DATABASE_COMMIT_ATTEMPTS: usize = 3;
const PET_REVISION_DATABASE_RETRY_DELAY: Duration = Duration::from_millis(100);
const MAX_GENERATION_HISTORY_QUERY_LIMIT: usize = 33;
const MAX_GENERATION_MESSAGE_PAGE_LIMIT: usize = 200;
const ONBOARDING_PROGRESS_SETTING_KEY: &str = "onboarding_progress";
const OVERLAY_PLACEMENT_SETTING_KEY: &str = "overlay_placement";
const OVERLAY_PLACEMENT_INTENT_SETTING_KEY: &str = "overlay_placement_intent";
const LEGACY_MIN_OVERLAY_DISPLAY_WIDTH_PT: f64 = 80.0;
const LEGACY_MAX_OVERLAY_DISPLAY_WIDTH_PT: f64 = 224.0;
const AGENT_SESSION_ACKNOWLEDGEMENTS_SETTING_KEY: &str = "agent_session_acknowledgements";
const AGENT_SESSION_ACKNOWLEDGEMENTS_SCHEMA_VERSION: &str = "apc.agent-session-acknowledgements.v1";
const MAX_AGENT_SESSION_ACKNOWLEDGEMENTS: usize = 1_024;
pub const PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION: &str = "apc.product-convergence-receipt.v1";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyOverlayPlacement {
    x: f64,
    y: f64,
    scale: f64,
    display_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentSessionAcknowledgements {
    schema_version: String,
    ids: Vec<String>,
}

impl Default for AgentSessionAcknowledgements {
    fn default() -> Self {
        Self {
            schema_version: AGENT_SESSION_ACKNOWLEDGEMENTS_SCHEMA_VERSION.to_string(),
            ids: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProductConvergenceConnectorSummary {
    pub total_sources: u32,
    pub managed_sources: u32,
    pub verified_sources: u32,
    pub skipped_sources: u32,
    pub report_sha256: String,
    pub codex_skills_sha256: Option<String>,
    pub codex_content_sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProductConvergenceReceipt {
    pub schema_version: String,
    pub build_id: String,
    pub app_version: String,
    pub completed_at: String,
    pub connector_report_summary: ProductConvergenceConnectorSummary,
}

#[derive(Debug, Clone)]
pub struct GenerationJobRecord {
    pub id: String,
    pub status: GenerationJobStatus,
    pub form_json: String,
    pub session_id: Option<String>,
    pub job_dir: PathBuf,
    pub result_pet_id: Option<String>,
    pub retry_of_job_id: Option<String>,
    pub owner_instance_id: Option<String>,
    pub heartbeat_at: String,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub cancel_requested_at: Option<String>,
    pub execution_stopped_at: Option<String>,
    pub thread_archived_at: Option<String>,
    pub recoverable: bool,
    pub failure_code: Option<String>,
    pub pause_reason: Option<String>,
    pub active_turn_id: Option<String>,
    pub last_checkpoint_at: Option<String>,
    pub visible_title: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletedGenerationHistoryJob {
    pub status: GenerationJobStatus,
    pub result_pet_id: Option<String>,
    pub deleted_message_count: usize,
    pub retry_children_relinked: usize,
    pub state_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConnectorEventReceipt {
    #[serde(skip_serializing)]
    pub sequence: i64,
    pub source_event: String,
    pub contract_version: Option<String>,
    pub created_at: String,
    pub diagnostic: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConnectorTaskReceipt {
    pub start: ConnectorEventReceipt,
    pub activity: ConnectorEventReceipt,
    pub completion: ConnectorEventReceipt,
}

/// Database-backed verification evidence for one connector contract.
///
/// All fields are projected by [`Database::connector_evidence_summary`] from
/// one descending scan of the source's event rows. Keeping this projection
/// together is important: connection checks run after every accepted event,
/// and independently rebuilding each receipt would repeatedly deserialize the
/// same bounded event history.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConnectorEvidenceSummary {
    pub observed_receipt: Option<ConnectorEventReceipt>,
    pub ordinary_receipt: Option<ConnectorEventReceipt>,
    pub diagnostic_receipt: Option<ConnectorEventReceipt>,
    pub real_start_receipt: Option<ConnectorEventReceipt>,
    pub task_receipt: Option<ConnectorTaskReceipt>,
    pub newer_stale_receipt: Option<ConnectorEventReceipt>,
}

/// Narrow projection of the bounded connector fields used by verification.
///
/// Agent payloads can contain sizeable tool metadata that is irrelevant to
/// connector health. Deserializing those rows into a complete `Value` tree on
/// every connection snapshot made the retained 10,000-event history an
/// expensive hot path. Unknown fields are skipped by serde without allocating
/// their nested representation, while `Value` on the six accepted fields keeps
/// the old tolerant type semantics for legacy rows.
#[derive(Debug, Default, Deserialize)]
struct ConnectorEvidencePayload {
    #[serde(default)]
    source_event: Option<Value>,
    #[serde(default)]
    contract_version: Option<Value>,
    #[serde(default)]
    diagnostic: Option<Value>,
    #[serde(default)]
    affects_activity: Option<Value>,
    #[serde(default)]
    session_active: Option<Value>,
    #[serde(default)]
    outcome: Option<Value>,
}

fn task_evidence_event_matches(
    source: AgentSource,
    candidates: &[&str],
    source_event: &str,
    payload: &ConnectorEvidencePayload,
    event_type: &str,
) -> bool {
    if !candidates.contains(&source_event) {
        return false;
    }
    if source != AgentSource::Opencode {
        return true;
    }
    let inactive = payload.session_active.as_ref().and_then(Value::as_bool) == Some(false);
    match source_event {
        "session.status" => {
            event_type == "done"
                && inactive
                && payload.outcome.as_ref().and_then(Value::as_str) == Some("idle")
        }
        "session.next.step.ended" => match payload.outcome.as_ref().and_then(Value::as_str) {
            Some("completed") => event_type == "done" && inactive,
            Some("session_failure") => event_type == "failed" && inactive,
            _ => false,
        },
        "session.next.step.failed" => {
            event_type == "failed"
                && inactive
                && payload.outcome.as_ref().and_then(Value::as_str) == Some("session_failure")
        }
        "session.error" => event_type == "failed" && inactive,
        _ => true,
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BehaviorSettingsPatch {
    pub enabled: Option<bool>,
    pub status_bubble: Option<bool>,
    pub interface_language: Option<InterfaceLanguage>,
    pub appearance_theme: Option<AppearanceTheme>,
    pub bubble_font_scale: Option<BubbleFontScale>,
    pub click_menu: Option<bool>,
    pub mouse_passthrough: Option<bool>,
    pub auto_hide: Option<bool>,
    pub group_sessions_by_agent: Option<bool>,
    pub session_group_display: Option<SessionGroupDisplay>,
    pub session_message_timeout_minutes: Option<u16>,
    pub sources: Option<BTreeMap<AgentSource, bool>>,
    pub events: Option<BTreeMap<AgentEventType, bool>>,
}

impl BehaviorSettingsPatch {
    fn is_empty(&self) -> bool {
        self.enabled.is_none()
            && self.status_bubble.is_none()
            && self.interface_language.is_none()
            && self.appearance_theme.is_none()
            && self.bubble_font_scale.is_none()
            && self.click_menu.is_none()
            && self.mouse_passthrough.is_none()
            && self.auto_hide.is_none()
            && self.group_sessions_by_agent.is_none()
            && self.session_group_display.is_none()
            && self.session_message_timeout_minutes.is_none()
            && self.sources.as_ref().is_none_or(BTreeMap::is_empty)
            && self.events.as_ref().is_none_or(BTreeMap::is_empty)
    }

    fn apply_to(&self, behavior: &mut BehaviorSettings) {
        if let Some(value) = self.enabled {
            behavior.enabled = value;
        }
        if let Some(value) = self.status_bubble {
            behavior.status_bubble = value;
        }
        if let Some(value) = self.interface_language {
            behavior.interface_language = value;
        }
        if let Some(value) = self.appearance_theme {
            behavior.appearance_theme = value;
        }
        if let Some(value) = self.bubble_font_scale {
            behavior.bubble_font_scale = value;
        }
        if let Some(value) = self.click_menu {
            behavior.click_menu = value;
        }
        if let Some(value) = self.auto_hide {
            behavior.auto_hide = value;
        }
        if let Some(value) = self.group_sessions_by_agent {
            behavior.group_sessions_by_agent = value;
        }
        if let Some(value) = self.session_group_display {
            behavior.session_group_display = value;
        }
        if let Some(value) = self.session_message_timeout_minutes {
            behavior.session_message_timeout_minutes = value;
        }
        if let Some(values) = &self.sources {
            behavior
                .sources
                .extend(values.iter().map(|(key, value)| (*key, *value)));
        }
        if let Some(values) = &self.events {
            behavior
                .events
                .extend(values.iter().map(|(key, value)| (*key, *value)));
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct VersionedBehaviorSettings {
    pub behavior: BehaviorSettings,
    pub revision: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VersionedOnboardingProgress {
    pub progress: OnboardingProgress,
    pub revision: String,
}

struct LegacyAgentEventRow {
    external_event_id: String,
    source: String,
    project_path: Option<String>,
    session_id: Option<String>,
    event_type: String,
    created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PetAssetValidationRecord {
    pub fingerprint: String,
    pub valid: bool,
    pub error: Option<String>,
    pub validated_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InsertEventOutcome {
    Inserted,
    Duplicate,
    Suppressed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventRetentionPolicy {
    pub max_rows: u64,
    pub max_age_days: u32,
}

/// Result of a projection read that must correspond to a caller-provided
/// `state_revision`. A revision mismatch is expected control flow, not a
/// database failure: callers can discard their in-progress snapshot and retry
/// from the newer revision without ever combining rows from two revisions.
#[derive(Debug, Clone)]
pub(crate) enum RevisionChecked<T> {
    Matched {
        state_revision: u64,
        value: T,
    },
    Mismatch {
        expected_revision: u64,
        actual_revision: u64,
    },
}

#[derive(Debug, Clone)]
pub(crate) struct OverlayPlacementProjection {
    pub(crate) placement: OverlayPlacement,
    pub(crate) intent: Option<OverlayPlacementIntent>,
    pub(crate) revision: u64,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct CodexRuntimeSurfaceHistory {
    pub(crate) has_any_trusted_marker: bool,
    pub(crate) latest_current_turn_marker: Option<SequencedAgentEvent>,
}

#[derive(Debug, Clone)]
pub(crate) enum OverlayPlacementWriteResult {
    Updated {
        state_revision: u64,
        projection: OverlayPlacementProjection,
    },
    Unchanged {
        state_revision: u64,
        projection: OverlayPlacementProjection,
    },
    Conflict {
        projection: OverlayPlacementProjection,
    },
}

#[derive(Debug, Clone, Default)]
pub(crate) struct SessionMessageProjection {
    pub(crate) latest_assistant: Option<SequencedAgentEvent>,
    pub(crate) latest_narrative_activity: Option<SequencedAgentEvent>,
    pub(crate) latest_user: Option<SequencedAgentEvent>,
    pub(crate) first_user: Option<AgentEvent>,
    pub(crate) latest_title: Option<AgentEvent>,
}

impl Default for EventRetentionPolicy {
    fn default() -> Self {
        Self {
            max_rows: 10_000,
            max_age_days: 30,
        }
    }
}

// Schema 6 added the smallest durable authority needed for content-free,
// stable anonymous-session aliases. Schema 7 widens the convergence receipt
// to the current five-Agent product contract. Runtime replacement preflight
// and rollback checkpoints keep a schema-6 last-known-good database available
// until a schema-7 candidate has completed its handoff.
//
// `product_convergence_receipt` is an additive singleton table and
// intentionally remains compatible with schema-6 last-known-good runtimes:
// an older runtime ignores it, so a failed binary replacement can still roll
// back without turning a successful receipt write into a downgrade blocker.
//
// `retired_pet_records` is likewise additive and rollback-compatible. It
// preserves metadata for pre-V3 quality rows and removed state contracts that
// the current runtime cannot decode, while their package and rendered assets
// remain untouched in the owned store.
// V3 pet metadata and retired-record storage remain additive extensions of the
// released schema-6 tables; the explicit v7 migration is limited to rebuilding
// the singleton convergence table with the wider closed source count.
pub const DATABASE_SCHEMA_VERSION: u32 = 7;
const DEFAULT_PET_STATES_JSON: &str = r#"[{"name":"idle","frames_dir":"assets/frames/idle","frame_durations_ms":[260,220,240,260,380,640],"playback":{"mode":"periodic","cooldown_ms":[2500,5000]},"reduced_motion_frame_index":2},{"name":"thinking","frames_dir":"assets/frames/thinking","frame_durations_ms":[120,140,160,180],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"tool","frames_dir":"assets/frames/tool","frame_durations_ms":[150,150,170,330],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"waiting","frames_dir":"assets/frames/waiting","frame_durations_ms":[100,100,110,110,120,130,160,230],"playback":{"mode":"burst_then_settle","entry_repeat_count":3,"settle_frame_index":7},"reduced_motion_frame_index":4},{"name":"done","frames_dir":"assets/frames/done","frame_durations_ms":[120,140,160,230],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"failed","frames_dir":"assets/frames/failed","frame_durations_ms":[80,80,90,100,110,120,190,290],"playback":{"mode":"burst_then_settle","entry_repeat_count":3,"settle_frame_index":7},"reduced_motion_frame_index":2},{"name":"acknowledge","frames_dir":"assets/frames/acknowledge","frame_durations_ms":[180,140,180,300],"playback":{"mode":"once_then_return"},"reduced_motion_frame_index":1},{"name":"drag_left","frames_dir":"assets/frames/drag_left","frame_durations_ms":[100,90,100,110,100,200],"playback":{"mode":"loop"},"reduced_motion_frame_index":2},{"name":"drag_right","frames_dir":"assets/frames/drag_right","frame_durations_ms":[100,90,100,110,100,200],"playback":{"mode":"loop"},"reduced_motion_frame_index":2}]"#;
const EVENT_PRIVACY_MIGRATION_KEY: &str = "event-envelope-v4-secure-vacuum";
const SUPPRESSED_AGENT_SESSION_RETENTION_DAYS: u32 = 30;
const MAX_SUPPRESSED_AGENT_SESSIONS: usize = 10_000;
const MAX_CODEX_LIST_RECONCILIATION_SESSIONS: usize = 24;

#[derive(Debug, Clone)]
pub struct Database {
    path: PathBuf,
}

impl Database {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn open(&self) -> Result<Connection> {
        self.open_with_busy_timeout(DATABASE_BUSY_TIMEOUT)
    }

    fn open_with_busy_timeout(&self, busy_timeout: Duration) -> Result<Connection> {
        let connection = Connection::open(&self.path)?;
        connection.busy_timeout(busy_timeout)?;
        Ok(connection)
    }
}

fn state_revision_in_connection(connection: &Connection) -> Result<u64> {
    let revision = connection.query_row(
        "SELECT revision FROM state_revision WHERE singleton = 1",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    u64::try_from(revision).map_err(|_| {
        PetCoreError::Validation("state revision must be a non-negative integer".to_string())
    })
}

fn read_overlay_placement_projection(
    connection: &Connection,
) -> Result<OverlayPlacementProjection> {
    let placement_row = connection
        .query_row(
            "SELECT value_json, revision FROM settings WHERE key = ?1",
            params![OVERLAY_PLACEMENT_SETTING_KEY],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let (placement, revision) = match placement_row {
        Some((value, revision)) => (
            decode_overlay_placement(&value)?,
            u64::try_from(revision).map_err(|_| {
                PetCoreError::Validation(
                    "overlay placement revision must be a non-negative integer".to_string(),
                )
            })?,
        ),
        None => (OverlayPlacement::default(), 0),
    };
    let intent = connection
        .query_row(
            "SELECT value_json FROM settings WHERE key = ?1",
            params![OVERLAY_PLACEMENT_INTENT_SETTING_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|value| serde_json::from_str::<OverlayPlacementIntent>(&value))
        .transpose()?;
    Ok(OverlayPlacementProjection {
        placement,
        intent,
        revision,
    })
}

fn decode_overlay_placement(value: &str) -> Result<OverlayPlacement> {
    let placement = serde_json::from_str::<OverlayPlacement>(value)?;
    placement.canonicalized().map_err(|error| {
        PetCoreError::Validation(format!("stored overlay placement is invalid: {error}"))
    })
}

fn read_agent_session_acknowledgements(
    connection: &Connection,
) -> Result<AgentSessionAcknowledgements> {
    let value = connection
        .query_row(
            "SELECT value_json FROM settings WHERE key = ?1",
            params![AGENT_SESSION_ACKNOWLEDGEMENTS_SETTING_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let acknowledgements = value
        .map(|value| serde_json::from_str::<AgentSessionAcknowledgements>(&value))
        .transpose()?
        .unwrap_or_default();
    if acknowledgements.schema_version != AGENT_SESSION_ACKNOWLEDGEMENTS_SCHEMA_VERSION {
        return Err(PetCoreError::Validation(
            "unsupported Agent session acknowledgement schema".to_string(),
        ));
    }
    if acknowledgements.ids.len() > MAX_AGENT_SESSION_ACKNOWLEDGEMENTS
        || acknowledgements
            .ids
            .iter()
            .any(|id| !is_valid_session_acknowledgement_id(id))
    {
        return Err(PetCoreError::Validation(
            "invalid Agent session acknowledgements".to_string(),
        ));
    }
    Ok(acknowledgements)
}

fn recent_events_in_connection(connection: &Connection, limit: usize) -> Result<Vec<AgentEvent>> {
    let limit = limit.min(MAX_RECENT_EVENTS);
    if limit == 0 {
        return Ok(Vec::new());
    }
    let mut statement = connection.prepare(
        r#"
        SELECT external_event_id, source, project_path, session_id, event_type,
               title, detail, payload_json, created_at
        FROM agent_events
        ORDER BY created_at DESC, row_id DESC
        LIMIT ?1
        "#,
    )?;
    let rows = statement.query_map(params![limit as i64], |row| agent_event_from_row(row, 0))?;
    rows.collect::<std::result::Result<Vec<_>, _>>()
        .map_err(Into::into)
}

fn session_message_projection_in_connection(
    connection: &Connection,
    source: AgentSource,
    session_id: Option<&str>,
) -> Result<SessionMessageProjection> {
    let session_id = normalized_session_id(session_id);
    let mut statement = connection.prepare(
        r#"
        SELECT row_id, external_event_id, source, project_path, session_id, event_type,
               title, detail, payload_json, created_at
        FROM agent_events
        WHERE source = ?1 AND session_key = ?2
        ORDER BY created_at DESC, row_id DESC
        "#,
    )?;
    let rows = statement.query_map(
        params![
            enum_name(source),
            normalized_session_key(session_id.as_deref())
        ],
        sequenced_session_event_from_row,
    )?;
    let mut projection = SessionMessageProjection::default();
    for row in rows {
        let sequenced = row?;
        if projection.latest_title.is_none()
            && event_has_nonempty_payload_text(&sequenced.event, "session_title")
        {
            projection.latest_title = Some(sequenced.event.clone());
        }
        if projection.latest_narrative_activity.is_none()
            && matches!(
                sequenced.event.event_type,
                AgentEventType::Thinking | AgentEventType::Plan
            )
            && event_has_nonempty_payload_text(&sequenced.event, "activity_content")
        {
            projection.latest_narrative_activity = Some(sequenced.clone());
        }
        if !event_has_nonempty_message_content(&sequenced.event) {
            continue;
        }
        match sequenced
            .event
            .payload_json
            .get("message_role")
            .and_then(Value::as_str)
        {
            Some("assistant") if projection.latest_assistant.is_none() => {
                projection.latest_assistant = Some(sequenced);
            }
            Some("user") => {
                if projection.latest_user.is_none() {
                    projection.latest_user = Some(sequenced.clone());
                }
                // Rows are newest-first, so the final matching user row is the
                // first user message under the existing `(created_at, row_id)`
                // ordering contract.
                projection.first_user = Some(sequenced.event);
            }
            _ => {}
        }
    }
    Ok(projection)
}

fn session_message_for_role_in_connection(
    connection: &Connection,
    source: AgentSource,
    session_id: Option<&str>,
    role: Option<&str>,
    newest_first: bool,
) -> Result<Option<SequencedAgentEvent>> {
    let session_id = normalized_session_id(session_id);
    let query = if newest_first {
        r#"
        SELECT row_id, external_event_id, source, project_path, session_id, event_type,
               title, detail, payload_json, created_at
        FROM agent_events
        WHERE source = ?1 AND session_key = ?2
        ORDER BY created_at DESC, row_id DESC
        "#
    } else {
        r#"
        SELECT row_id, external_event_id, source, project_path, session_id, event_type,
               title, detail, payload_json, created_at
        FROM agent_events
        WHERE source = ?1 AND session_key = ?2
        ORDER BY created_at ASC, row_id ASC
        "#
    };
    let mut statement = connection.prepare(query)?;
    let rows = statement.query_map(
        params![
            enum_name(source),
            normalized_session_key(session_id.as_deref())
        ],
        sequenced_session_event_from_row,
    )?;
    for row in rows {
        let sequenced = row?;
        let payload_role = sequenced
            .event
            .payload_json
            .get("message_role")
            .and_then(Value::as_str);
        if role.is_none_or(|role| payload_role == Some(role))
            && event_has_nonempty_message_content(&sequenced.event)
        {
            return Ok(Some(sequenced));
        }
    }
    Ok(None)
}

fn sequenced_session_event_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<SequencedAgentEvent> {
    sequenced_session_event_from_row_at(row, 0)
}

fn sequenced_session_event_from_row_at(
    row: &rusqlite::Row<'_>,
    offset: usize,
) -> rusqlite::Result<SequencedAgentEvent> {
    let row_id = row.get::<_, i64>(offset)?;
    Ok(SequencedAgentEvent {
        source_session_sequence: u64::try_from(row_id).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Integer,
                Box::new(error),
            )
        })?,
        session_alias_sequence: None,
        session_activated_at: None,
        session_first_seen_at: None,
        latest_terminal_navigation_payload: None,
        completion_epoch_event_ids: Vec::new(),
        preferred_app_navigation_payload: None,
        tool_activity_run_marker: None,
        event: agent_event_from_row(row, offset + 1)?,
    })
}

fn trusted_codex_runtime_surface_marker(event: &AgentEvent) -> bool {
    if event.source != AgentSource::Codex
        || event
            .payload_json
            .get("diagnostic")
            .and_then(Value::as_bool)
            != Some(false)
        || event
            .payload_json
            .get("contract_version")
            .and_then(Value::as_str)
            != Some(CODEX_HOOKS_CONTRACT_VERSION)
        || !event
            .payload_json
            .get("source_event")
            .and_then(Value::as_str)
            .is_some_and(|source_event| {
                matches!(
                    source_event,
                    "SessionStart"
                        | "UserPromptSubmit"
                        | "PreToolUse"
                        | "PermissionRequest"
                        | "PostToolUse"
                        | "PreCompact"
                        | "PostCompact"
                        | "SubagentStart"
                        | "SubagentStop"
                        | "Stop"
                )
            })
    {
        return false;
    }
    if event.payload_json.get("turn_id").is_some_and(|value| {
        value
            .as_str()
            .is_none_or(|turn_id| !bounded_runtime_marker_text(turn_id, 256))
            && !value.is_null()
    }) {
        return false;
    }

    let terminal_app = match event.payload_json.get("terminal_app") {
        None | Some(Value::Null) => None,
        Some(Value::String(value))
            if matches!(value.as_str(), "warp" | "terminal" | "iterm2" | "ghostty") =>
        {
            Some(value.as_str())
        }
        _ => return false,
    };
    let session_open_url = match event.payload_json.get("session_open_url") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) if bounded_runtime_marker_text(value, 256) => {
            Some(value.as_str())
        }
        _ => return false,
    };
    match event
        .payload_json
        .get("session_surface")
        .and_then(Value::as_str)
    {
        Some("chatgpt_app") => terminal_app.is_none() && session_open_url.is_none(),
        Some("cli_terminal") => session_open_url.is_none_or(|url| {
            terminal_app == Some("warp") && validated_warp_focus_url(url).as_deref() == Some(url)
        }),
        _ => false,
    }
}

fn bounded_runtime_marker_text(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty() && value.trim() == value && value.len() <= maximum_bytes
}

fn agent_event_from_row(row: &rusqlite::Row<'_>, offset: usize) -> rusqlite::Result<AgentEvent> {
    let source: String = row.get(offset + 1)?;
    let event_type: String = row.get(offset + 4)?;
    let payload_json: String = row.get(offset + 7)?;
    Ok(AgentEvent {
        id: row.get(offset)?,
        source: enum_from_name(&source).map_err(to_sql_error)?,
        project_path: row.get(offset + 2)?,
        session_id: row.get(offset + 3)?,
        event_type: enum_from_name(&event_type).map_err(to_sql_error)?,
        title: row.get(offset + 5)?,
        detail: row.get(offset + 6)?,
        payload_json: serde_json::from_str(&payload_json).map_err(to_sql_error)?,
        created_at: row.get(offset + 8)?,
    })
}

fn event_has_nonempty_message_content(event: &AgentEvent) -> bool {
    event_has_nonempty_payload_text(event, "message_content")
}

fn event_has_nonempty_payload_text(event: &AgentEvent, key: &str) -> bool {
    event
        .payload_json
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|message| !message.trim().is_empty())
}

fn prune_events_in_transaction(
    transaction: &rusqlite::Transaction<'_>,
    policy: EventRetentionPolicy,
) -> Result<usize> {
    let maximum_rows = i64::try_from(policy.max_rows).unwrap_or(i64::MAX);
    let rows = {
        let mut statement = transaction.prepare(
            r#"
            SELECT row_id, source, event_type, created_at
            FROM agent_events
            WHERE julianday(created_at) < julianday('now', '-' || ?1 || ' days')
               OR row_id IN (
                    SELECT row_id
                    FROM agent_events
                    ORDER BY created_at DESC, row_id DESC
                    LIMIT -1 OFFSET ?2
               )
            ORDER BY created_at ASC, row_id ASC
            "#,
        )?;
        let rows = statement
            .query_map(
                params![i64::from(policy.max_age_days), maximum_rows],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        rows
    };

    let mut daily_counts = BTreeMap::<(String, String, String), u64>::new();
    for (_, source, event_type, created_at) in &rows {
        let event_day = created_at
            .get(..10)
            .filter(|value| {
                value.as_bytes().get(4) == Some(&b'-') && value.as_bytes().get(7) == Some(&b'-')
            })
            .unwrap_or("unknown")
            .to_string();
        *daily_counts
            .entry((event_day, source.clone(), event_type.clone()))
            .or_default() += 1;
    }
    for ((event_day, source, event_type), count) in daily_counts {
        transaction.execute(
            r#"
            INSERT INTO agent_event_daily_counts
              (event_day, source, event_type, event_count)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(event_day, source, event_type) DO UPDATE SET
              event_count = event_count + excluded.event_count
            "#,
            params![event_day, source, event_type, count as i64],
        )?;
    }
    for (row_id, _, _, _) in &rows {
        transaction.execute(
            "DELETE FROM agent_events WHERE row_id = ?1",
            params![row_id],
        )?;
    }
    prune_agent_session_aliases(transaction)?;
    Ok(rows.len())
}

fn ensure_agent_session_alias_in_connection(
    connection: &Connection,
    source: &str,
    session_key: &str,
    assigned_at: &str,
) -> Result<u64> {
    let existing = connection
        .query_row(
            r#"
            SELECT alias_sequence
            FROM agent_session_aliases
            WHERE source = ?1 AND session_key = ?2
            "#,
            params![source, session_key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?;
    if let Some(sequence) = existing {
        return u64::try_from(sequence).map_err(|_| {
            PetCoreError::Validation("session alias sequence must be positive".to_string())
        });
    }
    connection.execute(
        r#"
        INSERT INTO agent_session_aliases
          (source, session_key, assigned_at)
        VALUES (?1, ?2, ?3)
        "#,
        params![source, session_key, assigned_at],
    )?;
    let sequence = connection.query_row(
        r#"
        SELECT alias_sequence
        FROM agent_session_aliases
        WHERE source = ?1 AND session_key = ?2
        "#,
        params![source, session_key],
        |row| row.get::<_, i64>(0),
    )?;
    u64::try_from(sequence).map_err(|_| {
        PetCoreError::Validation("session alias sequence must be positive".to_string())
    })
}

fn prune_agent_session_aliases(connection: &Connection) -> Result<usize> {
    // Alias rows only outlive a session while that session still has a
    // retained event. The alias table is therefore bounded by the event
    // retention row limit, while SQLite AUTOINCREMENT prevents token reuse.
    connection
        .execute(
            r#"
            DELETE FROM agent_session_aliases
            WHERE NOT EXISTS (
              SELECT 1
              FROM agent_events AS events
              WHERE events.source = agent_session_aliases.source
                AND events.session_key = agent_session_aliases.session_key
            )
            "#,
            [],
        )
        .map_err(Into::into)
}

fn suppress_agent_session_in_connection(
    connection: &Connection,
    source: AgentSource,
    session_key: &str,
    reason: &str,
) -> Result<()> {
    connection.execute(
        r#"
        INSERT INTO suppressed_agent_sessions (source, session_key, reason, suppressed_at)
        VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(source, session_key) DO UPDATE SET
          reason = excluded.reason,
          suppressed_at = excluded.suppressed_at
        "#,
        params![enum_name(source), session_key, reason, now_rfc3339()],
    )?;
    connection.execute(
        "DELETE FROM agent_events WHERE source = ?1 AND session_key = ?2",
        params![enum_name(source), session_key],
    )?;
    connection.execute(
        "DELETE FROM agent_session_aliases WHERE source = ?1 AND session_key = ?2",
        params![enum_name(source), session_key],
    )?;
    Ok(())
}

fn generation_job_owns_session(connection: &Connection, session_id: &str) -> Result<bool> {
    connection
        .query_row(
            "SELECT 1 FROM generation_jobs WHERE session_id = ?1 LIMIT 1",
            params![session_id],
            |_| Ok(()),
        )
        .optional()
        .map(|value| value.is_some())
        .map_err(Into::into)
}

fn agent_session_is_suppressed(
    connection: &Connection,
    source: AgentSource,
    session_key: &str,
) -> Result<bool> {
    connection
        .query_row(
            r#"
            SELECT 1
            FROM suppressed_agent_sessions
            WHERE source = ?1 AND session_key = ?2
            "#,
            params![enum_name(source), session_key],
            |_| Ok(()),
        )
        .optional()
        .map(|value| value.is_some())
        .map_err(Into::into)
}

fn prune_suppressed_agent_sessions(connection: &Connection) -> Result<()> {
    connection.execute(
        r#"
        DELETE FROM suppressed_agent_sessions
        WHERE julianday(suppressed_at) < julianday('now', ?1)
        "#,
        params![format!("-{} days", SUPPRESSED_AGENT_SESSION_RETENTION_DAYS)],
    )?;
    connection.execute(
        r#"
        DELETE FROM suppressed_agent_sessions
        WHERE rowid IN (
          SELECT rowid
          FROM suppressed_agent_sessions
          ORDER BY suppressed_at DESC, rowid DESC
          LIMIT -1 OFFSET ?1
        )
        "#,
        params![i64::try_from(MAX_SUPPRESSED_AGENT_SESSIONS).unwrap_or(i64::MAX)],
    )?;
    Ok(())
}

fn read_behavior_row(connection: &Connection) -> Result<(BehaviorSettings, u64)> {
    let row = connection
        .query_row(
            "SELECT value_json, revision FROM settings WHERE key = 'behavior'",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let Some((value_json, revision)) = row else {
        return Ok((BehaviorSettings::default(), 0));
    };
    let revision = u64::try_from(revision)
        .map_err(|_| PetCoreError::Validation("behavior revision must be non-negative".into()))?;
    Ok((serde_json::from_str(&value_json)?, revision))
}

fn write_behavior_row(
    connection: &Connection,
    behavior: &BehaviorSettings,
    expected_revision: u64,
    next_revision: u64,
) -> Result<()> {
    let changed = connection.execute(
        r#"
        INSERT INTO settings (key, value_json, updated_at, revision)
        VALUES ('behavior', ?1, ?2, ?3)
        ON CONFLICT(key) DO UPDATE SET
          value_json = excluded.value_json,
          updated_at = excluded.updated_at,
          revision = excluded.revision
        WHERE settings.revision = ?4
        "#,
        params![
            serde_json::to_string_pretty(behavior)?,
            now_rfc3339(),
            i64::try_from(next_revision).map_err(|_| {
                PetCoreError::Validation("behavior revision exceeds SQLite range".into())
            })?,
            i64::try_from(expected_revision).map_err(|_| {
                PetCoreError::Validation("behavior revision exceeds SQLite range".into())
            })?,
        ],
    )?;
    if changed == 0 {
        let (_, actual_revision) = read_behavior_row(connection)?;
        return Err(PetCoreError::Conflict(format!(
            "behavior revision conflict: expected {expected_revision}, actual {actual_revision}"
        )));
    }
    Ok(())
}

fn read_onboarding_row(connection: &Connection) -> Result<(OnboardingProgress, u64)> {
    let row = connection
        .query_row(
            "SELECT value_json, revision FROM settings WHERE key = ?1",
            params![ONBOARDING_PROGRESS_SETTING_KEY],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let Some((value_json, revision)) = row else {
        return Ok((OnboardingProgress::default(), 0));
    };
    let revision = u64::try_from(revision)
        .map_err(|_| PetCoreError::Validation("onboarding revision must be non-negative".into()))?;
    let progress: OnboardingProgress = serde_json::from_str(&value_json)?;
    if !progress.is_supported() {
        return Err(PetCoreError::Validation(format!(
            "onboarding schema_version must be {ONBOARDING_PROGRESS_SCHEMA_VERSION}"
        )));
    }
    Ok((progress, revision))
}

fn write_onboarding_row(
    connection: &Connection,
    progress: &OnboardingProgress,
    expected_revision: u64,
    next_revision: u64,
) -> Result<()> {
    let changed = connection.execute(
        r#"
        INSERT INTO settings (key, value_json, updated_at, revision)
        VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(key) DO UPDATE SET
          value_json = excluded.value_json,
          updated_at = excluded.updated_at,
          revision = excluded.revision
        WHERE settings.revision = ?5
        "#,
        params![
            ONBOARDING_PROGRESS_SETTING_KEY,
            serde_json::to_string_pretty(progress)?,
            now_rfc3339(),
            i64::try_from(next_revision).map_err(|_| {
                PetCoreError::Validation("onboarding revision exceeds SQLite range".into())
            })?,
            i64::try_from(expected_revision).map_err(|_| {
                PetCoreError::Validation("onboarding revision exceeds SQLite range".into())
            })?,
        ],
    )?;
    if changed == 0 {
        let (_, actual_revision) = read_onboarding_row(connection)?;
        return Err(PetCoreError::Conflict(format!(
            "onboarding revision conflict: expected {expected_revision}, actual {actual_revision}"
        )));
    }
    Ok(())
}

fn source_sort_key(source: AgentSource) -> usize {
    match source {
        AgentSource::Codex => 0,
        AgentSource::ClaudeCode => 1,
        AgentSource::Pi => 2,
        AgentSource::Opencode => 3,
        AgentSource::Dsh => 4,
    }
}

fn generation_job_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GenerationJobRecord> {
    let status: String = row.get(1)?;
    Ok(GenerationJobRecord {
        id: row.get(0)?,
        status: enum_from_name(&status).map_err(to_sql_error)?,
        form_json: row.get(2)?,
        session_id: row.get(3)?,
        job_dir: PathBuf::from(row.get::<_, String>(4)?),
        result_pet_id: row.get(5)?,
        retry_of_job_id: row.get(6)?,
        owner_instance_id: row.get(7)?,
        heartbeat_at: row.get(8)?,
        started_at: row.get(9)?,
        ended_at: row.get(10)?,
        cancel_requested_at: row.get(11)?,
        execution_stopped_at: row.get(12)?,
        thread_archived_at: row.get(13)?,
        recoverable: row.get::<_, i64>(14)? != 0,
        failure_code: row.get(15)?,
        pause_reason: row.get(16)?,
        active_turn_id: row.get(17)?,
        last_checkpoint_at: row.get(18)?,
        visible_title: row.get(19)?,
        created_at: row.get(20)?,
        updated_at: row.get(21)?,
    })
}

fn generation_message_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<GenerationMessageRecord> {
    let sequence = row.get::<_, i64>(2)?;
    let payload_json = row.get::<_, Option<String>>(8)?;
    let diagnostic_json = row.get::<_, Option<String>>(9)?;
    Ok(GenerationMessageRecord {
        id: row.get(0)?,
        job_id: row.get(1)?,
        sequence: u64::try_from(sequence).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                2,
                rusqlite::types::Type::Integer,
                Box::new(error),
            )
        })?,
        role: row.get(3)?,
        kind: row.get(4)?,
        content: row.get(5)?,
        progress: row.get(6)?,
        created_at: row.get(7)?,
        payload: payload_json
            .map(|value| serde_json::from_str(&value).map_err(to_sql_error))
            .transpose()?,
        diagnostic: diagnostic_json
            .map(|value| serde_json::from_str(&value).map_err(to_sql_error))
            .transpose()?,
    })
}

fn is_terminal_generation_message_kind(kind: &str) -> bool {
    matches!(
        kind,
        "generation_completed" | "generation_failed" | "generation_canceled"
    )
}

fn generation_status_for_terminal_message_kind(kind: &str) -> Option<GenerationJobStatus> {
    match kind {
        "generation_completed" => Some(GenerationJobStatus::Completed),
        "generation_failed" => Some(GenerationJobStatus::Failed),
        "generation_canceled" => Some(GenerationJobStatus::Canceled),
        _ => None,
    }
}

fn generation_visible_title(form: &GenerationForm) -> String {
    const MAX_TITLE_CHARS: usize = 64;
    const MAX_TITLE_BYTES: usize = 256;
    let normalized = form
        .description
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if normalized.is_empty() {
        return "未命名宠物制作".to_string();
    }
    if normalized.chars().count() <= MAX_TITLE_CHARS && normalized.len() <= MAX_TITLE_BYTES {
        return normalized;
    }
    let mut title = String::new();
    for character in normalized.chars().take(MAX_TITLE_CHARS.saturating_sub(1)) {
        if title.len() + character.len_utf8() > MAX_TITLE_BYTES.saturating_sub('…'.len_utf8()) {
            break;
        }
        title.push(character);
    }
    title.push('…');
    title
}

fn is_terminal_generation_status(status: GenerationJobStatus) -> bool {
    matches!(
        status,
        GenerationJobStatus::Completed
            | GenerationJobStatus::Failed
            | GenerationJobStatus::Canceled
    )
}

fn reject_other_active_generation(
    transaction: &rusqlite::Transaction<'_>,
    job_id: &str,
    target_status: GenerationJobStatus,
) -> Result<()> {
    if !matches!(
        target_status,
        GenerationJobStatus::Pending
            | GenerationJobStatus::Running
            | GenerationJobStatus::WaitingForUser
    ) {
        return Ok(());
    }
    let active_job = transaction
        .query_row(
            r#"
            SELECT id, status
            FROM generation_jobs
            WHERE id <> ?1
              AND (
                status IN (?2, ?3, ?4)
                OR (status = ?5 AND recoverable = 1)
                OR (cancel_requested_at IS NOT NULL AND thread_archived_at IS NULL)
              )
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
            params![
                job_id,
                enum_name(GenerationJobStatus::Pending),
                enum_name(GenerationJobStatus::Running),
                enum_name(GenerationJobStatus::WaitingForUser),
                enum_name(GenerationJobStatus::Failed),
            ],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    if let Some((active_job_id, active_status)) = active_job {
        return Err(PetCoreError::GenerationConflict {
            active_job: serde_json::json!({
                "job_id": active_job_id,
                "status": active_status
            }),
        });
    }
    Ok(())
}

fn to_sql_error(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

fn decode_pet_states(states_json: &str) -> std::result::Result<Vec<PetState>, rusqlite::Error> {
    let states: Vec<PetState> = serde_json::from_str(states_json).map_err(to_sql_error)?;
    if states.len() != REQUIRED_STATES.len()
        || REQUIRED_STATES
            .iter()
            .any(|name| states.iter().filter(|state| state.name == *name).count() != 1)
        || states.iter().any(|state| state.validate().is_err())
    {
        return Err(to_sql_error(PetCoreError::Validation(
            "stored pet has invalid V3 state or interaction timing contract".to_string(),
        )));
    }
    Ok(states)
}

fn is_recoverable_corruption(error: &PetCoreError) -> bool {
    matches!(
        error,
        PetCoreError::Sqlite(rusqlite::Error::SqliteFailure(sqlite_error, _))
            if matches!(
                sqlite_error.code,
                ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase
            )
    )
}

fn is_transient_database_contention(error: &PetCoreError) -> bool {
    matches!(
        error,
        PetCoreError::Sqlite(rusqlite::Error::SqliteFailure(sqlite_error, _))
            if matches!(
                sqlite_error.code,
                ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked
            )
    )
}

fn retry_transient_database_contention<T>(
    maximum_attempts: usize,
    retry_delay: Duration,
    mut operation: impl FnMut() -> Result<T>,
) -> Result<T> {
    debug_assert!(maximum_attempts > 0);
    let maximum_attempts = maximum_attempts.max(1);
    for attempt in 1..=maximum_attempts {
        match operation() {
            Err(error)
                if attempt < maximum_attempts && is_transient_database_contention(&error) =>
            {
                std::thread::sleep(retry_delay);
            }
            result => return result,
        }
    }
    unreachable!("database contention retry loop always returns")
}

fn table_has_column(connection: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let rows = statement.query_map([], |row| row.get::<_, String>(1))?;
    for row in rows {
        if row? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn table_exists(connection: &Connection, table: &str) -> Result<bool> {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
            params![table],
            |_| Ok(()),
        )
        .optional()
        .map(|value| value.is_some())
        .map_err(Into::into)
}

fn preflight_active_generation_forms(connection: &Connection) -> Result<()> {
    if !table_exists(connection, "generation_jobs")? {
        return Ok(());
    }
    let mut statement = connection.prepare(
        r#"
        SELECT form_json
        FROM generation_jobs
        WHERE status IN (?1, ?2, ?3)
        ORDER BY updated_at ASC, id ASC
        "#,
    )?;
    let forms = statement.query_map(
        params![
            enum_name(GenerationJobStatus::Pending),
            enum_name(GenerationJobStatus::Running),
            enum_name(GenerationJobStatus::WaitingForUser),
        ],
        |row| row.get::<_, String>(0),
    )?;
    for form in forms {
        let form = form?;
        serde_json::from_str::<GenerationForm>(&form).map_err(|error| {
            PetCoreError::Validation(format!(
                "active generation form is incompatible with this PetCore contract ({error}); finish or cancel the existing generation before updating"
            ))
        })?;
    }
    Ok(())
}

fn backup_if_exists(source: &Path, destination: &Path) -> Result<()> {
    if source.exists() {
        fs::rename(source, destination)?;
    }
    Ok(())
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}-{suffix}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::OnceLock;
    use time::{format_description::well_known::Rfc3339, Duration as TimeDuration, OffsetDateTime};

    fn retained_event_timestamp(offset_seconds: i64) -> String {
        static BASE: OnceLock<OffsetDateTime> = OnceLock::new();
        (*BASE.get_or_init(|| OffsetDateTime::now_utc() - TimeDuration::minutes(1))
            + TimeDuration::seconds(offset_seconds))
        .format(&Rfc3339)
        .expect("format retained event fixture timestamp")
    }

    fn sqlite_contention_error(code: ErrorCode, extended_code: i32) -> PetCoreError {
        PetCoreError::Sqlite(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error {
                code,
                extended_code,
            },
            Some("controlled test contention".to_string()),
        ))
    }

    fn product_convergence_receipt(build_id: &str) -> ProductConvergenceReceipt {
        ProductConvergenceReceipt {
            schema_version: PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION.to_string(),
            build_id: build_id.to_string(),
            app_version: "1.2.3".to_string(),
            completed_at: "2026-07-24T10:30:00Z".to_string(),
            connector_report_summary: ProductConvergenceConnectorSummary {
                total_sources: 4,
                managed_sources: 2,
                verified_sources: 2,
                skipped_sources: 2,
                report_sha256: "a".repeat(64),
                codex_skills_sha256: Some("b".repeat(64)),
                codex_content_sha256: Some("c".repeat(64)),
            },
        }
    }

    #[test]
    fn database_default_pet_states_match_the_typed_v3_contract() {
        assert_eq!(
            decode_pet_states(DEFAULT_PET_STATES_JSON).unwrap(),
            petcore_types::default_pet_states()
        );
    }

    #[test]
    fn overlay_placement_cas_is_canonical_idempotent_and_intent_sensitive() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("overlay-idempotent.sqlite"));
        database.init().unwrap();
        let initial = database.overlay_placement_projection().unwrap();
        let proposed = OverlayPlacement {
            x: 321.0001,
            y: -654.0001,
            display_width_pt: 112.5,
            display_id: "display-a".to_string(),
        };

        let updated = database
            .set_overlay_placement(&proposed, None, Some(initial.revision))
            .unwrap();
        let (state_revision, projection) = match updated {
            OverlayPlacementWriteResult::Updated {
                state_revision,
                projection,
            } => (state_revision, projection),
            other => panic!("expected updated result, got {other:?}"),
        };
        assert_eq!(projection.placement.x, 321.0);
        assert_eq!(projection.placement.y, -654.0);
        let connection = Connection::open(database.path()).unwrap();
        let before: (String, i64) = connection
            .query_row(
                "SELECT updated_at, revision FROM settings WHERE key = ?1",
                params![OVERLAY_PLACEMENT_SETTING_KEY],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        drop(connection);

        let equivalent = OverlayPlacement {
            x: 320.9999,
            y: -653.9999,
            ..proposed.clone()
        };
        let unchanged = database
            .set_overlay_placement(&equivalent, None, Some(projection.revision))
            .unwrap();
        match unchanged {
            OverlayPlacementWriteResult::Unchanged {
                state_revision: unchanged_state_revision,
                projection: unchanged_projection,
            } => {
                assert_eq!(unchanged_state_revision, state_revision);
                assert_eq!(unchanged_projection.revision, projection.revision);
                assert_eq!(unchanged_projection.placement, projection.placement);
            }
            other => panic!("expected unchanged result, got {other:?}"),
        }
        let connection = Connection::open(database.path()).unwrap();
        let after: (String, i64) = connection
            .query_row(
                "SELECT updated_at, revision FROM settings WHERE key = ?1",
                params![OVERLAY_PLACEMENT_SETTING_KEY],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(after, before);
        assert_eq!(
            state_revision_in_connection(&connection).unwrap(),
            state_revision
        );
        drop(connection);

        let intent_change = database
            .set_overlay_placement(
                &equivalent,
                Some(OverlayPlacementIntent::Reset),
                Some(projection.revision),
            )
            .unwrap();
        match intent_change {
            OverlayPlacementWriteResult::Updated {
                state_revision: next_state_revision,
                projection: next,
            } => {
                assert!(next_state_revision > state_revision);
                assert_eq!(next.revision, projection.revision + 1);
                assert_eq!(next.intent, Some(OverlayPlacementIntent::Reset));
            }
            other => panic!("expected intent update, got {other:?}"),
        }

        let stale = database
            .set_overlay_placement(&equivalent, None, Some(initial.revision))
            .unwrap();
        assert!(matches!(
            stale,
            OverlayPlacementWriteResult::Conflict { .. }
        ));
    }

    #[test]
    fn overlay_placement_transaction_failure_rolls_back_every_projection_field() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("overlay-atomic.sqlite"));
        database.init().unwrap();
        let before = database.overlay_placement_projection().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        let state_revision_before = state_revision_in_connection(&connection).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TRIGGER fail_overlay_intent_insert
                BEFORE INSERT ON settings
                WHEN NEW.key = 'overlay_placement_intent'
                BEGIN
                  SELECT RAISE(ABORT, 'synthetic overlay intent failure');
                END;
                "#,
            )
            .unwrap();
        drop(connection);

        let attempted = OverlayPlacement {
            x: 400.25,
            y: 300.75,
            display_width_pt: 112.0,
            display_id: "display-b".to_string(),
        };
        assert!(database
            .set_overlay_placement(
                &attempted,
                Some(OverlayPlacementIntent::ExternalReposition),
                Some(before.revision),
            )
            .is_err());

        let after = database.overlay_placement_projection().unwrap();
        assert_eq!(after.placement, before.placement);
        assert_eq!(after.intent, before.intent);
        assert_eq!(after.revision, before.revision);
        let connection = Connection::open(database.path()).unwrap();
        assert_eq!(
            state_revision_in_connection(&connection).unwrap(),
            state_revision_before
        );
    }

    #[test]
    fn pet_revision_database_commit_retries_bounded_busy_errors() {
        let mut attempts = 0;
        let value = retry_transient_database_contention(3, Duration::ZERO, || {
            attempts += 1;
            if attempts < 3 {
                return Err(sqlite_contention_error(
                    ErrorCode::DatabaseBusy,
                    rusqlite::ffi::SQLITE_BUSY,
                ));
            }
            Ok(42)
        })
        .unwrap();

        assert_eq!(value, 42);
        assert_eq!(attempts, 3);
    }

    #[test]
    fn pet_revision_database_commit_does_not_retry_noncontention_errors() {
        let mut attempts = 0;
        let error = retry_transient_database_contention(3, Duration::ZERO, || {
            attempts += 1;
            Err::<(), _>(PetCoreError::Validation(
                "controlled validation failure".to_string(),
            ))
        })
        .unwrap_err();

        assert!(matches!(error, PetCoreError::Validation(_)));
        assert_eq!(attempts, 1);
    }

    #[test]
    fn pet_activation_waits_for_an_overlapping_writer_instead_of_losing_the_request() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("pet-activation-contention.sqlite"));
        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute_batch(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  petpack_path, cover_path, active, created_at
                ) VALUES
                  ('pet-active', 'Active', 'test', 'standard', 384, 416,
                   '/tmp/active.petpack', '/tmp/active.png', 1,
                   '2026-08-07T00:00:00Z'),
                  ('pet-target', 'Target', 'test', 'standard', 384, 416,
                   '/tmp/target.petpack', '/tmp/target.png', 0,
                   '2026-08-07T00:00:01Z');
                "#,
            )
            .unwrap();
        drop(connection);

        let mut blocker = Connection::open(database.path()).unwrap();
        let blocker_transaction = blocker
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .unwrap();
        blocker_transaction
            .execute(
                "UPDATE state_revision SET revision = revision + 1 WHERE singleton = 1",
                [],
            )
            .unwrap();

        let activation_database = database.clone();
        let activation = std::thread::spawn(move || activation_database.activate_pet("pet-target"));
        std::thread::sleep(Duration::from_millis(100));
        blocker_transaction.commit().unwrap();

        activation.join().unwrap().unwrap();
        let pets = database.list_pets().unwrap();
        assert_eq!(pets.iter().filter(|pet| pet.active).count(), 1);
        assert!(pets.iter().any(|pet| pet.id == "pet-target" && pet.active));
    }

    #[test]
    fn product_convergence_receipt_is_optional_and_atomically_replaced() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("product-convergence.sqlite"));
        database.init().unwrap();

        assert_eq!(database.product_convergence_receipt().unwrap(), None);

        let first = product_convergence_receipt("release-build-1");
        database.upsert_product_convergence_receipt(&first).unwrap();
        assert_eq!(database.product_convergence_receipt().unwrap(), Some(first));

        let mut replacement = product_convergence_receipt("release-build-2");
        replacement.completed_at = "2026-07-24T10:31:00Z".to_string();
        replacement.connector_report_summary.report_sha256 = "d".repeat(64);
        database
            .upsert_product_convergence_receipt(&replacement)
            .unwrap();
        assert_eq!(
            database.product_convergence_receipt().unwrap(),
            Some(replacement)
        );

        let connection = Connection::open(database.path()).unwrap();
        let receipt_rows: u32 = connection
            .query_row(
                "SELECT COUNT(*) FROM product_convergence_receipt",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let generic_setting_rows: u32 = connection
            .query_row(
                "SELECT COUNT(*) FROM settings WHERE key LIKE 'diagnostic.%'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(receipt_rows, 1);
        assert_eq!(generic_setting_rows, 0);
    }

    #[test]
    fn product_convergence_table_is_a_schema_six_compatible_addition() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("schema-six-addition.sqlite"));
        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute("DROP TABLE product_convergence_receipt", [])
            .unwrap();
        connection
            .pragma_update(None, "user_version", DATABASE_SCHEMA_VERSION)
            .unwrap();
        drop(connection);

        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        let schema_version: u32 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let table_exists: bool = connection
            .query_row(
                r#"
                SELECT EXISTS(
                  SELECT 1
                  FROM sqlite_master
                  WHERE type = 'table' AND name = 'product_convergence_receipt'
                )
                "#,
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(schema_version, DATABASE_SCHEMA_VERSION);
        assert!(table_exists);
    }

    #[test]
    fn legacy_overlay_scale_is_canonicalized_without_weakening_closed_decoding() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("legacy-overlay.sqlite"));
        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute(
                r#"
                UPDATE settings
                SET value_json = ?2, revision = 7
                WHERE key = ?1
                "#,
                params![
                    OVERLAY_PLACEMENT_SETTING_KEY,
                    json!({
                        "x": 123.5,
                        "y": 456.25,
                        "scale": 0.72,
                        "display_id": "legacy-display"
                    })
                    .to_string()
                ],
            )
            .unwrap();
        drop(connection);

        database.init().unwrap();
        let projection = database.overlay_placement_projection().unwrap();
        assert_eq!(projection.placement.x, 123.5);
        assert_eq!(projection.placement.y, 456.25);
        assert_eq!(
            projection.placement.display_width_pt,
            DEFAULT_OVERLAY_DISPLAY_WIDTH_PT
        );
        assert_eq!(projection.placement.display_id, "legacy-display");
        assert_eq!(projection.revision, 8);

        let connection = Connection::open(database.path()).unwrap();
        let canonical: Value = connection
            .query_row(
                "SELECT value_json FROM settings WHERE key = ?1",
                params![OVERLAY_PLACEMENT_SETTING_KEY],
                |row| row.get::<_, String>(0),
            )
            .map(|value| serde_json::from_str(&value).unwrap())
            .unwrap();
        assert!(canonical.get("scale").is_none());
        assert_eq!(
            canonical["display_width_pt"],
            json!(DEFAULT_OVERLAY_DISPLAY_WIDTH_PT)
        );
        drop(connection);

        let invalid = Database::new(temp.path().join("invalid-legacy-overlay.sqlite"));
        invalid.init().unwrap();
        let connection = Connection::open(invalid.path()).unwrap();
        connection
            .execute(
                r#"
                UPDATE settings
                SET value_json = ?2
                WHERE key = ?1
                "#,
                params![
                    OVERLAY_PLACEMENT_SETTING_KEY,
                    json!({
                        "x": 1,
                        "y": 2,
                        "scale": 0.72,
                        "display_id": "legacy-display",
                        "unexpected": true
                    })
                    .to_string()
                ],
            )
            .unwrap();
        drop(connection);
        assert!(invalid.init().is_err());
    }

    #[test]
    fn previous_display_width_range_migrates_below_current_minimum_once() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("legacy-display-width.sqlite"));
        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute(
                r#"
                UPDATE settings
                SET value_json = ?2, revision = 7
                WHERE key = ?1
                "#,
                params![
                    OVERLAY_PLACEMENT_SETTING_KEY,
                    json!({
                        "x": 123.5,
                        "y": 456.25,
                        "display_width_pt": LEGACY_MIN_OVERLAY_DISPLAY_WIDTH_PT,
                        "display_id": "legacy-display"
                    })
                    .to_string()
                ],
            )
            .unwrap();
        drop(connection);

        database.init().unwrap();
        let migrated = database.overlay_placement_projection().unwrap();
        assert_eq!(
            migrated.placement.display_width_pt,
            MIN_OVERLAY_DISPLAY_WIDTH_PT
        );
        assert_eq!(migrated.placement.x, 123.5);
        assert_eq!(migrated.placement.y, 456.25);
        assert_eq!(migrated.placement.display_id, "legacy-display");
        assert_eq!(migrated.revision, 8);

        database.init().unwrap();
        let second_init = database.overlay_placement_projection().unwrap();
        assert_eq!(second_init.placement, migrated.placement);
        assert_eq!(second_init.intent, migrated.intent);
        assert_eq!(second_init.revision, migrated.revision);
    }

    #[test]
    fn current_overlay_placement_is_rejected_when_any_closed_bound_is_invalid() {
        let invalid_values = [
            r#"{"x":1,"y":2,"display_width_pt":1,"display_id":"display"}"#,
            r#"{"x":1,"y":2,"display_width_pt":112,"display_id":"   "}"#,
            r#"{"x":1e999,"y":2,"display_width_pt":112,"display_id":"display"}"#,
            r#"{"x":1,"y":-1e999,"display_width_pt":112,"display_id":"display"}"#,
        ];
        for (index, value) in invalid_values.into_iter().enumerate() {
            let temp = tempfile::tempdir().unwrap();
            let database = Database::new(
                temp.path()
                    .join(format!("invalid-current-overlay-{index}.sqlite")),
            );
            database.init().unwrap();
            let connection = Connection::open(database.path()).unwrap();
            connection
                .execute(
                    "UPDATE settings SET value_json = ?2 WHERE key = ?1",
                    params![OVERLAY_PLACEMENT_SETTING_KEY, value],
                )
                .unwrap();
            drop(connection);

            assert!(
                database.init().is_err(),
                "invalid current placement {index} must fail initialization"
            );
            assert!(
                database.overlay_placement_projection().is_err(),
                "invalid current placement {index} must fail projection"
            );
        }

        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("invalid-overlay-write.sqlite"));
        database.init().unwrap();
        let invalid = OverlayPlacement {
            x: f64::NAN,
            ..OverlayPlacement::default()
        };
        assert!(database
            .set_overlay_placement(&invalid, None, None)
            .is_err());
    }

    #[test]
    fn retired_quality_rows_are_quarantined_without_breaking_v2_pet_reads() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("retired-quality.sqlite"));
        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  states_json, petpack_path, cover_path, origin, generator,
                  provenance, active, created_at
                )
                VALUES (
                  'pet_legacy_high', 'Legacy High', 'legacy', 'high', 768, 832,
                  ?1, '/owned/legacy.petpack', '/owned/legacy-cover.png',
                  'external_import', NULL, NULL, 0, '2026-07-01T00:00:00Z'
                )
                "#,
                params![DEFAULT_PET_STATES_JSON],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  states_json, petpack_path, cover_path, origin, generator,
                  provenance, active, created_at
                )
                VALUES (
                  'pet_legacy_standard', 'Legacy Standard', 'legacy', 'standard', 192, 208,
                  ?1, '/owned/legacy-standard.petpack', '/owned/legacy-standard-cover.png',
                  'external_import', NULL, NULL, 1, '2026-07-02T00:00:00Z'
                )
                "#,
                params![DEFAULT_PET_STATES_JSON],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  states_json, petpack_path, cover_path, origin, generator,
                  provenance, active, created_at
                )
                VALUES (
                  'pet_existing_v2', 'Existing V2', 'current', 'standard', 384, 416,
                  ?1, '/owned/existing-v2.petpack', '/owned/existing-v2-cover.png',
                  'external_import', NULL, NULL, 0, '2026-07-15T00:00:00Z'
                )
                "#,
                params![DEFAULT_PET_STATES_JSON],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  states_json, petpack_path, cover_path, origin, generator,
                  provenance, active, created_at
                )
                VALUES (
                  'pet_existing_high', 'Existing High', 'current', 'high', 576, 624,
                  ?1, '/owned/existing-high.petpack', '/owned/existing-high-cover.png',
                  'external_import', NULL, NULL, 0, '2026-07-16T00:00:00Z'
                )
                "#,
                params![DEFAULT_PET_STATES_JSON],
            )
            .unwrap();
        connection.pragma_update(None, "user_version", 6).unwrap();
        drop(connection);

        database.init().unwrap();
        let live_pets = database.list_pets().unwrap();
        assert_eq!(live_pets.len(), 2);
        let existing_v2 = live_pets
            .iter()
            .find(|pet| pet.id == "pet_existing_v2")
            .unwrap();
        assert!(!existing_v2.active);
        let existing_high = live_pets
            .iter()
            .find(|pet| pet.id == "pet_existing_high")
            .unwrap();
        assert_eq!(existing_high.quality, QualityLevel::High);
        assert_eq!(existing_high.render_size, QualityLevel::High.render_size());
        assert!(existing_high.active);
        assert_eq!(live_pets.iter().filter(|pet| pet.active).count(), 1);

        let connection = Connection::open(database.path()).unwrap();
        let quarantined: (String, String, String, i64) = connection
            .query_row(
                r#"
                SELECT quality, petpack_path, retired_reason, active
                FROM retired_pet_records
                WHERE id = 'pet_legacy_high'
                "#,
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(
            quarantined,
            (
                "high".to_string(),
                "/owned/legacy.petpack".to_string(),
                "unsupported_quality".to_string(),
                0,
            )
        );
        let quarantined_standard: (String, i64) = connection
            .query_row(
                r#"
                SELECT quality, active
                FROM retired_pet_records
                WHERE id = 'pet_legacy_standard'
                "#,
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(quarantined_standard, ("standard".to_string(), 1));
        let schema_version: u32 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(schema_version, DATABASE_SCHEMA_VERSION);
        drop(connection);

        let current = PetSummary {
            id: "pet_new_v2".to_string(),
            name: "New V2 Pet".to_string(),
            style: "current".to_string(),
            quality: QualityLevel::Standard,
            render_size: QualityLevel::Standard.render_size(),
            states: decode_pet_states(DEFAULT_PET_STATES_JSON).unwrap(),
            petpack_path: "/owned/v2.petpack".to_string(),
            cover_path: "/owned/v2-cover.png".to_string(),
            origin: PetOrigin::ExternalImport,
            generator: None,
            provenance: None,
            revision_id: None,
            revision_count: 0,
            active: false,
            created_at: "2026-07-31T00:00:00Z".to_string(),
        };
        assert!(!database.upsert_pet_and_activate_if_first(&current).unwrap());
        assert!(!database.get_pet(&current.id).unwrap().unwrap().active);
        assert!(
            database
                .get_pet("pet_existing_high")
                .unwrap()
                .unwrap()
                .active
        );
    }

    #[test]
    fn removed_event_and_pet_state_data_is_converged_before_typed_projection() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("removed-contract-data.sqlite"));
        database.init().unwrap();

        let mut legacy_states = serde_json::from_str::<Value>(DEFAULT_PET_STATES_JSON).unwrap();
        let states = legacy_states.as_array_mut().unwrap();
        states[1]["name"] = json!("start");
        let mut review_state = states[4].clone();
        review_state["name"] = json!("review");
        states.insert(4, review_state);

        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute(
                r#"
                UPDATE settings
                SET value_json = ?1, revision = 41
                WHERE key = 'behavior'
                "#,
                params![json!({
                    "enabled": true,
                    "status_bubble": true,
                    "events": {
                        "start": false,
                        "tool": false,
                        "waiting": true,
                        "review": true,
                        "done": true,
                        "failed": true
                    }
                })
                .to_string()],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  states_json, petpack_path, cover_path, origin, generator,
                  provenance, active, created_at
                )
                VALUES (
                  'pet_removed_states', 'Removed states', 'legacy',
                  'standard', 384, 416, ?1, '/owned/legacy.petpack',
                  '/owned/legacy-cover.png', 'external_import', NULL, NULL, 1,
                  '2026-07-01T00:00:00Z'
                )
                "#,
                params![legacy_states.to_string()],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO agent_events (
                  external_event_id, source, project_path, session_id,
                  session_key, event_type, title, detail, payload_json,
                  created_at
                )
                VALUES (
                  'legacy-review', 'codex', NULL, 'legacy-session',
                  'legacy-session', 'review', 'legacy review', NULL, '{}',
                  '2026-07-01T00:00:00Z'
                )
                "#,
                [],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO agent_event_daily_counts (
                  event_day, source, event_type, event_count
                )
                VALUES ('2026-07-01', 'codex', 'review', 9)
                "#,
                [],
            )
            .unwrap();
        connection
            .execute(
                r#"
                INSERT INTO agent_session_aliases (
                  source, session_key, assigned_at
                )
                VALUES ('codex', 'legacy-session', '2026-07-01T00:00:00Z')
                "#,
                [],
            )
            .unwrap();
        drop(connection);

        database.init().unwrap();
        assert!(database.list_pets().unwrap().is_empty());
        let behavior = database.behavior().unwrap();
        assert_eq!(behavior.events.len(), 7);
        assert_eq!(behavior.events.get(&AgentEventType::Start), Some(&false));
        assert_eq!(behavior.events.get(&AgentEventType::Thinking), Some(&true));
        assert_eq!(behavior.events.get(&AgentEventType::Plan), Some(&true));
        assert_eq!(behavior.events.get(&AgentEventType::Tool), Some(&false));

        let connection = Connection::open(database.path()).unwrap();
        for table in ["agent_events", "agent_event_daily_counts"] {
            let query = format!("SELECT COUNT(*) FROM {table} WHERE event_type = 'review'");
            assert_eq!(
                connection
                    .query_row(&query, [], |row| row.get::<_, i64>(0))
                    .unwrap(),
                0
            );
        }
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM agent_session_aliases WHERE session_key = 'legacy-session'",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            0
        );
        let (stored_behavior, behavior_revision): (String, i64) = connection
            .query_row(
                "SELECT value_json, revision FROM settings WHERE key = 'behavior'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert!(!stored_behavior.contains("review"));
        assert!(stored_behavior.contains("thinking"));
        assert!(stored_behavior.contains("plan"));
        assert_eq!(behavior_revision, 42);
        assert_eq!(
            connection
                .query_row(
                    "SELECT retired_reason FROM retired_pet_records WHERE id = 'pet_removed_states'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "unsupported_state_contract"
        );
        drop(connection);

        database.init().unwrap();
        let connection = Connection::open(database.path()).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT revision FROM settings WHERE key = 'behavior'",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            behavior_revision
        );
    }

    #[test]
    fn every_row_from_a_pre_v2_pet_table_is_quarantined_before_projection() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("pre-v2-pets.sqlite"));
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE pets (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  style TEXT NOT NULL,
                  quality TEXT NOT NULL,
                  render_width INTEGER NOT NULL,
                  render_height INTEGER NOT NULL,
                  native_fps INTEGER NOT NULL DEFAULT 10,
                  state_durations_json TEXT NOT NULL,
                  petpack_path TEXT NOT NULL,
                  cover_path TEXT NOT NULL,
                  active INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL
                );
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  native_fps, state_durations_json, petpack_path, cover_path,
                  active, created_at
                )
                VALUES (
                  'pet_pre_v2', 'Pre-V2', 'legacy', 'standard', 384, 416,
                  20,
                  '{"idle":1000,"start":2000,"tool":1000,"waiting":2000,"review":1000,"done":2000,"failed":1000}',
                  '/owned/pre-v2.petpack', '/owned/pre-v2-cover.png',
                  1, '2026-06-01T00:00:00Z'
                );
                PRAGMA user_version = 6;
                "#,
            )
            .unwrap();
        drop(connection);

        database.init().unwrap();
        assert!(database.list_pets().unwrap().is_empty());

        let connection = Connection::open(database.path()).unwrap();
        let retired: (String, i64, String, i64, String) = connection
            .query_row(
                r#"
                SELECT quality, active, retired_reason, legacy_native_fps,
                       legacy_state_durations_json
                FROM retired_pet_records
                WHERE id = 'pet_pre_v2'
                "#,
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            retired,
            (
                "standard".to_string(),
                1,
                "unsupported_quality".to_string(),
                20,
                "{\"idle\":1000,\"start\":2000,\"tool\":1000,\"waiting\":2000,\"review\":1000,\"done\":2000,\"failed\":1000}".to_string(),
            )
        );
        assert_eq!(
            connection
                .query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        assert_eq!(
            connection
                .query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))
                .unwrap(),
            DATABASE_SCHEMA_VERSION
        );
        assert!(table_has_column(&connection, "pets", "native_fps").unwrap());
        assert!(table_has_column(&connection, "pets", "state_durations_json").unwrap());
    }

    #[test]
    fn interrupted_pre_v2_migration_still_preserves_exact_legacy_timing() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("interrupted-pre-v2.sqlite"));
        let connection = Connection::open(database.path()).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE pets (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  style TEXT NOT NULL,
                  quality TEXT NOT NULL,
                  render_width INTEGER NOT NULL,
                  render_height INTEGER NOT NULL,
                  native_fps INTEGER NOT NULL DEFAULT 10,
                  state_durations_json TEXT NOT NULL,
                  states_json TEXT NOT NULL,
                  petpack_path TEXT NOT NULL,
                  cover_path TEXT NOT NULL,
                  active INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL
                );
                PRAGMA user_version = 6;
                "#,
            )
            .unwrap();
        let legacy_timing = r#"{"idle":1000,"start":2000,"tool":1000,"waiting":2000,"review":1000,"done":2000,"failed":1000}"#;
        connection
            .execute(
                r#"
                INSERT INTO pets (
                  id, name, style, quality, render_width, render_height,
                  native_fps, state_durations_json, states_json, petpack_path,
                  cover_path, active, created_at
                )
                VALUES (
                  'pet_interrupted_v1', 'Interrupted V1', 'legacy',
                  'standard', 192, 208, 20, ?1, ?2,
                  '/owned/interrupted-v1.petpack',
                  '/owned/interrupted-v1-cover.png',
                  1, '2026-06-02T00:00:00Z'
                )
                "#,
                params![legacy_timing, DEFAULT_PET_STATES_JSON],
            )
            .unwrap();
        drop(connection);

        database.init().unwrap();
        assert!(database.list_pets().unwrap().is_empty());
        let connection = Connection::open(database.path()).unwrap();
        let preserved: (i64, String) = connection
            .query_row(
                r#"
                SELECT legacy_native_fps, legacy_state_durations_json
                FROM retired_pet_records
                WHERE id = 'pet_interrupted_v1'
                "#,
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(preserved, (20, legacy_timing.to_string()));
    }

    fn message_event(id: &str, role: &str, content: &str, created_at: &str) -> AgentEvent {
        AgentEvent {
            id: id.to_string(),
            source: AgentSource::Opencode,
            project_path: Some("/tmp/project".to_string()),
            session_id: Some("session-atomic-display".to_string()),
            event_type: AgentEventType::Start,
            title: AgentEventType::Start.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "schema_version": "apc.agent-event.v1",
                "external_event_id": id,
                "source_event": if role == "user" { "message.user" } else { "message.updated" },
                "message_role": role,
                "message_content": content,
                "diagnostic": false,
                "affects_activity": true
            }),
            created_at: created_at.to_string(),
        }
    }

    fn session_title_event(id: &str, title: &str, created_at: &str) -> AgentEvent {
        AgentEvent {
            id: id.to_string(),
            source: AgentSource::Opencode,
            project_path: Some("/tmp/project".to_string()),
            session_id: Some("session-atomic-display".to_string()),
            event_type: AgentEventType::Start,
            title: AgentEventType::Start.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "schema_version": "apc.agent-event.v1",
                "external_event_id": id,
                "source_event": "session.updated",
                "session_title": title,
                "diagnostic": false,
                "affects_activity": false
            }),
            created_at: created_at.to_string(),
        }
    }

    fn connector_event(
        id: &str,
        session_id: Option<&str>,
        source_event: &str,
        contract_version: Option<&str>,
        diagnostic: bool,
        affects_activity: bool,
    ) -> AgentEvent {
        AgentEvent {
            id: id.to_string(),
            source: AgentSource::Pi,
            project_path: Some("/tmp/project".to_string()),
            session_id: session_id.map(ToOwned::to_owned),
            event_type: AgentEventType::Start,
            title: AgentEventType::Start.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "schema_version": "apc.agent-event.v1",
                "external_event_id": id,
                "source_event": source_event,
                "contract_version": contract_version,
                "diagnostic": diagnostic,
                "affects_activity": affects_activity
            }),
            created_at: retained_event_timestamp(0),
        }
    }

    struct CodexRuntimeMarkerFixture<'a> {
        id: &'a str,
        session_id: &'a str,
        turn_id: Option<&'a str>,
        source_event: &'a str,
        contract_version: &'a str,
        diagnostic: bool,
        surface: &'a str,
        terminal_app: Option<&'a str>,
        session_open_url: Option<&'a str>,
    }

    impl<'a> CodexRuntimeMarkerFixture<'a> {
        fn new(
            id: &'a str,
            session_id: &'a str,
            turn_id: Option<&'a str>,
            source_event: &'a str,
            surface: &'a str,
        ) -> Self {
            Self {
                id,
                session_id,
                turn_id,
                source_event,
                contract_version: CODEX_HOOKS_CONTRACT_VERSION,
                diagnostic: false,
                surface,
                terminal_app: None,
                session_open_url: None,
            }
        }

        fn with_contract_version(mut self, contract_version: &'a str) -> Self {
            self.contract_version = contract_version;
            self
        }

        fn diagnostic(mut self) -> Self {
            self.diagnostic = true;
            self
        }

        fn terminal(mut self, terminal_app: &'a str, session_open_url: Option<&'a str>) -> Self {
            self.terminal_app = Some(terminal_app);
            self.session_open_url = session_open_url;
            self
        }
    }

    fn codex_runtime_marker(fixture: CodexRuntimeMarkerFixture<'_>) -> AgentEvent {
        AgentEvent {
            id: fixture.id.to_string(),
            source: AgentSource::Codex,
            project_path: None,
            session_id: Some(fixture.session_id.to_string()),
            event_type: AgentEventType::Start,
            title: AgentEventType::Start.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "schema_version": "apc.agent-event.v1",
                "external_event_id": fixture.id,
                "source_event": fixture.source_event,
                "contract_version": fixture.contract_version,
                "diagnostic": fixture.diagnostic,
                "affects_activity": fixture.source_event != "SessionStart",
                "turn_id": fixture.turn_id,
                "session_active": fixture.source_event != "SessionStart",
                "session_open": null,
                "session_surface": fixture.surface,
                "terminal_app": fixture.terminal_app,
                "session_open_url": fixture.session_open_url
            }),
            created_at: retained_event_timestamp(0),
        }
    }

    #[test]
    fn pet_studio_generation_session_is_suppressed_and_legacy_rows_are_scrubbed() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        let session_id = "019f5b0f-88ff-7413-8953-29de4ed0951c";
        let form = GenerationForm {
            description: "Private Studio task".to_string(),
            style: "半写实".to_string(),
            quality: QualityLevel::Standard,
            reference_images: Vec::new(),
        };
        let job_dir = temp.path().join("job_private");
        database
            .create_generation_job("job_private_studio", &form, &job_dir)
            .unwrap();

        let legacy = codex_runtime_marker(CodexRuntimeMarkerFixture::new(
            "studio-hook-before-link",
            session_id,
            Some("turn-studio"),
            "PreToolUse",
            "chatgpt_app",
        ));
        assert_eq!(
            database.insert_event(&legacy).unwrap(),
            InsertEventOutcome::Inserted
        );
        database
            .update_generation_job_session("job_private_studio", session_id)
            .unwrap();

        // Startup migration removes the row emitted before the job/session
        // link was durable and records the exact identity for future hooks.
        database.init().unwrap();
        assert!(database.recent_events(10).unwrap().is_empty());
        let later = codex_runtime_marker(CodexRuntimeMarkerFixture::new(
            "studio-hook-after-link",
            session_id,
            Some("turn-studio"),
            "PostToolUse",
            "chatgpt_app",
        ));
        assert_eq!(
            database.insert_event(&later).unwrap(),
            InsertEventOutcome::Suppressed
        );
        let connection = Connection::open(database.path()).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT reason FROM suppressed_agent_sessions WHERE source = 'codex' AND session_key = ?1",
                    params![normalized_session_key(Some(session_id))],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            PET_STUDIO_INTERNAL_SESSION_REASON
        );
    }

    #[test]
    fn codex_runtime_surface_history_is_bounded_and_uses_latest_trusted_current_turn_marker() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        let mut current_cli_old = codex_runtime_marker(
            CodexRuntimeMarkerFixture::new(
                "current-cli-old",
                "current-session",
                Some("turn-2"),
                "PreToolUse",
                "cli_terminal",
            )
            .terminal(
                "warp",
                Some("warp://session/0123456789abcdef0123456789abcdef"),
            ),
        );
        current_cli_old.created_at = retained_event_timestamp(10);
        let mut current_app_new = codex_runtime_marker(CodexRuntimeMarkerFixture::new(
            "current-app-new",
            "current-session",
            Some("turn-2"),
            "PostToolUse",
            "chatgpt_app",
        ));
        current_app_new.created_at = retained_event_timestamp(1);
        for marker in [
            current_cli_old,
            current_app_new,
            codex_runtime_marker(
                CodexRuntimeMarkerFixture::new(
                    "prior-turn",
                    "ambiguous-session",
                    Some("turn-1"),
                    "UserPromptSubmit",
                    "cli_terminal",
                )
                .terminal("iterm2", None),
            ),
            codex_runtime_marker(CodexRuntimeMarkerFixture::new(
                "session-start",
                "session-start-only",
                None,
                "SessionStart",
                "chatgpt_app",
            )),
            codex_runtime_marker(
                CodexRuntimeMarkerFixture::new(
                    "stale-contract",
                    "untrusted-session",
                    Some("turn-2"),
                    "PreToolUse",
                    "chatgpt_app",
                )
                .with_contract_version("codex-hooks-stale"),
            ),
            codex_runtime_marker(
                CodexRuntimeMarkerFixture::new(
                    "diagnostic",
                    "diagnostic-session",
                    Some("turn-2"),
                    "PreToolUse",
                    "chatgpt_app",
                )
                .diagnostic(),
            ),
            codex_runtime_marker(
                CodexRuntimeMarkerFixture::new(
                    "invalid-combination",
                    "invalid-session",
                    Some("turn-2"),
                    "PreToolUse",
                    "chatgpt_app",
                )
                .terminal("terminal", None),
            ),
            codex_runtime_marker(CodexRuntimeMarkerFixture::new(
                "probe",
                "probe-session",
                Some("turn-2"),
                "connector.probe",
                "chatgpt_app",
            )),
        ] {
            database.insert_event(&marker).unwrap();
        }
        let mut app_server_poll = codex_runtime_marker(CodexRuntimeMarkerFixture::new(
            "app-server-current-turn",
            "current-session",
            Some("turn-2"),
            "app_server_activity",
            "cli_terminal",
        ));
        app_server_poll.event_type = AgentEventType::Tool;
        database
            .upsert_codex_activity_event(&app_server_poll)
            .unwrap();
        app_server_poll.payload_json["activity_content"] = json!("second poll");
        database
            .upsert_codex_activity_event(&app_server_poll)
            .unwrap();

        let histories = database
            .codex_runtime_surface_history(&[
                ("current-session".to_string(), Some("turn-2".to_string())),
                ("ambiguous-session".to_string(), Some("turn-2".to_string())),
                ("session-start-only".to_string(), Some("turn-2".to_string())),
                ("untrusted-session".to_string(), Some("turn-2".to_string())),
                ("diagnostic-session".to_string(), Some("turn-2".to_string())),
                ("invalid-session".to_string(), Some("turn-2".to_string())),
                ("probe-session".to_string(), Some("turn-2".to_string())),
            ])
            .unwrap();

        let current = &histories["current-session"];
        assert!(current.has_any_trusted_marker);
        assert_eq!(
            current
                .latest_current_turn_marker
                .as_ref()
                .map(|marker| marker.event.id.as_str()),
            Some("current-app-new")
        );
        for session_id in ["ambiguous-session", "session-start-only"] {
            assert!(histories[session_id].has_any_trusted_marker);
            assert!(histories[session_id].latest_current_turn_marker.is_none());
        }
        for session_id in [
            "untrusted-session",
            "diagnostic-session",
            "invalid-session",
            "probe-session",
        ] {
            assert!(!histories[session_id].has_any_trusted_marker);
            assert!(histories[session_id].latest_current_turn_marker.is_none());
        }

        let mut at_limit_with_duplicate = (0..8)
            .map(|index| (format!("session-{index}"), Some("turn-2".to_string())))
            .collect::<Vec<_>>();
        at_limit_with_duplicate.push(("session-0".to_string(), Some("turn-3".to_string())));
        assert_eq!(
            database
                .codex_runtime_surface_history(&at_limit_with_duplicate)
                .unwrap()
                .len(),
            8
        );
        let oversized = (0..9)
            .map(|index| (format!("session-{index}"), Some("turn-2".to_string())))
            .collect::<Vec<_>>();
        assert!(matches!(
            database.codex_runtime_surface_history(&oversized),
            Err(PetCoreError::InvalidRequest(_))
        ));
    }

    #[test]
    fn listed_codex_task_repairs_only_its_synthetic_app_server_closure() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        let listed_thread = "019f5b0f-88ff-7413-8953-29de4ed0951c";
        let other_thread = "019f5b0f-88ff-7413-8953-29de4ed0951d";

        let mut prior_hook = codex_runtime_marker(CodexRuntimeMarkerFixture::new(
            "prior-hook-completion",
            listed_thread,
            Some("turn-1"),
            "Stop",
            "chatgpt_app",
        ));
        prior_hook.event_type = AgentEventType::Done;
        database.insert_event(&prior_hook).unwrap();

        let closure = |thread_id: &str| {
            let mut event = codex_runtime_marker(CodexRuntimeMarkerFixture::new(
                "placeholder",
                thread_id,
                Some("turn-1"),
                "app_server_activity",
                "chatgpt_app",
            ));
            event.id = format!("evt_codex_app_server_status_{thread_id}_turn-1");
            event.event_type = AgentEventType::Done;
            event.payload_json["outcome"] = json!("session_closed");
            event.payload_json["session_active"] = json!(false);
            event.payload_json["session_open"] = json!(false);
            event.created_at = retained_event_timestamp(60);
            event
        };
        let listed_closure = closure(listed_thread);
        let other_closure = closure(other_thread);
        database
            .upsert_codex_activity_event(&listed_closure)
            .unwrap();
        database
            .upsert_codex_activity_event(&other_closure)
            .unwrap();
        let before_revision = database.state_revision().unwrap();

        assert_eq!(
            database
                .reconcile_listed_codex_activity_sessions(&BTreeMap::from([(
                    listed_thread.to_string(),
                    "chatgpt_app".to_string(),
                )]))
                .unwrap(),
            1
        );
        assert!(database.state_revision().unwrap() > before_revision);
        let retained = database.recent_events(10).unwrap();
        let retained_ids = retained
            .iter()
            .map(|event| event.id.clone())
            .collect::<BTreeSet<_>>();
        assert!(retained_ids.contains("prior-hook-completion"));
        assert!(retained_ids.contains(&listed_closure.id));
        assert!(retained_ids.contains(&other_closure.id));
        let repaired = retained
            .iter()
            .find(|event| event.id == listed_closure.id)
            .unwrap();
        assert_eq!(
            repaired
                .payload_json
                .get("session_open")
                .and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            repaired
                .payload_json
                .get("session_surface")
                .and_then(Value::as_str),
            Some("chatgpt_app")
        );
        assert!(repaired.payload_json.get("outcome").is_none());
        let navigation = crate::agent_state::overlay_navigation(repaired);
        assert_eq!(
            navigation.capability,
            crate::agent_state::OverlayNavigationCapability::ExactSession
        );
        assert_eq!(
            navigation.routable_session_id.as_deref(),
            Some(listed_thread)
        );
        let untouched = retained
            .iter()
            .find(|event| event.id == other_closure.id)
            .unwrap();
        assert_eq!(
            untouched
                .payload_json
                .get("session_open")
                .and_then(Value::as_bool),
            Some(false)
        );

        let reconciled_revision = database.state_revision().unwrap();
        assert_eq!(
            database
                .reconcile_listed_codex_activity_sessions(&BTreeMap::from([(
                    listed_thread.to_string(),
                    "chatgpt_app".to_string(),
                )]))
                .unwrap(),
            0
        );
        assert_eq!(database.state_revision().unwrap(), reconciled_revision);
        assert!(matches!(
            database.reconcile_listed_codex_activity_sessions(&BTreeMap::from([(
                "not-a-codex-task".to_string(),
                "chatgpt_app".to_string(),
            )])),
            Err(PetCoreError::InvalidRequest(_))
        ));
    }

    fn matched_projection(
        result: RevisionChecked<SessionMessageProjection>,
    ) -> SessionMessageProjection {
        match result {
            RevisionChecked::Matched { value, .. } => value,
            RevisionChecked::Mismatch {
                expected_revision,
                actual_revision,
            } => panic!(
                "expected matched projection, got revision {actual_revision} instead of {expected_revision}"
            ),
        }
    }

    #[test]
    fn revision_checked_display_projections_match_one_database_snapshot() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        for event in [
            message_event(
                "user-first",
                "user",
                "first prompt",
                &retained_event_timestamp(0),
            ),
            message_event(
                "assistant-first",
                "assistant",
                "first answer",
                &retained_event_timestamp(1),
            ),
            message_event(
                "user-latest",
                "user",
                "next prompt",
                &retained_event_timestamp(2),
            ),
            message_event(
                "assistant-empty",
                "assistant",
                "   ",
                &retained_event_timestamp(3),
            ),
            message_event(
                "assistant-latest",
                "assistant",
                "latest answer",
                &retained_event_timestamp(4),
            ),
            session_title_event(
                "title-latest",
                "Generated session title",
                &retained_event_timestamp(5),
            ),
        ] {
            assert_eq!(
                database.insert_event(&event).unwrap(),
                InsertEventOutcome::Inserted
            );
        }

        let revision = database.state_revision().unwrap();
        let projection = matched_projection(
            database
                .session_message_projection_at_revision(
                    revision,
                    AgentSource::Opencode,
                    Some("session-atomic-display"),
                )
                .unwrap(),
        );
        assert_eq!(
            projection.latest_assistant.unwrap().event.id,
            "assistant-latest"
        );
        assert_eq!(projection.latest_user.unwrap().event.id, "user-latest");
        assert_eq!(projection.first_user.unwrap().id, "user-first");
        assert_eq!(projection.latest_title.unwrap().id, "title-latest");

        match database.recent_events_at_revision(revision, 3).unwrap() {
            RevisionChecked::Matched {
                state_revision,
                value,
            } => {
                assert_eq!(state_revision, revision);
                assert_eq!(
                    value
                        .iter()
                        .map(|event| event.id.as_str())
                        .collect::<Vec<_>>(),
                    ["title-latest", "assistant-latest", "assistant-empty"]
                );
            }
            RevisionChecked::Mismatch { .. } => panic!("revision unexpectedly changed"),
        }
    }

    #[test]
    fn revision_checked_display_projections_return_mismatch_after_write() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        database
            .insert_event(&message_event(
                "before",
                "user",
                "before",
                &retained_event_timestamp(0),
            ))
            .unwrap();
        let old_revision = database.state_revision().unwrap();
        // Deliberately bypass typed ingestion and add an unreadable payload.
        // A stale expected revision must short-circuit before either projection
        // attempts to deserialize this newer row.
        Connection::open(database.path())
            .unwrap()
            .execute(
                r#"
                INSERT INTO agent_events
                  (external_event_id, source, project_path, session_id, session_key,
                   event_type, title, detail, payload_json, created_at)
                VALUES (?1, ?2, NULL, ?3, ?3, ?4, ?5, NULL, ?6, ?7)
                "#,
                params![
                    "unreadable-after",
                    enum_name(AgentSource::Opencode),
                    "session-atomic-display",
                    enum_name(AgentEventType::Start),
                    AgentEventType::Start.zh_label(),
                    "{not-json",
                    retained_event_timestamp(1),
                ],
            )
            .unwrap();
        let current_revision = database.state_revision().unwrap();
        assert!(current_revision > old_revision);

        let session_mismatch = database
            .session_message_projection_at_revision(
                old_revision,
                AgentSource::Opencode,
                Some("session-atomic-display"),
            )
            .unwrap();
        let recent_mismatch = database.recent_events_at_revision(old_revision, 8).unwrap();
        let assert_mismatch = |expected_revision, actual_revision| {
            assert_eq!(expected_revision, old_revision);
            assert_eq!(actual_revision, current_revision);
        };
        match session_mismatch {
            RevisionChecked::Mismatch {
                expected_revision,
                actual_revision,
            } => assert_mismatch(expected_revision, actual_revision),
            RevisionChecked::Matched { .. } => panic!("stale revision unexpectedly matched"),
        }
        match recent_mismatch {
            RevisionChecked::Mismatch {
                expected_revision,
                actual_revision,
            } => assert_mismatch(expected_revision, actual_revision),
            RevisionChecked::Matched { .. } => panic!("stale revision unexpectedly matched"),
        }
    }

    #[test]
    fn deferred_projection_transaction_keeps_old_rows_during_concurrent_write() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        database
            .insert_event(&message_event(
                "before",
                "user",
                "before",
                &retained_event_timestamp(0),
            ))
            .unwrap();

        let mut connection = database.open().unwrap();
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Deferred)
            .unwrap();
        let snapshot_revision = state_revision_in_connection(&transaction).unwrap();

        let writer_database = database.clone();
        std::thread::spawn(move || {
            writer_database
                .insert_event(&message_event(
                    "concurrent",
                    "assistant",
                    "concurrent answer",
                    &retained_event_timestamp(1),
                ))
                .unwrap();
        })
        .join()
        .unwrap();

        let projection = session_message_projection_in_connection(
            &transaction,
            AgentSource::Opencode,
            Some("session-atomic-display"),
        )
        .unwrap();
        assert!(projection.latest_assistant.is_none());
        assert_eq!(projection.latest_user.unwrap().event.id, "before");
        assert_eq!(
            state_revision_in_connection(&transaction).unwrap(),
            snapshot_revision
        );
        transaction.commit().unwrap();

        match database
            .session_message_projection_at_revision(
                snapshot_revision,
                AgentSource::Opencode,
                Some("session-atomic-display"),
            )
            .unwrap()
        {
            RevisionChecked::Mismatch {
                expected_revision,
                actual_revision,
            } => {
                assert_eq!(expected_revision, snapshot_revision);
                assert!(actual_revision > snapshot_revision);
            }
            RevisionChecked::Matched { .. } => panic!("concurrent write was not detected"),
        }
    }

    #[test]
    fn opencode_task_evidence_accepts_only_semantic_terminal_outcomes() {
        const COMPLETIONS: &[&str] = &[
            "session.status",
            "session.error",
            "session.next.step.ended",
            "session.next.step.failed",
        ];
        let matches = |source_event: &str, event_type: &str, outcome: &str, active: bool| {
            let payload = serde_json::from_value(json!({
                "outcome": outcome,
                "session_active": active
            }))
            .unwrap();
            task_evidence_event_matches(
                AgentSource::Opencode,
                COMPLETIONS,
                source_event,
                &payload,
                event_type,
            )
        };

        assert!(matches("session.status", "done", "idle", false));
        assert!(!matches("session.status", "start", "idle", false));
        assert!(!matches("session.status", "done", "busy", false));
        assert!(!matches("session.status", "done", "idle", true));
        assert!(matches(
            "session.next.step.ended",
            "done",
            "completed",
            false
        ));
        assert!(matches(
            "session.next.step.ended",
            "failed",
            "session_failure",
            false
        ));
        assert!(!matches(
            "session.next.step.ended",
            "start",
            "continued",
            true
        ));
        assert!(matches(
            "session.next.step.failed",
            "failed",
            "session_failure",
            false
        ));
        assert!(matches("session.error", "failed", "session_failure", false));
    }

    #[test]
    fn connector_evidence_summary_matches_independent_receipt_queries_in_one_projection() {
        const CURRENT_CONTRACT: &str = "apc.pi-extension.v-test";
        const STALE_CONTRACT: &str = "apc.pi-extension.v-old";
        const STARTS: &[&str] = &["input", "agent_start"];
        const ACTIVITIES: &[&str] = &["tool_call", "tool_execution_start"];
        const COMPLETIONS: &[&str] = &["tool_execution_end", "agent_settled"];

        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("events.sqlite"));
        database.init().unwrap();
        for event in [
            connector_event(
                "task-start",
                Some("task-session"),
                "input",
                Some(CURRENT_CONTRACT),
                false,
                true,
            ),
            connector_event(
                "task-activity",
                Some("task-session"),
                "tool_call",
                Some(CURRENT_CONTRACT),
                false,
                true,
            ),
            connector_event(
                "task-completion",
                Some("task-session"),
                "tool_execution_end",
                Some(CURRENT_CONTRACT),
                false,
                true,
            ),
            connector_event(
                "current-probe",
                Some("probe-session"),
                "connector.probe",
                Some(CURRENT_CONTRACT),
                true,
                false,
            ),
            connector_event(
                "passive-current",
                Some("passive-session"),
                "session_start",
                Some(CURRENT_CONTRACT),
                false,
                false,
            ),
            connector_event(
                "newer-stale",
                Some("stale-session"),
                "turn_end",
                Some(STALE_CONTRACT),
                false,
                true,
            ),
            connector_event(
                "excluded-newest",
                Some("diagnostic-session"),
                "connection.test",
                Some(STALE_CONTRACT),
                false,
                true,
            ),
        ] {
            assert_eq!(
                database.insert_event(&event).unwrap(),
                InsertEventOutcome::Inserted
            );
        }

        let expected_observed = database
            .latest_connector_event_receipt_for_contract(AgentSource::Pi, false, CURRENT_CONTRACT)
            .unwrap();
        let expected_ordinary = database
            .latest_connector_ordinary_receipt_for_contract(AgentSource::Pi, CURRENT_CONTRACT)
            .unwrap();
        let expected_diagnostic = database
            .latest_connector_event_receipt_for_contract(AgentSource::Pi, true, CURRENT_CONTRACT)
            .unwrap();
        let expected_real_start = STARTS
            .iter()
            .filter_map(|source_event| {
                database
                    .latest_connector_event_receipt_for_source_event(
                        AgentSource::Pi,
                        false,
                        source_event,
                    )
                    .unwrap()
                    .filter(|receipt| receipt.contract_version.as_deref() == Some(CURRENT_CONTRACT))
            })
            .max_by_key(|receipt| receipt.sequence);
        let expected_task = database
            .latest_connector_task_receipt_for_contract(
                AgentSource::Pi,
                CURRENT_CONTRACT,
                STARTS,
                ACTIVITIES,
                COMPLETIONS,
            )
            .unwrap();
        let latest_current_sequence = [expected_observed.as_ref(), expected_diagnostic.as_ref()]
            .into_iter()
            .flatten()
            .map(|receipt| receipt.sequence)
            .max();
        let expected_newer_stale = [false, true]
            .into_iter()
            .filter_map(|diagnostic| {
                database
                    .latest_connector_event_receipt(AgentSource::Pi, diagnostic)
                    .unwrap()
                    .filter(|receipt| receipt.contract_version.as_deref() != Some(CURRENT_CONTRACT))
                    .filter(|receipt| {
                        latest_current_sequence.is_none_or(|current| receipt.sequence > current)
                    })
            })
            .max_by_key(|receipt| receipt.sequence);

        let summary = database
            .connector_evidence_summary(
                AgentSource::Pi,
                CURRENT_CONTRACT,
                STARTS,
                ACTIVITIES,
                COMPLETIONS,
            )
            .unwrap();
        assert_eq!(summary.observed_receipt, expected_observed);
        assert_eq!(summary.ordinary_receipt, expected_ordinary);
        assert_eq!(summary.diagnostic_receipt, expected_diagnostic);
        assert_eq!(summary.real_start_receipt, expected_real_start);
        assert_eq!(summary.task_receipt, expected_task);
        assert_eq!(summary.newer_stale_receipt, expected_newer_stale);
        assert_eq!(
            summary
                .ordinary_receipt
                .as_ref()
                .map(|receipt| receipt.source_event.as_str()),
            Some("tool_execution_end")
        );
        assert_eq!(
            summary
                .observed_receipt
                .as_ref()
                .map(|receipt| receipt.source_event.as_str()),
            Some("session_start")
        );
        assert_eq!(
            summary
                .newer_stale_receipt
                .as_ref()
                .map(|receipt| receipt.source_event.as_str()),
            Some("turn_end")
        );

        database
            .insert_event(&connector_event(
                "stale-start-shadows-current",
                Some("stale-session"),
                "input",
                Some(STALE_CONTRACT),
                false,
                true,
            ))
            .unwrap();
        assert!(database
            .connector_evidence_summary(
                AgentSource::Pi,
                CURRENT_CONTRACT,
                STARTS,
                ACTIVITIES,
                COMPLETIONS,
            )
            .unwrap()
            .real_start_receipt
            .is_none());

        database
            .insert_event(&connector_event(
                "newest-current",
                Some("passive-session"),
                "session_shutdown",
                Some(CURRENT_CONTRACT),
                false,
                false,
            ))
            .unwrap();
        assert!(database
            .connector_evidence_summary(
                AgentSource::Pi,
                CURRENT_CONTRACT,
                STARTS,
                ACTIVITIES,
                COMPLETIONS,
            )
            .unwrap()
            .newer_stale_receipt
            .is_none());
    }
}
