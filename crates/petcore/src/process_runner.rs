use crate::{PetCoreError, Result};
use rustix::fs::{fcntl_getfl, fcntl_setfl, OFlags};
use rustix::io::Errno;
use rustix::process::{
    getpid, kill_process, kill_process_group, test_kill_process_group, Pid, Signal,
};
use std::ffi::OsString;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStderr, ChildStdout, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::NamedTempFile;

pub const CONNECTOR_PROCESS_TIMEOUT: Duration = Duration::from_secs(5);
pub const CONNECTOR_MAX_STDOUT: usize = 64 * 1024;
pub const CONNECTOR_MAX_STDERR: usize = 64 * 1024;

/// Capability-scoped registry inherited by a launched process.
///
/// The process group is the primary ownership boundary. A helper that
/// intentionally daemonizes with `setsid`/`setpgid` must append its positive
/// PID followed by `\n` to this private file *before the command leader exits*.
/// PetCore captures the PID's start identity and terminates that exact process
/// at the deadline. A process that deliberately clears this environment value
/// and escapes its group is outside the portable macOS/Linux ownership
/// contract; there is no cross-platform kernel primitive that lets an
/// unprivileged parent reclaim an arbitrary double-forked orphan. Nonblocking
/// pipe reads still ensure such a non-cooperating process cannot make this
/// function wait past its final cleanup deadline.
pub const PROCESS_OWNERSHIP_FILE_ENV: &str = "APC_PROCESS_RUNNER_OWNERSHIP_FILE_V1";

const POLL_INTERVAL: Duration = Duration::from_millis(5);
const TERM_GRACE: Duration = Duration::from_millis(150);
const KILL_GRACE: Duration = Duration::from_millis(150);
const MAX_REGISTERED_PROCESSES: usize = 256;
const MAX_OWNERSHIP_FILE_BYTES: u64 = 8 * 1024;

#[derive(Debug, Clone)]
pub struct ProcessSpec {
    pub program: OsString,
    pub args: Vec<OsString>,
    pub timeout: Duration,
    pub max_stdout: usize,
    pub max_stderr: usize,
    env: Vec<(OsString, OsString)>,
}

impl ProcessSpec {
    pub fn new<P, I, S>(program: P, args: I, timeout: Duration) -> Self
    where
        P: Into<OsString>,
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            timeout,
            max_stdout: CONNECTOR_MAX_STDOUT,
            max_stderr: CONNECTOR_MAX_STDERR,
            env: Vec::new(),
        }
    }

    pub fn connector<P, I, S>(program: P, args: I) -> Self
    where
        P: Into<OsString>,
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Self::new(program, args, CONNECTOR_PROCESS_TIMEOUT)
    }

    pub fn with_output_limits(mut self, max_stdout: usize, max_stderr: usize) -> Self {
        self.max_stdout = max_stdout;
        self.max_stderr = max_stderr;
        self
    }

    pub fn with_env<K, V>(mut self, key: K, value: V) -> Self
    where
        K: Into<OsString>,
        V: Into<OsString>,
    {
        self.env.push((key.into(), value.into()));
        self
    }
}

#[derive(Debug)]
pub struct ProcessResult {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
    pub timed_out: bool,
}

#[derive(Debug)]
struct BoundedRead {
    bytes: Vec<u8>,
    truncated: bool,
    eof: bool,
}

impl BoundedRead {
    fn new(max_bytes: usize) -> Self {
        Self {
            bytes: Vec::with_capacity(max_bytes.min(8 * 1024)),
            truncated: false,
            eof: false,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ProcessStart {
    coarse: u64,
    fine: u64,
}

#[derive(Clone, Copy, Debug)]
struct ProcessSnapshot {
    start: ProcessStart,
    zombie: bool,
    parent: Option<Pid>,
    process_group: Option<Pid>,
}

#[derive(Clone, Copy, Debug)]
struct ProcessIdentity {
    pid: Pid,
    start: ProcessStart,
}

impl ProcessIdentity {
    fn capture(pid: Pid) -> Option<Self> {
        let snapshot = process_snapshot(pid)?;
        (!snapshot.zombie).then_some(Self {
            pid,
            start: snapshot.start,
        })
    }

    fn is_alive(self) -> bool {
        process_snapshot(self.pid)
            .is_some_and(|snapshot| !snapshot.zombie && snapshot.start == self.start)
    }

    fn signal(self, signal: Signal) {
        if self.is_alive() {
            let _ = kill_process(self.pid, signal);
        }
    }
}

struct OwnershipRegistry {
    file: NamedTempFile,
    processes: Vec<ProcessIdentity>,
    accepted_pids: Vec<Pid>,
}

impl OwnershipRegistry {
    fn new() -> io::Result<Self> {
        Ok(Self {
            file: NamedTempFile::new()?,
            processes: Vec::new(),
            accepted_pids: Vec::new(),
        })
    }

    fn path(&self) -> &std::path::Path {
        self.file.path()
    }

    fn refresh(&mut self, process_group: Pid) {
        let mut bytes = Vec::new();
        {
            let file = self.file.as_file_mut();
            if file.seek(SeekFrom::Start(0)).is_err() {
                return;
            }
            if file
                .take(MAX_OWNERSHIP_FILE_BYTES + 1)
                .read_to_end(&mut bytes)
                .is_err()
            {
                return;
            }
        }
        bytes.truncate(MAX_OWNERSHIP_FILE_BYTES as usize);
        for line in String::from_utf8_lossy(&bytes).lines() {
            if self.accepted_pids.len() >= MAX_REGISTERED_PROCESSES {
                break;
            }
            let Ok(raw_pid) = line.trim().parse::<i32>() else {
                continue;
            };
            let Some(pid) = Pid::from_raw(raw_pid) else {
                continue;
            };
            if pid.is_init()
                || pid == getpid()
                || self.accepted_pids.contains(&pid)
                || !is_owned_descendant(pid, process_group)
            {
                continue;
            }
            if let Some(identity) = ProcessIdentity::capture(pid) {
                self.processes.push(identity);
                self.accepted_pids.push(pid);
                self.acknowledge(pid);
            }
        }
    }

    fn acknowledge(&mut self, pid: Pid) {
        let file = self.file.as_file_mut();
        if file.seek(SeekFrom::End(0)).is_ok() {
            let _ = writeln!(file, "ACK {pid}");
            let _ = file.flush();
        }
    }

    fn has_live_processes(&mut self) -> bool {
        self.processes.retain(|identity| identity.is_alive());
        !self.processes.is_empty()
    }

    fn signal(&mut self, signal: Signal) {
        self.processes.retain(|identity| identity.is_alive());
        for process in &self.processes {
            process.signal(signal);
        }
    }
}

/// Runs an external command with bounded output, a hard execution deadline,
/// and two explicit descendant ownership mechanisms:
///
/// 1. every command starts in a dedicated process group; and
/// 2. a daemonizing helper can register exact PIDs through
///    [`PROCESS_OWNERSHIP_FILE_ENV`].
///
/// Output pipes are nonblocking, so neither inherited descriptors nor a
/// non-cooperating escaped orphan can make the caller wait forever. Normal
/// execution is bounded by `spec.timeout`; cleanup adds at most `TERM_GRACE +
/// KILL_GRACE` (plus one polling interval) before returning an error if the
/// direct child cannot be reaped.
pub fn run_bounded(spec: ProcessSpec) -> Result<ProcessResult> {
    let mut registry = OwnershipRegistry::new()?;
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.args)
        .envs(spec.env.iter().map(|(key, value)| (key, value)))
        .env(PROCESS_OWNERSHIP_FILE_ENV, registry.path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);

    let mut child = command.spawn()?;
    let process_group = Pid::from_child(&child);
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| PetCoreError::Io(io::Error::other("spawned process has no stdout pipe")))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| PetCoreError::Io(io::Error::other("spawned process has no stderr pipe")))?;
    set_nonblocking(&stdout)?;
    set_nonblocking(&stderr)?;

    let mut captured_stdout = BoundedRead::new(spec.max_stdout);
    let mut captured_stderr = BoundedRead::new(spec.max_stderr);
    let deadline = Instant::now() + spec.timeout;
    let mut status = None;
    let mut timed_out = false;

    loop {
        observe_process(
            &mut child,
            &mut status,
            &mut stdout,
            &mut captured_stdout,
            spec.max_stdout,
            &mut stderr,
            &mut captured_stderr,
            spec.max_stderr,
            process_group,
            &mut registry,
        )?;

        if status.is_some()
            && !owned_processes_alive(process_group, &mut registry)
            && captured_stdout.eof
            && captured_stderr.eof
        {
            break;
        }
        if Instant::now() >= deadline {
            timed_out = true;
            break;
        }
        sleep_bounded(deadline);
    }

    if timed_out {
        signal_owned(process_group, &mut registry, Signal::TERM);
        cleanup_until(
            Instant::now() + TERM_GRACE,
            &mut child,
            &mut status,
            &mut stdout,
            &mut captured_stdout,
            spec.max_stdout,
            &mut stderr,
            &mut captured_stderr,
            spec.max_stderr,
            process_group,
            &mut registry,
        )?;

        signal_owned(process_group, &mut registry, Signal::KILL);
        cleanup_until(
            Instant::now() + KILL_GRACE,
            &mut child,
            &mut status,
            &mut stdout,
            &mut captured_stdout,
            spec.max_stdout,
            &mut stderr,
            &mut captured_stderr,
            spec.max_stderr,
            process_group,
            &mut registry,
        )?;

        if owned_processes_alive(process_group, &mut registry) {
            return Err(PetCoreError::Io(io::Error::new(
                io::ErrorKind::TimedOut,
                "owned external-process descendants survived the final cleanup deadline",
            )));
        }
    }

    drain_nonblocking(&mut stdout, &mut captured_stdout, spec.max_stdout);
    drain_nonblocking(&mut stderr, &mut captured_stderr, spec.max_stderr);
    captured_stdout.truncated |= !captured_stdout.eof;
    captured_stderr.truncated |= !captured_stderr.eof;

    let status = status.ok_or_else(|| {
        PetCoreError::Io(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "external process {} did not exit by the final cleanup deadline",
                process_group
            ),
        ))
    })?;

    Ok(ProcessResult {
        status,
        stdout: captured_stdout.bytes,
        stderr: captured_stderr.bytes,
        stdout_truncated: captured_stdout.truncated,
        stderr_truncated: captured_stderr.truncated,
        timed_out,
    })
}

#[allow(clippy::too_many_arguments)]
fn observe_process(
    child: &mut Child,
    status: &mut Option<ExitStatus>,
    stdout: &mut ChildStdout,
    captured_stdout: &mut BoundedRead,
    max_stdout: usize,
    stderr: &mut ChildStderr,
    captured_stderr: &mut BoundedRead,
    max_stderr: usize,
    process_group: Pid,
    registry: &mut OwnershipRegistry,
) -> Result<()> {
    registry.refresh(process_group);
    drain_nonblocking(stdout, captured_stdout, max_stdout);
    drain_nonblocking(stderr, captured_stderr, max_stderr);
    if status.is_none() {
        if let Some(observed) = child.try_wait()? {
            *status = Some(observed);
            // Cooperative daemon descendants must register before the leader
            // exits. Refresh once more after observing that exit so there is
            // no polling race between the registry append and `try_wait`.
            registry.refresh(process_group);
            drain_nonblocking(stdout, captured_stdout, max_stdout);
            drain_nonblocking(stderr, captured_stderr, max_stderr);
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn cleanup_until(
    deadline: Instant,
    child: &mut Child,
    status: &mut Option<ExitStatus>,
    stdout: &mut ChildStdout,
    captured_stdout: &mut BoundedRead,
    max_stdout: usize,
    stderr: &mut ChildStderr,
    captured_stderr: &mut BoundedRead,
    max_stderr: usize,
    process_group: Pid,
    registry: &mut OwnershipRegistry,
) -> Result<()> {
    loop {
        observe_process(
            child,
            status,
            stdout,
            captured_stdout,
            max_stdout,
            stderr,
            captured_stderr,
            max_stderr,
            process_group,
            registry,
        )?;
        if status.is_some() && !owned_processes_alive(process_group, registry) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Ok(());
        }
        sleep_bounded(deadline);
    }
}

fn signal_owned(process_group: Pid, registry: &mut OwnershipRegistry, signal: Signal) {
    let _ = kill_process_group(process_group, signal);
    registry.refresh(process_group);
    registry.signal(signal);
}

fn owned_processes_alive(process_group: Pid, registry: &mut OwnershipRegistry) -> bool {
    process_group_alive(process_group) || registry.has_live_processes()
}

fn process_group_alive(process_group: Pid) -> bool {
    match test_kill_process_group(process_group) {
        Ok(()) => true,
        Err(Errno::SRCH) => false,
        Err(_) => true,
    }
}

fn is_owned_descendant(pid: Pid, process_group: Pid) -> bool {
    let mut current = pid;
    for _ in 0..64 {
        let Some(snapshot) = process_snapshot(current) else {
            return false;
        };
        if snapshot.process_group == Some(process_group) || current == process_group {
            return true;
        }
        let Some(parent) = snapshot.parent else {
            return false;
        };
        if parent.is_init() || parent == current {
            return false;
        }
        current = parent;
    }
    false
}

fn set_nonblocking(fd: &impl AsFd) -> Result<()> {
    let flags = fcntl_getfl(fd.as_fd()).map_err(io::Error::from)?;
    fcntl_setfl(fd.as_fd(), flags | OFlags::NONBLOCK).map_err(io::Error::from)?;
    Ok(())
}

fn drain_nonblocking(reader: &mut impl Read, captured: &mut BoundedRead, max_bytes: usize) {
    if captured.eof {
        return;
    }
    let mut buffer = [0_u8; 8 * 1024];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                captured.eof = true;
                return;
            }
            Ok(read) => {
                let available = max_bytes.saturating_sub(captured.bytes.len());
                let keep = available.min(read);
                captured.bytes.extend_from_slice(&buffer[..keep]);
                captured.truncated |= keep < read;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return,
            Err(_) => {
                captured.truncated = true;
                captured.eof = true;
                return;
            }
        }
    }
}

fn sleep_bounded(deadline: Instant) {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if !remaining.is_zero() {
        thread::sleep(remaining.min(POLL_INTERVAL));
    }
}

#[cfg(target_os = "linux")]
fn process_snapshot(pid: Pid) -> Option<ProcessSnapshot> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields = stat.get(stat.rfind(") ")? + 2..)?;
    let mut fields = fields.split_whitespace();
    let state = fields.next()?;
    let parent = Pid::from_raw(fields.next()?.parse::<i32>().ok()?);
    let process_group = Pid::from_raw(fields.next()?.parse::<i32>().ok()?);
    let start_ticks = fields.nth(16)?.parse::<u64>().ok()?;
    Some(ProcessSnapshot {
        start: ProcessStart {
            coarse: start_ticks,
            fine: 0,
        },
        zombie: state == "Z",
        parent,
        process_group,
    })
}

#[cfg(target_os = "macos")]
fn process_snapshot(pid: Pid) -> Option<ProcessSnapshot> {
    use std::mem::{size_of, MaybeUninit};
    use std::os::raw::{c_char, c_int, c_void};

    const PROC_PIDTBSDINFO: c_int = 3;
    const SZOMB: u32 = 5;
    const MAXCOMLEN: usize = 16;

    #[repr(C)]
    struct ProcBsdInfo {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [c_char; MAXCOMLEN],
        pbi_name: [c_char; 2 * MAXCOMLEN],
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    }

    #[link(name = "proc")]
    extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            buffer_size: c_int,
        ) -> c_int;
    }

    let mut info = MaybeUninit::<ProcBsdInfo>::zeroed();
    let expected_size = size_of::<ProcBsdInfo>();
    // SAFETY: `info` points to writable storage of exactly `expected_size`;
    // `PROC_PIDTBSDINFO` initializes the full `ProcBsdInfo` on success.
    let read = unsafe {
        proc_pidinfo(
            pid.as_raw_pid(),
            PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            expected_size as c_int,
        )
    };
    if read != expected_size as c_int {
        return None;
    }
    // SAFETY: the exact-size success check above proves initialization.
    let info = unsafe { info.assume_init() };
    Some(ProcessSnapshot {
        start: ProcessStart {
            coarse: info.pbi_start_tvsec,
            fine: info.pbi_start_tvusec,
        },
        zombie: info.pbi_status == SZOMB,
        parent: Pid::from_raw(i32::try_from(info.pbi_ppid).ok()?),
        process_group: Pid::from_raw(i32::try_from(info.pbi_pgid).ok()?),
    })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn process_snapshot(pid: Pid) -> Option<ProcessSnapshot> {
    rustix::process::test_kill_process(pid).ok()?;
    Some(ProcessSnapshot {
        start: ProcessStart { coarse: 0, fine: 0 },
        zombie: false,
        parent: None,
        process_group: None,
    })
}
