//! Live Claude hook ancestry. Kernel metadata and session associations stay in
//! this bounded, process-local registry; only the existing child marker or
//! corroborated navigation surface enters the ordinary event projection.
mod process;
#[cfg(test)]
mod tests;

use super::*;
use process::{Identity, Process};

const MAX_ANCESTORS: usize = 32;
const MAX_REGISTERED_PROCESSES: usize = 256;

#[derive(Debug, Default)]
pub(super) struct ProcessRegistry {
    entries: BTreeMap<Identity, Association>,
    sequence: u64,
}

#[derive(Debug)]
struct Association {
    // None fences multiplexed process identities: they cannot identify one
    // owning session reliably. Never persist either raw or opaque parent IDs.
    session: Option<String>,
    touched: u64,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Origin {
    Unknown,
    Cli,
    Desktop,
    Nested,
}

impl ProcessRegistry {
    fn observe(&mut self, session: &str, chain: &[Process]) -> Origin {
        let Some(engine_index) = chain.iter().position(Process::is_claude_engine) else {
            return Origin::Unknown;
        };
        let engine = &chain[engine_index];
        let ancestors = &chain[engine_index + 1..];
        self.sequence = self.sequence.saturating_add(1);
        let mut nested = false;
        for ancestor in ancestors.iter().filter(|p| p.is_claude_engine()) {
            if let Some(entry) = self.entries.get_mut(&ancestor.identity) {
                if let Some(parent) = &entry.session {
                    nested |= parent != session;
                    // A busy parent remains recent while launching many children.
                    entry.touched = self.sequence;
                }
            }
        }
        // PID reuse can never inherit an association from an older start time.
        self.entries
            .retain(|id, _| id.pid != engine.identity.pid || *id == engine.identity);
        if !self.entries.contains_key(&engine.identity)
            && self.entries.len() >= MAX_REGISTERED_PROCESSES
        {
            if let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.touched)
                .map(|(id, _)| *id)
            {
                self.entries.remove(&oldest);
            }
        }
        self.entries
            .entry(engine.identity)
            .and_modify(|entry| {
                if entry.session.as_deref() != Some(session) {
                    entry.session = None;
                }
                entry.touched = self.sequence;
            })
            .or_insert_with(|| Association {
                session: Some(session.to_string()),
                touched: self.sequence,
            });
        if nested {
            Origin::Nested
        } else if ancestors
            .iter()
            .take_while(|p| !p.is_claude_engine())
            .any(Process::is_claude_desktop)
        {
            Origin::Desktop
        } else {
            Origin::Cli
        }
    }
}

fn ancestry(
    hook_pid: u32,
    mut inspect: impl FnMut(u32) -> Option<Process>,
) -> Option<Vec<Process>> {
    let mut chain = Vec::<Process>::new();
    let mut pid = hook_pid;
    for _ in 0..MAX_ANCESTORS {
        if pid <= 1 {
            break;
        }
        let process = inspect(pid)?;
        if process.identity.pid != pid || chain.iter().any(|p| p.identity.pid == pid) {
            return None;
        }
        if process.uid != rustix::process::getuid().as_raw() {
            break;
        }
        pid = process.parent;
        chain.push(process);
    }
    if chain.len() == MAX_ANCESTORS {
        return None;
    }
    // Fail conservatively if an ancestor exited, exec'd or was reparented
    // while walking. No stale PID/parent edge may prove nested execution.
    for process in &chain {
        if inspect(process.identity.pid).as_ref() != Some(process) {
            return None;
        }
    }
    Some(chain)
}

pub(super) fn context(state: &CoreState, params: &Value) -> Result<Value> {
    let hook_pid = params
        .get("hook_pid")
        .and_then(Value::as_u64)
        .and_then(|pid| u32::try_from(pid).ok())
        .filter(|pid| *pid > 1 && *pid <= i32::MAX as u32)
        .ok_or_else(|| invalid_params("hook_pid must be a positive process ID"))?;
    let session = required_string(params, "session_id")?;
    if session.is_empty() || session.len() > 256 {
        return Err(invalid_params("session_id must contain 1 to 256 bytes"));
    }
    let origin = match ancestry(hook_pid, process::inspect) {
        Some(chain) => state
            .claude_hook_processes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .observe(&hex::encode(Sha256::digest(session.as_bytes())), &chain),
        None => Origin::Unknown,
    };
    Ok(json!({"origin": origin}))
}
