use crate::paths::AppPaths;
use crate::{PetCoreError, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

const SKILL_NAME: &str = "agent-pet-maker";
const SKILL_DISPLAY_PATH: &str = "~/agent/skills/agent-pet-maker";
const RECEIPT_SCHEMA: &str = "apc.portable-skill-install.v1";
const STATUS_SCHEMA: &str = "apc.portable-skill-status.v1";
const RECEIPT_FILE_NAME: &str = "agent-pet-maker.json";
const MAX_RECEIPT_BYTES: u64 = 64 * 1024;

#[derive(Clone, Copy)]
struct BundledSkillFile {
    relative_path: &'static str,
    content: &'static str,
    mode: u32,
}

const BUNDLED_SKILL_FILES: &[BundledSkillFile] = &[
    BundledSkillFile {
        relative_path: "SKILL.md",
        content: include_str!("../../../skills/agent-pet-maker/SKILL.md"),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "agents/openai.yaml",
        content: include_str!("../../../skills/agent-pet-maker/agents/openai.yaml"),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "references/create-modify.md",
        content: include_str!("../../../skills/agent-pet-maker/references/create-modify.md"),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "references/dreamina-high-production.md",
        content: include_str!(
            "../../../skills/agent-pet-maker/references/dreamina-high-production.md"
        ),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "references/petpack-v3.md",
        content: include_str!("../../../skills/agent-pet-maker/references/petpack-v3.md"),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "references/security.md",
        content: include_str!("../../../skills/agent-pet-maker/references/security.md"),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "references/transparent-frame-production.md",
        content: include_str!(
            "../../../skills/agent-pet-maker/references/transparent-frame-production.md"
        ),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "references/visual-production-and-native-resolution.md",
        content: include_str!(
            "../../../skills/agent-pet-maker/references/visual-production-and-native-resolution.md"
        ),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "scripts/petpack_workspace.py",
        content: include_str!("../../../skills/agent-pet-maker/scripts/petpack_workspace.py"),
        mode: 0o755,
    },
    BundledSkillFile {
        relative_path: "scripts/prepare_transparent_frames.py",
        content: include_str!(
            "../../../skills/agent-pet-maker/scripts/prepare_transparent_frames.py"
        ),
        mode: 0o755,
    },
    BundledSkillFile {
        relative_path: "tests/test_petpack_workspace.py",
        content: include_str!("../../../skills/agent-pet-maker/tests/test_petpack_workspace.py"),
        mode: 0o644,
    },
    BundledSkillFile {
        relative_path: "tests/test_prepare_transparent_frames.py",
        content: include_str!(
            "../../../skills/agent-pet-maker/tests/test_prepare_transparent_frames.py"
        ),
        mode: 0o644,
    },
];

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PortableSkillState {
    Missing,
    Current,
    UpdateAvailable,
    NeedsReinstall,
    UnmanagedCurrent,
    Conflict,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PortableSkillStatus {
    pub schema_version: String,
    pub name: String,
    pub state: PortableSkillState,
    pub target_display_path: String,
    pub expected_version: String,
    pub installed_version: Option<String>,
    pub managed: bool,
    pub target_exists: bool,
    pub can_install: bool,
    pub can_update: bool,
    pub can_reinstall: bool,
    pub can_uninstall: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ManagedSkillReceipt {
    schema_version: String,
    name: String,
    target_display_path: String,
    installed_version: String,
    content_sha256: String,
}

enum ReceiptState {
    Missing,
    Valid(ManagedSkillReceipt),
    Invalid,
}

pub fn status(paths: &AppPaths) -> Result<PortableSkillStatus> {
    let home = user_home()?;
    status_at(&paths.home, &home)
}

pub fn install(paths: &AppPaths) -> Result<PortableSkillStatus> {
    let home = user_home()?;
    install_at(&paths.home, &home)
}

pub fn uninstall(paths: &AppPaths) -> Result<PortableSkillStatus> {
    let home = user_home()?;
    uninstall_at(&paths.home, &home)
}

fn user_home() -> Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| PetCoreError::Validation("user home is unavailable".to_string()))?;
    Ok(home)
}

fn status_at(app_home: &Path, home: &Path) -> Result<PortableSkillStatus> {
    let target = target_path(home);
    let receipt_state = read_receipt(&receipt_path(app_home))?;
    let target_metadata = fs::symlink_metadata(&target).ok();
    let target_exists = target_metadata.is_some();
    let parent_safe = managed_parent_is_safe(home)?;
    let expected_version = bundled_version()?;
    let expected_matches = target_metadata.as_ref().is_some_and(|metadata| {
        metadata.is_dir()
            && tree_matches_bundle(&target).unwrap_or(false)
            && tree_contains_only_bundle(&target).unwrap_or(false)
    });
    let target_installed_version = target_metadata
        .as_ref()
        .filter(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
        .and_then(|_| installed_version(&target));
    let installed_version = target_installed_version.or_else(|| match &receipt_state {
        ReceiptState::Valid(receipt) => Some(receipt.installed_version.clone()),
        ReceiptState::Missing | ReceiptState::Invalid => None,
    });

    let (state, managed) = match receipt_state {
        ReceiptState::Valid(_) if !parent_safe => (PortableSkillState::Conflict, true),
        ReceiptState::Valid(receipt) => {
            if expected_matches {
                (PortableSkillState::Current, true)
            } else if installed_version.as_deref() != Some(expected_version.as_str())
                || receipt.installed_version != expected_version
                || receipt.content_sha256 != bundled_content_sha256()
            {
                (PortableSkillState::UpdateAvailable, true)
            } else {
                (PortableSkillState::NeedsReinstall, true)
            }
        }
        ReceiptState::Invalid => (PortableSkillState::Conflict, false),
        ReceiptState::Missing if !parent_safe => (PortableSkillState::Conflict, false),
        ReceiptState::Missing if !target_exists => (PortableSkillState::Missing, false),
        ReceiptState::Missing if expected_matches && tree_contains_only_bundle(&target)? => {
            (PortableSkillState::UnmanagedCurrent, false)
        }
        ReceiptState::Missing => (PortableSkillState::Conflict, false),
    };

    Ok(PortableSkillStatus {
        schema_version: STATUS_SCHEMA.to_string(),
        name: SKILL_NAME.to_string(),
        state,
        target_display_path: SKILL_DISPLAY_PATH.to_string(),
        expected_version,
        installed_version,
        managed,
        target_exists,
        can_install: matches!(
            state,
            PortableSkillState::Missing | PortableSkillState::UnmanagedCurrent
        ),
        can_update: state == PortableSkillState::UpdateAvailable,
        can_reinstall: matches!(
            state,
            PortableSkillState::Current | PortableSkillState::NeedsReinstall
        ),
        can_uninstall: managed && state != PortableSkillState::Conflict,
    })
}

fn install_at(app_home: &Path, home: &Path) -> Result<PortableSkillStatus> {
    let current = status_at(app_home, home)?;
    if current.state == PortableSkillState::Conflict {
        return Err(PetCoreError::Conflict(
            "the portable skill target is not managed by Agent Pet Companion".to_string(),
        ));
    }

    let target = target_path(home);
    let skills_root = target.parent().ok_or_else(|| {
        PetCoreError::Validation("portable skill target has no parent".to_string())
    })?;
    ensure_managed_parent(home)?;

    // User-triggered installation establishes App ownership before replacement.
    // If a later filesystem write fails, the next explicit repair may still
    // replace the exact target instead of stranding a partial App installation.
    write_receipt(
        &receipt_path(app_home),
        &ManagedSkillReceipt {
            schema_version: RECEIPT_SCHEMA.to_string(),
            name: SKILL_NAME.to_string(),
            target_display_path: SKILL_DISPLAY_PATH.to_string(),
            installed_version: bundled_version()?,
            content_sha256: bundled_content_sha256(),
        },
    )?;

    let staging = skills_root.join(format!(
        ".agent-pet-maker.apc-stage-{}",
        uuid::Uuid::now_v7().simple()
    ));
    fs::create_dir(&staging)?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))?;
    if let Err(error) = write_skill_tree(&staging) {
        let _ = remove_entry(&staging);
        return Err(error);
    }

    let backup = skills_root.join(format!(
        ".agent-pet-maker.apc-backup-{}",
        uuid::Uuid::now_v7().simple()
    ));
    let had_target = fs::symlink_metadata(&target).is_ok();
    if had_target {
        if let Err(error) = fs::rename(&target, &backup) {
            let _ = remove_entry(&staging);
            return Err(error.into());
        }
    }
    if let Err(error) = fs::rename(&staging, &target) {
        if had_target {
            let _ = fs::rename(&backup, &target);
        }
        let _ = remove_entry(&staging);
        return Err(error.into());
    }
    if had_target {
        let _ = remove_entry(&backup);
    }

    status_at(app_home, home)
}

fn uninstall_at(app_home: &Path, home: &Path) -> Result<PortableSkillStatus> {
    let current = status_at(app_home, home)?;
    if !current.managed || current.state == PortableSkillState::Conflict {
        return Err(PetCoreError::Conflict(
            "the portable skill target is not managed by Agent Pet Companion".to_string(),
        ));
    }

    let target = target_path(home);
    if fs::symlink_metadata(&target).is_ok() {
        remove_entry(&target)?;
    }
    let receipt = receipt_path(app_home);
    match fs::remove_file(receipt) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    status_at(app_home, home)
}

fn target_path(home: &Path) -> PathBuf {
    home.join("agent").join("skills").join(SKILL_NAME)
}

fn receipt_path(app_home: &Path) -> PathBuf {
    app_home.join("managed-skills").join(RECEIPT_FILE_NAME)
}

fn bundled_version() -> Result<String> {
    parse_skill_version(BUNDLED_SKILL_FILES[0].content).ok_or_else(|| {
        PetCoreError::Validation("bundled agent-pet-maker version is invalid".to_string())
    })
}

fn parse_skill_version(content: &str) -> Option<String> {
    let mut delimiters = 0;
    for line in content.lines() {
        if line.trim() == "---" {
            delimiters += 1;
            if delimiters == 2 {
                break;
            }
            continue;
        }
        if delimiters == 1 {
            if let Some(value) = line.trim().strip_prefix("version:") {
                let version = value.trim().trim_matches(['\'', '"']);
                if !version.is_empty()
                    && version.len() <= 32
                    && version
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
                {
                    return Some(version.to_string());
                }
            }
        }
    }
    None
}

fn bundled_content_sha256() -> String {
    let mut files = BUNDLED_SKILL_FILES.iter().copied().collect::<Vec<_>>();
    files.sort_by_key(|file| file.relative_path);
    let mut hasher = Sha256::new();
    hasher.update(b"agent-pet-companion/portable-skill/v1\0");
    for file in files {
        hasher.update(file.relative_path.as_bytes());
        hasher.update(b"\0");
        hasher.update(file.mode.to_le_bytes());
        hasher.update(b"\0");
        hasher.update(file.content.as_bytes());
        hasher.update(b"\0");
    }
    hex::encode(hasher.finalize())
}

fn installed_version(target: &Path) -> Option<String> {
    let path = target.join("SKILL.md");
    let metadata = fs::symlink_metadata(&path).ok()?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 64 * 1024 {
        return None;
    }
    fs::read_to_string(path)
        .ok()
        .and_then(|content| parse_skill_version(&content))
}

fn managed_parent_is_safe(home: &Path) -> Result<bool> {
    if !plain_directory(home)? {
        return Ok(false);
    }
    for path in [home.join("agent"), home.join("agent").join("skills")] {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
            Ok(_) => return Ok(false),
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(true),
            Err(error) => return Err(error.into()),
        }
    }
    Ok(true)
}

fn ensure_managed_parent(home: &Path) -> Result<()> {
    if !plain_directory(home)? {
        return Err(PetCoreError::Conflict(
            "the user home is not a safe directory".to_string(),
        ));
    }
    for path in [home.join("agent"), home.join("agent").join("skills")] {
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
            Ok(_) => {
                return Err(PetCoreError::Conflict(
                    "the portable skill parent is not a safe directory".to_string(),
                ));
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {
                fs::create_dir(&path)?;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn plain_directory(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.is_dir() && !metadata.file_type().is_symlink()),
        Err(error) => Err(error.into()),
    }
}

fn write_skill_tree(root: &Path) -> Result<()> {
    for file in BUNDLED_SKILL_FILES {
        let destination = safe_join(root, file.relative_path)?;
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
        }
        let mut handle = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(file.mode)
            .open(&destination)?;
        handle.write_all(file.content.as_bytes())?;
        handle.sync_all()?;
        fs::set_permissions(destination, fs::Permissions::from_mode(file.mode))?;
    }
    Ok(())
}

fn safe_join(root: &Path, relative: &str) -> Result<PathBuf> {
    let relative = Path::new(relative);
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(PetCoreError::Validation(
            "portable skill contains an invalid managed path".to_string(),
        ));
    }
    Ok(root.join(relative))
}

fn tree_matches_bundle(target: &Path) -> Result<bool> {
    for file in BUNDLED_SKILL_FILES {
        let path = safe_join(target, file.relative_path)?;
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error.into()),
        };
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Ok(false);
        }
        let executable = metadata.permissions().mode() & 0o111 != 0;
        if executable != (file.mode & 0o111 != 0) || fs::read(path)? != file.content.as_bytes() {
            return Ok(false);
        }
    }
    Ok(true)
}

fn tree_contains_only_bundle(target: &Path) -> Result<bool> {
    let allowed_files = BUNDLED_SKILL_FILES
        .iter()
        .map(|file| file.relative_path.to_string())
        .collect::<BTreeSet<_>>();
    let mut allowed_directories = BTreeSet::new();
    for file in BUNDLED_SKILL_FILES {
        let mut parent = Path::new(file.relative_path).parent();
        while let Some(path) = parent {
            if !path.as_os_str().is_empty() {
                allowed_directories.insert(path.to_string_lossy().to_string());
            }
            parent = path.parent();
        }
    }

    let mut pending = vec![target.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let path = entry.path();
            let relative = path
                .strip_prefix(target)
                .map_err(|_| {
                    PetCoreError::Validation("portable skill path escaped its root".to_string())
                })?
                .to_string_lossy()
                .to_string();
            let metadata = fs::symlink_metadata(&path)?;
            if metadata.file_type().is_symlink() {
                return Ok(false);
            }
            if metadata.is_dir() {
                if !allowed_directories.contains(&relative) {
                    return Ok(false);
                }
                pending.push(path);
            } else if !metadata.is_file() || !allowed_files.contains(&relative) {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn read_receipt(path: &Path) -> Result<ReceiptState> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(ReceiptState::Missing),
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() == 0
        || metadata.len() > MAX_RECEIPT_BYTES
    {
        return Ok(ReceiptState::Invalid);
    }
    let receipt = match fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ManagedSkillReceipt>(&bytes).ok())
    {
        Some(receipt) => receipt,
        None => return Ok(ReceiptState::Invalid),
    };
    if receipt.schema_version != RECEIPT_SCHEMA
        || receipt.name != SKILL_NAME
        || receipt.target_display_path != SKILL_DISPLAY_PATH
        || receipt.installed_version.is_empty()
        || receipt.installed_version.len() > 32
        || receipt.content_sha256.len() != 64
        || !receipt
            .content_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Ok(ReceiptState::Invalid);
    }
    Ok(ReceiptState::Valid(receipt))
}

fn write_receipt(path: &Path, receipt: &ManagedSkillReceipt) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        PetCoreError::Validation("portable skill receipt has no parent".to_string())
    })?;
    ensure_private_directory(parent)?;
    let bytes = serde_json::to_vec_pretty(receipt)?;
    let temporary = parent.join(format!(
        ".agent-pet-maker.receipt-{}",
        uuid::Uuid::now_v7().simple()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&bytes)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(error.into());
    }
    Ok(())
}

fn ensure_private_directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => {
            return Err(PetCoreError::Conflict(
                "portable skill receipt directory is unsafe".to_string(),
            ));
        }
        Err(error) if error.kind() == ErrorKind::NotFound => fs::create_dir_all(path)?,
        Err(error) => return Err(error.into()),
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn remove_entry(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn install_reinstall_and_uninstall_manage_the_fixed_target() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(&home).unwrap();

        let initial = status_at(&app_home, &home).unwrap();
        assert_eq!(initial.state, PortableSkillState::Missing);
        assert!(!initial.managed);

        let installed = install_at(&app_home, &home).unwrap();
        assert_eq!(installed.state, PortableSkillState::Current);
        assert!(installed.managed);
        assert!(installed.can_reinstall);

        fs::write(target_path(&home).join("SKILL.md"), "locally changed\n").unwrap();
        fs::write(target_path(&home).join("local-note.txt"), "replace me").unwrap();
        let changed = status_at(&app_home, &home).unwrap();
        assert_eq!(changed.state, PortableSkillState::NeedsReinstall);
        assert!(changed.can_reinstall);

        let repaired = install_at(&app_home, &home).unwrap();
        assert_eq!(repaired.state, PortableSkillState::Current);
        assert!(tree_matches_bundle(&target_path(&home)).unwrap());
        assert!(!target_path(&home).join("local-note.txt").exists());

        fs::write(
            target_path(&home).join("extra-local-file.txt"),
            "replace me",
        )
        .unwrap();
        assert_eq!(
            status_at(&app_home, &home).unwrap().state,
            PortableSkillState::NeedsReinstall
        );
        assert_eq!(
            install_at(&app_home, &home).unwrap().state,
            PortableSkillState::Current
        );
        assert!(!target_path(&home).join("extra-local-file.txt").exists());

        let skill_path = target_path(&home).join("SKILL.md");
        let current_version_line = format!("version: {}", bundled_version().unwrap());
        let older = fs::read_to_string(&skill_path).unwrap().replacen(
            current_version_line.as_str(),
            "version: 0.0.0",
            1,
        );
        fs::write(&skill_path, older).unwrap();
        let outdated = status_at(&app_home, &home).unwrap();
        assert_eq!(outdated.state, PortableSkillState::UpdateAvailable);
        assert!(outdated.can_update);
        assert_eq!(
            install_at(&app_home, &home).unwrap().state,
            PortableSkillState::Current
        );

        fs::write(target_path(&home).join("delete-with-root.txt"), "delete me").unwrap();

        let removed = uninstall_at(&app_home, &home).unwrap();
        assert_eq!(removed.state, PortableSkillState::Missing);
        assert!(!target_path(&home).exists());
    }

    #[test]
    fn foreign_target_is_preserved_and_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        let target = target_path(&home);
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("foreign.txt"), "keep me").unwrap();

        let status = status_at(&app_home, &home).unwrap();
        assert_eq!(status.state, PortableSkillState::Conflict);
        assert!(install_at(&app_home, &home).is_err());
        assert_eq!(
            fs::read_to_string(target.join("foreign.txt")).unwrap(),
            "keep me"
        );
    }

    #[test]
    fn empty_unmanaged_target_is_preserved_as_a_conflict() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        let target = target_path(&home);
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(&target).unwrap();

        let status = status_at(&app_home, &home).unwrap();
        assert_eq!(status.state, PortableSkillState::Conflict);
        assert!(!status.can_install);
        assert!(install_at(&app_home, &home).is_err());
        assert!(target.is_dir());
    }

    #[test]
    fn unmanaged_root_symlink_is_not_followed_for_version_or_install() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        let outside = temp.path().join("outside");
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(home.join("agent/skills")).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(
            outside.join("SKILL.md"),
            "---\nversion: 99.99.99\n---\nexternal\n",
        )
        .unwrap();
        symlink(&outside, target_path(&home)).unwrap();

        let status = status_at(&app_home, &home).unwrap();
        assert_eq!(status.state, PortableSkillState::Conflict);
        assert_eq!(status.installed_version, None);
        assert!(install_at(&app_home, &home).is_err());
        assert_eq!(
            fs::read_to_string(outside.join("SKILL.md")).unwrap(),
            "---\nversion: 99.99.99\n---\nexternal\n"
        );
    }

    #[test]
    fn exact_unmanaged_bundle_can_be_adopted() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        let target = target_path(&home);
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(&target).unwrap();
        write_skill_tree(&target).unwrap();

        let status = status_at(&app_home, &home).unwrap();
        assert_eq!(status.state, PortableSkillState::UnmanagedCurrent);
        assert!(status.can_install);
        assert_eq!(
            install_at(&app_home, &home).unwrap().state,
            PortableSkillState::Current
        );
    }

    #[test]
    fn managed_root_symlink_is_replaced_without_following_it() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        let outside = temp.path().join("outside");
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("keep.txt"), "safe").unwrap();
        install_at(&app_home, &home).unwrap();

        fs::remove_dir_all(target_path(&home)).unwrap();
        symlink(&outside, target_path(&home)).unwrap();
        let status = status_at(&app_home, &home).unwrap();
        assert!(status.managed);
        assert_eq!(status.state, PortableSkillState::NeedsReinstall);

        let repaired = install_at(&app_home, &home).unwrap();
        assert_eq!(repaired.state, PortableSkillState::Current);
        assert_eq!(
            fs::read_to_string(outside.join("keep.txt")).unwrap(),
            "safe"
        );
        assert!(!fs::symlink_metadata(target_path(&home))
            .unwrap()
            .file_type()
            .is_symlink());
    }

    #[test]
    fn unsafe_parent_is_never_followed_for_managed_uninstall() {
        let temp = tempfile::tempdir().unwrap();
        let app_home = temp.path().join("app-home");
        let home = temp.path().join("user-home");
        let moved_agent_root = temp.path().join("moved-agent-root");
        fs::create_dir_all(&app_home).unwrap();
        fs::create_dir_all(&home).unwrap();
        install_at(&app_home, &home).unwrap();

        fs::rename(home.join("agent"), &moved_agent_root).unwrap();
        symlink(&moved_agent_root, home.join("agent")).unwrap();

        let status = status_at(&app_home, &home).unwrap();
        assert!(status.managed);
        assert_eq!(status.state, PortableSkillState::Conflict);
        assert!(uninstall_at(&app_home, &home).is_err());
        assert!(moved_agent_root.join("skills").join(SKILL_NAME).exists());
    }
}
