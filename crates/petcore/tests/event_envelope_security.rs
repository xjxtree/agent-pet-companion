use petcore::db::{Database, EventRetentionPolicy, InsertEventOutcome};
use petcore::event_envelope::{NormalizedAgentEvent, MAX_RECENT_EVENTS};
use petcore_types::{
    AgentEvent, AgentEventType, AgentSource, PetOrigin, PetSummary, QualityLevel, RenderSize,
};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const RECEIVED_AT: &str = "2026-07-10T00:00:00Z";
const FORBIDDEN_VALUES: &[&str] = &[
    "FORBIDDEN_PROMPT_VALUE_7f16",
    "FORBIDDEN_COMMAND_VALUE_b8c2",
    "FORBIDDEN_API_KEY_VALUE_4a91",
    "FORBIDDEN_TOOL_RESPONSE_VALUE_19df",
    "FORBIDDEN_TRANSCRIPT_PATH_82e1",
    "FORBIDDEN_ARBITRARY_OUTPUT_VALUE_d611",
];

fn strict_event(
    id: &str,
    source: AgentSource,
    session_id: Option<&str>,
    created_at: &str,
) -> AgentEvent {
    AgentEvent {
        id: id.to_string(),
        source,
        project_path: None,
        session_id: session_id.map(ToOwned::to_owned),
        event_type: AgentEventType::Tool,
        title: "Working".to_string(),
        detail: Some("shell".to_string()),
        payload_json: json!({
            "schema_version": "apc.agent-event.v1",
            "external_event_id": id,
            "source_event": "PostToolUse",
            "tool_name": "shell",
            "outcome": "completed",
            "diagnostic": false
        }),
        created_at: created_at.to_string(),
    }
}

fn external_event(id: &str, session_id: Option<&str>) -> Value {
    json!({
        "id": id,
        "session_id": session_id,
        "event_type": "tool",
        "title": "Working",
        "detail": "shell",
        "payload": {
            "source_event": "PostToolUse",
            "tool_name": "shell",
            "outcome": "completed",
            "diagnostic": false
        }
    })
}

#[test]
fn external_display_and_metadata_aliases_never_reach_visible_records() {
    let event = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        json!({
            "id": "alias-sentinels",
            "session_id": "session-security",
            "event_type": "tool",
            "title": "RAW_TITLE_ALIAS_SENTINEL",
            "detail": "RAW_DETAIL_ALIAS_SENTINEL",
            "payload": {
                "source_event": "RAW_SOURCE_EVENT_ALIAS_SENTINEL",
                "tool_name": "RAW_TOOL_NAME_ALIAS_SENTINEL",
                "outcome": "RAW_OUTCOME_ALIAS_SENTINEL",
                "diagnostic": false
            }
        }),
        RECEIVED_AT,
    )
    .unwrap();

    assert_eq!(event.title, AgentEventType::Tool.zh_label());
    assert_eq!(event.detail, None);
    assert_eq!(event.payload_json["source_event"], "unclassified");
    assert_eq!(event.payload_json["tool_name"], "other");
    assert_eq!(event.payload_json["outcome"], "unknown");

    let visible_record = serde_json::to_string(&event).unwrap();
    for sentinel in [
        "RAW_TITLE_ALIAS_SENTINEL",
        "RAW_DETAIL_ALIAS_SENTINEL",
        "RAW_SOURCE_EVENT_ALIAS_SENTINEL",
        "RAW_TOOL_NAME_ALIAS_SENTINEL",
        "RAW_OUTCOME_ALIAS_SENTINEL",
    ] {
        assert!(!visible_record.contains(sentinel), "leaked {sentinel}");
    }
}

#[test]
fn pi_input_is_a_first_class_allowlisted_lifecycle_event() {
    let event = NormalizedAgentEvent::from_external(
        AgentSource::Pi,
        json!({
            "id": "pi-input-allowlisted",
            "session_id": "pi-input-session",
            "event_type": "start",
            "payload": {
                "source_event": "input",
                "session_active": true,
                "message_role": "user",
                "message_content": "下一条用户消息",
                "diagnostic": false
            }
        }),
        RECEIVED_AT,
    )
    .unwrap();

    assert_eq!(event.payload_json["source_event"], "input");
    assert_eq!(event.payload_json["message_role"], "user");
    assert_eq!(event.payload_json["message_content"], "下一条用户消息");
}

#[test]
fn payload_json_alias_is_normalized_through_the_same_closed_vocabularies() {
    let event = NormalizedAgentEvent::from_external(
        AgentSource::ClaudeCode,
        json!({
            "id": "payload-json-alias",
            "source": "claude_code",
            "event_type": "failed",
            "title": "RAW_TITLE_ALIAS_SENTINEL",
            "detail": "RAW_DETAIL_ALIAS_SENTINEL",
            "payload_json": {
                "schema_version": "apc.agent-event.v1",
                "external_event_id": "payload-json-alias",
                "source_event": "StopFailure",
                "tool_name": "Bash",
                "outcome": "api_failure",
                "diagnostic": false
            },
            "created_at": RECEIVED_AT
        }),
        RECEIVED_AT,
    )
    .unwrap();

    assert_eq!(event.title, AgentEventType::Failed.zh_label());
    assert_eq!(event.detail, None);
    assert_eq!(event.payload_json["source_event"], "StopFailure");
    assert_eq!(event.payload_json["tool_name"], "shell");
    assert_eq!(event.payload_json["outcome"], "api_failure");
    let record = serde_json::to_string(&event).unwrap();
    assert!(!record.contains("RAW_TITLE_ALIAS_SENTINEL"));
    assert!(!record.contains("RAW_DETAIL_ALIAS_SENTINEL"));
}

#[test]
fn session_navigation_accepts_only_allowlisted_warp_focus_urls() {
    let event = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        json!({
            "id": "warp-session-target",
            "event_type": "start",
            "payload": {
                "source_event": "UserPromptSubmit",
                "session_active": true,
                "session_open": true,
                "session_surface": "cli_terminal",
                "terminal_app": "warp",
                "session_open_url": "warppreview://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"
            }
        }),
        RECEIVED_AT,
    )
    .unwrap();
    assert_eq!(event.payload_json["session_open"], true);
    assert_eq!(event.payload_json["terminal_app"], "warp");
    assert_eq!(
        event.payload_json["session_open_url"],
        "warppreview://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"
    );

    let rejected = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        json!({
            "id": "unsafe-session-target",
            "event_type": "start",
            "payload": {
                "source_event": "UserPromptSubmit",
                "session_open_url": "https://example.com/session/not-allowed"
            }
        }),
        RECEIVED_AT,
    )
    .unwrap_err();
    assert!(rejected.to_string().contains("not a supported session URL"));
}

#[test]
fn strict_ingest_rejects_unknown_top_level_and_envelope_fields() {
    let top_level = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        json!({
            "id": "unknown-top-level",
            "event_type": "start",
            "raw_prompt": "must not be ignored"
        }),
        RECEIVED_AT,
    )
    .unwrap_err();
    assert!(top_level.to_string().contains("field is not supported"));

    let nested = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        json!({
            "id": "unknown-envelope-field",
            "event_type": "tool",
            "payload": {
                "source_event": "PreToolUse",
                "tool_name": "Bash",
                "outcome": "started",
                "raw_command": "must not be ignored"
            }
        }),
        RECEIVED_AT,
    )
    .unwrap_err();
    assert!(nested
        .to_string()
        .contains("payload field is not supported"));
}

#[test]
fn strict_ingest_rejects_ambiguous_payload_aliases_and_source_mismatch() {
    let ambiguous = NormalizedAgentEvent::from_external(
        AgentSource::Pi,
        json!({
            "event_type": "tool",
            "payload": {},
            "payload_json": {}
        }),
        RECEIVED_AT,
    )
    .unwrap_err();
    assert!(ambiguous.to_string().contains("only one of payload"));

    let mismatch = NormalizedAgentEvent::from_external(
        AgentSource::Pi,
        json!({
            "source": "codex",
            "event_type": "start"
        }),
        RECEIVED_AT,
    )
    .unwrap_err();
    assert!(mismatch.to_string().contains("source does not match"));
}

fn security_fixture() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/security/sensitive-agent-event.json");
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

#[test]
fn raw_hook_payload_cannot_cross_the_strict_ingest_boundary() {
    let encoded = serde_json::to_string(&security_fixture()).unwrap();
    let error =
        NormalizedAgentEvent::from_external(AgentSource::Codex, security_fixture(), RECEIVED_AT)
            .unwrap_err();

    assert!(error.to_string().contains("payload field is not supported"));
    for forbidden in FORBIDDEN_VALUES {
        assert!(encoded.contains(forbidden));
        assert!(!error.to_string().contains(forbidden));
    }
}

#[test]
fn external_title_and_detail_are_discarded_even_when_multibyte() {
    let mut value = external_event("utf8-bounds", Some("session"));
    value["title"] = Value::String("宠".repeat(100));
    value["detail"] = Value::String("🙂".repeat(200));

    let event = NormalizedAgentEvent::from_external(AgentSource::Pi, value, RECEIVED_AT).unwrap();

    assert_eq!(event.title, AgentEventType::Tool.zh_label());
    assert_eq!(event.detail, None);
}

#[test]
fn missing_external_id_is_stable_for_the_same_canonical_input() {
    let mut value = external_event("ignored", Some("session"));
    value.as_object_mut().unwrap().remove("id");

    let first =
        NormalizedAgentEvent::from_external(AgentSource::ClaudeCode, value.clone(), RECEIVED_AT)
            .unwrap();
    let second =
        NormalizedAgentEvent::from_external(AgentSource::ClaudeCode, value, RECEIVED_AT).unwrap();

    assert_eq!(first.id, second.id);
    assert!(first.id.starts_with("evt_external_"));
}

#[test]
fn same_external_id_from_two_sources_is_not_deduplicated() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("events.sqlite"));
    database.init().unwrap();
    let value = external_event("shared-id", Some("session"));
    let codex = NormalizedAgentEvent::from_external(AgentSource::Codex, value.clone(), RECEIVED_AT)
        .unwrap();
    let pi = NormalizedAgentEvent::from_external(AgentSource::Pi, value, RECEIVED_AT).unwrap();

    assert_eq!(
        database.insert_event(&codex).unwrap(),
        InsertEventOutcome::Inserted
    );
    assert_eq!(
        database.insert_event(&pi).unwrap(),
        InsertEventOutcome::Inserted
    );
    assert_eq!(database.recent_events(10).unwrap().len(), 2);
}

#[test]
fn same_id_in_two_sessions_is_not_deduplicated() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("events.sqlite"));
    database.init().unwrap();
    let first = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        external_event("shared-id", Some("session-a")),
        RECEIVED_AT,
    )
    .unwrap();
    let second = NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        external_event("shared-id", Some("session-b")),
        RECEIVED_AT,
    )
    .unwrap();

    assert_eq!(
        database.insert_event(&first).unwrap(),
        InsertEventOutcome::Inserted
    );
    assert_eq!(
        database.insert_event(&second).unwrap(),
        InsertEventOutcome::Inserted
    );
    assert_eq!(database.recent_events(10).unwrap().len(), 2);
}

#[test]
fn null_and_empty_sessions_share_a_stable_deduplication_namespace() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("events.sqlite"));
    database.init().unwrap();
    let missing = NormalizedAgentEvent::from_external(
        AgentSource::Opencode,
        external_event("same-no-session", None),
        RECEIVED_AT,
    )
    .unwrap();
    let empty = NormalizedAgentEvent::from_external(
        AgentSource::Opencode,
        external_event("same-no-session", Some("  ")),
        RECEIVED_AT,
    )
    .unwrap();

    assert_eq!(
        database.insert_event(&missing).unwrap(),
        InsertEventOutcome::Inserted
    );
    assert_eq!(
        database.insert_event(&empty).unwrap(),
        InsertEventOutcome::Duplicate
    );
}

#[test]
fn recent_events_clamps_limit() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("events.sqlite"));
    database.init().unwrap();
    for index in 0..(MAX_RECENT_EVENTS + 5) {
        let event = strict_event(
            &format!("event-{index:03}"),
            AgentSource::Codex,
            Some("session"),
            RECEIVED_AT,
        );
        assert_eq!(
            database.insert_event(&event).unwrap(),
            InsertEventOutcome::Inserted
        );
    }

    assert!(database.recent_events(0).unwrap().is_empty());
    assert_eq!(
        database.recent_events(usize::MAX).unwrap().len(),
        MAX_RECENT_EVENTS
    );
}

#[test]
fn event_retention_prunes_oldest_rows() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("events.sqlite"));
    database.init().unwrap();
    for (id, created_at) in [
        ("oldest", "2026-07-01T00:00:00Z"),
        ("middle", "2026-07-02T00:00:00Z"),
        ("newest", "2026-07-03T00:00:00Z"),
    ] {
        database
            .insert_event(&strict_event(
                id,
                AgentSource::ClaudeCode,
                Some("session"),
                created_at,
            ))
            .unwrap();
    }
    let defaults = EventRetentionPolicy::default();
    assert_eq!(defaults.max_rows, 10_000);
    assert_eq!(defaults.max_age_days, 30);

    let pruned = database
        .prune_events(EventRetentionPolicy {
            max_rows: 2,
            max_age_days: 36_500,
        })
        .unwrap();

    assert_eq!(pruned, 1);
    let recent = database.recent_events(10).unwrap();
    assert_eq!(recent.len(), 2);
    assert!(recent.iter().all(|event| event.id != "oldest"));
    let summarized: i64 = Connection::open(database.path())
        .unwrap()
        .query_row(
            r#"
            SELECT event_count
            FROM agent_event_daily_counts
            WHERE event_day = '2026-07-01'
              AND source = 'claude_code'
              AND event_type = 'tool'
            "#,
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(summarized, 1);
}

#[test]
fn legacy_payload_migration_removes_plaintext_and_rebuilds_rows() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("legacy.sqlite");
    let connection = Connection::open(&path).unwrap();
    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA user_version = 0;
            CREATE TABLE agent_events (
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
            "#,
        )
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO agent_events
              (id, source, project_path, session_id, event_type, title, detail, payload_json, created_at)
            VALUES (?1, 'codex', NULL, NULL, 'tool',
                    'FORBIDDEN_LEGACY_TITLE_ALIAS_0f31',
                    'FORBIDDEN_LEGACY_DETAIL_ALIAS_4b72', ?2, ?3)
            "#,
            params![
                "legacy-event",
                r#"{"prompt":"FORBIDDEN_LEGACY_PLAINTEXT_63bb","command":"cat secret"}"#,
                RECEIVED_AT,
            ],
        )
        .unwrap();
    drop(connection);

    let database = Database::new(path.clone());
    database.init().unwrap();

    let connection = Connection::open(&path).unwrap();
    let columns = connection
        .prepare("PRAGMA table_info(agent_events)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap();
    assert!(columns.iter().any(|column| column == "row_id"));
    assert!(columns.iter().any(|column| column == "external_event_id"));
    assert!(columns.iter().any(|column| column == "session_key"));
    let payload_text: String = connection
        .query_row("SELECT payload_json FROM agent_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    let payload: Value = serde_json::from_str(&payload_text).unwrap();
    assert_eq!(payload["external_event_id"], "legacy-event");
    assert_eq!(payload["source_event"], "legacy");
    assert!(!payload_text.contains("FORBIDDEN_LEGACY_PLAINTEXT_63bb"));
    let (title, detail): (String, Option<String>) = connection
        .query_row("SELECT title, detail FROM agent_events", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();
    assert_eq!(title, AgentEventType::Tool.zh_label());
    assert_eq!(detail, None);
    let user_version: u32 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    assert!(user_version >= 1);
    drop(connection);

    for candidate in [
        path.clone(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        if candidate.exists() {
            let bytes = fs::read(&candidate).unwrap();
            for forbidden in [
                b"FORBIDDEN_LEGACY_PLAINTEXT_63bb".as_slice(),
                b"FORBIDDEN_LEGACY_TITLE_ALIAS_0f31".as_slice(),
                b"FORBIDDEN_LEGACY_DETAIL_ALIAS_4b72".as_slice(),
            ] {
                assert!(
                    !bytes
                        .windows(forbidden.len())
                        .any(|window| window == forbidden),
                    "legacy plaintext remained in {}",
                    candidate.display()
                );
            }
        }
    }
}

#[test]
fn pending_privacy_scrub_is_retried_before_schema_version_completes() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("interrupted-privacy.sqlite");
    let connection = Connection::open(&path).unwrap();
    connection
        .execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA user_version = 2;
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
            CREATE TABLE privacy_migrations (
              migration_key TEXT PRIMARY KEY,
              phase TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            INSERT INTO privacy_migrations (migration_key, phase, updated_at)
            VALUES ('event-envelope-v4-secure-vacuum', 'pending_secure_vacuum',
                    '2026-07-10T00:00:00Z');
            CREATE TABLE discarded_sensitive_pages (value TEXT NOT NULL);
            INSERT INTO discarded_sensitive_pages VALUES (
              'FORBIDDEN_INTERRUPTED_MIGRATION_PLAINTEXT_93ac'
            );
            DROP TABLE discarded_sensitive_pages;
            "#,
        )
        .unwrap();
    drop(connection);

    let database = Database::new(path.clone());
    database.init().unwrap();

    let connection = Connection::open(&path).unwrap();
    let pending: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM privacy_migrations WHERE migration_key = 'event-envelope-v4-secure-vacuum'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(pending, 0);
    let user_version: u32 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    assert!(user_version >= 4);
    drop(connection);

    for candidate in [
        path.clone(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        if candidate.exists() {
            let bytes = fs::read(&candidate).unwrap();
            let forbidden = b"FORBIDDEN_INTERRUPTED_MIGRATION_PLAINTEXT_93ac";
            assert!(
                !bytes
                    .windows(forbidden.len())
                    .any(|window| window == forbidden),
                "interrupted migration plaintext remained in {}",
                candidate.display()
            );
        }
    }
}

#[test]
fn state_revision_changes_for_every_client_visible_pet_field() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("events.sqlite"));
    database.init().unwrap();
    let mut pet = PetSummary {
        id: "pet-revision".to_string(),
        name: "Pet".to_string(),
        style: "pixel".to_string(),
        quality: QualityLevel::High,
        render_size: RenderSize {
            width: 384,
            height: 416,
        },
        petpack_path: "/tmp/pet.petpack".to_string(),
        cover_path: "/tmp/cover.png".to_string(),
        origin: PetOrigin::ExternalImport,
        generator: None,
        provenance: None,
        active: false,
        created_at: "2026-07-01T00:00:00Z".to_string(),
    };
    let mut previous = database.state_revision().unwrap();

    macro_rules! mutate_and_assert_revision {
        ($mutation:expr) => {{
            $mutation;
            database.upsert_pet(&pet).unwrap();
            let current = database.state_revision().unwrap();
            assert!(current > previous, "revision did not advance");
            previous = current;
        }};
    }

    mutate_and_assert_revision!(pet.name = "Renamed".to_string());
    mutate_and_assert_revision!(pet.style = "watercolor".to_string());
    mutate_and_assert_revision!(pet.quality = QualityLevel::Ultra);
    mutate_and_assert_revision!(pet.render_size.width = 512);
    mutate_and_assert_revision!(pet.render_size.height = 560);
    mutate_and_assert_revision!(pet.petpack_path = "/tmp/revision.petpack".to_string());
    mutate_and_assert_revision!(pet.cover_path = "/tmp/revision-cover.png".to_string());
    mutate_and_assert_revision!(pet.origin = PetOrigin::GeneratedByPetcoreJob);
    mutate_and_assert_revision!(pet.generator = Some("codex".to_string()));
    mutate_and_assert_revision!(pet.provenance = Some("verified".to_string()));
    mutate_and_assert_revision!(pet.active = true);
    mutate_and_assert_revision!(pet.created_at = "2026-07-02T00:00:00Z".to_string());

    database
        .set_pet_asset_validation("pet-revision", "fingerprint", false, Some("repair needed"))
        .unwrap();
    let validation_revision = database.state_revision().unwrap();
    assert!(validation_revision > previous);

    let connection = Connection::open(database.path()).unwrap();
    let row_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM state_revision", [], |row| row.get(0))
        .unwrap();
    let stored: u64 = connection
        .query_row(
            "SELECT revision FROM state_revision WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(row_count, 1);
    assert_eq!(stored, validation_revision);
}
