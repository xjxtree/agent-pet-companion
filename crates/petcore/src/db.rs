use crate::agent_session_filters::{
    is_codex_internal_suggestions_prompt, suppressed_agent_session_reason,
    CODEX_INTERNAL_SUGGESTIONS_REASON,
};
use crate::agent_state::SequencedAgentEvent;
use crate::event_envelope::{
    minimal_legacy_payload, normalized_session_id, normalized_session_key, persisted_payload,
    source_event_proves_ordinary_activity, MAX_RECENT_EVENTS,
};
use crate::{enum_from_name, enum_name, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentEvent, AgentEventType, AgentSource, AppearanceTheme,
    BehaviorSettings, FpsProfileName, GenerationForm, GenerationJobStatus, GenerationMessageRecord,
    OnboardingProgress, OnboardingStage, OverlayPlacement, PetOrigin, PetStateName, PetSummary,
    QualityLevel, RenderSize, SessionGroupDisplay, LONG_ACTION_DURATION_MS,
    MAX_BUBBLE_TRANSPARENCY, MAX_SESSION_MESSAGE_TIMEOUT_MINUTES, MIN_BUBBLE_TRANSPARENCY,
    MIN_SESSION_MESSAGE_TIMEOUT_MINUTES, ONBOARDING_PROGRESS_SCHEMA_VERSION, REQUIRED_STATES,
    SHORT_ACTION_DURATION_MS, SMOOTH_FPS, STANDARD_FPS,
};
use rusqlite::{params, Connection, ErrorCode, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DATABASE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_GENERATION_HISTORY_QUERY_LIMIT: usize = 33;
const ONBOARDING_PROGRESS_SETTING_KEY: &str = "onboarding_progress";
pub const PRODUCT_CONVERGENCE_RECEIPT_SCHEMA_VERSION: &str = "apc.product-convergence-receipt.v1";

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
    pub created_at: String,
    pub updated_at: String,
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

fn task_evidence_event_matches(
    source: AgentSource,
    candidates: &[&str],
    source_event: &str,
    payload: &Value,
    event_type: &str,
) -> bool {
    if !candidates.contains(&source_event) {
        return false;
    }
    if source != AgentSource::Opencode {
        return true;
    }
    let inactive = payload.get("session_active").and_then(Value::as_bool) == Some(false);
    match source_event {
        "session.status" => {
            event_type == "done"
                && inactive
                && payload.get("outcome").and_then(Value::as_str) == Some("idle")
        }
        "session.next.step.ended" => match payload.get("outcome").and_then(Value::as_str) {
            Some("completed") => event_type == "done" && inactive,
            Some("session_failure") => event_type == "failed" && inactive,
            _ => false,
        },
        "session.next.step.failed" => {
            event_type == "failed"
                && inactive
                && payload.get("outcome").and_then(Value::as_str) == Some("session_failure")
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
    pub appearance_theme: Option<AppearanceTheme>,
    pub bubble_transparency: Option<f64>,
    pub click_menu: Option<bool>,
    pub mouse_passthrough: Option<bool>,
    pub auto_hide: Option<bool>,
    pub session_group_display: Option<SessionGroupDisplay>,
    pub session_message_timeout_minutes: Option<u16>,
    pub fps_profile: Option<FpsProfileName>,
    pub sources: Option<BTreeMap<AgentSource, bool>>,
    pub events: Option<BTreeMap<AgentEventType, bool>>,
}

impl BehaviorSettingsPatch {
    fn is_empty(&self) -> bool {
        self.enabled.is_none()
            && self.status_bubble.is_none()
            && self.appearance_theme.is_none()
            && self.bubble_transparency.is_none()
            && self.click_menu.is_none()
            && self.mouse_passthrough.is_none()
            && self.auto_hide.is_none()
            && self.session_group_display.is_none()
            && self.session_message_timeout_minutes.is_none()
            && self.fps_profile.is_none()
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
        if let Some(value) = self.appearance_theme {
            behavior.appearance_theme = value;
        }
        if let Some(value) = self.bubble_transparency {
            behavior.bubble_transparency = value;
        }
        if let Some(value) = self.click_menu {
            behavior.click_menu = value;
        }
        if let Some(value) = self.mouse_passthrough {
            behavior.mouse_passthrough = value;
        }
        if let Some(value) = self.auto_hide {
            behavior.auto_hide = value;
        }
        if let Some(value) = self.session_group_display {
            behavior.session_group_display = value;
        }
        if let Some(value) = self.session_message_timeout_minutes {
            behavior.session_message_timeout_minutes = value;
        }
        if let Some(value) = self.fps_profile {
            behavior.fps_profile = value;
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

#[derive(Debug, Clone, Default)]
pub(crate) struct SessionMessageProjection {
    pub(crate) latest_assistant: Option<SequencedAgentEvent>,
    pub(crate) latest_user: Option<SequencedAgentEvent>,
    pub(crate) first_user: Option<AgentEvent>,
}

impl Default for EventRetentionPolicy {
    fn default() -> Self {
        Self {
            max_rows: 10_000,
            max_age_days: 30,
        }
    }
}

// Schema 6 adds the smallest durable authority needed for content-free,
// stable anonymous-session aliases. Runtime replacement preflight blocks a
// schema-5 daemon from opening the upgraded database.
//
// `product_convergence_receipt` is an additive singleton table and
// intentionally remains compatible with schema-6 last-known-good runtimes:
// an older runtime ignores it, so a failed binary replacement can still roll
// back without turning a successful receipt write into a downgrade blocker.
pub const DATABASE_SCHEMA_VERSION: u32 = 6;
const DEFAULT_STATE_DURATIONS_JSON: &str = r#"{"idle":2000,"start":1000,"tool":2000,"waiting":2000,"review":2000,"done":1000,"failed":2000}"#;
const EVENT_PRIVACY_MIGRATION_KEY: &str = "event-envelope-v4-secure-vacuum";
const SUPPRESSED_AGENT_SESSION_RETENTION_DAYS: u32 = 30;
const MAX_SUPPRESSED_AGENT_SESSIONS: usize = 10_000;

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
        let connection = Connection::open(&self.path)?;
        connection.busy_timeout(DATABASE_BUSY_TIMEOUT)?;
        Ok(connection)
    }

    pub fn init(&self) -> Result<()> {
        if self.has_invalid_sqlite_header()? {
            self.backup_corrupt_database()?;
            return self.init_schema();
        }

        match self.init_schema() {
            Ok(()) => Ok(()),
            Err(error) if is_recoverable_corruption(&error) => {
                self.backup_corrupt_database()?;
                self.init_schema()
            }
            Err(error) => Err(error),
        }
    }

    pub fn preflight_compatibility(&self) -> Result<u32> {
        if !self.path.exists() {
            return Ok(0);
        }
        if self.has_invalid_sqlite_header()? {
            return Err(PetCoreError::Validation(
                "database preflight rejected an invalid SQLite header".to_string(),
            ));
        }
        let connection = Connection::open_with_flags(
            &self.path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        let schema_version: u32 =
            connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if schema_version > DATABASE_SCHEMA_VERSION {
            return Err(PetCoreError::Validation(format!(
                "database schema {schema_version} is newer than this PetCore supports ({DATABASE_SCHEMA_VERSION}); downgrade is blocked"
            )));
        }
        let quick_check: String =
            connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if !quick_check.eq_ignore_ascii_case("ok") {
            return Err(PetCoreError::Validation(format!(
                "database preflight quick_check failed: {quick_check}"
            )));
        }
        Ok(schema_version)
    }

    fn init_schema(&self) -> Result<()> {
        let mut connection = self.open()?;
        let previous_schema_version: u32 =
            connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if previous_schema_version > DATABASE_SCHEMA_VERSION {
            return Err(PetCoreError::Validation(format!(
                "database schema {previous_schema_version} is newer than this PetCore supports ({DATABASE_SCHEMA_VERSION}); downgrade is blocked"
            )));
        }
        connection.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;

            CREATE TABLE IF NOT EXISTS pets (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              style TEXT NOT NULL,
              quality TEXT NOT NULL,
              render_width INTEGER NOT NULL,
              render_height INTEGER NOT NULL,
              native_fps INTEGER NOT NULL DEFAULT 10,
              state_durations_json TEXT NOT NULL DEFAULT '{"idle":2000,"start":1000,"tool":2000,"waiting":2000,"review":2000,"done":1000,"failed":2000}',
              petpack_path TEXT NOT NULL,
              cover_path TEXT NOT NULL,
              origin TEXT NOT NULL DEFAULT 'external_import',
              generator TEXT,
              provenance TEXT,
              active INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS generation_jobs (
              id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              form_json TEXT NOT NULL,
              session_id TEXT,
              job_dir TEXT NOT NULL,
              result_pet_id TEXT,
              retry_of_job_id TEXT,
              owner_instance_id TEXT,
              heartbeat_at TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS generation_messages (
              id TEXT PRIMARY KEY,
              job_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              role TEXT NOT NULL,
              kind TEXT,
              content TEXT NOT NULL,
              progress REAL NOT NULL,
              created_at TEXT NOT NULL,
              diagnostic_json TEXT,
              UNIQUE(job_id, sequence),
              FOREIGN KEY(job_id) REFERENCES generation_jobs(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS generation_messages_job_sequence
              ON generation_messages(job_id, sequence);

            DROP INDEX IF EXISTS generation_terminal_message_kind;
            DROP INDEX IF EXISTS generation_terminal_message;

            CREATE TABLE IF NOT EXISTS generation_message_migrations (
              job_id TEXT PRIMARY KEY,
              migrated_at TEXT NOT NULL,
              FOREIGN KEY(job_id) REFERENCES generation_jobs(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS agent_events (
              row_id INTEGER PRIMARY KEY AUTOINCREMENT,
              external_event_id TEXT NOT NULL,
              source TEXT NOT NULL,
              project_path TEXT,
              session_id TEXT,
              session_key TEXT NOT NULL,
              event_type TEXT NOT NULL,
              title TEXT,
              detail TEXT,
              payload_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              UNIQUE(source, session_key, external_event_id)
            );

            CREATE TABLE IF NOT EXISTS agent_event_daily_counts (
              event_day TEXT NOT NULL,
              source TEXT NOT NULL,
              event_type TEXT NOT NULL,
              event_count INTEGER NOT NULL,
              PRIMARY KEY(event_day, source, event_type)
            );

            CREATE TABLE IF NOT EXISTS suppressed_agent_sessions (
              source TEXT NOT NULL,
              session_key TEXT NOT NULL,
              reason TEXT NOT NULL,
              suppressed_at TEXT NOT NULL,
              PRIMARY KEY(source, session_key)
            );

            CREATE TABLE IF NOT EXISTS agent_session_aliases (
              alias_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL,
              session_key TEXT NOT NULL,
              assigned_at TEXT NOT NULL,
              UNIQUE(source, session_key)
            );

            CREATE TABLE IF NOT EXISTS privacy_migrations (
              migration_key TEXT PRIMARY KEY,
              phase TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pet_asset_validation (
              pet_id TEXT PRIMARY KEY,
              fingerprint TEXT NOT NULL,
              valid INTEGER NOT NULL,
              error TEXT,
              validated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value_json TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0)
            );

            CREATE TABLE IF NOT EXISTS product_convergence_receipt (
              singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
              schema_version TEXT NOT NULL
                CHECK(schema_version = 'apc.product-convergence-receipt.v1'),
              build_id TEXT NOT NULL CHECK(length(build_id) BETWEEN 1 AND 128),
              app_version TEXT NOT NULL CHECK(length(app_version) BETWEEN 1 AND 128),
              completed_at TEXT NOT NULL CHECK(length(completed_at) BETWEEN 20 AND 64),
              connector_total_sources INTEGER NOT NULL
                CHECK(connector_total_sources BETWEEN 0 AND 4),
              connector_managed_sources INTEGER NOT NULL
                CHECK(connector_managed_sources BETWEEN 0 AND connector_total_sources),
              connector_verified_sources INTEGER NOT NULL
                CHECK(connector_verified_sources BETWEEN 0 AND connector_total_sources),
              connector_skipped_sources INTEGER NOT NULL
                CHECK(connector_skipped_sources BETWEEN 0 AND connector_total_sources),
              connector_report_sha256 TEXT NOT NULL
                CHECK(length(connector_report_sha256) = 64 AND
                      connector_report_sha256 NOT GLOB '*[^0-9a-f]*'),
              codex_skills_sha256 TEXT
                CHECK(codex_skills_sha256 IS NULL OR
                      (length(codex_skills_sha256) = 64 AND
                       codex_skills_sha256 NOT GLOB '*[^0-9a-f]*')),
              codex_content_sha256 TEXT
                CHECK(codex_content_sha256 IS NULL OR
                      (length(codex_content_sha256) = 64 AND
                       codex_content_sha256 NOT GLOB '*[^0-9a-f]*')),
              CHECK(connector_managed_sources + connector_skipped_sources =
                    connector_total_sources),
              CHECK(connector_verified_sources = connector_managed_sources),
              CHECK((codex_skills_sha256 IS NULL) =
                    (codex_content_sha256 IS NULL))
            );

            CREATE TABLE IF NOT EXISTS state_revision (
              singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
              revision INTEGER NOT NULL CHECK(revision >= 0)
            );
            INSERT OR IGNORE INTO state_revision (singleton, revision) VALUES (1, 0);
            "#,
        )?;
        self.migrate_agent_events(&mut connection)?;
        self.migrate_agent_session_aliases(&mut connection)?;
        self.ensure_pets_metadata_columns(&connection)?;
        self.ensure_generation_job_columns(&connection)?;
        self.ensure_settings_columns(&connection)?;
        self.ensure_state_revision_triggers(&connection)?;
        self.migrate_internal_codex_suggestion_sessions(&mut connection)?;
        self.scrub_legacy_connector_diagnostics(&mut connection)?;
        self.normalize_legacy_pi_tool_failures(&mut connection)?;
        if previous_schema_version < DATABASE_SCHEMA_VERSION {
            connection.execute(
                r#"
                INSERT OR IGNORE INTO privacy_migrations (migration_key, phase, updated_at)
                VALUES (?1, 'pending_secure_vacuum', ?2)
                "#,
                params![EVENT_PRIVACY_MIGRATION_KEY, now_rfc3339()],
            )?;
        }
        self.finish_event_privacy_scrub(&connection)?;
        connection.pragma_update(None, "user_version", DATABASE_SCHEMA_VERSION)?;

        self.ensure_setting("behavior", &BehaviorSettings::default())?;
        self.ensure_setting("overlay_placement", &OverlayPlacement::default())?;
        let quick_check: String =
            connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if !quick_check.eq_ignore_ascii_case("ok") {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error {
                    code: ErrorCode::DatabaseCorrupt,
                    extended_code: rusqlite::ffi::SQLITE_CORRUPT,
                },
                Some(format!("sqlite quick_check failed: {quick_check}")),
            )
            .into());
        }
        Ok(())
    }

    fn ensure_pets_metadata_columns(&self, connection: &Connection) -> Result<()> {
        if !table_has_column(connection, "pets", "generator")? {
            connection.execute("ALTER TABLE pets ADD COLUMN generator TEXT", [])?;
        }
        if !table_has_column(connection, "pets", "provenance")? {
            connection.execute("ALTER TABLE pets ADD COLUMN provenance TEXT", [])?;
        }
        if !table_has_column(connection, "pets", "origin")? {
            connection.execute(
                "ALTER TABLE pets ADD COLUMN origin TEXT NOT NULL DEFAULT 'external_import'",
                [],
            )?;
        }
        if !table_has_column(connection, "pets", "native_fps")? {
            connection.execute(
                "ALTER TABLE pets ADD COLUMN native_fps INTEGER NOT NULL DEFAULT 10",
                [],
            )?;
        }
        if !table_has_column(connection, "pets", "state_durations_json")? {
            let sql = format!(
                "ALTER TABLE pets ADD COLUMN state_durations_json TEXT NOT NULL DEFAULT '{DEFAULT_STATE_DURATIONS_JSON}'"
            );
            connection.execute(&sql, [])?;
        }
        Ok(())
    }

    fn ensure_generation_job_columns(&self, connection: &Connection) -> Result<()> {
        if !table_has_column(connection, "generation_jobs", "retry_of_job_id")? {
            connection.execute(
                "ALTER TABLE generation_jobs ADD COLUMN retry_of_job_id TEXT",
                [],
            )?;
        }
        if !table_has_column(connection, "generation_jobs", "owner_instance_id")? {
            connection.execute(
                "ALTER TABLE generation_jobs ADD COLUMN owner_instance_id TEXT",
                [],
            )?;
        }
        if !table_has_column(connection, "generation_jobs", "heartbeat_at")? {
            connection.execute(
                "ALTER TABLE generation_jobs ADD COLUMN heartbeat_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
                [],
            )?;
            connection.execute("UPDATE generation_jobs SET heartbeat_at = updated_at", [])?;
        }
        Ok(())
    }

    fn ensure_settings_columns(&self, connection: &Connection) -> Result<()> {
        if !table_has_column(connection, "settings", "revision")? {
            connection.execute(
                "ALTER TABLE settings ADD COLUMN revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0)",
                [],
            )?;
        }
        Ok(())
    }

    fn migrate_agent_events(&self, connection: &mut Connection) -> Result<()> {
        if table_has_column(connection, "agent_events", "row_id")?
            && table_has_column(connection, "agent_events", "external_event_id")?
            && table_has_column(connection, "agent_events", "session_key")?
            && !table_exists(connection, "agent_events_legacy_migration")?
        {
            return Ok(());
        }

        connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        let transaction = connection.transaction()?;
        if !table_exists(&transaction, "agent_events_legacy_migration")? {
            transaction.execute_batch(
                r#"
                ALTER TABLE agent_events RENAME TO agent_events_legacy_migration;
                CREATE TABLE agent_events (
                  row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  external_event_id TEXT NOT NULL,
                  source TEXT NOT NULL,
                  project_path TEXT,
                  session_id TEXT,
                  session_key TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  title TEXT,
                  detail TEXT,
                  payload_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  UNIQUE(source, session_key, external_event_id)
                );
                "#,
            )?;
        }

        let legacy_rows = {
            let mut statement = transaction.prepare(
                r#"
                SELECT id, source, project_path, session_id, event_type, created_at
                FROM agent_events_legacy_migration
                ORDER BY rowid ASC
                "#,
            )?;
            let rows = statement
                .query_map([], |row| {
                    Ok(LegacyAgentEventRow {
                        external_event_id: row.get(0)?,
                        source: row.get(1)?,
                        project_path: row.get(2)?,
                        session_id: row.get(3)?,
                        event_type: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };

        for (index, row) in legacy_rows.into_iter().enumerate() {
            let external_event_id = if row.external_event_id.trim().is_empty() {
                format!("legacy-event-{index}")
            } else {
                row.external_event_id
            };
            let session_id = normalized_session_id(row.session_id.as_deref());
            transaction.execute(
                r#"
                INSERT OR IGNORE INTO agent_events
                  (external_event_id, source, project_path, session_id, session_key,
                   event_type, title, detail, payload_json, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                "#,
                params![
                    external_event_id,
                    row.source,
                    row.project_path,
                    session_id,
                    normalized_session_key(session_id.as_deref()),
                    row.event_type,
                    enum_from_name::<AgentEventType>(&row.event_type)
                        .map(|event_type| event_type.zh_label())
                        .unwrap_or("历史 Agent 事件"),
                    Option::<&str>::None,
                    serde_json::to_string(&minimal_legacy_payload(&external_event_id))?,
                    row.created_at,
                ],
            )?;
        }
        transaction.execute("DROP TABLE agent_events_legacy_migration", [])?;
        transaction.execute(
            r#"
            INSERT OR REPLACE INTO privacy_migrations (migration_key, phase, updated_at)
            VALUES (?1, 'pending_secure_vacuum', ?2)
            "#,
            params![EVENT_PRIVACY_MIGRATION_KEY, now_rfc3339()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn migrate_agent_session_aliases(&self, connection: &mut Connection) -> Result<()> {
        let sessions = {
            let mut statement = connection.prepare(
                r#"
                SELECT events.source, events.session_key,
                       MIN(events.created_at) AS first_seen_at,
                       MIN(events.row_id) AS first_row_id
                FROM agent_events AS events
                LEFT JOIN agent_session_aliases AS aliases
                  ON aliases.source = events.source
                 AND aliases.session_key = events.session_key
                WHERE aliases.alias_sequence IS NULL
                GROUP BY events.source, events.session_key
                ORDER BY events.source ASC, first_seen_at ASC,
                         first_row_id ASC, events.session_key ASC
                "#,
            )?;
            let rows = statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };

        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        for (source, session_key, assigned_at) in sessions {
            ensure_agent_session_alias_in_connection(
                &transaction,
                &source,
                &session_key,
                &assigned_at,
            )?;
        }
        prune_agent_session_aliases(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    fn finish_event_privacy_scrub(&self, connection: &Connection) -> Result<()> {
        let pending = connection
            .query_row(
                "SELECT 1 FROM privacy_migrations WHERE migration_key = ?1",
                params![EVENT_PRIVACY_MIGRATION_KEY],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !pending {
            return Ok(());
        }

        // Remove the marker only after the main database and WAL have both
        // been rewritten without legacy plaintext. If VACUUM/checkpoint fails
        // or the process exits, the marker survives and startup retries before
        // advancing `user_version`.
        connection.execute_batch(
            "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; PRAGMA wal_checkpoint(TRUNCATE);",
        )?;
        connection.execute(
            "DELETE FROM privacy_migrations WHERE migration_key = ?1",
            params![EVENT_PRIVACY_MIGRATION_KEY],
        )?;
        connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        Ok(())
    }

    fn migrate_internal_codex_suggestion_sessions(
        &self,
        connection: &mut Connection,
    ) -> Result<()> {
        let suppressed_session_keys = {
            let mut statement = connection.prepare(
                r#"
                SELECT session_key, payload_json
                FROM agent_events
                WHERE source = 'codex'
                "#,
            )?;
            let rows = statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows.into_iter()
                .filter_map(|(session_key, payload_json)| {
                    let payload = serde_json::from_str::<Value>(&payload_json).ok()?;
                    (payload.get("source_event").and_then(Value::as_str)
                        == Some("UserPromptSubmit")
                        && payload.get("message_role").and_then(Value::as_str) == Some("user")
                        && payload
                            .get("message_content")
                            .and_then(Value::as_str)
                            .is_some_and(is_codex_internal_suggestions_prompt))
                    .then_some(session_key)
                })
                .collect::<BTreeSet<_>>()
        };

        let transaction = connection.transaction()?;
        for session_key in &suppressed_session_keys {
            suppress_agent_session_in_connection(
                &transaction,
                AgentSource::Codex,
                session_key,
                CODEX_INTERNAL_SUGGESTIONS_REASON,
            )?;
        }
        prune_suppressed_agent_sessions(&transaction)?;
        if !suppressed_session_keys.is_empty() {
            transaction.execute(
                r#"
                INSERT OR REPLACE INTO privacy_migrations (migration_key, phase, updated_at)
                VALUES (?1, 'pending_secure_vacuum', ?2)
                "#,
                params![EVENT_PRIVACY_MIGRATION_KEY, now_rfc3339()],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn scrub_legacy_connector_diagnostics(&self, connection: &mut Connection) -> Result<()> {
        let rows = {
            let mut statement = connection.prepare(
                r#"
                SELECT row_id, payload_json
                FROM agent_events
                WHERE instr(session_id, 'evt_pi_runtime_') = 1
                   OR instr(session_id, 'evt_opencode_runtime_') = 1
                   OR instr(session_id, 'real_agent_') = 1
                "#,
            )?;
            let rows = statement
                .query_map([], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        if rows.is_empty() {
            return Ok(());
        }

        let transaction = connection.transaction()?;
        for (row_id, payload_json) in rows {
            let Ok(mut payload) = serde_json::from_str::<Value>(&payload_json) else {
                continue;
            };
            let Some(payload) = payload.as_object_mut() else {
                continue;
            };
            if payload.get("diagnostic").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            payload.insert("diagnostic".to_string(), Value::Bool(true));
            transaction.execute(
                "UPDATE agent_events SET payload_json = ?1 WHERE row_id = ?2",
                params![serde_json::to_string(payload)?, row_id],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn normalize_legacy_pi_tool_failures(&self, connection: &mut Connection) -> Result<()> {
        let rows = {
            let mut statement = connection.prepare(
                r#"
                SELECT row_id, payload_json
                FROM agent_events
                WHERE source = 'pi' AND event_type = 'failed'
                "#,
            )?;
            let rows = statement
                .query_map([], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        if rows.is_empty() {
            return Ok(());
        }

        let transaction = connection.transaction()?;
        for (row_id, payload_json) in rows {
            let Ok(mut payload) = serde_json::from_str::<Value>(&payload_json) else {
                continue;
            };
            if payload.get("source_event").and_then(Value::as_str) != Some("tool_execution_end")
                || payload.get("outcome").and_then(Value::as_str) != Some("tool_failure")
            {
                continue;
            }
            let Some(payload) = payload.as_object_mut() else {
                continue;
            };
            // Historical connector versions incorrectly made one failed Pi tool
            // result terminal. It no longer proves that the agent loop is active,
            // so keep the event non-terminal and let the normal display TTL apply.
            payload.insert("session_active".to_string(), Value::Bool(false));
            transaction.execute(
                r#"
                UPDATE agent_events
                SET event_type = 'tool', title = ?1, payload_json = ?2
                WHERE row_id = ?3
                "#,
                params![
                    AgentEventType::Tool.zh_label(),
                    serde_json::to_string(payload)?,
                    row_id
                ],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn ensure_state_revision_triggers(&self, connection: &Connection) -> Result<()> {
        for table in [
            "pets",
            "generation_jobs",
            "generation_messages",
            "agent_events",
            "suppressed_agent_sessions",
            "agent_session_aliases",
            "pet_asset_validation",
            "settings",
        ] {
            for (suffix, operation) in [("ai", "INSERT"), ("au", "UPDATE"), ("ad", "DELETE")] {
                connection.execute_batch(&format!(
                    r#"
                    CREATE TRIGGER IF NOT EXISTS state_revision_{table}_{suffix}
                    AFTER {operation} ON {table}
                    BEGIN
                      UPDATE state_revision
                      SET revision = revision + 1
                      WHERE singleton = 1;
                    END;
                    "#
                ))?;
            }
        }
        Ok(())
    }

    fn backup_corrupt_database(&self) -> Result<()> {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or(0);
        let backup_path = self.path.with_extension(format!(
            "{}.corrupt-{timestamp}",
            self.path
                .extension()
                .and_then(|extension| extension.to_str())
                .unwrap_or("sqlite")
        ));

        backup_if_exists(&self.path, &backup_path)?;
        backup_if_exists(
            &sidecar_path(&self.path, "wal"),
            &sidecar_path(&backup_path, "wal"),
        )?;
        backup_if_exists(
            &sidecar_path(&self.path, "shm"),
            &sidecar_path(&backup_path, "shm"),
        )?;
        Ok(())
    }

    fn has_invalid_sqlite_header(&self) -> Result<bool> {
        const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";
        if !self.path.exists() {
            return Ok(false);
        }

        let metadata = fs::metadata(&self.path)?;
        if metadata.len() == 0 {
            return Ok(false);
        }
        if metadata.len() < SQLITE_HEADER.len() as u64 {
            return Ok(true);
        }

        let mut header = [0; SQLITE_HEADER.len()];
        fs::File::open(&self.path)?.read_exact(&mut header)?;
        Ok(&header != SQLITE_HEADER)
    }

    pub fn ensure_setting<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        if self.get_raw_setting(key)?.is_none() {
            self.set_setting(key, value)?;
        }
        Ok(())
    }

    pub fn get_raw_setting(&self, key: &str) -> Result<Option<String>> {
        let connection = self.open()?;
        let value = connection
            .query_row(
                "SELECT value_json FROM settings WHERE key = ?1",
                params![key],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        Ok(value)
    }

    pub fn get_setting<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        self.get_raw_setting(key)?
            .map(|value| serde_json::from_str(&value).map_err(Into::into))
            .transpose()
    }

    pub fn set_setting<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            r#"
            INSERT INTO settings (key, value_json, updated_at, revision)
            VALUES (?1, ?2, ?3, 1)
            ON CONFLICT(key) DO UPDATE SET
              value_json = excluded.value_json,
              updated_at = excluded.updated_at,
              revision = settings.revision + 1
            "#,
            params![key, serde_json::to_string_pretty(value)?, now_rfc3339()],
        )?;
        Ok(())
    }

    pub fn product_convergence_receipt(&self) -> Result<Option<ProductConvergenceReceipt>> {
        let connection = self.open()?;
        connection
            .query_row(
                r#"
                SELECT schema_version,
                       build_id,
                       app_version,
                       completed_at,
                       connector_total_sources,
                       connector_managed_sources,
                       connector_verified_sources,
                       connector_skipped_sources,
                       connector_report_sha256,
                       codex_skills_sha256,
                       codex_content_sha256
                FROM product_convergence_receipt
                WHERE singleton = 1
                "#,
                [],
                |row| {
                    Ok(ProductConvergenceReceipt {
                        schema_version: row.get(0)?,
                        build_id: row.get(1)?,
                        app_version: row.get(2)?,
                        completed_at: row.get(3)?,
                        connector_report_summary: ProductConvergenceConnectorSummary {
                            total_sources: row.get(4)?,
                            managed_sources: row.get(5)?,
                            verified_sources: row.get(6)?,
                            skipped_sources: row.get(7)?,
                            report_sha256: row.get(8)?,
                            codex_skills_sha256: row.get(9)?,
                            codex_content_sha256: row.get(10)?,
                        },
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn upsert_product_convergence_receipt(
        &self,
        receipt: &ProductConvergenceReceipt,
    ) -> Result<()> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute(
            r#"
            INSERT INTO product_convergence_receipt (
              singleton,
              schema_version,
              build_id,
              app_version,
              completed_at,
              connector_total_sources,
              connector_managed_sources,
              connector_verified_sources,
              connector_skipped_sources,
              connector_report_sha256,
              codex_skills_sha256,
              codex_content_sha256
            )
            VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ON CONFLICT(singleton) DO UPDATE SET
              schema_version = excluded.schema_version,
              build_id = excluded.build_id,
              app_version = excluded.app_version,
              completed_at = excluded.completed_at,
              connector_total_sources = excluded.connector_total_sources,
              connector_managed_sources = excluded.connector_managed_sources,
              connector_verified_sources = excluded.connector_verified_sources,
              connector_skipped_sources = excluded.connector_skipped_sources,
              connector_report_sha256 = excluded.connector_report_sha256,
              codex_skills_sha256 = excluded.codex_skills_sha256,
              codex_content_sha256 = excluded.codex_content_sha256
            "#,
            params![
                receipt.schema_version,
                receipt.build_id,
                receipt.app_version,
                receipt.completed_at,
                receipt.connector_report_summary.total_sources,
                receipt.connector_report_summary.managed_sources,
                receipt.connector_report_summary.verified_sources,
                receipt.connector_report_summary.skipped_sources,
                receipt.connector_report_summary.report_sha256,
                receipt.connector_report_summary.codex_skills_sha256,
                receipt.connector_report_summary.codex_content_sha256,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn behavior(&self) -> Result<BehaviorSettings> {
        Ok(self.behavior_with_revision()?.behavior)
    }

    pub fn behavior_with_revision(&self) -> Result<VersionedBehaviorSettings> {
        let connection = self.open()?;
        let (behavior, revision) = read_behavior_row(&connection)?;
        Ok(VersionedBehaviorSettings {
            behavior,
            revision: revision.to_string(),
        })
    }

    pub fn patch_behavior(
        &self,
        expected_revision: u64,
        changes: &BehaviorSettingsPatch,
    ) -> Result<VersionedBehaviorSettings> {
        if changes.is_empty() {
            return Err(PetCoreError::InvalidRequest(
                "invalid params: behavior changes must not be empty".to_string(),
            ));
        }
        if changes
            .session_message_timeout_minutes
            .is_some_and(|minutes| {
                !(MIN_SESSION_MESSAGE_TIMEOUT_MINUTES..=MAX_SESSION_MESSAGE_TIMEOUT_MINUTES)
                    .contains(&minutes)
            })
        {
            return Err(PetCoreError::InvalidRequest(format!(
                "invalid params: session_message_timeout_minutes must be between {MIN_SESSION_MESSAGE_TIMEOUT_MINUTES} and {MAX_SESSION_MESSAGE_TIMEOUT_MINUTES}"
            )));
        }
        if changes.bubble_transparency.is_some_and(|value| {
            !value.is_finite()
                || !(MIN_BUBBLE_TRANSPARENCY..=MAX_BUBBLE_TRANSPARENCY).contains(&value)
        }) {
            return Err(PetCoreError::InvalidRequest(format!(
                "invalid params: bubble_transparency must be between {MIN_BUBBLE_TRANSPARENCY} and {MAX_BUBBLE_TRANSPARENCY}"
            )));
        }
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (mut behavior, actual_revision) = read_behavior_row(&transaction)?;
        if actual_revision != expected_revision {
            return Err(PetCoreError::Conflict(format!(
                "behavior revision conflict: expected {expected_revision}, actual {actual_revision}"
            )));
        }
        changes.apply_to(&mut behavior);
        let next_revision = actual_revision
            .checked_add(1)
            .ok_or_else(|| PetCoreError::Validation("behavior revision overflow".to_string()))?;
        write_behavior_row(&transaction, &behavior, actual_revision, next_revision)?;
        transaction.commit()?;
        Ok(VersionedBehaviorSettings {
            behavior,
            revision: next_revision.to_string(),
        })
    }

    pub fn onboarding_with_revision(&self) -> Result<VersionedOnboardingProgress> {
        let connection = self.open()?;
        let (progress, revision) = read_onboarding_row(&connection)?;
        Ok(VersionedOnboardingProgress {
            progress,
            revision: revision.to_string(),
        })
    }

    pub fn update_onboarding(
        &self,
        expected_revision: u64,
        next_progress: &OnboardingProgress,
    ) -> Result<VersionedOnboardingProgress> {
        if !next_progress.is_supported() {
            return Err(PetCoreError::InvalidRequest(format!(
                "invalid params: onboarding schema_version must be {ONBOARDING_PROGRESS_SCHEMA_VERSION}"
            )));
        }

        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (current_progress, actual_revision) = read_onboarding_row(&transaction)?;
        if actual_revision != expected_revision {
            return Err(PetCoreError::Conflict(format!(
                "onboarding revision conflict: expected {expected_revision}, actual {actual_revision}"
            )));
        }
        if !current_progress.stage.can_advance_to(next_progress.stage) {
            return Err(PetCoreError::InvalidRequest(format!(
                "invalid params: onboarding transition {:?} -> {:?} is not allowed",
                current_progress.stage, next_progress.stage
            )));
        }

        if next_progress.stage == OnboardingStage::Completed {
            let (mut behavior, behavior_revision) = read_behavior_row(&transaction)?;
            if !behavior.enabled {
                behavior.enabled = true;
                let next_behavior_revision = behavior_revision.checked_add(1).ok_or_else(|| {
                    PetCoreError::Validation("behavior revision overflow".to_string())
                })?;
                write_behavior_row(
                    &transaction,
                    &behavior,
                    behavior_revision,
                    next_behavior_revision,
                )?;
            }
        }

        let next_revision = actual_revision
            .checked_add(1)
            .ok_or_else(|| PetCoreError::Validation("onboarding revision overflow".to_string()))?;
        write_onboarding_row(&transaction, next_progress, actual_revision, next_revision)?;
        transaction.commit()?;
        Ok(VersionedOnboardingProgress {
            progress: next_progress.clone(),
            revision: next_revision.to_string(),
        })
    }

    pub fn overlay_placement(&self) -> Result<OverlayPlacement> {
        Ok(self
            .get_setting("overlay_placement")?
            .unwrap_or_else(OverlayPlacement::default))
    }

    pub fn connection_statuses(&self) -> Result<Vec<AgentConnectionStatus>> {
        Ok(self.get_setting("connection_statuses")?.unwrap_or_default())
    }

    pub fn upsert_connection_status(&self, status: &AgentConnectionStatus) -> Result<()> {
        self.upsert_connection_statuses(std::slice::from_ref(status))
    }

    pub fn upsert_connection_statuses(&self, incoming: &[AgentConnectionStatus]) -> Result<()> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let raw = transaction
            .query_row(
                "SELECT value_json FROM settings WHERE key = 'connection_statuses'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let mut statuses: Vec<AgentConnectionStatus> = raw
            .map(|value| serde_json::from_str(&value))
            .transpose()?
            .unwrap_or_default();
        for status in incoming {
            statuses.retain(|existing| existing.source != status.source);
            statuses.push(status.clone());
        }
        statuses.sort_by_key(|status| source_sort_key(status.source));
        transaction.execute(
            r#"
            INSERT INTO settings (key, value_json, updated_at, revision)
            VALUES ('connection_statuses', ?1, ?2, 1)
            ON CONFLICT(key) DO UPDATE SET
              value_json = excluded.value_json,
              updated_at = excluded.updated_at,
              revision = settings.revision + 1
            "#,
            params![serde_json::to_string_pretty(&statuses)?, now_rfc3339()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn state_revision(&self) -> Result<u64> {
        let connection = self.open()?;
        state_revision_in_connection(&connection)
    }

    fn read_projection_at_revision<T, F>(
        &self,
        expected_state_revision: u64,
        read: F,
    ) -> Result<RevisionChecked<T>>
    where
        F: FnOnce(&Connection) -> Result<T>,
    {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let actual_revision = state_revision_in_connection(&transaction)?;
        if actual_revision != expected_state_revision {
            transaction.commit()?;
            return Ok(RevisionChecked::Mismatch {
                expected_revision: expected_state_revision,
                actual_revision,
            });
        }

        let value = read(&transaction)?;
        transaction.commit()?;
        Ok(RevisionChecked::Matched {
            state_revision: actual_revision,
            value,
        })
    }

    pub fn insert_event(&self, event: &AgentEvent) -> Result<InsertEventOutcome> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let session_id = normalized_session_id(event.session_id.as_deref());
        let session_key = normalized_session_key(session_id.as_deref());
        if let (Some(reason), Some(_)) = (
            suppressed_agent_session_reason(event),
            session_id.as_deref(),
        ) {
            suppress_agent_session_in_connection(&transaction, event.source, &session_key, reason)?;
            prune_suppressed_agent_sessions(&transaction)?;
            transaction.commit()?;
            return Ok(InsertEventOutcome::Suppressed);
        }
        if agent_session_is_suppressed(&transaction, event.source, &session_key)? {
            return Ok(InsertEventOutcome::Suppressed);
        }
        if event_arrived_after_turn_terminal(&transaction, event, &session_key)? {
            transaction.commit()?;
            return Ok(InsertEventOutcome::Suppressed);
        }
        ensure_agent_session_alias_in_connection(
            &transaction,
            &enum_name(event.source),
            &session_key,
            &event.created_at,
        )?;
        let changed = transaction.execute(
            r#"
            INSERT OR IGNORE INTO agent_events
              (external_event_id, source, project_path, session_id, session_key,
               event_type, title, detail, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
            params![
                event.id,
                enum_name(event.source),
                event.project_path,
                session_id,
                session_key,
                enum_name(event.event_type),
                event.event_type.zh_label(),
                Option::<&str>::None,
                serde_json::to_string(&persisted_payload(event))?,
                event.created_at,
            ],
        )?;
        prune_events_in_transaction(&transaction, EventRetentionPolicy::default())?;
        transaction.commit()?;
        Ok(if changed > 0 {
            InsertEventOutcome::Inserted
        } else {
            InsertEventOutcome::Duplicate
        })
    }

    /// Updates the single bounded display record for a Codex App Server turn.
    /// This is intentionally narrower than normal event ingestion: external
    /// hook events remain immutable and deduplicated, while the polling
    /// fallback can renew its finite lease without appending a row every few
    /// seconds.
    pub fn upsert_codex_activity_event(&self, event: &AgentEvent) -> Result<bool> {
        if event.source != AgentSource::Codex
            || event
                .payload_json
                .get("source_event")
                .and_then(Value::as_str)
                != Some("app_server_activity")
        {
            return Err(PetCoreError::InvalidRequest(
                "Codex activity upsert only accepts App Server activity events".to_string(),
            ));
        }
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let session_id = normalized_session_id(event.session_id.as_deref());
        let session_key = normalized_session_key(session_id.as_deref());
        if agent_session_is_suppressed(&transaction, event.source, &session_key)? {
            return Ok(false);
        }
        ensure_agent_session_alias_in_connection(
            &transaction,
            &enum_name(event.source),
            &session_key,
            &event.created_at,
        )?;
        let payload_json = serde_json::to_string(&persisted_payload(event))?;
        let changed = transaction.execute(
            r#"
            INSERT INTO agent_events
              (external_event_id, source, project_path, session_id, session_key,
               event_type, title, detail, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8, ?9)
            ON CONFLICT(source, session_key, external_event_id) DO UPDATE SET
              project_path = excluded.project_path,
              session_id = excluded.session_id,
              event_type = excluded.event_type,
              title = excluded.title,
              detail = NULL,
              payload_json = excluded.payload_json,
              created_at = excluded.created_at
            WHERE agent_events.project_path IS NOT excluded.project_path
               OR agent_events.session_id IS NOT excluded.session_id
               OR agent_events.event_type <> excluded.event_type
               OR agent_events.title <> excluded.title
               OR agent_events.detail IS NOT NULL
               OR agent_events.payload_json <> excluded.payload_json
               OR agent_events.created_at <> excluded.created_at
            "#,
            params![
                event.id,
                enum_name(event.source),
                event.project_path,
                session_id,
                session_key,
                enum_name(event.event_type),
                event.event_type.zh_label(),
                payload_json,
                event.created_at,
            ],
        )?;
        prune_events_in_transaction(&transaction, EventRetentionPolicy::default())?;
        transaction.commit()?;
        Ok(changed > 0)
    }

    pub fn recent_events(&self, limit: usize) -> Result<Vec<AgentEvent>> {
        let limit = limit.min(MAX_RECENT_EVENTS);
        if limit == 0 {
            return Ok(Vec::new());
        }
        let connection = self.open()?;
        recent_events_in_connection(&connection, limit)
    }

    /// Reads recent typed events only when the database snapshot still matches
    /// `expected_state_revision`. The revision check and event query share one
    /// deferred SQLite transaction, so a concurrent writer can produce either
    /// a clean mismatch or a self-consistent old snapshot, never mixed rows.
    pub(crate) fn recent_events_at_revision(
        &self,
        expected_state_revision: u64,
        limit: usize,
    ) -> Result<RevisionChecked<Vec<AgentEvent>>> {
        self.read_projection_at_revision(expected_state_revision, |connection| {
            recent_events_in_connection(connection, limit.min(MAX_RECENT_EVENTS))
        })
    }

    /// Projects all database-backed connector verification evidence in one
    /// source-filtered scan. PetCore's own channel test and Codex App Server
    /// fallback are excluded: neither proves that a connector ran.
    pub fn connector_evidence_summary(
        &self,
        source: AgentSource,
        expected_contract_version: &str,
        start_events: &[&str],
        activity_events: &[&str],
        completion_events: &[&str],
    ) -> Result<ConnectorEvidenceSummary> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT row_id, session_key, event_type, payload_json, created_at
            FROM agent_events
            WHERE source = ?1
            ORDER BY row_id DESC
            "#,
        )?;
        let rows = statement.query_map(params![enum_name(source)], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?;

        let mut summary = ConnectorEvidenceSummary::default();
        let mut newest_stale_receipt = None;
        let mut latest_start_receipts = HashMap::<String, ConnectorEventReceipt>::new();
        let mut completions = HashMap::<String, ConnectorEventReceipt>::new();
        let mut task_tails =
            HashMap::<String, (ConnectorEventReceipt, ConnectorEventReceipt)>::new();

        for row in rows {
            let (sequence, session_key, event_type, payload_json, created_at) = row?;
            let Ok(payload) = serde_json::from_str::<Value>(&payload_json) else {
                continue;
            };
            let diagnostic = payload
                .get("diagnostic")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let Some(raw_source_event) = payload.get("source_event").and_then(Value::as_str) else {
                continue;
            };
            let source_event = raw_source_event.trim();
            if source_event.is_empty() {
                continue;
            }
            let contract_version = payload
                .get("contract_version")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            let current_contract = contract_version.as_deref() == Some(expected_contract_version);
            let connector_receipt_eligible = !matches!(
                source_event,
                "connection.test" | "app_server_activity" | "legacy" | "unclassified"
            ) && (diagnostic || source_event != "connector.probe");
            let receipt = || ConnectorEventReceipt {
                sequence,
                source_event: source_event.to_string(),
                contract_version: contract_version.clone(),
                created_at: created_at.clone(),
                diagnostic,
            };

            if connector_receipt_eligible {
                if !diagnostic
                    && task_evidence_event_matches(
                        source,
                        start_events,
                        source_event,
                        &payload,
                        &event_type,
                    )
                {
                    // Preserve the previous two-stage lookup exactly: for
                    // each start name, the newest receipt wins before its
                    // contract is checked. A newer stale start therefore
                    // shadows an older current-contract start of that name.
                    latest_start_receipts
                        .entry(source_event.to_string())
                        .or_insert_with(&receipt);
                }
                if current_contract {
                    let slot = if diagnostic {
                        &mut summary.diagnostic_receipt
                    } else {
                        &mut summary.observed_receipt
                    };
                    if slot.is_none() {
                        *slot = Some(receipt());
                    }
                } else if newest_stale_receipt.is_none() {
                    // Rows are descending by sequence, so the first eligible
                    // non-current receipt is the newest stale contract across
                    // both diagnostic and ordinary connector traffic.
                    newest_stale_receipt = Some(receipt());
                }
            }

            if current_contract && !diagnostic {
                let affects_activity = payload
                    .get("affects_activity")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if summary.ordinary_receipt.is_none()
                    && source_event_proves_ordinary_activity(source_event, affects_activity)
                {
                    summary.ordinary_receipt = Some(receipt());
                }
            }

            // Preserve the task receipt's existing exact event-name and
            // session semantics. Unlike the general receipt projection, task
            // evidence is defined exclusively by the caller-provided closed
            // event sets, so source event whitespace is not normalized here.
            if summary.task_receipt.is_some()
                || diagnostic
                || !current_contract
                || session_key == "0:"
            {
                continue;
            }
            let task_receipt = || ConnectorEventReceipt {
                sequence,
                source_event: raw_source_event.to_string(),
                contract_version: Some(expected_contract_version.to_string()),
                created_at: created_at.clone(),
                diagnostic: false,
            };
            if task_evidence_event_matches(
                source,
                completion_events,
                raw_source_event,
                &payload,
                &event_type,
            ) {
                completions.entry(session_key).or_insert_with(task_receipt);
                continue;
            }
            if task_evidence_event_matches(
                source,
                activity_events,
                raw_source_event,
                &payload,
                &event_type,
            ) {
                if let Some(completion) = completions.remove(&session_key) {
                    task_tails
                        .entry(session_key)
                        .or_insert_with(|| (task_receipt(), completion));
                }
                continue;
            }
            if task_evidence_event_matches(
                source,
                start_events,
                raw_source_event,
                &payload,
                &event_type,
            ) {
                if let Some((activity, completion)) = task_tails.remove(&session_key) {
                    summary.task_receipt = Some(ConnectorTaskReceipt {
                        start: task_receipt(),
                        activity,
                        completion,
                    });
                }
            }
        }

        let latest_current_sequence = [
            summary.observed_receipt.as_ref(),
            summary.diagnostic_receipt.as_ref(),
        ]
        .into_iter()
        .flatten()
        .map(|receipt| receipt.sequence)
        .max();
        summary.newer_stale_receipt = newest_stale_receipt.filter(|receipt| {
            latest_current_sequence.is_none_or(|current| receipt.sequence > current)
        });
        summary.real_start_receipt = latest_start_receipts
            .into_values()
            .filter(|receipt| {
                receipt.contract_version.as_deref() == Some(expected_contract_version)
            })
            .max_by_key(|receipt| receipt.sequence);
        Ok(summary)
    }

    /// Returns the latest event that actually crossed an Agent connector.
    /// PetCore's own channel test and Codex App Server fallback are excluded:
    /// neither proves that an Agent hook, extension, or plugin ran.
    pub fn latest_connector_event_receipt(
        &self,
        source: AgentSource,
        diagnostic: bool,
    ) -> Result<Option<ConnectorEventReceipt>> {
        self.latest_connector_event_receipt_matching(source, diagnostic, None, None)
    }

    pub fn latest_connector_event_receipt_for_source_event(
        &self,
        source: AgentSource,
        diagnostic: bool,
        expected_source_event: &str,
    ) -> Result<Option<ConnectorEventReceipt>> {
        self.latest_connector_event_receipt_matching(
            source,
            diagnostic,
            Some(expected_source_event),
            None,
        )
    }

    pub fn latest_connector_event_receipt_for_contract(
        &self,
        source: AgentSource,
        diagnostic: bool,
        expected_contract_version: &str,
    ) -> Result<Option<ConnectorEventReceipt>> {
        self.latest_connector_event_receipt_matching(
            source,
            diagnostic,
            None,
            Some(expected_contract_version),
        )
    }

    /// Returns the latest current-contract, non-diagnostic event that proves
    /// ordinary task activity. Passive metadata and host lifecycle edges stay
    /// queryable through `latest_connector_event_receipt*`, but never satisfy
    /// the `ordinary_event_seen` verification layer.
    pub fn latest_connector_ordinary_receipt_for_contract(
        &self,
        source: AgentSource,
        expected_contract_version: &str,
    ) -> Result<Option<ConnectorEventReceipt>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT row_id, payload_json, created_at
            FROM agent_events
            WHERE source = ?1
            ORDER BY row_id DESC
            "#,
        )?;
        let rows = statement.query_map(params![enum_name(source)], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        for row in rows {
            let (sequence, payload_json, created_at) = row?;
            let Ok(payload) = serde_json::from_str::<Value>(&payload_json) else {
                continue;
            };
            if payload
                .get("diagnostic")
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || payload.get("contract_version").and_then(Value::as_str)
                    != Some(expected_contract_version)
            {
                continue;
            }
            let Some(source_event) = payload
                .get("source_event")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            let affects_activity = payload
                .get("affects_activity")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if !source_event_proves_ordinary_activity(source_event, affects_activity) {
                continue;
            }
            return Ok(Some(ConnectorEventReceipt {
                sequence,
                source_event: source_event.to_string(),
                contract_version: Some(expected_contract_version.to_string()),
                created_at,
                diagnostic: false,
            }));
        }
        Ok(None)
    }

    pub fn latest_connector_probe_receipt_for_contract(
        &self,
        source: AgentSource,
        expected_contract_version: &str,
    ) -> Result<Option<ConnectorEventReceipt>> {
        self.latest_connector_event_receipt_matching(
            source,
            true,
            Some("connector.probe"),
            Some(expected_contract_version),
        )
    }

    /// Finds a non-diagnostic task sequence in one real Agent session. A
    /// passive lifecycle event cannot satisfy this query: a task-bearing start
    /// must precede a tool/command activity event and then a completion or
    /// terminal event under the same current adapter contract.
    pub fn latest_connector_task_receipt_for_contract(
        &self,
        source: AgentSource,
        expected_contract_version: &str,
        start_events: &[&str],
        activity_events: &[&str],
        completion_events: &[&str],
    ) -> Result<Option<ConnectorTaskReceipt>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT row_id, session_key, event_type, payload_json, created_at
            FROM agent_events
            WHERE source = ?1
            ORDER BY row_id DESC
            "#,
        )?;
        let rows = statement.query_map(params![enum_name(source)], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?;
        let mut completions = HashMap::<String, ConnectorEventReceipt>::new();
        let mut task_tails =
            HashMap::<String, (ConnectorEventReceipt, ConnectorEventReceipt)>::new();
        for row in rows {
            let (sequence, session_key, event_type, payload_json, created_at) = row?;
            if session_key == "0:" {
                continue;
            }
            let Ok(payload) = serde_json::from_str::<Value>(&payload_json) else {
                continue;
            };
            if payload
                .get("diagnostic")
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || payload.get("contract_version").and_then(Value::as_str)
                    != Some(expected_contract_version)
            {
                continue;
            }
            let Some(source_event) = payload.get("source_event").and_then(Value::as_str) else {
                continue;
            };
            let receipt = ConnectorEventReceipt {
                sequence,
                source_event: source_event.to_string(),
                contract_version: Some(expected_contract_version.to_string()),
                created_at,
                diagnostic: false,
            };
            if task_evidence_event_matches(
                source,
                completion_events,
                source_event,
                &payload,
                &event_type,
            ) {
                completions.entry(session_key).or_insert(receipt);
                continue;
            }
            if task_evidence_event_matches(
                source,
                activity_events,
                source_event,
                &payload,
                &event_type,
            ) {
                if let Some(completion) = completions.remove(&session_key) {
                    task_tails
                        .entry(session_key)
                        .or_insert((receipt, completion));
                }
                continue;
            }
            if task_evidence_event_matches(
                source,
                start_events,
                source_event,
                &payload,
                &event_type,
            ) {
                if let Some((activity, completion)) = task_tails.remove(&session_key) {
                    return Ok(Some(ConnectorTaskReceipt {
                        start: receipt,
                        activity,
                        completion,
                    }));
                }
            }
        }
        Ok(None)
    }

    fn latest_connector_event_receipt_matching(
        &self,
        source: AgentSource,
        diagnostic: bool,
        expected_source_event: Option<&str>,
        expected_contract_version: Option<&str>,
    ) -> Result<Option<ConnectorEventReceipt>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT row_id, payload_json, created_at
            FROM agent_events
            WHERE source = ?1
            ORDER BY row_id DESC
            "#,
        )?;
        let rows = statement.query_map(params![enum_name(source)], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        for row in rows {
            let (sequence, payload_json, created_at) = row?;
            let Ok(payload) = serde_json::from_str::<Value>(&payload_json) else {
                continue;
            };
            let event_diagnostic = payload
                .get("diagnostic")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if event_diagnostic != diagnostic {
                continue;
            }
            let Some(source_event) = payload
                .get("source_event")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| {
                    !value.is_empty()
                        && !matches!(
                            *value,
                            "connection.test" | "app_server_activity" | "legacy" | "unclassified"
                        )
                })
            else {
                continue;
            };
            if source_event == "connector.probe" && !diagnostic {
                continue;
            }
            if expected_source_event.is_some_and(|expected| source_event != expected) {
                continue;
            }
            let contract_version = payload
                .get("contract_version")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            if expected_contract_version
                .is_some_and(|expected| contract_version.as_deref() != Some(expected))
            {
                continue;
            }
            return Ok(Some(ConnectorEventReceipt {
                sequence,
                source_event: source_event.to_string(),
                contract_version,
                created_at,
                diagnostic: event_diagnostic,
            }));
        }
        Ok(None)
    }

    pub fn connector_event_was_received(
        &self,
        source: AgentSource,
        session_id: &str,
        source_event: &str,
        diagnostic: bool,
        expected_contract_version: &str,
    ) -> Result<bool> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT payload_json
            FROM agent_events
            WHERE source = ?1 AND session_key = ?2
            ORDER BY row_id DESC
            "#,
        )?;
        let rows = statement.query_map(
            params![
                enum_name(source),
                normalized_session_key(normalized_session_id(Some(session_id)).as_deref())
            ],
            |row| row.get::<_, String>(0),
        )?;
        for row in rows {
            let Ok(payload) = serde_json::from_str::<Value>(&row?) else {
                continue;
            };
            if payload.get("source_event").and_then(Value::as_str) == Some(source_event)
                && payload
                    .get("diagnostic")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                    == diagnostic
                && payload.get("contract_version").and_then(Value::as_str)
                    == Some(expected_contract_version)
            {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn recent_sequenced_events(&self, limit: usize) -> Result<Vec<SequencedAgentEvent>> {
        let limit = limit.min(MAX_RECENT_EVENTS);
        if limit == 0 {
            return Ok(Vec::new());
        }
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT row_id, external_event_id, source, project_path, session_id, event_type,
                   title, detail, payload_json, created_at
            FROM agent_events
            ORDER BY created_at DESC, row_id DESC
            LIMIT ?1
            "#,
        )?;
        let rows = statement.query_map(params![limit as i64], |row| {
            let row_id = row.get::<_, i64>(0)?;
            let source: String = row.get(2)?;
            let event_type: String = row.get(5)?;
            let payload_json: String = row.get(8)?;
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
                event: AgentEvent {
                    id: row.get(1)?,
                    source: enum_from_name(&source).map_err(to_sql_error)?,
                    project_path: row.get(3)?,
                    session_id: row.get(4)?,
                    event_type: enum_from_name(&event_type).map_err(to_sql_error)?,
                    title: row.get(6)?,
                    detail: row.get(7)?,
                    payload_json: serde_json::from_str(&payload_json).map_err(to_sql_error)?,
                    created_at: row.get(9)?,
                },
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn latest_sequenced_events_by_session(
        &self,
        limit: usize,
    ) -> Result<Vec<SequencedAgentEvent>> {
        if limit.min(MAX_RECENT_EVENTS) == 0 {
            return Ok(Vec::new());
        }
        self.latest_sequenced_events_by_session_with_revision(limit)
            .map(|(_, events)| events)
    }

    pub(crate) fn latest_sequenced_events_by_session_with_revision(
        &self,
        limit: usize,
    ) -> Result<(u64, Vec<SequencedAgentEvent>)> {
        let limit = limit.min(MAX_RECENT_EVENTS);
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let revision = state_revision_in_connection(&transaction)?;
        if limit == 0 {
            transaction.commit()?;
            return Ok((revision, Vec::new()));
        }
        let events = {
            let mut statement = transaction.prepare(
                r#"
            WITH eligible AS (
              SELECT row_id, external_event_id, source, project_path, session_id,
                     session_key, event_type, title, detail, payload_json, created_at
              FROM agent_events
              WHERE COALESCE(json_extract(payload_json, '$.diagnostic'), 0) != 1
                AND (
                  COALESCE(json_extract(payload_json, '$.affects_activity'), 1) != 0
                  OR (
                    source = 'codex'
                    AND event_type = 'done'
                    AND json_extract(payload_json, '$.source_event') = 'Stop'
                  )
                  OR (
                    source = 'claude_code'
                    AND (
                      (
                        event_type = 'done'
                        AND json_extract(payload_json, '$.source_event') IN ('Stop', 'SessionEnd')
                      )
                      OR (
                        event_type = 'failed'
                        AND json_extract(payload_json, '$.source_event') = 'StopFailure'
                      )
                      OR (
                        event_type = 'done'
                        AND json_extract(payload_json, '$.source_event') = 'Notification'
                        AND json_extract(payload_json, '$.outcome') IN ('idle', 'agent_completed')
                      )
                    )
                  )
                  OR (
                    source = 'pi'
                    AND (
                      (
                        event_type IN ('done', 'failed')
                        AND json_extract(payload_json, '$.source_event') = 'agent_settled'
                      )
                      OR (
                        event_type = 'done'
                        AND json_extract(payload_json, '$.source_event') = 'session_shutdown'
                      )
                    )
                  )
                  OR (
                    source = 'opencode'
                    AND (
                      (
                        event_type = 'done'
                        AND json_extract(payload_json, '$.source_event') IN (
                          'session.deleted',
                          'session.idle'
                        )
                      )
                      OR (
                        event_type = 'done'
                        AND json_extract(payload_json, '$.source_event') = 'session.status'
                        AND json_extract(payload_json, '$.outcome') = 'idle'
                      )
                      OR (
                        event_type = 'failed'
                        AND json_extract(payload_json, '$.source_event') = 'session.error'
                      )
                      OR (
                        event_type IN ('done', 'failed')
                        AND json_extract(payload_json, '$.source_event') = 'session.next.step.ended'
                      )
                      OR (
                        event_type = 'failed'
                        AND json_extract(payload_json, '$.source_event') = 'session.next.step.failed'
                      )
                    )
                  )
                )
            ),
            sequenced AS (
              SELECT row_id, external_event_id, source, project_path, session_id,
                     session_key, event_type, title, detail, payload_json, created_at,
                     MAX(CASE
                       WHEN event_type = 'start'
                        AND (
                          json_extract(payload_json, '$.message_role') = 'user'
                          OR json_extract(payload_json, '$.source_event') IN (
                            'UserPromptSubmit',
                            'input',
                            'before_agent_start',
                            'message.user',
                            'session.next.prompt.admitted'
                          )
                        )
                       THEN created_at
                     END) OVER (PARTITION BY source, session_key) AS session_activated_at,
                     MIN(created_at) OVER (
                       PARTITION BY source, session_key
                     ) AS session_first_seen_at,
                     SUM(CASE
                       WHEN event_type NOT IN ('done', 'failed')
                        AND (
                          json_extract(payload_json, '$.message_role') = 'user'
                          OR (
                            event_type = 'waiting'
                            AND (
                              json_extract(payload_json, '$.session_active') = 1
                              OR json_extract(payload_json, '$.source_event') IN (
                                'waiting',
                                'legacy',
                                'unclassified'
                              )
                            )
                          )
                          OR (
                            source = 'codex'
                            AND (
                              json_extract(payload_json, '$.source_event') IN (
                                'UserPromptSubmit',
                                'PreToolUse',
                                'PermissionRequest',
                                'PreCompact',
                                'SubagentStart'
                              )
                              OR (
                                json_extract(payload_json, '$.source_event') = 'app_server_activity'
                                AND json_extract(payload_json, '$.session_active') = 1
                              )
                            )
                          )
                          OR (
                            source = 'claude_code'
                            AND (
                              json_extract(payload_json, '$.source_event') IN (
                                'UserPromptSubmit',
                                'PreToolUse',
                                'PermissionRequest',
                                'PreCompact',
                                'SubagentStart',
                                'TaskCreated',
                                'Elicitation'
                              )
                              OR (
                                json_extract(payload_json, '$.source_event') = 'Stop'
                                AND json_extract(payload_json, '$.outcome') = 'background_active'
                              )
                            )
                          )
                          OR (
                            source = 'pi'
                            AND json_extract(payload_json, '$.source_event') IN (
                              'input',
                              'before_agent_start',
                              'agent_start',
                              'turn_start',
                              'session_before_compact',
                              'tool_call',
                              'tool_execution_start'
                            )
                          )
                          OR (
                            source = 'opencode'
                            AND (
                              json_extract(payload_json, '$.source_event') IN (
                                'message.user',
                                'session.next.prompt.admitted',
                                'session.compaction.started',
                                'tool.execute.before',
                                'command.execute.before',
                                'permission.asked',
                                'permission.updated',
                                'permission.v2.asked',
                                'question.asked',
                                'question.v2.asked'
                              )
                              OR (
                                json_extract(payload_json, '$.source_event') = 'session.status'
                                AND json_extract(payload_json, '$.outcome') IN ('busy', 'retry')
                              )
                            )
                          )
                        )
                       THEN 1
                       ELSE 0
                     END) OVER (
                       PARTITION BY source, session_key
                       ORDER BY created_at ASC, row_id ASC
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                     ) AS activity_epoch
              FROM eligible
            ),
            ranked AS (
              SELECT row_id, external_event_id, source, project_path, session_id,
                     session_key, event_type, title, detail, payload_json, created_at,
                     session_activated_at, session_first_seen_at,
                     ROW_NUMBER() OVER (
                       PARTITION BY source, session_key
                       ORDER BY activity_epoch DESC,
                                CASE event_type
                                  WHEN 'failed' THEN 2
                                  WHEN 'done' THEN 1
                                  ELSE 0
                                END DESC,
                                created_at DESC,
                                row_id DESC
                     ) AS session_rank
              FROM sequenced
            )
            SELECT selected.row_id, selected.external_event_id, selected.source,
                   selected.project_path, selected.session_id, selected.event_type,
                   selected.title, selected.detail, selected.payload_json,
                   selected.created_at, selected.session_activated_at,
                   selected.session_first_seen_at,
                   (
                     SELECT navigation.payload_json
                     FROM eligible AS navigation
                     WHERE navigation.source = selected.source
                       AND navigation.session_key = selected.session_key
                       AND navigation.event_type IN ('done', 'failed')
                       AND (
                         navigation.created_at > selected.created_at
                         OR (
                           navigation.created_at = selected.created_at
                           AND navigation.row_id >= selected.row_id
                         )
                       )
                       AND (
                         json_type(navigation.payload_json, '$.session_open') IS NOT NULL
                         OR json_type(navigation.payload_json, '$.terminal_app') IS NOT NULL
                         OR json_type(navigation.payload_json, '$.session_open_url') IS NOT NULL
                       )
                     ORDER BY navigation.created_at DESC, navigation.row_id DESC
                     LIMIT 1
                   ) AS latest_terminal_navigation_payload,
                   aliases.alias_sequence
            FROM ranked AS selected
            LEFT JOIN agent_session_aliases AS aliases
              ON aliases.source = selected.source
             AND aliases.session_key = selected.session_key
            WHERE selected.session_rank = 1
            ORDER BY selected.created_at DESC, selected.row_id DESC
            LIMIT ?1
            "#,
            )?;
            let rows = statement.query_map(params![limit as i64], |row| {
                let row_id = row.get::<_, i64>(0)?;
                let source: String = row.get(2)?;
                let event_type: String = row.get(5)?;
                let payload_json: String = row.get(8)?;
                Ok(SequencedAgentEvent {
                    source_session_sequence: u64::try_from(row_id).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Integer,
                            Box::new(error),
                        )
                    })?,
                    session_alias_sequence: row
                        .get::<_, Option<i64>>(13)?
                        .map(|value| {
                            u64::try_from(value).map_err(|error| {
                                rusqlite::Error::FromSqlConversionFailure(
                                    13,
                                    rusqlite::types::Type::Integer,
                                    Box::new(error),
                                )
                            })
                        })
                        .transpose()?,
                    session_activated_at: row.get(10)?,
                    session_first_seen_at: row.get(11)?,
                    latest_terminal_navigation_payload: row
                        .get::<_, Option<String>>(12)?
                        .map(|payload| serde_json::from_str(&payload).map_err(to_sql_error))
                        .transpose()?,
                    event: AgentEvent {
                        id: row.get(1)?,
                        source: enum_from_name(&source).map_err(to_sql_error)?,
                        project_path: row.get(3)?,
                        session_id: row.get(4)?,
                        event_type: enum_from_name(&event_type).map_err(to_sql_error)?,
                        title: row.get(6)?,
                        detail: row.get(7)?,
                        payload_json: serde_json::from_str(&payload_json).map_err(to_sql_error)?,
                        created_at: row.get(9)?,
                    },
                })
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        transaction.commit()?;
        Ok((revision, events))
    }

    pub fn latest_session_message(
        &self,
        source: AgentSource,
        session_id: Option<&str>,
    ) -> Result<Option<AgentEvent>> {
        self.latest_session_message_for_role(source, session_id, None)
    }

    pub fn latest_session_message_for_role(
        &self,
        source: AgentSource,
        session_id: Option<&str>,
        role: Option<&str>,
    ) -> Result<Option<AgentEvent>> {
        Ok(self
            .session_message_for_role(source, session_id, role, true)?
            .map(|sequenced| sequenced.event))
    }

    /// Atomically projects the three persisted messages needed to hydrate a
    /// session bubble. A single ordered scan supplies the latest assistant,
    /// latest user, and first user records when (and only when) the caller's
    /// event revision is still current.
    pub(crate) fn session_message_projection_at_revision(
        &self,
        expected_state_revision: u64,
        source: AgentSource,
        session_id: Option<&str>,
    ) -> Result<RevisionChecked<SessionMessageProjection>> {
        self.read_projection_at_revision(expected_state_revision, |connection| {
            session_message_projection_in_connection(connection, source, session_id)
        })
    }

    pub fn first_session_message_for_role(
        &self,
        source: AgentSource,
        session_id: Option<&str>,
        role: Option<&str>,
    ) -> Result<Option<AgentEvent>> {
        Ok(self
            .session_message_for_role(source, session_id, role, false)?
            .map(|sequenced| sequenced.event))
    }

    fn session_message_for_role(
        &self,
        source: AgentSource,
        session_id: Option<&str>,
        role: Option<&str>,
        newest_first: bool,
    ) -> Result<Option<SequencedAgentEvent>> {
        let connection = self.open()?;
        session_message_for_role_in_connection(&connection, source, session_id, role, newest_first)
    }

    pub fn prune_events(&self, policy: EventRetentionPolicy) -> Result<usize> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        let pruned = prune_events_in_transaction(&transaction, policy)?;
        transaction.commit()?;
        Ok(pruned)
    }

    pub fn create_generation_job(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
    ) -> Result<()> {
        self.create_generation_job_with_retry(id, form, job_dir, None)
    }

    pub fn create_generation_job_with_retry(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
        retry_of_job_id: Option<&str>,
    ) -> Result<()> {
        self.create_generation_job_internal(id, form, job_dir, retry_of_job_id, None, None)
    }

    pub fn create_generation_job_for_instance(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
        retry_of_job_id: Option<&str>,
        owner_instance_id: &str,
    ) -> Result<()> {
        self.create_generation_job_internal(
            id,
            form,
            job_dir,
            retry_of_job_id,
            Some(owner_instance_id),
            None,
        )
    }

    pub fn create_generation_job_for_pet_instance(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
        pet_id: &str,
        owner_instance_id: &str,
    ) -> Result<()> {
        self.create_generation_job_for_pet_instance_with_retry(
            id,
            form,
            job_dir,
            pet_id,
            None,
            owner_instance_id,
        )
    }

    pub fn create_generation_job_for_pet_instance_with_retry(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
        pet_id: &str,
        retry_of_job_id: Option<&str>,
        owner_instance_id: &str,
    ) -> Result<()> {
        if pet_id.trim().is_empty() {
            return Err(PetCoreError::InvalidRequest(
                "generation base pet id must not be empty".to_string(),
            ));
        }
        self.create_generation_job_internal(
            id,
            form,
            job_dir,
            retry_of_job_id,
            Some(owner_instance_id),
            Some(pet_id),
        )
    }

    fn create_generation_job_internal(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
        retry_of_job_id: Option<&str>,
        owner_instance_id: Option<&str>,
        result_pet_id: Option<&str>,
    ) -> Result<()> {
        let now = now_rfc3339();
        if owner_instance_id.is_some_and(|owner| owner.trim().is_empty()) {
            return Err(PetCoreError::InvalidRequest(
                "generation owner instance id must not be empty".to_string(),
            ));
        }
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let active_job_id = transaction
            .query_row(
                r#"
                SELECT id
                FROM generation_jobs
                WHERE status IN (?1, ?2, ?3)
                ORDER BY updated_at DESC
                LIMIT 1
                "#,
                params![
                    enum_name(GenerationJobStatus::Pending),
                    enum_name(GenerationJobStatus::Running),
                    enum_name(GenerationJobStatus::WaitingForUser),
                ],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(active_job_id) = active_job_id {
            return Err(PetCoreError::InvalidRequest(format!(
                "active generation job already exists: {active_job_id}"
            )));
        }
        transaction.execute(
            r#"
            INSERT INTO generation_jobs
              (id, status, form_json, session_id, job_dir, result_pet_id,
               retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at)
            VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?8, ?8)
            "#,
            params![
                id,
                enum_name(GenerationJobStatus::Pending),
                serde_json::to_string_pretty(form)?,
                job_dir.display().to_string(),
                result_pet_id,
                retry_of_job_id,
                owner_instance_id,
                now,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn update_generation_job(
        &self,
        id: &str,
        status: GenerationJobStatus,
        result_pet_id: Option<&str>,
    ) -> Result<()> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        reject_other_active_generation(&transaction, id, status)?;
        transaction.execute(
            r#"
            UPDATE generation_jobs
            SET status = ?2,
                result_pet_id = COALESCE(?3, result_pet_id),
                heartbeat_at = ?4,
                updated_at = ?4
            WHERE id = ?1
            "#,
            params![id, enum_name(status), result_pet_id, now_rfc3339()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn update_generation_job_session(&self, id: &str, session_id: &str) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            r#"
            UPDATE generation_jobs
            SET session_id = ?2,
                heartbeat_at = ?3,
                updated_at = ?3
            WHERE id = ?1
            "#,
            params![id, session_id, now_rfc3339()],
        )?;
        Ok(())
    }

    pub fn claim_generation_job(&self, id: &str, owner_instance_id: &str) -> Result<()> {
        if owner_instance_id.trim().is_empty() {
            return Err(PetCoreError::InvalidRequest(
                "generation owner instance id must not be empty".to_string(),
            ));
        }
        let now = now_rfc3339();
        let connection = self.open()?;
        let updated = connection.execute(
            r#"
            UPDATE generation_jobs
            SET owner_instance_id = ?2,
                heartbeat_at = ?3,
                updated_at = ?3
            WHERE id = ?1
            "#,
            params![id, owner_instance_id, now],
        )?;
        if updated == 0 {
            return Err(PetCoreError::InvalidRequest(format!(
                "generation job not found: {id}"
            )));
        }
        Ok(())
    }

    pub fn generation_job_status(&self, id: &str) -> Result<Option<GenerationJobStatus>> {
        let connection = self.open()?;
        let status = connection
            .query_row(
                "SELECT status FROM generation_jobs WHERE id = ?1",
                params![id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(|status| enum_from_name(&status))
            .transpose()?;
        Ok(status)
    }

    pub fn interrupted_generation_jobs(&self) -> Result<Vec<(String, PathBuf)>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, job_dir
            FROM generation_jobs
            WHERE status IN (?1, ?2, ?3)
            ORDER BY updated_at ASC
            "#,
        )?;
        let rows = statement.query_map(
            params![
                enum_name(GenerationJobStatus::Pending),
                enum_name(GenerationJobStatus::Running),
                enum_name(GenerationJobStatus::WaitingForUser),
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    PathBuf::from(row.get::<_, String>(1)?),
                ))
            },
        )?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn interrupted_generation_job_records(&self) -> Result<Vec<GenerationJobRecord>> {
        self.generation_jobs_with_statuses(&[
            GenerationJobStatus::Pending,
            GenerationJobStatus::Running,
            GenerationJobStatus::WaitingForUser,
        ])
    }

    pub fn active_generation_job(&self) -> Result<Option<GenerationJobRecord>> {
        let mut jobs = self.generation_jobs_with_statuses(&[
            GenerationJobStatus::Pending,
            GenerationJobStatus::Running,
            GenerationJobStatus::WaitingForUser,
        ])?;
        Ok(jobs.pop())
    }

    fn generation_jobs_with_statuses(
        &self,
        statuses: &[GenerationJobStatus],
    ) -> Result<Vec<GenerationJobRecord>> {
        debug_assert_eq!(statuses.len(), 3);
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                   retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at
            FROM generation_jobs
            WHERE status IN (?1, ?2, ?3)
            ORDER BY updated_at ASC, id ASC
            "#,
        )?;
        let rows = statement.query_map(
            params![
                enum_name(statuses[0]),
                enum_name(statuses[1]),
                enum_name(statuses[2]),
            ],
            generation_job_from_row,
        )?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn generation_job_for_pet(&self, pet_id: &str) -> Result<Option<GenerationJobRecord>> {
        let connection = self.open()?;
        connection
            .query_row(
                r#"
                SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                       retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at
                FROM generation_jobs
                WHERE result_pet_id = ?1
                ORDER BY updated_at DESC
                LIMIT 1
                "#,
                params![pet_id],
                generation_job_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    /// Returns the most recently updated generation job regardless of whether
    /// it already produced a pet. Failed and canceled create jobs intentionally
    /// have no `result_pet_id`, so they cannot be recovered through
    /// `generation_job_for_pet` after the desktop App restarts.
    pub fn latest_generation_job(&self) -> Result<Option<GenerationJobRecord>> {
        let connection = self.open()?;
        connection
            .query_row(
                r#"
                SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                       retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at
                FROM generation_jobs
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
                "#,
                [],
                generation_job_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    /// Returns a newest-first, bounded job projection for one logical pet.
    /// Callers commonly request one extra row to derive a `truncated` flag.
    pub fn generation_jobs_for_pet(
        &self,
        pet_id: &str,
        limit: usize,
    ) -> Result<Vec<GenerationJobRecord>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let limit = limit.min(MAX_GENERATION_HISTORY_QUERY_LIMIT);
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                   retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at
            FROM generation_jobs
            WHERE result_pet_id = ?1
            ORDER BY updated_at DESC, id DESC
            LIMIT ?2
            "#,
        )?;
        let rows = statement.query_map(
            params![pet_id, i64::try_from(limit).unwrap_or(i64::MAX)],
            generation_job_from_row,
        )?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn generation_job(&self, job_id: &str) -> Result<Option<GenerationJobRecord>> {
        let connection = self.open()?;
        connection
            .query_row(
                r#"
                SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                       retry_of_job_id, owner_instance_id, heartbeat_at, created_at, updated_at
                FROM generation_jobs
                WHERE id = ?1
                "#,
                params![job_id],
                generation_job_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn generation_messages(&self, job_id: &str) -> Result<Vec<GenerationMessageRecord>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, job_id, sequence, role, kind, content, progress, created_at, diagnostic_json
            FROM generation_messages
            WHERE job_id = ?1
            ORDER BY sequence ASC
            "#,
        )?;
        let rows = statement.query_map(params![job_id], generation_message_from_row)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn generation_message_revision(&self, job_id: &str) -> Result<u64> {
        let connection = self.open()?;
        let revision = connection.query_row(
            "SELECT COALESCE(MAX(sequence), 0) FROM generation_messages WHERE job_id = ?1",
            params![job_id],
            |row| row.get::<_, i64>(0),
        )?;
        u64::try_from(revision).map_err(|_| {
            PetCoreError::Validation("generation message sequence must be non-negative".into())
        })
    }

    pub fn generation_messages_migrated(&self, job_id: &str) -> Result<bool> {
        let connection = self.open()?;
        Ok(connection
            .query_row(
                "SELECT 1 FROM generation_message_migrations WHERE job_id = ?1",
                params![job_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    pub fn mark_generation_messages_migrated(&self, job_id: &str) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            r#"
            INSERT OR IGNORE INTO generation_message_migrations (job_id, migrated_at)
            VALUES (?1, ?2)
            "#,
            params![job_id, now_rfc3339()],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn import_generation_message(
        &self,
        id: &str,
        job_id: &str,
        role: &str,
        kind: Option<&str>,
        content: &str,
        progress: f64,
        created_at: &str,
        diagnostic: Option<&serde_json::Value>,
    ) -> Result<Option<GenerationMessageRecord>> {
        self.insert_generation_message(
            Some(id),
            job_id,
            role,
            kind,
            content,
            progress,
            created_at,
            diagnostic,
            None,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn append_generation_message(
        &self,
        job_id: &str,
        role: &str,
        kind: Option<&str>,
        content: &str,
        progress: f64,
        status_transition: Option<GenerationJobStatus>,
        result_pet_id: Option<&str>,
    ) -> Result<GenerationMessageRecord> {
        self.insert_generation_message(
            None,
            job_id,
            role,
            kind,
            content,
            progress,
            &now_rfc3339(),
            None,
            status_transition,
            result_pet_id,
        )?
        .ok_or_else(|| {
            PetCoreError::Validation("new generation message was not inserted".to_string())
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_generation_message(
        &self,
        explicit_id: Option<&str>,
        job_id: &str,
        role: &str,
        kind: Option<&str>,
        content: &str,
        progress: f64,
        created_at: &str,
        diagnostic: Option<&serde_json::Value>,
        status_transition: Option<GenerationJobStatus>,
        result_pet_id: Option<&str>,
    ) -> Result<Option<GenerationMessageRecord>> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let job_status = transaction
            .query_row(
                "SELECT status FROM generation_jobs WHERE id = ?1",
                params![job_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(job_status) = job_status else {
            return Err(PetCoreError::InvalidRequest(format!(
                "generation job not found: {job_id}"
            )));
        };
        let job_status: GenerationJobStatus = enum_from_name(&job_status)?;
        if let Some(status) = status_transition {
            reject_other_active_generation(&transaction, job_id, status)?;
        }

        if explicit_id.is_none()
            && kind.is_some_and(is_terminal_generation_message_kind)
            && is_terminal_generation_status(job_status)
        {
            if let Some(existing) = transaction
                .query_row(
                    r#"
                    SELECT id, job_id, sequence, role, kind, content, progress, created_at, diagnostic_json
                    FROM generation_messages
                    WHERE job_id = ?1
                      AND kind IN ('generation_completed', 'generation_failed', 'generation_canceled')
                    ORDER BY sequence DESC
                    LIMIT 1
                    "#,
                    params![job_id],
                    generation_message_from_row,
                )
                .optional()?
            {
                let existing_status = existing
                    .kind
                    .as_deref()
                    .and_then(generation_status_for_terminal_message_kind);
                if existing_status == Some(job_status) {
                    transaction.commit()?;
                    return Ok(Some(existing));
                }
            }
            let requested_status = kind.and_then(generation_status_for_terminal_message_kind);
            if requested_status != Some(job_status) {
                return Err(PetCoreError::InvalidRequest(format!(
                    "generation job {job_id} already has immutable terminal status {}",
                    enum_name(job_status)
                )));
            }
        }

        let sequence = transaction.query_row(
            "SELECT COALESCE(MAX(sequence), 0) + 1 FROM generation_messages WHERE job_id = ?1",
            params![job_id],
            |row| row.get::<_, i64>(0),
        )?;
        let id = explicit_id
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| new_id("msg"));
        let inserted = transaction.execute(
            r#"
            INSERT OR IGNORE INTO generation_messages
              (id, job_id, sequence, role, kind, content, progress, created_at, diagnostic_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                id,
                job_id,
                sequence,
                role,
                kind,
                content,
                progress,
                created_at,
                diagnostic.map(serde_json::to_string).transpose()?,
            ],
        )?;
        if inserted == 0 {
            transaction.commit()?;
            return Ok(None);
        }
        if let Some(status) = status_transition {
            let now = now_rfc3339();
            transaction.execute(
                r#"
                UPDATE generation_jobs
                SET status = ?2,
                    result_pet_id = COALESCE(?3, result_pet_id),
                    heartbeat_at = ?4,
                    updated_at = ?4
                WHERE id = ?1
                "#,
                params![job_id, enum_name(status), result_pet_id, now],
            )?;
        }
        transaction.commit()?;
        Ok(Some(GenerationMessageRecord {
            id,
            job_id: job_id.to_string(),
            sequence: u64::try_from(sequence).map_err(|_| {
                PetCoreError::Validation("generation message sequence overflow".to_string())
            })?,
            role: role.to_string(),
            kind: kind.map(ToOwned::to_owned),
            content: content.to_string(),
            progress,
            created_at: created_at.to_string(),
            diagnostic: diagnostic.cloned(),
        }))
    }

    pub fn upsert_pet(&self, pet: &PetSummary) -> Result<()> {
        let connection = self.open()?;
        let state_durations_json = serde_json::to_string(&pet.state_durations_ms)?;
        connection.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, native_fps, state_durations_json, petpack_path, cover_path, origin, generator, provenance, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              native_fps = excluded.native_fps,
              state_durations_json = excluded.state_durations_json,
              petpack_path = excluded.petpack_path,
              cover_path = excluded.cover_path,
              origin = excluded.origin,
              generator = excluded.generator,
              provenance = excluded.provenance,
              active = excluded.active,
              created_at = excluded.created_at
            "#,
            params![
                pet.id,
                pet.name,
                pet.style,
                enum_name(pet.quality),
                pet.render_size.width as i64,
                pet.render_size.height as i64,
                pet.native_fps as i64,
                state_durations_json,
                pet.petpack_path,
                pet.cover_path,
                enum_name(pet.origin),
                pet.generator,
                pet.provenance,
                if pet.active { 1 } else { 0 },
                pet.created_at,
            ],
        )?;
        Ok(())
    }

    /// Commits a pet summary and the "first pet becomes active" rule in one
    /// SQLite transaction. Callers can therefore publish an immutable asset
    /// revision and roll it back as a unit when this transaction fails.
    pub fn upsert_pet_and_activate_if_first(&self, pet: &PetSummary) -> Result<bool> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        let state_durations_json = serde_json::to_string(&pet.state_durations_ms)?;
        let pet_count: i64 =
            transaction.query_row("SELECT COUNT(*) FROM pets", [], |row| row.get(0))?;
        let effective_active = pet_count == 0 || pet.active;
        transaction.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, native_fps, state_durations_json, petpack_path, cover_path, origin, generator, provenance, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              native_fps = excluded.native_fps,
              state_durations_json = excluded.state_durations_json,
              petpack_path = excluded.petpack_path,
              cover_path = excluded.cover_path,
              origin = excluded.origin,
              generator = excluded.generator,
              provenance = excluded.provenance,
              active = excluded.active,
              created_at = excluded.created_at
            "#,
            params![
                pet.id,
                pet.name,
                pet.style,
                enum_name(pet.quality),
                pet.render_size.width as i64,
                pet.render_size.height as i64,
                pet.native_fps as i64,
                state_durations_json,
                pet.petpack_path,
                pet.cover_path,
                enum_name(pet.origin),
                pet.generator,
                pet.provenance,
                if effective_active { 1 } else { 0 },
                pet.created_at,
            ],
        )?;
        transaction.commit()?;
        Ok(effective_active)
    }

    pub fn list_pets(&self) -> Result<Vec<PetSummary>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, name, style, quality, render_width, render_height, native_fps, state_durations_json, petpack_path, cover_path, origin, generator, provenance, active, created_at
            FROM pets
            ORDER BY created_at DESC
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            let quality: String = row.get(3)?;
            let (native_fps, state_durations_ms) =
                decode_pet_timing(row.get(6)?, &row.get::<_, String>(7)?)?;
            Ok(PetSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                style: row.get(2)?,
                quality: enum_from_name::<QualityLevel>(&quality).map_err(to_sql_error)?,
                render_size: RenderSize {
                    width: row.get::<_, i64>(4)? as u32,
                    height: row.get::<_, i64>(5)? as u32,
                },
                native_fps,
                state_durations_ms,
                petpack_path: row.get(8)?,
                cover_path: row.get(9)?,
                origin: enum_from_name::<PetOrigin>(&row.get::<_, String>(10)?)
                    .map_err(to_sql_error)?,
                generator: row.get(11)?,
                provenance: row.get(12)?,
                revision_id: None,
                revision_count: 0,
                active: row.get::<_, i64>(13)? == 1,
                created_at: row.get(14)?,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn get_pet(&self, pet_id: &str) -> Result<Option<PetSummary>> {
        let connection = self.open()?;
        let pet = connection
            .query_row(
                r#"
                SELECT id, name, style, quality, render_width, render_height, native_fps, state_durations_json, petpack_path, cover_path, origin, generator, provenance, active, created_at
                FROM pets
                WHERE id = ?1
                "#,
                params![pet_id],
                |row| {
                    let quality: String = row.get(3)?;
                    let (native_fps, state_durations_ms) = decode_pet_timing(row.get(6)?, &row.get::<_, String>(7)?)?;
                    Ok(PetSummary {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        style: row.get(2)?,
                        quality: enum_from_name::<QualityLevel>(&quality).map_err(to_sql_error)?,
                        render_size: RenderSize {
                            width: row.get::<_, i64>(4)? as u32,
                            height: row.get::<_, i64>(5)? as u32,
                        },
                        native_fps,
                        state_durations_ms,
                        petpack_path: row.get(8)?,
                        cover_path: row.get(9)?,
                        origin: enum_from_name::<PetOrigin>(&row.get::<_, String>(10)?)
                            .map_err(to_sql_error)?,
                        generator: row.get(11)?,
                        provenance: row.get(12)?,
                        revision_id: None,
                        revision_count: 0,
                        active: row.get::<_, i64>(13)? == 1,
                        created_at: row.get(14)?,
                    })
                },
            )
            .optional()?;
        Ok(pet)
    }

    pub fn pet_asset_validation(&self, pet_id: &str) -> Result<Option<PetAssetValidationRecord>> {
        let connection = self.open()?;
        connection
            .query_row(
                r#"
                SELECT fingerprint, valid, error, validated_at
                FROM pet_asset_validation
                WHERE pet_id = ?1
                "#,
                params![pet_id],
                |row| {
                    Ok(PetAssetValidationRecord {
                        fingerprint: row.get(0)?,
                        valid: row.get::<_, i64>(1)? == 1,
                        error: row.get(2)?,
                        validated_at: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn set_pet_asset_validation(
        &self,
        pet_id: &str,
        fingerprint: &str,
        valid: bool,
        error: Option<&str>,
    ) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            r#"
            INSERT INTO pet_asset_validation
              (pet_id, fingerprint, valid, error, validated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(pet_id) DO UPDATE SET
              fingerprint = excluded.fingerprint,
              valid = excluded.valid,
              error = excluded.error,
              validated_at = excluded.validated_at
            "#,
            params![
                pet_id,
                fingerprint,
                if valid { 1 } else { 0 },
                error,
                now_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn activate_pet(&self, pet_id: &str) -> Result<()> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        let exists = transaction
            .query_row("SELECT 1 FROM pets WHERE id = ?1", params![pet_id], |row| {
                row.get::<_, i64>(0)
            })
            .optional()?
            .is_some();
        if !exists {
            return Err(PetCoreError::InvalidRequest(format!(
                "pet not found: {pet_id}"
            )));
        }
        transaction.execute("UPDATE pets SET active = 0", [])?;
        transaction.execute("UPDATE pets SET active = 1 WHERE id = ?1", params![pet_id])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn delete_pet(&self, pet_id: &str) -> Result<()> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        transaction.execute(
            "DELETE FROM pet_asset_validation WHERE pet_id = ?1",
            params![pet_id],
        )?;
        transaction.execute("DELETE FROM pets WHERE id = ?1", params![pet_id])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn delete_pet_and_activate_next(
        &self,
        pet_id: &str,
        activate_next: bool,
    ) -> Result<Option<String>> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        transaction.execute(
            "DELETE FROM pet_asset_validation WHERE pet_id = ?1",
            params![pet_id],
        )?;
        let deleted = transaction.execute("DELETE FROM pets WHERE id = ?1", params![pet_id])?;
        if deleted == 0 {
            return Err(PetCoreError::InvalidRequest(format!(
                "pet not found: {pet_id}"
            )));
        }

        let next_pet_id = if activate_next {
            let next_pet_id = transaction
                .query_row(
                    "SELECT id FROM pets ORDER BY created_at DESC LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            if let Some(next_pet_id) = &next_pet_id {
                transaction.execute("UPDATE pets SET active = 0", [])?;
                transaction.execute(
                    "UPDATE pets SET active = 1 WHERE id = ?1",
                    params![next_pet_id],
                )?;
            }
            next_pet_id
        } else {
            None
        };

        transaction.commit()?;
        Ok(next_pet_id)
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
    let row_id = row.get::<_, i64>(0)?;
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
        event: agent_event_from_row(row, 1)?,
    })
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
    event
        .payload_json
        .get("message_content")
        .and_then(Value::as_str)
        .is_some_and(|message| !message.trim().is_empty())
}

fn event_arrived_after_turn_terminal(
    connection: &Connection,
    event: &AgentEvent,
    session_key: &str,
) -> Result<bool> {
    if matches!(
        event.event_type,
        AgentEventType::Done | AgentEventType::Failed
    ) || event
        .payload_json
        .get("diagnostic")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || event
            .payload_json
            .get("affects_activity")
            .and_then(Value::as_bool)
            == Some(false)
    {
        return Ok(false);
    }
    let Some(turn_id) = event
        .payload_json
        .get("turn_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(false);
    };

    let mut statement = connection.prepare(
        r#"
        SELECT event_type, payload_json
        FROM agent_events
        WHERE source = ?1 AND session_key = ?2
        ORDER BY row_id DESC
        "#,
    )?;
    let rows = statement.query_map(params![enum_name(event.source), session_key], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (event_type, payload_json) = row?;
        if !matches!(event_type.as_str(), "done" | "failed") {
            continue;
        }
        let Ok(payload) = serde_json::from_str::<Value>(&payload_json) else {
            continue;
        };
        if matches!(
            payload.get("source_event").and_then(Value::as_str),
            Some("app_server_activity" | "connection.test")
        ) {
            continue;
        }
        if payload.get("turn_id").and_then(Value::as_str) == Some(turn_id) {
            return Ok(true);
        }
    }
    Ok(false)
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
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
    })
}

fn generation_message_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<GenerationMessageRecord> {
    let sequence = row.get::<_, i64>(2)?;
    let diagnostic_json = row.get::<_, Option<String>>(8)?;
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
    let active_job_id = transaction
        .query_row(
            r#"
            SELECT id
            FROM generation_jobs
            WHERE id <> ?1 AND status IN (?2, ?3, ?4)
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
            params![
                job_id,
                enum_name(GenerationJobStatus::Pending),
                enum_name(GenerationJobStatus::Running),
                enum_name(GenerationJobStatus::WaitingForUser),
            ],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(active_job_id) = active_job_id {
        return Err(PetCoreError::InvalidRequest(format!(
            "active generation job already exists: {active_job_id}"
        )));
    }
    Ok(())
}

fn to_sql_error(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

fn decode_pet_timing(
    native_fps: i64,
    state_durations_json: &str,
) -> std::result::Result<(u32, BTreeMap<PetStateName, u32>), rusqlite::Error> {
    let native_fps = u32::try_from(native_fps).map_err(to_sql_error)?;
    if !matches!(native_fps, STANDARD_FPS | SMOOTH_FPS) {
        return Err(to_sql_error(PetCoreError::Validation(format!(
            "stored pet has unsupported native_fps {native_fps}"
        ))));
    }
    let state_durations_ms: BTreeMap<PetStateName, u32> =
        serde_json::from_str(state_durations_json).map_err(to_sql_error)?;
    if state_durations_ms.len() != REQUIRED_STATES.len()
        || REQUIRED_STATES.iter().any(|state| {
            !matches!(
                state_durations_ms.get(state),
                Some(&SHORT_ACTION_DURATION_MS) | Some(&LONG_ACTION_DURATION_MS)
            )
        })
    {
        return Err(to_sql_error(PetCoreError::Validation(
            "stored pet has invalid state duration contract".to_string(),
        )));
    }
    Ok((native_fps, state_durations_ms))
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
            created_at: "2026-07-20T00:00:00Z".to_string(),
        }
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
            message_event("user-first", "user", "first prompt", "2026-07-20T00:00:00Z"),
            message_event(
                "assistant-first",
                "assistant",
                "first answer",
                "2026-07-20T00:00:01Z",
            ),
            message_event("user-latest", "user", "next prompt", "2026-07-20T00:00:02Z"),
            message_event(
                "assistant-empty",
                "assistant",
                "   ",
                "2026-07-20T00:00:03Z",
            ),
            message_event(
                "assistant-latest",
                "assistant",
                "latest answer",
                "2026-07-20T00:00:04Z",
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
                    ["assistant-latest", "assistant-empty", "user-latest"]
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
                "2026-07-20T00:00:00Z",
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
                    "2026-07-20T00:00:01Z",
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
                "2026-07-20T00:00:00Z",
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
                    "2026-07-20T00:00:01Z",
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
            task_evidence_event_matches(
                AgentSource::Opencode,
                COMPLETIONS,
                source_event,
                &json!({ "outcome": outcome, "session_active": active }),
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
