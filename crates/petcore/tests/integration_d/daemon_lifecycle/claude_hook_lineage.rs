//! Synthetic executable trees using real kernel ancestry and a real isolated
//! daemon. No installed Agent, user settings or model/provider calls are used.
use super::*;
use petcore::process_runner::{run_bounded, ProcessSpec};

const FIXTURE_TEST: &str = "daemon_lifecycle::claude_hook_lineage::process_fixture";
const AUTH_FAILURE: &str = "Failed to authenticate. API Error: 401 Invalid bearer token";

fn fixture_command(program: &Path, mode: &str, home: &Path, engine: &Path) -> ProcessSpec {
    ProcessSpec::new(
        program,
        ["--exact", FIXTURE_TEST, "--nocapture"],
        Duration::from_secs(20),
    )
    .with_env("APC_CLAUDE_TEST_ROLE", mode)
    .with_env("APC_CLAUDE_TEST_HOME", home)
    .with_env("APC_CLAUDE_TEST_ENGINE", engine)
    .with_env("CLAUDE_CODE_ENTRYPOINT", "claude-desktop")
    .with_env("__CFBundleIdentifier", "com.anthropic.claudefordesktop")
}

fn run_fixture(program: &Path, mode: &str, home: &Path, engine: &Path) {
    let output = run_bounded(fixture_command(program, mode, home, engine)).unwrap();
    assert!(
        output.status.success() && !output.timed_out,
        "fixture {mode}: {output:?}"
    );
}

fn hook(
    paths: &AppPaths,
    session: &str,
    event_type: &str,
    source_event: &str,
    text: &str,
) -> Value {
    let context = daemon::request(
        paths,
        "agent.claude_context",
        json!({
            "hook_pid": std::process::id(), "session_id": session
        }),
    )
    .unwrap();
    let event = if context["origin"] == "nested" {
        json!({"source": "claude_code", "session_id": session, "event_type": "start",
            "payload": {"source_event": "session.child", "session_open": false, "affects_activity": false}})
    } else {
        json!({
            "source": "claude_code", "session_id": session, "event_type": event_type,
            "payload": {
                "source_event": source_event,
                "session_surface": if context["origin"] == "desktop" { "claude_app" } else { "cli_terminal" },
                "session_open": true, "session_title": if session == "root" { "主会话" } else { "x" },
                "message_role": if event_type == "start" { "user" } else { "assistant" },
                "message_content": text
            }
        })
    };
    daemon::request(paths, "agent.ingest", event).unwrap()
}

#[test]
fn process_fixture() {
    let Ok(mode) = std::env::var("APC_CLAUDE_TEST_ROLE") else {
        return;
    };
    let paths = AppPaths::new(std::env::var_os("APC_CLAUDE_TEST_HOME").unwrap().into());
    let engine = std::path::PathBuf::from(std::env::var_os("APC_CLAUDE_TEST_ENGINE").unwrap());
    match mode.as_str() {
        "desktop" => run_fixture(&engine, "root", &paths.home, &engine),
        "root" => {
            let result = hook(
                &paths,
                "root",
                "start",
                "UserPromptSubmit",
                "核验技能发现规则",
            );
            assert_eq!(
                result["event"]["payload_json"]["session_surface"],
                "claude_app"
            );
            hook(&paths, "root", "tool", "PreToolUse", "正在核验技能目录");
            for child in ["child-one", "child-two", "child-three"] {
                run_fixture(&engine, child, &paths.home, &engine);
            }
        }
        "standalone" => {
            assert_eq!(
                hook(&paths, "standalone", "start", "UserPromptSubmit", "x")["inserted"],
                true
            );
            let result = hook(&paths, "standalone", "failed", "StopFailure", AUTH_FAILURE);
            assert_eq!(result["inserted"], true);
            assert_eq!(
                result["event"]["payload_json"]["session_surface"],
                "cli_terminal"
            );
        }
        "child-one" | "child-two" | "child-three" => {
            for (kind, event, text) in [
                ("start", "UserPromptSubmit", "x"),
                ("failed", "StopFailure", AUTH_FAILURE),
            ] {
                let result = hook(&paths, &mode, kind, event, text);
                assert_eq!(result["suppressed"], true, "{result}");
                assert!(result["event"].is_null());
            }
        }
        other => panic!("unsupported test role: {other}"),
    }
}

#[test]
fn real_process_tree_keeps_app_and_standalone_cli_but_suppresses_three_nested_failures() {
    let daemon = start_daemon();
    let root = daemon._temp.path();
    let desktop = root.join("Claude.app/Contents/MacOS/Claude");
    let engine = root.join("node_modules/@anthropic-ai/claude-code/bin/claude.exe");
    for path in [&desktop, &engine] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::copy(std::env::current_exe().unwrap(), path).unwrap();
    }
    run_fixture(&desktop, "desktop", &daemon.paths.home, &engine);
    let events = daemon::request(&daemon.paths, "events.recent", json!({"limit": 20})).unwrap();
    assert!(!events.as_array().unwrap().is_empty());
    for event in events.as_array().unwrap() {
        assert_eq!(event["payload_json"]["session_title"], "主会话");
        assert!(!event.to_string().contains(AUTH_FAILURE));
        assert!(event["payload_json"].get("hook_pid").is_none());
    }
    let snapshot = daemon::request(&daemon.paths, "state.snapshot", json!({})).unwrap();
    assert_eq!(
        snapshot["active_agent_sessions"].as_array().unwrap().len(),
        1
    );
    run_fixture(&engine, "standalone", &daemon.paths.home, &engine);
    let snapshot = daemon::request(&daemon.paths, "state.snapshot", json!({})).unwrap();
    assert_eq!(
        snapshot["active_agent_sessions"].as_array().unwrap().len(),
        2
    );
    assert!(snapshot.to_string().contains(AUTH_FAILURE));
}
