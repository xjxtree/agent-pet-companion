use super::*;

impl Database {
    pub fn upsert_pet(&self, pet: &PetSummary) -> Result<()> {
        let connection = self.open()?;
        let states_json = serde_json::to_string(&pet.states)?;
        connection.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, states_json, petpack_path, cover_path, origin, generator, provenance, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              states_json = excluded.states_json,
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
                states_json,
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

    /// Commits a pet summary and the "first valid pet becomes active" rule in one
    /// SQLite transaction. Callers can therefore publish an immutable asset
    /// revision and roll it back as a unit when this transaction fails.
    pub fn upsert_pet_and_activate_if_first(&self, pet: &PetSummary) -> Result<bool> {
        self.upsert_pet_and_activate_if_first_with_retry(
            pet,
            DATABASE_BUSY_TIMEOUT,
            PET_REVISION_DATABASE_COMMIT_ATTEMPTS,
            PET_REVISION_DATABASE_RETRY_DELAY,
        )
    }

    fn upsert_pet_and_activate_if_first_with_retry(
        &self,
        pet: &PetSummary,
        busy_timeout: Duration,
        maximum_attempts: usize,
        retry_delay: Duration,
    ) -> Result<bool> {
        retry_transient_database_contention(maximum_attempts, retry_delay, || {
            self.upsert_pet_and_activate_if_first_once(pet, busy_timeout)
        })
    }

    fn upsert_pet_and_activate_if_first_once(
        &self,
        pet: &PetSummary,
        busy_timeout: Duration,
    ) -> Result<bool> {
        let mut connection = self.open_with_busy_timeout(busy_timeout)?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let states_json = serde_json::to_string(&pet.states)?;
        let active_pet_count: i64 =
            transaction.query_row("SELECT COUNT(*) FROM pets WHERE active = 1", [], |row| {
                row.get(0)
            })?;
        let effective_active = active_pet_count == 0 || pet.active;
        transaction.execute(
            r#"
            INSERT INTO pets
              (id, name, style, quality, render_width, render_height, states_json, petpack_path, cover_path, origin, generator, provenance, active, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              style = excluded.style,
              quality = excluded.quality,
              render_width = excluded.render_width,
              render_height = excluded.render_height,
              states_json = excluded.states_json,
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
                states_json,
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
            SELECT id, name, style, quality, render_width, render_height, states_json, petpack_path, cover_path, origin, generator, provenance, active, created_at
            FROM pets
            ORDER BY created_at DESC
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            let quality: String = row.get(3)?;
            let states = decode_pet_states(&row.get::<_, String>(6)?)?;
            Ok(PetSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                style: row.get(2)?,
                quality: enum_from_name::<QualityLevel>(&quality).map_err(to_sql_error)?,
                render_size: RenderSize {
                    width: row.get::<_, i64>(4)? as u32,
                    height: row.get::<_, i64>(5)? as u32,
                },
                states,
                petpack_path: row.get(7)?,
                cover_path: row.get(8)?,
                origin: enum_from_name::<PetOrigin>(&row.get::<_, String>(9)?)
                    .map_err(to_sql_error)?,
                generator: row.get(10)?,
                provenance: row.get(11)?,
                revision_id: None,
                revision_count: 0,
                active: row.get::<_, i64>(12)? == 1,
                created_at: row.get(13)?,
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
                SELECT id, name, style, quality, render_width, render_height, states_json, petpack_path, cover_path, origin, generator, provenance, active, created_at
                FROM pets
                WHERE id = ?1
                "#,
                params![pet_id],
                |row| {
                    let quality: String = row.get(3)?;
                    let states = decode_pet_states(&row.get::<_, String>(6)?)?;
                    Ok(PetSummary {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        style: row.get(2)?,
                        quality: enum_from_name::<QualityLevel>(&quality).map_err(to_sql_error)?,
                        render_size: RenderSize {
                            width: row.get::<_, i64>(4)? as u32,
                            height: row.get::<_, i64>(5)? as u32,
                        },
                        states,
                        petpack_path: row.get(7)?,
                        cover_path: row.get(8)?,
                        origin: enum_from_name::<PetOrigin>(&row.get::<_, String>(9)?)
                            .map_err(to_sql_error)?,
                        generator: row.get(10)?,
                        provenance: row.get(11)?,
                        revision_id: None,
                        revision_count: 0,
                        active: row.get::<_, i64>(12)? == 1,
                        created_at: row.get(13)?,
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
        // Reserve the writer before taking the existence snapshot. A deferred
        // transaction can read while another PetCore request is writing and
        // then fail immediately when it tries to upgrade, bypassing the busy
        // timeout and making a valid activation appear to need another click.
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
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
        transaction.execute(
            r#"
            UPDATE pets
            SET active = CASE WHEN id = ?1 THEN 1 ELSE 0 END
            WHERE active != CASE WHEN id = ?1 THEN 1 ELSE 0 END
            "#,
            params![pet_id],
        )?;
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
