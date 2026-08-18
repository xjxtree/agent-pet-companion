use super::manager::{
    CLAUDE_AUDITED_HOOK_EVENTS, CODEX_APP_SERVER_NOTIFICATION_EVENTS, CODEX_LOCAL_HOOK_EVENTS,
    OPENCODE_AUDITED_BUS_EVENTS, OPENCODE_AUDITED_PLUGIN_HOOKS, PI_AUDITED_EVENTS,
};
use crate::adapter_contracts::{
    CLAUDE_HOOKS_CONTRACT_VERSION, CODEX_HOOKS_CONTRACT_VERSION, DSH_PLUGIN_CONTRACT_VERSION,
    OPENCODE_CONTRACT_VERSION, PI_EXTENSION_CONTRACT_VERSION,
};
use petcore_types::{AgentConnectorCapabilities, AgentSource};

pub(crate) fn contract_version_for_source(source: AgentSource) -> &'static str {
    match source {
        AgentSource::Codex => CODEX_HOOKS_CONTRACT_VERSION,
        AgentSource::ClaudeCode => CLAUDE_HOOKS_CONTRACT_VERSION,
        AgentSource::Pi => PI_EXTENSION_CONTRACT_VERSION,
        AgentSource::Opencode => OPENCODE_CONTRACT_VERSION,
        AgentSource::Dsh => DSH_PLUGIN_CONTRACT_VERSION,
    }
}

pub(super) fn capabilities_for_source(source: AgentSource) -> AgentConnectorCapabilities {
    let strings = |values: &[&str]| values.iter().map(|value| (*value).to_string()).collect();
    match source {
        AgentSource::Codex => {
            let audited_events: Vec<String> = CODEX_LOCAL_HOOK_EVENTS
                .iter()
                .map(|event| format!("Plugin Hook · {event}"))
                .chain(
                    CODEX_APP_SERVER_NOTIFICATION_EVENTS
                        .iter()
                        .map(|event| format!("App Server Notification · {event}")),
                )
                .collect();
            let mut subscribed_events: Vec<String> = strings(CODEX_LOCAL_HOOK_EVENTS);
            subscribed_events.push(
                "App Server 只读后备 · hooks/list + thread/list + 有界 thread/read".to_string(),
            );
            AgentConnectorCapabilities {
                contract_version: CODEX_HOOKS_CONTRACT_VERSION.to_string(),
                audited_events,
                subscribed_events,
                mapped_information: strings(&[
                    "10 个官方 Hook 提供任务开始/完成、工具、权限、压缩与子 Agent 生命周期",
                    "已审计 CLI 0.144.5 与桌面内置 0.145.0-alpha.18 / 0.146.0-alpha.3.1 / 0.146.0-alpha.9.2 / 0.147.0-alpha.1.2 的 70 个 App Server 通知；仅以 thread/list/read 作有损只读后备",
                    "有界的用户提示、最终助手消息、reasoning、命令与工具输入输出",
                ]),
                privacy_exclusions: strings(&[
                    "不逐条保存 App Server 的高频 token delta、audio 或账户通知内容",
                    "不保存 transcript_path、完整 transcript、完整补丁或任意宿主 envelope",
                    "不读取认证存储，也不转发 auth headers、Token、Cookie、API Key 或完整环境变量",
                ]),
                ..Default::default()
            }
        }
        AgentSource::ClaudeCode => AgentConnectorCapabilities {
            contract_version: CLAUDE_HOOKS_CONTRACT_VERSION.to_string(),
            audited_events: strings(CLAUDE_AUDITED_HOOK_EVENTS),
            subscribed_events: strings(&[
                "SessionStart",
                "Setup",
                "InstructionsLoaded",
                "UserPromptSubmit",
                "UserPromptExpansion",
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "PostToolUseFailure",
                "PostToolBatch",
                "PermissionDenied",
                "Notification",
                "SubagentStart",
                "SubagentStop",
                "TaskCreated",
                "TaskCompleted",
                "Stop",
                "StopFailure",
                "TeammateIdle",
                "ConfigChange",
                "CwdChanged",
                "WorktreeRemove",
                "PreCompact",
                "PostCompact",
                "Elicitation",
                "ElicitationResult",
                "SessionEnd",
            ]),
            mapped_information: strings(&[
                "任务、工具、权限/提问、子 Agent/Task、压缩、失败与后台工作状态",
                "Setup/配置/CWD/指令加载等元数据仅用于连接观察，不驱动桌宠",
                "prompt_id 用作 turn 终止栅栏",
                "有界命令、工具输入输出、错误正文与原始活动详情用于本地气泡",
            ]),
            privacy_exclusions: strings(&[
                "不订阅 WorktreeCreate（会替换宿主默认创建行为）",
                "不订阅 MessageDisplay/FileChanged（流式风暴或无安全全量匹配）",
                "不保存完整 transcript、认证存储、auth headers、完整环境变量或无会话归属的宿主数据",
            ]),
            ..Default::default()
        },
        AgentSource::Pi => AgentConnectorCapabilities {
            contract_version: PI_EXTENSION_CONTRACT_VERSION.to_string(),
            audited_events: strings(PI_AUDITED_EVENTS),
            subscribed_events: strings(&[
                "project_trust",
                "resources_discover",
                "session_start",
                "session_info_changed",
                "session_before_switch",
                "session_before_fork",
                "session_before_compact",
                "session_compact",
                "session_shutdown",
                "session_before_tree",
                "session_tree",
                "context",
                "before_provider_request",
                "before_provider_headers",
                "after_provider_response",
                "before_agent_start",
                "agent_start",
                "agent_end",
                "agent_settled",
                "turn_start",
                "turn_end",
                "message_start",
                "message_update",
                "message_end",
                "tool_execution_start",
                "tool_execution_update",
                "tool_execution_end",
                "model_select",
                "thinking_level_select",
                "user_bash",
                "input",
                "tool_call",
                "tool_result",
            ]),
            mapped_information: strings(&[
                "输入、turn、工具开始/结束、压缩、最终 agent_settled 与会话关闭",
                "session title、工具名与单向散列调用身份",
                "稳定事件中的有界 reasoning、命令、工具输入输出与原始活动详情",
            ]),
            privacy_exclusions: strings(&[
                "不转发完整 context、provider headers/auth、完整环境变量或逐 token 流式 delta",
                "agent_end 不作为终态；只有 agent_settled 稳定完成",
            ]),
            ..Default::default()
        },
        AgentSource::Opencode => {
            let audited_events = OPENCODE_AUDITED_PLUGIN_HOOKS
                .iter()
                .map(|event| format!("Plugin Hook · {event}"))
                .chain(
                    OPENCODE_AUDITED_BUS_EVENTS
                        .iter()
                        .map(|event| format!("Event Bus · {event}")),
                )
                .collect();
            AgentConnectorCapabilities {
                contract_version: OPENCODE_CONTRACT_VERSION.to_string(),
                audited_events,
                subscribed_events: strings(&[
                    "event（统一观察 91 个 SDK v1 + v2/host bus 事件）",
                    "dispose（有界排空已接收事件，不生成会话终态）",
                    "chat.message",
                    "permission.ask",
                    "command.execute.before",
                    "tool.execute.before",
                    "tool.execute.after",
                    "experimental.session.compacting",
                    "experimental.text.complete",
                ]),
                mapped_information: strings(&[
                    "已盘点 21 个 Plugin Hook；注册 9 个只读安全项",
                    "generic event 覆盖 91 个 SDK v1 + v2/host bus 事件；映射有会话归属的有界活动内容",
                    "session 状态、权限/提问、消息、命令/工具、计划、压缩与 session.next 生命周期",
                    "稳定事件中的 reasoning、命令、工具输入输出、错误正文与原始活动详情",
                    "v2 单次 tool success/failure 保持可恢复；retry 重新激活；step.failed/session_failure 映射为终态失败",
                ]),
                privacy_exclusions: strings(&[
                    "不注册 config/tool/tool.definition/auth 等会修改配置、工具定义或认证行为的 Hook",
                    "不转发 provider headers/env/auth、认证存储、完整 transcript 或任意宿主 envelope",
                    "高频 token delta 不逐条持久化；使用稳定完成事件的有界内容",
                ]),
                ..Default::default()
            }
        }
        // T3/T4 land the audited event inventory and plugin template; the
        // capability row stays minimal and installable=false until then.
        AgentSource::Dsh => AgentConnectorCapabilities {
            contract_version: DSH_PLUGIN_CONTRACT_VERSION.to_string(),
            ..Default::default()
        },
    }
}
