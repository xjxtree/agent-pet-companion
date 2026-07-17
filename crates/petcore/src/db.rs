use crate::agent_state::SequencedAgentEvent;
use crate::event_envelope::{
    minimal_legacy_payload, normalized_session_id, normalized_session_key, persisted_payload,
    MAX_RECENT_EVENTS,
};
use crate::{enum_from_name, enum_name, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentEvent, AgentEventType, AgentSource, AppearanceTheme,
    BehaviorSettings, FpsProfileName, GenerationForm, GenerationJobStatus, GenerationMessageRecord,
    OverlayPlacement, PetOrigin, PetSummary, QualityLevel, RenderSize, MAX_BUBBLE_TRANSPARENCY,
    MAX_SESSION_MESSAGE_TIMEOUT_MINUTES, MIN_BUBBLE_TRANSPARENCY,
    MIN_SESSION_MESSAGE_TIMEOUT_MINUTES,
};
use rusqlite::{params, Connection, ErrorCode, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventRetentionPolicy {
    pub max_rows: u64,
    pub max_age_days: u32,
}

impl Default for EventRetentionPolicy {
    fn default() -> Self {
        Self {
            max_rows: 10_000,
            max_age_days: 30,
        }
    }
}

pub const DATABASE_SCHEMA_VERSION: u32 = 4;
const EVENT_PRIVACY_MIGRATION_KEY: &str = "event-envelope-v4-secure-vacuum";

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
        Ok(Connection::open(&self.path)?)
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

            CREATE TABLE IF NOT EXISTS state_revision (
              singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
              revision INTEGER NOT NULL CHECK(revision >= 0)
            );
            INSERT OR IGNORE INTO state_revision (singleton, revision) VALUES (1, 0);
            "#,
        )?;
        self.migrate_agent_events(&mut connection)?;
        self.ensure_pets_metadata_columns(&connection)?;
        self.ensure_generation_job_columns(&connection)?;
        self.ensure_settings_columns(&connection)?;
        self.ensure_state_revision_triggers(&connection)?;
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

    pub fn overlay_placement(&self) -> Result<OverlayPlacement> {
        Ok(self
            .get_setting("overlay_placement")?
            .unwrap_or_else(OverlayPlacement::default))
    }

    pub fn connection_statuses(&self) -> Result<Vec<AgentConnectionStatus>> {
        Ok(self.get_setting("connection_statuses")?.unwrap_or_default())
    }

    pub fn upsert_connection_status(&self, status: &AgentConnectionStatus) -> Result<()> {
        let mut statuses = self.connection_statuses()?;
        statuses.retain(|existing| existing.source != status.source);
        statuses.push(status.clone());
        statuses.sort_by_key(|status| source_sort_key(status.source));
        self.set_setting("connection_statuses", &statuses)
    }

    pub fn upsert_connection_statuses(&self, incoming: &[AgentConnectionStatus]) -> Result<()> {
        let mut statuses = self.connection_statuses()?;
        for status in incoming {
            statuses.retain(|existing| existing.source != status.source);
            statuses.push(status.clone());
        }
        statuses.sort_by_key(|status| source_sort_key(status.source));
        self.set_setting("connection_statuses", &statuses)
    }

    pub fn state_revision(&self) -> Result<u64> {
        let connection = self.open()?;
        let revision = connection.query_row(
            "SELECT revision FROM state_revision WHERE singleton = 1",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        u64::try_from(revision).map_err(|_| {
            PetCoreError::Validation("state revision must be a non-negative integer".to_string())
        })
    }

    pub fn insert_event(&self, event: &AgentEvent) -> Result<InsertEventOutcome> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        let session_id = normalized_session_id(event.session_id.as_deref());
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
                normalized_session_key(session_id.as_deref()),
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
        let transaction = connection.transaction()?;
        let session_id = normalized_session_id(event.session_id.as_deref());
        let session_key = normalized_session_key(session_id.as_deref());
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
        let mut statement = connection.prepare(
            r#"
            SELECT external_event_id, source, project_path, session_id, event_type,
                   title, detail, payload_json, created_at
            FROM agent_events
            ORDER BY created_at DESC, row_id DESC
            LIMIT ?1
            "#,
        )?;

        let rows = statement.query_map(params![limit as i64], |row| {
            let source: String = row.get(1)?;
            let event_type: String = row.get(4)?;
            let payload_json: String = row.get(7)?;
            Ok(AgentEvent {
                id: row.get(0)?,
                source: enum_from_name(&source).map_err(to_sql_error)?,
                project_path: row.get(2)?,
                session_id: row.get(3)?,
                event_type: enum_from_name(&event_type).map_err(to_sql_error)?,
                title: row.get(5)?,
                detail: row.get(6)?,
                payload_json: serde_json::from_str(&payload_json).map_err(to_sql_error)?,
                created_at: row.get(8)?,
            })
        })?;

        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
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
                session_activated_at: None,
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
        let limit = limit.min(MAX_RECENT_EVENTS);
        if limit == 0 {
            return Ok(Vec::new());
        }
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            WITH ranked AS (
              SELECT row_id, external_event_id, source, project_path, session_id,
                     session_key, event_type, title, detail, payload_json, created_at,
                     MAX(CASE WHEN event_type = 'start' THEN created_at END) OVER (
                       PARTITION BY source, session_key
                     ) AS session_activated_at,
                     ROW_NUMBER() OVER (
                       PARTITION BY source, session_key
                       ORDER BY created_at DESC, row_id DESC
                     ) AS session_rank
              FROM agent_events
            )
            SELECT row_id, external_event_id, source, project_path, session_id, event_type,
                   title, detail, payload_json, created_at, session_activated_at
            FROM ranked
            WHERE session_rank = 1
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
                session_activated_at: row.get(10)?,
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
        self.session_message_for_role(source, session_id, role, true)
    }

    pub fn first_session_message_for_role(
        &self,
        source: AgentSource,
        session_id: Option<&str>,
        role: Option<&str>,
    ) -> Result<Option<AgentEvent>> {
        self.session_message_for_role(source, session_id, role, false)
    }

    fn session_message_for_role(
        &self,
        source: AgentSource,
        session_id: Option<&str>,
        role: Option<&str>,
        newest_first: bool,
    ) -> Result<Option<AgentEvent>> {
        let connection = self.open()?;
        let session_id = normalized_session_id(session_id);
        let query = if newest_first {
            r#"
            SELECT external_event_id, source, project_path, session_id, event_type,
                   title, detail, payload_json, created_at
            FROM agent_events
            WHERE source = ?1 AND session_key = ?2
            ORDER BY created_at DESC, row_id DESC
            "#
        } else {
            r#"
            SELECT external_event_id, source, project_path, session_id, event_type,
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
            |row| {
                let source: String = row.get(1)?;
                let event_type: String = row.get(4)?;
                let payload_json: String = row.get(7)?;
                Ok(AgentEvent {
                    id: row.get(0)?,
                    source: enum_from_name(&source).map_err(to_sql_error)?,
                    project_path: row.get(2)?,
                    session_id: row.get(3)?,
                    event_type: enum_from_name(&event_type).map_err(to_sql_error)?,
                    title: row.get(5)?,
                    detail: row.get(6)?,
                    payload_json: serde_json::from_str(&payload_json).map_err(to_sql_error)?,
                    created_at: row.get(8)?,
                })
            },
        )?;
        for row in rows {
            let event = row?;
            let payload_role = event
                .payload_json
                .get("message_role")
                .and_then(serde_json::Value::as_str);
            if role.is_none_or(|role| payload_role == Some(role))
                && event
                    .payload_json
                    .get("message_content")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|message| !message.trim().is_empty())
            {
                return Ok(Some(event));
            }
        }
        Ok(None)
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
        connection.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, petpack_path, cover_path, origin, generator, provenance, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
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
        let pet_count: i64 =
            transaction.query_row("SELECT COUNT(*) FROM pets", [], |row| row.get(0))?;
        let effective_active = pet_count == 0 || pet.active;
        transaction.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, petpack_path, cover_path, origin, generator, provenance, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
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
            SELECT id, name, style, quality, render_width, render_height, petpack_path, cover_path, origin, generator, provenance, active, created_at
            FROM pets
            ORDER BY created_at DESC
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            let quality: String = row.get(3)?;
            Ok(PetSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                style: row.get(2)?,
                quality: enum_from_name::<QualityLevel>(&quality).map_err(to_sql_error)?,
                render_size: RenderSize {
                    width: row.get::<_, i64>(4)? as u32,
                    height: row.get::<_, i64>(5)? as u32,
                },
                petpack_path: row.get(6)?,
                cover_path: row.get(7)?,
                origin: enum_from_name::<PetOrigin>(&row.get::<_, String>(8)?)
                    .map_err(to_sql_error)?,
                generator: row.get(9)?,
                provenance: row.get(10)?,
                active: row.get::<_, i64>(11)? == 1,
                created_at: row.get(12)?,
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
                SELECT id, name, style, quality, render_width, render_height, petpack_path, cover_path, origin, generator, provenance, active, created_at
                FROM pets
                WHERE id = ?1
                "#,
                params![pet_id],
                |row| {
                    let quality: String = row.get(3)?;
                    Ok(PetSummary {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        style: row.get(2)?,
                        quality: enum_from_name::<QualityLevel>(&quality).map_err(to_sql_error)?,
                        render_size: RenderSize {
                            width: row.get::<_, i64>(4)? as u32,
                            height: row.get::<_, i64>(5)? as u32,
                        },
                        petpack_path: row.get(6)?,
                        cover_path: row.get(7)?,
                        origin: enum_from_name::<PetOrigin>(&row.get::<_, String>(8)?)
                            .map_err(to_sql_error)?,
                        generator: row.get(9)?,
                        provenance: row.get(10)?,
                        active: row.get::<_, i64>(11)? == 1,
                        created_at: row.get(12)?,
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
    Ok(rows.len())
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
