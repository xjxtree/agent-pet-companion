use crate::Result;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct AppPaths {
    pub home: PathBuf,
    pub run_dir: PathBuf,
    pub socket_path: PathBuf,
    pub token_path: PathBuf,
    pub http_port_path: PathBuf,
    pub db_path: PathBuf,
    pub pets_dir: PathBuf,
    pub jobs_dir: PathBuf,
    pub connectors_dir: PathBuf,
    pub logs_dir: PathBuf,
}

impl AppPaths {
    pub fn from_env() -> Result<Self> {
        if let Ok(home) = std::env::var("APC_HOME") {
            return Ok(Self::new(PathBuf::from(home)));
        }

        let user_home = std::env::var("HOME").map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::NotFound, "HOME is not set")
        })?;
        Ok(Self::new(
            PathBuf::from(user_home)
                .join("Library")
                .join("Application Support")
                .join("AgentPetCompanion"),
        ))
    }

    pub fn new(home: PathBuf) -> Self {
        let run_dir = home.join("run");
        Self {
            socket_path: run_dir.join("petcore.sock"),
            token_path: run_dir.join("update-token"),
            http_port_path: run_dir.join("http-port"),
            db_path: home.join("agent-pet.sqlite"),
            pets_dir: home.join("pets"),
            jobs_dir: home.join("generation-jobs"),
            connectors_dir: home.join("connectors"),
            logs_dir: home.join("logs"),
            home,
            run_dir,
        }
    }

    pub fn ensure(&self) -> Result<()> {
        std::fs::create_dir_all(&self.home)?;
        std::fs::create_dir_all(&self.run_dir)?;
        std::fs::create_dir_all(&self.pets_dir)?;
        std::fs::create_dir_all(&self.jobs_dir)?;
        std::fs::create_dir_all(&self.connectors_dir)?;
        std::fs::create_dir_all(&self.logs_dir)?;
        Ok(())
    }
}
