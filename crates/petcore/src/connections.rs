use crate::app_server;
use crate::paths::AppPaths;
use crate::process_runner::{run_bounded, ProcessResult, ProcessSpec};
use crate::{now_rfc3339, PetCoreError, Result};
use petcore_types::{
    AgentConnectionStatus, AgentSource, CheckStatus, ConnectionCheckItem, ConnectionCheckMode,
};
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

const PET_STUDIO_SKILL_MD: &str = include_str!("../../../skills/agent-pet-studio/SKILL.md");
const CODEX_PLUGIN_JSON: &str = include_str!("../../../plugins/codex/.codex-plugin/plugin.json");
const CODEX_HOOKS_TEMPLATE: &str = include_str!("../../../plugins/codex/hooks/hooks.json.tpl");
const CLAUDE_SETTINGS_TEMPLATE: &str =
    include_str!("../../../plugins/claude-code/settings.fragment.json.tpl");
const PI_EXTENSION_TEMPLATE: &str = include_str!("../../../plugins/pi/agent-pet-companion.ts.tpl");
const OPENCODE_PLUGIN_TEMPLATE: &str =
    include_str!("../../../plugins/opencode/agent-pet-companion.js.tpl");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CodexHookTrustState {
    Trusted,
    Untrusted,
    InstalledEnabledAuthOnInstall,
    Unknown,
}

pub fn check_all(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    check_all_with_runtime_smoke(paths, true)
}

pub fn check_all_light(paths: &AppPaths) -> Vec<AgentConnectionStatus> {
    check_all_with_runtime_smoke(paths, false)
}

fn check_all_with_runtime_smoke(
    paths: &AppPaths,
    run_runtime_smoke: bool,
) -> Vec<AgentConnectionStatus> {
    [
        AgentSource::Codex,
        AgentSource::ClaudeCode,
        AgentSource::Pi,
        AgentSource::Opencode,
    ]
    .into_iter()
    .map(|source| check_source_with_runtime_smoke(paths, source, run_runtime_smoke))
    .collect()
}

pub fn check_source(paths: &AppPaths, source: AgentSource) -> AgentConnectionStatus {
    check_source_with_runtime_smoke(paths, source, true)
}

fn check_source_with_runtime_smoke(
    paths: &AppPaths,
    source: AgentSource,
    run_runtime_smoke: bool,
) -> AgentConnectionStatus {
    let cli_name = cli_name(source);
    let install_root = install_root(paths, source);
    let connector_cli = connector_cli_path();
    let cli_status = if command_exists(cli_name) {
        CheckStatus::Ok
    } else {
        CheckStatus::Missing
    };
    let connector_cli_status = if connector_cli.is_file() {
        CheckStatus::Ok
    } else {
        CheckStatus::NeedsFix
    };
    let mut items = vec![
        ConnectionCheckItem {
            name: cli_label(source).to_string(),
            status: cli_status,
            detail: if cli_status == CheckStatus::Ok {
                "命令可用".to_string()
            } else {
                format!("未在 PATH 中检测到 {cli_name}")
            },
        },
        ConnectionCheckItem {
            name: "本地事件 CLI".to_string(),
            status: connector_cli_status,
            detail: if connector_cli_status == CheckStatus::Ok {
                connector_cli.display().to_string()
            } else {
                format!("未检测到 {}", connector_cli.display())
            },
        },
    ];

    match source {
        AgentSource::Codex => {
            items.push(check_file(
                &install_root.join(".codex-plugin/plugin.json"),
                "插件源",
            ));
            items.push(check_codex_hooks(&install_root.join("hooks/hooks.json")));
            items.push(check_file_contains(
                &install_root.join("skills/agent-pet-studio/SKILL.md"),
                "Pet Studio Skill",
                &[
                    "Generate Agent Pet Companion .petpack assets",
                    "APC_PETCORE_CLI",
                    "Do not read agent auth",
                ],
            ));
            items.push(check_codex_marketplace_entry());
            items.push(if run_runtime_smoke {
                check_codex_plugin_installed()
            } else {
                check_codex_plugin_installed_light(&install_root)
            });
            items.push(if run_runtime_smoke {
                check_codex_hook_trust()
            } else {
                check_codex_hook_trust_light(&install_root)
            });
            items.push(check_event_channel(paths, &connector_cli));
            items.push(if run_runtime_smoke {
                check_codex_app_server()
            } else {
                check_codex_app_server_light()
            });
        }
        AgentSource::ClaudeCode => {
            items.push(check_file(
                &install_root.join("settings.fragment.json"),
                "Hooks",
            ));
            items.push(check_file(
                &install_root.join("agent-pet-companion-hook.sh"),
                "事件通道",
            ));
            items.push(check_claude_settings(&connector_cli));
            items.push(check_event_channel(paths, &connector_cli));
        }
        AgentSource::Pi => {
            items.push(check_file_contains(
                &install_root.join("agent-pet-companion.ts"),
                "Extension",
                &[
                    "pi-extension-34582ef3",
                    "pi.on(\"agent_settled\"",
                    "event?.isError === true",
                    "--event-type",
                    "auto",
                ],
            ));
            items.push(check_pi_rpc(run_runtime_smoke));
            items.push(check_pi_waiting_capability());
            items.push(check_event_channel(paths, &connector_cli));
            if run_runtime_smoke {
                items.push(check_pi_extension_runtime(
                    paths,
                    &install_root,
                    &connector_cli,
                ));
            }
        }
        AgentSource::Opencode => {
            items.push(check_file_contains(
                &install_root.join("agent-pet-companion.js"),
                "Plugin",
                &[
                    "export const AgentPetCompanion",
                    "event: async",
                    "opencode-v1.17.18",
                    "\"tool.execute.before\"",
                    "event?.properties",
                    "output?.args",
                    "--event-type",
                    "auto",
                ],
            ));
            items.push(check_opencode_server(run_runtime_smoke));
            items.push(check_event_channel(paths, &connector_cli));
            if run_runtime_smoke {
                items.push(check_opencode_plugin_runtime(
                    paths,
                    &install_root,
                    &connector_cli,
                ));
            }
        }
    };
    if run_runtime_smoke {
        items.push(check_event_roundtrip(paths, &connector_cli, source));
    }

    let mut install_paths = vec![install_root.display().to_string()];
    match source {
        AgentSource::Codex => {
            install_paths.push(codex_marketplace_path().display().to_string());
        }
        AgentSource::ClaudeCode => {
            install_paths.push(claude_settings_path().display().to_string());
        }
        AgentSource::Pi | AgentSource::Opencode => {}
    }

    AgentConnectionStatus {
        source,
        items,
        install_paths,
        check_mode: if run_runtime_smoke {
            ConnectionCheckMode::Runtime
        } else {
            ConnectionCheckMode::Light
        },
        checked_at: now_rfc3339(),
    }
}

pub fn repair_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    fs::create_dir_all(&root)?;
    match source {
        AgentSource::Codex => repair_codex(&root)?,
        AgentSource::ClaudeCode => repair_claude(&root)?,
        AgentSource::Pi => repair_pi(&root)?,
        AgentSource::Opencode => repair_opencode(&root)?,
    }
    Ok(check_source(paths, source))
}

pub fn uninstall_source(paths: &AppPaths, source: AgentSource) -> Result<AgentConnectionStatus> {
    let root = install_root(paths, source);
    match source {
        AgentSource::Pi => {
            remove_if_exists(&root.join("agent-pet-companion.ts"))?;
            remove_if_exists(&root.join("rpc-check.json"))?;
        }
        AgentSource::Opencode => {
            remove_if_exists(&root.join("agent-pet-companion.js"))?;
            remove_if_exists(&root.join("server-check.json"))?;
        }
        AgentSource::Codex | AgentSource::ClaudeCode => {
            if root.exists() {
                fs::remove_dir_all(&root)?;
            }
            if source == AgentSource::Codex {
                remove_codex_marketplace_entry()?;
                uninstall_codex_plugin_if_possible();
            } else {
                remove_claude_settings_hooks(&root, &connector_cli_path())?;
            }
        }
    }
    Ok(check_source(paths, source))
}

fn repair_codex(root: &Path) -> Result<()> {
    fs::create_dir_all(root.join(".codex-plugin"))?;
    fs::create_dir_all(root.join("hooks"))?;
    fs::create_dir_all(root.join("skills/agent-pet-studio"))?;
    let cli = shell_quote(&connector_cli_path().display().to_string());
    let plugin: Value = serde_json::from_str(CODEX_PLUGIN_JSON)?;
    let hooks = render_json_template(CODEX_HOOKS_TEMPLATE, "__APC_CLI__", &cli)?;
    fs::write(
        root.join(".codex-plugin/plugin.json"),
        serde_json::to_vec_pretty(&plugin)?,
    )?;
    fs::write(
        root.join("hooks/hooks.json"),
        serde_json::to_vec_pretty(&hooks)?,
    )?;
    fs::write(
        root.join("skills/agent-pet-studio/SKILL.md"),
        PET_STUDIO_SKILL_MD,
    )?;
    ensure_codex_marketplace_entry()?;
    install_codex_plugin_if_possible(root)?;
    Ok(())
}

fn repair_claude(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    let cli_path = connector_cli_path();
    let cli = shell_quote(&cli_path.display().to_string());
    let fragment = render_json_template(CLAUDE_SETTINGS_TEMPLATE, "__APC_CLI__", &cli)?;
    fs::write(
        root.join("settings.fragment.json"),
        serde_json::to_vec_pretty(&fragment)?,
    )?;
    let hook_path = root.join("agent-pet-companion-hook.sh");
    fs::write(
        &hook_path,
        format!(
            "#!/usr/bin/env bash\nset -euo pipefail\nEVENT_TYPE=\"${{APC_EVENT_TYPE:-tool}}\"\n{cli} agent hook --source claude_code --event-type \"$EVENT_TYPE\" >/dev/null 2>&1\n"
        ),
    )?;
    fs::set_permissions(&hook_path, fs::Permissions::from_mode(0o755))?;
    install_claude_settings_fragment(&fragment, root, &cli_path)?;
    Ok(())
}

fn repair_pi(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    let cli = connector_cli_path().display().to_string();
    let cli_json = serde_json::to_string(&cli)?;
    let script = PI_EXTENSION_TEMPLATE.replace("__APC_CLI_JSON__", &cli_json);
    fs::write(root.join("agent-pet-companion.ts"), script)?;
    Ok(())
}

fn repair_opencode(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    let cli = connector_cli_path().display().to_string();
    let cli_json = serde_json::to_string(&cli)?;
    let script = OPENCODE_PLUGIN_TEMPLATE.replace("__APC_CLI_JSON__", &cli_json);
    fs::write(root.join("agent-pet-companion.js"), script)?;
    Ok(())
}

fn check_file(path: &Path, label: &str) -> ConnectionCheckItem {
    ConnectionCheckItem {
        name: label.to_string(),
        status: if path.exists() {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if path.exists() {
            "已安装".to_string()
        } else {
            format!("待写入 {}", path.display())
        },
    }
}

fn check_codex_hooks(path: &Path) -> ConnectionCheckItem {
    const REQUIRED: &[&str] = &[
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
    ];
    const OFFICIAL: &[&str] = &[
        "SessionStart",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PreCompact",
        "PostCompact",
        "UserPromptSubmit",
        "SubagentStart",
        "SubagentStop",
        "Stop",
    ];
    let configured = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .and_then(|value| value.get("hooks").and_then(Value::as_object).cloned())
        .is_some_and(|hooks| {
            REQUIRED.iter().all(|event| {
                hooks
                    .get(*event)
                    .is_some_and(|value| value_contains_command_marker(value, "--source codex"))
            }) && hooks.keys().all(|event| OFFICIAL.contains(&event.as_str()))
                && !hooks
                    .values()
                    .any(|value| value_contains_command_marker(value, "--event-type review"))
        });
    ConnectionCheckItem {
        name: "Hook".to_string(),
        status: if configured {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if configured {
            "configured: 仅安装当前官方 Codex hook 事件；review/failed 不由 hooks 宣称".to_string()
        } else {
            format!("待写入或升级 {}", path.display())
        },
    }
}

fn render_json_template(template: &str, placeholder: &str, replacement: &str) -> Result<Value> {
    let mut value: Value = serde_json::from_str(template)?;
    replace_json_string(&mut value, placeholder, replacement);
    Ok(value)
}

fn replace_json_string(value: &mut Value, placeholder: &str, replacement: &str) {
    match value {
        Value::String(text) => *text = text.replace(placeholder, replacement),
        Value::Array(values) => {
            for value in values {
                replace_json_string(value, placeholder, replacement);
            }
        }
        Value::Object(map) => {
            for value in map.values_mut() {
                replace_json_string(value, placeholder, replacement);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn value_contains_command_marker(value: &Value, marker: &str) -> bool {
    match value {
        Value::Object(map) => {
            map.get("command")
                .and_then(Value::as_str)
                .is_some_and(|command| command.contains(marker))
                || map
                    .values()
                    .any(|value| value_contains_command_marker(value, marker))
        }
        Value::Array(values) => values
            .iter()
            .any(|value| value_contains_command_marker(value, marker)),
        _ => false,
    }
}

fn check_file_contains(path: &Path, label: &str, required: &[&str]) -> ConnectionCheckItem {
    let content = fs::read_to_string(path).unwrap_or_default();
    let installed = path.exists() && required.iter().all(|needle| content.contains(needle));
    ConnectionCheckItem {
        name: label.to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if installed {
            "已安装".to_string()
        } else if path.exists() {
            format!("已安装旧版本，待更新 {}", path.display())
        } else {
            format!("待写入 {}", path.display())
        },
    }
}

fn check_pi_rpc(run_runtime_smoke: bool) -> ConnectionCheckItem {
    let mode = if run_runtime_smoke {
        "runtime"
    } else {
        "configured"
    };
    ConnectionCheckItem {
        name: "RPC".to_string(),
        status: CheckStatus::Ok,
        detail: format!(
            "unsupported ({mode}): V1 仅观察现有 Pi Extension 会话；尚未实现 strict LF JSONL RPC client，未宣称 RPC 健康"
        ),
    }
}

fn check_pi_waiting_capability() -> ConnectionCheckItem {
    ConnectionCheckItem {
        name: "Waiting 状态".to_string(),
        status: CheckStatus::Ok,
        detail: "unsupported: Pi waiting 需要 tool_call + ctx.ui.confirm()/RPC UI 子协议桥；V1 Extension 不伪造确认事件"
            .to_string(),
    }
}

fn check_opencode_server(run_runtime_smoke: bool) -> ConnectionCheckItem {
    let opted_in = std::env::var("APC_VALIDATE_REAL_OPENCODE_SERVER")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false);
    if !run_runtime_smoke || !opted_in {
        return ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::Ok,
            detail: "configured: Server 非 V1 事件观察必需；未宣称健康。设置 APC_VALIDATE_REAL_OPENCODE_SERVER=1 后执行 /global/health 真实探测"
                .to_string(),
        };
    }

    probe_opencode_server()
}

pub fn probe_opencode_server() -> ConnectionCheckItem {
    let Some(opencode) = command_path("opencode") else {
        return ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::Missing,
            detail: "未在 PATH 中检测到 opencode".to_string(),
        };
    };

    let port = 42_000 + (std::process::id() % 1_000);
    let script = r#"set -eu
"$OPENCODE_BIN" serve --hostname 127.0.0.1 --port "$OPENCODE_PORT" >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" >/dev/null 2>&1 || true; wait "$server_pid" >/dev/null 2>&1 || true' EXIT INT TERM
i=0
while [ "$i" -lt 40 ]; do
  if body=$(curl --silent --show-error --fail --max-time 1 "http://127.0.0.1:$OPENCODE_PORT/global/health" 2>/dev/null); then
    printf '%s' "$body"
    exit 0
  fi
  i=$((i + 1))
  sleep 0.1
done
exit 1
"#;
    let output = run_bounded(
        ProcessSpec::connector("/bin/sh", ["-c", script])
            .with_env("OPENCODE_BIN", opencode)
            .with_env("OPENCODE_PORT", port.to_string()),
    );
    match output {
        Ok(output) if output.status.success() && !output.timed_out => {
            let healthy = serde_json::from_slice::<Value>(&output.stdout)
                .ok()
                .and_then(|value| value.get("healthy").and_then(Value::as_bool))
                == Some(true);
            ConnectionCheckItem {
                name: "OpenCode Server".to_string(),
                status: if healthy {
                    CheckStatus::Ok
                } else {
                    CheckStatus::NeedsFix
                },
                detail: if healthy {
                    "runtime_verified: bounded opencode serve 返回有效 /global/health JSON"
                        .to_string()
                } else {
                    "OpenCode /global/health 响应不是 {healthy:true} JSON".to_string()
                },
            }
        }
        Ok(output) => ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::NeedsFix,
            detail: if output.timed_out {
                "OpenCode /global/health 真实探测在 5 秒后超时，进程组已终止".to_string()
            } else {
                format!(
                    "OpenCode /global/health 探测失败（exit={:?}）",
                    output.status.code()
                )
            },
        },
        Err(error) => ConnectionCheckItem {
            name: "OpenCode Server".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("OpenCode CLI 无法执行：{error}"),
        },
    }
}

fn check_pi_extension_runtime(
    paths: &AppPaths,
    install_root: &Path,
    connector_cli: &Path,
) -> ConnectionCheckItem {
    let label = "Extension 运行时";
    if !connector_runtime_smoke_should_run() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::Ok,
            detail: "检测到外部事件 CLI 覆盖，跳过内置运行时加载自检".to_string(),
        };
    }

    let Some(node) = command_path("node") else {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: "未检测到 node，无法加载 Pi extension 做运行时自检".to_string(),
        };
    };

    let extension = install_root.join("agent-pet-companion.ts");
    if !extension.is_file() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("Extension 缺失 {}", extension.display()),
        };
    }

    let smoke_module = install_root.join(format!(
        ".agent-pet-companion-runtime-{}.mjs",
        uuid::Uuid::now_v7().simple()
    ));
    if let Err(error) = fs::copy(&extension, &smoke_module) {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("无法准备 Extension 运行时自检模块：{error}"),
        };
    }

    let session_id = format!("evt_pi_runtime_{}", uuid::Uuid::now_v7().simple());
    let module_path = json_string(&smoke_module.display().to_string());
    let session_json = json_string(&session_id);
    let script = format!(
        r#"
import {{ pathToFileURL }} from 'node:url';
const mod = await import(pathToFileURL({module_path}).href);
const handlers = new Map();
mod.default({{ on: (name, callback) => handlers.set(name, callback) }});
for (const name of ['session_start', 'tool_call', 'tool_execution_end', 'agent_settled']) {{
  if (!handlers.has(name)) throw new Error(`Pi handler missing: ${{name}}`);
}}
await handlers.get('session_start')(
  {{ type: 'session_start', reason: 'startup' }},
  {{ sessionManager: {{ getSessionId: () => {session_json} }}, cwd: process.cwd() }}
);
await new Promise((resolve) => setTimeout(resolve, 700));
"#
    );
    let output = run_bounded(
        ProcessSpec::connector(
            node,
            vec![
                "--input-type=module".to_string(),
                "--eval".to_string(),
                script,
            ],
        )
        .with_env("APC_HOME", &paths.home),
    );
    let _ = fs::remove_file(&smoke_module);
    node_runtime_result(label, output, || {
        recent_events_contain(paths, connector_cli, "pi", "start", &session_id)
    })
}

fn check_opencode_plugin_runtime(
    paths: &AppPaths,
    install_root: &Path,
    connector_cli: &Path,
) -> ConnectionCheckItem {
    let label = "Plugin 运行时";
    if !connector_runtime_smoke_should_run() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::Ok,
            detail: "检测到外部事件 CLI 覆盖，跳过内置运行时加载自检".to_string(),
        };
    }

    let Some(node) = command_path("node") else {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: "未检测到 node，无法加载 OpenCode plugin 做运行时自检".to_string(),
        };
    };

    let plugin = install_root.join("agent-pet-companion.js");
    if !plugin.is_file() {
        return ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("Plugin 缺失 {}", plugin.display()),
        };
    }

    let session_id = format!("evt_opencode_runtime_{}", uuid::Uuid::now_v7().simple());
    let module_path = json_string(&plugin.display().to_string());
    let session_json = json_string(&session_id);
    let root_json = json_string(&install_root.display().to_string());
    let script = format!(
        r#"
import {{ pathToFileURL }} from 'node:url';
const mod = await import(pathToFileURL({module_path}).href);
const plugin = await mod.AgentPetCompanion({{
  project: 'agent-pet-companion',
  directory: {root_json},
  worktree: {root_json}
}});
for (const name of ['event', 'tool.execute.before', 'tool.execute.after']) {{
  if (!plugin[name]) throw new Error(`OpenCode handler missing: ${{name}}`);
}}
await plugin.event({{
  event: {{
    type: 'session.created',
    properties: {{ info: {{ id: {session_json} }} }}
  }}
}});
await new Promise((resolve) => setTimeout(resolve, 700));
"#
    );
    let output = run_bounded(
        ProcessSpec::connector(
            node,
            vec![
                "--input-type=module".to_string(),
                "--eval".to_string(),
                script,
            ],
        )
        .with_env("APC_HOME", &paths.home),
    );
    node_runtime_result(label, output, || {
        recent_events_contain(paths, connector_cli, "opencode", "start", &session_id)
    })
}

fn node_runtime_result(
    label: &str,
    output: Result<ProcessResult>,
    event_check: impl FnOnce() -> bool,
) -> ConnectionCheckItem {
    match output {
        Ok(output) if output.status.success() && !output.timed_out => {
            thread::sleep(Duration::from_millis(250));
            let event_seen = event_check();
            ConnectionCheckItem {
                name: label.to_string(),
                status: if event_seen {
                    CheckStatus::Ok
                } else {
                    CheckStatus::NeedsFix
                },
                detail: if event_seen {
                    "运行时模块已加载，并通过真实插件/Extension handler 回传诊断事件".to_string()
                } else {
                    "运行时模块已加载，但未观察到诊断事件入库".to_string()
                },
            }
        }
        Ok(output) => ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: if output.timed_out {
                "运行时模块自检在 5 秒后超时，进程组已终止".to_string()
            } else {
                format!("运行时模块加载失败（exit={:?}）", output.status.code())
            },
        },
        Err(error) => ConnectionCheckItem {
            name: label.to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("无法启动 node 运行时自检：{error}"),
        },
    }
}

fn recent_events_contain(
    paths: &AppPaths,
    connector_cli: &Path,
    source: &str,
    event_type: &str,
    needle: &str,
) -> bool {
    for _ in 0..8 {
        let output = run_bounded(
            ProcessSpec::connector(connector_cli, ["events", "recent", "--limit", "120"])
                .with_env("APC_HOME", &paths.home),
        );
        if let Ok(output) = output {
            if output.status.success() {
                if let Ok(events) = serde_json::from_slice::<Vec<Value>>(&output.stdout) {
                    if events.iter().any(|event| {
                        event.get("source").and_then(Value::as_str) == Some(source)
                            && event.get("event_type").and_then(Value::as_str) == Some(event_type)
                            && serde_json::to_string(event)
                                .map(|text| text.contains(needle))
                                .unwrap_or(false)
                    }) {
                        return true;
                    }
                }
            }
        }
        thread::sleep(Duration::from_millis(150));
    }
    false
}

fn connector_runtime_smoke_should_run() -> bool {
    std::env::var_os("APC_CONNECTOR_CLI_PATH").is_none()
        || std::env::var("APC_CONNECTOR_RUNTIME_SMOKE")
            .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
            .unwrap_or(false)
}

fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
}

fn check_codex_marketplace_entry() -> ConnectionCheckItem {
    let path = codex_marketplace_path();
    let expected_path = codex_marketplace_plugin_source_path();
    let entry_path = codex_marketplace_entry_path(&path);
    let installed = entry_path.as_deref() == Some(expected_path.as_str());
    let detail = if installed {
        format!("已注册 {}", path.display())
    } else if let Some(entry_path) = entry_path {
        format!(
            "路径已变化，待更新 {}（当前：{}，期望：{}）",
            path.display(),
            entry_path,
            expected_path
        )
    } else {
        format!("待注册 {}", path.display())
    };

    ConnectionCheckItem {
        name: "Codex marketplace".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail,
    }
}

fn codex_marketplace_entry_path(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .and_then(|value| value.get("plugins").and_then(Value::as_array).cloned())
        .and_then(|plugins| {
            plugins
                .iter()
                .find(|plugin| {
                    plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion")
                })
                .and_then(|plugin| {
                    plugin
                        .get("source")
                        .and_then(|source| source.get("path"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                })
        })
}

fn check_codex_hook_trust() -> ConnectionCheckItem {
    let Some(codex) = command_path("codex") else {
        return ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Missing,
            detail: "未检测到 codex 命令".to_string(),
        };
    };

    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "测试环境无法确认用户是否已信任 Codex plugin hooks".to_string(),
        };
    }

    let trust = run_bounded(ProcessSpec::connector(codex, ["plugin", "list", "--json"]))
        .ok()
        .filter(|output| !output.timed_out && output.status.success())
        .and_then(|output| codex_plugin_json_hook_trust_state(&output.stdout));

    match trust {
        Some(CodexHookTrustState::Trusted) => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Ok,
            detail: "Codex 已信任 agent-pet-companion hooks".to_string(),
        },
        Some(CodexHookTrustState::InstalledEnabledAuthOnInstall) => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::Ok,
            detail: "Codex CLI 未暴露独立 Hook trust 字段；插件已安装启用，授权策略为 ON_INSTALL"
                .to_string(),
        },
        Some(CodexHookTrustState::Untrusted) => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "请在 Codex 中 review 并信任 agent-pet-companion hooks".to_string(),
        },
        Some(CodexHookTrustState::Unknown) | None => ConnectionCheckItem {
            name: "Codex Hook Trust".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "Codex 未暴露 Hook trust 状态，请在 Codex 中确认并信任插件 hooks".to_string(),
        },
    }
}

fn check_codex_hook_trust_light(install_root: &Path) -> ConnectionCheckItem {
    let hooks_ready = install_root.join("hooks/hooks.json").is_file();
    ConnectionCheckItem {
        name: "Codex Hook Trust".to_string(),
        status: CheckStatus::NeedsFix,
        detail: if hooks_ready {
            "本地 hooks 已写入；点击检查并在 Codex 中信任后才会运行".to_string()
        } else {
            "待写入 hooks 并在 Codex 中信任".to_string()
        },
    }
}

fn check_codex_plugin_installed() -> ConnectionCheckItem {
    let Some(codex) = command_path("codex") else {
        return ConnectionCheckItem {
            name: "Codex 插件安装".to_string(),
            status: CheckStatus::Missing,
            detail: "未检测到 codex 命令".to_string(),
        };
    };

    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return ConnectionCheckItem {
            name: "Codex 插件安装".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "测试环境跳过 codex plugin add".to_string(),
        };
    }

    let installed = run_bounded(ProcessSpec::connector(&codex, ["plugin", "list", "--json"]))
        .ok()
        .filter(|output| !output.timed_out && output.status.success())
        .and_then(|output| codex_plugin_json_reports_installed(&output.stdout))
        .unwrap_or_else(|| {
            run_bounded(ProcessSpec::connector(codex, ["plugin", "list"]))
                .ok()
                .filter(|output| !output.timed_out && output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .map(|stdout| codex_plugin_text_reports_installed(&stdout))
                .unwrap_or(false)
        });

    ConnectionCheckItem {
        name: "Codex 插件安装".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if installed {
            "Codex 已安装并启用插件".to_string()
        } else {
            "待执行 codex plugin add agent-pet-companion@personal".to_string()
        },
    }
}

fn check_codex_plugin_installed_light(install_root: &Path) -> ConnectionCheckItem {
    let plugin_source_ready = install_root.join(".codex-plugin/plugin.json").is_file()
        && install_root.join("hooks/hooks.json").is_file();
    let marketplace_ready = codex_marketplace_entry_path(&codex_marketplace_path()).as_deref()
        == Some(codex_marketplace_plugin_source_path().as_str());

    let ready = plugin_source_ready && marketplace_ready;
    ConnectionCheckItem {
        name: "Codex 插件安装".to_string(),
        status: if ready {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if ready {
            "本地插件源已注册，点击检查确认 Codex 已启用插件".to_string()
        } else {
            "待注册本地插件源或执行一键修复".to_string()
        },
    }
}

fn check_codex_app_server() -> ConnectionCheckItem {
    let probe = app_server::probe_codex_app_server();
    let initialized = probe
        .get("initialized")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mode = probe
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("missing");

    let status = if initialized {
        CheckStatus::Ok
    } else if mode == "missing" {
        CheckStatus::Missing
    } else {
        CheckStatus::NeedsFix
    };
    let detail = if initialized {
        let source = probe
            .get("command_source")
            .and_then(Value::as_str)
            .unwrap_or("configured");
        format!("stdio 初始化成功（{source}）")
    } else {
        probe
            .get("error")
            .or_else(|| probe.get("detail"))
            .and_then(Value::as_str)
            .unwrap_or("Codex App Server 不可用")
            .to_string()
    };

    ConnectionCheckItem {
        name: "Codex App Server".to_string(),
        status,
        detail,
    }
}

fn check_codex_app_server_light() -> ConnectionCheckItem {
    let check = app_server::codex_app_server_command_check();
    let available = check
        .get("available")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mode = check
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("missing");

    let status = if available {
        CheckStatus::Ok
    } else if mode == "missing" {
        CheckStatus::Missing
    } else {
        CheckStatus::NeedsFix
    };
    let detail = if available {
        let source = check
            .get("command_source")
            .and_then(Value::as_str)
            .unwrap_or("configured");
        format!("命令已定位（{source}），点击检查验证 stdio 初始化")
    } else {
        check
            .get("detail")
            .and_then(Value::as_str)
            .unwrap_or("Codex App Server 不可用")
            .to_string()
    };

    ConnectionCheckItem {
        name: "Codex App Server".to_string(),
        status,
        detail,
    }
}

fn codex_plugin_json_reports_installed(stdout: &[u8]) -> Option<bool> {
    let value: Value = serde_json::from_slice(stdout).ok()?;
    let installed = value.get("installed")?.as_array()?;
    Some(installed.iter().any(|plugin| {
        let id_matches =
            plugin.get("pluginId").and_then(Value::as_str) == Some("agent-pet-companion@personal");
        let name_matches = plugin.get("name").and_then(Value::as_str)
            == Some("agent-pet-companion")
            && plugin.get("marketplaceName").and_then(Value::as_str) == Some("personal");
        let installed = plugin
            .get("installed")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let enabled = plugin
            .get("enabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        (id_matches || name_matches) && installed && enabled
    }))
}

fn codex_plugin_json_hook_trust_state(stdout: &[u8]) -> Option<CodexHookTrustState> {
    let value: Value = serde_json::from_slice(stdout).ok()?;
    let installed = value.get("installed")?.as_array()?;
    let plugin = installed
        .iter()
        .find(|plugin| codex_plugin_entry_is_agent_pet(plugin))?;
    if let Some(trusted) = codex_plugin_trust_value(plugin) {
        return Some(if trusted {
            CodexHookTrustState::Trusted
        } else {
            CodexHookTrustState::Untrusted
        });
    }

    let installed = plugin
        .get("installed")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let enabled = plugin
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let auth_on_install = plugin.get("authPolicy").and_then(Value::as_str) == Some("ON_INSTALL");

    Some(if installed && enabled && auth_on_install {
        CodexHookTrustState::InstalledEnabledAuthOnInstall
    } else {
        CodexHookTrustState::Unknown
    })
}

fn codex_plugin_entry_is_agent_pet(plugin: &Value) -> bool {
    let id_matches =
        plugin.get("pluginId").and_then(Value::as_str) == Some("agent-pet-companion@personal");
    let name_matches = plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion")
        && plugin.get("marketplaceName").and_then(Value::as_str) == Some("personal");
    id_matches || name_matches
}

fn codex_plugin_trust_value(plugin: &Value) -> Option<bool> {
    const TRUST_KEYS: &[&str] = &[
        "trusted",
        "trust",
        "approved",
        "approvedByUser",
        "userApproved",
        "hooksTrusted",
        "hooks_trusted",
        "hooksApproved",
        "hooks_approved",
    ];
    find_bool_by_keys(plugin, TRUST_KEYS)
}

fn find_bool_by_keys(value: &Value, keys: &[&str]) -> Option<bool> {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if keys.contains(&key.as_str()) {
                    if let Some(value) = child.as_bool() {
                        return Some(value);
                    }
                }
            }
            map.values()
                .find_map(|child| find_bool_by_keys(child, keys))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|child| find_bool_by_keys(child, keys)),
        _ => None,
    }
}

fn codex_plugin_text_reports_installed(stdout: &str) -> bool {
    stdout.lines().any(|line| {
        line.contains("agent-pet-companion@personal")
            && line.contains("installed")
            && line.contains("enabled")
    })
}

fn check_claude_settings(connector_cli: &Path) -> ConnectionCheckItem {
    let settings_path = claude_settings_path();
    let required = [
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "StopFailure",
    ];
    let installed = fs::read_to_string(&settings_path)
        .ok()
        .and_then(|content| serde_json::from_str::<Value>(&content).ok())
        .and_then(|settings| settings.get("hooks").and_then(Value::as_object).cloned())
        .is_some_and(|hooks| {
            required.iter().all(|event| {
                hooks
                    .get(*event)
                    .is_some_and(|value| claude_event_has_bounded_async_hook(value, connector_cli))
            })
        });
    ConnectionCheckItem {
        name: "Claude settings.json".to_string(),
        status: if installed {
            CheckStatus::Ok
        } else {
            CheckStatus::NeedsFix
        },
        detail: if installed {
            format!(
                "configured: 已结构化合并 quiet/async/5s hooks 到 {}（真实触发需运行时验证）",
                settings_path.display()
            )
        } else {
            format!(
                "待合并或升级 {}（事件 CLI：{}）",
                settings_path.display(),
                connector_cli.display()
            )
        },
    }
}

fn claude_event_has_bounded_async_hook(value: &Value, connector_cli: &Path) -> bool {
    value.as_array().is_some_and(|groups| {
        groups.iter().any(|group| {
            group
                .get("hooks")
                .and_then(Value::as_array)
                .is_some_and(|hooks| {
                    hooks.iter().any(|hook| {
                        is_agent_pet_claude_hook(hook, connector_cli, None)
                            && hook.get("async").and_then(Value::as_bool) == Some(true)
                            && hook
                                .get("timeout")
                                .and_then(Value::as_u64)
                                .is_some_and(|timeout| timeout <= 5)
                    })
                })
        })
    })
}

fn check_event_channel(paths: &AppPaths, connector_cli: &Path) -> ConnectionCheckItem {
    let cli_ready = connector_cli.is_file();
    let socket_ready =
        paths.socket_path.exists() && UnixStream::connect(&paths.socket_path).is_ok();
    let status = if cli_ready && socket_ready {
        CheckStatus::Ok
    } else {
        CheckStatus::NeedsFix
    };
    let detail = match (cli_ready, socket_ready) {
        (true, true) => format!(
            "事件 CLI 可用，socket 已连接 {}",
            paths.socket_path.display()
        ),
        (false, true) => format!("事件 CLI 缺失 {}", connector_cli.display()),
        (true, false) => format!("PetCore socket 未连接 {}", paths.socket_path.display()),
        (false, false) => format!("事件 CLI 和 socket 待修复：{}", connector_cli.display()),
    };

    ConnectionCheckItem {
        name: "事件回传".to_string(),
        status,
        detail,
    }
}

fn check_event_roundtrip(
    paths: &AppPaths,
    connector_cli: &Path,
    source: AgentSource,
) -> ConnectionCheckItem {
    if std::env::var_os("APC_CONNECTOR_CLI_PATH").is_some() {
        return ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::Ok,
            detail: "检测到外部覆盖的事件 CLI，跳过自动写入自检".to_string(),
        };
    }

    if !connector_cli.is_file() {
        return ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("事件 CLI 缺失 {}", connector_cli.display()),
        };
    }

    if !paths.socket_path.exists() || UnixStream::connect(&paths.socket_path).is_err() {
        return ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("PetCore socket 未连接 {}", paths.socket_path.display()),
        };
    }

    let source_arg = source_cli_arg(source);
    let event_id = format!("evt_connection_smoke_{source_arg}");
    let payload = json!({
        "diagnostic": true,
        "type": "connection_smoke",
        "source": source_arg,
        "created_by": "Agent Pet Companion connection check"
    })
    .to_string();
    let output = run_bounded(
        ProcessSpec::connector(
            connector_cli,
            vec![
                "agent".to_string(),
                "ingest".to_string(),
                "--id".to_string(),
                event_id.clone(),
                "--source".to_string(),
                source_arg.to_string(),
                "--event-type".to_string(),
                "review".to_string(),
                "--title".to_string(),
                "连接自检".to_string(),
                "--detail".to_string(),
                source.display_name().to_string(),
                "--payload-json".to_string(),
                payload,
            ],
        )
        .with_env("APC_HOME", &paths.home),
    );

    let output = match output {
        Ok(output) => output,
        Err(error) => {
            return ConnectionCheckItem {
                name: "事件自检".to_string(),
                status: CheckStatus::NeedsFix,
                detail: format!("事件 CLI 无法执行：{error}"),
            };
        }
    };

    if output.timed_out {
        return ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "事件 CLI 自检在 5 秒后超时，进程组已终止".to_string(),
        };
    }
    if !output.status.success() {
        return ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: format!("事件 CLI 返回失败（exit={:?}）", output.status.code()),
        };
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed = serde_json::from_str::<Value>(&stdout);
    let Ok(value) = parsed else {
        return ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "事件 CLI 返回了不可解析的 JSON".to_string(),
        };
    };

    let ok = value.get("ok").and_then(Value::as_bool) == Some(true);
    let inserted = value
        .get("inserted")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let event_matches = value
        .get("event")
        .and_then(|event| event.get("id"))
        .and_then(Value::as_str)
        == Some(event_id.as_str());
    let suppressed = value.get("triggered").and_then(Value::as_bool) == Some(false);

    if ok && event_matches && suppressed {
        ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::Ok,
            detail: if inserted {
                "诊断事件已通过 CLI、socket 与数据库，且未触发桌宠动作".to_string()
            } else {
                "诊断事件已通过 CLI 与 socket；重复自检未重复入库，且未触发桌宠动作".to_string()
            },
        }
    } else {
        ConnectionCheckItem {
            name: "事件自检".to_string(),
            status: CheckStatus::NeedsFix,
            detail: "诊断事件未完成端到端回传".to_string(),
        }
    }
}

fn source_cli_arg(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "codex",
        AgentSource::ClaudeCode => "claude_code",
        AgentSource::Pi => "pi",
        AgentSource::Opencode => "opencode",
    }
}

fn command_exists(name: &str) -> bool {
    command_path(name).is_some()
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

    let home = user_home();
    add(home.join(".local").join("bin"));
    add(home.join(".cargo").join("bin"));
    add(home.join(".bun").join("bin"));
    add(home.join("bin"));
    dirs
}

fn install_root(paths: &AppPaths, source: AgentSource) -> PathBuf {
    match source {
        AgentSource::Codex => codex_plugin_source_root(),
        AgentSource::ClaudeCode => paths.connectors_dir.join("claude-code"),
        AgentSource::Pi => agent_home().join(".pi").join("agent").join("extensions"),
        AgentSource::Opencode => opencode_plugins_dir(),
    }
}

fn cli_name(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "codex",
        AgentSource::ClaudeCode => "claude",
        AgentSource::Pi => "pi",
        AgentSource::Opencode => "opencode",
    }
}

fn cli_label(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => "Codex CLI",
        AgentSource::ClaudeCode => "Claude CLI",
        AgentSource::Pi => "Pi CLI",
        AgentSource::Opencode => "OpenCode CLI",
    }
}

fn connector_cli_path() -> PathBuf {
    if let Some(path) = std::env::var_os("APC_CONNECTOR_CLI_PATH").map(PathBuf::from) {
        return path;
    }
    std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join("petcore-cli")))
        .unwrap_or_else(|| PathBuf::from("petcore-cli"))
}

fn agent_home() -> PathBuf {
    std::env::var_os("APC_AGENT_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(user_home)
}

fn opencode_plugins_dir() -> PathBuf {
    if let Some(fake_home) = std::env::var_os("APC_AGENT_CONFIG_HOME").map(PathBuf::from) {
        return fake_home.join(".config").join("opencode").join("plugins");
    }
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| user_home().join(".config"))
        .join("opencode")
        .join("plugins")
}

fn codex_marketplace_path() -> PathBuf {
    agent_home()
        .join(".agents")
        .join("plugins")
        .join("marketplace.json")
}

fn codex_plugin_source_root() -> PathBuf {
    agent_home()
        .join(".agents")
        .join("plugins")
        .join("plugins")
        .join("agent-pet-companion")
}

fn codex_marketplace_plugin_source_path() -> String {
    let root = codex_plugin_source_root();
    let home = user_home();
    root.strip_prefix(&home)
        .ok()
        .map(|relative| format!("./{}", relative.display()))
        .unwrap_or_else(|| root.display().to_string())
}

fn ensure_codex_marketplace_entry() -> Result<()> {
    let path = codex_marketplace_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut marketplace =
        read_json_config_or_default(&path, default_codex_marketplace(), "Codex marketplace")?;
    let original = marketplace.clone();

    let Some(root) = marketplace.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Codex marketplace",
            "expected a JSON object",
        ));
    };
    root.insert("name".to_string(), json!("personal"));
    root.entry("interface".to_string())
        .or_insert_with(|| json!({ "displayName": "Personal" }));
    let plugins = root
        .entry("plugins".to_string())
        .or_insert_with(|| json!([]));
    let Some(plugins) = plugins.as_array_mut() else {
        return Err(config_shape_error(
            &path,
            "Codex marketplace",
            "expected `plugins` to be a JSON array",
        ));
    };
    let source_path = codex_marketplace_plugin_source_path();
    let entry = json!({
        "name": "agent-pet-companion",
        "source": {
            "source": "local",
            "path": source_path
        },
        "policy": {
            "installation": "AVAILABLE",
            "authentication": "ON_INSTALL"
        },
        "category": "Productivity"
    });

    if let Some(existing) = plugins
        .iter_mut()
        .find(|plugin| plugin.get("name").and_then(Value::as_str) == Some("agent-pet-companion"))
    {
        *existing = entry;
    } else {
        plugins.push(entry);
    }

    write_json_config_if_changed(&path, &original, &marketplace)?;
    Ok(())
}

fn remove_codex_marketplace_entry() -> Result<()> {
    let path = codex_marketplace_path();
    if !path.exists() {
        return Ok(());
    }
    let mut marketplace = read_json_config_or_default(&path, json!({}), "Codex marketplace")?;
    let original = marketplace.clone();
    let Some(root) = marketplace.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Codex marketplace",
            "expected a JSON object",
        ));
    };
    if let Some(plugins) = root.get_mut("plugins") {
        let Some(plugins) = plugins.as_array_mut() else {
            return Err(config_shape_error(
                &path,
                "Codex marketplace",
                "expected `plugins` to be a JSON array",
            ));
        };
        plugins.retain(|plugin| {
            plugin.get("name").and_then(Value::as_str) != Some("agent-pet-companion")
        });
    }
    write_json_config_if_changed(&path, &original, &marketplace)?;
    Ok(())
}

fn default_codex_marketplace() -> Value {
    json!({
        "name": "personal",
        "interface": {
            "displayName": "Personal"
        },
        "plugins": []
    })
}

fn read_json_config_or_default(path: &Path, default: Value, label: &str) -> Result<Value> {
    if !path.exists() {
        return Ok(default);
    }
    let content = fs::read_to_string(path)?;
    if content.trim().is_empty() {
        return Ok(default);
    }
    serde_json::from_str(&content).map_err(|error| {
        PetCoreError::Validation(format!(
            "{label} JSON 无效，已保留原文件：{}（{error}）",
            path.display()
        ))
    })
}

fn config_shape_error(path: &Path, label: &str, detail: impl Into<String>) -> PetCoreError {
    PetCoreError::Validation(format!(
        "{label} 结构不符合预期，已保留原文件：{}（{}）",
        path.display(),
        detail.into()
    ))
}

fn write_json_config_if_changed(path: &Path, original: &Value, updated: &Value) -> Result<()> {
    if original == updated {
        return Ok(());
    }
    let bytes = serde_json::to_vec_pretty(updated)?;
    if path.exists() {
        backup_json_config(path)?;
    }
    write_file_atomic(path, &bytes)
}

fn backup_json_config(path: &Path) -> Result<PathBuf> {
    let backup_path = json_config_backup_path(path);
    fs::copy(path, &backup_path)?;
    Ok(backup_path)
}

fn json_config_backup_path(path: &Path) -> PathBuf {
    path.with_extension("json.agent-pet-companion.bak")
}

fn write_file_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp_path = atomic_temp_path(path);
    let permissions = fs::metadata(path)
        .ok()
        .map(|metadata| metadata.permissions());
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        if let Some(permissions) = permissions {
            fs::set_permissions(&temp_path, permissions)?;
        }
        fs::rename(&temp_path, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

fn atomic_temp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("config");
    path.with_file_name(format!(
        ".{file_name}.agent-pet-companion.tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ))
}

fn install_codex_plugin_if_possible(root: &Path) -> Result<()> {
    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        fs::write(
            root.join("codex-install-result.json"),
            serde_json::to_vec_pretty(&json!({
                "status": "skipped",
                "reason": "APC_AGENT_CONFIG_HOME is set"
            }))?,
        )?;
        return Ok(());
    }

    let Some(codex) = command_path("codex") else {
        fs::write(
            root.join("codex-install-result.json"),
            serde_json::to_vec_pretty(&json!({
                "status": "skipped",
                "reason": "codex command not found"
            }))?,
        )?;
        return Ok(());
    };

    let output = run_bounded(ProcessSpec::connector(
        codex,
        ["plugin", "add", "agent-pet-companion@personal", "--json"],
    ));

    match output {
        Ok(output) => {
            fs::write(
                root.join("codex-install-result.json"),
                serde_json::to_vec_pretty(&json!({
                    "status": if output.status.success() && !output.timed_out { "ok" } else { "failed" },
                    "code": output.status.code(),
                    "timed_out": output.timed_out,
                    "stdout_truncated": output.stdout_truncated,
                    "stderr_truncated": output.stderr_truncated
                }))?,
            )?;
        }
        Err(error) => {
            fs::write(
                root.join("codex-install-result.json"),
                serde_json::to_vec_pretty(&json!({
                    "status": "failed",
                    "error": error.to_string()
                }))?,
            )?;
        }
    }
    Ok(())
}

fn uninstall_codex_plugin_if_possible() {
    if std::env::var_os("APC_AGENT_CONFIG_HOME").is_some() {
        return;
    }
    let Some(codex) = command_path("codex") else {
        return;
    };
    let _ = run_bounded(ProcessSpec::connector(
        codex,
        ["plugin", "remove", "agent-pet-companion@personal"],
    ));
}

fn remove_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn claude_settings_path() -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| agent_home().join(".claude"))
        .join("settings.json")
}

fn user_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(test)]
fn install_claude_settings(hook_entries: &[(&str, String)]) -> Result<()> {
    let path = claude_settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut settings = read_json_config_or_default(&path, json!({}), "Claude settings")?;
    let original = settings.clone();
    if !settings.is_object() {
        return Err(config_shape_error(
            &path,
            "Claude settings",
            "expected a JSON object",
        ));
    }

    for (event, command) in hook_entries {
        ensure_hook_command(&mut settings, &path, event, command)?;
    }

    write_json_config_if_changed(&path, &original, &settings)?;
    Ok(())
}

fn install_claude_settings_fragment(
    fragment: &Value,
    install_root: &Path,
    connector_cli: &Path,
) -> Result<()> {
    let path = claude_settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let fragment_hooks = fragment
        .get("hooks")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            PetCoreError::Validation(
                "Claude hook template must contain a `hooks` object".to_string(),
            )
        })?;

    let mut settings = read_json_config_or_default(&path, json!({}), "Claude settings")?;
    let original = settings.clone();
    let root = settings
        .as_object_mut()
        .ok_or_else(|| config_shape_error(&path, "Claude settings", "expected a JSON object"))?;
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().ok_or_else(|| {
        config_shape_error(
            &path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        )
    })?;

    for (event, template_groups) in fragment_hooks {
        let template_groups = template_groups.as_array().ok_or_else(|| {
            PetCoreError::Validation(format!(
                "Claude hook template `hooks.{event}` must be an array"
            ))
        })?;
        let target = hooks.entry(event.clone()).or_insert_with(|| json!([]));
        if !target.is_array() {
            return Err(config_shape_error(
                &path,
                "Claude settings",
                format!("expected `hooks.{event}` to be a JSON array"),
            ));
        }
        remove_agent_pet_hook_values(target, connector_cli, Some(install_root));
        let target_groups = target.as_array_mut().ok_or_else(|| {
            config_shape_error(
                &path,
                "Claude settings",
                format!("expected `hooks.{event}` to be a JSON array"),
            )
        })?;
        target_groups.extend(template_groups.iter().cloned());
    }

    write_json_config_if_changed(&path, &original, &settings)
}

fn remove_claude_settings_hooks(install_root: &Path, connector_cli: &Path) -> Result<()> {
    let path = claude_settings_path();
    if !path.exists() {
        return Ok(());
    }

    let mut settings = read_json_config_or_default(&path, json!({}), "Claude settings")?;
    let original = settings.clone();

    let Some(root) = settings.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Claude settings",
            "expected a JSON object",
        ));
    };
    let Some(hooks_value) = root.get_mut("hooks") else {
        return Ok(());
    };
    let Some(hooks) = hooks_value.as_object_mut() else {
        return Err(config_shape_error(
            &path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        ));
    };

    let events = hooks.keys().cloned().collect::<Vec<_>>();
    for event in events {
        let Some(value) = hooks.get_mut(&event) else {
            continue;
        };
        remove_agent_pet_hook_values(value, connector_cli, Some(install_root));
        if value.as_array().is_some_and(Vec::is_empty) {
            hooks.remove(&event);
        }
    }

    if hooks.is_empty() {
        root.remove("hooks");
    }

    write_json_config_if_changed(&path, &original, &settings)?;
    Ok(())
}

fn remove_agent_pet_hook_values(
    value: &mut Value,
    connector_cli: &Path,
    install_root: Option<&Path>,
) {
    let Some(groups) = value.as_array_mut() else {
        return;
    };

    groups.retain_mut(|group| {
        let Some(hooks) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
            return true;
        };
        let before = hooks.len();
        hooks.retain(|hook| !is_agent_pet_claude_hook(hook, connector_cli, install_root));
        let removed_agent_pet_hook = hooks.len() != before;
        !(removed_agent_pet_hook && hooks.is_empty())
    });
}

fn is_agent_pet_claude_hook(
    value: &Value,
    connector_cli: &Path,
    install_root: Option<&Path>,
) -> bool {
    let Some(command) = value.get("command").and_then(Value::as_str) else {
        return false;
    };
    let is_command_hook = value
        .get("type")
        .and_then(Value::as_str)
        .is_none_or(|kind| kind == "command");
    is_command_hook && is_agent_pet_claude_command(command, connector_cli, install_root)
}

fn is_agent_pet_claude_command(
    command: &str,
    connector_cli: &Path,
    install_root: Option<&Path>,
) -> bool {
    let command = command.trim();
    let cli = connector_cli.display().to_string();
    for executable in [shell_quote(&cli), cli] {
        if let Some(arguments) = command.strip_prefix(&executable) {
            const PREFIX: &str = " agent hook --source claude_code --event-type ";
            if let Some(arguments) = arguments.strip_prefix(PREFIX) {
                let (event_type, suffix) = arguments
                    .split_once(' ')
                    .map_or((arguments, ""), |(event_type, suffix)| (event_type, suffix));
                let known_event = matches!(
                    event_type,
                    "auto" | "start" | "tool" | "waiting" | "review" | "done" | "failed"
                );
                let exact_suffix = suffix.is_empty() || suffix == ">/dev/null 2>&1";
                if known_event && exact_suffix {
                    return true;
                }
            }
        }
    }

    let Some(install_root) = install_root else {
        return false;
    };
    let helper = install_root.join("agent-pet-companion-hook.sh");
    let helper = helper.display().to_string();
    [shell_quote(&helper), helper].iter().any(|executable| {
        command == executable || command == format!("{executable} >/dev/null 2>&1")
    })
}

#[cfg(test)]
fn ensure_hook_command(
    settings: &mut Value,
    path: &Path,
    event: &str,
    command: &str,
) -> Result<()> {
    let Some(root) = settings.as_object_mut() else {
        return Err(config_shape_error(
            path,
            "Claude settings",
            "expected a JSON object",
        ));
    };
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    if !hooks.is_object() {
        return Err(config_shape_error(
            path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        ));
    }
    let Some(hooks_object) = hooks.as_object_mut() else {
        return Err(config_shape_error(
            path,
            "Claude settings",
            "expected `hooks` to be a JSON object",
        ));
    };
    let event_hooks = hooks_object.entry(event).or_insert_with(|| json!([]));
    if !event_hooks.is_array() {
        return Err(config_shape_error(
            path,
            "Claude settings",
            format!("expected `hooks.{event}` to be a JSON array"),
        ));
    }
    let Some(array) = event_hooks.as_array_mut() else {
        return Err(config_shape_error(
            path,
            "Claude settings",
            format!("expected `hooks.{event}` to be a JSON array"),
        ));
    };
    if array
        .iter()
        .any(|item| value_contains_command(item, command))
    {
        return Ok(());
    }
    array.push(json!({
        "hooks": [
            {
                "type": "command",
                "command": command
            }
        ]
    }));
    Ok(())
}

#[cfg(test)]
fn value_contains_command(value: &Value, command: &str) -> bool {
    match value {
        Value::String(value) => value == command,
        Value::Array(values) => values
            .iter()
            .any(|value| value_contains_command(value, command)),
        Value::Object(map) => map
            .values()
            .any(|value| value_contains_command(value, command)),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        claude_settings_path, codex_marketplace_entry_path, codex_marketplace_path,
        codex_plugin_json_reports_installed, codex_plugin_text_reports_installed,
        ensure_codex_marketplace_entry, install_claude_settings, json_config_backup_path,
        remove_claude_settings_hooks, remove_codex_marketplace_entry,
    };
    use crate::connections;
    use crate::paths::AppPaths;
    use petcore_types::{AgentSource, CheckStatus};
    use serde_json::json;
    use std::ffi::{OsStr, OsString};
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvVarGuard {
        key: &'static str,
        original: Option<OsString>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: impl AsRef<OsStr>) -> Self {
            let original = std::env::var_os(key);
            std::env::set_var(key, value);
            Self { key, original }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    #[test]
    fn codex_plugin_text_parser_does_not_cross_match_other_installed_plugins() {
        let stdout = r#"
PLUGIN                        STATUS         VERSION  PATH
agent-pet-companion@personal  not installed           /Users/me/.agents/plugins/plugins/agent-pet-companion
browser@openai-bundled        installed, enabled  1.0 /tmp/browser
"#;

        assert!(!codex_plugin_text_reports_installed(stdout));
    }

    #[test]
    fn codex_plugin_json_parser_requires_agent_pet_installed_and_enabled() {
        let available_only = serde_json::to_vec(&json!({
            "installed": [
                {
                    "pluginId": "browser@openai-bundled",
                    "name": "browser",
                    "marketplaceName": "openai-bundled",
                    "installed": true,
                    "enabled": true
                }
            ],
            "available": [
                {
                    "pluginId": "agent-pet-companion@personal",
                    "name": "agent-pet-companion",
                    "marketplaceName": "personal",
                    "installed": false,
                    "enabled": false
                }
            ]
        }))
        .unwrap();
        assert_eq!(
            codex_plugin_json_reports_installed(&available_only),
            Some(false)
        );

        let installed = serde_json::to_vec(&json!({
            "installed": [
                {
                    "pluginId": "agent-pet-companion@personal",
                    "name": "agent-pet-companion",
                    "marketplaceName": "personal",
                    "installed": true,
                    "enabled": true
                }
            ]
        }))
        .unwrap();
        assert_eq!(codex_plugin_json_reports_installed(&installed), Some(true));
    }

    #[test]
    fn codex_marketplace_parser_returns_agent_pet_source_path() {
        let temp = tempfile::tempdir().unwrap();
        let marketplace = temp.path().join("marketplace.json");
        std::fs::write(
            &marketplace,
            serde_json::to_vec(&json!({
                "plugins": [
                    {
                        "name": "cowart",
                        "source": { "path": "./plugins/cowart" }
                    },
                    {
                        "name": "agent-pet-companion",
                        "source": { "path": "./.agents/plugins/plugins/agent-pet-companion" }
                    }
                ]
            }))
            .unwrap(),
        )
        .unwrap();

        assert_eq!(
            codex_marketplace_entry_path(&marketplace).as_deref(),
            Some("./.agents/plugins/plugins/agent-pet-companion")
        );
    }

    #[test]
    fn invalid_codex_marketplace_is_not_overwritten() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let marketplace = codex_marketplace_path();
        std::fs::create_dir_all(marketplace.parent().unwrap()).unwrap();
        let invalid_json = "{ not valid marketplace json";
        std::fs::write(&marketplace, invalid_json).unwrap();

        let repair_error = ensure_codex_marketplace_entry().unwrap_err();
        assert!(repair_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&marketplace).unwrap(), invalid_json);
        assert!(!json_config_backup_path(&marketplace).exists());

        let uninstall_error = remove_codex_marketplace_entry().unwrap_err();
        assert!(uninstall_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&marketplace).unwrap(), invalid_json);
    }

    #[test]
    fn invalid_claude_settings_is_not_overwritten() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let invalid_json = "{ not valid claude settings json";
        std::fs::write(&settings, invalid_json).unwrap();
        let hook_entries = [(
            "PreToolUse",
            "petcore-cli agent hook --source claude_code --event-type tool".to_string(),
        )];

        let repair_error = install_claude_settings(&hook_entries).unwrap_err();
        assert!(repair_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&settings).unwrap(), invalid_json);
        assert!(!json_config_backup_path(&settings).exists());

        let uninstall_error =
            remove_claude_settings_hooks(temp.path(), Path::new("petcore-cli")).unwrap_err();
        assert!(uninstall_error.to_string().contains("JSON 无效"));
        assert_eq!(std::fs::read_to_string(&settings).unwrap(), invalid_json);
    }

    #[test]
    fn claude_uninstall_preserves_mixed_hook_group() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path().join("agents"));
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let settings = claude_settings_path();
        assert_eq!(settings, config_root.join("settings.json"));
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Bash",
                            "groupExtension": { "preserve": true },
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "echo keep-user-hook",
                                    "timeout": 4,
                                    "unknownHookField": "keep"
                                },
                                {
                                    "type": "command",
                                    "command": "'/Applications/Agent Pet Companion/petcore-cli' agent hook --source claude_code --event-type tool"
                                }
                            ]
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        remove_claude_settings_hooks(
            temp.path(),
            Path::new("/Applications/Agent Pet Companion/petcore-cli"),
        )
        .unwrap();

        let updated: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        let group = &updated["hooks"]["PreToolUse"][0];
        assert_eq!(group["matcher"], "Bash");
        assert_eq!(group["groupExtension"]["preserve"], true);
        assert_eq!(group["hooks"].as_array().unwrap().len(), 1);
        assert_eq!(group["hooks"][0]["command"], "echo keep-user-hook");
        assert_eq!(group["hooks"][0]["unknownHookField"], "keep");
    }

    #[test]
    fn claude_uninstall_removes_only_exact_owned_hook_commands() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let config_root = temp.path().join("claude-config");
        let agent_home = temp.path().join("agents");
        let fake_cli = temp.path().join("owned").join("petcore-cli");
        let foreign_cli = temp.path().join("foreign").join("petcore-cli");
        std::fs::create_dir_all(fake_cli.parent().unwrap()).unwrap();
        std::fs::create_dir_all(foreign_cli.parent().unwrap()).unwrap();
        std::fs::write(&fake_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::write(&foreign_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&foreign_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", &config_root);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &fake_cli);
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();
        let canonical_helper = paths
            .connectors_dir
            .join("claude-code")
            .join("agent-pet-companion-hook.sh");
        let foreign_helper = temp
            .path()
            .join("foreign")
            .join("agent-pet-companion-hook.sh");
        let owned_cli_command = format!(
            "'{}' agent hook --source claude_code --event-type auto >/dev/null 2>&1",
            fake_cli.display()
        );
        let foreign_cli_command = format!(
            "'{}' agent hook --source claude_code --event-type auto >/dev/null 2>&1",
            foreign_cli.display()
        );
        let owned_helper_command = format!("'{}'", canonical_helper.display());
        let foreign_helper_command = format!("'{}'", foreign_helper.display());
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "hooks": {
                    "PreToolUse": [{
                        "hooks": [
                            { "type": "command", "command": owned_cli_command },
                            { "type": "command", "command": foreign_cli_command },
                            { "type": "command", "command": owned_helper_command },
                            { "type": "command", "command": foreign_helper_command }
                        ]
                    }]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();

        let updated: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        let hooks = updated["hooks"]["PreToolUse"][0]["hooks"]
            .as_array()
            .unwrap();
        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0]["command"], foreign_cli_command);
        assert_eq!(hooks[1]["command"], foreign_helper_command);
    }

    #[test]
    fn claude_uninstall_preserves_unknown_settings_fields() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", temp.path());
        let _claude_config = EnvVarGuard::set("CLAUDE_CONFIG_DIR", temp.path().join(".claude"));
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        let expected_unknown = json!({
            "future": [1, { "nested": "agent hook --source claude_code is documentation" }]
        });
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "$schema": "https://example.invalid/claude-settings.schema.json",
                "theme": "dark",
                "futureSettings": expected_unknown,
                "hooks": {
                    "Stop": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "petcore-cli agent hook --source claude_code --event-type done"
                                }
                            ]
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        remove_claude_settings_hooks(temp.path(), Path::new("petcore-cli")).unwrap();

        let updated: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        assert_eq!(
            updated["$schema"],
            "https://example.invalid/claude-settings.schema.json"
        );
        assert_eq!(updated["theme"], "dark");
        assert_eq!(updated["futureSettings"], expected_unknown);
        assert!(updated.get("hooks").is_none());
    }

    #[test]
    fn normal_json_repair_and_uninstall_are_idempotent() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let agent_home = temp.path().join("agent-home");
        let fake_cli = temp.path().join("petcore-cli");
        std::fs::write(&fake_cli, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&fake_cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _agent_home = EnvVarGuard::set("APC_AGENT_CONFIG_HOME", &agent_home);
        let _connector_cli = EnvVarGuard::set("APC_CONNECTOR_CLI_PATH", &fake_cli);
        let _app_server_cmd = EnvVarGuard::set("CODEX_APP_SERVER_CMD", "");
        let _disable_app_server_auto = EnvVarGuard::set("APC_DISABLE_CODEX_APP_SERVER_AUTO", "1");
        let paths = AppPaths::new(temp.path().join("app-home"));
        paths.ensure().unwrap();

        let marketplace = codex_marketplace_path();
        std::fs::create_dir_all(marketplace.parent().unwrap()).unwrap();
        std::fs::write(
            &marketplace,
            serde_json::to_vec_pretty(&json!({
                "name": "personal",
                "interface": { "displayName": "Personal" },
                "plugins": [
                    {
                        "name": "keep-plugin",
                        "source": { "source": "local", "path": "./plugins/keep-plugin" }
                    }
                ]
            }))
            .unwrap(),
        )
        .unwrap();
        let settings = claude_settings_path();
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(
            &settings,
            serde_json::to_vec_pretty(&json!({
                "theme": "dark",
                "hooks": {
                    "PreToolUse": [
                        {
                            "hooks": [
                                { "type": "command", "command": "echo keep" }
                            ]
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        connections::repair_source(&paths, AgentSource::Codex).unwrap();
        connections::repair_source(&paths, AgentSource::Codex).unwrap();
        let repaired_marketplace: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marketplace).unwrap()).unwrap();
        let plugins = repaired_marketplace["plugins"].as_array().unwrap();
        assert_eq!(agent_pet_plugin_count(&repaired_marketplace), 1);
        assert!(plugins
            .iter()
            .any(|plugin| plugin["name"].as_str() == Some("keep-plugin")));
        assert!(json_config_backup_path(&marketplace).is_file());

        connections::repair_source(&paths, AgentSource::ClaudeCode).unwrap();
        connections::repair_source(&paths, AgentSource::ClaudeCode).unwrap();
        let repaired_settings = std::fs::read_to_string(&settings).unwrap();
        assert!(repaired_settings.contains("agent hook --source claude_code"));
        assert!(repaired_settings.contains("echo keep"));
        assert!(json_config_backup_path(&settings).is_file());

        connections::uninstall_source(&paths, AgentSource::Codex).unwrap();
        connections::uninstall_source(&paths, AgentSource::Codex).unwrap();
        let uninstalled_marketplace: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marketplace).unwrap()).unwrap();
        assert_eq!(agent_pet_plugin_count(&uninstalled_marketplace), 0);
        assert!(uninstalled_marketplace["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .any(|plugin| plugin["name"].as_str() == Some("keep-plugin")));

        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();
        connections::uninstall_source(&paths, AgentSource::ClaudeCode).unwrap();
        let uninstalled_settings = std::fs::read_to_string(&settings).unwrap();
        assert!(!uninstalled_settings.contains("agent hook --source claude_code"));
        assert!(uninstalled_settings.contains("echo keep"));
        assert!(uninstalled_settings.contains("\"theme\": \"dark\""));
    }

    #[test]
    fn opencode_server_probe_requires_valid_health_json() {
        let _env_lock = ENV_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let opencode = bin.join("opencode");
        let curl = bin.join("curl");
        std::fs::write(&opencode, "#!/bin/sh\nexec /bin/sleep 10\n").unwrap();
        std::fs::write(
            &curl,
            "#!/bin/sh\nprintf '%s' '{\"healthy\":true,\"version\":\"test\"}'\n",
        )
        .unwrap();
        std::fs::set_permissions(&opencode, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _path = EnvVarGuard::set("PATH", &bin);

        let check = connections::probe_opencode_server();

        assert_eq!(check.status, CheckStatus::Ok);
        assert!(check.detail.contains("runtime_verified"));
    }

    fn agent_pet_plugin_count(marketplace: &serde_json::Value) -> usize {
        marketplace["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|plugin| plugin["name"].as_str() == Some("agent-pet-companion"))
            .count()
    }
}
