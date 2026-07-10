use crate::paths::AppPaths;
use crate::{now_rfc3339, PetCoreError, Result};
use petcore_types::{GenerationForm, PetStateName, REQUIRED_STATES};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const PROBE_TIMEOUT: Duration = Duration::from_millis(1200);
const THREAD_START_TIMEOUT: Duration = Duration::from_millis(8000);
const TURN_START_TIMEOUT: Duration = Duration::from_millis(12_000);
const TURN_RUN_TIMEOUT: Duration = Duration::from_millis(180_000);
const EXTERNAL_HELPER_TURN_TIMEOUT: Duration = Duration::from_millis(60_000);
const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(100);
const PET_STUDIO_EXTERNAL_HELPER_NAME: &str = "apc_write_skill_source.py";
const PET_STUDIO_EXTERNAL_FORM_NAME: &str = "apc_skill_form.json";
const PET_STUDIO_EXTERNAL_HELPER: &str =
    include_str!("../../../skills/agent-pet-studio/scripts/write_petpack_source.py");

#[derive(Debug, Clone)]
pub struct PetStudioSessionUpdate {
    pub content: String,
    pub progress: f64,
}

pub fn probe_codex_app_server() -> Value {
    let (command, command_source) = match codex_app_server_command() {
        Some(command) => command,
        None => return missing_app_server_json(),
    };

    match probe_stdio_command(&command) {
        Ok(response) => json!({
            "initialized": true,
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339(),
            "response": response
        }),
        Err(error) => app_server_failure_json(
            &command,
            command_source,
            None,
            None,
            false,
            false,
            false,
            &error,
        ),
    }
}

pub fn codex_app_server_command_check() -> Value {
    match codex_app_server_command() {
        Some((command, command_source)) => json!({
            "available": true,
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339()
        }),
        None => missing_app_server_json(),
    }
}

pub fn start_pet_studio_thread(paths: &AppPaths, job_id: &str, form: &GenerationForm) -> Value {
    let (command, command_source) = match codex_app_server_command() {
        Some(command) => command,
        None => return missing_app_server_json(),
    };

    let job_dir = paths.jobs_dir.join(job_id);
    if let Err(error) = std::fs::create_dir_all(&job_dir) {
        return json!({
            "initialized": false,
            "started": false,
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339(),
            "error": format!("generation job workspace is unavailable: {error}")
        });
    }
    if let Err(error) = prepare_external_skill_source_workspace(&job_dir, form) {
        return app_server_failure_json(
            &command,
            command_source,
            None,
            None,
            false,
            false,
            false,
            &error,
        );
    }
    let params = json!({
        "cwd": job_dir.display().to_string(),
        "ephemeral": false,
        "approvalPolicy": "never",
        "sandbox": "workspace-write",
        "baseInstructions": "You are Agent Pet Studio running inside Agent Pet Companion. Generate only Agent Pet Companion .petpack assets for the current generation job.",
        "developerInstructions": pet_studio_developer_instructions(job_id, form),
        "threadSource": "agent-pet-companion"
    });

    match start_thread_stdio_command(&command, params) {
        Ok(response) => {
            let thread = response
                .get("result")
                .and_then(|result| result.get("thread"));
            let thread_id = thread
                .and_then(|thread| thread.get("id"))
                .and_then(Value::as_str);
            let session_id = thread
                .and_then(|thread| thread.get("sessionId"))
                .and_then(Value::as_str)
                .or(thread_id);

            json!({
                "initialized": true,
                "started": thread_id.is_some(),
                "mode": "configured",
                "transport": "stdio",
                "command": command,
                "command_source": command_source,
                "checked_at": now_rfc3339(),
                "thread_id": thread_id,
                "session_id": session_id,
                "response": response
            })
        }
        Err(error) => app_server_failure_json(
            &command,
            command_source,
            None,
            None,
            false,
            false,
            false,
            &error,
        ),
    }
}

pub fn run_pet_studio_session(paths: &AppPaths, job_id: &str, form: &GenerationForm) -> Value {
    run_pet_studio_session_with_updates(paths, job_id, form, |_| {})
}

pub fn run_pet_studio_session_with_updates<F>(
    paths: &AppPaths,
    job_id: &str,
    form: &GenerationForm,
    on_update: F,
) -> Value
where
    F: FnMut(PetStudioSessionUpdate),
{
    run_pet_studio_session_with_updates_and_cancel(paths, job_id, form, on_update, || false)
}

pub fn run_pet_studio_session_with_updates_and_cancel<F, C>(
    paths: &AppPaths,
    job_id: &str,
    form: &GenerationForm,
    mut on_update: F,
    mut should_cancel: C,
) -> Value
where
    F: FnMut(PetStudioSessionUpdate),
    C: FnMut() -> bool,
{
    let (command, command_source) = match codex_app_server_command() {
        Some(command) => command,
        None => return missing_app_server_json(),
    };

    let job_dir = paths.jobs_dir.join(job_id);
    if let Err(error) = std::fs::create_dir_all(&job_dir) {
        return json!({
            "initialized": false,
            "started": false,
            "turn_started": false,
            "completed": false,
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339(),
            "error": format!("generation job workspace is unavailable: {error}")
        });
    }
    if let Err(error) = prepare_external_skill_source_workspace(&job_dir, form) {
        return app_server_failure_json(
            &command,
            command_source,
            None,
            None,
            false,
            false,
            false,
            &error,
        );
    }

    match run_pet_studio_session_stdio_command(
        &command,
        command_source,
        &job_dir,
        job_id,
        form,
        &mut on_update,
        &mut should_cancel,
    ) {
        Ok(value) => value,
        Err(error) => app_server_failure_json(
            &command,
            command_source,
            None,
            None,
            false,
            false,
            false,
            &error,
        ),
    }
}

fn prepare_external_skill_source_workspace(
    job_dir: &std::path::Path,
    form: &GenerationForm,
) -> Result<()> {
    if !app_server_requires_external_skill_source() {
        return Ok(());
    }

    std::fs::write(
        job_dir.join(PET_STUDIO_EXTERNAL_FORM_NAME),
        serde_json::to_vec_pretty(form)?,
    )?;
    std::fs::write(
        job_dir.join(PET_STUDIO_EXTERNAL_HELPER_NAME),
        PET_STUDIO_EXTERNAL_HELPER,
    )?;
    Ok(())
}

fn probe_stdio_command(command: &str) -> Result<Value> {
    let mut session = StdioSession::spawn(command)?;

    let initialize = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "AgentPetCompanion",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {}
        }
    });
    session.send(&initialize)?;
    let response = session.read_response(1, "initialize", PROBE_TIMEOUT)?;
    session.terminate();

    if response.get("error").is_some() {
        return Err(response_error(
            "initialize",
            "initialize",
            1,
            &response,
            &session,
        ));
    }
    Ok(response)
}

fn run_pet_studio_session_stdio_command(
    command: &str,
    command_source: &str,
    job_dir: &std::path::Path,
    job_id: &str,
    form: &GenerationForm,
    on_update: &mut dyn FnMut(PetStudioSessionUpdate),
    should_cancel: &mut dyn FnMut() -> bool,
) -> Result<Value> {
    let mut session = StdioSession::spawn(command)?;
    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "AgentPetCompanion",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {}
        }
    }))?;
    let initialize = session.read_response(1, "initialize", PROBE_TIMEOUT)?;
    if initialize.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "initialize",
            "initialize",
            1,
            &initialize,
            &session,
        ));
    }

    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "cwd": job_dir.display().to_string(),
            "ephemeral": false,
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "baseInstructions": "You are Agent Pet Studio running inside Agent Pet Companion. Generate only Agent Pet Companion .petpack assets for the current generation job.",
            "developerInstructions": pet_studio_developer_instructions(job_id, form),
            "threadSource": "agent-pet-companion"
        }
    }))?;
    let thread_response = session.read_response(2, "thread/start", THREAD_START_TIMEOUT)?;
    if thread_response.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "thread_start",
            "thread/start",
            2,
            &thread_response,
            &session,
        ));
    }

    let thread = thread_response
        .get("result")
        .and_then(|result| result.get("thread"));
    let thread_id = thread
        .and_then(|thread| thread.get("id"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "Codex App Server thread/start returned no thread id".to_string(),
            )
        })?;
    let session_id = thread
        .and_then(|thread| thread.get("sessionId"))
        .and_then(Value::as_str)
        .unwrap_or(thread_id);
    on_update(PetStudioSessionUpdate {
        content: format!(
            "已创建 Codex App Server 会话 {thread_id}，正在启动 Pet Studio brief turn。"
        ),
        progress: 0.08,
    });

    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "cwd": job_dir.display().to_string(),
            "approvalPolicy": "never",
            "sandboxPolicy": {
                "type": "workspaceWrite",
                "networkAccess": false
            },
            "input": [
                {
                    "type": "text",
                    "text": pet_studio_turn_prompt(form)
                }
            ]
        }
    }))?;
    let turn_response = session.read_response(3, "turn/start", TURN_START_TIMEOUT)?;
    if turn_response.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "turn_start",
            "turn/start",
            3,
            &turn_response,
            &session,
        ));
    }

    let turn_id = turn_response
        .get("result")
        .and_then(|result| result.get("turn"))
        .and_then(|turn| turn.get("id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    on_update(PetStudioSessionUpdate {
        content: format!(
            "Pet Studio brief turn 已启动（{}），等待 Codex 返回角色设定与动作方案。",
            turn_id.as_deref().unwrap_or("unknown")
        ),
        progress: 0.10,
    });
    let mut collected =
        collect_turn_events(&mut session, TURN_RUN_TIMEOUT, on_update, should_cancel)?;
    let helper_turn = maybe_run_external_helper_turn(
        &mut session,
        thread_id,
        job_dir,
        false,
        on_update,
        should_cancel,
    )?;
    merge_helper_turn(&mut collected, helper_turn.as_ref());
    session.terminate();

    let parsed_ai_brief = parse_ai_brief(collected.assistant_text.as_deref().unwrap_or(""));
    if let Some(question) = input_request_question_from_parsed(&parsed_ai_brief) {
        return Ok(json!({
            "initialized": true,
            "started": true,
            "turn_started": true,
            "completed": collected.completed,
            "needs_input": true,
            "input_request": {
                "question": question
            },
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339(),
            "thread_id": thread_id,
            "session_id": session_id,
            "turn_id": turn_id,
            "assistant_text": collected.assistant_text,
            "ai_brief": parsed_ai_brief,
            "ai_brief_warnings": [],
            "events": collected.events,
            "helper_turn_started": helper_turn.is_some(),
            "helper_turn_id": helper_turn.as_ref().and_then(|turn| turn.turn_id.as_deref()),
            "helper_completed": helper_turn.as_ref().map(|turn| turn.collected.completed),
            "helper_error": helper_turn.as_ref().and_then(|turn| turn.collected.error.as_deref()),
            "helper_response": helper_turn.as_ref().map(|turn| &turn.turn_response),
            "response": thread_response,
            "turn_response": turn_response,
            "error": collected.error
        }));
    }
    let (ai_brief, ai_brief_warnings) = normalize_ai_brief(parsed_ai_brief);
    Ok(json!({
        "initialized": true,
        "started": true,
        "turn_started": true,
        "completed": collected.completed,
        "mode": "configured",
        "transport": "stdio",
        "command": command,
        "command_source": command_source,
        "checked_at": now_rfc3339(),
        "thread_id": thread_id,
        "session_id": session_id,
        "turn_id": turn_id,
        "assistant_text": collected.assistant_text,
        "ai_brief": ai_brief,
        "ai_brief_warnings": ai_brief_warnings,
        "events": collected.events,
        "helper_turn_started": helper_turn.is_some(),
        "helper_turn_id": helper_turn.as_ref().and_then(|turn| turn.turn_id.as_deref()),
        "helper_completed": helper_turn.as_ref().map(|turn| turn.collected.completed),
        "helper_error": helper_turn.as_ref().and_then(|turn| turn.collected.error.as_deref()),
        "helper_response": helper_turn.as_ref().map(|turn| &turn.turn_response),
        "response": thread_response,
        "turn_response": turn_response,
        "error": collected.error
    }))
}

pub fn run_pet_studio_follow_up_with_updates<F>(
    paths: &AppPaths,
    job_id: &str,
    thread_id: &str,
    form: &GenerationForm,
    previous_ai_brief: Option<&Value>,
    user_message: &str,
    on_update: F,
) -> Value
where
    F: FnMut(PetStudioSessionUpdate),
{
    run_pet_studio_follow_up_with_updates_and_cancel(
        paths,
        job_id,
        thread_id,
        form,
        previous_ai_brief,
        user_message,
        on_update,
        || false,
    )
}

#[allow(clippy::too_many_arguments)] // Callback-based transport boundary; fields mirror protocol state.
pub fn run_pet_studio_follow_up_with_updates_and_cancel<F, C>(
    paths: &AppPaths,
    job_id: &str,
    thread_id: &str,
    form: &GenerationForm,
    previous_ai_brief: Option<&Value>,
    user_message: &str,
    mut on_update: F,
    mut should_cancel: C,
) -> Value
where
    F: FnMut(PetStudioSessionUpdate),
    C: FnMut() -> bool,
{
    let (command, command_source) = match codex_app_server_command() {
        Some(command) => command,
        None => return missing_app_server_json(),
    };

    let job_dir = paths.jobs_dir.join(job_id);
    if let Err(error) = std::fs::create_dir_all(&job_dir) {
        return json!({
            "initialized": false,
            "started": false,
            "resumed": false,
            "turn_started": false,
            "completed": false,
            "follow_up": true,
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339(),
            "error": format!("generation job workspace is unavailable: {error}")
        });
    }
    if let Err(error) = prepare_external_skill_source_workspace(&job_dir, form) {
        return app_server_failure_json(
            &command,
            command_source,
            Some(thread_id),
            None,
            false,
            false,
            true,
            &error,
        );
    }

    match run_pet_studio_follow_up_stdio_command(
        &command,
        command_source,
        &job_dir,
        job_id,
        thread_id,
        form,
        previous_ai_brief,
        user_message,
        &mut on_update,
        &mut should_cancel,
    ) {
        Ok(value) => value,
        Err(error) => app_server_failure_json(
            &command,
            command_source,
            Some(thread_id),
            None,
            false,
            false,
            true,
            &error,
        ),
    }
}

#[allow(clippy::too_many_arguments)] // Keeps follow-up protocol inputs explicit at the stdio boundary.
fn run_pet_studio_follow_up_stdio_command(
    command: &str,
    command_source: &str,
    job_dir: &std::path::Path,
    job_id: &str,
    thread_id: &str,
    form: &GenerationForm,
    previous_ai_brief: Option<&Value>,
    user_message: &str,
    on_update: &mut dyn FnMut(PetStudioSessionUpdate),
    should_cancel: &mut dyn FnMut() -> bool,
) -> Result<Value> {
    let mut session = StdioSession::spawn(command)?;
    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "AgentPetCompanion",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {}
        }
    }))?;
    let initialize = session.read_response(1, "initialize", PROBE_TIMEOUT)?;
    if initialize.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "initialize",
            "initialize",
            1,
            &initialize,
            &session,
        ));
    }

    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/resume",
        "params": {
            "threadId": thread_id,
            "cwd": job_dir.display().to_string(),
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "baseInstructions": "You are Agent Pet Studio running inside Agent Pet Companion. Continue the same pet generation job and update only Agent Pet Companion .petpack assets.",
            "developerInstructions": pet_studio_developer_instructions(job_id, form)
        }
    }))?;
    let resume_response = session.read_response(2, "thread/resume", THREAD_START_TIMEOUT)?;
    if resume_response.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "thread_resume",
            "thread/resume",
            2,
            &resume_response,
            &session,
        ));
    }

    let resumed_thread_id = resume_response
        .get("result")
        .and_then(|result| result.get("thread"))
        .and_then(|thread| thread.get("id"))
        .and_then(Value::as_str)
        .unwrap_or(thread_id);
    let session_id = resume_response
        .get("result")
        .and_then(|result| result.get("thread"))
        .and_then(|thread| thread.get("sessionId"))
        .and_then(Value::as_str)
        .unwrap_or(resumed_thread_id);
    on_update(PetStudioSessionUpdate {
        content: format!("已恢复 Codex App Server 会话 {resumed_thread_id}，正在处理调整意见。"),
        progress: 0.08,
    });

    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": resumed_thread_id,
            "cwd": job_dir.display().to_string(),
            "approvalPolicy": "never",
            "sandboxPolicy": {
                "type": "workspaceWrite",
                "networkAccess": false
            },
            "input": [
                {
                    "type": "text",
                    "text": pet_studio_follow_up_prompt(form, previous_ai_brief, user_message)
                }
            ]
        }
    }))?;
    let turn_response = session.read_response(3, "turn/start", TURN_START_TIMEOUT)?;
    if turn_response.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "turn_start",
            "turn/start",
            3,
            &turn_response,
            &session,
        ));
    }

    let turn_id = turn_response
        .get("result")
        .and_then(|result| result.get("turn"))
        .and_then(|turn| turn.get("id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    on_update(PetStudioSessionUpdate {
        content: format!(
            "调整 turn 已启动（{}），等待 Codex 返回更新后的 brief。",
            turn_id.as_deref().unwrap_or("unknown")
        ),
        progress: 0.10,
    });
    let mut collected =
        collect_turn_events(&mut session, TURN_RUN_TIMEOUT, on_update, should_cancel)?;
    let helper_turn = maybe_run_external_helper_turn(
        &mut session,
        resumed_thread_id,
        job_dir,
        true,
        on_update,
        should_cancel,
    )?;
    merge_helper_turn(&mut collected, helper_turn.as_ref());
    session.terminate();

    let parsed_ai_brief = parse_ai_brief(collected.assistant_text.as_deref().unwrap_or(""));
    if let Some(question) = input_request_question_from_parsed(&parsed_ai_brief) {
        return Ok(json!({
            "initialized": true,
            "started": true,
            "resumed": true,
            "turn_started": true,
            "completed": collected.completed,
            "follow_up": true,
            "needs_input": true,
            "input_request": {
                "question": question
            },
            "mode": "configured",
            "transport": "stdio",
            "command": command,
            "command_source": command_source,
            "checked_at": now_rfc3339(),
            "thread_id": resumed_thread_id,
            "session_id": session_id,
            "turn_id": turn_id,
            "assistant_text": collected.assistant_text,
            "ai_brief": parsed_ai_brief,
            "ai_brief_warnings": [],
            "events": collected.events,
            "helper_turn_started": helper_turn.is_some(),
            "helper_turn_id": helper_turn.as_ref().and_then(|turn| turn.turn_id.as_deref()),
            "helper_completed": helper_turn.as_ref().map(|turn| turn.collected.completed),
            "helper_error": helper_turn.as_ref().and_then(|turn| turn.collected.error.as_deref()),
            "helper_response": helper_turn.as_ref().map(|turn| &turn.turn_response),
            "response": resume_response,
            "turn_response": turn_response,
            "error": collected.error
        }));
    }
    let (ai_brief, ai_brief_warnings) = normalize_ai_brief(parsed_ai_brief);
    Ok(json!({
        "initialized": true,
        "started": true,
        "resumed": true,
        "turn_started": true,
        "completed": collected.completed,
        "follow_up": true,
        "mode": "configured",
        "transport": "stdio",
        "command": command,
        "command_source": command_source,
        "checked_at": now_rfc3339(),
        "thread_id": resumed_thread_id,
        "session_id": session_id,
        "turn_id": turn_id,
        "assistant_text": collected.assistant_text,
        "ai_brief": ai_brief,
        "ai_brief_warnings": ai_brief_warnings,
        "events": collected.events,
        "helper_turn_started": helper_turn.is_some(),
        "helper_turn_id": helper_turn.as_ref().and_then(|turn| turn.turn_id.as_deref()),
        "helper_completed": helper_turn.as_ref().map(|turn| turn.collected.completed),
        "helper_error": helper_turn.as_ref().and_then(|turn| turn.collected.error.as_deref()),
        "helper_response": helper_turn.as_ref().map(|turn| &turn.turn_response),
        "response": resume_response,
        "turn_response": turn_response,
        "error": collected.error
    }))
}

#[derive(Debug, Default)]
struct CollectedTurn {
    completed: bool,
    assistant_text: Option<String>,
    events: Vec<Value>,
    error: Option<String>,
}

#[derive(Debug)]
struct ExternalHelperTurn {
    turn_id: Option<String>,
    turn_response: Value,
    collected: CollectedTurn,
}

fn maybe_run_external_helper_turn(
    session: &mut StdioSession,
    thread_id: &str,
    job_dir: &std::path::Path,
    adjusted: bool,
    on_update: &mut dyn FnMut(PetStudioSessionUpdate),
    should_cancel: &mut dyn FnMut() -> bool,
) -> Result<Option<ExternalHelperTurn>> {
    if !app_server_requires_external_skill_source()
        || job_dir
            .join("petpack-source")
            .join("manifest.json")
            .is_file()
    {
        return Ok(None);
    }

    on_update(PetStudioSessionUpdate {
        content: "Codex 已返回 brief，但尚未写出外部 petpack-source；正在启动 helper 写源包 turn。"
            .to_string(),
        progress: 0.15,
    });
    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "cwd": job_dir.display().to_string(),
            "approvalPolicy": "never",
            "sandboxPolicy": {
                "type": "workspaceWrite",
                "networkAccess": false
            },
            "input": [
                {
                    "type": "text",
                    "text": pet_studio_external_helper_prompt(adjusted)
                }
            ]
        }
    }))?;
    let turn_response = session.read_response(3, "turn/start", TURN_START_TIMEOUT)?;
    if turn_response.get("error").is_some() {
        return Err(response_error(
            "helper_turn_start",
            "turn/start",
            3,
            &turn_response,
            session,
        ));
    }
    let turn_id = turn_response
        .get("result")
        .and_then(|result| result.get("turn"))
        .and_then(|turn| turn.get("id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    on_update(PetStudioSessionUpdate {
        content: format!(
            "helper turn 已启动（{}），等待 App Server 执行 petpack-source 生成脚本。",
            turn_id.as_deref().unwrap_or("unknown")
        ),
        progress: 0.16,
    });
    let collected = collect_turn_events(
        session,
        EXTERNAL_HELPER_TURN_TIMEOUT,
        on_update,
        should_cancel,
    )?;
    Ok(Some(ExternalHelperTurn {
        turn_id,
        turn_response,
        collected,
    }))
}

fn merge_helper_turn(collected: &mut CollectedTurn, helper_turn: Option<&ExternalHelperTurn>) {
    if let Some(helper_turn) = helper_turn {
        collected
            .events
            .extend(helper_turn.collected.events.iter().cloned());
        if helper_turn.collected.completed {
            collected.completed = true;
        }
        if helper_turn.collected.error.is_some() {
            collected.error = helper_turn.collected.error.clone();
        }
    }
}

fn collect_turn_events(
    session: &mut StdioSession,
    timeout: Duration,
    on_update: &mut dyn FnMut(PetStudioSessionUpdate),
    should_cancel: &mut dyn FnMut() -> bool,
) -> Result<CollectedTurn> {
    let deadline = Instant::now() + timeout;
    let mut collected = CollectedTurn::default();
    let mut delta_text = String::new();
    let mut announced_delta = false;

    loop {
        if should_cancel() {
            collected.error = Some("generation canceled".to_string());
            return Ok(collected);
        }
        let now = Instant::now();
        if now >= deadline {
            if !delta_text.trim().is_empty() {
                collected.assistant_text = Some(delta_text);
            }
            collected.error = Some(format!(
                "Codex App Server turn did not complete within {} ms",
                timeout.as_millis()
            ));
            return Ok(collected);
        }

        let remaining = deadline.saturating_duration_since(now);
        let read_timeout = remaining.min(CANCEL_POLL_INTERVAL);
        let Some(notification) = session.read_next(read_timeout)? else {
            continue;
        };
        let method = notification
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("");
        let params = notification
            .get("params")
            .cloned()
            .unwrap_or_else(|| json!({}));
        match method {
            "item/agentMessage/delta" => {
                if let Some(delta) = params.get("delta").and_then(Value::as_str) {
                    delta_text.push_str(delta);
                    if !announced_delta {
                        announced_delta = true;
                        on_update(PetStudioSessionUpdate {
                            content: "Codex 正在生成宠物 brief、调色和 7 个状态动作方案。"
                                .to_string(),
                            progress: 0.11,
                        });
                    }
                }
            }
            "item/completed" => {
                if let Some(item) = params.get("item") {
                    let item_type = item.get("type").and_then(Value::as_str);
                    if item_type == Some("agentMessage") {
                        if let Some(text) = item.get("text").and_then(Value::as_str) {
                            collected.assistant_text = Some(text.to_string());
                        } else if !delta_text.trim().is_empty() {
                            collected.assistant_text = Some(delta_text.clone());
                        }
                        collected.completed = true;
                        collected.events.push(slim_event(method, &params));
                        on_update(PetStudioSessionUpdate {
                            content: "已收到 Codex 回复，正在检查 Studio 会话结果。".to_string(),
                            progress: 0.14,
                        });
                        return Ok(collected);
                    }
                }
            }
            "error" | "turn/error" => {
                collected.error = Some(params.to_string());
                collected.events.push(slim_event(method, &params));
                return Ok(collected);
            }
            _ => {}
        }

        if should_keep_event(method) && collected.events.len() < 80 {
            collected.events.push(slim_event(method, &params));
        }
    }
}

fn should_keep_event(method: &str) -> bool {
    matches!(
        method,
        "turn/started"
            | "thread/status/changed"
            | "item/started"
            | "item/completed"
            | "turn/plan/updated"
            | "warning"
            | "thread/tokenUsage/updated"
            | "account/rateLimits/updated"
    )
}

fn slim_event(method: &str, params: &Value) -> Value {
    match method {
        "item/started" | "item/completed" => json!({
            "method": method,
            "item_type": params
                .get("item")
                .and_then(|item| item.get("type"))
                .and_then(Value::as_str),
            "item_id": params
                .get("item")
                .and_then(|item| item.get("id"))
                .and_then(Value::as_str),
            "turn_id": params.get("turnId").and_then(Value::as_str)
        }),
        _ => json!({
            "method": method,
            "turn_id": params.get("turnId").and_then(Value::as_str),
            "thread_id": params.get("threadId").and_then(Value::as_str)
        }),
    }
}

fn start_thread_stdio_command(command: &str, thread_params: Value) -> Result<Value> {
    let mut session = StdioSession::spawn(command)?;
    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "AgentPetCompanion",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {}
        }
    }))?;
    let initialize = session.read_response(1, "initialize", PROBE_TIMEOUT)?;
    if initialize.get("error").is_some() {
        session.terminate();
        return Err(response_error(
            "initialize",
            "initialize",
            1,
            &initialize,
            &session,
        ));
    }

    session.send(&json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": thread_params
    }))?;
    let response = session.read_response(2, "thread/start", THREAD_START_TIMEOUT)?;
    session.terminate();

    if response.get("error").is_some() {
        return Err(response_error(
            "thread_start",
            "thread/start",
            2,
            &response,
            &session,
        ));
    }
    Ok(response)
}

#[allow(clippy::too_many_arguments)] // Diagnostic fields intentionally map one-to-one to the JSON payload.
fn app_server_failure_json(
    command: &str,
    command_source: &str,
    thread_id: Option<&str>,
    turn_id: Option<&str>,
    initialized: bool,
    started: bool,
    follow_up: bool,
    error: &PetCoreError,
) -> Value {
    let error_info = error_info_from_error(error);
    let stage = error_info
        .get("stage")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let initialized = initialized
        || matches!(
            stage,
            "thread_start" | "thread_resume" | "turn_start" | "turn_events"
        );
    let started = started || matches!(stage, "turn_start" | "turn_events");
    let turn_started = matches!(stage, "turn_events");

    let mut value = json!({
        "initialized": initialized,
        "started": started,
        "turn_started": turn_started,
        "completed": false,
        "mode": "configured",
        "transport": "stdio",
        "command": command,
        "command_source": command_source,
        "checked_at": now_rfc3339(),
        "error": error_detail_from_info(error, &error_info),
        "error_info": error_info,
    });
    if let Some(object) = value.as_object_mut() {
        if follow_up {
            object.insert("follow_up".to_string(), json!(true));
            object.insert(
                "resumed".to_string(),
                json!(matches!(stage, "turn_start" | "turn_events")),
            );
        }
        if let Some(thread_id) = thread_id {
            object.insert("thread_id".to_string(), json!(thread_id));
        }
        if let Some(turn_id) = turn_id {
            object.insert("turn_id".to_string(), json!(turn_id));
        }
    }
    value
}

fn response_error(
    stage: &str,
    method: &str,
    request_id: i64,
    response: &Value,
    session: &StdioSession,
) -> PetCoreError {
    let detail = response
        .get("error")
        .and_then(codex_error_summary)
        .unwrap_or_else(|| format!("Codex App Server {method} returned an error response"));
    validation_with_error_info(app_server_error_info_json(
        "server_error",
        stage,
        method,
        Some(request_id),
        detail,
        None,
        Some(response.clone()),
        session.stderr_tail_value(),
    ))
}

fn validation_with_error_info(error_info: Value) -> PetCoreError {
    PetCoreError::Validation(
        serde_json::to_string(&error_info).unwrap_or_else(|_| error_info.to_string()),
    )
}

fn error_info_from_error(error: &PetCoreError) -> Value {
    match error {
        PetCoreError::Validation(message) => serde_json::from_str(message).unwrap_or_else(|_| {
            json!({
                "kind": "validation",
                "stage": "unknown",
                "detail": message,
            })
        }),
        other => json!({
            "kind": "petcore_error",
            "stage": "unknown",
            "detail": other.to_string(),
        }),
    }
}

fn error_detail_from_info(error: &PetCoreError, error_info: &Value) -> String {
    error_info
        .get("detail")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| match error {
            PetCoreError::Validation(message) => message.clone(),
            other => other.to_string(),
        })
}

#[allow(clippy::too_many_arguments)] // Diagnostic fields intentionally map one-to-one to the JSON payload.
fn app_server_error_info_json(
    kind: &str,
    stage: &str,
    method: &str,
    request_id: Option<i64>,
    detail: String,
    raw_line: Option<String>,
    response: Option<Value>,
    stderr_tail: Value,
) -> Value {
    let mut value = json!({
        "kind": kind,
        "stage": stage,
        "method": method,
        "detail": detail,
        "stderr_tail": stderr_tail,
    });
    if let Some(object) = value.as_object_mut() {
        if let Some(request_id) = request_id {
            object.insert("request_id".to_string(), json!(request_id));
        }
        if let Some(raw_line) = raw_line {
            object.insert("raw_line".to_string(), json!(raw_line));
        }
        if let Some(response) = response {
            object.insert("response".to_string(), response);
        }
    }
    value
}

fn codex_error_summary(error: &Value) -> Option<String> {
    if let Some(message) = error.get("message").and_then(Value::as_str) {
        let code = error
            .get("code")
            .map(Value::to_string)
            .unwrap_or_else(|| "unknown".to_string());
        return Some(format!("Codex App Server error {code}: {message}"));
    }
    if let Some(text) = error.as_str() {
        return Some(text.to_string());
    }
    Some(error.to_string()).filter(|text| !text.trim().is_empty())
}

fn method_stage(method: &str) -> &'static str {
    match method {
        "initialize" => "initialize",
        "thread/start" => "thread_start",
        "thread/resume" => "thread_resume",
        "turn/start" => "turn_start",
        "notification" => "turn_events",
        _ => "stdio",
    }
}

struct StdioSession {
    child: Child,
    stdin: Option<ChildStdin>,
    rx: Receiver<StdoutItem>,
    stderr_tail: Arc<Mutex<Vec<String>>>,
}

enum StdoutItem {
    Line(String),
    Eof,
    Io(std::io::Error),
}

impl StdioSession {
    fn spawn(command: &str) -> Result<Self> {
        let cli_path = petcore_cli_path();
        let mut child_command = Command::new("sh");
        child_command
            .arg("-lc")
            .arg(command)
            .env("APC_PETCORE_CLI", &cli_path)
            .env("PATH", app_server_child_path_environment(&cli_path))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = child_command.spawn()?;

        let stdin = child.stdin.take().ok_or_else(|| {
            PetCoreError::Validation("Codex App Server stdin unavailable".to_string())
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            PetCoreError::Validation("Codex App Server stdout unavailable".to_string())
        })?;
        let stderr = child.stderr.take();
        let (tx, rx) = mpsc::channel();
        let stderr_tail = Arc::new(Mutex::new(Vec::new()));

        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = String::new();
                match reader.read_line(&mut line) {
                    Ok(0) => {
                        let _ = tx.send(StdoutItem::Eof);
                        break;
                    }
                    Ok(_) => {
                        if tx.send(StdoutItem::Line(line)).is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = tx.send(StdoutItem::Io(error));
                        break;
                    }
                }
            }
        });

        if let Some(stderr) = stderr {
            let tail = Arc::clone(&stderr_tail);
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stderr);
                loop {
                    let mut line = String::new();
                    match reader.read_line(&mut line) {
                        Ok(0) => break,
                        Ok(_) => {
                            let trimmed = line.trim();
                            if trimmed.is_empty() {
                                continue;
                            }
                            if let Ok(mut lines) = tail.lock() {
                                lines.push(trimmed.chars().take(500).collect());
                                if lines.len() > 20 {
                                    let excess = lines.len() - 20;
                                    lines.drain(0..excess);
                                }
                            }
                        }
                        Err(_) => break,
                    }
                }
            });
        }

        Ok(Self {
            child,
            stdin: Some(stdin),
            rx,
            stderr_tail,
        })
    }

    fn send(&mut self, request: &Value) -> Result<()> {
        let stdin = self.stdin.as_mut().ok_or_else(|| {
            PetCoreError::Validation("Codex App Server stdin unavailable".to_string())
        })?;
        writeln!(stdin, "{request}")?;
        stdin.flush()?;
        Ok(())
    }

    fn read_response(&mut self, id: i64, method: &str, timeout: Duration) -> Result<Value> {
        let deadline = Instant::now() + timeout;
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err(self.stdio_error(
                    "timeout",
                    method_stage(method),
                    method,
                    Some(id),
                    format!(
                        "Codex App Server did not answer {method} within {} ms",
                        timeout.as_millis()
                    ),
                    None,
                    None,
                ));
            }
            let remaining = deadline.saturating_duration_since(now);
            let line = match self.rx.recv_timeout(remaining) {
                Ok(StdoutItem::Line(line)) => line,
                Ok(StdoutItem::Eof) => {
                    return Err(self.stdout_eof_error(method_stage(method), method, Some(id)));
                }
                Ok(StdoutItem::Io(error)) => {
                    return Err(self.stdio_error(
                        "stdout_io",
                        method_stage(method),
                        method,
                        Some(id),
                        format!("Codex App Server stdout read failed: {error}"),
                        None,
                        None,
                    ));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    return Err(self.stdio_error(
                        "timeout",
                        method_stage(method),
                        method,
                        Some(id),
                        format!(
                            "Codex App Server did not answer {method} within {} ms",
                            timeout.as_millis()
                        ),
                        None,
                        None,
                    ));
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(self.stdout_eof_error(method_stage(method), method, Some(id)));
                }
            };
            if line.trim().is_empty() {
                continue;
            }
            let response: Value = serde_json::from_str(line.trim()).map_err(|error| {
                self.stdio_error(
                    "invalid_json",
                    method_stage(method),
                    method,
                    Some(id),
                    format!(
                        "Codex App Server emitted invalid JSON while waiting for {method}: {error}"
                    ),
                    Some(line.trim().to_string()),
                    None,
                )
            })?;
            if response.get("id").and_then(Value::as_i64) == Some(id) {
                return Ok(response);
            }
        }
    }

    fn read_next(&mut self, timeout: Duration) -> Result<Option<Value>> {
        match self.rx.recv_timeout(timeout) {
            Ok(StdoutItem::Line(line)) => {
                if line.trim().is_empty() {
                    return Ok(None);
                }
                let value = serde_json::from_str(line.trim()).map_err(|error| {
                    self.stdio_error(
                        "invalid_json",
                        "turn_events",
                        "notification",
                        None,
                        format!("Codex App Server emitted invalid JSON notification: {error}"),
                        Some(line.trim().to_string()),
                        None,
                    )
                })?;
                Ok(Some(value))
            }
            Ok(StdoutItem::Eof) => Err(self.stdout_eof_error("turn_events", "notification", None)),
            Ok(StdoutItem::Io(error)) => Err(self.stdio_error(
                "stdout_io",
                "turn_events",
                "notification",
                None,
                format!("Codex App Server stdout read failed: {error}"),
                None,
                None,
            )),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(self.stdout_eof_error("turn_events", "notification", None))
            }
        }
    }

    fn stdout_eof_error(
        &mut self,
        stage: &str,
        method: &str,
        request_id: Option<i64>,
    ) -> PetCoreError {
        let exit_detail = self.exit_detail_after_stdout_eof();
        self.stdio_error(
            "stdout_eof",
            stage,
            method,
            request_id,
            format!("Codex App Server stdout closed unexpectedly{exit_detail}"),
            None,
            None,
        )
    }

    fn exit_detail_after_stdout_eof(&mut self) -> String {
        // stdout can reach EOF a few scheduler ticks before waitpid observes the
        // corresponding child exit. Give that status a small absolute grace
        // period so diagnostics include the real code without turning EOF into
        // another unbounded wait.
        let deadline = Instant::now() + Duration::from_millis(100);
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) => {
                    return status
                        .code()
                        .map(|code| format!(" with exit code {code}"))
                        .unwrap_or_else(|| format!(" with status {status}"));
                }
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(2));
                }
                Ok(None) => return " while the child process was still running".to_string(),
                Err(error) => return format!("; child status was unavailable: {error}"),
            }
        }
    }

    fn stderr_tail_value(&self) -> Value {
        let lines = self
            .stderr_tail
            .lock()
            .map(|lines| lines.clone())
            .unwrap_or_default();
        Value::Array(lines.into_iter().map(Value::String).collect())
    }

    #[allow(clippy::too_many_arguments)] // Method/request context is required for actionable transport errors.
    fn stdio_error(
        &self,
        kind: &str,
        stage: &str,
        method: &str,
        request_id: Option<i64>,
        detail: String,
        raw_line: Option<String>,
        response: Option<Value>,
    ) -> PetCoreError {
        validation_with_error_info(app_server_error_info_json(
            kind,
            stage,
            method,
            request_id,
            detail,
            raw_line,
            response,
            self.stderr_tail_value(),
        ))
    }

    fn terminate(&mut self) {
        let _ = self.stdin.take();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for StdioSession {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn codex_app_server_command() -> Option<(String, &'static str)> {
    match std::env::var("CODEX_APP_SERVER_CMD") {
        Ok(command) if !command.trim().is_empty() => Some((command, "env")),
        _ if app_server_auto_disabled() => None,
        _ => default_codex_app_server_command().map(|command| (command, "auto")),
    }
}

fn missing_app_server_json() -> Value {
    json!({
        "initialized": false,
        "started": false,
        "mode": "missing",
        "transport": "stdio",
        "checked_at": now_rfc3339(),
        "detail": "CODEX_APP_SERVER_CMD is not configured and codex app-server was not found. Configure Codex App Server before starting Pet Studio generation.",
        "skip_reason": "CODEX_APP_SERVER_CMD is unset and no codex app-server command was discovered on PATH.",
        "error_info": {
            "kind": "not_configured",
            "stage": "configuration",
            "method": "command_discovery",
            "detail": "Set CODEX_APP_SERVER_CMD to a stdio App Server command, or install a codex CLI that exposes `codex app-server --stdio`.",
            "safe_inputs": ["CODEX_APP_SERVER_CMD", "PATH"],
            "secret_policy": "Agent Pet Companion does not read auth, token, cookie, or API key files."
        }
    })
}

fn app_server_auto_disabled() -> bool {
    std::env::var("APC_DISABLE_CODEX_APP_SERVER_AUTO")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn pet_studio_developer_instructions(job_id: &str, form: &GenerationForm) -> String {
    let petcore_cli = petcore_cli_command();
    let strict_full_source = app_server_requires_skill_full_source();
    let strict_external_source = app_server_requires_external_skill_source();
    let output_mode = if strict_external_source {
        r#"External full source mode is mandatory for this run because APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1. The current job workspace already contains `apc_skill_form.json` and `apc_write_skill_source.py`. Run `python3 apc_write_skill_source.py`, validate the created `petpack-source`, and return only a compact status JSON. Returning only a brief JSON is not accepted in this mode."#
    } else if strict_full_source {
        r#"Full source mode is mandatory for this run because APC_REQUIRE_SKILL_FULL_SOURCE=1. Return a complete structured Pet Studio brief JSON; PetCore will run its built-in Pet Studio Skill materializer to write and validate `petpack-source` with trusted Skill provenance. Do not run `petcore-cli petpack materialize`; CLI materialization is fallback output and will be rejected as trusted Skill provenance."#
    } else {
        r#"Prefer full source mode when file-writing tools are available. If full source mode is not available, return compact brief JSON and PetCore will materialize the brief."#
    };
    format!(
        r#"Use the agent-pet-studio skill for generation job {job_id}.

Input form JSON:
{form_json}

PetCore CLI:
- Absolute command: {petcore_cli}
- The same path is available as the APC_PETCORE_CLI environment variable.

Required workflow:
1. {output_mode}
2. Read the Studio form and staged reference image path names only as user-provided visual context.
3. If details are missing and generation would require guessing the pet identity, return compact JSON only in this shape: {{"needs_input":true,"question":"one concise Studio follow-up question"}}.
4. In external full-source mode, use an image-capable tool to write manifest.json, brief.json, visibly distinct frame sequences for all seven fixed states, preview assets, source metadata, and build/validation.json under `petpack-source`. The staged `apc_write_skill_source.py` helper is deterministic preview output and is rejected as real image generation.
5. Built-in/simple generated transparent PNG frames must be labeled deterministic preview and cannot satisfy external full-source validation.
6. Use fixed states: idle, start, tool, waiting, review, done, failed.
7. PetCore will prefer a validated Skill-created `petpack-source`; non-strict runs may fall back to materializing returned brief JSON.
8. Do not read agent auth, token, cookie, API key, or unrelated project files."#,
        form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
    )
}

fn pet_studio_turn_prompt(form: &GenerationForm) -> String {
    if app_server_requires_external_skill_source() {
        return format!(
            r#"Use the agent-pet-studio skill constraints to generate one Agent Pet Companion desktop pet.

This run requires external full source mode. Create a complete `petpack-source` directory using an image-capable tool available to this App Server turn. PetCore will not materialize a returned brief.

Do not run `{helper_name}`. It creates deterministic preview geometry and is rejected as evidence of AI image generation.

Create at least two visibly distinct PNG frames for every fixed state, then run:
$APC_PETCORE_CLI petpack validate petpack-source

After validation passes, return only compact JSON:
{{"petpack_source":"petpack-source","mode":"external_full_source"}}

Required metadata: `source/source.json` must include {{"generator":"codex-app-server-skill","provenance":"skill-full-source","visual_source":"image-generation","frames_per_state":2,"preview_only":false}} and must not include `materialized_by`. Use `visual_source:"user-reference-derived"` only when the visible result actually derives from the staged user reference.

If details are missing and generation would require guessing the pet identity, return only:
{{"needs_input":true,"question":"one concise Studio follow-up question"}}

Do not read secrets or unrelated project files.

Studio form JSON:
{form_json}"#,
            helper_name = PET_STUDIO_EXTERNAL_HELPER_NAME,
            form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
        );
    }

    if app_server_requires_skill_full_source() {
        return format!(
            r#"Use the agent-pet-studio skill constraints to generate one Agent Pet Companion desktop pet.

This run requires real full source mode. In this host, PetCore's built-in Pet Studio Skill materializer writes the full `petpack-source` from your structured brief.

Do not write files and do not run `petcore-cli petpack materialize`; CLI materialization writes fallback provenance and will be rejected for this strict run.

Return only compact JSON with this exact shape:
{{
  "name": "short pet name",
  "visual_brief": "one paragraph describing appearance, material, expression, and silhouette",
  "palette": ["color or material note", "color or material note", "color or material note"],
  "states": [
    {{"name":"idle","motion":"motion notes"}},
    {{"name":"start","motion":"motion notes"}},
    {{"name":"tool","motion":"motion notes"}},
    {{"name":"waiting","motion":"motion notes"}},
    {{"name":"review","motion":"motion notes"}},
    {{"name":"done","motion":"motion notes"}},
    {{"name":"failed","motion":"motion notes"}}
  ],
  "render_notes": "constraints for PNG frame materialization",
  "petpack_source": "petpack-source"
}}

Use exact runtime quality dimensions from the form. Use fixed states: idle, start, tool, waiting, review, done, failed.

Do not read secrets or unrelated project files.

Studio form JSON:
{form_json}"#,
            form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
        );
    }

    format!(
        r#"Use the agent-pet-studio skill constraints to generate one Agent Pet Companion desktop pet.

Preferred output: if file-writing tools are available, use full source mode and create a complete `petpack-source` directory in the current turn cwd. Keep all generated files inside `petpack-source`, include `source/source.json` with `generator` set to `codex-app-server-skill` and `provenance` set to `skill-full-source`, then run:
$APC_PETCORE_CLI petpack validate petpack-source

Fallback output: if full source mode is unavailable in this App Server turn, return compact brief JSON. PetCore will materialize that brief into `petpack-source`, validate, build, and import the `.petpack`.

If the form is missing required identity, appearance, or behavior details and you cannot create a coherent pet without guessing, return only:
{{"needs_input":true,"question":"one concise Studio follow-up question"}}

For fallback brief mode, return only compact JSON with this shape:
{{
  "name": "short pet name",
  "visual_brief": "one paragraph describing appearance, material, expression, and silhouette",
  "palette": ["color or material note", "color or material note", "color or material note"],
  "states": [
    {{"name":"idle","motion":"motion notes"}},
    {{"name":"start","motion":"motion notes"}},
    {{"name":"tool","motion":"motion notes"}},
    {{"name":"waiting","motion":"motion notes"}},
    {{"name":"review","motion":"motion notes"}},
    {{"name":"done","motion":"motion notes"}},
    {{"name":"failed","motion":"motion notes"}}
  ],
  "render_notes": "constraints for PNG frame materialization",
  "petpack_source": "petpack-source"
}}

Do not read secrets or unrelated project files. Do not include markdown in the final response.

Studio form JSON:
{form_json}"#,
        form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
    )
}

fn pet_studio_external_helper_prompt(adjusted: bool) -> String {
    format!(
        r#"Create the Agent Pet Studio external full source now.

Do not run `{helper_name}` because it produces deterministic preview geometry. Use an image-capable tool to create at least two visibly distinct PNG frames for each fixed state, then execute:
$APC_PETCORE_CLI petpack validate petpack-source

Return only this compact JSON after validation succeeds:
{{"petpack_source":"petpack-source","mode":"external_full_source","adjusted":{adjusted}}}

Do not read secrets or unrelated project files."#,
        helper_name = PET_STUDIO_EXTERNAL_HELPER_NAME,
        adjusted = if adjusted { "true" } else { "false" }
    )
}

fn pet_studio_follow_up_prompt(
    form: &GenerationForm,
    previous_ai_brief: Option<&Value>,
    user_message: &str,
) -> String {
    let previous_json = previous_ai_brief
        .map(|value| serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".to_string()))
        .unwrap_or_else(|| "null".to_string());
    let user_message_json =
        serde_json::to_string(user_message).unwrap_or_else(|_| "\"\"".to_string());
    if app_server_requires_external_skill_source() {
        return format!(
            r#"Continue the Agent Pet Companion Pet Studio job by applying the user's adjustment to the previous pet brief.

This run requires external full source mode. Create a complete adjusted `petpack-source` with an image-capable tool, validate it, and do not return fallback brief JSON.

Do not run `{helper_name}` because it creates deterministic preview geometry. Create at least two visibly distinct PNG frames per fixed state, then run:
$APC_PETCORE_CLI petpack validate petpack-source

After validation passes, return only compact JSON:
{{"petpack_source":"petpack-source","mode":"external_full_source","adjusted":true}}

Required metadata: `source/source.json` must include {{"generator":"codex-app-server-skill","provenance":"skill-full-source","visual_source":"image-generation","frames_per_state":2,"preview_only":false}} and must not include `materialized_by`.

Do not read secrets or unrelated project files.

User adjustment JSON string:
{user_message_json}

Previous AI brief JSON:
{previous_json}

Studio form JSON:
{form_json}"#,
            helper_name = PET_STUDIO_EXTERNAL_HELPER_NAME,
            form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
        );
    }

    if app_server_requires_skill_full_source() {
        return format!(
            r#"Continue the Agent Pet Companion Pet Studio job by applying the user's adjustment to the previous pet brief.

This run requires full source mode. Create a complete adjusted `petpack-source` directory in the current turn cwd and validate it before your final response. Do not return fallback brief JSON.

Required metadata: `source/source.json` must include {{"generator":"codex-app-server-skill","provenance":"skill-full-source"}}.
Manifest contract: `manifest.json` must use {{"schema_version":"apc.petpack.v1"}}, an id beginning with `pet_`, exact quality render_size, fps_profiles {{"standard":12,"smooth":20}}, default_fps_profile `"standard"`, and exactly the seven states idle/start/tool/waiting/review/done/failed with frames_dir `assets/frames/<state>`.
Required states: idle, start, tool, waiting, review, done, failed.
Run:
$APC_PETCORE_CLI petpack validate petpack-source

After validation passes, return only compact JSON:
{{"petpack_source":"petpack-source","mode":"full_source","adjusted":true}}

Do not read secrets or unrelated project files.

User adjustment JSON string:
{user_message_json}

Previous AI brief JSON:
{previous_json}

Studio form JSON:
{form_json}"#,
            form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
        );
    }

    format!(
        r#"Continue the Agent Pet Companion Pet Studio job by applying the user's adjustment to the previous pet brief.

Preferred output: if file-writing tools are available, create a complete adjusted `petpack-source` directory in the current turn cwd, include `source/source.json` with `generator` set to `codex-app-server-skill` and `provenance` set to `skill-full-source`, and validate it with:
$APC_PETCORE_CLI petpack validate petpack-source

Fallback output: if full source mode is unavailable in this App Server turn, return compact replacement brief JSON. PetCore will materialize the adjusted brief into `petpack-source`, validate, build, and import the adjusted `.petpack`.

If the user's reply still lacks required identity, appearance, or behavior details and you cannot create a coherent pet without guessing, return only:
{{"needs_input":true,"question":"one concise Studio follow-up question"}}

For fallback brief mode, return only a complete replacement compact JSON brief with this shape:
{{
  "name": "short pet name",
  "visual_brief": "one paragraph describing appearance, material, expression, and silhouette",
  "palette": ["color or material note", "color or material note", "color or material note"],
  "states": [
    {{"name":"idle","motion":"motion notes"}},
    {{"name":"start","motion":"motion notes"}},
    {{"name":"tool","motion":"motion notes"}},
    {{"name":"waiting","motion":"motion notes"}},
    {{"name":"review","motion":"motion notes"}},
    {{"name":"done","motion":"motion notes"}},
    {{"name":"failed","motion":"motion notes"}}
  ],
  "render_notes": "constraints for PNG frame materialization",
  "petpack_source": "petpack-source"
}}

Keep the same product constraints: fixed states, Agent Pet Companion .petpack output handled by PetCore, no Codex built-in pet export, no secrets or unrelated files, and no markdown in the final response.

User adjustment JSON string:
{user_message_json}

Previous AI brief JSON:
{previous_json}

Studio form JSON:
{form_json}"#,
        form_json = serde_json::to_string_pretty(form).unwrap_or_else(|_| "{}".to_string())
    )
}

fn app_server_requires_skill_full_source() -> bool {
    std::env::var("APC_REQUIRE_SKILL_FULL_SOURCE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn app_server_requires_external_skill_source() -> bool {
    std::env::var("APC_REQUIRE_EXTERNAL_SKILL_SOURCE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn parse_ai_brief(text: &str) -> Value {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Value::Null;
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return value;
    }
    if let (Some(start), Some(end)) = (trimmed.find('{'), trimmed.rfind('}')) {
        if start < end {
            if let Ok(value) = serde_json::from_str::<Value>(&trimmed[start..=end]) {
                return value;
            }
        }
    }
    json!({
        "raw_text": trimmed
    })
}

pub fn input_request_question(session: &Value) -> Option<String> {
    session
        .get("input_request")
        .and_then(|request| request.get("question"))
        .and_then(Value::as_str)
        .and_then(clean_input_question)
        .or_else(|| {
            session
                .get("ai_brief")
                .and_then(input_request_question_from_parsed)
        })
        .or_else(|| input_request_question_from_parsed(session))
}

fn input_request_question_from_parsed(value: &Value) -> Option<String> {
    let object = value.as_object()?;
    let needs_input = object
        .get("needs_input")
        .or_else(|| object.get("requires_input"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let has_brief = object
        .get("visual_brief")
        .or_else(|| object.get("description"))
        .and_then(Value::as_str)
        .map(str::trim)
        .is_some_and(|text| !text.is_empty());

    for key in ["question", "follow_up_question", "prompt"] {
        if let Some(question) = object.get(key).and_then(Value::as_str) {
            if needs_input || !has_brief {
                if let Some(cleaned) = clean_input_question(question) {
                    return Some(cleaned);
                }
            }
        }
    }

    if needs_input {
        return Some("请补充一个关键外观或动作要求，我再继续生成桌宠。".to_string());
    }

    object
        .get("raw_text")
        .and_then(Value::as_str)
        .filter(|text| looks_like_follow_up_question(text))
        .and_then(clean_input_question)
}

fn clean_input_question(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut cleaned = trimmed.chars().take(180).collect::<String>();
    if cleaned.len() < trimmed.len() {
        cleaned.push('…');
    }
    Some(cleaned)
}

fn looks_like_follow_up_question(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.len() > 240 || trimmed.is_empty() {
        return false;
    }
    trimmed.ends_with('?')
        || trimmed.ends_with('？')
        || trimmed.contains("请补充")
        || trimmed.contains("需要补充")
        || trimmed.to_ascii_lowercase().contains("need more detail")
}

fn normalize_ai_brief(parsed: Value) -> (Value, Vec<String>) {
    let mut warnings = Vec::new();
    let raw_text = parsed
        .get("raw_text")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let mut object = match parsed {
        Value::Object(map) => map,
        other => {
            warnings.push(
                "Codex AI brief was not a JSON object; normalized from raw output.".to_string(),
            );
            let mut map = serde_json::Map::new();
            if !other.is_null() {
                map.insert("raw_value".to_string(), other);
            }
            map
        }
    };

    let name = object
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(16).collect::<String>())
        .unwrap_or_else(|| {
            warnings.push("AI brief missing non-empty name; using default pet name.".to_string());
            "自定义桌宠".to_string()
        });
    object.insert("name".to_string(), json!(name));

    let visual_brief = object
        .get("visual_brief")
        .or_else(|| object.get("description"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| raw_text.clone())
        .unwrap_or_else(|| {
            warnings.push(
                "AI brief missing visual_brief; using a generic desktop pet brief.".to_string(),
            );
            "透明 PNG 桌宠角色，轮廓清晰，适合桌面悬浮显示。".to_string()
        });
    object.insert("visual_brief".to_string(), json!(visual_brief));

    let palette = normalized_palette(object.get("palette"), &mut warnings);
    object.insert("palette".to_string(), Value::Array(palette));

    let states = normalized_states(object.get("states"), &mut warnings);
    object.insert("states".to_string(), Value::Array(states));

    let render_notes = object
        .get("render_notes")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            warnings
                .push("AI brief missing render_notes; using transparent PNG defaults.".to_string());
            "透明背景 PNG 序列，角色主体居中，边缘留少量安全空白。".to_string()
        });
    object.insert("render_notes".to_string(), json!(render_notes));
    object.insert("normalized_at".to_string(), json!(now_rfc3339()));

    (Value::Object(object), warnings)
}

fn normalized_palette(value: Option<&Value>, warnings: &mut Vec<String>) -> Vec<Value> {
    let mut palette = value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| match item {
                    Value::String(text) if !text.trim().is_empty() => {
                        Some(Value::String(text.trim().to_string()))
                    }
                    Value::Object(_) => Some(item.clone()),
                    _ => None,
                })
                .take(6)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    if palette.len() < 3 {
        warnings.push("AI brief palette had fewer than 3 usable entries; default palette notes were appended.".to_string());
        for fallback in [
            "主色与角色设定一致",
            "辅助色保持透明桌宠清晰度",
            "状态强调色用于动作反馈",
        ] {
            if palette.len() >= 3 {
                break;
            }
            palette.push(Value::String(fallback.to_string()));
        }
    }
    palette
}

fn normalized_states(value: Option<&Value>, warnings: &mut Vec<String>) -> Vec<Value> {
    REQUIRED_STATES
        .iter()
        .map(|state| {
            let motion = motion_from_ai_state(value, *state).unwrap_or_else(|| {
                warnings.push(format!(
                    "AI brief missing motion for state {}; default motion was appended.",
                    state.as_str()
                ));
                default_motion_for_state(*state).to_string()
            });
            json!({
                "name": state.as_str(),
                "motion": motion
            })
        })
        .collect()
}

fn motion_from_ai_state(value: Option<&Value>, state: PetStateName) -> Option<String> {
    let states = value?.as_array()?;
    states.iter().find_map(|item| {
        let name = item
            .get("name")
            .or_else(|| item.get("state"))
            .and_then(Value::as_str)?;
        if name != state.as_str() {
            return None;
        }
        item.get("motion")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|motion| !motion.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn default_motion_for_state(state: PetStateName) -> &'static str {
    match state {
        PetStateName::Idle => "轻微呼吸与衣摆摆动",
        PetStateName::Start => "抬头进入工作状态",
        PetStateName::Tool => "手部和装饰光效显示工具执行节奏",
        PetStateName::Waiting => "停顿并抬头提示用户确认",
        PetStateName::Review => "侧身展示待查看状态",
        PetStateName::Done => "轻微点头并显示完成光效",
        PetStateName::Failed => "低头并显示失败提示色带",
    }
}

fn default_codex_app_server_command() -> Option<String> {
    let codex = command_path("codex")?;
    Some(format!(
        "{} app-server --stdio",
        shell_quote(&codex.display().to_string())
    ))
}

fn petcore_cli_path() -> PathBuf {
    if let Some(path) = std::env::var_os("APC_PETCORE_CLI").map(PathBuf::from) {
        return path;
    }
    if let Some(path) = std::env::var_os("APC_CONNECTOR_CLI_PATH").map(PathBuf::from) {
        return path;
    }
    std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join("petcore-cli")))
        .unwrap_or_else(|| PathBuf::from("petcore-cli"))
}

fn petcore_cli_command() -> String {
    shell_quote(&petcore_cli_path().display().to_string())
}

fn app_server_child_path_environment(cli_path: &Path) -> String {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(parent) = cli_path.parent() {
        dirs.push(parent.to_path_buf());
    }
    dirs.extend(command_search_dirs());

    let mut seen = std::collections::BTreeSet::new();
    dirs.into_iter()
        .filter_map(|path| {
            let value = path.display().to_string();
            if value.is_empty() || !seen.insert(value.clone()) {
                None
            } else {
                Some(value)
            }
        })
        .collect::<Vec<_>>()
        .join(":")
}

fn command_path(name: &str) -> Option<PathBuf> {
    command_search_dirs()
        .into_iter()
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

fn command_search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();

    let mut add = |path: PathBuf| {
        if !dirs.iter().any(|existing| existing == &path) {
            dirs.push(path);
        }
    };

    add(PathBuf::from("/opt/homebrew/bin"));
    add(PathBuf::from("/opt/homebrew/sbin"));
    add(PathBuf::from("/usr/local/bin"));
    add(PathBuf::from("/usr/local/sbin"));
    add(PathBuf::from("/usr/bin"));
    add(PathBuf::from("/bin"));
    add(PathBuf::from("/usr/sbin"));
    add(PathBuf::from("/sbin"));

    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        add(home.join(".local").join("bin"));
        add(home.join(".cargo").join("bin"));
        add(home.join(".bun").join("bin"));
        add(home.join("bin"));
    }
    dirs
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
