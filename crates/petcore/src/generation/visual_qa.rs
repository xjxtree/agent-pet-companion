//! Visual-production QA for generation jobs: motion evidence, presence
//! preview, frame diversity, registration metrics, and synthetic-blend
//! detection. Extracted from the job-orchestration flow so both concerns
//! stay independently readable.

use super::*;

fn safe_motion_evidence_file(path: &Path, label: &str, maximum_bytes: u64) -> Result<PathBuf> {
    let metadata = fs::symlink_metadata(path).map_err(|_| {
        PetCoreError::Validation(format!(
            "visual production requires current {label} motion evidence"
        ))
    })?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > maximum_bytes
    {
        return Err(PetCoreError::Validation(format!(
            "visual production {label} motion evidence is unsafe or exceeds its size limit"
        )));
    }
    Ok(fs::canonicalize(path)?)
}

fn read_motion_evidence_json(path: &Path, label: &str) -> Result<(Value, Vec<u8>)> {
    let safe_path = safe_motion_evidence_file(path, label, MAX_MOTION_EVIDENCE_JSON_BYTES)?;
    let bytes = fs::read(safe_path)?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|error| {
        PetCoreError::Validation(format!(
            "visual production {label} motion evidence is invalid JSON: {error}"
        ))
    })?;
    if !value.is_object() {
        return Err(PetCoreError::Validation(format!(
            "visual production {label} motion evidence must be a JSON object"
        )));
    }
    Ok((value, bytes))
}

fn safe_motion_artifact(motion_root: &Path, relative: &str, label: &str) -> Result<PathBuf> {
    let relative_path = Path::new(relative);
    if relative_path.is_absolute()
        || relative_path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(PetCoreError::Validation(format!(
            "visual production {label} uses an unsafe motion artifact path"
        )));
    }
    let path = motion_root.join(relative_path);
    let safe_path = safe_motion_evidence_file(&path, label, MAX_MOTION_ARTIFACT_BYTES)?;
    let canonical_root = fs::canonicalize(motion_root)?;
    if !safe_path.starts_with(canonical_root) {
        return Err(PetCoreError::Validation(format!(
            "visual production {label} escapes the motion QA directory"
        )));
    }
    Ok(safe_path)
}

fn portable_motion_frame_digest(path: &Path) -> Result<String> {
    let mut image = image::open(path)?.to_rgba8();
    normalize_visible_pixels(&mut image);
    Ok(hex::encode(Sha256::digest(image.as_raw())))
}

pub(super) fn portable_motion_state_digest(source_dir: &Path, state: &str) -> Result<String> {
    let state_dir = source_dir.join("assets/frames").join(state);
    let mut frames = fs::read_dir(&state_dir)?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
        })
        .collect::<Vec<_>>();
    frames.sort_by(|left, right| natural_frame_path_cmp(left, right));
    let mut digest = Sha256::new();
    digest.update(MOTION_QA_SCHEMA.as_bytes());
    digest.update(b"\0");
    digest.update(state.as_bytes());
    digest.update(b"\0");
    for frame in frames {
        let filename = frame.file_name().ok_or_else(|| {
            PetCoreError::Validation(format!("motion QA state {state} has an invalid frame name"))
        })?;
        digest.update(filename.as_encoded_bytes());
        digest.update(b"\0");
        digest.update(portable_motion_frame_digest(&frame)?.as_bytes());
        digest.update(b"\0");
    }
    Ok(hex::encode(digest.finalize()))
}

pub(super) fn visual_production_required_states(
    source_dir: &Path,
    baseline_dir: Option<&Path>,
) -> Result<Vec<&'static str>> {
    let Some(baseline_dir) = baseline_dir else {
        return Ok(REQUIRED_STATES.iter().map(|state| state.as_str()).collect());
    };
    if !baseline_dir.join("manifest.json").is_file() {
        return Err(PetCoreError::Validation(
            "visual production baseline is missing manifest.json".to_string(),
        ));
    }
    let source_manifest: PetManifest =
        serde_json::from_slice(&fs::read(source_dir.join("manifest.json"))?).map_err(|error| {
            PetCoreError::Validation(format!(
                "visual production source manifest is invalid: {error}"
            ))
        })?;
    let baseline_manifest: PetManifest = serde_json::from_slice(&fs::read(
        baseline_dir.join("manifest.json"),
    )?)
    .map_err(|error| {
        PetCoreError::Validation(format!(
            "visual production baseline manifest is invalid: {error}"
        ))
    })?;
    validate_revision_manifest_contract(&baseline_manifest, &source_manifest)?;

    let mut changed = Vec::new();
    for state in REQUIRED_STATES {
        let relative = Path::new("assets/frames").join(state.as_str());
        let baseline = decoded_state_frame_digests(&baseline_dir.join(&relative))?;
        let current = decoded_state_frame_digests(&source_dir.join(&relative))?;
        if baseline != current {
            changed.push(state.as_str());
        }
    }
    if changed.is_empty() {
        return Err(PetCoreError::Validation(
            "visual production revision has no changed motion state to review".to_string(),
        ));
    }

    let timing_changed_states =
        revision_timing_changed_states(&baseline_manifest, &source_manifest);
    for state in REQUIRED_STATES {
        if timing_changed_states.contains(&state) && !changed.contains(&state.as_str()) {
            return Err(PetCoreError::Validation(format!(
                "changing V3 timing requires regenerated frames for action {}",
                state.as_str()
            )));
        }
    }
    Ok(changed)
}

fn evidence_state_names(value: &Value, label: &str) -> Result<Vec<String>> {
    let states = value
        .get("audited_states")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            PetCoreError::Validation(format!(
                "visual production {label} is missing audited_states"
            ))
        })?;
    let mut names = Vec::with_capacity(states.len());
    for state in states {
        let name = state.as_str().ok_or_else(|| {
            PetCoreError::Validation(format!(
                "visual production {label} has a non-string audited state"
            ))
        })?;
        if !REQUIRED_STATES
            .iter()
            .any(|required| required.as_str() == name)
            || names.iter().any(|existing| existing == name)
        {
            return Err(PetCoreError::Validation(format!(
                "visual production {label} has invalid audited states"
            )));
        }
        names.push(name.to_string());
    }
    if names.is_empty() {
        return Err(PetCoreError::Validation(format!(
            "visual production {label} audits no states"
        )));
    }
    Ok(names)
}

pub(super) fn verify_presence_preview(
    source_dir: &Path,
    motion_root: &Path,
    manifest: &PetManifest,
    report: &Value,
) -> Result<()> {
    let presence = report
        .get("presence_preview")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production motion QA is missing its 8–12 second presence preview"
                    .to_string(),
            )
        })?;
    let path = presence
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production presence preview is missing its artifact path".to_string(),
            )
        })?;
    safe_motion_artifact(motion_root, path, "presence preview")?;

    let duration_ms = presence
        .get("duration_ms")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production presence preview is missing duration_ms".to_string(),
            )
        })?;
    if !(PRESENCE_PREVIEW_MIN_MS..=PRESENCE_PREVIEW_MAX_MS).contains(&duration_ms)
        || presence.get("minimum_duration_ms").and_then(Value::as_u64)
            != Some(PRESENCE_PREVIEW_MIN_MS)
        || presence.get("maximum_duration_ms").and_then(Value::as_u64)
            != Some(PRESENCE_PREVIEW_MAX_MS)
    {
        return Err(PetCoreError::Validation(format!(
            "visual production presence preview must last 8–12 seconds; found {duration_ms} ms"
        )));
    }

    let late_motion_boundary_ms = presence
        .get("late_motion_boundary_ms")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let declared_rest_count = presence
        .get("rest_phase_count")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    if !(MIN_SEMANTIC_ACTIVE_MS..duration_ms).contains(&late_motion_boundary_ms)
        || declared_rest_count < 3
    {
        return Err(PetCoreError::Validation(
            "visual production presence preview must show late motion separated by at least three calm rests"
                .to_string(),
        ));
    }

    let sequence = presence
        .get("sequence")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production presence preview is missing its authored sequence".to_string(),
            )
        })?;
    let mut sequence_duration_ms = 0_u64;
    let mut observed_rest_count = 0_u64;
    for segment in sequence {
        let segment = segment.as_object().ok_or_else(|| {
            PetCoreError::Validation(
                "visual production presence preview contains an invalid sequence segment"
                    .to_string(),
            )
        })?;
        let segment_duration_ms = segment
            .get("duration_ms")
            .and_then(Value::as_u64)
            .filter(|duration| *duration > 0)
            .ok_or_else(|| {
                PetCoreError::Validation(
                    "visual production presence preview contains a zero-duration sequence segment"
                        .to_string(),
                )
            })?;
        sequence_duration_ms = sequence_duration_ms
            .checked_add(segment_duration_ms)
            .ok_or_else(|| {
                PetCoreError::Validation(
                    "visual production presence preview duration overflowed".to_string(),
                )
            })?;
        match segment.get("kind").and_then(Value::as_str) {
            Some("action") => {}
            Some("idle_rest") if segment.get("state").and_then(Value::as_str) == Some("idle") => {
                observed_rest_count += 1;
            }
            _ => {
                return Err(PetCoreError::Validation(
                    "visual production presence preview has an unsupported sequence segment"
                        .to_string(),
                ));
            }
        }
    }
    if sequence_duration_ms != duration_ms || observed_rest_count != declared_rest_count {
        return Err(PetCoreError::Validation(
            "visual production presence preview sequence does not match its duration metadata"
                .to_string(),
        ));
    }
    for required_action in ["idle", "thinking", "tool", "done"] {
        if !sequence.iter().any(|segment| {
            segment.get("kind").and_then(Value::as_str) == Some("action")
                && segment.get("state").and_then(Value::as_str) == Some(required_action)
        }) {
            return Err(PetCoreError::Validation(format!(
                "visual production presence preview is missing action {required_action}"
            )));
        }
    }

    for semantic_name in [
        PetStateName::Thinking,
        PetStateName::Tool,
        PetStateName::Waiting,
        PetStateName::Done,
        PetStateName::Failed,
    ] {
        let state = manifest
            .states
            .iter()
            .find(|state| state.name == semantic_name)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "visual production manifest is missing state {}",
                    semantic_name.as_str()
                ))
            })?;
        let authored_ms = state
            .frame_durations_ms
            .iter()
            .try_fold(0_u64, |total, duration| {
                total.checked_add(u64::from(*duration))
            })
            .ok_or_else(|| {
                PetCoreError::Validation(
                    "visual production semantic action duration overflowed".to_string(),
                )
            })?;
        let repeat_count = u64::from(state.playback.entry_repeat_count.unwrap_or(1));
        let active_ms = authored_ms.checked_mul(repeat_count).ok_or_else(|| {
            PetCoreError::Validation(
                "visual production semantic action duration overflowed".to_string(),
            )
        })?;
        if !(MIN_SEMANTIC_ACTIVE_MS..=MAX_SEMANTIC_ACTIVE_MS).contains(&active_ms) {
            return Err(PetCoreError::Validation(format!(
                "visual production action {} stays active for {active_ms} ms; it must remain active for 1000–3200 ms so it neither freezes in under a second nor loops mechanically",
                semantic_name.as_str()
            )));
        }
    }

    let mut all_state_digest = Sha256::new();
    for state in REQUIRED_STATES {
        let state_name = state.as_str();
        let digest = portable_motion_state_digest(source_dir, state_name)?;
        all_state_digest.update(state_name.as_bytes());
        all_state_digest.update(b"\0");
        all_state_digest.update(digest.as_bytes());
        all_state_digest.update(b"\0");
    }
    let expected_digest = hex::encode(all_state_digest.finalize());
    if presence.get("frame_set_digest").and_then(Value::as_str) != Some(expected_digest.as_str()) {
        return Err(PetCoreError::Validation(
            "visual production presence preview is stale for the current nine-action frame set"
                .to_string(),
        ));
    }
    Ok(())
}

pub fn verify_visual_production(
    source_dir: &Path,
    report_path: &Path,
    review_path: &Path,
    baseline_path: Option<&Path>,
) -> Result<VisualProductionVerification> {
    if let Some(path) = baseline_path.filter(|path| !path.is_dir()) {
        let extracted_baseline = tempfile::tempdir()?;
        let destination = extracted_baseline.path().join("baseline");
        extract_validated_petpack_source(path, &destination)?;
        return verify_visual_production_dir(
            source_dir,
            report_path,
            review_path,
            Some(&destination),
        );
    }
    verify_visual_production_dir(source_dir, report_path, review_path, baseline_path)
}

fn verify_visual_production_dir(
    source_dir: &Path,
    report_path: &Path,
    review_path: &Path,
    baseline_dir: Option<&Path>,
) -> Result<VisualProductionVerification> {
    validate_source_tree_budgets(source_dir)?;
    let package_ok = true;
    let manifest: PetManifest =
        serde_json::from_slice(&fs::read(source_dir.join("manifest.json"))?).map_err(|error| {
            PetCoreError::Validation(format!(
                "visual production source manifest is invalid: {error}"
            ))
        })?;
    validate_visual_build_contract(&manifest)?;
    let build_ok = true;
    let interaction_evidence = validate_visual_interaction_contract().unwrap_or_default();
    let interaction_ok = interaction_evidence
        == interaction_attestation::REQUIRED_INTERACTION_SUITES
            .iter()
            .map(|suite| (*suite).to_string())
            .collect::<Vec<_>>();
    validate_visual_runtime_contract(source_dir, &manifest)?;
    let runtime_ok = true;

    let motion_root = report_path.parent().ok_or_else(|| {
        PetCoreError::Validation("motion QA report has no parent directory".to_string())
    })?;
    let (report, report_bytes) = read_motion_evidence_json(report_path, "motion QA report")?;
    let (review, _) = read_motion_evidence_json(review_path, "motion review")?;
    if report.get("schema_version").and_then(Value::as_str) != Some(MOTION_QA_SCHEMA) {
        return Err(PetCoreError::Validation(
            "visual production motion QA report has an incompatible schema".to_string(),
        ));
    }
    if review.get("schema_version").and_then(Value::as_str) != Some(MOTION_REVIEW_SCHEMA)
        || review.get("status").and_then(Value::as_str) != Some("approved")
    {
        return Err(PetCoreError::Validation(
            "visual production motion review is missing or not approved".to_string(),
        ));
    }
    let report_sha256 = hex::encode(Sha256::digest(&report_bytes));
    if review.get("report_sha256").and_then(Value::as_str) != Some(report_sha256.as_str()) {
        return Err(PetCoreError::Validation(
            "visual production motion review is stale for the current QA report".to_string(),
        ));
    }

    let audited = evidence_state_names(&report, "motion QA report")?;
    if evidence_state_names(&review, "motion review")? != audited {
        return Err(PetCoreError::Validation(
            "visual production motion QA and review audit different states".to_string(),
        ));
    }
    let required = visual_production_required_states(source_dir, baseline_dir)?;
    if audited
        != required
            .iter()
            .map(|state| state.to_string())
            .collect::<Vec<_>>()
    {
        return Err(PetCoreError::Validation(format!(
            "visual production motion evidence must audit exactly the changed states: {}",
            required.join(", ")
        )));
    }

    let timing_digest = hex::encode(Sha256::digest(serde_json::to_vec(&manifest.states)?));
    if report.get("timing_digest").and_then(Value::as_str) != Some(timing_digest.as_str()) {
        return Err(PetCoreError::Validation(
            "visual production motion QA timing does not match manifest.json".to_string(),
        ));
    }
    let keyframes = report
        .get("keyframes")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production motion QA is missing its keyframe sheet".to_string(),
            )
        })?;
    safe_motion_artifact(motion_root, keyframes, "keyframe sheet")?;

    let report_states = report
        .get("states")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production motion QA is missing state evidence".to_string(),
            )
        })?;
    let review_states = review
        .get("states")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "visual production motion review is missing state notes".to_string(),
            )
        })?;
    let mut current_digests = Vec::new();
    for state in &required {
        let state_report = report_states
            .get(*state)
            .and_then(Value::as_object)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "visual production motion QA is missing state {state}"
                ))
            })?;
        let current_digest = portable_motion_state_digest(source_dir, state)?;
        if state_report.get("motion_digest").and_then(Value::as_str)
            != Some(current_digest.as_str())
        {
            return Err(PetCoreError::Validation(format!(
                "visual production frames changed after motion QA for state {state}"
            )));
        }
        current_digests.push((*state, current_digest));

        let state_review = review_states
            .get(*state)
            .and_then(Value::as_object)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "visual production motion review is missing state {state}"
                ))
            })?;
        let note_length = state_review
            .get("note")
            .and_then(Value::as_str)
            .map(str::chars)
            .map(Iterator::count)
            .unwrap_or_default();
        if state_review.get("status").and_then(Value::as_str) != Some("approved")
            || !(12..=500).contains(&note_length)
        {
            return Err(PetCoreError::Validation(format!(
                "visual production motion review for state {state} needs a concrete approved note"
            )));
        }

        let previews = state_report
            .get("previews")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "visual production motion QA is missing previews for state {state}"
                ))
            })?;
        let authored = previews
            .get("authored_timing")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "visual production motion QA lacks authored-timing preview for state {state}"
                ))
            })?;
        safe_motion_artifact(motion_root, authored, "authored-timing preview")?;
    }

    let mut frame_set_digest = Sha256::new();
    for (state, digest) in &current_digests {
        frame_set_digest.update(state.as_bytes());
        frame_set_digest.update(b"\0");
        frame_set_digest.update(digest.as_bytes());
        frame_set_digest.update(b"\0");
    }
    let expected_frame_set_digest = hex::encode(frame_set_digest.finalize());
    if report.get("frame_set_digest").and_then(Value::as_str)
        != Some(expected_frame_set_digest.as_str())
        || review.get("frame_set_digest").and_then(Value::as_str)
            != Some(expected_frame_set_digest.as_str())
    {
        return Err(PetCoreError::Validation(
            "visual production motion evidence has a stale frame-set digest".to_string(),
        ));
    }
    verify_presence_preview(source_dir, motion_root, &manifest, &report)?;
    validate_visual_frame_diversity(source_dir, &required)?;
    let visual_ok = true;

    let warning_codes = required
        .iter()
        .flat_map(|state| {
            report_states
                .get(*state)
                .and_then(Value::as_object)
                .and_then(|state| state.get("warnings"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(|warning| warning.get("code").and_then(Value::as_str))
        .map(ToOwned::to_owned)
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let changed_states = required
        .iter()
        .map(|state| (*state).to_string())
        .collect::<Vec<_>>();
    let readiness = ProductionReadiness {
        build_ok,
        package_ok,
        interaction_ok,
        runtime_ok,
        visual_ok,
    };
    let usable = readiness.usable();
    Ok(VisualProductionVerification {
        schema_version: VISUAL_PRODUCTION_VERIFICATION_SCHEMA,
        ok: usable,
        build_ok: readiness.build_ok,
        package_ok: readiness.package_ok,
        interaction_ok: readiness.interaction_ok,
        interaction_evidence,
        runtime_ok: readiness.runtime_ok,
        visual_ok: readiness.visual_ok,
        usable,
        audited_states: audited,
        changed_states,
        timing_digest,
        frame_set_digest: expected_frame_set_digest,
        warning_codes,
    })
}

fn validate_visual_build_contract(manifest: &PetManifest) -> Result<()> {
    if manifest.schema_version != PETPACK_SCHEMA_VERSION {
        return Err(PetCoreError::Validation(format!(
            "visual production requires {PETPACK_SCHEMA_VERSION}"
        )));
    }
    if manifest.render_size != manifest.quality.render_size() {
        return Err(PetCoreError::Validation(
            "visual production render_size does not match its V3 quality tier".to_string(),
        ));
    }
    if manifest.states.len() != REQUIRED_STATES.len() {
        return Err(PetCoreError::Validation(
            "visual production manifest must contain exactly nine authored actions".to_string(),
        ));
    }
    for required in REQUIRED_STATES {
        let matches = manifest
            .states
            .iter()
            .filter(|state| state.name == required)
            .collect::<Vec<_>>();
        if matches.len() != 1
            || matches[0].frames_dir != format!("assets/frames/{}", required.as_str())
        {
            return Err(PetCoreError::Validation(format!(
                "visual production manifest must declare state {} exactly once at its canonical frame directory",
                required.as_str()
            )));
        }
    }
    Ok(())
}

fn validate_visual_interaction_contract() -> Result<Vec<String>> {
    interaction_attestation::validate_current_interaction_attestation()
}

fn validate_visual_runtime_contract(source_dir: &Path, manifest: &PetManifest) -> Result<()> {
    for state in &manifest.states {
        state.validate().map_err(|message| {
            PetCoreError::Validation(format!(
                "visual production state {} timing is invalid: {message}",
                state.name.as_str()
            ))
        })?;
        let state_dir = source_dir.join(&state.frames_dir);
        let mut frames = fs::read_dir(&state_dir)?
            .filter_map(std::result::Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
            })
            .collect::<Vec<_>>();
        frames.sort_by(|left, right| natural_frame_path_cmp(left, right));
        if frames.len() != state.frame_durations_ms.len() {
            return Err(PetCoreError::Validation(format!(
                "visual production runtime frame count for state {} is {}, expected {} from authored timing",
                state.name.as_str(),
                frames.len(),
                state.frame_durations_ms.len()
            )));
        }
        for frame in frames {
            let (width, height) = image::image_dimensions(&frame)?;
            if width != manifest.render_size.width || height != manifest.render_size.height {
                return Err(PetCoreError::Validation(format!(
                    "visual production runtime frame for state {} is {}x{}, expected {}x{}",
                    state.name.as_str(),
                    width,
                    height,
                    manifest.render_size.width,
                    manifest.render_size.height
                )));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn validate_external_motion_evidence(source_dir: &Path) -> Result<()> {
    let workspace_root = source_dir.parent().ok_or_else(|| {
        PetCoreError::Validation("petpack-source has no generation workspace".to_string())
    })?;
    let baseline_dir = workspace_root.join("base-petpack-source");
    verify_visual_production(
        source_dir,
        &workspace_root.join("motion-qa/report.json"),
        &workspace_root.join("motion-review.json"),
        baseline_dir
            .join("manifest.json")
            .is_file()
            .then_some(baseline_dir.as_path()),
    )
    .map(|_| ())
}

#[cfg(test)]
pub(super) fn validate_external_frame_diversity(source_dir: &Path) -> Result<()> {
    let states = REQUIRED_STATES
        .iter()
        .map(|state| state.as_str())
        .collect::<Vec<_>>();
    validate_visual_frame_diversity(source_dir, &states)
}

fn validate_visual_frame_diversity(source_dir: &Path, states: &[&str]) -> Result<()> {
    let mut state_first_frames = std::collections::BTreeSet::new();
    for state_name in states {
        let state = REQUIRED_STATES
            .iter()
            .copied()
            .find(|state| state.as_str() == *state_name)
            .ok_or_else(|| {
                PetCoreError::Validation(format!(
                    "visual production requested unknown state {state_name}"
                ))
            })?;
        let state_dir = source_dir.join("assets/frames").join(state.as_str());
        let mut frames = fs::read_dir(&state_dir)?
            .filter_map(std::result::Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
            })
            .collect::<Vec<_>>();
        frames.sort_by(|left, right| natural_frame_path_cmp(left, right));
        if frames.len() < 2 {
            return Err(PetCoreError::Validation(format!(
                "visual production state {} must contain at least two PNG frames",
                state.as_str()
            )));
        }
        let first = decoded_frame_digest(&frames[0])?;
        let mut state_digests = std::collections::BTreeSet::from([first.clone()]);
        for path in frames.iter().skip(1) {
            state_digests.insert(decoded_frame_digest(path)?);
            if state_digests.len() >= 2 {
                break;
            }
        }
        if state_digests.len() < 2 {
            return Err(PetCoreError::Validation(format!(
                "visual production state {} has no visible frame-to-frame change",
                state.as_str()
            )));
        }
        let blend_candidates = synthetic_blend_candidate_indices(&frames)?;
        if blend_candidates.len() >= 2 {
            return Err(PetCoreError::Validation(format!(
                "visual production state {} contains synthetic blended filler near frames {}; render genuine authored poses instead of crossfade, morph, optical flow, or interpolation",
                state.as_str(),
                blend_candidates
                    .iter()
                    .take(8)
                    .map(usize::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            )));
        }
        let registration = maximum_registration_steps(&frames)?;
        if motion_registration_has_objective_failure(&registration) {
            return Err(PetCoreError::Validation(format!(
                "visual production state {} has visible content touching a runtime-frame edge in {} frame(s); keep at least one transparent pixel on every side. Displacement, silhouette, scale, baseline, and loop metrics are review evidence rather than automatic failures",
                state.as_str(),
                registration.edge_contact_frames,
            )));
        }
        state_first_frames.insert(first);
    }
    if states.len() == REQUIRED_STATES.len() && state_first_frames.len() < 4 {
        return Err(PetCoreError::Validation(
            "visual production states are not visually distinct".to_string(),
        ));
    }
    Ok(())
}

#[derive(Default)]
pub(super) struct RegistrationSteps {
    pub(super) edge_contact_frames: usize,
    pub(super) bbox_width: f64,
    pub(super) bbox_height: f64,
    pub(super) visible_area_ratio: f64,
    pub(super) centroid: f64,
    pub(super) baseline: f64,
}

#[derive(Clone, Copy)]
struct RegistrationSignature {
    touches_edge: bool,
    bbox_width: f64,
    bbox_height: f64,
    visible_area: f64,
    centroid_x: f64,
    centroid_y: f64,
    baseline: f64,
}

pub(super) fn maximum_registration_steps(frame_paths: &[PathBuf]) -> Result<RegistrationSteps> {
    let mut steps = RegistrationSteps::default();
    let mut previous: Option<RegistrationSignature> = None;
    for path in frame_paths {
        let image = image::open(path)?.to_rgba8();
        let signature = registration_signature(&image).ok_or_else(|| {
            PetCoreError::Validation(format!(
                "external full source frame has no visible subject: {}",
                path.display()
            ))
        })?;
        if signature.touches_edge {
            steps.edge_contact_frames = steps.edge_contact_frames.saturating_add(1);
        }
        if let Some(previous) = previous {
            steps.bbox_width = steps
                .bbox_width
                .max(f64::abs(signature.bbox_width - previous.bbox_width));
            steps.bbox_height = steps
                .bbox_height
                .max(f64::abs(signature.bbox_height - previous.bbox_height));
            steps.visible_area_ratio = steps.visible_area_ratio.max(
                f64::abs(signature.visible_area - previous.visible_area)
                    / previous.visible_area.max(0.000_001),
            );
            steps.centroid = steps.centroid.max(f64::hypot(
                signature.centroid_x - previous.centroid_x,
                signature.centroid_y - previous.centroid_y,
            ));
            steps.baseline = steps
                .baseline
                .max(f64::abs(signature.baseline - previous.baseline));
        }
        previous = Some(signature);
    }
    Ok(steps)
}

fn registration_signature(image: &image::RgbaImage) -> Option<RegistrationSignature> {
    if image.width() == 0 || image.height() == 0 {
        return None;
    }
    let mut alpha_total = 0u64;
    let mut weighted_x = 0u64;
    let mut weighted_y = 0u64;
    let mut left = image.width();
    let mut top = image.height();
    let mut right = 0u32;
    let mut bottom = 0u32;
    for (x, y, pixel) in image.enumerate_pixels() {
        let alpha = u64::from(pixel[3]);
        if alpha < 16 {
            continue;
        }
        alpha_total = alpha_total.checked_add(alpha)?;
        weighted_x = weighted_x.checked_add(u64::from(x).checked_mul(alpha)?)?;
        weighted_y = weighted_y.checked_add(u64::from(y).checked_mul(alpha)?)?;
        left = left.min(x);
        top = top.min(y);
        right = right.max(x);
        bottom = bottom.max(y);
    }
    if alpha_total == 0 {
        return None;
    }
    let width = f64::from(image.width());
    let height = f64::from(image.height());
    Some(RegistrationSignature {
        touches_edge: left == 0
            || top == 0
            || right.saturating_add(1) == image.width()
            || bottom.saturating_add(1) == image.height(),
        bbox_width: f64::from(right - left + 1) / width,
        bbox_height: f64::from(bottom - top + 1) / height,
        visible_area: alpha_total as f64 / (255.0 * width * height),
        centroid_x: weighted_x as f64 / alpha_total as f64 / width,
        centroid_y: weighted_y as f64 / alpha_total as f64 / height,
        baseline: f64::from(bottom + 1) / height,
    })
}

pub(super) fn motion_registration_has_objective_failure(registration: &RegistrationSteps) -> bool {
    registration.edge_contact_frames > 0
}

pub(super) fn synthetic_blend_candidate_indices(frame_paths: &[PathBuf]) -> Result<Vec<usize>> {
    if frame_paths.len() < 3 {
        return Ok(Vec::new());
    }
    let mut candidates = Vec::new();
    let mut left = image::open(&frame_paths[0])?.to_rgba8();
    let mut middle = image::open(&frame_paths[1])?.to_rgba8();
    for (index, path) in frame_paths.iter().enumerate().skip(2) {
        let right = image::open(path)?.to_rgba8();
        if linear_blend_fit(&left, &middle, &right).is_some() {
            candidates.push(index - 1);
        }
        left = middle;
        middle = right;
    }
    Ok(candidates)
}

fn linear_blend_fit(
    left: &image::RgbaImage,
    middle: &image::RgbaImage,
    right: &image::RgbaImage,
) -> Option<(f64, f64)> {
    if left.dimensions() != middle.dimensions() || left.dimensions() != right.dimensions() {
        return None;
    }
    let pixel_count = u64::from(left.width()).checked_mul(u64::from(left.height()))?;
    let stride = usize::try_from((pixel_count / 50_000).max(1)).ok()?;
    let mut denominator = 0.0;
    let mut numerator = 0.0;
    let mut channel_count = 0usize;
    for pixel_index in (0..usize::try_from(pixel_count).ok()?).step_by(stride) {
        let offset = pixel_index.checked_mul(4)?;
        for channel in 0..4 {
            let start = f64::from(left.as_raw()[offset + channel]);
            let delta = f64::from(right.as_raw()[offset + channel]) - start;
            let observed = f64::from(middle.as_raw()[offset + channel]) - start;
            denominator += delta * delta;
            numerator += observed * delta;
            channel_count += 1;
        }
    }
    if denominator <= 0.0 || channel_count == 0 {
        return None;
    }
    let motion_rms = (denominator / channel_count as f64).sqrt();
    let blend_weight = numerator / denominator;
    if motion_rms < 2.0 || !(0.05..=0.95).contains(&blend_weight) {
        return None;
    }
    let mut residual = 0.0;
    for pixel_index in (0..usize::try_from(pixel_count).ok()?).step_by(stride) {
        let offset = pixel_index.checked_mul(4)?;
        for channel in 0..4 {
            let start = f64::from(left.as_raw()[offset + channel]);
            let delta = f64::from(right.as_raw()[offset + channel]) - start;
            let observed = f64::from(middle.as_raw()[offset + channel]) - start;
            let error = observed - blend_weight * delta;
            residual += error * error;
        }
    }
    let relative_residual = (residual / denominator).sqrt();
    (relative_residual <= 0.06).then_some((blend_weight, relative_residual))
}

pub(super) fn decoded_frame_digest(path: &Path) -> Result<String> {
    let mut image = image::open(path)?.to_rgba8();
    normalize_visible_pixels(&mut image);
    let mut hasher = Sha256::new();
    hasher.update(image.width().to_le_bytes());
    hasher.update(image.height().to_le_bytes());
    hasher.update(image.as_raw());
    Ok(hex::encode(hasher.finalize()))
}

pub(super) fn decoded_state_frame_digests(state_dir: &Path) -> Result<Vec<String>> {
    let mut paths = fs::read_dir(state_dir)?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
        })
        .collect::<Vec<_>>();
    paths.sort_by(|left, right| natural_frame_path_cmp(left, right));
    paths
        .iter()
        .map(|path| decoded_frame_digest(path))
        .collect()
}
