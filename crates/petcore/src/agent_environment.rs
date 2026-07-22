use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

pub(crate) const CONNECTOR_ROOT_ENV_KEYS: &[&str] = &[
    "CODEX_HOME",
    "CLAUDE_CONFIG_DIR",
    "PI_CODING_AGENT_DIR",
    "OPENCODE_CONFIG_DIR",
    "OPENCODE_CONFIG",
    "XDG_CONFIG_HOME",
];

pub(crate) const AGENT_CLI_OVERRIDE_ENV_KEYS: &[&str] = &[
    "APC_CODEX_CLI_PATH",
    "APC_CLAUDE_CLI_PATH",
    "APC_PI_CLI_PATH",
    "APC_OPENCODE_CLI_PATH",
];

const MAX_VERSION_MANAGER_INSTALLATIONS: usize = 32;

pub(crate) fn absolute_env_path(key: &str) -> Option<PathBuf> {
    let value = std::env::var_os(key)?;
    if value.is_empty() {
        return None;
    }
    normalize_absolute_path(Path::new(&value))
}

pub(crate) fn user_home() -> PathBuf {
    absolute_env_path("HOME").unwrap_or_else(|| PathBuf::from("."))
}

pub(crate) fn is_executable_file(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

pub(crate) fn find_executable(name: &str) -> Option<PathBuf> {
    command_search_dirs()
        .into_iter()
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable_file(candidate))
}

pub(crate) fn command_search_dirs() -> Vec<PathBuf> {
    let current = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default();
    executable_search_dirs(&current, &user_home())
}

pub(crate) fn executable_search_path() -> String {
    command_search_dirs()
        .into_iter()
        .filter_map(|path| path.to_str().map(ToOwned::to_owned))
        .collect::<Vec<_>>()
        .join(":")
}

pub(crate) fn connector_identity_environment() -> BTreeMap<String, String> {
    let mut snapshot = BTreeMap::new();
    if let Some(home) = absolute_env_path("HOME") {
        snapshot.insert("HOME".to_string(), home.display().to_string());
    }
    for key in CONNECTOR_ROOT_ENV_KEYS
        .iter()
        .chain(AGENT_CLI_OVERRIDE_ENV_KEYS.iter())
    {
        if let Some(value) = absolute_env_path(key) {
            snapshot.insert((*key).to_string(), value.display().to_string());
        }
    }
    if let Some(path) = std::env::var("PATH")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        snapshot.insert("PATH".to_string(), path);
    }
    snapshot
}

pub(crate) fn inherited_connector_path_environment() -> Vec<(String, String)> {
    CONNECTOR_ROOT_ENV_KEYS
        .iter()
        .chain(AGENT_CLI_OVERRIDE_ENV_KEYS.iter())
        .filter_map(|key| {
            absolute_env_path(key).map(|value| ((*key).to_string(), value.display().to_string()))
        })
        .collect()
}

pub(crate) fn executable_search_dirs(current: &[PathBuf], home: &Path) -> Vec<PathBuf> {
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    let mut add = |path: PathBuf| {
        let Some(path) = normalize_absolute_path(&path) else {
            return;
        };
        if seen.insert(path.clone()) {
            result.push(path);
        }
    };

    for path in current {
        add(path.clone());
    }
    for path in default_executable_search_dirs(home) {
        add(path);
    }
    result
}

pub(crate) fn default_executable_search_dirs(home: &Path) -> Vec<PathBuf> {
    let mut directories = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/opt/homebrew/sbin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/local/sbin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
        PathBuf::from("/usr/sbin"),
        PathBuf::from("/sbin"),
        home.join(".local/bin"),
        home.join(".cargo/bin"),
        home.join(".bun/bin"),
        home.join(".opencode/bin"),
        home.join(".volta/bin"),
        home.join(".asdf/shims"),
        home.join(".local/share/mise/shims"),
        home.join(".fnm/current/bin"),
        home.join(".nvm/current/bin"),
        home.join(".nodenv/shims"),
        home.join(".npm-global/bin"),
        home.join(".local/share/pnpm"),
        home.join("Library/pnpm"),
        home.join(".yarn/bin"),
        home.join("bin"),
    ];
    directories.extend(version_manager_bin_directories(
        &home.join(".nvm/versions/node"),
        Path::new("bin"),
    ));
    directories.extend(version_manager_bin_directories(
        &home.join(".local/share/fnm/node-versions"),
        Path::new("installation/bin"),
    ));
    directories
}

fn version_manager_bin_directories(root: &Path, suffix: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut directories = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path().join(suffix))
        .filter(|path| path.is_dir())
        .collect::<Vec<_>>();
    directories.sort();
    directories.truncate(MAX_VERSION_MANAGER_INSTALLATIONS);
    directories
}

fn normalize_absolute_path(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(Path::new("/")),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(value) => normalized.push(value),
        }
    }
    Some(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn search_paths_cover_common_node_version_managers_and_skip_relative_entries() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let nvm = home.join(".nvm/versions/node/v22.0.0/bin");
        let fnm = home.join(".local/share/fnm/node-versions/v20.0.0/installation/bin");
        fs::create_dir_all(&nvm).unwrap();
        fs::create_dir_all(&fnm).unwrap();

        let paths = executable_search_dirs(
            &[PathBuf::from("relative/bin"), home.join("custom/bin")],
            home,
        );

        assert!(!paths.contains(&PathBuf::from("relative/bin")));
        assert!(paths.contains(&home.join("custom/bin")));
        assert!(paths.contains(&home.join(".volta/bin")));
        assert!(paths.contains(&home.join(".asdf/shims")));
        assert!(paths.contains(&home.join(".local/share/mise/shims")));
        assert!(paths.contains(&nvm));
        assert!(paths.contains(&fnm));
    }

    #[test]
    fn executable_lookup_skips_non_executable_shadow_files() {
        let temp = tempfile::tempdir().unwrap();
        let blocked = temp.path().join("blocked");
        let usable = temp.path().join("usable");
        fs::create_dir_all(&blocked).unwrap();
        fs::create_dir_all(&usable).unwrap();
        fs::write(blocked.join("pi"), "not executable").unwrap();
        fs::write(usable.join("pi"), "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(usable.join("pi"), fs::Permissions::from_mode(0o755)).unwrap();

        let candidates = executable_search_dirs(&[blocked, usable.clone()], temp.path());
        let resolved = candidates
            .into_iter()
            .map(|directory| directory.join("pi"))
            .find(|candidate| is_executable_file(candidate));
        assert_eq!(resolved, Some(usable.join("pi")));
    }
}
