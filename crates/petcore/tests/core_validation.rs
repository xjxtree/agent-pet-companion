use petcore::db::Database;
use petcore::daemon;
use petcore::paths::AppPaths;
use petcore::petpack::{validate_petpack_path, write_sample_petpack_dir};
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{AgentEventType, AgentSource, BehaviorSettings, QualityLevel};
use serde_json::json;
use std::os::unix::net::UnixListener;

#[test]
fn petpack_validation_rejects_missing_state() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 1).unwrap();
    std::fs::remove_dir_all(temp.path().join("assets/frames/tool")).unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("tool"));
}

#[test]
fn petpack_validation_rejects_escaping_asset_paths() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(temp.path(), QualityLevel::High, "Cloud Maiden", "半写实", 1).unwrap();
    let manifest_path = temp.path().join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    manifest["states"][0]["frames_dir"] = serde_json::Value::String("../outside".to_string());
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("inside the package"));
}

#[test]
fn rpc_ingest_deduplicates_and_filters_events() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    let state = CoreState::new(paths);
    state.ensure_ready().unwrap();

    let request = |params| RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("test")),
        method: "agent.ingest".to_string(),
        params,
    };

    let first = handle_request(
        &state,
        request(json!({
            "id": "evt_test_same",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(first["inserted"], true);
    assert_eq!(first["triggered"], true);

    let duplicate = handle_request(
        &state,
        request(json!({
            "id": "evt_test_same",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(duplicate["inserted"], false);
    assert_eq!(duplicate["triggered"], false);

    let database = Database::new(state.paths.db_path.clone());
    let mut behavior = BehaviorSettings::default();
    behavior.sources.insert(AgentSource::Codex, false);
    database.set_setting("behavior", &behavior).unwrap();

    let filtered = handle_request(
        &state,
        request(json!({
            "id": "evt_test_filtered",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(filtered["inserted"], true);
    assert_eq!(filtered["triggered"], false);

    behavior.sources.insert(AgentSource::Codex, true);
    behavior.events.insert(AgentEventType::Tool, false);
    database.set_setting("behavior", &behavior).unwrap();

    let event_filtered = handle_request(
        &state,
        request(json!({
            "id": "evt_test_event_filtered",
            "source": "codex",
            "event_type": "tool",
            "title": "执行工具"
        })),
    )
    .unwrap();
    assert_eq!(event_filtered["inserted"], true);
    assert_eq!(event_filtered["triggered"], false);
}

#[test]
fn daemon_does_not_remove_active_socket() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().to_path_buf());
    paths.ensure().unwrap();
    let _listener = UnixListener::bind(&paths.socket_path).unwrap();

    let error = daemon::serve(paths, None).unwrap_err().to_string();
    assert!(error.contains("already active"));
}
