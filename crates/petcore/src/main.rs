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
        other => Err(petcore::PetCoreError::InvalidRequest(format!(
            "unknown command {other}; expected serve"
        ))),
    }
}
