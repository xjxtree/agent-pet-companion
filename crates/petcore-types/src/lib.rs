use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PETPACK_SCHEMA_VERSION: &str = "apc.petpack.v1";
pub const REQUIRED_STATES: [PetStateName; 7] = [
    PetStateName::Idle,
    PetStateName::Start,
    PetStateName::Tool,
    PetStateName::Waiting,
    PetStateName::Review,
    PetStateName::Done,
    PetStateName::Failed,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityLevel {
    Standard,
    High,
    Ultra,
    Original,
}

impl QualityLevel {
    pub fn render_size(self) -> RenderSize {
        match self {
            Self::Standard => RenderSize {
                width: 192,
                height: 208,
            },
            Self::High => RenderSize {
                width: 384,
                height: 416,
            },
            Self::Ultra => RenderSize {
                width: 768,
                height: 832,
            },
            Self::Original => RenderSize {
                width: 1536,
                height: 1664,
            },
        }
    }

    pub fn zh_label(self) -> &'static str {
        match self {
            Self::Standard => "标清",
            Self::High => "高清",
            Self::Ultra => "超清",
            Self::Original => "原画",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct RenderSize {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FpsProfileName {
    Standard,
    Smooth,
}

impl FpsProfileName {
    pub fn fps(self) -> u32 {
        match self {
            Self::Standard => 12,
            Self::Smooth => 20,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PetStateName {
    Idle,
    Start,
    Tool,
    Waiting,
    Review,
    Done,
    Failed,
}

impl PetStateName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Start => "start",
            Self::Tool => "tool",
            Self::Waiting => "waiting",
            Self::Review => "review",
            Self::Done => "done",
            Self::Failed => "failed",
        }
    }

    pub fn zh_event_label(self) -> &'static str {
        match self {
            Self::Idle => "空闲",
            Self::Start => "开始处理",
            Self::Tool => "执行工具",
            Self::Waiting => "等待确认",
            Self::Review => "待查看",
            Self::Done => "完成",
            Self::Failed => "失败",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentSource {
    Codex,
    ClaudeCode,
    Pi,
    Opencode,
}

impl AgentSource {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::ClaudeCode => "Claude Code",
            Self::Pi => "Pi Coding Agent",
            Self::Opencode => "OpenCode",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEventType {
    Start,
    Tool,
    Waiting,
    Review,
    Done,
    Failed,
}

impl AgentEventType {
    pub fn pet_state(self) -> PetStateName {
        match self {
            Self::Start => PetStateName::Start,
            Self::Tool => PetStateName::Tool,
            Self::Waiting => PetStateName::Waiting,
            Self::Review => PetStateName::Review,
            Self::Done => PetStateName::Done,
            Self::Failed => PetStateName::Failed,
        }
    }

    pub fn zh_label(self) -> &'static str {
        self.pet_state().zh_event_label()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetManifest {
    pub schema_version: String,
    pub id: String,
    pub name: String,
    pub style: String,
    pub quality: QualityLevel,
    pub render_size: RenderSize,
    pub fps_profiles: BTreeMap<FpsProfileName, u32>,
    pub default_fps_profile: FpsProfileName,
    pub states: Vec<PetState>,
    pub created_at: String,
}

impl PetManifest {
    pub fn new(id: String, name: String, style: String, quality: QualityLevel, created_at: String) -> Self {
        let mut fps_profiles = BTreeMap::new();
        fps_profiles.insert(FpsProfileName::Standard, FpsProfileName::Standard.fps());
        fps_profiles.insert(FpsProfileName::Smooth, FpsProfileName::Smooth.fps());

        let states = REQUIRED_STATES
            .iter()
            .map(|state| PetState {
                name: *state,
                frames_dir: format!("assets/frames/{}", state.as_str()),
                looped: !matches!(state, PetStateName::Start | PetStateName::Done),
            })
            .collect();

        Self {
            schema_version: PETPACK_SCHEMA_VERSION.to_string(),
            id,
            name,
            style,
            quality,
            render_size: quality.render_size(),
            fps_profiles,
            default_fps_profile: FpsProfileName::Standard,
            states,
            created_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetState {
    pub name: PetStateName,
    pub frames_dir: String,
    #[serde(rename = "loop")]
    pub looped: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BehaviorSettings {
    pub enabled: bool,
    pub status_bubble: bool,
    pub click_menu: bool,
    pub mouse_passthrough: bool,
    pub auto_hide: bool,
    pub fps_profile: FpsProfileName,
    pub sources: BTreeMap<AgentSource, bool>,
    pub events: BTreeMap<AgentEventType, bool>,
}

impl Default for BehaviorSettings {
    fn default() -> Self {
        let mut sources = BTreeMap::new();
        for source in [
            AgentSource::Codex,
            AgentSource::ClaudeCode,
            AgentSource::Pi,
            AgentSource::Opencode,
        ] {
            sources.insert(source, true);
        }

        let mut events = BTreeMap::new();
        for event in [
            AgentEventType::Start,
            AgentEventType::Tool,
            AgentEventType::Waiting,
            AgentEventType::Review,
            AgentEventType::Done,
            AgentEventType::Failed,
        ] {
            events.insert(event, true);
        }

        Self {
            enabled: true,
            status_bubble: true,
            click_menu: true,
            mouse_passthrough: false,
            auto_hide: false,
            fps_profile: FpsProfileName::Standard,
            sources,
            events,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayPlacement {
    pub x: f64,
    pub y: f64,
    pub scale: f64,
    pub display_id: String,
}

impl Default for OverlayPlacement {
    fn default() -> Self {
        Self {
            x: 1180.0,
            y: 720.0,
            scale: 1.35,
            display_id: "main".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentEvent {
    pub id: String,
    pub source: AgentSource,
    pub project_path: Option<String>,
    pub session_id: Option<String>,
    pub event_type: AgentEventType,
    pub title: String,
    pub detail: Option<String>,
    pub payload_json: serde_json::Value,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerationForm {
    pub description: String,
    pub style: String,
    pub quality: QualityLevel,
    pub reference_images: Vec<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationJobStatus {
    Pending,
    Running,
    Failed,
    Completed,
    Canceled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PetSummary {
    pub id: String,
    pub name: String,
    pub style: String,
    pub quality: QualityLevel,
    pub render_size: RenderSize,
    pub petpack_path: String,
    pub cover_path: String,
    pub active: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckStatus {
    Ok,
    NeedsFix,
    Missing,
}

impl CheckStatus {
    pub fn zh_label(self) -> &'static str {
        match self {
            Self::Ok => "正常",
            Self::NeedsFix => "需修复",
            Self::Missing => "未检测到",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionCheckItem {
    pub name: String,
    pub status: CheckStatus,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConnectionStatus {
    pub source: AgentSource,
    pub items: Vec<ConnectionCheckItem>,
    pub install_paths: Vec<String>,
}
