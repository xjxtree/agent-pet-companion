use petcore::paths::AppPaths;
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use serde_json::json;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixListener;
use std::process::{Command, Stdio};
use std::sync::mpsc;

fn cli() -> std::ffi::OsString {
    std::env::var_os("APC_CLAUDE_ROUTING_TEST_CLI")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_petcore-cli").into())
}

#[test]
fn claude_completion_routes_latest_agent_text_to_petcore() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let paths = AppPaths::new(home.clone());
    let state = CoreState::new(paths.clone());
    state.ensure_ready().unwrap();

    let transcript_path = temp.path().join("claude-session.jsonl");
    let session_id = "308b79e0-bbc0-491b-984a-950d6aa4bbab";
    let transcript = [
        json!({
            "type": "custom-title",
            "customTitle": "修复 Claude 会话气泡",
            "sessionId": session_id
        }),
        json!({
            "type": "user",
            "sessionId": session_id,
            "message": {"role": "user", "content": "为什么只显示思考信息？"}
        }),
        json!({
            "type": "assistant",
            "sessionId": session_id,
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "thinking", "thinking": "不应进入消息气泡"},
                    {"type": "text", "text": "Claude Agent 回复现在会显示在消息气泡中。"}
                ]
            }
        }),
        // Claude appends this bookkeeping record after the completed Agent
        // response. It repeats the preceding prompt; it is not a newer turn.
        json!({
            "type": "last-prompt",
            "lastPrompt": "为什么只显示思考信息？",
            "sessionId": session_id
        }),
    ]
    .into_iter()
    .map(|record| serde_json::to_string(&record).unwrap())
    .collect::<Vec<_>>()
    .join("\n");
    std::fs::write(&transcript_path, format!("{transcript}\n")).unwrap();

    handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("activation")),
            method: "agent.ingest".to_string(),
            params: json!({
                "id": "claude-user-activation",
                "source": "claude_code",
                "session_id": session_id,
                "event_type": "start",
                "title": "开始处理",
                "payload": {
                    "source_event": "UserPromptSubmit",
                    "session_active": true,
                    "message_role": "user",
                    "message_content": "为什么只显示思考信息？",
                    "session_open": true,
                    "diagnostic": false
                }
            }),
        },
    )
    .unwrap();

    let listener = UnixListener::bind(&paths.socket_path).unwrap();
    let (request_tx, request_rx) = mpsc::sync_channel(1);
    let rpc_state = state.clone();
    let responder = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = String::new();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        reader.read_line(&mut request).unwrap();
        reader.read_to_end(&mut Vec::new()).unwrap();
        let rpc_request: RpcRequest = serde_json::from_str(request.trim()).unwrap();
        let response_id = rpc_request.id.clone();
        let result = handle_request(&rpc_state, rpc_request).unwrap();
        request_tx.send(request).unwrap();
        let response = json!({
            "jsonrpc": "2.0",
            "id": response_id,
            "result": result
        });
        stream
            .write_all(format!("{}\n", serde_json::to_string(&response).unwrap()).as_bytes())
            .unwrap();
    });

    let mut child = Command::new(cli())
        .env("APC_HOME", &home)
        .args([
            "agent",
            "hook",
            "--source",
            "claude_code",
            "--event-type",
            "auto",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let payload = json!({
        "hook_event_name": "SessionEnd",
        "session_id": session_id,
        "transcript_path": transcript_path
    });
    child
        .stdin
        .take()
        .unwrap()
        .write_all(serde_json::to_string(&payload).unwrap().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    responder.join().unwrap();

    assert!(
        output.status.success(),
        "Claude hook failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let request: serde_json::Value =
        serde_json::from_str(request_rx.recv().unwrap().trim()).unwrap();
    assert_eq!(request["method"], "agent.ingest");
    assert_eq!(request["params"]["source"], "claude_code");
    assert_eq!(request["params"]["session_id"], session_id);
    assert_eq!(
        request["params"]["payload_json"]["source_event"],
        "SessionEnd"
    );
    assert_eq!(
        request["params"]["payload_json"]["outcome"],
        "session_closed"
    );
    assert_eq!(
        request["params"]["payload_json"]["message_role"],
        "assistant"
    );
    assert_eq!(
        request["params"]["payload_json"]["message_content"],
        "Claude Agent 回复现在会显示在消息气泡中。"
    );
    assert_eq!(
        request["params"]["payload_json"]["session_title"],
        "修复 Claude 会话气泡"
    );
    assert!(!request.to_string().contains("不应进入消息气泡"));

    let snapshot = handle_request(
        &state,
        RpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!("snapshot")),
            method: "state.snapshot".to_string(),
            params: json!({}),
        },
    )
    .unwrap();
    let claude_session = snapshot["active_agent_sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["source"] == "claude_code")
        .unwrap();
    assert_eq!(
        claude_session["session_message"],
        json!({
            "role": "assistant",
            "content": "Claude Agent 回复现在会显示在消息气泡中。"
        })
    );
}
