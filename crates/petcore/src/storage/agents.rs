use super::*;

fn claude_session_has_open_background_work(
    connection: &Connection,
    session_key: &str,
) -> Result<bool> {
    let latest_boundary = connection
        .query_row(
            r#"
            SELECT CASE
                     WHEN event_type = 'start'
                      AND json_extract(payload_json, '$.source_event') = 'Stop'
                      AND json_extract(payload_json, '$.outcome') = 'background_active'
                     THEN 'background'
                     ELSE 'settled'
                   END
            FROM agent_events
            WHERE source = 'claude_code'
              AND session_key = ?1
              AND COALESCE(json_extract(payload_json, '$.diagnostic'), 0) != 1
              AND (
                (
                  event_type = 'start'
                  AND json_extract(payload_json, '$.source_event') = 'Stop'
                  AND json_extract(payload_json, '$.outcome') = 'background_active'
                )
                OR json_extract(payload_json, '$.source_event') = 'SessionStart'
                OR (
                  event_type = 'done'
                  AND json_extract(payload_json, '$.source_event') IN ('Stop', 'SessionEnd')
                )
                OR (
                  event_type = 'done'
                  AND json_extract(payload_json, '$.source_event') = 'Notification'
                  AND json_extract(payload_json, '$.outcome') = 'agent_completed'
                )
                OR (
                  event_type = 'failed'
                  AND json_extract(payload_json, '$.source_event') = 'StopFailure'
                )
              )
            ORDER BY created_at DESC, row_id DESC
            LIMIT 1
            "#,
            params![session_key],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(latest_boundary.as_deref() == Some("background"))
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
    let mut claude_background_work_is_open = None;

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
        let source_event = payload.get("source_event").and_then(Value::as_str);
        let outcome = payload.get("outcome").and_then(Value::as_str);
        let is_claude_idle_notification = event.source == AgentSource::ClaudeCode
            && source_event == Some("Notification")
            && outcome == Some("idle");
        let ignore_terminal = matches!(
            source_event,
            Some("app_server_activity" | "connection.test")
        ) || (is_claude_idle_notification
            && *claude_background_work_is_open.get_or_insert(
                claude_session_has_open_background_work(connection, session_key)?,
            ));
        if ignore_terminal {
            // Only an open Claude background fence makes the delayed idle
            // notification non-terminal. Ordinary idle keeps its existing
            // same-turn fence.
            continue;
        }
        if payload.get("turn_id").and_then(Value::as_str) == Some(turn_id) {
            return Ok(true);
        }
    }
    Ok(false)
}

impl Database {
    pub fn state_revision(&self) -> Result<u64> {
        let connection = self.open()?;
        state_revision_in_connection(&connection)
    }

    /// Opens a connection a caller can hold across repeated reads.
    ///
    /// Every other accessor opens and closes its own connection, which is the
    /// right default for one-shot RPCs but wasteful for a loop that re-reads
    /// the same row many times. The database runs in WAL mode and these reads
    /// take no explicit transaction, so a held connection never blocks writers.
    pub(crate) fn open_reusable_read_connection(&self) -> Result<Connection> {
        self.open()
    }

    /// Reads the state revision through a caller-owned connection.
    pub(crate) fn state_revision_using(&self, connection: &Connection) -> Result<u64> {
        state_revision_in_connection(connection)
    }

    pub(super) fn read_projection_at_revision<T, F>(
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
        if event.source == AgentSource::Codex
            && session_id
                .as_deref()
                .map(|session_id| generation_job_owns_session(&transaction, session_id))
                .transpose()?
                .unwrap_or(false)
        {
            suppress_agent_session_in_connection(
                &transaction,
                event.source,
                &session_key,
                PET_STUDIO_INTERNAL_SESSION_REASON,
            )?;
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
        if let (Some(reason), Some(_)) = (
            suppressed_agent_session_reason(event),
            session_id.as_deref(),
        ) {
            suppress_agent_session_in_connection(&transaction, event.source, &session_key, reason)?;
            prune_suppressed_agent_sessions(&transaction)?;
            transaction.commit()?;
            return Ok(false);
        }
        if event.source == AgentSource::Codex
            && session_id
                .as_deref()
                .map(|session_id| generation_job_owns_session(&transaction, session_id))
                .transpose()?
                .unwrap_or(false)
        {
            suppress_agent_session_in_connection(
                &transaction,
                event.source,
                &session_key,
                PET_STUDIO_INTERNAL_SESSION_REASON,
            )?;
            prune_suppressed_agent_sessions(&transaction)?;
            transaction.commit()?;
            return Ok(false);
        }
        if agent_session_is_suppressed(&transaction, event.source, &session_key)? {
            transaction.commit()?;
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

    /// Repairs only the synthetic App Server closure written when an observed
    /// Codex task disappeared from an unarchived listing. A later successful
    /// listing that contains the same task is stronger lifecycle evidence: the
    /// task remains a valid destination even when it is too old for bounded
    /// message hydration. The list's own typed source supplies the minimum
    /// navigation surface without reading a transcript.
    pub(crate) fn reconcile_listed_codex_activity_sessions(
        &self,
        listed_threads: &BTreeMap<String, String>,
    ) -> Result<usize> {
        if listed_threads.len() > MAX_CODEX_LIST_RECONCILIATION_SESSIONS {
            return Err(PetCoreError::InvalidRequest(format!(
                "Codex activity reconciliation accepts at most {MAX_CODEX_LIST_RECONCILIATION_SESSIONS} tasks"
            )));
        }
        if listed_threads.is_empty() {
            return Ok(0);
        }

        let mut sessions = Vec::with_capacity(listed_threads.len());
        for (thread_id, surface) in listed_threads {
            let canonical = uuid::Uuid::parse_str(thread_id)
                .map(|value| value.hyphenated().to_string())
                .map_err(|_| {
                    PetCoreError::InvalidRequest(
                        "Codex activity reconciliation requires canonical task IDs".to_string(),
                    )
                })?;
            if !canonical.eq_ignore_ascii_case(thread_id) {
                return Err(PetCoreError::InvalidRequest(
                    "Codex activity reconciliation requires canonical task IDs".to_string(),
                ));
            }
            if !matches!(surface.as_str(), "chatgpt_app" | "cli_terminal" | "unknown") {
                return Err(PetCoreError::InvalidRequest(
                    "Codex activity reconciliation requires a validated task surface".to_string(),
                ));
            }
            sessions.push((normalized_session_key(Some(thread_id)), surface));
        }

        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut repaired = 0;
        for (session_key, surface) in sessions {
            repaired += transaction.execute(
                r#"
                UPDATE agent_events
                SET payload_json = json_set(
                  json_remove(payload_json, '$.outcome'),
                  '$.session_open', json('true'),
                  '$.session_surface', ?3
                )
                WHERE source = ?1
                  AND session_key = ?2
                  AND external_event_id GLOB 'evt_codex_app_server_status_*'
                  AND json_extract(payload_json, '$.source_event') = 'app_server_activity'
                  AND json_extract(payload_json, '$.outcome') = 'session_closed'
                  AND json_extract(payload_json, '$.session_active') = 0
                  AND json_extract(payload_json, '$.session_open') = 0
                "#,
                params![enum_name(AgentSource::Codex), session_key, surface],
            )?;
        }
        transaction.commit()?;
        Ok(repaired)
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
            let Ok(payload) = serde_json::from_str::<ConnectorEvidencePayload>(&payload_json)
            else {
                continue;
            };
            let diagnostic = payload
                .diagnostic
                .as_ref()
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let Some(raw_source_event) = payload.source_event.as_ref().and_then(Value::as_str)
            else {
                continue;
            };
            let source_event = raw_source_event.trim();
            if source_event.is_empty() {
                continue;
            }
            let contract_version = payload
                .contract_version
                .as_ref()
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
                    .affects_activity
                    .as_ref()
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
            let Ok(payload) = serde_json::from_str::<ConnectorEvidencePayload>(&payload_json)
            else {
                continue;
            };
            if payload
                .diagnostic
                .as_ref()
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || payload.contract_version.as_ref().and_then(Value::as_str)
                    != Some(expected_contract_version)
            {
                continue;
            }
            let Some(source_event) = payload
                .source_event
                .as_ref()
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            let affects_activity = payload
                .affects_activity
                .as_ref()
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
            let Ok(payload) = serde_json::from_str::<ConnectorEvidencePayload>(&payload_json)
            else {
                continue;
            };
            if payload
                .diagnostic
                .as_ref()
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || payload.contract_version.as_ref().and_then(Value::as_str)
                    != Some(expected_contract_version)
            {
                continue;
            }
            let Some(source_event) = payload.source_event.as_ref().and_then(Value::as_str) else {
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

    /// Reads the durable hook history needed to resolve the current Codex
    /// runtime host. App Server activity rows are deliberately excluded: they
    /// describe a persisted thread, not the process that is currently running
    /// its turn. The caller is capped at the same eight threads returned by the
    /// bounded App Server activity poll.
    pub(crate) fn codex_runtime_surface_history(
        &self,
        sessions: &[(String, Option<String>)],
    ) -> Result<BTreeMap<String, CodexRuntimeSurfaceHistory>> {
        const MAX_CODEX_RUNTIME_SURFACE_SESSIONS: usize = 8;
        let requested_turns = sessions.iter().cloned().collect::<BTreeMap<_, _>>();
        if requested_turns.len() > MAX_CODEX_RUNTIME_SURFACE_SESSIONS {
            return Err(PetCoreError::InvalidRequest(format!(
                "Codex runtime surface history accepts at most {MAX_CODEX_RUNTIME_SURFACE_SESSIONS} sessions"
            )));
        }
        let mut histories = requested_turns
            .keys()
            .map(|session_id| (session_id.clone(), CodexRuntimeSurfaceHistory::default()))
            .collect::<BTreeMap<_, _>>();
        if histories.is_empty() {
            return Ok(histories);
        }

        let requested = requested_turns
            .iter()
            .map(|(session_id, turn_id)| {
                (
                    session_id.clone(),
                    normalized_session_key(normalized_session_id(Some(session_id)).as_deref()),
                    turn_id.clone(),
                )
            })
            .collect::<Vec<_>>();
        let placeholders = (0..requested.len())
            .map(|index| {
                let first = index * 3 + 1;
                format!("(?{first}, ?{}, ?{})", first + 1, first + 2)
            })
            .collect::<Vec<_>>()
            .join(", ");
        let query = format!(
            r#"
            WITH requested(session_id, session_key, turn_id) AS (
              VALUES {placeholders}
            ),
            trusted AS (
              SELECT requested.session_id AS requested_session_id,
                     requested.turn_id AS requested_turn_id,
                     events.row_id
              FROM requested
              JOIN agent_events AS events
                ON events.source = 'codex'
               AND events.session_key = requested.session_key
              WHERE json_type(events.payload_json, '$.diagnostic') = 'false'
                AND json_type(events.payload_json, '$.contract_version') = 'text'
                AND json_extract(events.payload_json, '$.contract_version') = '{CODEX_HOOKS_CONTRACT_VERSION}'
                AND json_extract(events.payload_json, '$.source_event') IN (
                  'SessionStart',
                  'UserPromptSubmit',
                  'PreToolUse',
                  'PermissionRequest',
                  'PostToolUse',
                  'PreCompact',
                  'PostCompact',
                  'SubagentStart',
                  'SubagentStop',
                  'Stop'
                )
                AND (
                  json_type(events.payload_json, '$.turn_id') IS NULL
                  OR json_type(events.payload_json, '$.turn_id') = 'null'
                  OR (
                    json_type(events.payload_json, '$.turn_id') = 'text'
                    AND length(json_extract(events.payload_json, '$.turn_id')) BETWEEN 1 AND 256
                    AND trim(json_extract(events.payload_json, '$.turn_id')) = json_extract(events.payload_json, '$.turn_id')
                  )
                )
                AND (
                  (
                    json_extract(events.payload_json, '$.session_surface') = 'chatgpt_app'
                    AND (
                      json_type(events.payload_json, '$.terminal_app') IS NULL
                      OR json_type(events.payload_json, '$.terminal_app') = 'null'
                    )
                    AND (
                      json_type(events.payload_json, '$.session_open_url') IS NULL
                      OR json_type(events.payload_json, '$.session_open_url') = 'null'
                    )
                  )
                  OR (
                    json_extract(events.payload_json, '$.session_surface') = 'cli_terminal'
                    AND (
                      json_type(events.payload_json, '$.terminal_app') IS NULL
                      OR json_type(events.payload_json, '$.terminal_app') = 'null'
                      OR json_extract(events.payload_json, '$.terminal_app') IN ('warp', 'terminal', 'iterm2', 'ghostty')
                    )
                    AND (
                      json_type(events.payload_json, '$.session_open_url') IS NULL
                      OR json_type(events.payload_json, '$.session_open_url') = 'null'
                      OR (
                        json_extract(events.payload_json, '$.terminal_app') = 'warp'
                        AND (
                          (
                            length(json_extract(events.payload_json, '$.session_open_url')) = 47
                            AND substr(json_extract(events.payload_json, '$.session_open_url'), 1, 15) = 'warp://session/'
                            AND substr(json_extract(events.payload_json, '$.session_open_url'), 16) NOT GLOB '*[^0-9A-Fa-f]*'
                          )
                          OR (
                            length(json_extract(events.payload_json, '$.session_open_url')) = 54
                            AND substr(json_extract(events.payload_json, '$.session_open_url'), 1, 22) = 'warppreview://session/'
                            AND substr(json_extract(events.payload_json, '$.session_open_url'), 23) NOT GLOB '*[^0-9A-Fa-f]*'
                          )
                        )
                      )
                    )
                  )
                )
            ),
            summary AS (
              SELECT requested_session_id,
                     1 AS has_any_trusted_marker,
                     MAX(CASE
                       WHEN requested_turn_id IS NOT NULL
                        AND json_extract(events.payload_json, '$.turn_id') = requested_turn_id
                       THEN trusted.row_id
                     END) AS latest_current_turn_row_id
              FROM trusted
              JOIN agent_events AS events ON events.row_id = trusted.row_id
              GROUP BY requested_session_id
            )
            SELECT requested.session_id,
                   COALESCE(summary.has_any_trusted_marker, 0),
                   current.row_id, current.external_event_id, current.source,
                   current.project_path, current.session_id, current.event_type,
                   current.title, current.detail, current.payload_json, current.created_at
            FROM requested
            LEFT JOIN summary ON summary.requested_session_id = requested.session_id
            LEFT JOIN agent_events AS current
              ON current.row_id = summary.latest_current_turn_row_id
            "#
        );
        let parameters = requested
            .iter()
            .flat_map(|(session_id, session_key, turn_id)| {
                [
                    rusqlite::types::Value::Text(session_id.clone()),
                    rusqlite::types::Value::Text(session_key.clone()),
                    turn_id
                        .as_ref()
                        .map_or(rusqlite::types::Value::Null, |turn_id| {
                            rusqlite::types::Value::Text(turn_id.clone())
                        }),
                ]
            })
            .collect::<Vec<_>>();
        let connection = self.open()?;
        let mut statement = connection.prepare(&query)?;
        let rows = statement.query_map(rusqlite::params_from_iter(parameters.iter()), |row| {
            let session_id = row.get::<_, String>(0)?;
            let has_any_trusted_marker = row.get::<_, bool>(1)?;
            let marker = row
                .get::<_, Option<i64>>(2)?
                .map(|_| sequenced_session_event_from_row_at(row, 2))
                .transpose()?;
            Ok((session_id, has_any_trusted_marker, marker))
        })?;
        for row in rows {
            let (session_id, has_any_trusted_marker, marker) = row?;
            let Some(history) = histories.get_mut(&session_id) else {
                continue;
            };
            history.has_any_trusted_marker = has_any_trusted_marker;
            history.latest_current_turn_marker =
                marker.filter(|marker| trusted_codex_runtime_surface_marker(&marker.event));
        }
        Ok(histories)
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
                completion_epoch_event_ids: Vec::new(),
                preferred_app_navigation_payload: None,
                tool_activity_run_marker: None,
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
            WITH claude_ordered AS (
              SELECT row_id, session_key, event_type, payload_json,
                     CASE
                       WHEN event_type = 'start'
                        AND json_extract(payload_json, '$.source_event') = 'Stop'
                        AND json_extract(payload_json, '$.outcome') = 'background_active'
                       THEN 'background'
                       WHEN json_extract(payload_json, '$.source_event') = 'SessionStart'
                         OR (
                           event_type = 'done'
                           AND json_extract(payload_json, '$.source_event') IN ('Stop', 'SessionEnd')
                         )
                         OR (
                           event_type = 'done'
                           AND json_extract(payload_json, '$.source_event') = 'Notification'
                           AND json_extract(payload_json, '$.outcome') = 'agent_completed'
                         )
                         OR (
                           event_type = 'failed'
                           AND json_extract(payload_json, '$.source_event') = 'StopFailure'
                         )
                       THEN 'settled'
                     END AS background_boundary,
                     ROW_NUMBER() OVER (
                       PARTITION BY session_key
                       ORDER BY created_at ASC, row_id ASC
                     ) AS session_sequence
              FROM agent_events
              WHERE source = 'claude_code'
                AND COALESCE(json_extract(payload_json, '$.diagnostic'), 0) != 1
            ),
            claude_background_state AS (
              SELECT row_id, event_type, payload_json,
                     MAX(CASE WHEN background_boundary = 'background'
                       THEN session_sequence END) OVER (
                         PARTITION BY session_key
                         ORDER BY session_sequence ASC
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS latest_background_sequence,
                     MAX(CASE WHEN background_boundary = 'settled'
                       THEN session_sequence END) OVER (
                         PARTITION BY session_key
                         ORDER BY session_sequence ASC
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS latest_settled_sequence
              FROM claude_ordered
            ),
            claude_background_fenced_idle AS (
              SELECT row_id
              FROM claude_background_state
              WHERE event_type = 'done'
                AND json_extract(payload_json, '$.source_event') = 'Notification'
                AND json_extract(payload_json, '$.outcome') = 'idle'
                AND latest_background_sequence > COALESCE(latest_settled_sequence, 0)
            ),
            eligible AS (
              SELECT row_id, external_event_id, source, project_path, session_id,
                     session_key, event_type, title, detail, payload_json, created_at
              FROM agent_events
              WHERE COALESCE(json_extract(payload_json, '$.diagnostic'), 0) != 1
                -- Claude emits idle_prompt on the main prompt's idle timer even
                -- while background agents are still running. Keep that bounded
                -- audit row, but do not let it close the projected session until
                -- a stronger lifecycle edge settles or resets the background work.
                AND row_id NOT IN (SELECT row_id FROM claude_background_fenced_idle)
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
            tool_activity AS (
              SELECT row_id, source, session_key, event_type, created_at,
                     json_extract(payload_json, '$.activity_kind') AS activity_kind,
                     LAG(event_type) OVER (
                       PARTITION BY source, session_key
                       ORDER BY created_at ASC, row_id ASC
                     ) AS previous_event_type
              FROM eligible
            ),
            labelled_tool_activity AS (
              SELECT row_id, activity_kind,
                     LAG(activity_kind) OVER (
                       PARTITION BY source, session_key
                       ORDER BY created_at ASC, row_id ASC
                     ) AS previous_activity_kind
              FROM tool_activity
              WHERE event_type = 'tool' AND activity_kind IS NOT NULL
            ),
            tool_runs AS (
              SELECT activity.row_id,
                     SUM(CASE
                       WHEN activity.event_type != 'tool' THEN 0
                       -- The first tool event after any interruption opens a
                       -- run, and so does a tool event that reports a different
                       -- closed activity subtype than the one before it. Tool
                       -- events published without a subtype (the tool-after
                       -- edge of a call) continue the run they arrive in.
                       WHEN activity.previous_event_type IS NOT 'tool' THEN 1
                       WHEN labelled.activity_kind IS NOT NULL
                        AND labelled.previous_activity_kind
                              IS NOT labelled.activity_kind THEN 1
                       ELSE 0
                     END) OVER (
                       PARTITION BY activity.source, activity.session_key
                       ORDER BY activity.created_at ASC, activity.row_id ASC
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                     ) AS tool_run_ordinal
              FROM tool_activity AS activity
              LEFT JOIN labelled_tool_activity AS labelled
                ON labelled.row_id = activity.row_id
            ),
            ranked AS (
              SELECT row_id, external_event_id, source, project_path, session_id,
                     session_key, event_type, title, detail, payload_json, created_at,
                     session_activated_at, session_first_seen_at, activity_epoch,
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
                   aliases.alias_sequence,
                   -- Identity of the tool activity run the selected event
                   -- belongs to. The ordinal advances once per run inside its
                   -- session, so continued traffic for the same activity keeps
                   -- one identity while every later run is distinct from the
                   -- runs before it.
                   CASE WHEN selected.event_type = 'tool'
                     THEN printf('run-%d', runs.tool_run_ordinal)
                   END AS tool_activity_run_marker,
                   COALESCE((
                     SELECT json_group_array(completion.external_event_id)
                     FROM sequenced AS completion
                     WHERE completion.source = selected.source
                       AND completion.session_key = selected.session_key
                       AND completion.activity_epoch = selected.activity_epoch
                       AND completion.event_type = 'done'
                   ), '[]') AS completion_epoch_event_ids,
                   (
                     SELECT navigation.payload_json
                     FROM sequenced AS navigation
                     WHERE navigation.source = selected.source
                       AND navigation.session_key = selected.session_key
                       AND navigation.activity_epoch = selected.activity_epoch
                       AND json_extract(
                             navigation.payload_json,
                             '$.session_surface'
                           ) = CASE selected.source
                                 WHEN 'codex' THEN 'chatgpt_app'
                                 WHEN 'claude_code' THEN 'claude_app'
                                 WHEN 'opencode' THEN 'opencode_app'
                               END
                     ORDER BY navigation.created_at DESC, navigation.row_id DESC
                     LIMIT 1
                   ) AS preferred_app_navigation_payload
            FROM ranked AS selected
            LEFT JOIN agent_session_aliases AS aliases
              ON aliases.source = selected.source
             AND aliases.session_key = selected.session_key
            LEFT JOIN tool_runs AS runs
              ON runs.row_id = selected.row_id
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
                    tool_activity_run_marker: row.get(14)?,
                    completion_epoch_event_ids: serde_json::from_str(&row.get::<_, String>(15)?)
                        .map_err(to_sql_error)?,
                    preferred_app_navigation_payload: row
                        .get::<_, Option<String>>(16)?
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

    /// Atomically projects the persisted display records needed to hydrate a
    /// session bubble. A single ordered scan supplies the latest assistant,
    /// latest narrative activity, latest user, and first user records when
    /// (and only when) the caller's event revision is still current.
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::OnceLock;
    use time::{format_description::well_known::Rfc3339, Duration, OffsetDateTime};

    fn fixture_timestamp(offset_seconds: i64) -> String {
        static BASE: OnceLock<OffsetDateTime> = OnceLock::new();
        (*BASE.get_or_init(|| OffsetDateTime::now_utc() - Duration::minutes(1))
            + Duration::seconds(offset_seconds))
        .format(&Rfc3339)
        .expect("format retained event fixture timestamp")
    }

    fn claude_event(
        id: &str,
        event_type: AgentEventType,
        source_event: &str,
        turn_id: &str,
        offset_seconds: i64,
    ) -> AgentEvent {
        AgentEvent {
            id: id.to_string(),
            source: AgentSource::ClaudeCode,
            project_path: None,
            session_id: Some("claude-background-session".to_string()),
            event_type,
            title: event_type.zh_label().to_string(),
            detail: None,
            payload_json: json!({
                "source_event": source_event,
                "turn_id": turn_id,
                "diagnostic": false,
                "affects_activity": true,
                "session_active": !matches!(
                    event_type,
                    AgentEventType::Done | AgentEventType::Failed
                )
            }),
            created_at: fixture_timestamp(offset_seconds),
        }
    }

    #[test]
    fn claude_idle_prompt_cannot_settle_open_background_work() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("agent-pet.sqlite"));
        database.init().unwrap();

        database
            .insert_event(&claude_event(
                "evt-background-prompt",
                AgentEventType::Start,
                "UserPromptSubmit",
                "prompt-background",
                0,
            ))
            .unwrap();

        let mut background = claude_event(
            "evt-background-active",
            AgentEventType::Start,
            "Stop",
            "prompt-background",
            1,
        );
        background.payload_json["outcome"] = json!("background_active");
        database.insert_event(&background).unwrap();

        let mut idle = claude_event(
            "evt-background-idle",
            AgentEventType::Done,
            "Notification",
            "prompt-background",
            2,
        );
        idle.payload_json["outcome"] = json!("idle");
        assert_eq!(
            database.insert_event(&idle).unwrap(),
            InsertEventOutcome::Inserted,
            "the idle notification remains available as bounded audit history"
        );

        let projected = database.latest_sequenced_events_by_session(10).unwrap();
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0].event.id, "evt-background-active");
        assert_eq!(projected[0].event.event_type, AgentEventType::Start);
        assert_eq!(
            projected[0].event.payload_json["outcome"],
            "background_active"
        );
        assert!(database
            .recent_events(10)
            .unwrap()
            .iter()
            .any(|event| event.id == "evt-background-idle"));

        let later_tool = claude_event(
            "evt-background-later-tool",
            AgentEventType::Tool,
            "PreToolUse",
            "prompt-background",
            3,
        );
        assert_eq!(
            database.insert_event(&later_tool).unwrap(),
            InsertEventOutcome::Inserted,
            "a background idle notification must not fence later activity for the same turn"
        );
        let projected = database.latest_sequenced_events_by_session(10).unwrap();
        assert_eq!(projected[0].event.id, "evt-background-later-tool");
        assert_eq!(projected[0].event.event_type, AgentEventType::Tool);

        let mut completed = claude_event(
            "evt-background-completed",
            AgentEventType::Done,
            "Stop",
            "prompt-background",
            4,
        );
        completed.payload_json["outcome"] = json!("completed");
        database.insert_event(&completed).unwrap();
        let projected = database.latest_sequenced_events_by_session(10).unwrap();
        assert_eq!(projected[0].event.id, "evt-background-completed");
        assert_eq!(projected[0].event.event_type, AgentEventType::Done);
    }

    #[test]
    fn claude_idle_prompt_still_settles_a_turn_without_background_work() {
        let temp = tempfile::tempdir().unwrap();
        let database = Database::new(temp.path().join("agent-pet.sqlite"));
        database.init().unwrap();

        database
            .insert_event(&claude_event(
                "evt-ordinary-prompt",
                AgentEventType::Start,
                "UserPromptSubmit",
                "prompt-ordinary",
                10,
            ))
            .unwrap();

        let mut idle = claude_event(
            "evt-ordinary-idle",
            AgentEventType::Done,
            "Notification",
            "prompt-ordinary",
            11,
        );
        idle.payload_json["outcome"] = json!("idle");
        database.insert_event(&idle).unwrap();

        let projected = database.latest_sequenced_events_by_session(10).unwrap();
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0].event.id, "evt-ordinary-idle");
        assert_eq!(projected[0].event.event_type, AgentEventType::Done);

        let late_tool = claude_event(
            "evt-ordinary-late-tool",
            AgentEventType::Tool,
            "PreToolUse",
            "prompt-ordinary",
            12,
        );
        assert_eq!(
            database.insert_event(&late_tool).unwrap(),
            InsertEventOutcome::Suppressed,
            "ordinary idle retains the existing same-turn terminal fence"
        );
    }
}
