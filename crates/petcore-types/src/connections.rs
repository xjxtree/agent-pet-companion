use crate::AgentSource;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckStatus {
    Ok,
    NeedsFix,
    Missing,
    Unverified,
    Unsupported,
    NotRequired,
}

impl CheckStatus {
    pub fn zh_label(self) -> &'static str {
        match self {
            Self::Ok => "正常",
            Self::NeedsFix => "需修复",
            Self::Missing => "未检测到",
            Self::Unverified => "未验证",
            Self::Unsupported => "暂不支持",
            Self::NotRequired => "非必需",
        }
    }

    pub fn is_blocking(self) -> bool {
        matches!(self, Self::NeedsFix | Self::Missing)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentExtensionKind {
    Connector,
    Plugin,
    Extension,
    Package,
    Skill,
    Hook,
    #[default]
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentExtensionOwnership {
    AppManaged,
    UserManaged,
    #[default]
    #[serde(other)]
    Unknown,
}

/// UI-safe evidence for an Agent Pet Companion-owned connector component.
///
/// Names and versions are bounded identifiers selected by PetCore. Digests,
/// paths, and arbitrary host diagnostic prose never cross this projection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentManagedComponent {
    pub kind: AgentExtensionKind,
    pub name: String,
    pub ownership: AgentExtensionOwnership,
    pub status: CheckStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_matches: Option<bool>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionCheckCode {
    AgentCli,
    EventCli,
    ProjectDirectory,
    AgentVersion,
    ManagedConnector,
    ClaudeHooksPolicy,
    HostRuntime,
    HostVerification,
    EventDelivery,
    ChannelTest,
    AppServer,
    HostServer,
    #[default]
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionCheckRecoveryAction {
    ChooseProjectDirectory,
    ConfirmManagedRepair,
    TestChannel,
    #[serde(other)]
    Recheck,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionCheckItem {
    #[serde(default)]
    pub code: ConnectionCheckCode,
    pub name: String,
    pub status: CheckStatus,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery_action: Option<ConnectionCheckRecoveryAction>,
}

impl ConnectionCheckItem {
    pub fn new(
        code: ConnectionCheckCode,
        name: impl Into<String>,
        status: CheckStatus,
        detail: impl Into<String>,
        recovery_action: Option<ConnectionCheckRecoveryAction>,
    ) -> Self {
        Self {
            code,
            name: name.into(),
            status,
            detail: detail.into(),
            recovery_action,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionCheckMode {
    Light,
    Runtime,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentVerificationStatus {
    Verified,
    ActionRequired,
    #[default]
    Unverified,
    NotRequired,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentVerification {
    #[serde(default)]
    pub status: AgentVerificationStatus,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_verified_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_detail: Option<String>,
    /// Directory used for project-scoped host trust/policy probes. A positive
    /// result must not be extrapolated to other working directories.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_cwd: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentConnectorCapabilities {
    #[serde(default)]
    pub contract_version: String,
    /// Complete host hook/event surface reviewed for this contract, including
    /// deliberately excluded capabilities.
    #[serde(default)]
    pub audited_events: Vec<String>,
    /// Handlers the connector actually registers. A generic bus handler may
    /// safely observe several audited host events.
    #[serde(default)]
    pub subscribed_events: Vec<String>,
    #[serde(default)]
    pub mapped_information: Vec<String>,
    #[serde(default)]
    pub privacy_exclusions: Vec<String>,
    /// Whether the latest check found an issue in connector-owned files or
    /// configuration that the App can safely repair. `None` identifies a
    /// legacy status that predates this typed management contract.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repairable_connector_issue: Option<bool>,
    /// Whether the current Agent/runtime prerequisites and managed paths allow
    /// the App to install or reapply its owned connector, even when the latest
    /// managed-file check is already healthy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_repair_managed_connector: Option<bool>,
    /// Whether a foreign, symlinked, or otherwise unsafe managed path blocks
    /// connector mutation. `None` identifies a legacy status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub managed_path_conflict: Option<bool>,
    /// Whether connector-owned artifacts are present and can currently be
    /// uninstalled without crossing a managed-path conflict.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_uninstall_managed_connector: Option<bool>,
    /// Bounded component identities and exact-match evidence for files owned
    /// by Agent Pet Companion. User-owned extensions are not projected here
    /// and never grant mutation authority.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub managed_components: Vec<AgentManagedComponent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConnectionStatus {
    pub source: AgentSource,
    pub items: Vec<ConnectionCheckItem>,
    pub install_paths: Vec<String>,
    #[serde(default)]
    pub connector_installed: bool,
    #[serde(default)]
    pub verification: AgentVerification,
    #[serde(default)]
    pub capabilities: AgentConnectorCapabilities,
    pub check_mode: ConnectionCheckMode,
    pub checked_at: String,
}
