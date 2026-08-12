use std::time::Duration;

pub(crate) const OPENCODE_PLUGIN_TEMPLATE: &str =
    include_str!("../../../../../plugins/opencode/agent-pet-companion.js.tpl");

pub(crate) const OPENCODE_NATIVE_PROBE_TIMEOUT: Duration = Duration::from_secs(10);

pub(crate) const OPENCODE_AUDITED_PLUGIN_HOOKS: &[&str] = &[
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

pub(crate) const OPENCODE_AUDITED_BUS_EVENTS: &[&str] = &[
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

pub(crate) const OPENCODE_TASK_START_EVENTS: &[&str] =
    &["message.user", "session.next.prompt.admitted"];

pub(crate) const OPENCODE_TASK_ACTIVITY_EVENTS: &[&str] =
    &["tool.execute.before", "command.execute.before"];

pub(crate) const OPENCODE_TASK_COMPLETION_EVENTS: &[&str] = &[
    "tool.execute.after",
    "command.execute.after",
    "message.assistant",
    "session.idle",
    "session.status",
    "session.error",
    "session.next.step.ended",
    "session.next.step.failed",
];

use super::*;

pub(super) fn opencode_managed_root_state(root: &Path) -> ManagedPathState {
    managed_script_root_state(root, AgentSource::Opencode)
}

pub(super) fn repair_opencode(root: &Path, cli_path: &Path) -> Result<()> {
    ensure_managed_script_root(root, AgentSource::Opencode)?;
    let script = render_connector_script(OPENCODE_PLUGIN_TEMPLATE, cli_path);
    write_owned_connector_script(
        &root.join("agent-pet-companion.js"),
        script.as_bytes(),
        AgentSource::Opencode,
    )?;
    Ok(())
}

pub(super) fn check_opencode_server(run_runtime_smoke: bool) -> ConnectionCheckItem {
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

pub(super) fn check_opencode_plugin_runtime(
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
                "OpenCode 宿主在 {} 秒内未完成 Plugin 发现；请修复宿主进程启动条件后重试",
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

pub(super) fn opencode_debug_reports_plugin(stdout: &[u8], plugin: &Path) -> bool {
    let stdout = String::from_utf8_lossy(stdout);
    let raw_path = plugin.display().to_string();
    let file_url = file_url_for_path(plugin);
    stdout.lines().any(|line| {
        let token = line.trim().strip_prefix("- ").unwrap_or(line.trim());
        token == raw_path || file_url.as_deref() == Some(token)
    })
}

pub(super) fn opencode_plugins_dir() -> PathBuf {
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

#[cfg(test)]
mod contract_tests {
    use super::*;

    #[test]
    fn opencode_adapter_contract_binds_cli_version_and_bounded_event_sets() {
        assert!(OPENCODE_PLUGIN_TEMPLATE.contains("__APC_CLI_JSON__"));
        assert!(OPENCODE_PLUGIN_TEMPLATE.contains("__APC_CONNECTOR_RELEASE_VERSION__"));
        assert!(OPENCODE_AUDITED_PLUGIN_HOOKS.contains(&"event"));
        assert!(OPENCODE_AUDITED_BUS_EVENTS.contains(&"session.status"));
        assert!(OPENCODE_AUDITED_BUS_EVENTS.len() < 128);
        assert!(OPENCODE_TASK_COMPLETION_EVENTS.contains(&"session.error"));
    }
}
