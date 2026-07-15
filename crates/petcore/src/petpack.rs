use crate::db::Database;
use crate::paths::AppPaths;
use crate::pet_revision::{revision_pet_root, PetRevisionTransaction, PetStoreGuard};
use crate::reference_images::validate_reference_inputs;
use crate::{new_id, now_rfc3339, PetCoreError, Result};
use image::{imageops, ImageBuffer, ImageFormat, Rgba, RgbaImage};
use petcore_types::{
    GenerationForm, PetManifest, PetOrigin, PetStateName, PetSummary, QualityLevel, RenderSize,
    PETPACK_SCHEMA_VERSION, REQUIRED_STATES,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{Read, Seek, Write};
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;
use zip::write::SimpleFileOptions;

pub const GENERATED_FRAMES_PER_STATE: usize = 24;
const RUNTIME_ASSETS_MARKER: &str = ".apc-runtime-assets.json";
const RUNTIME_ASSETS_SCHEMA_VERSION: &str = "apc.runtime-assets.v1";
const MAX_PETPACK_ARCHIVE_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_PETPACK_ENTRIES: usize = 5_000;
const MAX_PETPACK_ENTRY_BYTES: u64 = 256 * 1024 * 1024;
const MAX_PETPACK_TOTAL_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_FRAMES_PER_STATE: usize = 40;
const MAX_TOTAL_FRAMES: usize = MAX_FRAMES_PER_STATE * 7;
const MAX_DECODED_STATE_BYTES: u64 = 420 * 1024 * 1024;
const MAX_FRAME_PIXELS: u64 = 16_777_216;
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
    let mut warnings = Vec::new();
    validate_petpack_metadata(dir, &manifest)?;
    validate_preview_assets(dir, &mut warnings)?;

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
                image::open(&path)?;
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
        if state_frames < 2 {
            warnings.push(format!(
                "state {} has only one frame; animation will be static",
                state.as_str()
            ));
        }
    }

    Ok(PetpackValidation {
        ok: true,
        manifest,
        frame_count,
        warnings,
    })
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
    }

    let standard = manifest
        .fps_profiles
        .get(&petcore_types::FpsProfileName::Standard)
        .copied();
    let smooth = manifest
        .fps_profiles
        .get(&petcore_types::FpsProfileName::Smooth)
        .copied();
    if standard != Some(12) || smooth != Some(20) {
        return Err(PetCoreError::Validation(
            "fps_profiles must contain standard=12 and smooth=20".to_string(),
        ));
    }
    if manifest.default_fps_profile != petcore_types::FpsProfileName::Standard {
        return Err(PetCoreError::Validation(
            "default_fps_profile must be standard".to_string(),
        ));
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

fn validate_preview_assets(dir: &Path, warnings: &mut Vec<String>) -> Result<()> {
    validate_preview_image(dir, "assets/preview/cover.png", warnings)?;
    validate_preview_image(dir, "assets/preview/animated_preview.webp", warnings)?;
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
    if validation.get("manifest_id").is_some() {
        require_metadata_match(
            "build/validation.json",
            "manifest_id",
            validation.get("manifest_id"),
            &serde_json::Value::String(manifest.id.clone()),
        )?;
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
    image::open(&path).map_err(|error| {
        PetCoreError::Validation(format!("invalid preview asset {relative_path}: {error}"))
    })?;
    if width != 384 || height != 416 {
        warnings.push(format!(
            "preview asset {relative_path} is {width}x{height}; recommended preview size is 384x416"
        ));
    }
    Ok(())
}

pub fn write_sample_petpack_dir(
    dir: &Path,
    quality: QualityLevel,
    name: &str,
    style: &str,
    frames_per_state: usize,
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
    fs::write(
        dir.join("brief.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": "apc.pet-brief.v1",
            "name": name,
            "style": style,
            "quality": quality,
            "states": REQUIRED_STATES.iter().map(|state| state.as_str()).collect::<Vec<_>>(),
        }))?,
    )?;

    for state in REQUIRED_STATES {
        let state_dir = dir.join("assets").join("frames").join(state.as_str());
        fs::create_dir_all(&state_dir)?;
        for index in 0..frames_per_state.max(1) {
            let frame = draw_sample_frame(manifest.render_size, state, index);
            frame.save(state_dir.join(format!("{index:04}.png")))?;
        }
    }

    let preview_dir = dir.join("assets").join("preview");
    fs::create_dir_all(&preview_dir)?;
    draw_sample_frame(
        RenderSize {
            width: 384,
            height: 416,
        },
        PetStateName::Idle,
        0,
    )
    .save(preview_dir.join("cover.png"))?;
    draw_sample_frame(
        RenderSize {
            width: 384,
            height: 416,
        },
        PetStateName::Idle,
        1,
    )
    .save_with_format(preview_dir.join("animated_preview.webp"), ImageFormat::WebP)?;

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
            "quality": quality
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
            "validator": "sample-petpack"
        }))?,
    )?;

    Ok(manifest)
}

pub fn write_generated_petpack_dir(
    dir: &Path,
    form: &GenerationForm,
    pet_name: &str,
    ai_brief: Option<&serde_json::Value>,
    frames_per_state: usize,
) -> Result<PetManifest> {
    write_generated_petpack_dir_with_identity(dir, form, pet_name, ai_brief, frames_per_state, None)
}

pub fn write_skill_generated_petpack_dir(
    dir: &Path,
    form: &GenerationForm,
    pet_name: &str,
    ai_brief: Option<&serde_json::Value>,
    frames_per_state: usize,
) -> Result<PetManifest> {
    write_generated_petpack_dir_with_identity(
        dir,
        form,
        pet_name,
        ai_brief,
        frames_per_state,
        Some(("petcore-deterministic-preview", "deterministic_preview")),
    )
}

fn write_generated_petpack_dir_with_identity(
    dir: &Path,
    form: &GenerationForm,
    pet_name: &str,
    ai_brief: Option<&serde_json::Value>,
    frames_per_state: usize,
    source_identity: Option<(&str, &str)>,
) -> Result<PetManifest> {
    fs::create_dir_all(dir)?;
    let manifest = PetManifest::new(
        new_id("pet"),
        pet_name.to_string(),
        form.style.clone(),
        form.quality,
        now_rfc3339(),
    );
    fs::write(
        dir.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;

    let palette = Palette::from_form_and_brief(form, ai_brief);
    let reference_copies = copy_reference_images(dir, &form.reference_images)?;
    let source_form = form_with_package_references(form, &reference_copies);
    let action_plan = action_plan_for_form(form, ai_brief);
    let frame_count = frames_per_state.max(GENERATED_FRAMES_PER_STATE);
    let reference_frame_source = reference_frame_source(form, manifest.render_size);
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
                "default_fps": 12,
                "smooth_fps": 20,
                "frames_per_state": frame_count,
                "render_size": manifest.render_size
            }
        }))?,
    )?;

    for state in REQUIRED_STATES {
        let state_dir = dir.join("assets").join("frames").join(state.as_str());
        fs::create_dir_all(&state_dir)?;
        for index in 0..frame_count {
            let frame = match reference_frame_source.as_ref() {
                Some(source) => {
                    draw_reference_frame(source, manifest.render_size, state, index, frame_count)
                }
                None => {
                    draw_generated_frame(manifest.render_size, state, index, frame_count, &palette)
                }
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
    let preview_cover = match reference_frame_source.as_ref() {
        Some(source) => {
            draw_reference_frame(source, preview_size, PetStateName::Idle, 0, frame_count)
        }
        None => draw_generated_frame(preview_size, PetStateName::Idle, 0, frame_count, &palette),
    };
    preview_cover.save(preview_dir.join("cover.png"))?;
    let preview_animated = match reference_frame_source.as_ref() {
        Some(source) => {
            draw_reference_frame(source, preview_size, PetStateName::Idle, 1, frame_count)
        }
        None => draw_generated_frame(preview_size, PetStateName::Idle, 1, frame_count, &palette),
    };
    preview_animated
        .save_with_format(preview_dir.join("animated_preview.webp"), ImageFormat::WebP)?;

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
            "frames_per_state": frame_count,
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
            "frames_per_state": frame_count
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

pub fn import_petpack(
    paths: &AppPaths,
    database: &Database,
    source_path: &Path,
) -> Result<PetSummary> {
    import_petpack_with_origin(paths, database, source_path, PetOrigin::ExternalImport)
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
    _store_guard: &PetStoreGuard,
) -> Result<PetSummary> {
    let prepared = prepare_import_assets(paths, source_path)?;
    let PreparedImport {
        validation,
        target_path,
        cover_target_path: cover_path,
        generator,
        provenance,
        transaction,
    } = prepared;
    let existing_pet = database.get_pet(&validation.manifest.id)?;
    let was_active = existing_pet.as_ref().is_some_and(|pet| pet.active);
    let pet = PetSummary {
        id: validation.manifest.id.clone(),
        name: validation.manifest.name.clone(),
        style: validation.manifest.style.clone(),
        quality: validation.manifest.quality,
        render_size: validation.manifest.render_size,
        petpack_path: target_path.display().to_string(),
        cover_path: cover_path.display().to_string(),
        origin,
        generator,
        provenance,
        active: was_active,
        created_at: existing_pet
            .as_ref()
            .map(|pet| pet.created_at.clone())
            .unwrap_or_else(|| validation.manifest.created_at.clone()),
    };
    transaction.commit(database, pet)
}

fn prepare_import_assets(paths: &AppPaths, source_path: &Path) -> Result<PreparedImport> {
    let validation = validate_petpack_path(source_path)?;
    fs::create_dir_all(&paths.pets_dir)?;
    let transaction = PetRevisionTransaction::stage(paths, &validation.manifest.id)?;
    let package_stage_path = transaction.stage_petpack_path().to_path_buf();
    if source_path.is_dir() {
        write_petpack_zip(source_path, &package_stage_path)?;
    } else {
        fs::copy(source_path, &package_stage_path)?;
        let staged_validation = validate_petpack_path(&package_stage_path)?;
        if staged_validation.manifest.id != validation.manifest.id {
            return Err(PetCoreError::Validation(
                "staged petpack manifest id does not match source".to_string(),
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

    validate_petpack_path(&package_stage_path)?;
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
    hasher.update(b"apc.pet-assets.fingerprint.v1\0");
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
    if marker.pet_id != pet.id || marker.render_size != pet.render_size {
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
        if marker.pet_id != manifest.id || marker.render_size != manifest.render_size {
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
    image::open(path)
        .map(|_| ())
        .map_err(|error| PetCoreError::Validation(format!("invalid cover image: {error}")))
}

fn is_png(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case("png"))
        .unwrap_or(false)
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

fn reference_frame_source(form: &GenerationForm, render_size: RenderSize) -> Option<RgbaImage> {
    form.reference_images.iter().find_map(|reference| {
        image::open(reference)
            .ok()
            .map(|image| fit_reference_image(image.to_rgba8(), render_size))
    })
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

fn copy_reference_images(dir: &Path, references: &[String]) -> Result<Vec<String>> {
    let reference_dir = dir.join("source").join("references");
    fs::create_dir_all(&reference_dir)?;
    let validated = validate_reference_inputs(references)?;
    let mut copied = Vec::with_capacity(validated.len());
    for (index, reference) in validated.iter().enumerate() {
        let target = reference_dir.join(format!("reference-{index:02}.{}", reference.extension));
        fs::copy(&reference.source, &target)?;
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

fn form_with_package_references(
    form: &GenerationForm,
    reference_copies: &[String],
) -> GenerationForm {
    let mut source_form = form.clone();
    source_form.reference_images = reference_copies.to_vec();
    source_form
}

fn prompt_markdown(form: &GenerationForm, pet_name: &str) -> String {
    format!(
        "# {pet_name}\n\n## 描述\n{}\n\n## 风格\n{}\n\n## 画质\n{}\n\n## 参考图\n{}\n",
        form.description.trim(),
        form.style,
        form.quality.zh_label(),
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
