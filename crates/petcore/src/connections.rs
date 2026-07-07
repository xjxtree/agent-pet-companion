use crate::paths::AppPaths;
use crate::{now_rfc3339, Result};
use petcore_types::{AgentConnectionStatus, AgentSource, CheckStatus, ConnectionCheckItem};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};

pub fn check_all(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ]
    .into_iter()
    .map(|source| check_source(paths, source))
    .collect()
}

pub fn check_source(paths: &AppPaths, source: AgentSource) -> AgentConnectionStatus {
    let cli_name = cli_name(source);
    let install_root = install_root(paths, source);
    let cli_status = if command_exists(cli_name) {
        CheckStatus::Ok
    } else {
        CheckStatus::Missing
    };
    let mut items = vec![ConnectionCheckItem {
        name: cli_label(source).to_string(),
        status: cli_status,
        detail: if cli_status == CheckStatus::Ok {
            "命令可用".to_string()
        } else {
            format!("未在 PATH 中检测到 {cli_name}")
        },
    }];

    match source {
        AgentSource::Codex => {
            items.push(check_file(&install_root.join(".codex-plugin/plugin.json"), "插件"));
            items.push(check_file(&install_root.join("hooks/hooks.json"), "Hook"));
            items.push(check_file(
                &install_root.join("skills/agent-pet-studio/SKILL.md"),
                "Pet Studio Skill",
            ));
        }
        AgentSource::ClaudeCode => {
            items.push(check_file(&install_root.join("settings.fragment.json"), "Hooks"));
            items.push(check_file(&install_root.join("agent-pet-companion-hook.sh"), "事件通道"));
        }
        AgentSource::Pi => {
            items.push(check_file(&install_root.join("agent-pet-companion.ts"), "Extension"));
            items.push(check_file(&install_root.join("rpc-check.json"), "RPC"));
        }
        AgentSource::Opencode => {
            items.push(check_file(&install_root.join("agent-pet-companion.js"), "Plugin"));
            items.push(check_file(&install_root.join("server-check.json"), "Server"));
        }
    }

    AgentConnectionStatus {
        source,
        items,
        install_paths: vec![install_root.display().to_string()],
    }
}

pub fn repair_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    fs::create_dir_all(&root)?;
    match source {
        AgentSource::Codex => repair_codex(&root)?,
        AgentSource::ClaudeCode => repair_claude(&root)?,
        AgentSource::Pi => repair_pi(&root)?,
        AgentSource::Opencode => repair_opencode(&root)?,
    }
    Ok(check_source(paths, source))
}

pub fn uninstall_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    if root.exists() {
        fs::remove_dir_all(&root)?;
    }
    Ok(check_source(paths, source))
}

fn repair_codex(root: &Path) -> Result<()> {
    fs::create_dir_all(root.join(".codex-plugin"))?;
    fs::create_dir_all(root.join("hooks"))?;
    fs::create_dir_all(root.join("skills/agent-pet-studio"))?;
    fs::write(
        root.join(".codex-plugin/plugin.json"),
        serde_json::to_vec_pretty(&json!({
            "name": "agent-pet-companion",
            "version": "0.1.0",
            "hooks": "hooks/hooks.json",
            "description": "Forward trusted Codex lifecycle events to Agent Pet Companion."
        }))?,
    )?;
    fs::write(
        root.join("hooks/hooks.json"),
        serde_json::to_vec_pretty(&json!({
            "hooks": [
                {
                    "event": "session_start",
                    "command": "petcore-cli agent ingest --source codex --event-type start"
                },
                {
                    "event": "tool_start",
                    "command": "petcore-cli agent ingest --source codex --event-type tool"
                },
                {
                    "event": "permission_request",
                    "command": "petcore-cli agent ingest --source codex --event-type waiting"
                },
                {
                    "event": "session_done",
                    "command": "petcore-cli agent ingest --source codex --event-type done"
                },
                {
                    "event": "session_failed",
                    "command": "petcore-cli agent ingest --source codex --event-type failed"
                }
            ]
        }))?,
    )?;
    fs::write(
        root.join("skills/agent-pet-studio/SKILL.md"),
        "# agent-pet-studio\n\nInstalled by Agent Pet Companion. The repository copy is the source of truth.\n",
    )?;
    Ok(())
}

fn repair_claude(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    fs::write(
        root.join("settings.fragment.json"),
        serde_json::to_vec_pretty(&json!({
            "hooks": {
                "UserPromptSubmit": ["petcore-cli agent ingest --source claude_code --event-type start"],
                "PreToolUse": ["petcore-cli agent ingest --source claude_code --event-type tool"],
                "PermissionRequest": ["petcore-cli agent ingest --source claude_code --event-type waiting"],
                "Stop": ["petcore-cli agent ingest --source claude_code --event-type done"],
                "StopFailure": ["petcore-cli agent ingest --source claude_code --event-type failed"]
            }
        }))?,
    )?;
    fs::write(
        root.join("agent-pet-companion-hook.sh"),
        "#!/usr/bin/env bash\npetcore-cli agent ingest --source claude_code --event-type \"${APC_EVENT_TYPE:-tool}\"\n",
    )?;
    Ok(())
}

fn repair_pi(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    fs::write(
        root.join("agent-pet-companion.ts"),
        "export const name = 'agent-pet-companion';\nexport async function onEvent(event) { /* forwards to petcore-cli in installed builds */ }\n",
    )?;
    fs::write(
        root.join("rpc-check.json"),
        serde_json::to_vec_pretty(&json!({
            "status": "configured",
            "updated_at": now_rfc3339()
        }))?,
    )?;
    Ok(())
}

fn repair_opencode(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    fs::write(
        root.join("agent-pet-companion.js"),
        "export default function agentPetCompanionPlugin() { return { name: 'agent-pet-companion' }; }\n",
    )?;
    fs::write(
        root.join("server-check.json"),
        serde_json::to_vec_pretty(&json!({
            "status": "configured",
            "updated_at": now_rfc3339()
        }))?,
    )?;
    Ok(())
}

fn check_file(path: &Path, label: &str) -> ConnectionCheckItem {
    ConnectionCheckItem {
        name: label.to_string(),
        status: if path.exists() {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if path.exists() {
            "已安装".to_string()
        } else {
            format!("待写入 {}", path.display())
        },
    }
}

fn command_exists(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| dir.join(name).is_file())
}

fn install_root(paths: &AppPaths, source: AgentSource) -> PathBuf {
    paths.connectors_dir.join(match source {
        AgentSource::Codex => "codex",
        AgentSource::ClaudeCode => "claude-code",
        AgentSource::Pi => "pi",
        AgentSource::Opencode => "opencode",
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
        AgentSource::Codex => "CLI",
        AgentSource::ClaudeCode => "CLI",
        AgentSource::Pi => "CLI",
        AgentSource::Opencode => "Server",
    }
}
