use crate::paths::AppPaths;
use crate::{PetCoreError, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

const SKILL_NAME: &str = "agent-pet-maker";
const SKILL_DISPLAY_PATH: &str = "~/agent/skills/agent-pet-maker";
const RECEIPT_SCHEMA: &str = "apc.portable-skill-install.v1";
const STATUS_SCHEMA: &str = "apc.portable-skill-status.v1";
const RECEIPT_FILE_NAME: &str = "agent-pet-maker.json";
const MAX_RECEIPT_BYTES: u64 = 64 * 1024;
const MAX_MANAGED_REMOVAL_ENTRIES: usize = 4096;

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct EntryIdentity {
    dev: u64,
    ino: u64,
    mode: rustix::fs::RawMode,
}

struct StatusInspection {
    status: PortableSkillStatus,
    skills_identity: Option<EntryIdentity>,
    target_identity: Option<EntryIdentity>,
}

enum DirectoryState {
    Missing,
    Unsafe,
    Ready(File),
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
    Ok(inspect_status_at(app_home, home)?.status)
}

fn inspect_status_at(app_home: &Path, home: &Path) -> Result<StatusInspection> {
    let receipt_state = read_receipt(&receipt_path(app_home))?;
    let expected_version = bundled_version()?;
    let (parent_safe, skills_identity, target_identity, expected_matches, target_installed_version) =
        match inspect_managed_parent(home)? {
            DirectoryState::Missing => (true, None, None, false, None),
            DirectoryState::Unsafe => (false, None, None, false, None),
            DirectoryState::Ready(skills) => {
                let skills_identity =
                    entry_identity(&rustix::fs::fstat(&skills).map_err(std::io::Error::from)?);
                let target_identity = entry_identity_at(&skills, Path::new(SKILL_NAME))?;
                let mut expected_matches = false;
                let mut observed_version = None;
                if let Some(identity) = target_identity {
                    if rustix::fs::FileType::from_raw_mode(identity.mode).is_dir() {
                        if let Some(target) =
                            open_directory_at(&skills, Path::new(SKILL_NAME), Some(identity))?
                        {
                            expected_matches = bundle_tree_matches_root(&target).unwrap_or(false);
                            observed_version = installed_version(&target);
                        }
                    }
                }
                (
                    true,
                    Some(skills_identity),
                    target_identity,
                    expected_matches,
                    observed_version,
                )
            }
        };
    let target_exists = target_identity.is_some();
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
        ReceiptState::Missing if expected_matches => (PortableSkillState::UnmanagedCurrent, false),
        ReceiptState::Missing => (PortableSkillState::Conflict, false),
    };

    Ok(StatusInspection {
        status: PortableSkillStatus {
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
        },
        skills_identity,
        target_identity,
    })
}

fn install_at(app_home: &Path, home: &Path) -> Result<PortableSkillStatus> {
    let inspection = inspect_status_at(app_home, home)?;
    if inspection.status.state == PortableSkillState::Conflict {
        return Err(PetCoreError::Conflict(
            "the portable skill target is not managed by Agent Pet Companion".to_string(),
        ));
    }

    let skills = ensure_managed_parent(home)?;
    let current_skills_identity =
        entry_identity(&rustix::fs::fstat(&skills).map_err(std::io::Error::from)?);
    if inspection
        .skills_identity
        .is_some_and(|expected| expected != current_skills_identity)
        || entry_identity_at(&skills, Path::new(SKILL_NAME))? != inspection.target_identity
    {
        return Err(PetCoreError::Conflict(
            "the portable skill target changed while it was being inspected".to_string(),
        ));
    }

    let receipt = ManagedSkillReceipt {
        schema_version: RECEIPT_SCHEMA.to_string(),
        name: SKILL_NAME.to_string(),
        target_display_path: SKILL_DISPLAY_PATH.to_string(),
        installed_version: bundled_version()?,
        content_sha256: bundled_content_sha256(),
    };
    if inspection.status.state == PortableSkillState::UnmanagedCurrent {
        let expected = inspection.target_identity.ok_or_else(|| {
            PetCoreError::Conflict("the portable skill target disappeared".to_string())
        })?;
        let Some(target) = open_directory_at(&skills, Path::new(SKILL_NAME), Some(expected))?
        else {
            return Err(PetCoreError::Conflict(
                "the portable skill target changed before adoption".to_string(),
            ));
        };
        if !bundle_tree_matches_root(&target)? {
            return Err(PetCoreError::Conflict(
                "the portable skill target changed before adoption".to_string(),
            ));
        }
        write_receipt(&receipt_path(app_home), &receipt)?;
        return status_at(app_home, home);
    }

    let staging_name = format!(
        ".agent-pet-maker.apc-stage-{}",
        uuid::Uuid::now_v7().simple()
    );
    rustix::fs::mkdirat(
        &skills,
        Path::new(&staging_name),
        rustix::fs::Mode::from_bits_truncate(0o700),
    )
    .map_err(std::io::Error::from)?;
    let staging = open_directory_at(&skills, Path::new(&staging_name), None)?.ok_or_else(|| {
        PetCoreError::Conflict("portable skill staging directory is unsafe".to_string())
    })?;
    if let Err(error) = write_skill_tree_at(&staging) {
        let _ = remove_entry_at(&skills, Path::new(&staging_name));
        return Err(error);
    }
    drop(staging);
    if let Err(error) = commit_staged_install(
        &skills,
        Path::new(&staging_name),
        inspection.target_identity,
        &receipt_path(app_home),
        &receipt,
    ) {
        let _ = remove_entry_at(&skills, Path::new(&staging_name));
        return Err(error);
    }

    status_at(app_home, home)
}

fn uninstall_at(app_home: &Path, home: &Path) -> Result<PortableSkillStatus> {
    let inspection = inspect_status_at(app_home, home)?;
    if !inspection.status.managed || inspection.status.state == PortableSkillState::Conflict {
        return Err(PetCoreError::Conflict(
            "the portable skill target is not managed by Agent Pet Companion".to_string(),
        ));
    }

    let DirectoryState::Ready(skills) = inspect_managed_parent(home)? else {
        return Err(PetCoreError::Conflict(
            "the portable skill parent changed while it was being inspected".to_string(),
        ));
    };
    let current_skills_identity =
        entry_identity(&rustix::fs::fstat(&skills).map_err(std::io::Error::from)?);
    if inspection.skills_identity != Some(current_skills_identity)
        || entry_identity_at(&skills, Path::new(SKILL_NAME))? != inspection.target_identity
    {
        return Err(PetCoreError::Conflict(
            "the portable skill target changed while it was being inspected".to_string(),
        ));
    }
    if let Some(expected) = inspection.target_identity {
        quarantine_and_remove_target_at(&skills, expected)?;
    }
    let receipt = receipt_path(app_home);
    match fs::remove_file(receipt) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    status_at(app_home, home)
}

#[cfg(test)]
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
    let mut files = BUNDLED_SKILL_FILES.to_vec();
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

fn entry_identity(metadata: &rustix::fs::Stat) -> EntryIdentity {
    EntryIdentity {
        // Darwin exposes dev_t as a signed integer while Linux uses u64.
        #[allow(clippy::unnecessary_cast)]
        dev: metadata.st_dev as u64,
        ino: metadata.st_ino,
        mode: metadata.st_mode,
    }
}

fn entry_identity_at(parent: &File, name: &Path) -> Result<Option<EntryIdentity>> {
    match rustix::fs::statat(parent, name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW) {
        Ok(metadata) => Ok(Some(entry_identity(&metadata))),
        Err(rustix::io::Errno::NOENT) => Ok(None),
        Err(error) => Err(std::io::Error::from(error).into()),
    }
}

fn open_directory_at(
    parent: &File,
    name: &Path,
    expected: Option<EntryIdentity>,
) -> Result<Option<File>> {
    let Some(observed) = entry_identity_at(parent, name)? else {
        return Ok(None);
    };
    if expected.is_some_and(|expected| expected != observed)
        || !rustix::fs::FileType::from_raw_mode(observed.mode).is_dir()
    {
        return Ok(None);
    }
    let descriptor = match rustix::fs::openat(
        parent,
        name,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::DIRECTORY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    ) {
        Ok(descriptor) => descriptor,
        Err(_) => return Ok(None),
    };
    let opened = entry_identity(&rustix::fs::fstat(&descriptor).map_err(std::io::Error::from)?);
    if opened != observed || !rustix::fs::FileType::from_raw_mode(opened.mode).is_dir() {
        return Ok(None);
    }
    Ok(Some(File::from(descriptor)))
}

fn read_bounded_regular_file_at(
    parent: &File,
    name: &Path,
    maximum_bytes: u64,
) -> Result<Option<Vec<u8>>> {
    let Some(observed) = entry_identity_at(parent, name)? else {
        return Ok(None);
    };
    let observed_stat = rustix::fs::statat(parent, name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW)
        .map_err(std::io::Error::from)?;
    if entry_identity(&observed_stat) != observed
        || !rustix::fs::FileType::from_raw_mode(observed.mode).is_file()
        || observed_stat.st_size < 0
        || u64::try_from(observed_stat.st_size).unwrap_or(u64::MAX) > maximum_bytes
    {
        return Ok(None);
    }
    let descriptor = match rustix::fs::openat(
        parent,
        name,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    ) {
        Ok(descriptor) => descriptor,
        Err(_) => return Ok(None),
    };
    let opened_stat = rustix::fs::fstat(&descriptor).map_err(std::io::Error::from)?;
    if entry_identity(&opened_stat) != observed
        || opened_stat.st_size != observed_stat.st_size
        || opened_stat.st_size < 0
        || u64::try_from(opened_stat.st_size).unwrap_or(u64::MAX) > maximum_bytes
    {
        return Ok(None);
    }
    let mut handle = File::from(descriptor);
    let mut bytes = Vec::with_capacity(
        usize::try_from(opened_stat.st_size)
            .unwrap_or(0)
            .min(maximum_bytes as usize),
    );
    (&mut handle)
        .take(maximum_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    let final_stat = rustix::fs::fstat(&handle).map_err(std::io::Error::from)?;
    if bytes.len() as u64 > maximum_bytes
        || entry_identity(&final_stat) != observed
        || final_stat.st_size != opened_stat.st_size
    {
        return Ok(None);
    }
    Ok(Some(bytes))
}

fn replace_target_at(
    skills: &File,
    staging_name: &Path,
    expected_target: Option<EntryIdentity>,
) -> Result<()> {
    if expected_target.is_none() {
        return rustix::fs::renameat_with(
            skills,
            staging_name,
            skills,
            Path::new(SKILL_NAME),
            rustix::fs::RenameFlags::NOREPLACE,
        )
        .map_err(std::io::Error::from)
        .map_err(Into::into);
    }
    let expected_target = expected_target.unwrap();
    let backup_name = format!(
        ".agent-pet-maker.apc-backup-{}",
        uuid::Uuid::now_v7().simple()
    );
    rustix::fs::renameat_with(
        skills,
        Path::new(SKILL_NAME),
        skills,
        Path::new(&backup_name),
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(std::io::Error::from)?;
    if entry_identity_at(skills, Path::new(&backup_name))? != Some(expected_target) {
        let _ = rustix::fs::renameat_with(
            skills,
            Path::new(&backup_name),
            skills,
            Path::new(SKILL_NAME),
            rustix::fs::RenameFlags::NOREPLACE,
        );
        return Err(PetCoreError::Conflict(
            "the portable skill target changed before replacement".to_string(),
        ));
    }
    if let Err(error) = rustix::fs::renameat_with(
        skills,
        staging_name,
        skills,
        Path::new(SKILL_NAME),
        rustix::fs::RenameFlags::NOREPLACE,
    ) {
        let _ = rustix::fs::renameat_with(
            skills,
            Path::new(&backup_name),
            skills,
            Path::new(SKILL_NAME),
            rustix::fs::RenameFlags::NOREPLACE,
        );
        return Err(std::io::Error::from(error).into());
    }
    let _ = remove_entry_at_checked(skills, Path::new(&backup_name), expected_target);
    Ok(())
}

fn commit_staged_install(
    skills: &File,
    staging_name: &Path,
    expected_target: Option<EntryIdentity>,
    receipt_path: &Path,
    receipt: &ManagedSkillReceipt,
) -> Result<()> {
    replace_target_at(skills, staging_name, expected_target)?;
    write_receipt(receipt_path, receipt)
}

fn quarantine_and_remove_target_at(skills: &File, expected_target: EntryIdentity) -> Result<()> {
    let quarantine_name = format!(
        ".agent-pet-maker.apc-remove-{}",
        uuid::Uuid::now_v7().simple()
    );
    rustix::fs::renameat_with(
        skills,
        Path::new(SKILL_NAME),
        skills,
        Path::new(&quarantine_name),
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(std::io::Error::from)?;
    if entry_identity_at(skills, Path::new(&quarantine_name))? != Some(expected_target) {
        let _ = rustix::fs::renameat_with(
            skills,
            Path::new(&quarantine_name),
            skills,
            Path::new(SKILL_NAME),
            rustix::fs::RenameFlags::NOREPLACE,
        );
        return Err(PetCoreError::Conflict(
            "the portable skill target changed before removal".to_string(),
        ));
    }
    remove_entry_at_checked(skills, Path::new(&quarantine_name), expected_target)
}

fn installed_version(target: &File) -> Option<String> {
    read_bounded_regular_file_at(target, Path::new("SKILL.md"), 64 * 1024)
        .ok()
        .flatten()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .and_then(|content| parse_skill_version(&content))
}

fn inspect_managed_parent(home: &Path) -> Result<DirectoryState> {
    let descriptor = match rustix::fs::open(
        home,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::DIRECTORY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    ) {
        Ok(descriptor) => descriptor,
        Err(_) => return Ok(DirectoryState::Unsafe),
    };
    let mut directory = File::from(descriptor);
    for component in ["agent", "skills"] {
        let Some(identity) = entry_identity_at(&directory, Path::new(component))? else {
            return Ok(DirectoryState::Missing);
        };
        if !rustix::fs::FileType::from_raw_mode(identity.mode).is_dir() {
            return Ok(DirectoryState::Unsafe);
        }
        let Some(child) = open_directory_at(&directory, Path::new(component), Some(identity))?
        else {
            return Ok(DirectoryState::Unsafe);
        };
        directory = child;
    }
    Ok(DirectoryState::Ready(directory))
}

fn ensure_managed_parent(home: &Path) -> Result<File> {
    let descriptor = rustix::fs::open(
        home,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::DIRECTORY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| PetCoreError::Conflict("the user home is not a safe directory".to_string()))?;
    let mut directory = File::from(descriptor);
    for component in ["agent", "skills"] {
        let component = Path::new(component);
        if entry_identity_at(&directory, component)?.is_none() {
            match rustix::fs::mkdirat(
                &directory,
                component,
                rustix::fs::Mode::from_bits_truncate(0o700),
            ) {
                Ok(()) | Err(rustix::io::Errno::EXIST) => {}
                Err(error) => return Err(std::io::Error::from(error).into()),
            }
        }
        let Some(identity) = entry_identity_at(&directory, component)? else {
            return Err(PetCoreError::Conflict(
                "the portable skill parent changed while it was being created".to_string(),
            ));
        };
        if !rustix::fs::FileType::from_raw_mode(identity.mode).is_dir() {
            return Err(PetCoreError::Conflict(
                "the portable skill parent is not a safe directory".to_string(),
            ));
        }
        let Some(child) = open_directory_at(&directory, component, Some(identity))? else {
            return Err(PetCoreError::Conflict(
                "the portable skill parent changed while it was being opened".to_string(),
            ));
        };
        directory = child;
    }
    Ok(directory)
}

#[cfg(test)]
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

fn write_skill_tree_at(root: &File) -> Result<()> {
    for bundled in BUNDLED_SKILL_FILES {
        let relative = Path::new(bundled.relative_path);
        let leaf = relative.file_name().ok_or_else(|| {
            PetCoreError::Validation("portable skill contains an empty managed path".to_string())
        })?;
        let mut directory = root.try_clone()?;
        if let Some(parent) = relative.parent() {
            for component in parent.components() {
                let Component::Normal(name) = component else {
                    return Err(PetCoreError::Validation(
                        "portable skill contains an invalid managed path".to_string(),
                    ));
                };
                let name = Path::new(name);
                if entry_identity_at(&directory, name)?.is_none() {
                    match rustix::fs::mkdirat(
                        &directory,
                        name,
                        rustix::fs::Mode::from_bits_truncate(0o700),
                    ) {
                        Ok(()) | Err(rustix::io::Errno::EXIST) => {}
                        Err(error) => return Err(std::io::Error::from(error).into()),
                    }
                }
                let Some(identity) = entry_identity_at(&directory, name)? else {
                    return Err(PetCoreError::Conflict(
                        "portable skill staging directory changed".to_string(),
                    ));
                };
                if !rustix::fs::FileType::from_raw_mode(identity.mode).is_dir() {
                    return Err(PetCoreError::Conflict(
                        "portable skill staging path is unsafe".to_string(),
                    ));
                }
                let Some(child) = open_directory_at(&directory, name, Some(identity))? else {
                    return Err(PetCoreError::Conflict(
                        "portable skill staging directory changed".to_string(),
                    ));
                };
                directory = child;
            }
        }
        let descriptor = rustix::fs::openat(
            &directory,
            Path::new(leaf),
            rustix::fs::OFlags::WRONLY
                | rustix::fs::OFlags::CREATE
                | rustix::fs::OFlags::EXCL
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::from_bits_truncate(bundled.mode as rustix::fs::RawMode),
        )
        .map_err(std::io::Error::from)?;
        let mut handle = File::from(descriptor);
        handle.write_all(bundled.content.as_bytes())?;
        handle.sync_all()?;
        rustix::fs::fchmod(
            &handle,
            rustix::fs::Mode::from_bits_truncate(bundled.mode as rustix::fs::RawMode),
        )
        .map_err(std::io::Error::from)?;
    }
    Ok(())
}

#[cfg(test)]
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

#[cfg(test)]
fn bundle_tree_matches(target: &Path) -> Result<bool> {
    let descriptor = match rustix::fs::open(
        target,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::DIRECTORY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    ) {
        Ok(descriptor) => descriptor,
        Err(_) => return Ok(false),
    };
    let root = File::from(descriptor);
    bundle_tree_matches_root(&root)
}

fn bundle_tree_matches_root(root: &File) -> Result<bool> {
    let opened = rustix::fs::fstat(root).map_err(std::io::Error::from)?;
    if !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_dir()
        || !tree_contains_only_bundle(root)?
    {
        return Ok(false);
    }
    tree_matches_bundle(root)
}

fn tree_matches_bundle(root: &File) -> Result<bool> {
    for file in BUNDLED_SKILL_FILES {
        if !regular_file_matches(
            root,
            file.relative_path,
            file.content.as_bytes(),
            file.mode & 0o111 != 0,
        )? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn regular_file_matches(
    root: &File,
    relative: &str,
    expected: &[u8],
    expected_executable: bool,
) -> Result<bool> {
    let components = Path::new(relative)
        .components()
        .map(|component| match component {
            Component::Normal(name) => Ok(name.to_os_string()),
            _ => Err(PetCoreError::Validation(
                "portable skill contains an invalid managed path".to_string(),
            )),
        })
        .collect::<Result<Vec<_>>>()?;
    let Some((leaf, parents)) = components.split_last() else {
        return Err(PetCoreError::Validation(
            "portable skill contains an empty managed path".to_string(),
        ));
    };
    let mut directory = root.try_clone()?;
    for component in parents {
        let observed = match rustix::fs::statat(
            &directory,
            Path::new(component),
            rustix::fs::AtFlags::SYMLINK_NOFOLLOW,
        ) {
            Ok(observed) => observed,
            Err(_) => return Ok(false),
        };
        if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_dir() {
            return Ok(false);
        }
        let descriptor = match rustix::fs::openat(
            &directory,
            Path::new(component),
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        ) {
            Ok(descriptor) => descriptor,
            Err(_) => return Ok(false),
        };
        let opened = rustix::fs::fstat(&descriptor).map_err(std::io::Error::from)?;
        if !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_dir()
            || observed.st_dev != opened.st_dev
            || observed.st_ino != opened.st_ino
        {
            return Ok(false);
        }
        directory = File::from(descriptor);
    }

    let observed = match rustix::fs::statat(
        &directory,
        Path::new(leaf),
        rustix::fs::AtFlags::SYMLINK_NOFOLLOW,
    ) {
        Ok(observed) => observed,
        Err(_) => return Ok(false),
    };
    if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_file()
        || u64::try_from(observed.st_size).unwrap_or(u64::MAX) != expected.len() as u64
        || (observed.st_mode & 0o111 != 0) != expected_executable
    {
        return Ok(false);
    }
    let descriptor = match rustix::fs::openat(
        &directory,
        Path::new(leaf),
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    ) {
        Ok(descriptor) => descriptor,
        Err(_) => return Ok(false),
    };
    let opened = rustix::fs::fstat(&descriptor).map_err(std::io::Error::from)?;
    if !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_file()
        || observed.st_dev != opened.st_dev
        || observed.st_ino != opened.st_ino
        || observed.st_size != opened.st_size
        || u64::try_from(opened.st_size).unwrap_or(u64::MAX) != expected.len() as u64
        || (opened.st_mode & 0o111 != 0) != expected_executable
    {
        return Ok(false);
    }
    let mut handle = File::from(descriptor);
    let mut observed = Vec::with_capacity(expected.len().saturating_add(1));
    (&mut handle)
        .take(expected.len() as u64 + 1)
        .read_to_end(&mut observed)?;
    let final_metadata = rustix::fs::fstat(&handle).map_err(std::io::Error::from)?;
    Ok(observed == expected
        && final_metadata.st_dev == opened.st_dev
        && final_metadata.st_ino == opened.st_ino
        && final_metadata.st_size == opened.st_size
        && final_metadata.st_mode == opened.st_mode)
}

fn tree_contains_only_bundle(root: &File) -> Result<bool> {
    let allowed_files = BUNDLED_SKILL_FILES
        .iter()
        .map(|file| PathBuf::from(file.relative_path))
        .collect::<BTreeSet<_>>();
    let mut allowed_directories = BTreeSet::new();
    for file in BUNDLED_SKILL_FILES {
        let mut parent = Path::new(file.relative_path).parent();
        while let Some(path) = parent {
            if !path.as_os_str().is_empty() {
                allowed_directories.insert(path.to_path_buf());
            }
            parent = path.parent();
        }
    }

    let entry_limit = allowed_files.len() + allowed_directories.len();
    let mut entry_count = 0usize;
    let mut pending = vec![(PathBuf::new(), root.try_clone()?)];
    while let Some((relative_parent, directory)) = pending.pop() {
        let mut entries = rustix::fs::Dir::read_from(&directory).map_err(std::io::Error::from)?;
        while let Some(entry) = entries.read() {
            let entry = entry.map_err(std::io::Error::from)?;
            let name = entry.file_name();
            if matches!(name.to_bytes(), b"." | b"..") {
                continue;
            }
            entry_count = entry_count.saturating_add(1);
            if entry_count > entry_limit {
                return Ok(false);
            }
            let name_path = Path::new(std::ffi::OsStr::from_bytes(name.to_bytes()));
            let relative = relative_parent.join(name_path);
            let observed = match rustix::fs::statat(
                &directory,
                name_path,
                rustix::fs::AtFlags::SYMLINK_NOFOLLOW,
            ) {
                Ok(observed) => observed,
                Err(_) => return Ok(false),
            };
            let file_type = rustix::fs::FileType::from_raw_mode(observed.st_mode);
            if file_type.is_dir() {
                if !allowed_directories.contains(&relative) {
                    return Ok(false);
                }
                let descriptor = match rustix::fs::openat(
                    &directory,
                    name_path,
                    rustix::fs::OFlags::RDONLY
                        | rustix::fs::OFlags::DIRECTORY
                        | rustix::fs::OFlags::NOFOLLOW
                        | rustix::fs::OFlags::CLOEXEC,
                    rustix::fs::Mode::empty(),
                ) {
                    Ok(descriptor) => descriptor,
                    Err(_) => return Ok(false),
                };
                let opened = rustix::fs::fstat(&descriptor).map_err(std::io::Error::from)?;
                if !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_dir()
                    || observed.st_dev != opened.st_dev
                    || observed.st_ino != opened.st_ino
                {
                    return Ok(false);
                }
                pending.push((relative, File::from(descriptor)));
            } else if !file_type.is_file() || !allowed_files.contains(&relative) {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn read_receipt(path: &Path) -> Result<ReceiptState> {
    let descriptor = match rustix::fs::open(
        path,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    ) {
        Ok(descriptor) => descriptor,
        Err(rustix::io::Errno::NOENT) => return Ok(ReceiptState::Missing),
        Err(_) => return Ok(ReceiptState::Invalid),
    };
    let opened = rustix::fs::fstat(&descriptor).map_err(std::io::Error::from)?;
    if !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_file()
        || opened.st_size <= 0
        || u64::try_from(opened.st_size).unwrap_or(u64::MAX) > MAX_RECEIPT_BYTES
    {
        return Ok(ReceiptState::Invalid);
    }
    let mut handle = File::from(descriptor);
    let mut bytes = Vec::with_capacity(usize::try_from(opened.st_size).unwrap_or(0));
    (&mut handle)
        .take(MAX_RECEIPT_BYTES + 1)
        .read_to_end(&mut bytes)?;
    let final_metadata = rustix::fs::fstat(&handle).map_err(std::io::Error::from)?;
    if bytes.len() as u64 > MAX_RECEIPT_BYTES
        || final_metadata.st_dev != opened.st_dev
        || final_metadata.st_ino != opened.st_ino
        || final_metadata.st_size != opened.st_size
        || final_metadata.st_mode != opened.st_mode
    {
        return Ok(ReceiptState::Invalid);
    }
    let receipt = match serde_json::from_slice::<ManagedSkillReceipt>(&bytes).ok() {
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

fn remove_entry_at(parent: &File, name: &Path) -> Result<()> {
    let Some(expected) = entry_identity_at(parent, name)? else {
        return Ok(());
    };
    remove_entry_at_checked(parent, name, expected)
}

fn remove_entry_at_checked(parent: &File, name: &Path, expected: EntryIdentity) -> Result<()> {
    let mut budget = MAX_MANAGED_REMOVAL_ENTRIES;
    remove_entry_at_checked_with_budget(parent, name, expected, &mut budget)
}

fn remove_entry_at_checked_with_budget(
    parent: &File,
    name: &Path,
    expected: EntryIdentity,
    budget: &mut usize,
) -> Result<()> {
    if *budget == 0 {
        return Err(PetCoreError::Conflict(
            "portable skill removal exceeded its bounded entry budget".to_string(),
        ));
    }
    *budget -= 1;
    if entry_identity_at(parent, name)? != Some(expected) {
        return Err(PetCoreError::Conflict(
            "portable skill content changed during removal".to_string(),
        ));
    }
    if rustix::fs::FileType::from_raw_mode(expected.mode).is_dir() {
        let Some(directory) = open_directory_at(parent, name, Some(expected))? else {
            return Err(PetCoreError::Conflict(
                "portable skill directory changed during removal".to_string(),
            ));
        };
        let mut entries = rustix::fs::Dir::read_from(&directory).map_err(std::io::Error::from)?;
        while let Some(entry) = entries.read() {
            let entry = entry.map_err(std::io::Error::from)?;
            let entry_name = entry.file_name();
            if matches!(entry_name.to_bytes(), b"." | b"..") {
                continue;
            }
            let entry_path = Path::new(std::ffi::OsStr::from_bytes(entry_name.to_bytes()));
            let Some(child_identity) = entry_identity_at(&directory, entry_path)? else {
                continue;
            };
            remove_entry_at_checked_with_budget(&directory, entry_path, child_identity, budget)?;
        }
        if entry_identity_at(parent, name)? != Some(expected) {
            return Err(PetCoreError::Conflict(
                "portable skill directory changed before final removal".to_string(),
            ));
        }
        rustix::fs::unlinkat(parent, name, rustix::fs::AtFlags::REMOVEDIR)
            .map_err(std::io::Error::from)?;
    } else {
        rustix::fs::unlinkat(parent, name, rustix::fs::AtFlags::empty())
            .map_err(std::io::Error::from)?;
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
        assert!(bundle_tree_matches(&target_path(&home)).unwrap());
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
    fn unmanaged_adoption_rejects_a_wrong_length_before_reading_file_content() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("agent-pet-maker");
        fs::create_dir_all(&target).unwrap();
        let skill = target.join("SKILL.md");
        fs::write(&skill, "x").unwrap();
        fs::set_permissions(&skill, fs::Permissions::from_mode(0o000)).unwrap();

        assert!(!bundle_tree_matches(&target).unwrap());
    }

    #[test]
    fn unmanaged_adoption_never_follows_a_nested_directory_symlink() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("agent-pet-maker");
        let outside = temp.path().join("outside-references");
        fs::create_dir_all(&target).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let bundled = BUNDLED_SKILL_FILES
            .iter()
            .find(|file| file.relative_path == "references/security.md")
            .unwrap();
        fs::write(outside.join("security.md"), bundled.content).unwrap();
        symlink(&outside, target.join("references")).unwrap();

        let descriptor = rustix::fs::open(
            &target,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .unwrap();
        let root = File::from(descriptor);
        assert!(!regular_file_matches(
            &root,
            bundled.relative_path,
            bundled.content.as_bytes(),
            false,
        )
        .unwrap());
    }

    #[test]
    fn installed_version_never_follows_a_replaced_skill_file() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("agent-pet-maker");
        let outside = temp.path().join("outside-skill.md");
        fs::create_dir_all(&target).unwrap();
        fs::write(&outside, "---\nversion: 99.99.99\n---\nexternal\n").unwrap();
        symlink(&outside, target.join("SKILL.md")).unwrap();
        let descriptor = rustix::fs::open(
            &target,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .unwrap();

        assert_eq!(installed_version(&File::from(descriptor)), None);
    }

    #[test]
    fn replacement_preserves_a_target_whose_identity_changed_after_inspection() {
        let temp = tempfile::tempdir().unwrap();
        let skills_path = temp.path().join("skills");
        fs::create_dir_all(skills_path.join(SKILL_NAME)).unwrap();
        fs::create_dir(skills_path.join("stage")).unwrap();
        let descriptor = rustix::fs::open(
            &skills_path,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .unwrap();
        let skills = File::from(descriptor);
        let expected = entry_identity_at(&skills, Path::new(SKILL_NAME))
            .unwrap()
            .unwrap();
        fs::rename(
            skills_path.join(SKILL_NAME),
            skills_path.join("original-target"),
        )
        .unwrap();
        fs::create_dir(skills_path.join(SKILL_NAME)).unwrap();
        fs::write(skills_path.join(SKILL_NAME).join("keep.txt"), "foreign").unwrap();

        assert!(replace_target_at(&skills, Path::new("stage"), Some(expected)).is_err());
        assert_eq!(
            fs::read_to_string(skills_path.join(SKILL_NAME).join("keep.txt")).unwrap(),
            "foreign"
        );
        assert!(skills_path.join("original-target").is_dir());
        assert!(skills_path.join("stage").is_dir());
    }

    #[test]
    fn failed_missing_install_never_leaves_an_ownership_receipt() {
        let temp = tempfile::tempdir().unwrap();
        let skills_path = temp.path().join("skills");
        fs::create_dir_all(&skills_path).unwrap();
        fs::create_dir(skills_path.join("stage")).unwrap();
        fs::create_dir(skills_path.join(SKILL_NAME)).unwrap();
        fs::write(skills_path.join(SKILL_NAME).join("keep.txt"), "foreign").unwrap();
        let descriptor = rustix::fs::open(
            &skills_path,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .unwrap();
        let receipt = temp.path().join("receipts/agent-pet-maker.json");
        let managed_receipt = ManagedSkillReceipt {
            schema_version: RECEIPT_SCHEMA.to_string(),
            name: SKILL_NAME.to_string(),
            target_display_path: SKILL_DISPLAY_PATH.to_string(),
            installed_version: bundled_version().unwrap(),
            content_sha256: bundled_content_sha256(),
        };

        assert!(commit_staged_install(
            &File::from(descriptor),
            Path::new("stage"),
            None,
            &receipt,
            &managed_receipt,
        )
        .is_err());
        assert!(!receipt.exists());
        assert_eq!(
            fs::read_to_string(skills_path.join(SKILL_NAME).join("keep.txt")).unwrap(),
            "foreign"
        );
    }

    #[test]
    fn removal_preserves_a_target_whose_identity_changed_after_inspection() {
        let temp = tempfile::tempdir().unwrap();
        let skills_path = temp.path().join("skills");
        fs::create_dir_all(skills_path.join(SKILL_NAME)).unwrap();
        let descriptor = rustix::fs::open(
            &skills_path,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .unwrap();
        let skills = File::from(descriptor);
        let expected = entry_identity_at(&skills, Path::new(SKILL_NAME))
            .unwrap()
            .unwrap();
        fs::rename(
            skills_path.join(SKILL_NAME),
            skills_path.join("original-target"),
        )
        .unwrap();
        fs::create_dir(skills_path.join(SKILL_NAME)).unwrap();
        fs::write(skills_path.join(SKILL_NAME).join("keep.txt"), "foreign").unwrap();

        assert!(quarantine_and_remove_target_at(&skills, expected).is_err());
        assert_eq!(
            fs::read_to_string(skills_path.join(SKILL_NAME).join("keep.txt")).unwrap(),
            "foreign"
        );
        assert!(skills_path.join("original-target").is_dir());
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
