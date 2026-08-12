use super::*;

impl Database {
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

    pub fn acknowledge_agent_session(&self, acknowledgement_id: &str) -> Result<bool> {
        if !is_valid_session_acknowledgement_id(acknowledgement_id) {
            return Err(PetCoreError::InvalidRequest(
                "invalid params: acknowledgement_id is invalid".to_string(),
            ));
        }
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut acknowledgements = read_agent_session_acknowledgements(&transaction)?;
        if acknowledgements
            .ids
            .iter()
            .any(|existing| existing == acknowledgement_id)
        {
            transaction.commit()?;
            return Ok(false);
        }
        acknowledgements.ids.push(acknowledgement_id.to_string());
        if acknowledgements.ids.len() > MAX_AGENT_SESSION_ACKNOWLEDGEMENTS {
            let excess = acknowledgements.ids.len() - MAX_AGENT_SESSION_ACKNOWLEDGEMENTS;
            acknowledgements.ids.drain(..excess);
        }
        transaction.execute(
            r#"
            INSERT INTO settings (key, value_json, updated_at, revision)
            VALUES (?1, ?2, ?3, 1)
            ON CONFLICT(key) DO UPDATE SET
              value_json = excluded.value_json,
              updated_at = excluded.updated_at,
              revision = settings.revision + 1
            "#,
            params![
                AGENT_SESSION_ACKNOWLEDGEMENTS_SETTING_KEY,
                serde_json::to_string(&acknowledgements)?,
                now_rfc3339()
            ],
        )?;
        transaction.commit()?;
        Ok(true)
    }

    pub(crate) fn acknowledged_agent_sessions_at_revision(
        &self,
        expected_state_revision: u64,
    ) -> Result<RevisionChecked<BTreeSet<String>>> {
        self.read_projection_at_revision(expected_state_revision, |connection| {
            Ok(read_agent_session_acknowledgements(connection)?
                .ids
                .into_iter()
                .collect())
        })
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
        if changes.mouse_passthrough.is_some() {
            return Err(PetCoreError::InvalidRequest(
                "invalid params: mouse_passthrough is always enabled and is no longer configurable"
                    .to_string(),
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

    pub(crate) fn overlay_placement_projection(&self) -> Result<OverlayPlacementProjection> {
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
        let projection = read_overlay_placement_projection(&transaction)?;
        transaction.commit()?;
        Ok(projection)
    }

    pub(crate) fn overlay_placement_at_revision(
        &self,
        expected_state_revision: u64,
    ) -> Result<RevisionChecked<OverlayPlacementProjection>> {
        self.read_projection_at_revision(expected_state_revision, |connection| {
            read_overlay_placement_projection(connection)
        })
    }

    pub(crate) fn set_overlay_placement(
        &self,
        placement: &OverlayPlacement,
        intent: Option<OverlayPlacementIntent>,
        expected_revision: Option<u64>,
    ) -> Result<OverlayPlacementWriteResult> {
        let placement = placement.canonicalized().map_err(|error| {
            PetCoreError::Validation(format!("invalid overlay placement: {error}"))
        })?;
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = read_overlay_placement_projection(&transaction)?;
        if expected_revision.is_some_and(|expected| expected != current.revision) {
            return Ok(OverlayPlacementWriteResult::Conflict {
                projection: current,
            });
        }
        if current.placement.semantically_eq(&placement) && current.intent == intent {
            let state_revision = state_revision_in_connection(&transaction)?;
            transaction.commit()?;
            return Ok(OverlayPlacementWriteResult::Unchanged {
                state_revision,
                projection: current,
            });
        }
        let next_revision = current.revision.checked_add(1).ok_or_else(|| {
            PetCoreError::Validation("overlay placement revision overflow".to_string())
        })?;
        let updated_at = now_rfc3339();
        transaction.execute(
            r#"
            INSERT INTO settings (key, value_json, updated_at, revision)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(key) DO UPDATE SET
              value_json = excluded.value_json,
              updated_at = excluded.updated_at,
              revision = excluded.revision
            "#,
            params![
                OVERLAY_PLACEMENT_SETTING_KEY,
                serde_json::to_string_pretty(&placement)?,
                updated_at,
                next_revision,
            ],
        )?;
        if let Some(intent) = intent {
            transaction.execute(
                r#"
                INSERT INTO settings (key, value_json, updated_at, revision)
                VALUES (?1, ?2, ?3, 1)
                ON CONFLICT(key) DO UPDATE SET
                  value_json = excluded.value_json,
                  updated_at = excluded.updated_at,
                  revision = settings.revision + 1
                "#,
                params![
                    OVERLAY_PLACEMENT_INTENT_SETTING_KEY,
                    serde_json::to_string(&intent)?,
                    updated_at
                ],
            )?;
        } else {
            transaction.execute(
                "DELETE FROM settings WHERE key = ?1",
                params![OVERLAY_PLACEMENT_INTENT_SETTING_KEY],
            )?;
        }
        let state_revision = state_revision_in_connection(&transaction)?;
        transaction.commit()?;
        Ok(OverlayPlacementWriteResult::Updated {
            state_revision,
            projection: OverlayPlacementProjection {
                placement,
                intent,
                revision: next_revision,
            },
        })
    }
}
