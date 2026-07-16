use crate::app_server;
use crate::db::Database;
use crate::paths::AppPaths;
use crate::process_runner::{run_bounded, ProcessResult, ProcessSpec};
use crate::{enum_name, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentSource, CheckStatus, ConnectionCheckItem, ConnectionCheckMode,
};
use serde_json::{json, Value};
use std::fs;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CodexHookTrustState {
    Trusted,
    Untrusted,
    InstalledEnabledAuthOnInstall,
    Unknown,
}

pub fn check_all(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    check_all_with_runtime_smoke(paths, true)
}

pub fn check_all_light(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    check_all_with_runtime_smoke(paths, false)
}

fn check_all_with_runtime_smoke(
    paths: &AppPaths,
    run_runtime_smoke: bool,
) -> Vec<AgentConnectionStatus> {
    let sources = [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ];
    thread::scope(|scope| {
        let checks = sources.map(|source| {
            scope.spawn(move || check_source_with_runtime_smoke(paths, source, run_runtime_smoke))
        });
        checks
            .into_iter()
            .map(|check| check.join().expect("connection check worker panicked"))
            .collect()
    })
}

pub fn check_source(paths: &AppPaths, source: AgentSource) -> AgentConnectionStatus {
    check_source_with_runtime_smoke(paths, source, true)
}

fn check_source_with_runtime_smoke(
    paths: &AppPaths,
    source: AgentSource,
    run_runtime_smoke: bool,
) -> AgentConnectionStatus {
    let cli_name = cli_name(source);
    let install_root = install_root(paths, source);
    let connector_cli = connector_cli_path(paths);
    let agent_cli = if source == AgentSource::Codex {
        codex_command_path()
    } else {
        command_path(cli_name)
    };
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
        ConnectionCheckItem {
            name: cli_label(source).to_string(),
            status: cli_status,
            detail: if let Some(path) = agent_cli {
                format!("命令可用：{}", path.display())
            } else {
                format!("未在 PATH 与常用本地安装目录中检测到 {cli_name}")
            },
        },
        ConnectionCheckItem {
            name: "本地事件 CLI".to_string(),
            status: connector_cli_status,
            detail: if connector_cli_status == CheckStatus::Ok {
                connector_cli.display().to_string()
            } else {
                format!("未检测到 {}", connector_cli.display())
            },
        },
    ];

    match source {
        AgentSource::Codex => {
            items.push(check_file(
                &install_root.join(".codex-plugin/plugin.json"),
                "插件源",
            ));
            items.push(check_codex_hooks(&install_root.join("hooks/hooks.json")));
            items.push(check_file_contains(
                &install_root.join("skills/agent-pet-studio/SKILL.md"),
                "Pet Studio Skill",
                &[
                    "Generate Agent Pet Companion .petpack assets",
                    "APC_PETCORE_CLI",
                    "Do not read agent auth",
                ],
            ));
            items.push(check_codex_agent_pet_maker(&install_root));
            items.push(check_codex_marketplace_entry());
            items.push(if run_runtime_smoke {
                check_codex_plugin_installed()
            } else {
                check_codex_plugin_installed_light(&install_root)
            });
            items.push(if run_runtime_smoke {
                check_codex_hook_trust()
            } else {
                check_codex_hook_trust_light(&install_root)
            });
            items.push(check_event_channel(paths, &connector_cli));
            items.push(if run_runtime_smoke {
                check_codex_app_server()
            } else {
                check_codex_app_server_light()
            });
        }
        AgentSource::ClaudeCode => {
            items.push(check_file(
                &install_root.join("settings.fragment.json"),
                "Hooks",
            ));
            items.push(check_file(
                &install_root.join("agent-pet-companion-hook.sh"),
                "事件通道",
            ));
            items.push(check_claude_settings(&connector_cli));
            items.push(check_event_channel(paths, &connector_cli));
        }
        AgentSource::Pi => {
            items.push(check_file_contains(
                &install_root.join("agent-pet-companion.ts"),
                "Extension",
                &[
                    "pi-extension-20260714-message-v5",
                    "pi.on(\"input\"",
                    "pi.on(\"agent_settled\"",
                    "pi.on(\"message_end\"",
                    "pi.on(\"agent_end\"",
                    "pi.on(\"session_before_compact\"",
                    "pi.on(\"session_compact\"",
                    "event?.isError === true",
                    "diagnostic: event?.diagnostic === true",
                    "session_title: sessionTitle(ctx)",
                    "message_content: message?.content",
                    "agent_error: agentError",
                    "session_open: event?.type !== \"session_shutdown\"",
                    "--event-type",
                    "auto",
                ],
            ));
            items.push(check_event_channel(paths, &connector_cli));
            if run_runtime_smoke {
                items.push(check_pi_extension_runtime(paths, &install_root));
            }
        }
        AgentSource::Opencode => {
            items.push(check_file_contains(
                &install_root.join("agent-pet-companion.js"),
                "Plugin",
                &[
                    "export const AgentPetCompanion",
                    "event: async",
                    "opencode-v1.17.18-activity-v4",
                    "\"tool.execute.before\"",
                    "event?.properties",
                    "\"chat.message\"",
                    "message.assistant",
                    "session_title: sessions.get",
                    "output?.args",
                    "diagnostic: properties?.diagnostic",
                    "diagnostic: input?.diagnostic",
                    "--event-type",
                    "auto",
                ],
            ));
            items.push(check_opencode_server(run_runtime_smoke));
            items.push(check_event_channel(paths, &connector_cli));
            if run_runtime_smoke {
                items.push(check_opencode_plugin_runtime(paths, &install_root));
            }
        }
    };
    if run_runtime_smoke {
        items.push(check_event_roundtrip(paths, &connector_cli, source));
    }

    let mut install_paths = vec![install_root.display().to_string()];
    match source {
        AgentSource::Codex => {
            install_paths.push(codex_marketplace_path().display().to_string());
        }
        AgentSource::ClaudeCode => {
            install_paths.push(claude_settings_path().display().to_string());
        }
        AgentSource::Pi | AgentSource::Opencode => {}
    }

    AgentConnectionStatus {
        source,
        items,
        install_paths,
        connector_installed: connector_artifacts_present(paths, source),
        check_mode: if run_runtime_smoke {
            ConnectionCheckMode::Runtime
        } else {
            ConnectionCheckMode::Light
        },
        checked_at: now_rfc3339(),
    }
}

pub fn repair_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    if source != AgentSource::Codex {
        fs::create_dir_all(&root)?;
    }
    let cli_path = connector_cli_path(paths);
    match source {
        AgentSource::Codex => repair_codex(&root, &cli_path)?,
        AgentSource::ClaudeCode => repair_claude(&root, &cli_path)?,
        AgentSource::Pi => repair_pi(&root, &cli_path)?,
        AgentSource::Opencode => repair_opencode(&root, &cli_path)?,
    }
    Ok(check_source(paths, source))
}

pub fn refresh_installed_source(paths: &AppPaths, source: AgentSource) -> Result<bool> {
    if !connector_artifacts_present(paths, source) {
        return Ok(false);
    }
    let root = install_root(paths, source);
    if source != AgentSource::Codex {
        fs::create_dir_all(&root)?;
    }
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
            remove_if_exists(&root.join("agent-pet-companion.ts"))?;
            remove_if_exists(&root.join("rpc-check.json"))?;
        }
        AgentSource::Opencode => {
            remove_if_exists(&root.join("agent-pet-companion.js"))?;
            remove_if_exists(&root.join("server-check.json"))?;
        }
        AgentSource::Codex | AgentSource::ClaudeCode => {
            if root.exists() {
                fs::remove_dir_all(&root)?;
            }
            if source == AgentSource::Codex {
                remove_codex_marketplace_entry()?;
                uninstall_codex_plugin_if_possible();
            } else {
                remove_claude_settings_hooks(&root, &connector_cli_path(paths))?;
            }
        }
    }
    Ok(check_source(paths, source))
}

fn repair_codex(root: &Path, cli_path: &Path) -> Result<()> {
    write_codex_connector(root, cli_path)?;
    ensure_codex_marketplace_entry()?;
    install_codex_plugin_if_possible(root)?;
    Ok(())
}

fn write_codex_connector(root: &Path, cli_path: &Path) -> Result<()> {
    ensure_codex_plugin_root(root)?;
    let plugin_dir = root.join(".codex-plugin");
    let hooks_dir = root.join("hooks");
    let skills_dir = root.join("skills");
    let studio_skill_dir = skills_dir.join("agent-pet-studio");
    for path in [&plugin_dir, &hooks_dir, &skills_dir, &studio_skill_dir] {
        ensure_managed_directory(path)?;
    }
    let cli = shell_quote(&cli_path.display().to_string());
    let plugin: Value = serde_json::from_str(CODEX_PLUGIN_JSON)?;
    let hooks = render_json_template(CODEX_HOOKS_TEMPLATE, "__APC_CLI__", &cli)?;
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
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err(PetCoreError::Validation(format!(
                "拒绝通过符号链接写入 Codex plugin 管理目录：{}",
                path.display()
            )))
        }
        Ok(metadata) if metadata.is_dir() => Ok(()),
        Ok(_) => Err(PetCoreError::Validation(format!(
            "Codex plugin 管理目录路径不是目录：{}",
            path.display()
        ))),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let parent = path.parent().ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "Codex plugin 管理目录缺少父目录：{}",
                    path.display()
                ))
            })?;
            let parent_metadata = fs::symlink_metadata(parent)?;
            if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
                return Err(PetCoreError::Validation(format!(
                    "拒绝通过非目录或符号链接父路径创建 Codex plugin 管理目录：{}",
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
    fs::create_dir_all(root)?;
    let cli = shell_quote(&cli_path.display().to_string());
    let fragment = render_json_template(CLAUDE_SETTINGS_TEMPLATE, "__APC_CLI__", &cli)?;
    fs::write(
        root.join("settings.fragment.json"),
        serde_json::to_vec_pretty(&fragment)?,
    )?;
    let hook_path = root.join("agent-pet-companion-hook.sh");
    fs::write(
        &hook_path,
        format!(
            "#!/usr/bin/env bash\nset -euo pipefail\nEVENT_TYPE=\"${{APC_EVENT_TYPE:-tool}}\"\n{cli} agent hook --source claude_code --event-type \"$EVENT_TYPE\" >/dev/null 2>&1\n"
        ),
    )?;
    fs::set_permissions(&hook_path, fs::Permissions::from_mode(0o755))?;
    install_claude_settings_fragment(&fragment, root, cli_path)?;
    Ok(())
}

fn repair_pi(root: &Path, cli_path: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    let cli = cli_path.display().to_string();
    let cli_json = serde_json::to_string(&cli)?;
    let script = PI_EXTENSION_TEMPLATE.replace("__APC_CLI_JSON__", &cli_json);
    fs::write(root.join("agent-pet-companion.ts"), script)?;
    Ok(())
}

fn repair_opencode(root: &Path, cli_path: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    let cli = cli_path.display().to_string();
    let cli_json = serde_json::to_string(&cli)?;
    let script = OPENCODE_PLUGIN_TEMPLATE.replace("__APC_CLI_JSON__", &cli_json);
    fs::write(root.join("agent-pet-companion.js"), script)?;
    Ok(())
}

fn check_file(path: &Path, label: &str) -> ConnectionCheckItem {
    ConnectionCheckItem {
        name: label.to_string(),
        status: if path.exists() {
            CheckStatus::Ok
        } else {
            CheckStatus::Missing
        },
        detail: if path.exists() {
            "已安装".to_string()
        } else {
            format!("待写入 {}", path.display())
        },
    }
}

fn check_codex_hooks(path: &Path) -> ConnectionCheckItem {
    const REQUIRED: &[&str] = &[
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
    const OFFICIAL: &[&str] = &[
        "SessionStart",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PreCompact",
        "PostCompact",
        "UserPromptSubmit",
        "SubagentStart",
        "SubagentStop",
        "Stop",
    ];
    let configured = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .and_then(|value| value.get("hooks").and_then(Value::as_object).cloned())
        .is_some_and(|hooks| {
            REQUIRED.iter().all(|event| {
                hooks
                    .get(*event)
                    .is_some_and(|value| value_contains_command_marker(value, "--source codex"))
            }) && hooks.keys().all(|event| OFFICIAL.contains(&event.as_str()))
                && !hooks
                    .values()
                    .any(|value| value_contains_command_marker(value, "--event-type review"))
        });
    ConnectionCheckItem {
        name: "Hook".to_string(),
        status: if configured {
            CheckStatus::Ok
        } else if path.exists() {
            CheckStatus::NeedsFix
        } else {
            CheckStatus::Missing
        },
        detail: if configured {
            "configured: 仅安装当前官方 Codex hook 事件；review/failed 不由 hooks 宣称".to_string()
        } else {
            format!("待写入或升级 {}", path.display())
        },
    }
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

fn value_contains_command_marker(value: &Value, marker: &str) -> bool {
    match value {
        Value::Object(map) => {
            map.get("command")
                .and_then(Value::as_str)
                .is_some_and(|command| command.contains(marker))
                || map
                    .values()
                    .any(|value| value_contains_command_marker(value, marker))
        }
        Value::Array(values) => values
            .iter()
            .any(|value| value_contains_command_marker(value, marker)),
        _ => false,
    }
}

fn check_file_contains(path: &Path, label: &str, required: &[&str]) -> ConnectionCheckItem {
    let content = fs::read_to_string(path).unwrap_or_default();
    let installed = path.exists() && required.iter().all(|needle| content.contains(needle));
    ConnectionCheckItem {
        name: label.to_string(),
        status: if installed {
            CheckStatus::Ok
        } else if path.exists() {
            CheckStatus::NeedsFix
        } else {
            CheckStatus::Missing
        },
        detail: if installed {
            "已安装".to_string()
        } else if path.exists() {
            format!("已安装旧版本，待更新 {}", path.display())
        } else {
            format!("待写入 {}", path.display())
        },
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
    ConnectionCheckItem {
        name: "Agent Pet Maker Skill".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else if skill_root.exists() {
            CheckStatus::NeedsFix
        } else {
            CheckStatus::Missing
        },
        detail: if installed {
            format!(
                "configured: Codex plugin 可原生发现完整 agent-pet-maker（{} 个文件）",
                AGENT_PET_MAKER_FILES.len()
            )
        } else if skill_root.exists() {
            let mut reasons = missing_or_outdated;
            if !helper_is_executable {
                reasons.push("scripts/petpack_workspace.py（不可执行）".to_string());
            }
            format!("已安装不完整或旧版本，待更新：{}", reasons.join("、"))
        } else {
            format!("待写入 {}", skill_root.display())
        },
    }
}

fn check_opencode_server(run_runtime_smoke: bool) -> ConnectionCheckItem {
    let opted_in = std::env::var("APC_VALIDATE_REAL_OPENCODE_SERVER")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false);
    if !run_runtime_smoke || !opted_in {
        return ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::NotRequired,
            detail: "configured: Server 非 V1 事件观察必需；未宣称健康。设置 APC_VALIDATE_REAL_OPENCODE_SERVER=1 后执行 /global/health 真实探测"
                .to_string(),
        };
    }

    probe_opencode_server()
}

pub fn probe_opencode_server() -> ConnectionCheckItem {
    let Some(opencode) = command_path("opencode") else {
        return ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::Missing,
            detail: "未在 PATH 中检测到 opencode".to_string(),
        };
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
            ConnectionCheckItem {
                name: "OpenCode Server".to_string(),
                status: if healthy {
                    CheckStatus::Ok
                } else {
                    CheckStatus::NeedsFix
                },
                detail: if healthy {
                    "runtime_verified: bounded opencode serve 返回有效 /global/health JSON"
                        .to_string()
                } else {
                    "OpenCode /global/health 响应不是 {healthy:true} JSON".to_string()
                },
            }
        }
        Ok(output) => ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::NeedsFix,
            detail: if output.timed_out {
                "OpenCode /global/health 真实探测在 5 秒后超时，进程组已终止".to_string()
            } else {
                format!(
                    "OpenCode /global/health 探测失败（exit={:?}）",
                    output.status.code()
                )
            },
        },
        Err(error) => ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("OpenCode CLI 无法执行：{error}"),
        },
    }
}

fn check_pi_extension_runtime(paths: &AppPaths, install_root: &Path) -> ConnectionCheckItem {
    let label = "Extension 运行时";
    if !connector_runtime_smoke_should_run() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::Unverified,
            detail: "检测到外部事件 CLI 覆盖，跳过内置运行时加载自检".to_string(),
        };
    }

    let Some(node) = command_path("node") else {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: "未检测到 node，无法加载 Pi extension 做运行时自检".to_string(),
        };
    };

    let extension = install_root.join("agent-pet-companion.ts");
    if !extension.is_file() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("Extension 缺失 {}", extension.display()),
        };
    }

    let smoke_module = install_root.join(format!(
        ".agent-pet-companion-runtime-{}.mjs",
        uuid::Uuid::now_v7().simple()
    ));
    if let Err(error) = fs::copy(&extension, &smoke_module) {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("无法准备 Extension 运行时自检模块：{error}"),
        };
    }

    let session_id = format!("evt_pi_runtime_{}", uuid::Uuid::now_v7().simple());
    let module_path = json_string(&smoke_module.display().to_string());
    let session_json = json_string(&session_id);
    let response = format!("Agent Pet Companion runtime response {session_id}");
    let response_json = json_string(&response);
    let script = format!(
        r#"
import {{ pathToFileURL }} from 'node:url';
const mod = await import(pathToFileURL({module_path}).href);
const handlers = new Map();
mod.default({{ on: (name, callback) => handlers.set(name, callback) }});
for (const name of ['input', 'before_agent_start', 'message_end', 'agent_end', 'tool_call', 'tool_execution_end', 'agent_settled', 'session_before_compact', 'session_compact']) {{
  if (!handlers.has(name)) throw new Error(`Pi handler missing: ${{name}}`);
}}
const context = {{ sessionManager: {{ getSessionId: () => {session_json} }}, cwd: process.cwd() }};
await handlers.get('input')(
  {{ type: 'input', text: 'Agent Pet Companion runtime check', source: 'interactive', diagnostic: true }},
  context
);
await handlers.get('before_agent_start')(
  {{ type: 'before_agent_start', prompt: 'Agent Pet Companion runtime check', diagnostic: true }},
  context
);
await handlers.get('message_end')(
  {{ type: 'message_end', message: {{ role: 'assistant', content: [{{ type: 'text', text: {response_json} }}], stopReason: 'stop' }}, diagnostic: true }},
  context
);
await handlers.get('agent_end')(
  {{ type: 'agent_end', messages: [{{ role: 'assistant', content: [{{ type: 'text', text: {response_json} }}], stopReason: 'stop' }}], diagnostic: true }},
  context
);
await handlers.get('agent_settled')(
  {{ type: 'agent_settled', diagnostic: true }},
  context
);
"#
    );
    let output = run_bounded(
        ProcessSpec::connector(
            node,
            vec![
                "--input-type=module".to_string(),
                "--eval".to_string(),
                script,
            ],
        )
        .with_env("APC_HOME", &paths.home),
    );
    let _ = fs::remove_file(&smoke_module);
    node_runtime_result(label, output, || {
        recent_events_contain(paths, "pi", "done", &response)
    })
}

fn check_opencode_plugin_runtime(paths: &AppPaths, install_root: &Path) -> ConnectionCheckItem {
    let label = "Plugin 运行时";
    if !connector_runtime_smoke_should_run() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::Unverified,
            detail: "检测到外部事件 CLI 覆盖，跳过内置运行时加载自检".to_string(),
        };
    }

    let Some(node) = command_path("node") else {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: "未检测到 node，无法加载 OpenCode plugin 做运行时自检".to_string(),
        };
    };

    let plugin = install_root.join("agent-pet-companion.js");
    if !plugin.is_file() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("Plugin 缺失 {}", plugin.display()),
        };
    }

    let session_id = format!("evt_opencode_runtime_{}", uuid::Uuid::now_v7().simple());
    let module_path = json_string(&plugin.display().to_string());
    let session_json = json_string(&session_id);
    let root_json = json_string(&install_root.display().to_string());
    let prompt = format!("Agent Pet Companion runtime prompt {session_id}");
    let prompt_json = json_string(&prompt);
    let response = format!("Agent Pet Companion runtime response {session_id}");
    let response_json = json_string(&response);
    let script = format!(
        r#"
import {{ pathToFileURL }} from 'node:url';
const mod = await import(pathToFileURL({module_path}).href);
const plugin = await mod.AgentPetCompanion({{
  project: 'agent-pet-companion',
  directory: {root_json},
  worktree: {root_json}
}});
for (const name of ['event', 'chat.message', 'tool.execute.before', 'tool.execute.after']) {{
  if (!plugin[name]) throw new Error(`OpenCode handler missing: ${{name}}`);
}}
await plugin.event({{
    event: {{
    type: 'session.created',
    properties: {{ info: {{ id: {session_json}, diagnostic: true }} }}
  }}
}});
await plugin['chat.message'](
  {{ sessionID: {session_json}, diagnostic: true }},
  {{ parts: [{{ type: 'text', text: {prompt_json} }}] }}
);
// Deliberately deliver completion metadata before the final text part. This is
// the ordering that previously lost OpenCode assistant replies.
await plugin.event({{
  event: {{
    type: 'message.updated',
    properties: {{ info: {{ id: 'runtime-message', sessionID: {session_json}, role: 'assistant', time: {{ created: 1, completed: 2 }}, diagnostic: true }} }}
  }}
}});
await plugin.event({{
  event: {{
    type: 'message.part.updated',
    properties: {{ diagnostic: true, part: {{ id: 'runtime-part', messageID: 'runtime-message', sessionID: {session_json}, type: 'text', text: {response_json} }} }}
  }}
}});
await plugin.event({{
  event: {{ type: 'session.idle', properties: {{ sessionID: {session_json}, diagnostic: true }} }}
}});
await new Promise((resolve) => setTimeout(resolve, 700));
"#
    );
    let output = run_bounded(
        ProcessSpec::connector(
            node,
            vec![
                "--input-type=module".to_string(),
                "--eval".to_string(),
                script,
            ],
        )
        .with_env("APC_HOME", &paths.home),
    );
    node_runtime_result(label, output, || {
        recent_events_contain(paths, "opencode", "start", &prompt)
            && recent_events_contain(paths, "opencode", "start", &response)
            && recent_events_contain(paths, "opencode", "done", &session_id)
    })
}

fn node_runtime_result(
    label: &str,
    output: Result<ProcessResult>,
    event_check: impl FnOnce() -> bool,
) -> ConnectionCheckItem {
    match output {
        Ok(output) if output.status.success() && !output.timed_out => {
            thread::sleep(Duration::from_millis(250));
            let event_seen = event_check();
            ConnectionCheckItem {
                name: label.to_string(),
                status: if event_seen {
                    CheckStatus::Ok
                } else {
                    CheckStatus::NeedsFix
                },
                detail: if event_seen {
                    "运行时模块已加载，并通过真实插件/Extension handler 回传诊断事件".to_string()
                } else {
                    "运行时模块已加载，但未观察到诊断事件入库".to_string()
                },
            }
        }
        Ok(output) => ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: if output.timed_out {
                "运行时模块自检在 5 秒后超时，进程组已终止".to_string()
            } else {
                format!("运行时模块加载失败（exit={:?}）", output.status.code())
            },
        },
        Err(error) => ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("无法启动 node 运行时自检：{error}"),
        },
    }
}

fn recent_events_contain(paths: &AppPaths, source: &str, event_type: &str, needle: &str) -> bool {
    let database = Database::new(&paths.db_path);
    for _ in 0..16 {
        if database.recent_events(120).is_ok_and(|events| {
            events.iter().any(|event| {
                source_cli_arg(event.source) == source
                    && enum_name(event.event_type) == event_type
                    && serde_json::to_string(event)
                        .map(|text| text.contains(needle))
                        .unwrap_or(false)
            })
        }) {
            return true;
        }
        thread::sleep(Duration::from_millis(150));
    }
    false
}

fn connector_runtime_smoke_should_run() -> bool {
    std::env::var_os("APC_CONNECTOR_CLI_PATH").is_none()
        || std::env::var("APC_CONNECTOR_RUNTIME_SMOKE")
            .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
            .unwrap_or(false)
}

fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
}

fn check_codex_marketplace_entry() -> ConnectionCheckItem {
    let path = codex_marketplace_path();
    let expected_path = codex_marketplace_plugin_source_path();
    let entry_path = codex_marketplace_entry_path(&path);
    let installed = entry_path.as_deref() == Some(expected_path.as_str());
    let detail = if installed {
        format!("已注册 {}", path.display())
    } else if let Some(entry_path) = entry_path {
        format!(
            "路径已变化，待更新 {}（当前：{}，期望：{}）",
            path.display(),
            entry_path,
            expected_path
        )
    } else {
        format!("待注册 {}", path.display())
    };

    ConnectionCheckItem {
        name: "Codex marketplace".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail,
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

fn check_codex_hook_trust() -> ConnectionCheckItem {
    let Some(codex) = codex_command_path() else {
        return ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Missing,
            detail: "未检测到 codex 命令".to_string(),
        };
    };

    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Unverified,
            detail: "测试环境无法确认用户是否已信任 Codex plugin hooks".to_string(),
        };
    }

    let trust = run_bounded(ProcessSpec::connector(codex, ["plugin", "list", "--json"]))
        .ok()
        .filter(|output| !output.timed_out && output.status.success())
        .and_then(|output| codex_plugin_json_hook_trust_state(&output.stdout));

    match trust {
        Some(CodexHookTrustState::Trusted) => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Ok,
            detail: "Codex 已信任 agent-pet-companion hooks".to_string(),
        },
        Some(CodexHookTrustState::InstalledEnabledAuthOnInstall) => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Unverified,
            detail:
                "插件已安装启用，但 ON_INSTALL 不证明 hooks 已获用户信任；实时工具切换依赖 hooks，请在 ChatGPT Codex 中确认"
                    .to_string(),
        },
        Some(CodexHookTrustState::Untrusted) => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "请在 Codex 中 review 并信任 agent-pet-companion hooks；否则只能使用有损近期任务快照"
                .to_string(),
        },
        Some(CodexHookTrustState::Unknown) | None => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Unverified,
            detail: "Codex 未暴露 Hook trust 状态；实时 Shell/读取/搜索切换需在 Codex 中确认并信任插件 hooks"
                .to_string(),
        },
    }
}

fn check_codex_hook_trust_light(install_root: &Path) -> ConnectionCheckItem {
    let hooks_ready = install_root.join("hooks/hooks.json").is_file();
    ConnectionCheckItem {
        name: "Codex Hook Trust".to_string(),
        status: CheckStatus::Unverified,
        detail: if hooks_ready {
            "本地 hooks 已写入；点击检查并在 Codex 中信任后才可精确同步实时工具活动".to_string()
        } else {
            "待写入 hooks 并在 Codex 中信任".to_string()
        },
    }
}

fn check_codex_plugin_installed() -> ConnectionCheckItem {
    let Some(codex) = codex_command_path() else {
        return ConnectionCheckItem {
            name: "Codex 插件安装".to_string(),
            status: CheckStatus::Missing,
            detail: "未检测到 codex 命令".to_string(),
        };
    };

    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem {
            name: "Codex 插件安装".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "测试环境跳过 codex plugin add".to_string(),
        };
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

    ConnectionCheckItem {
        name: "Codex 插件安装".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if installed {
            "Codex 已安装并启用插件".to_string()
        } else {
            "待执行 codex plugin add agent-pet-companion@personal".to_string()
        },
    }
}

fn check_codex_plugin_installed_light(install_root: &Path) -> ConnectionCheckItem {
    let plugin_source_ready = install_root.join(".codex-plugin/plugin.json").is_file()
        && install_root.join("hooks/hooks.json").is_file();
    let marketplace_ready = codex_marketplace_entry_path(&codex_marketplace_path()).as_deref()
        == Some(codex_marketplace_plugin_source_path().as_str());

    let ready = plugin_source_ready && marketplace_ready;
    ConnectionCheckItem {
        name: "Codex 插件安装".to_string(),
        status: if ready {
            CheckStatus::Unverified
        } else {
            CheckStatus::NeedsFix
        },
        detail: if ready {
            "本地插件源已注册，点击检查确认 Codex 已启用插件".to_string()
        } else {
            "待注册本地插件源或执行一键修复".to_string()
        },
    }
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

    ConnectionCheckItem {
        name: "Codex App Server".to_string(),
        status,
        detail,
    }
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

    ConnectionCheckItem {
        name: "Codex App Server".to_string(),
        status,
        detail,
    }
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

fn codex_plugin_json_hook_trust_state(stdout: &[u8]) -> Option<CodexHookTrustState> {
    let value: Value = serde_json::from_slice(stdout).ok()?;
    let installed = value.get("installed")?.as_array()?;
    let plugin = installed
        .iter()
        .find(|plugin| codex_plugin_entry_is_agent_pet(plugin))?;
    if let Some(trusted) = codex_plugin_trust_value(plugin) {
        return Some(if trusted {
            CodexHookTrustState::Trusted
        } else {
            CodexHookTrustState::Untrusted
        });
    }

    let installed = plugin
        .get("installed")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let enabled = plugin
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let auth_on_install = plugin.get("authPolicy").and_then(Value::as_str) == Some("ON_INSTALL");

    Some(if installed && enabled && auth_on_install {
        CodexHookTrustState::InstalledEnabledAuthOnInstall
    } else {
        CodexHookTrustState::Unknown
    })
}

fn codex_plugin_entry_is_agent_pet(plugin: &Value) -> bool {
    let id_matches =
        plugin.get("pluginId").and_then(Value::as_str) == Some("agent-pet-companion@personal");
    let name_matches = plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion")
        && plugin.get("marketplaceName").and_then(Value::as_str) == Some("personal");
    id_matches || name_matches
}

fn codex_plugin_trust_value(plugin: &Value) -> Option<bool> {
    const TRUST_KEYS: &[&str] = &[
        "trusted",
        "trust",
        "approved",
        "approvedByUser",
        "userApproved",
        "hooksTrusted",
        "hooks_trusted",
        "hooksApproved",
        "hooks_approved",
    ];
    find_bool_by_keys(plugin, TRUST_KEYS)
}

fn find_bool_by_keys(value: &Value, keys: &[&str]) -> Option<bool> {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if keys.contains(&key.as_str()) {
                    if let Some(value) = child.as_bool() {
                        return Some(value);
                    }
                }
            }
            map.values()
                .find_map(|child| find_bool_by_keys(child, keys))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|child| find_bool_by_keys(child, keys)),
        _ => None,
    }
}

fn codex_plugin_text_reports_installed(stdout: &str) -> bool {
    stdout.lines().any(|line| {
        line.contains("agent-pet-companion@personal")
            && line.contains("installed")
            && line.contains("enabled")
    })
}

fn check_claude_settings(connector_cli: &Path) -> ConnectionCheckItem {
    let settings_path = claude_settings_path();
    let required = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostToolUseFailure",
        "PostToolBatch",
        "PermissionDenied",
        "PreCompact",
        "PostCompact",
        "SubagentStart",
        "SubagentStop",
        "TaskCreated",
        "TaskCompleted",
        "Notification",
        "Elicitation",
        "ElicitationResult",
        "Stop",
        "StopFailure",
        "SessionEnd",
    ];
    let installed = fs::read_to_string(&settings_path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .and_then(|settings| settings.get("hooks").and_then(Value::as_object).cloned())
        .is_some_and(|hooks| {
            required.iter().all(|event| {
                hooks
                    .get(*event)
                    .is_some_and(|value| claude_event_has_bounded_async_hook(value, connector_cli))
            })
        });
    ConnectionCheckItem {
        name: "Claude settings.json".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if installed {
            format!(
                "configured: 已结构化合并 quiet/async/5s hooks 到 {}（真实触发需运行时验证）",
                settings_path.display()
            )
        } else {
            format!(
                "待合并或升级 {}（事件 CLI：{}）",
                settings_path.display(),
                connector_cli.display()
            )
        },
    }
}

fn claude_event_has_bounded_async_hook(value: &Value, connector_cli: &Path) -> bool {
    value.as_array().is_some_and(|groups| {
        groups.iter().any(|group| {
            group
                .get("hooks")
                .and_then(Value::as_array)
                .is_some_and(|hooks| {
                    hooks.iter().any(|hook| {
                        is_agent_pet_claude_hook(hook, connector_cli, None)
                            && hook.get("async").and_then(Value::as_bool) == Some(true)
                            && hook
                                .get("timeout")
                                .and_then(Value::as_u64)
                                .is_some_and(|timeout| timeout <= 5)
                    })
                })
        })
    })
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

    ConnectionCheckItem {
        name: "事件回传".to_string(),
        status,
        detail,
    }
}

fn check_event_roundtrip(
    paths: &AppPaths,
    connector_cli: &Path,
    source: AgentSource,
) -> ConnectionCheckItem {
    if std::env::var_os("APC_CONNECTOR_CLI_PATH").is_some() {
        return ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::Unverified,
            detail: "检测到外部覆盖的事件 CLI，跳过自动写入自检".to_string(),
        };
    }

    if !connector_cli.is_file() {
        return ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("事件 CLI 缺失 {}", connector_cli.display()),
        };
    }

    if !paths.socket_path.exists() || UnixStream::connect(&paths.socket_path).is_err() {
        return ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("PetCore socket 未连接 {}", paths.socket_path.display()),
        };
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
            return ConnectionCheckItem {
                name: "PetCore 通道自检".to_string(),
                status: CheckStatus::NeedsFix,
                detail: format!("事件 CLI 无法执行：{error}"),
            };
        }
    };

    if output.timed_out {
        return ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "事件 CLI 自检在 5 秒后超时，进程组已终止".to_string(),
        };
    }
    if !output.status.success() {
        return ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("事件 CLI 返回失败（exit={:?}）", output.status.code()),
        };
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed = serde_json::from_str::<Value>(&stdout);
    let Ok(value) = parsed else {
        return ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "事件 CLI 返回了不可解析的 JSON".to_string(),
        };
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
        ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::Ok,
            detail: if inserted {
                "本地诊断事件已通过 CLI、socket 与数据库，且未触发桌宠动作；此项不代表 Agent Hook 已触发".to_string()
            } else {
                "本地诊断事件已通过 CLI 与 socket；重复自检未重复入库，且未触发桌宠动作；此项不代表 Agent Hook 已触发".to_string()
            },
        }
    } else {
        ConnectionCheckItem {
            name: "PetCore 通道自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "诊断事件未完成端到端回传".to_string(),
        }
    }
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
    command_search_dirs()
        .into_iter()
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

fn codex_command_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("APC_CODEX_CLI_PATH").map(PathBuf::from) {
        if path.is_file() {
            return Some(path);
        }
    }
    // Tests and alternate config homes must remain hermetic instead of
    // discovering the developer machine's installed desktop application.
    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return command_path("codex");
    }
    [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|candidate| candidate.is_file())
    .or_else(|| command_path("codex"))
}

fn command_search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();

    let mut add = |path: PathBuf| {
        if !dirs.iter().any(|existing| existing == &path) {
            dirs.push(path);
        }
    };

    add(PathBuf::from("/opt/homebrew/bin"));
    add(PathBuf::from("/opt/homebrew/sbin"));
    add(PathBuf::from("/usr/local/bin"));
    add(PathBuf::from("/usr/local/sbin"));
    add(PathBuf::from("/usr/bin"));
    add(PathBuf::from("/bin"));
    add(PathBuf::from("/usr/sbin"));
    add(PathBuf::from("/sbin"));

    let home = user_home();
    add(home.join(".local").join("bin"));
    add(home.join(".cargo").join("bin"));
    add(home.join(".bun").join("bin"));
    add(home.join("bin"));
    dirs
}

fn install_root(paths: &AppPaths, source: AgentSource) -> PathBuf {
    match source {
        AgentSource::Codex => codex_plugin_source_root(),
        AgentSource::ClaudeCode => paths.connectors_dir.join("claude-code"),
        AgentSource::Pi => agent_home().join(".pi").join("agent").join("extensions"),
        AgentSource::Opencode => opencode_plugins_dir(),
    }
}

fn connector_artifacts_present(paths: &AppPaths, source: AgentSource) -> bool {
    let root = install_root(paths, source);
    match source {
        AgentSource::Codex => {
            root.join(".codex-plugin/plugin.json").is_file()
                || root.join("hooks/hooks.json").is_file()
                || root.join("skills/agent-pet-studio/SKILL.md").is_file()
                || codex_marketplace_entry_path(&codex_marketplace_path()).is_some()
        }
        AgentSource::ClaudeCode => {
            root.join("settings.fragment.json").is_file()
                || root.join("agent-pet-companion-hook.sh").is_file()
                || fs::read_to_string(claude_settings_path())
                    .map(|content| content.contains("agent hook --source claude_code"))
                    .unwrap_or(false)
        }
        AgentSource::Pi => root.join("agent-pet-companion.ts").is_file(),
        AgentSource::Opencode => root.join("agent-pet-companion.js").is_file(),
    }
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
    if let Some(path) = std::env::var_os("APC_CONNECTOR_CLI_PATH").map(PathBuf::from) {
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
    std::env::var_os("APC_AGENT_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(user_home)
}

fn opencode_plugins_dir() -> PathBuf {
    if let Some(fake_home) = std::env::var_os("APC_AGENT_CONFIG_HOME").map(PathBuf::from) {
        return fake_home.join(".config").join("opencode").join("plugins");
    }
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
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
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
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
    let source_path = codex_marketplace_plugin_source_path();
    let entry = json!({
        "name": "agent-pet-companion",
        "source": {
            "source": "local",
            "path": source_path
        },
        "policy": {
            "installation": "AVAILABLE",
            "authentication": "ON_INSTALL"
        },
        "category": "Productivity"
    });

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
    if !path.exists() {
        return Ok(());
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
    if !path.exists() {
        return Ok(default);
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
    fs::copy(path, &backup_path)?;
    Ok(backup_path)
}

fn json_config_backup_path(path: &Path) -> PathBuf {
    path.with_extension("json.agent-pet-companion.bak")
}

fn write_file_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
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
    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
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

fn uninstall_codex_plugin_if_possible() {
    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return;
    }
    let Some(codex) = codex_command_path() else {
        return;
    };
    let _ = run_bounded(ProcessSpec::connector(
        codex,
        ["plugin", "remove", "agent-pet-companion@personal"],
    ));
}

fn remove_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn claude_settings_path() -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| agent_home().join(".claude"))
        .join("settings.json")
}

fn user_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
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
        remove_agent_pet_hook_values(target, connector_cli, Some(install_root));
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

fn is_agent_pet_claude_command(
    command: &str,
    connector_cli: &Path,
    install_root: Option<&Path>,
) -> bool {
    let command = command.trim();
    let cli = connector_cli.display().to_string();
    for executable in [shell_quote(&cli), cli] {
        if let Some(arguments) = command.strip_prefix(&executable) {
            if is_agent_pet_claude_arguments(arguments) {
                return true;
            }
        }
    }

    if let Some((executable, arguments)) = split_shell_executable(command) {
        if is_managed_runtime_cli(executable, connector_cli)
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
        command == executable || command == format!("{executable} >/dev/null 2>&1")
    })
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
    known_event && (suffix.is_empty() || suffix == ">/dev/null 2>&1")
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
        claude_settings_path, codex_marketplace_entry_path, codex_marketplace_path,
        codex_plugin_json_reports_installed, codex_plugin_text_reports_installed,
        connector_cli_path, ensure_codex_marketplace_entry, install_claude_settings,
        is_agent_pet_claude_command, json_config_backup_path, remove_claude_settings_hooks,
        remove_codex_marketplace_entry,
    };
    use crate::connections;
    use crate::paths::AppPaths;
    use petcore_types::{AgentSource, CheckStatus};
    use serde_json::json;
    use std::ffi::{OsStr, OsString};
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

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
        assert!(repair_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&marketplace).unwrap(), invalid_json);
        assert!(!json_config_backup_path(&marketplace).exists());

        let uninstall_error = remove_codex_marketplace_entry().unwrap_err();
        assert!(uninstall_error.to_string().contains("JSON 无效"));
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
        let owned_helper_command = format!("'{}'", canonical_helper.display());
        let foreign_helper_command = format!("'{}'", foreign_helper.display());
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
                            { "type": "command", "command": foreign_helper_command }
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
        assert!(repaired_settings.contains("agent hook --source claude_code"));
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

    fn agent_pet_plugin_count(marketplace: &serde_json::Value) -> usize {
        marketplace["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|plugin| plugin["name"].as_str() == Some("agent-pet-companion"))
            .count()
    }
}
