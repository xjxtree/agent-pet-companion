use super::*;

impl Database {
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
}
