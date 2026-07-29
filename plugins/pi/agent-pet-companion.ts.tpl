import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const CLI_PATH = __APC_CLI_JSON__;
export const APC_PI_CONNECTOR_RELEASE_VERSION = "__APC_CONNECTOR_RELEASE_VERSION__";
export const APC_PI_CONTRACT_VERSION = "pi-extension-0.80.10-activity-v9";
export const APC_PI_WAITING_CAPABILITY = "structured-extension-events";

// Pi 0.80.10 ExtensionAPI event inventory. Every official event is registered
// below. Stable, session-scoped reasoning, command, tool input/output, and raw
// activity details may cross as one bounded local display string; provider
// headers, auth state, environments, and complete contexts remain excluded.
export const APC_PI_EVENT_INVENTORY = Object.freeze([
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
]);

export const APC_PI_FORWARDED_EVENTS = Object.freeze([
  "input",
  "before_agent_start",
  "agent_start",
  "turn_start",
  "turn_end",
  "message_end",
  "tool_call",
  "tool_execution_start",
  "tool_execution_end",
  "session_before_compact",
  "session_compact",
  "session_info_changed",
  "agent_settled",
  "session_shutdown",
]);

const connectorDiagnostic = process.env.APC_CONNECTOR_DIAGNOSTIC === "1"
  || process.env.APC_CONNECTOR_PROBE === "1";
const connectorProbe = process.env.APC_CONNECTOR_PROBE === "1";
const connectorProbeID = /^apc-probe-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  .test(process.env.APC_CONNECTOR_PROBE_ID ?? "")
  ? process.env.APC_CONNECTOR_PROBE_ID
  : undefined;
let connectorProbeSent = false;
const finalAgentErrors = new Map();
const finalAssistantMessages = new Map();
const activeTurnIds = new Map();
const pendingInputTexts = new Map();
const MAX_TRACKED_SESSIONS = 256;

function sessionId(ctx) {
  return ctx?.sessionManager?.getSessionId?.() ?? ctx?.sessionManager?.sessionId;
}

function sessionTitle(ctx, event) {
  const title = event?.type === "session_info_changed" ? event?.name : undefined;
  return title ?? ctx?.sessionManager?.getSessionName?.() ?? ctx?.sessionManager?.sessionName;
}

function messageText(message) {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  const text = content
    .filter((part) => part?.type === "text" && typeof part?.text === "string")
    .map((part) => part.text)
    .join("\n")
    .trim();
  return text || undefined;
}

function assistantMessage(event) {
  if (event?.type === "message_end" && event?.message?.role === "assistant") {
    return event.message;
  }
  if (event?.type === "agent_end" && Array.isArray(event?.messages)) {
    return [...event.messages].reverse().find((message) => message?.role === "assistant");
  }
  return undefined;
}

function displayMessage(event, id, includeBeforeAgentPrompt) {
  if (event?.type === "input" && typeof event?.text === "string") {
    return { role: "user", content: event.text };
  }
  if (includeBeforeAgentPrompt
    && event?.type === "before_agent_start"
    && typeof event?.prompt === "string") {
    return { role: "user", content: event.prompt };
  }
  const content = messageText(assistantMessage(event));
  if (content) return { role: "assistant", content };
  if (event?.type === "agent_settled") {
    const settledContent = finalAssistantMessages.get(id);
    if (settledContent) return { role: "assistant", content: settledContent };
  }
  return undefined;
}

function activityText(event) {
  let value;
  if (typeof event?.activity_content === "string") {
    value = event.activity_content;
  } else if (["tool_call", "tool_execution_start"].includes(event?.type)) {
    value = event?.input;
  } else if (event?.type === "tool_execution_end") {
    value = event?.result ?? event?.output ?? event?.error;
  } else {
    const message = event?.type === "message_end" ? event?.message : undefined;
    const reasoning = Array.isArray(message?.content)
      ? message.content
        .filter((part) => (
          ["reasoning", "thinking", "analysis"].includes(part?.type)
          && typeof (part?.text ?? part?.content) === "string"
        ))
        .map((part) => part.text ?? part.content)
        .join("\n")
        .trim()
      : undefined;
    value = reasoning
      || event?.reasoning_summary
      || event?.reasoning
      || event?.summary
      || event?.detail
      || event?.reason;
  }
  if (value == null) return undefined;
  value = activityValueWithoutCredentials(value);
  let text;
  if (typeof value === "string") {
    text = value;
  } else {
    try {
      text = JSON.stringify(value);
    } catch {
      return undefined;
    }
  }
  text = text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ").trim();
  if (!text) return undefined;
  const bytes = new TextEncoder().encode(text);
  if (bytes.length <= 1024) return text;
  return new TextDecoder().decode(bytes.slice(0, 1024)).replace(/\uFFFD$/, "");
}

function activityValueWithoutCredentials(value) {
  if (Array.isArray(value)) return value.map(activityValueWithoutCredentials);
  if (value == null || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key]) => ![
      "auth", "authorization", "cookie", "cookies", "credential", "credentials",
      "env", "environment", "headers", "password", "secret", "secrets", "token",
      "tokens", "apikey", "accesstoken", "refreshtoken",
    ].includes(key.replace(/[^a-z0-9]/gi, "").toLowerCase()))
    .map(([key, nested]) => [key, activityValueWithoutCredentials(nested)]));
}

function remember(map, id, value) {
  if (!id) return;
  map.delete(id);
  map.set(id, value);
  while (map.size > MAX_TRACKED_SESSIONS) {
    map.delete(map.keys().next().value);
  }
}

function forgetSession(id) {
  finalAgentErrors.delete(id);
  finalAssistantMessages.delete(id);
  activeTurnIds.delete(id);
  pendingInputTexts.delete(id);
}

function sendEvent(payload) {
  return new Promise((resolve) => {
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      resolve();
    };
    let child;
    try {
      child = spawn(
        CLI_PATH,
        ["agent", "hook", "--source", "pi", "--event-type", "auto"],
        {
          stdio: ["pipe", "ignore", "ignore"],
          signal: AbortSignal.timeout(3000),
          windowsHide: true,
        },
      );
    } catch {
      finish();
      return;
    }
    child.once("error", finish);
    child.once("close", finish);
    child.stdin?.once("error", finish);
    child.stdin?.end(JSON.stringify({
      ...payload,
      contract_version: APC_PI_CONTRACT_VERSION,
    }));
  });
}

async function forward(event, ctx) {
  const id = sessionId(ctx);
  let includeBeforeAgentPrompt = true;
  if (event?.type === "input") {
    remember(activeTurnIds, id, randomUUID());
    remember(finalAgentErrors, id, false);
    finalAssistantMessages.delete(id);
    remember(pendingInputTexts, id, event?.text);
  } else if (event?.type === "before_agent_start") {
    const pendingInput = pendingInputTexts.get(id);
    includeBeforeAgentPrompt = pendingInput !== event?.prompt;
    if (!activeTurnIds.has(id) || includeBeforeAgentPrompt) {
      remember(activeTurnIds, id, randomUUID());
    }
    remember(finalAgentErrors, id, false);
    finalAssistantMessages.delete(id);
    pendingInputTexts.delete(id);
  } else if (
    id
    && !activeTurnIds.has(id)
    && !["session_start", "session_info_changed", "session_shutdown"].includes(event?.type)
  ) {
    remember(activeTurnIds, id, randomUUID());
  }

  const assistant = assistantMessage(event);
  const assistantContent = messageText(assistant);
  if (assistant) {
    remember(finalAgentErrors, id, assistant?.stopReason === "error");
    if (assistantContent) remember(finalAssistantMessages, id, assistantContent);
  }

  // agent_end is not a stable completion boundary in Pi 0.80.10. It can be
  // followed by automatic retry, compaction, or a queued continuation. Cache
  // its final message/error only; agent_settled is the sole terminal event.
  if (event?.type === "agent_end") return;

  const agentError = event?.type === "agent_settled" && finalAgentErrors.get(id) === true;
  const message = displayMessage(event, id, includeBeforeAgentPrompt);
  if (event?.type === "message_end" && !message) return;
  const allowlisted = {
    type: event?.type,
    session_id: id,
    turn_id: activeTurnIds.get(id),
    session_title: sessionTitle(ctx, event),
    session_open: event?.type !== "session_shutdown",
    tool_name: event?.toolName,
    tool_call_id: event?.toolCallId,
    is_error: event?.isError === true,
    agent_error: agentError,
    reason: typeof event?.reason === "string" ? event.reason : undefined,
    diagnostic: connectorDiagnostic || event?.diagnostic === true,
    message_role: message?.role,
    message_content: message?.content,
    activity_content: activityText(event),
  };
  try {
    await sendEvent(allowlisted);
  } finally {
    if (event?.type === "agent_settled" || event?.type === "session_shutdown") {
      forgetSession(id);
    }
  }
}

function observeOnly() {
  // Intentionally empty for events without a stable session-scoped display
  // payload. Provider context, headers, auth, and environment data never cross
  // the local connector boundary.
}

async function sendConnectorProbeOnce() {
  if (!connectorProbe || connectorProbeSent) return;
  connectorProbeSent = true;
  await sendEvent({
    type: "connector.probe",
    session_id: connectorProbeID ?? `apc-pi-probe-${randomUUID()}`,
    diagnostic: true,
  });
}

export default function agentPetCompanion(pi) {
  if (!pi?.on) return;

  // Returning undecided observes project-trust capability without changing the
  // host's own trust decision.
  pi.on("project_trust", async () => ({ trusted: "undecided" }));
  pi.on("resources_discover", observeOnly);
  pi.on("session_start", async () => sendConnectorProbeOnce());
  pi.on("session_info_changed", async (event, ctx) => forward(event, ctx));
  pi.on("session_before_switch", observeOnly);
  pi.on("session_before_fork", observeOnly);
  pi.on("session_before_compact", async (event, ctx) => forward(event, ctx));
  pi.on("session_compact", async (event, ctx) => forward(event, ctx));
  pi.on("session_shutdown", async (event, ctx) => {
    if (connectorProbe) {
      return;
    }
    await forward(event, ctx);
  });
  pi.on("session_before_tree", observeOnly);
  pi.on("session_tree", observeOnly);
  pi.on("context", observeOnly);
  pi.on("before_provider_request", observeOnly);
  pi.on("before_provider_headers", observeOnly);
  pi.on("after_provider_response", observeOnly);
  pi.on("before_agent_start", async (event, ctx) => forward(event, ctx));
  pi.on("agent_start", async (event, ctx) => forward(event, ctx));
  pi.on("agent_end", async (event, ctx) => forward(event, ctx));
  pi.on("agent_settled", async (event, ctx) => forward(event, ctx));
  pi.on("turn_start", async (event, ctx) => forward(event, ctx));
  pi.on("turn_end", async (event, ctx) => forward(event, ctx));
  pi.on("message_start", observeOnly);
  pi.on("message_update", observeOnly);
  pi.on("message_end", async (event, ctx) => forward(event, ctx));
  pi.on("tool_execution_start", async (event, ctx) => forward(event, ctx));
  pi.on("tool_execution_update", observeOnly);
  pi.on("tool_execution_end", async (event, ctx) => forward(event, ctx));
  pi.on("model_select", observeOnly);
  pi.on("thinking_level_select", observeOnly);
  pi.on("user_bash", observeOnly);
  pi.on("input", async (event, ctx) => forward(event, ctx));
  pi.on("tool_call", async (event, ctx) => forward(event, ctx));
  pi.on("tool_result", observeOnly);

}
