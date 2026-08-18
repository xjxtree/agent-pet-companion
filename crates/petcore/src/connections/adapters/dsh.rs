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

pub(crate) const DSH_TASK_START_EVENTS: &[&str] = &["user/message", "turn/start"];
pub(crate) const DSH_TASK_ACTIVITY_EVENTS: &[&str] = &["tool/call", "tool/result", "todo/write"];
pub(crate) const DSH_TASK_COMPLETION_EVENTS: &[&str] = &["turn/end"];

pub(super) const DSH_MANAGED_PLUGIN_FILENAME: &str = "agent-pet-companion.js";
pub(super) const DSH_MANAGED_PATCH_ENTRY_ID: &str = "agent-pet-companion";

fn dsh_home_spec() -> (PathBuf, Vec<&'static str>) {
    if let Some(base) = non_empty_env_path("APC_AGENT_CONFIG_HOME") {
        (base, vec![".dsh"])
    } else if let Some(base) = non_empty_env_path("DSH_HOME") {
        (base, Vec::new())
    } else {
        (user_home(), vec![".dsh"])
    }
}

pub(super) fn dsh_home() -> PathBuf {
    let (base, components) = dsh_home_spec();
    components
        .into_iter()
        .fold(base, |path, component| path.join(component))
}

pub(super) fn dsh_default_profile_dir() -> PathBuf {
    dsh_home().join("profiles").join("web")
}

pub(super) fn dsh_profile_directory_state() -> ManagedPathState {
    let (base, mut components) = dsh_home_spec();
    components.extend(["profiles", "web"]);
    managed_directory_chain_state(&dsh_default_profile_dir(), base, &components)
}

fn ensure_dsh_profile_directory() -> Result<()> {
    let (base, components) = dsh_home_spec();
    ensure_managed_directory_tree(&base)?;
    let mut current = base;
    for component in components.into_iter().chain(["profiles", "web"]) {
        current.push(component);
        ensure_managed_directory(&current)?;
    }
    Ok(())
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum DshPatchEntryState {
    Missing,
    Owned,
    Conflict,
}

fn patch_name_value(line: &str) -> Option<String> {
    let value = line.trim().strip_prefix("name:")?.trim();
    if value.starts_with('"') {
        serde_json::from_str(value).ok()
    } else if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

pub(super) fn dsh_patch_entry_state(content: &str, plugin_path: &Path) -> DshPatchEntryState {
    let lines: Vec<&str> = content.lines().collect();
    let expected_path = plugin_path.display().to_string();
    let mut owned_count = 0;
    let mut saw_id = false;
    for (index, line) in lines.iter().enumerate() {
        if line.trim() != format!("- id: {DSH_MANAGED_PATCH_ENTRY_ID}") {
            continue;
        }
        saw_id = true;
        let exact_block = index > 0
            && lines[index - 1].trim() == "- insert:"
            && lines
                .get(index + 1)
                .and_then(|line| patch_name_value(line))
                .as_deref()
                == Some(expected_path.as_str());
        if exact_block {
            owned_count += 1;
        } else {
            return DshPatchEntryState::Conflict;
        }
    }
    match (saw_id, owned_count) {
        (false, _) => DshPatchEntryState::Missing,
        (true, 1) => DshPatchEntryState::Owned,
        _ => DshPatchEntryState::Conflict,
    }
}

/// Generates the cordis.patch.yml patch entry block for insertion.
pub(super) fn rendered_dsh_patch_entry(plugin_path: &Path) -> String {
    let quoted_path = serde_json::to_string(&plugin_path.display().to_string())
        .expect("serializing a dsh plugin path cannot fail");
    format!("- insert:\n    - id: {DSH_MANAGED_PATCH_ENTRY_ID}\n      name: {quoted_path}\n")
}

fn bounded_patch_content(path: &Path) -> Result<Option<String>> {
    match dsh_profile_directory_state() {
        ManagedPathState::Missing => return Ok(None),
        ManagedPathState::Conflict => {
            return Err(PetCoreError::Conflict(format!(
                "拒绝读取包含符号链接或非目录路径的 dsh profile：{}",
                path.display()
            )))
        }
        ManagedPathState::Safe => {}
    }
    match config_file_path_state(path) {
        ManagedPathState::Missing => return Ok(None),
        ManagedPathState::Conflict => {
            return Err(PetCoreError::Conflict(format!(
                "拒绝读取符号链接、非普通文件或不安全目录中的 dsh 配置：{}",
                path.display()
            )))
        }
        ManagedPathState::Safe => {}
    }
    let metadata = fs::metadata(path)?;
    if metadata.len() > MAX_MANAGED_CONNECTOR_SCRIPT_BYTES {
        return Err(PetCoreError::Conflict(format!(
            "dsh cordis.patch.yml 超过安全读取上限，拒绝修改：{}",
            path.display()
        )));
    }
    Ok(Some(fs::read_to_string(path)?))
}

pub(super) fn dsh_patch_file_conflicts(plugin_path: &Path) -> bool {
    if dsh_profile_directory_state() == ManagedPathState::Conflict {
        return true;
    }
    let patch_path = dsh_patch_file_path();
    if config_file_path_state(&patch_path) == ManagedPathState::Conflict {
        return true;
    }
    match bounded_patch_content(&patch_path) {
        Ok(Some(content)) => {
            dsh_patch_entry_state(&content, plugin_path) == DshPatchEntryState::Conflict
        }
        Ok(None) => false,
        Err(_) => true,
    }
}

fn add_dsh_patch_entry(content: &str, plugin_path: &Path) -> Result<String> {
    match dsh_patch_entry_state(content, plugin_path) {
        DshPatchEntryState::Owned => return Ok(content.to_string()),
        DshPatchEntryState::Conflict => {
            return Err(PetCoreError::Conflict(
                "dsh cordis.patch.yml 已包含同名但不匹配的条目；拒绝覆盖".to_string(),
            ))
        }
        DshPatchEntryState::Missing => {}
    }
    let mut lines: Vec<String> = content.lines().map(ToOwned::to_owned).collect();
    let data_lines: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter_map(|(index, line)| {
            let trimmed = line.trim();
            (!trimmed.is_empty() && !trimmed.starts_with('#')).then_some(index)
        })
        .collect();
    let entry_lines: Vec<String> = rendered_dsh_patch_entry(plugin_path)
        .lines()
        .map(ToOwned::to_owned)
        .collect();
    if data_lines.len() == 1 && lines[data_lines[0]].trim() == "[]" {
        lines.splice(data_lines[0]..=data_lines[0], entry_lines);
    } else {
        lines.extend(entry_lines);
    }
    Ok(format!("{}\n", lines.join("\n")))
}

pub(super) fn check_dsh_patch_file(plugin_path: &Path) -> ConnectionCheckItem {
    let patch_path = dsh_patch_file_path();
    let path_state = config_file_path_state(&patch_path);
    let entry_state = bounded_patch_content(&patch_path)
        .ok()
        .flatten()
        .map(|content| dsh_patch_entry_state(&content, plugin_path))
        .unwrap_or(DshPatchEntryState::Missing);
    let installed =
        path_state == ManagedPathState::Safe && entry_state == DshPatchEntryState::Owned;
    let conflict = dsh_patch_file_conflicts(plugin_path);

    ConnectionCheckItem::new(
        CheckCode::ManagedConnector,
        if conflict {
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
        } else if conflict {
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

pub(super) fn repair_dsh(install_root: &Path, connector_cli: &Path) -> Result<()> {
    let plugin_path = install_root.join(DSH_MANAGED_PLUGIN_FILENAME);
    if managed_connector_script_ownership(&plugin_path, AgentSource::Dsh)
        == ManagedConnectorScriptOwnership::Foreign
    {
        return Err(PetCoreError::Conflict(format!(
            "拒绝覆盖无法识别为 Agent Pet Companion 的 dsh Plugin：{}",
            plugin_path.display()
        )));
    }
    let patch_path = dsh_patch_file_path();
    if let Some(content) = bounded_patch_content(&patch_path)? {
        if dsh_patch_entry_state(&content, &plugin_path) == DshPatchEntryState::Conflict {
            return Err(PetCoreError::Conflict(
                "dsh cordis.patch.yml 已包含同名但不匹配的条目；拒绝覆盖".to_string(),
            ));
        }
    }

    // Validate and create both managed trees before publishing either file.
    ensure_managed_directory_tree(install_root)?;
    ensure_dsh_profile_directory()?;
    let current_content = bounded_patch_content(&patch_path)?.unwrap_or_else(|| "[]\n".to_string());
    let updated = add_dsh_patch_entry(&current_content, &plugin_path)?;

    // Publish the owned plugin before making the host profile refer to it.
    let rendered_plugin = render_dsh_plugin(DSH_PLUGIN_TEMPLATE, connector_cli);
    write_owned_connector_script(&plugin_path, rendered_plugin.as_bytes(), AgentSource::Dsh)?;

    if updated != current_content {
        write_file_atomic(&patch_path, updated.as_bytes())?;
    }
    Ok(())
}

pub(super) fn remove_dsh_patch_entry(plugin_path: &Path) -> Result<()> {
    let patch_path = dsh_patch_file_path();
    let Some(content) = bounded_patch_content(&patch_path)? else {
        return Ok(());
    };
    match dsh_patch_entry_state(&content, plugin_path) {
        DshPatchEntryState::Missing => return Ok(()),
        DshPatchEntryState::Conflict => {
            return Err(PetCoreError::Conflict(
                "dsh cordis.patch.yml 的同名条目不属于当前安装；拒绝删除".to_string(),
            ))
        }
        DshPatchEntryState::Owned => {}
    }
    let lines: Vec<&str> = content.lines().collect();
    let id_index = lines
        .iter()
        .position(|line| line.trim() == format!("- id: {DSH_MANAGED_PATCH_ENTRY_ID}"))
        .expect("owned dsh patch entry must have an id line");
    let mut kept: Vec<String> = lines
        .iter()
        .enumerate()
        .filter(|(index, _)| !((id_index - 1)..=(id_index + 1)).contains(index))
        .map(|(_, line)| (*line).to_string())
        .collect();
    let has_data = kept.iter().any(|line| {
        let trimmed = line.trim();
        !trimmed.is_empty() && !trimmed.starts_with('#')
    });
    if !has_data {
        kept.push("[]".to_string());
    }
    let updated = format!("{}\n", kept.join("\n"));
    write_file_atomic(&patch_path, updated.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patch_entry_replaces_empty_sequence_and_quotes_paths() {
        let plugin = Path::new("/Applications/Agent Pet Companion/dsh/plugin.js");
        let updated = add_dsh_patch_entry("# user comment\n[]\n", plugin).unwrap();
        assert!(updated.starts_with("# user comment\n- insert:\n"));
        assert!(!updated.lines().any(|line| line.trim() == "[]"));
        assert!(updated.contains("name: \"/Applications/Agent Pet Companion/dsh/plugin.js\""));
        assert_eq!(
            dsh_patch_entry_state(&updated, plugin),
            DshPatchEntryState::Owned
        );
    }

    #[test]
    fn patch_entry_preserves_unrelated_rows_and_rejects_same_id_at_another_path() {
        let plugin = Path::new("/managed/plugin.js");
        let unrelated = "- insert:\n    - id: user-plugin\n      name: /user/plugin.js\n";
        let updated = add_dsh_patch_entry(unrelated, plugin).unwrap();
        assert!(updated.starts_with(unrelated));
        assert_eq!(
            dsh_patch_entry_state(&updated, plugin),
            DshPatchEntryState::Owned
        );

        let conflict = "- insert:\n    - id: agent-pet-companion\n      name: /someone/else.js\n";
        assert_eq!(
            dsh_patch_entry_state(conflict, plugin),
            DshPatchEntryState::Conflict
        );
        assert!(add_dsh_patch_entry(conflict, plugin).is_err());
    }
}
