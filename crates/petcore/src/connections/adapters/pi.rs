use std::time::Duration;

pub(crate) const PI_EXTENSION_TEMPLATE: &str =
    include_str!("../../../../../plugins/pi/agent-pet-companion.ts.tpl");

pub(crate) const PI_NATIVE_PROBE_TIMEOUT: Duration = Duration::from_secs(15);

pub(crate) const PI_AUDITED_EVENTS: &[&str] = &[
    "project_trust",
    "resources_discover",
    "session_start",
    "session_info_changed",
    "session_before_switch",
    "session_before_fork",
    "session_before_compact",
    "session_compact",
    "session_shutdown",
    "session_before_tree",
    "session_tree",
    "context",
    "before_provider_request",
    "before_provider_headers",
    "after_provider_response",
    "before_agent_start",
    "agent_start",
    "agent_end",
    "agent_settled",
    "turn_start",
    "turn_end",
    "message_start",
    "message_update",
    "message_end",
    "tool_execution_start",
    "tool_execution_update",
    "tool_execution_end",
    "model_select",
    "thinking_level_select",
    "user_bash",
    "input",
    "tool_call",
    "tool_result",
];

pub(crate) const PI_TASK_START_EVENTS: &[&str] =
    &["input", "before_agent_start", "agent_start", "turn_start"];

pub(crate) const PI_TASK_ACTIVITY_EVENTS: &[&str] = &["tool_call", "tool_execution_start"];

pub(crate) const PI_TASK_COMPLETION_EVENTS: &[&str] = &["tool_execution_end", "agent_settled"];

use super::*;

pub(super) fn pi_managed_root_state(root: &Path) -> ManagedPathState {
    managed_script_root_state(root, AgentSource::Pi)
}

pub(super) fn pi_runtime_probe_status(event_seen: bool, _host_ok: bool) -> CheckStatus {
    if event_seen {
        CheckStatus::Ok
    } else {
        CheckStatus::NeedsFix
    }
}

pub(super) fn pi_native_probe_spec(
    pi: PathBuf,
    paths: &AppPaths,
    probe_cwd: &Path,
    probe_id: &str,
) -> ProcessSpec {
    ProcessSpec::new(
        pi,
        [
            "--offline",
            "--no-session",
            "--mode",
            "rpc",
            "--no-approve",
            "--no-skills",
            "--no-prompt-templates",
            "--no-themes",
            "--no-context-files",
            "--no-tools",
        ],
        PI_NATIVE_PROBE_TIMEOUT,
    )
    .with_env("APC_HOME", &paths.home)
    .with_env("APC_CONNECTOR_PROBE", "1")
    .with_env("APC_CONNECTOR_PROBE_ID", probe_id)
    .with_current_dir(probe_cwd)
}

pub(super) fn pi_extensions_dir() -> PathBuf {
    // APC_AGENT_CONFIG_HOME is the hermetic test/alternate-home override for
    // every connector and must win over host variables inherited from the
    // developer machine.
    if let Some(fake_home) = non_empty_env_path("APC_AGENT_CONFIG_HOME") {
        return fake_home.join(".pi").join("agent").join("extensions");
    }
    non_empty_env_path("PI_CODING_AGENT_DIR")
        .unwrap_or_else(|| user_home().join(".pi").join("agent"))
        .join("extensions")
}

#[cfg(test)]
mod contract_tests {
    use super::*;

    #[test]
    fn pi_adapter_contract_binds_cli_version_and_task_lifecycle() {
        assert!(PI_EXTENSION_TEMPLATE.contains("__APC_CLI_JSON__"));
        assert!(PI_EXTENSION_TEMPLATE.contains("__APC_CONNECTOR_RELEASE_VERSION__"));
        assert!(PI_AUDITED_EVENTS.contains(&"project_trust"));
        assert!(PI_TASK_START_EVENTS.contains(&"before_agent_start"));
        assert!(PI_TASK_COMPLETION_EVENTS.contains(&"agent_settled"));
    }
}
