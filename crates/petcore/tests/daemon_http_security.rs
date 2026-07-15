use petcore::daemon;
use petcore::paths::AppPaths;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct TestDaemon {
    child: Child,
    _temp: tempfile::TempDir,
    paths: AppPaths,
    port: u16,
    token: String,
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

    let mut daemon = TestDaemon {
        child,
        _temp: temp,
        paths,
        port: 0,
        token: String::new(),
    };
    wait_for_file(&ready_file);
    let port = std::fs::read_to_string(&daemon.paths.http_port_path)
        .unwrap()
        .trim()
        .parse::<u16>()
        .unwrap();
    let token = std::fs::read_to_string(&daemon.paths.token_path)
        .unwrap()
        .trim()
        .to_string();

    daemon.port = port;
    daemon.token = token;
    daemon
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if path.exists() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "expected file was not created: {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn event(id: &str) -> Value {
    json!({
        "id": id,
        "source": "codex",
        "project_path": "/tmp/http-security-project",
        "session_id": "sess_http_security",
        "event_type": "tool",
        "title": "Tool call"
    })
}

fn post_agent_event(port: u16, extra_headers: &str, body: &Value) -> (u16, Value) {
    let body = serde_json::to_string(body).unwrap();
    let request = format!(
        "POST /agent-events HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{}Connection: close\r\n\r\n{}",
        body.len(),
        extra_headers,
        body
    );
    send_raw_request(port, request.as_bytes())
}

fn send_raw_request(port: u16, request: &[u8]) -> (u16, Value) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream.write_all(request).unwrap();
    stream.shutdown(Shutdown::Write).unwrap();

    let mut response = String::new();
    if let Err(error) = stream.read_to_string(&mut response) {
        assert_eq!(error.kind(), std::io::ErrorKind::ConnectionReset);
        assert!(
            !response.is_empty(),
            "connection reset before an HTTP response was received"
        );
    }
    let (headers, body) = response
        .split_once("\r\n\r\n")
        .unwrap_or_else(|| panic!("HTTP response should include headers and body:\n{response}"));
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok())
        .expect("HTTP response should include status code");
    let body = serde_json::from_str(body).unwrap();
    (status, body)
}

#[test]
fn agent_events_reject_bad_and_suffix_tokens_but_ingest_strict_bearer() {
    let daemon = start_daemon();
    let wrong_token_header = "X-Agent-Pet-Token: definitely-wrong\r\n";
    let (wrong_status, wrong_body) = post_agent_event(
        daemon.port,
        wrong_token_header,
        &event("evt_http_wrong_token"),
    );
    assert_eq!(wrong_status, 401);
    assert_eq!(wrong_body["error"], "missing capability token");

    let suffix_auth_header = format!("Authorization: Bearer wrong{}\r\n", daemon.token);
    let (suffix_status, suffix_body) = post_agent_event(
        daemon.port,
        &suffix_auth_header,
        &event("evt_http_suffix_token"),
    );
    assert_eq!(suffix_status, 401);
    assert_eq!(suffix_body["error"], "missing capability token");

    let suffix_x_token_header = format!("X-Agent-Pet-Token: wrong{}\r\n", daemon.token);
    let (suffix_x_status, suffix_x_body) = post_agent_event(
        daemon.port,
        &suffix_x_token_header,
        &event("evt_http_suffix_x_token"),
    );
    assert_eq!(suffix_x_status, 401);
    assert_eq!(suffix_x_body["error"], "missing capability token");

    let bearer_header = format!("Authorization: Bearer {}\r\n", daemon.token);
    let (ok_status, ok_body) = post_agent_event(
        daemon.port,
        &bearer_header,
        &event("evt_http_strict_bearer"),
    );
    assert_eq!(ok_status, 200);
    assert_eq!(ok_body["inserted"], true);

    let recent = daemon::request(&daemon.paths, "events.recent", json!({ "limit": 5 })).unwrap();
    let recent_events = recent.as_array().unwrap();
    assert!(recent_events
        .iter()
        .any(|event| event["id"] == "evt_http_strict_bearer"));
    assert!(recent_events
        .iter()
        .all(|event| event["id"] != "evt_http_wrong_token"
            && event["id"] != "evt_http_suffix_token"
            && event["id"] != "evt_http_suffix_x_token"));
}

#[test]
fn agent_events_reject_oversized_headers_and_bodies_with_json_errors() {
    let daemon = start_daemon();
    let oversized_headers = format!(
        "POST /agent-events HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Fill: {}\r\n\r\n",
        "a".repeat(20 * 1024)
    );
    let (header_status, header_body) = send_raw_request(daemon.port, oversized_headers.as_bytes());
    assert_eq!(header_status, 431);
    assert_eq!(header_body["error"], "request headers too large");

    let oversized_body_request = format!(
        "POST /agent-events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        daemon.token,
        300 * 1024
    );
    let (body_status, body) = send_raw_request(daemon.port, oversized_body_request.as_bytes());
    assert_eq!(body_status, 413);
    assert_eq!(body["error"], "request body too large");
}

#[test]
fn slow_http_headers_obey_absolute_deadline() {
    let daemon = start_daemon();
    let mut reader = TcpStream::connect(("127.0.0.1", daemon.port)).unwrap();
    reader
        .set_read_timeout(Some(Duration::from_secs(7)))
        .unwrap();
    let mut writer = reader.try_clone().unwrap();
    let drip = std::thread::spawn(move || {
        for byte in b"POST /agent-events HTTP/1.1\r\n" {
            if writer.write_all(std::slice::from_ref(byte)).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    });

    let started = Instant::now();
    let mut response = String::new();
    if let Err(error) = reader.read_to_string(&mut response) {
        assert_eq!(
            error.kind(),
            std::io::ErrorKind::ConnectionReset,
            "unexpected slow-header read error: {error}"
        );
    }
    let elapsed = started.elapsed();
    drip.join().unwrap();

    assert!(
        elapsed >= Duration::from_millis(4_500),
        "elapsed: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_millis(5_800),
        "elapsed: {elapsed:?}"
    );
    assert!(response.starts_with("HTTP/1.1 408 Request Timeout"));
}

#[test]
fn http_concurrency_is_bounded() {
    let daemon = start_daemon();
    let mut held_clients = Vec::new();
    for _ in 0..32 {
        let mut stream = TcpStream::connect(("127.0.0.1", daemon.port)).unwrap();
        stream.write_all(b"P").unwrap();
        held_clients.push(stream);
    }
    std::thread::sleep(Duration::from_millis(300));

    let request = b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    let (status, body) = send_raw_request(daemon.port, request);

    assert_eq!(status, 503);
    assert_eq!(body["error"], "server busy");
    for client in held_clients {
        let _ = client.shutdown(Shutdown::Both);
    }
}
