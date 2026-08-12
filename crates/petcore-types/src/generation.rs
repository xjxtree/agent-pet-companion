use crate::QualityLevel;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationForm {
    pub description: String,
    pub style: String,
    pub quality: QualityLevel,
    pub reference_images: Vec<String>,
}

pub const MAX_GENERATION_DESCRIPTION_CHARS: usize = 8_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationJobStatus {
    Pending,
    Running,
    WaitingForUser,
    Failed,
    Completed,
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationInputOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationInputQuestion {
    pub id: String,
    pub prompt: String,
    #[serde(default)]
    pub options: Vec<GenerationInputOption>,
    #[serde(default)]
    pub allows_freeform: bool,
}

/// Closed, user-presentable metadata for one Maker timeline entry. Raw App
/// Server requests, tool payloads, paths, and hidden reasoning never cross
/// this boundary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "payload_type", rename_all = "snake_case")]
pub enum GenerationMessagePayload {
    InputRequest {
        request_id: String,
        questions: Vec<GenerationInputQuestion>,
    },
    Result {
        result_pet_id: String,
        revision_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationMessageRecord {
    pub id: String,
    pub job_id: String,
    pub sequence: u64,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    pub content: String,
    pub progress: f64,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<GenerationMessagePayload>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diagnostic: Option<serde_json::Value>,
}

/// PetCore-authoritative actions for one Maker task. Swift renders these
/// values directly instead of reconstructing lifecycle policy from copy.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationSessionCapabilities {
    #[serde(default)]
    pub can_reply: bool,
    #[serde(default)]
    pub can_resume: bool,
    #[serde(default)]
    pub can_cancel: bool,
    #[serde(default)]
    pub can_open_result: bool,
    #[serde(default)]
    pub can_open_session: bool,
    #[serde(default)]
    pub can_delete: bool,
}

/// Compact, user-presentable evidence from the exact `.petpack` validation
/// that preceded a successful generation commit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationValidationSummary {
    pub ok: bool,
    pub state_count: usize,
    pub frame_count: usize,
    pub warning_count: usize,
}

/// Durable terminal result for a generation job. This is stored beside the
/// job rather than inferred from the current pet row, because later immutable
/// revisions must not rewrite the history of an earlier completed job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationResultSummary {
    pub result_pet_id: String,
    pub revision_id: String,
    pub validation_summary: GenerationValidationSummary,
}

/// Public operation identity used by bounded library history projections.
/// It intentionally carries no prompt, form, transcript, or provider data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationOperation {
    Create,
    Modify,
}

/// One structurally owned immutable revision exposed to the Pet Library.
/// `validated` is true only after PetCore has revalidated the exact archive;
/// only those entries may be selected as an edit baseline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetRevisionHistoryRecord {
    pub revision_id: String,
    pub current: bool,
    pub validated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validation_summary: Option<GenerationValidationSummary>,
}

/// Privacy-minimized job history for the Pet Library. Job workspaces, App
/// Server session IDs, forms, prompts, and messages remain private.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationJobHistoryRecord {
    pub job_id: String,
    pub status: GenerationJobStatus,
    pub operation: GenerationOperation,
    /// Exact owned immutable revision submitted as an edit baseline. Create
    /// jobs and legacy/current-head edits that predate explicit baselines omit
    /// this identity. No edit-context path or instruction is projected.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseline_revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validation_summary: Option<GenerationValidationSummary>,
    pub created_at: String,
    pub updated_at: String,
}

/// Bounded, typed projection consumed by the native Pet Library history
/// sheet. This is an internal RPC view and is never embedded in `.petpack`
/// exports or package metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetHistorySnapshot {
    pub ok: bool,
    pub pet_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_revision_id: Option<String>,
    pub revisions: Vec<PetRevisionHistoryRecord>,
    pub jobs: Vec<GenerationJobHistoryRecord>,
    pub truncated: bool,
}

/// Newest-first, privacy-bounded task summary for the AI Pet Maker history.
/// Source reference paths, task workspaces, provider payloads, and App Server
/// session IDs are intentionally excluded from this list projection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationStudioHistoryRecord {
    pub job_id: String,
    pub status: GenerationJobStatus,
    pub operation: GenerationOperation,
    #[serde(default)]
    pub visible_title: String,
    pub brief_preview: String,
    pub style: String,
    pub quality: QualityLevel,
    pub reference_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_pet_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_of_job_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default)]
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub progress: f64,
    #[serde(default)]
    pub recoverable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pause_reason: Option<String>,
    #[serde(default)]
    pub cancellation_pending: bool,
    #[serde(default)]
    pub capabilities: GenerationSessionCapabilities,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationStudioHistorySnapshot {
    pub ok: bool,
    pub jobs: Vec<GenerationStudioHistoryRecord>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationMessagesPage {
    pub ok: bool,
    pub job_id: String,
    pub messages: Vec<GenerationMessageRecord>,
    pub has_more: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_before_sequence: Option<u64>,
    pub revision: String,
}

/// Typed receipt for the irreversible removal of one terminal AI Pet Maker
/// task. A completed task's published Pet Library result is deliberately
/// retained; only the private task record, message stream, and workspace are
/// removed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationStudioHistoryDeleteReceipt {
    pub ok: bool,
    pub job_id: String,
    pub deleted_status: GenerationJobStatus,
    pub deleted_message_count: usize,
    pub workspace_removed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retained_result_pet_id: Option<String>,
    pub retry_children_relinked: usize,
    pub state_revision: String,
}

/// Live App Server availability for a Pet Studio thread. A deep link is
/// exposed only for `available`; persisted IDs alone are never trusted as a
/// navigation target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationStudioSessionAvailability {
    NotCreated,
    Available,
    Archived,
    Missing,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationStudioSessionNavigation {
    pub availability: GenerationStudioSessionAvailability,
    pub can_open: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub routable_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// Bounded task details for the AI Pet Maker. The complete transcript remains
/// owned by Codex/ChatGPT; this projection carries only the information needed
/// to understand the task without leaving the App.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationStudioHistoryDetail {
    pub ok: bool,
    pub found: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<GenerationJobStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation: Option<GenerationOperation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visible_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quality: Option<QualityLevel>,
    pub reference_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_pet_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_of_job_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validation_summary: Option<GenerationValidationSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub progress: f64,
    #[serde(default)]
    pub recoverable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pause_reason: Option<String>,
    #[serde(default)]
    pub cancellation_pending: bool,
    pub progress_messages: Vec<GenerationMessageRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_codex_excerpt: Option<String>,
    pub message_count: usize,
    pub messages_truncated: bool,
    pub session: GenerationStudioSessionNavigation,
    #[serde(default)]
    pub capabilities: GenerationSessionCapabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerationSessionSnapshot {
    pub job_id: String,
    pub status: GenerationJobStatus,
    pub form: GenerationForm,
    /// Number of original user-selected references that could not be restored
    /// from validated private job copies and must be selected again. This is
    /// bounded by the generation reference-image limit.
    #[serde(default)]
    pub reference_reselection_count: usize,
    pub session_id: Option<String>,
    pub result_pet_id: Option<String>,
    /// Public create/modify identity for the active generation. Legacy
    /// snapshots omit this field and decode it as `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation: Option<GenerationOperation>,
    /// Exact owned immutable revision selected as the edit baseline. This is
    /// absent for create jobs and legacy/current-head edits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub baseline_revision_id: Option<String>,
    pub owner_instance_id: Option<String>,
    pub heartbeat_at: String,
    #[serde(default)]
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub recoverable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pause_reason: Option<String>,
    #[serde(default)]
    pub cancellation_pending: bool,
    #[serde(default)]
    pub capabilities: GenerationSessionCapabilities,
    pub message_revision: String,
    pub messages: Vec<GenerationMessageRecord>,
    pub input_request: Option<GenerationMessageRecord>,
}
