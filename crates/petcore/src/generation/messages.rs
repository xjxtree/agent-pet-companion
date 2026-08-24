//! Single home for persisted user-visible generation copy.
//!
//! These strings are written into `generation_messages` and survive across
//! releases, so their exact bytes are part of the product contract: rename or
//! retranslate only with a deliberate product decision, never as a drive-by
//! refactor. New generation copy should be added here instead of being
//! inlined at call sites.

/// Default display name used when a brief provides no usable name.
pub(crate) const DEFAULT_PET_DISPLAY_NAME: &str = "自定义桌宠";

/// Shared tail appended when a job's pet has been imported successfully.
pub(crate) const COMPLETION_LIBRARY_READY_TAIL: &str = "完成，可在宠物库启用。";

/// Fallback detail when an App Server session carries no error/detail text.
pub(crate) const APP_SERVER_UNAVAILABLE_DETAIL: &str = "Codex App Server 暂不可用";

/// Progress copy for the transparent-frame/packaging pipeline stage.
pub(crate) const PIPELINE_STAGE_TRANSPARENT_FRAMES: &str =
    "图像素材已生成，正在透明化、分帧并构建宠物包。";
