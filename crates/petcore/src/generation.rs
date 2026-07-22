use crate::db::{Database, GenerationJobRecord};
use crate::paths::AppPaths;
use crate::pet_revision::{
    enrich_pet_revision_metadata, owned_pet_revision_path_guarded, owned_pet_revisions_guarded,
    rollback_imported_revision, PetStoreGuard,
};
use crate::petpack::{
    build_petpack, extract_validated_petpack_source, import_petpack_with_origin_guarded,
    is_bundled_pet, validate_petpack_path, validate_safe_producer_json_privacy,
    validate_source_tree_budgets, write_generated_petpack_dir, write_skill_generated_petpack_dir,
    GENERATED_FRAMES_PER_STATE,
};
use crate::reference_images::{
    stage_reference_inputs, validate_private_recovery_reference_at, MAX_REFERENCE_IMAGES,
    MAX_REFERENCE_TOTAL_BYTES,
};
use crate::{app_server, new_id, now_rfc3339, PetCoreError, Result};
use petcore_types::{
    GenerationForm, GenerationJobHistoryRecord, GenerationJobStatus, GenerationMessageRecord,
    GenerationOperation, GenerationResultSummary, GenerationValidationSummary, PetHistorySnapshot,
    PetManifest, PetOrigin, PetRevisionHistoryRecord, PetSummary, MAX_GENERATION_DESCRIPTION_CHARS,
    PETPACK_SCHEMA_VERSION, REQUIRED_STATES,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const KIND_GENERATION_COMPLETED: &str = "generation_completed";
const KIND_GENERATION_FAILED: &str = "generation_failed";
const KIND_GENERATION_CANCELED: &str = "generation_canceled";
const KIND_GENERATION_PROGRESS: &str = "generation_progress";
const KIND_INPUT_REQUEST: &str = "input_request";
pub const GENERATION_OPERATION_CREATE: &str = "create";
pub const GENERATION_OPERATION_MODIFY: &str = "modify";
static GENERATION_LIFECYCLE_LOCK: Mutex<()> = Mutex::new(());
static MESSAGE_LOG_LOCK: Mutex<()> = Mutex::new(());
const GENERATION_OWNER_STALE_SECONDS: i64 = 30;
const GENERATION_RESULT_FILENAME: &str = "result.json";
const MAX_GENERATION_RESULT_BYTES: u64 = 64 * 1024;
const MAX_STAGED_GENERATION_FORM_BYTES: u64 = 64 * 1024;
const MAX_EDIT_CONTEXT_BYTES: u64 = 512 * 1024;
const EDIT_BASELINE_SNAPSHOT_FILENAME: &str = "baseline-input.petpack";
pub const DEFAULT_PET_HISTORY_LIMIT: usize = 16;
pub const MAX_PET_HISTORY_LIMIT: usize = 32;

#[derive(Debug)]
pub struct GenerationRecoveryForm {
    pub form: GenerationForm,
    pub reference_reselection_count: usize,
}

#[derive(Debug)]
struct UnownedEditRetryBaseline {
    expected_petpack_path: Option<String>,
    expected_sha256: String,
    original_snapshot_path: PathBuf,
}

#[derive(Clone, Copy)]
enum EditBaseline<'a> {
    Current,
    OwnedRevision(&'a str),
    UnownedRetry(&'a UnownedEditRetryBaseline),
}

impl<'a> EditBaseline<'a> {
    fn revision_id(self) -> Option<&'a str> {
        match self {
            Self::OwnedRevision(revision_id) => Some(revision_id),
            Self::Current | Self::UnownedRetry(_) => None,
        }
    }

    fn unowned_retry(self) -> Option<&'a UnownedEditRetryBaseline> {
        match self {
            Self::UnownedRetry(baseline) => Some(baseline),
            Self::Current | Self::OwnedRevision(_) => None,
        }
    }
}

pub fn start_generation(
    paths: &AppPaths,
    database: &Database,
    form: GenerationForm,
) -> Result<String> {
    start_generation_for_instance(paths, database, form, "standalone")
}

pub fn start_generation_for_instance(
    paths: &AppPaths,
    database: &Database,
    form: GenerationForm,
    owner_instance_id: &str,
) -> Result<String> {
    recover_interrupted_jobs_for_instance(paths, database, owner_instance_id)?;
    start_generation_with_retry(paths, database, form, None, owner_instance_id)
}

pub fn start_pet_edit_for_instance(
    paths: &AppPaths,
    database: &Database,
    pet_id: &str,
    instruction: &str,
    owner_instance_id: &str,
) -> Result<String> {
    start_pet_edit_from_revision_for_instance(
        paths,
        database,
        pet_id,
        instruction,
        None,
        owner_instance_id,
    )
}

pub fn start_pet_edit_from_revision_for_instance(
    paths: &AppPaths,
    database: &Database,
    pet_id: &str,
    instruction: &str,
    baseline_revision_id: Option<&str>,
    owner_instance_id: &str,
) -> Result<String> {
    recover_interrupted_jobs_for_instance(paths, database, owner_instance_id)?;
    start_pet_edit_with_retry(
        paths,
        database,
        pet_id,
        instruction,
        baseline_revision_id
            .map(EditBaseline::OwnedRevision)
            .unwrap_or(EditBaseline::Current),
        None,
        owner_instance_id,
    )
}

fn start_pet_edit_with_retry(
    paths: &AppPaths,
    database: &Database,
    pet_id: &str,
    instruction: &str,
    baseline: EditBaseline<'_>,
    retry_of_job_id: Option<&str>,
    owner_instance_id: &str,
) -> Result<String> {
    let instruction = instruction.trim();
    if instruction.is_empty() {
        return Err(PetCoreError::InvalidRequest(
            "pet edit instruction must not be empty".to_string(),
        ));
    }
    if instruction.chars().count() > MAX_GENERATION_DESCRIPTION_CHARS {
        return Err(PetCoreError::InvalidRequest(
            "pet edit instruction must not exceed 8000 characters".to_string(),
        ));
    }
    let pet = database
        .get_pet(pet_id)?
        .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {pet_id}")))?;
    if is_bundled_pet(&pet) {
        return Err(PetCoreError::Conflict(
            "bundled pets are read-only; export and import under a new ID before editing"
                .to_string(),
        ));
    }
    if let Some(active) = database.active_generation_job()? {
        return Err(PetCoreError::InvalidRequest(format!(
            "active generation job already exists: {}",
            active.id
        )));
    }

    let job_id = new_id("job");
    let job_dir = paths.jobs_dir.join(&job_id);
    fs::create_dir_all(&job_dir)?;
    let baseline_manifest =
        match prepare_edit_workspace(paths, database, &job_id, &pet, instruction, baseline) {
            Ok(manifest) => manifest,
            Err(error) => {
                let _ = fs::remove_dir_all(&job_dir);
                return Err(error);
            }
        };
    let form = GenerationForm {
        // Pet identity and modify semantics live in the typed edit context;
        // keeping the submitted form description equal to the instruction
        // preserves the shared 8,000-scalar contract end to end.
        description: instruction.to_string(),
        style: baseline_manifest.style.clone(),
        quality: baseline_manifest.quality,
        reference_images: Vec::new(),
    };
    if let Err(error) = validate_generation_form(&form) {
        let _ = fs::remove_dir_all(&job_dir);
        return Err(error);
    }
    if let Err(error) = fs::write(job_dir.join("form.json"), serde_json::to_vec_pretty(&form)?) {
        let _ = fs::remove_dir_all(&job_dir);
        return Err(error.into());
    }
    if let Err(error) = database.create_generation_job_for_pet_instance_with_retry(
        &job_id,
        &form,
        &job_dir,
        &pet.id,
        retry_of_job_id,
        owner_instance_id,
    ) {
        let _ = fs::remove_dir_all(&job_dir);
        return Err(error);
    }

    append_message(paths, database, &job_id, "user", instruction, 0.01)?;
    append_progress_message(
        paths,
        database,
        &job_id,
        "assistant",
        "已建立所选宠物 revision 的只读基线，正在通过 Codex 生成同一宠物的新版本。",
        0.02,
    )?;

    let paths = paths.clone();
    let database = database.clone();
    let job_id_for_thread = job_id.clone();
    thread::spawn(move || {
        if let Err(error) =
            run_local_petpack_generation(&paths, &database, &job_id_for_thread, &form)
        {
            let _ = fail_generation(
                &paths,
                &database,
                &job_id_for_thread,
                &format!("修改失败：{error}。已保留当前版本。"),
            );
        }
    });

    Ok(job_id)
}

pub fn retry_generation(
    paths: &AppPaths,
    database: &Database,
    retry_of_job_id: &str,
    form: Option<GenerationForm>,
) -> Result<String> {
    retry_generation_for_instance(paths, database, retry_of_job_id, form, "standalone")
}

pub fn retry_generation_for_instance(
    paths: &AppPaths,
    database: &Database,
    retry_of_job_id: &str,
    form: Option<GenerationForm>,
    owner_instance_id: &str,
) -> Result<String> {
    recover_interrupted_jobs_for_instance(paths, database, owner_instance_id)?;
    let Some(original) = database.generation_job(retry_of_job_id)? else {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job not found: {retry_of_job_id}"
        )));
    };
    if matches!(
        original.status,
        GenerationJobStatus::Pending
            | GenerationJobStatus::Running
            | GenerationJobStatus::WaitingForUser
    ) {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job {retry_of_job_id} is not retryable while status is {}",
            crate::enum_name(original.status)
        )));
    }
    if generation_job_operation(&original) == GENERATION_OPERATION_MODIFY {
        let original_form: GenerationForm = serde_json::from_str(&original.form_json)?;
        if let Some(form) = &form {
            let original_value = serde_json::to_value(&original_form)?;
            let retry_value = serde_json::to_value(form)?;
            if retry_value != original_value {
                return Err(PetCoreError::InvalidRequest(
                    "pet edit retry cannot replace the original edit form".to_string(),
                ));
            }
        }
        let context = read_edit_context(paths, &original.id)?;
        let context_pet_id = context
            .get("pet_id")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                PetCoreError::Validation("pet edit retry context is missing pet_id".to_string())
            })?;
        let result_pet_id = original.result_pet_id.as_deref().ok_or_else(|| {
            PetCoreError::Validation("pet edit retry is missing its result_pet_id".to_string())
        })?;
        if context_pet_id != result_pet_id {
            return Err(PetCoreError::Validation(
                "pet edit retry context does not match result_pet_id".to_string(),
            ));
        }
        let instruction = context
            .get("instruction")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                PetCoreError::Validation(
                    "pet edit retry context is missing instruction".to_string(),
                )
            })?;
        let baseline_revision_id = context.get("baseline_revision_id").and_then(Value::as_str);
        let unowned_retry_baseline = if baseline_revision_id.is_none() {
            let expected_sha256 = context
                .get("base_petpack_sha256")
                .and_then(Value::as_str)
                .filter(|digest| valid_sha256(digest))
                .ok_or_else(|| {
                    PetCoreError::Validation(
                        "pet edit retry context is missing a valid original baseline digest"
                            .to_string(),
                    )
                })?;
            if context
                .get("expected_current_petpack_sha256")
                .and_then(Value::as_str)
                .is_some_and(|digest| !digest.eq_ignore_ascii_case(expected_sha256))
            {
                return Err(PetCoreError::Validation(
                    "pet edit retry context has inconsistent unowned baseline digests".to_string(),
                ));
            }
            Some(UnownedEditRetryBaseline {
                expected_petpack_path: context
                    .get("expected_current_petpack_path")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                expected_sha256: expected_sha256.to_ascii_lowercase(),
                original_snapshot_path: paths
                    .jobs_dir
                    .join(&original.id)
                    .join(EDIT_BASELINE_SNAPSHOT_FILENAME),
            })
        } else {
            None
        };
        let retry_baseline = match (baseline_revision_id, unowned_retry_baseline.as_ref()) {
            (Some(revision_id), _) => EditBaseline::OwnedRevision(revision_id),
            (None, Some(baseline)) => EditBaseline::UnownedRetry(baseline),
            (None, None) => {
                return Err(PetCoreError::Validation(
                    "pet edit retry could not reconstruct its original baseline".to_string(),
                ));
            }
        };
        return start_pet_edit_with_retry(
            paths,
            database,
            result_pet_id,
            instruction,
            retry_baseline,
            Some(retry_of_job_id),
            owner_instance_id,
        );
    }
    let retry_form = match form {
        Some(form) => form,
        None => serde_json::from_str(&original.form_json)?,
    };
    start_generation_with_retry(
        paths,
        database,
        retry_form,
        Some(retry_of_job_id),
        owner_instance_id,
    )
}

pub fn generation_job_operation(job: &GenerationJobRecord) -> &'static str {
    match generation_job_operation_kind(job) {
        GenerationOperation::Create => GENERATION_OPERATION_CREATE,
        GenerationOperation::Modify => GENERATION_OPERATION_MODIFY,
    }
}

/// Returns only the safe revision identity from an edit job's durable
/// context. Prompts, instructions, provider/session data, and filesystem
/// locations are intentionally not part of this projection.
pub fn generation_job_baseline_revision_id(
    paths: &AppPaths,
    job: &GenerationJobRecord,
) -> Result<Option<String>> {
    if generation_job_operation_kind(job) != GenerationOperation::Modify {
        return Ok(None);
    }
    let context = read_edit_context(paths, &job.id)?;
    if let (Some(expected_pet_id), Some(context_pet_id)) = (
        job.result_pet_id.as_deref(),
        context.get("pet_id").and_then(Value::as_str),
    ) {
        if expected_pet_id != context_pet_id {
            return Err(PetCoreError::Validation(
                "pet edit baseline identity does not match its job".to_string(),
            ));
        }
    }
    let Some(revision_id) = context.get("baseline_revision_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    if !valid_revision_id(revision_id) {
        return Err(PetCoreError::Validation(
            "pet edit baseline revision id is invalid".to_string(),
        ));
    }
    Ok(Some(revision_id.to_string()))
}

fn generation_job_operation_kind(job: &GenerationJobRecord) -> GenerationOperation {
    if job.job_dir.join("edit-context.json").is_file() {
        GenerationOperation::Modify
    } else {
        GenerationOperation::Create
    }
}

/// Builds the bounded, privacy-minimized history used by the native Pet
/// Library sheet. Unlike `generation.for_pet`, this projection never returns
/// a form, transcript, App Server session, provider payload, or job path.
pub fn pet_history(
    paths: &AppPaths,
    database: &Database,
    pet_id: &str,
    limit: usize,
) -> Result<PetHistorySnapshot> {
    let limit = limit.clamp(1, MAX_PET_HISTORY_LIMIT);

    let (pet, current_revision_id, revisions, revisions_truncated) = {
        let guard = PetStoreGuard::acquire_shared(paths)?;
        // Read the authoritative row only after acquiring the same lock used
        // by imports/deletes. Otherwise a concurrent immutable commit could
        // make a stale row appear to be the current revision in this
        // snapshot.
        let pet = database
            .get_pet(pet_id)?
            .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {pet_id}")))?;
        let scan = owned_pet_revisions_guarded(paths, &pet, limit, &guard)?;
        let mut records = Vec::with_capacity(scan.revisions.len());
        for revision in scan.revisions {
            let validation = validate_petpack_path(&revision.petpack_path)
                .ok()
                .filter(|validation| validation.ok && validation.manifest.id == pet.id);
            let validation_summary =
                validation
                    .as_ref()
                    .map(|validation| GenerationValidationSummary {
                        ok: true,
                        state_count: validation.manifest.states.len(),
                        frame_count: validation.frame_count,
                        warning_count: validation.warnings.len(),
                    });
            let validated = validation_summary.is_some();
            records.push(PetRevisionHistoryRecord {
                revision_id: revision.revision_id,
                current: revision.current,
                validated,
                cover_path: validated
                    .then(|| revision.cover_path.map(|path| path.display().to_string()))
                    .flatten(),
                validation_summary,
            });
        }
        (pet, scan.current_revision_id, records, scan.truncated)
    };

    let mut jobs = database.generation_jobs_for_pet(pet_id, limit.saturating_add(1))?;
    let jobs_truncated = jobs.len() > limit;
    jobs.truncate(limit);
    let jobs = jobs
        .into_iter()
        .map(|job| {
            let result = read_generation_result(paths, database, &job.id)?;
            let operation = generation_job_operation_kind(&job);
            let baseline_revision_id = generation_job_baseline_revision_id(paths, &job)?;
            Ok(GenerationJobHistoryRecord {
                job_id: job.id,
                status: job.status,
                operation,
                baseline_revision_id,
                revision_id: result.as_ref().map(|result| result.revision_id.clone()),
                validation_summary: result.map(|result| result.validation_summary),
                created_at: job.created_at,
                updated_at: job.updated_at,
            })
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(PetHistorySnapshot {
        ok: true,
        pet_id: pet.id,
        current_revision_id,
        revisions,
        jobs,
        truncated: revisions_truncated || jobs_truncated,
    })
}

fn start_generation_with_retry(
    paths: &AppPaths,
    database: &Database,
    form: GenerationForm,
    retry_of_job_id: Option<&str>,
    owner_instance_id: &str,
) -> Result<String> {
    validate_generation_form(&form)?;
    let job_id = new_id("job");
    let job_dir = paths.jobs_dir.join(&job_id);
    fs::create_dir_all(&job_dir)?;
    fs::write(job_dir.join("form.json"), serde_json::to_vec_pretty(&form)?)?;
    if let Err(error) = database.create_generation_job_for_instance(
        &job_id,
        &form,
        &job_dir,
        retry_of_job_id,
        owner_instance_id,
    ) {
        let _ = fs::remove_dir_all(&job_dir);
        return Err(error);
    }

    let paths = paths.clone();
    let database = database.clone();
    let job_id_for_thread = job_id.clone();
    thread::spawn(move || {
        if let Err(error) =
            run_local_petpack_generation(&paths, &database, &job_id_for_thread, &form)
        {
            let _ = fail_generation(
                &paths,
                &database,
                &job_id_for_thread,
                &format!("生成失败：{error}"),
            );
        }
    });

    Ok(job_id)
}

fn validate_generation_form(form: &GenerationForm) -> Result<()> {
    let description = form.description.trim();
    if description.is_empty() {
        return Err(PetCoreError::InvalidRequest(
            "generation description must not be empty".to_string(),
        ));
    }
    if description.chars().count() > MAX_GENERATION_DESCRIPTION_CHARS {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation description must not exceed {MAX_GENERATION_DESCRIPTION_CHARS} characters"
        )));
    }
    Ok(())
}

/// Builds the private Maker recovery projection without reflecting the
/// user-selected source paths persisted in `generation_jobs.form_json`.
///
/// Reference paths are recoverable only after the complete staged form and all
/// descriptor-bound job-local copies validate. Any absent, partial, corrupt,
/// or unsafe staging state degrades to an empty reference list plus a bounded
/// reselection count; it never makes the surrounding session snapshot fail.
pub fn generation_recovery_form(
    paths: &AppPaths,
    job: &GenerationJobRecord,
) -> Result<GenerationRecoveryForm> {
    let original: GenerationForm = serde_json::from_str(&job.form_json)?;
    let original_reference_count = original.reference_images.len();
    let reference_reselection_count = original_reference_count.min(MAX_REFERENCE_IMAGES);
    let mut safe_form = original.clone();
    safe_form.reference_images.clear();

    if original_reference_count == 0 {
        return Ok(GenerationRecoveryForm {
            form: safe_form,
            reference_reselection_count: 0,
        });
    }
    if original_reference_count > MAX_REFERENCE_IMAGES {
        return Ok(GenerationRecoveryForm {
            form: safe_form,
            reference_reselection_count,
        });
    }

    let staged = validated_staged_recovery_form(paths, job, &original).ok();
    if let Some(reference_images) = staged {
        safe_form.reference_images = reference_images;
        return Ok(GenerationRecoveryForm {
            form: safe_form,
            reference_reselection_count: 0,
        });
    }

    Ok(GenerationRecoveryForm {
        form: safe_form,
        reference_reselection_count,
    })
}

fn validated_staged_recovery_form(
    paths: &AppPaths,
    job: &GenerationJobRecord,
    original: &GenerationForm,
) -> Result<Vec<String>> {
    if paths.jobs_dir != paths.home.join("generation-jobs") || !single_path_component(&job.id) {
        return Err(invalid_recovery_workspace());
    }

    let home = open_private_directory(&paths.home)?;
    let jobs = open_private_child_directory(&home, Path::new("generation-jobs"))?;
    let job_directory = open_private_child_directory(&jobs, Path::new(&job.id))?;
    let staged_bytes = read_bounded_private_file_at(
        &job_directory,
        Path::new("form.staged.json"),
        MAX_STAGED_GENERATION_FORM_BYTES,
    )?;
    let staged: GenerationForm =
        serde_json::from_slice(&staged_bytes).map_err(|_| invalid_recovery_workspace())?;
    if staged.description != original.description
        || staged.style != original.style
        || staged.quality != original.quality
        || staged.reference_images.len() != original.reference_images.len()
    {
        return Err(invalid_recovery_workspace());
    }

    let input = open_private_child_directory(&job_directory, Path::new("input"))?;
    let references = open_private_child_directory(&input, Path::new("references"))?;
    let reference_directory_path = paths
        .jobs_dir
        .join(&job.id)
        .join("input")
        .join("references");
    let mut total_bytes = 0u64;
    let mut safe_paths = Vec::with_capacity(staged.reference_images.len());
    for (index, staged_path) in staged.reference_images.iter().enumerate() {
        let staged_path = Path::new(staged_path);
        let extension = staged_path
            .extension()
            .and_then(|value| value.to_str())
            .map(str::to_ascii_lowercase)
            .filter(|value| matches!(value.as_str(), "png" | "webp"))
            .ok_or_else(invalid_recovery_workspace)?;
        let original_extension = Path::new(&original.reference_images[index])
            .extension()
            .and_then(|value| value.to_str())
            .filter(|value| value.eq_ignore_ascii_case(&extension))
            .ok_or_else(invalid_recovery_workspace)?;
        if original_extension.is_empty() {
            return Err(invalid_recovery_workspace());
        }
        let file_name = format!("reference-{index:02}.{extension}");
        let expected_path = reference_directory_path.join(&file_name);
        if staged_path != expected_path {
            return Err(invalid_recovery_workspace());
        }
        let reference_bytes =
            validate_private_recovery_reference_at(&references, index, Path::new(&file_name))?;
        total_bytes = total_bytes
            .checked_add(reference_bytes)
            .ok_or_else(invalid_recovery_workspace)?;
        if total_bytes > MAX_REFERENCE_TOTAL_BYTES {
            return Err(invalid_recovery_workspace());
        }
        safe_paths.push(expected_path.display().to_string());
    }
    Ok(safe_paths)
}

fn single_path_component(value: &str) -> bool {
    let mut components = Path::new(value).components();
    matches!(components.next(), Some(Component::Normal(component)) if component == value)
        && components.next().is_none()
}

fn open_private_directory(path: &Path) -> Result<File> {
    let descriptor = rustix::fs::open(
        path,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::DIRECTORY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| invalid_recovery_workspace())?;
    let metadata = rustix::fs::fstat(&descriptor).map_err(|_| invalid_recovery_workspace())?;
    if !rustix::fs::FileType::from_raw_mode(metadata.st_mode).is_dir()
        || metadata.st_uid != rustix::process::geteuid().as_raw()
    {
        return Err(invalid_recovery_workspace());
    }
    Ok(File::from(descriptor))
}

fn open_private_child_directory<Fd: AsFd>(parent: Fd, name: &Path) -> Result<File> {
    if name.file_name() != Some(name.as_os_str()) {
        return Err(invalid_recovery_workspace());
    }
    let observed = rustix::fs::statat(&parent, name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW)
        .map_err(|_| invalid_recovery_workspace())?;
    let descriptor = rustix::fs::openat(
        &parent,
        name,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::DIRECTORY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| invalid_recovery_workspace())?;
    let opened = rustix::fs::fstat(&descriptor).map_err(|_| invalid_recovery_workspace())?;
    let current_uid = rustix::process::geteuid().as_raw();
    if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_dir()
        || !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_dir()
        || observed.st_uid != current_uid
        || opened.st_uid != current_uid
        || observed.st_dev != opened.st_dev
        || observed.st_ino != opened.st_ino
    {
        return Err(invalid_recovery_workspace());
    }
    Ok(File::from(descriptor))
}

fn read_bounded_private_file_at<Fd: AsFd>(
    parent: Fd,
    name: &Path,
    max_bytes: u64,
) -> Result<Vec<u8>> {
    if name.file_name() != Some(name.as_os_str()) {
        return Err(invalid_recovery_workspace());
    }
    let observed = rustix::fs::statat(&parent, name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW)
        .map_err(|_| invalid_recovery_workspace())?;
    let current_uid = rustix::process::geteuid().as_raw();
    let observed_size = u64::try_from(observed.st_size).unwrap_or(u64::MAX);
    if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_file()
        || observed.st_uid != current_uid
        || observed.st_nlink != 1
        || observed_size > max_bytes
    {
        return Err(invalid_recovery_workspace());
    }
    let descriptor = rustix::fs::openat(
        &parent,
        name,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::NONBLOCK
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| invalid_recovery_workspace())?;
    let opened = rustix::fs::fstat(&descriptor).map_err(|_| invalid_recovery_workspace())?;
    let opened_size = u64::try_from(opened.st_size).unwrap_or(u64::MAX);
    if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_file()
        || !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_file()
        || observed.st_uid != current_uid
        || opened.st_uid != current_uid
        || observed.st_nlink != 1
        || opened.st_nlink != 1
        || observed.st_dev != opened.st_dev
        || observed.st_ino != opened.st_ino
        || observed.st_size != opened.st_size
        || opened_size > max_bytes
    {
        return Err(invalid_recovery_workspace());
    }

    let mut file = File::from(descriptor);
    let mut bytes = Vec::with_capacity(usize::try_from(opened_size).unwrap_or(0));
    Read::by_ref(&mut file)
        .take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| invalid_recovery_workspace())?;
    let final_metadata = rustix::fs::fstat(&file).map_err(|_| invalid_recovery_workspace())?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > max_bytes
        || final_metadata.st_dev != opened.st_dev
        || final_metadata.st_ino != opened.st_ino
        || final_metadata.st_size != opened.st_size
        || final_metadata.st_uid != current_uid
        || final_metadata.st_nlink != 1
        || u64::try_from(bytes.len()).ok() != Some(opened_size)
    {
        return Err(invalid_recovery_workspace());
    }
    Ok(bytes)
}

fn invalid_recovery_workspace() -> PetCoreError {
    PetCoreError::Validation("generation recovery staging is unavailable or unsafe".to_string())
}

pub fn recover_interrupted_jobs(paths: &AppPaths, database: &Database) -> Result<usize> {
    recover_interrupted_jobs_for_instance(paths, database, "standalone")
}

pub fn recover_interrupted_jobs_for_instance(
    paths: &AppPaths,
    database: &Database,
    current_instance_id: &str,
) -> Result<usize> {
    let mut recovered = 0;
    for job in database.interrupted_generation_job_records()? {
        if !generation_heartbeat_is_stale(&job.heartbeat_at) {
            continue;
        }
        if job.owner_instance_id.as_deref() == Some(current_instance_id) {
            continue;
        }
        if job.owner_instance_id.as_deref().is_some_and(|owner| {
            crate::daemon::instance_lock::runtime_owner_is_healthy(paths, owner)
        }) {
            continue;
        }
        fs::create_dir_all(&job.job_dir)?;
        fail_generation(
            paths,
            database,
            &job.id,
            "生成已中断：PetCore 上次退出时该任务仍在运行，已标记失败。请重新发起生成。",
        )?;
        recovered += 1;
    }
    Ok(recovered)
}

fn generation_heartbeat_is_stale(heartbeat_at: &str) -> bool {
    let Ok(heartbeat_at) = OffsetDateTime::parse(heartbeat_at, &Rfc3339) else {
        return true;
    };
    OffsetDateTime::now_utc() - heartbeat_at
        >= time::Duration::seconds(GENERATION_OWNER_STALE_SECONDS)
}

pub fn read_messages(paths: &AppPaths, job_id: &str) -> Result<Vec<serde_json::Value>> {
    let database = Database::new(paths.db_path.clone());
    database.init()?;
    read_messages_with_database(paths, &database, job_id)
}

pub fn read_messages_with_database(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<Vec<Value>> {
    let path = paths.jobs_dir.join(job_id).join("messages.jsonl");
    let _log = message_log_lock();
    sync_legacy_messages_unlocked(database, &path, job_id)?;
    database
        .generation_messages(job_id)?
        .into_iter()
        .map(|message| serde_json::to_value(message).map_err(Into::into))
        .collect()
}

fn sync_legacy_messages_unlocked(database: &Database, path: &Path, job_id: &str) -> Result<()> {
    if database.generation_job(job_id)?.is_none() || !path.exists() {
        return Ok(());
    }
    let migrated = database.generation_messages_migrated(job_id)?;
    for message in read_messages_unlocked(path, job_id)? {
        let kind = message.get("kind").and_then(Value::as_str);
        if migrated && kind != Some("jsonl_diagnostic") {
            continue;
        }
        let id = message.get("id").and_then(Value::as_str).ok_or_else(|| {
            PetCoreError::Validation(
                "legacy generation message is missing its stable id".to_string(),
            )
        })?;
        database.import_generation_message(
            id,
            job_id,
            message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("system"),
            kind,
            message.get("content").and_then(Value::as_str).unwrap_or(""),
            message
                .get("progress")
                .and_then(Value::as_f64)
                .unwrap_or(0.0),
            message
                .get("created_at")
                .and_then(Value::as_str)
                .unwrap_or(""),
            message.get("diagnostic"),
        )?;
    }
    database.mark_generation_messages_migrated(job_id)
}

fn read_messages_unlocked(path: &Path, job_id: &str) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let bytes = fs::read(path)?;
    let mut messages = Vec::new();
    for (index, line) in bytes.split(|byte| *byte == b'\n').enumerate() {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        match serde_json::from_slice::<Value>(line) {
            Ok(mut message) if message.is_object() => {
                ensure_message_id(&mut message, job_id, index, line);
                messages.push(message);
            }
            Ok(_) => messages.push(jsonl_shape_diagnostic(job_id, index, line)),
            Err(error) => messages.push(jsonl_diagnostic(job_id, index, line, &error)),
        }
    }
    Ok(messages)
}

fn ensure_message_id(message: &mut Value, job_id: &str, index: usize, raw: &[u8]) {
    let Some(object) = message.as_object_mut() else {
        return;
    };
    if object
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.trim().is_empty())
    {
        return;
    }
    object.insert(
        "id".to_string(),
        json!(stable_message_id(job_id, index, raw)),
    );
}

fn stable_message_id(job_id: &str, index: usize, raw: &[u8]) -> String {
    let mut digest = Sha256::new();
    digest.update(job_id.as_bytes());
    digest.update(b"\0");
    digest.update(index.to_le_bytes());
    digest.update(b"\0");
    digest.update(raw);
    format!("msg_legacy_{}", hex::encode(digest.finalize()))
}

fn jsonl_diagnostic(job_id: &str, index: usize, raw: &[u8], error: &serde_json::Error) -> Value {
    let digest = Sha256::digest(raw);
    json!({
        "id": stable_message_id(job_id, index, raw),
        "role": "system",
        "kind": "jsonl_diagnostic",
        "content": format!("已隔离损坏的生成消息记录（第 {} 行）", index + 1),
        "progress": 0.0,
        "created_at": "",
        "diagnostic": {
            "line": index + 1,
            "sha256": hex::encode(digest),
            "error_category": format!("{:?}", error.classify()).to_ascii_lowercase()
        }
    })
}

fn jsonl_shape_diagnostic(job_id: &str, index: usize, raw: &[u8]) -> Value {
    let digest = Sha256::digest(raw);
    json!({
        "id": stable_message_id(job_id, index, raw),
        "role": "system",
        "kind": "jsonl_diagnostic",
        "content": format!("已隔离格式无效的生成消息记录（第 {} 行）", index + 1),
        "progress": 0.0,
        "created_at": "",
        "diagnostic": {
            "line": index + 1,
            "sha256": hex::encode(digest),
            "error_category": "shape"
        }
    })
}

pub fn wait_messages(
    paths: &AppPaths,
    job_id: &str,
    after_revision: &str,
    timeout_ms: u64,
) -> Result<Value> {
    let database = Database::new(paths.db_path.clone());
    database.init()?;
    wait_messages_with_database(paths, &database, job_id, after_revision, timeout_ms)
}

pub fn wait_messages_with_database(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    after_revision: &str,
    timeout_ms: u64,
) -> Result<Value> {
    let timeout_ms = timeout_ms.clamp(250, 30_000);
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let poll_interval = Duration::from_millis(80);

    loop {
        // Discover a legacy JSONL file exactly once before comparing the
        // authoritative database sequence. Subsequent mirror-only changes do
        // not advance the revision.
        let _ = read_messages_with_database(paths, database, job_id)?;
        let revision = messages_revision(database, job_id)?;
        if revision != after_revision {
            return messages_payload(paths, database, job_id, true);
        }
        if Instant::now() >= deadline {
            return messages_payload(paths, database, job_id, false);
        }
        thread::sleep(poll_interval);
    }
}

fn messages_payload(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    changed: bool,
) -> Result<Value> {
    let result = read_generation_result(paths, database, job_id)?;
    let legacy_result_pet_id = if result.is_none() {
        database.generation_job(job_id)?.and_then(|job| {
            (job.status == GenerationJobStatus::Completed)
                .then_some(job.result_pet_id)
                .flatten()
        })
    } else {
        None
    };
    Ok(json!({
        "revision": messages_revision(database, job_id)?,
        "changed": changed,
        "messages": read_messages_with_database(paths, database, job_id)?,
        "result_pet_id": result
            .as_ref()
            .map(|result| result.result_pet_id.as_str())
            .or(legacy_result_pet_id.as_deref()),
        "revision_id": result.as_ref().map(|result| &result.revision_id),
        "validation_summary": result.as_ref().map(|result| &result.validation_summary),
    }))
}

/// Reads the durable result of a completed job. Legacy jobs and non-terminal
/// jobs intentionally return `None`, allowing older response shapes to remain
/// valid without guessing a revision from the pet's current database row.
pub fn read_generation_result(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<Option<GenerationResultSummary>> {
    let Some(job) = database.generation_job(job_id)? else {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job not found: {job_id}"
        )));
    };
    if job.status != GenerationJobStatus::Completed {
        return Ok(None);
    }
    let path = paths.jobs_dir.join(job_id).join(GENERATION_RESULT_FILENAME);
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > MAX_GENERATION_RESULT_BYTES
        || metadata.uid() != rustix::process::geteuid().as_raw()
        || metadata.nlink() != 1
    {
        return Err(PetCoreError::Validation(format!(
            "generation result is not a bounded regular file: {}",
            path.display()
        )));
    }
    let descriptor = rustix::fs::open(
        &path,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(std::io::Error::from)?;
    let mut file = File::from(descriptor);
    let opened = file.metadata()?;
    if !opened.is_file()
        || opened.len() > MAX_GENERATION_RESULT_BYTES
        || opened.uid() != rustix::process::geteuid().as_raw()
        || opened.nlink() != 1
        || opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
    {
        return Err(PetCoreError::Validation(
            "generation result identity changed while opening".to_string(),
        ));
    }
    let mut bytes = Vec::with_capacity(usize::try_from(opened.len()).unwrap_or(0));
    file.read_to_end(&mut bytes)?;
    let result: GenerationResultSummary = serde_json::from_slice(&bytes)?;
    if job.result_pet_id.as_deref() != Some(result.result_pet_id.as_str()) {
        return Err(PetCoreError::Validation(
            "generation result pet id does not match the completed job".to_string(),
        ));
    }
    if !valid_revision_id(&result.revision_id)
        || !result.validation_summary.ok
        || result.validation_summary.state_count != REQUIRED_STATES.len()
        || result.validation_summary.frame_count == 0
        || result.validation_summary.frame_count > REQUIRED_STATES.len() * 40
        || result.validation_summary.warning_count > 4_096
    {
        return Err(PetCoreError::Validation(
            "generation result failed structural validation".to_string(),
        ));
    }
    Ok(Some(result))
}

fn valid_revision_id(value: &str) -> bool {
    value.strip_prefix("rev_").is_some_and(|suffix| {
        suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}

fn messages_revision(database: &Database, job_id: &str) -> Result<String> {
    Ok(database.generation_message_revision(job_id)?.to_string())
}

pub fn cancel_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<Vec<serde_json::Value>> {
    let job_dir = paths.jobs_dir.join(job_id);
    if !job_dir.is_dir() {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job not found: {job_id}"
        )));
    }

    let _lifecycle = lifecycle_lock();
    let status = database.generation_job_status(job_id)?.ok_or_else(|| {
        PetCoreError::InvalidRequest(format!("generation job not found: {job_id}"))
    })?;
    match status {
        GenerationJobStatus::Completed | GenerationJobStatus::Failed => {
            return read_messages(paths, job_id);
        }
        GenerationJobStatus::Canceled => {
            if !is_generation_canceled(paths, job_id) {
                fs::write(cancel_marker_path(paths, job_id), now_rfc3339())?;
            }
            mark_canceled_locked(paths, database, job_id)?;
        }
        GenerationJobStatus::Pending
        | GenerationJobStatus::Running
        | GenerationJobStatus::WaitingForUser => {
            fs::write(cancel_marker_path(paths, job_id), now_rfc3339())?;
            mark_canceled_locked(paths, database, job_id)?;
        }
    }
    read_messages(paths, job_id)
}

pub fn append_user_reply(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    content: &str,
) -> Result<Vec<serde_json::Value>> {
    append_user_reply_for_instance(paths, database, job_id, content, "standalone")
}

pub fn append_user_reply_for_instance(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    content: &str,
    owner_instance_id: &str,
) -> Result<Vec<serde_json::Value>> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return read_messages(paths, job_id);
    }

    let job_dir = paths.jobs_dir.join(job_id);
    if !job_dir.is_dir() {
        return Err(crate::PetCoreError::InvalidRequest(format!(
            "generation job not found: {job_id}"
        )));
    }

    let status = {
        let _lifecycle = lifecycle_lock();
        if is_generation_canceled(paths, job_id) {
            mark_canceled_locked(paths, database, job_id)?;
            return Err(PetCoreError::InvalidRequest(
                "generation was canceled; start a new generation job before sending revision feedback"
                    .to_string(),
            ));
        }
        let status = database.generation_job_status(job_id)?.ok_or_else(|| {
            PetCoreError::InvalidRequest(format!("generation job not found: {job_id}"))
        })?;
        match status {
            GenerationJobStatus::Completed | GenerationJobStatus::WaitingForUser => {}
            GenerationJobStatus::Canceled => {
                return Err(PetCoreError::InvalidRequest(
                    "generation was canceled; start a new generation job before sending revision feedback"
                        .to_string(),
                ));
            }
            GenerationJobStatus::Failed => {
                return Err(PetCoreError::InvalidRequest(
                    "generation failed; start a new generation job before sending revision feedback"
                        .to_string(),
                ));
            }
            GenerationJobStatus::Pending | GenerationJobStatus::Running => {
                return Err(PetCoreError::InvalidRequest(
                    "generation is still running; wait for completion before sending revision feedback"
                        .to_string(),
                ));
            }
        }

        let messages = read_messages(paths, job_id)?;
        let progress = messages
            .last()
            .and_then(|message| message.get("progress").and_then(serde_json::Value::as_f64))
            .unwrap_or(0.0);
        if status == GenerationJobStatus::Completed && progress < 1.0 {
            return Err(PetCoreError::InvalidRequest(
                "generation is still running; wait for completion before sending revision feedback"
                    .to_string(),
            ));
        }

        database.claim_generation_job(job_id, owner_instance_id)?;
        append_message_with_kind(
            paths,
            database,
            job_id,
            "user",
            trimmed,
            0.03,
            None,
            Some(GenerationJobStatus::Running),
            None,
        )?;
        status
    };
    let assistant_message = if status == GenerationJobStatus::WaitingForUser {
        "已收到补充信息，正在恢复 Codex 会话继续生成。"
    } else {
        "已发送调整意见，正在恢复 Codex 会话生成新版本。"
    };
    append_progress_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        assistant_message,
        0.04,
    )?;
    let messages = read_messages(paths, job_id)?;
    let paths = paths.clone();
    let database = database.clone();
    let job_id = job_id.to_string();
    let content = trimmed.to_string();
    let rebase_on_current_revision = status == GenerationJobStatus::Completed;
    thread::spawn(move || {
        if let Err(error) = run_reply_revision(
            &paths,
            &database,
            &job_id,
            &content,
            rebase_on_current_revision,
        ) {
            let _ = fail_generation(
                &paths,
                &database,
                &job_id,
                &format!("调整失败：{error}。已保留当前版本。"),
            );
        }
    });
    Ok(messages)
}

fn append_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
) -> Result<()> {
    append_message_with_kind(
        paths, database, job_id, role, content, progress, None, None, None,
    )
}

fn append_progress_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        progress,
        Some(KIND_GENERATION_PROGRESS),
        None,
        None,
    )
}

fn append_completed_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    result_pet_id: &str,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        1.0,
        Some(KIND_GENERATION_COMPLETED),
        Some(GenerationJobStatus::Completed),
        Some(result_pet_id),
    )
}

fn append_failed_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        1.0,
        Some(KIND_GENERATION_FAILED),
        Some(GenerationJobStatus::Failed),
        None,
    )
}

fn append_canceled_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
) -> Result<()> {
    append_message_with_kind(
        paths,
        database,
        job_id,
        role,
        content,
        1.0,
        Some(KIND_GENERATION_CANCELED),
        Some(GenerationJobStatus::Canceled),
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn append_message_with_kind(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
    kind: Option<&str>,
    status_transition: Option<GenerationJobStatus>,
    result_pet_id: Option<&str>,
) -> Result<()> {
    let _log = message_log_lock();
    let job_dir = paths.jobs_dir.join(job_id);
    fs::create_dir_all(&job_dir)?;
    let message_path = job_dir.join("messages.jsonl");
    sync_legacy_messages_unlocked(database, &message_path, job_id)?;
    repair_truncated_message_tail(&message_path, job_id)?;
    let message = database.append_generation_message(
        job_id,
        role,
        kind,
        content,
        progress,
        status_transition,
        result_pet_id,
    )?;
    database.mark_generation_messages_migrated(job_id)?;
    // SQLite is authoritative. The JSONL file remains a best-effort diagnostic
    // mirror, so a mirror write failure must not roll back a committed message.
    let _ = append_message_mirror_unlocked(&message_path, job_id, &message);
    Ok(())
}

fn append_message_mirror_unlocked(
    path: &Path,
    job_id: &str,
    message: &GenerationMessageRecord,
) -> Result<()> {
    if path.exists()
        && read_messages_unlocked(path, job_id)?
            .iter()
            .any(|value| value.get("id").and_then(Value::as_str) == Some(message.id.as_str()))
    {
        return Ok(());
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{}", serde_json::to_string(message)?)?;
    file.flush()?;
    Ok(())
}

fn append_progress_message_if_active(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
) -> Result<()> {
    if is_generation_canceled(paths, job_id) || is_terminal_job(database, job_id)? {
        return Ok(());
    }
    append_progress_message(paths, database, job_id, role, content, progress)
}

fn repair_truncated_message_tail(path: &Path, job_id: &str) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let bytes = fs::read(path)?;
    if bytes.is_empty() || bytes.ends_with(b"\n") {
        return Ok(());
    }
    let boundary = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    let tail = &bytes[boundary..];
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    if serde_json::from_slice::<Value>(tail).is_ok() {
        file.seek(SeekFrom::End(0))?;
        file.write_all(b"\n")?;
        file.flush()?;
        return Ok(());
    }

    file.set_len(boundary as u64)?;
    file.seek(SeekFrom::Start(boundary as u64))?;
    let line_index = bytes[..boundary]
        .iter()
        .filter(|byte| **byte == b'\n')
        .count();
    let parse_error = serde_json::from_slice::<Value>(tail).unwrap_err();
    let diagnostic = jsonl_diagnostic(job_id, line_index, tail, &parse_error);
    writeln!(file, "{}", serde_json::to_string(&diagnostic)?)?;
    file.flush()?;
    Ok(())
}

fn message_log_lock() -> MutexGuard<'static, ()> {
    MESSAGE_LOG_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn cancel_marker_path(paths: &AppPaths, job_id: &str) -> PathBuf {
    paths.jobs_dir.join(job_id).join("canceled")
}

fn is_generation_canceled(paths: &AppPaths, job_id: &str) -> bool {
    cancel_marker_path(paths, job_id).exists()
}

fn lifecycle_lock() -> MutexGuard<'static, ()> {
    GENERATION_LIFECYCLE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn is_terminal_status(status: GenerationJobStatus) -> bool {
    matches!(
        status,
        GenerationJobStatus::Completed
            | GenerationJobStatus::Failed
            | GenerationJobStatus::Canceled
    )
}

fn is_terminal_job(database: &Database, job_id: &str) -> Result<bool> {
    Ok(database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status))
}

fn mark_canceled_locked(paths: &AppPaths, database: &Database, job_id: &str) -> Result<()> {
    append_canceled_message(paths, database, job_id, "assistant", "已取消生成。")?;
    Ok(())
}

fn finish_if_canceled(paths: &AppPaths, database: &Database, job_id: &str) -> Result<bool> {
    if !is_generation_canceled(paths, job_id) {
        return Ok(false);
    }
    let _lifecycle = lifecycle_lock();
    mark_canceled_locked(paths, database, job_id)?;
    Ok(true)
}

fn fail_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    content: &str,
) -> Result<()> {
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(());
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(|status| {
            matches!(
                status,
                GenerationJobStatus::Completed | GenerationJobStatus::Canceled
            )
        })
    {
        return Ok(());
    }
    append_failed_message(paths, database, job_id, "assistant", content)?;
    Ok(())
}

fn mark_running_if_active(paths: &AppPaths, database: &Database, job_id: &str) -> Result<bool> {
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(false);
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status)
    {
        return Ok(false);
    }
    database.update_generation_job(job_id, GenerationJobStatus::Running, None)?;
    Ok(true)
}

fn run_local_petpack_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    form: &GenerationForm,
) -> Result<()> {
    if !mark_running_if_active(paths, database, job_id)? {
        return Ok(());
    }
    let staged_form = stage_reference_images(paths, job_id, form)?;
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let app_server_session = app_server::run_pet_studio_session_with_updates_and_cancel(
        paths,
        job_id,
        &staged_form,
        |update| {
            let _ = append_progress_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                &update.content,
                update.progress,
            );
        },
        || is_generation_canceled(paths, job_id),
    );
    write_app_server_session(paths, job_id, &app_server_session)?;
    if let Some(session_id) = app_server_session
        .get("session_id")
        .and_then(serde_json::Value::as_str)
    {
        database.update_generation_job_session(job_id, session_id)?;
    }
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    if pause_generation_for_input_request(paths, database, job_id, &app_server_session, 0.18)? {
        return Ok(());
    }
    if app_server_session
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        append_progress_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            "AI brief 已进入本次 petpack 元数据。",
            0.145,
        )?;
        append_ai_brief_normalization_message(paths, database, job_id, &app_server_session, 0.146)?;
    } else {
        if skill_full_source_required() {
            match prepare_and_import_skill_petpack_source(
                paths,
                database,
                job_id,
                &staged_form,
                &app_server_session,
            )? {
                SkillPetpackImport::Imported { pet, previous_pet } => {
                    complete_imported_pet(
                        paths,
                        database,
                        job_id,
                        &pet,
                        previous_pet.as_ref(),
                        Some((
                            "Codex App Server final response 未完成，但 Pet Studio Skill 已写出可校验 petpack-source，已采用该产物加入宠物库。",
                            0.95,
                        )),
                        "完成，可在宠物库启用。",
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Canceled => return Ok(()),
                SkillPetpackImport::Invalid(error) => {
                    fail_generation(
                        paths,
                        database,
                        job_id,
                        &format!("Pet Studio Skill 已写出 petpack-source，但校验失败：{error}。"),
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Missing => {}
            }
        }
        let detail = app_server_failure_detail(&app_server_session);
        if !local_pet_studio_fallback_enabled() {
            fail_generation(
                paths,
                database,
                job_id,
                &format!("Codex App Server brief turn 未完成：{detail}。请在 Agent 连接中修复 Codex App Server 后重试。"),
            )?;
            return Ok(());
        }

        append_progress_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            &format!("Codex App Server brief turn 未完成：{detail}。已显式启用开发本地 Pet Studio runner，将继续完成打包与校验。"),
            0.12,
        )?;
    }

    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    match prepare_and_import_skill_petpack_source(
        paths,
        database,
        job_id,
        &staged_form,
        &app_server_session,
    )? {
        SkillPetpackImport::Imported { pet, previous_pet } => {
            complete_imported_pet(
                paths,
                database,
                job_id,
                &pet,
                previous_pet.as_ref(),
                Some((
                    "已采用 Pet Studio Skill 输出的 petpack-source，校验通过并加入宠物库。",
                    0.95,
                )),
                "完成，可在宠物库启用。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Canceled => {
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) if !local_pet_studio_fallback_enabled() => {
            fail_generation(
                paths,
                database,
                job_id,
                &format!("Pet Studio Skill 输出的 petpack-source 不可用：{error}。请在 Agent 连接中修复 Codex App Server / Skill 后重试。"),
            )?;
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) => {
            append_progress_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                &format!("Pet Studio Skill 输出的 petpack-source 不可用：{error}。已显式启用开发本地 Pet Studio materializer。"),
                0.16,
            )?;
        }
        SkillPetpackImport::Missing if external_skill_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在 App Server turn 中创建外部 petpack-source；当前验证要求 external full source mode，因此不会使用内置 Pet Studio materializer。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing
            if skill_full_source_required() && app_server_completed(&app_server_session) =>
        {
            append_progress_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                "Codex App Server 已返回结构化 brief，正在由内置 Pet Studio Skill 写出完整 petpack-source。",
                0.18,
            )?;
            if let Some((pet, previous_pet)) = materialize_internal_skill_petpack(
                paths,
                database,
                job_id,
                &staged_form,
                &app_server_session,
            )? {
                complete_imported_pet(
                    paths,
                    database,
                    job_id,
                    &pet,
                    previous_pet.as_ref(),
                    Some((
                        "内置 Pet Studio Skill 已写出 full-source，校验通过并加入宠物库。",
                        0.9,
                    )),
                    "完成，可在宠物库启用。",
                )?;
            }
            return Ok(());
        }
        SkillPetpackImport::Missing if skill_full_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在 App Server turn 中创建 petpack-source；当前验证要求 full source mode，因此不会回退到 Codex brief materializer。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing => {}
    }

    append_progress_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "PetCore 正在根据 Codex AI brief 生成 petpack-source 与动作方案。",
        0.15,
    )?;
    thread::sleep(Duration::from_millis(120));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    append_progress_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "已根据描述、风格和参考图生成 7 个状态动作。",
        0.35,
    )?;
    thread::sleep(Duration::from_millis(120));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    append_progress_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "正在渲染实机 PNG 帧并写入 .petpack source 元数据。",
        0.62,
    )?;

    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let pet_name = derive_pet_name(&staged_form, app_server_session.get("ai_brief"));
    let manifest = write_generated_petpack_dir(
        &source_dir,
        &staged_form,
        &pet_name,
        app_server_session.get("ai_brief"),
        GENERATED_FRAMES_PER_STATE,
    )?;
    let manifest = apply_expected_pet_identity(paths, database, job_id, &source_dir, manifest)?;
    write_skill_session(
        paths,
        job_id,
        &source_dir,
        &staged_form,
        &manifest,
        &app_server_session,
    )?;
    let output = paths
        .jobs_dir
        .join(job_id)
        .join(format!("{}.petpack", manifest.id));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let validation = build_petpack(&source_dir, &output)?;
    let Some((pet, previous_pet)) = import_petpack_if_active(
        paths,
        database,
        job_id,
        &output,
        Some(&validation.manifest.id),
        PetOrigin::GeneratedByPetcoreJob,
    )?
    else {
        return Ok(());
    };
    complete_imported_pet(
        paths,
        database,
        job_id,
        &pet,
        previous_pet.as_ref(),
        Some(("校验通过，已保存 .petpack 并加入宠物库。", 0.9)),
        "完成，可在宠物库启用。",
    )?;
    Ok(())
}

fn run_reply_revision(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    user_message: &str,
    rebase_on_current_revision: bool,
) -> Result<()> {
    if !mark_running_if_active(paths, database, job_id)? {
        return Ok(());
    }
    let form = read_generation_form(paths, job_id)?;
    let staged_form = stage_reference_images(paths, job_id, &form)?;
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    refresh_edit_workspace_for_reply(
        paths,
        database,
        job_id,
        user_message,
        rebase_on_current_revision,
    )?;
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let previous_session = read_app_server_session(paths, job_id)?.unwrap_or(Value::Null);

    let thread_id = previous_session
        .get("thread_id")
        .and_then(serde_json::Value::as_str);
    let mut render_form = staged_form.clone();
    let mut app_server_session = if let Some(thread_id) = thread_id {
        app_server::run_pet_studio_follow_up_with_updates_and_cancel(
            paths,
            job_id,
            thread_id,
            &staged_form,
            previous_session.get("ai_brief"),
            user_message,
            |update| {
                let _ = append_progress_message_if_active(
                    paths,
                    database,
                    job_id,
                    "assistant",
                    &update.content,
                    update.progress,
                );
            },
            || is_generation_canceled(paths, job_id),
        )
    } else {
        json!({
            "initialized": false,
            "started": false,
            "resumed": false,
            "turn_started": false,
            "completed": false,
            "follow_up": true,
            "checked_at": now_rfc3339(),
            "error": "previous Codex App Server thread id is missing"
        })
    };

    if app_server_session
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        != Some(true)
        && should_retry_revision_with_new_session(&app_server_session)
    {
        append_progress_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            "原 Codex 会话无法恢复，正在基于调整意见开启新的 Pet Studio brief turn。",
            0.06,
        )?;
        render_form = form_with_revision_feedback(&staged_form, user_message);
        app_server_session = app_server::run_pet_studio_session_with_updates_and_cancel(
            paths,
            job_id,
            &render_form,
            |update| {
                let _ = append_progress_message_if_active(
                    paths,
                    database,
                    job_id,
                    "assistant",
                    &update.content,
                    update.progress,
                );
            },
            || is_generation_canceled(paths, job_id),
        );
    }

    write_app_server_session(paths, job_id, &app_server_session)?;
    if let Some(session_id) = app_server_session
        .get("session_id")
        .and_then(serde_json::Value::as_str)
    {
        database.update_generation_job_session(job_id, session_id)?;
    }
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    if pause_generation_for_input_request(paths, database, job_id, &app_server_session, 0.18)? {
        return Ok(());
    }

    if app_server_session
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        != Some(true)
    {
        if skill_full_source_required() {
            match prepare_and_import_skill_petpack_source(
                paths,
                database,
                job_id,
                &render_form,
                &app_server_session,
            )? {
                SkillPetpackImport::Imported { pet, previous_pet } => {
                    complete_imported_pet(
                        paths,
                        database,
                        job_id,
                        &pet,
                        previous_pet.as_ref(),
                        None,
                        "Codex App Server final response 未完成，但 Pet Studio Skill 已写出可校验调整版 petpack-source，并保留原启用状态。",
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Canceled => return Ok(()),
                SkillPetpackImport::Invalid(error) => {
                    fail_generation(
                        paths,
                        database,
                        job_id,
                        &format!("Pet Studio Skill 已写出调整版 petpack-source，但校验失败：{error}。已保留当前版本。"),
                    )?;
                    return Ok(());
                }
                SkillPetpackImport::Missing => {}
            }
        }
        let detail = app_server_session
            .get("error")
            .or_else(|| app_server_session.get("detail"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Codex App Server 暂不可用");
        fail_generation(
            paths,
            database,
            job_id,
            &format!("Codex 调整未完成：{detail}。已保留当前版本。"),
        )?;
        return Ok(());
    }

    append_progress_message_if_active(
        paths,
        database,
        job_id,
        "assistant",
        "Codex 已完成调整方案，正在重新渲染 petpack。",
        0.35,
    )?;
    append_ai_brief_normalization_message(paths, database, job_id, &app_server_session, 0.36)?;
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    match prepare_and_import_skill_petpack_source(
        paths,
        database,
        job_id,
        &render_form,
        &app_server_session,
    )? {
        SkillPetpackImport::Imported { pet, previous_pet } => {
            complete_imported_pet(
                paths,
                database,
                job_id,
                &pet,
                previous_pet.as_ref(),
                None,
                "已采用 Pet Studio Skill 输出的调整版 petpack-source，并保留原启用状态。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Canceled => {
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) if !local_pet_studio_fallback_enabled() => {
            fail_generation(
                paths,
                database,
                job_id,
                &format!("Pet Studio Skill 输出的调整版 petpack-source 不可用：{error}。已保留当前版本，请在 Agent 连接中修复 Codex App Server / Skill 后重试。"),
            )?;
            return Ok(());
        }
        SkillPetpackImport::Invalid(error) => {
            append_progress_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                &format!("Pet Studio Skill 输出的调整版 petpack-source 不可用：{error}。已显式启用开发本地 Pet Studio materializer。"),
                0.37,
            )?;
        }
        SkillPetpackImport::Missing if external_skill_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在调整 turn 中创建外部 petpack-source；当前验证要求 external full source mode，因此已保留当前版本。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing
            if skill_full_source_required() && app_server_completed(&app_server_session) =>
        {
            append_progress_message_if_active(
                paths,
                database,
                job_id,
                "assistant",
                "Codex App Server 已返回调整 brief，正在由内置 Pet Studio Skill 写出完整调整版 petpack-source。",
                0.38,
            )?;
            if let Some((pet, previous_pet)) = materialize_internal_skill_petpack(
                paths,
                database,
                job_id,
                &render_form,
                &app_server_session,
            )? {
                complete_imported_pet(
                    paths,
                    database,
                    job_id,
                    &pet,
                    previous_pet.as_ref(),
                    None,
                    "内置 Pet Studio Skill 已写出调整版 full-source，并保留原启用状态。",
                )?;
            }
            return Ok(());
        }
        SkillPetpackImport::Missing if skill_full_source_required() => {
            fail_generation(
                paths,
                database,
                job_id,
                "Pet Studio Skill 未在调整 turn 中创建 petpack-source；当前验证要求 full source mode，因此已保留当前版本。",
            )?;
            return Ok(());
        }
        SkillPetpackImport::Missing => {}
    }

    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let pet_name = derive_pet_name(&render_form, app_server_session.get("ai_brief"));
    let manifest = write_generated_petpack_dir(
        &source_dir,
        &render_form,
        &pet_name,
        app_server_session.get("ai_brief"),
        GENERATED_FRAMES_PER_STATE,
    )?;
    let manifest = apply_expected_pet_identity(paths, database, job_id, &source_dir, manifest)?;
    write_skill_session(
        paths,
        job_id,
        &source_dir,
        &render_form,
        &manifest,
        &app_server_session,
    )?;
    let output = paths
        .jobs_dir
        .join(job_id)
        .join(format!("{}.petpack", manifest.id));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(());
    }
    let validation = build_petpack(&source_dir, &output)?;
    let Some((pet, previous_pet)) = import_petpack_if_active(
        paths,
        database,
        job_id,
        &output,
        Some(&validation.manifest.id),
        PetOrigin::GeneratedByPetcoreJob,
    )?
    else {
        return Ok(());
    };
    complete_imported_pet(
        paths,
        database,
        job_id,
        &pet,
        previous_pet.as_ref(),
        None,
        "调整版本已保存入库，并保留原启用状态。",
    )?;
    Ok(())
}

fn read_generation_form(paths: &AppPaths, job_id: &str) -> Result<GenerationForm> {
    let path = paths.jobs_dir.join(job_id).join("form.json");
    if !path.is_file() {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation form not found for job: {job_id}"
        )));
    }
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn prepare_edit_workspace(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    pet: &PetSummary,
    instruction: &str,
    baseline: EditBaseline<'_>,
) -> Result<PetManifest> {
    let baseline_revision_id = baseline.revision_id();
    let unowned_retry_baseline = baseline.unowned_retry();
    let _store_guard = PetStoreGuard::acquire_shared(paths)?;
    let job_dir = paths.jobs_dir.join(job_id);
    let base_dir = job_dir.join("base-petpack-source");
    if base_dir.exists() {
        fs::remove_dir_all(&base_dir)?;
    }
    let current_petpack_path = PathBuf::from(&pet.petpack_path);
    if unowned_retry_baseline
        .and_then(|baseline| baseline.expected_petpack_path.as_deref())
        .is_some_and(|expected_path| expected_path != pet.petpack_path)
    {
        return Err(unowned_retry_conflict());
    }

    let baseline_snapshot_path = job_dir.join(EDIT_BASELINE_SNAPSHOT_FILENAME);
    remove_regular_file_if_present(&baseline_snapshot_path)?;
    let current_probe_path = job_dir.join(".current-petpack-probe");
    remove_regular_file_if_present(&current_probe_path)?;
    let expected_retry_sha256 =
        unowned_retry_baseline.map(|baseline| baseline.expected_sha256.as_str());
    let expected_current_sha256 = stage_stable_petpack_snapshot(
        &current_petpack_path,
        &current_probe_path,
        expected_retry_sha256,
    )?;

    let base_sha256 = match baseline_revision_id {
        Some(revision_id) => {
            let baseline_petpack_path =
                owned_pet_revision_path_guarded(paths, pet, revision_id, &_store_guard)?
                    .ok_or_else(|| {
                        PetCoreError::InvalidRequest(format!(
                    "baseline revision is not an owned immutable revision for {}: {revision_id}",
                    pet.id
                ))
                    })?;
            let digest = stage_stable_petpack_snapshot(
                &baseline_petpack_path,
                &baseline_snapshot_path,
                None,
            )?;
            remove_regular_file_if_present(&current_probe_path)?;
            digest
        }
        None => {
            if let Some(retry_baseline) = unowned_retry_baseline {
                match fs::symlink_metadata(&retry_baseline.original_snapshot_path) {
                    Ok(metadata)
                        if metadata.file_type().is_file() && !metadata.file_type().is_symlink() =>
                    {
                        stage_stable_petpack_snapshot(
                            &retry_baseline.original_snapshot_path,
                            &baseline_snapshot_path,
                            Some(&retry_baseline.expected_sha256),
                        )?;
                        remove_regular_file_if_present(&current_probe_path)?;
                    }
                    Ok(_) => {
                        return Err(PetCoreError::Validation(
                            "original edit baseline snapshot is not a regular file".to_string(),
                        ));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        // Jobs created before durable baseline snapshots were
                        // introduced can still retry, but only while the live
                        // package is byte-identical to the submitted baseline.
                        fs::rename(&current_probe_path, &baseline_snapshot_path)?;
                    }
                    Err(error) => return Err(error.into()),
                }
                retry_baseline.expected_sha256.clone()
            } else {
                fs::rename(&current_probe_path, &baseline_snapshot_path)?;
                expected_current_sha256.clone()
            }
        }
    };

    let validation = extract_validated_petpack_source(&baseline_snapshot_path, &base_dir)?;
    if validation.manifest.id != pet.id {
        let _ = fs::remove_dir_all(&base_dir);
        return Err(PetCoreError::Validation(format!(
            "pet database id {} does not match package id {}",
            pet.id, validation.manifest.id
        )));
    }
    if sha256_file(&baseline_snapshot_path)? != base_sha256 {
        let _ = fs::remove_dir_all(&base_dir);
        return Err(PetCoreError::Conflict(
            "selected baseline revision changed while staging edit".to_string(),
        ));
    }

    // The authoritative package may have changed between lookup and staging.
    // Recheck it through another descriptor-bound snapshot before the
    // generation job becomes visible. This keeps validation and staging on
    // exact bytes instead of hashing one path instance and later reopening a
    // potentially replaced file.
    let current = database
        .get_pet(&pet.id)?
        .ok_or_else(|| PetCoreError::Conflict("base pet was deleted while staging edit".into()))?;
    if current.petpack_path != pet.petpack_path {
        let _ = fs::remove_dir_all(&base_dir);
        return Err(unowned_retry_baseline
            .map(|_| unowned_retry_conflict())
            .unwrap_or_else(|| {
                PetCoreError::Conflict(
                    "current pet changed while staging edit; start the modification again"
                        .to_string(),
                )
            }));
    }
    let current_verify_path = job_dir.join(".current-petpack-verify");
    remove_regular_file_if_present(&current_verify_path)?;
    if let Err(error) = stage_stable_petpack_snapshot(
        Path::new(&current.petpack_path),
        &current_verify_path,
        Some(&expected_current_sha256),
    ) {
        let _ = fs::remove_dir_all(&base_dir);
        return Err(if unowned_retry_baseline.is_some() {
            unowned_retry_conflict()
        } else {
            error
        });
    }
    remove_regular_file_if_present(&current_verify_path)?;

    let context = json!({
        "schema_version": "apc.pet-edit-context.v2",
        "operation": "modify",
        "pet_id": pet.id,
        "baseline_revision_id": baseline_revision_id,
        "base_petpack_sha256": base_sha256,
        "expected_current_petpack_path": pet.petpack_path,
        "expected_current_petpack_sha256": expected_current_sha256,
        "base_manifest": validation.manifest,
        "instruction": instruction,
        "preserve_pet_id": true,
        "security": {
            "package_metadata_is_untrusted_data": true,
            "execute_package_content": false
        },
        "created_at": now_rfc3339()
    });
    fs::write(
        job_dir.join("edit-context.json"),
        serde_json::to_vec_pretty(&context)?,
    )?;
    Ok(validation.manifest)
}

fn refresh_edit_workspace_for_reply(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    instruction: &str,
    rebase_on_current_revision: bool,
) -> Result<()> {
    let Some(pet_id) = expected_pet_id(database, job_id)? else {
        return Ok(());
    };
    let pet = database
        .get_pet(&pet_id)?
        .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {pet_id}")))?;
    let context = read_edit_context(paths, job_id)?;
    let baseline_revision_id = if rebase_on_current_revision {
        None
    } else {
        if let Some(expected_path) = context
            .get("expected_current_petpack_path")
            .and_then(Value::as_str)
        {
            if pet.petpack_path != expected_path {
                return Err(PetCoreError::Conflict(
                    "current pet changed while the edit was waiting for input".to_string(),
                ));
            }
        }
        let expected_sha256 = context
            .get("expected_current_petpack_sha256")
            .or_else(|| context.get("base_petpack_sha256"))
            .and_then(Value::as_str);
        if let Some(expected_sha256) = expected_sha256 {
            if sha256_file(Path::new(&pet.petpack_path))? != expected_sha256 {
                return Err(PetCoreError::Conflict(
                    "current pet changed while the edit was waiting for input".to_string(),
                ));
            }
        }
        context.get("baseline_revision_id").and_then(Value::as_str)
    };
    prepare_edit_workspace(
        paths,
        database,
        job_id,
        &pet,
        instruction,
        baseline_revision_id
            .map(EditBaseline::OwnedRevision)
            .unwrap_or(EditBaseline::Current),
    )
    .map(|_| ())
}

fn expected_pet_id(database: &Database, job_id: &str) -> Result<Option<String>> {
    Ok(database
        .generation_job(job_id)?
        .and_then(|job| job.result_pet_id))
}

fn apply_expected_pet_identity(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    source_dir: &Path,
    mut manifest: PetManifest,
) -> Result<PetManifest> {
    let Some(expected_id) = expected_pet_id(database, job_id)? else {
        return Ok(manifest);
    };
    manifest.id = expected_id;
    if let Some(base_manifest) = read_edit_context(paths, job_id)?
        .get("base_manifest")
        .cloned()
        .and_then(|value| serde_json::from_value::<PetManifest>(value).ok())
    {
        manifest.created_at = base_manifest.created_at;
    }
    fs::write(
        source_dir.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;
    Ok(manifest)
}

fn read_edit_context(paths: &AppPaths, job_id: &str) -> Result<Value> {
    let path = paths.jobs_dir.join(job_id).join("edit-context.json");
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Value::Null),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > MAX_EDIT_CONTEXT_BYTES
        || metadata.uid() != rustix::process::geteuid().as_raw()
        || metadata.nlink() != 1
    {
        return Err(PetCoreError::Validation(
            "pet edit context is not a bounded private regular file".to_string(),
        ));
    }

    let descriptor = rustix::fs::open(
        &path,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(std::io::Error::from)?;
    let mut file = File::from(descriptor);
    let opened = file.metadata()?;
    if !opened.is_file()
        || opened.len() > MAX_EDIT_CONTEXT_BYTES
        || opened.uid() != rustix::process::geteuid().as_raw()
        || opened.nlink() != 1
        || opened.dev() != metadata.dev()
        || opened.ino() != metadata.ino()
    {
        return Err(PetCoreError::Validation(
            "pet edit context identity changed while opening".to_string(),
        ));
    }
    let mut bytes = Vec::with_capacity(usize::try_from(opened.len()).unwrap_or(0));
    Read::by_ref(&mut file)
        .take(MAX_EDIT_CONTEXT_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_EDIT_CONTEXT_BYTES {
        return Err(PetCoreError::Validation(
            "pet edit context exceeds its size limit".to_string(),
        ));
    }
    let value: Value = serde_json::from_slice(&bytes)?;
    Ok(value)
}

fn ensure_edit_commit_preconditions(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    output_manifest: &PetManifest,
) -> Result<()> {
    let context = read_edit_context(paths, job_id)?;
    if context.is_null() {
        return Ok(());
    }
    let expected_id = context
        .get("pet_id")
        .and_then(Value::as_str)
        .ok_or_else(|| PetCoreError::Validation("edit context is missing pet_id".to_string()))?;
    if output_manifest.id != expected_id {
        return Err(PetCoreError::Validation(format!(
            "pet modification must preserve manifest id {expected_id}; got {}",
            output_manifest.id
        )));
    }
    let base_manifest: PetManifest = context
        .get("base_manifest")
        .cloned()
        .ok_or_else(|| {
            PetCoreError::Validation("edit context is missing base_manifest".to_string())
        })
        .and_then(|value| {
            serde_json::from_value(value).map_err(|error| {
                PetCoreError::Validation(format!("edit context base_manifest is invalid: {error}"))
            })
        })?;
    if output_manifest.schema_version != base_manifest.schema_version
        || output_manifest.quality != base_manifest.quality
        || output_manifest.render_size != base_manifest.render_size
        || output_manifest.fps_profiles != base_manifest.fps_profiles
        || output_manifest.default_fps_profile != base_manifest.default_fps_profile
        || output_manifest.states != base_manifest.states
        || output_manifest.created_at != base_manifest.created_at
    {
        return Err(PetCoreError::Validation(
            "pet modification changed the base format, quality, state layout, FPS, or created_at contract"
                .to_string(),
        ));
    }
    let expected_sha256 = context
        .get("expected_current_petpack_sha256")
        .or_else(|| context.get("base_petpack_sha256"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "edit context is missing expected current petpack digest".to_string(),
            )
        })?;
    let current = database.get_pet(expected_id)?.ok_or_else(|| {
        PetCoreError::Conflict("base pet was deleted while modification was running".to_string())
    })?;
    if context
        .get("expected_current_petpack_path")
        .and_then(Value::as_str)
        .is_some_and(|expected_path| current.petpack_path != expected_path)
    {
        return Err(PetCoreError::Conflict(
            "base pet changed: the current revision changed while modification was running; the generated revision was not committed"
                .to_string(),
        ));
    }
    let current_sha256 = sha256_file(Path::new(&current.petpack_path))?;
    if current_sha256 != expected_sha256 {
        return Err(PetCoreError::Conflict(
            "base pet changed: the current revision changed while modification was running; the generated revision was not committed"
                .to_string(),
        ));
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn unowned_retry_conflict() -> PetCoreError {
    PetCoreError::Conflict(
        "original edit baseline changed; retry requires the same package bytes submitted by the original edit"
            .to_string(),
    )
}

fn remove_regular_file_if_present(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() || metadata.file_type().is_symlink() => {
            fs::remove_file(path)?;
            Ok(())
        }
        Ok(_) => Err(PetCoreError::Validation(format!(
            "edit baseline snapshot path is not a file: {}",
            path.display()
        ))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

/// Copies one descriptor-bound source observation into the private job
/// workspace and hashes those exact copied bytes. Callers validate and expand
/// only the returned snapshot, so a path replacement cannot move the source
/// between digest validation and staging.
fn stage_stable_petpack_snapshot(
    source_path: &Path,
    snapshot_path: &Path,
    expected_sha256: Option<&str>,
) -> Result<String> {
    let result = (|| {
        let observed = fs::symlink_metadata(source_path)?;
        if !observed.file_type().is_file() || observed.file_type().is_symlink() {
            return Err(PetCoreError::Validation(
                "edit baseline must be a regular non-symlink petpack file".to_string(),
            ));
        }
        let descriptor = rustix::fs::open(
            source_path,
            rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(std::io::Error::from)?;
        let mut source = File::from(descriptor);
        let opened = source.metadata()?;
        if !opened.is_file() || opened.dev() != observed.dev() || opened.ino() != observed.ino() {
            return Err(PetCoreError::Conflict(
                "edit baseline identity changed while opening its snapshot".to_string(),
            ));
        }

        let mut snapshot = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(snapshot_path)?;
        let mut digest = Sha256::new();
        let mut copied = 0u64;
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let read = source.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            snapshot.write_all(&buffer[..read])?;
            digest.update(&buffer[..read]);
            copied = copied.checked_add(read as u64).ok_or_else(|| {
                PetCoreError::Validation("edit baseline size overflow".to_string())
            })?;
        }
        snapshot.sync_all()?;

        let finished = source.metadata()?;
        if copied != opened.len()
            || finished.dev() != opened.dev()
            || finished.ino() != opened.ino()
            || finished.len() != opened.len()
            || finished.mtime() != opened.mtime()
            || finished.mtime_nsec() != opened.mtime_nsec()
            || finished.ctime() != opened.ctime()
            || finished.ctime_nsec() != opened.ctime_nsec()
        {
            return Err(PetCoreError::Conflict(
                "edit baseline changed while its stable snapshot was being staged".to_string(),
            ));
        }

        let actual_sha256 = hex::encode(digest.finalize());
        if expected_sha256.is_some_and(|expected| !actual_sha256.eq_ignore_ascii_case(expected)) {
            return Err(unowned_retry_conflict());
        }
        Ok(actual_sha256)
    })();

    if result.is_err() {
        let _ = fs::remove_file(snapshot_path);
    }
    result
}

#[allow(clippy::large_enum_variant)] // Success carries rollback state; other variants intentionally stay allocation-free.
enum SkillPetpackImport {
    Imported {
        pet: PetSummary,
        previous_pet: Option<PetSummary>,
    },
    Canceled,
    Missing,
    Invalid(String),
}

/// Treat everything written under `petpack-source` by the App Server Skill as
/// one untrusted-input boundary. Metadata normalization checks the source tree
/// before its first write and the complete package contract before import.
/// Failures inside that boundary are therefore source failures, not PetCore
/// execution failures, and must use the same dedicated failure path as
/// validation during import.
fn prepare_and_import_skill_petpack_source(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    form: &GenerationForm,
    app_server_session: &Value,
) -> Result<SkillPetpackImport> {
    if let Err(error) = ensure_skill_full_source_metadata(paths, job_id, form, app_server_session) {
        return Ok(SkillPetpackImport::Invalid(error.to_string()));
    }
    try_import_skill_petpack_source(paths, database, job_id)
}

fn try_import_skill_petpack_source(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
) -> Result<SkillPetpackImport> {
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if !source_dir.join("manifest.json").is_file() {
        return Ok(SkillPetpackImport::Missing);
    }
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(SkillPetpackImport::Canceled);
    }

    match validate_petpack_path(&source_dir) {
        Ok(validation) => {
            if let Some(expected_id) = expected_pet_id(database, job_id)? {
                if validation.manifest.id != expected_id {
                    return Ok(SkillPetpackImport::Invalid(format!(
                        "pet modification must preserve manifest id {expected_id}; got {}",
                        validation.manifest.id
                    )));
                }
            }
            if let Err(error) = validate_skill_source_identity(&source_dir) {
                return Ok(SkillPetpackImport::Invalid(error.to_string()));
            }
            write_petcore_validation_artifact(&source_dir, &validation)?;
            let output = paths
                .jobs_dir
                .join(job_id)
                .join(format!("{}.petpack", validation.manifest.id));
            if finish_if_canceled(paths, database, job_id)? {
                return Ok(SkillPetpackImport::Canceled);
            }
            build_petpack(&source_dir, &output)?;
            if let Some((pet, previous_pet)) = import_petpack_if_active(
                paths,
                database,
                job_id,
                &output,
                Some(&validation.manifest.id),
                PetOrigin::VerifiedSkillSource,
            )? {
                Ok(SkillPetpackImport::Imported { pet, previous_pet })
            } else {
                Ok(SkillPetpackImport::Canceled)
            }
        }
        Err(error) => Ok(SkillPetpackImport::Invalid(error.to_string())),
    }
}

fn validate_skill_source_identity(source_dir: &Path) -> Result<()> {
    let metadata_path = source_dir.join("source").join("source.json");
    let metadata: Value = serde_json::from_slice(&fs::read(&metadata_path)?).map_err(|error| {
        PetCoreError::Validation(format!("invalid Skill source/source.json: {error}"))
    })?;
    let generator = metadata
        .get("generator")
        .and_then(Value::as_str)
        .unwrap_or("");
    let provenance = metadata
        .get("provenance")
        .and_then(Value::as_str)
        .unwrap_or("");
    if metadata
        .get("materialized_by")
        .and_then(Value::as_str)
        .is_some()
    {
        return Err(PetCoreError::Validation(
            "Skill petpack-source must be written by the App Server Skill, not a PetCore or CLI materializer"
                .to_string(),
        ));
    }
    if generator != "codex-app-server-skill" || provenance != "skill-full-source" {
        return Err(PetCoreError::Validation(format!(
            "Skill petpack-source must declare generator=codex-app-server-skill and provenance=skill-full-source, got generator={generator:?}, provenance={provenance:?}"
        )));
    }
    if external_skill_source_required() {
        let preview_only = metadata.get("preview_only").and_then(Value::as_bool);
        if preview_only != Some(false) {
            return Err(PetCoreError::Validation(format!(
                "external full source mode requires preview_only=false, got {preview_only:?}"
            )));
        }
        let visual_source = metadata.get("visual_source").and_then(Value::as_str);
        if !matches!(
            visual_source,
            Some("image-generation" | "user-reference-derived")
        ) {
            return Err(PetCoreError::Validation(format!(
                "external full source mode requires visual_source=image-generation or user-reference-derived, got {visual_source:?}"
            )));
        }
        let frames_per_state = metadata
            .get("frames_per_state")
            .and_then(Value::as_u64)
            .unwrap_or_default();
        if frames_per_state < 2 {
            return Err(PetCoreError::Validation(
                "external full source mode requires at least two frames per state".to_string(),
            ));
        }
        if visual_source == Some("user-reference-derived") {
            let visibly_applied = metadata
                .get("reference_visual_influence")
                .and_then(Value::as_bool)
                == Some(true);
            let has_reference = fs::read_dir(source_dir.join("source/references"))
                .ok()
                .into_iter()
                .flatten()
                .filter_map(std::result::Result::ok)
                .any(|entry| entry.path().is_file());
            if !visibly_applied || !has_reference {
                return Err(PetCoreError::Validation(
                    "user-reference-derived source must copy a reference and declare reference_visual_influence=true"
                        .to_string(),
                ));
            }
        }
        validate_external_frame_diversity(source_dir)?;
    }
    Ok(())
}

fn validate_external_frame_diversity(source_dir: &Path) -> Result<()> {
    let mut state_first_frames = std::collections::BTreeSet::new();
    for state in REQUIRED_STATES {
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
        frames.sort();
        if frames.len() < 2 {
            return Err(PetCoreError::Validation(format!(
                "external full source state {} must contain at least two PNG frames",
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
                "external full source state {} has no visible frame-to-frame change",
                state.as_str()
            )));
        }
        state_first_frames.insert(first);
    }
    if state_first_frames.len() < 4 {
        return Err(PetCoreError::Validation(
            "external full source states are not visually distinct".to_string(),
        ));
    }
    Ok(())
}

fn decoded_frame_digest(path: &Path) -> Result<String> {
    let image = image::open(path)?.to_rgba8();
    let mut hasher = Sha256::new();
    hasher.update(image.width().to_le_bytes());
    hasher.update(image.height().to_le_bytes());
    hasher.update(image.as_raw());
    Ok(hex::encode(hasher.finalize()))
}

fn ensure_skill_full_source_metadata(
    paths: &AppPaths,
    job_id: &str,
    form: &GenerationForm,
    _app_server_session: &Value,
) -> Result<()> {
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if !source_dir.join("manifest.json").is_file() {
        return Ok(());
    }

    // The App Server/skill owns this tree until the turn finishes, so treat it
    // as untrusted input. Check the entire tree before normalization performs
    // its first write; in particular, never let provider-created symlinks turn
    // metadata writes into writes outside the job directory.
    validate_source_tree_budgets(&source_dir)?;
    if skill_full_source_required() {
        validate_petpack_path(&source_dir)?;
    } else {
        normalize_skill_manifest(&source_dir, form)?;
    }
    validate_source_tree_budgets(&source_dir)?;

    let metadata_dir = source_dir.join("source");
    if !metadata_dir.is_dir() || !metadata_dir.join("references").is_dir() {
        return Err(PetCoreError::Validation(
            "skill petpack source must contain real source and source/references directories"
                .to_string(),
        ));
    }

    let metadata_path = metadata_dir.join("source.json");
    let metadata_value: Value = serde_json::from_slice(&fs::read(&metadata_path)?)?;
    let mut metadata = metadata_value.as_object().cloned().ok_or_else(|| {
        PetCoreError::Validation("skill source/source.json must be an object".to_string())
    })?;

    // A .petpack is portable user data, not a Studio execution trace. Keep
    // App Server identifiers in the generation job only; they must never be
    // copied into an exported package.
    for private_key in [
        "codex_app_server",
        "thread_id",
        "turn_id",
        "session_id",
        "request_id",
        "command_source",
    ] {
        metadata.remove(private_key);
    }

    metadata.insert("schema_version".to_string(), json!("apc.pet-source.v1"));
    metadata
        .entry("created_at".to_string())
        .or_insert_with(|| json!(now_rfc3339()));
    metadata
        .entry("reference_files".to_string())
        .or_insert_with(|| json!([]));
    let portable_references = metadata
        .get("reference_files")
        .cloned()
        .unwrap_or_else(|| json!([]));
    // The staged generation form contains job-local absolute paths. Rebuild
    // its portable representation and retain only package-relative references.
    metadata.insert(
        "form".to_string(),
        json!({
            "description": form.description,
            "style": form.style,
            "quality": form.quality,
            "reference_images": portable_references
        }),
    );

    let metadata_value = Value::Object(metadata);
    validate_safe_producer_json_privacy("source/source.json", &metadata_value)?;
    write_json_atomic(&metadata_path, &metadata_value)?;

    let skill_session_path = metadata_dir.join("skill_session.jsonl");
    // Never trust or preserve a provider-written execution trace. The
    // portable package carries only the normalized lifecycle fact needed for
    // provenance; the full Studio session remains in the private job store.
    let portable_event = json!({
        "schema_version": "apc.pet-source-event.v1",
        "event": "skill.loaded",
        "skill": "agent-pet-studio",
        "runner": "codex-app-server",
        "created_at": now_rfc3339()
    });
    validate_safe_producer_json_privacy("source/skill_session.jsonl", &portable_event)?;
    write_file_atomic(
        &skill_session_path,
        (serde_json::to_string(&portable_event)? + "\n").as_bytes(),
    )?;

    // Re-run the complete contract after normalization so malformed or
    // privacy-unsafe nested metadata is rejected before it reaches import.
    validate_petpack_path(&source_dir)?;

    Ok(())
}

fn write_petcore_validation_artifact(
    source_dir: &Path,
    validation: &crate::petpack::PetpackValidation,
) -> Result<()> {
    let build_dir = source_dir.join("build");
    fs::create_dir_all(&build_dir)?;
    let mut artifact = serde_json::to_value(validation)?
        .as_object()
        .cloned()
        .ok_or_else(|| {
            PetCoreError::Validation("PetCore validation artifact must be an object".to_string())
        })?;
    artifact.insert("schema_version".to_string(), json!("apc.pet-validation.v1"));
    artifact.insert("validator".to_string(), json!("petcore"));
    artifact.insert("validated_at".to_string(), json!(now_rfc3339()));
    artifact.insert("manifest_id".to_string(), json!(validation.manifest.id));
    fs::write(
        build_dir.join("validation.json"),
        serde_json::to_vec_pretty(&Value::Object(artifact))?,
    )?;
    Ok(())
}

fn normalize_skill_manifest(source_dir: &Path, form: &GenerationForm) -> Result<()> {
    let manifest_path = source_dir.join("manifest.json");
    let mut manifest_json: Value = serde_json::from_slice(&fs::read(&manifest_path)?)?;
    let Some(manifest) = manifest_json.as_object_mut() else {
        return Ok(());
    };

    manifest.insert("schema_version".to_string(), json!(PETPACK_SCHEMA_VERSION));
    let existing_id = manifest
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("pet")
        .to_string();
    manifest.insert("id".to_string(), json!(normalized_pet_id(&existing_id)));
    if manifest
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
    {
        manifest.insert("name".to_string(), json!(derive_pet_name(form, None)));
    }
    if manifest
        .get("style")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
    {
        manifest.insert("style".to_string(), json!(form.style.clone()));
    }
    manifest.insert("quality".to_string(), json!(form.quality));
    manifest.insert("render_size".to_string(), json!(form.quality.render_size()));
    manifest.insert(
        "fps_profiles".to_string(),
        json!({
            "standard": 12,
            "smooth": 20
        }),
    );
    manifest.insert("default_fps_profile".to_string(), json!("standard"));
    if manifest
        .get("created_at")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .is_none()
    {
        manifest.insert("created_at".to_string(), json!(now_rfc3339()));
    }

    let raw_states = manifest.remove("states");
    manifest.insert("states".to_string(), normalize_manifest_states(raw_states));

    write_json_atomic(&manifest_path, &manifest_json)?;
    Ok(())
}

fn normalized_pet_id(raw_id: &str) -> String {
    let mut suffix = raw_id
        .trim()
        .trim_start_matches("pet_")
        .chars()
        .filter_map(|character| {
            let lowercase = character.to_ascii_lowercase();
            lowercase.is_ascii_alphanumeric().then_some(lowercase)
        })
        .take(48)
        .collect::<String>();
    if suffix.is_empty() {
        return new_id("pet");
    }
    suffix.insert_str(0, "pet_");
    suffix
}

fn normalize_manifest_states(raw_states: Option<Value>) -> Value {
    Value::Array(
        REQUIRED_STATES
            .iter()
            .map(|state| {
                let source = state_value(raw_states.as_ref(), state.as_str());
                let frames_dir = source
                    .and_then(|value| value.get("frames_dir").or_else(|| value.get("framesDir")))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| default_frames_dir(state.as_str()));
                let looped = source
                    .and_then(|value| value.get("loop").or_else(|| value.get("looped")))
                    .and_then(Value::as_bool)
                    .unwrap_or_else(|| default_state_loop(state.as_str()));
                json!({
                    "name": state.as_str(),
                    "frames_dir": frames_dir,
                    "loop": looped
                })
            })
            .collect(),
    )
}

fn state_value<'a>(states: Option<&'a Value>, state_name: &str) -> Option<&'a Value> {
    match states {
        Some(Value::Object(map)) => map.get(state_name),
        Some(Value::Array(values)) => values.iter().find(|value| {
            value
                .get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| name == state_name)
        }),
        _ => None,
    }
}

fn default_frames_dir(state_name: &str) -> &'static str {
    match state_name {
        "idle" => "assets/frames/idle",
        "start" => "assets/frames/start",
        "tool" => "assets/frames/tool",
        "waiting" => "assets/frames/waiting",
        "review" => "assets/frames/review",
        "done" => "assets/frames/done",
        "failed" => "assets/frames/failed",
        _ => "assets/frames/idle",
    }
}

fn default_state_loop(state_name: &str) -> bool {
    !matches!(state_name, "start" | "done")
}

fn materialize_internal_skill_petpack(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    form: &GenerationForm,
    app_server_session: &Value,
) -> Result<Option<(PetSummary, Option<PetSummary>)>> {
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(None);
    }
    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    if source_dir.exists() {
        fs::remove_dir_all(&source_dir)?;
    }
    let pet_name = derive_pet_name(form, app_server_session.get("ai_brief"));
    let manifest = write_skill_generated_petpack_dir(
        &source_dir,
        form,
        &pet_name,
        app_server_session.get("ai_brief"),
        GENERATED_FRAMES_PER_STATE,
    )?;
    let manifest = apply_expected_pet_identity(paths, database, job_id, &source_dir, manifest)?;
    mark_internal_skill_materializer(&source_dir)?;
    write_skill_session(
        paths,
        job_id,
        &source_dir,
        form,
        &manifest,
        app_server_session,
    )?;
    let output = paths
        .jobs_dir
        .join(job_id)
        .join(format!("{}.petpack", manifest.id));
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(None);
    }
    let validation = build_petpack(&source_dir, &output)?;
    import_petpack_if_active(
        paths,
        database,
        job_id,
        &output,
        Some(&validation.manifest.id),
        PetOrigin::GeneratedByPetcoreJob,
    )
}

fn mark_internal_skill_materializer(source_dir: &Path) -> Result<()> {
    let source_path = source_dir.join("source").join("source.json");
    let mut source = fs::read(&source_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    source.insert(
        "materialized_by".to_string(),
        json!("petcore-internal-skill-materializer"),
    );
    fs::write(
        source_path,
        serde_json::to_vec_pretty(&Value::Object(source))?,
    )?;

    let validation_path = source_dir.join("build").join("validation.json");
    if validation_path.is_file() {
        let mut validation = fs::read(&validation_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|value| value.as_object().cloned())
            .unwrap_or_default();
        validation.insert(
            "materialized_by".to_string(),
            json!("petcore-internal-skill-materializer"),
        );
        fs::write(
            validation_path,
            serde_json::to_vec_pretty(&Value::Object(validation))?,
        )?;
    }
    Ok(())
}

fn import_petpack_if_active(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    source_path: &Path,
    pet_id_hint: Option<&str>,
    origin: PetOrigin,
) -> Result<Option<(PetSummary, Option<PetSummary>)>> {
    if finish_if_canceled(paths, database, job_id)? {
        return Ok(None);
    }
    let store_guard = PetStoreGuard::acquire(paths)?;
    let output_validation = validate_petpack_path(source_path)?;
    ensure_edit_commit_preconditions(paths, database, job_id, &output_validation.manifest)?;
    let previous_pet = match pet_id_hint {
        Some(pet_id) => database.get_pet(pet_id)?,
        None => None,
    };
    let pet =
        import_petpack_with_origin_guarded(paths, database, source_path, origin, &store_guard)?;
    // Cancellation rollback owns the same store lock, so release the guarded
    // stale-check/commit section before entering that independent mutation.
    drop(store_guard);
    if finish_if_canceled(paths, database, job_id)? {
        cleanup_canceled_import(paths, database, &pet, previous_pet.as_ref())?;
        return Ok(None);
    }
    Ok(Some((pet, previous_pet)))
}

fn cleanup_canceled_import(
    paths: &AppPaths,
    database: &Database,
    pet: &PetSummary,
    previous_pet: Option<&PetSummary>,
) -> Result<()> {
    rollback_imported_revision(paths, database, pet, previous_pet)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)] // Atomic completion keeps lifecycle and rollback inputs explicit.
fn complete_imported_pet(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    pet: &PetSummary,
    previous_pet: Option<&PetSummary>,
    pre_completion_message: Option<(&str, f64)>,
    completion_message: &str,
) -> Result<()> {
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        cleanup_canceled_import(paths, database, pet, previous_pet)?;
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(());
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status)
    {
        cleanup_canceled_import(paths, database, pet, previous_pet)?;
        return Ok(());
    }
    if let Some((content, progress)) = pre_completion_message {
        append_progress_message(paths, database, job_id, "assistant", content, progress)?;
    }
    // Persist the result before the terminal transition. The following
    // completed message commits the job status and advances the authoritative
    // message revision atomically, so a long-poll can never observe a terminal
    // revision without the matching durable result.
    write_generation_result(paths, job_id, pet)?;
    append_completed_message(
        paths,
        database,
        job_id,
        "assistant",
        completion_message,
        &pet.id,
    )?;
    Ok(())
}

fn write_generation_result(paths: &AppPaths, job_id: &str, pet: &PetSummary) -> Result<()> {
    let mut enriched = [pet.clone()];
    enrich_pet_revision_metadata(paths, &mut enriched)?;
    let revision_id = enriched[0].revision_id.clone().ok_or_else(|| {
        PetCoreError::Validation(
            "completed generation result is missing its owned immutable revision".to_string(),
        )
    })?;
    let validation = validate_petpack_path(Path::new(&pet.petpack_path))?;
    let result = GenerationResultSummary {
        result_pet_id: pet.id.clone(),
        revision_id,
        validation_summary: GenerationValidationSummary {
            ok: validation.ok,
            state_count: validation.manifest.states.len(),
            frame_count: validation.frame_count,
            warning_count: validation.warnings.len(),
        },
    };
    let path = paths.jobs_dir.join(job_id).join(GENERATION_RESULT_FILENAME);
    write_json_atomic(&path, &serde_json::to_value(result)?)
}

fn stage_reference_images(
    paths: &AppPaths,
    job_id: &str,
    form: &GenerationForm,
) -> Result<GenerationForm> {
    let job_dir = paths.jobs_dir.join(job_id);
    let reference_dir = job_dir.join("input").join("references");
    let references = stage_reference_inputs(&form.reference_images, &reference_dir)?;
    let staged_paths = references
        .into_iter()
        .map(|reference| reference.source.display().to_string())
        .collect();

    let mut staged = form.clone();
    staged.reference_images = staged_paths;
    fs::write(
        job_dir.join("form.staged.json"),
        serde_json::to_vec_pretty(&staged)?,
    )?;
    Ok(staged)
}

fn app_server_session_path(paths: &AppPaths, job_id: &str) -> std::path::PathBuf {
    paths.jobs_dir.join(job_id).join("app_server_session.json")
}

fn read_app_server_session(paths: &AppPaths, job_id: &str) -> Result<Option<Value>> {
    let path = app_server_session_path(paths, job_id);
    if !path.is_file() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_slice(&fs::read(path)?)?))
}

fn write_app_server_session(paths: &AppPaths, job_id: &str, session: &Value) -> Result<()> {
    let path = app_server_session_path(paths, job_id);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    write_json_atomic(&path, session)?;
    Ok(())
}

fn write_json_atomic(path: &Path, value: &Value) -> Result<()> {
    write_file_atomic(path, &serde_json::to_vec_pretty(value)?)
}

fn write_file_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let temporary_path = path.with_extension(format!(
        "{}.tmp.{}",
        path.extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("data"),
        new_id("write")
    ));
    let mut temporary = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary_path)?;
    temporary.write_all(bytes)?;
    temporary.sync_all()?;
    drop(temporary);
    fs::rename(&temporary_path, path).inspect_err(|_error| {
        let _ = fs::remove_file(&temporary_path);
    })?;
    Ok(())
}

fn append_ai_brief_normalization_message(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    session: &Value,
    progress: f64,
) -> Result<()> {
    let warning_count = session
        .get("ai_brief_warnings")
        .and_then(serde_json::Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    if warning_count > 0 {
        append_progress_message_if_active(
            paths,
            database,
            job_id,
            "assistant",
            &format!("Codex brief 缺少 {warning_count} 项约束，已按固定 7 状态 petpack 契约补齐后继续渲染。"),
            progress,
        )?;
    }
    Ok(())
}

fn pause_generation_for_input_request(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    session: &Value,
    progress: f64,
) -> Result<bool> {
    let Some(question) = app_server::input_request_question(session) else {
        return Ok(false);
    };
    let _lifecycle = lifecycle_lock();
    if is_generation_canceled(paths, job_id) {
        mark_canceled_locked(paths, database, job_id)?;
        return Ok(true);
    }
    if database
        .generation_job_status(job_id)?
        .is_some_and(is_terminal_status)
    {
        return Ok(true);
    }
    append_message_with_kind(
        paths,
        database,
        job_id,
        "assistant",
        &question,
        progress,
        Some(KIND_INPUT_REQUEST),
        Some(GenerationJobStatus::WaitingForUser),
        None,
    )?;
    Ok(true)
}

fn should_retry_revision_with_new_session(session: &Value) -> bool {
    if session
        .get("thread_id")
        .and_then(serde_json::Value::as_str)
        .is_none()
    {
        return true;
    }
    let error = session
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    error.contains("thread/resume")
        || error.contains("thread not found")
        || error.contains("no rollout found")
}

fn app_server_failure_detail(session: &Value) -> &str {
    session
        .get("error")
        .or_else(|| session.get("detail"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("Codex App Server 暂不可用")
}

fn app_server_completed(session: &Value) -> bool {
    session.get("completed").and_then(Value::as_bool) == Some(true)
}

fn local_pet_studio_fallback_enabled() -> bool {
    std::env::var("APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn skill_full_source_required() -> bool {
    std::env::var("APC_REQUIRE_SKILL_FULL_SOURCE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn external_skill_source_required() -> bool {
    std::env::var("APC_REQUIRE_EXTERNAL_SKILL_SOURCE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn form_with_revision_feedback(form: &GenerationForm, user_message: &str) -> GenerationForm {
    let mut adjusted = form.clone();
    adjusted.description = format!(
        "{}\n\n用户调整意见：{}",
        form.description.trim(),
        user_message.trim()
    );
    adjusted
}

fn write_skill_session(
    _paths: &AppPaths,
    _job_id: &str,
    source_dir: &std::path::Path,
    _form: &GenerationForm,
    manifest: &PetManifest,
    app_server_session: &serde_json::Value,
) -> Result<()> {
    let source_dir_path = source_dir.join("source");
    fs::create_dir_all(&source_dir_path)?;
    let skill_session_path = source_dir_path.join("skill_session.jsonl");
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&skill_session_path)?;
    let states = REQUIRED_STATES
        .iter()
        .map(|state| state.as_str())
        .collect::<Vec<_>>();
    let runner = if app_server_session
        .get("started")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        "codex-app-server"
    } else {
        "local-pet-studio-runner"
    };
    let reference_count = petpack_reference_files(source_dir)?.len();
    let mut events = vec![
        json!({
            "schema_version": "apc.pet-source-event.v1",
            "event": "skill.loaded",
            "skill": "agent-pet-studio",
            "runner": runner,
            "created_at": now_rfc3339()
        }),
        json!({
            "schema_version": "apc.pet-source-event.v1",
            "event": "form.read",
            "skill": "agent-pet-studio",
            "reference_count": reference_count,
            "created_at": now_rfc3339()
        }),
        json!({
            "schema_version": "apc.pet-source-event.v1",
            "event": "brief.generated",
            "skill": "agent-pet-studio",
            "manifest_id": manifest.id,
            "name": manifest.name,
            "style": manifest.style,
            "quality": manifest.quality,
            "render_size": manifest.render_size,
            "created_at": now_rfc3339()
        }),
        json!({
            "schema_version": "apc.pet-source-event.v1",
            "event": "states.rendered",
            "skill": "agent-pet-studio",
            "states": states,
            "frames_per_state": GENERATED_FRAMES_PER_STATE,
            "fps_profiles": manifest.fps_profiles,
            "created_at": now_rfc3339()
        }),
        json!({
            "schema_version": "apc.pet-source-event.v1",
            "event": "petpack.validated",
            "skill": "agent-pet-studio",
            "created_at": now_rfc3339()
        }),
    ];

    if app_server_session
        .get("started")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        events.insert(
            1,
            json!({
                "schema_version": "apc.pet-source-event.v1",
                "event": "codex_thread.started",
                "skill": "agent-pet-studio",
                "created_at": now_rfc3339()
            }),
        );
    }

    if app_server_session
        .get("turn_started")
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        let event_name = if app_server_session
            .get("follow_up")
            .and_then(serde_json::Value::as_bool)
            == Some(true)
        {
            "codex_followup_turn.completed"
        } else {
            "codex_turn.completed"
        };
        events.insert(
            2,
            json!({
                "schema_version": "apc.pet-source-event.v1",
                "event": event_name,
                "skill": "agent-pet-studio",
                "completed": app_server_session.get("completed"),
                "created_at": now_rfc3339()
            }),
        );
    }

    for event in events {
        writeln!(file, "{}", serde_json::to_string(&event)?)?;
    }

    Ok(())
}

fn petpack_reference_files(source_dir: &std::path::Path) -> Result<Vec<String>> {
    let source_json_path = source_dir.join("source").join("source.json");
    if !source_json_path.is_file() {
        return Ok(Vec::new());
    }
    let source_json: Value = serde_json::from_slice(&fs::read(source_json_path)?)?;
    Ok(source_json
        .get("reference_files")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default())
}

fn derive_pet_name(form: &GenerationForm, ai_brief: Option<&serde_json::Value>) -> String {
    if let Some(name) = ai_brief
        .and_then(|brief| brief.get("name"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
    {
        return name.chars().take(16).collect();
    }

    let trimmed = form.description.trim();
    if trimmed.is_empty() {
        return "自定义桌宠".to_string();
    }

    let stop_chars = ['，', '。', ',', '.', '、', '\n', '\r', ';', '；'];
    let first_phrase = trimmed
        .split(|character| stop_chars.contains(&character))
        .next()
        .unwrap_or(trimmed)
        .trim();
    let name: String = first_phrase
        .chars()
        .filter(|character| !character.is_whitespace())
        .take(12)
        .collect();
    if name.is_empty() {
        "自定义桌宠".to_string()
    } else {
        name
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn edit_context_reader_rejects_oversized_and_symlinked_files() {
        let temp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(temp.path().join("home"));
        let job_dir = paths.jobs_dir.join("job_context_bounds");
        fs::create_dir_all(&job_dir).unwrap();
        let context_path = job_dir.join("edit-context.json");

        let oversized = File::create(&context_path).unwrap();
        oversized.set_len(MAX_EDIT_CONTEXT_BYTES + 1).unwrap();
        drop(oversized);
        assert!(matches!(
            read_edit_context(&paths, "job_context_bounds"),
            Err(PetCoreError::Validation(_))
        ));

        fs::remove_file(&context_path).unwrap();
        let external = temp.path().join("private-context.json");
        fs::write(&external, br#"{"baseline_revision_id":null}"#).unwrap();
        symlink(&external, &context_path).unwrap();
        assert!(matches!(
            read_edit_context(&paths, "job_context_bounds"),
            Err(PetCoreError::Validation(_))
        ));
    }
}
