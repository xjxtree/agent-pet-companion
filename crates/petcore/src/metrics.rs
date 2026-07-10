use petcore_types::{FpsProfileName, QualityLevel};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererBudget {
    pub quality: QualityLevel,
    pub fps_profile: FpsProfileName,
    pub fps: u32,
    pub frame_count_for_two_seconds: u32,
    pub decoded_state_mb: f64,
    pub runtime_cache_frame_limit: u32,
    pub estimated_runtime_cache_mb: f64,
    pub renderer_budget_mb: u32,
    pub uses_ring_cache: bool,
}

pub fn renderer_budget(quality: QualityLevel, fps_profile: FpsProfileName) -> RendererBudget {
    let size = quality.render_size();
    let fps = fps_profile.fps();
    let frame_count = fps * 2;
    let bytes_per_frame = size.width as f64 * size.height as f64 * 4.0;
    let decoded_state_mb = bytes_per_frame * frame_count as f64 / 1024.0 / 1024.0;
    let uses_ring_cache = matches!(quality, QualityLevel::Original);
    let runtime_cache_frame_limit = if uses_ring_cache {
        if fps_profile == FpsProfileName::Smooth {
            9
        } else {
            7
        }
    } else {
        frame_count
    };
    let estimated_runtime_cache_mb =
        bytes_per_frame * runtime_cache_frame_limit as f64 / 1024.0 / 1024.0;
    let renderer_budget_mb = match (quality, fps_profile) {
        (QualityLevel::Standard, FpsProfileName::Standard)
        | (QualityLevel::High, FpsProfileName::Standard)
        | (QualityLevel::Ultra, FpsProfileName::Standard) => 180,
        (QualityLevel::Standard, FpsProfileName::Smooth)
        | (QualityLevel::High, FpsProfileName::Smooth)
        | (QualityLevel::Ultra, FpsProfileName::Smooth) => 260,
        (QualityLevel::Original, FpsProfileName::Standard) => 320,
        (QualityLevel::Original, FpsProfileName::Smooth) => 420,
    };

    RendererBudget {
        quality,
        fps_profile,
        fps,
        frame_count_for_two_seconds: frame_count,
        decoded_state_mb,
        runtime_cache_frame_limit,
        estimated_runtime_cache_mb,
        renderer_budget_mb,
        uses_ring_cache,
    }
}
