use petcore::daemon;
use petcore::paths::AppPaths;
use std::path::PathBuf;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> petcore::Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "serve".to_string());
    match command.as_str() {
        "serve" => {
            let mut ready_file = None;
            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--home" => {
                        let home = args.next().ok_or_else(|| {
                            petcore::PetCoreError::InvalidRequest(
                                "--home requires a path".to_string(),
                            )
                        })?;
                        std::env::set_var("APC_HOME", home);
                    }
                    "--ready-file" => {
                        ready_file = args.next().map(PathBuf::from);
                    }
                    other => {
                        return Err(petcore::PetCoreError::InvalidRequest(format!(
                            "unknown serve option {other}"
                        )));
                    }
                }
            }
            let paths = AppPaths::from_env()?;
            daemon::serve(paths, ready_file.as_deref())
        }
        "init" => {
            let paths = AppPaths::from_env()?;
            let _instance_guard = daemon::instance_lock::InstanceGuard::acquire(&paths)?;
            paths.ensure()?;
            petcore::db::Database::new(paths.db_path).init()?;
            Ok(())
        }
        "preflight" => {
            let mut manifest = None;
            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--home" => {
                        let home = args.next().ok_or_else(|| {
                            petcore::PetCoreError::InvalidRequest(
                                "--home requires a path".to_string(),
                            )
                        })?;
                        std::env::set_var("APC_HOME", home);
                    }
                    "--manifest" => {
                        manifest = args.next().map(PathBuf::from);
                    }
                    other => {
                        return Err(petcore::PetCoreError::InvalidRequest(format!(
                            "unknown preflight option {other}"
                        )));
                    }
                }
            }
            let manifest = manifest.ok_or_else(|| {
                petcore::PetCoreError::InvalidRequest(
                    "preflight requires --manifest PATH".to_string(),
                )
            })?;
            let runtime = petcore::runtime_manifest::validate_expected_manifest(&manifest)?;
            let paths = AppPaths::from_env()?;
            let database_schema =
                petcore::db::Database::new(&paths.db_path).preflight_compatibility()?;
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "ok": true,
                    "build_id": runtime.build_id,
                    "database_schema_version": database_schema,
                    "maximum_database_schema_version": runtime.maximum_database_schema_version,
                }))?
            );
            Ok(())
        }
        "rollback-checkpoint" => {
            let action = args.next().ok_or_else(|| {
                petcore::PetCoreError::InvalidRequest(
                    "rollback-checkpoint requires create, restore, discard, or status".to_string(),
                )
            })?;
            let mut source_build_id = None;
            let mut candidate_build_id = None;
            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--home" => {
                        let home = args.next().ok_or_else(|| {
                            petcore::PetCoreError::InvalidRequest(
                                "--home requires a path".to_string(),
                            )
                        })?;
                        std::env::set_var("APC_HOME", home);
                    }
                    "--source-build-id" => {
                        source_build_id = Some(args.next().ok_or_else(|| {
                            petcore::PetCoreError::InvalidRequest(
                                "--source-build-id requires a value".to_string(),
                            )
                        })?);
                    }
                    "--candidate-build-id" => {
                        candidate_build_id = Some(args.next().ok_or_else(|| {
                            petcore::PetCoreError::InvalidRequest(
                                "--candidate-build-id requires a value".to_string(),
                            )
                        })?);
                    }
                    other => {
                        return Err(petcore::PetCoreError::InvalidRequest(format!(
                            "unknown rollback-checkpoint option {other}"
                        )));
                    }
                }
            }
            let paths = AppPaths::from_env()?;
            match action.as_str() {
                "create" => {
                    let source_build_id = source_build_id.as_deref().ok_or_else(|| {
                        petcore::PetCoreError::InvalidRequest(
                            "rollback-checkpoint create requires --source-build-id".to_string(),
                        )
                    })?;
                    let candidate_build_id =
                        candidate_build_id.as_deref().ok_or_else(|| {
                            petcore::PetCoreError::InvalidRequest(
                                "rollback-checkpoint create requires --candidate-build-id"
                                    .to_string(),
                            )
                        })?;
                    let _instance_guard =
                        daemon::instance_lock::InstanceGuard::acquire(&paths)?;
                    petcore::rollback_checkpoint::create(
                        &paths,
                        source_build_id,
                        candidate_build_id,
                    )
                }
                "restore" => {
                    if source_build_id.is_some() || candidate_build_id.is_some() {
                        return Err(petcore::PetCoreError::InvalidRequest(
                            "rollback-checkpoint restore does not accept build IDs".to_string(),
                        ));
                    }
                    let _instance_guard =
                        daemon::instance_lock::InstanceGuard::acquire(&paths)?;
                    petcore::rollback_checkpoint::restore(&paths)
                }
                // Cleanup touches only the private checkpoint copy and is safe
                // after either the candidate or rollback runtime is healthy.
                "discard" => {
                    if source_build_id.is_some() || candidate_build_id.is_some() {
                        return Err(petcore::PetCoreError::InvalidRequest(
                            "rollback-checkpoint discard does not accept build IDs".to_string(),
                        ));
                    }
                    petcore::rollback_checkpoint::discard(&paths)
                }
                "status" => {
                    if source_build_id.is_some() || candidate_build_id.is_some() {
                        return Err(petcore::PetCoreError::InvalidRequest(
                            "rollback-checkpoint status does not accept build IDs".to_string(),
                        ));
                    }
                    println!(
                        "{}",
                        serde_json::to_string_pretty(
                            &petcore::rollback_checkpoint::status(&paths)?
                        )?
                    );
                    Ok(())
                }
                other => Err(petcore::PetCoreError::InvalidRequest(format!(
                    "unknown rollback-checkpoint action {other}"
                ))),
            }
        }
        "runtime-manifest" => {
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &petcore::runtime_manifest::RuntimeReleaseManifest::compiled()
                )?
            );
            Ok(())
        }
        other => Err(petcore::PetCoreError::InvalidRequest(format!(
            "unknown command {other}; expected serve, init, preflight, rollback-checkpoint, or runtime-manifest"
        ))),
    }
}
