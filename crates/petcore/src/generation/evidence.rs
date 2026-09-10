//! Workspace-only evidence of executed generation calls and native-alpha retries.
use super::*;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ledger {
    schema_version: String,
    attempts: Vec<Attempt>,
    #[serde(default)]
    selections: BTreeMap<String, Selection>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    call_id: String,
    reason: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Attempt {
    call_id: String,
    object: String,
    provider: String,
    mode: String,
    outcome: String,
    reason: String,
    source: String,
    source_sha256: String,
    prompt: String,
    prompt_sha256: String,
}
fn invalid(message: &str) -> PetCoreError {
    PetCoreError::Validation(format!("generation evidence: {message}"))
}
fn read(root: &Path, relative: &str, maximum: u64) -> Result<Vec<u8>> {
    if relative.is_empty()
        || relative.len() > 512
        || relative.contains('\\')
        || relative
            .split('/')
            .any(|part| matches!(part, "" | "." | ".."))
    {
        return Err(invalid("unsafe workspace-relative artifact path"));
    }
    let mut path = root.to_path_buf();
    for part in relative.split('/') {
        path.push(part);
        if fs::symlink_metadata(&path)?.file_type().is_symlink() {
            return Err(invalid("artifact paths cannot traverse symlinks"));
        }
    }
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_file() || metadata.len() > maximum {
        return Err(invalid("artifact must be a bounded regular file"));
    }
    let bytes = fs::read(path)?;
    if bytes.len() as u64 > maximum {
        return Err(invalid("artifact exceeds its byte limit"));
    }
    Ok(bytes)
}

pub(super) fn verify(root: &Path, required: &[&str]) -> Result<String> {
    let bytes = read(root, "generation-evidence.json", 512 * 1024)?;
    let ledger: Ledger = serde_json::from_slice(&bytes)?;
    if ledger.schema_version != "apc.pet-generation-evidence.v1" || ledger.attempts.len() > 180 {
        return Err(invalid("incompatible schema or excessive attempt count"));
    }
    for (object, selection) in &ledger.selections {
        if !(12..=500).contains(&selection.reason.trim().chars().count())
            || !ledger
                .attempts
                .iter()
                .any(|a| a.object == *object && a.call_id == selection.call_id)
        {
            return Err(invalid(
                "selection references an unknown or mismatched call, or lacks a review reason",
            ));
        }
    }
    let mut calls = BTreeSet::new();
    let mut sources = BTreeSet::new();
    let mut failed: BTreeMap<&str, usize> = BTreeMap::new();
    let mut previous: BTreeMap<&str, &Attempt> = BTreeMap::new();
    for attempt in &ledger.attempts {
        if attempt.call_id.is_empty()
            || attempt.call_id.chars().count() > 128
            || attempt.call_id.chars().any(|c| (c as u32) < 32)
            || !calls.insert(&attempt.call_id)
            || !sources.insert(&attempt.source)
            || !(12..=500).contains(&attempt.reason.trim().chars().count())
            || !(attempt.object == "base"
                || REQUIRED_STATES.iter().any(|s| s.as_str() == attempt.object))
            || !matches!(attempt.provider.as_str(), "codex_imagegen" | "other")
            || !matches!(attempt.mode.as_str(), "native_alpha" | "flat_chroma")
            || !matches!(attempt.outcome.as_str(), "accepted" | "rejected")
        {
            return Err(invalid("invalid attempt fields or repeated executed call"));
        }
        if attempt.provider == "codex_imagegen"
            && attempt.mode == "flat_chroma"
            && failed.get(attempt.object.as_str()).copied().unwrap_or(0) < 3
        {
            return Err(invalid(
                "chroma fallback requires 3 rejected native calls for this object and cycle",
            ));
        }
        let source = read(root, &attempt.source, 64 * 1024 * 1024)?;
        let prompt = read(root, &attempt.prompt, 64 * 1024)?;
        if hex::encode(Sha256::digest(&source)) != attempt.source_sha256
            || hex::encode(Sha256::digest(&prompt)) != attempt.prompt_sha256
        {
            return Err(invalid("recorded source or prompt changed"));
        }
        if std::str::from_utf8(&prompt)
            .ok()
            .is_none_or(|s| s.trim().is_empty())
        {
            return Err(invalid("executed prompt is empty or not UTF-8"));
        }
        if let Some(prior) = previous.get(attempt.object.as_str()) {
            if prior.outcome == "rejected"
                && prior.mode == "native_alpha"
                && attempt.mode == "native_alpha"
                && prior.prompt_sha256 == attempt.prompt_sha256
            {
                return Err(invalid("failed native retries require changed prompts"));
            }
        }
        let selected = ledger
            .selections
            .get(&attempt.object)
            .is_some_and(|s| s.call_id == attempt.call_id);
        if attempt.outcome == "accepted" || selected {
            let reader =
                image::ImageReader::new(std::io::Cursor::new(&source)).with_guessed_format()?;
            let dimensions = reader.into_dimensions()?;
            if u64::from(dimensions.0) * u64::from(dimensions.1) > 32_000_000 {
                return Err(invalid("source exceeds its pixel limit"));
            }
            let decoded = image::load_from_memory(&source)?.to_rgba8();
            let transparent = decoded.pixels().any(|p| p[3] == 0);
            let visible = decoded.pixels().any(|p| p[3] >= 16);
            if (attempt.mode == "native_alpha" && (!transparent || !visible))
                || (attempt.mode == "flat_chroma" && decoded.pixels().any(|p| p[3] != 255))
            {
                return Err(invalid(
                    "accepted source does not match its declared Alpha mode",
                ));
            }
        }
        if attempt.outcome == "accepted" {
            failed.insert(&attempt.object, 0);
        } else if attempt.provider == "codex_imagegen" && attempt.mode == "native_alpha" {
            *failed.entry(&attempt.object).or_default() += 1;
        }
        previous.insert(&attempt.object, attempt);
    }
    for object in required {
        if ledger.selections.contains_key(*object) {
            continue;
        }
        if previous.get(object).is_none_or(|a| a.outcome != "accepted") {
            return Err(invalid(&format!(
                "{object}: latest generation attempt is missing or not accepted"
            )));
        }
    }
    Ok(hex::encode(Sha256::digest(&bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn attempt(root: &Path, index: usize, object: &str, mode: &str, outcome: &str) -> Value {
        let source = format!("source-{index}.png");
        let mut frame = image::RgbaImage::from_pixel(
            192,
            208,
            image::Rgba([0, 0, 0, if mode == "flat_chroma" { 255 } else { 0 }]),
        );
        frame.put_pixel(96, 104, image::Rgba([255, 255, 255, 255]));
        frame.save(root.join(&source)).unwrap();
        let prompt = format!("prompt-{index}.txt");
        fs::write(
            root.join(&prompt),
            format!("Synthetic corrected prompt {index}. No provider call was executed."),
        )
        .unwrap();
        json!({"call_id":format!("fixture-{index}"),"object":object,"provider":"codex_imagegen",
            "mode":mode,"outcome":outcome,"reason":"Synthetic test output inspected for Alpha and geometry.",
            "source":source,"source_sha256":hex::encode(Sha256::digest(fs::read(root.join(&source)).unwrap())),
            "prompt":prompt,"prompt_sha256":hex::encode(Sha256::digest(fs::read(root.join(&prompt)).unwrap()))})
    }
    fn write(root: &Path, attempts: &[Value]) {
        fs::write(
            root.join("generation-evidence.json"),
            serde_json::to_vec(&json!({
            "schema_version":"apc.pet-generation-evidence.v1","attempts":attempts}))
            .unwrap(),
        )
        .unwrap();
    }
    #[test]
    fn retry_count_is_per_object_and_success_closes_cycle() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let mut attempts = Vec::new();
        for count in 0..3 {
            let mut premature = attempts.clone();
            premature.push(attempt(root, 10 + count, "tool", "flat_chroma", "accepted"));
            write(root, &premature);
            assert!(verify(root, &["tool"])
                .unwrap_err()
                .to_string()
                .contains("3 rejected native"));
            attempts.push(attempt(root, count, "tool", "native_alpha", "rejected"));
        }
        let mut other = attempts.clone();
        other.push(attempt(root, 20, "base", "flat_chroma", "accepted"));
        write(root, &other);
        assert!(verify(root, &["base"]).is_err());
        attempts.push(attempt(root, 3, "tool", "flat_chroma", "accepted"));
        write(root, &attempts);
        assert!(verify(root, &["tool"]).is_ok());
        attempts.push(attempt(root, 4, "tool", "flat_chroma", "accepted"));
        write(root, &attempts);
        assert!(verify(root, &["tool"]).is_err());
    }
    #[test]
    fn selection_reuses_earlier_source_without_changing_retry_cycle() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let mut attempts: Vec<_> = (0..3)
            .map(|i| attempt(root, i, "tool", "native_alpha", "rejected"))
            .collect();
        attempts.push(attempt(root, 3, "tool", "flat_chroma", "rejected"));
        let mut ledger = serde_json::json!({"schema_version":"apc.pet-generation-evidence.v1", "attempts":attempts,
            "selections":{"tool":{"call_id":attempts[0]["call_id"],"reason":"Earlier source passes after proportional placement and visual review."}}});
        fs::write(
            root.join("generation-evidence.json"),
            serde_json::to_vec(&ledger).unwrap(),
        )
        .unwrap();
        assert!(verify(root, &["tool"]).is_ok());
        ledger["selections"]["tool"]["call_id"] = Value::String("missing-call".into());
        fs::write(
            root.join("generation-evidence.json"),
            serde_json::to_vec(&ledger).unwrap(),
        )
        .unwrap();
        assert!(verify(root, &["tool"]).is_err());
    }
    #[test]
    fn continuation_rejects_changed_prompt_stale_input_and_unaccepted_latest() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let first = attempt(root, 0, "tool", "native_alpha", "rejected");
        let mut second = attempt(root, 1, "tool", "native_alpha", "accepted");
        second["prompt"] = first["prompt"].clone();
        second["prompt_sha256"] = first["prompt_sha256"].clone();
        write(root, &[first.clone(), second]);
        assert!(verify(root, &["tool"])
            .unwrap_err()
            .to_string()
            .contains("changed prompts"));
        write(root, &[first]);
        assert!(verify(root, &["tool"])
            .unwrap_err()
            .to_string()
            .contains("not accepted"));
        let accepted = attempt(root, 2, "tool", "native_alpha", "accepted");
        write(root, &[accepted]);
        assert!(verify(root, &["tool"]).is_ok());
        fs::write(root.join("source-2.png"), b"changed").unwrap();
        assert!(verify(root, &["tool"])
            .unwrap_err()
            .to_string()
            .contains("changed"));
    }
}
