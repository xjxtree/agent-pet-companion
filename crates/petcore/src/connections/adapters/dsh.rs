//! DeepSeek Harness (dsh) connector adapter constants.
//!
//! T1 is extension-only: the source enum, schemas, and capability plumbing
//! accept `dsh` everywhere with the most conservative behavior (nothing
//! installed, nothing parsed, nothing reported as evidence). T3 replaces
//! this file with the full managed-operations adapter and T4 lands the
//! Cordis plugin template; the audited event inventory below is filled by
//! those tasks.

use petcore_types::AgentSource;

/// Audited dsh broadcast events the connector may subscribe to.
///
/// The emit-only surface per the connector plan: waterfall/interception
/// events (`agent/pre-step`, `agent/turn-stopping`, `tools/pre-execute`, …)
/// must never be subscribed by a pure observer - an observer that swallows
/// the decision chain crashes the driver.
pub(crate) const DSH_AUDITED_EVENTS: &[&str] = &[
    "session/event",
    "session/disposed",
    "subagent/start",
    "subagent/end",
    "agent/status",
];

/// dsh session events that prove a new user-driven task began.
///
/// Empty until T2/T4 define the dsh epoch vocabulary.
pub(crate) const DSH_TASK_START_EVENTS: &[&str] = &[];

/// dsh session events that prove ordinary Agent task activity.
pub(crate) const DSH_TASK_ACTIVITY_EVENTS: &[&str] = &[];

/// dsh session events that prove a task reached a terminal edge.
pub(crate) const DSH_TASK_COMPLETION_EVENTS: &[&str] = &[];

/// The CLI name users invoke dsh with.
pub(crate) const DSH_CLI_NAME: &str = "dsh";

/// Environment override for a non-default dsh CLI location.
pub(crate) const DSH_CLI_OVERRIDE_KEY: &str = "APC_DSH_CLI_PATH";

/// Report whether the dsh CLI is discoverable on this host.
///
/// Conservative until T3 wires installation/repair: dsh is reported as not
/// installed, which is a normal optional state and never a global problem.
pub(crate) fn dsh_cli_available() -> bool {
    false
}

/// Placeholder keeping the adapter module shaped like its siblings; T3 owns
/// the real check/repair/uninstall surface.
pub(crate) fn dsh_display(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Dsh => "DeepSeek Harness",
        _ => "",
    }
}
