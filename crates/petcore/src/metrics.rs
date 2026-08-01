use petcore_types::{QualityLevel, MAX_FRAMES_PER_STATE, MIN_FRAMES_PER_STATE};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererBudget {
    pub quality: QualityLevel,
    pub frame_count: u32,
    pub decoded_state_mb: f64,
    pub runtime_cache_frame_limit: u32,
    pub estimated_runtime_cache_mb: f64,
    pub renderer_budget_mb: u32,
    pub uses_ring_cache: bool,
}

pub fn renderer_budget(quality: QualityLevel, frame_count: u32) -> RendererBudget {
    let frame_count = frame_count.clamp(MIN_FRAMES_PER_STATE as u32, MAX_FRAMES_PER_STATE as u32);
    let size = quality.render_size();
    let bytes_per_frame = size.width as f64 * size.height as f64 * 4.0;
    let decoded_state_mb = bytes_per_frame * frame_count as f64 / 1024.0 / 1024.0;
    let uses_ring_cache = false;
    let runtime_cache_frame_limit = frame_count;
    let estimated_runtime_cache_mb =
        bytes_per_frame * runtime_cache_frame_limit as f64 / 1024.0 / 1024.0;
    let renderer_budget_mb = (estimated_runtime_cache_mb * 3.0).ceil().max(64.0) as u32;

    RendererBudget {
        quality,
        frame_count,
        decoded_state_mb,
        runtime_cache_frame_limit,
        estimated_runtime_cache_mb,
        renderer_budget_mb,
        uses_ring_cache,
    }
}
