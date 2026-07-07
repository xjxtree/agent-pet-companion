use petcore::daemon;
use petcore::paths::AppPaths;
use petcore::petpack;
use petcore::{enum_from_name, PetCoreError, Result};
use petcore_types::{FpsProfileName, QualityLevel};
use serde_json::json;
use std::path::PathBuf;

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
        "health" => print_json(daemon::request(&AppPaths::from_env()?, "petcore.health", json!({}))?),
        "snapshot" => print_json(daemon::request(&AppPaths::from_env()?, "state.snapshot", json!({}))?),
        "agent" => run_agent(args),
        "behavior" => run_behavior(args),
        "petpack" => run_petpack(args),
        "generation" => run_generation(args),
        "connections" => run_connections(args),
        "renderer" => run_renderer(args),
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

fn run_agent(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "agent subcommand")?;
    match subcommand.as_str() {
        "ingest" => {
            let source = flag(&mut args, "--source")?;
            let event_type = flag(&mut args, "--event-type")?;
            let title = flag_optional(&mut args, "--title").unwrap_or_else(|| event_type.clone());
            let detail = flag_optional(&mut args, "--detail");
            let id = flag_optional(&mut args, "--id");
            let result = daemon::request(
                &AppPaths::from_env()?,
                "agent.ingest",
                json!({
                    "id": id,
                    "source": source,
                    "event_type": event_type,
                    "title": title,
                    "detail": detail,
                    "payload": {}
                }),
            )?;
            print_json(result)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown agent subcommand {other}"
        ))),
    }
}

fn run_behavior(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "behavior subcommand")?;
    match subcommand.as_str() {
        "get" => print_json(daemon::request(&AppPaths::from_env()?, "behavior.get", json!({}))?),
        "set-json" => {
            let value_json = flag(&mut args, "--value-json")?;
            let value: serde_json::Value = serde_json::from_str(&value_json)?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "behavior.update",
                value,
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown behavior subcommand {other}"
        ))),
    }
}

fn run_petpack(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "petpack subcommand")?;
    match subcommand.as_str() {
        "sample" => {
            let output = PathBuf::from(flag(&mut args, "--output")?);
            let quality = parse_quality(&flag_optional(&mut args, "--quality").unwrap_or_else(|| "high".to_string()))?;
            let name = flag_optional(&mut args, "--name").unwrap_or_else(|| "Cloud Maiden".to_string());
            let style = flag_optional(&mut args, "--style").unwrap_or_else(|| "半写实".to_string());
            let frames = flag_optional(&mut args, "--frames")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(2);
            let manifest = petpack::write_sample_petpack_dir(&output, quality, &name, &style, frames)?;
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
            let path = PathBuf::from(pop(&mut args, "petpack path")?);
            let paths = AppPaths::from_env()?;
            let database = petcore::db::Database::new(paths.db_path.clone());
            database.init()?;
            let pet = petpack::import_petpack(&paths, &database, &path)?;
            print_json(json!(pet))
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
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown generation subcommand {other}"
        ))),
    }
}

fn run_connections(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "connections subcommand")?;
    match subcommand.as_str() {
        "check" => {
            let params = flag_optional(&mut args, "--source")
                .map(|source| json!({ "source": source }))
                .unwrap_or_else(|| json!({}));
            print_json(daemon::request(&AppPaths::from_env()?, "connections.check", params)?)
        }
        "repair" => {
            let source = flag(&mut args, "--source")?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "connections.repair",
                json!({ "source": source }),
            )?)
        }
        "uninstall" => {
            let source = flag(&mut args, "--source")?;
            print_json(daemon::request(
                &AppPaths::from_env()?,
                "connections.uninstall",
                json!({ "source": source }),
            )?)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown connections subcommand {other}"
        ))),
    }
}

fn run_renderer(mut args: Vec<String>) -> Result<()> {
    let subcommand = pop(&mut args, "renderer subcommand")?;
    match subcommand.as_str() {
        "budget" => {
            let quality = parse_quality(&flag(&mut args, "--quality")?)?;
            let fps = flag_optional(&mut args, "--fps")
                .and_then(|value| value.parse::<u32>().ok())
                .unwrap_or(12);
            let fps_profile = if fps >= 20 {
                FpsProfileName::Smooth
            } else {
                FpsProfileName::Standard
            };
            print_json(json!(petcore::metrics::renderer_budget(quality, fps_profile)))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown renderer subcommand {other}"
        ))),
    }
}

fn parse_quality(value: &str) -> Result<QualityLevel> {
    enum_from_name(value)
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

fn print_json(value: serde_json::Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn usage() {
    eprintln!(
        "usage: petcore-cli health | agent ingest | petpack sample|validate|build | generation start|messages | connections check|repair|uninstall | renderer budget"
    );
}
