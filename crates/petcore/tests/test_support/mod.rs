use std::ffi::{OsStr, OsString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

static PROCESS_STATE_LOCK: Mutex<()> = Mutex::new(());

pub fn lock_process_state() -> MutexGuard<'static, ()> {
    PROCESS_STATE_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[allow(dead_code)]
pub struct ProcessEnvironmentGuard {
    key: &'static str,
    original: Option<OsString>,
}

#[allow(dead_code)]
impl ProcessEnvironmentGuard {
    pub fn set(key: &'static str, value: impl AsRef<OsStr>) -> Self {
        let original = std::env::var_os(key);
        std::env::set_var(key, value);
        Self { key, original }
    }

    pub fn remove(key: &'static str) -> Self {
        let original = std::env::var_os(key);
        std::env::remove_var(key);
        Self { key, original }
    }
}

impl Drop for ProcessEnvironmentGuard {
    fn drop(&mut self) {
        if let Some(value) = &self.original {
            std::env::set_var(self.key, value);
        } else {
            std::env::remove_var(self.key);
        }
    }
}

#[allow(dead_code)]
pub struct CurrentDirectoryGuard {
    original: PathBuf,
}

#[allow(dead_code)]
impl CurrentDirectoryGuard {
    pub fn enter(path: &Path) -> std::io::Result<Self> {
        let original = std::env::current_dir()?;
        std::env::set_current_dir(path)?;
        Ok(Self { original })
    }
}

impl Drop for CurrentDirectoryGuard {
    fn drop(&mut self) {
        let _ = std::env::set_current_dir(&self.original);
    }
}

#[allow(dead_code)]
pub struct BoundedTempDir(tempfile::TempDir);

#[allow(dead_code)]
impl BoundedTempDir {
    pub fn new() -> std::io::Result<Self> {
        tempfile::tempdir().map(Self)
    }

    pub fn path(&self) -> &Path {
        self.0.path()
    }
}

#[allow(dead_code)]
pub struct OwnedLoopbackPort {
    listener: TcpListener,
}

#[allow(dead_code)]
impl OwnedLoopbackPort {
    pub fn bind() -> std::io::Result<Self> {
        TcpListener::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0))
            .map(|listener| Self { listener })
    }

    pub fn address(&self) -> std::io::Result<SocketAddr> {
        self.listener.local_addr()
    }
}
