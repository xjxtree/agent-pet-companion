#[path = "instance_lock.rs"]
pub mod instance_lock;

use self::instance_lock::{atomic_write_private, InstanceGuard};
use crate::diagnostics::{DiagnosticLogger, DiagnosticRejection, DiagnosticTransport};
use crate::paths::AppPaths;
use crate::rpc::{
    encoded_error_response, handle_json_line, handle_request, normalize_event, CoreState,
    RpcRequest,
};
use crate::{new_id, PetCoreError, Result};
use serde_json::json;
use std::fs;
use std::io::{BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

const CAPABILITY_TOKEN_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const HTTP_MAX_HEADER_BYTES: usize = 16 * 1024;
const HTTP_MAX_BODY_BYTES: usize = 256 * 1024;
const HTTP_MAX_CONCURRENT_CLIENTS: usize = 32;
const HTTP_READ_DEADLINE: Duration = Duration::from_secs(5);
const HTTP_WRITE_DEADLINE: Duration = Duration::from_secs(5);
// This remains the hard safety deadline for server-side UDS request reads and
// response writes, as well as client request writes. Long-running methods only
// receive a larger client-side response wait below.
const UDS_IO_DEADLINE: Duration = Duration::from_secs(5);
const UDS_PETPACK_RESPONSE_DEADLINE: Duration = Duration::from_secs(120);
// A full four-host check intentionally serializes every native Agent/App
// Server launch. Its strict worst-case process deadlines exceed 90 seconds
// when several hosts are broken at once, so the transport budget must cover
// the complete bounded sequence instead of timing out while PetCore continues.
const UDS_CONNECTIONS_RESPONSE_DEADLINE: Duration = Duration::from_secs(180);
const UDS_DIAGNOSTICS_RESPONSE_DEADLINE: Duration = Duration::from_secs(120);
const UDS_MAX_FRAME_BYTES: usize = 256 * 1024;
const UDS_MAX_CONCURRENT_CLIENTS: usize = 32;

pub fn serve(paths: AppPaths, ready_file: Option<&Path>) -> Result<()> {
    // Acquire the process-wide instance lock before opening the shared log.
    // This prevents a losing second daemon from rotating a file still held by
    // the winning daemon under a different inode.
    let instance_guard = InstanceGuard::acquire(&paths)?;
    let diagnostics = DiagnosticLogger::new(&paths);
    diagnostics.daemon_phase("starting");
    let result = serve_with_diagnostics(paths, ready_file, diagnostics.clone(), instance_guard);
    match &result {
        Ok(()) => diagnostics.daemon_phase("stopped"),
        Err(error) => diagnostics.daemon_failed(error),
    }
    diagnostics.sync();
    result
}

fn serve_with_diagnostics(
    paths: AppPaths,
    ready_file: Option<&Path>,
    diagnostics: DiagnosticLogger,
    instance_guard: InstanceGuard,
) -> Result<()> {
    startup_step(
        &diagnostics,
        "manifest",
        crate::runtime_manifest::validate_expected_manifest_from_env(),
    )?;
    if let Ok(expected_build_id) = std::env::var("APC_EXPECTED_BUILD_ID") {
        if !expected_build_id.is_empty() && expected_build_id != crate::rpc::PETCORE_BUILD_ID {
            let error = PetCoreError::InvalidRequest(format!(
                "petcore build {} does not match the App-required build {expected_build_id}",
                crate::rpc::PETCORE_BUILD_ID
            ));
            diagnostics.startup_failed("build_identity", &error);
            return Err(error);
        }
    }
    let state = CoreState::new_with_diagnostics(paths, diagnostics.clone())
        .with_instance_id(instance_guard.instance_id())
        .with_codex_activity_sync(true);
    state.ensure_ready()?;
    startup_step(
        &diagnostics,
        "capability_token",
        write_capability_token(&state.paths),
    )?;
    if state.paths.socket_path.exists() {
        if UnixStream::connect(&state.paths.socket_path).is_ok() {
            let error = PetCoreError::InvalidRequest(format!(
                "petcore socket is already active at {}",
                state.paths.socket_path.display()
            ));
            diagnostics.startup_failed("socket_bind", &error);
            return Err(error);
        }
        startup_step(
            &diagnostics,
            "socket_bind",
            fs::remove_file(&state.paths.socket_path).map_err(PetCoreError::from),
        )?;
    }

    let listener = startup_step(
        &diagnostics,
        "socket_bind",
        UnixListener::bind(&state.paths.socket_path).map_err(PetCoreError::from),
    )?;
    startup_step(
        &diagnostics,
        "socket_bind",
        fs::set_permissions(&state.paths.socket_path, fs::Permissions::from_mode(0o600))
            .map_err(PetCoreError::from),
    )?;
    startup_step(
        &diagnostics,
        "socket_bind",
        listener.set_nonblocking(true).map_err(PetCoreError::from),
    )?;
    let http_listener = startup_step(
        &diagnostics,
        "http_bind",
        TcpListener::bind(("127.0.0.1", 0)).map_err(PetCoreError::from),
    )?;
    let http_port = startup_step(
        &diagnostics,
        "http_bind",
        http_listener
            .local_addr()
            .map(|address| address.port())
            .map_err(PetCoreError::from),
    )?;
    startup_step(
        &diagnostics,
        "runtime_publish",
        instance_guard.publish_runtime(http_port),
    )?;

    let http_state = state.clone();
    let http_diagnostics = state.diagnostics.clone();
    thread::spawn(move || {
        if let Err(error) = serve_http(http_state, http_listener) {
            http_diagnostics.transport_failed(DiagnosticTransport::Http, &error);
        }
    });

    if let Some(path) = ready_file {
        startup_step(
            &diagnostics,
            "runtime_publish",
            fs::write(path, "ready\n").map_err(PetCoreError::from),
        )?;
    }
    state.diagnostics.daemon_phase("ready");

    let active_clients = Arc::new(AtomicUsize::new(0));
    while !state.shutdown_requested() {
        match listener.accept() {
            Ok((stream, _)) => {
                let Some(permit) = ClientPermit::try_acquire(
                    Arc::clone(&active_clients),
                    UDS_MAX_CONCURRENT_CLIENTS,
                ) else {
                    reject_busy_client(&state, stream);
                    continue;
                };
                let state = state.clone();
                thread::spawn(move || {
                    let _permit = permit;
                    if let Err(error) = handle_unix_stream(&state, stream) {
                        state
                            .diagnostics
                            .transport_failed(DiagnosticTransport::Unix, &error);
                    }
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(error) => {
                let error = PetCoreError::Io(error);
                state
                    .diagnostics
                    .transport_failed(DiagnosticTransport::Unix, &error);
                return Err(error);
            }
        }
    }
    state.diagnostics.daemon_phase("shutdown_requested");
    Ok(())
}

fn startup_step<T>(
    diagnostics: &DiagnosticLogger,
    stage: &'static str,
    result: Result<T>,
) -> Result<T> {
    result.inspect_err(|error| {
        diagnostics.startup_failed(stage, error);
    })
}

pub fn write_capability_token(paths: &AppPaths) -> Result<String> {
    paths.ensure_runtime_dirs()?;
    let token = if let Some(token) = read_usable_capability_token(paths)? {
        token
    } else {
        let token = new_id("cap");
        atomic_write_private(&paths.token_path, token.as_bytes())?;
        token
    };
    fs::set_permissions(&paths.token_path, fs::Permissions::from_mode(0o600))?;
    Ok(token)
}

fn read_usable_capability_token(paths: &AppPaths) -> Result<Option<String>> {
    if !paths.token_path.exists() {
        return Ok(None);
    }

    let metadata = fs::metadata(&paths.token_path)?;
    let expired = metadata
        .modified()
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())
        .is_some_and(|age| age > CAPABILITY_TOKEN_MAX_AGE);
    if expired {
        return Ok(None);
    }

    let token = fs::read_to_string(&paths.token_path)?.trim().to_string();
    if token.is_empty() {
        return Ok(None);
    }

    Ok(Some(token))
}

fn handle_unix_stream(state: &CoreState, mut stream: UnixStream) -> Result<()> {
    let frame = match read_unix_frame(&mut stream) {
        Ok(Some(frame)) => frame,
        Ok(None) => return Ok(()),
        Err(UnixFrameReadError::TooLarge) => {
            state.diagnostics.transport_rejected(
                DiagnosticTransport::Unix,
                DiagnosticRejection::FrameTooLarge,
            );
            return write_unix_response(
                &mut stream,
                &encoded_error_response(
                    -32600,
                    &format!("request exceeds {UDS_MAX_FRAME_BYTES} bytes"),
                ),
            );
        }
        Err(UnixFrameReadError::Timeout) => {
            state
                .diagnostics
                .transport_rejected(DiagnosticTransport::Unix, DiagnosticRejection::ReadTimeout);
            return write_unix_response(
                &mut stream,
                &encoded_error_response(-32000, "request read timed out"),
            );
        }
        Err(UnixFrameReadError::Io(error)) => return Err(error.into()),
    };
    let line = match std::str::from_utf8(&frame) {
        Ok(line) => line,
        Err(_) => {
            state
                .diagnostics
                .transport_rejected(DiagnosticTransport::Unix, DiagnosticRejection::InvalidUtf8);
            return write_unix_response(
                &mut stream,
                &encoded_error_response(-32700, "request is not valid UTF-8 JSON"),
            );
        }
    };
    if let Some(response) = handle_json_line(state, line.trim()) {
        write_unix_response(&mut stream, &response)?;
    }
    Ok(())
}

#[derive(Debug)]
enum UnixFrameReadError {
    TooLarge,
    Timeout,
    Io(std::io::Error),
}

fn read_unix_frame(
    stream: &mut UnixStream,
) -> std::result::Result<Option<Vec<u8>>, UnixFrameReadError> {
    let readiness = stream.try_clone().map_err(UnixFrameReadError::Io)?;
    let deadline = Instant::now() + UDS_IO_DEADLINE;
    let mut limited = stream.take((UDS_MAX_FRAME_BYTES + 1) as u64);
    let mut frame = Vec::new();
    let mut buffer = [0u8; 8 * 1024];

    loop {
        wait_for_unix_readable(&readiness, deadline)?;

        let read = match limited.read(&mut buffer) {
            Ok(read) => read,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) =>
            {
                return Err(UnixFrameReadError::Timeout);
            }
            Err(error) => return Err(UnixFrameReadError::Io(error)),
        };
        if read == 0 {
            return if frame.is_empty() {
                Ok(None)
            } else {
                Ok(Some(frame))
            };
        }

        if let Some(newline) = buffer[..read].iter().position(|byte| *byte == b'\n') {
            if frame.len() + newline > UDS_MAX_FRAME_BYTES {
                return Err(UnixFrameReadError::TooLarge);
            }
            frame.extend_from_slice(&buffer[..newline]);
            return Ok(Some(frame));
        }

        frame.extend_from_slice(&buffer[..read]);
        if frame.len() > UDS_MAX_FRAME_BYTES {
            return Err(UnixFrameReadError::TooLarge);
        }
    }
}

fn wait_for_unix_readable(
    stream: &UnixStream,
    deadline: Instant,
) -> std::result::Result<(), UnixFrameReadError> {
    let mut descriptor = rustix::event::PollFd::new(stream, rustix::event::PollFlags::IN);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(UnixFrameReadError::Timeout);
        }
        let timeout = rustix::event::Timespec::try_from(remaining).map_err(|error| {
            UnixFrameReadError::Io(std::io::Error::new(std::io::ErrorKind::InvalidInput, error))
        })?;
        descriptor.clear_revents();
        match rustix::event::poll(std::slice::from_mut(&mut descriptor), Some(&timeout)) {
            Ok(0) => return Err(UnixFrameReadError::Timeout),
            Ok(_) => return Ok(()),
            Err(rustix::io::Errno::INTR) => continue,
            Err(error) => {
                return Err(UnixFrameReadError::Io(std::io::Error::from(error)));
            }
        }
    }
}

fn write_unix_response(stream: &mut UnixStream, response: &str) -> Result<()> {
    let mut frame = Vec::with_capacity(response.len() + 1);
    frame.extend_from_slice(response.as_bytes());
    frame.push(b'\n');
    write_unix_with_deadline(stream, &frame, Instant::now() + UDS_IO_DEADLINE)
}

fn reject_busy_client(state: &CoreState, mut stream: UnixStream) {
    state
        .diagnostics
        .transport_rejected(DiagnosticTransport::Unix, DiagnosticRejection::Busy);
    let response = encoded_error_response(
        -32000,
        &format!("server busy: maximum {UDS_MAX_CONCURRENT_CLIENTS} concurrent clients"),
    );
    let _ = write_unix_response(&mut stream, &response);
}

struct ClientPermit {
    active: Arc<AtomicUsize>,
}

impl ClientPermit {
    fn try_acquire(active: Arc<AtomicUsize>, maximum: usize) -> Option<Self> {
        active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                (current < maximum).then_some(current + 1)
            })
            .ok()?;
        Some(Self { active })
    }
}

impl Drop for ClientPermit {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

fn serve_http(state: CoreState, listener: TcpListener) -> Result<()> {
    let active_clients = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let Some(permit) = ClientPermit::try_acquire(
                    Arc::clone(&active_clients),
                    HTTP_MAX_CONCURRENT_CLIENTS,
                ) else {
                    reject_busy_http_client(&state, stream);
                    continue;
                };
                let state = state.clone();
                thread::spawn(move || {
                    let _permit = permit;
                    if let Err(error) = handle_http_stream(&state, stream) {
                        state
                            .diagnostics
                            .transport_failed(DiagnosticTransport::Http, &error);
                    }
                });
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn reject_busy_http_client(state: &CoreState, mut stream: TcpStream) {
    state
        .diagnostics
        .transport_rejected(DiagnosticTransport::Http, DiagnosticRejection::Busy);
    let _ = write_http(&mut stream, 503, json!({ "error": "server busy" }));
}

fn handle_http_stream(state: &CoreState, mut stream: TcpStream) -> Result<()> {
    let (headers, body) = match read_http_request(&mut stream) {
        Ok(request) => request,
        Err(error) => {
            state
                .diagnostics
                .transport_rejected(DiagnosticTransport::Http, error.diagnostic_rejection());
            return write_http(
                &mut stream,
                error.status(),
                json!({ "error": error.message() }),
            );
        }
    };
    let mut lines = headers.lines();
    let request_line = lines.next().unwrap_or_default();
    if !request_line.starts_with("POST /agent-events ") {
        state
            .diagnostics
            .transport_rejected(DiagnosticTransport::Http, DiagnosticRejection::NotFound);
        return write_http(&mut stream, 404, json!({ "error": "not found" }));
    }

    let expected_token = write_capability_token(&state.paths)?;
    let expected_bearer = format!("Bearer {expected_token}");
    let mut authorized = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("authorization") {
            authorized |= value == expected_bearer;
        }
        if name.eq_ignore_ascii_case("x-agent-pet-token") {
            authorized |= value == expected_token;
        }
    }

    if !authorized {
        state
            .diagnostics
            .transport_rejected(DiagnosticTransport::Http, DiagnosticRejection::Unauthorized);
        return write_http(
            &mut stream,
            401,
            json!({ "error": "missing capability token" }),
        );
    }

    let params: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(params) => params,
        Err(_) => {
            state
                .diagnostics
                .transport_rejected(DiagnosticTransport::Http, DiagnosticRejection::InvalidJson);
            return write_http(&mut stream, 400, json!({ "error": "invalid json" }));
        }
    };
    let event = match normalize_event(&params) {
        Ok(event) => event,
        Err(error) => {
            state
                .diagnostics
                .transport_rejected(DiagnosticTransport::Http, DiagnosticRejection::BadRequest);
            return write_http(&mut stream, 400, json!({ "error": error.to_string() }));
        }
    };
    let request = RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("http")),
        method: "agent.ingest".to_string(),
        params: serde_json::to_value(event_to_params(event))?,
    };
    let result = match handle_request(state, request) {
        Ok(result) => result,
        Err(error) => {
            return write_http(
                &mut stream,
                http_status_for_core_error(&error),
                json!({ "error": error.to_string() }),
            );
        }
    };
    write_http(&mut stream, 200, result)
}

#[derive(Debug)]
enum HttpReadError {
    BadRequest(&'static str),
    HeaderTooLarge,
    BodyTooLarge,
    Timeout,
    Io,
}

impl HttpReadError {
    fn status(&self) -> u16 {
        match self {
            Self::BadRequest(_) => 400,
            Self::HeaderTooLarge => 431,
            Self::BodyTooLarge => 413,
            Self::Timeout => 408,
            Self::Io => 400,
        }
    }

    fn message(&self) -> &'static str {
        match self {
            Self::BadRequest(message) => message,
            Self::HeaderTooLarge => "request headers too large",
            Self::BodyTooLarge => "request body too large",
            Self::Timeout => "request timed out",
            Self::Io => "invalid http request",
        }
    }

    fn diagnostic_rejection(&self) -> DiagnosticRejection {
        match self {
            Self::HeaderTooLarge | Self::BodyTooLarge => DiagnosticRejection::FrameTooLarge,
            Self::Timeout => DiagnosticRejection::ReadTimeout,
            Self::BadRequest(_) | Self::Io => DiagnosticRejection::BadRequest,
        }
    }
}

fn read_http_request(
    stream: &mut TcpStream,
) -> std::result::Result<(String, Vec<u8>), HttpReadError> {
    let deadline = Instant::now() + HTTP_READ_DEADLINE;
    let mut reader = BufReader::new(stream);
    let headers = read_http_headers(&mut reader, deadline)?;
    let content_length = parse_content_length(&headers)?;
    if content_length > HTTP_MAX_BODY_BYTES {
        return Err(HttpReadError::BodyTooLarge);
    }

    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        read_exact_with_deadline(&mut reader, &mut body, deadline)?;
    }
    Ok((headers, body))
}

fn read_http_headers(
    reader: &mut BufReader<&mut TcpStream>,
    deadline: Instant,
) -> std::result::Result<String, HttpReadError> {
    let mut headers = Vec::new();
    loop {
        set_http_read_timeout(reader, deadline)?;

        let mut byte = [0u8; 1];
        let read = reader.read(&mut byte).map_err(map_http_io_error)?;
        if read == 0 {
            return Err(HttpReadError::BadRequest("incomplete http request"));
        }

        headers.push(byte[0]);
        if headers.len() > HTTP_MAX_HEADER_BYTES {
            return Err(HttpReadError::HeaderTooLarge);
        }
        if headers.ends_with(b"\r\n\r\n") {
            return String::from_utf8(headers)
                .map_err(|_| HttpReadError::BadRequest("invalid http headers"));
        }
    }
}

fn read_exact_with_deadline(
    reader: &mut BufReader<&mut TcpStream>,
    buffer: &mut [u8],
    deadline: Instant,
) -> std::result::Result<(), HttpReadError> {
    let mut offset = 0;
    while offset < buffer.len() {
        set_http_read_timeout(reader, deadline)?;
        let read = reader
            .read(&mut buffer[offset..])
            .map_err(map_http_io_error)?;
        if read == 0 {
            return Err(HttpReadError::BadRequest("incomplete http body"));
        }
        offset += read;
    }
    Ok(())
}

fn set_http_read_timeout(
    reader: &mut BufReader<&mut TcpStream>,
    deadline: Instant,
) -> std::result::Result<(), HttpReadError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining < Duration::from_millis(1) {
        return Err(HttpReadError::Timeout);
    }
    reader
        .get_mut()
        .set_read_timeout(Some(remaining))
        .map_err(|_| HttpReadError::Io)
}

fn parse_content_length(headers: &str) -> std::result::Result<usize, HttpReadError> {
    let mut content_length = None;
    for line in headers.lines().skip(1) {
        if line.trim().is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err(HttpReadError::BadRequest("invalid http header"));
        };
        if name.eq_ignore_ascii_case("content-length") {
            if content_length.is_some() {
                return Err(HttpReadError::BadRequest("duplicate content-length"));
            }
            content_length = Some(
                value
                    .trim()
                    .parse::<usize>()
                    .map_err(|_| HttpReadError::BadRequest("invalid content-length"))?,
            );
        }
    }
    Ok(content_length.unwrap_or(0))
}

fn map_http_io_error(error: std::io::Error) -> HttpReadError {
    match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => HttpReadError::Timeout,
        _ => HttpReadError::Io,
    }
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

fn http_status_for_core_error(error: &PetCoreError) -> u16 {
    match error {
        PetCoreError::InvalidRequest(_) | PetCoreError::Json(_) => 400,
        PetCoreError::Conflict(_) => 409,
        _ => 500,
    }
}

fn write_http(stream: &mut TcpStream, status: u16, body: serde_json::Value) -> Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        500 => "Internal Server Error",
        _ => "Error",
    };
    let body = serde_json::to_string(&body)?;
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(), body
    );
    write_tcp_with_deadline(stream, response.as_bytes(), HTTP_WRITE_DEADLINE)
}

fn write_tcp_with_deadline(stream: &mut TcpStream, bytes: &[u8], timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    let mut offset = 0;
    while offset < bytes.len() {
        let remaining = remaining_io_time(deadline, "http response write timed out")?;
        stream.set_write_timeout(Some(remaining))?;
        match stream.write(&bytes[offset..]) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "http response socket closed",
                )
                .into());
            }
            Ok(written) => offset += written,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) =>
            {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "http response write timed out",
                )
                .into());
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

pub fn request(
    paths: &AppPaths,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
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
    let request = serde_json::to_vec(&request)?;
    if request.len() > UDS_MAX_FRAME_BYTES {
        return Err(PetCoreError::InvalidRequest(format!(
            "request exceeds {UDS_MAX_FRAME_BYTES} bytes"
        )));
    }
    let mut request_frame = Vec::with_capacity(request.len() + 1);
    request_frame.extend_from_slice(&request);
    request_frame.push(b'\n');
    write_unix_with_deadline(
        &mut stream,
        &request_frame,
        Instant::now() + UDS_IO_DEADLINE,
    )?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let response = read_unix_response_with_deadline(
        &mut stream,
        Instant::now() + client_response_timeout(method),
    )?;
    let response: serde_json::Value = serde_json::from_slice(trim_ascii_bytes(&response))?;
    if let Some(error) = response.get("error") {
        return Err(PetCoreError::InvalidRequest(error.to_string()));
    }
    Ok(response
        .get("result")
        .cloned()
        .unwrap_or(serde_json::Value::Null))
}

fn client_response_timeout(method: &str) -> Duration {
    match method {
        "pet.history" | "petpack.import" | "petpack.seed_bundled" | "petpack.export" => {
            UDS_PETPACK_RESPONSE_DEADLINE
        }
        "connections.check"
        | "connections.repair"
        | "connections.refresh_installed"
        | "connections.uninstall" => UDS_CONNECTIONS_RESPONSE_DEADLINE,
        "diagnostics.export" => UDS_DIAGNOSTICS_RESPONSE_DEADLINE,
        _ => UDS_IO_DEADLINE,
    }
}

fn write_unix_with_deadline(
    stream: &mut UnixStream,
    bytes: &[u8],
    deadline: Instant,
) -> Result<()> {
    let readiness = stream.try_clone()?;
    stream.set_nonblocking(true)?;
    let result = write_unix_nonblocking_until(stream, &readiness, bytes, deadline);
    let restore = stream.set_nonblocking(false);
    match (result, restore) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error.into()),
        (Ok(()), Ok(())) => Ok(()),
    }
}

fn write_unix_nonblocking_until(
    stream: &mut UnixStream,
    readiness: &UnixStream,
    bytes: &[u8],
    deadline: Instant,
) -> Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        wait_for_unix_event(
            readiness,
            rustix::event::PollFlags::OUT,
            deadline,
            "unix socket write timed out",
        )?;
        match stream.write(&bytes[offset..]) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "unix socket closed while writing",
                )
                .into());
            }
            Ok(written) => offset += written,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn read_unix_response_with_deadline(stream: &mut UnixStream, deadline: Instant) -> Result<Vec<u8>> {
    read_unix_bounded_with_deadline(stream, deadline, UDS_MAX_FRAME_BYTES + 1)
}

fn read_unix_bounded_with_deadline(
    stream: &mut UnixStream,
    deadline: Instant,
    maximum_bytes: usize,
) -> Result<Vec<u8>> {
    let readiness = stream.try_clone()?;
    stream.set_nonblocking(true)?;
    let result = read_unix_response_nonblocking_until(stream, &readiness, deadline, maximum_bytes);
    let restore = stream.set_nonblocking(false);
    match (result, restore) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error.into()),
        (Ok(response), Ok(())) => Ok(response),
    }
}

fn read_unix_response_nonblocking_until(
    stream: &mut UnixStream,
    readiness: &UnixStream,
    deadline: Instant,
    maximum_bytes: usize,
) -> Result<Vec<u8>> {
    let mut response = Vec::new();
    let mut buffer = [0u8; 8 * 1024];
    loop {
        wait_for_unix_event(
            readiness,
            rustix::event::PollFlags::IN,
            deadline,
            "unix socket read timed out",
        )?;
        let maximum_read = (maximum_bytes + 1 - response.len()).min(buffer.len());
        match stream.read(&mut buffer[..maximum_read]) {
            Ok(0) => return Ok(response),
            Ok(read) => {
                response.extend_from_slice(&buffer[..read]);
                if response.len() > maximum_bytes {
                    return Err(PetCoreError::InvalidRequest(format!(
                        "response exceeds {maximum_bytes} bytes"
                    )));
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(error) => return Err(error.into()),
        }
    }
}

fn wait_for_unix_event(
    stream: &UnixStream,
    events: rustix::event::PollFlags,
    deadline: Instant,
    timeout_message: &'static str,
) -> Result<()> {
    let mut descriptor = rustix::event::PollFd::new(stream, events);
    loop {
        let remaining = remaining_io_time(deadline, timeout_message)?;
        let timeout = rustix::event::Timespec::try_from(remaining)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
        descriptor.clear_revents();
        match rustix::event::poll(std::slice::from_mut(&mut descriptor), Some(&timeout)) {
            Ok(0) => {
                return Err(
                    std::io::Error::new(std::io::ErrorKind::TimedOut, timeout_message).into(),
                );
            }
            Ok(_) => return Ok(()),
            Err(rustix::io::Errno::INTR) => continue,
            Err(error) => return Err(std::io::Error::from(error).into()),
        }
    }
}

fn remaining_io_time(deadline: Instant, message: &'static str) -> Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining < Duration::from_millis(1) {
        return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, message).into());
    }
    Ok(remaining)
}

fn trim_ascii_bytes(bytes: &[u8]) -> &[u8] {
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

#[cfg(test)]
mod tests {
    use super::{
        client_response_timeout, UDS_CONNECTIONS_RESPONSE_DEADLINE,
        UDS_DIAGNOSTICS_RESPONSE_DEADLINE, UDS_IO_DEADLINE, UDS_PETPACK_RESPONSE_DEADLINE,
    };
    use std::time::Duration;

    #[test]
    fn client_response_timeout_extends_only_bounded_long_operations() {
        assert_eq!(UDS_IO_DEADLINE, Duration::from_secs(5));
        assert_eq!(UDS_PETPACK_RESPONSE_DEADLINE, Duration::from_secs(120));
        assert_eq!(UDS_CONNECTIONS_RESPONSE_DEADLINE, Duration::from_secs(180));
        assert_eq!(UDS_DIAGNOSTICS_RESPONSE_DEADLINE, Duration::from_secs(120));
        assert_eq!(
            client_response_timeout("petpack.import"),
            UDS_PETPACK_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("petpack.seed_bundled"),
            UDS_PETPACK_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("petpack.export"),
            UDS_PETPACK_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("pet.history"),
            UDS_PETPACK_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("connections.check"),
            UDS_CONNECTIONS_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("connections.repair"),
            UDS_CONNECTIONS_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("connections.uninstall"),
            UDS_CONNECTIONS_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("connections.refresh_installed"),
            UDS_CONNECTIONS_RESPONSE_DEADLINE
        );
        assert_eq!(
            client_response_timeout("diagnostics.export"),
            UDS_DIAGNOSTICS_RESPONSE_DEADLINE
        );

        for method in [
            "petpack.validate",
            "pet.list",
            "state.snapshot",
            "petpack.import.preview",
            "connections.test",
            "Petpack.import",
        ] {
            assert_eq!(
                client_response_timeout(method),
                UDS_IO_DEADLINE,
                "ordinary RPC {method} must retain the five-second response deadline"
            );
        }
    }
}
