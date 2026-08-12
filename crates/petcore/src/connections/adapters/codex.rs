pub(crate) const CODEX_PLUGIN_JSON: &str =
    include_str!("../../../../../plugins/codex/.codex-plugin/plugin.json");

pub(crate) const CODEX_HOOKS_TEMPLATE: &str =
    include_str!("../../../../../plugins/codex/hooks/hooks.json.tpl");

pub(crate) const CODEX_INSTALL_RESULT_SCHEMA: &str = "apc.codex-install-result.v1";

pub(crate) const CODEX_LOCAL_HOOK_EVENTS: &[&str] = &[
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

pub(crate) const CODEX_APP_SERVER_HOOK_EVENTS: &[&str] = &[
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

pub(crate) const CODEX_APP_SERVER_NOTIFICATION_EVENTS: &[&str] = &[
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

pub(crate) const CODEX_TASK_START_EVENTS: &[&str] = &["UserPromptSubmit"];

pub(crate) const CODEX_TASK_ACTIVITY_EVENTS: &[&str] = &["PreToolUse"];

pub(crate) const CODEX_TASK_COMPLETION_EVENTS: &[&str] = &["PostToolUse", "Stop"];

use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CodexMarketplaceEntryState {
    Missing,
    Current,
    OwnedOutdated,
    Conflict,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CodexVerifiedInstallResult {
    schema_version: String,
    status: String,
    phase: String,
    expected_version: String,
    active_version: String,
    expected_skills_sha256: String,
    active_skills_sha256: String,
    expected_content_sha256: String,
    managed_source_content_sha256: String,
    active_content_sha256: String,
    expected_studio_skill_sha256: String,
    managed_source_studio_skill_sha256: String,
    active_studio_skill_sha256: String,
}

#[derive(Clone, Debug)]
pub(super) struct CodexActivePluginProbe {
    pub(super) expected_version: String,
    pub(super) active_version: Option<String>,
    pub(super) expected_skills_sha256: String,
    pub(super) active_skills_sha256: Option<String>,
    pub(super) expected_content_sha256: String,
    pub(super) managed_source_content_sha256: Option<String>,
    pub(super) active_content_sha256: Option<String>,
    pub(super) expected_studio_skill_sha256: String,
    pub(super) managed_source_studio_skill_sha256: Option<String>,
    pub(super) active_studio_skill_sha256: Option<String>,
    pub(super) managed_source: bool,
    pub(super) exact: bool,
    pub(super) detail: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CodexPluginInstallAttempt {
    InstalledAndVerified,
    SkippedHermetic,
    HostMissing,
}

pub(super) fn codex_managed_root_state(root: &Path) -> ManagedPathState {
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

pub(super) fn installed_codex_plugin_manifest_version(root: &Path) -> Option<String> {
    let path = root.join(".codex-plugin/plugin.json");
    if !codex_manifest_is_owned(&path, root) {
        return None;
    }
    validated_connector_release_version(read_regular_json_config(&path)?.get("version")?.as_str()?)
}

/// Codex Hook configuration has a closed top-level schema and rejects custom
/// version fields. Bind an exact Hook file to the enclosing plugin manifest
/// only after its complete operational content matches the current template.
pub(super) fn installed_codex_hooks_bundle_version(
    root: &Path,
    connector_cli: &Path,
) -> Option<String> {
    (check_codex_hooks(&root.join("hooks/hooks.json"), connector_cli, root).status
        == CheckStatus::Ok)
        .then(|| installed_codex_plugin_manifest_version(root))
        .flatten()
}

pub(super) fn installed_codex_skill_version(root: &Path, skill: &str) -> Option<String> {
    let path = root.join("skills").join(skill).join("SKILL.md");
    if managed_regular_file_state(root, &path) != ManagedPathState::Safe {
        return None;
    }
    let content = fs::read_to_string(&path).ok()?;
    if !content.contains(&format!("name: {skill}")) {
        return None;
    }
    skill_front_matter_version(&content)
}

pub(super) fn codex_managed_components(
    paths: &AppPaths,
    plugin_status: CheckStatus,
    probe: Option<&CodexActivePluginProbe>,
) -> Vec<AgentManagedComponent> {
    let expected_version = expected_codex_plugin_version().ok();
    let source_content_matches =
        managed_connector_artifacts_match_current_installation(paths, AgentSource::Codex);
    let active_content_matches = probe.map(|probe| {
        probe.active_content_sha256.as_deref() == Some(probe.expected_content_sha256.as_str())
            && probe.managed_source_content_sha256.as_deref()
                == Some(probe.expected_content_sha256.as_str())
            && source_content_matches
    });
    let skills_match = probe.map(|probe| {
        probe.active_skills_sha256.as_deref() == Some(probe.expected_skills_sha256.as_str())
    });
    let active_version = probe.and_then(|probe| probe.active_version.clone());
    let unavailable_active_status = match plugin_status {
        CheckStatus::Missing => CheckStatus::Missing,
        CheckStatus::NeedsFix => CheckStatus::NeedsFix,
        _ => CheckStatus::Unverified,
    };
    let skill_status = match skills_match {
        Some(true) => CheckStatus::Ok,
        Some(false) => CheckStatus::NeedsFix,
        None => unavailable_active_status,
    };
    // Skills state their own installed versions. Codex rejects custom Hook
    // metadata, so an exact Hook is bound to the enclosing plugin version only
    // after the complete Hook template matches.
    let root = install_root(paths, AgentSource::Codex);
    let installed_hook_bundle_version =
        installed_codex_hooks_bundle_version(&root, &connector_cli_path(paths));
    let installed_studio_version = installed_codex_skill_version(&root, "agent-pet-studio");
    let installed_maker_version = installed_codex_skill_version(&root, "agent-pet-maker");

    vec![
        AgentManagedComponent {
            kind: AgentExtensionKind::Plugin,
            name: "agent-pet-companion".to_string(),
            ownership: AgentExtensionOwnership::AppManaged,
            status: plugin_status,
            expected_version: expected_version.clone(),
            active_version: active_version
                .clone()
                .or_else(|| installed_codex_plugin_manifest_version(&root)),
            content_matches: active_content_matches,
        },
        AgentManagedComponent {
            kind: AgentExtensionKind::Hook,
            name: "agent-pet-companion".to_string(),
            ownership: AgentExtensionOwnership::AppManaged,
            status: plugin_status,
            expected_version: expected_version.clone(),
            active_version: installed_hook_bundle_version,
            content_matches: active_content_matches,
        },
        AgentManagedComponent {
            kind: AgentExtensionKind::Skill,
            name: "agent-pet-studio".to_string(),
            ownership: AgentExtensionOwnership::AppManaged,
            status: skill_status,
            expected_version: expected_version.clone(),
            active_version: installed_studio_version,
            content_matches: skills_match,
        },
        AgentManagedComponent {
            kind: AgentExtensionKind::Skill,
            name: "agent-pet-maker".to_string(),
            ownership: AgentExtensionOwnership::AppManaged,
            status: skill_status,
            expected_version,
            active_version: installed_maker_version,
            content_matches: skills_match,
        },
    ]
}

pub(super) fn refresh_managed_codex(
    paths: &AppPaths,
    root: &Path,
    cli_path: &Path,
) -> Result<InstalledSourceRefreshResult> {
    let expected_version = expected_codex_plugin_version()?;
    let expected_skills_sha256 = expected_codex_skill_bundle_sha256();
    let expected_content_sha256 = expected_codex_plugin_content_sha256(cli_path)?;
    let source_was_current =
        managed_connector_artifacts_match_current_installation(paths, AgentSource::Codex);

    if source_was_current {
        if let Some(codex) = codex_command_path() {
            let probe = probe_codex_active_plugin(root, cli_path, &codex)?;
            if probe.exact {
                return Ok(codex_refresh_result(
                    InstalledSourceRefreshStatus::Current,
                    true,
                    probe,
                    "Codex 插件源、启用版本、活动缓存与宠物制作 Skills 均已是当前版本",
                ));
            }
        }
    }

    let attempt = repair_codex(root, cli_path)?;
    match attempt {
        CodexPluginInstallAttempt::InstalledAndVerified => {
            let codex = codex_command_path().ok_or_else(|| {
                PetCoreError::Validation("Codex 安装后命令不可用，无法完成复检".to_string())
            })?;
            let probe = probe_codex_active_plugin(root, cli_path, &codex)?;
            if !probe.exact {
                return Err(PetCoreError::Validation(format!(
                    "Codex plugin add 返回成功，但活动插件未收敛：{}",
                    probe.detail
                )));
            }
            Ok(codex_refresh_result(
                InstalledSourceRefreshStatus::Updated,
                true,
                probe,
                "Codex 插件源、活动缓存与宠物制作 Skills 已更新并通过摘要复检",
            ))
        }
        CodexPluginInstallAttempt::SkippedHermetic => {
            let source_verified =
                managed_connector_artifacts_match_current_installation(paths, AgentSource::Codex);
            Ok(InstalledSourceRefreshResult {
                source: AgentSource::Codex,
                status: if source_was_current {
                    InstalledSourceRefreshStatus::Current
                } else {
                    InstalledSourceRefreshStatus::Updated
                },
                managed: true,
                refreshed: true,
                ok: source_verified,
                verified: false,
                expected_version: Some(expected_version),
                active_version: None,
                expected_skills_sha256: Some(expected_skills_sha256),
                active_skills_sha256: None,
                expected_content_sha256: Some(expected_content_sha256.clone()),
                managed_source_content_sha256: codex_plugin_content_sha256(root).ok(),
                active_content_sha256: None,
                detail: "隔离配置环境已精确更新插件源；未调用 Codex，也未宣称活动缓存已验证"
                    .to_string(),
                error: (!source_verified)
                    .then(|| "codex_managed_source_verification_failed".to_string()),
            })
        }
        CodexPluginInstallAttempt::HostMissing => Ok(InstalledSourceRefreshResult {
            source: AgentSource::Codex,
            status: InstalledSourceRefreshStatus::PendingHost,
            managed: true,
            refreshed: true,
            ok: false,
            verified: false,
            expected_version: Some(expected_version),
            active_version: None,
            expected_skills_sha256: Some(expected_skills_sha256),
            active_skills_sha256: None,
            expected_content_sha256: Some(expected_content_sha256),
            managed_source_content_sha256: codex_plugin_content_sha256(root).ok(),
            active_content_sha256: None,
            detail: "插件源已更新；Codex 命令当前不可用，活动缓存尚未更新".to_string(),
            error: Some("codex_host_unavailable".to_string()),
        }),
    }
}

pub(super) fn codex_refresh_result(
    status: InstalledSourceRefreshStatus,
    refreshed: bool,
    probe: CodexActivePluginProbe,
    detail: &str,
) -> InstalledSourceRefreshResult {
    InstalledSourceRefreshResult {
        source: AgentSource::Codex,
        status,
        managed: true,
        refreshed,
        ok: probe.exact,
        verified: probe.exact,
        expected_version: Some(probe.expected_version),
        active_version: probe.active_version,
        expected_skills_sha256: Some(probe.expected_skills_sha256),
        active_skills_sha256: probe.active_skills_sha256,
        expected_content_sha256: Some(probe.expected_content_sha256),
        managed_source_content_sha256: probe.managed_source_content_sha256,
        active_content_sha256: probe.active_content_sha256,
        detail: detail.to_string(),
        error: None,
    }
}

pub(super) fn repair_codex(root: &Path, cli_path: &Path) -> Result<CodexPluginInstallAttempt> {
    write_codex_connector(root, cli_path)?;
    ensure_codex_marketplace_entry()?;
    install_codex_plugin_if_possible(root, cli_path)
}

pub(super) fn write_codex_connector(root: &Path, cli_path: &Path) -> Result<()> {
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

pub(super) fn write_codex_agent_pet_maker(root: &Path) -> Result<()> {
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
        let mode = if AGENT_PET_MAKER_EXECUTABLE_FILES.contains(relative_path) {
            0o755
        } else {
            0o644
        };
        write_managed_file_atomic(&path, content.as_bytes(), mode)?;
    }
    Ok(())
}

pub(super) fn ensure_codex_plugin_root(root: &Path) -> Result<()> {
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

pub(super) fn validate_codex_root_repair_ownership(root: &Path) -> Result<()> {
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
    // On-disk evidence that this fixed root holds an install this App wrote.
    // The marketplace entry alone is not evidence: it can point at a directory
    // whose contents this App never created.
    let root_owned_on_disk = codex_manifest_is_owned(&root.join(".codex-plugin/plugin.json"), root)
        || codex_hooks_are_owned(&root.join("hooks/hooks.json"), root)
        || codex_studio_skill_is_owned(&root.join("skills/agent-pet-studio/SKILL.md"), root)
        || codex_maker_skill_is_owned(root);
    let owned = root_owned_on_disk
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
    // Inside a root this App provably wrote, a plain regular file at one of the
    // App's own fixed paths is this App's file: an unrecognized revision means
    // it is stale or locally edited, not that it belongs to someone else.
    // Refusing to rewrite it strands the install with no working repair, so
    // only a path this App cannot safely write — a symlink, a directory, or an
    // unreadable entry — still blocks.
    for path in [
        root.join(".codex-plugin/plugin.json"),
        root.join("hooks/hooks.json"),
        root.join("skills/agent-pet-studio/SKILL.md"),
    ] {
        match managed_regular_file_state(root, &path) {
            ManagedPathState::Missing => {}
            ManagedPathState::Safe if root_owned_on_disk => {}
            ManagedPathState::Safe => {
                return Err(PetCoreError::Conflict(format!(
                    "Codex connector 固定路径已有本 App 未写入的文件，拒绝覆盖：{}",
                    path.display()
                )));
            }
            ManagedPathState::Conflict => {
                return Err(PetCoreError::Conflict(format!(
                    "Codex connector 固定路径是符号链接、目录或不可检查项，拒绝覆盖：{}",
                    path.display()
                )));
            }
        }
    }

    let maker_root = root.join("skills/agent-pet-maker");
    let maker_owned = root_owned_on_disk
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

pub(super) fn check_codex_plugin_manifest(path: &Path, install_root: &Path) -> ConnectionCheckItem {
    let path_state = managed_regular_file_state(install_root, path);
    let expected = serde_json::from_str::<Value>(CODEX_PLUGIN_JSON).ok();
    let configured = path_state == ManagedPathState::Safe
        && fs::read_to_string(path)
            .ok()
            .and_then(|content| serde_json::from_str::<Value>(&content).ok())
            .zip(expected)
            .is_some_and(|(actual, expected)| actual == expected);
    let unrecognized_content = path_state == ManagedPathState::Safe
        && !configured
        && !codex_manifest_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict;
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
                "路径是符号链接、目录或不可检查项，拒绝覆盖：{}",
                path.display()
            )
        } else if unrecognized_content {
            format!(
                "内容不是本 App 写入的版本，待替换为当前版本 {}",
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

pub(super) fn check_codex_hooks(
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
    let unrecognized_content = path_state == ManagedPathState::Safe
        && !configured
        && !codex_hooks_are_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict;
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
            "configured: Hook 键、group、command 与当前 App 模板精确一致；failed 不由 hooks 直接宣称".to_string()
        } else if conflict {
            format!(
                "路径是符号链接、目录或不可检查项，拒绝覆盖：{}",
                path.display()
            )
        } else if unrecognized_content {
            format!(
                "内容不是本 App 写入的版本，待替换为当前版本 {}",
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

pub(super) fn rendered_codex_hooks(connector_cli: &Path) -> Result<Value> {
    let cli = shell_quote(&connector_cli.display().to_string());
    let hook_cli = format!(
        "APC_CONNECTOR_CONTRACT_VERSION={} {cli}",
        shell_quote(CODEX_HOOKS_CONTRACT_VERSION)
    );
    render_json_template(CODEX_HOOKS_TEMPLATE, "__APC_CLI__", &hook_cli)
}

pub(super) fn check_codex_studio_skill(path: &Path, install_root: &Path) -> ConnectionCheckItem {
    let path_state = managed_regular_file_state(install_root, path);
    let installed = path_state == ManagedPathState::Safe
        && fs::read(path).is_ok_and(|content| content == PET_STUDIO_SKILL_MD.as_bytes());
    let unrecognized_content = path_state == ManagedPathState::Safe
        && !installed
        && !codex_studio_skill_is_owned(path, install_root);
    let conflict = path_state == ManagedPathState::Conflict;
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
                "路径是符号链接、目录或不可检查项，拒绝覆盖：{}",
                path.display()
            )
        } else if unrecognized_content {
            format!(
                "内容不是本 App 写入的版本，待替换为当前版本 {}",
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

pub(super) fn remove_owned_codex_connector_files(root: &Path) -> Result<()> {
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

pub(super) fn check_codex_agent_pet_maker(root: &Path) -> ConnectionCheckItem {
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
    let non_executable_helpers = AGENT_PET_MAKER_EXECUTABLE_FILES
        .iter()
        .filter(|relative_path| {
            !directories_are_safe
                || !fs::symlink_metadata(skill_root.join(relative_path))
                    .map(|metadata| {
                        metadata.is_file()
                            && !metadata.file_type().is_symlink()
                            && metadata.permissions().mode() & 0o111 != 0
                    })
                    .unwrap_or(false)
        })
        .copied()
        .collect::<Vec<_>>();
    let helpers_are_executable = non_executable_helpers.is_empty();

    let installed = missing_or_outdated.is_empty() && helpers_are_executable;
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
            reasons.extend(
                non_executable_helpers
                    .iter()
                    .map(|path| format!("{path}（不可执行）")),
            );
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

pub(super) fn check_codex_marketplace_entry() -> ConnectionCheckItem {
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

pub(super) fn codex_marketplace_entry() -> Value {
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

pub(super) fn codex_marketplace_entry_state(path: &Path) -> CodexMarketplaceEntryState {
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

pub(super) fn codex_marketplace_entry_path(path: &Path) -> Option<String> {
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

pub(super) fn check_codex_hook_trust(probe_cwd: &Path) -> ConnectionCheckItem {
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

pub(super) fn check_codex_hook_trust_light(install_root: &Path) -> ConnectionCheckItem {
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct CodexPluginListing {
    pub(super) installed: bool,
    pub(super) enabled: bool,
    pub(super) version: Option<String>,
    pub(super) source_path: Option<String>,
}

pub(super) fn expected_codex_plugin_version() -> Result<String> {
    let manifest: Value = serde_json::from_str(CODEX_PLUGIN_JSON)?;
    let version = manifest
        .get("version")
        .and_then(Value::as_str)
        .filter(|version| {
            !version.is_empty()
                && *version != "."
                && *version != ".."
                && version
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
        })
        .ok_or_else(|| {
            PetCoreError::Validation("App 自带 Codex plugin.json 缺少安全的版本标识".to_string())
        })?;
    Ok(version.to_string())
}

pub(super) fn codex_home() -> PathBuf {
    absolute_env_path("CODEX_HOME").unwrap_or_else(|| agent_home().join(".codex"))
}

pub(super) fn codex_active_cache_root(expected_version: &str) -> PathBuf {
    codex_home()
        .join("plugins")
        .join("cache")
        .join("personal")
        .join("agent-pet-companion")
        .join(expected_version)
}

pub(super) fn update_codex_skill_digest(hasher: &mut Sha256, relative_path: &str, contents: &[u8]) {
    hasher.update(relative_path.as_bytes());
    hasher.update([0]);
    hasher.update((contents.len() as u64).to_le_bytes());
    hasher.update(contents);
}

pub(super) fn expected_codex_skill_bundle_sha256() -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"agent-pet-companion/codex-skills/v1\0");
    update_codex_skill_digest(
        &mut hasher,
        "skills/agent-pet-studio/SKILL.md",
        PET_STUDIO_SKILL_MD.as_bytes(),
    );
    for (relative_path, contents) in AGENT_PET_MAKER_FILES {
        update_codex_skill_digest(
            &mut hasher,
            &format!("skills/agent-pet-maker/{relative_path}"),
            contents.as_bytes(),
        );
    }
    hex::encode(hasher.finalize())
}

pub(super) fn codex_skill_bundle_sha256(root: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hasher.update(b"agent-pet-companion/codex-skills/v1\0");
    let studio_path = root.join("skills/agent-pet-studio/SKILL.md");
    if managed_regular_file_state(root, &studio_path) != ManagedPathState::Safe {
        return Err(PetCoreError::Validation(
            "Codex 活动缓存中的 agent-pet-studio 不是安全普通文件".to_string(),
        ));
    }
    let studio = fs::read(&studio_path)?;
    update_codex_skill_digest(&mut hasher, "skills/agent-pet-studio/SKILL.md", &studio);
    for (relative_path, _) in AGENT_PET_MAKER_FILES {
        let path = root.join("skills/agent-pet-maker").join(relative_path);
        if managed_regular_file_state(root, &path) != ManagedPathState::Safe {
            return Err(PetCoreError::Validation(format!(
                "Codex 活动缓存中的 agent-pet-maker 文件不是安全普通文件：{relative_path}"
            )));
        }
        let contents = fs::read(path)?;
        update_codex_skill_digest(
            &mut hasher,
            &format!("skills/agent-pet-maker/{relative_path}"),
            &contents,
        );
    }
    Ok(hex::encode(hasher.finalize()))
}

pub(super) fn expected_codex_plugin_content_sha256(connector_cli: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hasher.update(b"agent-pet-companion/codex-plugin-content/v1\0");
    let plugin: Value = serde_json::from_str(CODEX_PLUGIN_JSON)?;
    update_codex_skill_digest(
        &mut hasher,
        ".codex-plugin/plugin.json",
        &serde_json::to_vec_pretty(&plugin)?,
    );
    update_codex_skill_digest(
        &mut hasher,
        "hooks/hooks.json",
        &serde_json::to_vec_pretty(&rendered_codex_hooks(connector_cli)?)?,
    );
    update_codex_skill_digest(
        &mut hasher,
        "skills/agent-pet-studio/SKILL.md",
        PET_STUDIO_SKILL_MD.as_bytes(),
    );
    for (relative_path, contents) in AGENT_PET_MAKER_FILES {
        update_codex_skill_digest(
            &mut hasher,
            &format!("skills/agent-pet-maker/{relative_path}"),
            contents.as_bytes(),
        );
    }
    Ok(hex::encode(hasher.finalize()))
}

pub(crate) fn compiled_codex_plugin_identity(paths: &AppPaths) -> Result<(String, String, String)> {
    Ok((
        expected_codex_plugin_version()?,
        expected_codex_skill_bundle_sha256(),
        expected_codex_plugin_content_sha256(&connector_cli_path(paths))?,
    ))
}

pub(super) fn codex_plugin_content_sha256(root: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hasher.update(b"agent-pet-companion/codex-plugin-content/v1\0");
    for relative_path in [
        ".codex-plugin/plugin.json",
        "hooks/hooks.json",
        "skills/agent-pet-studio/SKILL.md",
    ] {
        let path = root.join(relative_path);
        if managed_regular_file_state(root, &path) != ManagedPathState::Safe {
            return Err(PetCoreError::Validation(format!(
                "Codex plugin 内容文件不是安全普通文件：{relative_path}"
            )));
        }
        let contents = fs::read(path)?;
        update_codex_skill_digest(&mut hasher, relative_path, &contents);
    }
    for (relative_path, _) in AGENT_PET_MAKER_FILES {
        let digest_path = format!("skills/agent-pet-maker/{relative_path}");
        let path = root.join(&digest_path);
        if managed_regular_file_state(root, &path) != ManagedPathState::Safe {
            return Err(PetCoreError::Validation(format!(
                "Codex plugin 内容文件不是安全普通文件：{digest_path}"
            )));
        }
        let contents = fs::read(path)?;
        update_codex_skill_digest(&mut hasher, &digest_path, &contents);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub(super) fn parse_codex_plugin_listing(stdout: &[u8]) -> Result<Option<CodexPluginListing>> {
    let value: Value = serde_json::from_slice(stdout).map_err(|error| {
        PetCoreError::Validation(format!("codex plugin list --json 返回了无效 JSON：{error}"))
    })?;
    let installed = value
        .get("installed")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            PetCoreError::Validation("codex plugin list --json 缺少 installed 数组".to_string())
        })?;
    Ok(installed.iter().find_map(|plugin| {
        let id_matches =
            plugin.get("pluginId").and_then(Value::as_str) == Some("agent-pet-companion@personal");
        let name_matches = plugin.get("name").and_then(Value::as_str)
            == Some("agent-pet-companion")
            && plugin.get("marketplaceName").and_then(Value::as_str) == Some("personal");
        (id_matches || name_matches).then(|| CodexPluginListing {
            installed: plugin
                .get("installed")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            enabled: plugin
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            version: plugin
                .get("version")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            source_path: plugin
                .pointer("/source/path")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        })
    }))
}

pub(super) fn read_codex_plugin_listing(codex: &Path) -> Result<Option<CodexPluginListing>> {
    let output = run_bounded(ProcessSpec::connector(codex, ["plugin", "list", "--json"]))?;
    if output.timed_out || !output.status.success() {
        return Err(PetCoreError::Validation(format!(
            "codex plugin list --json 未成功完成（timed_out={}, exit={:?}）",
            output.timed_out,
            output.status.code()
        )));
    }
    parse_codex_plugin_listing(&output.stdout)
}

pub(super) fn probe_codex_active_plugin(
    source_root: &Path,
    connector_cli: &Path,
    codex: &Path,
) -> Result<CodexActivePluginProbe> {
    let expected_version = expected_codex_plugin_version()?;
    let expected_skills_sha256 = expected_codex_skill_bundle_sha256();
    let expected_content_sha256 = expected_codex_plugin_content_sha256(connector_cli)?;
    let expected_studio_skill_sha256 = hex::encode(Sha256::digest(PET_STUDIO_SKILL_MD.as_bytes()));
    let managed_source_content_sha256 = codex_plugin_content_sha256(source_root).ok();
    let managed_source_studio_skill_sha256 = safe_regular_file_sha256(
        source_root,
        &source_root.join("skills/agent-pet-studio/SKILL.md"),
    );
    let listing = read_codex_plugin_listing(codex)?;
    let active_version = listing.as_ref().and_then(|plugin| plugin.version.clone());
    let expected_source = source_root.display().to_string();
    let source_matches = listing
        .as_ref()
        .and_then(|plugin| plugin.source_path.as_deref())
        == Some(expected_source.as_str());
    let installed_and_enabled = listing
        .as_ref()
        .is_some_and(|plugin| plugin.installed && plugin.enabled);
    let version_matches = active_version.as_deref() == Some(expected_version.as_str());

    let cache_root = codex_active_cache_root(&expected_version);
    let cache_manifest_matches =
        check_codex_plugin_manifest(&cache_root.join(".codex-plugin/plugin.json"), &cache_root)
            .status
            == CheckStatus::Ok;
    let cache_hooks_match = check_codex_hooks(
        &cache_root.join("hooks/hooks.json"),
        connector_cli,
        &cache_root,
    )
    .status
        == CheckStatus::Ok;
    let cache_studio_matches = check_codex_studio_skill(
        &cache_root.join("skills/agent-pet-studio/SKILL.md"),
        &cache_root,
    )
    .status
        == CheckStatus::Ok;
    let cache_maker_matches = check_codex_agent_pet_maker(&cache_root).status == CheckStatus::Ok;
    let active_skills_sha256 = codex_skill_bundle_sha256(&cache_root).ok();
    let active_content_sha256 = codex_plugin_content_sha256(&cache_root).ok();
    let active_studio_skill_sha256 = safe_regular_file_sha256(
        &cache_root,
        &cache_root.join("skills/agent-pet-studio/SKILL.md"),
    );
    let skill_digest_matches =
        active_skills_sha256.as_deref() == Some(expected_skills_sha256.as_str());
    let source_content_matches =
        managed_source_content_sha256.as_deref() == Some(expected_content_sha256.as_str());
    let active_content_matches = active_content_sha256.as_deref()
        == managed_source_content_sha256.as_deref()
        && active_content_sha256.as_deref() == Some(expected_content_sha256.as_str());
    let studio_digest_matches = managed_source_studio_skill_sha256.as_deref()
        == Some(expected_studio_skill_sha256.as_str())
        && active_studio_skill_sha256.as_deref() == Some(expected_studio_skill_sha256.as_str());
    let exact = installed_and_enabled
        && source_matches
        && version_matches
        && source_content_matches
        && cache_manifest_matches
        && cache_hooks_match
        && cache_studio_matches
        && cache_maker_matches
        && skill_digest_matches
        && active_content_matches
        && studio_digest_matches;

    let detail = if exact {
        format!(
            "Codex 已启用插件 {expected_version}，活动缓存与 Skills SHA-256 {} 一致",
            &expected_skills_sha256[..12]
        )
    } else if listing.is_none() {
        "Codex 未报告已安装的 Agent Pet Companion 插件".to_string()
    } else if !installed_and_enabled {
        "Codex 插件存在但未同时处于 installed/enabled 状态".to_string()
    } else if !source_matches {
        "Codex 同名插件来源不是 Agent Pet Companion 管理源；拒绝覆盖".to_string()
    } else if !source_content_matches {
        "Agent Pet Companion 管理的 Codex 插件源内容摘要不匹配".to_string()
    } else if !version_matches {
        format!(
            "Codex 活动插件版本不匹配（期望 {expected_version}，实际 {}）",
            active_version.as_deref().unwrap_or("unknown")
        )
    } else if !skill_digest_matches {
        format!(
            "Codex 活动缓存中的宠物制作 Skills 摘要不匹配（期望 {}，实际 {}）",
            &expected_skills_sha256[..12],
            active_skills_sha256
                .as_deref()
                .map(|digest| &digest[..12])
                .unwrap_or("missing")
        )
    } else if !active_content_matches {
        format!(
            "Codex 活动缓存内容摘要不匹配（期望 {}，实际 {}）",
            &expected_content_sha256[..12],
            active_content_sha256
                .as_deref()
                .map(|digest| &digest[..12])
                .unwrap_or("missing")
        )
    } else {
        "Codex 活动缓存的 manifest、hooks 或 Skill 文件未通过精确复检".to_string()
    };

    Ok(CodexActivePluginProbe {
        expected_version,
        active_version,
        expected_skills_sha256,
        active_skills_sha256,
        expected_content_sha256,
        managed_source_content_sha256,
        active_content_sha256,
        expected_studio_skill_sha256,
        managed_source_studio_skill_sha256,
        active_studio_skill_sha256,
        managed_source: listing.is_none() || source_matches,
        exact,
        detail,
    })
}

pub(super) fn check_codex_plugin_installed(
    paths: &AppPaths,
    install_root: &Path,
) -> (ConnectionCheckItem, Option<CodexActivePluginProbe>) {
    let Some(codex) = codex_command_path() else {
        return (
            ConnectionCheckItem::new(
                CheckCode::HostVerification,
                "Codex 插件安装",
                CheckStatus::Missing,
                "未检测到 codex 命令",
                Some(RecoveryAction::Recheck),
            ),
            None,
        );
    };

    if absolute_env_path("APC_AGENT_CONFIG_HOME").is_some() {
        return (
            ConnectionCheckItem::new(
                CheckCode::HostVerification,
                "Codex 插件安装",
                CheckStatus::NeedsFix,
                "测试环境跳过 codex plugin add",
                Some(RecoveryAction::Recheck),
            ),
            None,
        );
    }

    let connector_cli = connector_cli_path(paths);
    let probe = probe_codex_active_plugin(install_root, &connector_cli, &codex);
    let installed = probe.as_ref().is_ok_and(|probe| probe.exact);
    let detail = match probe.as_ref() {
        Ok(probe) => probe.detail.clone(),
        Err(error) => error.to_string(),
    };

    (
        ConnectionCheckItem::new(
            CheckCode::HostVerification,
            "Codex 插件安装",
            if installed {
                CheckStatus::Ok
            } else {
                CheckStatus::NeedsFix
            },
            if installed {
                detail
            } else {
                format!("{detail}；待更新并重新验证 Codex 插件")
            },
            Some(RecoveryAction::Recheck),
        ),
        probe.ok(),
    )
}

pub(super) fn check_codex_plugin_installed_light(install_root: &Path) -> ConnectionCheckItem {
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

pub(super) fn check_codex_app_server() -> ConnectionCheckItem {
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

pub(super) fn check_codex_app_server_light() -> ConnectionCheckItem {
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

#[cfg(test)]
pub(super) fn codex_plugin_json_reports_installed(stdout: &[u8]) -> Option<bool> {
    parse_codex_plugin_listing(stdout)
        .ok()
        .map(|plugin| plugin.is_some_and(|plugin| plugin.installed && plugin.enabled))
}

pub(super) fn codex_plugin_json_reports_present(stdout: &[u8]) -> Option<bool> {
    parse_codex_plugin_listing(stdout)
        .ok()
        .map(|plugin| plugin.is_some_and(|plugin| plugin.installed))
}

#[cfg(test)]
pub(super) fn codex_plugin_text_reports_installed(stdout: &str) -> bool {
    stdout.lines().any(|line| {
        line.contains("agent-pet-companion@personal")
            && line.contains("installed")
            && line.contains("enabled")
    })
}

pub(super) fn codex_plugin_text_reports_present(stdout: &str) -> bool {
    stdout.lines().any(|line| {
        line.contains("agent-pet-companion@personal")
            && line.contains("installed")
            && !line.contains("not installed")
    })
}

pub(super) fn codex_command_path() -> Option<PathBuf> {
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

pub(super) fn codex_manifest_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && read_regular_json_config(path).is_some_and(|value| {
            value.get("name").and_then(Value::as_str) == Some("agent-pet-companion")
                && value.get("hooks").and_then(Value::as_str) == Some("./hooks/hooks.json")
                && value.get("skills").and_then(Value::as_str) == Some("./skills/")
        })
}

pub(super) fn codex_hooks_are_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("--source codex")
                && content.contains("agent hook")
                && content.contains("\"hooks\"")
        })
}

pub(super) fn verified_codex_install_studio_sha256(root: &Path) -> Option<String> {
    let result_path = root.join("codex-install-result.json");
    if managed_regular_file_state(root, &result_path) != ManagedPathState::Safe {
        return None;
    }
    let result: CodexVerifiedInstallResult =
        serde_json::from_value(read_regular_json_config(&result_path)?).ok()?;
    if result.schema_version != CODEX_INSTALL_RESULT_SCHEMA
        || result.status != "ok"
        || result.phase != "active_cache_verified"
        || result.expected_version != result.active_version
        || result.expected_skills_sha256 != result.active_skills_sha256
        || result.expected_content_sha256 != result.managed_source_content_sha256
        || result.expected_content_sha256 != result.active_content_sha256
        || result.expected_studio_skill_sha256 != result.managed_source_studio_skill_sha256
        || result.expected_studio_skill_sha256 != result.active_studio_skill_sha256
        || ![
            &result.expected_skills_sha256,
            &result.expected_content_sha256,
            &result.expected_studio_skill_sha256,
        ]
        .into_iter()
        .all(|digest| is_lowercase_sha256(digest))
    {
        return None;
    }
    let manifest = read_regular_json_config(&root.join(".codex-plugin/plugin.json"))?;
    if manifest.get("version").and_then(Value::as_str) != Some(result.expected_version.as_str()) {
        return None;
    }
    let cache_root = codex_active_cache_root(&result.expected_version);
    let cache_manifest = read_regular_json_config(&cache_root.join(".codex-plugin/plugin.json"))?;
    if cache_manifest.get("version").and_then(Value::as_str)
        != Some(result.expected_version.as_str())
        || safe_regular_file_sha256(
            &cache_root,
            &cache_root.join("skills/agent-pet-studio/SKILL.md"),
        )
        .as_deref()
            != Some(result.expected_studio_skill_sha256.as_str())
    {
        return None;
    }
    Some(result.expected_studio_skill_sha256)
}

/// Ownership of the Studio Skill is proven by content this App can derive right
/// now: the exact current Skill, or the revision named by a verified install
/// receipt. A list of retired digests would have to be extended on every
/// release and silently strands installs whenever an entry goes missing, so the
/// managed root's own manifest and hooks carry the structural ownership proof
/// instead — see `validate_codex_root_repair_ownership`.
pub(super) fn codex_studio_skill_is_owned(path: &Path, root: &Path) -> bool {
    managed_regular_file_state(root, path) == ManagedPathState::Safe
        && fs::read(path).is_ok_and(|content| {
            content == PET_STUDIO_SKILL_MD.as_bytes()
                || verified_codex_install_studio_sha256(root).as_deref()
                    == Some(hex::encode(Sha256::digest(&content)).as_str())
        })
}

pub(super) fn codex_maker_skill_is_owned(root: &Path) -> bool {
    let path = root.join("skills/agent-pet-maker/SKILL.md");
    managed_regular_file_state(root, &path) == ManagedPathState::Safe
        && fs::read_to_string(path).is_ok_and(|content| {
            content.contains("agent-pet-maker") && content.contains("Agent Pet Companion")
        })
}

pub(super) fn codex_marketplace_path() -> PathBuf {
    agent_home()
        .join(".agents")
        .join("plugins")
        .join("marketplace.json")
}

pub(super) fn codex_plugin_source_root() -> PathBuf {
    agent_home()
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
}

pub(super) fn codex_marketplace_plugin_source_path() -> String {
    let root = codex_plugin_source_root();
    let home = user_home();
    root.strip_prefix(&home)
        .ok()
        .map(|relative| format!("./{}", relative.display()))
        .unwrap_or_else(|| root.display().to_string())
}

pub(super) fn ensure_codex_marketplace_entry() -> Result<()> {
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

pub(super) fn remove_codex_marketplace_entry() -> Result<()> {
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

pub(super) fn default_codex_marketplace() -> Value {
    json!({
        "name": "personal",
        "interface": {
            "displayName": "Personal"
        },
        "plugins": []
    })
}

pub(super) fn install_codex_plugin_if_possible(
    root: &Path,
    connector_cli: &Path,
) -> Result<CodexPluginInstallAttempt> {
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
        return Ok(CodexPluginInstallAttempt::SkippedHermetic);
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
        return Ok(CodexPluginInstallAttempt::HostMissing);
    };

    let output = match run_bounded(ProcessSpec::connector(
        &codex,
        ["plugin", "add", "agent-pet-companion@personal", "--json"],
    )) {
        Ok(output) => output,
        Err(error) => {
            write_managed_file_atomic(
                &result_path,
                &serde_json::to_vec_pretty(&json!({
                    "status": "failed",
                    "phase": "plugin_add",
                    "error": error.to_string()
                }))?,
                0o644,
            )?;
            return Err(error);
        }
    };
    if output.timed_out || !output.status.success() {
        write_managed_file_atomic(
            &result_path,
            &serde_json::to_vec_pretty(&json!({
                "status": "failed",
                "phase": "plugin_add",
                "code": output.status.code(),
                "timed_out": output.timed_out,
                "stdout_truncated": output.stdout_truncated,
                "stderr_truncated": output.stderr_truncated
            }))?,
            0o644,
        )?;
        return Err(PetCoreError::Validation(format!(
            "codex plugin add 未成功完成（timed_out={}, exit={:?}）",
            output.timed_out,
            output.status.code()
        )));
    }

    let probe = match probe_codex_active_plugin(root, connector_cli, &codex) {
        Ok(probe) => probe,
        Err(error) => {
            write_managed_file_atomic(
                &result_path,
                &serde_json::to_vec_pretty(&json!({
                    "status": "failed",
                    "phase": "active_cache_verification",
                    "error": error.to_string()
                }))?,
                0o644,
            )?;
            return Err(error);
        }
    };
    if !probe.exact {
        write_managed_file_atomic(
            &result_path,
            &serde_json::to_vec_pretty(&json!({
                "schema_version": CODEX_INSTALL_RESULT_SCHEMA,
                "status": "failed",
                "phase": "active_cache_verification",
                "expected_version": probe.expected_version,
                "active_version": probe.active_version,
                "expected_skills_sha256": probe.expected_skills_sha256,
                "active_skills_sha256": probe.active_skills_sha256,
                "expected_content_sha256": probe.expected_content_sha256,
                "managed_source_content_sha256": probe.managed_source_content_sha256,
                "active_content_sha256": probe.active_content_sha256,
                "expected_studio_skill_sha256": probe.expected_studio_skill_sha256,
                "managed_source_studio_skill_sha256": probe.managed_source_studio_skill_sha256,
                "active_studio_skill_sha256": probe.active_studio_skill_sha256,
                "detail": probe.detail
            }))?,
            0o644,
        )?;
        if !probe.managed_source {
            return Err(PetCoreError::Conflict(
                "Codex 同名插件来自非 Agent Pet Companion 管理源；已保留且拒绝覆盖".to_string(),
            ));
        }
        return Err(PetCoreError::Validation(format!(
            "codex plugin add 未激活当前插件缓存：{}",
            probe.detail
        )));
    }
    write_managed_file_atomic(
        &result_path,
        &serde_json::to_vec_pretty(&json!({
            "schema_version": CODEX_INSTALL_RESULT_SCHEMA,
            "status": "ok",
            "phase": "active_cache_verified",
            "expected_version": probe.expected_version,
            "active_version": probe.active_version,
            "expected_skills_sha256": probe.expected_skills_sha256,
            "active_skills_sha256": probe.active_skills_sha256,
            "expected_content_sha256": probe.expected_content_sha256,
            "managed_source_content_sha256": probe.managed_source_content_sha256,
            "active_content_sha256": probe.active_content_sha256,
            "expected_studio_skill_sha256": probe.expected_studio_skill_sha256,
            "managed_source_studio_skill_sha256": probe.managed_source_studio_skill_sha256,
            "active_studio_skill_sha256": probe.active_studio_skill_sha256
        }))?,
        0o644,
    )?;
    Ok(CodexPluginInstallAttempt::InstalledAndVerified)
}

pub(super) fn codex_plugin_installation_state(codex: &Path) -> Option<bool> {
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

pub(super) fn uninstall_codex_plugin_if_possible() -> Result<()> {
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

#[cfg(test)]
mod contract_tests {
    use super::*;

    #[test]
    fn codex_adapter_contract_has_exact_local_and_app_server_event_pairs() {
        assert_eq!(
            CODEX_LOCAL_HOOK_EVENTS.len(),
            CODEX_APP_SERVER_HOOK_EVENTS.len()
        );
        assert!(CODEX_HOOKS_TEMPLATE.contains("__APC_CLI__ agent hook --source codex"));
        assert!(CODEX_PLUGIN_JSON.contains("agent-pet-companion"));
        assert_eq!(CODEX_TASK_START_EVENTS, &["UserPromptSubmit"]);
        assert!(CODEX_TASK_COMPLETION_EVENTS.contains(&"Stop"));
    }
}
