use petcore::db::{Database, InsertEventOutcome};
use petcore::{agent_state, agent_state::SequencedAgentEvent};
use petcore_types::{
    AgentConnectionStatus, AgentConnectorCapabilities, AgentEvent, AgentEventType, AgentSource,
    AgentVerification, BehaviorSettings, ConnectionCheckMode,
};
use serde_json::json;
use std::sync::{Arc, Barrier};

fn event(id: &str, kind: AgentEventType, source_event: &str, turn_id: &str) -> AgentEvent {
    AgentEvent {
        id: id.to_string(),
        source: AgentSource::ClaudeCode,
        project_path: None,
        session_id: Some("claude-ordering-session".to_string()),
        event_type: kind,
        title: kind.zh_label().to_string(),
        detail: None,
        payload_json: json!({
            "source_event": source_event,
            "turn_id": turn_id,
            "diagnostic": false,
            "affects_activity": true,
            "session_active": !matches!(kind, AgentEventType::Done | AgentEventType::Failed)
        }),
        created_at: "2026-07-17T10:00:00Z".to_string(),
    }
}

#[test]
fn metadata_only_connector_events_never_drive_the_pet_state() {
    let mut metadata = event(
        "evt-metadata",
        AgentEventType::Start,
        "Setup",
        "prompt-metadata",
    );
    metadata.payload_json["affects_activity"] = json!(false);
    let candidates = [SequencedAgentEvent {
        event: metadata,
        source_session_sequence: 1,
        session_alias_sequence: Some(1),
        session_activated_at: None,
        session_first_seen_at: None,
        latest_terminal_navigation_payload: None,
    }];
    let now = time::OffsetDateTime::parse(
        "2026-07-17T10:00:01Z",
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap();
    assert!(
        agent_state::select_active_agent_state(&BehaviorSettings::default(), &candidates, now)
            .is_none()
    );
}

#[test]
fn terminal_turn_fence_rejects_late_async_activity_but_allows_the_next_prompt() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("agent-pet.sqlite"));
    database.init().unwrap();

    let terminal = event("evt-terminal", AgentEventType::Done, "Stop", "prompt-one");
    assert_eq!(
        database.insert_event(&terminal).unwrap(),
        InsertEventOutcome::Inserted
    );

    let late_tool = event(
        "evt-late-tool",
        AgentEventType::Tool,
        "PostToolUse",
        "prompt-one",
    );
    assert_eq!(
        database.insert_event(&late_tool).unwrap(),
        InsertEventOutcome::Suppressed
    );

    let next_prompt = event(
        "evt-next-prompt",
        AgentEventType::Start,
        "UserPromptSubmit",
        "prompt-two",
    );
    assert_eq!(
        database.insert_event(&next_prompt).unwrap(),
        InsertEventOutcome::Inserted
    );
    let recent = database.recent_events(10).unwrap();
    assert_eq!(recent.len(), 2);
    assert!(recent.iter().all(|event| event.id != "evt-late-tool"));
}

#[test]
fn newer_metadata_does_not_hide_the_latest_activity_for_a_session() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("agent-pet.sqlite"));
    database.init().unwrap();

    let tool = event("evt-tool", AgentEventType::Tool, "PreToolUse", "prompt-one");
    database.insert_event(&tool).unwrap();
    let mut setup = event("evt-setup", AgentEventType::Start, "Setup", "prompt-one");
    setup.payload_json["affects_activity"] = json!(false);
    database.insert_event(&setup).unwrap();

    let candidates = database.latest_sequenced_events_by_session(10).unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].event.id, "evt-tool");
    assert_eq!(candidates[0].event.event_type, AgentEventType::Tool);

    let mut done = event("evt-done", AgentEventType::Done, "Stop", "prompt-one");
    done.created_at = "2026-07-17T10:00:01Z".to_string();
    database.insert_event(&done).unwrap();
    let mut config = event(
        "evt-config",
        AgentEventType::Start,
        "ConfigChange",
        "prompt-one",
    );
    config.created_at = "2026-07-17T10:00:02Z".to_string();
    config.payload_json["affects_activity"] = json!(false);
    database.insert_event(&config).unwrap();

    let candidates = database.latest_sequenced_events_by_session(10).unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].event.id, "evt-done");
    assert_eq!(candidates[0].event.event_type, AgentEventType::Done);
}

#[test]
fn concurrent_single_source_status_writes_preserve_all_four_agents() {
    let temp = tempfile::tempdir().unwrap();
    let database = Database::new(temp.path().join("agent-pet.sqlite"));
    database.init().unwrap();
    let sources = [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ];
    let barrier = Arc::new(Barrier::new(sources.len()));
    let threads = sources.map(|source| {
        let database = database.clone();
        let barrier = Arc::clone(&barrier);
        std::thread::spawn(move || {
            let status = AgentConnectionStatus {
                source,
                items: vec![],
                install_paths: vec![format!("/tmp/{source:?}")],
                connector_installed: true,
                verification: AgentVerification::default(),
                capabilities: AgentConnectorCapabilities::default(),
                check_mode: ConnectionCheckMode::Runtime,
                checked_at: "2026-07-17T10:00:00Z".to_string(),
            };
            barrier.wait();
            database.upsert_connection_status(&status).unwrap();
        })
    });
    for thread in threads {
        thread.join().unwrap();
    }

    let statuses = database.connection_statuses().unwrap();
    assert_eq!(statuses.len(), sources.len());
    for source in sources {
        assert!(statuses.iter().any(|status| status.source == source));
    }
}
