use petcore_types::{AgentEvent, AgentEventType, AgentSource, BehaviorSettings, PetStateName};
use serde::Serialize;
use std::collections::BTreeMap;
use time::{format_description::well_known::Rfc3339, Duration, OffsetDateTime};

pub const ACTIVITY_LEASE_SECONDS: i64 = 30;
pub const TERMINAL_LEASE_SECONDS: i64 = 5;
pub const MAX_DISPLAY_AGENT_SESSIONS: usize = 8;
const FUTURE_EVENT_GRACE_SECONDS: i64 = 60;

#[derive(Debug, Clone)]
pub struct SequencedAgentEvent {
    pub event: AgentEvent,
    pub source_session_sequence: u64,
    pub session_activated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionDisplayMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionActivity {
    pub kind: String,
    pub content: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ActiveAgentState {
    pub state: PetStateName,
    pub official_status: String,
    pub source: AgentSource,
    pub session_id: Option<String>,
    pub session_active: bool,
    pub source_session_sequence: u64,
    pub priority: u16,
    pub lease_seconds: Option<i64>,
    pub expires_at: Option<String>,
    pub session_activated_at: Option<String>,
    pub event: AgentEvent,
    pub latest_message: Option<AgentEvent>,
    pub latest_user_message: Option<AgentEvent>,
    pub session_title: Option<String>,
    pub session_message: Option<SessionDisplayMessage>,
    pub session_user_message: Option<SessionDisplayMessage>,
    pub session_activity: Option<SessionActivity>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct OverlayVisibility {
    pub pet_visible: bool,
    pub status_bubble_visible: bool,
}

struct TimedCandidate<'a> {
    candidate: &'a SequencedAgentEvent,
    created_at: OffsetDateTime,
}

/// Selects the single canonical agent state in two phases:
///
/// 1. Event time and persisted sequence select the newest event for each
///    source/session, even if an older event arrived later.
/// 2. Current, enabled session states are compared by product priority, then
///    event time and persisted sequence.
///
/// Expiration happens after phase one so an expired terminal event closes its
/// session instead of allowing older activity to reappear.
pub fn select_active_agent_state(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
) -> Option<ActiveAgentState> {
    if !behavior.enabled {
        return None;
    }

    latest_candidates_by_session(candidates, now)
        .into_values()
        .filter(|candidate| event_enabled(behavior, &candidate.candidate.event))
        .filter(|candidate| {
            event_session_active(&candidate.candidate.event) == Some(true)
                || candidate.created_at
                    + Duration::seconds(event_lease_seconds_for_behavior(
                        behavior,
                        &candidate.candidate.event,
                    ))
                    >= now
        })
        .max_by_key(|candidate| {
            (
                event_priority(candidate.candidate.event.event_type),
                candidate.created_at,
                candidate.candidate.source_session_sequence,
                candidate.candidate.event.source,
            )
        })
        .map(|candidate| active_state_from_candidate(behavior, candidate, candidates))
}

/// Returns the bounded set of sessions that should be rendered in status
/// bubbles. Waiting-for-user and failed sessions remain visible until a newer
/// event replaces them; ordinary sessions are hidden after the configured
/// interval and reappear when the next user activation/start event arrives.
pub fn select_display_agent_states(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
) -> Vec<ActiveAgentState> {
    if !behavior.enabled {
        return Vec::new();
    }

    let timeout = Duration::minutes(i64::from(behavior.session_message_timeout_minutes));
    let mut visible = latest_candidates_by_session(candidates, now)
        .into_values()
        .filter(|candidate| event_enabled(behavior, &candidate.candidate.event))
        .filter(|candidate| {
            let event = &candidate.candidate.event;
            match event.event_type {
                AgentEventType::Failed => true,
                AgentEventType::Waiting => match event_session_active(event) {
                    Some(active) => active,
                    None => {
                        candidate.created_at
                            + Duration::seconds(event_lease_seconds(event.event_type))
                            >= now
                    }
                },
                AgentEventType::Start
                | AgentEventType::Tool
                | AgentEventType::Review
                | AgentEventType::Done => session_activation_time(candidate)
                    .is_some_and(|activated_at| activated_at + timeout >= now),
            }
        })
        .collect::<Vec<_>>();
    visible.sort_by_key(|candidate| {
        std::cmp::Reverse((
            candidate.created_at,
            candidate.candidate.source_session_sequence,
            candidate.candidate.event.source,
        ))
    });
    visible
        .into_iter()
        .take(MAX_DISPLAY_AGENT_SESSIONS)
        .map(|candidate| active_state_from_candidate(behavior, candidate, candidates))
        .collect()
}

pub fn overlay_visibility(
    behavior: &BehaviorSettings,
    active_agent_state: Option<&ActiveAgentState>,
) -> OverlayVisibility {
    let pet_visible = behavior.enabled;
    let status_bubble_visible = pet_visible
        && behavior.status_bubble
        && (!behavior.auto_hide || active_agent_state.is_some());
    OverlayVisibility {
        pet_visible,
        status_bubble_visible,
    }
}

pub fn overlay_visibility_for_sessions(
    behavior: &BehaviorSettings,
    has_display_sessions: bool,
    has_canonical_state: bool,
) -> OverlayVisibility {
    let pet_visible = behavior.enabled;
    let status_bubble_visible = pet_visible
        && behavior.status_bubble
        && (has_display_sessions || (!behavior.auto_hide && !has_canonical_state));
    OverlayVisibility {
        pet_visible,
        status_bubble_visible,
    }
}

pub fn event_lease_seconds(event_type: AgentEventType) -> i64 {
    match event_type {
        AgentEventType::Done | AgentEventType::Failed => TERMINAL_LEASE_SECONDS,
        AgentEventType::Start
        | AgentEventType::Tool
        | AgentEventType::Waiting
        | AgentEventType::Review => ACTIVITY_LEASE_SECONDS,
    }
}

fn event_priority(event_type: AgentEventType) -> u16 {
    match event_type {
        // Match the official Pets ordering: Needs input > Blocked > Ready > Running.
        AgentEventType::Waiting => 600,
        AgentEventType::Failed => 500,
        AgentEventType::Review | AgentEventType::Done => 400,
        AgentEventType::Tool | AgentEventType::Start => 300,
    }
}

fn latest_candidates_by_session<'a>(
    candidates: &'a [SequencedAgentEvent],
    now: OffsetDateTime,
) -> BTreeMap<(AgentSource, String), TimedCandidate<'a>> {
    let mut latest_by_session = BTreeMap::new();
    for candidate in candidates {
        if event_is_diagnostic(&candidate.event) {
            continue;
        }
        let Ok(created_at) = OffsetDateTime::parse(&candidate.event.created_at, &Rfc3339) else {
            continue;
        };
        if created_at - now > Duration::seconds(FUTURE_EVENT_GRACE_SECONDS) {
            continue;
        }
        let key = (
            candidate.event.source,
            normalized_session_key(candidate.event.session_id.as_deref()),
        );
        let replace = latest_by_session
            .get(&key)
            .is_none_or(|current: &TimedCandidate<'_>| {
                (created_at, candidate.source_session_sequence)
                    > (
                        current.created_at,
                        current.candidate.source_session_sequence,
                    )
            });
        if replace {
            latest_by_session.insert(
                key,
                TimedCandidate {
                    candidate,
                    created_at,
                },
            );
        }
    }
    latest_by_session
}

fn session_activation_time(candidate: &TimedCandidate<'_>) -> Option<OffsetDateTime> {
    let activated_at = candidate
        .candidate
        .session_activated_at
        .as_deref()
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok());
    Some(
        activated_at
            .map(|activated_at| activated_at.max(candidate.created_at))
            .unwrap_or(candidate.created_at),
    )
}

fn active_state_from_candidate(
    behavior: &BehaviorSettings,
    candidate: TimedCandidate<'_>,
    candidates: &[SequencedAgentEvent],
) -> ActiveAgentState {
    let event = &candidate.candidate.event;
    let session_active = event_session_active(event) == Some(true);
    let lease_seconds =
        (!session_active).then(|| event_lease_seconds_for_behavior(behavior, event));
    let expires_at = lease_seconds.map(|lease_seconds| {
        (candidate.created_at + Duration::seconds(lease_seconds))
            .format(&Rfc3339)
            .unwrap_or_else(|_| event.created_at.clone())
    });
    let latest_message =
        latest_message_for_session(candidates, event.source, event.session_id.as_deref());
    ActiveAgentState {
        state: event.event_type.pet_state(),
        official_status: official_status(event.event_type).to_string(),
        source: event.source,
        session_id: event.session_id.clone(),
        session_active,
        source_session_sequence: candidate.candidate.source_session_sequence,
        priority: event_priority(event.event_type),
        lease_seconds,
        expires_at,
        session_activated_at: candidate.candidate.session_activated_at.clone(),
        event: event.clone(),
        latest_message,
        latest_user_message: None,
        session_title: None,
        session_message: None,
        session_user_message: None,
        session_activity: event_activity(event),
    }
}

fn event_activity(event: &AgentEvent) -> Option<SessionActivity> {
    let kind = event
        .payload_json
        .get("activity_kind")
        .and_then(serde_json::Value::as_str)?
        .trim();
    if kind.is_empty() {
        return None;
    }
    let content = event
        .payload_json
        .get("activity_content")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    Some(SessionActivity {
        kind: kind.to_string(),
        content,
    })
}

fn event_lease_seconds_for_behavior(behavior: &BehaviorSettings, event: &AgentEvent) -> i64 {
    if event
        .payload_json
        .get("source_event")
        .and_then(serde_json::Value::as_str)
        == Some("app_server_activity")
        && matches!(
            event.event_type,
            AgentEventType::Start
                | AgentEventType::Tool
                | AgentEventType::Review
                | AgentEventType::Done
        )
    {
        return i64::from(behavior.session_message_timeout_minutes).saturating_mul(60);
    }
    event_lease_seconds(event.event_type)
}

fn official_status(event_type: AgentEventType) -> &'static str {
    match event_type {
        AgentEventType::Start | AgentEventType::Tool => "running",
        AgentEventType::Waiting => "needs_input",
        AgentEventType::Review | AgentEventType::Done => "ready",
        AgentEventType::Failed => "blocked",
    }
}

fn event_enabled(behavior: &BehaviorSettings, event: &AgentEvent) -> bool {
    behavior
        .sources
        .get(&event.source)
        .copied()
        .unwrap_or(false)
        && behavior
            .events
            .get(&event.event_type)
            .copied()
            .unwrap_or(false)
}

fn event_is_diagnostic(event: &AgentEvent) -> bool {
    event
        .payload_json
        .get("diagnostic")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

pub fn event_session_active(event: &AgentEvent) -> Option<bool> {
    event
        .payload_json
        .get("session_active")
        .and_then(serde_json::Value::as_bool)
}

fn latest_message_for_session(
    candidates: &[SequencedAgentEvent],
    source: AgentSource,
    session_id: Option<&str>,
) -> Option<AgentEvent> {
    let session_key = normalized_session_key(session_id);
    candidates
        .iter()
        .filter(|candidate| {
            !event_is_diagnostic(&candidate.event)
                && candidate.event.source == source
                && normalized_session_key(candidate.event.session_id.as_deref()) == session_key
                && candidate
                    .event
                    .payload_json
                    .get("message_content")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|message| !message.trim().is_empty())
        })
        .filter_map(|candidate| {
            OffsetDateTime::parse(&candidate.event.created_at, &Rfc3339)
                .ok()
                .map(|created_at| (created_at, candidate))
        })
        .max_by_key(|(created_at, candidate)| (*created_at, candidate.source_session_sequence))
        .map(|(_, candidate)| candidate.event.clone())
}

fn normalized_session_key(session_id: Option<&str>) -> String {
    session_id
        .map(str::trim)
        .filter(|session_id| !session_id.is_empty())
        .unwrap_or("__no_session__")
        .to_string()
}
