use petcore::db::{BehaviorSettingsPatch, DATABASE_SCHEMA_VERSION};
use petcore::paths::AppPaths;
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::{OnboardingProgress, OnboardingStage, ONBOARDING_PROGRESS_SCHEMA_VERSION};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::sync::{Arc, Barrier};

fn ready() -> (tempfile::TempDir, CoreState) {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    state.ensure_ready().unwrap();
    (temp, state)
}

fn request(method: &str, params: Value) -> RpcRequest {
    RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("onboarding-test")),
        method: method.to_string(),
        params,
    }
}

fn progress(stage: OnboardingStage) -> OnboardingProgress {
    OnboardingProgress {
        schema_version: ONBOARDING_PROGRESS_SCHEMA_VERSION.to_string(),
        stage,
    }
}

fn update(state: &CoreState, expected_revision: &str, stage: OnboardingStage) -> Value {
    handle_request(
        state,
        request(
            "onboarding.update",
            json!({
                "expected_revision": expected_revision,
                "progress": progress(stage),
            }),
        ),
    )
    .unwrap()
}

#[test]
fn fresh_home_projects_versioned_default_without_a_schema_bump() {
    let (_temp, state) = ready();

    let onboarding = handle_request(&state, request("onboarding.get", json!({}))).unwrap();
    assert_eq!(
        onboarding["progress"]["schema_version"],
        ONBOARDING_PROGRESS_SCHEMA_VERSION
    );
    assert_eq!(onboarding["progress"]["stage"], "choose_pet");
    assert_eq!(onboarding["revision"], "0");

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(snapshot["onboarding"], onboarding);

    let connection = Connection::open(state.database.path()).unwrap();
    let schema_version: u32 = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(schema_version, DATABASE_SCHEMA_VERSION);
    let persisted_count: u64 = connection
        .query_row(
            "SELECT COUNT(*) FROM settings WHERE key = 'onboarding_progress'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        persisted_count, 0,
        "the derived fresh-home default does not need a synthetic migration row"
    );
}

#[test]
fn progress_resumes_after_restart_and_completion_reenables_the_pet() {
    let (temp, state) = ready();
    let connected = update(&state, "0", OnboardingStage::ConnectAgents);
    assert_eq!(connected["revision"], "1");
    drop(state);

    let resumed = CoreState::new(AppPaths::new(temp.path().join("home")));
    resumed.ensure_ready().unwrap();
    let restored = handle_request(&resumed, request("onboarding.get", json!({}))).unwrap();
    assert_eq!(restored["progress"]["stage"], "connect_agents");
    assert_eq!(restored["revision"], "1");

    let demo = update(&resumed, "1", OnboardingStage::Demo);
    assert_eq!(demo["revision"], "2");
    let behavior_revision = resumed
        .database
        .behavior_with_revision()
        .unwrap()
        .revision
        .parse()
        .unwrap();
    resumed
        .database
        .patch_behavior(
            behavior_revision,
            &BehaviorSettingsPatch {
                enabled: Some(false),
                ..BehaviorSettingsPatch::default()
            },
        )
        .unwrap();
    assert!(!resumed.database.behavior().unwrap().enabled);

    let completed = update(&resumed, "2", OnboardingStage::Completed);
    assert_eq!(completed["progress"]["stage"], "completed");
    assert_eq!(completed["revision"], "3");
    assert!(
        resumed.database.behavior().unwrap().enabled,
        "completion atomically restores pet visibility"
    );
}

#[test]
fn every_nonterminal_scene_can_be_explicitly_skipped() {
    for (advance, revision) in [
        (Vec::new(), "0"),
        (vec![OnboardingStage::ConnectAgents], "1"),
        (
            vec![OnboardingStage::ConnectAgents, OnboardingStage::Demo],
            "2",
        ),
    ] {
        let (_temp, state) = ready();
        let mut expected = "0".to_string();
        for stage in advance {
            let result = update(&state, &expected, stage);
            expected = result["revision"].as_str().unwrap().to_string();
        }
        assert_eq!(expected, revision);
        let skipped = update(&state, &expected, OnboardingStage::Skipped);
        assert_eq!(skipped["progress"]["stage"], "skipped");
        assert!(state
            .database
            .onboarding_with_revision()
            .unwrap()
            .progress
            .stage
            .is_terminal());
    }
}

#[test]
fn cas_unknown_values_and_invalid_transitions_fail_closed() {
    let (_temp, state) = ready();
    let invalid_transition = handle_request(
        &state,
        request(
            "onboarding.update",
            json!({
                "expected_revision": "0",
                "progress": progress(OnboardingStage::Demo),
            }),
        ),
    )
    .unwrap_err();
    assert!(invalid_transition.to_string().contains("is not allowed"));

    let unknown_schema = handle_request(
        &state,
        request(
            "onboarding.update",
            json!({
                "expected_revision": "0",
                "progress": {
                    "schema_version": "apc.onboarding-progress.v2",
                    "stage": "connect_agents",
                },
            }),
        ),
    )
    .unwrap_err();
    assert!(unknown_schema.to_string().contains("schema_version"));

    let unknown_stage = handle_request(
        &state,
        request(
            "onboarding.update",
            json!({
                "expected_revision": "0",
                "progress": {
                    "schema_version": ONBOARDING_PROGRESS_SCHEMA_VERSION,
                    "stage": "future_scene",
                },
            }),
        ),
    )
    .unwrap_err();
    assert!(unknown_stage
        .to_string()
        .contains("invalid onboarding progress"));

    update(&state, "0", OnboardingStage::ConnectAgents);
    let stale = handle_request(
        &state,
        request(
            "onboarding.update",
            json!({
                "expected_revision": "0",
                "progress": progress(OnboardingStage::Skipped),
            }),
        ),
    )
    .unwrap_err();
    assert!(stale.to_string().contains("onboarding revision conflict"));

    update(&state, "1", OnboardingStage::Demo);
    update(&state, "2", OnboardingStage::Completed);
    let terminal_rewrite = handle_request(
        &state,
        request(
            "onboarding.update",
            json!({
                "expected_revision": "3",
                "progress": progress(OnboardingStage::Skipped),
            }),
        ),
    )
    .unwrap_err();
    assert!(terminal_rewrite.to_string().contains("is not allowed"));

    let bypass = handle_request(
        &state,
        request(
            "settings.update",
            json!({
                "key": "onboarding_progress",
                "value": progress(OnboardingStage::Completed),
            }),
        ),
    )
    .unwrap_err();
    assert!(bypass
        .to_string()
        .contains("product settings use typed methods"));
}

#[test]
fn concurrent_updates_from_one_revision_have_exactly_one_winner() {
    let (_temp, state) = ready();
    let database = Arc::new(state.database.clone());
    let barrier = Arc::new(Barrier::new(3));
    let mut workers = Vec::new();
    for stage in [OnboardingStage::ConnectAgents, OnboardingStage::Skipped] {
        let database = Arc::clone(&database);
        let barrier = Arc::clone(&barrier);
        workers.push(std::thread::spawn(move || {
            barrier.wait();
            database.update_onboarding(0, &progress(stage))
        }));
    }
    barrier.wait();
    let results = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(results.iter().filter(|result| result.is_err()).count(), 1);
    assert_eq!(database.onboarding_with_revision().unwrap().revision, "1");
}

#[test]
fn onboarding_persistence_never_creates_agent_or_session_records() {
    let (_temp, state) = ready();
    update(&state, "0", OnboardingStage::ConnectAgents);
    update(&state, "1", OnboardingStage::Demo);

    let snapshot = handle_request(&state, request("state.snapshot", json!({}))).unwrap();
    assert_eq!(snapshot["events"], json!([]));
    assert_eq!(snapshot["recent_events"], json!([]));
    assert_eq!(snapshot["active_agent_state"], Value::Null);
    assert_eq!(snapshot["active_agent_sessions"], json!([]));

    let connection = Connection::open(state.database.path()).unwrap();
    for table in [
        "agent_events",
        "agent_event_daily_counts",
        "suppressed_agent_sessions",
        "agent_session_aliases",
    ] {
        let count: u64 = connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "{table} must remain untouched by onboarding");
    }
}
