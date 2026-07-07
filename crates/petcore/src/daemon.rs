use crate::paths::AppPaths;
use crate::rpc::{handle_json_line, handle_request, normalize_event, CoreState, RpcRequest};
use crate::{new_id, PetCoreError, Result};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::thread;
use std::time::Duration;

pub fn serve(paths: AppPaths, ready_file: Option<&Path>) -> Result<()> {
    let state = CoreState::new(paths);
    state.ensure_ready()?;
    write_capability_token(&state.paths)?;
    if state.paths.socket_path.exists() {
        if UnixStream::connect(&state.paths.socket_path).is_ok() {
            return Err(PetCoreError::InvalidRequest(format!(
                "petcore socket is already active at {}",
                state.paths.socket_path.display()
            )));
        }
        fs::remove_file(&state.paths.socket_path)?;
    }

    let http_state = state.clone();
    thread::spawn(move || {
        if let Err(error) = serve_http(http_state) {
            eprintln!("petcore http endpoint stopped: {error}");
        }
    });

    let listener = UnixListener::bind(&state.paths.socket_path)?;
    fs::set_permissions(&state.paths.socket_path, fs::Permissions::from_mode(0o600))?;

    wait_for_http_port(&state.paths.http_port_path);
    if let Some(path) = ready_file {
        fs::write(path, "ready\n")?;
    }

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || {
                    if let Err(error) = handle_unix_stream(&state, stream) {
                        eprintln!("petcore unix client error: {error}");
                    }
                });
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

pub fn write_capability_token(paths: &AppPaths) -> Result<String> {
    fs::create_dir_all(&paths.run_dir)?;
    let token = if paths.token_path.exists() {
        fs::read_to_string(&paths.token_path)?.trim().to_string()
    } else {
        let token = new_id("cap");
        fs::write(&paths.token_path, &token)?;
        fs::set_permissions(&paths.token_path, fs::Permissions::from_mode(0o600))?;
        token
    };
    fs::set_permissions(&paths.token_path, fs::Permissions::from_mode(0o600))?;
    Ok(token)
}

fn handle_unix_stream(state: &CoreState, stream: UnixStream) -> Result<()> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    if line.trim().is_empty() {
        return Ok(());
    }
    let response = handle_json_line(state, line.trim());
    let mut stream = reader.into_inner();
    stream.write_all(response.as_bytes())?;
    stream.write_all(b"\n")?;
    Ok(())
}

fn serve_http(state: CoreState) -> Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    fs::write(&state.paths.http_port_path, port.to_string())?;
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || {
                    if let Err(error) = handle_http_stream(&state, stream) {
                        eprintln!("petcore http client error: {error}");
                    }
                });
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn handle_http_stream(state: &CoreState, mut stream: TcpStream) -> Result<()> {
    let (headers, body) = read_http_request(&mut stream)?;
    let mut lines = headers.lines();
    let request_line = lines.next().unwrap_or_default();
    if !request_line.starts_with("POST /agent-events ") {
        return write_http(&mut stream, 404, json!({ "error": "not found" }));
    }

    let expected_token = fs::read_to_string(&state.paths.token_path)?.trim().to_string();
    let mut authorized = false;
    for line in lines {
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("authorization:") {
            authorized |= line.trim().ends_with(&expected_token);
        }
        if lower.starts_with("x-agent-pet-token:") {
            authorized |= line
                .split_once(':')
                .map(|(_, value)| value.trim() == expected_token)
                .unwrap_or(false);
        }
    }

    if !authorized {
        return write_http(&mut stream, 401, json!({ "error": "missing capability token" }));
    }

    let params: serde_json::Value = serde_json::from_slice(&body)?;
    let event = normalize_event(&params)?;
    let request = RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("http")),
        method: "agent.ingest".to_string(),
        params: serde_json::to_value(event_to_params(event))?,
    };
    let result = handle_request(state, request)?;
    write_http(&mut stream, 200, result)
}

fn read_http_request(stream: &mut TcpStream) -> Result<(String, Vec<u8>)> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut headers = String::new();
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            break;
        }
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().unwrap_or(0);
            }
        }
        headers.push_str(&line);
    }
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader.read_exact(&mut body)?;
    }
    Ok((headers, body))
}

fn event_to_params(event: petcore_types::AgentEvent) -> serde_json::Value {
    json!({
        "id": event.id,
        "source": event.source,
        "project_path": event.project_path,
        "session_id": event.session_id,
        "event_type": event.event_type,
        "title": event.title,
        "detail": event.detail,
        "payload": event.payload_json,
        "created_at": event.created_at,
    })
}

fn write_http(stream: &mut TcpStream, status: u16, body: serde_json::Value) -> Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Error",
    };
    let body = serde_json::to_string(&body)?;
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )?;
    Ok(())
}

fn wait_for_http_port(path: &Path) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

pub fn request(paths: &AppPaths, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
    let mut stream = UnixStream::connect(&paths.socket_path).map_err(|error| {
        PetCoreError::InvalidRequest(format!(
            "could not connect to petcore at {}: {error}",
            paths.socket_path.display()
        ))
    })?;
    let request = json!({
        "jsonrpc": "2.0",
        "id": "cli",
        "method": method,
        "params": params,
    });
    stream.write_all(serde_json::to_string(&request)?.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    let response: serde_json::Value = serde_json::from_str(response.trim())?;
    if let Some(error) = response.get("error") {
        return Err(PetCoreError::InvalidRequest(error.to_string()));
    }
    Ok(response.get("result").cloned().unwrap_or_else(|| json!(null)))
}
