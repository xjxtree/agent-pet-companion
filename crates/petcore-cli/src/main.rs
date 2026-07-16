use petcore::adapter_contracts::{parse_contract_event, ContractEvent};
use petcore::connections;
use petcore::daemon;
use petcore::daemon::instance_lock::InstanceGuard;
use petcore::db::Database;
use petcore::event_envelope::NormalizedAgentEvent;
use petcore::launch_agent::{self, LaunchAgentConfig};
use petcore::paths::AppPaths;
use petcore::petpack;
use petcore::{enum_from_name, enum_name, now_rfc3339, PetCoreError, Result};
use petcore_types::{AgentEventType, AgentSource, FpsProfileName, GenerationForm, QualityLevel};
use serde_json::{json, Value};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        return Ok(());
    }

    let command = args.remove(0);
    match command.as_str() {
        "health" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "petcore.health",
            json!({}),
        )?),
        "state" => run_state(args),
        "snapshot" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "state.snapshot",
            json!({}),
        )?),
        "agent" => run_agent(args),
        "behavior" => run_behavior(args),
        "pet" => run_pet(args),
        "petpack" => run_petpack(args),
        "generation" => run_generation(args),
        "connections" => run_connections(args),
        "events" => run_events(args),
        "renderer" => run_renderer(args),
        "launch-agent" => run_launch_agent(args),
        "overlay" => run_overlay(args),
        "codex" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "codex.app_server.probe",
            json!({}),
        )?),
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown command {other}"
        ))),
    }
}

fn run_state(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "state subcommand")?;
    match subcommand.as_str() {
        "snapshot" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "state.snapshot",
            json!({}),
        )?),
        "wait" => {
            let after_revision = flag_optional(&mut args, "--after-revision").unwrap_or_default();
            let timeout_ms = flag_optional(&mut args, "--timeout-ms")
                .unwrap_or_else(|| "30000".to_string())
                .parse::<u64>()
                .map_err(|error| {
                    PetCoreError::InvalidRequest(format!("invalid --timeout-ms: {error}"))
                })?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "state.wait",
                json!({
                    "after_revision": after_revision,
                    "timeout_ms": timeout_ms
                }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown state subcommand {other}"
        ))),
    }
}

fn run_overlay(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "overlay subcommand")?;
    match subcommand.as_str() {
        "placement" => run_overlay_placement(args),
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown overlay subcommand {other}"
        ))),
    }
}

fn run_overlay_placement(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "overlay placement subcommand")?;
    match subcommand.as_str() {
        "get" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "overlay.placement.get",
            json!({}),
        )?),
        "set" => {
            let x = flag(&mut args, "--x")?
                .parse::<f64>()
                .map_err(|error| PetCoreError::InvalidRequest(format!("invalid --x: {error}")))?;
            let y = flag(&mut args, "--y")?
                .parse::<f64>()
                .map_err(|error| PetCoreError::InvalidRequest(format!("invalid --y: {error}")))?;
            let scale = flag(&mut args, "--scale")?
                .parse::<f64>()
                .map_err(|error| {
                    PetCoreError::InvalidRequest(format!("invalid --scale: {error}"))
                })?;
            let display_id =
                flag_optional(&mut args, "--display-id").unwrap_or_else(|| "main".to_string());
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "overlay.placement.update",
                json!({
                    "x": x,
                    "y": y,
                    "scale": scale,
                    "display_id": display_id
                }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown overlay placement subcommand {other}"
        ))),
    }
}

fn run_agent(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "agent subcommand")?;
    match subcommand.as_str() {
        "ingest" => {
            let source = flag(&mut args, "--source")?;
            let event_type_arg = flag(&mut args, "--event-type")?;
            let payload = flag_optional(&mut args, "--payload-json")
                .map(|value| serde_json::from_str(&value))
                .transpose()?
                .unwrap_or_else(|| json!({}));
            let event_kind = infer_event_type(Some(&event_type_arg), &payload, None, None)?;
            let event_type = enum_name(event_kind);
            let title = flag_optional(&mut args, "--title")
                .unwrap_or_else(|| event_kind.zh_label().to_string());
            let detail = flag_optional(&mut args, "--detail");
            let id = flag_optional(&mut args, "--id");
            let project_path = flag_optional(&mut args, "--project-path");
            let session_id = flag_optional(&mut args, "--session-id");
            let request = normalized_agent_request(
                &source,
                json!({
                    "id": id,
                    "event_type": event_type,
                    "title": title,
                    "detail": detail,
                    "project_path": project_path,
                    "session_id": session_id,
                    "payload": payload
                }),
            )?;
            let result = daemon::request(&AppPaths::from_env()?, "agent.ingest", request)?;
            print_json(result)
        }
        "hook" => {
            let source = flag(&mut args, "--source")?;
            let event_type_arg = flag_optional(&mut args, "--event-type");
            // Legacy flags are accepted so older installed hooks keep working,
            // but their arbitrary text is never forwarded or persisted.
            let _title_arg = flag_optional(&mut args, "--title");
            let _detail_arg = flag_optional(&mut args, "--detail");
            let mut stdin = String::new();
            io::stdin().read_to_string(&mut stdin)?;
            let payload = hook_payload_from_stdin(&stdin);
            let Some(contract) =
                contract_event_for_hook(&source, event_type_arg.as_deref(), &payload)?
            else {
                return print_json(json!({ "ok": true, "ignored": true }));
            };
            let request = normalized_contract_request(&contract)?;
            let result = daemon::request(&AppPaths::from_env()?, "agent.ingest", request)?;
            print_json(result)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown agent subcommand {other}"
        ))),
    }
}

fn normalized_agent_request(source: &str, value: Value) -> Result<Value> {
    let source = enum_from_name::<AgentSource>(source)?;
    let event = NormalizedAgentEvent::from_external(source, value, &now_rfc3339())?;
    serde_json::to_value(event).map_err(Into::into)
}

fn normalized_contract_request(contract: &ContractEvent) -> Result<Value> {
    let event_type = enum_name(contract.kind);
    let source = enum_name(contract.source);
    normalized_agent_request(
        &source,
        json!({
            "id": null,
            "source": contract.source,
            "event_type": event_type,
            "title": contract.kind.zh_label(),
            "detail": null,
            "project_path": null,
            "session_id": contract.session_id,
            "payload": {
                "source_event": contract.source_event,
                "tool_name": contract.tool_name,
                "outcome": contract.outcome,
                "diagnostic": contract.diagnostic,
                "turn_id": contract.turn_id,
                "session_active": contract.session_active,
                "message_role": contract.message_role,
                "message_content": contract.message_content,
                "activity_kind": contract.activity_kind,
                "activity_content": contract.activity_content,
                "interaction_kind": contract.interaction_kind,
                "project_label": contract.project_label,
                "session_title": contract.session_title,
                "session_open": contract.session_open,
                "session_surface": contract.session_surface,
                "terminal_app": contract.terminal_app,
                "session_open_url": contract.session_open_url
            }
        }),
    )
}

fn run_behavior(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "behavior subcommand")?;
    match subcommand.as_str() {
        "get" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "behavior.get",
            json!({}),
        )?),
        "set-json" => {
            let value_json = flag(&mut args, "--value-json")?;
            let value: serde_json::Value = serde_json::from_str(&value_json)?;
            let current = daemon::request(&AppPaths::from_env()?, "behavior.get", json!({}))?;
            let expected_revision =
                current
                    .get("revision")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        PetCoreError::Validation(
                            "behavior.get response is missing revision".to_string(),
                        )
                    })?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "behavior.patch",
                json!({
                    "expected_revision": expected_revision,
                    "changes": value,
                }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown behavior subcommand {other}"
        ))),
    }
}

fn run_pet(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "pet subcommand")?;
    match subcommand.as_str() {
        "list" => print_json(daemon::request(
            &AppPaths::from_env()?,
            "pet.list",
            json!({}),
        )?),
        "activate" => {
            let id = flag_optional(&mut args, "--id")
                .unwrap_or_else(|| pop(&mut args, "pet id").unwrap_or_else(|_| String::new()));
            if id.is_empty() {
                return Err(PetCoreError::InvalidRequest(
                    "missing pet activate id".to_string(),
                ));
            }
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "pet.activate",
                json!({ "id": id }),
            )?)
        }
        "delete" => {
            let id = flag_optional(&mut args, "--id")
                .unwrap_or_else(|| pop(&mut args, "pet id").unwrap_or_else(|_| String::new()));
            if id.is_empty() {
                return Err(PetCoreError::InvalidRequest(
                    "missing pet delete id".to_string(),
                ));
            }
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "pet.delete",
                json!({ "id": id }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown pet subcommand {other}"
        ))),
    }
}

fn run_petpack(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "petpack subcommand")?;
    match subcommand.as_str() {
        "sample" => {
            let output = PathBuf::from(flag(&mut args, "--output")?);
            let quality = parse_quality(
                &flag_optional(&mut args, "--quality").unwrap_or_else(|| "high".to_string()),
            )?;
            let name =
                flag_optional(&mut args, "--name").unwrap_or_else(|| "Cloud Maiden".to_string());
            let style = flag_optional(&mut args, "--style").unwrap_or_else(|| "半写实".to_string());
            let frames = flag_optional(&mut args, "--frames")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(2);
            let manifest =
                petpack::write_sample_petpack_dir(&output, quality, &name, &style, frames)?;
            print_json(json!({ "ok": true, "manifest": manifest }))
        }
        "materialize" => {
            let output = PathBuf::from(flag(&mut args, "--output")?);
            let form_json = flag(&mut args, "--form-json")?;
            let form: GenerationForm = serde_json::from_str(&form_json)?;
            let name = flag_optional(&mut args, "--name")
                .unwrap_or_else(|| derive_materialized_pet_name(&form));
            let ai_brief = flag_optional(&mut args, "--ai-brief-json")
                .map(|brief| serde_json::from_str::<Value>(&brief))
                .transpose()?;
            let frames = flag_optional(&mut args, "--frames")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(petpack::GENERATED_FRAMES_PER_STATE);
            let manifest = petpack::write_generated_petpack_dir(
                &output,
                &form,
                &name,
                ai_brief.as_ref(),
                frames,
            )?;
            if let Some(generator) = flag_optional(&mut args, "--generator") {
                let provenance = flag_optional(&mut args, "--provenance")
                    .unwrap_or_else(|| "cli_materialized".to_string());
                if generator == "codex-app-server-skill" && provenance == "skill-full-source" {
                    return Err(PetCoreError::InvalidRequest(
                        "petcore-cli materialize cannot declare trusted skill-full-source provenance"
                            .to_string(),
                    ));
                }
                rewrite_materialized_provenance(&output, &generator, &provenance)?;
            } else {
                let (generator, provenance) = materialized_source_identity(&output)?;
                write_materialized_session(&output, &generator, &provenance)?;
            }
            print_json(json!({ "ok": true, "manifest": manifest }))
        }
        "validate" => {
            let path = PathBuf::from(pop(&mut args, "petpack path")?);
            print_json(json!(petpack::validate_petpack_path(&path)?))
        }
        "build" => {
            let input = PathBuf::from(flag(&mut args, "--input")?);
            let output = PathBuf::from(flag(&mut args, "--output")?);
            let validation = petpack::build_petpack(&input, &output)?;
            print_json(json!({ "ok": true, "output": output, "validation": validation }))
        }
        "import" => {
            let offline = flag_present(&mut args, "--offline");
            let expect_absent = flag_present(&mut args, "--expect-absent");
            let path = PathBuf::from(pop(&mut args, "petpack path")?);
            reject_extra_args(&args, "petpack import")?;
            let paths = AppPaths::from_env()?;
            if offline {
                let _instance_guard = InstanceGuard::acquire(&paths)?;
                paths.ensure()?;
                let database = petcore::db::Database::new(paths.db_path.clone());
                database.init()?;
                let pet = if expect_absent {
                    petpack::import_petpack_expecting_absent(&paths, &database, &path)?
                } else {
                    petpack::import_petpack(&paths, &database, &path)?
                };
                print_json(json!(pet))
            } else {
                print_json(daemon::request(
                    &paths,
                    "petpack.import",
                    json!({
                        "path": path.display().to_string(),
                        "expect_absent": expect_absent,
                    }),
                )?)
            }
        }
        "export" => {
            let offline = flag_present(&mut args, "--offline");
            let id = flag(&mut args, "--id")?;
            let output = PathBuf::from(flag(&mut args, "--output")?);
            reject_extra_args(&args, "petpack export")?;
            let paths = AppPaths::from_env()?;
            if offline {
                let _instance_guard = InstanceGuard::acquire(&paths)?;
                paths.ensure()?;
                let database = petcore::db::Database::new(paths.db_path.clone());
                database.init()?;
                print_json(json!(petpack::export_petpack(
                    &paths, &database, &id, &output
                )?))
            } else {
                print_json(daemon::request(
                    &paths,
                    "petpack.export",
                    json!({
                        "id": id,
                        "path": output.display().to_string()
                    }),
                )?)
            }
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown petpack subcommand {other}"
        ))),
    }
}

fn run_generation(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "generation subcommand")?;
    match subcommand.as_str() {
        "start" => {
            let form_json = flag(&mut args, "--form-json")?;
            let form: serde_json::Value = serde_json::from_str(&form_json)?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "generation.start",
                form,
            )?)
        }
        "messages" => {
            let job_id = flag(&mut args, "--job-id")?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "generation.messages",
                json!({ "job_id": job_id }),
            )?)
        }
        "retry" => {
            let job_id = flag(&mut args, "--job-id")?;
            let form = flag_optional(&mut args, "--form-json")
                .map(|form_json| serde_json::from_str::<serde_json::Value>(&form_json))
                .transpose()?;
            reject_extra_args(&args, "generation retry")?;
            let mut params = json!({ "job_id": job_id });
            if let Some(form) = form {
                params["form"] = form;
            }
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "generation.retry",
                params,
            )?)
        }
        "status" => {
            let job_id = flag(&mut args, "--job-id")?;
            let include_messages = flag_present(&mut args, "--include-messages");
            reject_extra_args(&args, "generation status")?;
            print_json(generation_status(&job_id, include_messages)?)
        }
        "for-pet" => {
            let pet_id = flag(&mut args, "--pet-id")?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "generation.for_pet",
                json!({ "pet_id": pet_id }),
            )?)
        }
        "reply" => {
            let job_id = flag(&mut args, "--job-id")?;
            let content = flag(&mut args, "--content")?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "generation.reply",
                json!({ "job_id": job_id, "content": content }),
            )?)
        }
        "cancel" => {
            let job_id = flag(&mut args, "--job-id")?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "generation.cancel",
                json!({ "job_id": job_id }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown generation subcommand {other}"
        ))),
    }
}

fn generation_status(job_id: &str, include_messages: bool) -> Result<Value> {
    let paths = AppPaths::from_env()?;
    let job_dir = paths.jobs_dir.join(job_id);
    if !job_dir.is_dir() {
        return Err(PetCoreError::InvalidRequest(format!(
            "generation job not found: {job_id}"
        )));
    }

    let status = if paths.db_path.is_file() {
        Database::new(paths.db_path.clone())
            .generation_job_status(job_id)?
            .map(enum_name)
    } else {
        None
    };
    let messages = petcore::generation::read_messages(&paths, job_id)?;
    let latest_message = messages.last().cloned();
    let session_path = job_dir.join("app_server_session.json");
    let app_server_session = read_optional_json(&session_path)?;
    let source_dir = job_dir.join("petpack-source");
    let manifest_path = source_dir.join("manifest.json");
    let source_manifest = read_optional_json(&manifest_path)?;
    let source_metadata_path = source_dir.join("source").join("source.json");
    let source_metadata = read_optional_json(&source_metadata_path)?;
    let skill_session_path = source_dir.join("source").join("skill_session.jsonl");
    let validation_path = source_dir.join("build").join("validation.json");
    let source_validation = read_optional_json(&validation_path)?;
    let petpack_files = list_petpack_files(&job_dir)?;

    let app_server = summarize_app_server_session(&session_path, app_server_session.as_ref());
    let artifacts = summarize_generation_artifacts(
        &source_dir,
        &manifest_path,
        source_manifest.as_ref(),
        &source_metadata_path,
        source_metadata.as_ref(),
        &skill_session_path,
        &validation_path,
        source_validation.as_ref(),
        &petpack_files,
    );
    let actions = generation_status_actions(
        status.as_deref(),
        app_server_session.as_ref(),
        source_manifest.as_ref(),
        &petpack_files,
    );

    let mut value = json!({
        "ok": true,
        "job_id": job_id,
        "status": status.unwrap_or_else(|| "unknown".to_string()),
        "job_dir": path_string(&job_dir),
        "messages_count": messages.len(),
        "latest_message": latest_message,
        "app_server": app_server,
        "artifacts": artifacts,
        "actions": actions,
    });
    if include_messages {
        if let Some(object) = value.as_object_mut() {
            object.insert("messages".to_string(), Value::Array(messages));
        }
    }
    Ok(value)
}

fn summarize_app_server_session(path: &Path, session: Option<&Value>) -> Value {
    let Some(session) = session else {
        return json!({
            "path": path_string(path),
            "exists": false,
        });
    };

    let ai_brief = session.get("ai_brief");
    json!({
        "path": path_string(path),
        "exists": true,
        "initialized": session.get("initialized"),
        "started": session.get("started"),
        "resumed": session.get("resumed"),
        "turn_started": session.get("turn_started"),
        "completed": session.get("completed"),
        "needs_input": session.get("needs_input"),
        "thread_id": session.get("thread_id"),
        "session_id": session.get("session_id"),
        "turn_id": session.get("turn_id"),
        "command_source": session.get("command_source"),
        "error": session.get("error"),
        "error_info": session.get("error_info"),
        "ai_brief": {
            "name": ai_brief.and_then(|brief| brief.get("name")),
            "states_count": ai_brief
                .and_then(|brief| brief.get("states"))
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0),
            "warnings_count": session
                .get("ai_brief_warnings")
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0),
        }
    })
}

#[allow(clippy::too_many_arguments)] // Read-only artifact summary mirrors the independent filesystem probes.
fn summarize_generation_artifacts(
    source_dir: &Path,
    manifest_path: &Path,
    source_manifest: Option<&Value>,
    source_metadata_path: &Path,
    source_metadata: Option<&Value>,
    skill_session_path: &Path,
    validation_path: &Path,
    source_validation: Option<&Value>,
    petpack_files: &[PathBuf],
) -> Value {
    let manifest_id = source_manifest.and_then(|manifest| manifest.get("id"));
    let generator = source_metadata
        .and_then(|metadata| metadata.get("generator"))
        .and_then(Value::as_str);
    let provenance = source_metadata
        .and_then(|metadata| metadata.get("provenance"))
        .and_then(Value::as_str);
    let materialized_by_cli = source_metadata
        .and_then(|metadata| metadata.get("materialized_by"))
        .and_then(Value::as_str)
        == Some("petcore-cli");
    let materializer = source_metadata
        .and_then(|metadata| metadata.get("materialized_by"))
        .and_then(Value::as_str);
    let skill_helper = source_metadata
        .and_then(|metadata| metadata.get("skill_helper"))
        .and_then(Value::as_str);
    let materialized_by_petcore = materializer == Some("petcore-internal-skill-materializer");
    let deterministic_preview = is_deterministic_preview(generator, provenance);
    let real_skill_source = generator == Some("codex-app-server-skill")
        && provenance == Some("skill-full-source")
        && materializer.is_none()
        && !deterministic_preview;
    let fallback_used = deterministic_preview
        || matches!(
            provenance,
            Some(
                "codex_app_server_brief"
                    | "local_form"
                    | "test_fixture"
                    | "app_server_cli_materialized"
                    | "cli_materialized"
            )
        );
    let sample_output = generator.is_some_and(|value| value.contains("sample"))
        || provenance == Some("test_fixture")
        || deterministic_preview;
    let diagnostics = if deterministic_preview {
        vec![json!({
            "code": "deterministic_preview",
            "severity": "warning",
            "detail": "This artifact is deterministic preview output, not real skill/image-generated source."
        })]
    } else {
        Vec::new()
    };
    json!({
        "petpack_source": {
            "path": path_string(source_dir),
            "exists": source_dir.is_dir(),
            "generation_mode": generation_mode(generator, provenance, materializer),
            "real_skill_source": real_skill_source,
            "fallback_used": fallback_used,
            "preview_output": deterministic_preview,
            "materialized_by_cli": materialized_by_cli,
            "materialized_by_petcore": materialized_by_petcore,
            "materializer": materializer,
            "skill_helper": skill_helper,
            "sample_output": sample_output,
            "diagnostics": diagnostics,
            "manifest_path": path_string(manifest_path),
            "manifest_exists": manifest_path.is_file(),
            "manifest_id": manifest_id,
            "states_count": source_manifest
                .and_then(|manifest| manifest.get("states"))
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0),
            "validation_path": path_string(validation_path),
            "validation_exists": validation_path.is_file(),
            "validation_ok": source_validation
                .and_then(|validation| validation.get("ok"))
                .and_then(Value::as_bool),
            "repaired_validation": source_validation
                .and_then(|validation| validation.get("repaired_by"))
                .is_some(),
            "source_metadata": {
                "path": path_string(source_metadata_path),
                "exists": source_metadata_path.is_file(),
                "generator": source_metadata.and_then(|metadata| metadata.get("generator")),
                "provenance": source_metadata.and_then(|metadata| metadata.get("provenance")),
                "skill_helper": source_metadata.and_then(|metadata| metadata.get("skill_helper")),
            },
            "skill_session": {
                "path": path_string(skill_session_path),
                "exists": skill_session_path.is_file(),
            },
        },
        "petpack_files": petpack_files
            .iter()
            .map(|path| json!({
                "path": path_string(path),
                "bytes": fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0),
            }))
            .collect::<Vec<_>>(),
    })
}

fn generation_mode(
    generator: Option<&str>,
    provenance: Option<&str>,
    materializer: Option<&str>,
) -> &'static str {
    match (generator, provenance, materializer) {
        (_, Some("deterministic_preview"), _) => "deterministic_preview",
        (
            Some("codex-app-server-skill"),
            Some("skill-full-source"),
            Some("petcore-internal-skill-materializer"),
        ) => "petcore_internal_skill_materialized",
        (Some("codex-app-server-skill"), Some("skill-full-source"), None) => "skill_full_source",
        (Some("codex-app-server-brief-petpack-v1"), Some("codex_app_server_brief"), _) => {
            "codex_brief_materialized"
        }
        (_, Some("app_server_cli_materialized"), _) => "app_server_cli_materialized",
        (_, Some("cli_materialized"), _) => "cli_materialized",
        (_, Some("local_form"), _) => "local_form_materialized",
        (Some(generator), _, _) if generator.contains("sample") => "sample_fixture",
        _ => "unknown",
    }
}

fn is_deterministic_preview(generator: Option<&str>, provenance: Option<&str>) -> bool {
    provenance == Some("deterministic_preview")
        || matches!(
            generator,
            Some("petcore-deterministic-preview" | "agent-pet-studio-preview-helper")
        )
}

fn generation_status_actions(
    status: Option<&str>,
    session: Option<&Value>,
    source_manifest: Option<&Value>,
    petpack_files: &[PathBuf],
) -> Vec<Value> {
    let mut actions = Vec::new();
    match status {
        Some("pending") | Some("running") => actions.push(json!({
            "kind": "wait",
            "detail": "Job is still running. Poll `petcore-cli generation status --job-id <id> --include-messages` or `generation messages`."
        })),
        Some("waiting_for_user") => actions.push(json!({
            "kind": "reply",
            "detail": "Job is waiting for Studio input. Reply with `petcore-cli generation reply --job-id <id> --content ...`."
        })),
        Some("failed") => actions.push(json!({
            "kind": "inspect_error",
            "detail": "Job failed. Inspect app_server.error_info and the app_server_session.json path in this status payload."
        })),
        Some("completed") if petpack_files.is_empty() => actions.push(json!({
            "kind": "inspect_artifacts",
            "detail": "Job is completed but no .petpack file was found in the job workspace; inspect Pet Library import state."
        })),
        None | Some("unknown") => actions.push(json!({
            "kind": "check_home",
            "detail": "No generation_jobs status row was found. Verify APC_HOME points at the PetCore home used by the running daemon."
        })),
        _ => {}
    }

    if let Some(error_info) = session.and_then(|session| session.get("error_info")) {
        if error_info.get("kind").and_then(Value::as_str) == Some("not_configured") {
            actions.push(json!({
                "kind": "configure_app_server",
                "detail": "Set CODEX_APP_SERVER_CMD to a real stdio Codex App Server command, or install a codex CLI that exposes `codex app-server --stdio`."
            }));
        }
    }
    if source_manifest.is_some() && petpack_files.is_empty() {
        actions.push(json!({
            "kind": "build_artifact",
            "detail": "petpack-source exists but no built .petpack file was found; validate with `petcore-cli petpack validate <petpack-source-path>`."
        }));
    }
    actions
}

fn read_optional_json(path: &Path) -> Result<Option<Value>> {
    if !path.is_file() {
        return Ok(None);
    }
    let mut last_error = None;
    for _ in 0..5 {
        let bytes = fs::read(path)?;
        if bytes.is_empty() {
            thread::sleep(Duration::from_millis(20));
            continue;
        }
        match serde_json::from_slice(&bytes) {
            Ok(value) => return Ok(Some(value)),
            Err(error) if error.is_eof() => {
                last_error = Some(error);
                thread::sleep(Duration::from_millis(20));
            }
            Err(error) => return Err(error.into()),
        }
    }
    match last_error {
        Some(error) => Err(error.into()),
        None => Ok(None),
    }
}

fn list_petpack_files(dir: &Path) -> Result<Vec<PathBuf>> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("petpack") {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

fn run_connections(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "connections subcommand")?;
    match subcommand.as_str() {
        "check" => {
            let params = connection_source_arg(&mut args, "check", false)?
                .map(|source| json!({ "source": source }))
                .unwrap_or_else(|| json!({}));
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "connections.check",
                params,
            )?)
        }
        "repair" => {
            let source = connection_source_arg(&mut args, "repair", true)?.ok_or_else(|| {
                PetCoreError::InvalidRequest("missing connection source".to_string())
            })?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "connections.repair",
                json!({ "source": source }),
            )?)
        }
        "refresh-installed" => {
            if !args.is_empty() {
                return Err(PetCoreError::InvalidRequest(format!(
                    "unexpected connections refresh-installed argument: {}",
                    args.join(" ")
                )));
            }
            let paths = AppPaths::from_env()?;
            let refreshed = [
                AgentSource::Codex,
                AgentSource::ClaudeCode,
                AgentSource::Pi,
                AgentSource::Opencode,
            ]
            .into_iter()
            .map(|source| {
                let result = connections::refresh_installed_source(&paths, source);
                json!({
                    "source": source,
                    "refreshed": result.as_ref().copied().unwrap_or(false),
                    "ok": result.is_ok(),
                    "error": result.err().map(|error| error.to_string()),
                })
            })
            .collect::<Vec<_>>();
            print_json(json!({ "results": refreshed }))
        }
        "uninstall" => {
            let source = connection_source_arg(&mut args, "uninstall", true)?.ok_or_else(|| {
                PetCoreError::InvalidRequest("missing connection source".to_string())
            })?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "connections.uninstall",
                json!({ "source": source }),
            )?)
        }
        "test" => {
            let source = connection_source_arg(&mut args, "test", true)?.ok_or_else(|| {
                PetCoreError::InvalidRequest("missing connection source".to_string())
            })?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "connections.test",
                json!({ "source": source }),
            )?)
        }
        "probe-opencode-server" => {
            if !args.is_empty() {
                return Err(PetCoreError::InvalidRequest(format!(
                    "unexpected connections probe-opencode-server argument: {}",
                    args.join(" ")
                )));
            }
            print_json(serde_json::to_value(connections::probe_opencode_server())?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown connections subcommand {other}"
        ))),
    }
}

fn run_launch_agent(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "launch-agent subcommand")?;
    match subcommand.as_str() {
        "plist" => {
            let config = launch_agent_config(&mut args)?;
            print_json(json!({
                "label": config.label,
                "plist_path": launch_agent::default_plist_path(),
                "plist_xml": config.plist_xml()
            }))
        }
        "install" => {
            let no_load = flag_present(&mut args, "--no-load");
            let config = launch_agent_config(&mut args)?;
            print_json(json!(launch_agent::install(&config, !no_load)?))
        }
        "uninstall" => {
            let no_load = flag_present(&mut args, "--no-load");
            print_json(json!(launch_agent::uninstall(
                launch_agent::DEFAULT_LABEL,
                !no_load
            )?))
        }
        "status" => {
            let no_launchctl = flag_present(&mut args, "--no-launchctl");
            print_json(json!(launch_agent::status(!no_launchctl)))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown launch-agent subcommand {other}"
        ))),
    }
}

fn launch_agent_config(args: &mut Vec<String>) -> Result<LaunchAgentConfig> {
    let program = flag_optional(args, "--program")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::current_exe()
                .map(|path| launch_agent::program_next_to_cli(&path))
                .unwrap_or_else(|_| PathBuf::from("petcore"))
        });
    let home = flag_optional(args, "--home")
        .map(PathBuf::from)
        .unwrap_or(AppPaths::from_env()?.home);
    Ok(LaunchAgentConfig::new(program, home))
}

fn run_events(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "events subcommand")?;
    match subcommand.as_str() {
        "recent" => {
            let limit = flag_optional(&mut args, "--limit")
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(20);
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "events.recent",
                json!({ "limit": limit }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown events subcommand {other}"
        ))),
    }
}

fn run_renderer(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "renderer subcommand")?;
    match subcommand.as_str() {
        "budget" => {
            let quality = parse_quality(&flag(&mut args, "--quality")?)?;
            let fps_profile = if let Some(profile) = flag_optional(&mut args, "--fps-profile") {
                enum_from_name(&profile)?
            } else {
                let fps = flag_optional(&mut args, "--fps")
                    .and_then(|value| value.parse::<u32>().ok())
                    .unwrap_or(12);
                if fps >= 20 {
                    FpsProfileName::Smooth
                } else {
                    FpsProfileName::Standard
                }
            };
            print_json(json!(petcore::metrics::renderer_budget(
                quality,
                fps_profile
            )))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown renderer subcommand {other}"
        ))),
    }
}

fn parse_quality(value: &str) -> Result<QualityLevel> {
    enum_from_name(value)
}

fn derive_materialized_pet_name(form: &GenerationForm) -> String {
    let candidate = form.description.trim();
    if candidate.is_empty() {
        return "Studio Pet".to_string();
    }
    let name = candidate
        .chars()
        .filter(|character| !character.is_control())
        .take(16)
        .collect::<String>();
    if name.trim().is_empty() {
        "Studio Pet".to_string()
    } else {
        name
    }
}

fn rewrite_materialized_provenance(output: &Path, generator: &str, provenance: &str) -> Result<()> {
    rewrite_json_object(output.join("source").join("source.json"), |object| {
        object.insert("generator".to_string(), json!(generator));
        object.insert("provenance".to_string(), json!(provenance));
        object.insert("materialized_by".to_string(), json!("petcore-cli"));
    })?;
    rewrite_json_object(output.join("brief.json"), |object| {
        object.insert(
            "generation".to_string(),
            json!({
                "generator": generator,
                "provenance": provenance,
            }),
        );
    })?;
    rewrite_json_object(output.join("build").join("validation.json"), |object| {
        object.insert("generator".to_string(), json!(generator));
        object.insert("provenance".to_string(), json!(provenance));
    })?;

    write_materialized_session(output, generator, provenance)?;
    Ok(())
}

fn materialized_source_identity(output: &Path) -> Result<(String, String)> {
    let metadata = read_optional_json(&output.join("source").join("source.json"))?;
    let generator = metadata
        .as_ref()
        .and_then(|value| value.get("generator"))
        .and_then(Value::as_str)
        .unwrap_or("local-form-driven-petpack-v1")
        .to_string();
    let provenance = metadata
        .as_ref()
        .and_then(|value| value.get("provenance"))
        .and_then(Value::as_str)
        .unwrap_or("local_form")
        .to_string();
    Ok((generator, provenance))
}

fn write_materialized_session(output: &Path, generator: &str, provenance: &str) -> Result<()> {
    let source_dir = output.join("source");
    fs::create_dir_all(&source_dir)?;
    let session_path = output.join("source").join("skill_session.jsonl");
    let event = json!({
        "schema_version": "apc.pet-source-event.v1",
        "event": if generator == "codex-app-server-skill" && provenance == "skill-full-source" {
            "skill.full_source.materialized"
        } else {
            "petpack.materialized"
        },
        "skill": "agent-pet-studio",
        "generator": generator,
        "provenance": provenance,
        "materializer": "petcore-cli",
        "created_at": petcore::now_rfc3339(),
    });
    fs::write(session_path, serde_json::to_string(&event)? + "\n")?;
    Ok(())
}

fn rewrite_json_object(
    path: PathBuf,
    rewrite: impl FnOnce(&mut serde_json::Map<String, Value>),
) -> Result<()> {
    let value = read_optional_json(&path)?.unwrap_or_else(|| json!({}));
    let mut object = value.as_object().cloned().unwrap_or_default();
    rewrite(&mut object);
    fs::write(path, serde_json::to_vec_pretty(&Value::Object(object))?)?;
    Ok(())
}

fn pop(args: &mut Vec<String>, label: &str) -> Result<String> {
    if args.is_empty() {
        return Err(PetCoreError::InvalidRequest(format!("missing {label}")));
    }
    Ok(args.remove(0))
}

fn flag(args: &mut Vec<String>, name: &str) -> Result<String> {
    flag_optional(args, name).ok_or_else(|| PetCoreError::InvalidRequest(format!("missing {name}")))
}

fn flag_optional(args: &mut Vec<String>, name: &str) -> Option<String> {
    let index = args.iter().position(|arg| arg == name)?;
    args.remove(index);
    if index >= args.len() {
        return None;
    }
    Some(args.remove(index))
}

fn flag_present(args: &mut Vec<String>, name: &str) -> bool {
    let Some(index) = args.iter().position(|arg| arg == name) else {
        return false;
    };
    args.remove(index);
    true
}

fn reject_extra_args(args: &[String], context: &str) -> Result<()> {
    if args.is_empty() {
        return Ok(());
    }
    Err(PetCoreError::InvalidRequest(format!(
        "unexpected {context} argument: {}",
        args.join(" ")
    )))
}

fn connection_source_arg(
    args: &mut Vec<String>,
    subcommand: &str,
    required: bool,
) -> Result<Option<String>> {
    let from_flag = if let Some(index) = args.iter().position(|arg| arg == "--source") {
        args.remove(index);
        if index >= args.len() || args[index].starts_with("--") {
            return Err(PetCoreError::InvalidRequest(
                "missing --source value".to_string(),
            ));
        }
        Some(args.remove(index))
    } else {
        None
    };

    let from_position = if args.first().is_some_and(|arg| !arg.starts_with("--")) {
        Some(args.remove(0))
    } else {
        None
    };

    if from_flag.is_some() && from_position.is_some() {
        return Err(PetCoreError::InvalidRequest(
            "connection source specified more than once".to_string(),
        ));
    }

    if !args.is_empty() {
        return Err(PetCoreError::InvalidRequest(format!(
            "unexpected connections {subcommand} argument: {}",
            args.join(" ")
        )));
    }

    let source = from_flag.or(from_position);
    if required && source.is_none() {
        return Err(PetCoreError::InvalidRequest(format!(
            "missing connections {subcommand} source"
        )));
    }
    Ok(source)
}

fn print_json(value: serde_json::Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn path_string(path: &Path) -> String {
    path.display().to_string()
}

fn hook_payload_from_stdin(stdin: &str) -> serde_json::Value {
    let trimmed = stdin.trim();
    if trimmed.is_empty() {
        return json!({});
    }

    serde_json::from_str(trimmed).unwrap_or_else(|error| {
        json!({
            "stdin_format": "text",
            "stdin_bytes": stdin.len(),
            "stdin_parse_error": error.to_string(),
        })
    })
}

fn contract_event_for_hook(
    source: &str,
    explicit_event_type: Option<&str>,
    payload: &Value,
) -> Result<Option<ContractEvent>> {
    let source = enum_from_name::<AgentSource>(source)?;
    let explicit = explicit_event_type
        .map(str::trim)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("auto"));

    let mut contract = if explicit.is_none() {
        let Some(contract) = parse_contract_event(source, payload)? else {
            return Ok(None);
        };
        contract
    } else {
        let kind = infer_event_type(explicit, payload, None, None)?;
        ContractEvent {
            source,
            session_id: string_at_any_path(payload, SESSION_PATHS),
            kind,
            tool_name: string_at_any_path(payload, TOOL_NAME_PATHS),
            outcome: None,
            source_event: enum_name(kind).to_string(),
            diagnostic: payload
                .get("diagnostic")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            session_active: !matches!(kind, AgentEventType::Done | AgentEventType::Failed),
            turn_id: None,
            message_role: None,
            message_content: None,
            activity_kind: (!matches!(
                kind,
                AgentEventType::Done | AgentEventType::Failed | AgentEventType::Waiting
            ))
            .then(|| "thinking".to_string()),
            activity_content: None,
            interaction_kind: (kind == AgentEventType::Waiting)
                .then(|| "approval_required".to_string()),
            project_label: None,
            session_title: None,
            session_open: Some(true),
            session_surface: None,
            terminal_app: None,
            session_open_url: None,
        }
    };
    apply_runtime_navigation(&mut contract);
    Ok(Some(contract))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RuntimeNavigation {
    session_surface: Option<String>,
    terminal_app: Option<String>,
    session_open_url: Option<String>,
}

fn apply_runtime_navigation(contract: &mut ContractEvent) {
    let navigation = runtime_navigation_from_values(
        contract.source,
        std::env::var("WARP_FOCUS_URL").ok().as_deref(),
        std::env::var("TERM_PROGRAM").ok().as_deref(),
        std::env::var("__CFBundleIdentifier").ok().as_deref(),
    );
    contract.session_surface = navigation.session_surface;
    contract.terminal_app = navigation.terminal_app;
    contract.session_open_url = navigation.session_open_url;
}

fn runtime_navigation_from_values(
    source: AgentSource,
    warp_focus_url: Option<&str>,
    term_program: Option<&str>,
    bundle_identifier: Option<&str>,
) -> RuntimeNavigation {
    let session_open_url = warp_focus_url.and_then(validated_warp_focus_url);
    let terminal_app = if session_open_url.is_some() {
        Some("warp".to_string())
    } else {
        term_program.and_then(normalized_terminal_app)
    };
    let session_surface = if terminal_app.is_some() || source != AgentSource::Codex {
        Some("cli_terminal".to_string())
    } else if bundle_identifier == Some("com.openai.codex") {
        Some("chatgpt_app".to_string())
    } else {
        None
    };
    RuntimeNavigation {
        session_surface,
        terminal_app,
        session_open_url,
    }
}

fn validated_warp_focus_url(value: &str) -> Option<String> {
    let value = value.trim();
    let uuid = value
        .strip_prefix("warp://session/")
        .or_else(|| value.strip_prefix("warppreview://session/"))?;
    (uuid.len() == 32 && uuid.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| value.to_string())
}

fn normalized_terminal_app(term_program: &str) -> Option<String> {
    let normalized = term_program.trim().to_ascii_lowercase();
    if normalized.contains("warp") {
        Some("warp".to_string())
    } else if normalized.contains("iterm") {
        Some("iterm2".to_string())
    } else if normalized.contains("ghostty") {
        Some("ghostty".to_string())
    } else if normalized == "apple_terminal" || normalized == "terminal" {
        Some("terminal".to_string())
    } else {
        None
    }
}

fn usage() {
    eprintln!(
        "usage: petcore-cli health | state snapshot|wait | snapshot | codex | agent ingest|hook | behavior get|set-json | overlay placement get|set | pet list|activate|delete | petpack sample|materialize|validate|build|import [--offline] <path>|export [--offline] --id PET_ID --output PATH | generation start|messages|retry|status|for-pet|reply|cancel | connections check [--source SOURCE|SOURCE] | connections repair|uninstall|test --source SOURCE | connections refresh-installed | connections probe-opencode-server | events recent | renderer budget | launch-agent plist|install|uninstall|status"
    );
}

#[cfg(test)]
const ID_PATHS: &[&[&str]] = &[
    &["id"],
    &["event", "id"],
    &["event_id"],
    &["hook_id"],
    &["request_id"],
    &["uuid"],
];

const SESSION_PATHS: &[&[&str]] = &[
    &["session_id"],
    &["sessionId"],
    &["sessionID"],
    &["session", "id"],
    &["event", "session_id"],
    &["event", "sessionId"],
    &["event", "sessionID"],
    &["properties", "sessionID"],
    &["properties", "info", "id"],
    &["event", "properties", "sessionID"],
    &["event", "properties", "info", "id"],
    &["input", "sessionID"],
    &["conversation_id"],
    &["conversationId"],
    &["conversation", "id"],
    &["thread_id"],
    &["threadId"],
    &["thread", "id"],
];

const TOOL_NAME_PATHS: &[&[&str]] = &[
    &["tool_name"],
    &["toolName"],
    &["tool", "name"],
    &["input", "tool"],
    &["input", "name"],
    &["event", "tool_name"],
    &["event", "toolName"],
    &["event", "tool", "name"],
    &["event", "input", "tool"],
];

const DETAIL_PATHS: &[&[&str]] = &[
    &["detail"],
    &["message"],
    &["summary"],
    &["tool_name"],
    &["toolName"],
    &["tool"],
    &["tool", "name"],
    &["input", "tool"],
    &["input", "name"],
    &["command"],
    &["args", "command"],
    &["input", "command"],
    &["input", "args", "command"],
    &["permission", "tool"],
    &["error", "message"],
    &["output", "error", "message"],
    &["event", "detail"],
    &["event", "message"],
    &["event", "summary"],
    &["event", "tool_name"],
    &["event", "toolName"],
    &["event", "tool"],
    &["event", "tool", "name"],
    &["event", "input", "tool"],
    &["event", "input", "name"],
    &["event", "command"],
    &["event", "input", "command"],
    &["event", "input", "args", "command"],
    &["event", "permission", "tool"],
    &["event", "error", "message"],
    &["event", "output", "error", "message"],
];

const EVENT_TYPE_PATHS: &[&[&str]] = &[
    &["event_type"],
    &["eventType"],
    &["type"],
    &["kind"],
    &["name"],
    &["action"],
    &["status"],
    &["state"],
    &["phase"],
    &["lifecycle"],
    &["event"],
    &["event", "type"],
    &["event", "kind"],
    &["event", "name"],
    &["event", "action"],
    &["event", "status"],
    &["event", "state"],
    &["event", "phase"],
    &["hook", "event_name"],
    &["hook", "type"],
    &["hook_event_name"],
    &["payload", "type"],
    &["payload", "event_type"],
    &["input", "type"],
    &["output", "type"],
];

fn infer_event_type(
    explicit: Option<&str>,
    payload: &serde_json::Value,
    title: Option<&str>,
    detail: Option<&str>,
) -> Result<AgentEventType> {
    let mut candidates = Vec::new();
    if let Some(value) = explicit.filter(|value| !value.trim().eq_ignore_ascii_case("auto")) {
        candidates.push(value.to_string());
    }
    if let Some(value) = string_at_any_path(payload, EVENT_TYPE_PATHS) {
        candidates.push(value);
    }
    if let Some(value) = title {
        candidates.push(value.to_string());
    }
    if let Some(value) = detail {
        candidates.push(value.to_string());
    }
    if let Some(value) = string_at_any_path(payload, DETAIL_PATHS) {
        candidates.push(value);
    }

    for candidate in &candidates {
        if let Ok(kind) = enum_from_name::<AgentEventType>(candidate) {
            return Ok(kind);
        }
        if let Some(kind) = classify_event_label(candidate) {
            return Ok(kind);
        }
    }

    Ok(AgentEventType::Tool)
}

fn classify_event_label(label: &str) -> Option<AgentEventType> {
    let normalized: String = label
        .chars()
        .flat_map(char::to_lowercase)
        .filter(|character| character.is_ascii_alphanumeric())
        .collect();
    let raw = label.to_lowercase();

    if raw.contains('失') && raw.contains('败') || raw.contains("错误") || raw.contains("异常")
    {
        return Some(AgentEventType::Failed);
    }
    if raw.contains("等待") || raw.contains("确认") || raw.contains("批准") || raw.contains("授权")
    {
        return Some(AgentEventType::Waiting);
    }
    if raw.contains("待查看") || raw.contains("查看") || raw.contains("审阅") {
        return Some(AgentEventType::Review);
    }
    if raw.contains("执行") || raw.contains("工具") || raw.contains("命令") {
        return Some(AgentEventType::Tool);
    }
    if raw.contains("完成") || raw.contains("结束") || raw.contains("成功") {
        return Some(AgentEventType::Done);
    }
    if raw.contains("开始") || raw.contains("启动") {
        return Some(AgentEventType::Start);
    }

    let aliases: &[(AgentEventType, &[&str])] = &[
        (
            AgentEventType::Failed,
            &[
                "failed",
                "failure",
                "stopfailure",
                "error",
                "exception",
                "crash",
                "errored",
                "abort",
                "aborted",
                "cancel",
                "cancelled",
                "canceled",
                "iserror",
                "sessionerror",
                "toolexecutefailed",
                "toolfailed",
            ],
        ),
        (
            AgentEventType::Waiting,
            &[
                "waiting",
                "permissionrequest",
                "permissionasked",
                "permission",
                "approval",
                "approve",
                "confirmation",
                "confirm",
                "needsapproval",
                "needspermission",
                "userapproval",
                "askuser",
                "permissionrequired",
                "authorization",
                "authorize",
                "confirmationrequired",
            ],
        ),
        (
            AgentEventType::Review,
            &[
                "review",
                "posttooluse",
                "toolexecuteafter",
                "toolcomplete",
                "toolcompleted",
                "tooldone",
                "toolresult",
                "toolresultend",
                "toolfinished",
                "toolresponse",
                "aftertool",
                "result",
                "output",
                "sessiondiff",
            ],
        ),
        (
            AgentEventType::Tool,
            &[
                "tool",
                "pretooluse",
                "toolexecutebefore",
                "toolcall",
                "toolstart",
                "toolstarted",
                "toolrun",
                "toolinvoke",
                "toolinvocation",
                "toolexecutionstart",
                "tooluse",
                "toolinput",
                "command",
                "commandexecuted",
                "commandstart",
                "shell",
                "bash",
                "execute",
            ],
        ),
        (
            AgentEventType::Done,
            &[
                "done",
                "stop",
                "success",
                "complete",
                "completed",
                "finish",
                "finished",
                "idle",
                "sessionidle",
                "sessionend",
                "sessiondone",
                "sessionshutdown",
                "agentend",
                "runcomplete",
                "taskcomplete",
            ],
        ),
        (
            AgentEventType::Start,
            &[
                "start",
                "sessionstart",
                "sessioncreated",
                "sessionupdated",
                "userpromptsubmit",
                "userprompt",
                "promptsubmit",
                "beforeagentstart",
                "agentstart",
                "conversationstart",
                "threadstart",
                "runstart",
                "jobstart",
                "taskstart",
            ],
        ),
    ];

    aliases
        .iter()
        .find(|(_, values)| values.iter().any(|alias| normalized.contains(alias)))
        .map(|(kind, _)| *kind)
}

fn string_at_any_path(value: &serde_json::Value, paths: &[&[&str]]) -> Option<String> {
    paths.iter().find_map(|path| string_at_path(value, path))
}

fn string_at_path(value: &serde_json::Value, path: &[&str]) -> Option<String> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    match current {
        serde_json::Value::String(value) if !value.is_empty() => Some(value.clone()),
        serde_json::Value::Number(value) => Some(value.to_string()),
        serde_json::Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warp_runtime_navigation_preserves_only_exact_session_focus_urls() {
        let navigation = runtime_navigation_from_values(
            AgentSource::ClaudeCode,
            Some("warp://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"),
            Some("WarpTerminal"),
            None,
        );
        assert_eq!(navigation.session_surface.as_deref(), Some("cli_terminal"));
        assert_eq!(navigation.terminal_app.as_deref(), Some("warp"));
        assert_eq!(
            navigation.session_open_url.as_deref(),
            Some("warp://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4")
        );

        let rejected = runtime_navigation_from_values(
            AgentSource::Codex,
            Some("https://example.com/session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"),
            None,
            None,
        );
        assert_eq!(rejected.session_open_url, None);
        assert_eq!(rejected.session_surface, None);
    }

    #[test]
    fn cli_only_agents_keep_app_fallback_without_terminal_metadata() {
        let navigation = runtime_navigation_from_values(AgentSource::Pi, None, None, None);
        assert_eq!(navigation.session_surface.as_deref(), Some("cli_terminal"));
        assert_eq!(navigation.terminal_app, None);

        let iterm =
            runtime_navigation_from_values(AgentSource::Codex, None, Some("iTerm.app"), None);
        assert_eq!(iterm.session_surface.as_deref(), Some("cli_terminal"));
        assert_eq!(iterm.terminal_app.as_deref(), Some("iterm2"));

        let chatgpt = runtime_navigation_from_values(
            AgentSource::Codex,
            None,
            None,
            Some("com.openai.codex"),
        );
        assert_eq!(chatgpt.session_surface.as_deref(), Some("chatgpt_app"));
    }

    #[test]
    fn infers_common_agent_hook_event_types() {
        assert_eq!(
            infer_event_type(Some("SessionStart"), &json!({}), None, None).unwrap(),
            AgentEventType::Start
        );
        assert_eq!(
            infer_event_type(
                Some("auto"),
                &json!({ "type": "tool.execute.before" }),
                None,
                None
            )
            .unwrap(),
            AgentEventType::Tool
        );
        assert_eq!(
            infer_event_type(
                Some("auto"),
                &json!({ "type": "permission.asked" }),
                None,
                None
            )
            .unwrap(),
            AgentEventType::Waiting
        );
        assert_eq!(
            infer_event_type(Some("auto"), &json!({ "type": "tool_result" }), None, None).unwrap(),
            AgentEventType::Review
        );
        assert_eq!(
            infer_event_type(Some("auto"), &json!({ "type": "session.idle" }), None, None).unwrap(),
            AgentEventType::Done
        );
        assert_eq!(
            infer_event_type(Some("auto"), &json!({}), Some("失败"), None).unwrap(),
            AgentEventType::Failed
        );
        assert_eq!(
            infer_event_type(
                Some("auto"),
                &json!({ "event": { "type": "session.error" } }),
                None,
                None
            )
            .unwrap(),
            AgentEventType::Failed
        );
        assert_eq!(
            infer_event_type(
                Some("auto"),
                &json!({ "status": "permission_required" }),
                None,
                None
            )
            .unwrap(),
            AgentEventType::Waiting
        );
        assert_eq!(
            infer_event_type(
                Some("auto"),
                &json!({ "event": { "name": "tool.finished" } }),
                None,
                None
            )
            .unwrap(),
            AgentEventType::Review
        );
        assert_eq!(
            infer_event_type(
                Some("auto"),
                &json!({ "event": { "type": "session.updated" } }),
                None,
                None
            )
            .unwrap(),
            AgentEventType::Start
        );
    }

    #[test]
    fn extracts_nested_agent_hook_details() {
        assert_eq!(
            string_at_any_path(
                &json!({ "event": { "input": { "tool": "Bash" } } }),
                DETAIL_PATHS
            ),
            Some("Bash".to_string())
        );
        assert_eq!(
            string_at_any_path(
                &json!({ "input": { "args": { "command": "swift build" } } }),
                DETAIL_PATHS
            ),
            Some("swift build".to_string())
        );
        assert_eq!(
            string_at_any_path(
                &json!({ "event": { "error": { "message": "permission denied" } } }),
                DETAIL_PATHS
            ),
            Some("permission denied".to_string())
        );
    }

    #[test]
    fn does_not_use_session_id_as_event_id() {
        let payload = json!({
            "session": { "id": "sess_123" },
            "conversation": { "id": "conv_456" }
        });
        assert_eq!(string_at_any_path(&payload, ID_PATHS), None);
        assert_eq!(
            string_at_any_path(&payload, SESSION_PATHS),
            Some("sess_123".to_string())
        );
    }

    #[test]
    fn hook_payload_from_stdin_accepts_json_or_text_without_storing_raw_text() {
        assert_eq!(hook_payload_from_stdin(" \n"), json!({}));
        assert_eq!(
            hook_payload_from_stdin(r#"{"type":"tool_call","tool":"Bash"}"#),
            json!({ "type": "tool_call", "tool": "Bash" })
        );

        let payload = hook_payload_from_stdin("not-json token=should-not-be-stored");
        assert_eq!(payload["stdin_format"], "text");
        assert_eq!(payload["stdin_bytes"], 35);
        assert!(payload["stdin_parse_error"]
            .as_str()
            .unwrap_or("")
            .contains("expected"));
        assert!(!serde_json::to_string(&payload)
            .unwrap()
            .contains("should-not-be-stored"));
    }

    #[test]
    fn contract_hook_request_keeps_only_allowlisted_state_fields() {
        let input = json!({
            "type": "tool.execute.before",
            "input": {
                "tool": "bash",
                "sessionID": "session-123",
                "callID": "secret-call-id"
            },
            "output": {
                "args": {
                    "command": "TOKEN=secret-command"
                }
            }
        });

        let contract = contract_event_for_hook("opencode", Some("auto"), &input)
            .unwrap()
            .unwrap();
        assert_eq!(contract.session_id.as_deref(), Some("session-123"));
        assert_eq!(contract.tool_name.as_deref(), Some("bash"));
        assert_eq!(contract.kind, AgentEventType::Tool);
        assert_eq!(contract.activity_kind.as_deref(), Some("command"));
        assert_eq!(contract.activity_content, None);
        let forwarded = serde_json::to_string(&contract).unwrap();
        assert!(!forwarded.contains("secret"));
        assert!(!forwarded.contains("args"));
        assert!(!forwarded.contains("callID"));
    }

    #[test]
    fn normalized_agent_request_never_forwards_arbitrary_payload_fields() {
        let error = normalized_agent_request(
            "codex",
            json!({
                "id": "cli-envelope-1",
                "session_id": "session-1",
                "event_type": "tool",
                "title": "Working",
                "payload": {
                    "source_event": "PostToolUse",
                    "tool_name": "shell",
                    "outcome": "completed",
                    "prompt": "CLI_FORBIDDEN_PROMPT_47c1",
                    "tool_input": { "command": "CLI_FORBIDDEN_COMMAND_8da2" }
                }
            }),
        )
        .unwrap_err();

        assert!(error.to_string().contains("payload field is not supported"));
    }

    #[test]
    fn official_contract_event_enters_the_strict_ingest_boundary() {
        let contract = contract_event_for_hook(
            "opencode",
            Some("auto"),
            &json!({
                "type": "tool.execute.before",
                "input": {
                    "tool": "bash",
                    "sessionID": "strict-contract-session",
                    "callID": "RAW_CALL_ID_MUST_NOT_CROSS"
                },
                "output": {
                    "args": { "command": "RAW_COMMAND_MUST_NOT_CROSS" }
                }
            }),
        )
        .unwrap()
        .unwrap();

        let request = normalized_contract_request(&contract).unwrap();
        assert_eq!(request["title"], AgentEventType::Tool.zh_label());
        assert_eq!(request["detail"], Value::Null);
        assert_eq!(
            request["payload_json"]["source_event"],
            "tool.execute.before"
        );
        assert_eq!(request["payload_json"]["tool_name"], "shell");
        assert_eq!(request["payload_json"]["outcome"], "started");
        assert_eq!(request["payload_json"]["session_active"], true);
        let encoded = serde_json::to_string(&request).unwrap();
        assert!(!encoded.contains("RAW_CALL_ID_MUST_NOT_CROSS"));
        assert!(!encoded.contains("RAW_COMMAND_MUST_NOT_CROSS"));
    }

    #[test]
    fn deterministic_materializers_are_reported_as_preview_only() {
        assert!(is_deterministic_preview(
            Some("petcore-deterministic-preview"),
            Some("deterministic_preview")
        ));
        assert!(is_deterministic_preview(
            Some("agent-pet-studio-preview-helper"),
            Some("deterministic_preview")
        ));
        assert_eq!(
            generation_mode(
                Some("agent-pet-studio-preview-helper"),
                Some("deterministic_preview"),
                None
            ),
            "deterministic_preview"
        );
        assert!(!is_deterministic_preview(
            Some("codex-app-server-skill"),
            Some("skill-full-source")
        ));
    }

    #[test]
    fn parses_connection_source_from_flag_or_position() {
        let mut args = vec!["--source".to_string(), "codex".to_string()];
        assert_eq!(
            connection_source_arg(&mut args, "check", false).unwrap(),
            Some("codex".to_string())
        );
        assert!(args.is_empty());

        let mut args = vec!["claude_code".to_string()];
        assert_eq!(
            connection_source_arg(&mut args, "check", false).unwrap(),
            Some("claude_code".to_string())
        );
        assert!(args.is_empty());

        let mut args = Vec::new();
        assert_eq!(
            connection_source_arg(&mut args, "check", false).unwrap(),
            None
        );
    }

    #[test]
    fn rejects_ambiguous_or_unexpected_connection_source_args() {
        let mut duplicate = vec![
            "--source".to_string(),
            "codex".to_string(),
            "pi".to_string(),
        ];
        assert!(connection_source_arg(&mut duplicate, "check", false).is_err());

        let mut missing = vec!["--source".to_string()];
        assert!(connection_source_arg(&mut missing, "repair", true).is_err());

        let mut unexpected = vec!["--verbose".to_string()];
        assert!(connection_source_arg(&mut unexpected, "check", false).is_err());

        let mut required = Vec::new();
        assert!(connection_source_arg(&mut required, "repair", true).is_err());
    }
}
