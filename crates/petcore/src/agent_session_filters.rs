use petcore_types::{AgentEvent, AgentSource};
use serde_json::Value;

pub const CODEX_INTERNAL_SUGGESTIONS_REASON: &str = "codex_internal_suggestions";
pub const PET_STUDIO_INTERNAL_SESSION_REASON: &str = "pet_studio_internal_session";
pub const AGENT_CHILD_SESSION_REASON: &str = "agent_child_session";
pub const AGENT_CHILD_SESSION_SOURCE_EVENT: &str = "session.child";

const CODEX_INTERNAL_SUGGESTIONS_PREFIXES: [&str; 2] = [
    "# Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project:",
    "# Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this Projectless task",
];

/// Codex Desktop runs short-lived background turns to prepare suggested next
/// actions. Those turns emit the same public hooks as a user conversation but
/// are not persisted as resumable rollouts. Until the upstream hook schema
/// exposes explicit provenance, keep this recognizer deliberately narrow and
/// anchored to the complete, normalized prompt prefixes observed for local
/// projects and Projectless tasks.
pub fn is_codex_internal_suggestions_prompt(message: &str) -> bool {
    let normalized = message.split_whitespace().collect::<Vec<_>>().join(" ");
    CODEX_INTERNAL_SUGGESTIONS_PREFIXES
        .iter()
        .any(|prefix| normalized.starts_with(prefix))
}

/// Recognizes the same internal task at both Codex ingress boundaries. Public
/// hooks carry the original user prompt, while App Server persistence can omit
/// that item and expose only the prompt-derived thread title.
pub fn is_codex_internal_suggestions_payload(payload: &Value) -> bool {
    let source_event = payload.get("source_event").and_then(Value::as_str);
    let user_prompt_matches = payload.get("message_role").and_then(Value::as_str) == Some("user")
        && payload
            .get("message_content")
            .and_then(Value::as_str)
            .is_some_and(is_codex_internal_suggestions_prompt);

    match source_event {
        Some("UserPromptSubmit") => user_prompt_matches,
        Some("app_server_activity") => {
            user_prompt_matches
                || payload
                    .get("session_title")
                    .and_then(Value::as_str)
                    .is_some_and(is_codex_internal_suggestions_prompt)
        }
        _ => false,
    }
}

pub fn suppressed_agent_session_reason(event: &AgentEvent) -> Option<&'static str> {
    if event
        .payload_json
        .get("source_event")
        .and_then(Value::as_str)
        == Some(AGENT_CHILD_SESSION_SOURCE_EVENT)
    {
        return Some(AGENT_CHILD_SESSION_REASON);
    }
    if event.source != AgentSource::Codex
        || !is_codex_internal_suggestions_payload(&event.payload_json)
    {
        return None;
    }
    Some(CODEX_INTERNAL_SUGGESTIONS_REASON)
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
        assert!(is_codex_internal_suggestions_prompt(
            "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this Projectless task\n\nGet an understanding of the user's intent"
        ));
        assert!(!is_codex_internal_suggestions_prompt(
            "Please analyze this text: # Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project"
        ));
        assert!(!is_codex_internal_suggestions_prompt(
            "# Overview\nGenerate project suggestions for this user"
        ));
    }

    #[test]
    fn recognizes_title_only_app_server_suggestion_activity() {
        assert!(is_codex_internal_suggestions_payload(&serde_json::json!({
            "source_event": "app_server_activity",
            "session_title": "# Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project",
            "message_role": "assistant",
            "message_content": "{\"suggestions\":[]}"
        })));
        assert!(!is_codex_internal_suggestions_payload(&serde_json::json!({
            "source_event": "app_server_activity",
            "session_title": "Analyze this # Overview Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project:",
            "message_role": "assistant"
        })));
    }

    #[test]
    fn recognizes_structured_child_session_markers_for_every_agent() {
        for source in [
            AgentSource::Codex,
            AgentSource::ClaudeCode,
            AgentSource::Pi,
            AgentSource::Opencode,
            AgentSource::Dsh,
        ] {
            let event = AgentEvent {
                id: "child-marker".to_string(),
                source,
                project_path: None,
                session_id: Some("child-session".to_string()),
                event_type: petcore_types::AgentEventType::Start,
                title: "start".to_string(),
                detail: None,
                payload_json: serde_json::json!({
                    "source_event": AGENT_CHILD_SESSION_SOURCE_EVENT
                }),
                created_at: "2026-08-06T00:00:00Z".to_string(),
            };
            assert_eq!(
                suppressed_agent_session_reason(&event),
                Some(AGENT_CHILD_SESSION_REASON)
            );
        }
    }
}
