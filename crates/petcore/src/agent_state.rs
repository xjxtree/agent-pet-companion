use petcore_types::{AgentEvent, AgentEventType, AgentSource, BehaviorSettings, PetStateName};
use serde::Serialize;
use std::collections::BTreeMap;
use time::{format_description::well_known::Rfc3339, Duration, OffsetDateTime};

pub const ACTIVITY_LEASE_SECONDS: i64 = 30;
pub const TERMINAL_LEASE_SECONDS: i64 = 5;
const FUTURE_EVENT_GRACE_SECONDS: i64 = 60;

#[derive(Debug, Clone)]
pub struct SequencedAgentEvent {
    pub event: AgentEvent,
    pub source_session_sequence: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ActiveAgentState {
    pub state: PetStateName,
    pub source: AgentSource,
    pub session_id: Option<String>,
    pub source_session_sequence: u64,
    pub priority: u16,
    pub lease_seconds: i64,
    pub expires_at: String,
    pub event: AgentEvent,
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

    let mut latest_by_session = BTreeMap::<(AgentSource, String), TimedCandidate<'_>>::new();
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
        let replace = latest_by_session.get(&key).is_none_or(|current| {
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
        .into_values()
        .filter(|candidate| event_enabled(behavior, &candidate.candidate.event))
        .filter(|candidate| {
            candidate.created_at
                + Duration::seconds(event_lease_seconds(candidate.candidate.event.event_type))
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
        .map(|candidate| {
            let event = &candidate.candidate.event;
            let lease_seconds = event_lease_seconds(event.event_type);
            let expires_at = (candidate.created_at + Duration::seconds(lease_seconds))
                .format(&Rfc3339)
                .unwrap_or_else(|_| event.created_at.clone());
            ActiveAgentState {
                state: event.event_type.pet_state(),
                source: event.source,
                session_id: event.session_id.clone(),
                source_session_sequence: candidate.candidate.source_session_sequence,
                priority: event_priority(event.event_type),
                lease_seconds,
                expires_at,
                event: event.clone(),
            }
        })
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
        AgentEventType::Failed => 600,
        AgentEventType::Waiting => 500,
        AgentEventType::Review => 400,
        AgentEventType::Tool => 300,
        AgentEventType::Start => 200,
        AgentEventType::Done => 100,
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

fn normalized_session_key(session_id: Option<&str>) -> String {
    session_id
        .map(str::trim)
        .filter(|session_id| !session_id.is_empty())
        .unwrap_or("__no_session__")
        .to_string()
}
