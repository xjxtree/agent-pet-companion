//! DeepSeek Harness (dsh) connector adapter.
//!
//! Owns dsh-specific paths, Cordis patch file manipulation, plugin file
//! management, and health/verification checks.

use std::fs;
use std::path::{Path, PathBuf};

use super::*;

pub(crate) const DSH_PLUGIN_TEMPLATE: &str =
    include_str!("../../../../../plugins/dsh/agent-pet-companion.js.tpl");

pub(crate) const DSH_AUDITED_EVENTS: &[&str] = &[
    "session/event",
    "session/disposed",
    "subagent/start",
    "subagent/end",
    "agent/status",
];

pub(crate) const DSH_TASK_START_EVENTS: &[&str] = &["turn/start"];
pub(crate) const DSH_TASK_ACTIVITY_EVENTS: &[&str] = &["tool/call", "tool/result", "todo/write"];
pub(crate) const DSH_TASK_COMPLETION_EVENTS: &[&str] = &["turn/end"];

pub(super) const DSH_MANAGED_PLUGIN_FILENAME: &str = "agent-pet-companion.js";
pub(super) const DSH_MANAGED_PATCH_ENTRY_ID: &str = "agent-pet-companion";

pub(super) fn dsh_home() -> PathBuf {
    non_empty_env_path("DSH_HOME").unwrap_or_else(|| user_home().join(".dsh"))
}

pub(super) fn dsh_default_profile_dir() -> PathBuf {
    dsh_home().join("profiles").join("web")
}

pub(super) fn dsh_patch_file_path() -> PathBuf {
    dsh_default_profile_dir().join("cordis.patch.yml")
}

pub(super) fn dsh_managed_root_state(root: &Path) -> ManagedPathState {
    managed_directory_state(root)
}

pub(super) fn render_dsh_plugin(template: &str, connector_cli: &Path) -> String {
    template
        .replace(
            "__APC_CLI_JSON__",
            &serde_json::to_string(&connector_cli.display().to_string()).unwrap_or_default(),
        )
        .replace(
            "__APC_CONNECTOR_RELEASE_VERSION__",
            APP_MANAGED_CONNECTOR_RELEASE_VERSION,
        )
}

/// Checks whether the cordis.patch.yml file contains our owned insert entry.
pub(super) fn patch_file_contains_owned_entry(content: &str, plugin_path: &Path) -> bool {
    let path_str = plugin_path.display().to_string();
    content.contains(DSH_MANAGED_PATCH_ENTRY_ID) && content.contains(&path_str)
}

/// Generates the cordis.patch.yml patch entry block for insertion.
pub(super) fn rendered_dsh_patch_entry(plugin_path: &Path) -> String {
    format!(
        "- insert:\n    - id: {DSH_MANAGED_PATCH_ENTRY_ID}\n      name: {}\n",
        plugin_path.display()
    )
}

pub(super) fn check_dsh_patch_file(plugin_path: &Path) -> ConnectionCheckItem {
    let patch_path = dsh_patch_file_path();
    let path_state = config_file_path_state(&patch_path);
    let installed = path_state == ManagedPathState::Safe
        && fs::read_to_string(&patch_path)
            .is_ok_and(|content| patch_file_contains_owned_entry(&content, plugin_path));

    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if path_state == ManagedPathState::Conflict {
            "dsh cordis.patch.yml 配置冲突".to_string()
        } else {
            "dsh cordis.patch.yml".to_string()
        },
        if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        if installed {
            format!("configured: 已包含受管插件条目：{}", patch_path.display())
        } else if path_state == ManagedPathState::Conflict {
            format!(
                "cordis.patch.yml 或其配置目录是符号链接/非普通路径；拒绝一键覆盖：{}",
                patch_path.display()
            )
        } else {
            format!("待配置 {}（指向受管插件）", patch_path.display())
        },
        Some(RecoveryAction::Recheck),
    )
}

fn ensure_directory_tree(path: &Path) -> Result<()> {
    let mut stack = Vec::new();
    let mut current = Some(path);
    while let Some(p) = current {
        if p.exists() {
            break;
        }
        stack.push(p.to_path_buf());
        current = p.parent();
    }
    while let Some(p) = stack.pop() {
        ensure_managed_directory(&p)?;
    }
    Ok(())
}

pub(super) fn repair_dsh(install_root: &Path, connector_cli: &Path) -> Result<()> {
    // 1. Write the managed plugin file in install_root
    ensure_directory_tree(install_root)?;
    let plugin_path = install_root.join(DSH_MANAGED_PLUGIN_FILENAME);
    let rendered_plugin = render_dsh_plugin(DSH_PLUGIN_TEMPLATE, connector_cli);
    fs::write(&plugin_path, rendered_plugin)?;

    // 2. Ensure cordis.patch.yml contains the managed entry
    let patch_path = dsh_patch_file_path();
    if let Some(parent) = patch_path.parent() {
        ensure_directory_tree(parent)?;
    }
    let current_content = fs::read_to_string(&patch_path).unwrap_or_default();
    if !patch_file_contains_owned_entry(&current_content, &plugin_path) {
        let entry = rendered_dsh_patch_entry(&plugin_path);
        let updated = if current_content.trim().is_empty() || current_content.trim() == "[]" {
            entry
        } else {
            format!("{current_content}\n{entry}")
        };
        fs::write(&patch_path, updated)?;
    }
    Ok(())
}

pub(super) fn remove_dsh_patch_entry(plugin_path: &Path) -> Result<()> {
    let patch_path = dsh_patch_file_path();
    if !patch_path.is_file() {
        return Ok(());
    }
    let content = fs::read_to_string(&patch_path)?;
    if !patch_file_contains_owned_entry(&content, plugin_path) {
        return Ok(());
    }
    let path_str = plugin_path.display().to_string();
    let mut kept_lines = Vec::new();
    for line in content.lines() {
        if line.contains(DSH_MANAGED_PATCH_ENTRY_ID) || line.contains(&path_str) {
            continue;
        }
        kept_lines.push(line);
    }
    let updated = kept_lines.join("\n");
    let trimmed = updated.trim();
    if trimmed.is_empty() {
        fs::write(&patch_path, "[]\n")?;
    } else {
        fs::write(&patch_path, format!("{trimmed}\n"))?;
    }
    Ok(())
}
