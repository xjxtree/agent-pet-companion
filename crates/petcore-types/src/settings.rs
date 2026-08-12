use crate::{AgentEventType, AgentSource};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const ONBOARDING_PROGRESS_SCHEMA_VERSION: &str = "apc.onboarding-progress.v1";
pub const MIN_OVERLAY_DISPLAY_WIDTH_PT: f64 = 100.0;
pub const MAX_OVERLAY_DISPLAY_WIDTH_PT: f64 = 300.0;
pub const DEFAULT_OVERLAY_DISPLAY_WIDTH_PT: f64 = 112.0;
pub const OVERLAY_DISPLAY_WIDTH_STEP_PT: f64 = 1.0;
pub const OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT: f64 = 256.0;
pub const OVERLAY_PLACEMENT_QUANTUM_PT: f64 = 1.0 / OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT;
pub const MAX_OVERLAY_COORDINATE_MAGNITUDE: f64 = f64::MAX / OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT;
pub const DEFAULT_SESSION_MESSAGE_TIMEOUT_MINUTES: u16 = 15;
pub const MIN_SESSION_MESSAGE_TIMEOUT_MINUTES: u16 = 1;
pub const MAX_SESSION_MESSAGE_TIMEOUT_MINUTES: u16 = 1_440;
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
            #[serde(rename = "mouse_passthrough")]
            _mouse_passthrough: Option<bool>,
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
            // Kept in the serialized shape for mixed-version compatibility,
            // but legacy `false` values no longer change runtime behavior.
            mouse_passthrough: true,
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
            group_sessions_by_agent: false,
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
