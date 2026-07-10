use crate::{PetCoreError, Result};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const DEFAULT_LABEL: &str = "dev.agentpet.petcore";

#[derive(Debug, Clone)]
pub struct LaunchAgentConfig {
    pub label: String,
    pub program: PathBuf,
    pub home: PathBuf,
    pub stdout_path: PathBuf,
    pub stderr_path: PathBuf,
    pub path_environment: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct LaunchAgentStatus {
    pub label: String,
    pub plist_path: String,
    pub installed: bool,
    pub loaded: Option<bool>,
}

impl LaunchAgentConfig {
    pub fn new(program: PathBuf, home: PathBuf) -> Self {
        let logs = home.join("logs");
        Self {
            label: DEFAULT_LABEL.to_string(),
            program,
            home,
            stdout_path: logs.join("petcore.launchd.out.log"),
            stderr_path: logs.join("petcore.launchd.err.log"),
            path_environment: launch_agent_path_environment(),
        }
    }

    pub fn plist_xml(&self) -> String {
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{program}</string>
    <string>serve</string>
    <string>--home</string>
    <string>{home}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>APC_HOME</key>
    <string>{home}</string>
    <key>RUST_LOG</key>
    <string>info</string>
    <key>PATH</key>
    <string>{path}</string>
  </dict>
</dict>
</plist>
"#,
            label = xml_escape(&self.label),
            program = xml_escape(&self.program.display().to_string()),
            home = xml_escape(&self.home.display().to_string()),
            stdout = xml_escape(&self.stdout_path.display().to_string()),
            stderr = xml_escape(&self.stderr_path.display().to_string()),
            path = xml_escape(&self.path_environment)
        )
    }
}

pub fn default_plist_path() -> PathBuf {
    launch_agents_dir().join(format!("{DEFAULT_LABEL}.plist"))
}

pub fn install(config: &LaunchAgentConfig, load: bool) -> Result<LaunchAgentStatus> {
    let plist_path = default_plist_path();
    if let Some(parent) = plist_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if let Some(parent) = config.stdout_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let plist = config.plist_xml();
    let previous = fs::read_to_string(&plist_path).ok();
    if previous.as_deref() != Some(plist.as_str()) {
        if load {
            let _ = launchctl(&["bootout", &launch_domain_and_label(&config.label)]);
        }
        fs::write(&plist_path, plist)?;
    }

    if load {
        if !is_loaded(&config.label) {
            launchctl_checked(&[
                "bootstrap",
                &launch_domain(),
                &plist_path.display().to_string(),
            ])?;
        }
        launchctl_checked(&["kickstart", "-k", &launch_domain_and_label(&config.label)])?;
    }

    status_for_label(&config.label, load)
}

pub fn uninstall(label: &str, unload: bool) -> Result<LaunchAgentStatus> {
    let plist_path = plist_path_for_label(label);
    if unload {
        let _ = launchctl(&["bootout", &launch_domain_and_label(label)]);
    }
    if plist_path.exists() {
        fs::remove_file(&plist_path)?;
    }
    status_for_label(label, unload)
}

pub fn status(check_launchctl: bool) -> LaunchAgentStatus {
    status_for_label(DEFAULT_LABEL, check_launchctl).unwrap_or_else(|_| LaunchAgentStatus {
        label: DEFAULT_LABEL.to_string(),
        plist_path: default_plist_path().display().to_string(),
        installed: default_plist_path().exists(),
        loaded: None,
    })
}

fn status_for_label(label: &str, check_launchctl: bool) -> Result<LaunchAgentStatus> {
    let plist_path = plist_path_for_label(label);
    Ok(LaunchAgentStatus {
        label: label.to_string(),
        installed: plist_path.exists(),
        loaded: check_launchctl.then(|| is_loaded(label)),
        plist_path: plist_path.display().to_string(),
    })
}

fn plist_path_for_label(label: &str) -> PathBuf {
    launch_agents_dir().join(format!("{label}.plist"))
}

fn launch_agents_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("APC_LAUNCH_AGENT_DIR").map(PathBuf::from) {
        return path;
    }
    user_home().join("Library").join("LaunchAgents")
}

fn launch_agent_path_environment() -> String {
    let current = std::env::var("PATH").unwrap_or_default();
    let additions = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ];
    let home = user_home();
    let home_additions = [
        home.join(".local").join("bin"),
        home.join(".cargo").join("bin"),
        home.join(".bun").join("bin"),
        home.join("bin"),
    ];

    let mut parts = Vec::<String>::new();
    for path in current
        .split(':')
        .filter(|path| !path.is_empty())
        .map(ToOwned::to_owned)
        .chain(additions.into_iter().map(ToOwned::to_owned))
        .chain(home_additions.iter().map(|path| path.display().to_string()))
    {
        if !parts.iter().any(|existing| existing == &path) {
            parts.push(path);
        }
    }
    parts.join(":")
}

fn user_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn is_loaded(label: &str) -> bool {
    launchctl(&["print", &launch_domain_and_label(label)])
}

fn launchctl_checked(args: &[&str]) -> Result<()> {
    if launchctl(args) {
        Ok(())
    } else {
        Err(PetCoreError::InvalidRequest(format!(
            "launchctl failed: {}",
            args.join(" ")
        )))
    }
}

fn launchctl(args: &[&str]) -> bool {
    if std::env::var_os("APC_SKIP_LAUNCHCTL").is_some() {
        return true;
    }
    let Ok(status) = Command::new("/bin/launchctl").args(args).status() else {
        return false;
    };
    status.success()
}

fn launch_domain() -> String {
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "0".to_string());
    format!("gui/{uid}")
}

fn launch_domain_and_label(label: &str) -> String {
    format!("{}/{}", launch_domain(), label)
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

pub fn program_next_to_cli(cli_path: &Path) -> PathBuf {
    cli_path
        .parent()
        .map(|parent| parent.join("petcore"))
        .unwrap_or_else(|| PathBuf::from("petcore"))
}
