use petcore::app_server::probe_codex_app_server;
use petcore::paths::AppPaths;
use petcore_types::{GenerationForm, QualityLevel};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ENV_LOCK: Mutex<()> = Mutex::new(());

struct EnvGuard {
    key: &'static str,
    original: Option<OsString>,
}

impl EnvGuard {
    fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
        let original = std::env::var_os(key);
        std::env::set_var(key, value);
        Self { key, original }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        if let Some(value) = &self.original {
            std::env::set_var(self.key, value);
        } else {
            std::env::remove_var(self.key);
        }
    }
}

#[test]
fn stdout_eof_fails_immediately_with_exit_diagnostics() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("exits-immediately.sh");
    std::fs::write(
        &script,
        "#!/bin/sh\necho 'synthetic app-server failure' >&2\nexit 17\n",
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());

    let started = Instant::now();
    let result = probe_codex_app_server();
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_millis(700),
        "EOF was treated as a timeout and took {elapsed:?}: {result}"
    );
    assert_eq!(
        result.pointer("/error_info/kind").and_then(|v| v.as_str()),
        Some("stdout_eof"),
        "{result}"
    );
    let serialized = result.to_string();
    assert!(
        serialized.contains("synthetic app-server failure"),
        "{result}"
    );
    assert!(serialized.contains("17"), "{result}");
}

#[test]
fn turn_event_stdout_eof_fails_immediately() {
    let _lock = ENV_LOCK.lock().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("exits-during-turn.sh");
    std::fs::write(
        &script,
        r#"#!/bin/sh
while IFS= read -r request; do
  case "$request" in
    *\"method\":\"initialize\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"eof-test"}}}'
      ;;
    *\"method\":\"thread/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread_eof","sessionId":"thread_eof"}}}'
      ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn_eof","status":"inProgress"}}}'
      echo 'turn stream ended unexpectedly' >&2
      exit 23
      ;;
  esac
done
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let _command = EnvGuard::set("CODEX_APP_SERVER_CMD", script.as_os_str());
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let form = GenerationForm {
        description: "EOF transport pet".to_string(),
        style: "半写实".to_string(),
        quality: QualityLevel::Standard,
        reference_images: Vec::new(),
    };

    let started = Instant::now();
    let result = petcore::app_server::run_pet_studio_session(&paths, "job_eof", &form);
    let elapsed = started.elapsed();

    assert!(elapsed < Duration::from_secs(1), "{elapsed:?}: {result}");
    assert_eq!(
        result.pointer("/error_info/kind").and_then(|v| v.as_str()),
        Some("stdout_eof"),
        "{result}"
    );
    let serialized = result.to_string();
    assert!(serialized.contains("23"), "{result}");
    assert!(
        serialized.contains("turn stream ended unexpectedly"),
        "{result}"
    );
}
