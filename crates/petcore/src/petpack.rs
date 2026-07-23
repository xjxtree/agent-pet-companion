use crate::db::Database;
use crate::paths::AppPaths;
use crate::pet_revision::{revision_pet_root, PetRevisionTransaction, PetStoreGuard};
use crate::reference_images::{load_reference_snapshots, ValidatedReferenceSnapshot};
use crate::{new_id, now_rfc3339, PetCoreError, Result};
use image::{
    codecs::webp::{WebPDecoder, WebPEncoder},
    imageops, AnimationDecoder, ImageBuffer, ImageEncoder, Rgba, RgbaImage,
};
use petcore_types::{
    expected_frame_count, GenerationForm, PetManifest, PetOrigin, PetStateName, PetSummary,
    QualityLevel, RenderSize, DEFAULT_NATIVE_FPS, LONG_ACTION_DURATION_MS, PETPACK_SCHEMA_VERSION,
    REQUIRED_STATES, SHORT_ACTION_DURATION_MS, SMOOTH_FPS, STANDARD_FPS,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{BufReader, Read, Seek, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;
use zip::write::SimpleFileOptions;

pub const GENERATED_NATIVE_FPS: u32 = DEFAULT_NATIVE_FPS;
pub const BUNDLED_PET_INVENTORY_VERSION: &str = "apc.bundled-pets.v1";
pub const BUNDLED_PET_GENERATOR_MARKER: &str = "agent-pet-companion.release-inventory";
pub const BUNDLED_PET_PROVENANCE_MARKER: &str = BUNDLED_PET_INVENTORY_VERSION;
const RUNTIME_ASSETS_MARKER: &str = ".apc-runtime-assets.json";
const RUNTIME_ASSETS_SCHEMA_VERSION: &str = "apc.runtime-assets.v2";
const MAX_PETPACK_ARCHIVE_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_PETPACK_ENTRIES: usize = 5_000;
const MAX_PETPACK_ENTRY_BYTES: u64 = 256 * 1024 * 1024;
const MAX_PETPACK_TOTAL_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_FRAMES_PER_STATE: usize = 40;
const MAX_TOTAL_FRAMES: usize = MAX_FRAMES_PER_STATE * 7;
const MAX_DECODED_STATE_BYTES: u64 = 420 * 1024 * 1024;
const MAX_FRAME_PIXELS: u64 = 16_777_216;
const MAX_ANIMATED_PREVIEW_FRAMES: usize = 120;
const MAX_DECODED_ANIMATED_PREVIEW_BYTES: u64 = 128 * 1024 * 1024;
const MIN_VISUAL_COVERAGE_PERCENT: usize = 1;
const MIN_VISIBLE_ALPHA: u8 = 16;
const MAX_TRANSPARENT_ALPHA: u8 = 239;
const PET_SOURCE_SCHEMA_VERSION: &str = "apc.pet-source.v1";
const PET_SOURCE_SCHEMA: &str = include_str!("../../../schemas/pet-source.schema.json");
const PET_BRIEF_SCHEMA: &str = include_str!("../../../schemas/pet-brief.schema.json");
const PET_SOURCE_EVENT_SCHEMA: &str = include_str!("../../../schemas/pet-source-event.schema.json");
const PET_VALIDATION_SCHEMA: &str = include_str!("../../../schemas/pet-validation.schema.json");
const PETPACK_MANIFEST_SCHEMA: &str = include_str!("../../../schemas/petpack.schema.json");

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PetpackValidation {
    pub ok: bool,
    pub manifest: PetManifest,
    pub frame_count: usize,
    pub state_frame_counts: BTreeMap<PetStateName, usize>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PetpackExport {
    pub ok: bool,
    pub pet_id: String,
    pub output_path: String,
    pub byte_count: u64,
    pub validation: PetpackValidation,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PetAssetWarning {
    pub pet_id: String,
    pub code: String,
    pub fingerprint: String,
    pub message: String,
}

pub struct PetAssetValidationOutcome {
    pub pet: PetSummary,
    pub warning: Option<PetAssetWarning>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BundledPetSeedStatus {
    Installed,
    PreservedExistingId,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct BundledPetSeedOutcome {
    pub pet_id: String,
    pub status: BundledPetSeedStatus,
    pub pet: PetSummary,
}

#[derive(Debug, Clone, Copy)]
struct BundledPetDescriptor {
    file_name: &'static str,
    pet_id: &'static str,
    sha256: &'static str,
}

// This is intentionally a closed, content-pinned inventory. The private RPC
// accepts a directory only so the App can point at its SwiftPM resource
// bundle; callers cannot turn an arbitrary petpack into a trusted bundled pet.
const BUNDLED_PET_DESCRIPTORS: [BundledPetDescriptor; 2] = [
    BundledPetDescriptor {
        file_name: "pet_xingwutuanzi.petpack",
        pet_id: "pet_xingwutuanzi",
        sha256: "9a67254a1ee3f1a2afd599f376fd0cc0ee9935e137426924a99c20a24bdb49c2",
    },
    BundledPetDescriptor {
        file_name: "pet_bytebudcodex.petpack",
        pet_id: "pet_bytebudcodex",
        sha256: "a0b64b46054ed5a73abeefc7c0f734cfaa2d92878f5c097ca85bdcb06d547d6f",
    },
];

struct ValidatedBundledPet {
    descriptor: BundledPetDescriptor,
    path: PathBuf,
    expected_digest: [u8; 32],
}

#[derive(Debug, Clone, Copy)]
enum ImportIdentityPolicy {
    PackageDeclared(PetOrigin),
    BundledInventory,
}

/// Returns true only for an identity that PetCore itself can assign while
/// installing the content-pinned release inventory. Display names are never
/// part of this decision, and package-declared metadata alone is insufficient.
pub fn is_bundled_pet(pet: &PetSummary) -> bool {
    BUNDLED_PET_DESCRIPTORS
        .iter()
        .any(|descriptor| descriptor.pet_id == pet.id)
        && pet.origin == PetOrigin::VerifiedSkillSource
        && pet.generator.as_deref() == Some(BUNDLED_PET_GENERATOR_MARKER)
        && pet.provenance.as_deref() == Some(BUNDLED_PET_PROVENANCE_MARKER)
}

pub fn validate_petpack_path(path: &Path) -> Result<PetpackValidation> {
    if path.is_dir() {
        return validate_petpack_dir(path);
    }

    let temp = tempfile::tempdir()?;
    unzip_petpack(path, temp.path())?;
    validate_petpack_dir(temp.path())
}

/// Validates and safely expands a portable petpack into a new workspace.
///
/// The destination must not already exist. Archive limits and path-safety
/// checks are identical to normal import, and a failed expansion is removed so
/// callers never observe a partial edit baseline.
pub fn extract_validated_petpack_source(
    source_path: &Path,
    destination: &Path,
) -> Result<PetpackValidation> {
    if destination.exists() {
        return Err(PetCoreError::InvalidRequest(format!(
            "petpack workspace already exists: {}",
            destination.display()
        )));
    }
    let validation = validate_petpack_path(source_path)?;
    let parent = destination.parent().ok_or_else(|| {
        PetCoreError::InvalidRequest("petpack workspace must have a parent directory".to_string())
    })?;
    fs::create_dir_all(parent)?;
    fs::create_dir(destination)?;

    let expanded = if source_path.is_dir() {
        // Rebuild directory input through the canonical archive writer so the
        // same entry/path rules are applied before it becomes an edit baseline.
        let temp = tempfile::Builder::new()
            .prefix(".apc-petpack-workspace-")
            .tempdir_in(parent)?;
        let archive = temp.path().join("source.petpack");
        write_petpack_zip(source_path, &archive).and_then(|_| unzip_petpack(&archive, destination))
    } else {
        unzip_petpack(source_path, destination)
    };
    if let Err(error) = expanded {
        let _ = fs::remove_dir_all(destination);
        return Err(error);
    }

    match validate_petpack_dir(destination) {
        Ok(expanded_validation) if expanded_validation.manifest.id == validation.manifest.id => {
            Ok(expanded_validation)
        }
        Ok(_) => {
            let _ = fs::remove_dir_all(destination);
            Err(PetCoreError::Validation(
                "expanded petpack manifest id changed".to_string(),
            ))
        }
        Err(error) => {
            let _ = fs::remove_dir_all(destination);
            Err(error)
        }
    }
}

pub fn validate_petpack_dir(dir: &Path) -> Result<PetpackValidation> {
    validate_source_tree_budgets(dir)?;
    let manifest_path = dir.join("manifest.json");
    if !manifest_path.exists() {
        return Err(PetCoreError::Validation(
            "missing manifest.json in petpack root".to_string(),
        ));
    }

    let manifest: PetManifest = serde_json::from_slice(&fs::read(&manifest_path)?)?;
    validate_manifest(&manifest)?;
    validate_no_codex_compat_package_markers(dir)?;

    let mut frame_count = 0usize;
    let mut state_frame_counts = BTreeMap::new();
    let mut warnings = Vec::new();
    validate_petpack_metadata(dir, &manifest)?;
    let skill_full_source = has_skill_full_source_provenance(dir)?;
    validate_preview_assets(dir, skill_full_source, &mut warnings)?;

    for state in REQUIRED_STATES {
        let state_entry = manifest
            .states
            .iter()
            .find(|entry| entry.name == state)
            .ok_or_else(|| {
                PetCoreError::Validation(format!("manifest missing state {}", state.as_str()))
            })?;
        validate_relative_asset_path(&state_entry.frames_dir)?;
        let state_dir = dir.join(&state_entry.frames_dir);
        if !state_dir.is_dir() {
            return Err(PetCoreError::Validation(format!(
                "missing frames directory for state {}",
                state.as_str()
            )));
        }

        let mut state_frames = 0usize;
        let mut decoded_state_bytes = 0u64;
        let mut opaque_state_frames = 0usize;
        let mut invisible_state_frames = 0usize;
        let mut first_frame_digest: Option<[u8; 32]> = None;
        let mut previous_frame_digest: Option<[u8; 32]> = None;
        let mut frame_digests = Vec::new();
        let mut adjacent_duplicate_pairs = 0usize;
        let mut frame_paths = Vec::new();
        for entry in fs::read_dir(&state_dir)? {
            let entry = entry?;
            let path = entry.path();
            if entry.file_type()?.is_dir() {
                return Err(PetCoreError::Validation(format!(
                    "state {} frames must be direct files; nested path {} is not allowed",
                    state.as_str(),
                    path.display()
                )));
            }
            frame_paths.push(path);
        }
        frame_paths.sort_by(|left, right| natural_frame_path_cmp(left, right));
        for path in frame_paths {
            if is_png(&path) {
                let (width, height) = image::image_dimensions(&path)?;
                validate_pixel_budget(width, height, &format!("frame {}", path.display()))?;
                if width != manifest.render_size.width || height != manifest.render_size.height {
                    return Err(PetCoreError::Validation(format!(
                        "frame {} is {}x{}, expected {}x{}",
                        path.display(),
                        width,
                        height,
                        manifest.render_size.width,
                        manifest.render_size.height
                    )));
                }
                let mut decoded = image::open(&path)?.to_rgba8();
                let transparent_pixels = decoded
                    .pixels()
                    .filter(|pixel| pixel.0[3] <= MAX_TRANSPARENT_ALPHA)
                    .count();
                let visible_pixels = decoded
                    .pixels()
                    .filter(|pixel| pixel.0[3] >= MIN_VISIBLE_ALPHA)
                    .count();
                let pixel_count = decoded.pixels().len();
                let has_transparent_coverage =
                    has_minimum_visual_coverage(transparent_pixels, pixel_count);
                let has_visible_coverage = has_minimum_visual_coverage(visible_pixels, pixel_count);
                if !has_transparent_coverage {
                    if skill_full_source {
                        let detail = if transparent_pixels == 0 {
                            "is fully opaque"
                        } else {
                            "has less than 1% transparent coverage"
                        };
                        return Err(PetCoreError::Validation(format!(
                            "skill-full-source frame {}/{} {detail}; every PNG frame must contain at least 1% transparent pixels",
                            state_entry.frames_dir,
                            path.file_name()
                                .and_then(|name| name.to_str())
                                .unwrap_or("<frame>")
                        )));
                    }
                    opaque_state_frames += 1;
                }
                if !has_visible_coverage {
                    if skill_full_source {
                        let detail = if visible_pixels == 0 {
                            "is fully transparent"
                        } else {
                            "has less than 1% visible coverage"
                        };
                        return Err(PetCoreError::Validation(format!(
                            "skill-full-source frame {}/{} {detail}; every PNG frame must contain at least 1% visible pet pixels",
                            state_entry.frames_dir,
                            path.file_name()
                                .and_then(|name| name.to_str())
                                .unwrap_or("<frame>")
                        )));
                    }
                    invisible_state_frames += 1;
                }
                normalize_visible_pixels(&mut decoded);
                let digest: [u8; 32] = Sha256::digest(decoded.as_raw()).into();
                if first_frame_digest.is_none() {
                    first_frame_digest = Some(digest);
                }
                if previous_frame_digest == Some(digest) {
                    if skill_full_source {
                        return Err(PetCoreError::Validation(format!(
                            "skill-full-source state {} has adjacent pixel-duplicate PNG frames near {}",
                            state.as_str(),
                            path.file_name()
                                .and_then(|name| name.to_str())
                                .unwrap_or("<frame>")
                        )));
                    }
                    adjacent_duplicate_pairs += 1;
                }
                previous_frame_digest = Some(digest);
                frame_digests.push(digest);
                frame_count += 1;
                if frame_count > MAX_TOTAL_FRAMES {
                    return Err(PetCoreError::Validation(format!(
                        "petpack has too many frames; maximum is {MAX_TOTAL_FRAMES}"
                    )));
                }
                state_frames += 1;
                if state_frames > MAX_FRAMES_PER_STATE {
                    return Err(PetCoreError::Validation(format!(
                        "state {} has too many frames; maximum is {}",
                        state.as_str(),
                        MAX_FRAMES_PER_STATE
                    )));
                }
                let decoded_frame_bytes = u64::from(width)
                    .checked_mul(u64::from(height))
                    .and_then(|pixels| pixels.checked_mul(4))
                    .ok_or_else(|| {
                        PetCoreError::Validation(format!(
                            "state {} decoded frame size overflow",
                            state.as_str()
                        ))
                    })?;
                decoded_state_bytes = decoded_state_bytes
                    .checked_add(decoded_frame_bytes)
                    .ok_or_else(|| {
                        PetCoreError::Validation(format!(
                            "state {} decoded size overflow",
                            state.as_str()
                        ))
                    })?;
                if decoded_state_bytes > MAX_DECODED_STATE_BYTES {
                    return Err(PetCoreError::Validation(format!(
                        "state {} decoded frames exceed the {} MiB budget",
                        state.as_str(),
                        MAX_DECODED_STATE_BYTES / (1024 * 1024)
                    )));
                }
            }
        }

        if state_frames == 0 {
            return Err(PetCoreError::Validation(format!(
                "state {} has no PNG frames",
                state.as_str()
            )));
        }
        let expected_frames = expected_frame_count(manifest.native_fps, state_entry.duration_ms)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "state {} frame count overflows its timing contract",
                    state.as_str()
                ))
            })?;
        if state_frames != expected_frames {
            return Err(PetCoreError::Validation(format!(
                "state {} has {} PNG frames, expected {} for {} FPS and {} ms",
                state.as_str(),
                state_frames,
                expected_frames,
                manifest.native_fps,
                state_entry.duration_ms
            )));
        }
        if state_entry.looped && state_frames >= 2 && first_frame_digest == previous_frame_digest {
            if skill_full_source {
                return Err(PetCoreError::Validation(format!(
                    "skill-full-source loop state {} repeats the same decoded pixels across its last-to-first playback boundary",
                    state.as_str()
                )));
            }
            adjacent_duplicate_pairs += 1;
        }
        if skill_full_source && manifest.native_fps == SMOOTH_FPS {
            validate_standard_sample_motion(
                state,
                state_entry.duration_ms,
                state_entry.looped,
                &frame_digests,
            )?;
        }
        if adjacent_duplicate_pairs > 0 {
            warnings.push(format!(
                "state {} has {adjacent_duplicate_pairs} adjacent pixel-duplicate playback pair(s); animation may contain padded holds",
                state.as_str(),
            ));
        }
        if opaque_state_frames > 0 {
            warnings.push(format!(
                "state {} has {opaque_state_frames} PNG frame(s) below 1% transparent coverage; portable skill-full-source pets require transparent pixels in every frame",
                state.as_str()
            ));
        }
        if invisible_state_frames > 0 {
            warnings.push(format!(
                "state {} has {invisible_state_frames} PNG frame(s) below 1% visible coverage; portable skill-full-source pets require visible pet pixels in every frame",
                state.as_str()
            ));
        }
        state_frame_counts.insert(state, state_frames);
    }

    Ok(PetpackValidation {
        ok: true,
        manifest,
        frame_count,
        state_frame_counts,
        warnings,
    })
}

fn runtime_sample_indices(
    source_frame_count: usize,
    target_frame_count: usize,
    loops: bool,
) -> Vec<usize> {
    if source_frame_count == 0 || target_frame_count == 0 {
        return Vec::new();
    }
    let target_frame_count = source_frame_count.min(target_frame_count);
    if target_frame_count == source_frame_count {
        return (0..source_frame_count).collect();
    }
    if loops {
        return (0..target_frame_count)
            .map(|logical_index| logical_index * source_frame_count / target_frame_count)
            .collect();
    }
    if target_frame_count == 1 {
        return vec![source_frame_count - 1];
    }

    let denominator = target_frame_count - 1;
    (0..target_frame_count)
        .map(|logical_index| {
            let numerator = logical_index * (source_frame_count - 1);
            let quotient = numerator / denominator;
            let remainder = numerator % denominator;
            quotient + usize::from(remainder * 2 >= denominator)
        })
        .collect()
}

fn validate_standard_sample_motion(
    state: PetStateName,
    duration_ms: u32,
    loops: bool,
    frame_digests: &[[u8; 32]],
) -> Result<()> {
    let target_frame_count = expected_frame_count(STANDARD_FPS, duration_ms).ok_or_else(|| {
        PetCoreError::Validation(format!(
            "state {} Standard sample count overflows its timing contract",
            state.as_str()
        ))
    })?;
    let indices = runtime_sample_indices(frame_digests.len(), target_frame_count, loops);
    for pair in indices.windows(2) {
        if frame_digests[pair[0]] == frame_digests[pair[1]] {
            return Err(PetCoreError::Validation(format!(
                "skill-full-source state {} has duplicate runtime Standard 10 FPS poses at source indices {} and {}",
                state.as_str(), pair[0], pair[1]
            )));
        }
    }
    if loops
        && indices.len() >= 2
        && frame_digests[*indices.last().expect("checked non-empty sample")]
            == frame_digests[indices[0]]
    {
        return Err(PetCoreError::Validation(format!(
            "skill-full-source loop state {} repeats the same decoded pixels across its runtime Standard 10 FPS wrap boundary at source indices {} and {}",
            state.as_str(),
            indices.last().expect("checked non-empty sample"),
            indices[0]
        )));
    }
    Ok(())
}

pub fn validate_manifest(manifest: &PetManifest) -> Result<()> {
    if manifest.schema_version != PETPACK_SCHEMA_VERSION {
        return Err(PetCoreError::Validation(format!(
            "unsupported petpack schema {}; expected {}",
            manifest.schema_version, PETPACK_SCHEMA_VERSION
        )));
    }
    validate_pet_id(&manifest.id)?;
    if manifest.name.trim().is_empty() {
        return Err(PetCoreError::Validation(
            "petpack manifest name must not be blank".to_string(),
        ));
    }
    if manifest.style.trim().is_empty() {
        return Err(PetCoreError::Validation(
            "petpack manifest style must not be blank".to_string(),
        ));
    }
    if time::OffsetDateTime::parse(
        &manifest.created_at,
        &time::format_description::well_known::Rfc3339,
    )
    .is_err()
    {
        return Err(PetCoreError::Validation(
            "petpack manifest created_at must be RFC3339".to_string(),
        ));
    }

    let expected_size = manifest.quality.render_size();
    if manifest.render_size != expected_size {
        return Err(PetCoreError::Validation(format!(
            "render_size does not match quality {}; expected {}x{}",
            manifest.quality.zh_label(),
            expected_size.width,
            expected_size.height
        )));
    }

    if !matches!(manifest.native_fps, STANDARD_FPS | SMOOTH_FPS) {
        return Err(PetCoreError::Validation(format!(
            "native_fps must be exactly {STANDARD_FPS} or {SMOOTH_FPS}"
        )));
    }

    for required in REQUIRED_STATES {
        if !manifest.states.iter().any(|state| state.name == required) {
            return Err(PetCoreError::Validation(format!(
                "missing required state {}",
                required.as_str()
            )));
        }
    }

    if manifest.states.len() != REQUIRED_STATES.len() {
        return Err(PetCoreError::Validation(format!(
            "petpack manifest must contain exactly {} states",
            REQUIRED_STATES.len()
        )));
    }

    let mut seen_states = BTreeSet::new();
    for state in &manifest.states {
        if !seen_states.insert(state.name) {
            return Err(PetCoreError::Validation(format!(
                "duplicate state {}",
                state.name.as_str()
            )));
        }
        validate_relative_asset_path(&state.frames_dir)?;
        let expected_frames_dir = format!("assets/frames/{}", state.name.as_str());
        if state.frames_dir != expected_frames_dir {
            return Err(PetCoreError::Validation(format!(
                "state {} frames_dir must be {}",
                state.name.as_str(),
                expected_frames_dir
            )));
        }
        let expected_loop = !matches!(state.name, PetStateName::Start | PetStateName::Done);
        if state.looped != expected_loop {
            return Err(PetCoreError::Validation(format!(
                "state {} loop must be {}",
                state.name.as_str(),
                expected_loop
            )));
        }
        if !matches!(
            state.duration_ms,
            SHORT_ACTION_DURATION_MS | LONG_ACTION_DURATION_MS
        ) {
            return Err(PetCoreError::Validation(format!(
                "state {} duration_ms must be exactly {} or {}",
                state.name.as_str(),
                SHORT_ACTION_DURATION_MS,
                LONG_ACTION_DURATION_MS
            )));
        }
        let expected_frames = expected_frame_count(manifest.native_fps, state.duration_ms)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "state {} timing contract overflows",
                    state.name.as_str()
                ))
            })?;
        if expected_frames == 0 || expected_frames > MAX_FRAMES_PER_STATE {
            return Err(PetCoreError::Validation(format!(
                "state {} timing requires {} frames, outside the 1-{} frame budget",
                state.name.as_str(),
                expected_frames,
                MAX_FRAMES_PER_STATE
            )));
        }
    }

    Ok(())
}

fn validate_no_codex_compat_package_markers(dir: &Path) -> Result<()> {
    for marker in [
        ".codex-plugin",
        "hooks",
        "skills",
        "codex-pet.json",
        "codex_pet.json",
        "pet.json",
    ] {
        if dir.join(marker).exists() {
            return Err(PetCoreError::Validation(format!(
                "petpack must not include Codex compatibility package marker {marker}"
            )));
        }
    }
    Ok(())
}

fn validate_pet_id(id: &str) -> Result<()> {
    if id.is_empty() || id.len() > 128 {
        return Err(PetCoreError::Validation(
            "petpack manifest id must be 1-128 characters".to_string(),
        ));
    }
    let Some(suffix) = id.strip_prefix("pet_") else {
        return Err(PetCoreError::Validation(
            "petpack manifest id must match ^pet_[a-z0-9]+$ and be a safe file name".to_string(),
        ));
    };
    if suffix.is_empty()
        || !suffix
            .chars()
            .all(|character| character.is_ascii_lowercase() || character.is_ascii_digit())
    {
        return Err(PetCoreError::Validation(
            "petpack manifest id must match ^pet_[a-z0-9]+$ and be a safe file name".to_string(),
        ));
    }
    Ok(())
}

fn validate_relative_asset_path(path: &str) -> Result<()> {
    let path = Path::new(path);
    if path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::Prefix(_)))
    {
        return Err(PetCoreError::Validation(
            "petpack asset paths must stay inside the package".to_string(),
        ));
    }
    Ok(())
}

fn validate_preview_assets(
    dir: &Path,
    skill_full_source: bool,
    warnings: &mut Vec<String>,
) -> Result<()> {
    validate_preview_image(dir, "assets/preview/cover.png", warnings)?;
    validate_preview_image(dir, "assets/preview/animated_preview.webp", warnings)?;
    let animated_preview = dir.join("assets/preview/animated_preview.webp");
    if let Err(issue) = inspect_animated_webp(&animated_preview) {
        match issue {
            AnimatedPreviewIssue::Safety(detail) => {
                return Err(PetCoreError::Validation(format!(
                    "animated preview assets/preview/animated_preview.webp rejected by safety budget: {detail}"
                )));
            }
            AnimatedPreviewIssue::Contract(detail) => {
                let message = format!(
                    "animated preview assets/preview/animated_preview.webp {detail}; it must contain at least two decodable, visible, pixel-distinct frames"
                );
                if skill_full_source {
                    return Err(PetCoreError::Validation(format!(
                        "skill-full-source {message}"
                    )));
                }
                warnings.push(message);
            }
        }
    }
    Ok(())
}

fn has_skill_full_source_provenance(dir: &Path) -> Result<bool> {
    Ok(read_json_file(dir, "source/source.json")?
        .get("provenance")
        .and_then(serde_json::Value::as_str)
        == Some("skill-full-source"))
}

#[derive(Debug)]
enum AnimatedPreviewIssue {
    Contract(String),
    Safety(String),
}

fn inspect_animated_webp(path: &Path) -> std::result::Result<(), AnimatedPreviewIssue> {
    let file = File::open(path)
        .map_err(|_| AnimatedPreviewIssue::Contract("could not be opened".to_string()))?;
    let decoder = WebPDecoder::new(BufReader::new(file))
        .map_err(|_| AnimatedPreviewIssue::Contract("could not be decoded as WebP".to_string()))?;
    let mut first_frame: Option<RgbaImage> = None;
    let mut decoded_frames = 0usize;
    let mut decoded_bytes = 0u64;
    let mut has_distinct_frame = false;
    let mut invisible_frames = 0usize;

    for frame in decoder.into_frames() {
        let mut frame = frame
            .map_err(|_| {
                AnimatedPreviewIssue::Contract(
                    "contains an undecodable animation frame".to_string(),
                )
            })?
            .into_buffer();
        account_animated_preview_frame(
            &mut decoded_frames,
            &mut decoded_bytes,
            u64::try_from(frame.as_raw().len()).map_err(|_| {
                AnimatedPreviewIssue::Safety("decoded frame size overflow".to_string())
            })?,
        )?;

        let visible_pixels = frame
            .pixels()
            .filter(|pixel| pixel.0[3] >= MIN_VISIBLE_ALPHA)
            .count();
        if !has_minimum_visual_coverage(visible_pixels, frame.pixels().len()) {
            invisible_frames += 1;
        }
        // Compare premultiplied visible pixels. Provider-specific RGB hidden
        // under transparent or nearly transparent alpha must not satisfy the
        // animation contract.
        normalize_visible_pixels(&mut frame);
        if let Some(first) = &first_frame {
            has_distinct_frame |= frame.as_raw() != first.as_raw();
        } else {
            first_frame = Some(frame);
        }
    }

    if decoded_frames == 0 {
        return Err(AnimatedPreviewIssue::Contract(
            "contains no decodable frames".to_string(),
        ));
    }
    if decoded_frames < 2 {
        return Err(AnimatedPreviewIssue::Contract(
            "contains fewer than two decodable frames".to_string(),
        ));
    }
    if invisible_frames > 0 {
        return Err(AnimatedPreviewIssue::Contract(format!(
            "contains {invisible_frames} frame(s) below 1% visible coverage"
        )));
    }
    if !has_distinct_frame {
        return Err(AnimatedPreviewIssue::Contract(
            "contains no pixel-distinct frames".to_string(),
        ));
    }
    Ok(())
}

fn account_animated_preview_frame(
    decoded_frames: &mut usize,
    decoded_bytes: &mut u64,
    frame_bytes: u64,
) -> std::result::Result<(), AnimatedPreviewIssue> {
    *decoded_frames = decoded_frames
        .checked_add(1)
        .ok_or_else(|| AnimatedPreviewIssue::Safety("decoded frame count overflow".to_string()))?;
    if *decoded_frames > MAX_ANIMATED_PREVIEW_FRAMES {
        return Err(AnimatedPreviewIssue::Safety(format!(
            "contains more than {MAX_ANIMATED_PREVIEW_FRAMES} decoded frames"
        )));
    }
    *decoded_bytes = decoded_bytes.checked_add(frame_bytes).ok_or_else(|| {
        AnimatedPreviewIssue::Safety("cumulative decoded byte count overflow".to_string())
    })?;
    if *decoded_bytes > MAX_DECODED_ANIMATED_PREVIEW_BYTES {
        return Err(AnimatedPreviewIssue::Safety(format!(
            "decoded frames exceed the {} MiB limit",
            MAX_DECODED_ANIMATED_PREVIEW_BYTES / (1024 * 1024)
        )));
    }
    Ok(())
}

fn validate_petpack_metadata(dir: &Path, manifest: &PetManifest) -> Result<()> {
    read_json_file(dir, "brief.json")?;
    validate_source_metadata(dir)?;
    validate_nonempty_text_file(dir, "source/prompt.md")?;
    validate_reference_directory(dir)?;
    validate_skill_session_jsonl(dir)?;
    validate_build_metadata(dir)?;
    validate_safe_producer_metadata(dir, manifest)?;
    Ok(())
}

fn manifest_state_durations_ms(manifest: &PetManifest) -> BTreeMap<PetStateName, u32> {
    manifest
        .states
        .iter()
        .map(|state| (state.name, state.duration_ms))
        .collect()
}

fn manifest_state_frame_counts(manifest: &PetManifest) -> Result<BTreeMap<PetStateName, usize>> {
    manifest
        .states
        .iter()
        .map(|state| {
            expected_frame_count(manifest.native_fps, state.duration_ms)
                .map(|count| (state.name, count))
                .ok_or_else(|| {
                    PetCoreError::Validation(format!(
                        "state {} frame count overflows its timing contract",
                        state.name.as_str()
                    ))
                })
        })
        .collect()
}

fn validate_safe_producer_metadata(dir: &Path, manifest: &PetManifest) -> Result<()> {
    let source = read_json_file(dir, "source/source.json")?;
    let Some(schema_version) = source.get("schema_version") else {
        // Historical v1 packages predate the safe-producer profile. They keep
        // the original minimum metadata gate so users can still reimport an
        // archive exported by an older App build.
        return Ok(());
    };
    if schema_version.as_str() != Some(PET_SOURCE_SCHEMA_VERSION) {
        return Err(PetCoreError::Validation(format!(
            "unsupported petpack source metadata schema; expected {PET_SOURCE_SCHEMA_VERSION}"
        )));
    }

    let brief = read_json_file(dir, "brief.json")?;
    let validation = read_json_file(dir, "build/validation.json")?;
    validate_json_schema("brief.json", &brief, PET_BRIEF_SCHEMA)?;
    validate_json_schema("source/source.json", &source, PET_SOURCE_SCHEMA)?;
    validate_json_schema("build/validation.json", &validation, PET_VALIDATION_SCHEMA)?;
    validate_safe_producer_json_privacy("brief.json", &brief)?;
    validate_safe_producer_json_privacy("source/source.json", &source)?;
    validate_safe_producer_json_privacy("build/validation.json", &validation)?;

    let session_path = dir.join("source/skill_session.jsonl");
    let session = fs::read_to_string(&session_path)?;
    for (index, line) in session.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let event: serde_json::Value = serde_json::from_str(trimmed).map_err(|_| {
            PetCoreError::Validation(format!(
                "invalid JSONL metadata source/skill_session.jsonl at line {}",
                index + 1
            ))
        })?;
        validate_json_schema(
            &format!("source/skill_session.jsonl line {}", index + 1),
            &event,
            PET_SOURCE_EVENT_SCHEMA,
        )?;
        validate_safe_producer_json_privacy("source/skill_session.jsonl", &event)?;
    }

    let manifest_name = serde_json::Value::String(manifest.name.clone());
    let manifest_style = serde_json::Value::String(manifest.style.clone());
    let manifest_quality = serde_json::to_value(manifest.quality)?;
    let manifest_size = serde_json::to_value(manifest.render_size)?;
    let manifest_native_fps = serde_json::json!(manifest.native_fps);
    let manifest_durations = serde_json::to_value(manifest_state_durations_ms(manifest))?;
    let frame_counts = manifest_state_frame_counts(manifest)?;
    let manifest_frame_count = serde_json::json!(frame_counts.values().sum::<usize>());
    let manifest_frame_counts = serde_json::to_value(frame_counts)?;
    require_metadata_match("brief.json", "name", brief.get("name"), &manifest_name)?;
    require_metadata_match("brief.json", "style", brief.get("style"), &manifest_style)?;
    require_metadata_match(
        "brief.json",
        "quality",
        brief.get("quality"),
        &manifest_quality,
    )?;
    if let Some(runtime) = brief.get("runtime") {
        require_metadata_match(
            "brief.json",
            "runtime.render_size",
            runtime.get("render_size"),
            &manifest_size,
        )?;
        require_metadata_match(
            "brief.json",
            "runtime.native_fps",
            runtime.get("native_fps"),
            &manifest_native_fps,
        )?;
        require_metadata_match(
            "brief.json",
            "runtime.state_durations_ms",
            runtime.get("state_durations_ms"),
            &manifest_durations,
        )?;
        require_metadata_match(
            "brief.json",
            "runtime.state_frame_counts",
            runtime.get("state_frame_counts"),
            &manifest_frame_counts,
        )?;
    }
    for (field, expected) in [
        (
            "manifest_id",
            serde_json::Value::String(manifest.id.clone()),
        ),
        ("pet_name", manifest_name.clone()),
        ("style", manifest_style.clone()),
        ("quality", manifest_quality.clone()),
    ] {
        if source.get(field).is_some() {
            require_metadata_match("source/source.json", field, source.get(field), &expected)?;
        }
    }
    for (field, expected) in [
        ("native_fps", &manifest_native_fps),
        ("state_durations_ms", &manifest_durations),
        ("state_frame_counts", &manifest_frame_counts),
    ] {
        if source.get(field).is_some() {
            require_metadata_match("source/source.json", field, source.get(field), expected)?;
        }
    }
    if validation.get("manifest_id").is_some() {
        require_metadata_match(
            "build/validation.json",
            "manifest_id",
            validation.get("manifest_id"),
            &serde_json::Value::String(manifest.id.clone()),
        )?;
    }
    for (field, expected) in [
        ("frame_count", &manifest_frame_count),
        ("native_fps", &manifest_native_fps),
        ("state_durations_ms", &manifest_durations),
        ("state_frame_counts", &manifest_frame_counts),
    ] {
        if validation.get(field).is_some() {
            require_metadata_match(
                "build/validation.json",
                field,
                validation.get(field),
                expected,
            )?;
        }
    }
    if let Some(artifact_manifest) = validation.get("manifest") {
        validate_json_schema(
            "build/validation.json manifest",
            artifact_manifest,
            PETPACK_MANIFEST_SCHEMA,
        )?;
        let artifact_manifest: PetManifest = serde_json::from_value(artifact_manifest.clone())?;
        if &artifact_manifest != manifest {
            return Err(PetCoreError::Validation(
                "build/validation.json manifest does not match manifest.json".to_string(),
            ));
        }
    }
    Ok(())
}

/// Enforces the portable-metadata privacy boundary independently from the
/// producer JSON schemas. In particular, `ai_brief` is intentionally open to
/// creative fields, so schema validation alone cannot stop a provider from
/// nesting execution traces, credentials, or local filesystem locations in
/// that object.
pub(crate) fn validate_safe_producer_json_privacy(
    relative_path: &str,
    value: &serde_json::Value,
) -> Result<()> {
    const MAX_PRIVACY_DEPTH: usize = 64;
    const MAX_PRIVACY_NODES: usize = 65_536;

    let mut stack = vec![(value, 0usize)];
    let mut visited = 0usize;
    while let Some((current, depth)) = stack.pop() {
        visited = visited.saturating_add(1);
        if visited > MAX_PRIVACY_NODES {
            return Err(metadata_privacy_error(
                relative_path,
                "metadata is too complex",
            ));
        }
        if depth > MAX_PRIVACY_DEPTH {
            return Err(metadata_privacy_error(
                relative_path,
                "metadata is too deeply nested",
            ));
        }

        match current {
            serde_json::Value::Object(object) => {
                for (key, nested) in object {
                    if let Some(category) = forbidden_private_field(key) {
                        return Err(metadata_privacy_error(
                            relative_path,
                            &format!("forbidden private field {category}"),
                        ));
                    }
                    stack.push((nested, depth + 1));
                }
            }
            serde_json::Value::Array(values) => {
                stack.extend(values.iter().map(|nested| (nested, depth + 1)));
            }
            serde_json::Value::String(text) => {
                if contains_external_locator(text) {
                    return Err(metadata_privacy_error(
                        relative_path,
                        "external locator is not portable",
                    ));
                }
                if contains_absolute_local_path(text) {
                    return Err(metadata_privacy_error(
                        relative_path,
                        "absolute local path is not portable",
                    ));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn metadata_privacy_error(relative_path: &str, category: &str) -> PetCoreError {
    // Both inputs are internal labels/categories. Never include the rejected
    // value (which may itself be a credential, transcript, or user path).
    PetCoreError::Validation(bounded_asset_error(&format!(
        "petpack metadata privacy check rejected {relative_path}: {category}"
    )))
}

fn forbidden_private_field(key: &str) -> Option<&'static str> {
    let normalized = normalize_private_field(key);
    if let Some(category) = private_field_category(&normalized) {
        return Some(category);
    }
    if let Some(category) = affixed_private_field_category(&normalized) {
        return Some(category);
    }

    // Extension and creative-object keys may carry a reverse-domain namespace
    // or a descriptive prefix/suffix. Match forbidden names only on explicit
    // punctuation/camel-case word boundaries so harmless words such as
    // `commanding` or `environmental` do not become false positives.
    let words = private_field_words(key);
    for start in 0..words.len() {
        let mut candidate = String::new();
        for word in &words[start..] {
            candidate.push_str(word);
            // Every currently forbidden field name is much shorter than this;
            // bounding candidate windows keeps adversarial long keys linear.
            if candidate.len() > 32 {
                break;
            }
            if let Some(category) = private_field_category(&candidate) {
                return Some(category);
            }
            if let Some(category) = affixed_private_field_category(&candidate) {
                return Some(category);
            }
        }
    }
    None
}

fn normalize_private_field(key: &str) -> String {
    key.chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn private_field_words(key: &str) -> Vec<String> {
    let characters = key.chars().collect::<Vec<_>>();
    let mut words = Vec::new();
    let mut current = String::new();
    for (index, character) in characters.iter().copied().enumerate() {
        if !character.is_ascii_alphanumeric() {
            if !current.is_empty() {
                words.push(current.to_ascii_lowercase());
                current.clear();
            }
            continue;
        }

        let previous = index
            .checked_sub(1)
            .and_then(|offset| characters.get(offset));
        let next = characters.get(index + 1);
        let camel_boundary = !current.is_empty()
            && character.is_ascii_uppercase()
            && (previous.is_some_and(|value| value.is_ascii_lowercase() || value.is_ascii_digit())
                || (previous.is_some_and(|value| value.is_ascii_uppercase())
                    && next.is_some_and(|value| value.is_ascii_lowercase())));
        if camel_boundary {
            words.push(current.to_ascii_lowercase());
            current.clear();
        }
        current.push(character);
    }
    if !current.is_empty() {
        words.push(current.to_ascii_lowercase());
    }
    words
}

fn private_field_category(normalized: &str) -> Option<&'static str> {
    match normalized {
        "threadid" => Some("thread_id"),
        "turnid" => Some("turn_id"),
        "sessionid" => Some("session_id"),
        "requestid" => Some("request_id"),
        "conversationid" => Some("conversation_id"),
        "conversation" | "conversations" => Some("conversation"),
        "messagehistory" | "messages" => Some("messages"),
        "transcript" | "transcripts" | "fulltranscript" | "rawtranscript" => Some("transcript"),
        "assistanttext" | "assistantmessage" | "usermessage" | "usermessages" => {
            Some("conversation_text")
        }
        "reasoning" | "reasoningtext" | "hiddenreasoning" | "chainofthought"
        | "internalthoughts" => Some("hidden_reasoning"),
        "command" | "commands" | "commandline" | "commandsource" | "shellcommand" => {
            Some("command")
        }
        "toolargs" | "toolarguments" | "toolinput" => Some("tool_input"),
        "tooloutput" | "toolresult" | "toolresults" | "toolresponse" | "toolresponses" => {
            Some("tool_output")
        }
        "stdout" | "stderr" => Some("process_output"),
        "environment" | "env" | "cwd" | "workingdirectory" | "workspacepath" => {
            Some("execution_environment")
        }
        "token" | "accesstoken" | "refreshtoken" | "apikey" => Some("credential"),
        "cookie" | "cookies" | "authorization" | "auth" | "authentication" => {
            Some("authentication")
        }
        "secret" | "secrets" | "password" | "credential" | "credentials" => Some("credential"),
        "codexappserver" => Some("codex_app_server"),
        _ => None,
    }
}

fn affixed_private_field_category(normalized: &str) -> Option<&'static str> {
    // These compound identifiers are specific enough to recognize when an
    // all-lowercase producer joins a descriptive affix without a separator.
    // Do not extend this to short/generic names such as token, secret, command,
    // or auth: that would reject ordinary creative keys like `tokenized` and
    // `commanding`.
    for (private_name, category) in [
        ("threadid", "thread_id"),
        ("turnid", "turn_id"),
        ("sessionid", "session_id"),
        ("requestid", "request_id"),
        ("conversationid", "conversation_id"),
        ("apikey", "credential"),
        ("accesstoken", "credential"),
        ("refreshtoken", "credential"),
        ("codexappserver", "codex_app_server"),
    ] {
        if normalized.len() > private_name.len()
            && (normalized.starts_with(private_name) || normalized.ends_with(private_name))
        {
            return Some(category);
        }
    }
    None
}

fn contains_absolute_local_path(text: &str) -> bool {
    let characters = text.chars().collect::<Vec<_>>();
    for (index, character) in characters.iter().copied().enumerate() {
        let previous = index
            .checked_sub(1)
            .and_then(|offset| characters.get(offset).copied());
        if !is_locator_boundary(previous) {
            continue;
        }
        let next = characters.get(index + 1).copied();
        let after_next = characters.get(index + 2).copied();

        if character == '~' && next == Some('/') {
            return true;
        }
        if character == '/'
            && next.is_some_and(|value| {
                value.is_ascii_alphanumeric() || matches!(value, '/' | '.' | '_' | '-')
            })
        {
            return true;
        }
        if character.is_ascii_alphabetic()
            && next == Some(':')
            && after_next.is_some_and(|value| matches!(value, '/' | '\\'))
        {
            return true;
        }
        if character == '\\'
            && next == Some('\\')
            && after_next.is_some_and(|value| {
                value.is_ascii_alphanumeric() || matches!(value, '.' | '_' | '-')
            })
        {
            return true;
        }
    }
    false
}

fn is_locator_boundary(previous: Option<char>) -> bool {
    previous.is_none_or(|character| {
        character.is_whitespace()
            || (!character.is_ascii_alphanumeric() && !matches!(character, '_' | '-'))
    })
}

fn contains_external_locator(text: &str) -> bool {
    let bytes = text.as_bytes();
    for (separator, _) in text.match_indices("://") {
        let mut start = separator;
        while start > 0
            && (bytes[start - 1].is_ascii_alphanumeric()
                || matches!(bytes[start - 1], b'+' | b'-' | b'.'))
        {
            start -= 1;
        }
        let scheme = &bytes[start..separator];
        if scheme.first().is_some_and(u8::is_ascii_alphabetic)
            && scheme.iter().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, b'+' | b'-' | b'.')
            })
        {
            return true;
        }
    }
    false
}

fn validate_json_schema(
    relative_path: &str,
    instance: &serde_json::Value,
    schema_source: &str,
) -> Result<()> {
    let schema: serde_json::Value = serde_json::from_str(schema_source).map_err(|_| {
        PetCoreError::Validation("bundled petpack metadata schema is invalid".to_string())
    })?;
    let validator = jsonschema::options()
        .with_draft(jsonschema::Draft::Draft202012)
        .should_validate_formats(true)
        .build(&schema)
        .map_err(|_| {
            PetCoreError::Validation("bundled petpack metadata schema is invalid".to_string())
        })?;
    let diagnostics = validator
        .iter_errors(instance)
        .take(8)
        .map(|error| {
            let instance_path = error.instance_path.to_string();
            let schema_path = error.schema_path.to_string();
            format!(
                "{} -> {}",
                if instance_path.is_empty() {
                    "/"
                } else {
                    &instance_path
                },
                if schema_path.is_empty() {
                    "/"
                } else {
                    &schema_path
                }
            )
        })
        .collect::<Vec<_>>();
    if diagnostics.is_empty() {
        return Ok(());
    }
    Err(PetCoreError::Validation(bounded_asset_error(&format!(
        "petpack metadata {relative_path} does not conform: {}",
        diagnostics.join(", ")
    ))))
}

fn require_metadata_match(
    relative_path: &str,
    field: &str,
    actual: Option<&serde_json::Value>,
    expected: &serde_json::Value,
) -> Result<()> {
    if actual == Some(expected) {
        return Ok(());
    }
    Err(PetCoreError::Validation(format!(
        "petpack metadata {relative_path} field {field} does not match manifest.json"
    )))
}

fn validate_source_metadata(dir: &Path) -> Result<()> {
    let value = read_json_file(dir, "source/source.json")?;
    for key in ["generator", "provenance"] {
        let present = value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .is_some_and(|text| !text.is_empty());
        if !present {
            return Err(PetCoreError::Validation(format!(
                "petpack metadata source/source.json must contain non-empty {key}"
            )));
        }
    }
    Ok(())
}

fn read_json_file(dir: &Path, relative_path: &str) -> Result<serde_json::Value> {
    let path = dir.join(relative_path);
    if !path.is_file() {
        return Err(PetCoreError::Validation(format!(
            "missing petpack metadata {relative_path}"
        )));
    }
    serde_json::from_slice(&fs::read(&path)?).map_err(|error| {
        PetCoreError::Validation(format!("invalid JSON metadata {relative_path}: {error}"))
    })
}

fn validate_nonempty_text_file(dir: &Path, relative_path: &str) -> Result<()> {
    let path = dir.join(relative_path);
    if !path.is_file() {
        return Err(PetCoreError::Validation(format!(
            "missing petpack metadata {relative_path}"
        )));
    }
    let content = fs::read_to_string(&path)?;
    if content.trim().is_empty() {
        return Err(PetCoreError::Validation(format!(
            "petpack metadata {relative_path} is empty"
        )));
    }
    Ok(())
}

fn validate_reference_directory(dir: &Path) -> Result<()> {
    let path = dir.join("source/references");
    if !path.is_dir() {
        return Err(PetCoreError::Validation(
            "missing petpack metadata source/references".to_string(),
        ));
    }
    Ok(())
}

fn validate_skill_session_jsonl(dir: &Path) -> Result<()> {
    let relative_path = "source/skill_session.jsonl";
    let path = dir.join(relative_path);
    if !path.is_file() {
        return Err(PetCoreError::Validation(format!(
            "missing petpack metadata {relative_path}"
        )));
    }
    let content = fs::read_to_string(&path)?;
    let mut has_event = false;
    for (index, line) in content.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let value: serde_json::Value = serde_json::from_str(trimmed).map_err(|error| {
            PetCoreError::Validation(format!(
                "invalid JSONL metadata {relative_path}: line {}: {error}",
                index + 1
            ))
        })?;
        if value
            .get("event")
            .and_then(serde_json::Value::as_str)
            .is_some()
        {
            has_event = true;
        }
    }
    if !has_event {
        return Err(PetCoreError::Validation(format!(
            "petpack metadata {relative_path} has no events"
        )));
    }
    Ok(())
}

fn validate_build_metadata(dir: &Path) -> Result<()> {
    let value = read_json_file(dir, "build/validation.json")?;
    if value.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
        return Err(PetCoreError::Validation(
            "petpack metadata build/validation.json must contain ok=true".to_string(),
        ));
    }
    Ok(())
}

fn validate_preview_image(
    dir: &Path,
    relative_path: &str,
    warnings: &mut Vec<String>,
) -> Result<()> {
    let path = dir.join(relative_path);
    if !path.is_file() {
        return Err(PetCoreError::Validation(format!(
            "missing preview asset {relative_path}"
        )));
    }

    let (width, height) = image::image_dimensions(&path).map_err(|err| {
        PetCoreError::Validation(format!("invalid preview asset {relative_path}: {err}"))
    })?;
    validate_pixel_budget(width, height, &format!("preview asset {relative_path}"))?;
    let decoded = image::open(&path).map_err(|error| {
        PetCoreError::Validation(format!("invalid preview asset {relative_path}: {error}"))
    })?;
    if relative_path == "assets/preview/cover.png" {
        validate_visible_cover(&decoded.to_rgba8(), relative_path)?;
    }
    if width != 384 || height != 416 {
        warnings.push(format!(
            "preview asset {relative_path} is {width}x{height}; recommended preview size is 384x416"
        ));
    }
    Ok(())
}

fn write_animated_webp(path: &Path, frames: &[RgbaImage]) -> Result<()> {
    let first = frames.first().ok_or_else(|| {
        PetCoreError::Validation("animated WebP requires at least one frame".to_string())
    })?;
    if frames.len() < 2 {
        return Err(PetCoreError::Validation(
            "animated WebP requires at least two frames".to_string(),
        ));
    }
    if first.width() == 0 || first.height() == 0 {
        return Err(PetCoreError::Validation(
            "animated WebP frames must not be empty".to_string(),
        ));
    }
    if frames
        .iter()
        .any(|frame| frame.dimensions() != first.dimensions())
    {
        return Err(PetCoreError::Validation(
            "animated WebP frames must use one canvas size".to_string(),
        ));
    }

    let mut output = Vec::new();
    output.extend_from_slice(b"RIFF");
    output.extend_from_slice(&[0; 4]);
    output.extend_from_slice(b"WEBP");

    let mut extended_header = vec![0x12, 0, 0, 0]; // alpha + animation
    push_webp_u24(&mut extended_header, first.width() - 1)?;
    push_webp_u24(&mut extended_header, first.height() - 1)?;
    append_webp_chunk(&mut output, b"VP8X", &extended_header)?;

    // Transparent background and infinite loop.
    append_webp_chunk(&mut output, b"ANIM", &[0, 0, 0, 0, 0, 0])?;
    for frame in frames {
        let mut encoded = Vec::new();
        WebPEncoder::new_lossless(&mut encoded).write_image(
            frame.as_raw(),
            frame.width(),
            frame.height(),
            image::ExtendedColorType::Rgba8,
        )?;
        if encoded.len() < 12 || &encoded[..4] != b"RIFF" || &encoded[8..12] != b"WEBP" {
            return Err(PetCoreError::Validation(
                "could not encode an animated WebP frame".to_string(),
            ));
        }

        let mut animation_frame = Vec::new();
        push_webp_u24(&mut animation_frame, 0)?; // x offset / 2
        push_webp_u24(&mut animation_frame, 0)?; // y offset / 2
        push_webp_u24(&mut animation_frame, frame.width() - 1)?;
        push_webp_u24(&mut animation_frame, frame.height() - 1)?;
        // Use a 100 millisecond frame duration. Replace the canvas for each
        // full-size frame: blending two identical semi-transparent inputs
        // would otherwise create pixel differences that are not real animation.
        push_webp_u24(&mut animation_frame, 100)?;
        animation_frame.push(0x02); // no blending; do not dispose
        animation_frame.extend_from_slice(&encoded[12..]);
        append_webp_chunk(&mut output, b"ANMF", &animation_frame)?;
    }

    let riff_size = u32::try_from(output.len().saturating_sub(8)).map_err(|_| {
        PetCoreError::Validation("animated WebP exceeds RIFF size limits".to_string())
    })?;
    output[4..8].copy_from_slice(&riff_size.to_le_bytes());
    fs::write(path, output)?;
    Ok(())
}

fn append_webp_chunk(output: &mut Vec<u8>, fourcc: &[u8; 4], payload: &[u8]) -> Result<()> {
    let payload_size = u32::try_from(payload.len()).map_err(|_| {
        PetCoreError::Validation("animated WebP chunk exceeds RIFF size limits".to_string())
    })?;
    output.extend_from_slice(fourcc);
    output.extend_from_slice(&payload_size.to_le_bytes());
    output.extend_from_slice(payload);
    if payload.len() & 1 == 1 {
        output.push(0);
    }
    Ok(())
}

fn push_webp_u24(output: &mut Vec<u8>, value: u32) -> Result<()> {
    if value > 0x00ff_ffff {
        return Err(PetCoreError::Validation(
            "animated WebP dimension exceeds format limits".to_string(),
        ));
    }
    let bytes = value.to_le_bytes();
    output.extend_from_slice(&bytes[..3]);
    Ok(())
}

pub fn write_sample_petpack_dir(
    dir: &Path,
    quality: QualityLevel,
    name: &str,
    style: &str,
) -> Result<PetManifest> {
    fs::create_dir_all(dir)?;
    let manifest = PetManifest::new(
        new_id("pet"),
        name.to_string(),
        style.to_string(),
        quality,
        now_rfc3339(),
    );
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    fs::write(dir.join("manifest.json"), manifest_json)?;
    let state_durations_ms = manifest_state_durations_ms(&manifest);
    let state_frame_counts = manifest_state_frame_counts(&manifest)?;
    let total_frame_count = state_frame_counts.values().sum::<usize>();
    fs::write(
        dir.join("brief.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-brief.v1",
            "name": name,
            "style": style,
            "quality": quality,
            "states": REQUIRED_STATES.iter().map(|state| serde_json::json!({
                "name": state.as_str(),
                "motion": "Sample validation motion",
                "duration_ms": state.default_duration_ms()
            })).collect::<Vec<_>>(),
            "runtime": {
                "native_fps": manifest.native_fps,
                "state_durations_ms": state_durations_ms,
                "state_frame_counts": state_frame_counts,
                "render_size": manifest.render_size
            }
        }))?,
    )?;

    for state in REQUIRED_STATES {
        let state_dir = dir.join("assets").join("frames").join(state.as_str());
        fs::create_dir_all(&state_dir)?;
        let frame_count = state_frame_counts.get(&state).copied().ok_or_else(|| {
            PetCoreError::Validation(format!("missing frame count for state {}", state.as_str()))
        })?;
        for index in 0..frame_count {
            let frame = draw_sample_frame(manifest.render_size, state, index);
            frame.save(state_dir.join(format!("{index:04}.png")))?;
        }
    }

    let preview_dir = dir.join("assets").join("preview");
    fs::create_dir_all(&preview_dir)?;
    let preview_size = RenderSize {
        width: 384,
        height: 416,
    };
    let preview_cover = draw_sample_frame(preview_size, PetStateName::Idle, 0);
    let preview_second = draw_sample_frame(preview_size, PetStateName::Idle, 1);
    preview_cover.save(preview_dir.join("cover.png"))?;
    write_animated_webp(
        &preview_dir.join("animated_preview.webp"),
        &[preview_cover, preview_second],
    )?;

    let source_dir = dir.join("source");
    fs::create_dir_all(source_dir.join("references"))?;
    fs::write(
        source_dir.join("prompt.md"),
        "Sample pet generated for validation.\n",
    )?;
    fs::write(
        source_dir.join("source.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-source.v1",
            "generator": "sample-petpack",
            "provenance": "test_fixture",
            "created_at": manifest.created_at,
            "pet_name": name,
            "style": style,
            "quality": quality,
            "native_fps": manifest.native_fps,
            "state_durations_ms": state_durations_ms,
            "state_frame_counts": state_frame_counts
        }))?,
    )?;
    fs::write(
        source_dir.join("skill_session.jsonl"),
        serde_json::to_string(&serde_json::json!({
            "schema_version": "apc.pet-source-event.v1",
            "event": "skill.loaded",
            "skill": "agent-pet-studio",
            "runner": "sample-petpack",
            "created_at": manifest.created_at,
        }))? + "\n",
    )?;

    let build_dir = dir.join("build");
    fs::create_dir_all(&build_dir)?;
    fs::write(
        build_dir.join("validation.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-validation.v1",
            "ok": true,
            "validator": "sample-petpack",
            "frame_count": total_frame_count,
            "native_fps": manifest.native_fps,
            "state_durations_ms": state_durations_ms,
            "state_frame_counts": state_frame_counts
        }))?,
    )?;

    Ok(manifest)
}

pub fn write_generated_petpack_dir(
    dir: &Path,
    form: &GenerationForm,
    pet_name: &str,
    ai_brief: Option<&serde_json::Value>,
) -> Result<PetManifest> {
    write_generated_petpack_dir_with_identity(dir, form, pet_name, ai_brief, None)
}

pub fn write_skill_generated_petpack_dir(
    dir: &Path,
    form: &GenerationForm,
    pet_name: &str,
    ai_brief: Option<&serde_json::Value>,
) -> Result<PetManifest> {
    write_generated_petpack_dir_with_identity(
        dir,
        form,
        pet_name,
        ai_brief,
        Some(("petcore-deterministic-preview", "deterministic_preview")),
    )
}

fn write_generated_petpack_dir_with_identity(
    dir: &Path,
    form: &GenerationForm,
    pet_name: &str,
    ai_brief: Option<&serde_json::Value>,
    source_identity: Option<(&str, &str)>,
) -> Result<PetManifest> {
    fs::create_dir_all(dir)?;
    let mut manifest = PetManifest::new(
        new_id("pet"),
        pet_name.to_string(),
        form.style.clone(),
        form.quality,
        now_rfc3339(),
    );
    manifest.native_fps = form.native_fps;
    for state in &mut manifest.states {
        state.duration_ms = form
            .state_durations_ms
            .get(&state.name)
            .copied()
            .unwrap_or_else(|| state.name.default_duration_ms());
    }
    validate_manifest(&manifest)?;
    let state_durations_ms = manifest_state_durations_ms(&manifest);
    let state_frame_counts = manifest_state_frame_counts(&manifest)?;
    let total_frame_count = state_frame_counts.values().sum::<usize>();
    fs::write(
        dir.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;

    let palette = Palette::from_form_and_brief(form, ai_brief);
    let (reference_copies, reference_frame_source) =
        materialize_reference_inputs(dir, &form.reference_images, manifest.render_size)?;
    let source_form = form_with_package_references(form, &reference_copies);
    let action_plan = action_plan_for_form(form, ai_brief);
    let has_ai_brief = ai_brief.map(|brief| !brief.is_null()).unwrap_or(false);
    let (generator, provenance) = if let Some(identity) = source_identity {
        identity
    } else if has_ai_brief {
        (
            "codex-app-server-brief-petpack-v1",
            "codex_app_server_brief",
        )
    } else {
        ("local-form-driven-petpack-v1", "local_form")
    };
    fs::write(
        dir.join("brief.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-brief.v1",
            "name": pet_name,
            "style": form.style,
            "quality": form.quality,
            "description": form.description,
            "generation": {
                "generator": generator,
                "provenance": provenance
            },
            "ai_brief": ai_brief,
            "references": reference_copies,
            "states": action_plan,
            "runtime": {
                "native_fps": manifest.native_fps,
                "state_durations_ms": state_durations_ms,
                "state_frame_counts": state_frame_counts,
                "render_size": manifest.render_size
            }
        }))?,
    )?;

    for state in REQUIRED_STATES {
        let frame_count = state_frame_counts.get(&state).copied().ok_or_else(|| {
            PetCoreError::Validation(format!("missing frame count for state {}", state.as_str()))
        })?;
        let duration_ms = state_durations_ms.get(&state).copied().ok_or_else(|| {
            PetCoreError::Validation(format!("missing duration for state {}", state.as_str()))
        })?;
        let state_dir = dir.join("assets").join("frames").join(state.as_str());
        fs::create_dir_all(&state_dir)?;
        for index in 0..frame_count {
            // Native FPS and duration are immutable authored properties. A
            // timing edit must therefore produce a new ordered sequence even
            // when two valid timing combinations happen to have the same
            // frame count (10 FPS × 2 s and 20 FPS × 1 s).
            let rendered_index =
                timing_adjusted_frame_index(index, frame_count, manifest.native_fps, duration_ms);
            let frame = match reference_frame_source.as_ref() {
                Some(source) => draw_reference_frame(
                    source,
                    manifest.render_size,
                    state,
                    rendered_index,
                    frame_count,
                ),
                None => draw_generated_frame(
                    manifest.render_size,
                    state,
                    rendered_index,
                    frame_count,
                    &palette,
                ),
            };
            frame.save(state_dir.join(format!("{index:04}.png")))?;
        }
    }

    let preview_dir = dir.join("assets").join("preview");
    fs::create_dir_all(&preview_dir)?;
    let preview_size = RenderSize {
        width: 384,
        height: 416,
    };
    let idle_frame_count = state_frame_counts
        .get(&PetStateName::Idle)
        .copied()
        .ok_or_else(|| PetCoreError::Validation("missing idle frame count".to_string()))?;
    let preview_cover = match reference_frame_source.as_ref() {
        Some(source) => draw_reference_frame(
            source,
            preview_size,
            PetStateName::Idle,
            0,
            idle_frame_count,
        ),
        None => draw_generated_frame(
            preview_size,
            PetStateName::Idle,
            0,
            idle_frame_count,
            &palette,
        ),
    };
    preview_cover.save(preview_dir.join("cover.png"))?;
    let preview_animated = match reference_frame_source.as_ref() {
        Some(source) => draw_reference_frame(
            source,
            preview_size,
            PetStateName::Idle,
            1,
            idle_frame_count,
        ),
        None => draw_generated_frame(
            preview_size,
            PetStateName::Idle,
            1,
            idle_frame_count,
            &palette,
        ),
    };
    write_animated_webp(
        &preview_dir.join("animated_preview.webp"),
        &[preview_cover, preview_animated],
    )?;

    let source_dir = dir.join("source");
    fs::create_dir_all(&source_dir)?;
    fs::write(
        source_dir.join("prompt.md"),
        prompt_markdown(&source_form, pet_name),
    )?;
    fs::write(
        source_dir.join("source.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-source.v1",
            "generator": generator,
            "provenance": provenance,
            "created_at": manifest.created_at,
            "form": source_form,
            "pet_name": pet_name,
            "ai_brief": ai_brief,
            "palette": palette.as_json(),
            "palette_source": if palette.from_ai_brief { "codex-ai-brief" } else { "form-derived" },
            "visual_source": if reference_frame_source.is_some() { "reference-image" } else { "generated-vector" },
            "native_fps": manifest.native_fps,
            "state_durations_ms": state_durations_ms,
            "state_frame_counts": state_frame_counts,
            "input_reference_count": form.reference_images.len(),
            "copied_reference_count": reference_copies.len(),
            "reference_files": reference_copies
        }))?,
    )?;

    let build_dir = dir.join("build");
    fs::create_dir_all(&build_dir)?;
    fs::write(
        build_dir.join("validation.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-validation.v1",
            "ok": true,
            "validator": "petcore",
            "generator": generator,
            "provenance": provenance,
            "frame_count": total_frame_count,
            "native_fps": manifest.native_fps,
            "state_durations_ms": state_durations_ms,
            "state_frame_counts": state_frame_counts
        }))?,
    )?;

    Ok(manifest)
}

struct PreparedImport {
    validation: PetpackValidation,
    target_path: PathBuf,
    cover_target_path: PathBuf,
    generator: Option<String>,
    provenance: Option<String>,
    transaction: PetRevisionTransaction,
}

pub fn build_petpack(input_dir: &Path, output_path: &Path) -> Result<PetpackValidation> {
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)?;
    }
    reject_output_inside_input(input_dir, output_path)?;
    let parent = output_path.parent().unwrap_or_else(|| Path::new("."));
    let stage = tempfile::Builder::new()
        .prefix(".apc-petpack-build-")
        .tempdir_in(parent)?;
    let staged_output = stage.path().join("package.petpack");
    let validation = write_petpack_zip(input_dir, &staged_output)?;
    commit_asset_replacements(&[AssetReplacement::file(
        staged_output,
        output_path.to_path_buf(),
        stage.path().join("previous-package.petpack"),
    )])?;
    Ok(validation)
}

/// Exports the currently installed immutable package for `pet_id` without
/// rebuilding it. The owned archive is validated before it is copied, the
/// staged copy is validated again, and only then is it atomically renamed to
/// the caller-selected destination. Keeping the original archive bytes makes
/// export/import a lossless round trip for provenance and optional metadata.
pub fn export_petpack(
    paths: &AppPaths,
    database: &Database,
    pet_id: &str,
    output_path: &Path,
) -> Result<PetpackExport> {
    validate_pet_id(pet_id)?;
    let _store_guard = PetStoreGuard::acquire(paths)?;
    let pet = database
        .get_pet(pet_id)?
        .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {pet_id}")))?;
    let source_path = owned_pet_asset_path(paths, Path::new(&pet.petpack_path), AssetKind::File)?
        .ok_or_else(|| {
        PetCoreError::Validation(format!(
            "installed petpack for {pet_id} is missing or outside the owned pet store"
        ))
    })?;
    let validation = validate_petpack_path(&source_path)?;
    if validation.manifest.id != pet.id {
        return Err(PetCoreError::Validation(format!(
            "installed petpack manifest id {} does not match library pet {}",
            validation.manifest.id, pet.id
        )));
    }

    let output_file_name = output_path.file_name().ok_or_else(|| {
        PetCoreError::InvalidRequest(format!(
            "petpack export path must name a file: {}",
            output_path.display()
        ))
    })?;
    if output_file_name.is_empty() {
        return Err(PetCoreError::InvalidRequest(
            "petpack export path must name a file".to_string(),
        ));
    }
    let requested_parent = output_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    if !requested_parent.is_dir() {
        return Err(PetCoreError::InvalidRequest(format!(
            "petpack export parent directory does not exist: {}",
            requested_parent.display()
        )));
    }
    let output_parent = fs::canonicalize(requested_parent)?;
    let owned_store = fs::canonicalize(&paths.pets_dir)?;
    let output_path = output_parent.join(output_file_name);
    if output_path.starts_with(&owned_store) {
        return Err(PetCoreError::Validation(
            "petpack export destination must be outside the owned pet store".to_string(),
        ));
    }
    if let Ok(metadata) = fs::symlink_metadata(&output_path) {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(PetCoreError::Validation(format!(
                "petpack export destination must be a regular file: {}",
                output_path.display()
            )));
        }
    }

    let stage = tempfile::Builder::new()
        .prefix(".apc-petpack-export-")
        .tempdir_in(&output_parent)?;
    let staged_output = stage.path().join("package.petpack");
    let source_size = fs::metadata(&source_path)?.len();
    let copied = fs::copy(&source_path, &staged_output)?;
    if copied != source_size {
        return Err(PetCoreError::Validation(
            "installed petpack changed while it was being exported".to_string(),
        ));
    }
    File::open(&staged_output)?.sync_all()?;
    let staged_validation = validate_petpack_path(&staged_output)?;
    if staged_validation.manifest != validation.manifest
        || staged_validation.frame_count != validation.frame_count
        || staged_validation.warnings != validation.warnings
    {
        return Err(PetCoreError::Validation(
            "staged petpack validation changed while exporting".to_string(),
        ));
    }

    // On the supported Unix/macOS runtime, rename replaces an existing regular
    // file in one filesystem operation. The staged file lives in the target
    // directory, so the commit cannot cross filesystems.
    fs::rename(&staged_output, &output_path)?;
    File::open(&output_parent)?.sync_all()?;

    Ok(PetpackExport {
        ok: true,
        pet_id: pet.id,
        output_path: output_path.display().to_string(),
        byte_count: copied,
        validation: staged_validation,
    })
}

fn reject_output_inside_input(input_dir: &Path, output_path: &Path) -> Result<()> {
    let canonical_input = fs::canonicalize(input_dir)?;
    let output_parent = output_path.parent().unwrap_or_else(|| Path::new("."));
    let canonical_output_parent = fs::canonicalize(output_parent)?;
    let canonical_output = match output_path.file_name() {
        Some(file_name) => canonical_output_parent.join(file_name),
        None => canonical_output_parent,
    };
    if canonical_output.starts_with(&canonical_input) {
        return Err(PetCoreError::Validation(format!(
            "petpack output {} must not be inside input directory {}",
            output_path.display(),
            input_dir.display()
        )));
    }
    Ok(())
}

fn write_petpack_zip(input_dir: &Path, output_path: &Path) -> Result<PetpackValidation> {
    let validation = validate_petpack_dir(input_dir)?;
    let file = File::create(output_path)?;
    let mut zip = zip::ZipWriter::new(file);
    zip_dir(input_dir, input_dir, &mut zip)?;
    zip.finish()?;
    let staged_validation = validate_petpack_path(output_path)?;
    if staged_validation.manifest.id != validation.manifest.id {
        return Err(PetCoreError::Validation(
            "staged petpack manifest id changed while building".to_string(),
        ));
    }
    Ok(validation)
}

/// Installs the two release-bundled pets without replacing any logical pet
/// already present under the same stable manifest ID.
///
/// Names are deliberately not part of conflict resolution. A user pet with
/// the same display name and a different ID remains visible beside the
/// bundled pet; an existing matching ID always wins and is left byte-for-byte
/// untouched. Re-running this function is therefore deterministic and safe on
/// first launch, upgrade, and App bootstrap against an already healthy daemon.
pub fn seed_bundled_pet_inventory(
    paths: &AppPaths,
    database: &Database,
    inventory_root: &Path,
) -> Result<Vec<BundledPetSeedOutcome>> {
    // The steady-state App launch must not unzip and decode both packages.
    // While holding the same mutation lock used by imports/deletes, first
    // establish whether both stable IDs already exist. No resource bytes are
    // trusted or written on this fast path, so validating the bundle again
    // would add latency without improving conflict safety.
    {
        let _store_guard = PetStoreGuard::acquire(paths)?;
        let existing = BUNDLED_PET_DESCRIPTORS
            .iter()
            .map(|descriptor| {
                database
                    .get_pet(descriptor.pet_id)
                    .map(|pet| (descriptor, pet))
            })
            .collect::<Result<Vec<_>>>()?;
        if existing.iter().all(|(_, pet)| pet.is_some()) {
            return Ok(existing
                .into_iter()
                .filter_map(|(descriptor, pet)| pet.map(|pet| (descriptor, pet)))
                .map(|(descriptor, pet)| BundledPetSeedOutcome {
                    pet_id: descriptor.pet_id.to_string(),
                    status: BundledPetSeedStatus::PreservedExistingId,
                    pet,
                })
                .collect());
        }
    }

    let inventory = validate_bundled_pet_inventory(inventory_root)?;
    let store_guard = PetStoreGuard::acquire(paths)?;
    let mut outcomes = Vec::with_capacity(inventory.len());

    for item in inventory {
        if let Some(existing) = database.get_pet(item.descriptor.pet_id)? {
            outcomes.push(BundledPetSeedOutcome {
                pet_id: item.descriptor.pet_id.to_string(),
                status: BundledPetSeedStatus::PreservedExistingId,
                pet: existing,
            });
            continue;
        }

        let pet = import_petpack_with_origin_policy_guarded(
            paths,
            database,
            &item.path,
            ImportIdentityPolicy::BundledInventory,
            false,
            Some(item.expected_digest),
            &store_guard,
        )?;
        outcomes.push(BundledPetSeedOutcome {
            pet_id: item.descriptor.pet_id.to_string(),
            status: BundledPetSeedStatus::Installed,
            pet,
        });
    }

    Ok(outcomes)
}

fn validate_bundled_pet_inventory(inventory_root: &Path) -> Result<Vec<ValidatedBundledPet>> {
    if !inventory_root.is_absolute() {
        return Err(PetCoreError::InvalidRequest(
            "bundled pet inventory root must be absolute".to_string(),
        ));
    }
    let root_metadata = fs::symlink_metadata(inventory_root).map_err(|_| {
        PetCoreError::Validation("bundled pet inventory is unavailable".to_string())
    })?;
    if !root_metadata.file_type().is_dir() {
        return Err(PetCoreError::Validation(
            "bundled pet inventory root must be a real directory".to_string(),
        ));
    }
    let canonical_root = fs::canonicalize(inventory_root).map_err(|_| {
        PetCoreError::Validation("bundled pet inventory cannot be resolved".to_string())
    })?;

    let expected_names = BUNDLED_PET_DESCRIPTORS
        .iter()
        .map(|descriptor| descriptor.file_name)
        .collect::<BTreeSet<_>>();
    let mut actual_names = BTreeSet::new();
    for entry in fs::read_dir(inventory_root)? {
        let entry = entry?;
        let Some(file_name) = entry.file_name().to_str().map(ToOwned::to_owned) else {
            return Err(PetCoreError::Validation(
                "bundled pet inventory contains a non-UTF-8 entry".to_string(),
            ));
        };
        if !expected_names.contains(file_name.as_str()) || !actual_names.insert(file_name) {
            return Err(PetCoreError::Validation(
                "bundled pet inventory contains an unexpected entry".to_string(),
            ));
        }
    }
    if actual_names.len() != BUNDLED_PET_DESCRIPTORS.len() {
        return Err(PetCoreError::Validation(
            "bundled pet inventory is incomplete".to_string(),
        ));
    }

    let mut validated = Vec::with_capacity(BUNDLED_PET_DESCRIPTORS.len());
    for descriptor in BUNDLED_PET_DESCRIPTORS {
        let path = inventory_root.join(descriptor.file_name);
        let metadata = fs::symlink_metadata(&path).map_err(|_| {
            PetCoreError::Validation("bundled pet resource is unavailable".to_string())
        })?;
        if !metadata.file_type().is_file() || metadata.nlink() != 1 {
            return Err(PetCoreError::Validation(
                "bundled pet resource must be a single-link regular file".to_string(),
            ));
        }
        let canonical_path = fs::canonicalize(&path).map_err(|_| {
            PetCoreError::Validation("bundled pet resource cannot be resolved".to_string())
        })?;
        if canonical_path.parent() != Some(canonical_root.as_path()) {
            return Err(PetCoreError::Validation(
                "bundled pet resource escaped its inventory root".to_string(),
            ));
        }

        let digest = sha256_file(&path)?;
        if hex::encode(digest) != descriptor.sha256 {
            return Err(PetCoreError::Validation(
                "bundled pet resource digest does not match the release inventory".to_string(),
            ));
        }
        let validation = validate_petpack_path(&path)?;
        if validation.manifest.id != descriptor.pet_id {
            return Err(PetCoreError::Validation(
                "bundled pet manifest ID does not match the release inventory".to_string(),
            ));
        }
        validated.push(ValidatedBundledPet {
            descriptor,
            path,
            expected_digest: digest,
        });
    }
    Ok(validated)
}

pub fn import_petpack(
    paths: &AppPaths,
    database: &Database,
    source_path: &Path,
) -> Result<PetSummary> {
    import_petpack_with_origin(paths, database, source_path, PetOrigin::ExternalImport)
}

pub fn import_petpack_expecting_absent(
    paths: &AppPaths,
    database: &Database,
    source_path: &Path,
) -> Result<PetSummary> {
    let store_guard = PetStoreGuard::acquire(paths)?;
    import_petpack_with_origin_policy_guarded(
        paths,
        database,
        source_path,
        ImportIdentityPolicy::PackageDeclared(PetOrigin::ExternalImport),
        false,
        None,
        &store_guard,
    )
}

pub fn import_petpack_with_origin(
    paths: &AppPaths,
    database: &Database,
    source_path: &Path,
    origin: PetOrigin,
) -> Result<PetSummary> {
    let store_guard = PetStoreGuard::acquire(paths)?;
    import_petpack_with_origin_guarded(paths, database, source_path, origin, &store_guard)
}

/// Imports while the caller holds the pet-store mutation lock. This is kept
/// crate-private so generation can make its stale-edit precondition and the
/// revision commit one serialized operation without attempting to flock the
/// same store twice.
pub(crate) fn import_petpack_with_origin_guarded(
    paths: &AppPaths,
    database: &Database,
    source_path: &Path,
    origin: PetOrigin,
    store_guard: &PetStoreGuard,
) -> Result<PetSummary> {
    import_petpack_with_origin_policy_guarded(
        paths,
        database,
        source_path,
        ImportIdentityPolicy::PackageDeclared(origin),
        true,
        None,
        store_guard,
    )
}

fn import_petpack_with_origin_policy_guarded(
    paths: &AppPaths,
    database: &Database,
    source_path: &Path,
    identity_policy: ImportIdentityPolicy,
    allow_existing_id_revision: bool,
    expected_source_digest: Option<[u8; 32]>,
    _store_guard: &PetStoreGuard,
) -> Result<PetSummary> {
    let prepared = prepare_import_assets(paths, source_path, expected_source_digest)?;
    let PreparedImport {
        validation,
        target_path,
        cover_target_path: cover_path,
        generator: package_generator,
        provenance: package_provenance,
        transaction,
    } = prepared;
    let (origin, generator, provenance) = match identity_policy {
        ImportIdentityPolicy::PackageDeclared(origin) => {
            (origin, package_generator, package_provenance)
        }
        ImportIdentityPolicy::BundledInventory => (
            PetOrigin::VerifiedSkillSource,
            Some(BUNDLED_PET_GENERATOR_MARKER.to_string()),
            Some(BUNDLED_PET_PROVENANCE_MARKER.to_string()),
        ),
    };
    let existing_pet = database.get_pet(&validation.manifest.id)?;
    if existing_pet.as_ref().is_some_and(is_bundled_pet) {
        return Err(PetCoreError::Conflict(format!(
            "bundled pet id is read-only: {}",
            validation.manifest.id
        )));
    }
    let candidate = PetSummary {
        id: validation.manifest.id.clone(),
        name: validation.manifest.name.clone(),
        style: validation.manifest.style.clone(),
        quality: validation.manifest.quality,
        render_size: validation.manifest.render_size,
        native_fps: validation.manifest.native_fps,
        state_durations_ms: manifest_state_durations_ms(&validation.manifest),
        petpack_path: target_path.display().to_string(),
        cover_path: cover_path.display().to_string(),
        origin,
        generator,
        provenance,
        revision_id: None,
        revision_count: 0,
        active: false,
        created_at: validation.manifest.created_at.clone(),
    };
    if matches!(identity_policy, ImportIdentityPolicy::PackageDeclared(_))
        && is_bundled_pet(&candidate)
    {
        return Err(PetCoreError::Validation(
            "bundled pet identity marker is reserved for the App release inventory".to_string(),
        ));
    }
    if existing_pet.is_some() && !allow_existing_id_revision {
        return Err(PetCoreError::Conflict(format!(
            "pet id already exists: {}",
            validation.manifest.id
        )));
    }
    let was_active = existing_pet.as_ref().is_some_and(|pet| pet.active);
    let pet = PetSummary {
        active: was_active,
        created_at: existing_pet
            .as_ref()
            .map(|pet| pet.created_at.clone())
            .unwrap_or(candidate.created_at),
        ..candidate
    };
    transaction.commit(database, pet)
}

fn prepare_import_assets(
    paths: &AppPaths,
    source_path: &Path,
    expected_source_digest: Option<[u8; 32]>,
) -> Result<PreparedImport> {
    if expected_source_digest.is_some() {
        let metadata = fs::symlink_metadata(source_path).map_err(|_| {
            PetCoreError::Validation("bundled pet resource is unavailable".to_string())
        })?;
        if !metadata.file_type().is_file() || metadata.nlink() != 1 {
            return Err(PetCoreError::Validation(
                "bundled pet resource identity changed during import".to_string(),
            ));
        }
    }
    let source_digest_before = source_path
        .is_file()
        .then(|| sha256_file(source_path))
        .transpose()?;
    if let Some(expected) = expected_source_digest {
        if source_digest_before != Some(expected) {
            return Err(PetCoreError::Conflict(
                "bundled pet resource changed during import".to_string(),
            ));
        }
    }
    let validation = validate_petpack_path(source_path)?;
    if let Some(expected) = source_digest_before {
        if sha256_file(source_path)? != expected {
            return Err(PetCoreError::Conflict(
                "petpack changed while it was being validated".to_string(),
            ));
        }
    }
    fs::create_dir_all(&paths.pets_dir)?;
    let transaction = PetRevisionTransaction::stage(paths, &validation.manifest.id)?;
    let package_stage_path = transaction.stage_petpack_path().to_path_buf();
    if source_path.is_dir() {
        write_petpack_zip(source_path, &package_stage_path)?;
    } else {
        let expected_digest = source_digest_before.ok_or_else(|| {
            PetCoreError::Validation("petpack source archive is not a regular file".to_string())
        })?;
        fs::copy(source_path, &package_stage_path)?;
        if sha256_file(&package_stage_path)? != expected_digest {
            return Err(PetCoreError::Validation(
                "staged petpack archive does not match validated source".to_string(),
            ));
        }
    }

    write_cover_image(
        &package_stage_path,
        &package_stage_path,
        transaction.stage_cover_path(),
    )?;
    prepare_runtime_frames_to_dir(
        &package_stage_path,
        &package_stage_path,
        transaction.stage_frames_dir(),
        &validation.manifest,
    )?;
    let (generator, provenance) =
        read_petpack_generation_metadata(&package_stage_path, &package_stage_path);
    let target_path = transaction.layout().petpack_path.clone();
    let cover_target_path = transaction.layout().cover_path.clone();

    validate_cover_file(transaction.stage_cover_path())?;
    validate_runtime_frames_for_manifest(transaction.stage_frames_dir(), &validation.manifest)?;

    Ok(PreparedImport {
        validation,
        target_path,
        cover_target_path,
        generator,
        provenance,
        transaction,
    })
}

fn sha256_file(path: &Path) -> Result<[u8; 32]> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().into())
}

pub fn remove_imported_pet_assets(paths: &AppPaths, pet: &PetSummary) -> Result<()> {
    let _store_guard = PetStoreGuard::acquire(paths)?;
    if let Some(root) = revision_pet_root(paths, pet)? {
        remove_owned_pet_dir(paths, &root)?;
        return Ok(());
    }
    remove_owned_pet_file(paths, Path::new(&pet.petpack_path))?;
    remove_owned_pet_file(paths, Path::new(&pet.cover_path))?;
    remove_owned_pet_dir(paths, &runtime_frames_dir_for_pet(paths, pet)?)?;
    Ok(())
}

pub struct StagedPetAssetRemoval {
    staged: Vec<StagedPetAsset>,
    trash_root: PathBuf,
    _store_guard: PetStoreGuard,
}

struct StagedPetAsset {
    original: PathBuf,
    staged: PathBuf,
}

impl StagedPetAssetRemoval {
    pub fn commit(self) -> bool {
        let mut removed_all = true;
        for asset in &self.staged {
            if path_exists(&asset.staged) && remove_path(&asset.staged).is_err() {
                removed_all = false;
            }
        }
        if path_exists(&self.trash_root) && remove_path(&self.trash_root).is_err() {
            removed_all = false;
        }
        removed_all
    }

    pub fn rollback(&self) -> Result<()> {
        for asset in self.staged.iter().rev() {
            if path_exists(&asset.staged) && !path_exists(&asset.original) {
                fs::rename(&asset.staged, &asset.original)?;
            }
        }
        if path_exists(&self.trash_root) {
            let _ = remove_path(&self.trash_root);
        }
        Ok(())
    }
}

pub fn stage_imported_pet_assets_for_removal(
    paths: &AppPaths,
    pet: &PetSummary,
) -> Result<StagedPetAssetRemoval> {
    fs::create_dir_all(&paths.pets_dir)?;
    let _store_guard = PetStoreGuard::acquire(paths)?;
    let trash_root = paths
        .pets_dir
        .join(format!(".apc-delete-{}", uuid::Uuid::now_v7().simple()));
    fs::create_dir_all(&trash_root)?;

    let mut staged = Vec::new();
    let candidates = if let Some(root) = revision_pet_root(paths, pet)? {
        // Validate the typed assets before staging the containing immutable
        // revision tree. A corrupt child must not let the DB row be deleted.
        let _ = owned_pet_asset_path(paths, Path::new(&pet.petpack_path), AssetKind::File)?;
        let _ = owned_pet_asset_path(paths, Path::new(&pet.cover_path), AssetKind::File)?;
        let _ = owned_pet_asset_path(
            paths,
            &runtime_frames_dir_for_pet(paths, pet)?,
            AssetKind::Dir,
        )?;
        vec![(root, AssetKind::Dir)]
    } else {
        vec![
            (Path::new(&pet.petpack_path).to_path_buf(), AssetKind::File),
            (Path::new(&pet.cover_path).to_path_buf(), AssetKind::File),
            (runtime_frames_dir_for_pet(paths, pet)?, AssetKind::Dir),
        ]
    };

    for (index, (path, kind)) in candidates.iter().enumerate() {
        let Some(original) = owned_pet_asset_path(paths, path, *kind)? else {
            continue;
        };
        let name = original
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("asset");
        let staged_path = trash_root.join(format!("{index}-{name}"));
        if let Err(error) = fs::rename(&original, &staged_path) {
            let removal = StagedPetAssetRemoval {
                staged,
                trash_root,
                _store_guard,
            };
            let _ = removal.rollback();
            return Err(error.into());
        }
        staged.push(StagedPetAsset {
            original,
            staged: staged_path,
        });
    }

    Ok(StagedPetAssetRemoval {
        staged,
        trash_root,
        _store_guard,
    })
}

pub fn ensure_runtime_frames(paths: &AppPaths, pet: &PetSummary) -> Result<()> {
    let frames_dir = runtime_frames_dir_for_pet(paths, pet)?;
    if validate_runtime_frames_for_pet(&frames_dir, pet).is_ok() {
        return Ok(());
    }

    let _store_guard = PetStoreGuard::acquire(paths)?;
    if validate_runtime_frames_for_pet(&frames_dir, pet).is_ok() {
        return Ok(());
    }
    let petpack_path = Path::new(&pet.petpack_path);
    let validation = validate_petpack_path(petpack_path)?;
    install_runtime_frames(
        paths,
        petpack_path,
        petpack_path,
        &frames_dir,
        &validation.manifest,
    )?;
    Ok(())
}

pub fn ensure_runtime_assets(
    paths: &AppPaths,
    database: &Database,
    pet: &PetSummary,
) -> Result<PetSummary> {
    let frames_dir = runtime_frames_dir_for_pet(paths, pet)?;
    let frames_missing = validate_runtime_frames_for_pet(&frames_dir, pet).is_err();
    let cover_missing = !cover_path_is_readable(pet);
    let metadata_missing = pet.generator.is_none() || pet.provenance.is_none();
    if !frames_missing && !cover_missing && !metadata_missing {
        return Ok(pet.clone());
    }

    let _store_guard = PetStoreGuard::acquire(paths)?;
    let mut repaired = pet.clone();
    let petpack_path = Path::new(&pet.petpack_path);
    let mut metadata_changed = false;
    if metadata_missing {
        let (generator, provenance) = read_petpack_generation_metadata(petpack_path, petpack_path);
        if repaired.generator.is_none() && generator.is_some() {
            repaired.generator = generator;
            metadata_changed = true;
        }
        if repaired.provenance.is_none() && provenance.is_some() {
            repaired.provenance = provenance;
            metadata_changed = true;
        }
    }

    if cover_missing {
        let cover_path = cover_path_for_pet(paths, pet)?;
        install_cover_image(paths, petpack_path, petpack_path, &cover_path)?;
        repaired.cover_path = cover_path.display().to_string();
    }

    if frames_missing {
        let validation = validate_petpack_path(petpack_path)?;
        install_runtime_frames(
            paths,
            petpack_path,
            petpack_path,
            &frames_dir,
            &validation.manifest,
        )?;
    }

    if cover_missing || metadata_changed {
        database.upsert_pet(&repaired)?;
    }

    Ok(repaired)
}

pub fn ensure_runtime_assets_cached(
    paths: &AppPaths,
    database: &Database,
    pet: &PetSummary,
) -> Result<PetAssetValidationOutcome> {
    let fingerprint = pet_asset_fingerprint(paths, pet);
    if let Some(cached) = database.pet_asset_validation(&pet.id)? {
        if cached.fingerprint == fingerprint {
            return Ok(PetAssetValidationOutcome {
                pet: pet.clone(),
                warning: if cached.valid {
                    None
                } else {
                    Some(PetAssetWarning {
                        pet_id: pet.id.clone(),
                        code: "pet_assets_invalid".to_string(),
                        fingerprint,
                        message: cached
                            .error
                            .unwrap_or_else(|| "pet assets failed validation".to_string()),
                    })
                },
            });
        }
    }

    match ensure_runtime_assets(paths, database, pet) {
        Ok(repaired) => {
            let repaired_fingerprint = pet_asset_fingerprint(paths, &repaired);
            database.set_pet_asset_validation(&pet.id, &repaired_fingerprint, true, None)?;
            Ok(PetAssetValidationOutcome {
                pet: repaired,
                warning: None,
            })
        }
        Err(error) => {
            let message = bounded_asset_error(&error.to_string());
            database.set_pet_asset_validation(&pet.id, &fingerprint, false, Some(&message))?;
            Ok(PetAssetValidationOutcome {
                pet: pet.clone(),
                warning: Some(PetAssetWarning {
                    pet_id: pet.id.clone(),
                    code: "pet_assets_invalid".to_string(),
                    fingerprint,
                    message,
                }),
            })
        }
    }
}

fn pet_asset_fingerprint(paths: &AppPaths, pet: &PetSummary) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"apc.pet-assets.fingerprint.v2\0");
    hasher.update(pet.native_fps.to_le_bytes());
    for state in REQUIRED_STATES {
        hasher.update(state.as_str().as_bytes());
        hasher.update(b"\0");
        hasher.update(
            pet.state_durations_ms
                .get(&state)
                .copied()
                .unwrap_or_default()
                .to_le_bytes(),
        );
    }
    let petpack = Path::new(&pet.petpack_path);
    let cover = if Path::new(&pet.cover_path).is_absolute() {
        PathBuf::from(&pet.cover_path)
    } else {
        petpack
            .parent()
            .unwrap_or(&paths.pets_dir)
            .join(&pet.cover_path)
    };
    let frames = petpack
        .parent()
        .unwrap_or(&paths.pets_dir)
        .join(format!("{}-frames", pet.id));
    for (label, path) in [
        ("petpack", petpack.to_path_buf()),
        ("cover", cover),
        ("frames", frames.clone()),
        ("marker", frames.join(RUNTIME_ASSETS_MARKER)),
    ] {
        hash_path_metadata(&mut hasher, label, &path);
    }
    for state in REQUIRED_STATES {
        hash_path_metadata(&mut hasher, state.as_str(), &frames.join(state.as_str()));
    }
    hex::encode(hasher.finalize())
}

fn hash_path_metadata(hasher: &mut Sha256, label: &str, path: &Path) {
    hasher.update(label.as_bytes());
    hasher.update(b"\0");
    hasher.update(path.as_os_str().as_encoded_bytes());
    hasher.update(b"\0");
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            hasher.update(if metadata.is_file() {
                b"file".as_slice()
            } else if metadata.is_dir() {
                b"dir".as_slice()
            } else if metadata.file_type().is_symlink() {
                b"symlink".as_slice()
            } else {
                b"other".as_slice()
            });
            hasher.update(metadata.len().to_le_bytes());
            let modified = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok());
            hasher.update(
                modified
                    .map(|duration| duration.as_nanos())
                    .unwrap_or_default()
                    .to_le_bytes(),
            );
        }
        Err(error) => {
            hasher.update(b"missing");
            hasher.update(format!("{:?}", error.kind()).as_bytes());
        }
    }
    hasher.update(b"\0");
}

fn bounded_asset_error(message: &str) -> String {
    const LIMIT: usize = 512;
    if message.len() <= LIMIT {
        return message.to_string();
    }
    let mut end = LIMIT - '…'.len_utf8();
    while !message.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &message[..end])
}

fn read_petpack_generation_metadata(
    source_path: &Path,
    target_petpack_path: &Path,
) -> (Option<String>, Option<String>) {
    let mut generator = None;
    let mut provenance = None;
    for (relative_path, nested) in [("source/source.json", false), ("brief.json", true)] {
        let Some(value) = read_package_json(source_path, target_petpack_path, relative_path) else {
            continue;
        };
        let (candidate_generator, candidate_provenance) = if nested {
            value
                .get("generation")
                .map(|generation| {
                    (
                        metadata_text(generation.get("generator")),
                        metadata_text(generation.get("provenance")),
                    )
                })
                .unwrap_or((None, None))
        } else {
            (
                metadata_text(value.get("generator")),
                metadata_text(value.get("provenance")),
            )
        };
        if generator.is_none() {
            generator = candidate_generator;
        }
        if provenance.is_none() {
            provenance = candidate_provenance;
        }
        if generator.is_some() && provenance.is_some() {
            break;
        }
    }
    (generator, provenance)
}

fn read_package_json(
    source_path: &Path,
    target_petpack_path: &Path,
    relative_path: &str,
) -> Option<serde_json::Value> {
    if source_path.is_dir() {
        let path = source_path.join(relative_path);
        if path.is_file() {
            return serde_json::from_slice(&fs::read(path).ok()?).ok();
        }
    }

    let file = File::open(target_petpack_path).ok()?;
    let mut archive = zip::ZipArchive::new(file).ok()?;
    let mut entry = archive.by_name(relative_path).ok()?;
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn metadata_text(value: Option<&serde_json::Value>) -> Option<String> {
    let raw = value?.as_str()?;
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut cleaned = collapsed
        .chars()
        .filter(|character| !character.is_control())
        .take(96)
        .collect::<String>();
    cleaned = cleaned.trim().to_string();
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned)
    }
}

fn cover_path_is_readable(pet: &PetSummary) -> bool {
    if pet.cover_path.is_empty() {
        return false;
    }

    let cover_path = Path::new(&pet.cover_path);
    if cover_path.is_file() && validate_cover_file(cover_path).is_ok() {
        return true;
    }

    if !cover_path.is_absolute() {
        if let Some(parent) = Path::new(&pet.petpack_path).parent() {
            let absolute_cover = parent.join(cover_path);
            return absolute_cover.is_file() && validate_cover_file(&absolute_cover).is_ok();
        }
    }

    false
}

fn remove_owned_pet_file(paths: &AppPaths, path: &Path) -> Result<()> {
    if let Some(file) = owned_pet_asset_path(paths, path, AssetKind::File)? {
        fs::remove_file(file)?;
    }
    Ok(())
}

fn remove_owned_pet_dir(paths: &AppPaths, path: &Path) -> Result<()> {
    if let Some(dir) = owned_pet_asset_path(paths, path, AssetKind::Dir)? {
        fs::remove_dir_all(dir)?;
    }
    Ok(())
}

fn owned_pet_asset_path(paths: &AppPaths, path: &Path, kind: AssetKind) -> Result<Option<PathBuf>> {
    if !path_exists(path) {
        return Ok(None);
    }

    let pets_dir = fs::canonicalize(&paths.pets_dir)?;
    let asset = fs::canonicalize(path)?;
    if !asset.starts_with(&pets_dir) {
        return Ok(None);
    }

    match kind {
        AssetKind::File if asset.is_file() => Ok(Some(asset)),
        AssetKind::Dir if asset.is_dir() => Ok(Some(asset)),
        AssetKind::File => Err(PetCoreError::Validation(format!(
            "owned pet asset {} is not a file",
            asset.display()
        ))),
        AssetKind::Dir => Err(PetCoreError::Validation(format!(
            "owned pet asset {} is not a directory",
            asset.display()
        ))),
    }
}

fn runtime_frames_dir_for_pet(paths: &AppPaths, pet: &PetSummary) -> Result<PathBuf> {
    let parent = owned_petpack_parent(paths, pet)?;
    Ok(parent.join(format!("{}-frames", pet.id)))
}

fn cover_path_for_pet(paths: &AppPaths, pet: &PetSummary) -> Result<PathBuf> {
    let parent = owned_petpack_parent(paths, pet)?;
    Ok(parent.join(format!("{}-cover.png", pet.id)))
}

fn owned_petpack_parent(paths: &AppPaths, pet: &PetSummary) -> Result<PathBuf> {
    validate_pet_id(&pet.id)?;
    let parent = Path::new(&pet.petpack_path).parent().ok_or_else(|| {
        PetCoreError::Validation("petpack path has no parent directory".to_string())
    })?;
    let canonical_pets = fs::canonicalize(&paths.pets_dir)?;
    let canonical_parent = fs::canonicalize(parent)?;
    if !canonical_parent.starts_with(&canonical_pets) {
        return Err(PetCoreError::Validation(format!(
            "petpack parent {} is outside the owned pet store",
            canonical_parent.display()
        )));
    }
    Ok(canonical_parent)
}

#[derive(Debug, Clone, Copy)]
enum AssetKind {
    File,
    Dir,
}

#[derive(Debug, Clone)]
struct AssetReplacement {
    source: PathBuf,
    target: PathBuf,
    backup: PathBuf,
    kind: AssetKind,
}

impl AssetReplacement {
    fn file(source: PathBuf, target: PathBuf, backup: PathBuf) -> Self {
        Self {
            source,
            target,
            backup,
            kind: AssetKind::File,
        }
    }

    fn dir(source: PathBuf, target: PathBuf, backup: PathBuf) -> Self {
        Self {
            source,
            target,
            backup,
            kind: AssetKind::Dir,
        }
    }
}

fn commit_asset_replacements(replacements: &[AssetReplacement]) -> Result<()> {
    let mut backed_up = Vec::new();
    let mut installed = Vec::new();

    for replacement in replacements {
        if let Some(parent) = replacement.target.parent() {
            fs::create_dir_all(parent)?;
        }
        if let Some(parent) = replacement.backup.parent() {
            fs::create_dir_all(parent)?;
        }
        if path_exists(&replacement.target) {
            if path_exists(&replacement.backup) {
                remove_path(&replacement.backup)?;
            }
            if let Err(error) = fs::rename(&replacement.target, &replacement.backup) {
                rollback_asset_replacements(&installed, &backed_up);
                return Err(error.into());
            }
            backed_up.push(replacement.clone());
        }
    }

    for replacement in replacements {
        if let Err(error) = validate_replacement_source(replacement) {
            rollback_asset_replacements(&installed, &backed_up);
            return Err(error);
        }
        if let Err(error) = fs::rename(&replacement.source, &replacement.target) {
            rollback_asset_replacements(&installed, &backed_up);
            return Err(error.into());
        }
        installed.push(replacement.clone());
    }

    for replacement in backed_up {
        if path_exists(&replacement.backup) {
            remove_path(&replacement.backup)?;
        }
    }
    Ok(())
}

fn validate_replacement_source(replacement: &AssetReplacement) -> Result<()> {
    match replacement.kind {
        AssetKind::File if replacement.source.is_file() => Ok(()),
        AssetKind::Dir if replacement.source.is_dir() => Ok(()),
        AssetKind::File => Err(PetCoreError::Validation(format!(
            "staged asset {} is not a file",
            replacement.source.display()
        ))),
        AssetKind::Dir => Err(PetCoreError::Validation(format!(
            "staged asset {} is not a directory",
            replacement.source.display()
        ))),
    }
}

fn rollback_asset_replacements(installed: &[AssetReplacement], backed_up: &[AssetReplacement]) {
    for replacement in installed.iter().rev() {
        if path_exists(&replacement.target) {
            let _ = remove_path(&replacement.target);
        }
    }
    for replacement in backed_up.iter().rev() {
        if path_exists(&replacement.backup) {
            let _ = fs::rename(&replacement.backup, &replacement.target);
        }
    }
}

fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn remove_path(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => Ok(fs::remove_dir_all(path)?),
        Ok(_) => Ok(fs::remove_file(path)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn install_runtime_frames(
    paths: &AppPaths,
    source_path: &Path,
    target_petpack_path: &Path,
    output_dir: &Path,
    manifest: &PetManifest,
) -> Result<PathBuf> {
    let stage = tempfile::Builder::new()
        .prefix(".apc-runtime-frames-")
        .tempdir_in(output_dir.parent().unwrap_or(&paths.pets_dir))?;
    let staged_frames = stage.path().join("frames");
    prepare_runtime_frames_to_dir(source_path, target_petpack_path, &staged_frames, manifest)?;
    commit_asset_replacements(&[AssetReplacement::dir(
        staged_frames,
        output_dir.to_path_buf(),
        stage.path().join("previous-frames"),
    )])?;
    validate_runtime_frames_for_manifest(output_dir, manifest)?;
    Ok(output_dir.to_path_buf())
}

fn prepare_runtime_frames_to_dir(
    source_path: &Path,
    target_petpack_path: &Path,
    output_dir: &Path,
    manifest: &PetManifest,
) -> Result<()> {
    if path_exists(output_dir) {
        remove_path(output_dir)?;
    }
    if source_path.is_dir() {
        copy_runtime_frames_from_dir(source_path, output_dir, manifest)?;
    } else {
        extract_runtime_frames_from_zip(target_petpack_path, output_dir, manifest)?;
    }
    let state_counts = collect_runtime_frame_counts(output_dir, Some(manifest.render_size), None)?;
    write_runtime_assets_marker(output_dir, manifest, &state_counts)?;
    validate_runtime_frames_for_manifest(output_dir, manifest)
}

fn copy_runtime_frames_from_dir(
    source_path: &Path,
    output_dir: &Path,
    manifest: &PetManifest,
) -> Result<()> {
    for required in REQUIRED_STATES {
        let state = manifest
            .states
            .iter()
            .find(|entry| entry.name == required)
            .ok_or_else(|| {
                PetCoreError::Validation(format!("manifest missing state {}", required.as_str()))
            })?;
        let source_dir = source_path.join(&state.frames_dir);
        let output_state_dir = output_dir.join(required.as_str());
        fs::create_dir_all(&output_state_dir)?;
        for entry in fs::read_dir(source_dir)? {
            let path = entry?.path();
            if path.is_file() && is_png(&path) {
                let file_name = path.file_name().ok_or_else(|| {
                    PetCoreError::Validation("frame file has no file name".to_string())
                })?;
                fs::copy(&path, output_state_dir.join(file_name))?;
            }
        }
    }
    Ok(())
}

fn extract_runtime_frames_from_zip(
    target_petpack_path: &Path,
    output_dir: &Path,
    manifest: &PetManifest,
) -> Result<()> {
    let file = File::open(target_petpack_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    let state_prefixes = REQUIRED_STATES
        .iter()
        .map(|required| {
            let state = manifest
                .states
                .iter()
                .find(|entry| entry.name == *required)
                .ok_or_else(|| {
                    PetCoreError::Validation(format!(
                        "manifest missing state {}",
                        required.as_str()
                    ))
                })?;
            let mut prefix = state.frames_dir.replace('\\', "/");
            if !prefix.ends_with('/') {
                prefix.push('/');
            }
            Ok((*required, prefix))
        })
        .collect::<Result<Vec<_>>>()?;

    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        if entry.is_dir() {
            continue;
        }
        let entry_name = entry.name().replace('\\', "/");
        if !entry_name.to_ascii_lowercase().ends_with(".png") {
            continue;
        }

        let Some((state, _prefix)) = state_prefixes
            .iter()
            .find(|(_, prefix)| entry_name.starts_with(prefix))
        else {
            continue;
        };
        let file_name = Path::new(&entry_name)
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| PetCoreError::Validation("frame file has no file name".to_string()))?;
        if file_name.contains('/')
            || file_name.contains('\\')
            || file_name == "."
            || file_name == ".."
        {
            return Err(PetCoreError::Validation(
                "petpack contains unsafe frame file name".to_string(),
            ));
        }

        let output_state_dir = output_dir.join(state.as_str());
        fs::create_dir_all(&output_state_dir)?;
        let mut output = File::create(output_state_dir.join(file_name))?;
        std::io::copy(&mut entry, &mut output)?;
    }
    Ok(())
}

fn validate_runtime_frames_for_pet(output_dir: &Path, pet: &PetSummary) -> Result<()> {
    let marker = read_runtime_assets_marker(output_dir, None)?;
    if marker.pet_id != pet.id
        || marker.render_size != pet.render_size
        || marker.native_fps != pet.native_fps
        || marker.state_durations_ms != pet.state_durations_ms
    {
        return Err(PetCoreError::Validation(
            "runtime frames marker does not match pet summary".to_string(),
        ));
    }
    collect_runtime_frame_counts(output_dir, Some(marker.render_size), Some(&marker.states))?;
    Ok(())
}

fn validate_runtime_frames_for_manifest(output_dir: &Path, manifest: &PetManifest) -> Result<()> {
    let marker = read_runtime_assets_marker(output_dir, Some(manifest))?;
    collect_runtime_frame_counts(output_dir, Some(marker.render_size), Some(&marker.states))?;
    Ok(())
}

#[derive(Debug, serde::Deserialize)]
struct RuntimeAssetsMarker {
    schema_version: String,
    pet_id: String,
    render_size: RenderSize,
    native_fps: u32,
    state_durations_ms: BTreeMap<PetStateName, u32>,
    states: BTreeMap<String, usize>,
}

fn read_runtime_assets_marker(
    output_dir: &Path,
    manifest: Option<&PetManifest>,
) -> Result<RuntimeAssetsMarker> {
    let marker_path = output_dir.join(RUNTIME_ASSETS_MARKER);
    if !marker_path.is_file() {
        return Err(PetCoreError::Validation(
            "runtime frames missing completion marker".to_string(),
        ));
    }
    let marker: RuntimeAssetsMarker = serde_json::from_slice(&fs::read(&marker_path)?)?;
    if marker.schema_version != RUNTIME_ASSETS_SCHEMA_VERSION {
        return Err(PetCoreError::Validation(
            "runtime frames marker has unsupported schema".to_string(),
        ));
    }
    if let Some(manifest) = manifest {
        if marker.pet_id != manifest.id
            || marker.render_size != manifest.render_size
            || marker.native_fps != manifest.native_fps
            || marker.state_durations_ms != manifest_state_durations_ms(manifest)
        {
            return Err(PetCoreError::Validation(
                "runtime frames marker does not match petpack manifest".to_string(),
            ));
        }
    }
    Ok(marker)
}

fn write_runtime_assets_marker(
    output_dir: &Path,
    manifest: &PetManifest,
    state_counts: &BTreeMap<String, usize>,
) -> Result<()> {
    fs::write(
        output_dir.join(RUNTIME_ASSETS_MARKER),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": RUNTIME_ASSETS_SCHEMA_VERSION,
            "pet_id": manifest.id,
            "render_size": manifest.render_size,
            "native_fps": manifest.native_fps,
            "state_durations_ms": manifest_state_durations_ms(manifest),
            "states": state_counts,
            "created_at": now_rfc3339()
        }))?,
    )?;
    Ok(())
}

fn collect_runtime_frame_counts(
    output_dir: &Path,
    render_size: Option<RenderSize>,
    expected_counts: Option<&BTreeMap<String, usize>>,
) -> Result<BTreeMap<String, usize>> {
    let mut counts = BTreeMap::new();
    for state in REQUIRED_STATES {
        let state_dir = output_dir.join(state.as_str());
        if !state_dir.is_dir() {
            return Err(PetCoreError::Validation(format!(
                "runtime frames missing state {}",
                state.as_str()
            )));
        }
        let mut png_count = 0usize;
        for entry in fs::read_dir(&state_dir)? {
            let path = entry?.path();
            if is_png(&path) {
                if let Some(render_size) = render_size {
                    let (width, height) = image::image_dimensions(&path).map_err(|error| {
                        PetCoreError::Validation(format!(
                            "invalid runtime frame {}: {error}",
                            path.display()
                        ))
                    })?;
                    if width != render_size.width || height != render_size.height {
                        return Err(PetCoreError::Validation(format!(
                            "runtime frame {} is {}x{}, expected {}x{}",
                            path.display(),
                            width,
                            height,
                            render_size.width,
                            render_size.height
                        )));
                    }
                }
                png_count += 1;
            }
        }
        if png_count == 0 {
            return Err(PetCoreError::Validation(format!(
                "runtime state {} has no PNG frames",
                state.as_str()
            )));
        }
        if let Some(expected_counts) = expected_counts {
            let expected_count = expected_counts.get(state.as_str()).copied().unwrap_or(0);
            if expected_count != png_count {
                return Err(PetCoreError::Validation(format!(
                    "runtime state {} has {} PNG frames, expected {}",
                    state.as_str(),
                    png_count,
                    expected_count
                )));
            }
        }
        counts.insert(state.as_str().to_string(), png_count);
    }
    Ok(counts)
}

fn install_cover_image(
    paths: &AppPaths,
    source_path: &Path,
    target_petpack_path: &Path,
    output_path: &Path,
) -> Result<PathBuf> {
    let stage = tempfile::Builder::new()
        .prefix(".apc-cover-")
        .tempdir_in(output_path.parent().unwrap_or(&paths.pets_dir))?;
    let staged_cover = stage.path().join("cover.png");
    write_cover_image(source_path, target_petpack_path, &staged_cover)?;
    commit_asset_replacements(&[AssetReplacement::file(
        staged_cover,
        output_path.to_path_buf(),
        stage.path().join("previous-cover.png"),
    )])?;
    validate_cover_file(output_path)?;
    Ok(output_path.to_path_buf())
}

fn write_cover_image(
    source_path: &Path,
    target_petpack_path: &Path,
    output_path: &Path,
) -> Result<()> {
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if source_path.is_dir() {
        let source_cover = source_path.join("assets/preview/cover.png");
        if source_cover.is_file() {
            fs::copy(source_cover, output_path)?;
            return validate_cover_file(output_path);
        }
    }

    let file = File::open(target_petpack_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    let mut cover = archive.by_name("assets/preview/cover.png")?;
    let mut output = File::create(output_path)?;
    std::io::copy(&mut cover, &mut output)?;
    validate_cover_file(output_path)
}

fn validate_cover_file(path: &Path) -> Result<()> {
    let (width, height) = image::image_dimensions(path)
        .map_err(|error| PetCoreError::Validation(format!("invalid cover image: {error}")))?;
    validate_pixel_budget(width, height, "cover image")?;
    let decoded = image::open(path)
        .map_err(|error| PetCoreError::Validation(format!("invalid cover image: {error}")))?;
    validate_visible_cover(&decoded.to_rgba8(), "cover image")
}

fn is_png(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case("png"))
        .unwrap_or(false)
}

pub(crate) fn natural_frame_path_cmp(left: &Path, right: &Path) -> std::cmp::Ordering {
    let left_name = left
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let right_name = right
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let left_bytes = left_name.as_bytes();
    let right_bytes = right_name.as_bytes();
    let (mut left_index, mut right_index) = (0usize, 0usize);
    while left_index < left_bytes.len() && right_index < right_bytes.len() {
        if left_bytes[left_index].is_ascii_digit() && right_bytes[right_index].is_ascii_digit() {
            let left_end = left_bytes[left_index..]
                .iter()
                .position(|byte| !byte.is_ascii_digit())
                .map(|offset| left_index + offset)
                .unwrap_or(left_bytes.len());
            let right_end = right_bytes[right_index..]
                .iter()
                .position(|byte| !byte.is_ascii_digit())
                .map(|offset| right_index + offset)
                .unwrap_or(right_bytes.len());
            let left_significant = left_bytes[left_index..left_end]
                .iter()
                .position(|byte| *byte != b'0')
                .map(|offset| left_index + offset)
                .unwrap_or(left_end.saturating_sub(1));
            let right_significant = right_bytes[right_index..right_end]
                .iter()
                .position(|byte| *byte != b'0')
                .map(|offset| right_index + offset)
                .unwrap_or(right_end.saturating_sub(1));
            let ordering = (left_end - left_significant)
                .cmp(&(right_end - right_significant))
                .then_with(|| {
                    left_bytes[left_significant..left_end]
                        .cmp(&right_bytes[right_significant..right_end])
                })
                .then_with(|| (left_end - left_index).cmp(&(right_end - right_index)));
            if ordering != std::cmp::Ordering::Equal {
                return ordering;
            }
            left_index = left_end;
            right_index = right_end;
            continue;
        }
        let ordering = left_bytes[left_index]
            .to_ascii_lowercase()
            .cmp(&right_bytes[right_index].to_ascii_lowercase())
            .then_with(|| left_bytes[left_index].cmp(&right_bytes[right_index]));
        if ordering != std::cmp::Ordering::Equal {
            return ordering;
        }
        left_index += 1;
        right_index += 1;
    }
    left_bytes.len().cmp(&right_bytes.len())
}

fn draw_sample_frame(
    size: RenderSize,
    state: PetStateName,
    frame_index: usize,
) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
    let mut image = ImageBuffer::from_pixel(size.width, size.height, Rgba([0, 0, 0, 0]));
    let center_x = size.width as i32 / 2;
    let center_y = size.height as i32 / 2;
    let body_w = (size.width as f32 * 0.34) as i32;
    let body_h = (size.height as f32 * 0.52) as i32;
    let bob = if frame_index & 1 == 0 {
        0
    } else {
        -(size.height as i32 / 80).max(1)
    };
    let accent = state_color(state);

    fill_ellipse(
        &mut image,
        center_x,
        center_y + body_h / 2 + bob,
        body_w,
        body_h / 7,
        Rgba([126, 132, 160, 55]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y + bob,
        body_w,
        body_h,
        Rgba([246, 240, 255, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y - body_h / 3 + bob,
        body_w / 2,
        body_w / 2,
        Rgba([255, 219, 188, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y - body_h / 3 + bob,
        body_w / 2 + body_w / 5,
        body_w / 2 + body_w / 3,
        Rgba([54, 50, 151, 245]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y - body_h / 3 + body_w / 9 + bob,
        body_w / 2,
        body_w / 3,
        Rgba([255, 219, 188, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x - body_w / 9,
        center_y - body_h / 3 + bob,
        body_w / 26,
        body_w / 26,
        Rgba([24, 32, 48, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x + body_w / 9,
        center_y - body_h / 3 + bob,
        body_w / 26,
        body_w / 26,
        Rgba([24, 32, 48, 255]),
    );
    fill_rect(
        &mut image,
        center_x - body_w / 3,
        center_y + body_h / 12 + bob,
        body_w * 2 / 3,
        body_h / 5,
        accent,
    );
    image
}

fn draw_generated_frame(
    size: RenderSize,
    state: PetStateName,
    frame_index: usize,
    frame_count: usize,
    palette: &Palette,
) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
    let mut image = ImageBuffer::from_pixel(size.width, size.height, Rgba([0, 0, 0, 0]));
    let center_x = size.width as i32 / 2;
    let center_y = size.height as i32 / 2;
    let body_w = (size.width as f32 * 0.34) as i32;
    let body_h = (size.height as f32 * 0.52) as i32;
    let phase = frame_phase(frame_index, frame_count);
    let breath = (phase * std::f32::consts::TAU).sin();
    let secondary = (phase * std::f32::consts::TAU * 2.0).sin();
    let bob = (breath * (size.height as f32 / 96.0).max(1.0)).round() as i32;
    let sway = (secondary * (size.width as f32 / 180.0).max(1.0)).round() as i32;
    let state_accent = blend_rgba(palette.accent, state_color(state), 0.42);

    fill_ellipse(
        &mut image,
        center_x + sway / 2,
        center_y + body_h / 2 + bob,
        body_w,
        body_h / 7,
        Rgba([72, 84, 112, 58]),
    );
    fill_ellipse(
        &mut image,
        center_x + sway / 3,
        center_y + bob,
        body_w,
        body_h,
        palette.body,
    );
    fill_ellipse(
        &mut image,
        center_x + sway,
        center_y - body_h / 3 + bob,
        body_w / 2,
        body_w / 2,
        palette.skin,
    );
    fill_ellipse(
        &mut image,
        center_x + sway,
        center_y - body_h / 3 + bob,
        body_w / 2 + body_w / 5,
        body_w / 2 + body_w / 3,
        palette.hair,
    );
    fill_ellipse(
        &mut image,
        center_x + sway,
        center_y - body_h / 3 + body_w / 9 + bob,
        body_w / 2,
        body_w / 3,
        palette.skin,
    );
    fill_ellipse(
        &mut image,
        center_x - body_w / 9 + sway,
        center_y - body_h / 3 + bob,
        body_w / 26,
        body_w / 26,
        Rgba([22, 28, 42, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x + body_w / 9 + sway,
        center_y - body_h / 3 + bob,
        body_w / 26,
        body_w / 26,
        Rgba([22, 28, 42, 255]),
    );
    fill_rect(
        &mut image,
        center_x - body_w / 3 + sway / 2,
        center_y + body_h / 12 + bob,
        body_w * 2 / 3,
        body_h / 5,
        state_accent,
    );

    let glow_radius = (body_w / 7).max(3);
    let pulse_alpha = (118.0 + 42.0 * breath.abs()).round() as u8;
    let drift = (breath * (body_w as f32 / 10.0).max(1.0)).round() as i32;
    match state {
        PetStateName::Start | PetStateName::Tool | PetStateName::Review => fill_ellipse(
            &mut image,
            center_x + body_w / 2 + drift,
            center_y - body_h / 5 + bob,
            glow_radius,
            glow_radius,
            Rgba([
                state_accent.0[0],
                state_accent.0[1],
                state_accent.0[2],
                pulse_alpha,
            ]),
        ),
        PetStateName::Waiting => fill_rect(
            &mut image,
            center_x - glow_radius / 2,
            center_y - body_h / 2 + bob + drift / 2,
            glow_radius,
            glow_radius * 2,
            Rgba([
                state_accent.0[0],
                state_accent.0[1],
                state_accent.0[2],
                pulse_alpha,
            ]),
        ),
        PetStateName::Done => fill_ellipse(
            &mut image,
            center_x,
            center_y + body_h / 3 + bob,
            glow_radius * 2,
            glow_radius / 2,
            Rgba([
                state_accent.0[0],
                state_accent.0[1],
                state_accent.0[2],
                pulse_alpha,
            ]),
        ),
        PetStateName::Failed => fill_rect(
            &mut image,
            center_x - body_w / 2,
            center_y + body_h / 4 + bob,
            body_w,
            glow_radius,
            Rgba([
                state_accent.0[0],
                state_accent.0[1],
                state_accent.0[2],
                pulse_alpha,
            ]),
        ),
        PetStateName::Idle => {}
    }
    image
}

fn materialize_reference_inputs(
    dir: &Path,
    references: &[String],
    render_size: RenderSize,
) -> Result<(Vec<String>, Option<RgbaImage>)> {
    materialize_reference_inputs_with_hook(dir, references, render_size, || Ok(()))
}

fn materialize_reference_inputs_with_hook<AfterSnapshot>(
    dir: &Path,
    references: &[String],
    render_size: RenderSize,
    after_snapshot: AfterSnapshot,
) -> Result<(Vec<String>, Option<RgbaImage>)>
where
    AfterSnapshot: FnOnce() -> Result<()>,
{
    // The job directory is writable by the App Server. Resolve every staged
    // path once through the reference module's O_NOFOLLOW reader, then stop
    // consulting those paths. Package copies and rendered pixels both derive
    // from this same immutable, metadata-bound byte snapshot.
    let snapshots = load_reference_snapshots(references)?;
    after_snapshot()?;
    let copied = copy_reference_images(dir, &snapshots)?;
    let frame_source = reference_frame_source(&snapshots, render_size)?;
    Ok((copied, frame_source))
}

fn reference_frame_source(
    references: &[ValidatedReferenceSnapshot],
    render_size: RenderSize,
) -> Result<Option<RgbaImage>> {
    references
        .first()
        .map(|reference| {
            reference
                .decode_verified_rgba(0)
                .map(|image| fit_reference_image(image, render_size))
        })
        .transpose()
}

fn fit_reference_image(source: RgbaImage, size: RenderSize) -> RgbaImage {
    let source_width = source.width().max(1);
    let source_height = source.height().max(1);
    let scale = f32::min(
        size.width as f32 / source_width as f32,
        size.height as f32 / source_height as f32,
    );
    let fitted_width = ((source_width as f32 * scale).round() as u32).clamp(1, size.width);
    let fitted_height = ((source_height as f32 * scale).round() as u32).clamp(1, size.height);
    let fitted = imageops::resize(
        &source,
        fitted_width,
        fitted_height,
        imageops::FilterType::Lanczos3,
    );
    let mut canvas = ImageBuffer::from_pixel(size.width, size.height, Rgba([0, 0, 0, 0]));
    let x = (size.width - fitted_width) / 2;
    let y = size.height.saturating_sub(fitted_height);
    imageops::overlay(&mut canvas, &fitted, i64::from(x), i64::from(y));
    canvas
}

fn draw_reference_frame(
    source: &RgbaImage,
    size: RenderSize,
    state: PetStateName,
    frame_index: usize,
    frame_count: usize,
) -> RgbaImage {
    let mut image = ImageBuffer::from_pixel(size.width, size.height, Rgba([0, 0, 0, 0]));
    let phase = frame_phase(frame_index, frame_count);
    let breath = (phase * std::f32::consts::TAU).sin();
    let bob = (breath * (size.height as f32 / 110.0).max(1.0)).round() as i64;
    let sway = match state {
        PetStateName::Tool | PetStateName::Review => {
            (breath * (size.width as f32 / 180.0).max(1.0)).round() as i64
        }
        PetStateName::Failed => -(i64::from(size.width) / 140).max(1),
        PetStateName::Start => (i64::from(size.width) / 160).max(1),
        PetStateName::Idle | PetStateName::Waiting | PetStateName::Done => 0,
    };
    imageops::overlay(&mut image, source, sway, bob);

    let accent = state_color(state);
    let pulse_alpha = (80.0 + 54.0 * breath.abs()).round() as u8;
    let glow_size = (size.width.min(size.height) / 12).max(8) as i32;
    let center_x = size.width as i32 / 2;
    let center_y = size.height as i32 / 2;
    match state {
        PetStateName::Start | PetStateName::Tool | PetStateName::Review => fill_ellipse(
            &mut image,
            center_x + (size.width as i32 / 4),
            center_y - (size.height as i32 / 5),
            glow_size,
            glow_size,
            Rgba([accent.0[0], accent.0[1], accent.0[2], pulse_alpha]),
        ),
        PetStateName::Waiting => fill_rect(
            &mut image,
            center_x - glow_size / 4,
            center_y - (size.height as i32 / 3),
            glow_size / 2,
            glow_size * 2,
            Rgba([accent.0[0], accent.0[1], accent.0[2], pulse_alpha]),
        ),
        PetStateName::Done => fill_ellipse(
            &mut image,
            center_x,
            center_y + (size.height as i32 / 4),
            glow_size * 2,
            glow_size / 2,
            Rgba([accent.0[0], accent.0[1], accent.0[2], pulse_alpha]),
        ),
        PetStateName::Failed => fill_rect(
            &mut image,
            center_x - glow_size,
            center_y + (size.height as i32 / 5),
            glow_size * 2,
            glow_size / 3,
            Rgba([accent.0[0], accent.0[1], accent.0[2], pulse_alpha]),
        ),
        PetStateName::Idle => {}
    }
    image
}

fn frame_phase(frame_index: usize, frame_count: usize) -> f32 {
    let cycle = frame_count.max(2) as f32;
    (frame_index as f32 % cycle) / cycle
}

fn timing_adjusted_frame_index(
    frame_index: usize,
    frame_count: usize,
    native_fps: u32,
    duration_ms: u32,
) -> usize {
    if frame_count == 0 {
        return frame_index;
    }
    let fps_offset = usize::from(native_fps == SMOOTH_FPS) * 2;
    let duration_offset = usize::from(duration_ms == LONG_ACTION_DURATION_MS);
    (frame_index + fps_offset + duration_offset) % frame_count
}

#[derive(Clone)]
struct Palette {
    hair: Rgba<u8>,
    skin: Rgba<u8>,
    body: Rgba<u8>,
    accent: Rgba<u8>,
    from_ai_brief: bool,
}

impl Palette {
    fn from_form(form: &GenerationForm) -> Self {
        let seed = stable_hash(&format!(
            "{}\n{}\n{:?}",
            form.description, form.style, form.quality
        ));
        let accent = Rgba([
            80 + ((seed >> 8) & 0x7f) as u8,
            90 + ((seed >> 16) & 0x7f) as u8,
            120 + ((seed >> 24) & 0x5f) as u8,
            255,
        ]);
        let hair = if contains_any(&form.description, &["白", "银", "雪"]) {
            Rgba([218, 226, 236, 248])
        } else if contains_any(&form.description, &["粉", "桃", "樱"]) {
            Rgba([104, 60, 82, 248])
        } else {
            Rgba([42, 38, 52, 248])
        };
        let body = if contains_any(&form.description, &["古风", "东方", "裙", "衣摆"]) {
            Rgba([255, 233, 228, 248])
        } else if contains_any(&form.style, &["像素", "pixel"]) {
            Rgba([232, 244, 255, 248])
        } else {
            Rgba([244, 240, 255, 248])
        };
        Self {
            hair,
            skin: Rgba([255, 218, 188, 255]),
            body,
            accent,
            from_ai_brief: false,
        }
    }

    fn from_form_and_brief(form: &GenerationForm, ai_brief: Option<&serde_json::Value>) -> Self {
        let mut palette = Self::from_form(form);
        let Some(brief) = ai_brief else {
            return palette;
        };

        let mut palette_text = Vec::new();
        if let Some(items) = brief.get("palette").and_then(serde_json::Value::as_array) {
            for item in items {
                match item {
                    serde_json::Value::String(text) => palette_text.push(text.clone()),
                    value => palette_text.push(value.to_string()),
                }
            }
        }
        if let Some(visual) = brief
            .get("visual_brief")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.trim().is_empty())
        {
            palette_text.push(visual.to_string());
        }

        if palette_text.is_empty() {
            return palette;
        }

        let joined = palette_text.join("\n");
        palette.accent = color_from_text(&format!("accent\n{joined}"), 255);
        palette.body = blend_rgba(
            palette.body,
            color_from_text(&format!("body\n{joined}"), 248),
            0.36,
        );
        palette.hair = blend_rgba(
            palette.hair,
            color_from_text(&format!("hair\n{joined}"), 248),
            0.44,
        );
        palette.from_ai_brief = true;
        palette
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::json!({
            "hair": self.hair.0,
            "skin": self.skin.0,
            "body": self.body.0,
            "accent": self.accent.0,
            "source": if self.from_ai_brief { "codex-ai-brief" } else { "form-derived" }
        })
    }
}

fn stable_hash(value: &str) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn blend_rgba(a: Rgba<u8>, b: Rgba<u8>, amount_b: f32) -> Rgba<u8> {
    let amount_a = 1.0 - amount_b;
    Rgba([
        (a.0[0] as f32 * amount_a + b.0[0] as f32 * amount_b) as u8,
        (a.0[1] as f32 * amount_a + b.0[1] as f32 * amount_b) as u8,
        (a.0[2] as f32 * amount_a + b.0[2] as f32 * amount_b) as u8,
        255,
    ])
}

fn color_from_text(value: &str, alpha: u8) -> Rgba<u8> {
    let hash = stable_hash(value);
    Rgba([
        72 + (hash & 0x8f) as u8,
        72 + ((hash >> 12) & 0x8f) as u8,
        84 + ((hash >> 24) & 0x7f) as u8,
        alpha,
    ])
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    let lower = haystack.to_lowercase();
    needles.iter().any(|needle| lower.contains(needle))
}

fn copy_reference_images(
    dir: &Path,
    references: &[ValidatedReferenceSnapshot],
) -> Result<Vec<String>> {
    let reference_dir = dir.join("source").join("references");
    fs::create_dir_all(&reference_dir).map_err(|_| reference_materialization_failed())?;
    let mut copied = Vec::with_capacity(references.len());
    for (index, reference) in references.iter().enumerate() {
        let target = reference_dir.join(format!("reference-{index:02}.{}", reference.extension()));
        reference.write_verified_copy(index, &target)?;
        copied.push(
            target
                .strip_prefix(dir)
                .unwrap_or(&target)
                .to_string_lossy()
                .replace('\\', "/"),
        );
    }
    Ok(copied)
}

fn reference_materialization_failed() -> PetCoreError {
    PetCoreError::InvalidRequest("参考图物化失败，请重新选择后重试".to_string())
}

fn form_with_package_references(
    form: &GenerationForm,
    reference_copies: &[String],
) -> GenerationForm {
    let mut source_form = form.clone();
    source_form.reference_images = reference_copies.to_vec();
    source_form
}

fn prompt_markdown(form: &GenerationForm, pet_name: &str) -> String {
    let durations = REQUIRED_STATES
        .iter()
        .map(|state| {
            format!(
                "- {}: {} ms",
                state.as_str(),
                form.state_durations_ms
                    .get(state)
                    .copied()
                    .unwrap_or_else(|| state.default_duration_ms())
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "# {pet_name}\n\n## 描述\n{}\n\n## 风格\n{}\n\n## 画质\n{}\n\n## 原生帧率\n{} FPS\n\n## 动作时长\n{}\n\n## 参考图\n{}\n",
        form.description.trim(),
        form.style,
        form.quality.zh_label(),
        form.native_fps,
        durations,
        if form.reference_images.is_empty() {
            "无".to_string()
        } else {
            form.reference_images.join("\n")
        }
    )
}

fn action_plan_for_form(
    form: &GenerationForm,
    ai_brief: Option<&serde_json::Value>,
) -> Vec<serde_json::Value> {
    REQUIRED_STATES
        .iter()
        .map(|state| {
            serde_json::json!({
                "state": state.as_str(),
                "label": state.zh_event_label(),
                "duration_ms": form
                    .state_durations_ms
                    .get(state)
                    .copied()
                    .unwrap_or_else(|| state.default_duration_ms()),
                "motion": ai_motion_for_state(*state, ai_brief)
                    .unwrap_or_else(|| motion_for_state(*state, form).to_string()),
            })
        })
        .collect()
}

fn ai_motion_for_state(
    state: PetStateName,
    ai_brief: Option<&serde_json::Value>,
) -> Option<String> {
    let states = ai_brief?.get("states")?.as_array()?;
    for item in states {
        let name = item
            .get("name")
            .or_else(|| item.get("state"))
            .and_then(serde_json::Value::as_str)?;
        if name == state.as_str() {
            return item
                .get("motion")
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
                .filter(|motion| !motion.trim().is_empty());
        }
    }
    None
}

fn motion_for_state(state: PetStateName, form: &GenerationForm) -> &'static str {
    match state {
        PetStateName::Idle => "轻微呼吸与衣摆摆动",
        PetStateName::Start => "抬头进入工作状态",
        PetStateName::Tool => {
            if contains_any(&form.description, &["发光", "光"]) {
                "衣摆和工具光效增强"
            } else {
                "手部与胸前色带显示工具执行节奏"
            }
        }
        PetStateName::Waiting => "停顿并向上提醒确认",
        PetStateName::Review => "侧身展示待查看状态",
        PetStateName::Done => "轻微点头并显示完成光效",
        PetStateName::Failed => "低头并显示失败提示色带",
    }
}

fn state_color(state: PetStateName) -> Rgba<u8> {
    match state {
        PetStateName::Idle => Rgba([96, 169, 232, 255]),
        PetStateName::Start => Rgba([129, 81, 247, 255]),
        PetStateName::Tool => Rgba([60, 189, 214, 255]),
        PetStateName::Waiting => Rgba([240, 176, 64, 255]),
        PetStateName::Review => Rgba([116, 113, 255, 255]),
        PetStateName::Done => Rgba([64, 196, 129, 255]),
        PetStateName::Failed => Rgba([232, 90, 110, 255]),
    }
}

fn fill_rect(
    image: &mut ImageBuffer<Rgba<u8>, Vec<u8>>,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    color: Rgba<u8>,
) {
    for px in x.max(0)..(x + width).min(image.width() as i32) {
        for py in y.max(0)..(y + height).min(image.height() as i32) {
            image.put_pixel(px as u32, py as u32, color);
        }
    }
}

fn fill_ellipse(
    image: &mut ImageBuffer<Rgba<u8>, Vec<u8>>,
    center_x: i32,
    center_y: i32,
    radius_x: i32,
    radius_y: i32,
    color: Rgba<u8>,
) {
    if radius_x <= 0 || radius_y <= 0 {
        return;
    }
    let min_x = (center_x - radius_x).max(0);
    let max_x = (center_x + radius_x).min(image.width() as i32 - 1);
    let min_y = (center_y - radius_y).max(0);
    let max_y = (center_y + radius_y).min(image.height() as i32 - 1);

    let rx2 = (radius_x * radius_x) as i64;
    let ry2 = (radius_y * radius_y) as i64;
    for x in min_x..=max_x {
        for y in min_y..=max_y {
            let dx = (x - center_x) as i64;
            let dy = (y - center_y) as i64;
            if dx * dx * ry2 + dy * dy * rx2 <= rx2 * ry2 {
                image.put_pixel(x as u32, y as u32, color);
            }
        }
    }
}

fn zip_dir<W: Write + Seek>(base: &Path, dir: &Path, zip: &mut zip::ZipWriter<W>) -> Result<()> {
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            return Err(PetCoreError::Validation(format!(
                "petpack source must not contain symlink {}",
                path.display()
            )));
        }
        let relative = path.strip_prefix(base).map_err(|error| {
            PetCoreError::Validation(format!("could not build zip relative path: {error}"))
        })?;
        let name = relative.to_string_lossy().replace('\\', "/");
        if metadata.is_dir() {
            if !name.is_empty() {
                zip.add_directory(format!("{name}/"), options)?;
            }
            zip_dir(base, &path, zip)?;
        } else if metadata.is_file() {
            zip.start_file(name, options)?;
            let mut file = File::open(&path)?;
            std::io::copy(&mut file, zip)?;
        } else {
            return Err(PetCoreError::Validation(format!(
                "petpack source contains unsupported file type {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn unzip_petpack(source_path: &Path, output_dir: &Path) -> Result<()> {
    let file = File::open(source_path)?;
    let archive_bytes = file.metadata()?.len();
    if archive_bytes > MAX_PETPACK_ARCHIVE_BYTES {
        return Err(PetCoreError::Validation(format!(
            "petpack archive exceeds the {} MiB limit",
            MAX_PETPACK_ARCHIVE_BYTES / (1024 * 1024)
        )));
    }
    let mut archive = zip::ZipArchive::new(file)?;
    if archive.len() > MAX_PETPACK_ENTRIES {
        return Err(PetCoreError::Validation(format!(
            "petpack has too many entries: {}",
            archive.len()
        )));
    }
    let mut total_uncompressed_bytes = 0u64;
    let mut normalized_entries = BTreeSet::new();
    for index in 0..archive.len() {
        let mut file = archive.by_index(index)?;
        if file.name().contains('\\') {
            return Err(PetCoreError::Validation(format!(
                "petpack entry {} must use canonical forward-slash paths",
                file.name()
            )));
        }
        let entry_size = file.size();
        if entry_size > MAX_PETPACK_ENTRY_BYTES {
            return Err(PetCoreError::Validation(format!(
                "petpack entry {} is too large",
                file.name()
            )));
        }
        total_uncompressed_bytes = total_uncompressed_bytes
            .checked_add(entry_size)
            .ok_or_else(|| {
                PetCoreError::Validation("petpack uncompressed size overflow".to_string())
            })?;
        if total_uncompressed_bytes > MAX_PETPACK_TOTAL_BYTES {
            return Err(PetCoreError::Validation(
                "petpack uncompressed size exceeds limit".to_string(),
            ));
        }
        let enclosed = file
            .enclosed_name()
            .ok_or_else(|| PetCoreError::Validation("petpack contains unsafe path".to_string()))?;
        let normalized = enclosed
            .to_string_lossy()
            .trim_end_matches('/')
            .to_ascii_lowercase();
        if !normalized_entries.insert(normalized) {
            return Err(PetCoreError::Validation(format!(
                "petpack contains duplicate logical path {}",
                file.name()
            )));
        }
        let output_path = output_dir.join(enclosed);
        if file.is_dir() {
            fs::create_dir_all(&output_path)?;
        } else {
            if let Some(parent) = output_path.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut output = File::create(&output_path)?;
            std::io::copy(&mut file, &mut output)?;
        }
    }
    Ok(())
}

pub(crate) fn validate_source_tree_budgets(root: &Path) -> Result<()> {
    fn visit(path: &Path, entries: &mut usize, total: &mut u64) -> Result<()> {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            *entries = entries.checked_add(1).ok_or_else(|| {
                PetCoreError::Validation("petpack entry count overflow".to_string())
            })?;
            if *entries > MAX_PETPACK_ENTRIES {
                return Err(PetCoreError::Validation(format!(
                    "petpack has too many entries; maximum is {MAX_PETPACK_ENTRIES}"
                )));
            }
            let entry_path = entry.path();
            let metadata = fs::symlink_metadata(&entry_path)?;
            if metadata.file_type().is_symlink() {
                return Err(PetCoreError::Validation(format!(
                    "petpack source must not contain symlink {}",
                    entry_path.display()
                )));
            }
            if metadata.is_dir() {
                visit(&entry_path, entries, total)?;
                continue;
            }
            if !metadata.is_file() {
                return Err(PetCoreError::Validation(format!(
                    "petpack source contains unsupported file type {}",
                    entry_path.display()
                )));
            }
            let bytes = metadata.len();
            if bytes > MAX_PETPACK_ENTRY_BYTES {
                return Err(PetCoreError::Validation(format!(
                    "petpack entry {} is too large",
                    entry_path.display()
                )));
            }
            *total = total.checked_add(bytes).ok_or_else(|| {
                PetCoreError::Validation("petpack expanded size overflow".to_string())
            })?;
            if *total > MAX_PETPACK_TOTAL_BYTES {
                return Err(PetCoreError::Validation(format!(
                    "petpack expanded size exceeds the {} MiB limit",
                    MAX_PETPACK_TOTAL_BYTES / (1024 * 1024)
                )));
            }
        }
        Ok(())
    }

    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(PetCoreError::Validation(
            "petpack source root must be a real directory".to_string(),
        ));
    }
    let mut entries = 0usize;
    let mut total = 0u64;
    visit(root, &mut entries, &mut total)
}

fn validate_pixel_budget(width: u32, height: u32, label: &str) -> Result<()> {
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| PetCoreError::Validation(format!("{label} pixel count overflow")))?;
    if pixels > MAX_FRAME_PIXELS {
        return Err(PetCoreError::Validation(format!(
            "{label} exceeds the {MAX_FRAME_PIXELS} pixel limit"
        )));
    }
    Ok(())
}

fn has_minimum_visual_coverage(matching_pixels: usize, total_pixels: usize) -> bool {
    total_pixels > 0
        && matching_pixels.saturating_mul(100)
            >= total_pixels.saturating_mul(MIN_VISUAL_COVERAGE_PERCENT)
}

fn validate_visible_cover(image: &RgbaImage, label: &str) -> Result<()> {
    let visible_pixels = image
        .pixels()
        .filter(|pixel| pixel.0[3] >= MIN_VISIBLE_ALPHA)
        .count();
    if !has_minimum_visual_coverage(visible_pixels, image.pixels().len()) {
        return Err(PetCoreError::Validation(format!(
            "{label} must contain at least 1% visible pixels"
        )));
    }
    Ok(())
}

pub(crate) fn normalize_visible_pixels(image: &mut RgbaImage) {
    for pixel in image.pixels_mut() {
        let alpha = pixel.0[3];
        if alpha < MIN_VISIBLE_ALPHA {
            pixel.0 = [0, 0, 0, 0];
            continue;
        }
        for channel in &mut pixel.0[..3] {
            *channel = ((u16::from(*channel) * u16::from(alpha) + 127) / 255) as u8;
        }
    }
}

#[cfg(test)]
mod asset_contract_tests {
    use super::*;

    #[test]
    fn frame_paths_use_runtime_natural_numeric_order() {
        let mut paths = [
            PathBuf::from("frame-10.png"),
            PathBuf::from("frame-02.png"),
            PathBuf::from("frame-2.png"),
            PathBuf::from("frame-1.png"),
            PathBuf::from("frame-002.png"),
            PathBuf::from("Frame-2.png"),
        ];
        paths.sort_by(|left, right| natural_frame_path_cmp(left, right));
        assert_eq!(
            paths
                .iter()
                .map(|path| path.file_name().unwrap().to_str().unwrap())
                .collect::<Vec<_>>(),
            [
                "Frame-2.png",
                "frame-1.png",
                "frame-2.png",
                "frame-02.png",
                "frame-002.png",
                "frame-10.png"
            ]
        );
    }

    #[test]
    fn generated_native_20_pet_preserves_custom_authored_durations() {
        let temp = tempfile::tempdir().unwrap();
        let mut durations = petcore_types::default_state_durations_ms();
        durations.insert(PetStateName::Idle, SHORT_ACTION_DURATION_MS);
        durations.insert(PetStateName::Start, LONG_ACTION_DURATION_MS);
        let form = GenerationForm {
            description: "native 20 contract fixture".to_string(),
            style: "storybook".to_string(),
            quality: QualityLevel::Standard,
            reference_images: Vec::new(),
            native_fps: SMOOTH_FPS,
            state_durations_ms: durations.clone(),
        };

        let manifest = write_generated_petpack_dir(temp.path(), &form, "Timing Pet", None).unwrap();
        fs::write(
            temp.path().join("source/skill_session.jsonl"),
            serde_json::to_string(&serde_json::json!({
                "schema_version": "apc.pet-source-event.v1",
                "event": "skill.loaded",
                "skill": "agent-pet-studio",
                "runner": "petcore-test"
            }))
            .unwrap()
                + "\n",
        )
        .unwrap();
        let validation = validate_petpack_dir(temp.path()).unwrap();
        let artifact: serde_json::Value =
            serde_json::from_slice(&fs::read(temp.path().join("build/validation.json")).unwrap())
                .unwrap();

        assert_eq!(manifest.native_fps, SMOOTH_FPS);
        assert_eq!(
            manifest
                .states
                .iter()
                .find(|state| state.name == PetStateName::Idle)
                .unwrap()
                .duration_ms,
            SHORT_ACTION_DURATION_MS
        );
        assert_eq!(
            manifest
                .states
                .iter()
                .find(|state| state.name == PetStateName::Start)
                .unwrap()
                .duration_ms,
            LONG_ACTION_DURATION_MS
        );
        assert_eq!(validation.state_frame_counts[&PetStateName::Idle], 20);
        assert_eq!(validation.state_frame_counts[&PetStateName::Start], 40);
        assert_eq!(artifact["native_fps"], serde_json::json!(SMOOTH_FPS));
        assert_eq!(artifact["state_durations_ms"], serde_json::json!(durations));
        assert_eq!(
            artifact["frame_count"],
            serde_json::json!(validation.frame_count)
        );
    }

    fn write_strict_sample(dir: &Path) -> PetManifest {
        let manifest =
            write_sample_petpack_dir(dir, QualityLevel::Standard, "Contract Pet", "storybook")
                .unwrap();
        let source_path = dir.join("source/source.json");
        let mut source: serde_json::Value =
            serde_json::from_slice(&fs::read(&source_path).unwrap()).unwrap();
        let source = source.as_object_mut().unwrap();
        source.insert(
            "generator".to_string(),
            serde_json::json!("test-image-generator"),
        );
        source.insert(
            "provenance".to_string(),
            serde_json::json!("skill-full-source"),
        );
        source.insert(
            "visual_source".to_string(),
            serde_json::json!("image-generation"),
        );
        source.insert("preview_only".to_string(), serde_json::json!(false));
        source.insert("runner".to_string(), serde_json::json!("petcore-test"));
        source.insert(
            "skill_helper".to_string(),
            serde_json::json!("agent-pet-maker"),
        );
        fs::write(source_path, serde_json::to_vec_pretty(&source).unwrap()).unwrap();
        manifest
    }

    fn rewrite_strict_sample_as_native_20_alternating(dir: &Path) -> PetManifest {
        let mut manifest = write_strict_sample(dir);
        manifest.native_fps = SMOOTH_FPS;
        for state in REQUIRED_STATES {
            let state_entry = manifest
                .states
                .iter()
                .find(|entry| entry.name == state)
                .unwrap();
            let frame_count = expected_frame_count(SMOOTH_FPS, state_entry.duration_ms).unwrap();
            let state_dir = dir.join("assets/frames").join(state.as_str());
            for entry in fs::read_dir(&state_dir).unwrap() {
                let path = entry.unwrap().path();
                if is_png(&path) {
                    fs::remove_file(path).unwrap();
                }
            }
            for index in 0..frame_count {
                draw_sample_frame(manifest.render_size, state, index)
                    .save(state_dir.join(format!("{index:04}.png")))
                    .unwrap();
            }
        }
        rewrite_timing_metadata(dir, &manifest);
        manifest
    }

    fn rewrite_timing_metadata(dir: &Path, manifest: &PetManifest) {
        let durations = manifest_state_durations_ms(manifest);
        let counts = manifest_state_frame_counts(manifest).unwrap();
        fs::write(
            dir.join("manifest.json"),
            serde_json::to_vec_pretty(manifest).unwrap(),
        )
        .unwrap();
        for (relative, nested) in [
            ("brief.json", Some("runtime")),
            ("source/source.json", None),
            ("build/validation.json", None),
        ] {
            let path = dir.join(relative);
            let mut value: serde_json::Value =
                serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            let target = match nested {
                Some(key) => value.get_mut(key).unwrap().as_object_mut().unwrap(),
                None => value.as_object_mut().unwrap(),
            };
            target.insert(
                "native_fps".to_string(),
                serde_json::json!(manifest.native_fps),
            );
            target.insert(
                "state_durations_ms".to_string(),
                serde_json::json!(durations),
            );
            target.insert("state_frame_counts".to_string(), serde_json::json!(counts));
            if relative == "build/validation.json" {
                target.insert(
                    "frame_count".to_string(),
                    serde_json::json!(counts.values().sum::<usize>()),
                );
            }
            fs::write(path, serde_json::to_vec_pretty(&value).unwrap()).unwrap();
        }
    }

    fn replace_preview_with_static_webp(dir: &Path) {
        image::open(dir.join("assets/preview/cover.png"))
            .unwrap()
            .save_with_format(
                dir.join("assets/preview/animated_preview.webp"),
                image::ImageFormat::WebP,
            )
            .unwrap();
    }

    fn corrupt_animation_frame(path: &Path, target_index: usize) {
        let mut bytes = fs::read(path).unwrap();
        let mut offset = 12usize;
        let mut animation_index = 0usize;
        while offset + 8 <= bytes.len() {
            let payload_size =
                u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
            let payload_start = offset + 8;
            let payload_end = payload_start + payload_size;
            assert!(payload_end <= bytes.len());
            if &bytes[offset..offset + 4] == b"ANMF" {
                if animation_index == target_index {
                    let inner_chunk = payload_start + 16;
                    assert_eq!(&bytes[inner_chunk..inner_chunk + 4], b"VP8L");
                    let bitstream = inner_chunk + 8;
                    assert_eq!(bytes[bitstream], 0x2f);
                    bytes[bitstream] = 0;
                    fs::write(path, bytes).unwrap();
                    return;
                }
                animation_index += 1;
            }
            offset = payload_end + (payload_size & 1);
        }
        panic!("animation frame {target_index} was not found");
    }

    fn rewrite_png_with_different_encoding(source: &Path, destination: &Path) {
        let frame = image::open(source).unwrap().to_rgba8();
        let output = File::create(destination).unwrap();
        image::codecs::png::PngEncoder::new_with_quality(
            output,
            image::codecs::png::CompressionType::Uncompressed,
            image::codecs::png::FilterType::NoFilter,
        )
        .write_image(
            frame.as_raw(),
            frame.width(),
            frame.height(),
            image::ExtendedColorType::Rgba8,
        )
        .unwrap();
    }

    #[test]
    fn reference_materialization_uses_one_snapshot_after_staged_path_swap() {
        let temp = tempfile::tempdir().unwrap();
        let staged = temp.path().join("staged.png");
        let replacement = temp.path().join("replacement.png");
        let output = temp.path().join("petpack-source");
        let original_color = [12, 34, 56, 255];
        let replacement_color = [210, 190, 170, 255];
        ImageBuffer::from_pixel(8, 8, Rgba(original_color))
            .save_with_format(&staged, image::ImageFormat::Png)
            .unwrap();
        ImageBuffer::from_pixel(8, 8, Rgba(replacement_color))
            .save_with_format(&replacement, image::ImageFormat::Png)
            .unwrap();
        let original_bytes = fs::read(&staged).unwrap();
        let staged_for_swap = staged.clone();
        let replacement_for_swap = replacement.clone();

        let (copied, rendered) = materialize_reference_inputs_with_hook(
            &output,
            &[staged.display().to_string()],
            RenderSize {
                width: 8,
                height: 8,
            },
            move || {
                fs::remove_file(&staged_for_swap)?;
                std::os::unix::fs::symlink(&replacement_for_swap, &staged_for_swap)?;
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(fs::read(output.join(&copied[0])).unwrap(), original_bytes);
        assert_ne!(fs::read(&staged).unwrap(), original_bytes);
        let rendered = rendered.expect("validated reference should render");
        assert_eq!(rendered.get_pixel(4, 4).0, original_color);
        assert_ne!(rendered.get_pixel(4, 4).0, replacement_color);
    }

    #[test]
    fn skill_full_source_accepts_transparent_frames_and_distinct_animation() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());

        let validation = validate_petpack_dir(temp.path()).unwrap();

        assert!(validation.ok);
        assert!(!validation.warnings.iter().any(
            |warning| warning.contains("fully opaque") || warning.contains("animated preview")
        ));
    }

    #[test]
    fn skill_full_source_rejects_validation_total_frame_count_mismatch() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        let validation_path = temp.path().join("build/validation.json");
        let mut validation: serde_json::Value =
            serde_json::from_slice(&fs::read(&validation_path).unwrap()).unwrap();
        validation["frame_count"] = serde_json::json!(110);
        fs::write(
            &validation_path,
            serde_json::to_vec_pretty(&validation).unwrap(),
        )
        .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(
            error.contains("build/validation.json field frame_count does not match manifest"),
            "{error}"
        );
    }

    #[test]
    fn skill_full_source_rejects_a_fully_opaque_png_frame() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = write_strict_sample(temp.path());
        RgbaImage::from_pixel(
            manifest.render_size.width,
            manifest.render_size.height,
            Rgba([24, 48, 72, u8::MAX]),
        )
        .save(temp.path().join("assets/frames/idle/0000.png"))
        .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("skill-full-source frame"), "{error}");
        assert!(error.contains("fully opaque"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_a_fully_transparent_png_frame() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = write_strict_sample(temp.path());
        RgbaImage::from_pixel(
            manifest.render_size.width,
            manifest.render_size.height,
            Rgba([24, 48, 72, 0]),
        )
        .save(temp.path().join("assets/frames/idle/0000.png"))
        .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("skill-full-source frame"), "{error}");
        assert!(error.contains("fully transparent"), "{error}");
        assert!(error.contains("visible pet pixels"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_less_than_one_percent_visible_pixels() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = write_strict_sample(temp.path());
        let mut frame = RgbaImage::from_pixel(
            manifest.render_size.width,
            manifest.render_size.height,
            Rgba([0, 0, 0, 0]),
        );
        let visible_pixels = frame.pixels().len() / 200;
        for pixel in frame.pixels_mut().take(visible_pixels) {
            *pixel = Rgba([24, 48, 72, u8::MAX]);
        }
        frame
            .save(temp.path().join("assets/frames/idle/0000.png"))
            .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("less than 1% visible coverage"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_less_than_one_percent_transparent_pixels() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = write_strict_sample(temp.path());
        let mut frame = RgbaImage::from_pixel(
            manifest.render_size.width,
            manifest.render_size.height,
            Rgba([24, 48, 72, u8::MAX]),
        );
        let transparent_pixels = frame.pixels().len() / 200;
        for pixel in frame.pixels_mut().take(transparent_pixels) {
            *pixel = Rgba([0, 0, 0, 0]);
        }
        frame
            .save(temp.path().join("assets/frames/idle/0000.png"))
            .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(
            error.contains("less than 1% transparent coverage"),
            "{error}"
        );
    }

    #[test]
    fn petpack_rejects_a_cover_below_one_percent_visible_coverage() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        let mut cover = RgbaImage::from_pixel(384, 416, Rgba([0, 0, 0, 0]));
        let visible_pixels = cover.pixels().len() / 200;
        for pixel in cover.pixels_mut().take(visible_pixels) {
            *pixel = Rgba([24, 48, 72, u8::MAX]);
        }
        cover
            .save(temp.path().join("assets/preview/cover.png"))
            .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("at least 1% visible pixels"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_a_state_below_its_exact_timing_count() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        fs::remove_file(temp.path().join("assets/frames/idle/0019.png")).unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("state idle has 19 PNG frames"), "{error}");
        assert!(error.contains("expected 20"), "{error}");
    }

    #[test]
    fn state_animation_compares_decoded_pixels_not_png_file_bytes() {
        let strict = tempfile::tempdir().unwrap();
        write_strict_sample(strict.path());
        let strict_first = strict.path().join("assets/frames/idle/0000.png");
        let strict_second = strict.path().join("assets/frames/idle/0001.png");
        rewrite_png_with_different_encoding(&strict_first, &strict_second);
        assert_ne!(
            fs::read(&strict_first).unwrap(),
            fs::read(&strict_second).unwrap()
        );

        let error = validate_petpack_dir(strict.path()).unwrap_err().to_string();

        assert!(error.contains("state idle"), "{error}");
        assert!(error.contains("adjacent pixel-duplicate"), "{error}");

        let legacy = tempfile::tempdir().unwrap();
        write_sample_petpack_dir(
            legacy.path(),
            QualityLevel::Standard,
            "Legacy Duplicate Frames",
            "storybook",
        )
        .unwrap();
        let legacy_first = legacy.path().join("assets/frames/idle/0000.png");
        let legacy_second = legacy.path().join("assets/frames/idle/0001.png");
        rewrite_png_with_different_encoding(&legacy_first, &legacy_second);

        let validation = validate_petpack_dir(legacy.path()).unwrap();

        assert!(validation.ok);
        assert!(validation
            .warnings
            .iter()
            .any(|warning| warning.contains("state idle has")
                && warning.contains("adjacent pixel-duplicate")));
    }

    #[test]
    fn skill_full_source_rejects_duplicate_padding_in_a_high_rate_state() {
        let temp = tempfile::tempdir().unwrap();
        let mut manifest = write_strict_sample(temp.path());
        manifest.native_fps = SMOOTH_FPS;
        for state in REQUIRED_STATES {
            let state_dir = temp.path().join("assets/frames").join(state.as_str());
            let mut originals = fs::read_dir(&state_dir)
                .unwrap()
                .filter_map(std::result::Result::ok)
                .map(|entry| entry.path())
                .filter(|path| is_png(path))
                .collect::<Vec<_>>();
            originals.sort_by(|left, right| natural_frame_path_cmp(left, right));
            let frames = originals
                .iter()
                .map(|path| fs::read(path).unwrap())
                .collect::<Vec<_>>();
            for path in originals {
                fs::remove_file(path).unwrap();
            }
            for (index, bytes) in frames.iter().enumerate() {
                fs::write(state_dir.join(format!("{:04}.png", index * 2)), bytes).unwrap();
                fs::write(state_dir.join(format!("{:04}.png", index * 2 + 1)), bytes).unwrap();
            }
        }
        rewrite_timing_metadata(temp.path(), &manifest);

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("adjacent pixel-duplicate"), "{error}");
    }

    #[test]
    fn runtime_standard_sampling_matches_loop_and_one_shot_renderer_contract() {
        assert_eq!(
            runtime_sample_indices(20, 10, true),
            vec![0, 2, 4, 6, 8, 10, 12, 14, 16, 18]
        );
        assert_eq!(
            runtime_sample_indices(20, 10, false),
            vec![0, 2, 4, 6, 8, 11, 13, 15, 17, 19]
        );
    }

    #[test]
    fn skill_full_source_rejects_native_20_motion_that_becomes_static_at_standard_fps() {
        let temp = tempfile::tempdir().unwrap();
        rewrite_strict_sample_as_native_20_alternating(temp.path());

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("state idle"), "{error}");
        assert!(error.contains("runtime Standard 10 FPS poses"), "{error}");
        assert!(error.contains("source indices 0 and 2"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_duplicate_loop_boundary_frames() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        let idle_dir = temp.path().join("assets/frames/idle");
        let mut paths = fs::read_dir(&idle_dir)
            .unwrap()
            .filter_map(std::result::Result::ok)
            .map(|entry| entry.path())
            .filter(|path| is_png(path))
            .collect::<Vec<_>>();
        paths.sort_by(|left, right| natural_frame_path_cmp(left, right));
        for (index, path) in paths.iter().enumerate() {
            let mut frame = image::open(path).unwrap().to_rgba8();
            let x = frame.width() / 2;
            let y = frame.height() / 2;
            frame.put_pixel(x, y, Rgba([index as u8 + 1, 160, 80, u8::MAX]));
            frame.save(path).unwrap();
        }
        fs::copy(&paths[0], paths.last().unwrap()).unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("last-to-first playback boundary"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_a_static_webp_preview() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        replace_preview_with_static_webp(temp.path());

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(
            error.contains("skill-full-source animated preview"),
            "{error}"
        );
        assert!(error.contains("at least two decodable"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_duplicate_animation_frames() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        let frame = image::open(temp.path().join("assets/preview/cover.png"))
            .unwrap()
            .to_rgba8();
        write_animated_webp(
            &temp.path().join("assets/preview/animated_preview.webp"),
            &[frame.clone(), frame],
        )
        .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("pixel-distinct"), "{error}");
    }

    #[test]
    fn skill_full_source_rejects_corrupt_trailing_animation_frame() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        let preview_size = RenderSize {
            width: 384,
            height: 416,
        };
        let first = draw_sample_frame(preview_size, PetStateName::Idle, 0);
        let second = draw_sample_frame(preview_size, PetStateName::Idle, 1);
        let preview_path = temp.path().join("assets/preview/animated_preview.webp");
        write_animated_webp(&preview_path, &[first.clone(), second, first]).unwrap();
        corrupt_animation_frame(&preview_path, 2);

        let file = File::open(&preview_path).unwrap();
        let decoder = WebPDecoder::new(BufReader::new(file)).unwrap();
        let mut frames = decoder.into_frames();
        assert!(frames.next().unwrap().is_ok());
        assert!(frames.next().unwrap().is_ok());
        assert!(frames.next().unwrap().is_err());

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("undecodable animation frame"), "{error}");
    }

    #[test]
    fn transparent_hidden_rgb_does_not_count_as_distinct_visible_animation() {
        let temp = tempfile::tempdir().unwrap();
        write_strict_sample(temp.path());
        let first = RgbaImage::from_pixel(1, 1, Rgba([255, 0, 0, 0]));
        let second = RgbaImage::from_pixel(1, 1, Rgba([0, 255, 0, 0]));
        write_animated_webp(
            &temp.path().join("assets/preview/animated_preview.webp"),
            &[first, second],
        )
        .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("below 1% visible coverage"), "{error}");
    }

    #[test]
    fn animation_frame_budget_is_a_hard_limit_for_legacy_packages() {
        let temp = tempfile::tempdir().unwrap();
        write_sample_petpack_dir(
            temp.path(),
            QualityLevel::Standard,
            "Legacy Oversized Preview",
            "storybook",
        )
        .unwrap();
        let frames = (0..=MAX_ANIMATED_PREVIEW_FRAMES)
            .map(|index| RgbaImage::from_pixel(1, 1, Rgba([(index & 1) as u8, 24, 48, u8::MAX])))
            .collect::<Vec<_>>();
        write_animated_webp(
            &temp.path().join("assets/preview/animated_preview.webp"),
            &frames,
        )
        .unwrap();

        let error = validate_petpack_dir(temp.path()).unwrap_err().to_string();

        assert!(error.contains("rejected by safety budget"), "{error}");
        assert!(error.contains("more than 120 decoded frames"), "{error}");
    }

    #[test]
    fn animation_decoded_byte_budget_rejects_overflow() {
        let mut frame_count = 0usize;
        let mut decoded_bytes = MAX_DECODED_ANIMATED_PREVIEW_BYTES;

        let issue =
            account_animated_preview_frame(&mut frame_count, &mut decoded_bytes, 1).unwrap_err();

        assert!(matches!(
            issue,
            AnimatedPreviewIssue::Safety(detail) if detail.contains("128 MiB")
        ));
    }

    #[test]
    fn ordinary_assets_remain_valid_with_visual_contract_warnings() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = write_sample_petpack_dir(
            temp.path(),
            QualityLevel::Standard,
            "Legacy Contract Pet",
            "storybook",
        )
        .unwrap();
        RgbaImage::from_pixel(
            manifest.render_size.width,
            manifest.render_size.height,
            Rgba([24, 48, 72, u8::MAX]),
        )
        .save(temp.path().join("assets/frames/idle/0000.png"))
        .unwrap();
        RgbaImage::from_pixel(
            manifest.render_size.width,
            manifest.render_size.height,
            Rgba([72, 48, 24, 0]),
        )
        .save(temp.path().join("assets/frames/tool/0000.png"))
        .unwrap();
        replace_preview_with_static_webp(temp.path());

        let validation = validate_petpack_dir(temp.path()).unwrap();

        assert!(validation.ok);
        assert!(validation
            .warnings
            .iter()
            .any(|warning| warning.contains("below 1% transparent coverage")));
        assert!(validation
            .warnings
            .iter()
            .any(|warning| warning.contains("below 1% visible coverage")));
        assert!(validation
            .warnings
            .iter()
            .any(|warning| warning.contains("at least two decodable")));
    }
}
