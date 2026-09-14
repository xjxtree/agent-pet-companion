//! Read only process identity, executable path and parent edges, never argv,
//! environment blocks, credential files or transcript history.
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Identity {
    pub pid: u32,
    pub started: u64,
    pub started_fraction: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Process {
    pub identity: Identity,
    pub parent: u32,
    pub uid: u32,
    pub executable: PathBuf,
}

impl Process {
    pub fn is_claude_engine(&self) -> bool {
        let path = &self.executable;
        path.file_name()
            .is_some_and(|name| name == "claude" || name == "claude.exe")
            || path
                .parent()
                .is_some_and(|p| p.ends_with("claude/versions"))
                && path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|name| {
                        let parts: Vec<_> = name.split('.').collect();
                        parts.len() == 3
                            && parts
                                .iter()
                                .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
                    })
    }

    pub fn is_claude_desktop(&self) -> bool {
        self.executable
            .ends_with("Claude.app/Contents/MacOS/Claude")
    }
}

#[cfg(target_os = "macos")]
pub(super) fn inspect(pid: u32) -> Option<Process> {
    use std::mem::{size_of, MaybeUninit};
    use std::os::raw::{c_char, c_int, c_void};
    use std::os::unix::ffi::OsStringExt;

    // libproc's PROC_PIDTBSDINFO ABI, shared with the existing process runner.
    #[repr(C)]
    struct BsdInfo {
        flags: u32,
        status: u32,
        xstatus: u32,
        pid: u32,
        ppid: u32,
        uid: u32,
        gid: u32,
        ruid: u32,
        rgid: u32,
        svuid: u32,
        svgid: u32,
        reserved: u32,
        comm: [c_char; 16],
        name: [c_char; 32],
        nfiles: u32,
        pgid: u32,
        pjobc: u32,
        tdev: u32,
        tpgid: u32,
        nice: i32,
        start_sec: u64,
        start_usec: u64,
    }
    #[link(name = "proc")]
    extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            size: c_int,
        ) -> c_int;
        fn proc_pidpath(pid: c_int, buffer: *mut c_void, size: u32) -> c_int;
    }
    let pid_int = i32::try_from(pid).ok()?;
    let mut info = MaybeUninit::<BsdInfo>::zeroed();
    let size = size_of::<BsdInfo>();
    // SAFETY: the kernel writes at most the supplied size into this allocation;
    // initialization is accepted only when the exact ABI size was returned.
    if unsafe { proc_pidinfo(pid_int, 3, 0, info.as_mut_ptr().cast(), size as c_int) }
        != size as c_int
    {
        return None;
    }
    // SAFETY: the exact-size success check above proves initialization.
    let info = unsafe { info.assume_init() };
    if info.pid != pid || info.status == 5 || info.start_sec == 0 {
        return None;
    }
    let mut bytes = [0_u8; 4096];
    // SAFETY: bytes is writable for exactly the size supplied to libproc.
    let count = unsafe { proc_pidpath(pid_int, bytes.as_mut_ptr().cast(), bytes.len() as u32) };
    if count <= 0 || count as usize >= bytes.len() {
        return None;
    }
    let end = bytes.iter().position(|b| *b == 0)?;
    Some(Process {
        identity: Identity {
            pid,
            started: info.start_sec,
            started_fraction: info.start_usec,
        },
        parent: info.ppid,
        uid: info.uid,
        executable: std::ffi::OsString::from_vec(bytes[..end].to_vec()).into(),
    })
}

#[cfg(target_os = "linux")]
pub(super) fn inspect(pid: u32) -> Option<Process> {
    use std::io::Read;
    use std::os::unix::fs::MetadataExt;
    let root = PathBuf::from(format!("/proc/{pid}"));
    let uid = root.metadata().ok()?.uid();
    let mut stat = String::new();
    std::fs::File::open(root.join("stat"))
        .ok()?
        .take(4097)
        .read_to_string(&mut stat)
        .ok()?;
    if stat.len() > 4096 {
        return None;
    }
    let mut fields = stat.get(stat.rfind(") ")? + 2..)?.split_whitespace();
    if fields.next()? == "Z" {
        return None;
    }
    let parent = fields.next()?.parse().ok()?;
    let started = fields.nth(17)?.parse().ok()?;
    Some(Process {
        identity: Identity {
            pid,
            started,
            started_fraction: 0,
        },
        parent,
        uid,
        executable: std::fs::read_link(root.join("exe")).ok()?,
    })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(super) fn inspect(_pid: u32) -> Option<Process> {
    None
}
