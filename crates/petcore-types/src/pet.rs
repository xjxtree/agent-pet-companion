use serde::{Deserialize, Serialize};

pub const PETPACK_SCHEMA_VERSION: &str = "apc.petpack.v3";
pub const MIN_FRAME_DURATION_MS: u32 = 50;
pub const MAX_FRAME_DURATION_MS: u32 = 2_000;
pub const MAX_STATE_DURATION_MS: u32 = 5_000;
pub const MAX_PERIODIC_COOLDOWN_MS: u32 = 86_400_000;
pub const MIN_FRAMES_PER_STATE: usize = 2;
pub const MAX_FRAMES_PER_STATE: usize = 40;
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

pub(crate) fn burst_then_settle(
    entry_repeat_count: u32,
    settle_frame_index: usize,
) -> PlaybackContract {
    PlaybackContract {
        mode: PlaybackMode::BurstThenSettle,
        entry_repeat_count: Some(entry_repeat_count),
        settle_frame_index: Some(settle_frame_index),
        cooldown_ms: None,
    }
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
