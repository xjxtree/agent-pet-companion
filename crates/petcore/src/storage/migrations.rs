use super::*;

impl Database {
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
        preflight_active_generation_forms(&connection)?;
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
        let pre_v2_pet_table = table_exists(&connection, "pets")?
            && !table_has_column(&connection, "pets", "states_json")?;
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
              states_json TEXT NOT NULL DEFAULT '[{"name":"idle","frames_dir":"assets/frames/idle","frame_durations_ms":[260,220,240,260,380,640],"playback":{"mode":"periodic","cooldown_ms":[2500,5000]},"reduced_motion_frame_index":2},{"name":"thinking","frames_dir":"assets/frames/thinking","frame_durations_ms":[120,140,160,180],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"tool","frames_dir":"assets/frames/tool","frame_durations_ms":[150,150,170,330],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"waiting","frames_dir":"assets/frames/waiting","frame_durations_ms":[100,100,110,110,120,130,160,230],"playback":{"mode":"burst_then_settle","entry_repeat_count":3,"settle_frame_index":7},"reduced_motion_frame_index":4},{"name":"done","frames_dir":"assets/frames/done","frame_durations_ms":[120,140,160,230],"playback":{"mode":"burst_then_idle","entry_repeat_count":3},"reduced_motion_frame_index":2},{"name":"failed","frames_dir":"assets/frames/failed","frame_durations_ms":[80,80,90,100,110,120,190,290],"playback":{"mode":"burst_then_settle","entry_repeat_count":3,"settle_frame_index":7},"reduced_motion_frame_index":2},{"name":"acknowledge","frames_dir":"assets/frames/acknowledge","frame_durations_ms":[180,140,180,300],"playback":{"mode":"once_then_return"},"reduced_motion_frame_index":1},{"name":"drag_left","frames_dir":"assets/frames/drag_left","frame_durations_ms":[100,90,100,110,100,200],"playback":{"mode":"loop"},"reduced_motion_frame_index":2},{"name":"drag_right","frames_dir":"assets/frames/drag_right","frame_durations_ms":[100,90,100,110,100,200],"playback":{"mode":"loop"},"reduced_motion_frame_index":2}]',
              petpack_path TEXT NOT NULL,
              cover_path TEXT NOT NULL,
              origin TEXT NOT NULL DEFAULT 'external_import',
              generator TEXT,
              provenance TEXT,
              active INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS retired_pet_records (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              style TEXT NOT NULL,
              quality TEXT NOT NULL,
              render_width INTEGER NOT NULL,
              render_height INTEGER NOT NULL,
              states_json TEXT NOT NULL,
              legacy_native_fps INTEGER,
              legacy_state_durations_json TEXT,
              petpack_path TEXT NOT NULL,
              cover_path TEXT NOT NULL,
              origin TEXT NOT NULL,
              generator TEXT,
              provenance TEXT,
              active INTEGER NOT NULL,
              created_at TEXT NOT NULL,
              retired_reason TEXT NOT NULL
                CHECK(retired_reason IN (
                  'unsupported_quality',
                  'unsupported_state_contract'
                )),
              retired_at TEXT NOT NULL
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
              started_at TEXT NOT NULL,
              ended_at TEXT,
              cancel_requested_at TEXT,
              execution_stopped_at TEXT,
              thread_archived_at TEXT,
              recoverable INTEGER NOT NULL DEFAULT 0 CHECK(recoverable IN (0, 1)),
              failure_code TEXT,
              pause_reason TEXT,
              active_turn_id TEXT,
              last_checkpoint_at TEXT,
              visible_title TEXT NOT NULL DEFAULT '',
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
              payload_json TEXT,
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

            CREATE TABLE IF NOT EXISTS generation_action_requests (
              job_id TEXT NOT NULL,
              request_id TEXT NOT NULL,
              action TEXT NOT NULL,
              content_sha256 TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY(job_id, request_id),
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
        self.ensure_pets_metadata_columns(&connection)?;
        self.ensure_retired_pet_record_columns(&mut connection)?;
        self.ensure_generation_job_columns(&connection)?;
        self.ensure_generation_message_columns(&connection)?;
        self.ensure_settings_columns(&connection)?;
        self.migrate_removed_agent_event_data(&mut connection)?;
        self.migrate_agent_session_aliases(&mut connection)?;
        self.ensure_state_revision_triggers(&connection)?;
        self.migrate_legacy_overlay_placement(&mut connection)?;
        self.migrate_retired_pet_qualities(&mut connection, pre_v2_pet_table)?;
        self.migrate_retired_pet_state_contracts(&mut connection)?;
        self.migrate_internal_codex_suggestion_sessions(&mut connection)?;
        self.migrate_internal_pet_studio_sessions(&mut connection)?;
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
        self.ensure_setting(OVERLAY_PLACEMENT_SETTING_KEY, &OverlayPlacement::default())?;
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
        if !table_has_column(connection, "pets", "states_json")? {
            let sql = format!(
                "ALTER TABLE pets ADD COLUMN states_json TEXT NOT NULL DEFAULT '{DEFAULT_PET_STATES_JSON}'"
            );
            connection.execute(&sql, [])?;
        }
        Ok(())
    }

    fn ensure_retired_pet_record_columns(&self, connection: &mut Connection) -> Result<()> {
        if !table_has_column(connection, "retired_pet_records", "legacy_native_fps")? {
            connection.execute(
                "ALTER TABLE retired_pet_records ADD COLUMN legacy_native_fps INTEGER",
                [],
            )?;
        }
        if !table_has_column(
            connection,
            "retired_pet_records",
            "legacy_state_durations_json",
        )? {
            connection.execute(
                "ALTER TABLE retired_pet_records ADD COLUMN legacy_state_durations_json TEXT",
                [],
            )?;
        }
        let table_sql = connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'retired_pet_records'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .unwrap_or_default();
        if table_sql.contains("unsupported_state_contract") {
            return Ok(());
        }

        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(
            r#"
            ALTER TABLE retired_pet_records
              RENAME TO retired_pet_records_legacy_reason;

            CREATE TABLE retired_pet_records (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              style TEXT NOT NULL,
              quality TEXT NOT NULL,
              render_width INTEGER NOT NULL,
              render_height INTEGER NOT NULL,
              states_json TEXT NOT NULL,
              legacy_native_fps INTEGER,
              legacy_state_durations_json TEXT,
              petpack_path TEXT NOT NULL,
              cover_path TEXT NOT NULL,
              origin TEXT NOT NULL,
              generator TEXT,
              provenance TEXT,
              active INTEGER NOT NULL,
              created_at TEXT NOT NULL,
              retired_reason TEXT NOT NULL
                CHECK(retired_reason IN (
                  'unsupported_quality',
                  'unsupported_state_contract'
                )),
              retired_at TEXT NOT NULL
            );

            INSERT INTO retired_pet_records (
              id, name, style, quality, render_width, render_height,
              states_json, legacy_native_fps, legacy_state_durations_json,
              petpack_path, cover_path, origin, generator, provenance, active,
              created_at, retired_reason, retired_at
            )
            SELECT
              id, name, style, quality, render_width, render_height,
              states_json, legacy_native_fps, legacy_state_durations_json,
              petpack_path, cover_path, origin, generator, provenance, active,
              created_at, retired_reason, retired_at
            FROM retired_pet_records_legacy_reason;

            DROP TABLE retired_pet_records_legacy_reason;
            "#,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn migrate_retired_pet_qualities(
        &self,
        connection: &mut Connection,
        retire_every_existing_pet: bool,
    ) -> Result<()> {
        let legacy_timing_available = table_has_column(connection, "pets", "native_fps")?
            && table_has_column(connection, "pets", "state_durations_json")?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let retired_at = now_rfc3339();
        let retire_every_existing_pet = if retire_every_existing_pet {
            1_i64
        } else {
            0_i64
        };
        let retire_sql = if legacy_timing_available {
            r#"
            INSERT INTO retired_pet_records (
              id, name, style, quality, render_width, render_height,
              states_json, legacy_native_fps, legacy_state_durations_json,
              petpack_path, cover_path, origin, generator, provenance, active,
              created_at, retired_reason, retired_at
            )
            SELECT
              id, name, style, quality, render_width, render_height,
              states_json, native_fps, state_durations_json, petpack_path,
              cover_path, origin, generator, provenance, active, created_at,
              'unsupported_quality', ?1
            FROM pets
            WHERE ?2 != 0
               OR NOT (
                    (quality = 'low' AND render_width = 192 AND render_height = 208)
                 OR (quality = 'standard' AND render_width = 384 AND render_height = 416)
                 OR (quality = 'high' AND render_width = 576 AND render_height = 624)
               )
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              states_json = excluded.states_json,
              legacy_native_fps = COALESCE(
                excluded.legacy_native_fps,
                retired_pet_records.legacy_native_fps
              ),
              legacy_state_durations_json = COALESCE(
                excluded.legacy_state_durations_json,
                retired_pet_records.legacy_state_durations_json
              ),
              petpack_path = excluded.petpack_path,
              cover_path = excluded.cover_path,
              origin = excluded.origin,
              generator = excluded.generator,
              provenance = excluded.provenance,
              active = excluded.active,
              created_at = excluded.created_at,
              retired_reason = excluded.retired_reason,
              retired_at = excluded.retired_at
            "#
        } else {
            r#"
            INSERT INTO retired_pet_records (
              id, name, style, quality, render_width, render_height,
              states_json, legacy_native_fps, legacy_state_durations_json,
              petpack_path, cover_path, origin, generator, provenance, active,
              created_at, retired_reason, retired_at
            )
            SELECT
              id, name, style, quality, render_width, render_height,
              states_json, NULL, NULL, petpack_path, cover_path, origin,
              generator, provenance, active, created_at,
              'unsupported_quality', ?1
            FROM pets
            WHERE ?2 != 0
               OR NOT (
                    (quality = 'low' AND render_width = 192 AND render_height = 208)
                 OR (quality = 'standard' AND render_width = 384 AND render_height = 416)
                 OR (quality = 'high' AND render_width = 576 AND render_height = 624)
               )
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              states_json = excluded.states_json,
              legacy_native_fps = COALESCE(
                excluded.legacy_native_fps,
                retired_pet_records.legacy_native_fps
              ),
              legacy_state_durations_json = COALESCE(
                excluded.legacy_state_durations_json,
                retired_pet_records.legacy_state_durations_json
              ),
              petpack_path = excluded.petpack_path,
              cover_path = excluded.cover_path,
              origin = excluded.origin,
              generator = excluded.generator,
              provenance = excluded.provenance,
              active = excluded.active,
              created_at = excluded.created_at,
              retired_reason = excluded.retired_reason,
              retired_at = excluded.retired_at
            "#
        };
        transaction.execute(retire_sql, params![retired_at, retire_every_existing_pet])?;
        transaction.execute(
            r#"
            DELETE FROM pet_asset_validation
            WHERE pet_id IN (
              SELECT id
              FROM pets
              WHERE ?1 != 0
                 OR NOT (
                      (quality = 'low' AND render_width = 192 AND render_height = 208)
                   OR (quality = 'standard' AND render_width = 384 AND render_height = 416)
                   OR (quality = 'high' AND render_width = 576 AND render_height = 624)
                 )
            )
            "#,
            params![retire_every_existing_pet],
        )?;
        let retired_count = transaction.execute(
            r#"
            DELETE FROM pets
            WHERE ?1 != 0
               OR NOT (
                    (quality = 'low' AND render_width = 192 AND render_height = 208)
                 OR (quality = 'standard' AND render_width = 384 AND render_height = 416)
                 OR (quality = 'high' AND render_width = 576 AND render_height = 624)
               )
            "#,
            params![retire_every_existing_pet],
        )?;
        if retired_count > 0 {
            let active_pet_count: i64 =
                transaction.query_row("SELECT COUNT(*) FROM pets WHERE active = 1", [], |row| {
                    row.get(0)
                })?;
            if active_pet_count == 0 {
                let next_pet_id = transaction
                    .query_row(
                        "SELECT id FROM pets ORDER BY created_at DESC, id ASC LIMIT 1",
                        [],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
                if let Some(next_pet_id) = next_pet_id {
                    transaction.execute(
                        "UPDATE pets SET active = 1 WHERE id = ?1",
                        params![next_pet_id],
                    )?;
                }
            }
        }
        transaction.commit()?;
        Ok(())
    }

    fn migrate_retired_pet_state_contracts(&self, connection: &mut Connection) -> Result<()> {
        let invalid_pet_ids = {
            let mut statement = connection.prepare("SELECT id, states_json FROM pets")?;
            let rows = statement.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            let mut invalid_pet_ids = Vec::new();
            for row in rows {
                let (pet_id, states_json) = row?;
                if decode_pet_states(&states_json).is_err() {
                    invalid_pet_ids.push(pet_id);
                }
            }
            invalid_pet_ids
        };
        if invalid_pet_ids.is_empty() {
            return Ok(());
        }

        let legacy_timing_available = table_has_column(connection, "pets", "native_fps")?
            && table_has_column(connection, "pets", "state_durations_json")?;
        let legacy_timing_projection = if legacy_timing_available {
            "native_fps, state_durations_json"
        } else {
            "NULL, NULL"
        };
        let retire_sql = format!(
            r#"
            INSERT INTO retired_pet_records (
              id, name, style, quality, render_width, render_height,
              states_json, legacy_native_fps, legacy_state_durations_json,
              petpack_path, cover_path, origin, generator, provenance, active,
              created_at, retired_reason, retired_at
            )
            SELECT
              id, name, style, quality, render_width, render_height,
              states_json, {legacy_timing_projection}, petpack_path, cover_path,
              origin, generator, provenance, active, created_at,
              'unsupported_state_contract', ?2
            FROM pets
            WHERE id = ?1
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              states_json = excluded.states_json,
              legacy_native_fps = COALESCE(
                excluded.legacy_native_fps,
                retired_pet_records.legacy_native_fps
              ),
              legacy_state_durations_json = COALESCE(
                excluded.legacy_state_durations_json,
                retired_pet_records.legacy_state_durations_json
              ),
              petpack_path = excluded.petpack_path,
              cover_path = excluded.cover_path,
              origin = excluded.origin,
              generator = excluded.generator,
              provenance = excluded.provenance,
              active = excluded.active,
              created_at = excluded.created_at,
              retired_reason = excluded.retired_reason,
              retired_at = excluded.retired_at
            "#
        );
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let retired_at = now_rfc3339();
        for pet_id in &invalid_pet_ids {
            transaction.execute(&retire_sql, params![pet_id, retired_at])?;
            transaction.execute(
                "DELETE FROM pet_asset_validation WHERE pet_id = ?1",
                params![pet_id],
            )?;
            transaction.execute("DELETE FROM pets WHERE id = ?1", params![pet_id])?;
        }

        let active_pet_count: i64 =
            transaction.query_row("SELECT COUNT(*) FROM pets WHERE active = 1", [], |row| {
                row.get(0)
            })?;
        if active_pet_count == 0 {
            let next_pet_id = transaction
                .query_row(
                    "SELECT id FROM pets ORDER BY created_at DESC, id ASC LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            if let Some(next_pet_id) = next_pet_id {
                transaction.execute(
                    "UPDATE pets SET active = 1 WHERE id = ?1",
                    params![next_pet_id],
                )?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    fn migrate_legacy_overlay_placement(&self, connection: &mut Connection) -> Result<()> {
        let value = connection
            .query_row(
                "SELECT value_json FROM settings WHERE key = ?1",
                params![OVERLAY_PLACEMENT_SETTING_KEY],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(value) = value else { return Ok(()) };
        let current_error = match decode_overlay_placement(&value) {
            Ok(_) => return Ok(()),
            Err(error) => error,
        };

        let parsed = serde_json::from_str::<Value>(&value)?;
        let uses_legacy_scale = parsed
            .as_object()
            .is_some_and(|object| object.contains_key("scale"));
        let migrated = if uses_legacy_scale {
            let legacy = serde_json::from_value::<LegacyOverlayPlacement>(parsed)?;
            if !legacy.x.is_finite()
                || !legacy.y.is_finite()
                || !(0.10..=1.80).contains(&legacy.scale)
                || legacy.display_id.trim().is_empty()
            {
                return Err(PetCoreError::Validation(
                    "legacy overlay placement is outside its closed bounds".to_string(),
                ));
            }

            OverlayPlacement {
                x: legacy.x,
                y: legacy.y,
                display_width_pt: DEFAULT_OVERLAY_DISPLAY_WIDTH_PT,
                display_id: legacy.display_id,
            }
        } else {
            let legacy = serde_json::from_value::<OverlayPlacement>(parsed)?;
            if !(LEGACY_MIN_OVERLAY_DISPLAY_WIDTH_PT..=LEGACY_MAX_OVERLAY_DISPLAY_WIDTH_PT)
                .contains(&legacy.display_width_pt)
            {
                return Err(current_error);
            }
            OverlayPlacement {
                display_width_pt: legacy.display_width_pt.max(MIN_OVERLAY_DISPLAY_WIDTH_PT),
                ..legacy
            }
        };
        let migrated = migrated.canonicalized().map_err(|error| {
            PetCoreError::Validation(format!("legacy overlay placement is invalid: {error}"))
        })?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute(
            r#"
            UPDATE settings
            SET value_json = ?2,
                updated_at = ?3,
                revision = revision + 1
            WHERE key = ?1
            "#,
            params![
                OVERLAY_PLACEMENT_SETTING_KEY,
                serde_json::to_string_pretty(&migrated)?,
                now_rfc3339(),
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn ensure_generation_job_columns(&self, connection: &Connection) -> Result<()> {
        let had_ended_at = table_has_column(connection, "generation_jobs", "ended_at")?;
        let had_recoverable = table_has_column(connection, "generation_jobs", "recoverable")?;
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
        if !table_has_column(connection, "generation_jobs", "started_at")? {
            connection.execute(
                "ALTER TABLE generation_jobs ADD COLUMN started_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
                [],
            )?;
            connection.execute("UPDATE generation_jobs SET started_at = created_at", [])?;
        }
        for (column, declaration) in [
            ("ended_at", "TEXT"),
            ("cancel_requested_at", "TEXT"),
            ("execution_stopped_at", "TEXT"),
            ("thread_archived_at", "TEXT"),
            ("failure_code", "TEXT"),
            ("pause_reason", "TEXT"),
            ("active_turn_id", "TEXT"),
            ("last_checkpoint_at", "TEXT"),
        ] {
            if !table_has_column(connection, "generation_jobs", column)? {
                connection.execute(
                    &format!("ALTER TABLE generation_jobs ADD COLUMN {column} {declaration}"),
                    [],
                )?;
            }
        }
        if !table_has_column(connection, "generation_jobs", "recoverable")? {
            connection.execute(
                "ALTER TABLE generation_jobs ADD COLUMN recoverable INTEGER NOT NULL DEFAULT 0 CHECK(recoverable IN (0, 1))",
                [],
            )?;
        }
        if !table_has_column(connection, "generation_jobs", "visible_title")? {
            connection.execute(
                "ALTER TABLE generation_jobs ADD COLUMN visible_title TEXT NOT NULL DEFAULT ''",
                [],
            )?;
        }
        let missing_titles = {
            let mut statement = connection
                .prepare("SELECT id, form_json FROM generation_jobs WHERE visible_title = ''")?;
            let rows = statement.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        for (job_id, form_json) in missing_titles {
            if let Ok(form) = serde_json::from_str::<GenerationForm>(&form_json) {
                connection.execute(
                    "UPDATE generation_jobs SET visible_title = ?2 WHERE id = ?1",
                    params![job_id, generation_visible_title(&form)],
                )?;
            }
        }
        // Legacy failures were not governed by the single-unfinished-task
        // contract. Keep them terminal during the additive migration; only
        // failures created by the current runtime can become recoverable.
        if !had_ended_at || !had_recoverable {
            connection.execute(
                r#"
                UPDATE generation_jobs
                SET ended_at = updated_at,
                    recoverable = 0
                WHERE status IN ('completed', 'canceled', 'failed')
                  AND ended_at IS NULL
                "#,
                [],
            )?;
        }
        connection.execute("DROP INDEX IF EXISTS generation_single_unfinished_job", [])?;
        connection.execute(
            r#"
            CREATE UNIQUE INDEX IF NOT EXISTS generation_single_unfinished_job
            ON generation_jobs ((1))
            WHERE status IN ('pending', 'running', 'waiting_for_user')
               OR (status = 'failed' AND recoverable = 1)
               OR (cancel_requested_at IS NOT NULL AND thread_archived_at IS NULL)
            "#,
            [],
        )?;
        Ok(())
    }

    fn ensure_generation_message_columns(&self, connection: &Connection) -> Result<()> {
        if !table_has_column(connection, "generation_messages", "payload_json")? {
            connection.execute(
                "ALTER TABLE generation_messages ADD COLUMN payload_json TEXT",
                [],
            )?;
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

    fn migrate_removed_agent_event_data(&self, connection: &mut Connection) -> Result<()> {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute(
            r#"
            DELETE FROM agent_events
            WHERE event_type NOT IN (
              'start', 'thinking', 'plan', 'tool', 'waiting', 'done', 'failed'
            )
            "#,
            [],
        )?;
        transaction.execute(
            r#"
            DELETE FROM agent_event_daily_counts
            WHERE event_type NOT IN (
              'start', 'thinking', 'plan', 'tool', 'waiting', 'done', 'failed'
            )
            "#,
            [],
        )?;
        transaction.execute(
            r#"
            DELETE FROM agent_session_aliases
            WHERE NOT EXISTS (
              SELECT 1
              FROM agent_events
              WHERE agent_events.source = agent_session_aliases.source
                AND agent_events.session_key = agent_session_aliases.session_key
            )
            "#,
            [],
        )?;

        let stored_behavior = transaction
            .query_row(
                "SELECT value_json FROM settings WHERE key = 'behavior'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(stored_behavior) = stored_behavior {
            let stored_value = serde_json::from_str::<Value>(&stored_behavior)?;
            let behavior = serde_json::from_value::<BehaviorSettings>(stored_value.clone())?;
            let normalized_value = serde_json::to_value(&behavior)?;
            if stored_value != normalized_value {
                transaction.execute(
                    r#"
                    UPDATE settings
                    SET value_json = ?1,
                        updated_at = ?2,
                        revision = revision + 1
                    WHERE key = 'behavior'
                    "#,
                    params![serde_json::to_string_pretty(&behavior)?, now_rfc3339()],
                )?;
            }
        }
        transaction.commit()?;
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
                    is_codex_internal_suggestions_payload(&payload).then_some(session_key)
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

    /// Pet Studio threads are intentionally visible only through the Maker
    /// task history. Older builds could still ingest their public Codex hooks
    /// into the ordinary desktop bubble before the generation job recorded its
    /// App Server session ID. Convert every durable Studio identity into an
    /// exact suppression entry and securely scrub any legacy bubble rows.
    fn migrate_internal_pet_studio_sessions(&self, connection: &mut Connection) -> Result<()> {
        let session_keys = {
            let mut statement = connection.prepare(
                r#"
                SELECT DISTINCT session_id
                FROM generation_jobs
                WHERE session_id IS NOT NULL
                "#,
            )?;
            let session_keys = statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
                .into_iter()
                .filter_map(|value| normalized_session_id(Some(&value)))
                .map(|value| normalized_session_key(Some(&value)))
                .collect::<BTreeSet<_>>();
            session_keys
        };

        let transaction = connection.transaction()?;
        let mut removed_legacy_events = false;
        for session_key in &session_keys {
            removed_legacy_events |= transaction
                .query_row(
                    "SELECT 1 FROM agent_events WHERE source = 'codex' AND session_key = ?1 LIMIT 1",
                    params![session_key],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            suppress_agent_session_in_connection(
                &transaction,
                AgentSource::Codex,
                session_key,
                PET_STUDIO_INTERNAL_SESSION_REASON,
            )?;
        }
        prune_suppressed_agent_sessions(&transaction)?;
        if removed_legacy_events {
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
}
