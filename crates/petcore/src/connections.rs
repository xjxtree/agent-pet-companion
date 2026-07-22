use crate::adapter_contracts::{
    CLAUDE_HOOKS_CONTRACT_VERSION, CODEX_HOOKS_CONTRACT_VERSION, OPENCODE_CONTRACT_VERSION,
    PI_EXTENSION_CONTRACT_VERSION,
};
use crate::agent_environment::{
    absolute_env_path, command_search_dirs as shared_command_search_dirs, find_executable,
    is_executable_file, user_home as shared_user_home,
};
use crate::app_server;
use crate::db::{ConnectorEvidenceSummary, Database};
use crate::paths::AppPaths;
use crate::process_runner::{run_bounded, ProcessSpec};
use crate::{now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentConnectorCapabilities, AgentSource, AgentVerification,
    AgentVerificationStatus, CheckStatus, ConnectionCheckCode as CheckCode, ConnectionCheckItem,
    ConnectionCheckMode, ConnectionCheckRecoveryAction as RecoveryAction,
};
use serde_json::{json, Value};
use std::collections::hash_map::DefaultHasher;
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fs;
use std::hash::{Hash, Hasher};
use std::io::{ErrorKind, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const PET_STUDIO_SKILL_MD: &str = include_str!("../../../skills/agent-pet-studio/SKILL.md");
const AGENT_PET_MAKER_FILES: &[(&str, &str)] = &[
    (
        "SKILL.md",
        include_str!("../../../skills/agent-pet-maker/SKILL.md"),
    ),
    (
        "references/petpack-v1.md",
        include_str!("../../../skills/agent-pet-maker/references/petpack-v1.md"),
    ),
    (
        "references/create-modify.md",
        include_str!("../../../skills/agent-pet-maker/references/create-modify.md"),
    ),
    (
        "references/security.md",
        include_str!("../../../skills/agent-pet-maker/references/security.md"),
    ),
    (
        "scripts/petpack_workspace.py",
        include_str!("../../../skills/agent-pet-maker/scripts/petpack_workspace.py"),
    ),
    (
        "agents/openai.yaml",
        include_str!("../../../skills/agent-pet-maker/agents/openai.yaml"),
    ),
    (
        "tests/test_petpack_workspace.py",
        include_str!("../../../skills/agent-pet-maker/tests/test_petpack_workspace.py"),
    ),
];
const CODEX_PLUGIN_JSON: &str = include_str!("../../../plugins/codex/.codex-plugin/plugin.json");
const CODEX_HOOKS_TEMPLATE: &str = include_str!("../../../plugins/codex/hooks/hooks.json.tpl");
const CLAUDE_SETTINGS_TEMPLATE: &str =
    include_str!("../../../plugins/claude-code/settings.fragment.json.tpl");
const PI_EXTENSION_TEMPLATE: &str = include_str!("../../../plugins/pi/agent-pet-companion.ts.tpl");
const OPENCODE_PLUGIN_TEMPLATE: &str =
    include_str!("../../../plugins/opencode/agent-pet-companion.js.tpl");
const HOST_VERIFICATION_CACHE_TTL_SECONDS: i64 = 5 * 60;
const HOST_VERIFICATION_FUTURE_SKEW_SECONDS: i64 = 60;
const PROBE_CWD_ACCESS_TIMEOUT: Duration = Duration::from_secs(2);
const CLAUDE_NATIVE_PROBE_TIMEOUT: Duration = Duration::from_secs(12);
const PI_NATIVE_PROBE_TIMEOUT: Duration = Duration::from_secs(15);
const OPENCODE_NATIVE_PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_MANAGED_CONNECTOR_SCRIPT_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug)]
struct ProbeCwdAccess {
    item: ConnectionCheckItem,
    resolved_cwd: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ManagedConnectorScriptOwnership {
    Missing,
    Owned,
    Foreign,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ManagedPathState {
    Missing,
    Safe,
    Conflict,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CodexMarketplaceEntryState {
    Missing,
    Current,
    OwnedOutdated,
    Conflict,
}

// Codex uses two spellings for the same hook surface: hooks.json keys are
// PascalCase, while the App Server hooks/list API returns camelCase.
const CODEX_LOCAL_HOOK_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "Stop",
];
const CODEX_APP_SERVER_HOOK_EVENTS: &[&str] = &[
    "sessionStart",
    "userPromptSubmit",
    "preToolUse",
    "permissionRequest",
    "postToolUse",
    "preCompact",
    "postCompact",
    "subagentStart",
    "subagentStop",
    "stop",
];
// Generated and diffed from Codex CLI 0.144.5 and the ChatGPT desktop bundled
// Codex CLI 0.145.0-alpha.18 with
// `codex app-server generate-json-schema --experimental`. These are audited
// notification methods, not fields that Agent Pet Companion persists.
const CODEX_APP_SERVER_NOTIFICATION_EVENTS: &[&str] = &[
    "error",
    "thread/started",
    "thread/status/changed",
    "thread/archived",
    "thread/deleted",
    "thread/unarchived",
    "thread/closed",
    "thread/environment/connected",
    "thread/environment/disconnected",
    "skills/changed",
    "thread/name/updated",
    "thread/goal/updated",
    "thread/goal/cleared",
    "thread/settings/updated",
    "thread/tokenUsage/updated",
    "turn/started",
    "hook/started",
    "turn/completed",
    "hook/completed",
    "turn/diff/updated",
    "turn/plan/updated",
    "item/started",
    "item/autoApprovalReview/started",
    "item/autoApprovalReview/completed",
    "item/completed",
    "item/agentMessage/delta",
    "item/plan/delta",
    "command/exec/outputDelta",
    "process/outputDelta",
    "process/exited",
    "item/commandExecution/outputDelta",
    "item/commandExecution/terminalInteraction",
    "item/fileChange/outputDelta",
    "item/fileChange/patchUpdated",
    "serverRequest/resolved",
    "item/mcpToolCall/progress",
    "mcpServer/oauthLogin/completed",
    "mcpServer/startupStatus/updated",
    "account/updated",
    "account/rateLimits/updated",
    "app/list/updated",
    "remoteControl/status/changed",
    "externalAgentConfig/import/progress",
    "externalAgentConfig/import/completed",
    "fs/changed",
    "item/reasoning/summaryTextDelta",
    "item/reasoning/summaryPartAdded",
    "item/reasoning/textDelta",
    "thread/compacted",
    "model/rerouted",
    "model/verification",
    "turn/moderationMetadata",
    "model/safetyBuffering/updated",
    "warning",
    "guardianWarning",
    "deprecationNotice",
    "configWarning",
    "fuzzyFileSearch/sessionUpdated",
    "fuzzyFileSearch/sessionCompleted",
    "thread/realtime/started",
    "thread/realtime/itemAdded",
    "thread/realtime/transcript/delta",
    "thread/realtime/transcript/done",
    "thread/realtime/outputAudio/delta",
    "thread/realtime/sdp",
    "thread/realtime/error",
    "thread/realtime/closed",
    "windows/worldWritableWarning",
    "windowsSandbox/setupCompleted",
    "account/login/completed",
];
const CLAUDE_AUDITED_HOOK_EVENTS: &[&str] = &[
    "SessionStart",
    "Setup",
    "InstructionsLoaded",
    "UserPromptSubmit",
    "UserPromptExpansion",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PostToolUseFailure",
    "PostToolBatch",
    "PermissionDenied",
    "Notification",
    "SubagentStart",
    "SubagentStop",
    "TaskCreated",
    "TaskCompleted",
    "Stop",
    "StopFailure",
    "TeammateIdle",
    "ConfigChange",
    "CwdChanged",
    "WorktreeCreate",
    "WorktreeRemove",
    "PreCompact",
    "PostCompact",
    "Elicitation",
    "ElicitationResult",
    "SessionEnd",
    "MessageDisplay",
    "FileChanged",
];
const PI_AUDITED_EVENTS: &[&str] = &[
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
const OPENCODE_AUDITED_PLUGIN_HOOKS: &[&str] = &[
    "event",
    "dispose",
    "config",
    "tool",
    "tool.definition",
    "auth",
    "provider",
    "chat.message",
    "chat.params",
    "chat.headers",
    "permission.ask",
    "command.execute.before",
    "tool.execute.before",
    "shell.env",
    "tool.execute.after",
    "experimental.chat.messages.transform",
    "experimental.chat.system.transform",
    "experimental.provider.small_model",
    "experimental.session.compacting",
    "experimental.compaction.autocontinue",
    "experimental.text.complete",
];
const OPENCODE_AUDITED_BUS_EVENTS: &[&str] = &[
    "server.connected",
    "server.instance.disposed",
    "global.disposed",
    "installation.updated",
    "installation.update-available",
    "project.updated",
    "project.directories.updated",
    "plugin.added",
    "integration.updated",
    "integration.connection.updated",
    "reference.updated",
    "catalog.updated",
    "models-dev.refreshed",
    "lsp.client.diagnostics",
    "lsp.updated",
    "file.edited",
    "file.watcher.updated",
    "message.updated",
    "message.removed",
    "message.part.updated",
    "message.part.delta",
    "message.part.removed",
    "permission.asked",
    "permission.updated",
    "permission.replied",
    "permission.v2.asked",
    "permission.v2.replied",
    "session.status",
    "session.idle",
    "session.compacted",
    "session.created",
    "session.updated",
    "session.deleted",
    "session.diff",
    "session.error",
    "question.asked",
    "question.replied",
    "question.rejected",
    "question.v2.asked",
    "question.v2.replied",
    "question.v2.rejected",
    "todo.updated",
    "command.executed",
    "tui.prompt.append",
    "tui.command.execute",
    "tui.toast.show",
    "tui.session.select",
    "mcp.tools.changed",
    "mcp.browser.open.failed",
    "vcs.branch.updated",
    "workspace.ready",
    "workspace.failed",
    "workspace.status",
    "worktree.ready",
    "worktree.failed",
    "pty.created",
    "pty.updated",
    "pty.exited",
    "pty.deleted",
    "session.next.agent.switched",
    "session.next.model.switched",
    "session.next.prompted",
    "session.next.prompt.admitted",
    "session.next.synthetic",
    "session.next.moved",
    "session.next.context.updated",
    "session.next.revert.staged",
    "session.next.revert.committed",
    "session.next.revert.cleared",
    "session.next.shell.started",
    "session.next.shell.ended",
    "session.next.step.started",
    "session.next.step.ended",
    "session.next.step.failed",
    "session.next.text.started",
    "session.next.text.delta",
    "session.next.text.ended",
    "session.next.reasoning.started",
    "session.next.reasoning.delta",
    "session.next.reasoning.ended",
    "session.next.tool.input.started",
    "session.next.tool.input.delta",
    "session.next.tool.input.ended",
    "session.next.tool.called",
    "session.next.tool.progress",
    "session.next.tool.success",
    "session.next.tool.failed",
    "session.next.retried",
    "session.next.compaction.started",
    "session.next.compaction.delta",
    "session.next.compaction.ended",
];

const CODEX_TASK_START_EVENTS: &[&str] = &["UserPromptSubmit"];
const CODEX_TASK_ACTIVITY_EVENTS: &[&str] = &["PreToolUse"];
const CODEX_TASK_COMPLETION_EVENTS: &[&str] = &["PostToolUse", "Stop"];
const CLAUDE_TASK_START_EVENTS: &[&str] = &["UserPromptSubmit"];
const CLAUDE_TASK_ACTIVITY_EVENTS: &[&str] = &["PreToolUse"];
const CLAUDE_TASK_COMPLETION_EVENTS: &[&str] = &[
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionDenied",
    "Stop",
    "StopFailure",
];
const PI_TASK_START_EVENTS: &[&str] = &["input", "before_agent_start", "agent_start", "turn_start"];
const PI_TASK_ACTIVITY_EVENTS: &[&str] = &["tool_call", "tool_execution_start"];
const PI_TASK_COMPLETION_EVENTS: &[&str] = &["tool_execution_end", "agent_settled"];
const OPENCODE_TASK_START_EVENTS: &[&str] = &["message.user", "session.next.prompt.admitted"];
const OPENCODE_TASK_ACTIVITY_EVENTS: &[&str] = &["tool.execute.before", "command.execute.before"];
const OPENCODE_TASK_COMPLETION_EVENTS: &[&str] = &[
    "tool.execute.after",
    "command.execute.after",
    "message.assistant",
    "session.idle",
    "session.status",
    "session.error",
    "session.next.step.ended",
    "session.next.step.failed",
];

pub(crate) fn task_evidence_events(
    source: AgentSource,
) -> (
    &'static [&'static str],
    &'static [&'static str],
    &'static [&'static str],
) {
    match source {
        AgentSource::Codex => (
            CODEX_TASK_START_EVENTS,
            CODEX_TASK_ACTIVITY_EVENTS,
            CODEX_TASK_COMPLETION_EVENTS,
        ),
        AgentSource::ClaudeCode => (
            CLAUDE_TASK_START_EVENTS,
            CLAUDE_TASK_ACTIVITY_EVENTS,
            CLAUDE_TASK_COMPLETION_EVENTS,
        ),
        AgentSource::Pi => (
            PI_TASK_START_EVENTS,
            PI_TASK_ACTIVITY_EVENTS,
            PI_TASK_COMPLETION_EVENTS,
        ),
        AgentSource::Opencode => (
            OPENCODE_TASK_START_EVENTS,
            OPENCODE_TASK_ACTIVITY_EVENTS,
            OPENCODE_TASK_COMPLETION_EVENTS,
        ),
    }
}

pub fn check_all(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    check_all_at(paths, &user_home())
}

pub fn check_all_at(paths: &AppPaths, probe_cwd: &Path) -> Vec<AgentConnectionStatus> {
    check_all_with_runtime_smoke(paths, true, probe_cwd)
}

pub fn check_all_light(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    check_all_with_runtime_smoke(paths, false, &user_home())
}

fn check_all_with_runtime_smoke(
    paths: &AppPaths,
    run_runtime_smoke: bool,
    probe_cwd: &Path,
) -> Vec<AgentConnectionStatus> {
    let cwd_access = run_runtime_smoke.then(|| check_probe_cwd_access(probe_cwd));
    let sources = [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ];
    if run_runtime_smoke {
        // Native hosts are comparatively heavy and may all cold-start Node,
        // settings discovery, project trust, and plugin loading. Running four
        // canaries at once creates deadline-sensitive false negatives and can
        // trigger several macOS protected-folder prompts simultaneously.
        return sources
            .into_iter()
            .map(|source| {
                check_source_with_runtime_smoke(paths, source, true, probe_cwd, cwd_access.as_ref())
            })
            .collect();
    }
    thread::scope(|scope| {
        let checks = sources.map(|source| {
            let cwd_access = cwd_access.clone();
            scope.spawn(move || {
                check_source_with_runtime_smoke(
                    paths,
                    source,
                    run_runtime_smoke,
                    probe_cwd,
                    cwd_access.as_ref(),
                )
            })
        });
        checks
            .into_iter()
            .map(|check| check.join().expect("connection check worker panicked"))
            .collect()
    })
}

pub fn check_source(paths: &AppPaths, source: AgentSource) -> AgentConnectionStatus {
    check_source_at(paths, source, &user_home())
}

pub fn check_source_at(
    paths: &AppPaths,
    source: AgentSource,
    probe_cwd: &Path,
) -> AgentConnectionStatus {
    let cwd_access = check_probe_cwd_access(probe_cwd);
    check_source_with_runtime_smoke(paths, source, true, probe_cwd, Some(&cwd_access))
}

fn check_source_with_runtime_smoke(
    paths: &AppPaths,
    source: AgentSource,
    run_runtime_smoke: bool,
    probe_cwd: &Path,
    shared_cwd_access: Option<&ProbeCwdAccess>,
) -> AgentConnectionStatus {
    let cli_name = cli_name(source);
    let install_root = install_root(paths, source);
    let connector_cli = connector_cli_path(paths);
    let agent_cli = agent_command_path(source);
    let override_key = agent_cli_override_key(source);
    let raw_override = std::env::var(override_key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let cli_status = if agent_cli.is_some() {
        CheckStatus::Ok
    } else {
        CheckStatus::Missing
    };
    let connector_cli_status = if connector_cli.is_file() {
        CheckStatus::Ok
    } else {
        CheckStatus::NeedsFix
    };
    let mut items = vec![
        ConnectionCheckItem::new(
            CheckCode::AgentCli,
            cli_label(source),
            cli_status,
            if let Some(path) = agent_cli.as_ref() {
                format!("命令可用：{}", path.display())
            } else if let Some(path) = raw_override.as_deref() {
                if Path::new(path).is_absolute() {
                    format!(
                        "{override_key} 已设置为 {path}，但目标不存在或不可执行；请修正或移除该覆盖后重新检查"
                    )
                } else {
                    format!(
                        "{override_key} 必须是绝对可执行文件路径，当前为 {path}；请修正或移除后重新检查"
                    )
                }
            } else {
                format!("未在 PATH 与常用本地安装目录中检测到 {cli_name}")
            },
            Some(RecoveryAction::Recheck),
        ),
        ConnectionCheckItem::new(
            CheckCode::EventCli,
            "本地事件 CLI",
            connector_cli_status,
            if connector_cli_status == CheckStatus::Ok {
                connector_cli.display().to_string()
            } else {
                format!("未检测到 {}", connector_cli.display())
            },
            Some(RecoveryAction::Recheck),
        ),
    ];
    let cwd_access = if run_runtime_smoke {
        shared_cwd_access
            .cloned()
            .unwrap_or_else(|| check_probe_cwd_access(probe_cwd))
    } else {
        ProbeCwdAccess {
            item: ConnectionCheckItem::new(
                CheckCode::ProjectDirectory,
                "检查目录访问",
                CheckStatus::Unverified,
                "完整检查会从 App/PetCore 责任链验证所选目录的真实访问权限",
                Some(RecoveryAction::ChooseProjectDirectory),
            ),
            resolved_cwd: None,
        }
    };
    let cwd_access_ok = cwd_access.item.status == CheckStatus::Ok;
    let runtime_processes_allowed = run_runtime_smoke && cwd_access_ok;
    let runtime_probe_cwd = cwd_access
        .resolved_cwd
        .clone()
        .unwrap_or_else(|| probe_cwd.to_path_buf());
    items.push(cwd_access.item.clone());
    items.push(check_agent_cli_version(
        source,
        agent_cli.as_deref(),
        runtime_processes_allowed,
    ));

    let (repairable_connector_issue, managed_path_conflict, host_connector_installed) = match source
    {
        AgentSource::Codex => {
            let root_state = codex_managed_root_state(&install_root);
            let managed_root_state = if root_state == ManagedPathState::Safe
                && validate_codex_root_repair_ownership(&install_root).is_err()
            {
                ManagedPathState::Conflict
            } else {
                root_state
            };
            let root_check =
                check_managed_connector_root(&install_root, "连接器目录", managed_root_state);
            let manifest_check = check_codex_plugin_manifest(
                &install_root.join(".codex-plugin/plugin.json"),
                &install_root,
            );
            let hooks_check = check_codex_hooks(
                &install_root.join("hooks/hooks.json"),
                &connector_cli,
                &install_root,
            );
            let studio_check = check_codex_studio_skill(
                &install_root.join("skills/agent-pet-studio/SKILL.md"),
                &install_root,
            );
            let maker_check = check_codex_agent_pet_maker(&install_root);
            let marketplace_check = check_codex_marketplace_entry();
            let managed_path_conflict = managed_root_state == ManagedPathState::Conflict
                || codex_marketplace_entry_state(&codex_marketplace_path())
                    == CodexMarketplaceEntryState::Conflict;
            let repairable_connector_issue = has_repairable_managed_connector_issue(
                managed_path_conflict,
                &[
                    &manifest_check,
                    &hooks_check,
                    &studio_check,
                    &maker_check,
                    &marketplace_check,
                ],
            );
            let static_connector_ready = [
                &root_check,
                &manifest_check,
                &hooks_check,
                &studio_check,
                &maker_check,
                &marketplace_check,
            ]
            .into_iter()
            .all(|item| item.status == CheckStatus::Ok);
            items.extend([
                root_check,
                manifest_check,
                hooks_check,
                studio_check,
                maker_check,
                marketplace_check,
            ]);
            let plugin_install_check = if runtime_processes_allowed {
                check_codex_plugin_installed()
            } else {
                check_codex_plugin_installed_light(&install_root)
            };
            let host_connector_installed = plugin_install_check.status == CheckStatus::Ok;
            items.push(plugin_install_check);
            items.push(if run_runtime_smoke {
                exact_connector_gated_native_host_check(
                    static_connector_ready,
                    cwd_access_ok,
                    CheckCode::HostVerification,
                    RecoveryAction::Recheck,
                    "Codex Hook Trust",
                    || check_codex_hook_trust(&runtime_probe_cwd),
                )
            } else {
                check_codex_hook_trust_light(&install_root)
            });
            items.push(check_event_channel(paths, &connector_cli));
            items.push(if !static_connector_ready {
                skipped_inexact_connector_check(
                    CheckCode::AppServer,
                    RecoveryAction::Recheck,
                    "Codex App Server",
                )
            } else if runtime_processes_allowed {
                check_codex_app_server()
            } else if run_runtime_smoke {
                skipped_external_process_check(
                    CheckCode::AppServer,
                    RecoveryAction::Recheck,
                    "Codex App Server",
                )
            } else {
                check_codex_app_server_light()
            });
            (
                repairable_connector_issue,
                managed_path_conflict,
                host_connector_installed,
            )
        }
        AgentSource::ClaudeCode => {
            let root_state = claude_managed_root_state(&install_root);
            let managed_root_state = if root_state == ManagedPathState::Safe
                && validate_claude_root_repair_ownership(&install_root, &connector_cli).is_err()
            {
                ManagedPathState::Conflict
            } else {
                root_state
            };
            let root_check =
                check_managed_connector_root(&install_root, "连接器目录", managed_root_state);
            let fragment_check = check_claude_fragment(
                &install_root.join("settings.fragment.json"),
                &connector_cli,
                &install_root,
            );
            let helper_check = check_claude_hook(
                &install_root.join("agent-pet-companion-hook.sh"),
                &connector_cli,
            );
            let settings_check = check_claude_settings(&connector_cli, &install_root);
            let managed_path_conflict = managed_root_state == ManagedPathState::Conflict
                || config_file_path_state(&claude_settings_path()) == ManagedPathState::Conflict;
            let repairable_connector_issue = has_repairable_managed_connector_issue(
                managed_path_conflict,
                &[&fragment_check, &helper_check, &settings_check],
            );
            let static_connector_ready =
                [&root_check, &fragment_check, &helper_check, &settings_check]
                    .into_iter()
                    .all(|item| item.status == CheckStatus::Ok);
            items.extend([root_check, fragment_check, helper_check]);
            items.push(check_claude_auth_status(runtime_processes_allowed));
            items.push(check_claude_hooks_policy());
            items.push(settings_check);
            items.push(check_event_channel(paths, &connector_cli));
            items.push(if run_runtime_smoke {
                exact_connector_gated_native_host_check(
                    static_connector_ready,
                    cwd_access_ok,
                    CheckCode::HostVerification,
                    RecoveryAction::Recheck,
                    "Claude Hook 真实触发",
                    || check_claude_hook_runtime(paths, &runtime_probe_cwd),
                )
            } else {
                ConnectionCheckItem::new(
                    CheckCode::HostVerification,
                    "Claude Hook 真实触发",
                    CheckStatus::Unverified,
                    "点击检查后将运行不调用模型的 --init-only canary",
                    Some(RecoveryAction::Recheck),
                )
            });
            (repairable_connector_issue, managed_path_conflict, false)
        }
        AgentSource::Pi => {
            let root_state = pi_managed_root_state(&install_root);
            let root_check =
                check_managed_connector_root(&install_root, "Extension 目录", root_state);
            let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
            let extension_path = install_root.join("agent-pet-companion.ts");
            let extension_ownership =
                managed_connector_script_ownership(&extension_path, AgentSource::Pi);
            let extension_check = check_exact_connector_file(
                &extension_path,
                "Extension",
                expected.as_bytes(),
                AgentSource::Pi,
            );
            let managed_path_conflict = root_state == ManagedPathState::Conflict
                || extension_ownership == ManagedConnectorScriptOwnership::Foreign;
            let repairable_connector_issue =
                has_repairable_managed_connector_issue(managed_path_conflict, &[&extension_check]);
            let static_connector_ready =
                root_check.status == CheckStatus::Ok && extension_check.status == CheckStatus::Ok;
            items.extend([root_check, extension_check]);
            items.push(check_event_channel(paths, &connector_cli));
            if run_runtime_smoke {
                items.push(exact_connector_gated_native_host_check(
                    static_connector_ready,
                    cwd_access_ok,
                    CheckCode::HostRuntime,
                    RecoveryAction::Recheck,
                    "Extension 运行时",
                    || check_pi_extension_runtime(paths, &install_root, &runtime_probe_cwd),
                ));
            }
            (repairable_connector_issue, managed_path_conflict, false)
        }
        AgentSource::Opencode => {
            let root_state = opencode_managed_root_state(&install_root);
            let root_check = check_managed_connector_root(&install_root, "Plugin 目录", root_state);
            let expected = render_connector_script(OPENCODE_PLUGIN_TEMPLATE, &connector_cli);
            let plugin_path = install_root.join("agent-pet-companion.js");
            let plugin_ownership =
                managed_connector_script_ownership(&plugin_path, AgentSource::Opencode);
            let plugin_check = check_exact_connector_file(
                &plugin_path,
                "Plugin",
                expected.as_bytes(),
                AgentSource::Opencode,
            );
            let managed_path_conflict = root_state == ManagedPathState::Conflict
                || plugin_ownership == ManagedConnectorScriptOwnership::Foreign;
            let repairable_connector_issue =
                has_repairable_managed_connector_issue(managed_path_conflict, &[&plugin_check]);
            let static_connector_ready =
                root_check.status == CheckStatus::Ok && plugin_check.status == CheckStatus::Ok;
            items.extend([root_check, plugin_check]);
            items.push(if static_connector_ready {
                check_opencode_server(runtime_processes_allowed)
            } else {
                skipped_inexact_connector_check(
                    CheckCode::HostServer,
                    RecoveryAction::Recheck,
                    "OpenCode Server",
                )
            });
            items.push(check_event_channel(paths, &connector_cli));
            if run_runtime_smoke {
                items.push(exact_connector_gated_native_host_check(
                    static_connector_ready,
                    cwd_access_ok,
                    CheckCode::HostRuntime,
                    RecoveryAction::Recheck,
                    "Plugin 运行时",
                    || check_opencode_plugin_runtime(paths, &install_root, &runtime_probe_cwd),
                ));
            }
            (repairable_connector_issue, managed_path_conflict, false)
        }
    };
    if runtime_processes_allowed {
        items.push(check_event_roundtrip(paths, &connector_cli, source));
    } else if run_runtime_smoke {
        items.push(skipped_external_process_check(
            CheckCode::ChannelTest,
            RecoveryAction::TestChannel,
            "PetCore 通道自检",
        ));
    }

    let install_paths = connection_install_paths(paths, source);

    let verification = if run_runtime_smoke {
        verification_for_source(paths, source, &items, true, &runtime_probe_cwd)
    } else {
        static_light_verification(source, &items, &runtime_probe_cwd)
    };
    let connector_installed =
        connector_artifacts_present(paths, source) || host_connector_installed;
    let mut capabilities = capabilities_for_source(source);
    capabilities.repairable_connector_issue = Some(repairable_connector_issue);
    capabilities.managed_path_conflict = Some(managed_path_conflict);
    capabilities.can_uninstall_managed_connector =
        Some(connector_installed && !managed_path_conflict);
    AgentConnectionStatus {
        source,
        items,
        install_paths,
        connector_installed,
        verification,
        capabilities,
        check_mode: if run_runtime_smoke {
            ConnectionCheckMode::Runtime
        } else {
            ConnectionCheckMode::Light
        },
        checked_at: now_rfc3339(),
    }
}

fn check_probe_cwd_access(probe_cwd: &Path) -> ProbeCwdAccess {
    if !probe_cwd.is_absolute() {
        return ProbeCwdAccess {
            item: ConnectionCheckItem::new(
                CheckCode::ProjectDirectory,
                "检查目录访问",
                CheckStatus::NeedsFix,
                "检查目录必须是绝对路径；未启动任何 Agent 宿主探针，也不会改用其他目录",
                Some(RecoveryAction::ChooseProjectDirectory),
            ),
            resolved_cwd: None,
        };
    }

    // `Command::current_dir` and in-process canonicalize/getcwd can themselves
    // block behind macOS TCC or a stalled filesystem. Keep every operation that
    // touches the selected directory inside the owned, bounded child instead.
    let result = run_bounded(ProcessSpec::new(
        "/bin/sh",
        vec![
            OsString::from("-c"),
            OsString::from("cd -P -- \"$1\" && exec /bin/pwd -P"),
            OsString::from("apc-cwd-probe"),
            probe_cwd.as_os_str().to_os_string(),
        ],
        PROBE_CWD_ACCESS_TIMEOUT,
    ));
    let resolved = result.as_ref().ok().and_then(|output| {
        (!output.timed_out && output.status.success())
            .then(|| physical_cwd_from_pwd_output(&output.stdout))
            .flatten()
    });
    let status = if resolved.is_some() {
        CheckStatus::Ok
    } else {
        CheckStatus::NeedsFix
    };
    let detail = if status == CheckStatus::Ok {
        format!(
            "PetCore 后台服务派生进程可解析检查目录：{}",
            resolved.as_deref().unwrap_or(probe_cwd).display()
        )
    } else if result.as_ref().is_ok_and(|output| output.timed_out) {
        format!(
            "PetCore 后台服务派生进程在 {} 秒内无法解析检查目录；若目录位于“桌面/文稿/下载”，请在“系统设置 → 隐私与安全性 → 文件与文件夹”中允许 AgentPetCompanion（以及系统单列时的后台 helper）访问对应文件夹，或选择已授权目录；改选目录不会代表原项目已验证",
            PROBE_CWD_ACCESS_TIMEOUT.as_secs()
        )
    } else if let Ok(output) = result.as_ref() {
        format!(
            "PetCore 后台服务派生进程无法进入或精确解析检查目录（exit={:?}）；请检查目录权限，或在 macOS 文件与文件夹隐私设置中授权 AgentPetCompanion/系统单列的后台 helper",
            output.status.code()
        )
    } else {
        "无法启动检查目录访问预检；请确认 /bin/pwd 可执行并检查 macOS 文件与文件夹权限".to_string()
    };
    ProbeCwdAccess {
        item: ConnectionCheckItem::new(
            CheckCode::ProjectDirectory,
            "检查目录访问",
            status,
            detail,
            Some(RecoveryAction::ChooseProjectDirectory),
        ),
        resolved_cwd: resolved,
    }
}

fn physical_cwd_from_pwd_output(stdout: &[u8]) -> Option<PathBuf> {
    let mut bytes = stdout.to_vec();
    while matches!(bytes.last(), Some(b'\n' | b'\r')) {
        bytes.pop();
    }
    if bytes.is_empty() || bytes.contains(&0) {
        return None;
    }
    let path = PathBuf::from(OsString::from_vec(bytes));
    path.is_absolute().then_some(path)
}

fn skipped_native_host_check(
    code: CheckCode,
    recovery_action: RecoveryAction,
    name: &str,
) -> ConnectionCheckItem {
    ConnectionCheckItem::new(
        code,
        name,
        CheckStatus::Unverified,
        "检查目录访问未通过，因此未启动 Agent 宿主；不会改用其他目录冒充当前项目已验证",
        Some(recovery_action),
    )
}

fn skipped_external_process_check(
    code: CheckCode,
    recovery_action: RecoveryAction,
    name: &str,
) -> ConnectionCheckItem {
    ConnectionCheckItem::new(
        code,
        name,
        CheckStatus::Unverified,
        "检查目录访问未通过，因此未启动任何 Agent CLI、App Server 或事件 CLI 子进程；不会改用 HOME 或其他目录冒充当前项目已验证",
        Some(recovery_action),
    )
}

fn skipped_inexact_connector_check(
    code: CheckCode,
    recovery_action: RecoveryAction,
    name: &str,
) -> ConnectionCheckItem {
    ConnectionCheckItem::new(
        code,
        name,
        CheckStatus::Unverified,
        "当前受管连接器文件、配置或目录未通过精确所有权校验，因此未启动 Agent 宿主；请先处理对应缺失、旧版本或路径冲突项",
        Some(recovery_action),
    )
}

fn cwd_gated_native_host_check(
    cwd_access_ok: bool,
    code: CheckCode,
    recovery_action: RecoveryAction,
    name: &str,
    check: impl FnOnce() -> ConnectionCheckItem,
) -> ConnectionCheckItem {
    if cwd_access_ok {
        check()
    } else {
        skipped_native_host_check(code, recovery_action, name)
    }
}

fn exact_connector_gated_native_host_check(
    exact_connector_ready: bool,
    cwd_access_ok: bool,
    code: CheckCode,
    recovery_action: RecoveryAction,
    name: &str,
    check: impl FnOnce() -> ConnectionCheckItem,
) -> ConnectionCheckItem {
    if !exact_connector_ready {
        skipped_inexact_connector_check(code, recovery_action, name)
    } else {
        cwd_gated_native_host_check(cwd_access_ok, code, recovery_action, name, check)
    }
}

fn verification_guidance(source: AgentSource) -> (&'static str, &'static str, &'static str) {
    match source {
        AgentSource::Codex => (
            "Codex Hook Trust",
            "Codex Hook 信任与真实回传",
            "在当前任务使用的 Codex/ChatGPT 宿主中审查并信任 Agent Pet Companion Hooks，然后重新检查。",
        ),
        AgentSource::ClaudeCode => (
            "Claude Hook 真实触发",
            "Claude Hooks 配置与真实触发",
            "不要使用 --safe-mode 或 --bare；可在 Claude Code 中用 /hooks 查看有效 Hooks，再重新检查。",
        ),
        AgentSource::Pi => (
            "Extension 运行时",
            "Pi Extension 宿主加载",
            "重启 Pi 以重新加载全局 Extension，然后重新检查；项目级 Extension 还需遵循 Pi 的 project trust。使用 --no-extensions/-ne 的单次启动会明确绕过此连接器。",
        ),
        AgentSource::Opencode => (
            "Plugin 运行时",
            "OpenCode Plugin 宿主加载",
            "重启 OpenCode 以重新加载全局 Plugin，然后重新检查。使用 --pure 的单次启动会明确绕过外部 Plugin。",
        ),
    }
}

fn static_light_verification(
    source: AgentSource,
    items: &[ConnectionCheckItem],
    probe_cwd: &Path,
) -> AgentVerification {
    let (_, title, action_detail) = verification_guidance(source);
    let first_action_required = items
        .iter()
        .filter(|item| verification_requires_item(source, item))
        .find(|item| {
            matches!(
                item.status,
                CheckStatus::Missing | CheckStatus::NeedsFix | CheckStatus::Unsupported
            )
        });
    let status = if first_action_required.is_some() {
        AgentVerificationStatus::ActionRequired
    } else {
        AgentVerificationStatus::Unverified
    };
    AgentVerification {
        status,
        title: title.to_string(),
        detail: first_action_required.map_or_else(
            || "轻量检查只确认本地文件；点击“检查”后才会执行无模型调用的宿主侧验证。".to_string(),
            |item| format!("{}：{}", item.name, item.detail),
        ),
        last_verified_at: None,
        last_event: None,
        action_detail: Some(first_action_required.map_or_else(
            || action_detail.to_string(),
            |item| format!("请处理「{}」：{}", item.name, item.detail),
        )),
        checked_cwd: Some(probe_cwd.display().to_string()),
    }
}

fn verification_for_source(
    paths: &AppPaths,
    source: AgentSource,
    items: &[ConnectionCheckItem],
    run_runtime_smoke: bool,
    probe_cwd: &Path,
) -> AgentVerification {
    let receipt_freshness = ConnectorReceiptFreshness::load(paths, source);
    verification_for_source_with_freshness(
        paths,
        source,
        items,
        run_runtime_smoke,
        probe_cwd,
        &receipt_freshness,
    )
}

fn verification_for_source_with_freshness(
    paths: &AppPaths,
    source: AgentSource,
    items: &[ConnectionCheckItem],
    run_runtime_smoke: bool,
    probe_cwd: &Path,
    receipt_freshness: &ConnectorReceiptFreshness,
) -> AgentVerification {
    let database = Database::new(&paths.db_path);
    let contract_version = contract_version_for_source(source);
    let (task_starts, task_activities, task_completions) = task_evidence_events(source);
    let ConnectorEvidenceSummary {
        observed_receipt,
        ordinary_receipt,
        diagnostic_receipt,
        real_start_receipt,
        task_receipt,
        newer_stale_receipt,
    } = database
        .connector_evidence_summary(
            source,
            contract_version,
            task_starts,
            task_activities,
            task_completions,
        )
        .unwrap_or_default();
    let observed_receipt = observed_receipt.filter(|receipt| receipt_freshness.is_current(receipt));
    let ordinary_receipt = ordinary_receipt.filter(|receipt| receipt_freshness.is_current(receipt));
    let diagnostic_receipt =
        diagnostic_receipt.filter(|receipt| receipt_freshness.is_current(receipt));
    let real_start_receipt =
        real_start_receipt.filter(|receipt| receipt_freshness.is_current(receipt));
    let task_receipt = task_receipt.filter(|receipt| {
        receipt_freshness.is_current(&receipt.start)
            && receipt_freshness.is_current(&receipt.activity)
            && receipt_freshness.is_current(&receipt.completion)
    });

    let (check_name, title, action_detail) = verification_guidance(source);

    let required_items = items
        .iter()
        .filter(|item| verification_requires_item(source, item))
        .collect::<Vec<_>>();
    // A historical receipt never overrides a failure from the current native
    // host probe. Project trust, launch flags, or policy may have changed since
    // that receipt was recorded.
    let item_effectively_ok = |item: &ConnectionCheckItem| item.status == CheckStatus::Ok;
    let first_action_required = required_items.iter().copied().find(|item| {
        !item_effectively_ok(item)
            && matches!(
                item.status,
                CheckStatus::Missing | CheckStatus::NeedsFix | CheckStatus::Unsupported
            )
    });
    let first_unverified = required_items
        .iter()
        .copied()
        .find(|item| !item_effectively_ok(item) && item.status == CheckStatus::Unverified);
    let required_items_ok =
        !required_items.is_empty() && required_items.iter().all(|item| item_effectively_ok(item));

    let has_current_host_receipt = match source {
        // Codex exposes an authoritative, machine-readable hooks/list trust
        // result. The other hosts are verified by a connector event emitted by
        // the current installed contract during their native-host canary.
        AgentSource::Codex => true,
        AgentSource::ClaudeCode | AgentSource::Pi | AgentSource::Opencode => {
            observed_receipt.is_some() || diagnostic_receipt.is_some()
        }
    };
    let has_current_ordinary_receipt =
        has_required_ordinary_task_evidence(source, ordinary_receipt.is_some());
    let verified = run_runtime_smoke
        && required_items_ok
        && has_current_host_receipt
        && has_current_ordinary_receipt
        && newer_stale_receipt.is_none();
    let status = if verified {
        AgentVerificationStatus::Verified
    } else if first_action_required.is_some() || newer_stale_receipt.is_some() {
        AgentVerificationStatus::ActionRequired
    } else {
        AgentVerificationStatus::Unverified
    };

    let last_verified_at = if verified {
        ordinary_receipt
            .as_ref()
            .or(diagnostic_receipt.as_ref())
            .map(|receipt| receipt.created_at.clone())
            .or_else(|| Some(now_rfc3339()))
    } else {
        ordinary_receipt
            .as_ref()
            .or(observed_receipt.as_ref())
            .map(|receipt| receipt.created_at.clone())
    };
    let last_event = task_receipt
        .as_ref()
        .map(|receipt| {
            format!(
                "{} → {} → {}",
                receipt.start.source_event,
                receipt.activity.source_event,
                receipt.completion.source_event
            )
        })
        .or_else(|| {
            ordinary_receipt
                .as_ref()
                .map(|receipt| receipt.source_event.clone())
        })
        .or_else(|| {
            observed_receipt
                .as_ref()
                .map(|receipt| format!("{} (passive)", receipt.source_event))
        })
        .or_else(|| {
            diagnostic_receipt
                .as_ref()
                .map(|receipt| format!("{} (canary)", receipt.source_event))
        });

    let stale_host_detail = newer_stale_receipt.as_ref().map(|receipt| {
        format!(
            "检测到更晚的旧/未知契约事件 {}（契约：{}）；至少一个已开启的 {} 宿主仍加载旧连接器，请重启该宿主后重新检查。",
            receipt.source_event,
            receipt.contract_version.as_deref().unwrap_or("未报告"),
            source.display_name()
        )
    });
    let detail = if verified {
        if let Some(receipt) = task_receipt.as_ref() {
            format!(
                "宿主侧验证通过（检查目录：{}）；已收到同一会话的真实任务证据 {} → {} → {}。回执不携带可靠项目范围，不会被外推为其他目录的策略结论。",
                probe_cwd.display(), receipt.start.source_event, receipt.activity.source_event,
                receipt.completion.source_event
            )
        } else if let Some(receipt) = ordinary_receipt.as_ref() {
            format!(
                "宿主侧验证通过（检查目录：{}）；已收到普通事件 {}，但尚未形成同会话 prompt → tool → completion 的完整任务证据。",
                probe_cwd.display(), receipt.source_event
            )
        } else {
            format!(
                "宿主侧加载与无模型活动 canary 已通过（检查目录：{}）；尚未收到用户真实任务的 prompt 回执，也未形成同会话 prompt → tool → completion 证据。",
                probe_cwd.display()
            )
        }
    } else if !run_runtime_smoke {
        "轻量检查只确认本地文件；点击“检查”后才会执行无模型调用的宿主侧验证。".to_string()
    } else if let Some(item) = first_action_required {
        let item_detail = format!("{}：{}", item.name, item.detail);
        stale_host_detail
            .as_ref()
            .map(|stale| format!("{item_detail} 同时，{stale}"))
            .unwrap_or(item_detail)
    } else if let Some(stale) = stale_host_detail.as_ref() {
        stale.clone()
    } else if let Some(item) = first_unverified {
        format!("{}：{}", item.name, item.detail)
    } else if required_items_ok
        && has_current_host_receipt
        && ordinary_receipt.is_none()
        && newer_stale_receipt.is_none()
    {
        format!(
            "宿主加载证据已通过（检查目录：{}），但尚未收到当前契约的普通任务活动事件；因此保持“待验证”，不会把 canary、会话创建或关闭事件冒充真实任务接通。",
            probe_cwd.display()
        )
    } else if !has_current_host_receipt {
        "宿主检查未产生当前连接器契约且晚于安装文件的回执；不会沿用旧 canary。".to_string()
    } else {
        items
            .iter()
            .find(|item| item.name == check_name)
            .map(|item| item.detail.clone())
            .unwrap_or_else(|| "尚未获得 Agent 宿主加载或真实 Hook 回执证据。".to_string())
    };
    let detail = if verified {
        match source {
            AgentSource::ClaudeCode => {
                format!("{detail} 注意：--safe-mode/--bare 单次启动会绕过 Hooks。")
            }
            AgentSource::Pi => {
                format!("{detail} 注意：--no-extensions/-ne 单次启动会绕过 Extension。")
            }
            AgentSource::Opencode => {
                format!("{detail} 注意：--pure 单次启动会绕过外部 Plugin。")
            }
            AgentSource::Codex => detail,
        }
    } else {
        detail
    };

    AgentVerification {
        status,
        title: title.to_string(),
        detail,
        last_verified_at,
        last_event,
        action_detail: if has_current_host_receipt
            && ordinary_receipt.is_none()
            && newer_stale_receipt.is_none()
        {
            match source {
                AgentSource::Codex => None,
                AgentSource::ClaudeCode => Some(
                    "当前只有宿主加载或被动生命周期回执。请重启所有已打开的 Claude Code 会话以重新加载 Hooks，再运行一条真实任务；收到 UserPromptSubmit 后这里会显示普通任务回执。"
                        .to_string(),
                ),
                AgentSource::Pi => Some(
                    "当前只有宿主加载或被动生命周期回执。请重启所有已打开的 Pi 会话以重新加载 Extension，再运行一条真实任务；收到 input/before_agent_start 后这里会显示普通任务回执。"
                        .to_string(),
                ),
                AgentSource::Opencode => Some(
                    "当前只有宿主加载或被动生命周期回执。请重启所有已打开的 OpenCode 会话以重新加载 Plugin，再运行一条真实任务；attach/run --attach 模式还必须确保目标 server 进程加载了该 Plugin。"
                        .to_string(),
                ),
            }
        } else if verified && task_receipt.is_none() {
            Some(if real_start_receipt.is_some() {
                format!(
                    "普通任务开始事件已接通，但尚未形成同一会话的 start → activity → completion 完整证据。请在 {} 中完成一条会使用工具的任务后重新检查。",
                    source.display_name()
                )
            } else {
                format!(
                    "已收到普通宿主事件，但还没有当前契约的任务开始回执。请在 {} 中运行一条普通任务，再重新检查完整生命周期。",
                    source.display_name()
                )
            })
        } else if verified {
            None
        } else if let Some(item) = first_action_required {
            let item_action = format!("请处理「{}」：{}", item.name, item.detail);
            if newer_stale_receipt.is_some() {
                Some(format!(
                    "{item_action} 完成后请重启所有已开启的 {} 宿主，使其重新加载当前连接器，再重新检查。",
                    source.display_name()
                ))
            } else {
                Some(item_action)
            }
        } else if newer_stale_receipt.is_some() {
            Some(format!(
                "请重启所有已开启的 {} 宿主，使其重新加载当前连接器后再检查。",
                source.display_name()
            ))
        } else if let Some(item) = first_unverified {
            Some(format!("请处理「{}」：{}", item.name, item.detail))
        } else {
            Some(action_detail.to_string())
        },
        checked_cwd: Some(probe_cwd.display().to_string()),
    }
}

/// Rebuilds only the database-backed evidence projection for a previously
/// checked status. This never launches an Agent host and deliberately keeps
/// the original `checked_at`, so a snapshot cannot extend runtime freshness.
pub(crate) fn project_connection_evidence(
    paths: &AppPaths,
    status: &AgentConnectionStatus,
) -> AgentConnectionStatus {
    let freshness = ConnectorReceiptFreshness::load(paths, status.source);
    let probe_cwd = status
        .verification
        .checked_cwd
        .as_deref()
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(user_home);
    let mut projected = status.clone();
    projected.verification = verification_for_source_with_freshness(
        paths,
        status.source,
        &status.items,
        status.check_mode == ConnectionCheckMode::Runtime,
        &probe_cwd,
        &freshness,
    );
    if status.source == AgentSource::Codex
        && projected.verification.status == AgentVerificationStatus::Verified
        && projected.verification.last_event.is_none()
    {
        projected.verification.last_verified_at = status
            .verification
            .last_verified_at
            .clone()
            .or_else(|| Some(status.checked_at.clone()));
    }
    projected
}

fn has_required_ordinary_task_evidence(source: AgentSource, ordinary_event_seen: bool) -> bool {
    // hooks/list is an authoritative trust/configuration check for the exact
    // Codex host version. Other hosts need a non-diagnostic event from the
    // currently installed contract before the UI may call the task connection
    // verified. A diagnostic canary proves only host loading and routing.
    source == AgentSource::Codex || ordinary_event_seen
}

fn verification_requires_item(source: AgentSource, item: &ConnectionCheckItem) -> bool {
    match item.code {
        CheckCode::AgentCli
        | CheckCode::EventCli
        | CheckCode::ProjectDirectory
        | CheckCode::AgentVersion
        | CheckCode::EventDelivery
        | CheckCode::ChannelTest => true,
        CheckCode::ManagedConnector | CheckCode::ClaudeHooksPolicy => true,
        CheckCode::HostRuntime => matches!(source, AgentSource::Pi | AgentSource::Opencode),
        CheckCode::HostVerification => {
            matches!(source, AgentSource::Codex | AgentSource::ClaudeCode)
        }
        CheckCode::AppServer | CheckCode::HostServer | CheckCode::Unknown => false,
    }
}

/// Immutable freshness facts shared by every receipt in one evidence
/// projection. Exact artifact validation can hash/read several connector
/// files, so doing it once prevents a complete static re-check for each of the
/// observed, ordinary, diagnostic, start, and task-edge receipts.
struct ConnectorReceiptFreshness {
    contract_version: &'static str,
    installation_exact: bool,
    artifact_mtimes: Option<Vec<i128>>,
}

#[cfg(test)]
std::thread_local! {
    static CONNECTOR_RECEIPT_FRESHNESS_LOAD_COUNT: std::cell::Cell<usize> = const {
        std::cell::Cell::new(0)
    };
}

#[cfg(test)]
pub(crate) fn reset_connector_receipt_freshness_load_count() {
    CONNECTOR_RECEIPT_FRESHNESS_LOAD_COUNT.with(|count| count.set(0));
}

#[cfg(test)]
pub(crate) fn connector_receipt_freshness_load_count() -> usize {
    CONNECTOR_RECEIPT_FRESHNESS_LOAD_COUNT.with(std::cell::Cell::get)
}

impl ConnectorReceiptFreshness {
    fn load(paths: &AppPaths, source: AgentSource) -> Self {
        #[cfg(test)]
        CONNECTOR_RECEIPT_FRESHNESS_LOAD_COUNT.with(|count| count.set(count.get() + 1));
        let installation_exact =
            managed_connector_artifacts_match_current_installation(paths, source);
        let artifact_mtimes = installation_exact
            .then(|| managed_connector_artifact_mtimes(paths, source))
            .flatten();
        Self {
            contract_version: contract_version_for_source(source),
            installation_exact,
            artifact_mtimes,
        }
    }

    fn is_current(&self, receipt: &crate::db::ConnectorEventReceipt) -> bool {
        if receipt.contract_version.as_deref() != Some(self.contract_version)
            || !self.installation_exact
        {
            return false;
        }
        let Ok(received_at) = OffsetDateTime::parse(&receipt.created_at, &Rfc3339) else {
            return false;
        };
        self.artifact_mtimes.as_ref().is_some_and(|modified_at| {
            modified_at
                .iter()
                .all(|modified_at| received_at.unix_timestamp_nanos() >= *modified_at)
        })
    }
}

pub(crate) fn connector_receipt_is_current(
    paths: &AppPaths,
    source: AgentSource,
    receipt: &crate::db::ConnectorEventReceipt,
) -> bool {
    // A matching contract and timestamp are evidence only for the exact
    // connector installation that produced them. Never let an older mtime,
    // preserved timestamp, or symlink make a tampered installation current.
    ConnectorReceiptFreshness::load(paths, source).is_current(receipt)
}

#[cfg(test)]
pub(crate) fn cached_connection_status_is_current(
    paths: &AppPaths,
    status: &AgentConnectionStatus,
) -> bool {
    let freshness = ConnectorReceiptFreshness::load(paths, status.source);
    cached_connection_status_is_current_with_freshness_at(
        paths,
        status,
        OffsetDateTime::now_utc(),
        &freshness,
    )
}

/// Fast runtime-cache admission after the current light projection has passed
/// for the same `connection_light_cache_revision`. That revision includes
/// inode, mode, size, mtime, and ctime for every leaf/target plus ancestor
/// identities, so ordinary writes (even with restored mtime) force a cold
/// exact light scan. Evidence projection misses still perform their own one
/// exact freshness load before accepting receipts.
pub(crate) fn cached_connection_status_is_current_for_light_projection(
    paths: &AppPaths,
    status: &AgentConnectionStatus,
) -> bool {
    let Some(checked_at) =
        cached_connection_status_base_checked_at(paths, status, OffsetDateTime::now_utc())
    else {
        return false;
    };
    managed_connector_artifact_mtimes(paths, status.source).is_some_and(|modified_at| {
        modified_at
            .into_iter()
            .all(|modified_at| modified_at <= checked_at.unix_timestamp_nanos())
    }) && resolved_agent_cli_metadata_predates(status.source, checked_at)
}

fn resolved_agent_cli_metadata_predates(source: AgentSource, checked_at: OffsetDateTime) -> bool {
    let Some(path) = agent_command_path(source) else {
        return false;
    };
    let Ok(leaf) = fs::symlink_metadata(&path) else {
        return false;
    };
    if !leaf.is_file() && !leaf.file_type().is_symlink() {
        return false;
    }
    let Ok(target) = fs::metadata(path) else {
        return false;
    };
    if !target.is_file() || target.permissions().mode() & 0o111 == 0 {
        return false;
    }
    let checked_at = checked_at.unix_timestamp_nanos();
    [leaf, target]
        .into_iter()
        .all(|metadata| metadata_timestamps_predate(&metadata, checked_at))
}

fn metadata_timestamps_predate(metadata: &std::fs::Metadata, checked_at: i128) -> bool {
    [
        (metadata.mtime(), metadata.mtime_nsec()),
        (metadata.ctime(), metadata.ctime_nsec()),
    ]
    .into_iter()
    .all(|(seconds, nanoseconds)| {
        (0..1_000_000_000).contains(&nanoseconds)
            && i128::from(seconds)
                .checked_mul(1_000_000_000)
                .and_then(|value| value.checked_add(i128::from(nanoseconds)))
                .is_some_and(|timestamp| timestamp <= checked_at)
    })
}

#[cfg(test)]
fn cached_connection_status_is_current_at(
    paths: &AppPaths,
    status: &AgentConnectionStatus,
    now: OffsetDateTime,
) -> bool {
    let freshness = ConnectorReceiptFreshness::load(paths, status.source);
    cached_connection_status_is_current_with_freshness_at(paths, status, now, &freshness)
}

#[cfg(test)]
fn cached_connection_status_is_current_with_freshness_at(
    paths: &AppPaths,
    status: &AgentConnectionStatus,
    now: OffsetDateTime,
    freshness: &ConnectorReceiptFreshness,
) -> bool {
    let Some(checked_at) = cached_connection_status_base_checked_at(paths, status, now) else {
        return false;
    };
    if !freshness.installation_exact {
        return false;
    }
    freshness
        .artifact_mtimes
        .as_ref()
        .is_some_and(|modified_at| {
            modified_at
                .iter()
                .all(|modified_at| *modified_at <= checked_at.unix_timestamp_nanos())
        })
}

fn cached_connection_status_base_checked_at(
    paths: &AppPaths,
    status: &AgentConnectionStatus,
    now: OffsetDateTime,
) -> Option<OffsetDateTime> {
    if status.check_mode != ConnectionCheckMode::Runtime
        || status.capabilities.contract_version != contract_version_for_source(status.source)
        || status.install_paths != connection_install_paths(paths, status.source)
    {
        return None;
    }
    if status.source != AgentSource::Codex
        && status.verification.status == AgentVerificationStatus::Verified
        && status
            .verification
            .last_event
            .as_deref()
            .is_none_or(|event| event.ends_with(" (canary)"))
    {
        // Older builds treated a diagnostic canary as a fully verified CLI
        // task connection. Do not reuse that cached green state after the
        // evidence model was tightened; a current non-diagnostic event is
        // represented by a last_event without the canary suffix.
        return None;
    }
    // This is only the static/TTL admission gate for the cached runtime base
    // status. The sole production caller immediately runs (or reuses) the
    // database-backed evidence projection, which authoritatively rebuilds
    // ordinary activity from ConnectorEvidenceSummary. Keeping that ownership
    // in one place avoids a second full event-history scan on every snapshot.
    let Ok(checked_at) = OffsetDateTime::parse(&status.checked_at, &Rfc3339) else {
        return None;
    };
    if !host_verification_check_is_fresh(checked_at, now) {
        return None;
    }
    Some(checked_at)
}

fn managed_connector_artifacts_match_current_installation(
    paths: &AppPaths,
    source: AgentSource,
) -> bool {
    let root = install_root(paths, source);
    let connector_cli = connector_cli_path(paths);
    match source {
        AgentSource::Codex => {
            codex_managed_root_state(&root) == ManagedPathState::Safe
                && check_codex_plugin_manifest(&root.join(".codex-plugin/plugin.json"), &root)
                    .status
                    == CheckStatus::Ok
                && check_codex_hooks(&root.join("hooks/hooks.json"), &connector_cli, &root).status
                    == CheckStatus::Ok
                && check_codex_studio_skill(&root.join("skills/agent-pet-studio/SKILL.md"), &root)
                    .status
                    == CheckStatus::Ok
                && check_codex_agent_pet_maker(&root).status == CheckStatus::Ok
                && check_codex_marketplace_entry().status == CheckStatus::Ok
        }
        AgentSource::ClaudeCode => {
            claude_managed_root_state(&root) == ManagedPathState::Safe
                && check_claude_fragment(
                    &root.join("settings.fragment.json"),
                    &connector_cli,
                    &root,
                )
                .status
                    == CheckStatus::Ok
                && check_claude_hook(&root.join("agent-pet-companion-hook.sh"), &connector_cli)
                    .status
                    == CheckStatus::Ok
                && check_claude_settings(&connector_cli, &root).status == CheckStatus::Ok
        }
        AgentSource::Pi => {
            let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
            pi_managed_root_state(&root) == ManagedPathState::Safe
                && check_exact_connector_file(
                    &root.join("agent-pet-companion.ts"),
                    "Extension",
                    expected.as_bytes(),
                    AgentSource::Pi,
                )
                .status
                    == CheckStatus::Ok
        }
        AgentSource::Opencode => {
            let expected = render_connector_script(OPENCODE_PLUGIN_TEMPLATE, &connector_cli);
            opencode_managed_root_state(&root) == ManagedPathState::Safe
                && check_exact_connector_file(
                    &root.join("agent-pet-companion.js"),
                    "Plugin",
                    expected.as_bytes(),
                    AgentSource::Opencode,
                )
                .status
                    == CheckStatus::Ok
        }
    }
}

fn connection_install_paths(paths: &AppPaths, source: AgentSource) -> Vec<String> {
    let mut install_paths = vec![install_root(paths, source).display().to_string()];
    match source {
        AgentSource::Codex => {
            install_paths.push(codex_marketplace_path().display().to_string());
        }
        AgentSource::ClaudeCode => {
            install_paths.push(claude_settings_path().display().to_string());
        }
        AgentSource::Pi | AgentSource::Opencode => {}
    }
    install_paths
}

fn managed_directory_state(path: &Path) -> ManagedPathState {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
            ManagedPathState::Safe
        }
        Ok(_) => ManagedPathState::Conflict,
        Err(error) if error.kind() == ErrorKind::NotFound => ManagedPathState::Missing,
        Err(_) => ManagedPathState::Conflict,
    }
}

fn codex_managed_root_state(root: &Path) -> ManagedPathState {
    let base = agent_home();
    let expected = base
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion");
    if root != expected {
        return ManagedPathState::Conflict;
    }

    let mut current = base;
    let mut saw_missing = false;
    for component in [
        None,
        Some(".agents"),
        Some("plugins"),
        Some("plugins"),
        Some("agent-pet-companion"),
    ] {
        if let Some(component) = component {
            current.push(component);
        }
        match managed_directory_state(&current) {
            ManagedPathState::Safe if !saw_missing => {}
            ManagedPathState::Missing => saw_missing = true,
            ManagedPathState::Safe | ManagedPathState::Conflict => {
                return ManagedPathState::Conflict;
            }
        }
    }
    if saw_missing {
        ManagedPathState::Missing
    } else {
        ManagedPathState::Safe
    }
}

fn claude_managed_root_state(root: &Path) -> ManagedPathState {
    let Some(parent) = root.parent() else {
        return ManagedPathState::Conflict;
    };
    match managed_directory_state(parent) {
        ManagedPathState::Conflict => return ManagedPathState::Conflict,
        ManagedPathState::Missing => return ManagedPathState::Missing,
        ManagedPathState::Safe => {}
    }
    managed_directory_state(root)
}

fn managed_directory_chain_state(
    root: &Path,
    base: PathBuf,
    components: &[&str],
) -> ManagedPathState {
    let expected = components
        .iter()
        .fold(base.clone(), |path, component| path.join(component));
    if root != expected {
        return ManagedPathState::Conflict;
    }

    let mut current = base;
    let mut saw_missing = false;
    for component in std::iter::once(None).chain(components.iter().map(|value| Some(*value))) {
        if let Some(component) = component {
            current.push(component);
        }
        match managed_directory_state(&current) {
            ManagedPathState::Safe if !saw_missing => {}
            ManagedPathState::Missing => saw_missing = true,
            ManagedPathState::Safe | ManagedPathState::Conflict => {
                return ManagedPathState::Conflict;
            }
        }
    }
    if saw_missing {
        ManagedPathState::Missing
    } else {
        ManagedPathState::Safe
    }
}

fn managed_script_root_spec(source: AgentSource) -> Option<(PathBuf, Vec<&'static str>)> {
    match source {
        AgentSource::Pi => {
            if let Some(base) = non_empty_env_path("APC_AGENT_CONFIG_HOME") {
                Some((base, vec![".pi", "agent", "extensions"]))
            } else if let Some(base) = non_empty_env_path("PI_CODING_AGENT_DIR") {
                Some((base, vec!["extensions"]))
            } else {
                Some((user_home(), vec![".pi", "agent", "extensions"]))
            }
        }
        AgentSource::Opencode => {
            if let Some(base) = non_empty_env_path("APC_AGENT_CONFIG_HOME") {
                Some((base, vec![".config", "opencode", "plugins"]))
            } else if let Some(base) = non_empty_env_path("OPENCODE_CONFIG_DIR") {
                Some((base, vec!["plugins"]))
            } else if let Some(base) = non_empty_env_path("XDG_CONFIG_HOME") {
                Some((base, vec!["opencode", "plugins"]))
            } else {
                Some((user_home(), vec![".config", "opencode", "plugins"]))
            }
        }
        AgentSource::Codex | AgentSource::ClaudeCode => None,
    }
}

fn managed_script_root_state(root: &Path, source: AgentSource) -> ManagedPathState {
    let Some((base, components)) = managed_script_root_spec(source) else {
        return ManagedPathState::Conflict;
    };
    managed_directory_chain_state(root, base, &components)
}

fn pi_managed_root_state(root: &Path) -> ManagedPathState {
    managed_script_root_state(root, AgentSource::Pi)
}

fn opencode_managed_root_state(root: &Path) -> ManagedPathState {
    managed_script_root_state(root, AgentSource::Opencode)
}

fn check_managed_connector_root(
    root: &Path,
    label: &str,
    state: ManagedPathState,
) -> ConnectionCheckItem {
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if state == ManagedPathState::Conflict {
            format!("{label}路径冲突")
        } else {
            label.to_string()
        },
        match state {
            ManagedPathState::Safe => CheckStatus::Ok,
            ManagedPathState::Missing => CheckStatus::NotRequired,
            ManagedPathState::Conflict => CheckStatus::NeedsFix,
        },
        match state {
            ManagedPathState::Safe => format!("管理根为非符号链接目录：{}", root.display()),
            ManagedPathState::Missing => format!("管理根尚未创建：{}", root.display()),
            ManagedPathState::Conflict => format!(
                "管理根或受管父目录是符号链接、非目录或不可检查路径；为保护外部内容，一键修复与卸载均被阻止：{}",
                root.display()
            ),
        },
        Some(if state == ManagedPathState::Conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn host_verification_check_is_fresh(checked_at: OffsetDateTime, now: OffsetDateTime) -> bool {
    checked_at >= now - time::Duration::seconds(HOST_VERIFICATION_CACHE_TTL_SECONDS)
        && checked_at <= now + time::Duration::seconds(HOST_VERIFICATION_FUTURE_SKEW_SECONDS)
}

fn managed_connector_artifacts(paths: &AppPaths, source: AgentSource) -> Vec<PathBuf> {
    let root = install_root(paths, source);
    match source {
        AgentSource::Codex => vec![
            root.join(".codex-plugin/plugin.json"),
            root.join("hooks/hooks.json"),
            codex_marketplace_path(),
        ],
        AgentSource::ClaudeCode => {
            vec![
                root.join("settings.fragment.json"),
                root.join("agent-pet-companion-hook.sh"),
                claude_settings_path(),
            ]
        }
        AgentSource::Pi => vec![root.join("agent-pet-companion.ts")],
        AgentSource::Opencode => vec![root.join("agent-pet-companion.js")],
    }
}

/// Cheap, opaque revision for invalidating the snapshot light-status cache.
/// It retains no paths or file contents: only the final process-local hash of
/// metadata for every managed connector artifact, command-search candidate,
/// explicit override, and the connector CLI.
pub(crate) fn connection_light_cache_revision(paths: &AppPaths) -> u64 {
    let mut artifacts = vec![connector_cli_path(paths)];
    for source in [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ] {
        let root = install_root(paths, source);
        match source {
            AgentSource::Codex => {
                artifacts.extend([
                    root.join(".codex-plugin/plugin.json"),
                    root.join("hooks/hooks.json"),
                    root.join("skills/agent-pet-studio/SKILL.md"),
                    codex_marketplace_path(),
                ]);
                artifacts.extend(
                    AGENT_PET_MAKER_FILES
                        .iter()
                        .map(|(relative, _)| root.join("skills/agent-pet-maker").join(relative)),
                );
            }
            AgentSource::ClaudeCode => artifacts.extend([
                root.join("settings.fragment.json"),
                root.join("agent-pet-companion-hook.sh"),
                claude_settings_path(),
            ]),
            AgentSource::Pi => artifacts.push(root.join("agent-pet-companion.ts")),
            AgentSource::Opencode => artifacts.push(root.join("agent-pet-companion.js")),
        }
    }
    artifacts.extend(agent_cli_cache_candidates());
    artifacts.sort();
    artifacts.dedup();

    let ancestors = artifacts
        .iter()
        .filter_map(|path| path.parent())
        .flat_map(Path::ancestors)
        .map(Path::to_path_buf)
        .collect::<BTreeSet<_>>();

    let mut revision = DefaultHasher::new();
    // Search order and explicit overrides are part of command resolution even
    // when all candidate files are currently absent. Hash values only into the
    // opaque process-local revision; never retain or expose them.
    for key in [
        "PATH",
        "HOME",
        "APC_AGENT_CONFIG_HOME",
        "APC_CONNECTOR_CLI_PATH",
        "APC_CODEX_CLI_PATH",
        "APC_CLAUDE_CLI_PATH",
        "APC_PI_CLI_PATH",
        "APC_OPENCODE_CLI_PATH",
    ] {
        key.hash(&mut revision);
        if let Some(value) = std::env::var_os(key) {
            1_u8.hash(&mut revision);
            value.as_os_str().as_bytes().hash(&mut revision);
        } else {
            0_u8.hash(&mut revision);
        }
    }
    // A leaf may resolve to exactly the same inode after one of its parent
    // directories is replaced by a symlink. Hash every unique parent with
    // lstat identity so that unsafe ancestry transitions invalidate the
    // projection. Directory timestamps and sizes are intentionally excluded:
    // unrelated siblings must not cause a cold connector scan.
    for ancestor in ancestors {
        hash_ancestor_identity(&ancestor, &mut revision);
    }
    for path in artifacts {
        hash_path_metadata(&path, &mut revision);
    }
    revision.finish()
}

fn agent_cli_cache_candidates() -> Vec<PathBuf> {
    let sources = [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ];
    let mut candidates = shared_command_search_dirs()
        .into_iter()
        .flat_map(|directory| {
            sources
                .into_iter()
                .map(move |source| directory.join(cli_name(source)))
        })
        .collect::<Vec<_>>();
    candidates.extend([
        PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex"),
        PathBuf::from("/Applications/Codex.app/Contents/Resources/codex"),
    ]);
    candidates.extend(
        sources
            .into_iter()
            .filter_map(|source| absolute_env_path(agent_cli_override_key(source))),
    );
    candidates
}

fn hash_ancestor_identity(path: &Path, revision: &mut DefaultHasher) {
    path.as_os_str().as_bytes().hash(revision);
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            1_u8.hash(revision);
            let file_type = metadata.file_type();
            file_type.is_dir().hash(revision);
            file_type.is_file().hash(revision);
            file_type.is_symlink().hash(revision);
            metadata.dev().hash(revision);
            metadata.ino().hash(revision);
            metadata.mode().hash(revision);
        }
        Err(error) => {
            0_u8.hash(revision);
            error.raw_os_error().hash(revision);
        }
    }
}

fn hash_path_metadata(path: &Path, revision: &mut DefaultHasher) {
    path.as_os_str().as_bytes().hash(revision);
    hash_metadata_result(fs::symlink_metadata(path), revision);
    // Package managers commonly expose CLIs through stable symlinks. Include
    // the followed target metadata as well so replacing the target invalidates
    // the projection even when the link inode itself is unchanged.
    hash_metadata_result(fs::metadata(path), revision);
}

fn hash_metadata_result(result: std::io::Result<std::fs::Metadata>, revision: &mut DefaultHasher) {
    match result {
        Ok(metadata) => {
            1_u8.hash(revision);
            metadata.mode().hash(revision);
            metadata.dev().hash(revision);
            metadata.ino().hash(revision);
            metadata.len().hash(revision);
            metadata.mtime().hash(revision);
            metadata.mtime_nsec().hash(revision);
            metadata.ctime().hash(revision);
            metadata.ctime_nsec().hash(revision);
        }
        Err(error) => {
            0_u8.hash(revision);
            error.raw_os_error().hash(revision);
        }
    }
}

fn managed_connector_artifact_mtimes(paths: &AppPaths, source: AgentSource) -> Option<Vec<i128>> {
    let artifacts = managed_connector_artifacts(paths, source);
    if artifacts.is_empty() {
        return None;
    }
    artifacts
        .into_iter()
        .map(|path| {
            let metadata = fs::symlink_metadata(path).ok()?;
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return None;
            }
            metadata
                .modified()
                .ok()?
                .duration_since(UNIX_EPOCH)
                .ok()
                .map(|duration| i128::try_from(duration.as_nanos()).unwrap_or(i128::MAX))
        })
        .collect()
}

pub(crate) fn contract_version_for_source(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => CODEX_HOOKS_CONTRACT_VERSION,
        AgentSource::ClaudeCode => CLAUDE_HOOKS_CONTRACT_VERSION,
        AgentSource::Pi => PI_EXTENSION_CONTRACT_VERSION,
        AgentSource::Opencode => OPENCODE_CONTRACT_VERSION,
    }
}

fn has_repairable_managed_connector_issue(
    managed_path_conflict: bool,
    managed_checks: &[&ConnectionCheckItem],
) -> bool {
    !managed_path_conflict
        && managed_checks
            .iter()
            .any(|check| check.status.is_blocking())
}

fn capabilities_for_source(source: AgentSource) -> AgentConnectorCapabilities {
    let strings = |values: &[&str]| values.iter().map(|value| (*value).to_string()).collect();
    match source {
        AgentSource::Codex => {
            let audited_events: Vec<String> = CODEX_LOCAL_HOOK_EVENTS
                .iter()
                .map(|event| format!("Plugin Hook · {event}"))
                .chain(
                    CODEX_APP_SERVER_NOTIFICATION_EVENTS
                        .iter()
                        .map(|event| format!("App Server Notification · {event}")),
                )
                .collect();
            let mut subscribed_events: Vec<String> = strings(CODEX_LOCAL_HOOK_EVENTS);
            subscribed_events.push(
                "App Server 只读后备 · hooks/list + thread/list + 有界 thread/read".to_string(),
            );
            AgentConnectorCapabilities {
                contract_version: CODEX_HOOKS_CONTRACT_VERSION.to_string(),
                audited_events,
                subscribed_events,
                mapped_information: strings(&[
                    "10 个官方 Hook 提供任务开始/完成、工具、权限、压缩与子 Agent 生命周期",
                    "已审计 CLI 0.144.5 与桌面内置 0.145.0-alpha.18 的 70 个 App Server 通知；仅以 thread/list/read 作有损只读后备",
                    "有界的用户提示与最终助手消息",
                ]),
                privacy_exclusions: strings(&[
                    "不订阅/保存 App Server 的 output delta、patch、reasoning、transcript/audio 或账户通知内容",
                    "不保存 transcript_path、tool_input、tool_response、命令输出或完整补丁",
                    "不保存推理正文、认证信息、Token、Cookie 或 API Key",
                ]),
                ..Default::default()
            }
        }
        AgentSource::ClaudeCode => AgentConnectorCapabilities {
            contract_version: CLAUDE_HOOKS_CONTRACT_VERSION.to_string(),
            audited_events: strings(CLAUDE_AUDITED_HOOK_EVENTS),
            subscribed_events: strings(&[
                "SessionStart",
                "Setup",
                "InstructionsLoaded",
                "UserPromptSubmit",
                "UserPromptExpansion",
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "PostToolUseFailure",
                "PostToolBatch",
                "PermissionDenied",
                "Notification",
                "SubagentStart",
                "SubagentStop",
                "TaskCreated",
                "TaskCompleted",
                "Stop",
                "StopFailure",
                "TeammateIdle",
                "ConfigChange",
                "CwdChanged",
                "WorktreeRemove",
                "PreCompact",
                "PostCompact",
                "Elicitation",
                "ElicitationResult",
                "SessionEnd",
            ]),
            mapped_information: strings(&[
                "任务、工具、权限/提问、子 Agent/Task、压缩、失败与后台工作状态",
                "Setup/配置/CWD/指令加载等元数据仅用于连接观察，不驱动桌宠",
                "prompt_id 用作 turn 终止栅栏",
            ]),
            privacy_exclusions: strings(&[
                "不订阅 WorktreeCreate（会替换宿主默认创建行为）",
                "不订阅 MessageDisplay/FileChanged（流式风暴或无安全全量匹配）",
                "不保存 tool input/output、transcript、错误正文、elicitation 内容或后台命令",
            ]),
            ..Default::default()
        },
        AgentSource::Pi => AgentConnectorCapabilities {
            contract_version: PI_EXTENSION_CONTRACT_VERSION.to_string(),
            audited_events: strings(PI_AUDITED_EVENTS),
            subscribed_events: strings(&[
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
            ]),
            mapped_information: strings(&[
                "输入、turn、工具开始/结束、压缩、最终 agent_settled 与会话关闭",
                "session title、工具名与单向散列调用身份",
            ]),
            privacy_exclusions: strings(&[
                "不转发 context、provider request/headers/response、tool result 或流式 delta",
                "agent_end 不作为终态；只有 agent_settled 稳定完成",
            ]),
            ..Default::default()
        },
        AgentSource::Opencode => {
            let audited_events = OPENCODE_AUDITED_PLUGIN_HOOKS
                .iter()
                .map(|event| format!("Plugin Hook · {event}"))
                .chain(
                    OPENCODE_AUDITED_BUS_EVENTS
                        .iter()
                        .map(|event| format!("Event Bus · {event}")),
                )
                .collect();
            AgentConnectorCapabilities {
                contract_version: OPENCODE_CONTRACT_VERSION.to_string(),
                audited_events,
                subscribed_events: strings(&[
                    "event（统一观察 91 个 SDK v1 + v2/host bus 事件）",
                    "dispose（有界排空已接收事件，不生成会话终态）",
                    "chat.message",
                    "permission.ask",
                    "command.execute.before",
                    "tool.execute.before",
                    "tool.execute.after",
                    "experimental.session.compacting",
                    "experimental.text.complete",
                ]),
                mapped_information: strings(&[
                    "已盘点 21 个 Plugin Hook；注册 9 个只读安全项",
                    "generic event 覆盖 91 个 SDK v1 + v2/host bus 事件；仅映射隐私安全的活动子集",
                    "session 状态、权限/提问、消息、命令/工具、计划、压缩与 session.next 生命周期",
                    "v2 单次 tool success/failure 保持可恢复；retry 重新激活；step.failed/session_failure 映射为终态失败",
                ]),
                privacy_exclusions: strings(&[
                    "不注册 config/tool/tool.definition/auth 等会修改配置、工具定义或认证行为的 Hook",
                    "不转发 prompt 参数、headers/env/auth、tool args/output、todo 内容或 reasoning delta",
                    "不保存命令文本、权限 patterns、错误正文或补丁内容",
                ]),
                ..Default::default()
            }
        }
    }
}

pub fn repair_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    repair_source_at(paths, source, &user_home())
}

pub fn repair_source_at(
    paths: &AppPaths,
    source: AgentSource,
    probe_cwd: &Path,
) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    let cli_path = connector_cli_path(paths);
    match source {
        AgentSource::Codex => repair_codex(&root, &cli_path)?,
        AgentSource::ClaudeCode => repair_claude(&root, &cli_path)?,
        AgentSource::Pi => repair_pi(&root, &cli_path)?,
        AgentSource::Opencode => repair_opencode(&root, &cli_path)?,
    }
    Ok(check_source_at(paths, source, probe_cwd))
}

pub fn refresh_installed_source(paths: &AppPaths, source: AgentSource) -> Result<bool> {
    if !connector_artifacts_present(paths, source) {
        return Ok(false);
    }
    let root = install_root(paths, source);
    let cli_path = connector_cli_path(paths);
    match source {
        AgentSource::Codex => write_codex_connector(&root, &cli_path)?,
        AgentSource::ClaudeCode => repair_claude(&root, &cli_path)?,
        AgentSource::Pi => repair_pi(&root, &cli_path)?,
        AgentSource::Opencode => repair_opencode(&root, &cli_path)?,
    }
    Ok(true)
}

pub fn uninstall_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    match source {
        AgentSource::Pi => {
            if pi_managed_root_state(&root) == ManagedPathState::Conflict {
                return Err(PetCoreError::Conflict(format!(
                    "拒绝通过 Pi 管理目录符号链接或非目录路径卸载：{}",
                    root.display()
                )));
            }
            remove_owned_connector_script(&root.join("agent-pet-companion.ts"), AgentSource::Pi)?;
        }
        AgentSource::Opencode => {
            if opencode_managed_root_state(&root) == ManagedPathState::Conflict {
                return Err(PetCoreError::Conflict(format!(
                    "拒绝通过 OpenCode 管理目录符号链接或非目录路径卸载：{}",
                    root.display()
                )));
            }
            remove_owned_connector_script(
                &root.join("agent-pet-companion.js"),
                AgentSource::Opencode,
            )?;
        }
        AgentSource::Codex => {
            if codex_managed_root_state(&root) == ManagedPathState::Conflict {
                return Err(PetCoreError::Conflict(format!(
                    "拒绝通过 Codex 管理目录符号链接或非目录路径卸载：{}",
                    root.display()
                )));
            }
            uninstall_codex_plugin_if_possible()?;
            remove_codex_marketplace_entry()?;
            remove_owned_codex_connector_files(&root)?;
        }
        AgentSource::ClaudeCode => {
            if claude_managed_root_state(&root) == ManagedPathState::Conflict {
                return Err(PetCoreError::Conflict(format!(
                    "拒绝通过 Claude 管理目录符号链接或非目录路径卸载：{}",
                    root.display()
                )));
            }
            remove_claude_settings_hooks(&root, &connector_cli_path(paths))?;
            remove_owned_claude_connector_files(&root)?;
        }
    }
    let status = check_source(paths, source);
    if status.connector_installed {
        return Err(PetCoreError::Conflict(format!(
            "{} 卸载后的即时复检仍检测到受管连接器或宿主插件，未标记为已卸载",
            source.display_name()
        )));
    }
    Ok(status)
}

fn repair_codex(root: &Path, cli_path: &Path) -> Result<()> {
    write_codex_connector(root, cli_path)?;
    ensure_codex_marketplace_entry()?;
    install_codex_plugin_if_possible(root)?;
    Ok(())
}

fn write_codex_connector(root: &Path, cli_path: &Path) -> Result<()> {
    validate_codex_root_repair_ownership(root)?;
    ensure_codex_plugin_root(root)?;
    let plugin_dir = root.join(".codex-plugin");
    let hooks_dir = root.join("hooks");
    let skills_dir = root.join("skills");
    let studio_skill_dir = skills_dir.join("agent-pet-studio");
    for path in [&plugin_dir, &hooks_dir, &skills_dir, &studio_skill_dir] {
        ensure_managed_directory(path)?;
    }
    let plugin: Value = serde_json::from_str(CODEX_PLUGIN_JSON)?;
    let hooks = rendered_codex_hooks(cli_path)?;
    write_managed_file_atomic(
        &plugin_dir.join("plugin.json"),
        &serde_json::to_vec_pretty(&plugin)?,
        0o644,
    )?;
    write_managed_file_atomic(
        &hooks_dir.join("hooks.json"),
        &serde_json::to_vec_pretty(&hooks)?,
        0o644,
    )?;
    write_managed_file_atomic(
        &studio_skill_dir.join("SKILL.md"),
        PET_STUDIO_SKILL_MD.as_bytes(),
        0o644,
    )?;
    write_codex_agent_pet_maker(root)?;
    Ok(())
}

fn write_codex_agent_pet_maker(root: &Path) -> Result<()> {
    let skill_root = root.join("skills/agent-pet-maker");
    ensure_managed_directory(&skill_root)?;
    for directory in ["references", "scripts", "agents", "tests"] {
        ensure_managed_directory(&skill_root.join(directory))?;
    }
    for (relative_path, _) in AGENT_PET_MAKER_FILES {
        ensure_managed_file_target(&skill_root.join(relative_path))?;
    }
    for (relative_path, content) in AGENT_PET_MAKER_FILES {
        let path = skill_root.join(relative_path);
        let mode = if *relative_path == "scripts/petpack_workspace.py" {
            0o755
        } else {
            0o644
        };
        write_managed_file_atomic(&path, content.as_bytes(), mode)?;
    }
    Ok(())
}

fn ensure_codex_plugin_root(root: &Path) -> Result<()> {
    let base = agent_home();
    let expected = base
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion");
    if root != expected {
        return Err(PetCoreError::Validation(format!(
            "Codex plugin 管理根不符合预期：{}",
            root.display()
        )));
    }

    ensure_managed_directory(&base)?;
    let mut current = base;
    for component in [".agents", "plugins", "plugins", "agent-pet-companion"] {
        current.push(component);
        ensure_managed_directory(&current)?;
    }
    Ok(())
}

fn ensure_managed_directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(PetCoreError::Validation(
            format!("拒绝通过符号链接写入受管连接器目录：{}", path.display()),
        )),
        Ok(metadata) if metadata.is_dir() => Ok(()),
        Ok(_) => Err(PetCoreError::Validation(format!(
            "受管连接器目录路径不是目录：{}",
            path.display()
        ))),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let parent = path.parent().ok_or_else(|| {
                PetCoreError::Validation(format!("受管连接器目录缺少父目录：{}", path.display()))
            })?;
            let parent_metadata = fs::symlink_metadata(parent)?;
            if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
                return Err(PetCoreError::Validation(format!(
                    "拒绝通过非目录或符号链接父路径创建受管连接器目录：{}",
                    parent.display()
                )));
            }
            fs::create_dir(path)?;
            Ok(())
        }
        Err(error) => Err(error.into()),
    }
}

fn ensure_managed_file_target(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(PetCoreError::Validation(
            format!("拒绝覆盖 Codex plugin 中的符号链接文件：{}", path.display()),
        )),
        Ok(metadata) if metadata.is_file() => Ok(()),
        Ok(_) => Err(PetCoreError::Validation(format!(
            "Codex plugin 管理文件路径不是普通文件：{}",
            path.display()
        ))),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn write_managed_file_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        PetCoreError::Validation(format!(
            "Codex plugin 管理文件缺少父目录：{}",
            path.display()
        ))
    })?;
    ensure_managed_directory(parent)?;
    ensure_managed_file_target(path)?;
    if fs::read(path).ok().as_deref() == Some(bytes) {
        let permissions = fs::metadata(path)?.permissions();
        if permissions.mode() & 0o777 != mode {
            fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
        }
        return Ok(());
    }

    let temp_path = atomic_temp_path(path);
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::set_permissions(&temp_path, fs::Permissions::from_mode(mode))?;
        fs::rename(&temp_path, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn repair_claude(root: &Path, cli_path: &Path) -> Result<()> {
    validate_claude_root_repair_ownership(root, cli_path)?;
    let parent = root.parent().ok_or_else(|| {
        PetCoreError::Validation(format!(
            "Claude connector 管理根缺少父目录：{}",
            root.display()
        ))
    })?;
    if managed_directory_state(parent) != ManagedPathState::Safe {
        return Err(PetCoreError::Conflict(format!(
            "拒绝通过符号链接或非目录父路径写入 Claude connector：{}",
            parent.display()
        )));
    }
    ensure_managed_directory(root)?;
    let hook_path = root.join("agent-pet-companion-hook.sh");
    let hook_script = rendered_claude_hook(cli_path);
    write_managed_file_atomic(&hook_path, hook_script.as_bytes(), 0o755)?;
    let fragment = rendered_claude_settings_fragment(cli_path, root)?;
    write_managed_file_atomic(
        &root.join("settings.fragment.json"),
        &serde_json::to_vec_pretty(&fragment)?,
        0o644,
    )?;
    install_claude_settings_fragment(&fragment, root, cli_path)?;
    Ok(())
}

fn validate_codex_root_repair_ownership(root: &Path) -> Result<()> {
    match codex_managed_root_state(root) {
        ManagedPathState::Missing => return Ok(()),
        ManagedPathState::Conflict => {
            return Err(PetCoreError::Conflict(format!(
                "Codex connector 管理根是符号链接或非目录路径：{}",
                root.display()
            )));
        }
        ManagedPathState::Safe => {}
    }
    let owned = codex_manifest_is_owned(&root.join(".codex-plugin/plugin.json"), root)
        || codex_hooks_are_owned(&root.join("hooks/hooks.json"), root)
        || codex_studio_skill_is_owned(&root.join("skills/agent-pet-studio/SKILL.md"), root)
        || codex_maker_skill_is_owned(root)
        || matches!(
            codex_marketplace_entry_state(&codex_marketplace_path()),
            CodexMarketplaceEntryState::Current | CodexMarketplaceEntryState::OwnedOutdated
        );
    if !owned && directory_has_entries(root)? {
        return Err(PetCoreError::Conflict(format!(
            "Codex connector 固定管理根已有无法识别为 Agent Pet Companion 的内容，拒绝覆盖：{}",
            root.display()
        )));
    }
    for (path, path_owned) in [
        (
            root.join(".codex-plugin/plugin.json"),
            codex_manifest_is_owned(&root.join(".codex-plugin/plugin.json"), root),
        ),
        (
            root.join("hooks/hooks.json"),
            codex_hooks_are_owned(&root.join("hooks/hooks.json"), root),
        ),
        (
            root.join("skills/agent-pet-studio/SKILL.md"),
            codex_studio_skill_is_owned(&root.join("skills/agent-pet-studio/SKILL.md"), root),
        ),
    ] {
        match managed_regular_file_state(root, &path) {
            ManagedPathState::Missing => {}
            ManagedPathState::Safe if path_owned => {}
            ManagedPathState::Safe | ManagedPathState::Conflict => {
                return Err(PetCoreError::Conflict(format!(
                    "Codex connector 固定路径被无法识别的文件或符号链接占用，拒绝覆盖：{}",
                    path.display()
                )));
            }
        }
    }

    let maker_root = root.join("skills/agent-pet-maker");
    let maker_owned = codex_maker_skill_is_owned(root)
        || AGENT_PET_MAKER_FILES
            .iter()
            .any(|(relative_path, expected)| {
                let path = maker_root.join(relative_path);
                managed_regular_file_state(root, &path) == ManagedPathState::Safe
                    && fs::read(path).is_ok_and(|content| content == expected.as_bytes())
            });
    if managed_directory_state(&maker_root) == ManagedPathState::Safe
        && directory_has_entries(&maker_root)?
        && !maker_owned
    {
        return Err(PetCoreError::Conflict(format!(
            "Codex Agent Pet Maker 固定目录已有无法识别的内容，拒绝覆盖：{}",
            maker_root.display()
        )));
    }
    if maker_owned {
        for (relative_path, _) in AGENT_PET_MAKER_FILES {
            let path = maker_root.join(relative_path);
            if managed_regular_file_state(root, &path) == ManagedPathState::Conflict {
                return Err(PetCoreError::Conflict(format!(
                    "Codex Agent Pet Maker 固定路径是符号链接或非普通文件，拒绝覆盖：{}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

fn validate_claude_root_repair_ownership(root: &Path, connector_cli: &Path) -> Result<()> {
    match claude_managed_root_state(root) {
        ManagedPathState::Missing => return Ok(()),
        ManagedPathState::Conflict => {
            return Err(PetCoreError::Conflict(format!(
                "Claude connector 管理根是符号链接或非目录路径：{}",
                root.display()
            )));
        }
        ManagedPathState::Safe => {}
    }
    let settings_owned = read_regular_json_config(&claude_settings_path())
        .is_some_and(|settings| value_contains_owned_claude_hook(&settings, connector_cli, root));
    let owned = claude_fragment_is_owned(&root.join("settings.fragment.json"), root)
        || claude_helper_is_owned(&root.join("agent-pet-companion-hook.sh"), root)
        || settings_owned;
    if !owned && directory_has_entries(root)? {
        return Err(PetCoreError::Conflict(format!(
            "Claude connector 固定管理根已有无法识别为 Agent Pet Companion 的内容，拒绝覆盖：{}",
            root.display()
        )));
    }
    for (path, path_owned) in [
        (
            root.join("settings.fragment.json"),
            claude_fragment_is_owned(&root.join("settings.fragment.json"), root),
        ),
        (
            root.join("agent-pet-companion-hook.sh"),
            claude_helper_is_owned(&root.join("agent-pet-companion-hook.sh"), root),
        ),
    ] {
        match managed_regular_file_state(root, &path) {
            ManagedPathState::Missing => {}
            ManagedPathState::Safe if path_owned => {}
            ManagedPathState::Safe | ManagedPathState::Conflict => {
                return Err(PetCoreError::Conflict(format!(
                    "Claude connector 固定路径被无法识别的文件或符号链接占用，拒绝覆盖：{}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

fn directory_has_entries(path: &Path) -> Result<bool> {
    Ok(fs::read_dir(path)?.next().transpose()?.is_some())
}

fn ensure_managed_directory_tree(path: &Path) -> Result<()> {
    match managed_directory_state(path) {
        ManagedPathState::Safe => Ok(()),
        ManagedPathState::Conflict => Err(PetCoreError::Conflict(format!(
            "受管连接器目录是符号链接、非目录或不可检查路径，拒绝写入：{}",
            path.display()
        ))),
        ManagedPathState::Missing => {
            let parent = path.parent().ok_or_else(|| {
                PetCoreError::Validation(format!("受管连接器目录缺少父目录：{}", path.display()))
            })?;
            ensure_managed_directory_tree(parent)?;
            ensure_managed_directory(path)
        }
    }
}

fn ensure_managed_script_root(root: &Path, source: AgentSource) -> Result<()> {
    let Some((base, components)) = managed_script_root_spec(source) else {
        return Err(PetCoreError::Validation(format!(
            "{} 不使用单文件脚本连接器根",
            source.display_name()
        )));
    };
    let expected = components
        .iter()
        .fold(base.clone(), |path, component| path.join(component));
    if root != expected {
        return Err(PetCoreError::Validation(format!(
            "{} 连接器管理根不符合预期：{}",
            source.display_name(),
            root.display()
        )));
    }
    ensure_managed_directory_tree(&base)?;
    let mut current = base;
    for component in components {
        current.push(component);
        ensure_managed_directory(&current)?;
    }
    if managed_script_root_state(root, source) != ManagedPathState::Safe {
        return Err(PetCoreError::Conflict(format!(
            "{} 连接器管理根创建后未通过非符号链接目录校验：{}",
            source.display_name(),
            root.display()
        )));
    }
    Ok(())
}

fn repair_pi(root: &Path, cli_path: &Path) -> Result<()> {
    ensure_managed_script_root(root, AgentSource::Pi)?;
    let script = render_connector_script(PI_EXTENSION_TEMPLATE, cli_path);
    write_owned_connector_script(
        &root.join("agent-pet-companion.ts"),
        script.as_bytes(),
        AgentSource::Pi,
    )?;
    Ok(())
}

fn repair_opencode(root: &Path, cli_path: &Path) -> Result<()> {
    ensure_managed_script_root(root, AgentSource::Opencode)?;
    let script = render_connector_script(OPENCODE_PLUGIN_TEMPLATE, cli_path);
    write_owned_connector_script(
        &root.join("agent-pet-companion.js"),
        script.as_bytes(),
        AgentSource::Opencode,
    )?;
    Ok(())
}

fn render_connector_script(template: &str, cli_path: &Path) -> String {
    let cli_json = serde_json::to_string(&cli_path.display().to_string())
        .expect("serializing a connector CLI path string cannot fail");
    template.replace("__APC_CLI_JSON__", &cli_json)
}

fn rendered_claude_hook(connector_cli: &Path) -> String {
    let cli = shell_quote(&connector_cli.display().to_string());
    format!(
        "#!/bin/sh\nset -eu\nAPC_CONNECTOR_CONTRACT_VERSION={} {cli} agent hook --source claude_code --event-type auto >/dev/null 2>&1 || true\n",
        shell_quote(CLAUDE_HOOKS_CONTRACT_VERSION)
    )
}

fn managed_regular_file_state(root: &Path, path: &Path) -> ManagedPathState {
    match managed_directory_state(root) {
        ManagedPathState::Safe => {}
        state => return state,
    }
    let Ok(relative) = path.strip_prefix(root) else {
        return ManagedPathState::Conflict;
    };
    let Some(relative_parent) = relative.parent() else {
        return ManagedPathState::Conflict;
    };
    let mut current = root.to_path_buf();
    for component in relative_parent.components() {
        let std::path::Component::Normal(component) = component else {
            return ManagedPathState::Conflict;
        };
        current.push(component);
        match managed_directory_state(&current) {
            ManagedPathState::Safe => {}
            state => return state,
        }
    }
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            ManagedPathState::Safe
        }
        Ok(_) => ManagedPathState::Conflict,
        Err(error) if error.kind() == ErrorKind::NotFound => ManagedPathState::Missing,
        Err(_) => ManagedPathState::Conflict,
    }
}

fn check_claude_fragment(
    path: &Path,
    connector_cli: &Path,
    install_root: &Path,
) -> ConnectionCheckItem {
    let path_state = if claude_managed_root_state(install_root) == ManagedPathState::Safe {
        managed_regular_file_state(install_root, path)
    } else {
        claude_managed_root_state(install_root)
    };
    let expected = rendered_claude_settings_fragment(connector_cli, install_root).ok();
    let configured = path_state == ManagedPathState::Safe
        && fs::read(path)
            .ok()
            .and_then(|content| serde_json::from_slice::<Value>(&content).ok())
            .zip(expected)
            .is_some_and(|(actual, expected)| actual == expected);
    let content_conflict = path_state == ManagedPathState::Safe
        && !configured
        && !claude_fragment_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict || content_conflict;
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if conflict {
            "Hooks 路径冲突".to_string()
        } else {
            "Hooks".to_string()
        },
        if configured {
            CheckStatus::Ok
        } else if path_state == ManagedPathState::Missing {
            CheckStatus::Missing
        } else {
            CheckStatus::NeedsFix
        },
        if configured {
            "与当前 27 个 Claude Hook group 模板精确一致".to_string()
        } else if conflict {
            format!(
                "fragment 或受管目录是符号链接/非普通路径；拒绝一键覆盖：{}",
                path.display()
            )
        } else if path_state == ManagedPathState::Safe {
            format!("已安装旧版本或损坏，待更新 {}", path.display())
        } else {
            format!("待写入 {}", path.display())
        },
        Some(if conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn check_claude_hook(path: &Path, connector_cli: &Path) -> ConnectionCheckItem {
    let install_root = path.parent().unwrap_or(path);
    let path_state = if claude_managed_root_state(install_root) == ManagedPathState::Safe {
        managed_regular_file_state(install_root, path)
    } else {
        claude_managed_root_state(install_root)
    };
    let expected = rendered_claude_hook(connector_cli);
    let metadata = fs::symlink_metadata(path).ok();
    let is_regular_executable = path_state == ManagedPathState::Safe
        && metadata.as_ref().is_some_and(|metadata| {
            metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.permissions().mode() & 0o111 != 0
        });
    let configured = is_regular_executable
        && fs::read(path).is_ok_and(|contents| contents == expected.as_bytes());
    let content_conflict = path_state == ManagedPathState::Safe
        && !configured
        && !claude_helper_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict || content_conflict;
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if conflict {
            "事件通道路径冲突".to_string()
        } else {
            "事件通道".to_string()
        },
        if configured {
            CheckStatus::Ok
        } else if path_state == ManagedPathState::Missing {
            CheckStatus::Missing
        } else {
            CheckStatus::NeedsFix
        },
        if configured {
            "helper 的 CLI 路径、事件契约、命令与可执行权限均与当前 App 精确一致".to_string()
        } else if conflict {
            format!(
                "helper 或受管目录是符号链接/非普通路径；拒绝一键覆盖或 chmod：{}",
                path.display()
            )
        } else if metadata.is_some() {
            format!(
                "helper 为空、损坏、不可执行，或仍引用旧 CLI/契约；待更新 {}",
                path.display()
            )
        } else {
            format!("待写入 {}", path.display())
        },
        Some(if conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn check_codex_plugin_manifest(path: &Path, install_root: &Path) -> ConnectionCheckItem {
    let path_state = managed_regular_file_state(install_root, path);
    let expected = serde_json::from_str::<Value>(CODEX_PLUGIN_JSON).ok();
    let configured = path_state == ManagedPathState::Safe
        && fs::read_to_string(path)
            .ok()
            .and_then(|content| serde_json::from_str::<Value>(&content).ok())
            .zip(expected)
            .is_some_and(|(actual, expected)| actual == expected);
    let content_conflict = path_state == ManagedPathState::Safe
        && !configured
        && !codex_manifest_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict || content_conflict;
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if conflict {
            "插件源路径冲突".to_string()
        } else {
            "插件源".to_string()
        },
        if configured {
            CheckStatus::Ok
        } else if path_state == ManagedPathState::Missing {
            CheckStatus::Missing
        } else {
            CheckStatus::NeedsFix
        },
        if configured {
            "与 App 自带 plugin.json 的操作字段精确一致".to_string()
        } else if conflict {
            format!(
                "路径是符号链接或非普通受管文件，拒绝覆盖：{}",
                path.display()
            )
        } else {
            format!("待写入或升级 {}", path.display())
        },
        Some(if conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn check_codex_hooks(
    path: &Path,
    connector_cli: &Path,
    install_root: &Path,
) -> ConnectionCheckItem {
    let path_state = managed_regular_file_state(install_root, path);
    let expected = rendered_codex_hooks(connector_cli).ok();
    let configured = path_state == ManagedPathState::Safe
        && fs::read_to_string(path)
            .ok()
            .and_then(|content| serde_json::from_str::<Value>(&content).ok())
            .zip(expected)
            .is_some_and(|(actual, expected)| actual == expected);
    let content_conflict = path_state == ManagedPathState::Safe
        && !configured
        && !codex_hooks_are_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict || content_conflict;
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if conflict {
            "Hook 路径冲突".to_string()
        } else {
            "Hook".to_string()
        },
        if configured {
            CheckStatus::Ok
        } else if path_state == ManagedPathState::Missing {
            CheckStatus::Missing
        } else {
            CheckStatus::NeedsFix
        },
        if configured {
            "configured: Hook 键、group、command 与当前 App 模板精确一致；review/failed 不由 hooks 宣称".to_string()
        } else if conflict {
            format!(
                "路径是符号链接或非普通受管文件，拒绝覆盖：{}",
                path.display()
            )
        } else {
            format!("待写入或升级 {}", path.display())
        },
        Some(if conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn rendered_codex_hooks(connector_cli: &Path) -> Result<Value> {
    let cli = shell_quote(&connector_cli.display().to_string());
    let hook_cli = format!(
        "APC_CONNECTOR_CONTRACT_VERSION={} {cli}",
        shell_quote(CODEX_HOOKS_CONTRACT_VERSION)
    );
    render_json_template(CODEX_HOOKS_TEMPLATE, "__APC_CLI__", &hook_cli)
}

fn rendered_claude_settings_fragment(_connector_cli: &Path, install_root: &Path) -> Result<Value> {
    let hook = shell_quote(
        &install_root
            .join("agent-pet-companion-hook.sh")
            .display()
            .to_string(),
    );
    render_json_template(CLAUDE_SETTINGS_TEMPLATE, "__APC_HOOK__", &hook)
}

fn render_json_template(template: &str, placeholder: &str, replacement: &str) -> Result<Value> {
    let mut value: Value = serde_json::from_str(template)?;
    replace_json_string(&mut value, placeholder, replacement);
    Ok(value)
}

fn replace_json_string(value: &mut Value, placeholder: &str, replacement: &str) {
    match value {
        Value::String(text) => *text = text.replace(placeholder, replacement),
        Value::Array(values) => {
            for value in values {
                replace_json_string(value, placeholder, replacement);
            }
        }
        Value::Object(map) => {
            for value in map.values_mut() {
                replace_json_string(value, placeholder, replacement);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn check_codex_studio_skill(path: &Path, install_root: &Path) -> ConnectionCheckItem {
    let path_state = managed_regular_file_state(install_root, path);
    let installed = path_state == ManagedPathState::Safe
        && fs::read(path).is_ok_and(|content| content == PET_STUDIO_SKILL_MD.as_bytes());
    let content_conflict = path_state == ManagedPathState::Safe
        && !installed
        && !codex_studio_skill_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict || content_conflict;
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if conflict {
            "Pet Studio Skill 路径冲突".to_string()
        } else {
            "Pet Studio Skill".to_string()
        },
        if installed {
            CheckStatus::Ok
        } else if path_state == ManagedPathState::Missing {
            CheckStatus::Missing
        } else {
            CheckStatus::NeedsFix
        },
        if installed {
            "与当前 App 模板逐字节一致".to_string()
        } else if conflict {
            format!(
                "路径是符号链接或非普通受管文件，拒绝覆盖：{}",
                path.display()
            )
        } else if path_state == ManagedPathState::Safe {
            format!("已安装旧版本，待更新 {}", path.display())
        } else {
            format!("待写入 {}", path.display())
        },
        Some(if conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn check_exact_connector_file(
    path: &Path,
    label: &str,
    expected: &[u8],
    source: AgentSource,
) -> ConnectionCheckItem {
    let ownership = managed_connector_script_ownership(path, source);
    let contents = if ownership == ManagedConnectorScriptOwnership::Owned {
        fs::read(path).ok()
    } else {
        None
    };
    let status = match (contents.as_deref(), ownership) {
        (Some(contents), ManagedConnectorScriptOwnership::Owned) if contents == expected => {
            CheckStatus::Ok
        }
        (None, ManagedConnectorScriptOwnership::Missing) => CheckStatus::Missing,
        _ => CheckStatus::NeedsFix,
    };
    let name = if status == CheckStatus::NeedsFix
        && ownership == ManagedConnectorScriptOwnership::Foreign
    {
        format!("{label} 路径冲突")
    } else {
        label.to_string()
    };
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        name,
        status,
        match status {
            CheckStatus::Ok => "与当前 App 拥有的完整事件清单和 handler 模板精确一致".to_string(),
            CheckStatus::NeedsFix => {
                if ownership == ManagedConnectorScriptOwnership::Owned {
                    "文件属于 Agent Pet Companion，但不等于当前完整连接器模板；可一键更新"
                        .to_string()
                } else {
                    "目标路径被无法识别为 Agent Pet Companion 的文件或符号链接占用；为保护用户内容，一键修复/卸载不会覆盖或删除它，请先自行移动或备份"
                        .to_string()
                }
            }
            _ => format!("待写入 {}", path.display()),
        },
        Some(if ownership == ManagedConnectorScriptOwnership::Foreign {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn managed_connector_script_ownership(
    path: &Path,
    source: AgentSource,
) -> ManagedConnectorScriptOwnership {
    let Some(root) = path.parent() else {
        return ManagedConnectorScriptOwnership::Foreign;
    };
    match managed_script_root_state(root, source) {
        ManagedPathState::Safe => {}
        ManagedPathState::Missing => return ManagedConnectorScriptOwnership::Missing,
        ManagedPathState::Conflict => return ManagedConnectorScriptOwnership::Foreign,
    }
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return ManagedConnectorScriptOwnership::Missing;
        }
        Err(_) => return ManagedConnectorScriptOwnership::Foreign,
    };
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > MAX_MANAGED_CONNECTOR_SCRIPT_BYTES
    {
        return ManagedConnectorScriptOwnership::Foreign;
    }
    let Ok(content) = fs::read_to_string(path) else {
        return ManagedConnectorScriptOwnership::Foreign;
    };
    let owned = match source {
        AgentSource::Pi => {
            content.contains("APC_PI_CONTRACT_VERSION") && content.contains("\"--source\", \"pi\"")
        }
        AgentSource::Opencode => {
            content.contains("APC_OPENCODE_CONTRACT_VERSION")
                && content.contains("\"--source\", \"opencode\"")
        }
        AgentSource::Codex | AgentSource::ClaudeCode => false,
    };
    if owned {
        ManagedConnectorScriptOwnership::Owned
    } else {
        ManagedConnectorScriptOwnership::Foreign
    }
}

fn write_owned_connector_script(path: &Path, bytes: &[u8], source: AgentSource) -> Result<()> {
    match managed_connector_script_ownership(path, source) {
        ManagedConnectorScriptOwnership::Missing | ManagedConnectorScriptOwnership::Owned => {
            write_file_if_changed(path, bytes)
        }
        ManagedConnectorScriptOwnership::Foreign => Err(PetCoreError::Conflict(format!(
            "拒绝覆盖无法识别为 Agent Pet Companion 的文件或符号链接：{}；请先自行移动或备份",
            path.display()
        ))),
    }
}

fn remove_owned_connector_script(path: &Path, source: AgentSource) -> Result<()> {
    match managed_connector_script_ownership(path, source) {
        ManagedConnectorScriptOwnership::Missing => Ok(()),
        ManagedConnectorScriptOwnership::Owned => {
            fs::remove_file(path)?;
            Ok(())
        }
        ManagedConnectorScriptOwnership::Foreign => Err(PetCoreError::Conflict(format!(
            "拒绝删除无法识别为 Agent Pet Companion 的文件或符号链接：{}；请先自行移动或备份",
            path.display()
        ))),
    }
}

fn remove_owned_codex_connector_files(root: &Path) -> Result<()> {
    if codex_managed_root_state(root) == ManagedPathState::Missing {
        return Ok(());
    }

    let manifest = root.join(".codex-plugin/plugin.json");
    if codex_manifest_is_owned(&manifest, root) {
        fs::remove_file(&manifest)?;
    }
    let hooks = root.join("hooks/hooks.json");
    if codex_hooks_are_owned(&hooks, root) {
        fs::remove_file(&hooks)?;
    }
    let studio = root.join("skills/agent-pet-studio/SKILL.md");
    if codex_studio_skill_is_owned(&studio, root) {
        fs::remove_file(&studio)?;
    }

    let maker_root = root.join("skills/agent-pet-maker");
    let maker_owned = codex_maker_skill_is_owned(root)
        || AGENT_PET_MAKER_FILES
            .iter()
            .any(|(relative_path, expected)| {
                let path = maker_root.join(relative_path);
                managed_regular_file_state(root, &path) == ManagedPathState::Safe
                    && fs::read(path).is_ok_and(|content| content == expected.as_bytes())
            });
    if maker_owned {
        for (relative_path, _) in AGENT_PET_MAKER_FILES {
            let path = maker_root.join(relative_path);
            if managed_regular_file_state(root, &path) == ManagedPathState::Safe {
                fs::remove_file(path)?;
            }
        }
    }

    let install_result = root.join("codex-install-result.json");
    if managed_regular_file_state(root, &install_result) == ManagedPathState::Safe
        && read_regular_json_config(&install_result).is_some_and(|value| {
            value
                .get("status")
                .and_then(Value::as_str)
                .is_some_and(|status| matches!(status, "ok" | "failed" | "skipped"))
        })
    {
        fs::remove_file(install_result)?;
    }

    for directory in [
        maker_root.join("tests"),
        maker_root.join("agents"),
        maker_root.join("scripts"),
        maker_root.join("references"),
        maker_root,
        root.join("skills/agent-pet-studio"),
        root.join("skills"),
        root.join("hooks"),
        root.join(".codex-plugin"),
        root.to_path_buf(),
    ] {
        remove_directory_if_empty(&directory)?;
    }
    Ok(())
}

fn remove_owned_claude_connector_files(root: &Path) -> Result<()> {
    if claude_managed_root_state(root) == ManagedPathState::Missing {
        return Ok(());
    }
    let fragment = root.join("settings.fragment.json");
    if claude_fragment_is_owned(&fragment, root) {
        fs::remove_file(fragment)?;
    }
    let helper = root.join("agent-pet-companion-hook.sh");
    if claude_helper_is_owned(&helper, root) {
        fs::remove_file(helper)?;
    }
    remove_directory_if_empty(root)
}

fn remove_directory_if_empty(path: &Path) -> Result<()> {
    if managed_directory_state(path) != ManagedPathState::Safe {
        return Ok(());
    }
    match fs::remove_dir(path) {
        Ok(()) => Ok(()),
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::NotFound | ErrorKind::DirectoryNotEmpty
            ) =>
        {
            Ok(())
        }
        Err(error) => Err(error.into()),
    }
}

fn check_codex_agent_pet_maker(root: &Path) -> ConnectionCheckItem {
    let skill_root = root.join("skills/agent-pet-maker");
    let managed_directories = [
        (root.to_path_buf(), "plugin root"),
        (root.join("skills"), "skills"),
        (skill_root.clone(), "agent-pet-maker"),
        (skill_root.join("references"), "references"),
        (skill_root.join("scripts"), "scripts"),
        (skill_root.join("agents"), "agents"),
        (skill_root.join("tests"), "tests"),
    ];
    let unsafe_directory = managed_directories.iter().any(|(path, _)| {
        fs::symlink_metadata(path)
            .is_ok_and(|metadata| metadata.file_type().is_symlink() || !metadata.is_dir())
    });
    let unsafe_file = AGENT_PET_MAKER_FILES.iter().any(|(relative_path, _)| {
        fs::symlink_metadata(skill_root.join(relative_path))
            .is_ok_and(|metadata| metadata.file_type().is_symlink() || !metadata.is_file())
    });
    let path_conflict = unsafe_directory || unsafe_file;
    let mut missing_or_outdated = managed_directories
        .iter()
        .filter_map(|(path, label)| {
            let safe = fs::symlink_metadata(path)
                .map(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
                .unwrap_or(false);
            (!safe).then(|| format!("{label}/"))
        })
        .collect::<Vec<_>>();
    let directories_are_safe = missing_or_outdated.is_empty();
    if directories_are_safe {
        missing_or_outdated.extend(AGENT_PET_MAKER_FILES.iter().filter_map(
            |(relative_path, expected)| {
                let path = skill_root.join(relative_path);
                let is_regular_file = fs::symlink_metadata(&path)
                    .map(|metadata| metadata.is_file() && !metadata.file_type().is_symlink())
                    .unwrap_or(false);
                if is_regular_file
                    && fs::read_to_string(&path)
                        .map(|actual| actual == *expected)
                        .unwrap_or(false)
                {
                    None
                } else {
                    Some(relative_path.to_string())
                }
            },
        ));
    }
    let helper_is_executable = directories_are_safe
        && fs::symlink_metadata(skill_root.join("scripts/petpack_workspace.py"))
            .map(|metadata| {
                metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.permissions().mode() & 0o111 != 0
            })
            .unwrap_or(false);

    let installed = missing_or_outdated.is_empty() && helper_is_executable;
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if path_conflict {
            "Agent Pet Maker Skill 路径冲突".to_string()
        } else {
            "Agent Pet Maker Skill".to_string()
        },
        if installed {
            CheckStatus::Ok
        } else if fs::symlink_metadata(&skill_root).is_err() {
            CheckStatus::Missing
        } else {
            CheckStatus::NeedsFix
        },
        if installed {
            format!(
                "configured: Codex plugin 可原生发现完整 agent-pet-maker（{} 个文件）",
                AGENT_PET_MAKER_FILES.len()
            )
        } else if path_conflict {
            format!(
                "受管 Skill 目录或文件是符号链接/非预期类型；拒绝一键覆盖：{}",
                skill_root.display()
            )
        } else if fs::symlink_metadata(&skill_root).is_ok() {
            let mut reasons = missing_or_outdated;
            if !helper_is_executable {
                reasons.push("scripts/petpack_workspace.py（不可执行）".to_string());
            }
            format!("已安装不完整或旧版本，待更新：{}", reasons.join("、"))
        } else {
            format!("待写入 {}", skill_root.display())
        },
        Some(if path_conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn check_opencode_server(run_runtime_smoke: bool) -> ConnectionCheckItem {
    let opted_in = std::env::var("APC_VALIDATE_REAL_OPENCODE_SERVER")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false);
    if !run_runtime_smoke || !opted_in {
        return ConnectionCheckItem::new(
            CheckCode::HostServer,
            "OpenCode Server",
            CheckStatus::NotRequired,
            "独立本地 TUI 不要求额外 Server；但 attach/run --attach 的事件发生在目标 Server 侧，必须由该 Server 加载 Plugin，本地 canary 不能外推。设置 APC_VALIDATE_REAL_OPENCODE_SERVER=1 仅探测本机新建 Server 的 /global/health",
            Some(RecoveryAction::Recheck),
        );
    }

    probe_opencode_server()
}

pub fn probe_opencode_server() -> ConnectionCheckItem {
    let Some(opencode) = agent_command_path(AgentSource::Opencode) else {
        return ConnectionCheckItem::new(
            CheckCode::HostServer,
            "OpenCode Server",
            CheckStatus::Missing,
            "未在 PATH 中检测到 opencode",
            Some(RecoveryAction::Recheck),
        );
    };

    let port = 42_000 + (std::process::id() % 1_000);
    let script = r#"set -eu
"$OPENCODE_BIN" serve --hostname 127.0.0.1 --port "$OPENCODE_PORT" >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" >/dev/null 2>&1 || true; wait "$server_pid" >/dev/null 2>&1 || true' EXIT INT TERM
i=0
while [ "$i" -lt 40 ]; do
  if body=$(curl --silent --show-error --fail --max-time 1 "http://127.0.0.1:$OPENCODE_PORT/global/health" 2>/dev/null); then
    printf '%s' "$body"
    exit 0
  fi
  i=$((i + 1))
  sleep 0.1
done
exit 1
"#;
    let output = run_bounded(
        ProcessSpec::connector("/bin/sh", ["-c", script])
            .with_env("OPENCODE_BIN", opencode)
            .with_env("OPENCODE_PORT", port.to_string()),
    );
    match output {
        Ok(output) if output.status.success() && !output.timed_out => {
            let healthy = serde_json::from_slice::<Value>(&output.stdout)
                .ok()
                .and_then(|value| value.get("healthy").and_then(Value::as_bool))
                == Some(true);
            ConnectionCheckItem::new(
                CheckCode::HostServer,
                "OpenCode Server",
                if healthy {
                    CheckStatus::Ok
                } else {
                    CheckStatus::NeedsFix
                },
                if healthy {
                    "runtime_verified: bounded opencode serve 返回有效 /global/health JSON"
                        .to_string()
                } else {
                    "OpenCode /global/health 响应不是 {healthy:true} JSON".to_string()
                },
                Some(RecoveryAction::Recheck),
            )
        }
        Ok(output) => ConnectionCheckItem::new(
            CheckCode::HostServer,
            "OpenCode Server",
            CheckStatus::NeedsFix,
            if output.timed_out {
                "OpenCode /global/health 真实探测在 5 秒后超时，进程组已终止".to_string()
            } else {
                format!(
                    "OpenCode /global/health 探测失败（exit={:?}）",
                    output.status.code()
                )
            },
            Some(RecoveryAction::Recheck),
        ),
        Err(error) => ConnectionCheckItem::new(
            CheckCode::HostServer,
            "OpenCode Server",
            CheckStatus::NeedsFix,
            format!("OpenCode CLI 无法执行：{error}"),
            Some(RecoveryAction::Recheck),
        ),
    }
}

fn check_pi_extension_runtime(
    paths: &AppPaths,
    install_root: &Path,
    probe_cwd: &Path,
) -> ConnectionCheckItem {
    let label = "Extension 运行时";
    if !connector_runtime_smoke_should_run() {
        return ConnectionCheckItem::new(
            CheckCode::HostRuntime,
            label,
            CheckStatus::Unverified,
            "检测到外部事件 CLI 覆盖，跳过内置运行时加载自检",
            Some(RecoveryAction::Recheck),
        );
    }

    let Some(pi) = agent_command_path(AgentSource::Pi) else {
        return ConnectionCheckItem::new(
            CheckCode::HostRuntime,
            label,
            CheckStatus::Missing,
            "未检测到 pi，无法由真实宿主加载 Extension",
            Some(RecoveryAction::Recheck),
        );
    };

    let extension = install_root.join("agent-pet-companion.ts");
    if !extension.is_file() {
        return ConnectionCheckItem::new(
            CheckCode::HostRuntime,
            label,
            CheckStatus::NeedsFix,
            format!("Extension 缺失 {}", extension.display()),
            Some(RecoveryAction::Recheck),
        );
    }

    let probe_id = format!("apc-probe-{}", uuid::Uuid::now_v7().hyphenated());
    let output = run_bounded(pi_native_probe_spec(pi, paths, probe_cwd, &probe_id));
    let host_ok = output
        .as_ref()
        .is_ok_and(|output| output.status.success() && !output.timed_out);
    let event_seen =
        output.is_ok() && wait_for_connector_probe_session(paths, AgentSource::Pi, &probe_id);
    ConnectionCheckItem::new(
        CheckCode::HostRuntime,
        label,
        if event_seen && host_ok {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        if event_seen && host_ok {
            "真实 pi --offline RPC 宿主已加载全局 Extension，并回传 connector.probe（无模型调用）"
                .to_string()
        } else if event_seen {
            "Pi Extension 已回传当前 connector.probe，但宿主未正常退出；可能存在 project trust、启动参数或配置错误，不能标记为已验证"
                .to_string()
        } else if host_ok {
            "Pi 宿主已启动，但未收到 Extension connector.probe；请重启 Pi/检查 Extension 加载"
                .to_string()
        } else if output.as_ref().is_ok_and(|output| output.timed_out) {
            format!(
                "真实 Pi 宿主在 {} 秒内未完成最小化 Extension 加载与退出",
                PI_NATIVE_PROBE_TIMEOUT.as_secs()
            )
        } else if let Ok(output) = output.as_ref() {
            format!(
                "真实 Pi 宿主未正常退出（exit={:?}）；未把本地通道或旧回执误判为 Extension 已加载",
                output.status.code()
            )
        } else {
            "无法启动真实 Pi 宿主加载检查".to_string()
        },
        Some(RecoveryAction::Recheck),
    )
}

fn pi_native_probe_spec(
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

fn check_opencode_plugin_runtime(
    paths: &AppPaths,
    install_root: &Path,
    probe_cwd: &Path,
) -> ConnectionCheckItem {
    let label = "Plugin 运行时";
    if !connector_runtime_smoke_should_run() {
        return ConnectionCheckItem::new(
            CheckCode::HostRuntime,
            label,
            CheckStatus::Unverified,
            "检测到外部事件 CLI 覆盖，跳过内置运行时加载自检",
            Some(RecoveryAction::Recheck),
        );
    }

    let Some(opencode) = agent_command_path(AgentSource::Opencode) else {
        return ConnectionCheckItem::new(
            CheckCode::HostRuntime,
            label,
            CheckStatus::Missing,
            "未检测到 opencode，无法由真实宿主加载 Plugin",
            Some(RecoveryAction::Recheck),
        );
    };

    let plugin = install_root.join("agent-pet-companion.js");
    if !plugin.is_file() {
        return ConnectionCheckItem::new(
            CheckCode::HostRuntime,
            label,
            CheckStatus::NeedsFix,
            format!("Plugin 缺失 {}", plugin.display()),
            Some(RecoveryAction::Recheck),
        );
    }

    let probe_id = format!("apc-probe-{}", uuid::Uuid::now_v7().hyphenated());
    let output = run_bounded(
        ProcessSpec::new(&opencode, ["debug", "info"], OPENCODE_NATIVE_PROBE_TIMEOUT)
            .with_env("APC_HOME", &paths.home)
            .with_env("APC_CONNECTOR_PROBE", "1")
            .with_env("APC_CONNECTOR_PROBE_ID", &probe_id)
            .with_current_dir(probe_cwd),
    );
    let host_reports_plugin = output.as_ref().is_ok_and(|output| {
        output.status.success()
            && !output.timed_out
            && opencode_debug_reports_plugin(&output.stdout, &plugin)
    });
    let event_seen =
        output.is_ok() && wait_for_connector_probe_session(paths, AgentSource::Opencode, &probe_id);
    ConnectionCheckItem::new(
        CheckCode::HostRuntime,
        label,
        if host_reports_plugin && event_seen {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        if host_reports_plugin && event_seen {
            "OpenCode debug info 已精确报告全局 Plugin 路径，且真实宿主已执行并回传 connector.probe（host_loaded）；普通任务活动与同会话生命周期由独立回执继续验证"
                .to_string()
        } else if event_seen {
            "OpenCode Plugin 已由真实宿主执行并回传 connector.probe；debug 输出未列出预期路径，请检查多配置目录覆盖"
                .to_string()
        } else if host_reports_plugin {
            "OpenCode 宿主报告了 Plugin 路径，但未收到 connector.probe；请重启 OpenCode".to_string()
        } else if output.as_ref().is_ok_and(|output| output.timed_out) {
            format!(
                "OpenCode 宿主在 {} 秒内未完成 Plugin 发现；请先确认“检查目录访问”，再重试",
                OPENCODE_NATIVE_PROBE_TIMEOUT.as_secs()
            )
        } else if let Ok(output) = output.as_ref() {
            if !output.status.success() {
                format!(
                    "opencode debug info 未正常退出（exit={:?}）；未把本地通道或旧回执误判为 Plugin 已加载",
                    output.status.code()
                )
            } else {
                "opencode debug info 已正常退出，但未精确报告当前 Agent Pet Companion Plugin 路径"
                    .to_string()
            }
        } else {
            "无法启动 OpenCode 真实宿主 Plugin 检查".to_string()
        },
        Some(RecoveryAction::Recheck),
    )
}

fn opencode_debug_reports_plugin(stdout: &[u8], plugin: &Path) -> bool {
    let stdout = String::from_utf8_lossy(stdout);
    let raw_path = plugin.display().to_string();
    let file_url = file_url_for_path(plugin);
    stdout.lines().any(|line| {
        let token = line.trim().strip_prefix("- ").unwrap_or(line.trim());
        token == raw_path || file_url.as_deref() == Some(token)
    })
}

fn file_url_for_path(path: &Path) -> Option<String> {
    if !path.is_absolute() {
        return None;
    }
    let mut encoded = String::from("file://");
    for byte in path.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric()
            || matches!(
                *byte,
                b'/' | b'-'
                    | b'.'
                    | b'_'
                    | b'~'
                    | b':'
                    | b'@'
                    | b'!'
                    | b'$'
                    | b'&'
                    | b'\''
                    | b'('
                    | b')'
                    | b'*'
                    | b'+'
                    | b','
                    | b';'
                    | b'='
            )
        {
            encoded.push(char::from(*byte));
        } else {
            encoded.push('%');
            encoded.push_str(&format!("{byte:02X}"));
        }
    }
    Some(encoded)
}

fn wait_for_connector_probe_session(paths: &AppPaths, source: AgentSource, probe_id: &str) -> bool {
    wait_for_connector_session_event(paths, source, probe_id, "connector.probe", true)
}

fn wait_for_connector_session_event(
    paths: &AppPaths,
    source: AgentSource,
    session_id: &str,
    source_event: &str,
    diagnostic: bool,
) -> bool {
    let database = Database::new(&paths.db_path);
    for _ in 0..20 {
        if database
            .connector_event_was_received(
                source,
                session_id,
                source_event,
                diagnostic,
                contract_version_for_source(source),
            )
            .is_ok_and(|received| received)
        {
            return true;
        }
        thread::sleep(Duration::from_millis(150));
    }
    false
}

fn connector_runtime_smoke_should_run() -> bool {
    absolute_env_path("APC_CONNECTOR_CLI_PATH").is_none()
        || std::env::var("APC_CONNECTOR_RUNTIME_SMOKE")
            .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
            .unwrap_or(false)
}

fn check_codex_marketplace_entry() -> ConnectionCheckItem {
    let path = codex_marketplace_path();
    let state = codex_marketplace_entry_state(&path);

    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if state == CodexMarketplaceEntryState::Conflict {
            "Codex marketplace 配置冲突".to_string()
        } else {
            "Codex marketplace".to_string()
        },
        if state == CodexMarketplaceEntryState::Current {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        match state {
            CodexMarketplaceEntryState::Current => {
                format!("完整 owned entry 已精确注册：{}", path.display())
            }
            CodexMarketplaceEntryState::OwnedOutdated => format!(
                "本地 source/path 属于 Agent Pet Companion，但 policy/category 或其他 owned 字段已过期；可安全更新 {}",
                path.display()
            ),
            CodexMarketplaceEntryState::Missing => format!("待注册 {}", path.display()),
            CodexMarketplaceEntryState::Conflict => format!(
                "同名 entry、JSON 结构或配置路径不属于当前 Agent Pet Companion；拒绝一键覆盖/删除：{}",
                path.display()
            ),
        },
        Some(if state == CodexMarketplaceEntryState::Conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn codex_marketplace_entry() -> Value {
    json!({
        "name": "agent-pet-companion",
        "source": {
            "source": "local",
            "path": codex_marketplace_plugin_source_path()
        },
        "policy": {
            "installation": "AVAILABLE",
            "authentication": "ON_INSTALL"
        },
        "category": "Productivity"
    })
}

fn codex_marketplace_entry_state(path: &Path) -> CodexMarketplaceEntryState {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => metadata,
        Ok(_) => return CodexMarketplaceEntryState::Conflict,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return CodexMarketplaceEntryState::Missing;
        }
        Err(_) => return CodexMarketplaceEntryState::Conflict,
    };
    if metadata.len() > MAX_MANAGED_CONNECTOR_SCRIPT_BYTES {
        return CodexMarketplaceEntryState::Conflict;
    }
    let Ok(value) = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .ok_or(())
    else {
        return CodexMarketplaceEntryState::Conflict;
    };
    let Some(plugins) = value.get("plugins").and_then(Value::as_array) else {
        return CodexMarketplaceEntryState::Conflict;
    };
    let matches = plugins
        .iter()
        .filter(|plugin| plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion"))
        .collect::<Vec<_>>();
    let Some(entry) = matches.first().copied() else {
        return CodexMarketplaceEntryState::Missing;
    };
    if matches.len() != 1 {
        return CodexMarketplaceEntryState::Conflict;
    }
    if *entry == codex_marketplace_entry() {
        return CodexMarketplaceEntryState::Current;
    }
    let owned_source = entry
        .get("source")
        .and_then(Value::as_object)
        .is_some_and(|source| {
            source.get("source").and_then(Value::as_str) == Some("local")
                && source.get("path").and_then(Value::as_str)
                    == Some(codex_marketplace_plugin_source_path().as_str())
        });
    if owned_source {
        CodexMarketplaceEntryState::OwnedOutdated
    } else {
        CodexMarketplaceEntryState::Conflict
    }
}

fn codex_marketplace_entry_path(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .and_then(|value| value.get("plugins").and_then(Value::as_array).cloned())
        .and_then(|plugins| {
            plugins
                .iter()
                .find(|plugin| {
                    plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion")
                })
                .and_then(|plugin| {
                    plugin
                        .get("source")
                        .and_then(|source| source.get("path"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                })
        })
}

fn check_codex_hook_trust(probe_cwd: &Path) -> ConnectionCheckItem {
    if codex_command_path().is_none() {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            "Codex Hook Trust",
            CheckStatus::Missing,
            "未检测到 codex 命令",
            Some(RecoveryAction::Recheck),
        );
    }

    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            "Codex Hook Trust",
            CheckStatus::Unverified,
            "测试环境无法确认用户是否已信任 Codex plugin hooks",
            Some(RecoveryAction::Recheck),
        );
    }

    let probe = app_server::probe_codex_agent_pet_hooks(probe_cwd);
    let observed = probe
        .hooks
        .iter()
        .map(|hook| hook.event_name.as_str())
        .collect::<BTreeSet<_>>();
    let exact_contract = probe.hook_count == CODEX_APP_SERVER_HOOK_EVENTS.len()
        && CODEX_APP_SERVER_HOOK_EVENTS
            .iter()
            .all(|event| observed.contains(event));
    let disabled_count = probe.hooks.iter().filter(|hook| !hook.enabled).count();
    let modified_count = probe
        .hooks
        .iter()
        .filter(|hook| {
            matches!(
                &hook.trust_status,
                app_server::CodexHookTrustStatus::Modified
            )
        })
        .count();
    let untrusted_count = probe
        .hooks
        .iter()
        .filter(|hook| {
            matches!(
                &hook.trust_status,
                app_server::CodexHookTrustStatus::Untrusted
            )
        })
        .count();

    let (status, detail) = if !probe.app_server_available {
        (
            CheckStatus::Missing,
            "Codex App Server 不可用，无法读取 hooks/list 信任状态".to_string(),
        )
    } else if !probe.completed {
        (
            CheckStatus::Unverified,
            "Codex hooks/list 未完成；未把 plugin list 的 ON_INSTALL 误判为已信任".to_string(),
        )
    } else if !probe.discovered {
        (
            CheckStatus::NeedsFix,
            "当前 Codex 宿主未发现 Agent Pet Companion Hooks；请修复插件并重新加载宿主".to_string(),
        )
    } else if !probe.all_enabled || !probe.all_trusted {
        (
            CheckStatus::NeedsFix,
            format!(
                "Codex hooks/list 精确检测：未启用 {disabled_count}、已修改 {modified_count}、未信任 {untrusted_count}（共 {}）；App 更新或连接器内容变化后必须在当前宿主重新审查并信任",
                probe.hook_count
            ),
        )
    } else if !exact_contract {
        (
            CheckStatus::NeedsFix,
            format!(
                "Codex 已信任 {} 个 Hook，但与当前 10 事件契约不一致；请一键修复后重新信任",
                probe.hook_count
            ),
        )
    } else {
        (
            CheckStatus::Ok,
            format!(
                "hooks/list 已确认 10/10 Hook 启用且 trusted/managed（宿主：{}）",
                probe.host_source.as_deref().unwrap_or("当前 Codex")
            ),
        )
    };
    ConnectionCheckItem::new(
        CheckCode::HostVerification,
        "Codex Hook Trust",
        status,
        detail,
        Some(RecoveryAction::Recheck),
    )
}

fn check_codex_hook_trust_light(install_root: &Path) -> ConnectionCheckItem {
    let hooks_ready = install_root.join("hooks/hooks.json").is_file();
    ConnectionCheckItem::new(
        CheckCode::HostVerification,
        "Codex Hook Trust",
        CheckStatus::Unverified,
        if hooks_ready {
            "本地 hooks 已写入；点击检查并在 Codex 中信任后才可精确同步实时工具活动".to_string()
        } else {
            "待写入 hooks 并在 Codex 中信任".to_string()
        },
        Some(RecoveryAction::Recheck),
    )
}

fn check_codex_plugin_installed() -> ConnectionCheckItem {
    let Some(codex) = codex_command_path() else {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            "Codex 插件安装",
            CheckStatus::Missing,
            "未检测到 codex 命令",
            Some(RecoveryAction::Recheck),
        );
    };

    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            "Codex 插件安装",
            CheckStatus::NeedsFix,
            "测试环境跳过 codex plugin add",
            Some(RecoveryAction::Recheck),
        );
    }

    let installed = run_bounded(ProcessSpec::connector(&codex, ["plugin", "list", "--json"]))
        .ok()
        .filter(|output| !output.timed_out && output.status.success())
        .and_then(|output| codex_plugin_json_reports_installed(&output.stdout))
        .unwrap_or_else(|| {
            run_bounded(ProcessSpec::connector(codex, ["plugin", "list"]))
                .ok()
                .filter(|output| !output.timed_out && output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .map(|stdout| codex_plugin_text_reports_installed(&stdout))
                .unwrap_or(false)
        });

    ConnectionCheckItem::new(
        CheckCode::HostVerification,
        "Codex 插件安装",
        if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        if installed {
            "Codex 已安装并启用插件".to_string()
        } else {
            "待执行 codex plugin add agent-pet-companion@personal".to_string()
        },
        Some(RecoveryAction::Recheck),
    )
}

fn check_codex_plugin_installed_light(install_root: &Path) -> ConnectionCheckItem {
    let plugin_source_ready = install_root.join(".codex-plugin/plugin.json").is_file()
        && install_root.join("hooks/hooks.json").is_file();
    let marketplace_ready = codex_marketplace_entry_path(&codex_marketplace_path()).as_deref()
        == Some(codex_marketplace_plugin_source_path().as_str());

    let ready = plugin_source_ready && marketplace_ready;
    ConnectionCheckItem::new(
        CheckCode::HostVerification,
        "Codex 插件安装",
        if ready {
            CheckStatus::Unverified
        } else {
            CheckStatus::NeedsFix
        },
        if ready {
            "本地插件源已注册，点击检查确认 Codex 已启用插件".to_string()
        } else {
            "待注册本地插件源或执行一键修复".to_string()
        },
        Some(RecoveryAction::Recheck),
    )
}

fn check_codex_app_server() -> ConnectionCheckItem {
    let probe = app_server::probe_codex_app_server();
    let initialized = probe
        .get("initialized")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mode = probe
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("missing");

    let status = if initialized {
        CheckStatus::Ok
    } else if mode == "missing" {
        CheckStatus::Missing
    } else {
        CheckStatus::NeedsFix
    };
    let detail = if initialized {
        let source = probe
            .get("command_source")
            .and_then(Value::as_str)
            .unwrap_or("configured");
        format!("stdio 初始化成功（{source}）")
    } else {
        probe
            .get("error")
            .or_else(|| probe.get("detail"))
            .and_then(Value::as_str)
            .unwrap_or("Codex App Server 不可用")
            .to_string()
    };

    ConnectionCheckItem::new(
        CheckCode::AppServer,
        "Codex App Server",
        status,
        detail,
        Some(RecoveryAction::Recheck),
    )
}

fn check_codex_app_server_light() -> ConnectionCheckItem {
    let check = app_server::codex_app_server_command_check();
    let available = check
        .get("available")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mode = check
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("missing");

    let status = if available {
        CheckStatus::Unverified
    } else if mode == "missing" {
        CheckStatus::Missing
    } else {
        CheckStatus::NeedsFix
    };
    let detail = if available {
        let source = check
            .get("command_source")
            .and_then(Value::as_str)
            .unwrap_or("configured");
        format!("命令已定位（{source}），点击检查验证 stdio 初始化")
    } else {
        check
            .get("detail")
            .and_then(Value::as_str)
            .unwrap_or("Codex App Server 不可用")
            .to_string()
    };

    ConnectionCheckItem::new(
        CheckCode::AppServer,
        "Codex App Server",
        status,
        detail,
        Some(RecoveryAction::Recheck),
    )
}

fn codex_plugin_json_reports_installed(stdout: &[u8]) -> Option<bool> {
    let value: Value = serde_json::from_slice(stdout).ok()?;
    let installed = value.get("installed")?.as_array()?;
    Some(installed.iter().any(|plugin| {
        let id_matches =
            plugin.get("pluginId").and_then(Value::as_str) == Some("agent-pet-companion@personal");
        let name_matches = plugin.get("name").and_then(Value::as_str)
            == Some("agent-pet-companion")
            && plugin.get("marketplaceName").and_then(Value::as_str) == Some("personal");
        let installed = plugin
            .get("installed")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let enabled = plugin
            .get("enabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        (id_matches || name_matches) && installed && enabled
    }))
}

fn codex_plugin_json_reports_present(stdout: &[u8]) -> Option<bool> {
    let value: Value = serde_json::from_slice(stdout).ok()?;
    let installed = value.get("installed")?.as_array()?;
    Some(installed.iter().any(|plugin| {
        let id_matches =
            plugin.get("pluginId").and_then(Value::as_str) == Some("agent-pet-companion@personal");
        let name_matches = plugin.get("name").and_then(Value::as_str)
            == Some("agent-pet-companion")
            && plugin.get("marketplaceName").and_then(Value::as_str) == Some("personal");
        let installed = plugin
            .get("installed")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        (id_matches || name_matches) && installed
    }))
}

fn codex_plugin_text_reports_installed(stdout: &str) -> bool {
    stdout.lines().any(|line| {
        line.contains("agent-pet-companion@personal")
            && line.contains("installed")
            && line.contains("enabled")
    })
}

fn codex_plugin_text_reports_present(stdout: &str) -> bool {
    stdout.lines().any(|line| {
        line.contains("agent-pet-companion@personal")
            && line.contains("installed")
            && !line.contains("not installed")
    })
}

fn check_claude_auth_status(run_runtime_smoke: bool) -> ConnectionCheckItem {
    let label = "Claude 登录状态";
    if !run_runtime_smoke || absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            label,
            CheckStatus::NotRequired,
            "轻量/测试环境未调用 claude auth status；登录状态与 Hook 权限分开判断",
            Some(RecoveryAction::Recheck),
        );
    }
    let Some(claude) = agent_command_path(AgentSource::ClaudeCode) else {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            label,
            CheckStatus::Missing,
            "未检测到 claude 命令",
            Some(RecoveryAction::Recheck),
        );
    };
    let output = run_bounded(ProcessSpec::connector(claude, ["auth", "status", "--json"]));
    let value = output
        .ok()
        .filter(|output| output.status.success() && !output.timed_out)
        .and_then(|output| serde_json::from_slice::<Value>(&output.stdout).ok());
    let logged_in = value
        .as_ref()
        .and_then(|value| value.get("loggedIn"))
        .and_then(Value::as_bool);
    ConnectionCheckItem::new(
        CheckCode::HostVerification,
        label,
        match logged_in {
            Some(true) => CheckStatus::Ok,
            // OAuth login is not a connector prerequisite: Claude Code can be
            // validly authenticated through Bedrock, Vertex, Foundry, or an
            // enterprise gateway. Native Hook canary is the authority here.
            Some(false) => CheckStatus::NotRequired,
            None => CheckStatus::NotRequired,
        },
        match logged_in {
            Some(true) => {
                "claude auth status --json 已确认登录；这不等同于 Hooks 已启用".to_string()
            }
            Some(false) => "未检测到 Anthropic OAuth 登录；Bedrock/Vertex/Foundry/企业网关可能仍有效。此项仅作提示，连接可用性由无模型 Hook canary 判定".to_string(),
            None => "无法从 claude auth status --json 获取结构化登录状态".to_string(),
        },
        Some(RecoveryAction::Recheck),
    )
}

fn check_claude_hooks_policy() -> ConnectionCheckItem {
    let user_settings = read_regular_json_config(&claude_settings_path());
    let user_disabled = user_settings
        .as_ref()
        .and_then(|settings| settings.get("disableAllHooks"))
        .and_then(Value::as_bool)
        == Some(true);

    let managed_path =
        PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json");
    let managed_settings = if managed_path.is_file() {
        match fs::read_to_string(&managed_path)
            .ok()
            .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        {
            Some(value) => Some(Ok(value)),
            None => Some(Err(())),
        }
    } else {
        None
    };
    let managed_invalid = matches!(managed_settings, Some(Err(())));
    let managed_value = managed_settings.and_then(std::result::Result::ok);
    let managed_disabled = managed_value
        .as_ref()
        .and_then(|settings| settings.get("disableAllHooks"))
        .and_then(Value::as_bool)
        == Some(true);
    let managed_only = managed_value
        .as_ref()
        .and_then(|settings| settings.get("allowManagedHooksOnly"))
        .and_then(Value::as_bool)
        == Some(true);

    let blocked = user_disabled || managed_disabled || managed_only || managed_invalid;
    let detail = if user_disabled {
        "~/.claude/settings.json 的 disableAllHooks=true 会禁用 Agent Pet Companion Hooks"
            .to_string()
    } else if managed_disabled {
        "系统 managed settings 的 disableAllHooks=true 禁用了 Hooks；请联系管理员".to_string()
    } else if managed_only {
        "系统 allowManagedHooksOnly=true 会阻止当前 user-level Hooks；请联系管理员允许".to_string()
    } else if managed_invalid {
        format!("无法解析公开 managed settings：{}", managed_path.display())
    } else {
        "用户 settings 与公开 managed-settings.json 中未见禁用；server-managed、MDM 与 managed-settings.d 等来源不在此静态结论内，最终由 canary 及 /status、/hooks 判断"
            .to_string()
    };
    ConnectionCheckItem::new(
        CheckCode::ClaudeHooksPolicy,
        "Claude Hooks Policy",
        if blocked {
            CheckStatus::NeedsFix
        } else {
            CheckStatus::Ok
        },
        detail,
        Some(RecoveryAction::Recheck),
    )
}

fn check_claude_hook_runtime(paths: &AppPaths, probe_cwd: &Path) -> ConnectionCheckItem {
    let label = "Claude Hook 真实触发";
    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            label,
            CheckStatus::Unverified,
            "测试配置目录不启动真实 Claude 宿主",
            Some(RecoveryAction::Recheck),
        );
    }
    let Some(claude) = agent_command_path(AgentSource::ClaudeCode) else {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            label,
            CheckStatus::Missing,
            "未检测到 claude 命令",
            Some(RecoveryAction::Recheck),
        );
    };
    if !paths.socket_path.exists() || UnixStream::connect(&paths.socket_path).is_err() {
        return ConnectionCheckItem::new(
            CheckCode::HostVerification,
            label,
            CheckStatus::NeedsFix,
            "PetCore socket 未连接，无法接收 Claude canary",
            Some(RecoveryAction::Recheck),
        );
    }

    let session_id = uuid::Uuid::now_v7().hyphenated().to_string();
    let output = run_bounded(
        ProcessSpec::new(
            claude,
            ["--init-only", "--session-id", session_id.as_str()],
            CLAUDE_NATIVE_PROBE_TIMEOUT,
        )
        .with_env("APC_HOME", &paths.home)
        .with_env("APC_CONNECTOR_DIAGNOSTIC", "1")
        .with_current_dir(probe_cwd),
    );
    let host_ok = output
        .as_ref()
        .is_ok_and(|output| output.status.success() && !output.timed_out);
    let database = Database::new(&paths.db_path);
    let mut received = false;
    if output.is_ok() {
        for _ in 0..16 {
            if database
                .connector_event_was_received(
                    AgentSource::ClaudeCode,
                    &session_id,
                    "SessionStart",
                    true,
                    CLAUDE_HOOKS_CONTRACT_VERSION,
                )
                .is_ok_and(|received| received)
            {
                received = true;
                break;
            }
            thread::sleep(Duration::from_millis(150));
        }
    }
    ConnectionCheckItem::new(
        CheckCode::HostVerification,
        label,
        if host_ok && received {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        if host_ok && received {
            "claude --init-only 已由真实宿主触发 SessionStart 并回传诊断事件（无模型调用）"
                .to_string()
        } else if received {
            "Claude Hook 已回传当前 SessionStart，但 --init-only 宿主未正常完成；登录、provider 或策略仍可能阻断真实任务，不能标记为已验证"
                .to_string()
        } else if host_ok {
            "Claude canary 已退出，但未收到 SessionStart；请检查 /hooks、policy、--safe-mode/--bare"
                .to_string()
        } else if output.as_ref().is_ok_and(|output| output.timed_out) {
            format!(
                "Claude --init-only 在 {} 秒内未退出；请先确认“检查目录访问”，再检查 /status、/hooks 与 policy",
                CLAUDE_NATIVE_PROBE_TIMEOUT.as_secs()
            )
        } else if let Ok(output) = output.as_ref() {
            format!(
                "Claude --init-only 未正常退出（exit={:?}）；未把本地通道或旧回执误判为 Hook 已加载",
                output.status.code()
            )
        } else {
            "无法启动 Claude --init-only canary；未把本地 CLI 自注入当作真实 Hook".to_string()
        },
        Some(RecoveryAction::Recheck),
    )
}

fn check_claude_settings(connector_cli: &Path, install_root: &Path) -> ConnectionCheckItem {
    let settings_path = claude_settings_path();
    let path_state = config_file_path_state(&settings_path);
    let expected = rendered_claude_settings_fragment(connector_cli, install_root).ok();
    let installed = path_state == ManagedPathState::Safe
        && read_regular_json_config(&settings_path)
            .zip(expected)
            .is_some_and(|(settings, expected)| {
                claude_settings_match_owned_fragment(&settings, &expected)
            });
    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if path_state == ManagedPathState::Conflict {
            "Claude settings.json 配置冲突".to_string()
        } else {
            "Claude settings.json".to_string()
        },
        if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        if installed {
            format!(
                "configured: 27 个 APC-owned group 与 quiet/sync/2s 模板逐项精确一致，且无遗留 APC 命令：{}（真实触发另由 canary 验证）",
                settings_path.display()
            )
        } else if path_state == ManagedPathState::Conflict {
            format!(
                "settings.json 或其配置目录是符号链接/非普通路径；拒绝一键覆盖或删除：{}",
                settings_path.display()
            )
        } else {
            format!(
                "待合并或升级 {}（事件 CLI：{}）",
                settings_path.display(),
                connector_cli.display()
            )
        },
        Some(if path_state == ManagedPathState::Conflict {
            RecoveryAction::Recheck
        } else {
            RecoveryAction::ConfirmManagedRepair
        }),
    )
}

fn claude_settings_match_owned_fragment(settings: &Value, expected_fragment: &Value) -> bool {
    let Some(actual_hooks) = settings.get("hooks").and_then(Value::as_object) else {
        return false;
    };
    let Some(expected_hooks) = expected_fragment.get("hooks").and_then(Value::as_object) else {
        return false;
    };

    for (event, actual_groups) in actual_hooks {
        let Some(actual_groups) = actual_groups.as_array() else {
            return false;
        };
        let owned_groups = actual_groups
            .iter()
            .filter(|group| value_contains_apparent_claude_connector(group))
            .collect::<Vec<_>>();
        match expected_hooks.get(event).and_then(Value::as_array) {
            Some(expected_groups) => {
                if owned_groups.len() != expected_groups.len()
                    || !owned_groups
                        .iter()
                        .zip(expected_groups)
                        .all(|(actual, expected)| *actual == expected)
                {
                    return false;
                }
            }
            None if !owned_groups.is_empty() => return false,
            None => {}
        }
    }

    expected_hooks.keys().all(|event| {
        actual_hooks
            .get(event)
            .and_then(Value::as_array)
            .is_some_and(|groups| {
                groups
                    .iter()
                    .filter(|group| value_contains_apparent_claude_connector(group))
                    .count()
                    == 1
            })
    })
}

fn value_contains_apparent_claude_connector(value: &Value) -> bool {
    match value {
        Value::Object(map) => {
            map.get("command")
                .and_then(Value::as_str)
                .is_some_and(|command| {
                    command.contains("agent hook --source claude_code")
                        || command.contains("agent-pet-companion-hook.sh")
                })
                || map.values().any(value_contains_apparent_claude_connector)
        }
        Value::Array(values) => values.iter().any(value_contains_apparent_claude_connector),
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => false,
    }
}

fn check_event_channel(paths: &AppPaths, connector_cli: &Path) -> ConnectionCheckItem {
    let cli_ready = connector_cli.is_file();
    let socket_ready =
        paths.socket_path.exists() && UnixStream::connect(&paths.socket_path).is_ok();
    let status = if cli_ready && socket_ready {
        CheckStatus::Ok
    } else {
        CheckStatus::NeedsFix
    };
    let detail = match (cli_ready, socket_ready) {
        (true, true) => format!(
            "事件 CLI 可用，socket 已连接 {}",
            paths.socket_path.display()
        ),
        (false, true) => format!("事件 CLI 缺失 {}", connector_cli.display()),
        (true, false) => format!("PetCore socket 未连接 {}", paths.socket_path.display()),
        (false, false) => format!("事件 CLI 和 socket 待修复：{}", connector_cli.display()),
    };

    ConnectionCheckItem::new(
        CheckCode::EventDelivery,
        "事件回传",
        status,
        detail,
        Some(RecoveryAction::TestChannel),
    )
}

fn check_event_roundtrip(
    paths: &AppPaths,
    connector_cli: &Path,
    source: AgentSource,
) -> ConnectionCheckItem {
    if absolute_env_path("APC_CONNECTOR_CLI_PATH").is_some() {
        return ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::Unverified,
            "检测到外部覆盖的事件 CLI，跳过自动写入自检",
            Some(RecoveryAction::TestChannel),
        );
    }

    if !connector_cli.is_file() {
        return ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::NeedsFix,
            format!("事件 CLI 缺失 {}", connector_cli.display()),
            Some(RecoveryAction::TestChannel),
        );
    }

    if !paths.socket_path.exists() || UnixStream::connect(&paths.socket_path).is_err() {
        return ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::NeedsFix,
            format!("PetCore socket 未连接 {}", paths.socket_path.display()),
            Some(RecoveryAction::TestChannel),
        );
    }

    let source_arg = source_cli_arg(source);
    let event_id = format!("evt_connection_smoke_{source_arg}");
    let payload = json!({
        "schema_version": "apc.agent-event.v1",
        "external_event_id": event_id,
        "source_event": "connection.test",
        "tool_name": null,
        "outcome": "completed",
        "diagnostic": true,
        "turn_id": null,
        "session_active": false,
        "message_role": null,
        "message_content": null,
        "interaction_kind": null,
        "project_label": null
    })
    .to_string();
    let output = run_bounded(
        ProcessSpec::connector(
            connector_cli,
            vec![
                "agent".to_string(),
                "ingest".to_string(),
                "--id".to_string(),
                event_id.clone(),
                "--source".to_string(),
                source_arg.to_string(),
                "--event-type".to_string(),
                "review".to_string(),
                "--title".to_string(),
                "连接自检".to_string(),
                "--detail".to_string(),
                source.display_name().to_string(),
                "--payload-json".to_string(),
                payload,
            ],
        )
        .with_env("APC_HOME", &paths.home),
    );

    let output = match output {
        Ok(output) => output,
        Err(error) => {
            return ConnectionCheckItem::new(
                CheckCode::ChannelTest,
                "PetCore 通道自检",
                CheckStatus::NeedsFix,
                format!("事件 CLI 无法执行：{error}"),
                Some(RecoveryAction::TestChannel),
            );
        }
    };

    if output.timed_out {
        return ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::NeedsFix,
            "事件 CLI 自检在 5 秒后超时，进程组已终止",
            Some(RecoveryAction::TestChannel),
        );
    }
    if !output.status.success() {
        return ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::NeedsFix,
            format!("事件 CLI 返回失败（exit={:?}）", output.status.code()),
            Some(RecoveryAction::TestChannel),
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed = serde_json::from_str::<Value>(&stdout);
    let Ok(value) = parsed else {
        return ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::NeedsFix,
            "事件 CLI 返回了不可解析的 JSON",
            Some(RecoveryAction::TestChannel),
        );
    };

    let ok = value.get("ok").and_then(Value::as_bool) == Some(true);
    let inserted = value
        .get("inserted")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let event_matches = value
        .get("event")
        .and_then(|event| event.get("id"))
        .and_then(Value::as_str)
        == Some(event_id.as_str());
    let suppressed = value.get("triggered").and_then(Value::as_bool) == Some(false);

    if ok && event_matches && suppressed {
        ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::Ok,
            if inserted {
                "本地诊断事件已通过 CLI、socket 与数据库，且未触发桌宠动作；此项不代表 Agent Hook 已触发".to_string()
            } else {
                "本地诊断事件已通过 CLI 与 socket；重复自检未重复入库，且未触发桌宠动作；此项不代表 Agent Hook 已触发".to_string()
            },
            Some(RecoveryAction::TestChannel),
        )
    } else {
        ConnectionCheckItem::new(
            CheckCode::ChannelTest,
            "PetCore 通道自检",
            CheckStatus::NeedsFix,
            "诊断事件未完成端到端回传",
            Some(RecoveryAction::TestChannel),
        )
    }
}

fn check_agent_cli_version(
    source: AgentSource,
    command: Option<&Path>,
    run_runtime_smoke: bool,
) -> ConnectionCheckItem {
    let label = format!("{} 版本", source.display_name());
    let Some(command) = command else {
        return ConnectionCheckItem::new(
            CheckCode::AgentVersion,
            label,
            CheckStatus::Missing,
            "CLI 不可用，无法读取版本",
            Some(RecoveryAction::Recheck),
        );
    };
    if !run_runtime_smoke {
        return ConnectionCheckItem::new(
            CheckCode::AgentVersion,
            label,
            CheckStatus::Unverified,
            "轻量检查不启动 Agent CLI；点击检查读取版本",
            Some(RecoveryAction::Recheck),
        );
    }
    let output = run_bounded(ProcessSpec::connector(command, ["--version"]));
    let text = output
        .ok()
        .filter(|output| output.status.success() && !output.timed_out)
        .and_then(|output| {
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            (!stdout.is_empty())
                .then_some(stdout)
                .or_else(|| (!stderr.is_empty()).then_some(stderr))
        });
    if source == AgentSource::Codex {
        return check_codex_cli_version(label, text);
    }
    let (minimum, audited_maximum) = match source {
        AgentSource::Codex => unreachable!("Codex uses an exact audited version allowlist"),
        AgentSource::ClaudeCode => ((2, 1, 212), (2, 1, 212)),
        AgentSource::Pi => ((0, 80, 10), (0, 80, 10)),
        AgentSource::Opencode => ((1, 18, 0), (1, 18, 0)),
    };
    let parsed = text
        .as_deref()
        .and_then(parse_version_triplet_with_stability);
    let status = parsed.map(|(version, stable)| {
        if !stable {
            CheckStatus::Unverified
        } else if version < minimum {
            CheckStatus::NeedsFix
        } else if version > audited_maximum {
            CheckStatus::Unverified
        } else {
            CheckStatus::Ok
        }
    });
    ConnectionCheckItem::new(
        CheckCode::AgentVersion,
        label,
        status.unwrap_or(CheckStatus::Unverified),
        match (text, parsed, status) {
            (Some(text), _, Some(CheckStatus::Ok)) if minimum == audited_maximum => format!(
                "检测到 {text}；命中精确审计版本 {}.{}.{}",
                minimum.0, minimum.1, minimum.2
            ),
            (Some(text), _, Some(CheckStatus::Ok)) => format!(
                "检测到 {text}；位于已审计范围 {}.{}.{}–{}.{}.{}",
                minimum.0,
                minimum.1,
                minimum.2,
                audited_maximum.0,
                audited_maximum.1,
                audited_maximum.2
            ),
            (Some(text), _, Some(CheckStatus::NeedsFix)) => format!(
                "检测到 {text}，低于当前连接器最低版本 {}.{}.{}",
                minimum.0, minimum.1, minimum.2
            ),
            (Some(text), Some((_, false)), Some(CheckStatus::Unverified)) => {
                format!("检测到 {text}；预发布或 build 后缀不属于已审计稳定版本")
            }
            (Some(text), _, Some(CheckStatus::Unverified)) => format!(
                "检测到 {text}，高于已审计上限 {}.{}.{}；请更新 App 的连接器契约后重新验证",
                audited_maximum.0, audited_maximum.1, audited_maximum.2
            ),
            (Some(text), _, _) => format!("检测到版本输出但无法判定：{text}"),
            (None, _, _) => "Agent CLI 未返回可解析的 --version 输出".to_string(),
        },
        Some(RecoveryAction::Recheck),
    )
}

fn check_codex_cli_version(label: String, text: Option<String>) -> ConnectionCheckItem {
    const MINIMUM: (u64, u64, u64) = (0, 144, 5);
    const AUDITED: &[&str] = &["0.144.5", "0.145.0-alpha.18"];
    let audited = text.as_deref().is_some_and(|output| {
        AUDITED
            .iter()
            .any(|version| version_token_present(output, version))
    });
    let parsed = text.as_deref().and_then(parse_version_triplet);
    let status = if audited {
        CheckStatus::Ok
    } else if parsed.is_some_and(|version| version < MINIMUM) {
        CheckStatus::NeedsFix
    } else {
        CheckStatus::Unverified
    };
    let detail = match (text.as_deref(), status) {
        (Some(text), CheckStatus::Ok) => format!(
            "检测到 {text}；命中精确审计版本 0.144.5 / 0.145.0-alpha.18"
        ),
        (Some(text), CheckStatus::NeedsFix) => {
            format!("检测到 {text}，低于当前连接器最低版本 0.144.5")
        }
        (Some(text), _) => format!(
            "检测到 {text}，不在精确审计版本 0.144.5 / 0.145.0-alpha.18 中；不会把其他 alpha 或正式版自动视为兼容"
        ),
        (None, _) => "Codex CLI 未返回可解析的 --version 输出".to_string(),
    };
    ConnectionCheckItem::new(
        CheckCode::AgentVersion,
        label,
        status,
        detail,
        Some(RecoveryAction::Recheck),
    )
}

fn version_token_present(output: &str, expected: &str) -> bool {
    output.split_whitespace().any(|token| {
        token.trim_matches(|character: char| {
            !(character.is_ascii_alphanumeric() || character == '.' || character == '-')
        }) == expected
    })
}

fn parse_version_triplet(value: &str) -> Option<(u64, u64, u64)> {
    parse_version_triplet_with_stability(value).map(|(version, _)| version)
}

fn parse_version_triplet_with_stability(value: &str) -> Option<((u64, u64, u64), bool)> {
    value.char_indices().find_map(|(start, character)| {
        if !character.is_ascii_digit() {
            return None;
        }
        let candidate = &value[start..];
        let bytes = candidate.as_bytes();
        let mut cursor = 0;
        let parse_component = |cursor: &mut usize| -> Option<u64> {
            let begin = *cursor;
            while bytes.get(*cursor).is_some_and(u8::is_ascii_digit) {
                *cursor += 1;
            }
            (begin != *cursor)
                .then(|| candidate[begin..*cursor].parse().ok())
                .flatten()
        };
        let major = parse_component(&mut cursor)?;
        if bytes.get(cursor) != Some(&b'.') {
            return None;
        }
        cursor += 1;
        let minor = parse_component(&mut cursor)?;
        if bytes.get(cursor) != Some(&b'.') {
            return None;
        }
        cursor += 1;
        let patch = parse_component(&mut cursor)?;
        let stable = bytes.get(cursor).is_none_or(|next| {
            !next.is_ascii_alphanumeric() && !matches!(*next, b'-' | b'+' | b'.' | b'_')
        });
        Some(((major, minor, patch), stable))
    })
}

fn source_cli_arg(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "codex",
        AgentSource::ClaudeCode => "claude_code",
        AgentSource::Pi => "pi",
        AgentSource::Opencode => "opencode",
    }
}

fn command_path(name: &str) -> Option<PathBuf> {
    find_executable(name)
}

fn agent_command_path(source: AgentSource) -> Option<PathBuf> {
    let override_key = agent_cli_override_key(source);
    if let Some(path) = non_empty_env_path(override_key) {
        return is_executable_file(&path).then_some(path);
    }
    if std::env::var_os(override_key).is_some_and(|value| !value.is_empty()) {
        return None;
    }
    if source == AgentSource::Codex {
        codex_command_path()
    } else {
        command_path(cli_name(source))
    }
}

fn agent_cli_override_key(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "APC_CODEX_CLI_PATH",
        AgentSource::ClaudeCode => "APC_CLAUDE_CLI_PATH",
        AgentSource::Pi => "APC_PI_CLI_PATH",
        AgentSource::Opencode => "APC_OPENCODE_CLI_PATH",
    }
}

fn codex_command_path() -> Option<PathBuf> {
    if let Some(path) = non_empty_env_path("APC_CODEX_CLI_PATH") {
        if is_executable_file(&path) {
            return Some(path);
        }
    }
    // Tests and alternate config homes must remain hermetic instead of
    // discovering the developer machine's installed desktop application.
    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return command_path("codex");
    }
    [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|candidate| is_executable_file(candidate))
    .or_else(|| command_path("codex"))
}

#[cfg(test)]
fn command_search_dirs() -> Vec<PathBuf> {
    shared_command_search_dirs()
}

fn install_root(paths: &AppPaths, source: AgentSource) -> PathBuf {
    match source {
        AgentSource::Codex => codex_plugin_source_root(),
        AgentSource::ClaudeCode => paths.connectors_dir.join("claude-code"),
        AgentSource::Pi => pi_extensions_dir(),
        AgentSource::Opencode => opencode_plugins_dir(),
    }
}

fn connector_artifacts_present(paths: &AppPaths, source: AgentSource) -> bool {
    let root = install_root(paths, source);
    match source {
        AgentSource::Codex => {
            (codex_managed_root_state(&root) == ManagedPathState::Safe
                && (codex_manifest_is_owned(&root.join(".codex-plugin/plugin.json"), &root)
                    || codex_hooks_are_owned(&root.join("hooks/hooks.json"), &root)
                    || codex_studio_skill_is_owned(
                        &root.join("skills/agent-pet-studio/SKILL.md"),
                        &root,
                    )
                    || codex_maker_skill_is_owned(&root)))
                || matches!(
                    codex_marketplace_entry_state(&codex_marketplace_path()),
                    CodexMarketplaceEntryState::Current | CodexMarketplaceEntryState::OwnedOutdated
                )
        }
        AgentSource::ClaudeCode => {
            let connector_cli = connector_cli_path(paths);
            (claude_managed_root_state(&root) == ManagedPathState::Safe
                && (claude_fragment_is_owned(&root.join("settings.fragment.json"), &root)
                    || claude_helper_is_owned(&root.join("agent-pet-companion-hook.sh"), &root)))
                || read_regular_json_config(&claude_settings_path()).is_some_and(|settings| {
                    value_contains_owned_claude_hook(&settings, &connector_cli, &root)
                })
        }
        AgentSource::Pi => {
            pi_managed_root_state(&root) == ManagedPathState::Safe
                && managed_connector_script_ownership(
                    &root.join("agent-pet-companion.ts"),
                    AgentSource::Pi,
                ) == ManagedConnectorScriptOwnership::Owned
        }
        AgentSource::Opencode => {
            opencode_managed_root_state(&root) == ManagedPathState::Safe
                && managed_connector_script_ownership(
                    &root.join("agent-pet-companion.js"),
                    AgentSource::Opencode,
                ) == ManagedConnectorScriptOwnership::Owned
        }
    }
}

fn read_regular_json_config(path: &Path) -> Option<Value> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > MAX_MANAGED_CONNECTOR_SCRIPT_BYTES
    {
        return None;
    }
    fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
}

fn config_file_path_state(path: &Path) -> ManagedPathState {
    let Some(parent) = path.parent() else {
        return ManagedPathState::Conflict;
    };
    match managed_directory_state(parent) {
        ManagedPathState::Safe => {}
        state => return state,
    }
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            ManagedPathState::Safe
        }
        Ok(_) => ManagedPathState::Conflict,
        Err(error) if error.kind() == ErrorKind::NotFound => ManagedPathState::Missing,
        Err(_) => ManagedPathState::Conflict,
    }
}

fn codex_manifest_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && read_regular_json_config(path).is_some_and(|value| {
            value.get("name").and_then(Value::as_str) == Some("agent-pet-companion")
                && value.get("hooks").and_then(Value::as_str) == Some("./hooks/hooks.json")
                && value.get("skills").and_then(Value::as_str) == Some("./skills/")
        })
}

fn codex_hooks_are_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("--source codex")
                && content.contains("agent hook")
                && content.contains("\"hooks\"")
        })
}

fn codex_studio_skill_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("Generate Agent Pet Companion .petpack assets")
                && content.contains("APC_PETCORE_CLI")
        })
}

fn codex_maker_skill_is_owned(root: &Path) -> bool {
    let path = root.join("skills/agent-pet-maker/SKILL.md");
    managed_regular_file_state(root, &path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("agent-pet-maker") && content.contains("Agent Pet Companion")
        })
}

fn claude_fragment_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && read_regular_json_config(path).is_some_and(|value| {
            value
                .get("contract_version")
                .and_then(Value::as_str)
                .is_some_and(|version| version.starts_with("claude-hooks-"))
                && value_contains_apparent_claude_connector(&value)
        })
}

fn claude_helper_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("agent hook --source claude_code")
                && (content.contains("APC_CONNECTOR_CONTRACT_VERSION='claude-hooks-")
                    || content.contains("EVENT_TYPE=\"${APC_EVENT_TYPE:-tool}\""))
        })
}

fn cli_name(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "codex",
        AgentSource::ClaudeCode => "claude",
        AgentSource::Pi => "pi",
        AgentSource::Opencode => "opencode",
    }
}

fn cli_label(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "Codex CLI",
        AgentSource::ClaudeCode => "Claude CLI",
        AgentSource::Pi => "Pi CLI",
        AgentSource::Opencode => "OpenCode CLI",
    }
}

fn connector_cli_path(paths: &AppPaths) -> PathBuf {
    if let Some(path) = absolute_env_path("APC_CONNECTOR_CLI_PATH") {
        return path;
    }
    let stable_path = paths.home.join("runtime/current/petcore-cli");
    if stable_path.is_file() {
        return stable_path;
    }
    std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join("petcore-cli")))
        .unwrap_or_else(|| PathBuf::from("petcore-cli"))
}

fn agent_home() -> PathBuf {
    absolute_env_path("APC_AGENT_CONFIG_HOME").unwrap_or_else(user_home)
}

fn non_empty_env_path(key: &str) -> Option<PathBuf> {
    absolute_env_path(key)
}

fn pi_extensions_dir() -> PathBuf {
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

fn opencode_plugins_dir() -> PathBuf {
    if let Some(fake_home) = non_empty_env_path("APC_AGENT_CONFIG_HOME") {
        return fake_home.join(".config").join("opencode").join("plugins");
    }
    if let Some(config_dir) = non_empty_env_path("OPENCODE_CONFIG_DIR") {
        return config_dir.join("plugins");
    }
    non_empty_env_path("XDG_CONFIG_HOME")
        .unwrap_or_else(|| user_home().join(".config"))
        .join("opencode")
        .join("plugins")
}

fn codex_marketplace_path() -> PathBuf {
    agent_home()
        .join(".agents")
        .join("plugins")
        .join("marketplace.json")
}

fn codex_plugin_source_root() -> PathBuf {
    agent_home()
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
}

fn codex_marketplace_plugin_source_path() -> String {
    let root = codex_plugin_source_root();
    let home = user_home();
    root.strip_prefix(&home)
        .ok()
        .map(|relative| format!("./{}", relative.display()))
        .unwrap_or_else(|| root.display().to_string())
}

fn ensure_codex_marketplace_entry() -> Result<()> {
    let path = codex_marketplace_path();
    if codex_managed_root_state(&codex_plugin_source_root()) == ManagedPathState::Conflict {
        return Err(PetCoreError::Conflict(
            "拒绝通过 Codex 配置目录符号链接或非目录路径写入 marketplace".to_string(),
        ));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        if managed_directory_state(parent) != ManagedPathState::Safe {
            return Err(PetCoreError::Conflict(format!(
                "Codex marketplace 父目录不是安全普通目录：{}",
                parent.display()
            )));
        }
    }

    if codex_marketplace_entry_state(&path) == CodexMarketplaceEntryState::Conflict {
        return Err(PetCoreError::Conflict(format!(
            "拒绝覆盖同名 foreign Codex marketplace entry、符号链接或无效结构：{}",
            path.display()
        )));
    }

    let mut marketplace =
        read_json_config_or_default(&path, default_codex_marketplace(), "Codex marketplace")?;
    let original = marketplace.clone();

    let Some(root) = marketplace.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Codex marketplace",
            "expected a JSON object",
        ));
    };
    root.insert("name".to_string(), json!("personal"));
    root.entry("interface".to_string())
        .or_insert_with(|| json!({ "displayName": "Personal" }));
    let plugins = root
        .entry("plugins".to_string())
        .or_insert_with(|| json!([]));
    let Some(plugins) = plugins.as_array_mut() else {
        return Err(config_shape_error(
            &path,
            "Codex marketplace",
            "expected `plugins` to be a JSON array",
        ));
    };
    let entry = codex_marketplace_entry();

    if let Some(existing) = plugins
        .iter_mut()
        .find(|plugin| plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion"))
    {
        *existing = entry;
    } else {
        plugins.push(entry);
    }

    write_json_config_if_changed(&path, &original, &marketplace)?;
    Ok(())
}

fn remove_codex_marketplace_entry() -> Result<()> {
    let path = codex_marketplace_path();
    if codex_managed_root_state(&codex_plugin_source_root()) == ManagedPathState::Conflict {
        return Err(PetCoreError::Conflict(
            "拒绝通过 Codex 配置目录符号链接或非目录路径删除 marketplace entry".to_string(),
        ));
    }
    let state = codex_marketplace_entry_state(&path);
    if state == CodexMarketplaceEntryState::Missing {
        return Ok(());
    }
    if state == CodexMarketplaceEntryState::Conflict {
        return Err(PetCoreError::Conflict(format!(
            "拒绝删除同名 foreign Codex marketplace entry、符号链接或无效结构：{}",
            path.display()
        )));
    }
    let mut marketplace = read_json_config_or_default(&path, json!({}), "Codex marketplace")?;
    let original = marketplace.clone();
    let Some(root) = marketplace.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Codex marketplace",
            "expected a JSON object",
        ));
    };
    if let Some(plugins) = root.get_mut("plugins") {
        let Some(plugins) = plugins.as_array_mut() else {
            return Err(config_shape_error(
                &path,
                "Codex marketplace",
                "expected `plugins` to be a JSON array",
            ));
        };
        plugins.retain(|plugin| {
            plugin.get("name").and_then(Value::as_str) != Some("agent-pet-companion")
        });
    }
    write_json_config_if_changed(&path, &original, &marketplace)?;
    Ok(())
}

fn default_codex_marketplace() -> Value {
    json!({
        "name": "personal",
        "interface": {
            "displayName": "Personal"
        },
        "plugins": []
    })
}

fn read_json_config_or_default(path: &Path, default: Value, label: &str) -> Result<Value> {
    if let Some(parent) = path.parent() {
        if fs::symlink_metadata(parent)
            .is_ok_and(|metadata| metadata.file_type().is_symlink() || !metadata.is_dir())
        {
            return Err(PetCoreError::Conflict(format!(
                "{label} 父目录是符号链接或非目录，已保留且拒绝修改：{}",
                parent.display()
            )));
        }
    }
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {}
        Ok(_) => {
            return Err(PetCoreError::Conflict(format!(
                "{label} 路径是符号链接或非普通文件，已保留且拒绝修改：{}",
                path.display()
            )));
        }
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(default),
        Err(error) => return Err(error.into()),
    }
    let content = fs::read_to_string(path)?;
    if content.trim().is_empty() {
        return Ok(default);
    }
    serde_json::from_str(&content).map_err(|error| {
        PetCoreError::Validation(format!(
            "{label} JSON 无效，已保留原文件：{}（{error}）",
            path.display()
        ))
    })
}

fn config_shape_error(path: &Path, label: &str, detail: impl Into<String>) -> PetCoreError {
    PetCoreError::Validation(format!(
        "{label} 结构不符合预期，已保留原文件：{}（{}）",
        path.display(),
        detail.into()
    ))
}

fn write_json_config_if_changed(path: &Path, original: &Value, updated: &Value) -> Result<()> {
    if original == updated {
        return Ok(());
    }
    let bytes = serde_json::to_vec_pretty(updated)?;
    if path.exists() {
        backup_json_config(path)?;
    }
    write_file_atomic(path, &bytes)
}

fn backup_json_config(path: &Path) -> Result<PathBuf> {
    let backup_path = json_config_backup_path(path);
    match fs::symlink_metadata(&backup_path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            // Preserve the first pre-APC backup. Repeated repairs must never
            // overwrite an existing file whose ownership cannot be proven.
            return Ok(backup_path);
        }
        Ok(_) => {
            return Err(PetCoreError::Conflict(format!(
                "备份路径是符号链接或非普通文件，拒绝覆盖：{}",
                backup_path.display()
            )));
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let mut source = fs::File::open(path)?;
    let mut backup = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&backup_path)?;
    let copy_result = (|| -> Result<()> {
        std::io::copy(&mut source, &mut backup)?;
        backup.sync_all()?;
        Ok(())
    })();
    drop(backup);
    if let Err(error) = copy_result {
        let _ = fs::remove_file(&backup_path);
        return Err(error);
    }
    Ok(backup_path)
}

fn json_config_backup_path(path: &Path) -> PathBuf {
    path.with_extension("json.agent-pet-companion.bak")
}

fn write_file_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        if managed_directory_state(parent) != ManagedPathState::Safe {
            return Err(PetCoreError::Conflict(format!(
                "拒绝通过符号链接或非目录父路径写入：{}",
                parent.display()
            )));
        }
    }
    if fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(PetCoreError::Conflict(format!(
            "拒绝覆盖符号链接或非普通文件：{}",
            path.display()
        )));
    }
    let temp_path = atomic_temp_path(path);
    let permissions = fs::metadata(path)
        .ok()
        .map(|metadata| metadata.permissions());
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        if let Some(permissions) = permissions {
            fs::set_permissions(&temp_path, permissions)?;
        }
        fs::rename(&temp_path, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn write_file_if_changed(path: &Path, bytes: &[u8]) -> Result<()> {
    if fs::read(path).ok().as_deref() == Some(bytes) {
        return Ok(());
    }
    write_file_atomic(path, bytes)
}

fn atomic_temp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("config");
    path.with_file_name(format!(
        ".{file_name}.agent-pet-companion.tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ))
}

fn install_codex_plugin_if_possible(root: &Path) -> Result<()> {
    let result_path = root.join("codex-install-result.json");
    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        write_managed_file_atomic(
            &result_path,
            &serde_json::to_vec_pretty(&json!({
                "status": "skipped",
                "reason": "APC_AGENT_CONFIG_HOME is set"
            }))?,
            0o644,
        )?;
        return Ok(());
    }

    let Some(codex) = codex_command_path() else {
        write_managed_file_atomic(
            &result_path,
            &serde_json::to_vec_pretty(&json!({
                "status": "skipped",
                "reason": "codex command not found"
            }))?,
            0o644,
        )?;
        return Ok(());
    };

    let output = run_bounded(ProcessSpec::connector(
        codex,
        ["plugin", "add", "agent-pet-companion@personal", "--json"],
    ));

    match output {
        Ok(output) => {
            write_managed_file_atomic(
                &result_path,
                &serde_json::to_vec_pretty(&json!({
                    "status": if output.status.success() && !output.timed_out { "ok" } else { "failed" },
                    "code": output.status.code(),
                    "timed_out": output.timed_out,
                    "stdout_truncated": output.stdout_truncated,
                    "stderr_truncated": output.stderr_truncated
                }))?,
                0o644,
            )?;
        }
        Err(error) => {
            write_managed_file_atomic(
                &result_path,
                &serde_json::to_vec_pretty(&json!({
                    "status": "failed",
                    "error": error.to_string()
                }))?,
                0o644,
            )?;
        }
    }
    Ok(())
}

fn codex_plugin_installation_state(codex: &Path) -> Option<bool> {
    let json_output = run_bounded(ProcessSpec::connector(codex, ["plugin", "list", "--json"]))
        .ok()
        .filter(|output| !output.timed_out && output.status.success());
    if let Some(installed) = json_output
        .as_ref()
        .and_then(|output| codex_plugin_json_reports_present(&output.stdout))
    {
        return Some(installed);
    }

    run_bounded(ProcessSpec::connector(codex, ["plugin", "list"]))
        .ok()
        .filter(|output| !output.timed_out && output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|stdout| codex_plugin_text_reports_present(&stdout))
}

fn uninstall_codex_plugin_if_possible() -> Result<()> {
    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return Ok(());
    }
    let Some(codex) = codex_command_path() else {
        return Ok(());
    };
    if codex_plugin_installation_state(&codex) == Some(false) {
        return Ok(());
    }
    let output = run_bounded(ProcessSpec::connector(
        &codex,
        ["plugin", "remove", "agent-pet-companion@personal"],
    ))?;
    if output.timed_out || !output.status.success() {
        if codex_plugin_installation_state(&codex) == Some(false) {
            return Ok(());
        }
        return Err(PetCoreError::Conflict(format!(
            "codex plugin remove 未成功完成（timed_out={}, exit={:?}）；未改动本地 marketplace 与连接器文件",
            output.timed_out,
            output.status.code()
        )));
    }
    if codex_plugin_installation_state(&codex) == Some(true) {
        return Err(PetCoreError::Conflict(
            "codex plugin remove 已返回成功，但即时 plugin list 仍报告插件已安装；未改动本地 marketplace 与连接器文件"
                .to_string(),
        ));
    }
    Ok(())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn claude_settings_path() -> PathBuf {
    non_empty_env_path("CLAUDE_CONFIG_DIR")
        .unwrap_or_else(|| agent_home().join(".claude"))
        .join("settings.json")
}

fn user_home() -> PathBuf {
    shared_user_home()
}

#[cfg(test)]
fn install_claude_settings(hook_entries: &[(&str, String)]) -> Result<()> {
    let path = claude_settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut settings = read_json_config_or_default(&path, json!({}), "Claude settings")?;
    let original = settings.clone();
    if !settings.is_object() {
        return Err(config_shape_error(
            &path,
            "Claude settings",
            "expected a JSON object",
        ));
    }

    for (event, command) in hook_entries {
        ensure_hook_command(&mut settings, &path, event, command)?;
    }

    write_json_config_if_changed(&path, &original, &settings)?;
    Ok(())
}

fn install_claude_settings_fragment(
    fragment: &Value,
    install_root: &Path,
    connector_cli: &Path,
) -> Result<()> {
    let path = claude_settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let fragment_hooks = fragment
        .get("hooks")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "Claude hook template must contain a `hooks` object".to_string(),
            )
        })?;

    let mut settings = read_json_config_or_default(&path, json!({}), "Claude settings")?;
    let original = settings.clone();
    let root = settings
        .as_object_mut()
        .ok_or_else(|| config_shape_error(&path, "Claude settings", "expected a JSON object"))?;
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().ok_or_else(|| {
        config_shape_error(
            &path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        )
    })?;

    // Remove every previously managed APC hook before installing the current
    // exact event set. This also cleans up hooks that a newer contract
    // deliberately stops subscribing to, while preserving all user/third-party
    // handlers and unknown fields.
    let existing_events = hooks.keys().cloned().collect::<Vec<_>>();
    for event in existing_events {
        let Some(value) = hooks.get_mut(&event) else {
            continue;
        };
        remove_agent_pet_hook_values(value, connector_cli, Some(install_root));
        if value.as_array().is_some_and(Vec::is_empty) {
            hooks.remove(&event);
        }
    }

    for (event, template_groups) in fragment_hooks {
        let template_groups = template_groups.as_array().ok_or_else(|| {
            PetCoreError::Validation(format!(
                "Claude hook template `hooks.{event}` must be an array"
            ))
        })?;
        let target = hooks.entry(event.clone()).or_insert_with(|| json!([]));
        if !target.is_array() {
            return Err(config_shape_error(
                &path,
                "Claude settings",
                format!("expected `hooks.{event}` to be a JSON array"),
            ));
        }
        let target_groups = target.as_array_mut().ok_or_else(|| {
            config_shape_error(
                &path,
                "Claude settings",
                format!("expected `hooks.{event}` to be a JSON array"),
            )
        })?;
        target_groups.extend(template_groups.iter().cloned());
    }

    write_json_config_if_changed(&path, &original, &settings)
}

fn remove_claude_settings_hooks(install_root: &Path, connector_cli: &Path) -> Result<()> {
    let path = claude_settings_path();
    if !path.exists() {
        return Ok(());
    }

    let mut settings = read_json_config_or_default(&path, json!({}), "Claude settings")?;
    let original = settings.clone();

    let Some(root) = settings.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Claude settings",
            "expected a JSON object",
        ));
    };
    let Some(hooks_value) = root.get_mut("hooks") else {
        return Ok(());
    };
    let Some(hooks) = hooks_value.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        ));
    };

    let events = hooks.keys().cloned().collect::<Vec<_>>();
    for event in events {
        let Some(value) = hooks.get_mut(&event) else {
            continue;
        };
        remove_agent_pet_hook_values(value, connector_cli, Some(install_root));
        if value.as_array().is_some_and(Vec::is_empty) {
            hooks.remove(&event);
        }
    }

    if hooks.is_empty() {
        root.remove("hooks");
    }

    write_json_config_if_changed(&path, &original, &settings)?;
    Ok(())
}

fn remove_agent_pet_hook_values(
    value: &mut Value,
    connector_cli: &Path,
    install_root: Option<&Path>,
) {
    let Some(groups) = value.as_array_mut() else {
        return;
    };

    groups.retain_mut(|group| {
        let Some(hooks) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
            return true;
        };
        let before = hooks.len();
        hooks.retain(|hook| !is_agent_pet_claude_hook(hook, connector_cli, install_root));
        let removed_agent_pet_hook = hooks.len() != before;
        !(removed_agent_pet_hook && hooks.is_empty())
    });
}

fn is_agent_pet_claude_hook(
    value: &Value,
    connector_cli: &Path,
    install_root: Option<&Path>,
) -> bool {
    let Some(command) = value.get("command").and_then(Value::as_str) else {
        return false;
    };
    let is_command_hook = value
        .get("type")
        .and_then(Value::as_str)
        .is_none_or(|kind| kind == "command");
    is_command_hook && is_agent_pet_claude_command(command, connector_cli, install_root)
}

fn value_contains_owned_claude_hook(
    value: &Value,
    connector_cli: &Path,
    install_root: &Path,
) -> bool {
    if is_agent_pet_claude_hook(value, connector_cli, Some(install_root)) {
        return true;
    }
    match value {
        Value::Array(values) => values
            .iter()
            .any(|value| value_contains_owned_claude_hook(value, connector_cli, install_root)),
        Value::Object(map) => map
            .values()
            .any(|value| value_contains_owned_claude_hook(value, connector_cli, install_root)),
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => false,
    }
}

fn is_agent_pet_claude_command(
    command: &str,
    connector_cli: &Path,
    install_root: Option<&Path>,
) -> bool {
    let command = command.trim();
    let command = command
        .strip_prefix("APC_CONNECTOR_CONTRACT_VERSION=")
        .and_then(|rest| rest.split_once(' '))
        .filter(|(version, _)| version.trim_matches('\'').starts_with("claude-hooks-"))
        .map(|(_, command)| command.trim_start())
        .unwrap_or(command);
    let cli = connector_cli.display().to_string();
    for executable in [shell_quote(&cli), cli] {
        if let Some(arguments) = command.strip_prefix(&executable) {
            if is_agent_pet_claude_arguments(arguments) {
                return true;
            }
        }
    }

    if let Some((executable, arguments)) = split_shell_executable(command) {
        if (is_managed_runtime_cli(executable, connector_cli)
            || is_legacy_bundled_connector_cli(executable))
            && is_agent_pet_claude_arguments(arguments)
        {
            return true;
        }
    }

    let Some(install_root) = install_root else {
        return false;
    };
    let helper = install_root.join("agent-pet-companion-hook.sh");
    let helper = helper.display().to_string();
    [shell_quote(&helper), helper].iter().any(|executable| {
        command == executable
            || command == format!("{executable} >/dev/null 2>&1")
            || command == format!("{executable} >/dev/null 2>&1 || true")
    })
}

fn is_legacy_bundled_connector_cli(executable: &str) -> bool {
    let executable = Path::new(executable);
    executable.is_absolute()
        && executable.ends_with(Path::new(
            "AgentPetCompanion.app/Contents/Resources/bin/petcore-cli",
        ))
}

fn is_agent_pet_claude_arguments(arguments: &str) -> bool {
    const PREFIX: &str = "agent hook --source claude_code --event-type ";
    let arguments = arguments.strip_prefix(' ').unwrap_or(arguments);
    let Some(arguments) = arguments.strip_prefix(PREFIX) else {
        return false;
    };
    let (event_type, suffix) = arguments
        .split_once(' ')
        .map_or((arguments, ""), |(event_type, suffix)| (event_type, suffix));
    let known_event = matches!(
        event_type,
        "auto" | "start" | "tool" | "waiting" | "review" | "done" | "failed"
    );
    known_event && matches!(suffix, "" | ">/dev/null 2>&1" | ">/dev/null 2>&1 || true")
}

fn split_shell_executable(command: &str) -> Option<(&str, &str)> {
    if let Some(quoted) = command.strip_prefix('\'') {
        let (executable, arguments) = quoted.split_once("' ")?;
        return Some((executable, arguments));
    }
    command.split_once(' ')
}

fn is_managed_runtime_cli(executable: &str, connector_cli: &Path) -> bool {
    let Some(parent) = connector_cli.parent() else {
        return false;
    };
    let runtime_root = if parent.file_name().and_then(|value| value.to_str()) == Some("current") {
        let Some(runtime_root) = parent.parent() else {
            return false;
        };
        runtime_root
    } else if parent
        .parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        == Some("versions")
    {
        let Some(runtime_root) = parent.parent().and_then(Path::parent) else {
            return false;
        };
        runtime_root
    } else {
        return false;
    };
    let executable = Path::new(executable);
    if executable == runtime_root.join("current/petcore-cli") {
        return true;
    }
    let Ok(relative) = executable.strip_prefix(runtime_root.join("versions")) else {
        return false;
    };
    let mut components = relative.components();
    let Some(std::path::Component::Normal(build_id)) = components.next() else {
        return false;
    };
    let Some(std::path::Component::Normal(binary)) = components.next() else {
        return false;
    };
    components.next().is_none()
        && binary == "petcore-cli"
        && build_id.to_str().is_some_and(|value| {
            !value.is_empty()
                && value.len() <= 128
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._+-".contains(&byte))
        })
}

#[cfg(test)]
fn ensure_hook_command(
    settings: &mut Value,
    path: &Path,
    event: &str,
    command: &str,
) -> Result<()> {
    let Some(root) = settings.as_object_mut() else {
        return Err(config_shape_error(
            path,
            "Claude settings",
            "expected a JSON object",
        ));
    };
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    if !hooks.is_object() {
        return Err(config_shape_error(
            path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        ));
    }
    let Some(hooks_object) = hooks.as_object_mut() else {
        return Err(config_shape_error(
            path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        ));
    };
    let event_hooks = hooks_object.entry(event).or_insert_with(|| json!([]));
    if !event_hooks.is_array() {
        return Err(config_shape_error(
            path,
            "Claude settings",
            format!("expected `hooks.{event}` to be a JSON array"),
        ));
    }
    let Some(array) = event_hooks.as_array_mut() else {
        return Err(config_shape_error(
            path,
            "Claude settings",
            format!("expected `hooks.{event}` to be a JSON array"),
        ));
    };
    if array
        .iter()
        .any(|item| value_contains_command(item, command))
    {
        return Ok(());
    }
    array.push(json!({
        "hooks": [
            {
                "type": "command",
                "command": command
            }
        ]
    }));
    Ok(())
}

#[cfg(test)]
fn value_contains_command(value: &Value, command: &str) -> bool {
    match value {
        Value::String(value) => value == command,
        Value::Array(values) => values
            .iter()
            .any(|value| value_contains_command(value, command)),
        Value::Object(map) => map
            .values()
            .any(|value| value_contains_command(value, command)),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        agent_command_path, backup_json_config, cached_connection_status_is_current,
        capabilities_for_source, check_agent_cli_version, check_claude_hook, check_claude_settings,
        check_codex_hooks, check_codex_plugin_manifest, check_exact_connector_file,
        check_probe_cwd_access, check_source_with_runtime_smoke, claude_settings_path,
        codex_marketplace_entry_path, codex_marketplace_path, codex_plugin_json_reports_installed,
        codex_plugin_json_reports_present, codex_plugin_text_reports_installed,
        codex_plugin_text_reports_present, command_search_dirs, connector_artifacts_present,
        connector_cli_path, connector_receipt_is_current, cwd_gated_native_host_check,
        ensure_codex_marketplace_entry, has_repairable_managed_connector_issue,
        has_required_ordinary_task_evidence, host_verification_check_is_fresh,
        install_claude_settings, install_root, is_agent_pet_claude_command,
        json_config_backup_path, managed_connector_script_ownership, opencode_debug_reports_plugin,
        opencode_plugins_dir, pi_extensions_dir, pi_native_probe_spec,
        remove_claude_settings_hooks, remove_codex_marketplace_entry,
        remove_owned_connector_script, render_connector_script, rendered_claude_hook,
        rendered_claude_settings_fragment, rendered_codex_hooks, repair_claude, repair_source_at,
        uninstall_codex_plugin_if_possible, verification_requires_item, version_token_present,
        write_owned_connector_script, ManagedConnectorScriptOwnership,
        CODEX_APP_SERVER_HOOK_EVENTS, CODEX_LOCAL_HOOK_EVENTS, CODEX_PLUGIN_JSON,
        OPENCODE_PLUGIN_TEMPLATE, PI_EXTENSION_TEMPLATE, PI_NATIVE_PROBE_TIMEOUT,
    };
    use crate::adapter_contracts::PI_EXTENSION_CONTRACT_VERSION;
    use crate::connections;
    use crate::db::{ConnectorEventReceipt, Database};
    use crate::paths::AppPaths;
    use petcore_types::{
        AgentConnectionStatus, AgentEvent, AgentEventType, AgentSource, AgentVerification,
        AgentVerificationStatus, CheckStatus, ConnectionCheckCode as CheckCode,
        ConnectionCheckItem, ConnectionCheckMode, ConnectionCheckRecoveryAction as RecoveryAction,
    };
    use serde_json::{json, Value};
    use std::cell::Cell;
    use std::ffi::{OsStr, OsString};
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::Path;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn probe_cwd_access_uses_a_real_child_in_the_selected_directory() {
        let temp = tempfile::tempdir().unwrap();
        let check = check_probe_cwd_access(temp.path());

        assert_eq!(check.item.name, "检查目录访问");
        assert_eq!(check.item.status, CheckStatus::Ok);
        let resolved = check.resolved_cwd.as_deref().expect("physical cwd");
        assert!(resolved.is_absolute());
        assert_eq!(resolved.file_name(), temp.path().file_name());
        assert!(check.item.detail.contains(&resolved.display().to_string()));
    }

    #[test]
    fn probe_cwd_access_rejects_missing_absolute_directory_without_a_fallback() {
        let temp = tempfile::tempdir().unwrap();
        let missing = temp.path().join("missing-project");
        let check = check_probe_cwd_access(&missing);

        assert_eq!(check.item.status, CheckStatus::NeedsFix);
        assert_eq!(check.resolved_cwd, None);
        assert!(!check.item.detail.contains("HOME"));
    }

    #[test]
    fn probe_cwd_access_returns_the_physical_directory_from_the_child() {
        let temp = tempfile::tempdir().unwrap();
        let physical = temp.path().join("physical-project");
        let selected = temp.path().join("selected-project");
        std::fs::create_dir(&physical).unwrap();
        std::os::unix::fs::symlink(&physical, &selected).unwrap();

        let expected = check_probe_cwd_access(&physical)
            .resolved_cwd
            .expect("physical directory resolves");
        let check = check_probe_cwd_access(&selected);

        assert_eq!(check.item.status, CheckStatus::Ok);
        assert_eq!(check.resolved_cwd.as_deref(), Some(expected.as_path()));
    }

    #[test]
    fn failed_cwd_access_skips_the_native_host_without_falling_back() {
        let called = Cell::new(false);
        let skipped = cwd_gated_native_host_check(
            false,
            CheckCode::HostRuntime,
            RecoveryAction::Recheck,
            "Plugin 运行时",
            || {
                called.set(true);
                ConnectionCheckItem::new(
                    CheckCode::HostRuntime,
                    "Plugin 运行时",
                    CheckStatus::Ok,
                    "must not run",
                    Some(RecoveryAction::Recheck),
                )
            },
        );

        assert!(!called.get());
        assert_eq!(skipped.status, CheckStatus::Unverified);
        assert!(skipped.detail.contains("不会改用其他目录"));
    }

    #[test]
    fn every_managed_path_conflict_is_required_for_verification() {
        for (source, name) in [
            (AgentSource::Codex, "Hook 路径冲突"),
            (AgentSource::ClaudeCode, "Claude settings.json 配置冲突"),
            (AgentSource::Pi, "Extension 路径冲突"),
            (AgentSource::Opencode, "Plugin 路径冲突"),
        ] {
            let item = ConnectionCheckItem::new(
                CheckCode::ManagedConnector,
                name,
                CheckStatus::NeedsFix,
                "must block verification",
                Some(RecoveryAction::Recheck),
            );
            assert!(verification_requires_item(source, &item));
            assert_eq!(item.recovery_action, Some(RecoveryAction::Recheck));
        }
    }

    #[test]
    fn missing_claude_connector_and_blocked_hooks_policy_have_distinct_row_recovery() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agent-home");
        let claude_config = temp.path().join("claude-config");
        let connector_cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(&claude_config).unwrap();
        std::fs::create_dir_all(connector_cli.parent().unwrap()).unwrap();
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::write(
            claude_config.join("settings.json"),
            r#"{"disableAllHooks":true}"#,
        )
        .unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &claude_config);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let status = check_source_with_runtime_smoke(
            &paths,
            AgentSource::ClaudeCode,
            false,
            temp.path(),
            None,
        );
        assert_eq!(
            status.capabilities.repairable_connector_issue,
            Some(true),
            "missing connector-owned files remain repairable"
        );
        assert_eq!(status.capabilities.managed_path_conflict, Some(false));

        let connector_row = status
            .items
            .iter()
            .find(|item| {
                item.code == CheckCode::ManagedConnector
                    && item.status.is_blocking()
                    && item.recovery_action == Some(RecoveryAction::ConfirmManagedRepair)
            })
            .expect("a missing managed connector row");
        assert_ne!(connector_row.name, "Claude Hooks Policy");

        let policy = status
            .items
            .iter()
            .find(|item| item.name == "Claude Hooks Policy")
            .expect("policy row");
        assert_eq!(policy.status, CheckStatus::NeedsFix);
        assert_eq!(policy.code, CheckCode::ClaudeHooksPolicy);
        assert_eq!(policy.recovery_action, Some(RecoveryAction::Recheck));

        let mut renamed_policy = policy.clone();
        renamed_policy.name = "Enterprise hook policy vNext".to_string();
        renamed_policy.detail = "arbitrary localized guidance".to_string();
        assert_eq!(renamed_policy.code, policy.code);
        assert_eq!(renamed_policy.recovery_action, policy.recovery_action);
        assert!(verification_requires_item(
            AgentSource::ClaudeCode,
            &renamed_policy
        ));
    }

    #[test]
    fn claude_policy_only_block_does_not_authorize_connector_repair() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agent-home");
        let claude_config = temp.path().join("claude-config");
        let connector_cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(&agent_home).unwrap();
        std::fs::create_dir_all(&claude_config).unwrap();
        std::fs::create_dir_all(connector_cli.parent().unwrap()).unwrap();
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &claude_config);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let connector_root = install_root(&paths, AgentSource::ClaudeCode);
        repair_claude(&connector_root, &connector_cli).unwrap();

        let settings_path = claude_settings_path();
        let mut settings: Value =
            serde_json::from_slice(&std::fs::read(&settings_path).unwrap()).unwrap();
        settings["disableAllHooks"] = Value::Bool(true);
        std::fs::write(
            &settings_path,
            serde_json::to_vec_pretty(&settings).unwrap(),
        )
        .unwrap();

        let status = check_source_with_runtime_smoke(
            &paths,
            AgentSource::ClaudeCode,
            false,
            temp.path(),
            None,
        );
        assert_eq!(status.capabilities.managed_path_conflict, Some(false));
        assert_eq!(
            status.capabilities.repairable_connector_issue,
            Some(false),
            "a policy restriction that repair preserves must not authorize repair"
        );

        let settings_row = status
            .items
            .iter()
            .find(|item| item.name == "Claude settings.json")
            .expect("managed settings row");
        assert_eq!(settings_row.code, CheckCode::ManagedConnector);
        assert_eq!(settings_row.status, CheckStatus::Ok);

        let policy = status
            .items
            .iter()
            .find(|item| item.code == CheckCode::ClaudeHooksPolicy)
            .expect("policy row");
        assert_eq!(policy.status, CheckStatus::NeedsFix);
        assert_eq!(policy.recovery_action, Some(RecoveryAction::Recheck));
        assert!(!status.items.iter().any(|item| {
            item.status.is_blocking()
                && item.recovery_action == Some(RecoveryAction::ConfirmManagedRepair)
        }));
    }

    #[test]
    fn every_current_connection_check_row_has_explicit_typed_recovery_metadata() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agent-home");
        let connector_cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(&agent_home).unwrap();
        std::fs::create_dir_all(connector_cli.parent().unwrap()).unwrap();
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        for source in [
            AgentSource::Codex,
            AgentSource::ClaudeCode,
            AgentSource::Pi,
            AgentSource::Opencode,
        ] {
            let status = check_source_with_runtime_smoke(&paths, source, false, temp.path(), None);
            assert!(!status.items.is_empty());
            for item in status.items {
                assert_ne!(
                    item.code,
                    CheckCode::Unknown,
                    "{source:?} row {:?} lacks a stable code",
                    item.name
                );
                assert!(
                    item.recovery_action.is_some(),
                    "{source:?} row {:?} lacks typed row recovery",
                    item.name
                );
            }
        }
    }

    #[test]
    fn repairable_management_capability_ignores_human_copy() {
        let original = ConnectionCheckItem::new(
            CheckCode::ManagedConnector,
            "Agent Pet Maker Skill",
            CheckStatus::NeedsFix,
            "已安装旧版本，待更新",
            Some(RecoveryAction::ConfirmManagedRepair),
        );
        let renamed = ConnectionCheckItem::new(
            CheckCode::ManagedConnector,
            "Managed component v2",
            CheckStatus::NeedsFix,
            "Arbitrary future localized detail",
            Some(RecoveryAction::ConfirmManagedRepair),
        );

        assert!(has_repairable_managed_connector_issue(false, &[&original]));
        assert_eq!(
            has_repairable_managed_connector_issue(false, &[&original]),
            has_repairable_managed_connector_issue(false, &[&renamed])
        );
        assert!(!has_repairable_managed_connector_issue(true, &[&renamed]));
    }

    #[test]
    fn connector_management_capabilities_exclude_cli_cwd_and_runtime_failures() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_home = temp.path().join("agent-home");
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::create_dir_all(&config_home).unwrap();
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&connector_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &config_home);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let _pi_cli = EnvVarGuard::set("APC_PI_CLI_PATH", temp.path().join("missing-pi"));
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let missing_connector =
            check_source_with_runtime_smoke(&paths, AgentSource::Pi, false, temp.path(), None);
        assert_eq!(
            missing_connector.capabilities.repairable_connector_issue,
            Some(true)
        );
        assert_eq!(
            missing_connector.capabilities.managed_path_conflict,
            Some(false)
        );
        assert_eq!(
            missing_connector
                .capabilities
                .can_uninstall_managed_connector,
            Some(false)
        );

        let extension_root = install_root(&paths, AgentSource::Pi);
        std::fs::create_dir_all(&extension_root).unwrap();
        let extension_path = extension_root.join("agent-pet-companion.ts");
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
        write_owned_connector_script(&extension_path, expected.as_bytes(), AgentSource::Pi)
            .unwrap();
        let inaccessible_cwd = temp.path().join("missing-project");
        let failed_cwd = check_probe_cwd_access(&inaccessible_cwd);
        let installed_connector = check_source_with_runtime_smoke(
            &paths,
            AgentSource::Pi,
            true,
            &inaccessible_cwd,
            Some(&failed_cwd),
        );

        assert_eq!(installed_connector.items[0].status, CheckStatus::Missing);
        assert_eq!(
            installed_connector.capabilities.repairable_connector_issue,
            Some(false)
        );
        assert_eq!(
            installed_connector.capabilities.managed_path_conflict,
            Some(false)
        );
        assert_eq!(
            installed_connector
                .capabilities
                .can_uninstall_managed_connector,
            Some(true)
        );
    }

    #[test]
    fn failed_shared_cwd_preflight_skips_every_external_process_for_all_sources() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agent-home");
        let app_home = temp.path().join("app-home");
        let marker = temp.path().join("external-process-ran");
        let canary = temp.path().join("must-not-run");
        std::fs::write(
            &canary,
            format!("#!/bin/sh\nprintf ran >> '{}'\nexit 0\n", marker.display()),
        )
        .unwrap();
        std::fs::set_permissions(&canary, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _claude_root = EnvVarGuard::set("CLAUDE_CONFIG_DIR", agent_home.join("claude"));
        let _codex = EnvVarGuard::set("APC_CODEX_CLI_PATH", &canary);
        let _claude = EnvVarGuard::set("APC_CLAUDE_CLI_PATH", &canary);
        let _pi = EnvVarGuard::set("APC_PI_CLI_PATH", &canary);
        let _opencode = EnvVarGuard::set("APC_OPENCODE_CLI_PATH", &canary);
        let _connector = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &canary);
        let paths = AppPaths::new(app_home);
        paths.ensure().unwrap();
        let missing = temp.path().join("missing-project");
        let failed = check_probe_cwd_access(&missing);

        for (source, native_item) in [
            (AgentSource::Codex, "Codex Hook Trust"),
            (AgentSource::ClaudeCode, "Claude Hook 真实触发"),
            (AgentSource::Pi, "Extension 运行时"),
            (AgentSource::Opencode, "Plugin 运行时"),
        ] {
            let status =
                check_source_with_runtime_smoke(&paths, source, true, &missing, Some(&failed));
            let item = |name: &str| {
                status
                    .items
                    .iter()
                    .find(|item| item.name == name)
                    .unwrap_or_else(|| panic!("missing {name} for {source:?}"))
            };
            assert_eq!(item("检查目录访问").status, CheckStatus::NeedsFix);
            assert_eq!(item(native_item).status, CheckStatus::Unverified);
            assert_eq!(
                item(&format!("{} 版本", source.display_name())).status,
                CheckStatus::Unverified
            );
            assert_eq!(item("PetCore 通道自检").status, CheckStatus::Unverified);
            if source == AgentSource::Codex {
                assert_eq!(item("Codex App Server").status, CheckStatus::Unverified);
            }
        }

        assert!(!marker.exists(), "a supposedly skipped subprocess ran");
    }

    #[test]
    fn pi_native_probe_skips_unrelated_resources_and_keeps_a_bounded_exit_gate() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("app-home"));
        let spec = pi_native_probe_spec(
            temp.path().join("pi"),
            &paths,
            temp.path(),
            "apc-probe-018f47d2-6f9d-7b1a-8d31-12f447f59f01",
        );
        let args = spec
            .args
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        assert_eq!(spec.timeout, PI_NATIVE_PROBE_TIMEOUT);
        assert!(spec.timeout >= std::time::Duration::from_secs(15));
        for expected in [
            "--offline",
            "--no-session",
            "--no-approve",
            "--no-skills",
            "--no-prompt-templates",
            "--no-themes",
            "--no-context-files",
            "--no-tools",
        ] {
            assert!(args.iter().any(|arg| arg == expected), "missing {expected}");
        }
        assert!(!args.iter().any(|arg| arg == "--no-extensions"));
    }

    #[test]
    fn codex_local_and_app_server_hook_names_are_distinct_complete_contracts() {
        assert_eq!(CODEX_LOCAL_HOOK_EVENTS.len(), 10);
        assert_eq!(CODEX_APP_SERVER_HOOK_EVENTS.len(), 10);
        assert!(CODEX_LOCAL_HOOK_EVENTS.contains(&"PreToolUse"));
        assert!(!CODEX_LOCAL_HOOK_EVENTS.contains(&"preToolUse"));
        assert!(CODEX_APP_SERVER_HOOK_EVENTS.contains(&"preToolUse"));
        assert!(!CODEX_APP_SERVER_HOOK_EVENTS.contains(&"PreToolUse"));
    }

    #[test]
    fn capability_inventory_reports_full_audited_and_registered_surfaces() {
        let codex = capabilities_for_source(AgentSource::Codex);
        assert_eq!(
            (codex.audited_events.len(), codex.subscribed_events.len()),
            (80, 11)
        );
        let claude = capabilities_for_source(AgentSource::ClaudeCode);
        assert_eq!(
            (claude.audited_events.len(), claude.subscribed_events.len()),
            (30, 27)
        );
        let pi = capabilities_for_source(AgentSource::Pi);
        assert_eq!(
            (pi.audited_events.len(), pi.subscribed_events.len()),
            (33, 33)
        );
        let opencode = capabilities_for_source(AgentSource::Opencode);
        assert_eq!(
            (
                opencode.audited_events.len(),
                opencode.subscribed_events.len()
            ),
            (112, 9)
        );
        assert!(opencode
            .audited_events
            .iter()
            .any(|event| event.ends_with("tool.definition")));
    }

    #[test]
    fn diagnostic_canary_does_not_claim_cli_task_connection_verified() {
        assert!(has_required_ordinary_task_evidence(
            AgentSource::Codex,
            false
        ));
        for source in [
            AgentSource::ClaudeCode,
            AgentSource::Pi,
            AgentSource::Opencode,
        ] {
            assert!(!has_required_ordinary_task_evidence(source, false));
            assert!(has_required_ordinary_task_evidence(source, true));
        }
    }

    #[test]
    fn codex_audited_versions_are_exact_including_alpha_build() {
        assert!(version_token_present("codex-cli 0.144.5", "0.144.5"));
        assert!(version_token_present(
            "codex-cli 0.145.0-alpha.18",
            "0.145.0-alpha.18"
        ));
        assert!(!version_token_present(
            "codex-cli 0.145.0-alpha.180",
            "0.145.0-alpha.18"
        ));
        assert!(!version_token_present(
            "codex-cli 0.145.0",
            "0.145.0-alpha.18"
        ));
    }

    #[test]
    fn stable_agent_version_gates_reject_unreviewed_prerelease_suffixes() {
        let temp = tempfile::tempdir().unwrap();
        let pi = temp.path().join("pi");
        std::fs::write(&pi, "#!/bin/sh\necho 'pi 0.80.10-beta.1'\n").unwrap();
        std::fs::set_permissions(&pi, std::fs::Permissions::from_mode(0o755)).unwrap();

        let check = check_agent_cli_version(AgentSource::Pi, Some(&pi), true);
        assert_eq!(check.status, CheckStatus::Unverified);
        assert!(check.detail.contains("预发布或 build 后缀"));
    }

    #[test]
    fn claude_full_capability_claim_requires_the_exact_audited_version() {
        let temp = tempfile::tempdir().unwrap();
        let claude = temp.path().join("claude");
        std::fs::write(&claude, "#!/bin/sh\necho '2.1.211 (Claude Code)'\n").unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        let old = check_agent_cli_version(AgentSource::ClaudeCode, Some(&claude), true);
        assert_eq!(old.status, CheckStatus::NeedsFix);

        std::fs::write(&claude, "#!/bin/sh\necho '2.1.212 (Claude Code)'\n").unwrap();
        let audited = check_agent_cli_version(AgentSource::ClaudeCode, Some(&claude), true);
        assert_eq!(audited.status, CheckStatus::Ok);
        assert!(audited.detail.contains("精确审计版本 2.1.212"));
    }

    #[test]
    fn exact_connector_check_rejects_a_missing_unforwarded_handler() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_home = temp.path().join("agent-home");
        std::fs::create_dir_all(&config_home).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &config_home);
        let cli = temp.path().join("petcore-cli");
        let path = pi_extensions_dir().join("agent-pet-companion.ts");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &cli);
        std::fs::write(&path, &expected).unwrap();
        assert_eq!(
            check_exact_connector_file(&path, "Extension", expected.as_bytes(), AgentSource::Pi)
                .status,
            CheckStatus::Ok
        );

        let missing_handler = expected.replace("  pi.on(\"tool_result\", observeOnly);\n", "");
        std::fs::write(&path, missing_handler).unwrap();
        assert_eq!(
            check_exact_connector_file(&path, "Extension", expected.as_bytes(), AgentSource::Pi)
                .status,
            CheckStatus::NeedsFix
        );
    }

    #[test]
    fn fixed_connector_filenames_never_overwrite_or_delete_foreign_content() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        for (source, name, template) in [
            (
                AgentSource::Pi,
                "agent-pet-companion.ts",
                PI_EXTENSION_TEMPLATE,
            ),
            (
                AgentSource::Opencode,
                "agent-pet-companion.js",
                OPENCODE_PLUGIN_TEMPLATE,
            ),
        ] {
            let temp = tempfile::tempdir().unwrap();
            let config_home = temp.path().join("agent-home");
            std::fs::create_dir_all(&config_home).unwrap();
            let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &config_home);
            let root = install_root(&AppPaths::new(temp.path().join("app-home")), source);
            std::fs::create_dir_all(&root).unwrap();
            let path = root.join(name);
            let foreign = b"// user-owned connector\nexport const keep = true;\n";
            std::fs::write(&path, foreign).unwrap();
            let expected = render_connector_script(template, &temp.path().join("petcore-cli"));

            assert_eq!(
                managed_connector_script_ownership(&path, source),
                ManagedConnectorScriptOwnership::Foreign
            );
            assert!(write_owned_connector_script(&path, expected.as_bytes(), source).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), foreign);
            assert!(remove_owned_connector_script(&path, source).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), foreign);
        }
    }

    #[test]
    fn owned_connector_scripts_can_be_updated_and_removed() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        for (source, name, template) in [
            (
                AgentSource::Pi,
                "agent-pet-companion.ts",
                PI_EXTENSION_TEMPLATE,
            ),
            (
                AgentSource::Opencode,
                "agent-pet-companion.js",
                OPENCODE_PLUGIN_TEMPLATE,
            ),
        ] {
            let temp = tempfile::tempdir().unwrap();
            let config_home = temp.path().join("agent-home");
            std::fs::create_dir_all(&config_home).unwrap();
            let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &config_home);
            let root = install_root(&AppPaths::new(temp.path().join("app-home")), source);
            std::fs::create_dir_all(&root).unwrap();
            let path = root.join(name);
            let mut old = render_connector_script(template, &temp.path().join("old-cli"));
            old.push_str("\n// old APC revision\n");
            std::fs::write(&path, old).unwrap();
            let current = render_connector_script(template, &temp.path().join("current-cli"));

            assert_eq!(
                managed_connector_script_ownership(&path, source),
                ManagedConnectorScriptOwnership::Owned
            );
            write_owned_connector_script(&path, current.as_bytes(), source).unwrap();
            assert_eq!(std::fs::read(&path).unwrap(), current.as_bytes());
            remove_owned_connector_script(&path, source).unwrap();
            assert!(!path.exists());
        }
    }

    #[test]
    fn connector_script_symlinks_are_always_foreign_even_if_target_bytes_match() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_home = temp.path().join("agent-home");
        std::fs::create_dir_all(&config_home).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &config_home);
        let target = temp.path().join("target.ts");
        let path = pi_extensions_dir().join("agent-pet-companion.ts");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &temp.path().join("cli"));
        std::fs::write(&target, &expected).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();

        assert_eq!(
            managed_connector_script_ownership(&path, AgentSource::Pi),
            ManagedConnectorScriptOwnership::Foreign
        );
        let check =
            check_exact_connector_file(&path, "Extension", expected.as_bytes(), AgentSource::Pi);
        assert_eq!(check.name, "Extension 路径冲突");
        assert_eq!(check.status, CheckStatus::NeedsFix);
        assert_eq!(check.recovery_action, Some(RecoveryAction::Recheck));
        assert!(remove_owned_connector_script(&path, AgentSource::Pi).is_err());
        assert!(path.symlink_metadata().is_ok());
        assert_eq!(std::fs::read(&target).unwrap(), expected.as_bytes());
    }

    #[test]
    fn pi_and_opencode_ancestor_symlinks_never_expose_external_scripts_to_repair_or_uninstall() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        for (source, linked_component, external_subdir, filename, template) in [
            (
                AgentSource::Pi,
                ".pi",
                "agent/extensions",
                "agent-pet-companion.ts",
                PI_EXTENSION_TEMPLATE,
            ),
            (
                AgentSource::Opencode,
                ".config",
                "opencode/plugins",
                "agent-pet-companion.js",
                OPENCODE_PLUGIN_TEMPLATE,
            ),
        ] {
            let temp = tempfile::tempdir().unwrap();
            let config_home = temp.path().join("agent-home");
            let external = temp.path().join("external");
            let external_root = external.join(external_subdir);
            std::fs::create_dir_all(&config_home).unwrap();
            std::fs::create_dir_all(&external_root).unwrap();
            std::os::unix::fs::symlink(&external, config_home.join(linked_component)).unwrap();
            let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &config_home);
            let paths = AppPaths::new(temp.path().join("app-home"));
            paths.ensure().unwrap();
            let cli = connector_cli_path(&paths);
            let expected = render_connector_script(template, &cli);
            let external_script = external_root.join(filename);
            std::fs::write(&external_script, &expected).unwrap();
            let managed_script = install_root(&paths, source).join(filename);
            let host_marker = temp.path().join("foreign-host-was-started");
            let host_cli = temp.path().join("agent-cli");
            let version = match source {
                AgentSource::Pi => "pi 0.80.10",
                AgentSource::Opencode => "opencode 1.18.0",
                AgentSource::Codex | AgentSource::ClaudeCode => unreachable!(),
            };
            std::fs::write(
                &host_cli,
                format!(
                    "#!/bin/sh\nif [ \"${{1-}}\" = \"--version\" ]; then printf '%s\\n' '{}'; exit 0; fi\nprintf ran > '{}'\nexit 0\n",
                    version,
                    host_marker.display()
                ),
            )
            .unwrap();
            std::fs::set_permissions(&host_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
            let _host_cli = EnvVarGuard::set(super::agent_cli_override_key(source), &host_cli);

            assert_eq!(
                managed_connector_script_ownership(&managed_script, source),
                ManagedConnectorScriptOwnership::Foreign
            );
            assert!(!connector_artifacts_present(&paths, source));
            let cwd_access = check_probe_cwd_access(temp.path());
            let status = check_source_with_runtime_smoke(
                &paths,
                source,
                true,
                temp.path(),
                Some(&cwd_access),
            );
            assert!(status.items.iter().any(|item| {
                item.status == CheckStatus::NeedsFix
                    && item.name.ends_with("冲突")
                    && item.recovery_action == Some(RecoveryAction::Recheck)
            }));
            assert_eq!(status.capabilities.managed_path_conflict, Some(true));
            assert_eq!(status.capabilities.repairable_connector_issue, Some(false));
            assert_eq!(
                status.capabilities.can_uninstall_managed_connector,
                Some(false)
            );
            let runtime_name = match source {
                AgentSource::Pi => "Extension 运行时",
                AgentSource::Opencode => "Plugin 运行时",
                AgentSource::Codex | AgentSource::ClaudeCode => unreachable!(),
            };
            let runtime = status
                .items
                .iter()
                .find(|item| item.name == runtime_name)
                .unwrap();
            assert_eq!(runtime.status, CheckStatus::Unverified);
            assert!(runtime.detail.contains("未启动 Agent 宿主"));
            assert!(!host_marker.exists());
            assert!(repair_source_at(&paths, source, temp.path()).is_err());
            assert!(connections::uninstall_source(&paths, source).is_err());
            assert_eq!(
                std::fs::read(&external_script).unwrap(),
                expected.as_bytes()
            );
        }
    }

    #[test]
    fn codex_owned_manifest_and_hooks_require_exact_operational_templates() {
        let temp = tempfile::tempdir().unwrap();
        let cli = temp.path().join("petcore-cli");
        let manifest = temp.path().join("plugin.json");
        let hooks = temp.path().join("hooks.json");
        std::fs::write(&manifest, CODEX_PLUGIN_JSON).unwrap();
        std::fs::write(
            &hooks,
            serde_json::to_vec_pretty(&rendered_codex_hooks(&cli).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(
            check_codex_plugin_manifest(&manifest, temp.path()).status,
            CheckStatus::Ok
        );
        assert_eq!(
            check_codex_hooks(&hooks, &cli, temp.path()).status,
            CheckStatus::Ok
        );

        let mut bad_manifest: serde_json::Value = serde_json::from_str(CODEX_PLUGIN_JSON).unwrap();
        bad_manifest["hooks"] = json!("hooks/other.json");
        std::fs::write(&manifest, serde_json::to_vec_pretty(&bad_manifest).unwrap()).unwrap();
        assert_eq!(
            check_codex_plugin_manifest(&manifest, temp.path()).status,
            CheckStatus::NeedsFix
        );

        let mut bad_hooks = rendered_codex_hooks(&cli).unwrap();
        bad_hooks["hooks"]["PreToolUse"][0]["hooks"][0]["command"] =
            json!("true # --source codex codex-hooks-2026-07-17-schema-v6");
        std::fs::write(&hooks, serde_json::to_vec_pretty(&bad_hooks).unwrap()).unwrap();
        assert_eq!(
            check_codex_hooks(&hooks, &cli, temp.path()).status,
            CheckStatus::NeedsFix
        );
    }

    #[test]
    fn claude_owned_groups_require_exact_event_command_and_matcher_semantics() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let install_root = temp.path().join("claude-connector");
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let cli = temp.path().join("petcore-cli");
        let fragment = rendered_claude_settings_fragment(&cli, &install_root).unwrap();
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({ "hooks": fragment["hooks"] })).unwrap(),
        )
        .unwrap();
        assert_eq!(
            check_claude_settings(&cli, &install_root).status,
            CheckStatus::Ok
        );

        let mut filtered: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        filtered["hooks"]["PreToolUse"][0]["matcher"] = json!("Read");
        std::fs::write(&settings, serde_json::to_vec_pretty(&filtered).unwrap()).unwrap();
        assert_eq!(
            check_claude_settings(&cli, &install_root).status,
            CheckStatus::NeedsFix
        );

        let mut miswired = json!({ "hooks": fragment["hooks"] });
        miswired["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = json!(format!(
            "'{}' agent hook --source claude_code --event-type done >/dev/null 2>&1 || true",
            cli.display()
        ));
        std::fs::write(&settings, serde_json::to_vec_pretty(&miswired).unwrap()).unwrap();
        assert_eq!(
            check_claude_settings(&cli, &install_root).status,
            CheckStatus::NeedsFix
        );
    }

    #[test]
    fn claude_event_helper_requires_exact_current_cli_contract_and_executable_mode() {
        let temp = tempfile::tempdir().unwrap();
        let helper = temp.path().join("agent-pet-companion-hook.sh");
        let cli_a = temp.path().join("runtime-a/petcore-cli");
        let cli_b = temp.path().join("runtime-b/petcore-cli");
        std::fs::write(&helper, rendered_claude_hook(&cli_a)).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();

        assert_eq!(check_claude_hook(&helper, &cli_a).status, CheckStatus::Ok);
        assert_eq!(
            check_claude_hook(&helper, &cli_b).status,
            CheckStatus::NeedsFix
        );

        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            check_claude_hook(&helper, &cli_a).status,
            CheckStatus::NeedsFix
        );
        std::fs::write(&helper, "").unwrap();
        assert_eq!(
            check_claude_hook(&helper, &cli_a).status,
            CheckStatus::NeedsFix
        );
    }

    #[test]
    fn claude_cached_verification_is_invalidated_when_the_runtime_cli_path_changes() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let cli_a = temp.path().join("runtime-a/petcore-cli");
        let cli_b = temp.path().join("runtime-b/petcore-cli");
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path().join("agents"));
        let _claude_root = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli_a);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let install_root = paths.connectors_dir.join("claude-code");
        repair_claude(&install_root, &cli_a).unwrap();
        let status = AgentConnectionStatus {
            source: AgentSource::ClaudeCode,
            items: vec![],
            install_paths: vec![
                install_root.display().to_string(),
                claude_settings_path().display().to_string(),
            ],
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::ClaudeCode),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };

        assert!(cached_connection_status_is_current(&paths, &status));
        drop(connector_cli);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli_b);
        assert!(!cached_connection_status_is_current(&paths, &status));
    }

    #[test]
    fn cached_cli_verification_rejects_legacy_canary_only_green_state() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let custom_pi_root = temp.path().join("pi-root");
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::unset("APC_AGENT_CONFIG_HOME");
        let _pi_root = EnvVarGuard::set("PI_CODING_AGENT_DIR", &custom_pi_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
        let extension = custom_pi_root
            .join("extensions")
            .join("agent-pet-companion.ts");
        std::fs::create_dir_all(extension.parent().unwrap()).unwrap();
        std::fs::write(&extension, &expected).unwrap();
        let database = Database::new(&paths.db_path);
        database.init().unwrap();
        let mut status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: vec![],
            install_paths: vec![custom_pi_root.join("extensions").display().to_string()],
            connector_installed: true,
            verification: AgentVerification {
                status: AgentVerificationStatus::Verified,
                last_event: Some("connector.probe (canary)".to_string()),
                ..AgentVerification::default()
            },
            capabilities: capabilities_for_source(AgentSource::Pi),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };

        assert!(!cached_connection_status_is_current(&paths, &status));
        status.verification.last_event = Some("session_shutdown".to_string());
        assert!(cached_connection_status_is_current(&paths, &status));
        assert_ne!(
            super::project_connection_evidence(&paths, &status)
                .verification
                .status,
            AgentVerificationStatus::Verified,
            "the authoritative evidence projection must reject passive-only cached green state"
        );
        database
            .insert_event(&AgentEvent {
                id: "evt_current_pi_ordinary_evidence".to_string(),
                source: AgentSource::Pi,
                project_path: None,
                session_id: Some("pi-current-ordinary-evidence".to_string()),
                event_type: AgentEventType::Start,
                title: AgentEventType::Start.zh_label().to_string(),
                detail: None,
                payload_json: json!({
                    "source_event": "input",
                    "contract_version": PI_EXTENSION_CONTRACT_VERSION,
                    "diagnostic": false,
                    "affects_activity": true,
                    "session_active": true
                }),
                created_at: (time::OffsetDateTime::now_utc() + time::Duration::seconds(2))
                    .format(&time::format_description::well_known::Rfc3339)
                    .unwrap(),
            })
            .unwrap();
        status.verification.last_event = Some("input".to_string());
        assert!(cached_connection_status_is_current(&paths, &status));
        assert_eq!(
            super::project_connection_evidence(&paths, &status)
                .verification
                .last_event
                .as_deref(),
            Some("input"),
            "the authoritative projection must recover current ordinary evidence even though this minimal fixture omits the required runtime check items"
        );
    }

    #[test]
    fn claude_settings_only_residue_is_detected_without_claiming_foreign_helpers() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let cli = temp.path().join("runtime/current/petcore-cli");
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path().join("agents"));
        let _claude_root = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let install_root = paths.connectors_dir.join("claude-code");
        repair_claude(&install_root, &cli).unwrap();
        std::fs::remove_dir_all(&install_root).unwrap();

        assert!(connector_artifacts_present(&paths, AgentSource::ClaudeCode));

        std::fs::write(
            claude_settings_path(),
            serde_json::to_vec_pretty(&json!({
                "hooks": {
                    "PreToolUse": [{
                        "hooks": [{
                            "type": "command",
                            "command": "'/tmp/foreign/agent-pet-companion-hook.sh' >/dev/null 2>&1 || true"
                        }]
                    }]
                }
            }))
            .unwrap(),
        )
        .unwrap();
        assert!(!connector_artifacts_present(
            &paths,
            AgentSource::ClaudeCode
        ));
    }

    #[test]
    fn connector_receipt_requires_current_contract_and_post_install_timestamp() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let connector_cli = connector_cli_path(&paths);
        let extension = temp
            .path()
            .join(".pi/agent/extensions/agent-pet-companion.ts");
        std::fs::create_dir_all(extension.parent().unwrap()).unwrap();
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
        std::fs::write(&extension, &expected).unwrap();

        let current = ConnectorEventReceipt {
            sequence: 1,
            source_event: "connector.probe".to_string(),
            contract_version: Some(PI_EXTENSION_CONTRACT_VERSION.to_string()),
            created_at: "2999-01-01T00:00:00Z".to_string(),
            diagnostic: true,
        };
        assert!(connector_receipt_is_current(
            &paths,
            AgentSource::Pi,
            &current
        ));

        std::fs::write(
            &extension,
            "tampered connector with an older-looking receipt",
        )
        .unwrap();
        assert!(!connector_receipt_is_current(
            &paths,
            AgentSource::Pi,
            &current
        ));
        std::fs::write(&extension, &expected).unwrap();

        let stale_contract = ConnectorEventReceipt {
            contract_version: Some("pi-extension-stale".to_string()),
            ..current.clone()
        };
        assert!(!connector_receipt_is_current(
            &paths,
            AgentSource::Pi,
            &stale_contract
        ));

        let before_install = ConnectorEventReceipt {
            created_at: "1970-01-01T00:00:00Z".to_string(),
            ..current
        };
        assert!(!connector_receipt_is_current(
            &paths,
            AgentSource::Pi,
            &before_install
        ));
    }

    #[test]
    fn cache_revision_and_strict_freshness_reject_restored_mtime_tampering() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let connector_cli = connector_cli_path(&paths);
        let extension = temp
            .path()
            .join(".pi/agent/extensions/agent-pet-companion.ts");
        std::fs::create_dir_all(extension.parent().unwrap()).unwrap();
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
        std::fs::write(&extension, expected.as_bytes()).unwrap();

        let before = std::fs::metadata(&extension).unwrap();
        let before_revision = super::connection_light_cache_revision(&paths);
        let mut tampered = expected.into_bytes();
        let index = tampered.len() / 2;
        tampered[index] = if tampered[index] == b'X' { b'Y' } else { b'X' };
        std::thread::sleep(std::time::Duration::from_millis(2));
        std::fs::write(&extension, &tampered).unwrap();
        std::fs::File::open(&extension)
            .unwrap()
            .set_times(
                std::fs::FileTimes::new()
                    .set_accessed(before.accessed().unwrap())
                    .set_modified(before.modified().unwrap()),
            )
            .unwrap();
        let after = std::fs::metadata(&extension).unwrap();
        assert_eq!(after.ino(), before.ino());
        assert_eq!(after.len(), before.len());
        assert_eq!(after.modified().unwrap(), before.modified().unwrap());
        assert_ne!(
            super::connection_light_cache_revision(&paths),
            before_revision,
            "ctime must invalidate the metadata projection even when inode, size, and mtime are restored"
        );

        let freshness = super::ConnectorReceiptFreshness::load(&paths, AgentSource::Pi);
        assert!(!freshness.installation_exact);
        let receipt = ConnectorEventReceipt {
            sequence: 1,
            source_event: "input".to_string(),
            contract_version: Some(PI_EXTENSION_CONTRACT_VERSION.to_string()),
            created_at: "2999-01-01T00:00:00Z".to_string(),
            diagnostic: false,
        };
        assert!(!freshness.is_current(&receipt));
    }

    #[test]
    fn cached_host_verification_expires_and_rejects_future_timestamps() {
        let now = time::OffsetDateTime::now_utc();
        assert!(host_verification_check_is_fresh(now, now));
        assert!(host_verification_check_is_fresh(
            now - time::Duration::minutes(4),
            now
        ));
        assert!(!host_verification_check_is_fresh(
            now - time::Duration::minutes(6),
            now
        ));
        assert!(!host_verification_check_is_fresh(
            now + time::Duration::minutes(2),
            now
        ));
    }

    #[test]
    fn cached_runtime_checked_at_expiry_is_absolute_not_cache_relative() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&connector_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let _pi_cli = EnvVarGuard::set("APC_PI_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let extension_root = super::install_root(&paths, AgentSource::Pi);
        super::repair_pi(&extension_root, &connector_cli).unwrap();

        let checked_at = time::OffsetDateTime::now_utc() + time::Duration::seconds(2);
        let status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: Vec::new(),
            install_paths: super::connection_install_paths(&paths, AgentSource::Pi),
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::Pi),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: checked_at
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };

        assert!(super::cached_connection_status_is_current_at(
            &paths,
            &status,
            checked_at + time::Duration::minutes(4)
        ));
        assert!(!super::cached_connection_status_is_current_at(
            &paths,
            &status,
            checked_at + time::Duration::minutes(6)
        ));
        assert_eq!(
            status.checked_at,
            checked_at
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap()
        );
    }

    #[test]
    fn fast_light_admission_rejects_runtime_checked_before_artifact_update() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&connector_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let _pi_cli = EnvVarGuard::set("APC_PI_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let extension_root = super::install_root(&paths, AgentSource::Pi);
        super::repair_pi(&extension_root, &connector_cli).unwrap();
        let checked_at = time::OffsetDateTime::now_utc();
        let status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: Vec::new(),
            install_paths: super::connection_install_paths(&paths, AgentSource::Pi),
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::Pi),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: checked_at
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };
        assert!(super::cached_connection_status_is_current_for_light_projection(&paths, &status));

        std::thread::sleep(std::time::Duration::from_millis(2));
        std::fs::write(
            extension_root.join("agent-pet-companion.ts"),
            render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli),
        )
        .unwrap();
        assert!(
            !super::cached_connection_status_is_current_for_light_projection(&paths, &status),
            "a cold light scan may find the rewritten exact artifact healthy, but it must not reuse runtime evidence checked before that write"
        );
    }

    #[test]
    fn fast_light_admission_rejects_runtime_before_resolved_cli_target_update() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&connector_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let target_a = temp.path().join("pi-a");
        let target_b = temp.path().join("pi-b");
        let cli_link = temp.path().join("pi-current");
        std::fs::write(&target_a, "#!/bin/sh\nprintf 'pi 0.80.10\\n'\n# A\n").unwrap();
        std::fs::set_permissions(&target_a, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink(&target_a, &cli_link).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let _pi_cli = EnvVarGuard::set("APC_PI_CLI_PATH", &cli_link);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let extension_root = super::install_root(&paths, AgentSource::Pi);
        super::repair_pi(&extension_root, &connector_cli).unwrap();
        let checked_at = time::OffsetDateTime::now_utc();
        let status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: Vec::new(),
            install_paths: super::connection_install_paths(&paths, AgentSource::Pi),
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::Pi),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: checked_at
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };
        assert!(super::cached_connection_status_is_current_for_light_projection(&paths, &status));

        std::thread::sleep(std::time::Duration::from_millis(2));
        std::fs::write(&target_b, "#!/bin/sh\nprintf 'pi 0.80.10\\n'\n# B\n").unwrap();
        std::fs::set_permissions(&target_b, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::remove_file(&cli_link).unwrap();
        std::os::unix::fs::symlink(&target_b, &cli_link).unwrap();

        let light = super::check_source_with_runtime_smoke(
            &paths,
            AgentSource::Pi,
            false,
            temp.path(),
            None,
        );
        assert_eq!(
            light
                .items
                .iter()
                .find(|item| item.name == "Pi CLI")
                .map(|item| item.status),
            Some(CheckStatus::Ok),
            "the replacement target remains a resolvable, executable light-check CLI"
        );
        assert!(
            !super::cached_connection_status_is_current_for_light_projection(&paths, &status),
            "runtime authorization/version details checked against target A must not survive switching the resolved CLI to newer target B"
        );
    }

    #[test]
    fn evidence_projection_observes_new_ordinary_event_without_host_probe() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&connector_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let extension_root = super::install_root(&paths, AgentSource::Pi);
        super::repair_pi(&extension_root, &connector_cli).unwrap();
        let database = Database::new(&paths.db_path);
        database.init().unwrap();

        let status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: vec![ConnectionCheckItem::new(
                CheckCode::ManagedConnector,
                "Extension",
                CheckStatus::Ok,
                "exact",
                Some(RecoveryAction::ConfirmManagedRepair),
            )],
            install_paths: super::connection_install_paths(&paths, AgentSource::Pi),
            connector_installed: true,
            verification: AgentVerification {
                checked_cwd: Some(temp.path().display().to_string()),
                ..AgentVerification::default()
            },
            capabilities: capabilities_for_source(AgentSource::Pi),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };
        let before = super::project_connection_evidence(&paths, &status);
        assert_eq!(
            before.verification.status,
            AgentVerificationStatus::Unverified
        );

        database
            .insert_event(&AgentEvent {
                id: "evt_pi_fresh_evidence_projection".to_string(),
                source: AgentSource::Pi,
                project_path: None,
                session_id: Some("pi-evidence-session".to_string()),
                event_type: AgentEventType::Start,
                title: AgentEventType::Start.zh_label().to_string(),
                detail: None,
                payload_json: json!({
                    "source_event": "input",
                    "contract_version": PI_EXTENSION_CONTRACT_VERSION,
                    "diagnostic": false,
                    "affects_activity": true,
                    "session_active": true
                }),
                created_at: (time::OffsetDateTime::now_utc() + time::Duration::seconds(2))
                    .format(&time::format_description::well_known::Rfc3339)
                    .unwrap(),
            })
            .unwrap();

        let after = super::project_connection_evidence(&paths, &status);
        assert_eq!(after.verification.status, AgentVerificationStatus::Verified);
        assert_eq!(after.verification.last_event.as_deref(), Some("input"));
        assert_eq!(after.checked_at, status.checked_at);

        let static_light = super::check_source_with_runtime_smoke(
            &paths,
            AgentSource::Pi,
            false,
            temp.path(),
            None,
        );
        assert_eq!(static_light.check_mode, ConnectionCheckMode::Light);
        assert!(static_light.verification.last_event.is_none());
        let projected_light = super::project_connection_evidence(&paths, &static_light);
        assert_eq!(
            projected_light.verification.last_event.as_deref(),
            Some("input")
        );
    }

    #[test]
    fn light_cache_revision_tracks_path_overrides_and_every_agent_cli_candidate() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let _home = EnvVarGuard::set("HOME", temp.path());
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _path = EnvVarGuard::set("PATH", &bin);
        let _codex = EnvVarGuard::unset("APC_CODEX_CLI_PATH");
        let _claude = EnvVarGuard::unset("APC_CLAUDE_CLI_PATH");
        let _pi = EnvVarGuard::unset("APC_PI_CLI_PATH");
        let _opencode = EnvVarGuard::unset("APC_OPENCODE_CLI_PATH");
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let absent_revision = super::connection_light_cache_revision(&paths);
        for name in ["codex", "claude", "pi", "opencode"] {
            let candidate = bin.join(name);
            std::fs::write(&candidate, "#!/bin/sh\nexit 0\n").unwrap();
            std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o755)).unwrap();
            let installed_revision = super::connection_light_cache_revision(&paths);
            assert_ne!(installed_revision, absent_revision, "{name} install");
            std::fs::remove_file(candidate).unwrap();
        }

        let symlink_target = temp.path().join("opencode-target");
        std::fs::write(&symlink_target, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&symlink_target, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink(&symlink_target, bin.join("opencode")).unwrap();
        let symlink_revision = super::connection_light_cache_revision(&paths);
        std::fs::write(&symlink_target, "#!/bin/sh\nexit 42\n").unwrap();
        assert_ne!(
            super::connection_light_cache_revision(&paths),
            symlink_revision
        );

        let override_path = temp.path().join("override-pi");
        let _override = EnvVarGuard::set("APC_PI_CLI_PATH", &override_path);
        let missing_override_revision = super::connection_light_cache_revision(&paths);
        std::fs::write(&override_path, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&override_path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let installed_override_revision = super::connection_light_cache_revision(&paths);
        assert_ne!(installed_override_revision, missing_override_revision);

        let other_bin = temp.path().join("other-bin");
        std::fs::create_dir_all(&other_bin).unwrap();
        let _other_path = EnvVarGuard::set("PATH", &other_bin);
        assert_ne!(
            super::connection_light_cache_revision(&paths),
            installed_override_revision
        );
    }

    #[test]
    fn light_cache_revision_detects_parent_directory_replaced_by_symlink() {
        use std::hash::Hasher as _;

        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let cli = bin.join("pi");
        std::fs::write(&cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _home = EnvVarGuard::set("HOME", temp.path());
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _path = EnvVarGuard::set("PATH", &bin);
        let _codex = EnvVarGuard::unset("APC_CODEX_CLI_PATH");
        let _claude = EnvVarGuard::unset("APC_CLAUDE_CLI_PATH");
        let _pi = EnvVarGuard::unset("APC_PI_CLI_PATH");
        let _opencode = EnvVarGuard::unset("APC_OPENCODE_CLI_PATH");
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let mut leaf_before = std::collections::hash_map::DefaultHasher::new();
        super::hash_path_metadata(&cli, &mut leaf_before);
        let leaf_before = leaf_before.finish();
        let revision_before = super::connection_light_cache_revision(&paths);

        let relocated_bin = temp.path().join("relocated-bin");
        std::fs::rename(&bin, &relocated_bin).unwrap();
        std::os::unix::fs::symlink(&relocated_bin, &bin).unwrap();

        let mut leaf_after = std::collections::hash_map::DefaultHasher::new();
        super::hash_path_metadata(&cli, &mut leaf_after);
        assert_eq!(
            leaf_after.finish(),
            leaf_before,
            "the leaf and followed target metadata must remain identical"
        );
        assert_ne!(
            super::connection_light_cache_revision(&paths),
            revision_before,
            "the parent lstat identity must invalidate the light projection"
        );
    }

    #[test]
    fn cached_verification_requires_every_artifact_in_the_current_host_config_root() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let custom_pi_root = temp.path().join("pi-root-a");
        let switched_pi_root = temp.path().join("pi-root-b");
        let connector_cli = temp.path().join("petcore-cli");
        std::fs::write(&connector_cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::unset("APC_AGENT_CONFIG_HOME");
        let _pi_root = EnvVarGuard::set("PI_CODING_AGENT_DIR", &custom_pi_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &connector_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        let expected = render_connector_script(PI_EXTENSION_TEMPLATE, &connector_cli);
        let extension = custom_pi_root
            .join("extensions")
            .join("agent-pet-companion.ts");
        std::fs::create_dir_all(extension.parent().unwrap()).unwrap();
        std::fs::write(&extension, &expected).unwrap();
        let checked_at = time::OffsetDateTime::now_utc()
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let status = AgentConnectionStatus {
            source: AgentSource::Pi,
            items: vec![],
            install_paths: vec![custom_pi_root.join("extensions").display().to_string()],
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::Pi),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at,
        };

        assert!(cached_connection_status_is_current(&paths, &status));
        std::fs::remove_file(&extension).unwrap();
        assert!(!cached_connection_status_is_current(&paths, &status));

        std::fs::create_dir_all(extension.parent().unwrap()).unwrap();
        std::fs::write(&extension, &expected).unwrap();
        let switched_extension = switched_pi_root
            .join("extensions")
            .join("agent-pet-companion.ts");
        std::fs::create_dir_all(switched_extension.parent().unwrap()).unwrap();
        std::fs::write(&switched_extension, &expected).unwrap();
        let _switched_pi_root = EnvVarGuard::set("PI_CODING_AGENT_DIR", &switched_pi_root);
        assert!(!cached_connection_status_is_current(&paths, &status));
    }

    #[test]
    fn claude_root_helper_and_fragment_symlinks_are_never_followed_or_cached() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path().join("agents"));
        let _claude_root = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let install_root = paths.connectors_dir.join("claude-code");

        let external_root = temp.path().join("external-root");
        std::fs::create_dir(&external_root).unwrap();
        std::os::unix::fs::symlink(&external_root, &install_root).unwrap();
        assert!(repair_claude(&install_root, &cli).is_err());
        assert!(std::fs::read_dir(&external_root).unwrap().next().is_none());
        assert!(connections::uninstall_source(&paths, AgentSource::ClaudeCode).is_err());
        std::fs::remove_file(&install_root).unwrap();

        repair_claude(&install_root, &cli).unwrap();
        let status = AgentConnectionStatus {
            source: AgentSource::ClaudeCode,
            items: vec![],
            install_paths: super::connection_install_paths(&paths, AgentSource::ClaudeCode),
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::ClaudeCode),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };
        assert!(cached_connection_status_is_current(&paths, &status));

        let helper = install_root.join("agent-pet-companion-hook.sh");
        let helper_bytes = std::fs::read(&helper).unwrap();
        let external_helper = temp.path().join("external-helper.sh");
        std::fs::write(&external_helper, &helper_bytes).unwrap();
        std::fs::set_permissions(&external_helper, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::remove_file(&helper).unwrap();
        std::os::unix::fs::symlink(&external_helper, &helper).unwrap();
        assert!(check_claude_hook(&helper, &cli).name.ends_with("冲突"));
        assert!(!cached_connection_status_is_current(&paths, &status));
        assert!(repair_claude(&install_root, &cli).is_err());
        assert_eq!(std::fs::read(&external_helper).unwrap(), helper_bytes);
        assert_eq!(
            std::fs::metadata(&external_helper)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o644
        );
        std::fs::remove_file(&helper).unwrap();
        std::fs::write(&helper, rendered_claude_hook(&cli)).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();

        let fragment = install_root.join("settings.fragment.json");
        let fragment_bytes = std::fs::read(&fragment).unwrap();
        let external_fragment = temp.path().join("external-fragment.json");
        std::fs::write(&external_fragment, &fragment_bytes).unwrap();
        std::fs::remove_file(&fragment).unwrap();
        std::os::unix::fs::symlink(&external_fragment, &fragment).unwrap();
        assert!(super::check_claude_fragment(&fragment, &cli, &install_root)
            .name
            .ends_with("冲突"));
        assert!(!cached_connection_status_is_current(&paths, &status));
        assert!(repair_claude(&install_root, &cli).is_err());
        assert_eq!(std::fs::read(&external_fragment).unwrap(), fragment_bytes);
    }

    #[test]
    fn codex_managed_file_symlinks_never_pass_checks_cache_or_repair() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path().join("agents"));
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let root = super::codex_plugin_source_root();
        super::repair_codex(&root, &cli).unwrap();
        let status = AgentConnectionStatus {
            source: AgentSource::Codex,
            items: vec![],
            install_paths: super::connection_install_paths(&paths, AgentSource::Codex),
            connector_installed: true,
            verification: AgentVerification::default(),
            capabilities: capabilities_for_source(AgentSource::Codex),
            check_mode: ConnectionCheckMode::Runtime,
            checked_at: time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
        };
        assert!(cached_connection_status_is_current(&paths, &status));

        for (relative, label) in [
            (".codex-plugin/plugin.json", "插件源"),
            ("hooks/hooks.json", "Hook"),
            ("skills/agent-pet-studio/SKILL.md", "Pet Studio Skill"),
        ] {
            let path = root.join(relative);
            let bytes = std::fs::read(&path).unwrap();
            let external = temp.path().join(relative.replace('/', "-"));
            std::fs::write(&external, &bytes).unwrap();
            std::fs::remove_file(&path).unwrap();
            std::os::unix::fs::symlink(&external, &path).unwrap();

            let check = match label {
                "插件源" => super::check_codex_plugin_manifest(&path, &root),
                "Hook" => super::check_codex_hooks(&path, &cli, &root),
                _ => super::check_codex_studio_skill(&path, &root),
            };
            assert!(check.name.ends_with("冲突"));
            assert!(!cached_connection_status_is_current(&paths, &status));
            assert!(super::write_codex_connector(&root, &cli).is_err());
            assert_eq!(std::fs::read(&external).unwrap(), bytes);

            std::fs::remove_file(&path).unwrap();
            std::fs::write(&path, bytes).unwrap();
        }
    }

    #[test]
    fn codex_marketplace_foreign_entries_and_symlinks_are_preserved() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let marketplace = codex_marketplace_path();
        std::fs::create_dir_all(marketplace.parent().unwrap()).unwrap();
        let foreign = serde_json::to_vec_pretty(&json!({
            "plugins": [{
                "name": "agent-pet-companion",
                "source": { "source": "remote", "path": "./foreign" }
            }]
        }))
        .unwrap();
        std::fs::write(&marketplace, &foreign).unwrap();
        assert!(super::check_codex_marketplace_entry()
            .name
            .ends_with("冲突"));
        assert!(ensure_codex_marketplace_entry().is_err());
        assert!(remove_codex_marketplace_entry().is_err());
        assert_eq!(std::fs::read(&marketplace).unwrap(), foreign);

        let mut outdated = super::codex_marketplace_entry();
        outdated["policy"]["authentication"] = json!("OUTDATED");
        std::fs::write(
            &marketplace,
            serde_json::to_vec_pretty(&json!({ "plugins": [outdated] })).unwrap(),
        )
        .unwrap();
        assert_eq!(
            super::codex_marketplace_entry_state(&marketplace),
            super::CodexMarketplaceEntryState::OwnedOutdated
        );
        ensure_codex_marketplace_entry().unwrap();
        assert_eq!(
            super::codex_marketplace_entry_state(&marketplace),
            super::CodexMarketplaceEntryState::Current
        );

        let target = temp.path().join("marketplace-target.json");
        let target_bytes = std::fs::read(&marketplace).unwrap();
        std::fs::write(&target, &target_bytes).unwrap();
        std::fs::remove_file(&marketplace).unwrap();
        std::os::unix::fs::symlink(&target, &marketplace).unwrap();
        assert!(ensure_codex_marketplace_entry().is_err());
        assert!(remove_codex_marketplace_entry().is_err());
        assert_eq!(std::fs::read(&target).unwrap(), target_bytes);
    }

    #[test]
    fn json_backup_collisions_never_overwrite_external_content() {
        let temp = tempfile::tempdir().unwrap();
        let config = temp.path().join("settings.json");
        let original = json!({ "before": true });
        let updated = json!({ "after": true });
        std::fs::write(&config, serde_json::to_vec_pretty(&original).unwrap()).unwrap();
        let backup = json_config_backup_path(&config);
        let external = temp.path().join("external-backup-target");
        std::fs::write(&external, "never overwrite").unwrap();
        std::os::unix::fs::symlink(&external, &backup).unwrap();

        assert!(super::write_json_config_if_changed(&config, &original, &updated).is_err());
        assert_eq!(
            std::fs::read_to_string(&external).unwrap(),
            "never overwrite"
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(&config).unwrap()).unwrap(),
            original
        );

        std::fs::remove_file(&backup).unwrap();
        std::fs::write(&backup, "foreign backup; preserve").unwrap();
        super::write_json_config_if_changed(&config, &original, &updated).unwrap();
        assert_eq!(
            std::fs::read_to_string(&backup).unwrap(),
            "foreign backup; preserve"
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(&config).unwrap()).unwrap(),
            updated
        );
    }

    #[test]
    fn failed_json_backup_copy_never_leaves_a_partial_recovery_file() {
        let temp = tempfile::tempdir().unwrap();
        let unreadable_as_file = temp.path().join("broken.json");
        std::fs::create_dir(&unreadable_as_file).unwrap();
        let backup = json_config_backup_path(&unreadable_as_file);

        assert!(backup_json_config(&unreadable_as_file).is_err());
        assert!(
            !backup.exists(),
            "a failed backup must not look like a valid recovery copy"
        );
    }

    #[test]
    fn uninstall_removes_recognized_legacy_codex_and_claude_artifacts_only() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agents");
        let config_root = temp.path().join("claude-config");
        let cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _claude_root = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let codex_root = super::codex_plugin_source_root();
        super::repair_codex(&codex_root, &cli).unwrap();
        std::fs::write(
            codex_root.join("hooks/hooks.json"),
            r#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"petcore-cli agent hook --source codex --event-type auto"}]}]}}"#,
        )
        .unwrap();
        std::fs::write(
            codex_root.join("skills/agent-pet-maker/references/security.md"),
            "# Agent Pet Companion agent-pet-maker legacy security\n",
        )
        .unwrap();
        connections::uninstall_source(&paths, AgentSource::Codex).unwrap();
        assert!(!codex_root.exists());

        let claude_root = paths.connectors_dir.join("claude-code");
        repair_claude(&claude_root, &cli).unwrap();
        std::fs::write(
            claude_root.join("agent-pet-companion-hook.sh"),
            format!(
                "#!/usr/bin/env bash\nset -euo pipefail\nEVENT_TYPE=\"${{APC_EVENT_TYPE:-tool}}\"\n'{}' agent hook --source claude_code --event-type \"$EVENT_TYPE\" >/dev/null 2>&1\n",
                cli.display()
            ),
        )
        .unwrap();
        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();
        assert!(!claude_root.exists());
        assert!(!std::fs::read_to_string(claude_settings_path())
            .unwrap()
            .contains("agent-pet-companion-hook.sh"));
    }

    struct EnvVarGuard {
        key: &'static str,
        original: Option<OsString>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: impl AsRef<OsStr>) -> Self {
            let original = std::env::var_os(key);
            std::env::set_var(key, value);
            Self { key, original }
        }

        fn unset(key: &'static str) -> Self {
            let original = std::env::var_os(key);
            std::env::remove_var(key);
            Self { key, original }
        }
    }

    #[test]
    fn installed_connectors_follow_the_stable_current_runtime_cli() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let version = paths.home.join("runtime/versions/build-a");
        std::fs::create_dir_all(&version).unwrap();
        let versioned_cli = version.join("petcore-cli");
        std::fs::write(&versioned_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&versioned_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink("versions/build-a", paths.home.join("runtime/current")).unwrap();
        let _connector_cli = EnvVarGuard::unset("APC_CONNECTOR_CLI_PATH");

        assert_eq!(
            connector_cli_path(&paths),
            paths.home.join("runtime/current/petcore-cli")
        );
    }

    #[test]
    fn connector_install_roots_follow_official_host_config_directories() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let pi_root = temp.path().join("pi-agent-root");
        let opencode_root = temp.path().join("opencode-config-root");
        let hermetic_home = temp.path().join("hermetic-home");
        let _agent_home = EnvVarGuard::unset("APC_AGENT_CONFIG_HOME");
        let _pi_root = EnvVarGuard::set("PI_CODING_AGENT_DIR", &pi_root);
        let _opencode_root = EnvVarGuard::set("OPENCODE_CONFIG_DIR", &opencode_root);

        assert_eq!(pi_extensions_dir(), pi_root.join("extensions"));
        assert_eq!(opencode_plugins_dir(), opencode_root.join("plugins"));

        let _hermetic_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &hermetic_home);
        assert_eq!(
            pi_extensions_dir(),
            hermetic_home.join(".pi/agent/extensions")
        );
        assert_eq!(
            opencode_plugins_dir(),
            hermetic_home.join(".config/opencode/plugins")
        );
    }

    #[test]
    fn relative_host_config_roots_are_ignored_consistently() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _home = EnvVarGuard::set("HOME", temp.path());
        let _agent_home = EnvVarGuard::unset("APC_AGENT_CONFIG_HOME");
        let _claude = EnvVarGuard::set("CLAUDE_CONFIG_DIR", "relative/claude");
        let _pi = EnvVarGuard::set("PI_CODING_AGENT_DIR", "relative/pi");
        let _opencode = EnvVarGuard::set("OPENCODE_CONFIG_DIR", "relative/opencode");
        let _xdg = EnvVarGuard::set("XDG_CONFIG_HOME", "relative/xdg");

        assert_eq!(
            claude_settings_path(),
            temp.path().join(".claude/settings.json")
        );
        assert_eq!(
            pi_extensions_dir(),
            temp.path().join(".pi/agent/extensions")
        );
        assert_eq!(
            opencode_plugins_dir(),
            temp.path().join(".config/opencode/plugins")
        );
    }

    #[test]
    fn command_lookup_skips_non_executable_shadow_candidates() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let blocked = temp.path().join("blocked");
        let usable = temp.path().join("usable");
        std::fs::create_dir_all(&blocked).unwrap();
        std::fs::create_dir_all(&usable).unwrap();
        std::fs::write(blocked.join("pi"), "not executable").unwrap();
        std::fs::write(usable.join("pi"), "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(usable.join("pi"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        let path = std::env::join_paths([blocked, usable.clone()]).unwrap();
        let _path = EnvVarGuard::set("PATH", path);
        let _override = EnvVarGuard::unset("APC_PI_CLI_PATH");

        assert_eq!(agent_command_path(AgentSource::Pi), Some(usable.join("pi")));
    }

    #[test]
    fn invalid_explicit_cli_override_is_reported_instead_of_silently_falling_back() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let fallback = temp.path().join("fallback");
        std::fs::create_dir_all(&fallback).unwrap();
        std::fs::write(fallback.join("pi"), "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(fallback.join("pi"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        let invalid = temp.path().join("missing-pi");
        let _path = EnvVarGuard::set("PATH", &fallback);
        let _override = EnvVarGuard::set("APC_PI_CLI_PATH", &invalid);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let status =
            check_source_with_runtime_smoke(&paths, AgentSource::Pi, false, temp.path(), None);
        let cli = status.items.first().unwrap();
        assert_eq!(cli.status, CheckStatus::Missing);
        assert!(cli.detail.contains("APC_PI_CLI_PATH"));
        assert!(cli.detail.contains("不存在或不可执行"));
    }

    #[test]
    fn command_search_includes_the_official_opencode_installer_directory() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _home = EnvVarGuard::set("HOME", temp.path());
        let _path = EnvVarGuard::set("PATH", "");
        assert!(command_search_dirs().contains(&temp.path().join(".opencode/bin")));
    }

    #[test]
    fn repair_and_uninstall_use_official_pi_and_opencode_config_roots() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let pi_root = temp.path().join("pi-agent-root");
        let opencode_root = temp.path().join("opencode-config-root");
        let cli = temp.path().join("petcore-cli");
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("pi"), "#!/bin/sh\necho 'pi 0.80.10'\n").unwrap();
        std::fs::write(bin.join("opencode"), "#!/bin/sh\necho 'opencode 1.18.0'\n").unwrap();
        std::fs::set_permissions(bin.join("pi"), std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(bin.join("opencode"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        std::fs::write(&cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::unset("APC_AGENT_CONFIG_HOME");
        let _pi_root = EnvVarGuard::set("PI_CODING_AGENT_DIR", &pi_root);
        let _opencode_root = EnvVarGuard::set("OPENCODE_CONFIG_DIR", &opencode_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &cli);
        let _path = EnvVarGuard::set("PATH", &bin);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let pi_status = connections::repair_source(&paths, AgentSource::Pi).unwrap();
        let pi_extension = pi_root.join("extensions/agent-pet-companion.ts");
        assert!(pi_extension.is_file());
        assert!(pi_status
            .install_paths
            .contains(&pi_root.join("extensions").display().to_string()));

        let opencode_status = connections::repair_source(&paths, AgentSource::Opencode).unwrap();
        let opencode_plugin = opencode_root.join("plugins/agent-pet-companion.js");
        assert!(opencode_plugin.is_file());
        assert!(opencode_status
            .install_paths
            .contains(&opencode_root.join("plugins").display().to_string()));

        connections::uninstall_source(&paths, AgentSource::Pi).unwrap();
        connections::uninstall_source(&paths, AgentSource::Opencode).unwrap();
        assert!(!pi_extension.exists());
        assert!(!opencode_plugin.exists());
    }

    #[test]
    fn stable_claude_connector_recognizes_only_its_prior_versioned_cli_paths() {
        let stable = Path::new(
            "/Users/test/Library/Application Support/AgentPetCompanion/runtime/current/petcore-cli",
        );
        let install_root = Path::new(
            "/Users/test/Library/Application Support/AgentPetCompanion/connectors/claude-code",
        );
        let prior = "'/Users/test/Library/Application Support/AgentPetCompanion/runtime/versions/0.1.0.1.20260715/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1";
        let forged_build = "'/Users/test/Library/Application Support/AgentPetCompanion/runtime/versions/../../foreign/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1";
        let foreign = "'/Users/test/other/runtime/versions/0.1.0/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1";
        let legacy_bundle = "'/Users/test/project/dist/AgentPetCompanion.app/Contents/Resources/bin/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1";
        let current_with_contract = "APC_CONNECTOR_CONTRACT_VERSION='claude-hooks-2026-07-17-activity-v5' '/Users/test/Library/Application Support/AgentPetCompanion/runtime/current/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1 || true";

        assert!(is_agent_pet_claude_command(
            prior,
            stable,
            Some(install_root)
        ));
        assert!(!is_agent_pet_claude_command(
            forged_build,
            stable,
            Some(install_root)
        ));
        assert!(!is_agent_pet_claude_command(
            foreign,
            stable,
            Some(install_root)
        ));
        assert!(is_agent_pet_claude_command(
            legacy_bundle,
            stable,
            Some(install_root)
        ));
        assert!(is_agent_pet_claude_command(
            current_with_contract,
            stable,
            Some(install_root)
        ));
    }

    #[test]
    fn claude_repair_migrates_legacy_bundle_hooks_to_one_current_group_per_event() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let install_root = temp.path().join("connector");
        let cli = temp.path().join("runtime/current/petcore-cli");
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, "#!/bin/sh\nexit 0\n").unwrap();
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();

        let fragment = rendered_claude_settings_fragment(&cli, &install_root).unwrap();
        let mut duplicated = fragment.clone();
        let legacy = "'/Users/test/project/dist/AgentPetCompanion.app/Contents/Resources/bin/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1 || true";
        for groups in duplicated["hooks"]
            .as_object_mut()
            .unwrap()
            .values_mut()
            .take(20)
        {
            groups.as_array_mut().unwrap().push(json!({
                "hooks": [{
                    "type": "command",
                    "command": legacy,
                    "async": false,
                    "timeout": 2
                }]
            }));
        }
        std::fs::write(&settings, serde_json::to_vec_pretty(&duplicated).unwrap()).unwrap();

        super::repair_claude(&install_root, &cli).unwrap();

        let repaired_text = std::fs::read_to_string(&settings).unwrap();
        let repaired: serde_json::Value = serde_json::from_str(&repaired_text).unwrap();
        assert_eq!(
            repaired_text.matches("agent-pet-companion-hook.sh").count(),
            27
        );
        assert!(!repaired_text.contains("agent hook --source claude_code"));
        assert!(!repaired_text.contains("AgentPetCompanion.app/Contents/Resources/bin/petcore-cli"));
        assert!(super::claude_settings_match_owned_fragment(
            &repaired, &fragment
        ));
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    #[test]
    fn codex_plugin_text_parser_does_not_cross_match_other_installed_plugins() {
        let stdout = r#"
PLUGIN                        STATUS         VERSION  PATH
agent-pet-companion@personal  not installed           /Users/me/.agents/plugins/plugins/agent-pet-companion
browser@openai-bundled        installed, enabled  1.0 /tmp/browser
"#;

        assert!(!codex_plugin_text_reports_installed(stdout));
        assert!(!codex_plugin_text_reports_present(stdout));
    }

    #[test]
    fn codex_plugin_json_parser_requires_agent_pet_installed_and_enabled() {
        let available_only = serde_json::to_vec(&json!({
            "installed": [
                {
                    "pluginId": "browser@openai-bundled",
                    "name": "browser",
                    "marketplaceName": "openai-bundled",
                    "installed": true,
                    "enabled": true
                }
            ],
            "available": [
                {
                    "pluginId": "agent-pet-companion@personal",
                    "name": "agent-pet-companion",
                    "marketplaceName": "personal",
                    "installed": false,
                    "enabled": false
                }
            ]
        }))
        .unwrap();
        assert_eq!(
            codex_plugin_json_reports_installed(&available_only),
            Some(false)
        );

        let installed = serde_json::to_vec(&json!({
            "installed": [
                {
                    "pluginId": "agent-pet-companion@personal",
                    "name": "agent-pet-companion",
                    "marketplaceName": "personal",
                    "installed": true,
                    "enabled": true
                }
            ]
        }))
        .unwrap();
        assert_eq!(codex_plugin_json_reports_installed(&installed), Some(true));
        assert_eq!(codex_plugin_json_reports_present(&installed), Some(true));

        let disabled = serde_json::to_vec(&json!({
            "installed": [{
                "pluginId": "agent-pet-companion@personal",
                "installed": true,
                "enabled": false
            }]
        }))
        .unwrap();
        assert_eq!(codex_plugin_json_reports_installed(&disabled), Some(false));
        assert_eq!(codex_plugin_json_reports_present(&disabled), Some(true));
    }

    #[test]
    fn codex_plugin_uninstall_is_idempotent_and_never_hides_a_failed_removal() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let cli = temp.path().join("codex");
        let remove_marker = temp.path().join("remove-ran");
        let _agent_home = EnvVarGuard::unset("APC_AGENT_CONFIG_HOME");
        let _codex_cli = EnvVarGuard::set("APC_CODEX_CLI_PATH", &cli);

        std::fs::write(
            &cli,
            format!(
                "#!/bin/sh\nif [ \"${{1-}}\" = plugin ] && [ \"${{2-}}\" = list ]; then printf '%s' '{{\"installed\":[]}}'; exit 0; fi\nprintf ran > '{}'\nexit 9\n",
                remove_marker.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        uninstall_codex_plugin_if_possible().unwrap();
        assert!(
            !remove_marker.exists(),
            "absent plugin should not be removed"
        );

        std::fs::write(
            &cli,
            format!(
                "#!/bin/sh\nif [ \"${{1-}}\" = plugin ] && [ \"${{2-}}\" = list ]; then printf '%s' '{{\"installed\":[{{\"pluginId\":\"agent-pet-companion@personal\",\"installed\":true,\"enabled\":true}}]}}'; exit 0; fi\nprintf ran > '{}'\nexit 9\n",
                remove_marker.display()
            ),
        )
        .unwrap();
        let error = uninstall_codex_plugin_if_possible().unwrap_err();
        assert!(error.to_string().contains("plugin remove 未成功"));
        assert!(remove_marker.is_file());
    }

    #[test]
    fn codex_marketplace_parser_returns_agent_pet_source_path() {
        let temp = tempfile::tempdir().unwrap();
        let marketplace = temp.path().join("marketplace.json");
        std::fs::write(
            &marketplace,
            serde_json::to_vec(&json!({
                "plugins": [
                    {
                        "name": "cowart",
                        "source": { "path": "./plugins/cowart" }
                    },
                    {
                        "name": "agent-pet-companion",
                        "source": { "path": "./.agents/plugins/plugins/agent-pet-companion" }
                    }
                ]
            }))
            .unwrap(),
        )
        .unwrap();

        assert_eq!(
            codex_marketplace_entry_path(&marketplace).as_deref(),
            Some("./.agents/plugins/plugins/agent-pet-companion")
        );
    }

    #[test]
    fn invalid_codex_marketplace_is_not_overwritten() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let marketplace = codex_marketplace_path();
        std::fs::create_dir_all(marketplace.parent().unwrap()).unwrap();
        let invalid_json = "{ not valid marketplace json";
        std::fs::write(&marketplace, invalid_json).unwrap();

        let repair_error = ensure_codex_marketplace_entry().unwrap_err();
        assert!(repair_error.to_string().contains("无效结构"));
        assert_eq!(std::fs::read_to_string(&marketplace).unwrap(), invalid_json);
        assert!(!json_config_backup_path(&marketplace).exists());

        let uninstall_error = remove_codex_marketplace_entry().unwrap_err();
        assert!(uninstall_error.to_string().contains("无效结构"));
        assert_eq!(std::fs::read_to_string(&marketplace).unwrap(), invalid_json);
    }

    #[test]
    fn invalid_claude_settings_is_not_overwritten() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let invalid_json = "{ not valid claude settings json";
        std::fs::write(&settings, invalid_json).unwrap();
        let hook_entries = [(
            "PreToolUse",
            "petcore-cli agent hook --source claude_code --event-type tool".to_string(),
        )];

        let repair_error = install_claude_settings(&hook_entries).unwrap_err();
        assert!(repair_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&settings).unwrap(), invalid_json);
        assert!(!json_config_backup_path(&settings).exists());

        let uninstall_error =
            remove_claude_settings_hooks(temp.path(), Path::new("petcore-cli")).unwrap_err();
        assert!(uninstall_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&settings).unwrap(), invalid_json);
    }

    #[test]
    fn claude_uninstall_preserves_mixed_hook_group() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path().join("agents"));
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let settings = claude_settings_path();
        assert_eq!(settings, config_root.join("settings.json"));
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Bash",
                            "groupExtension": { "preserve": true },
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "echo keep-user-hook",
                                    "timeout": 4,
                                    "unknownHookField": "keep"
                                },
                                {
                                    "type": "command",
                                    "command": "'/Applications/Agent Pet Companion/petcore-cli' agent hook --source claude_code --event-type tool"
                                }
                            ]
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        remove_claude_settings_hooks(
            temp.path(),
            Path::new("/Applications/Agent Pet Companion/petcore-cli"),
        )
        .unwrap();

        let updated: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        let group = &updated["hooks"]["PreToolUse"][0];
        assert_eq!(group["matcher"], "Bash");
        assert_eq!(group["groupExtension"]["preserve"], true);
        assert_eq!(group["hooks"].as_array().unwrap().len(), 1);
        assert_eq!(group["hooks"][0]["command"], "echo keep-user-hook");
        assert_eq!(group["hooks"][0]["unknownHookField"], "keep");
    }

    #[test]
    fn claude_uninstall_removes_only_exact_owned_hook_commands() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let agent_home = temp.path().join("agents");
        let fake_cli = temp.path().join("owned").join("petcore-cli");
        let foreign_cli = temp.path().join("foreign").join("petcore-cli");
        std::fs::create_dir_all(fake_cli.parent().unwrap()).unwrap();
        std::fs::create_dir_all(foreign_cli.parent().unwrap()).unwrap();
        std::fs::write(&fake_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::write(&foreign_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&foreign_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &fake_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let canonical_helper = paths
            .connectors_dir
            .join("claude-code")
            .join("agent-pet-companion-hook.sh");
        let foreign_helper = temp
            .path()
            .join("foreign")
            .join("agent-pet-companion-hook.sh");
        let owned_cli_command = format!(
            "'{}' agent hook --source claude_code --event-type auto >/dev/null 2>&1",
            fake_cli.display()
        );
        let foreign_cli_command = format!(
            "'{}' agent hook --source claude_code --event-type auto >/dev/null 2>&1",
            foreign_cli.display()
        );
        let owned_helper_command =
            format!("'{}' >/dev/null 2>&1 || true", canonical_helper.display());
        let foreign_helper_command = format!("'{}'", foreign_helper.display());
        let legacy_bundled_command = "'/Users/test/project/dist/AgentPetCompanion.app/Contents/Resources/bin/petcore-cli' agent hook --source claude_code --event-type auto >/dev/null 2>&1".to_string();
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "hooks": {
                    "PreToolUse": [{
                        "hooks": [
                            { "type": "command", "command": owned_cli_command },
                            { "type": "command", "command": foreign_cli_command },
                            { "type": "command", "command": owned_helper_command },
                            { "type": "command", "command": foreign_helper_command },
                            { "type": "command", "command": legacy_bundled_command }
                        ]
                    }]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();

        let updated: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        let hooks = updated["hooks"]["PreToolUse"][0]["hooks"]
            .as_array()
            .unwrap();
        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0]["command"], foreign_cli_command);
        assert_eq!(hooks[1]["command"], foreign_helper_command);
    }

    #[test]
    fn claude_uninstall_preserves_unknown_settings_fields() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", temp.path().join(".claude"));
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let expected_unknown = json!({
            "future": [1, { "nested": "agent hook --source claude_code is documentation" }]
        });
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "$schema": "https://example.invalid/claude-settings.schema.json",
                "theme": "dark",
                "futureSettings": expected_unknown,
                "hooks": {
                    "Stop": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "petcore-cli agent hook --source claude_code --event-type done"
                                }
                            ]
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        remove_claude_settings_hooks(temp.path(), Path::new("petcore-cli")).unwrap();

        let updated: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        assert_eq!(
            updated["$schema"],
            "https://example.invalid/claude-settings.schema.json"
        );
        assert_eq!(updated["theme"], "dark");
        assert_eq!(updated["futureSettings"], expected_unknown);
        assert!(updated.get("hooks").is_none());
    }

    #[test]
    fn normal_json_repair_and_uninstall_are_idempotent() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agent-home");
        let fake_cli = temp.path().join("petcore-cli");
        std::fs::write(&fake_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &fake_cli);
        let _app_server_cmd = EnvVarGuard::set("CODEX_APP_SERVER_CMD", "");
        let _disable_app_server_auto = EnvVarGuard::set("APC_DISABLE_CODEX_APP_SERVER_AUTO", "1");
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let marketplace = codex_marketplace_path();
        std::fs::create_dir_all(marketplace.parent().unwrap()).unwrap();
        std::fs::write(
            &marketplace,
            serde_json::to_vec_pretty(&json!({
                "name": "personal",
                "interface": { "displayName": "Personal" },
                "plugins": [
                    {
                        "name": "keep-plugin",
                        "source": { "source": "local", "path": "./plugins/keep-plugin" }
                    }
                ]
            }))
            .unwrap(),
        )
        .unwrap();
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "theme": "dark",
                "hooks": {
                    "PreToolUse": [
                        {
                            "hooks": [
                                { "type": "command", "command": "echo keep" }
                            ]
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        connections::repair_source(&paths, AgentSource::Codex).unwrap();
        connections::repair_source(&paths, AgentSource::Codex).unwrap();
        let repaired_marketplace: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marketplace).unwrap()).unwrap();
        let plugins = repaired_marketplace["plugins"].as_array().unwrap();
        assert_eq!(agent_pet_plugin_count(&repaired_marketplace), 1);
        assert!(plugins
            .iter()
            .any(|plugin| plugin["name"].as_str() == Some("keep-plugin")));
        assert!(json_config_backup_path(&marketplace).is_file());

        connections::repair_source(&paths, AgentSource::ClaudeCode).unwrap();
        connections::repair_source(&paths, AgentSource::ClaudeCode).unwrap();
        let repaired_settings = std::fs::read_to_string(&settings).unwrap();
        assert!(repaired_settings.contains("agent-pet-companion-hook.sh"));
        assert!(!repaired_settings.contains("agent hook --source claude_code"));
        assert!(repaired_settings.contains("echo keep"));
        assert!(json_config_backup_path(&settings).is_file());

        connections::uninstall_source(&paths, AgentSource::Codex).unwrap();
        connections::uninstall_source(&paths, AgentSource::Codex).unwrap();
        let uninstalled_marketplace: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marketplace).unwrap()).unwrap();
        assert_eq!(agent_pet_plugin_count(&uninstalled_marketplace), 0);
        assert!(uninstalled_marketplace["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .any(|plugin| plugin["name"].as_str() == Some("keep-plugin")));

        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();
        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();
        let uninstalled_settings = std::fs::read_to_string(&settings).unwrap();
        assert!(!uninstalled_settings.contains("agent hook --source claude_code"));
        assert!(!uninstalled_settings.contains("agent-pet-companion-hook.sh"));
        assert!(uninstalled_settings.contains("echo keep"));
        assert!(uninstalled_settings.contains("\"theme\": \"dark\""));
    }

    #[test]
    fn opencode_server_probe_requires_valid_health_json() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let opencode = bin.join("opencode");
        let curl = bin.join("curl");
        std::fs::write(&opencode, "#!/bin/sh\nexec /bin/sleep 10\n").unwrap();
        std::fs::write(
            &curl,
            "#!/bin/sh\nprintf '%s' '{\"healthy\":true,\"version\":\"test\"}'\n",
        )
        .unwrap();
        std::fs::set_permissions(&opencode, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _path = EnvVarGuard::set("PATH", &bin);

        let check = connections::probe_opencode_server();

        assert_eq!(check.status, CheckStatus::Ok);
        assert!(check.detail.contains("runtime_verified"));
    }

    #[test]
    fn opencode_debug_plugin_path_accepts_percent_encoded_file_urls() {
        let plugin = Path::new("/Users/test/配置 根/plugins/agent-pet-companion.js");
        let stdout = b"plugins\n  file:///Users/test/%E9%85%8D%E7%BD%AE%20%E6%A0%B9/plugins/agent-pet-companion.js\n";
        assert!(opencode_debug_reports_plugin(stdout, plugin));
        assert!(!opencode_debug_reports_plugin(
            b"file:///Users/test/other/agent-pet-companion.js",
            plugin
        ));
        assert!(!opencode_debug_reports_plugin(
            b"plugins:\n- file:///Users/test/%E9%85%8D%E7%BD%AE%20%E6%A0%B9/plugins/agent-pet-companion.js.disabled\n",
            plugin
        ));
    }

    fn agent_pet_plugin_count(marketplace: &serde_json::Value) -> usize {
        marketplace["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|plugin| plugin["name"].as_str() == Some("agent-pet-companion"))
            .count()
    }
}
