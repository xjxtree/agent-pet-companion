use super::*;

const SETTING_KEY: &str = "agent_message_dismissals";
const SCHEMA_VERSION: &str = "apc.agent-message-dismissals.v1";
const MAX_DISMISSALS: usize = 10_000;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MessageDismissals {
    schema_version: String,
    ids: BTreeSet<String>,
}

fn read(connection: &Connection) -> Result<MessageDismissals> {
    let value: Option<String> = connection
        .query_row(
            "SELECT value_json FROM settings WHERE key = ?1",
            [SETTING_KEY],
            |row| row.get(0),
        )
        .optional()?;
    let value = value
        .map(|value| serde_json::from_str::<MessageDismissals>(&value))
        .transpose()?
        .unwrap_or_else(|| MessageDismissals {
            schema_version: SCHEMA_VERSION.to_string(),
            ids: BTreeSet::new(),
        });
    if value.schema_version != SCHEMA_VERSION
        || value.ids.len() > MAX_DISMISSALS
        || value
            .ids
            .iter()
            .any(|id| !crate::agent_state::is_valid_message_dismissal_id(id))
    {
        return Err(PetCoreError::InvalidRequest(
            "invalid Agent message dismissals".to_string(),
        ));
    }
    Ok(value)
}

impl Database {
    pub fn dismiss_agent_message(&self, dismissal_id: &str) -> Result<bool> {
        if !crate::agent_state::is_valid_message_dismissal_id(dismissal_id) {
            return Err(PetCoreError::InvalidParams(
                "invalid params: dismissal_id is invalid".to_string(),
            ));
        }
        let mut connection = self.open()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut dismissals = read(&transaction)?;
        if dismissals.ids.contains(dismissal_id) {
            return Ok(false);
        }
        // Never revive a previously closed message to make room for a new one.
        if dismissals.ids.len() == MAX_DISMISSALS {
            return Err(PetCoreError::Conflict(
                "Agent message dismissal storage is full".to_string(),
            ));
        }
        dismissals.ids.insert(dismissal_id.to_string());
        transaction.execute(
            "INSERT INTO settings (key, value_json, updated_at, revision) VALUES (?1, ?2, ?3, 1)
             ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json,
               updated_at = excluded.updated_at, revision = settings.revision + 1",
            params![
                SETTING_KEY,
                serde_json::to_string(&dismissals)?,
                now_rfc3339()
            ],
        )?;
        transaction.commit()?;
        Ok(true)
    }

    pub(crate) fn dismissed_agent_messages_at_revision(
        &self,
        revision: u64,
    ) -> Result<RevisionChecked<BTreeSet<String>>> {
        self.read_projection_at_revision(revision, |connection| Ok(read(connection)?.ids))
    }
}
