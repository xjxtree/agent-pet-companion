use super::*;

impl Database {
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
        let active_job = transaction
            .query_row(
                r#"
                SELECT id, status
                FROM generation_jobs
                WHERE status IN (?1, ?2, ?3)
                   OR (status = ?4 AND recoverable = 1)
                   OR (cancel_requested_at IS NOT NULL AND thread_archived_at IS NULL)
                ORDER BY updated_at DESC
                LIMIT 1
                "#,
                params![
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
        transaction.execute(
            r#"
            INSERT INTO generation_jobs
              (id, status, form_json, session_id, job_dir, result_pet_id,
               retry_of_job_id, owner_instance_id, heartbeat_at, started_at,
               visible_title, created_at, updated_at)
            VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?8, ?8)
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
                generation_visible_title(form),
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
                ended_at = CASE
                  WHEN ?2 = 'canceled' THEN COALESCE(cancel_requested_at, ended_at, ?4)
                  WHEN ?2 IN ('completed', 'failed') THEN COALESCE(ended_at, ?4)
                  ELSE NULL
                END,
                recoverable = 0,
                failure_code = CASE WHEN ?2 IN ('pending', 'running', 'waiting_for_user') THEN NULL ELSE failure_code END,
                pause_reason = CASE WHEN ?2 IN ('pending', 'running', 'waiting_for_user') THEN NULL ELSE pause_reason END,
                active_turn_id = CASE WHEN ?2 IN ('completed', 'failed', 'canceled') THEN NULL ELSE active_turn_id END,
                owner_instance_id = CASE WHEN ?2 IN ('completed', 'failed', 'canceled') THEN NULL ELSE owner_instance_id END,
                updated_at = ?4
            WHERE id = ?1
            "#,
            params![id, enum_name(status), result_pet_id, now_rfc3339()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn mark_generation_recoverable_failure(
        &self,
        id: &str,
        failure_code: &str,
        pause_reason: &str,
    ) -> Result<()> {
        let now = now_rfc3339();
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        reject_other_active_generation(&transaction, id, GenerationJobStatus::Failed)?;
        let updated = transaction.execute(
            r#"
            UPDATE generation_jobs
            SET status = 'failed',
                recoverable = 1,
                failure_code = ?2,
                pause_reason = ?3,
                ended_at = NULL,
                active_turn_id = NULL,
                owner_instance_id = NULL,
                heartbeat_at = ?4,
                updated_at = ?4
            WHERE id = ?1
              AND cancel_requested_at IS NULL
              AND status NOT IN ('completed', 'canceled')
            "#,
            params![id, failure_code, pause_reason, now],
        )?;
        if updated == 0 {
            return Err(PetCoreError::Conflict(format!(
                "generation job cannot enter recoverable failure: {id}"
            )));
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn request_generation_cancellation(&self, id: &str) -> Result<String> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing = transaction
            .query_row(
                "SELECT cancel_requested_at FROM generation_jobs WHERE id = ?1",
                params![id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?;
        let Some(existing) = existing else {
            return Err(PetCoreError::InvalidRequest(format!(
                "generation job not found: {id}"
            )));
        };
        if let Some(existing) = existing {
            transaction.commit()?;
            return Ok(existing);
        }
        let now = now_rfc3339();
        let updated = transaction.execute(
            r#"
            UPDATE generation_jobs
            SET cancel_requested_at = ?2,
                ended_at = ?2,
                recoverable = 0,
                updated_at = ?2
            WHERE id = ?1
              AND status IN ('pending', 'running', 'waiting_for_user', 'failed')
              AND (status <> 'failed' OR recoverable = 1)
            "#,
            params![id, now],
        )?;
        if updated == 0 {
            return Err(PetCoreError::Conflict(format!(
                "generation job is already terminal and cannot be canceled: {id}"
            )));
        }
        transaction.commit()?;
        Ok(now)
    }

    pub fn confirm_generation_execution_stopped(&self, id: &str) -> Result<()> {
        let now = now_rfc3339();
        let connection = self.open()?;
        let updated = connection.execute(
            r#"
            UPDATE generation_jobs
            SET execution_stopped_at = COALESCE(execution_stopped_at, ?2),
                active_turn_id = NULL,
                owner_instance_id = NULL,
                heartbeat_at = ?2,
                updated_at = ?2
            WHERE id = ?1 AND cancel_requested_at IS NOT NULL
            "#,
            params![id, now],
        )?;
        if updated == 0 {
            return Err(PetCoreError::Conflict(format!(
                "generation cancellation was not requested: {id}"
            )));
        }
        Ok(())
    }

    pub fn confirm_generation_thread_archived(&self, id: &str) -> Result<()> {
        let now = now_rfc3339();
        let connection = self.open()?;
        let updated = connection.execute(
            r#"
            UPDATE generation_jobs
            SET thread_archived_at = COALESCE(thread_archived_at, ?2),
                updated_at = ?2
            WHERE id = ?1 AND execution_stopped_at IS NOT NULL
            "#,
            params![id, now],
        )?;
        if updated == 0 {
            return Err(PetCoreError::Conflict(format!(
                "generation execution has not stopped: {id}"
            )));
        }
        Ok(())
    }

    pub fn update_generation_active_turn(&self, id: &str, turn_id: Option<&str>) -> Result<()> {
        let connection = self.open()?;
        connection.execute(
            "UPDATE generation_jobs SET active_turn_id = ?2, updated_at = ?3 WHERE id = ?1 AND cancel_requested_at IS NULL",
            params![id, turn_id, now_rfc3339()],
        )?;
        Ok(())
    }

    pub fn checkpoint_generation_job(&self, id: &str) -> Result<()> {
        let now = now_rfc3339();
        let connection = self.open()?;
        connection.execute(
            r#"
            UPDATE generation_jobs
            SET last_checkpoint_at = ?2,
                heartbeat_at = ?2,
                updated_at = ?2
            WHERE id = ?1 AND cancel_requested_at IS NULL
            "#,
            params![id, now],
        )?;
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

    pub fn touch_generation_job(&self, id: &str) -> Result<()> {
        let now = now_rfc3339();
        let connection = self.open()?;
        connection.execute(
            r#"
            UPDATE generation_jobs
            SET heartbeat_at = ?2,
                updated_at = ?2
            WHERE id = ?1
              AND status IN ('pending', 'running', 'waiting_for_user')
            "#,
            params![id, now],
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
            WHERE status IN (?1, ?2)
              AND cancel_requested_at IS NULL
            ORDER BY updated_at ASC
            "#,
        )?;
        let rows = statement.query_map(
            params![
                enum_name(GenerationJobStatus::Pending),
                enum_name(GenerationJobStatus::Running),
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
        self.generation_jobs_matching_unfinished(false)
    }

    pub fn active_generation_job(&self) -> Result<Option<GenerationJobRecord>> {
        let mut jobs = self.generation_jobs_matching_unfinished(true)?;
        Ok(jobs.pop())
    }

    fn generation_jobs_matching_unfinished(
        &self,
        include_stable_waiting_and_failures: bool,
    ) -> Result<Vec<GenerationJobRecord>> {
        let connection = self.open()?;
        let predicate = if include_stable_waiting_and_failures {
            r#"
            status IN ('pending', 'running', 'waiting_for_user')
            OR (status = 'failed' AND recoverable = 1)
            OR (cancel_requested_at IS NOT NULL AND thread_archived_at IS NULL)
            "#
        } else {
            r#"
            status IN ('pending', 'running')
            AND cancel_requested_at IS NULL
            "#
        };
        let mut statement = connection.prepare(&format!(
            r#"
            SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                   retry_of_job_id, owner_instance_id, heartbeat_at, started_at, ended_at,
                   cancel_requested_at, execution_stopped_at, thread_archived_at, recoverable,
                   failure_code, pause_reason, active_turn_id, last_checkpoint_at, visible_title,
                   created_at, updated_at
            FROM generation_jobs
            WHERE {predicate}
            ORDER BY updated_at ASC, id ASC
            "#
        ))?;
        let rows = statement.query_map([], generation_job_from_row)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn generation_job_for_pet(&self, pet_id: &str) -> Result<Option<GenerationJobRecord>> {
        let connection = self.open()?;
        connection
            .query_row(
                r#"
                SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                       retry_of_job_id, owner_instance_id, heartbeat_at, started_at, ended_at,
                       cancel_requested_at, execution_stopped_at, thread_archived_at, recoverable,
                       failure_code, pause_reason, active_turn_id, last_checkpoint_at, visible_title,
                       created_at, updated_at
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
                       retry_of_job_id, owner_instance_id, heartbeat_at, started_at, ended_at,
                       cancel_requested_at, execution_stopped_at, thread_archived_at, recoverable,
                       failure_code, pause_reason, active_turn_id, last_checkpoint_at, visible_title,
                       created_at, updated_at
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
                   retry_of_job_id, owner_instance_id, heartbeat_at, started_at, ended_at,
                   cancel_requested_at, execution_stopped_at, thread_archived_at, recoverable,
                   failure_code, pause_reason, active_turn_id, last_checkpoint_at, visible_title,
                   created_at, updated_at
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

    /// Returns the unique unfinished Maker job first, followed by terminal
    /// jobs newest-first. Failed and canceled create jobs deliberately remain
    /// present even without a result pet, which makes this distinct from the
    /// Pet Library history query.
    pub fn generation_jobs(&self, limit: usize) -> Result<Vec<GenerationJobRecord>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let limit = limit.min(MAX_GENERATION_HISTORY_QUERY_LIMIT);
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, status, form_json, session_id, job_dir, result_pet_id,
                   retry_of_job_id, owner_instance_id, heartbeat_at, started_at, ended_at,
                   cancel_requested_at, execution_stopped_at, thread_archived_at, recoverable,
                   failure_code, pause_reason, active_turn_id, last_checkpoint_at, visible_title,
                   created_at, updated_at
            FROM generation_jobs
            ORDER BY CASE
                       WHEN status IN ('pending', 'running', 'waiting_for_user') THEN 0
                       WHEN status = 'failed' AND recoverable = 1 THEN 0
                       WHEN cancel_requested_at IS NOT NULL AND thread_archived_at IS NULL THEN 0
                       ELSE 1
                     END ASC,
                     updated_at DESC,
                     id DESC
            LIMIT ?1
            "#,
        )?;
        let rows = statement.query_map(
            params![i64::try_from(limit).unwrap_or(i64::MAX)],
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
                       retry_of_job_id, owner_instance_id, heartbeat_at, started_at, ended_at,
                       cancel_requested_at, execution_stopped_at, thread_archived_at, recoverable,
                       failure_code, pause_reason, active_turn_id, last_checkpoint_at, visible_title,
                       created_at, updated_at
                FROM generation_jobs
                WHERE id = ?1
                "#,
                params![job_id],
                generation_job_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    /// Irreversibly removes one terminal Maker task and its cascading message
    /// rows while preserving any published Pet Library result. Direct retries
    /// are relinked to the deleted task's retained predecessor (or detached
    /// when no predecessor remains), so retry history never points at a
    /// missing task. The terminal check and lineage rewrite share the same
    /// immediate transaction as the delete.
    pub fn delete_generation_history_job(
        &self,
        job_id: &str,
    ) -> Result<DeletedGenerationHistoryJob> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let row = transaction
            .query_row(
                r#"
                SELECT status, result_pet_id, retry_of_job_id
                FROM generation_jobs
                WHERE id = ?1
                "#,
                params![job_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((status, result_pet_id, retry_of_job_id)) = row else {
            return Err(PetCoreError::InvalidRequest(format!(
                "generation job not found: {job_id}"
            )));
        };
        let status = enum_from_name::<GenerationJobStatus>(&status)?;
        if !matches!(
            status,
            GenerationJobStatus::Completed
                | GenerationJobStatus::Failed
                | GenerationJobStatus::Canceled
        ) {
            return Err(PetCoreError::Conflict(format!(
                "generation job {job_id} cannot be deleted while status is {}",
                enum_name(status)
            )));
        }

        let deleted_message_count = transaction.query_row(
            "SELECT COUNT(*) FROM generation_messages WHERE job_id = ?1",
            params![job_id],
            |row| row.get::<_, i64>(0),
        )?;
        let retained_predecessor = retry_of_job_id
            .as_deref()
            .filter(|predecessor| *predecessor != job_id)
            .map(|predecessor| {
                transaction
                    .query_row(
                        "SELECT 1 FROM generation_jobs WHERE id = ?1",
                        params![predecessor],
                        |_| Ok(()),
                    )
                    .optional()
                    .map(|found| found.map(|()| predecessor))
            })
            .transpose()?
            .flatten();
        let retry_children_relinked = transaction.execute(
            r#"
            UPDATE generation_jobs
            SET retry_of_job_id = CASE WHEN id = ?2 THEN NULL ELSE ?2 END
            WHERE retry_of_job_id = ?1
              AND id <> ?1
            "#,
            params![job_id, retained_predecessor],
        )?;
        let deleted =
            transaction.execute("DELETE FROM generation_jobs WHERE id = ?1", params![job_id])?;
        if deleted != 1 {
            return Err(PetCoreError::Conflict(format!(
                "generation job changed while deleting history: {job_id}"
            )));
        }
        let state_revision = state_revision_in_connection(&transaction)?;
        transaction.commit()?;

        Ok(DeletedGenerationHistoryJob {
            status,
            result_pet_id,
            deleted_message_count: usize::try_from(deleted_message_count).map_err(|_| {
                PetCoreError::Validation(
                    "generation message count must be a non-negative integer".to_string(),
                )
            })?,
            retry_children_relinked,
            state_revision,
        })
    }

    pub fn generation_messages(&self, job_id: &str) -> Result<Vec<GenerationMessageRecord>> {
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, job_id, sequence, role, kind, content, progress, created_at, payload_json, diagnostic_json
            FROM generation_messages
            WHERE job_id = ?1
            ORDER BY sequence ASC
            "#,
        )?;
        let rows = statement.query_map(params![job_id], generation_message_from_row)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Returns one chronological page immediately before `before_sequence`.
    /// The database query is newest-first so it can use the job/sequence
    /// index, then the bounded result is reversed for conversation rendering.
    pub fn generation_messages_page(
        &self,
        job_id: &str,
        before_sequence: Option<u64>,
        limit: usize,
    ) -> Result<(Vec<GenerationMessageRecord>, bool)> {
        let limit = limit.clamp(1, MAX_GENERATION_MESSAGE_PAGE_LIMIT);
        let fetch_limit = limit.saturating_add(1);
        let before_sequence = before_sequence
            .map(|value| i64::try_from(value).unwrap_or(i64::MAX))
            .unwrap_or(i64::MAX);
        let connection = self.open()?;
        let mut statement = connection.prepare(
            r#"
            SELECT id, job_id, sequence, role, kind, content, progress, created_at, payload_json, diagnostic_json
            FROM generation_messages
            WHERE job_id = ?1
              AND sequence < ?2
              AND (kind IS NULL OR kind NOT IN ('generation_heartbeat', 'jsonl_diagnostic'))
            ORDER BY sequence DESC
            LIMIT ?3
            "#,
        )?;
        let rows = statement.query_map(
            params![
                job_id,
                before_sequence,
                i64::try_from(fetch_limit).unwrap_or(i64::MAX)
            ],
            generation_message_from_row,
        )?;
        let mut messages = rows
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(PetCoreError::from)?;
        let has_more = messages.len() > limit;
        messages.truncate(limit);
        messages.reverse();
        Ok((messages, has_more))
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

    /// Claims one client-generated action identity. Repeating the exact
    /// action is a no-op; reusing an identity for different content fails
    /// closed so transport retries cannot create duplicate turns.
    pub fn begin_generation_action_request(
        &self,
        job_id: &str,
        request_id: &str,
        action: &str,
        content: &str,
    ) -> Result<bool> {
        if request_id.trim().is_empty() || request_id.len() > 128 {
            return Err(PetCoreError::InvalidRequest(
                "generation action request_id must be 1-128 bytes".to_string(),
            ));
        }
        if !matches!(action, "reply" | "resume") {
            return Err(PetCoreError::InvalidRequest(
                "generation action type is unsupported".to_string(),
            ));
        }
        let content_sha256 = hex::encode(Sha256::digest(content.as_bytes()));
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let inserted = transaction.execute(
            r#"
            INSERT OR IGNORE INTO generation_action_requests
              (job_id, request_id, action, content_sha256, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![job_id, request_id, action, content_sha256, now_rfc3339()],
        )?;
        if inserted == 0 {
            let existing = transaction.query_row(
                r#"
                SELECT action, content_sha256
                FROM generation_action_requests
                WHERE job_id = ?1 AND request_id = ?2
                "#,
                params![job_id, request_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )?;
            if existing != (action.to_string(), content_sha256) {
                return Err(PetCoreError::Conflict(
                    "generation action request_id was reused with different content".to_string(),
                ));
            }
            transaction.commit()?;
            return Ok(false);
        }
        transaction.commit()?;
        Ok(true)
    }

    pub fn generation_action_request_matches(
        &self,
        job_id: &str,
        request_id: &str,
        action: &str,
        content: &str,
    ) -> Result<bool> {
        let connection = self.open()?;
        let existing = connection
            .query_row(
                r#"
                SELECT action, content_sha256
                FROM generation_action_requests
                WHERE job_id = ?1 AND request_id = ?2
                "#,
                params![job_id, request_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        let Some((existing_action, existing_sha256)) = existing else {
            return Ok(false);
        };
        let content_sha256 = hex::encode(Sha256::digest(content.as_bytes()));
        if existing_action != action || existing_sha256 != content_sha256 {
            return Err(PetCoreError::Conflict(
                "generation action request_id was reused with different content".to_string(),
            ));
        }
        Ok(true)
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
            None,
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
        self.append_generation_message_with_payload(
            job_id,
            role,
            kind,
            content,
            progress,
            None,
            status_transition,
            result_pet_id,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn append_generation_message_with_payload(
        &self,
        job_id: &str,
        role: &str,
        kind: Option<&str>,
        content: &str,
        progress: f64,
        payload: Option<&GenerationMessagePayload>,
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
            payload,
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
        payload: Option<&GenerationMessagePayload>,
        diagnostic: Option<&serde_json::Value>,
        status_transition: Option<GenerationJobStatus>,
        result_pet_id: Option<&str>,
    ) -> Result<Option<GenerationMessageRecord>> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let job_state = transaction
            .query_row(
                "SELECT status, cancel_requested_at, execution_stopped_at, thread_archived_at FROM generation_jobs WHERE id = ?1",
                params![job_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((job_status, cancel_requested_at, execution_stopped_at, thread_archived_at)) =
            job_state
        else {
            return Err(PetCoreError::InvalidRequest(format!(
                "generation job not found: {job_id}"
            )));
        };
        let job_status: GenerationJobStatus = enum_from_name(&job_status)?;
        if explicit_id.is_none() && cancel_requested_at.is_some() {
            let is_final_cancellation = kind == Some("generation_canceled")
                && execution_stopped_at.is_some()
                && thread_archived_at.is_some();
            if !is_final_cancellation {
                return Err(PetCoreError::Conflict(format!(
                    "generation job is fenced by cancellation: {job_id}"
                )));
            }
        }
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
                    SELECT id, job_id, sequence, role, kind, content, progress, created_at, payload_json, diagnostic_json
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
              (id, job_id, sequence, role, kind, content, progress, created_at, payload_json, diagnostic_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
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
                payload.map(serde_json::to_string).transpose()?,
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
                    ended_at = CASE
                      WHEN ?2 = 'canceled' THEN COALESCE(cancel_requested_at, ended_at, ?4)
                      WHEN ?2 IN ('completed', 'failed') THEN COALESCE(ended_at, ?4)
                      ELSE NULL
                    END,
                    recoverable = 0,
                    active_turn_id = CASE WHEN ?2 IN ('completed', 'failed', 'canceled') THEN NULL ELSE active_turn_id END,
                    owner_instance_id = CASE WHEN ?2 IN ('completed', 'failed', 'canceled') THEN NULL ELSE owner_instance_id END,
                    updated_at = ?4
                WHERE id = ?1
                "#,
                params![job_id, enum_name(status), result_pet_id, now],
            )?;
        } else {
            let now = now_rfc3339();
            transaction.execute(
                r#"
                UPDATE generation_jobs
                SET heartbeat_at = ?2,
                    updated_at = ?2
                WHERE id = ?1
                "#,
                params![job_id, now],
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
            payload: payload.cloned(),
            diagnostic: diagnostic.cloned(),
        }))
    }
}
