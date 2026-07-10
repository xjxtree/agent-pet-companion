use crate::paths::AppPaths;
use crate::{new_id, now_rfc3339, PetCoreError, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::net::Shutdown;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

pub const RUNTIME_MARKER_SCHEMA_VERSION: &str = "apc.runtime.v1";
const MAX_RUNTIME_MARKER_BYTES: u64 = 64 * 1024;
const INSTANCE_PROBE_MAX_BYTES: usize = 64 * 1024;
const INSTANCE_PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(1);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeMarker {
    pub schema_version: String,
    pub pid: u32,
    pub process_start: String,
    pub instance_id: String,
    pub http_port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct LockRecord {
    schema_version: String,
    pid: u32,
    process_start: String,
    instance_id: String,
}

#[derive(Debug)]
pub struct InstanceGuard {
    lock_file: File,
    paths: AppPaths,
    process_start: String,
    instance_id: String,
}

impl InstanceGuard {
    pub fn acquire(paths: &AppPaths) -> Result<Self> {
        paths.ensure_runtime_dirs()?;
        let mut lock_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&paths.instance_lock_path)?;

        match try_acquire_nonblocking_lock(&lock_file)? {
            LockAttempt::Contended => {
                return match inspect_contended_endpoint(paths) {
                    ActiveEndpoint::Verified => Err(already_running(&paths.socket_path)),
                    ActiveEndpoint::Inactive => Err(PetCoreError::InvalidRequest(format!(
                        "petcore instance lock is held but no active socket was verified at {}",
                        paths.socket_path.display()
                    ))),
                    ActiveEndpoint::Foreign(reason) => Err(PetCoreError::InvalidRequest(format!(
                        "petcore instance lock is held but endpoint identity was not verified: {reason}"
                    ))),
                };
            }
            LockAttempt::Acquired => {
                if socket_is_connectable(paths) {
                    return Err(PetCoreError::InvalidRequest(format!(
                        "foreign local socket is already active while the PetCore instance lock is available at {}",
                        paths.socket_path.display()
                    )));
                }
            }
        }

        fs::set_permissions(&paths.instance_lock_path, fs::Permissions::from_mode(0o600))?;
        let process_start = now_rfc3339();
        let instance_id = new_id("instance");
        let record = LockRecord {
            schema_version: RUNTIME_MARKER_SCHEMA_VERSION.to_string(),
            pid: std::process::id(),
            process_start: process_start.clone(),
            instance_id: instance_id.clone(),
        };
        lock_file.set_len(0)?;
        lock_file.seek(SeekFrom::Start(0))?;
        serde_json::to_writer(&mut lock_file, &record)?;
        lock_file.write_all(b"\n")?;
        lock_file.sync_all()?;

        Ok(Self {
            lock_file,
            paths: paths.clone(),
            process_start,
            instance_id,
        })
    }

    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    pub fn marker(&self, http_port: u16) -> RuntimeMarker {
        RuntimeMarker {
            schema_version: RUNTIME_MARKER_SCHEMA_VERSION.to_string(),
            pid: std::process::id(),
            process_start: self.process_start.clone(),
            instance_id: self.instance_id.clone(),
            http_port,
        }
    }

    pub fn publish_runtime(&self, http_port: u16) -> Result<()> {
        let marker = self.marker(http_port);
        atomic_write_private(&self.paths.http_port_path, http_port.to_string().as_bytes())?;
        atomic_write_private(
            &self.paths.runtime_marker_path,
            &serde_json::to_vec_pretty(&marker)?,
        )?;
        Ok(())
    }
}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        let owns_runtime_marker = read_runtime_marker(&self.paths)
            .ok()
            .flatten()
            .is_some_and(|marker| marker.instance_id == self.instance_id);
        if owns_runtime_marker {
            let _ = fs::remove_file(&self.paths.runtime_marker_path);
            let _ = fs::remove_file(&self.paths.http_port_path);
            let _ = fs::remove_file(&self.paths.socket_path);
        }
        let _ = rustix::fs::flock(&self.lock_file, rustix::fs::FlockOperation::Unlock);
    }
}

pub fn read_runtime_marker(paths: &AppPaths) -> Result<Option<RuntimeMarker>> {
    let metadata = match fs::metadata(&paths.runtime_marker_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if metadata.len() > MAX_RUNTIME_MARKER_BYTES {
        return Err(PetCoreError::InvalidRequest(format!(
            "runtime marker exceeds {MAX_RUNTIME_MARKER_BYTES} bytes"
        )));
    }
    let marker = serde_json::from_slice(&fs::read(&paths.runtime_marker_path)?)?;
    Ok(Some(marker))
}

/// Returns true only when the runtime marker and the live endpoint agree on
/// the requested daemon identity. Recovery code uses this as a conservative
/// proof that an apparently stale owner is still serving requests.
pub fn runtime_owner_is_healthy(paths: &AppPaths, owner_instance_id: &str) -> bool {
    let marker = match read_runtime_marker(paths) {
        Ok(Some(marker)) => marker,
        _ => return false,
    };
    if marker.schema_version != RUNTIME_MARKER_SCHEMA_VERSION
        || marker.instance_id != owner_instance_id
        || !process_exists(marker.pid)
    {
        return false;
    }
    let stream = match UnixStream::connect(&paths.socket_path) {
        Ok(stream) => stream,
        Err(_) => return false,
    };
    probe_instance_identity(stream).is_ok_and(|identity| identity == owner_instance_id)
}

pub(crate) fn atomic_write_private(path: &Path, content: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        PetCoreError::InvalidRequest(format!("path has no parent: {}", path.display()))
    })?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("runtime");
    let temporary_path: PathBuf = parent.join(format!(".{file_name}.{}.tmp", new_id("write")));

    let result = (|| -> Result<()> {
        let mut temporary = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary_path)?;
        temporary.write_all(content)?;
        temporary.sync_all()?;
        fs::rename(&temporary_path, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    result
}

enum LockAttempt {
    Acquired,
    Contended,
}

enum ActiveEndpoint {
    Inactive,
    Verified,
    Foreign(String),
}

fn try_acquire_nonblocking_lock(file: &File) -> Result<LockAttempt> {
    match rustix::fs::flock(file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => Ok(LockAttempt::Acquired),
        Err(rustix::io::Errno::AGAIN) => Ok(LockAttempt::Contended),
        Err(error) => Err(std::io::Error::from(error).into()),
    }
}

fn socket_is_connectable(paths: &AppPaths) -> bool {
    paths.socket_path.exists() && UnixStream::connect(&paths.socket_path).is_ok()
}

fn inspect_contended_endpoint(paths: &AppPaths) -> ActiveEndpoint {
    let lock_record = match read_lock_record(paths) {
        Ok(Some(record)) => record,
        Ok(None) => {
            return ActiveEndpoint::Foreign("instance lock record is missing".to_string());
        }
        Err(error) => {
            return ActiveEndpoint::Foreign(format!("instance lock record is invalid: {error}"));
        }
    };
    if lock_record.schema_version != RUNTIME_MARKER_SCHEMA_VERSION {
        return ActiveEndpoint::Foreign(format!(
            "instance lock schema is {}, expected {RUNTIME_MARKER_SCHEMA_VERSION}",
            lock_record.schema_version
        ));
    }
    if lock_record.instance_id.is_empty() || lock_record.process_start.trim().is_empty() {
        return ActiveEndpoint::Foreign(
            "instance lock record has an empty identity or process start".to_string(),
        );
    }
    if !process_exists(lock_record.pid) {
        return ActiveEndpoint::Foreign(format!(
            "instance lock record PID {} is not running",
            lock_record.pid
        ));
    }

    let marker = match read_runtime_marker(paths) {
        Ok(Some(marker)) => marker,
        Ok(None) => {
            return ActiveEndpoint::Foreign("runtime marker is missing".to_string());
        }
        Err(error) => {
            return ActiveEndpoint::Foreign(format!("runtime marker is invalid: {error}"));
        }
    };
    if marker.schema_version != lock_record.schema_version
        || marker.pid != lock_record.pid
        || marker.process_start != lock_record.process_start
        || marker.instance_id != lock_record.instance_id
    {
        return ActiveEndpoint::Foreign(
            "instance lock record does not fully match runtime marker schema/PID/process_start/instance_id"
                .to_string(),
        );
    }

    if !paths.socket_path.exists() {
        return ActiveEndpoint::Inactive;
    }
    let stream = match UnixStream::connect(&paths.socket_path) {
        Ok(stream) => stream,
        Err(_) => return ActiveEndpoint::Inactive,
    };
    match probe_instance_identity(stream) {
        Ok(instance_id) if instance_id == marker.instance_id => ActiveEndpoint::Verified,
        Ok(instance_id) => ActiveEndpoint::Foreign(format!(
            "endpoint identity {instance_id} does not match runtime marker identity {}",
            marker.instance_id
        )),
        Err(reason) => ActiveEndpoint::Foreign(reason),
    }
}

fn read_lock_record(paths: &AppPaths) -> Result<Option<LockRecord>> {
    let metadata = match fs::metadata(&paths.instance_lock_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if metadata.len() > MAX_RUNTIME_MARKER_BYTES {
        return Err(PetCoreError::InvalidRequest(format!(
            "instance lock record exceeds {MAX_RUNTIME_MARKER_BYTES} bytes"
        )));
    }
    let record = serde_json::from_slice(&fs::read(&paths.instance_lock_path)?)?;
    Ok(Some(record))
}

fn process_exists(pid: u32) -> bool {
    let Ok(raw_pid) = i32::try_from(pid) else {
        return false;
    };
    let Some(pid) = rustix::process::Pid::from_raw(raw_pid) else {
        return false;
    };
    matches!(
        rustix::process::test_kill_process(pid),
        Ok(()) | Err(rustix::io::Errno::PERM)
    )
}

fn probe_instance_identity(mut stream: UnixStream) -> std::result::Result<String, String> {
    let deadline = std::time::Instant::now() + INSTANCE_PROBE_TIMEOUT;
    let request = json!({
        "jsonrpc": "2.0",
        "id": "instance-probe",
        "method": "petcore.health",
        "params": {}
    });
    let mut request = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    request.push(b'\n');
    super::write_unix_with_deadline(&mut stream, &request, deadline)
        .map_err(|error| format!("health probe write failed: {error}"))?;
    stream
        .shutdown(Shutdown::Write)
        .map_err(|error| format!("health probe shutdown failed: {error}"))?;
    let response =
        super::read_unix_bounded_with_deadline(&mut stream, deadline, INSTANCE_PROBE_MAX_BYTES)
            .map_err(|error| format!("health probe read failed: {error}"))?;
    let response: Value = serde_json::from_slice(&response)
        .map_err(|error| format!("health probe response is invalid JSON: {error}"))?;
    if response.get("error").is_some() {
        return Err("health probe returned a JSON-RPC error".to_string());
    }
    response
        .get("result")
        .and_then(|result| result.get("instance_id"))
        .and_then(Value::as_str)
        .filter(|instance_id| !instance_id.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| "health probe did not return an instance identity".to_string())
}

fn already_running(path: &Path) -> PetCoreError {
    PetCoreError::InvalidRequest(format!(
        "petcore is already running; its local endpoint is already active at {}",
        path.display()
    ))
}
