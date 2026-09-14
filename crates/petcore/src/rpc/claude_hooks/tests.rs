use super::*;

fn process(pid: u32, parent: u32, executable: &str) -> Process {
    Process {
        identity: Identity {
            pid,
            started: pid as u64 + 100,
            started_fraction: 7,
        },
        parent,
        uid: rustix::process::getuid().as_raw(),
        executable: executable.into(),
    }
}

fn root() -> Vec<Process> {
    vec![
        process(30, 20, "/bin/petcore-cli"),
        process(20, 10, "/bin/claude"),
        process(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
    ]
}

fn nested() -> Vec<Process> {
    let mut chain = vec![
        process(50, 40, "/bin/petcore-cli"),
        process(40, 20, "/bin/claude"),
    ];
    chain.extend(root().into_iter().skip(1));
    chain
}

#[test]
fn registered_parent_hides_nested_calls_but_standalone_cli_and_app_survive() {
    let mut registry = ProcessRegistry::default();
    assert_eq!(registry.observe("parent", &root()), Origin::Desktop);
    assert_eq!(registry.observe("child", &nested()), Origin::Nested);
    assert_eq!(registry.observe("parent", &root()), Origin::Desktop);
    assert_eq!(
        registry.observe("standalone", &[process(70, 1, "/bin/claude")]),
        Origin::Cli
    );
    // An inherited Desktop ancestor alone cannot hide a child if the owning
    // Claude process has not yet registered (including after daemon restart).
    assert_eq!(
        ProcessRegistry::default().observe("child", &nested()),
        Origin::Cli
    );
    assert_eq!(
        registry.observe("unknown", &[process(80, 1, "/bin/node")]),
        Origin::Unknown
    );
}

#[test]
fn pid_reuse_same_session_and_multiplexed_processes_do_not_prove_children() {
    let mut registry = ProcessRegistry::default();
    registry.observe("parent", &root());
    assert_ne!(registry.observe("parent", &nested()), Origin::Nested);
    let mut reused = nested();
    reused[2].identity.started += 1;
    assert_eq!(registry.observe("new-child", &reused), Origin::Cli);
    registry.observe("second-session", &root());
    assert_eq!(registry.observe("child", &nested()), Origin::Cli);
}

#[test]
fn registry_is_bounded_and_discards_reused_pid_associations() {
    let mut registry = ProcessRegistry::default();
    for pid in 2..400 {
        registry.observe("session", &[process(pid, 1, "/bin/claude")]);
    }
    assert_eq!(registry.entries.len(), MAX_REGISTERED_PROCESSES);
    let mut reused = process(399, 1, "/bin/claude");
    reused.identity.started += 1;
    registry.observe("new-session", &[reused.clone()]);
    assert_eq!(registry.entries.len(), MAX_REGISTERED_PROCESSES);
    assert_eq!(
        registry.entries.keys().filter(|id| id.pid == 399).count(),
        1
    );
    assert_eq!(
        registry.entries[&reused.identity].session.as_deref(),
        Some("new-session")
    );
}

#[test]
fn ancestry_rejects_missing_changed_cyclic_deep_and_foreign_process_edges() {
    let chain = root();
    assert_eq!(
        ancestry(30, |pid| chain
            .iter()
            .find(|p| p.identity.pid == pid)
            .cloned()),
        Some(chain.clone())
    );
    assert!(ancestry(30, |_| None).is_none());
    let mut reads = 0;
    assert!(ancestry(30, |pid| {
        reads += 1;
        let mut process = chain.iter().find(|p| p.identity.pid == pid)?.clone();
        if reads > chain.len() {
            process.identity.started += 1;
        }
        Some(process)
    })
    .is_none());
    assert!(ancestry(30, |pid| Some(process(pid, pid, "/bin/claude"))).is_none());
    assert!(ancestry(100, |pid| Some(process(pid, pid - 1, "/bin/claude"))).is_none());
    let foreign = ancestry(30, |pid| {
        let mut p = process(pid, 20, "/bin/claude");
        p.uid = p.uid.wrapping_add(1);
        Some(p)
    })
    .unwrap();
    assert!(foreign.is_empty());
}

#[test]
fn kernel_snapshot_reads_current_process_without_arguments_or_environment() {
    let pid = std::process::id();
    let process = process::inspect(pid).unwrap();
    assert_eq!(process.identity.pid, pid);
    assert!(process.identity.started > 0);
    assert!(process.executable.is_absolute());
    assert_eq!(process.uid, rustix::process::getuid().as_raw());
    assert_eq!(process::inspect(pid), Some(process));
    assert!(process::inspect(i32::MAX as u32).is_none());
}

#[test]
fn typed_hook_context_rejects_bad_process_ids_and_unbounded_session_ids() {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().join("home")));
    for pid in [
        json!(0),
        json!(-1),
        json!("20"),
        json!(u64::MAX),
        Value::Null,
    ] {
        assert!(context(&state, &json!({"hook_pid": pid, "session_id": "fixture"})).is_err());
    }
    for session in [json!(""), json!("x".repeat(257)), json!(1), Value::Null] {
        assert!(context(&state, &json!({"hook_pid": 20, "session_id": session})).is_err());
    }
    let result = context(
        &state,
        &json!({"hook_pid": i32::MAX, "session_id": "fixture"}),
    )
    .unwrap();
    assert_eq!(result, json!({"origin": "unknown"}));
}

#[test]
fn native_installation_names_include_npm_and_versioned_binaries() {
    for executable in [
        "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
        "/Users/fixture/.local/share/claude/versions/2.1.270",
        "/Users/fixture/Library/Application Support/Claude/claude-code/2.1.270/claude.app/Contents/MacOS/claude",
    ] {
        assert!(process(20, 1, executable).is_claude_engine(), "{executable}");
    }
    for executable in [
        "/bin/node",
        "/bin/my-claude",
        "/claude/versions/not-a-version",
    ] {
        assert!(!process(20, 1, executable).is_claude_engine());
    }
}

#[test]
fn busy_parent_is_not_evicted_by_its_nested_calls() {
    let mut registry = ProcessRegistry::default();
    registry.observe("parent", &root());
    for pid in 100..500 {
        let mut chain = nested();
        chain[1].identity.pid = pid;
        assert_eq!(registry.observe("child", &chain), Origin::Nested);
    }
    assert_eq!(registry.entries.len(), MAX_REGISTERED_PROCESSES);
}
