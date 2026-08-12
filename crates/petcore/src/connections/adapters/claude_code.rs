use std::time::Duration;

pub(crate) const CLAUDE_SETTINGS_TEMPLATE: &str =
    include_str!("../../../../../plugins/claude-code/settings.fragment.json.tpl");

pub(crate) const CLAUDE_NATIVE_PROBE_TIMEOUT: Duration = Duration::from_secs(12);

pub(crate) const CLAUDE_AUDITED_HOOK_EVENTS: &[&str] = &[
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

pub(crate) const CLAUDE_TASK_START_EVENTS: &[&str] = &["UserPromptSubmit"];

pub(crate) const CLAUDE_TASK_ACTIVITY_EVENTS: &[&str] = &["PreToolUse"];

pub(crate) const CLAUDE_TASK_COMPLETION_EVENTS: &[&str] = &[
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionDenied",
    "Stop",
    "StopFailure",
];

use super::*;

pub(super) fn claude_managed_root_state(root: &Path) -> ManagedPathState {
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

pub(super) fn repair_claude(root: &Path, cli_path: &Path) -> Result<()> {
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

pub(super) fn validate_claude_root_repair_ownership(
    root: &Path,
    connector_cli: &Path,
) -> Result<()> {
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
    // Only files under the connector root prove this App wrote the root itself;
    // the host settings file lives outside it.
    let root_owned_on_disk = claude_fragment_is_owned(&root.join("settings.fragment.json"), root)
        || claude_helper_is_owned(&root.join("agent-pet-companion-hook.sh"), root);
    let owned = root_owned_on_disk || settings_owned;
    if !owned && directory_has_entries(root)? {
        return Err(PetCoreError::Conflict(format!(
            "Claude connector 固定管理根已有无法识别为 Agent Pet Companion 的内容，拒绝覆盖：{}",
            root.display()
        )));
    }
    for path in [
        root.join("settings.fragment.json"),
        root.join("agent-pet-companion-hook.sh"),
    ] {
        match managed_regular_file_state(root, &path) {
            ManagedPathState::Missing => {}
            ManagedPathState::Safe if root_owned_on_disk => {}
            ManagedPathState::Safe => {
                return Err(PetCoreError::Conflict(format!(
                    "Claude connector 固定路径已有本 App 未写入的文件，拒绝覆盖：{}",
                    path.display()
                )));
            }
            ManagedPathState::Conflict => {
                return Err(PetCoreError::Conflict(format!(
                    "Claude connector 固定路径是符号链接、目录或不可检查项，拒绝覆盖：{}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

pub(super) fn rendered_claude_hook(connector_cli: &Path) -> String {
    let cli = shell_quote(&connector_cli.display().to_string());
    format!(
        "#!/bin/sh\nset -eu\nAPC_CONNECTOR_CONTRACT_VERSION={} {cli} agent hook --source claude_code --event-type auto >/dev/null 2>&1 || true\n",
        shell_quote(CLAUDE_HOOKS_CONTRACT_VERSION)
    )
}

pub(super) fn check_claude_fragment(
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
    let unrecognized_content = path_state == ManagedPathState::Safe
        && !configured
        && !claude_fragment_is_owned(path, install_root);
    // Only a path this App cannot safely write is a conflict. Unrecognized
    // content at this App's own fixed path is stale or edited, and repair
    // rewrites it once the root itself is proven to be this App's.
    let conflict = path_state == ManagedPathState::Conflict;
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
        } else if unrecognized_content {
            format!(
                "内容不是本 App 写入的版本，待替换为当前版本 {}",
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

pub(super) fn check_claude_hook(path: &Path, connector_cli: &Path) -> ConnectionCheckItem {
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
    let unrecognized_content = path_state == ManagedPathState::Safe
        && !configured
        && !claude_helper_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict;
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
        } else if unrecognized_content {
            format!(
                "内容不是本 App 写入的版本，待替换为当前版本 {}",
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

pub(super) fn rendered_claude_settings_fragment(
    _connector_cli: &Path,
    install_root: &Path,
) -> Result<Value> {
    let hook = shell_quote(
        &install_root
            .join("agent-pet-companion-hook.sh")
            .display()
            .to_string(),
    );
    let mut fragment = render_json_template(CLAUDE_SETTINGS_TEMPLATE, "__APC_HOOK__", &hook)?;
    replace_json_string(
        &mut fragment,
        CONNECTOR_RELEASE_VERSION_PLACEHOLDER,
        APP_MANAGED_CONNECTOR_RELEASE_VERSION,
    );
    Ok(fragment)
}

pub(super) fn remove_owned_claude_connector_files(root: &Path) -> Result<()> {
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

pub(super) fn check_claude_auth_status(run_runtime_smoke: bool) -> ConnectionCheckItem {
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

pub(super) fn check_claude_hooks_policy() -> ConnectionCheckItem {
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

pub(super) fn check_claude_hook_runtime(paths: &AppPaths, probe_cwd: &Path) -> ConnectionCheckItem {
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
                "Claude --init-only 在 {} 秒内未退出；请检查 /status、/hooks 与 policy",
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

pub(super) fn check_claude_settings(
    connector_cli: &Path,
    install_root: &Path,
) -> ConnectionCheckItem {
    let settings_path = claude_settings_path();
    let path_state = config_file_path_state(&settings_path);
    let expected = rendered_claude_settings_fragment(connector_cli, install_root).ok();
    let installed = path_state == ManagedPathState::Safe
        && read_regular_json_config(&settings_path)
            .zip(expected)
            .is_some_and(|(settings, expected)| {
                claude_settings_match_owned_fragment(
                    &settings,
                    &expected,
                    connector_cli,
                    install_root,
                )
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

pub(super) fn claude_settings_match_owned_fragment(
    settings: &Value,
    expected_fragment: &Value,
    connector_cli: &Path,
    install_root: &Path,
) -> bool {
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
            .filter(|group| value_contains_owned_claude_hook(group, connector_cli, install_root))
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
                    .filter(|group| {
                        value_contains_owned_claude_hook(group, connector_cli, install_root)
                    })
                    .count()
                    == 1
            })
    })
}

pub(super) fn value_contains_apparent_claude_connector(value: &Value) -> bool {
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

pub(super) fn claude_fragment_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && read_regular_json_config(path).is_some_and(|value| {
            value
                .get("contract_version")
                .and_then(Value::as_str)
                .is_some_and(|version| version.starts_with("claude-hooks-"))
                && value_contains_apparent_claude_connector(&value)
        })
}

pub(super) fn claude_helper_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("agent hook --source claude_code")
                && (content.contains("APC_CONNECTOR_CONTRACT_VERSION='claude-hooks-")
                    || content.contains("EVENT_TYPE=\"${APC_EVENT_TYPE:-tool}\""))
        })
}

pub(super) fn claude_settings_path() -> PathBuf {
    non_empty_env_path("CLAUDE_CONFIG_DIR")
        .unwrap_or_else(|| agent_home().join(".claude"))
        .join("settings.json")
}

#[cfg(test)]
pub(super) fn install_claude_settings(hook_entries: &[(&str, String)]) -> Result<()> {
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

pub(super) fn install_claude_settings_fragment(
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

pub(super) fn remove_claude_settings_hooks(
    install_root: &Path,
    connector_cli: &Path,
) -> Result<()> {
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

pub(super) fn is_agent_pet_claude_hook(
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

pub(super) fn value_contains_owned_claude_hook(
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

pub(super) fn is_agent_pet_claude_command(
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

pub(super) fn is_agent_pet_claude_arguments(arguments: &str) -> bool {
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
        "auto" | "start" | "thinking" | "plan" | "tool" | "waiting" | "done" | "failed"
    );
    known_event && matches!(suffix, "" | ">/dev/null 2>&1" | ">/dev/null 2>&1 || true")
}

#[cfg(test)]
mod contract_tests {
    use super::*;

    #[test]
    fn claude_adapter_contract_covers_every_authored_hook_once() {
        let template: Value = serde_json::from_str(CLAUDE_SETTINGS_TEMPLATE).unwrap();
        let hooks = template.get("hooks").and_then(Value::as_object).unwrap();
        let authored: std::collections::BTreeSet<_> =
            CLAUDE_AUDITED_HOOK_EVENTS.iter().copied().collect();
        let rendered: std::collections::BTreeSet<_> = hooks.keys().map(String::as_str).collect();
        assert_eq!(authored.len(), CLAUDE_AUDITED_HOOK_EVENTS.len());
        assert!(rendered.is_subset(&authored));
        assert!(rendered.contains("UserPromptSubmit"));
        assert!(rendered.contains("Stop"));
        assert!(CLAUDE_SETTINGS_TEMPLATE.contains("__APC_HOOK__"));
        assert!(CLAUDE_TASK_COMPLETION_EVENTS.contains(&"StopFailure"));
    }
}
