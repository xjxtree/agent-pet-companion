use crate::adapter_contracts::normalize_agent_activity_content_for_kind;
use crate::enum_name;
use crate::event_envelope::{
    event_affects_activity, event_requires_prior_user_activation, event_starts_new_activity_epoch,
    validated_warp_focus_url,
};
use petcore_types::{AgentEvent, AgentEventType, AgentSource, BehaviorSettings, PetStateName};
use serde::{ser::SerializeStruct, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use time::{format_description::well_known::Rfc3339, Duration, OffsetDateTime};

pub const ACTIVITY_LEASE_SECONDS: i64 = 30;
pub const TERMINAL_LEASE_SECONDS: i64 = 5;
pub const MAX_DISPLAY_AGENT_SESSIONS: usize = 8;
const FUTURE_EVENT_GRACE_SECONDS: i64 = 60;

#[derive(Debug, Clone)]
pub struct SequencedAgentEvent {
    pub event: AgentEvent,
    pub source_session_sequence: u64,
    /// Stable PetCore-owned alias authority for this source/session. The
    /// sequence is allocated independently of event/display ordering and is
    /// never derived from the host's raw session identifier.
    pub session_alias_sequence: Option<u64>,
    pub session_activated_at: Option<String>,
    pub session_first_seen_at: Option<String>,
    pub latest_terminal_navigation_payload: Option<serde_json::Value>,
    /// External identities of every successful terminal edge in the selected
    /// activity epoch. Claude Desktop may emit more than one process-level
    /// `SessionEnd` for one durable conversation; acknowledging any one of
    /// those tails consumes the whole completed epoch without consuming the
    /// next real activation.
    pub completion_epoch_event_ids: Vec<String>,
    /// A source-matching App origin observed in the selected activity epoch.
    /// Tail hooks do not always inherit the desktop marker, so this trusted
    /// origin wins over a later marker-free CLI fallback for the same epoch.
    pub preferred_app_navigation_payload: Option<serde_json::Value>,
    /// Identity of the tool activity run this event belongs to. One run is the
    /// uninterrupted stretch of tool events carrying the same closed activity
    /// subtype, so the renderer can replay a bounded burst for genuinely new
    /// tool work without restarting on continued traffic for the same activity.
    pub tool_activity_run_marker: Option<String>,
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

#[derive(Debug, Clone)]
pub struct ActiveAgentState {
    pub state: PetStateName,
    pub official_status: String,
    pub source: AgentSource,
    pub session_id: Option<String>,
    pub session_active: bool,
    pub source_session_sequence: u64,
    pub session_alias_sequence: Option<u64>,
    pub anonymous_session_alias: Option<String>,
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
    pub overlay_display: OverlaySessionDisplay,
}

/// Closed structural projection consumed by the desktop overlay. The
/// separately hydrated, bounded session title, user/assistant messages, and
/// provider-visible activity summary supply the single retained bubble body
/// message and its independent status. Arbitrary raw event fields are not
/// duplicated into this projection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OverlaySessionDisplay {
    pub summary_kind: OverlaySummaryKind,
    pub navigation: OverlaySessionNavigation,
    /// Opaque animation identity. This lets the App coalesce repeated host
    /// events without inspecting the raw payload that produced the state.
    pub state_entry_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OverlaySummaryKind {
    Start,
    Thinking,
    Plan,
    Command,
    File,
    FileChange,
    Tool,
    Subagent,
    Search,
    Network,
    Image,
    Compaction,
    NeedsInput,
    Done,
    Failed,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OverlayNavigationCapability {
    ExactSession,
    AgentHost,
    #[default]
    Unavailable,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct OverlaySessionNavigation {
    pub capability: OverlayNavigationCapability,
    pub session_open: Option<bool>,
    pub surface: Option<String>,
    pub terminal_app: Option<String>,
    pub open_url: Option<String>,
    /// Raw host session identity is never projected generically. An audited
    /// App deep link may expose only its canonical UUID in this dedicated
    /// routing field.
    pub routable_session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OverlayEventProjection {
    id: String,
    source: AgentSource,
    session_id: Option<String>,
    event_type: AgentEventType,
    title: &'static str,
    created_at: String,
}

impl Serialize for ActiveAgentState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let session_id = self.session_id.as_deref().map(opaque_session_id);
        let event = overlay_event_projection(&self.event);
        let acknowledgement_id = session_acknowledgement_id(&self.event);
        let mut state = serializer.serialize_struct("ActiveAgentState", 18)?;
        state.serialize_field("state", &self.state)?;
        state.serialize_field("official_status", &self.official_status)?;
        state.serialize_field("source", &self.source)?;
        state.serialize_field("session_id", &session_id)?;
        state.serialize_field("session_active", &self.session_active)?;
        state.serialize_field("source_session_sequence", &self.source_session_sequence)?;
        state.serialize_field("anonymous_session_alias", &self.anonymous_session_alias)?;
        state.serialize_field("priority", &self.priority)?;
        state.serialize_field("lease_seconds", &self.lease_seconds)?;
        state.serialize_field("expires_at", &self.expires_at)?;
        state.serialize_field("session_activated_at", &self.session_activated_at)?;
        state.serialize_field("session_title", &self.session_title)?;
        state.serialize_field("session_message", &self.session_message)?;
        state.serialize_field("session_user_message", &self.session_user_message)?;
        state.serialize_field("session_activity", &self.session_activity)?;
        state.serialize_field("acknowledgement_id", &acknowledgement_id)?;
        state.serialize_field("event", &event)?;
        state.serialize_field("overlay_display", &self.overlay_display)?;
        state.end()
    }
}

/// Converts a stored/audited event to the compact embedded event shape used by
/// the App snapshot. Bounded session display fields are serialized separately
/// on `ActiveAgentState`; `events.recent` remains the distinct stored-event
/// audit RPC.
pub fn overlay_event_projection(event: &AgentEvent) -> OverlayEventProjection {
    OverlayEventProjection {
        id: opaque_event_id(&event.id),
        source: event.source,
        session_id: event.session_id.as_deref().map(opaque_session_id),
        event_type: event.event_type,
        title: event.event_type.zh_label(),
        created_at: event.created_at.clone(),
    }
}

#[derive(Debug, Clone)]
pub struct DisplayAgentStates {
    pub states: Vec<ActiveAgentState>,
    pub omitted_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct OverlayVisibility {
    pub pet_visible: bool,
    pub status_bubble_visible: bool,
}

#[derive(Clone, Copy)]
struct TimedCandidate<'a> {
    candidate: &'a SequencedAgentEvent,
    created_at: OffsetDateTime,
}

/// Selects the single canonical agent state in two phases:
///
/// 1. Event time and persisted sequence select the newest event for each
///    source/session, even if an older event arrived later.
/// 2. Needs-input and blocked states retain product priority. Ready and Running
///    are ordered by activity time so a newly active task immediately moves the
///    pet away from an older completion pose.
///
/// Ordinary expiration happens after phase one so an expired event closes its
/// session instead of allowing older activity to reappear. A host
/// `session_active` hint extends ordinary activity only through the configured
/// session window; it is not durable proof that a connector session is still
/// running. Waiting and failed attention states do not expire locally.
pub fn select_active_agent_state(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
) -> Option<ActiveAgentState> {
    select_active_agent_state_with_acknowledgements(behavior, candidates, now, &BTreeSet::new())
}

pub fn select_active_agent_state_with_acknowledgements(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
    acknowledged_session_activations: &BTreeSet<String>,
) -> Option<ActiveAgentState> {
    if !behavior.enabled {
        return None;
    }

    latest_candidates_by_session(candidates, now)
        .into_values()
        .filter(|candidate| event_enabled(behavior, &candidate.candidate.event))
        .filter(|candidate| !event_is_explicitly_closed_completion(&candidate.candidate.event))
        .filter(|candidate| terminal_event_has_prior_activation(candidate))
        .filter(|candidate| {
            !candidate_is_acknowledged(candidate.candidate, acknowledged_session_activations)
        })
        .filter(|candidate| {
            let event = &candidate.candidate.event;
            matches!(
                event.event_type,
                AgentEventType::Waiting | AgentEventType::Failed
            ) || candidate.created_at
                + Duration::seconds(event_lease_seconds_for_behavior(behavior, event))
                >= now
        })
        .max_by_key(|candidate| {
            (
                interrupt_priority(candidate.candidate.event.event_type),
                candidate.created_at,
                event_priority(candidate.candidate.event.event_type),
                candidate.candidate.source_session_sequence,
                candidate.candidate.event.source,
            )
        })
        .map(|candidate| active_state_from_candidate(behavior, candidate, candidates))
}

/// Returns the bounded set of sessions that should be rendered in status
/// bubbles. Waiting and failed sessions remain visible until a newer
/// event replaces them, regardless of host `session_active` metadata.
/// Completed and ordinary sessions are hidden after the configured interval
/// and reappear when the next user activation/start event arrives. A completed
/// session whose host explicitly reports `session_open = false` is already
/// archived/closed and leaves the bubble immediately while remaining in audit
/// history.
pub fn select_display_agent_states(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
) -> DisplayAgentStates {
    select_display_agent_states_with_acknowledgements(behavior, candidates, now, &BTreeSet::new())
}

pub fn select_display_agent_states_with_acknowledgements(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
    acknowledged_session_activations: &BTreeSet<String>,
) -> DisplayAgentStates {
    if !behavior.enabled {
        return DisplayAgentStates {
            states: Vec::new(),
            omitted_count: 0,
        };
    }

    let timeout = Duration::minutes(i64::from(behavior.session_message_timeout_minutes));
    let mut visible = latest_candidates_by_session(candidates, now)
        .into_values()
        .filter(|candidate| event_enabled(behavior, &candidate.candidate.event))
        .filter(|candidate| !event_is_explicitly_closed_completion(&candidate.candidate.event))
        .filter(|candidate| terminal_event_has_prior_activation(candidate))
        .filter(|candidate| {
            !candidate_is_acknowledged(candidate.candidate, acknowledged_session_activations)
        })
        .filter(|candidate| {
            let event = &candidate.candidate.event;
            match event.event_type {
                // User-blocked and failed work remains until a newer session
                // event replaces it. These states do not disappear on the
                // ordinary message timeout used for running/completed work.
                AgentEventType::Waiting | AgentEventType::Failed => true,
                AgentEventType::Start
                | AgentEventType::Thinking
                | AgentEventType::Plan
                | AgentEventType::Tool
                | AgentEventType::Done => candidate.created_at + timeout >= now,
            }
        })
        .collect::<Vec<_>>();
    visible.sort_by(|left, right| {
        display_interrupt_priority(&right.candidate.event)
            .cmp(&display_interrupt_priority(&left.candidate.event))
            .then_with(|| session_display_order_time(right).cmp(&session_display_order_time(left)))
            .then_with(|| {
                left.candidate
                    .event
                    .source
                    .cmp(&right.candidate.event.source)
            })
            .then_with(|| {
                normalized_session_key(left.candidate.event.session_id.as_deref()).cmp(
                    &normalized_session_key(right.candidate.event.session_id.as_deref()),
                )
            })
    });
    let omitted_count = visible.len().saturating_sub(MAX_DISPLAY_AGENT_SESSIONS);
    let states = visible
        .into_iter()
        .take(MAX_DISPLAY_AGENT_SESSIONS)
        .map(|candidate| active_state_from_candidate(behavior, candidate, candidates))
        .collect();
    DisplayAgentStates {
        states,
        omitted_count,
    }
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
        | AgentEventType::Thinking
        | AgentEventType::Plan
        | AgentEventType::Tool
        | AgentEventType::Waiting => ACTIVITY_LEASE_SECONDS,
    }
}

fn event_priority(event_type: AgentEventType) -> u16 {
    match event_type {
        // Preserve the official status ordering in the published metadata and
        // as a same-time tie-breaker. Canonical selection applies the separate
        // interrupt tier before comparing Ready and Running activity time.
        AgentEventType::Waiting => 600,
        AgentEventType::Failed => 500,
        AgentEventType::Done => 400,
        AgentEventType::Tool
        | AgentEventType::Thinking
        | AgentEventType::Plan
        | AgentEventType::Start => 300,
    }
}

fn interrupt_priority(event_type: AgentEventType) -> u16 {
    match event_type {
        // Needs-input and blocked work must remain visible until the session
        // advances or their canonical lease expires. Ready and Running are
        // intentionally in the same tier so newer work drives the animation.
        AgentEventType::Waiting => 2,
        AgentEventType::Failed => 1,
        AgentEventType::Done
        | AgentEventType::Tool
        | AgentEventType::Thinking
        | AgentEventType::Plan
        | AgentEventType::Start => 0,
    }
}

fn latest_candidates_by_session<'a>(
    candidates: &'a [SequencedAgentEvent],
    now: OffsetDateTime,
) -> BTreeMap<(AgentSource, String), TimedCandidate<'a>> {
    let mut candidates_by_session = BTreeMap::<_, Vec<_>>::new();
    for candidate in candidates {
        if event_is_diagnostic(&candidate.event)
            || (!event_affects_activity(&candidate.event)
                && !event_requires_prior_user_activation(&candidate.event))
        {
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
        candidates_by_session
            .entry(key)
            .or_default()
            .push(TimedCandidate {
                candidate,
                created_at,
            });
    }
    candidates_by_session
        .into_iter()
        .filter_map(|(key, candidates)| {
            let latest_activity_epoch = candidates
                .iter()
                .filter(|candidate| event_starts_new_activity_epoch(&candidate.candidate.event))
                .map(candidate_order)
                .max();
            let current_epoch = candidates
                .into_iter()
                .filter(|candidate| {
                    latest_activity_epoch
                        .is_none_or(|boundary| candidate_order(candidate) >= boundary)
                })
                .collect::<Vec<_>>();
            // A host may publish Failed and then its normal idle/close tail.
            // Keep the failure latched within that activity epoch; a later
            // non-terminal event starts a new epoch and permits progression.
            let latest_failed = current_epoch
                .iter()
                .filter(|candidate| candidate.candidate.event.event_type == AgentEventType::Failed)
                .max_by_key(|candidate| candidate_order(candidate))
                .copied();
            let latest = current_epoch
                .iter()
                .max_by_key(|candidate| candidate_order(candidate))
                .copied();
            latest_failed.or(latest).map(|candidate| (key, candidate))
        })
        .collect()
}

fn candidate_order(candidate: &TimedCandidate<'_>) -> (OffsetDateTime, u64) {
    (
        candidate.created_at,
        candidate.candidate.source_session_sequence,
    )
}

fn session_display_order_time(candidate: &TimedCandidate<'_>) -> OffsetDateTime {
    let session_order_time = candidate
        .candidate
        .session_activated_at
        .as_deref()
        .or(candidate.candidate.session_first_seen_at.as_deref())
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok());
    if display_interrupt_priority(&candidate.candidate.event) > 0 {
        candidate.created_at
    } else {
        session_order_time.unwrap_or(candidate.created_at)
    }
}

fn display_interrupt_priority(event: &AgentEvent) -> u8 {
    match event.event_type {
        AgentEventType::Waiting => 2,
        AgentEventType::Failed => 1,
        AgentEventType::Start
        | AgentEventType::Thinking
        | AgentEventType::Plan
        | AgentEventType::Tool
        | AgentEventType::Done => 0,
    }
}

fn terminal_event_has_prior_activation(candidate: &TimedCandidate<'_>) -> bool {
    !event_requires_prior_user_activation(&candidate.candidate.event)
        || candidate.candidate.session_activated_at.is_some()
}

/// A successful completion remains useful in the return bubble only while the
/// host still exposes a destination. An explicit close/archive edge is durable
/// audit history, not an unavailable message the user must manually dismiss.
fn event_is_explicitly_closed_completion(event: &AgentEvent) -> bool {
    event.event_type == AgentEventType::Done
        && event
            .payload_json
            .get("session_open")
            .and_then(serde_json::Value::as_bool)
            == Some(false)
}

fn active_state_from_candidate(
    behavior: &BehaviorSettings,
    candidate: TimedCandidate<'_>,
    candidates: &[SequencedAgentEvent],
) -> ActiveAgentState {
    let event = &candidate.candidate.event;
    let session_active = event_session_active(event) == Some(true);
    let attention_state = matches!(
        event.event_type,
        AgentEventType::Waiting | AgentEventType::Failed
    );
    let lease_seconds =
        (!attention_state).then(|| event_lease_seconds_for_behavior(behavior, event));
    let expires_at = lease_seconds.map(|lease_seconds| {
        (candidate.created_at + Duration::seconds(lease_seconds))
            .format(&Rfc3339)
            .unwrap_or_else(|_| event.created_at.clone())
    });
    let latest_message =
        latest_message_for_session(candidates, event.source, event.session_id.as_deref());
    let mut projected_event = event.clone();
    if event.event_type == AgentEventType::Failed {
        if let Some(navigation) = candidate
            .candidate
            .latest_terminal_navigation_payload
            .as_ref()
        {
            for key in [
                "session_open",
                "session_surface",
                "terminal_app",
                "session_open_url",
            ] {
                if let Some(value) = navigation.get(key) {
                    projected_event.payload_json[key] = value.clone();
                }
            }
        }
    }
    if let Some(navigation) = candidate
        .candidate
        .preferred_app_navigation_payload
        .as_ref()
    {
        // Origin and liveness are separate facts. A later terminal edge still
        // owns `session_open`, but it cannot downgrade an App-origin activity
        // epoch merely because that hook invocation lost the desktop marker.
        for key in ["session_surface", "terminal_app", "session_open_url"] {
            if let Some(value) = navigation.get(key) {
                projected_event.payload_json[key] = value.clone();
            }
        }
    }
    let overlay_display = overlay_session_display(
        &projected_event,
        candidate.candidate.session_activated_at.as_deref(),
        candidate.candidate.tool_activity_run_marker.as_deref(),
    );
    ActiveAgentState {
        state: event.event_type.pet_state(),
        official_status: official_status(event.event_type).to_string(),
        source: event.source,
        session_id: event.session_id.clone(),
        session_active,
        source_session_sequence: candidate.candidate.source_session_sequence,
        session_alias_sequence: candidate.candidate.session_alias_sequence,
        anonymous_session_alias: None,
        priority: event_priority(event.event_type),
        lease_seconds,
        expires_at,
        session_activated_at: candidate.candidate.session_activated_at.clone(),
        event: projected_event,
        latest_message,
        latest_user_message: None,
        session_title: None,
        session_message: None,
        session_user_message: None,
        // Display copy is hydrated from persisted session history so a tool
        // or lifecycle event cannot evict the latest Agent/thinking message.
        session_activity: None,
        overlay_display,
    }
}

fn overlay_session_display(
    event: &AgentEvent,
    session_activated_at: Option<&str>,
    tool_activity_run_marker: Option<&str>,
) -> OverlaySessionDisplay {
    OverlaySessionDisplay {
        summary_kind: overlay_summary_kind(event),
        navigation: overlay_navigation(event),
        state_entry_id: overlay_state_entry_id(
            event,
            session_activated_at,
            tool_activity_run_marker,
        ),
    }
}

fn overlay_state_entry_id(
    event: &AgentEvent,
    session_activated_at: Option<&str>,
    tool_activity_run_marker: Option<&str>,
) -> String {
    let Some(reaction) = event.event_type.pet_reaction() else {
        return "idle".to_string();
    };
    // Waiting and Failed latch one attention state until the session advances,
    // so repeated host traffic keeps a single stable identity.
    if matches!(reaction, PetStateName::Waiting | PetStateName::Failed) {
        return enum_name(reaction);
    }

    let marker = match reaction {
        // One tool activity run is the animation unit. Continued traffic for
        // the same closed activity subtype keeps its identity, while a
        // genuinely different activity opens a new run.
        PetStateName::Tool => tool_activity_run_marker
            .map(str::trim)
            .filter(|value| !value.is_empty()),
        _ => session_activated_at
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .or_else(|| {
                (reaction == PetStateName::Done)
                    .then(|| {
                        event
                            .payload_json
                            .get("turn_id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                    })
                    .flatten()
            }),
    }
    .unwrap_or("initial");
    let mut digest = Sha256::new();
    // Thinking and plan deliberately share the same authored action and the
    // same per-activation identity, so changing the badge from Thinking to
    // Planning does not restart the pet animation.
    let reaction = enum_name(reaction);
    let source = enum_name(event.source);
    let session_id = normalized_session_key(event.session_id.as_deref());
    for component in [
        reaction.as_str(),
        source.as_str(),
        session_id.as_str(),
        marker,
    ] {
        digest.update(component.as_bytes());
        digest.update([0]);
    }
    format!("state-{}", hex::encode(&digest.finalize()[..12]))
}

fn opaque_event_id(value: &str) -> String {
    opaque_overlay_identity("event", value, "evt")
}

fn opaque_session_id(value: &str) -> String {
    opaque_overlay_identity("session", value, "ses")
}

pub fn session_acknowledgement_id(event: &AgentEvent) -> String {
    session_acknowledgement_id_for_event_id(event.source, event.session_id.as_deref(), &event.id)
}

fn session_acknowledgement_id_for_event_id(
    source: AgentSource,
    session_id: Option<&str>,
    event_id: &str,
) -> String {
    let mut digest = Sha256::new();
    digest.update(b"agent-pet-companion/session-acknowledgement/v1\0");
    for component in [
        enum_name(source),
        normalized_session_key(session_id),
        event_id.to_string(),
    ] {
        digest.update(component.as_bytes());
        digest.update([0]);
    }
    format!("ack-{}", hex::encode(digest.finalize()))
}

fn candidate_is_acknowledged(
    candidate: &SequencedAgentEvent,
    acknowledged_session_activations: &BTreeSet<String>,
) -> bool {
    let event = &candidate.event;
    if acknowledged_session_activations.contains(&session_acknowledgement_id(event)) {
        return true;
    }
    event.event_type == AgentEventType::Done
        && candidate.completion_epoch_event_ids.iter().any(|event_id| {
            acknowledged_session_activations.contains(&session_acknowledgement_id_for_event_id(
                event.source,
                event.session_id.as_deref(),
                event_id,
            ))
        })
}

pub fn is_valid_session_acknowledgement_id(value: &str) -> bool {
    value.len() == 68
        && value.starts_with("ack-")
        && value[4..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn opaque_overlay_identity(domain: &str, value: &str, prefix: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"agent-pet-companion/overlay-identity/v1\0");
    digest.update(domain.as_bytes());
    digest.update([0]);
    digest.update(value.as_bytes());
    format!("{prefix}-{}", hex::encode(digest.finalize()))
}

fn overlay_summary_kind(event: &AgentEvent) -> OverlaySummaryKind {
    match event.event_type {
        AgentEventType::Start => OverlaySummaryKind::Start,
        AgentEventType::Thinking => OverlaySummaryKind::Thinking,
        AgentEventType::Plan => OverlaySummaryKind::Plan,
        AgentEventType::Waiting => OverlaySummaryKind::NeedsInput,
        AgentEventType::Done => OverlaySummaryKind::Done,
        AgentEventType::Failed => OverlaySummaryKind::Failed,
        AgentEventType::Tool => event
            .payload_json
            .get("activity_kind")
            .and_then(serde_json::Value::as_str)
            .and_then(overlay_activity_summary_kind)
            .unwrap_or(OverlaySummaryKind::Tool),
    }
}

pub fn overlay_activity_summary_kind(kind: &str) -> Option<OverlaySummaryKind> {
    Some(match kind {
        "thinking" => OverlaySummaryKind::Thinking,
        "plan" => OverlaySummaryKind::Plan,
        "command" => OverlaySummaryKind::Command,
        "file" => OverlaySummaryKind::File,
        "file_change" => OverlaySummaryKind::FileChange,
        "tool" => OverlaySummaryKind::Tool,
        "subagent" => OverlaySummaryKind::Subagent,
        "search" => OverlaySummaryKind::Search,
        "network" => OverlaySummaryKind::Network,
        "image" => OverlaySummaryKind::Image,
        "compaction" => OverlaySummaryKind::Compaction,
        _ => return None,
    })
}

pub(crate) fn overlay_navigation(event: &AgentEvent) -> OverlaySessionNavigation {
    let payload = &event.payload_json;
    let session_open = payload
        .get("session_open")
        .and_then(serde_json::Value::as_bool);
    let surface = payload
        .get("session_surface")
        .and_then(serde_json::Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "chatgpt_app" | "claude_app" | "opencode_app" | "cli_terminal" | "unknown"
            )
        })
        .map(ToOwned::to_owned);
    let terminal_app = payload
        .get("terminal_app")
        .and_then(serde_json::Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "warp" | "terminal" | "iterm2" | "ghostty" | "unknown"
            )
        })
        .map(ToOwned::to_owned);
    let projected_open_url = payload
        .get("session_open_url")
        .and_then(serde_json::Value::as_str)
        // Ingest validates this closed URL shape. Keep the projection
        // independently fail-closed for legacy database rows.
        .and_then(validated_warp_focus_url);
    let open_url = (surface.as_deref() == Some("cli_terminal")
        && terminal_app.as_deref() == Some("warp"))
    .then_some(projected_open_url)
    .flatten();
    let declared_open_url = payload
        .get("session_open_url")
        .and_then(serde_json::Value::as_str)
        .is_some();
    let app_surface_is_valid = source_app_surface(event.source) == surface.as_deref()
        && terminal_app.is_none()
        && !declared_open_url;
    let routable_session_id = app_surface_is_valid
        .then(|| routable_app_session_id(event))
        .flatten();
    let exact_session = session_open != Some(false)
        && (open_url.is_some()
            || (app_surface_is_valid
                && session_open == Some(true)
                && routable_session_id.is_some()));
    let known_terminal_host = surface.as_deref() == Some("cli_terminal")
        && terminal_app
            .as_deref()
            .is_some_and(|value| value != "unknown");
    let known_agent_app_host = app_surface_is_valid;
    let capability = if exact_session {
        OverlayNavigationCapability::ExactSession
    } else if session_open != Some(false) && (known_terminal_host || known_agent_app_host) {
        // A host-only route needs a specific known application. Merely knowing
        // that a CLI source exists is insufficient: opening an arbitrary
        // terminal would not truthfully return to that Agent.
        OverlayNavigationCapability::AgentHost
    } else {
        OverlayNavigationCapability::Unavailable
    };
    OverlaySessionNavigation {
        capability,
        session_open,
        surface,
        terminal_app,
        open_url,
        routable_session_id,
    }
}

/// Publishes a stable opaque alias only where the visible source group needs
/// one to distinguish two or more sessions that have neither a title nor user
/// context. The persisted sequence is not display order and the token itself
/// is presentation data, not a routable host identity.
pub fn assign_anonymous_session_aliases(states: &mut [ActiveAgentState]) {
    let mut anonymous_counts = BTreeMap::<AgentSource, usize>::new();
    for state in states.iter_mut() {
        state.anonymous_session_alias = None;
        if state.session_title.is_none() && state.session_user_message.is_none() {
            *anonymous_counts.entry(state.source).or_default() += 1;
        }
    }
    for state in states {
        if state.session_title.is_some()
            || state.session_user_message.is_some()
            || anonymous_counts.get(&state.source).copied().unwrap_or(0) < 2
        {
            continue;
        }
        state.anonymous_session_alias = state
            .session_alias_sequence
            .map(|sequence| format!("anon-{}", base36(sequence)));
    }
}

fn base36(mut value: u64) -> String {
    const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    if value == 0 {
        return "0".to_string();
    }
    let mut encoded = Vec::new();
    while value > 0 {
        encoded.push(DIGITS[(value % 36) as usize]);
        value /= 36;
    }
    encoded.reverse();
    String::from_utf8(encoded).expect("base36 digits are valid UTF-8")
}

fn source_app_surface(source: AgentSource) -> Option<&'static str> {
    match source {
        AgentSource::Codex => Some("chatgpt_app"),
        AgentSource::ClaudeCode => Some("claude_app"),
        AgentSource::Opencode => Some("opencode_app"),
        AgentSource::Pi => None,
        // V1 dsh has no App surface; same as Pi.
        AgentSource::Dsh => None,
    }
}

/// Only Codex publishes a routable App session identity. Claude Desktop owns
/// its session identity separately from the CLI transcript UUID that hooks
/// report, and its `claude://resume` deep link imports that transcript as a new
/// Desktop session instead of locating the existing one. Publishing the CLI
/// UUID as routable would therefore promise an exact-session return that the
/// host cannot honor, so Claude Code resolves to host activation like OpenCode.
fn routable_app_session_id(event: &AgentEvent) -> Option<String> {
    if !matches!(event.source, AgentSource::Codex) {
        return None;
    }
    let candidate = event.session_id.as_deref()?.trim();
    if candidate.len() != 36 {
        return None;
    }
    let parsed = uuid::Uuid::parse_str(candidate).ok()?;
    let canonical = parsed.hyphenated().to_string();
    canonical
        .eq_ignore_ascii_case(candidate)
        .then_some(canonical)
}

fn event_activity_kind(event: &AgentEvent) -> Option<&str> {
    event
        .payload_json
        .get("activity_kind")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
}

fn event_activity(event: &AgentEvent) -> Option<SessionActivity> {
    let kind = event_activity_kind(event)?;
    let content = event
        .payload_json
        .get("activity_content")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .and_then(|content| normalize_agent_activity_content_for_kind(content, Some(kind)));
    Some(SessionActivity {
        kind: kind.to_string(),
        content,
    })
}

pub(crate) fn event_narrative_activity(event: &AgentEvent) -> Option<SessionActivity> {
    if !matches!(
        event.event_type,
        AgentEventType::Thinking | AgentEventType::Plan
    ) {
        return None;
    }
    let activity = event_activity(event)?;
    activity.content.as_ref()?;
    Some(activity)
}

fn event_lease_seconds_for_behavior(behavior: &BehaviorSettings, event: &AgentEvent) -> i64 {
    let source_event = event
        .payload_json
        .get("source_event")
        .and_then(serde_json::Value::as_str);
    if (event_session_active(event) == Some(true) || source_event == Some("app_server_activity"))
        && matches!(
            event.event_type,
            AgentEventType::Start
                | AgentEventType::Thinking
                | AgentEventType::Plan
                | AgentEventType::Tool
                | AgentEventType::Done
        )
    {
        return i64::from(behavior.session_message_timeout_minutes).saturating_mul(60);
    }
    event_lease_seconds(event.event_type)
}

fn official_status(event_type: AgentEventType) -> &'static str {
    match event_type {
        AgentEventType::Start => "started",
        AgentEventType::Thinking | AgentEventType::Plan | AgentEventType::Tool => "running",
        AgentEventType::Waiting => "needs_input",
        AgentEventType::Done => "ready",
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn navigation_event(
        source: AgentSource,
        session_id: &str,
        payload_json: serde_json::Value,
    ) -> AgentEvent {
        AgentEvent {
            id: "navigation-event".to_string(),
            source,
            project_path: None,
            session_id: Some(session_id.to_string()),
            event_type: AgentEventType::Tool,
            title: AgentEventType::Tool.zh_label().to_string(),
            detail: None,
            payload_json,
            created_at: "2026-07-23T00:00:00Z".to_string(),
        }
    }

    #[test]
    fn navigation_capability_requires_a_truthful_structural_target() {
        let terminal = overlay_navigation(&navigation_event(
            AgentSource::ClaudeCode,
            "claude-session",
            json!({
                "session_open": true,
                "session_surface": "cli_terminal",
                "terminal_app": "warp",
                "session_open_url": "warp://session/0123456789abcdef0123456789abcdef"
            }),
        ));
        assert_eq!(
            terminal.capability,
            OverlayNavigationCapability::ExactSession
        );

        let codex = overlay_navigation(&navigation_event(
            AgentSource::Codex,
            "019f5b0f-88ff-7413-8953-29de4ed0951c",
            json!({
                "session_open": true,
                "session_surface": "chatgpt_app"
            }),
        ));
        assert_eq!(codex.capability, OverlayNavigationCapability::ExactSession);

        let codex_host = overlay_navigation(&navigation_event(
            AgentSource::Codex,
            "not-a-routable-uuid",
            json!({
                "session_open": null,
                "session_surface": "chatgpt_app"
            }),
        ));
        assert_eq!(
            codex_host.capability,
            OverlayNavigationCapability::AgentHost
        );

        let malformed_terminal = overlay_navigation(&navigation_event(
            AgentSource::ClaudeCode,
            "claude-session",
            json!({
                "session_open": true,
                "session_surface": "cli_terminal",
                "terminal_app": "terminal",
                "session_open_url": "https://example.com/not-allowed"
            }),
        ));
        assert_eq!(malformed_terminal.open_url, None);
        assert_eq!(
            malformed_terminal.capability,
            OverlayNavigationCapability::AgentHost
        );

        let closed = overlay_navigation(&navigation_event(
            AgentSource::ClaudeCode,
            "claude-session",
            json!({
                "session_open": false,
                "session_surface": "cli_terminal",
                "terminal_app": "terminal"
            }),
        ));
        assert_eq!(closed.capability, OverlayNavigationCapability::Unavailable);

        let unknown_host = overlay_navigation(&navigation_event(
            AgentSource::Opencode,
            "opencode-session",
            json!({
                "session_open": true,
                "session_surface": "cli_terminal",
                "terminal_app": "unknown"
            }),
        ));
        assert_eq!(
            unknown_host.capability,
            OverlayNavigationCapability::Unavailable
        );

        let inconsistent_terminal = overlay_navigation(&navigation_event(
            AgentSource::ClaudeCode,
            "claude-session",
            json!({
                "session_open": true,
                "session_surface": "chatgpt_app",
                "terminal_app": "warp",
                "session_open_url": "warp://session/0123456789abcdef0123456789abcdef"
            }),
        ));
        assert_eq!(inconsistent_terminal.open_url, None);
        assert_eq!(
            inconsistent_terminal.capability,
            OverlayNavigationCapability::Unavailable
        );

        let missing_codex_surface = overlay_navigation(&navigation_event(
            AgentSource::Codex,
            "not-a-routable-uuid",
            json!({"session_open": null}),
        ));
        assert_eq!(
            missing_codex_surface.capability,
            OverlayNavigationCapability::Unavailable
        );
    }

    #[test]
    fn navigation_capability_distinguishes_desktop_agent_hosts_from_cli() {
        // A canonical UUID is still only the CLI transcript identity. Claude
        // Desktop cannot route to an existing session by it, so the projection
        // resolves to host activation rather than promising exact return.
        let claude = overlay_navigation(&navigation_event(
            AgentSource::ClaudeCode,
            "657555f8-108e-44af-96ac-a306b50451bd",
            json!({
                "session_open": true,
                "session_surface": "claude_app"
            }),
        ));
        assert_eq!(claude.capability, OverlayNavigationCapability::AgentHost);
        assert_eq!(claude.routable_session_id, None);

        let claude_host = overlay_navigation(&navigation_event(
            AgentSource::ClaudeCode,
            "not-a-routable-uuid",
            json!({
                "session_open": true,
                "session_surface": "claude_app"
            }),
        ));
        assert_eq!(
            claude_host.capability,
            OverlayNavigationCapability::AgentHost
        );
        assert_eq!(claude_host.routable_session_id, None);

        let opencode = overlay_navigation(&navigation_event(
            AgentSource::Opencode,
            "ses_052d7fe89ffeVWsrMygGA3AKvL",
            json!({
                "session_open": true,
                "session_surface": "opencode_app"
            }),
        ));
        assert_eq!(opencode.capability, OverlayNavigationCapability::AgentHost);
        assert_eq!(opencode.routable_session_id, None);

        let mismatched = overlay_navigation(&navigation_event(
            AgentSource::Pi,
            "pi-session",
            json!({
                "session_open": true,
                "session_surface": "opencode_app"
            }),
        ));
        assert_eq!(
            mismatched.capability,
            OverlayNavigationCapability::Unavailable
        );
    }

    #[test]
    fn anonymous_aliases_are_only_published_for_ambiguous_source_groups() {
        let event = navigation_event(AgentSource::Pi, "pi-session", json!({"session_open": null}));
        let state = |sequence| ActiveAgentState {
            state: PetStateName::Tool,
            official_status: "running".to_string(),
            source: AgentSource::Pi,
            session_id: Some(format!("pi-session-{sequence}")),
            session_active: true,
            source_session_sequence: sequence,
            session_alias_sequence: Some(sequence),
            anonymous_session_alias: None,
            priority: 300,
            lease_seconds: None,
            expires_at: None,
            session_activated_at: None,
            event: event.clone(),
            latest_message: None,
            latest_user_message: None,
            session_title: None,
            session_message: None,
            session_user_message: None,
            session_activity: None,
            overlay_display: overlay_session_display(&event, None, None),
        };

        let mut single = vec![state(1)];
        assign_anonymous_session_aliases(&mut single);
        assert_eq!(single[0].anonymous_session_alias, None);

        let mut multiple = vec![state(1), state(37)];
        assign_anonymous_session_aliases(&mut multiple);
        assert_eq!(
            multiple[0].anonymous_session_alias.as_deref(),
            Some("anon-1")
        );
        assert_eq!(
            multiple[1].anonymous_session_alias.as_deref(),
            Some("anon-11")
        );

        multiple[0].session_title = Some("Explicit title".to_string());
        assign_anonymous_session_aliases(&mut multiple);
        assert!(multiple
            .iter()
            .all(|state| state.anonymous_session_alias.is_none()));
    }
}
