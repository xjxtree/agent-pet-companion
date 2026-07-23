use petcore::daemon;
use petcore::daemon::instance_lock::{read_runtime_marker, InstanceGuard, RuntimeMarker};
use petcore::db::Database;
use petcore::paths::AppPaths;
use petcore_types::{GenerationForm, GenerationJobStatus, OverlayPlacement, QualityLevel};
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const MAX_RPC_BATCH_ITEMS: usize = 64;
const MAX_UDS_FRAME_BYTES: usize = 256 * 1024;

struct TestDaemon {
    child: Child,
    _temp: tempfile::TempDir,
    paths: AppPaths,
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_daemon() -> TestDaemon {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let ready_file = temp.path().join("daemon-ready");
    let child = Command::new(env!("CARGO_BIN_EXE_petcore"))
        .args([
            "serve",
            "--home",
            paths.home.to_str().unwrap(),
            "--ready-file",
            ready_file.to_str().unwrap(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let daemon = TestDaemon {
        child,
        _temp: temp,
        paths,
    };
    wait_for_file(&ready_file);
    daemon
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.exists() {
        assert!(
            Instant::now() < deadline,
            "expected file was not created: {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn uds_exchange(paths: &AppPaths, payload: &[u8]) -> Vec<u8> {
    let mut stream = UnixStream::connect(&paths.socket_path).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(7)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(7)))
        .unwrap();
    stream.write_all(payload).unwrap();
    stream.shutdown(Shutdown::Write).unwrap();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();
    response
}

fn rpc_exchange(paths: &AppPaths, request: Value) -> Value {
    let mut payload = serde_json::to_vec(&request).unwrap();
    payload.push(b'\n');
    let response = uds_exchange(paths, &payload);
    serde_json::from_slice(trim_ascii(&response)).unwrap_or_else(|error| {
        panic!(
            "expected JSON-RPC response, got {:?}: {error}",
            String::from_utf8_lossy(&response)
        )
    })
}

fn trim_ascii(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map(|index| index + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

fn spawn_fake_health_listener(
    listener: UnixListener,
    instance_id: String,
) -> std::thread::JoinHandle<()> {
    listener.set_nonblocking(true).unwrap();
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let mut request = String::new();
                    let _ = stream.read_to_string(&mut request);
                    let response = json!({
                        "jsonrpc": "2.0",
                        "id": "instance-probe",
                        "result": { "ok": true, "instance_id": instance_id }
                    });
                    let _ = stream.write_all(serde_json::to_string(&response).unwrap().as_bytes());
                    let _ = stream.write_all(b"\n");
                    return;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "identity probe never connected");
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("fake listener failed: {error}"),
            }
        }
    })
}

#[test]
fn second_daemon_does_not_recover_first_daemon_jobs() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let database = Database::new(paths.db_path.clone());
    database.init().unwrap();
    let job_id = "job_owned_by_first_daemon";
    let job_dir = paths.jobs_dir.join(job_id);
    fs::create_dir_all(&job_dir).unwrap();
    let form = GenerationForm {
        description: "singleton regression".to_string(),
        style: "pixel".to_string(),
        quality: QualityLevel::High,
        reference_images: Vec::new(),
        native_fps: petcore_types::DEFAULT_NATIVE_FPS,
        state_durations_ms: petcore_types::default_state_durations_ms(),
    };
    database
        .create_generation_job(job_id, &form, &job_dir)
        .unwrap();
    database
        .update_generation_job(job_id, GenerationJobStatus::Running, None)
        .unwrap();

    let _first = InstanceGuard::acquire(&paths).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_petcore"))
        .args(["serve", "--home", paths.home.to_str().unwrap()])
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("instance lock"));
    assert_eq!(
        database.generation_job_status(job_id).unwrap(),
        Some(GenerationJobStatus::Running)
    );
}

#[test]
fn init_respects_daemon_instance_lock() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let _guard = InstanceGuard::acquire(&paths).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_petcore"))
        .arg("init")
        .env("APC_HOME", &paths.home)
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("instance lock"));
    assert!(!paths.db_path.exists());
}

#[test]
fn uds_rejects_request_larger_than_256k() {
    let daemon = start_daemon();
    let oversized = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "petcore.health",
        "padding": "x".repeat(MAX_UDS_FRAME_BYTES)
    });
    let mut payload = serde_json::to_vec(&oversized).unwrap();
    assert!(payload.len() > MAX_UDS_FRAME_BYTES);
    payload.push(b'\n');

    let response: Value =
        serde_json::from_slice(trim_ascii(&uds_exchange(&daemon.paths, &payload))).unwrap();
    assert_eq!(response["error"]["code"], -32600);
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("262144"));
}

#[test]
fn uds_times_out_partial_line() {
    let daemon = start_daemon();
    let mut stream = UnixStream::connect(&daemon.paths.socket_path).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(7)))
        .unwrap();
    stream.write_all(b"{").unwrap();
    let started = Instant::now();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();
    let elapsed = started.elapsed();
    let response: Value = serde_json::from_slice(trim_ascii(&response)).unwrap();

    assert!(
        elapsed >= Duration::from_millis(4_500),
        "elapsed: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_millis(5_800),
        "elapsed: {elapsed:?}"
    );
    assert_eq!(response["error"]["code"], -32000);
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("timed out"));
}

#[test]
fn uds_response_write_has_one_absolute_deadline_for_a_slow_reader() {
    let daemon = start_daemon();
    let stored_value = "x".repeat(248 * 1024);
    daemon::request(
        &daemon.paths,
        "settings.update",
        json!({ "key": "diagnostic.slow_reader_response", "value": stored_value }),
    )
    .unwrap();

    let mut stream = UnixStream::connect(&daemon.paths.socket_path).unwrap();
    rustix::net::sockopt::set_socket_recv_buffer_size(&stream, 1024).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    let mut request = serde_json::to_vec(&json!({
        "jsonrpc": "2.0",
        "id": "slow-reader",
        "method": "settings.get",
        "params": { "key": "diagnostic.slow_reader_response" }
    }))
    .unwrap();
    request.push(b'\n');
    stream.write_all(&request).unwrap();
    stream.shutdown(Shutdown::Write).unwrap();

    let started = Instant::now();
    let slow_read_until = started + Duration::from_millis(5_300);
    let mut response = Vec::new();
    let mut chunk = [0u8; 512];
    while Instant::now() < slow_read_until {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => response.extend_from_slice(&chunk[..read]),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(error) => panic!("slow reader failed: {error}"),
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => response.extend_from_slice(&chunk[..read]),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) =>
            {
                break
            }
            Err(error) => panic!("response drain failed: {error}"),
        }
    }
    let elapsed = started.elapsed();

    assert!(
        elapsed >= Duration::from_millis(4_500),
        "elapsed: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_millis(6_500),
        "elapsed: {elapsed:?}"
    );
    assert!(
        response.len() < 248 * 1024,
        "server wrote the complete oversized response to a slow reader"
    );
}

#[test]
fn uds_concurrency_is_bounded() {
    let daemon = start_daemon();
    let mut held_clients = Vec::new();
    for _ in 0..32 {
        let mut stream = UnixStream::connect(&daemon.paths.socket_path).unwrap();
        stream.write_all(b"{").unwrap();
        held_clients.push(stream);
    }
    std::thread::sleep(Duration::from_millis(300));

    let response = rpc_exchange(
        &daemon.paths,
        json!({ "jsonrpc": "2.0", "id": 33, "method": "petcore.health" }),
    );
    assert_eq!(response["error"]["code"], -32000);
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("busy"));

    for mut client in held_clients {
        client
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        client.write_all(b"}\n").unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let mut ignored = Vec::new();
        client.read_to_end(&mut ignored).unwrap();
    }
}

#[test]
fn rpc_rejects_missing_or_wrong_version() {
    let daemon = start_daemon();
    let missing = rpc_exchange(
        &daemon.paths,
        json!({ "id": 1, "method": "petcore.health" }),
    );
    let wrong = rpc_exchange(
        &daemon.paths,
        json!({ "jsonrpc": "1.0", "id": 2, "method": "petcore.health" }),
    );

    assert_eq!(missing["error"]["code"], -32600);
    assert_eq!(missing["id"], Value::Null);
    assert_eq!(wrong["error"]["code"], -32600);
    assert_eq!(wrong["id"], Value::Null);
}

#[test]
fn rpc_notification_has_no_response() {
    let daemon = start_daemon();
    let mut payload =
        serde_json::to_vec(&json!({ "jsonrpc": "2.0", "method": "petcore.health", "params": {} }))
            .unwrap();
    payload.push(b'\n');

    let response = uds_exchange(&daemon.paths, &payload);
    assert!(response.is_empty(), "notification returned a response");
}

#[test]
fn rpc_batch_returns_only_request_responses() {
    let daemon = start_daemon();
    let response = rpc_exchange(
        &daemon.paths,
        json!([
            { "jsonrpc": "2.0", "method": "petcore.health" },
            { "jsonrpc": "2.0", "id": "health", "method": "petcore.health" }
        ]),
    );

    let responses = response.as_array().unwrap();
    assert_eq!(responses.len(), 1);
    assert_eq!(responses[0]["id"], "health");
    assert_eq!(responses[0]["result"]["ok"], true);
}

#[test]
fn rpc_rejects_batch_larger_than_64_items() {
    let daemon = start_daemon();
    let batch = (0..=MAX_RPC_BATCH_ITEMS)
        .map(|id| json!({ "jsonrpc": "2.0", "id": id, "method": "petcore.health" }))
        .collect::<Vec<_>>();

    let response = rpc_exchange(&daemon.paths, Value::Array(batch));

    assert_eq!(response["error"]["code"], -32600);
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("64"));
}

#[test]
fn rpc_encoded_response_never_exceeds_transport_frame() {
    let daemon = start_daemon();
    daemon::request(
        &daemon.paths,
        "settings.update",
        json!({
            "key": "diagnostic.large_rpc_response",
            "value": "x".repeat(180 * 1024)
        }),
    )
    .unwrap();
    let batch = json!([
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "settings.get",
            "params": { "key": "diagnostic.large_rpc_response" }
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "settings.get",
            "params": { "key": "diagnostic.large_rpc_response" }
        }
    ]);
    let mut payload = serde_json::to_vec(&batch).unwrap();
    payload.push(b'\n');

    let encoded = uds_exchange(&daemon.paths, &payload);
    let response: Value = serde_json::from_slice(trim_ascii(&encoded)).unwrap();

    assert!(encoded.len() <= MAX_UDS_FRAME_BYTES + 1);
    assert_eq!(response["error"]["code"], -32000);
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("response"));
}

#[test]
fn rpc_rejects_wrong_typed_and_out_of_range_named_params() {
    let daemon = start_daemon();
    let requests = json!([
        {
            "jsonrpc": "2.0",
            "id": "connection-source",
            "method": "connections.check",
            "params": { "source": 42 }
        },
        {
            "jsonrpc": "2.0",
            "id": "renderer-profile",
            "method": "renderer.budget",
            "params": { "quality": "high", "fps_profile": false }
        },
        {
            "jsonrpc": "2.0",
            "id": "renderer-fps-type",
            "method": "renderer.budget",
            "params": { "quality": "high", "fps": "20" }
        },
        {
            "jsonrpc": "2.0",
            "id": "renderer-fps-value",
            "method": "renderer.budget",
            "params": { "quality": "high", "fps": 13 }
        },
        {
            "jsonrpc": "2.0",
            "id": "state-revision",
            "method": "state.wait",
            "params": { "after_revision": 7, "timeout_ms": 250 }
        },
        {
            "jsonrpc": "2.0",
            "id": "state-timeout",
            "method": "state.wait",
            "params": { "after_revision": "", "timeout_ms": 30_001 }
        },
        {
            "jsonrpc": "2.0",
            "id": "generation-revision",
            "method": "generation.messages.wait",
            "params": { "job_id": "missing", "after_revision": [], "timeout_ms": 250 }
        },
        {
            "jsonrpc": "2.0",
            "id": "recent-limit",
            "method": "events.recent",
            "params": { "limit": "all" }
        },
        {
            "jsonrpc": "2.0",
            "id": "array-params",
            "method": "connections.check",
            "params": []
        }
    ]);

    let response = rpc_exchange(&daemon.paths, requests);
    let responses = response.as_array().unwrap();

    assert_eq!(responses.len(), 9);
    for response in responses {
        assert_eq!(
            response["error"]["code"], -32602,
            "unexpected response: {response}"
        );
    }
}

#[test]
fn rpc_uses_standard_error_codes() {
    let daemon = start_daemon();
    let parse_error = uds_exchange(&daemon.paths, b"{not-json\n");
    let parse_error: Value = serde_json::from_slice(trim_ascii(&parse_error)).unwrap();
    let unknown = rpc_exchange(
        &daemon.paths,
        json!({ "jsonrpc": "2.0", "id": 1, "method": "does.not.exist" }),
    );
    let invalid_params = rpc_exchange(
        &daemon.paths,
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "behavior.patch",
            "params": "not-an-object"
        }),
    );
    let empty_batch = rpc_exchange(&daemon.paths, json!([]));

    assert_eq!(parse_error["error"]["code"], -32700);
    assert_eq!(unknown["error"]["code"], -32601);
    assert_eq!(invalid_params["error"]["code"], -32602);
    assert_eq!(empty_batch["error"]["code"], -32600);
}

#[test]
fn stale_marker_is_replaced_atomically() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let stale = RuntimeMarker {
        schema_version: "apc.runtime.v1".to_string(),
        pid: u32::MAX,
        process_start: "1970-01-01T00:00:00Z".to_string(),
        instance_id: "instance_stale".to_string(),
        http_port: 1,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&stale).unwrap(),
    )
    .unwrap();
    fs::write(&paths.http_port_path, "1").unwrap();

    let guard = InstanceGuard::acquire(&paths).unwrap();
    guard.publish_runtime(41_234).unwrap();
    let marker = read_runtime_marker(&paths).unwrap().unwrap();

    assert_eq!(marker.instance_id, guard.instance_id());
    assert_eq!(marker.http_port, 41_234);
    assert_eq!(fs::read_to_string(&paths.http_port_path).unwrap(), "41234");
}

#[test]
fn daemon_health_identity_matches_runtime_marker() {
    let daemon = start_daemon();
    let marker = read_runtime_marker(&daemon.paths).unwrap().unwrap();
    let health = rpc_exchange(
        &daemon.paths,
        json!({ "jsonrpc": "2.0", "id": 1, "method": "petcore.health" }),
    );

    assert_eq!(health["result"]["instance_id"], marker.instance_id);
    assert!(health["result"]["build_id"]
        .as_str()
        .is_some_and(|value| !value.is_empty()));
    assert_eq!(marker.schema_version, "apc.runtime.v1");
}

#[test]
fn daemon_shutdown_requires_matching_instance_and_releases_runtime() {
    let mut daemon = start_daemon();
    let health = rpc_exchange(
        &daemon.paths,
        json!({ "jsonrpc": "2.0", "id": 1, "method": "petcore.health" }),
    );
    let instance_id = health["result"]["instance_id"]
        .as_str()
        .unwrap()
        .to_string();

    let rejected = rpc_exchange(
        &daemon.paths,
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "petcore.shutdown",
            "params": { "expected_instance_id": "instance-stale" }
        }),
    );
    assert_eq!(rejected["error"]["code"], -32009);

    let accepted = rpc_exchange(
        &daemon.paths,
        json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "petcore.shutdown",
            "params": { "expected_instance_id": instance_id }
        }),
    );
    assert_eq!(accepted["result"]["ok"], true);

    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if daemon.child.try_wait().unwrap().is_some() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "PetCore did not stop after shutdown handoff"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!daemon.paths.socket_path.exists());
    assert!(!daemon.paths.runtime_marker_path.exists());
}

#[test]
fn live_daemon_lock_marker_and_health_identity_are_accepted_together() {
    let daemon = start_daemon();

    let error = InstanceGuard::acquire(&daemon.paths)
        .unwrap_err()
        .to_string();

    assert!(error.contains("already running"), "{error}");
}

#[test]
fn foreign_listener_with_stale_marker_is_not_accepted_as_petcore() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let marker = RuntimeMarker {
        schema_version: "apc.runtime.v1".to_string(),
        pid: std::process::id(),
        process_start: "1970-01-01T00:00:00Z".to_string(),
        instance_id: "instance_stale".to_string(),
        http_port: 1,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&marker).unwrap(),
    )
    .unwrap();
    let listener = UnixListener::bind(&paths.socket_path).unwrap();
    let responder = spawn_fake_health_listener(listener, "instance_foreign".to_string());

    let error = InstanceGuard::acquire(&paths).unwrap_err().to_string();
    responder.join().unwrap();

    assert!(!error.contains("already running"), "{error}");
    assert!(error.contains("foreign local socket"), "{error}");
    assert!(paths.socket_path.exists());
}

#[test]
fn matching_stale_identity_with_dead_pid_is_not_accepted_as_petcore() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let marker = RuntimeMarker {
        schema_version: "apc.runtime.v1".to_string(),
        pid: u32::MAX,
        process_start: "1970-01-01T00:00:00Z".to_string(),
        instance_id: "instance_stale_but_matching".to_string(),
        http_port: 1,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&marker).unwrap(),
    )
    .unwrap();
    let listener = UnixListener::bind(&paths.socket_path).unwrap();
    let responder = spawn_fake_health_listener(listener, "instance_stale_but_matching".to_string());

    let error = InstanceGuard::acquire(&paths).unwrap_err().to_string();
    responder.join().unwrap();

    assert!(!error.contains("already running"), "{error}");
    assert!(
        error.contains("foreign") || error.contains("identity"),
        "{error}"
    );
    assert!(paths.socket_path.exists());
}

#[test]
fn contended_lock_identity_must_fully_match_runtime_marker() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let first = InstanceGuard::acquire(&paths).unwrap();
    let lock_record: Value =
        serde_json::from_slice(&fs::read(&paths.instance_lock_path).unwrap()).unwrap();
    let marker = RuntimeMarker {
        schema_version: lock_record["schema_version"].as_str().unwrap().to_string(),
        pid: u32::MAX,
        process_start: "1970-01-01T00:00:00Z".to_string(),
        instance_id: first.instance_id().to_string(),
        http_port: 1,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&marker).unwrap(),
    )
    .unwrap();
    let _listener = UnixListener::bind(&paths.socket_path).unwrap();

    let error = InstanceGuard::acquire(&paths).unwrap_err().to_string();

    assert!(!error.contains("already running"), "{error}");
    assert!(
        error.contains("lock") && error.contains("marker"),
        "{error}"
    );
    drop(first);
}

#[test]
fn contended_identity_probe_has_absolute_deadline_for_dripped_health_response() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let first = InstanceGuard::acquire(&paths).unwrap();
    first.publish_runtime(1).unwrap();
    let listener = UnixListener::bind(&paths.socket_path).unwrap();
    let instance_id = first.instance_id().to_string();
    let responder = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = String::new();
        stream.read_to_string(&mut request).unwrap();
        let response = serde_json::to_vec(&json!({
            "jsonrpc": "2.0",
            "id": "instance-probe",
            "result": { "ok": true, "instance_id": instance_id }
        }))
        .unwrap();
        for byte in response.iter().take(16) {
            if stream.write_all(std::slice::from_ref(byte)).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    });

    let started = Instant::now();
    let error = InstanceGuard::acquire(&paths).unwrap_err().to_string();
    let elapsed = started.elapsed();
    responder.join().unwrap();

    assert!(error.contains("health probe"), "{error}");
    assert!(
        elapsed >= Duration::from_millis(850),
        "elapsed: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_millis(1_800),
        "elapsed: {elapsed:?}"
    );
    drop(first);
}

#[test]
fn foreign_listener_with_wrong_marker_schema_is_not_accepted_as_petcore() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let marker = RuntimeMarker {
        schema_version: "foreign.runtime.v1".to_string(),
        pid: std::process::id(),
        process_start: "1970-01-01T00:00:00Z".to_string(),
        instance_id: "instance_claimed".to_string(),
        http_port: 1,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&marker).unwrap(),
    )
    .unwrap();
    let listener = UnixListener::bind(&paths.socket_path).unwrap();
    let responder = spawn_fake_health_listener(listener, "instance_claimed".to_string());

    let error = InstanceGuard::acquire(&paths).unwrap_err().to_string();
    responder.join().unwrap();

    assert!(!error.contains("already running"), "{error}");
    assert!(error.contains("foreign local socket"), "{error}");
    assert!(paths.socket_path.exists());
}

#[test]
fn old_instance_cannot_delete_new_marker() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let guard = InstanceGuard::acquire(&paths).unwrap();
    guard.publish_runtime(41_235).unwrap();
    let successor = RuntimeMarker {
        schema_version: "apc.runtime.v1".to_string(),
        pid: std::process::id(),
        process_start: "2099-01-01T00:00:00Z".to_string(),
        instance_id: "instance_successor".to_string(),
        http_port: 41_236,
    };
    fs::write(
        &paths.runtime_marker_path,
        serde_json::to_vec_pretty(&successor).unwrap(),
    )
    .unwrap();

    drop(guard);

    let remaining = read_runtime_marker(&paths).unwrap().unwrap();
    assert_eq!(remaining.instance_id, successor.instance_id);
    assert_eq!(remaining.http_port, successor.http_port);
}

#[test]
fn capability_token_is_created_mode_0600() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    let token = daemon::write_capability_token(&paths).unwrap();

    assert!(!token.is_empty());
    assert_eq!(
        fs::metadata(&paths.token_path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&paths.home).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&paths.run_dir).unwrap().permissions().mode() & 0o777,
        0o700
    );
}

#[test]
fn nested_generation_form_and_overlay_placement_are_strict() {
    let daemon = start_daemon();
    let response = rpc_exchange(
        &daemon.paths,
        json!([
            {
                "jsonrpc": "2.0",
                "id": "retry-form",
                "method": "generation.retry",
                "params": {
                    "job_id": "missing-job",
                    "form": {
                        "description": "strict nested form",
                        "style": "pixel",
                        "quality": "high",
                        "reference_images": [],
                        "surprise": true
                    }
                }
            },
            {
                "jsonrpc": "2.0",
                "id": "negative-scale",
                "method": "overlay.placement.update",
                "params": { "x": 0, "y": 0, "scale": -0.1, "display_id": "main" }
            },
            {
                "jsonrpc": "2.0",
                "id": "large-scale",
                "method": "overlay.placement.update",
                "params": { "x": 0, "y": 0, "scale": 1.81, "display_id": "main" }
            },
            {
                "jsonrpc": "2.0",
                "id": "empty-display",
                "method": "overlay.placement.update",
                "params": { "x": 0, "y": 0, "scale": 0.12, "display_id": "   " }
            }
        ]),
    );

    for response in response.as_array().unwrap() {
        assert_eq!(
            response["error"]["code"], -32602,
            "unexpected response: {response}"
        );
    }

    let decoded = serde_json::from_value::<OverlayPlacement>(json!({
        "x": 0,
        "y": 0,
        "scale": 0.12,
        "display_id": "main",
        "surprise": true
    }));
    assert!(
        decoded.is_err(),
        "OverlayPlacement accepted an unknown field"
    );
}

#[test]
fn daemon_request_read_has_one_absolute_deadline() {
    let temp = tempfile::tempdir().unwrap();
    let paths = AppPaths::new(temp.path().join("home"));
    paths.ensure().unwrap();
    let listener = UnixListener::bind(&paths.socket_path).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = String::new();
        stream.read_to_string(&mut request).unwrap();
        let response = b"{\"jsonrpc\":\"2.0\",\"id\":\"cli\",\"result\":null}\n";
        for byte in response {
            if stream.write_all(std::slice::from_ref(byte)).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(150));
        }
    });

    let started = Instant::now();
    let result = daemon::request(&paths, "petcore.health", json!({}));
    let elapsed = started.elapsed();
    server.join().unwrap();

    assert!(
        result.is_err(),
        "dripped response escaped the hard deadline"
    );
    assert!(
        elapsed >= Duration::from_millis(4_500),
        "elapsed: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_millis(5_800),
        "elapsed: {elapsed:?}"
    );
}
