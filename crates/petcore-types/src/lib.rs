use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PETPACK_SCHEMA_VERSION: &str = "apc.petpack.v3";
pub const ONBOARDING_PROGRESS_SCHEMA_VERSION: &str = "apc.onboarding-progress.v1";
pub const MIN_FRAME_DURATION_MS: u32 = 50;
pub const MAX_FRAME_DURATION_MS: u32 = 2_000;
pub const MAX_STATE_DURATION_MS: u32 = 5_000;
pub const MAX_PERIODIC_COOLDOWN_MS: u32 = 86_400_000;
pub const MIN_FRAMES_PER_STATE: usize = 2;
pub const MAX_FRAMES_PER_STATE: usize = 40;
pub const MIN_OVERLAY_DISPLAY_WIDTH_PT: f64 = 80.0;
pub const MAX_OVERLAY_DISPLAY_WIDTH_PT: f64 = 224.0;
pub const DEFAULT_OVERLAY_DISPLAY_WIDTH_PT: f64 = 112.0;
pub const OVERLAY_DISPLAY_WIDTH_STEP_PT: f64 = 1.0;
pub const OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT: f64 = 256.0;
pub const OVERLAY_PLACEMENT_QUANTUM_PT: f64 = 1.0 / OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT;
pub const MAX_OVERLAY_COORDINATE_MAGNITUDE: f64 = f64::MAX / OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT;
pub const DEFAULT_SESSION_MESSAGE_TIMEOUT_MINUTES: u16 = 15;
pub const MIN_SESSION_MESSAGE_TIMEOUT_MINUTES: u16 = 1;
pub const MAX_SESSION_MESSAGE_TIMEOUT_MINUTES: u16 = 1_440;
pub const REQUIRED_SEMANTIC_STATES: [PetStateName; 6] = [
    PetStateName::Idle,
    PetStateName::Thinking,
    PetStateName::Tool,
    PetStateName::Waiting,
    PetStateName::Done,
    PetStateName::Failed,
];
pub const REQUIRED_INTERACTION_STATES: [PetStateName; 3] = [
    PetStateName::Acknowledge,
    PetStateName::DragLeft,
    PetStateName::DragRight,
];
pub const REQUIRED_STATES: [PetStateName; 9] = [
    PetStateName::Idle,
    PetStateName::Thinking,
    PetStateName::Tool,
    PetStateName::Waiting,
    PetStateName::Done,
    PetStateName::Failed,
    PetStateName::Acknowledge,
    PetStateName::DragLeft,
    PetStateName::DragRight,
];
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityLevel {
    Low,
    Standard,
    High,
}

impl QualityLevel {
    pub fn render_size(self) -> RenderSize {
        match self {
            Self::Low => RenderSize {
                width: 192,
                height: 208,
            },
            Self::Standard => RenderSize {
                width: 384,
                height: 416,
            },
            Self::High => RenderSize {
                width: 576,
                height: 624,
            },
        }
    }

    pub fn is_studio_supported(self) -> bool {
        matches!(self, Self::Low | Self::Standard)
    }

    pub fn zh_label(self) -> &'static str {
        match self {
            Self::Low => "标清",
            Self::Standard => "标准",
            Self::High => "高清",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenderSize {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AppearanceTheme {
    #[default]
    System,
    Dark,
    Light,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InterfaceLanguage {
    #[default]
    System,
    English,
    SimplifiedChinese,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionGroupDisplay {
    #[default]
    Stacked,
    Expanded,
}

/// Bubble text size tier. The App owns the exact per-role point sizes; PetCore
/// only stores which closed tier the user selected.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BubbleFontScale {
    #[default]
    Standard,
    Large,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PetStateName {
    Idle,
    Thinking,
    Tool,
    Waiting,
    Done,
    Failed,
    Acknowledge,
    DragLeft,
    DragRight,
}

impl PetStateName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Thinking => "thinking",
            Self::Tool => "tool",
            Self::Waiting => "waiting",
            Self::Done => "done",
            Self::Failed => "failed",
            Self::Acknowledge => "acknowledge",
            Self::DragLeft => "drag_left",
            Self::DragRight => "drag_right",
        }
    }

    pub fn is_interaction(self) -> bool {
        matches!(self, Self::Acknowledge | Self::DragLeft | Self::DragRight)
    }

    pub fn zh_event_label(self) -> &'static str {
        match self {
            Self::Idle => "空闲",
            Self::Thinking => "思考",
            Self::Tool => "执行工具",
            Self::Waiting => "等待确认",
            Self::Done => "完成",
            Self::Failed => "失败",
            Self::Acknowledge => "轻回应",
            Self::DragLeft => "向左拖动",
            Self::DragRight => "向右拖动",
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
    Thinking,
    Plan,
    Tool,
    Waiting,
    Done,
    Failed,
}

impl AgentEventType {
    /// Sparse event -> authored pet-action mapping.
    ///
    /// `start` is a useful one-shot session event, but it is not evidence that
    /// the Agent is thinking and therefore does not trigger an authored pet
    /// action. `thinking` and `plan` share the explicitly named Thinking action.
    pub fn pet_reaction(self) -> Option<PetStateName> {
        match self {
            Self::Start => None,
            Self::Thinking | Self::Plan => Some(PetStateName::Thinking),
            Self::Tool => Some(PetStateName::Tool),
            Self::Waiting => Some(PetStateName::Waiting),
            Self::Done => Some(PetStateName::Done),
            Self::Failed => Some(PetStateName::Failed),
        }
    }

    /// Renderer-facing compatibility projection. Events without a pet
    /// reaction render the ordinary idle state.
    pub fn pet_state(self) -> PetStateName {
        self.pet_reaction().unwrap_or(PetStateName::Idle)
    }

    pub fn zh_label(self) -> &'static str {
        match self {
            Self::Start => "开始处理",
            Self::Thinking => "思考",
            Self::Plan => "规划",
            Self::Tool => "执行工具",
            Self::Waiting => "等待确认",
            Self::Done => "完成",
            Self::Failed => "失败",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PetManifest {
    pub schema_version: String,
    pub id: String,
    pub name: String,
    pub style: String,
    pub quality: QualityLevel,
    pub render_size: RenderSize,
    pub states: Vec<PetState>,
    pub created_at: String,
}

impl PetManifest {
    pub fn new(
        id: String,
        name: String,
        style: String,
        quality: QualityLevel,
        created_at: String,
    ) -> Self {
        Self {
            schema_version: PETPACK_SCHEMA_VERSION.to_string(),
            id,
            name,
            style,
            quality,
            render_size: quality.render_size(),
            states: default_pet_states(),
            created_at,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackMode {
    Loop,
    Periodic,
    BurstThenSettle,
    BurstThenIdle,
    OnceThenReturn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlaybackContract {
    pub mode: PlaybackMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_repeat_count: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settle_frame_index: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cooldown_ms: Option<[u32; 2]>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PetState {
    pub name: PetStateName,
    pub frames_dir: String,
    pub frame_durations_ms: Vec<u32>,
    pub playback: PlaybackContract,
    pub reduced_motion_frame_index: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PetTimingContract {
    pub frame_durations_ms: Vec<u32>,
    pub playback: PlaybackContract,
    pub reduced_motion_frame_index: usize,
}

impl PetTimingContract {
    pub fn validate(&self) -> Result<Vec<String>, String> {
        let frame_count = self.frame_durations_ms.len();
        if !(MIN_FRAMES_PER_STATE..=MAX_FRAMES_PER_STATE).contains(&frame_count) {
            return Err(format!(
                "frame_durations_ms must contain between {MIN_FRAMES_PER_STATE} and {MAX_FRAMES_PER_STATE} entries"
            ));
        }
        if let Some((index, _)) =
            self.frame_durations_ms
                .iter()
                .copied()
                .enumerate()
                .find(|(_, duration)| {
                    !(MIN_FRAME_DURATION_MS..=MAX_FRAME_DURATION_MS).contains(duration)
                })
        {
            return Err(format!(
                "frame_durations_ms[{index}] must be between {MIN_FRAME_DURATION_MS} and {MAX_FRAME_DURATION_MS}"
            ));
        }
        let total_duration_ms = self
            .frame_durations_ms
            .iter()
            .try_fold(0_u32, |total, duration| total.checked_add(*duration))
            .ok_or_else(|| "frame duration total overflowed".to_string())?;
        if total_duration_ms > MAX_STATE_DURATION_MS {
            return Err(format!(
                "frame duration total must not exceed {MAX_STATE_DURATION_MS} ms"
            ));
        }
        if self.reduced_motion_frame_index >= frame_count {
            return Err("reduced_motion_frame_index is outside the frame sequence".to_string());
        }

        match self.playback.mode {
            PlaybackMode::Loop => {
                if self.playback.entry_repeat_count.is_some()
                    || self.playback.settle_frame_index.is_some()
                    || self.playback.cooldown_ms.is_some()
                {
                    return Err(
                        "loop playback must not declare entry_repeat_count, settle_frame_index, or cooldown_ms"
                            .to_string(),
                    );
                }
            }
            PlaybackMode::Periodic => {
                let [minimum, maximum] = self
                    .playback
                    .cooldown_ms
                    .ok_or_else(|| "periodic playback requires cooldown_ms".to_string())?;
                if minimum > MAX_PERIODIC_COOLDOWN_MS || maximum > MAX_PERIODIC_COOLDOWN_MS {
                    return Err(format!(
                        "periodic cooldown_ms values must not exceed {MAX_PERIODIC_COOLDOWN_MS}"
                    ));
                }
                if minimum > maximum {
                    return Err("periodic cooldown_ms minimum exceeds maximum".to_string());
                }
                if self.playback.entry_repeat_count.is_some()
                    || self.playback.settle_frame_index.is_some()
                {
                    return Err("periodic playback allows only cooldown_ms".to_string());
                }
            }
            PlaybackMode::BurstThenSettle => {
                validate_settle_frame(&self.playback, frame_count)?;
                if !matches!(self.playback.entry_repeat_count, Some(1..=8)) {
                    return Err(
                        "burst_then_settle playback requires entry_repeat_count between 1 and 8"
                            .to_string(),
                    );
                }
                if self.playback.cooldown_ms.is_some() {
                    return Err(
                        "burst_then_settle playback must not declare cooldown_ms".to_string()
                    );
                }
            }
            PlaybackMode::BurstThenIdle => {
                if !matches!(self.playback.entry_repeat_count, Some(1..=8)) {
                    return Err(
                        "burst_then_idle playback requires entry_repeat_count between 1 and 8"
                            .to_string(),
                    );
                }
                if self.playback.settle_frame_index.is_some() || self.playback.cooldown_ms.is_some()
                {
                    return Err(
                        "burst_then_idle playback allows only entry_repeat_count".to_string()
                    );
                }
            }
            PlaybackMode::OnceThenReturn => {
                if self.playback.entry_repeat_count.is_some()
                    || self.playback.settle_frame_index.is_some()
                    || self.playback.cooldown_ms.is_some()
                {
                    return Err(
                        "once_then_return playback must not declare entry_repeat_count, settle_frame_index, or cooldown_ms"
                            .to_string(),
                    );
                }
            }
        }

        let mut warnings = Vec::new();
        if !(4..=8).contains(&frame_count) {
            warnings.push(format!(
                "authored frame count {frame_count} is outside the recommended 4–8 range"
            ));
        }
        // A periodic idle may deliberately spend longer in a calm authored
        // hold before its separate cooldown. Keep the ordinary duration
        // warning for every non-periodic action.
        if self.playback.mode != PlaybackMode::Periodic && total_duration_ms > 1_500 {
            warnings.push(format!(
                "authored duration {total_duration_ms} ms exceeds the recommended 1500 ms"
            ));
        }
        let effective_fps = frame_count as f64 * 1_000.0 / f64::from(total_duration_ms);
        // A periodic action deliberately includes a long authored rest frame before
        // its separate cooldown. Treating that calm hold as an animation-rate
        // defect would make the low-distraction V3 idle baseline warn by design.
        if self.playback.mode != PlaybackMode::Periodic && !(4.0..=12.0).contains(&effective_fps) {
            warnings.push(format!(
                "average effective frame rate {effective_fps:.2} FPS is outside the recommended 4–12 FPS range"
            ));
        }
        Ok(warnings)
    }
}

fn validate_settle_frame(playback: &PlaybackContract, frame_count: usize) -> Result<(), String> {
    let index = playback
        .settle_frame_index
        .ok_or_else(|| "playback requires settle_frame_index".to_string())?;
    if index >= frame_count {
        return Err("settle_frame_index is outside the frame sequence".to_string());
    }
    Ok(())
}

impl From<&PetState> for PetTimingContract {
    fn from(state: &PetState) -> Self {
        Self {
            frame_durations_ms: state.frame_durations_ms.clone(),
            playback: state.playback,
            reduced_motion_frame_index: state.reduced_motion_frame_index,
        }
    }
}

impl PetState {
    pub fn validate(&self) -> Result<Vec<String>, String> {
        let warnings = PetTimingContract::from(self).validate()?;
        let expected_mode = match self.name {
            PetStateName::Idle => PlaybackMode::Periodic,
            PetStateName::Thinking | PetStateName::Tool | PetStateName::Done => {
                PlaybackMode::BurstThenIdle
            }
            PetStateName::Waiting | PetStateName::Failed => PlaybackMode::BurstThenSettle,
            PetStateName::Acknowledge => PlaybackMode::OnceThenReturn,
            PetStateName::DragLeft | PetStateName::DragRight => PlaybackMode::Loop,
        };
        if self.playback.mode != expected_mode {
            return Err(format!(
                "state {} requires {} playback",
                self.name.as_str(),
                playback_mode_name(expected_mode)
            ));
        }
        Ok(warnings)
    }
}

pub fn playback_mode_name(mode: PlaybackMode) -> &'static str {
    match mode {
        PlaybackMode::Loop => "loop",
        PlaybackMode::Periodic => "periodic",
        PlaybackMode::BurstThenSettle => "burst_then_settle",
        PlaybackMode::BurstThenIdle => "burst_then_idle",
        PlaybackMode::OnceThenReturn => "once_then_return",
    }
}

pub fn default_pet_states() -> Vec<PetState> {
    REQUIRED_STATES.into_iter().map(default_pet_state).collect()
}

pub fn default_pet_state(name: PetStateName) -> PetState {
    let (frame_durations_ms, playback, reduced_motion_frame_index) = match name {
        PetStateName::Idle => (
            vec![260, 220, 240, 260, 380, 640],
            PlaybackContract {
                mode: PlaybackMode::Periodic,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: Some([2_500, 5_000]),
            },
            2,
        ),
        PetStateName::Thinking => (vec![120, 140, 160, 180], burst_then_idle(3), 2),
        PetStateName::Tool => (vec![150, 150, 170, 330], burst_then_idle(3), 2),
        PetStateName::Waiting => (
            vec![100, 100, 110, 110, 120, 130, 160, 230],
            burst_then_settle(3, 7),
            4,
        ),
        PetStateName::Done => (vec![120, 140, 160, 230], burst_then_idle(3), 2),
        PetStateName::Failed => (
            vec![80, 80, 90, 100, 110, 120, 190, 290],
            burst_then_settle(3, 7),
            2,
        ),
        PetStateName::Acknowledge => (
            vec![180, 140, 180, 300],
            PlaybackContract {
                mode: PlaybackMode::OnceThenReturn,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
            1,
        ),
        PetStateName::DragLeft | PetStateName::DragRight => (
            vec![100, 90, 100, 110, 100, 200],
            PlaybackContract {
                mode: PlaybackMode::Loop,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
            2,
        ),
    };
    PetState {
        name,
        frames_dir: format!("assets/frames/{}", name.as_str()),
        frame_durations_ms,
        playback,
        reduced_motion_frame_index,
    }
}

fn burst_then_idle(entry_repeat_count: u32) -> PlaybackContract {
    PlaybackContract {
        mode: PlaybackMode::BurstThenIdle,
        entry_repeat_count: Some(entry_repeat_count),
        settle_frame_index: None,
        cooldown_ms: None,
    }
}

fn burst_then_settle(entry_repeat_count: u32, settle_frame_index: usize) -> PlaybackContract {
    PlaybackContract {
        mode: PlaybackMode::BurstThenSettle,
        entry_repeat_count: Some(entry_repeat_count),
        settle_frame_index: Some(settle_frame_index),
        cooldown_ms: None,
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct BehaviorSettings {
    pub enabled: bool,
    pub status_bubble: bool,
    pub interface_language: InterfaceLanguage,
    pub appearance_theme: AppearanceTheme,
    pub bubble_font_scale: BubbleFontScale,
    pub click_menu: bool,
    pub mouse_passthrough: bool,
    pub auto_hide: bool,
    pub group_sessions_by_agent: bool,
    pub session_group_display: SessionGroupDisplay,
    pub session_message_timeout_minutes: u16,
    pub sources: BTreeMap<AgentSource, bool>,
    pub events: BTreeMap<AgentEventType, bool>,
}

impl<'de> Deserialize<'de> for BehaviorSettings {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct RawBehaviorSettings {
            enabled: Option<bool>,
            status_bubble: Option<bool>,
            interface_language: Option<InterfaceLanguage>,
            appearance_theme: Option<AppearanceTheme>,
            bubble_font_scale: Option<BubbleFontScale>,
            click_menu: Option<bool>,
            mouse_passthrough: Option<bool>,
            auto_hide: Option<bool>,
            group_sessions_by_agent: Option<bool>,
            session_group_display: Option<SessionGroupDisplay>,
            session_message_timeout_minutes: Option<u16>,
            sources: Option<BTreeMap<AgentSource, bool>>,
            events: Option<BTreeMap<String, bool>>,
        }

        let raw = RawBehaviorSettings::deserialize(deserializer)?;
        let defaults = BehaviorSettings::default();
        let mut sources = defaults.sources.clone();
        if let Some(raw_sources) = raw.sources {
            for (source, enabled) in raw_sources {
                sources.insert(source, enabled);
            }
        }
        let mut events = defaults.events.clone();
        if let Some(raw_events) = raw.events {
            for (event, enabled) in raw_events {
                let Ok(event) =
                    serde_json::from_value::<AgentEventType>(serde_json::Value::String(event))
                else {
                    continue;
                };
                events.insert(event, enabled);
            }
        }

        Ok(Self {
            enabled: raw.enabled.unwrap_or(defaults.enabled),
            status_bubble: raw.status_bubble.unwrap_or(defaults.status_bubble),
            interface_language: raw
                .interface_language
                .unwrap_or(defaults.interface_language),
            appearance_theme: raw.appearance_theme.unwrap_or(defaults.appearance_theme),
            bubble_font_scale: raw.bubble_font_scale.unwrap_or(defaults.bubble_font_scale),
            click_menu: raw.click_menu.unwrap_or(defaults.click_menu),
            mouse_passthrough: raw.mouse_passthrough.unwrap_or(defaults.mouse_passthrough),
            auto_hide: raw.auto_hide.unwrap_or(defaults.auto_hide),
            group_sessions_by_agent: raw
                .group_sessions_by_agent
                .unwrap_or(defaults.group_sessions_by_agent),
            session_group_display: raw
                .session_group_display
                .unwrap_or(defaults.session_group_display),
            session_message_timeout_minutes: raw
                .session_message_timeout_minutes
                .unwrap_or(defaults.session_message_timeout_minutes),
            sources,
            events,
        })
    }
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
            AgentEventType::Thinking,
            AgentEventType::Plan,
            AgentEventType::Tool,
            AgentEventType::Waiting,
            AgentEventType::Done,
            AgentEventType::Failed,
        ] {
            events.insert(event, true);
        }

        Self {
            enabled: true,
            status_bubble: true,
            interface_language: InterfaceLanguage::System,
            appearance_theme: AppearanceTheme::System,
            bubble_font_scale: BubbleFontScale::Standard,
            click_menu: true,
            mouse_passthrough: true,
            auto_hide: false,
            group_sessions_by_agent: true,
            session_group_display: SessionGroupDisplay::Stacked,
            session_message_timeout_minutes: DEFAULT_SESSION_MESSAGE_TIMEOUT_MINUTES,
            sources,
            events,
        }
    }
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(rename_all = "snake_case")]
pub enum OnboardingStage {
    #[default]
    ChoosePet,
    ConnectAgents,
    Demo,
    Completed,
    Skipped,
}

impl OnboardingStage {
    pub fn can_advance_to(self, next: Self) -> bool {
        matches!(
            (self, next),
            (Self::ChoosePet, Self::ConnectAgents | Self::Skipped)
                | (Self::ConnectAgents, Self::Demo | Self::Skipped)
                | (Self::Demo, Self::Completed | Self::Skipped)
        )
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Skipped)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OnboardingProgress {
    pub schema_version: String,
    pub stage: OnboardingStage,
}

impl OnboardingProgress {
    pub fn is_supported(&self) -> bool {
        self.schema_version == ONBOARDING_PROGRESS_SCHEMA_VERSION
    }
}

impl Default for OnboardingProgress {
    fn default() -> Self {
        Self {
            schema_version: ONBOARDING_PROGRESS_SCHEMA_VERSION.to_string(),
            stage: OnboardingStage::ChoosePet,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OverlayPlacement {
    pub x: f64,
    pub y: f64,
    pub display_width_pt: f64,
    pub display_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OverlayPlacementIntent {
    ExternalReposition,
    Reset,
}

impl Default for OverlayPlacement {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            display_width_pt: DEFAULT_OVERLAY_DISPLAY_WIDTH_PT,
            display_id: "main".to_string(),
        }
    }
}

impl OverlayPlacement {
    pub fn validate(&self) -> Result<(), String> {
        canonical_overlay_coordinate(self.x)?;
        canonical_overlay_coordinate(self.y)?;
        if !(MIN_OVERLAY_DISPLAY_WIDTH_PT..=MAX_OVERLAY_DISPLAY_WIDTH_PT)
            .contains(&self.display_width_pt)
        {
            return Err(format!(
                "display_width_pt must be between {MIN_OVERLAY_DISPLAY_WIDTH_PT:.0} and {MAX_OVERLAY_DISPLAY_WIDTH_PT:.0}"
            ));
        }
        if self.display_id.trim().is_empty() {
            return Err("display_id must not be empty".to_string());
        }
        Ok(())
    }

    pub fn canonicalized(&self) -> Result<Self, String> {
        self.validate()?;
        Ok(Self {
            x: canonical_overlay_coordinate(self.x)?,
            y: canonical_overlay_coordinate(self.y)?,
            display_width_pt: self.display_width_pt,
            display_id: self.display_id.clone(),
        })
    }

    pub fn semantically_eq(&self, other: &Self) -> bool {
        match (self.canonicalized(), other.canonicalized()) {
            (Ok(lhs), Ok(rhs)) => lhs == rhs,
            _ => false,
        }
    }
}

pub fn canonical_overlay_coordinate(value: f64) -> Result<f64, String> {
    if !value.is_finite() || value.abs() > MAX_OVERLAY_COORDINATE_MAGNITUDE {
        return Err("x and y must be finite canonicalizable numbers".to_string());
    }
    let canonical = (value * OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT).round()
        / OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT;
    if !canonical.is_finite() {
        return Err("x and y must be finite canonicalizable numbers".to_string());
    }
    Ok(if canonical == 0.0 { 0.0 } else { canonical })
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
#[serde(deny_unknown_fields)]
pub struct GenerationForm {
    pub description: String,
    pub style: String,
    pub quality: QualityLevel,
    pub reference_images: Vec<String>,
}

pub const MAX_GENERATION_DESCRIPTION_CHARS: usize = 8_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationJobStatus {
    Pending,
    Running,
    WaitingForUser,
    Failed,
    Completed,
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationMessageRecord {
    pub id: String,
    pub job_id: String,
    pub sequence: u64,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    pub content: String,
    pub progress: f64,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diagnostic: Option<serde_json::Value>,
}

/// Compact, user-presentable evidence from the exact `.petpack` validation
/// that preceded a successful generation commit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationValidationSummary {
    pub ok: bool,
    pub state_count: usize,
    pub frame_count: usize,
    pub warning_count: usize,
}

/// Durable terminal result for a generation job. This is stored beside the
/// job rather than inferred from the current pet row, because later immutable
/// revisions must not rewrite the history of an earlier completed job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationResultSummary {
    pub result_pet_id: String,
    pub revision_id: String,
    pub validation_summary: GenerationValidationSummary,
}

/// Public operation identity used by bounded library history projections.
/// It intentionally carries no prompt, form, transcript, or provider data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationOperation {
    Create,
    Modify,
}

/// One structurally owned immutable revision exposed to the Pet Library.
/// `validated` is true only after PetCore has revalidated the exact archive;
/// only those entries may be selected as an edit baseline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetRevisionHistoryRecord {
    pub revision_id: String,
    pub current: bool,
    pub validated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validation_summary: Option<GenerationValidationSummary>,
}

/// Privacy-minimized job history for the Pet Library. Job workspaces, App
/// Server session IDs, forms, prompts, and messages remain private.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationJobHistoryRecord {
    pub job_id: String,
    pub status: GenerationJobStatus,
    pub operation: GenerationOperation,
    /// Exact owned immutable revision submitted as an edit baseline. Create
    /// jobs and legacy/current-head edits that predate explicit baselines omit
    /// this identity. No edit-context path or instruction is projected.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseline_revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validation_summary: Option<GenerationValidationSummary>,
    pub created_at: String,
    pub updated_at: String,
}

/// Bounded, typed projection consumed by the native Pet Library history
/// sheet. This is an internal RPC view and is never embedded in `.petpack`
/// exports or package metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetHistorySnapshot {
    pub ok: bool,
    pub pet_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_revision_id: Option<String>,
    pub revisions: Vec<PetRevisionHistoryRecord>,
    pub jobs: Vec<GenerationJobHistoryRecord>,
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerationSessionSnapshot {
    pub job_id: String,
    pub status: GenerationJobStatus,
    pub form: GenerationForm,
    /// Number of original user-selected references that could not be restored
    /// from validated private job copies and must be selected again. This is
    /// bounded by the generation reference-image limit.
    #[serde(default)]
    pub reference_reselection_count: usize,
    pub session_id: Option<String>,
    pub result_pet_id: Option<String>,
    /// Public create/modify identity for the active generation. Legacy
    /// snapshots omit this field and decode it as `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation: Option<GenerationOperation>,
    /// Exact owned immutable revision selected as the edit baseline. This is
    /// absent for create jobs and legacy/current-head edits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub baseline_revision_id: Option<String>,
    pub owner_instance_id: Option<String>,
    pub heartbeat_at: String,
    pub message_revision: String,
    pub messages: Vec<GenerationMessageRecord>,
    pub input_request: Option<GenerationMessageRecord>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PetOrigin {
    #[default]
    ExternalImport,
    GeneratedByPetcoreJob,
    VerifiedSkillSource,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PetSummary {
    pub id: String,
    pub name: String,
    pub style: String,
    pub quality: QualityLevel,
    pub render_size: RenderSize,
    pub states: Vec<PetState>,
    pub petpack_path: String,
    pub cover_path: String,
    #[serde(default)]
    pub origin: PetOrigin,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generator: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance: Option<String>,
    /// The current immutable revision when the package is owned by PetCore.
    /// Legacy and externally referenced packages intentionally decode as None.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<String>,
    /// Number of structurally verified immutable revisions owned by PetCore.
    /// Zero means the package is external or revision metadata is unavailable.
    #[serde(default)]
    pub revision_count: u32,
    pub active: bool,
    pub created_at: String,
}

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

#[cfg(test)]
mod tests {
    use super::*;

    fn overlay_placement_fixture() -> serde_json::Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/overlay-placement-canonicalization-v1.json");
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn overlay_placement_shared_fixture_is_canonical_and_round_trips() {
        let fixture = overlay_placement_fixture();
        assert_eq!(
            fixture["schema_version"],
            "apc.overlay-placement-canonicalization.v1"
        );
        for case in fixture["cases"].as_array().unwrap() {
            let input: OverlayPlacement = serde_json::from_value(case["input"].clone()).unwrap();
            let expected: OverlayPlacement =
                serde_json::from_value(case["expected"].clone()).unwrap();
            let canonical = input.canonicalized().unwrap();
            assert_eq!(canonical, expected, "fixture case {}", case["id"]);
            assert_eq!(
                canonical.canonicalized().unwrap(),
                canonical,
                "fixture case {} must be idempotent",
                case["id"]
            );
            let decoded: OverlayPlacement =
                serde_json::from_str(&serde_json::to_string(&canonical).unwrap()).unwrap();
            assert_eq!(decoded.canonicalized().unwrap(), canonical);
            if canonical.x == 0.0 {
                assert!(!canonical.x.is_sign_negative());
            }
            if canonical.y == 0.0 {
                assert!(!canonical.y.is_sign_negative());
            }
        }
    }

    #[test]
    fn overlay_placement_coordinate_canonicalization_is_monotonic_and_idempotent() {
        let values = [
            -1_000_000.001953125,
            -10.001953125,
            -0.001953125,
            -0.0,
            0.001953125,
            10.001953125,
            1_000_000.001953125,
        ];
        let canonical: Vec<f64> = values
            .into_iter()
            .map(|value| canonical_overlay_coordinate(value).unwrap())
            .collect();
        assert!(canonical.windows(2).all(|pair| pair[0] <= pair[1]));
        for value in canonical {
            assert_eq!(canonical_overlay_coordinate(value).unwrap(), value);
            assert_eq!(
                value * OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT,
                (value * OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT).round()
            );
        }
        for invalid in [f64::NAN, f64::NEG_INFINITY, f64::INFINITY, f64::MAX] {
            assert!(canonical_overlay_coordinate(invalid).is_err());
        }
    }

    #[test]
    fn quality_levels_have_the_fixed_v3_render_sizes() {
        assert_eq!(
            QualityLevel::Low.render_size(),
            RenderSize {
                width: 192,
                height: 208
            }
        );
        assert_eq!(
            QualityLevel::Standard.render_size(),
            RenderSize {
                width: 384,
                height: 416
            }
        );
        assert_eq!(
            QualityLevel::High.render_size(),
            RenderSize {
                width: 576,
                height: 624
            }
        );
        assert!(QualityLevel::Low.is_studio_supported());
        assert!(QualityLevel::Standard.is_studio_supported());
        assert!(!QualityLevel::High.is_studio_supported());
    }

    #[test]
    fn behavior_settings_drop_removed_event_keys_and_fill_the_current_contract() {
        let behavior: BehaviorSettings = serde_json::from_value(serde_json::json!({
            "events": {
                "start": false,
                "tool": false,
                "waiting": true,
                "review": true,
                "done": true,
                "failed": true
            }
        }))
        .unwrap();

        assert_eq!(behavior.events.len(), 7);
        assert_eq!(behavior.events.get(&AgentEventType::Start), Some(&false));
        assert_eq!(behavior.events.get(&AgentEventType::Thinking), Some(&true));
        assert_eq!(behavior.events.get(&AgentEventType::Plan), Some(&true));
        assert_eq!(behavior.events.get(&AgentEventType::Tool), Some(&false));
        assert!(!serde_json::to_string(&behavior).unwrap().contains("review"));
    }

    #[test]
    fn overlay_placement_intent_is_a_closed_wire_enum() {
        assert_eq!(
            serde_json::to_value(OverlayPlacementIntent::ExternalReposition).unwrap(),
            serde_json::json!("external_reposition")
        );
        assert_eq!(
            serde_json::to_value(OverlayPlacementIntent::Reset).unwrap(),
            serde_json::json!("reset")
        );
        assert!(
            serde_json::from_value::<OverlayPlacementIntent>(serde_json::json!("move")).is_err()
        );
    }

    #[test]
    fn default_v3_action_timings_satisfy_the_hard_contract() {
        let states = default_pet_states();
        assert_eq!(states.len(), REQUIRED_STATES.len());
        assert_eq!(
            states
                .iter()
                .map(|state| state.frame_durations_ms.len())
                .sum::<usize>(),
            50
        );
        for state in &states {
            let warnings = state.validate().unwrap_or_else(|error| {
                panic!(
                    "{} action contract must be valid: {error}",
                    state.name.as_str()
                )
            });
            assert!(
                warnings.is_empty(),
                "{} default action must not warn: {warnings:?}",
                state.name.as_str()
            );
        }
    }

    #[test]
    fn prior_default_v3_action_timings_remain_valid() {
        let mut states = default_pet_states();
        let idle = states
            .iter_mut()
            .find(|state| state.name == PetStateName::Idle)
            .unwrap();
        idle.frame_durations_ms = vec![300, 260, 300, 640];

        let waiting = states
            .iter_mut()
            .find(|state| state.name == PetStateName::Waiting)
            .unwrap();
        waiting.frame_durations_ms = vec![150, 150, 150, 150, 170, 230];
        waiting.playback = burst_then_settle(2, 5);

        let failed = states
            .iter_mut()
            .find(|state| state.name == PetStateName::Failed)
            .unwrap();
        failed.frame_durations_ms = vec![150, 170, 190, 290];
        failed.playback = burst_then_settle(3, 3);

        assert_eq!(
            states
                .iter()
                .map(|state| state.frame_durations_ms.len())
                .sum::<usize>(),
            42
        );
        for state in &states {
            state.validate().unwrap_or_else(|error| {
                panic!(
                    "prior V3 action {} must remain valid: {error}",
                    state.name.as_str()
                )
            });
        }
    }

    #[test]
    fn timing_contract_separates_hard_failures_from_authoring_warnings() {
        let soft_warning = PetTimingContract {
            frame_durations_ms: vec![500; 3],
            playback: PlaybackContract {
                mode: PlaybackMode::Loop,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
            reduced_motion_frame_index: 1,
        };
        let warnings = soft_warning.validate().unwrap();
        assert!(warnings.iter().any(|warning| warning.contains("4–8")));

        let invalid = PetTimingContract {
            frame_durations_ms: vec![49, 100],
            ..soft_warning
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn all_five_v3_playback_modes_have_valid_typed_contracts() {
        let cases = [
            PlaybackContract {
                mode: PlaybackMode::Loop,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
            PlaybackContract {
                mode: PlaybackMode::Periodic,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: Some([2_000, 4_000]),
            },
            PlaybackContract {
                mode: PlaybackMode::BurstThenSettle,
                entry_repeat_count: Some(2),
                settle_frame_index: Some(1),
                cooldown_ms: None,
            },
            PlaybackContract {
                mode: PlaybackMode::BurstThenIdle,
                entry_repeat_count: Some(3),
                settle_frame_index: None,
                cooldown_ms: None,
            },
            PlaybackContract {
                mode: PlaybackMode::OnceThenReturn,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
        ];

        for playback in cases {
            let contract = PetTimingContract {
                frame_durations_ms: vec![120, 180],
                playback,
                reduced_motion_frame_index: 1,
            };
            assert!(
                contract.validate().is_ok(),
                "{:?} must satisfy its mode-specific contract",
                playback.mode
            );
        }
    }

    #[test]
    fn periodic_cooldown_enforces_the_published_single_value_bounds() {
        let contract = |cooldown_ms| PetTimingContract {
            frame_durations_ms: vec![120, 180],
            playback: PlaybackContract {
                mode: PlaybackMode::Periodic,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: Some(cooldown_ms),
            },
            reduced_motion_frame_index: 1,
        };

        for cooldown_ms in [
            [0, 0],
            [0, MAX_PERIODIC_COOLDOWN_MS],
            [MAX_PERIODIC_COOLDOWN_MS, MAX_PERIODIC_COOLDOWN_MS],
        ] {
            assert!(
                contract(cooldown_ms).validate().is_ok(),
                "published boundary {cooldown_ms:?} must be accepted"
            );
        }

        let error = contract([MAX_PERIODIC_COOLDOWN_MS + 1, MAX_PERIODIC_COOLDOWN_MS + 1])
            .validate()
            .unwrap_err();
        assert!(error.contains("must not exceed 86400000"), "{error}");
    }

    #[test]
    fn atomic_agent_events_have_a_sparse_pet_reaction_mapping() {
        assert_eq!(AgentEventType::Start.pet_reaction(), None);
        assert_eq!(AgentEventType::Start.pet_state(), PetStateName::Idle);
        assert_eq!(
            AgentEventType::Thinking.pet_reaction(),
            Some(PetStateName::Thinking)
        );
        assert_eq!(
            AgentEventType::Plan.pet_reaction(),
            Some(PetStateName::Thinking)
        );
        assert_ne!(
            AgentEventType::Thinking.zh_label(),
            AgentEventType::Plan.zh_label()
        );
    }

    #[test]
    fn onboarding_progress_is_versioned_and_has_only_forward_terminal_transitions() {
        let progress = OnboardingProgress::default();
        assert_eq!(progress.schema_version, ONBOARDING_PROGRESS_SCHEMA_VERSION);
        assert_eq!(progress.stage, OnboardingStage::ChoosePet);
        assert!(OnboardingStage::ChoosePet.can_advance_to(OnboardingStage::ConnectAgents));
        assert!(OnboardingStage::ConnectAgents.can_advance_to(OnboardingStage::Demo));
        assert!(OnboardingStage::Demo.can_advance_to(OnboardingStage::Completed));
        assert!(OnboardingStage::Demo.can_advance_to(OnboardingStage::Skipped));
        assert!(!OnboardingStage::Demo.can_advance_to(OnboardingStage::ChoosePet));
        assert!(!OnboardingStage::Completed.can_advance_to(OnboardingStage::Demo));
        assert!(OnboardingStage::Completed.is_terminal());
        assert!(OnboardingStage::Skipped.is_terminal());
    }

    #[test]
    fn pet_summary_defaults_revision_metadata() {
        let pet: PetSummary = serde_json::from_value(serde_json::json!({
            "id": "pet_external",
            "name": "External",
            "style": "pixel",
            "quality": "standard",
            "render_size": { "width": 384, "height": 416 },
            "states": default_pet_states(),
            "petpack_path": "/external.petpack",
            "cover_path": "",
            "active": false,
            "created_at": "2026-07-21T00:00:00Z"
        }))
        .unwrap();

        assert_eq!(pet.revision_id, None);
        assert_eq!(pet.revision_count, 0);
    }

    #[test]
    fn active_generation_snapshot_round_trips_operation_and_baseline_revision() {
        let current = serde_json::json!({
            "job_id": "job_modify",
            "status": "running",
            "form": {
                "description": "Refine the ears",
                "style": "pixel",
                "quality": "standard",
                "reference_images": []
            },
            "reference_reselection_count": 0,
            "session_id": "session_1",
            "result_pet_id": "pet_1",
            "operation": "modify",
            "baseline_revision_id": "revision_1",
            "owner_instance_id": "instance_1",
            "heartbeat_at": "2026-07-21T00:00:00Z",
            "message_revision": "4",
            "messages": [],
            "input_request": null
        });

        let snapshot: GenerationSessionSnapshot = serde_json::from_value(current.clone()).unwrap();
        assert_eq!(snapshot.operation, Some(GenerationOperation::Modify));
        assert_eq!(snapshot.baseline_revision_id.as_deref(), Some("revision_1"));
        assert_eq!(snapshot.reference_reselection_count, 0);
        assert_eq!(serde_json::to_value(snapshot).unwrap(), current);
    }

    #[test]
    fn legacy_active_generation_snapshot_defaults_edit_identity() {
        let snapshot: GenerationSessionSnapshot = serde_json::from_value(serde_json::json!({
            "job_id": "job_legacy",
            "status": "pending",
            "form": {
                "description": "Create a companion",
                "style": "pixel",
                "quality": "standard",
                "reference_images": []
            },
            "session_id": null,
            "result_pet_id": null,
            "owner_instance_id": null,
            "heartbeat_at": "2026-07-21T00:00:00Z",
            "message_revision": "0",
            "messages": [],
            "input_request": null
        }))
        .unwrap();

        assert_eq!(snapshot.operation, None);
        assert_eq!(snapshot.baseline_revision_id, None);
        assert_eq!(snapshot.reference_reselection_count, 0);
        let encoded = serde_json::to_value(snapshot).unwrap();
        assert!(encoded.get("operation").is_none());
        assert!(encoded.get("baseline_revision_id").is_none());
    }

    #[test]
    fn connector_management_capabilities_decode_legacy_and_current_payloads() {
        let legacy: AgentConnectorCapabilities = serde_json::from_value(serde_json::json!({
            "contract_version": "legacy-v1"
        }))
        .unwrap();
        assert_eq!(legacy.repairable_connector_issue, None);
        assert_eq!(legacy.managed_path_conflict, None);
        assert_eq!(legacy.can_uninstall_managed_connector, None);

        let current: AgentConnectorCapabilities = serde_json::from_value(serde_json::json!({
            "repairable_connector_issue": true,
            "managed_path_conflict": false,
            "can_uninstall_managed_connector": true
        }))
        .unwrap();
        assert_eq!(current.repairable_connector_issue, Some(true));
        assert_eq!(current.managed_path_conflict, Some(false));
        assert_eq!(current.can_uninstall_managed_connector, Some(true));
    }

    #[test]
    fn connection_check_serialization_emits_typed_code_and_row_recovery() {
        let item = ConnectionCheckItem::new(
            ConnectionCheckCode::ProjectDirectory,
            "检查目录访问",
            CheckStatus::NeedsFix,
            "任意中文技术信息",
            Some(ConnectionCheckRecoveryAction::ChooseProjectDirectory),
        );
        let value = serde_json::to_value(&item).unwrap();
        assert_eq!(value["code"], "project_directory");
        assert_eq!(value["recovery_action"], "choose_project_directory");

        let renamed = ConnectionCheckItem::new(
            ConnectionCheckCode::ProjectDirectory,
            "Project workspace access v3",
            CheckStatus::NeedsFix,
            "renamed backend detail",
            Some(ConnectionCheckRecoveryAction::ChooseProjectDirectory),
        );
        let renamed_value = serde_json::to_value(&renamed).unwrap();
        assert_eq!(renamed_value["code"], value["code"]);
        assert_eq!(renamed_value["recovery_action"], value["recovery_action"]);

        let claude_policy = ConnectionCheckItem::new(
            ConnectionCheckCode::ClaudeHooksPolicy,
            "renamed backend policy row",
            CheckStatus::NeedsFix,
            "backend-only policy detail",
            Some(ConnectionCheckRecoveryAction::Recheck),
        );
        let claude_policy_value = serde_json::to_value(&claude_policy).unwrap();
        assert_eq!(claude_policy_value["code"], "claude_hooks_policy");
        assert_eq!(claude_policy_value["recovery_action"], "recheck");

        let legacy: ConnectionCheckItem = serde_json::from_value(serde_json::json!({
            "name": "旧检查项",
            "status": "unverified",
            "detail": "legacy"
        }))
        .unwrap();
        assert_eq!(legacy.code, ConnectionCheckCode::Unknown);
        assert_eq!(legacy.recovery_action, None);

        let unknown: ConnectionCheckItem = serde_json::from_value(serde_json::json!({
            "code": "future_policy_probe",
            "name": "Future policy probe",
            "status": "needs_fix",
            "detail": "future",
            "recovery_action": "future_privileged_mutation"
        }))
        .unwrap();
        assert_eq!(unknown.code, ConnectionCheckCode::Unknown);
        assert_eq!(
            unknown.recovery_action,
            Some(ConnectionCheckRecoveryAction::Recheck)
        );
    }
}
