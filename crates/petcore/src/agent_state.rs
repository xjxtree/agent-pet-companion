use crate::enum_name;
use crate::event_envelope::{
    event_affects_activity, event_requires_prior_user_activation, event_starts_new_activity_epoch,
    validated_warp_focus_url,
};
use petcore_types::{AgentEvent, AgentEventType, AgentSource, BehaviorSettings, PetStateName};
use serde::{ser::SerializeStruct, Serialize, Serializer};
use sha2::{Digest, Sha256};
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
    pub session_first_seen_at: Option<String>,
    pub latest_terminal_navigation_payload: Option<serde_json::Value>,
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

/// Closed, content-free projection consumed by the desktop overlay. Agent
/// prompts, assistant replies, paths, command arguments, and activity detail
/// remain available only to PetCore's internal arbitration/hydration logic and
/// are never serialized as part of an `ActiveAgentState`.
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
    Running,
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
    Review,
    Done,
    Failed,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct OverlaySessionNavigation {
    pub session_open: Option<bool>,
    pub surface: Option<String>,
    pub terminal_app: Option<String>,
    pub open_url: Option<String>,
    /// Raw host session identity is never projected. Codex may expose only a
    /// canonical UUID in this dedicated routing field.
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
        let mut state = serializer.serialize_struct("ActiveAgentState", 12)?;
        state.serialize_field("state", &self.state)?;
        state.serialize_field("official_status", &self.official_status)?;
        state.serialize_field("source", &self.source)?;
        state.serialize_field("session_id", &session_id)?;
        state.serialize_field("session_active", &self.session_active)?;
        state.serialize_field("source_session_sequence", &self.source_session_sequence)?;
        state.serialize_field("priority", &self.priority)?;
        state.serialize_field("lease_seconds", &self.lease_seconds)?;
        state.serialize_field("expires_at", &self.expires_at)?;
        state.serialize_field("session_activated_at", &self.session_activated_at)?;
        state.serialize_field("event", &event)?;
        state.serialize_field("overlay_display", &self.overlay_display)?;
        state.end()
    }
}

/// Converts a stored/audited event to the content-free shape permitted across
/// the App state-snapshot boundary. The explicit `events.recent` audit RPC is
/// intentionally separate and continues to expose the stored event contract.
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
/// Ordinary expiration happens after phase one so an expired done event closes
/// its session instead of allowing older activity to reappear. Waiting,
/// review, and failed attention states do not expire locally.
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
        .filter(|candidate| terminal_event_has_prior_activation(candidate))
        .filter(|candidate| {
            let event = &candidate.candidate.event;
            matches!(
                event.event_type,
                AgentEventType::Waiting | AgentEventType::Review | AgentEventType::Failed
            ) || event_session_active(event) == Some(true)
                || candidate.created_at
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
/// bubbles. Waiting, review, and failed sessions remain visible until a newer
/// event replaces them, regardless of host `session_active` metadata.
/// Completed and ordinary sessions are hidden after the configured interval
/// and reappear when the next user activation/start event arrives.
pub fn select_display_agent_states(
    behavior: &BehaviorSettings,
    candidates: &[SequencedAgentEvent],
    now: OffsetDateTime,
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
        .filter(|candidate| terminal_event_has_prior_activation(candidate))
        .filter(|candidate| {
            let event = &candidate.candidate.event;
            match event.event_type {
                // Review is an attention state: it remains until the user
                // opens/dismisses it in the App or a newer session event
                // replaces it. It must not disappear on the ordinary message
                // timeout used for running/completed activity.
                AgentEventType::Waiting | AgentEventType::Review | AgentEventType::Failed => true,
                AgentEventType::Start | AgentEventType::Tool | AgentEventType::Done => {
                    candidate.created_at + timeout >= now
                }
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
        | AgentEventType::Tool
        | AgentEventType::Waiting
        | AgentEventType::Review => ACTIVITY_LEASE_SECONDS,
    }
}

fn event_priority(event_type: AgentEventType) -> u16 {
    match event_type {
        // Preserve the official status ordering in the published metadata and
        // as a same-time tie-breaker. Canonical selection applies the separate
        // interrupt tier before comparing Ready and Running activity time.
        AgentEventType::Waiting => 600,
        AgentEventType::Failed => 500,
        AgentEventType::Review | AgentEventType::Done => 400,
        AgentEventType::Tool | AgentEventType::Start => 300,
    }
}

fn interrupt_priority(event_type: AgentEventType) -> u16 {
    match event_type {
        // Needs-input and blocked work must remain visible until the session
        // advances or their canonical lease expires. Ready and Running are
        // intentionally in the same tier so newer work drives the animation.
        AgentEventType::Waiting => 2,
        AgentEventType::Failed => 1,
        AgentEventType::Review
        | AgentEventType::Done
        | AgentEventType::Tool
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
        | AgentEventType::Tool
        | AgentEventType::Review
        | AgentEventType::Done => 0,
    }
}

fn terminal_event_has_prior_activation(candidate: &TimedCandidate<'_>) -> bool {
    !event_requires_prior_user_activation(&candidate.candidate.event)
        || candidate.candidate.session_activated_at.is_some()
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
        AgentEventType::Waiting | AgentEventType::Review | AgentEventType::Failed
    );
    let lease_seconds = (!session_active && !attention_state)
        .then(|| event_lease_seconds_for_behavior(behavior, event));
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
    let overlay_display = overlay_session_display(
        &projected_event,
        candidate.candidate.session_activated_at.as_deref(),
    );
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
        event: projected_event,
        latest_message,
        latest_user_message: None,
        session_title: None,
        session_message: None,
        session_user_message: None,
        session_activity: event_activity(event),
        overlay_display,
    }
}

fn overlay_session_display(
    event: &AgentEvent,
    session_activated_at: Option<&str>,
) -> OverlaySessionDisplay {
    OverlaySessionDisplay {
        summary_kind: overlay_summary_kind(event),
        navigation: overlay_navigation(event),
        state_entry_id: overlay_state_entry_id(event, session_activated_at),
    }
}

fn overlay_state_entry_id(event: &AgentEvent, session_activated_at: Option<&str>) -> String {
    if matches!(
        event.event_type,
        AgentEventType::Tool
            | AgentEventType::Waiting
            | AgentEventType::Review
            | AgentEventType::Failed
    ) {
        return enum_name(event.event_type);
    }

    let marker = session_activated_at
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            (event.event_type == AgentEventType::Done)
                .then(|| {
                    event
                        .payload_json
                        .get("turn_id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                })
                .flatten()
        })
        .unwrap_or("initial");
    let mut digest = Sha256::new();
    let event_type = enum_name(event.event_type);
    let source = enum_name(event.source);
    let session_id = normalized_session_key(event.session_id.as_deref());
    for component in [
        event_type.as_str(),
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
        AgentEventType::Waiting => OverlaySummaryKind::NeedsInput,
        AgentEventType::Review => OverlaySummaryKind::Review,
        AgentEventType::Done => OverlaySummaryKind::Done,
        AgentEventType::Failed => OverlaySummaryKind::Failed,
        AgentEventType::Start | AgentEventType::Tool => event
            .payload_json
            .get("activity_kind")
            .and_then(serde_json::Value::as_str)
            .and_then(overlay_activity_summary_kind)
            .unwrap_or_else(|| {
                if event.event_type == AgentEventType::Tool {
                    OverlaySummaryKind::Tool
                } else {
                    OverlaySummaryKind::Running
                }
            }),
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

fn overlay_navigation(event: &AgentEvent) -> OverlaySessionNavigation {
    let payload = &event.payload_json;
    OverlaySessionNavigation {
        session_open: payload
            .get("session_open")
            .and_then(serde_json::Value::as_bool),
        surface: payload
            .get("session_surface")
            .and_then(serde_json::Value::as_str)
            .filter(|value| matches!(*value, "chatgpt_app" | "cli_terminal" | "unknown"))
            .map(ToOwned::to_owned),
        terminal_app: payload
            .get("terminal_app")
            .and_then(serde_json::Value::as_str)
            .filter(|value| {
                matches!(
                    *value,
                    "warp" | "terminal" | "iterm2" | "ghostty" | "unknown"
                )
            })
            .map(ToOwned::to_owned),
        open_url: payload
            .get("session_open_url")
            .and_then(serde_json::Value::as_str)
            // Ingest validates this closed URL shape. Keep the projection
            // independently fail-closed for legacy database rows.
            .and_then(validated_warp_focus_url),
        routable_session_id: routable_codex_session_id(event),
    }
}

fn routable_codex_session_id(event: &AgentEvent) -> Option<String> {
    if event.source != AgentSource::Codex {
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
