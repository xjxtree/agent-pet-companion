//! DeepSeek Harness (dsh) connector adapter constants.
//!
//! T1 is extension-only: the source enum, schemas, and capability plumbing
//! accept `dsh` everywhere with the most conservative behavior (nothing
//! installed, nothing parsed, nothing reported as evidence). T3 replaces
//! this file with the full managed-operations adapter and T4 lands the
//! Cordis plugin template; the audited event inventory below is filled by
//! those tasks.

/// dsh session events that prove a new user-driven task began.
///
/// Empty until T2/T4 define the dsh epoch vocabulary.
pub(crate) const DSH_TASK_START_EVENTS: &[&str] = &[];

/// dsh session events that prove ordinary Agent task activity.
pub(crate) const DSH_TASK_ACTIVITY_EVENTS: &[&str] = &[];

/// dsh session events that prove a task reached a terminal edge.
pub(crate) const DSH_TASK_COMPLETION_EVENTS: &[&str] = &[];
