use crate::{enum_from_name, enum_name, now_rfc3339, Result};
use petcore_types::{
    AgentEvent, BehaviorSettings, GenerationForm, GenerationJobStatus, PetSummary, QualityLevel,
    RenderSize,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::path::{Path, PathBuf};

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
        let connection = self.open()?;
        connection.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS pets (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              style TEXT NOT NULL,
              quality TEXT NOT NULL,
              render_width INTEGER NOT NULL,
              render_height INTEGER NOT NULL,
              petpack_path TEXT NOT NULL,
              cover_path TEXT NOT NULL,
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
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS agent_events (
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              project_path TEXT,
              session_id TEXT,
              event_type TEXT NOT NULL,
              title TEXT,
              detail TEXT,
              payload_json TEXT NOT NULL,
              created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value_json TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            "#,
        )?;

        self.ensure_setting("behavior", &BehaviorSettings::default())?;
        Ok(())
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
            INSERT INTO settings (key, value_json, updated_at)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(key) DO UPDATE SET
              value_json = excluded.value_json,
              updated_at = excluded.updated_at
            "#,
            params![key, serde_json::to_string_pretty(value)?, now_rfc3339()],
        )?;
        Ok(())
    }

    pub fn behavior(&self) -> Result<BehaviorSettings> {
        Ok(self
            .get_setting("behavior")?
            .unwrap_or_else(BehaviorSettings::default))
    }

    pub fn insert_event(&self, event: &AgentEvent) -> Result<bool> {
        let connection = self.open()?;
        let changed = connection.execute(
            r#"
            INSERT OR IGNORE INTO agent_events
              (id, source, project_path, session_id, event_type, title, detail, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                event.id,
                enum_name(event.source),
                event.project_path,
                event.session_id,
                enum_name(event.event_type),
                event.title,
                event.detail,
                serde_json::to_string(&event.payload_json)?,
                event.created_at,
            ],
        )?;
        Ok(changed > 0)
    }

    pub fn recent_events(&self, limit: usize) -> Result<Vec<AgentEvent>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, source, project_path, session_id, event_type, title, detail, payload_json, created_at
            FROM agent_events
            ORDER BY created_at DESC
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

    pub fn create_generation_job(
        &self,
        id: &str,
        form: &GenerationForm,
        job_dir: &Path,
    ) -> Result<()> {
        let now = now_rfc3339();
        let connection = self.open()?;
        connection.execute(
            r#"
            INSERT INTO generation_jobs
              (id, status, form_json, session_id, job_dir, result_pet_id, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, ?6)
            "#,
            params![
                id,
                enum_name(GenerationJobStatus::Pending),
                serde_json::to_string_pretty(form)?,
                format!("session_{id}"),
                job_dir.display().to_string(),
                now,
            ],
        )?;
        Ok(())
    }

    pub fn update_generation_job(
        &self,
        id: &str,
        status: GenerationJobStatus,
        result_pet_id: Option<&str>,
    ) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            r#"
            UPDATE generation_jobs
            SET status = ?2,
                result_pet_id = COALESCE(?3, result_pet_id),
                updated_at = ?4
            WHERE id = ?1
            "#,
            params![id, enum_name(status), result_pet_id, now_rfc3339()],
        )?;
        Ok(())
    }

    pub fn upsert_pet(&self, pet: &PetSummary) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, petpack_path, cover_path, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              petpack_path = excluded.petpack_path,
              cover_path = excluded.cover_path,
              active = excluded.active
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
                if pet.active { 1 } else { 0 },
                pet.created_at,
            ],
        )?;
        Ok(())
    }

    pub fn list_pets(&self) -> Result<Vec<PetSummary>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, name, style, quality, render_width, render_height, petpack_path, cover_path, active, created_at
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
                active: row.get::<_, i64>(8)? == 1,
                created_at: row.get(9)?,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn activate_pet(&self, pet_id: &str) -> Result<()> {
        let mut connection = self.open()?;
        let transaction = connection.transaction()?;
        transaction.execute("UPDATE pets SET active = 0", [])?;
        transaction.execute("UPDATE pets SET active = 1 WHERE id = ?1", params![pet_id])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn delete_pet(&self, pet_id: &str) -> Result<()> {
        let connection = self.open()?;
        connection.execute("DELETE FROM pets WHERE id = ?1", params![pet_id])?;
        Ok(())
    }
}

fn to_sql_error(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}
