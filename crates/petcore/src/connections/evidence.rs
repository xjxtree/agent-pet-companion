use super::manager::{
    CLAUDE_TASK_ACTIVITY_EVENTS, CLAUDE_TASK_COMPLETION_EVENTS, CLAUDE_TASK_START_EVENTS,
    CODEX_TASK_ACTIVITY_EVENTS, CODEX_TASK_COMPLETION_EVENTS, CODEX_TASK_START_EVENTS,
    OPENCODE_TASK_ACTIVITY_EVENTS, OPENCODE_TASK_COMPLETION_EVENTS, OPENCODE_TASK_START_EVENTS,
    PI_TASK_ACTIVITY_EVENTS, PI_TASK_COMPLETION_EVENTS, PI_TASK_START_EVENTS,
};
use petcore_types::AgentSource;

pub(crate) fn task_evidence_events(
    source: AgentSource,
) -> (
    &'static [&'static str],
    &'static [&'static str],
    &'static [&'static str],
) {
    match source {
        AgentSource::Codex => (
            CODEX_TASK_START_EVENTS,
            CODEX_TASK_ACTIVITY_EVENTS,
            CODEX_TASK_COMPLETION_EVENTS,
        ),
        AgentSource::ClaudeCode => (
            CLAUDE_TASK_START_EVENTS,
            CLAUDE_TASK_ACTIVITY_EVENTS,
            CLAUDE_TASK_COMPLETION_EVENTS,
        ),
        AgentSource::Pi => (
            PI_TASK_START_EVENTS,
            PI_TASK_ACTIVITY_EVENTS,
            PI_TASK_COMPLETION_EVENTS,
        ),
        AgentSource::Opencode => (
            OPENCODE_TASK_START_EVENTS,
            OPENCODE_TASK_ACTIVITY_EVENTS,
            OPENCODE_TASK_COMPLETION_EVENTS,
        ),
    }
}
