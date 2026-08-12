use crate::PetStateName;
use serde::{Deserialize, Serialize};

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
