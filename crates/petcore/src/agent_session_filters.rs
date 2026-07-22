use petcore_types::{AgentEvent, AgentSource};

pub const CODEX_INTERNAL_SUGGESTIONS_REASON: &str = "codex_internal_suggestions";

const CODEX_INTERNAL_SUGGESTIONS_PREFIX: &str =
    "# Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project:";

/// Codex Desktop runs short-lived background turns to prepare suggested next
/// actions. Those turns emit the same public hooks as a user conversation but
/// are not persisted as resumable rollouts. Until the upstream hook schema
/// exposes explicit provenance, keep this recognizer deliberately narrow and
/// anchored to the complete, normalized prompt prefix.
pub fn is_codex_internal_suggestions_prompt(message: &str) -> bool {
    let normalized = message.split_whitespace().collect::<Vec<_>>().join(" ");
    normalized.starts_with(CODEX_INTERNAL_SUGGESTIONS_PREFIX)
}

pub fn suppressed_agent_session_reason(event: &AgentEvent) -> Option<&'static str> {
    if event.source != AgentSource::Codex
        || event
            .payload_json
            .get("source_event")
            .and_then(serde_json::Value::as_str)
            != Some("UserPromptSubmit")
        || event
            .payload_json
            .get("message_role")
            .and_then(serde_json::Value::as_str)
            != Some("user")
    {
        return None;
    }
    event
        .payload_json
        .get("message_content")
        .and_then(serde_json::Value::as_str)
        .filter(|message| is_codex_internal_suggestions_prompt(message))
        .map(|_| CODEX_INTERNAL_SUGGESTIONS_REASON)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_only_the_anchored_internal_suggestions_prompt() {
        assert!(is_codex_internal_suggestions_prompt(
            "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project\n\n# Rules"
        ));
        assert!(is_codex_internal_suggestions_prompt(
            "  # Overview   Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project"
        ));
        assert!(!is_codex_internal_suggestions_prompt(
            "Please analyze this text: # Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project"
        ));
        assert!(!is_codex_internal_suggestions_prompt(
            "# Overview\nGenerate project suggestions for this user"
        ));
    }
}
