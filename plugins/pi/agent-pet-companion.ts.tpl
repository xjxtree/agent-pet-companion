import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const CLI_PATH = __APC_CLI_JSON__;
export const APC_PI_CONTRACT_VERSION = "pi-extension-20260714-message-v5";
export const APC_PI_WAITING_CAPABILITY = "structured-extension-events";
const finalAgentErrors = new Map();
const finalAssistantMessages = new Map();
const activeTurnIds = new Map();
const pendingInputTexts = new Map();
const MAX_TRACKED_SESSIONS = 256;

function sessionId(ctx) {
  return ctx?.sessionManager?.getSessionId?.() ?? ctx?.sessionManager?.sessionId;
}

function sessionTitle(ctx) {
  return ctx?.sessionManager?.getSessionName?.() ?? ctx?.sessionManager?.sessionName;
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

function displayMessage(event, id) {
  if (event?.type === "input" && typeof event?.text === "string") {
    return { role: "user", content: event.text };
  }
  if (event?.type === "before_agent_start" && typeof event?.prompt === "string") {
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

function agentEndedWithError(event) {
  const assistant = assistantMessage(event);
  return assistant?.stopReason === "error";
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
    child.stdin?.end(JSON.stringify(payload));
  });
}

async function forward(event, ctx) {
  const id = sessionId(ctx);
  if (event?.type === "input") {
    remember(activeTurnIds, id, randomUUID());
    remember(finalAgentErrors, id, false);
    finalAssistantMessages.delete(id);
    remember(pendingInputTexts, id, event?.text);
  } else if (event?.type === "before_agent_start") {
    const pendingInput = pendingInputTexts.get(id);
    if (!activeTurnIds.has(id) || pendingInput !== event?.prompt) {
      remember(activeTurnIds, id, randomUUID());
    }
    remember(finalAgentErrors, id, false);
    finalAssistantMessages.delete(id);
    pendingInputTexts.delete(id);
  } else if (id && !activeTurnIds.has(id) && !["session_start", "session_shutdown"].includes(event?.type)) {
    remember(activeTurnIds, id, randomUUID());
  }

  const assistant = assistantMessage(event);
  const assistantContent = messageText(assistant);
  if (assistant) {
    remember(finalAgentErrors, id, assistant?.stopReason === "error");
    if (assistantContent) remember(finalAssistantMessages, id, assistantContent);
  }

  const agentError = event?.type === "agent_end" || event?.type === "message_end"
    ? agentEndedWithError(event)
    : event?.type === "agent_settled" && finalAgentErrors.get(id) === true;
  const message = displayMessage(event, id);
  if (event?.type === "message_end" && !message) return;
  const allowlisted = {
    type: event?.type,
    session_id: id,
    turn_id: activeTurnIds.get(id),
    session_title: sessionTitle(ctx),
    session_open: event?.type !== "session_shutdown",
    tool_name: event?.toolName,
    is_error: event?.isError === true,
    agent_error: agentError,
    reason: event?.reason,
    diagnostic: event?.diagnostic === true,
    message_role: message?.role,
    message_content: message?.content,
  };
  try {
    await sendEvent(allowlisted);
  } finally {
    if (event?.type === "agent_settled" || event?.type === "session_shutdown") {
      forgetSession(id);
    }
  }
}

export default function agentPetCompanion(pi) {
  if (!pi?.on) return;
  pi.on("session_start", async (event, ctx) => forward(event, ctx));
  pi.on("input", async (event, ctx) => forward(event, ctx));
  pi.on("before_agent_start", async (event, ctx) => forward(event, ctx));
  pi.on("agent_start", async (event, ctx) => forward(event, ctx));
  pi.on("tool_call", async (event, ctx) => forward(event, ctx));
  pi.on("tool_execution_start", async (event, ctx) => forward(event, ctx));
  pi.on("tool_execution_end", async (event, ctx) => forward(event, ctx));
  pi.on("message_end", async (event, ctx) => forward(event, ctx));
  pi.on("agent_end", async (event, ctx) => forward(event, ctx));
  pi.on("agent_settled", async (event, ctx) => forward(event, ctx));
  pi.on("session_before_compact", async (event, ctx) => forward(event, ctx));
  pi.on("session_compact", async (event, ctx) => forward(event, ctx));
  pi.on("session_shutdown", async (event, ctx) => forward(event, ctx));
}
