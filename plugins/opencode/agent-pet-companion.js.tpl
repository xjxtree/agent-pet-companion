import { spawn } from "node:child_process";

const CLI_PATH = __APC_CLI_JSON__;
export const APC_OPENCODE_CONTRACT_VERSION = "opencode-v1.17.18-activity-v4";

const sessions = new Map();
const messageRoles = new Map();
const messageTexts = new Map();
const messageTextParts = new Map();
const messageSessions = new Map();
const messageDiagnostics = new Map();
const completedAssistantMessages = new Map();
const latestAssistantMessages = new Map();
const emittedAssistantMessages = new Map();
const MAX_TRACKED_ITEMS = 256;

function remember(map, key, value) {
  if (!key) return;
  if (!map.has(key) && map.size >= MAX_TRACKED_ITEMS) {
    map.delete(map.keys().next().value);
  }
  map.set(key, value);
}

function forward(allowlisted) {
  const child = spawn(
    CLI_PATH,
    ["agent", "hook", "--source", "opencode", "--event-type", "auto"],
    {
      stdio: ["pipe", "ignore", "ignore"],
      signal: AbortSignal.timeout(1500),
      windowsHide: true,
    },
  );
  child.on("error", () => {});
  child.stdin?.end(JSON.stringify(allowlisted));
  child.unref?.();
}

function sessionID(properties) {
  const info = properties?.info;
  return properties?.sessionID
    ?? info?.sessionID
    ?? properties?.part?.sessionID
    ?? (info?.role === undefined ? info?.id : undefined);
}

function rememberSession(properties) {
  const id = sessionID(properties);
  const title = properties?.info?.title;
  if (id && typeof title === "string" && title.trim()) {
    remember(sessions, id, title.trim());
  }
  return id;
}

function textParts(parts) {
  if (!Array.isArray(parts)) return undefined;
  const text = parts
    .filter((part) => part?.type === "text" && typeof part?.text === "string" && part?.synthetic !== true)
    .map((part) => part.text)
    .join("\n")
    .trim();
  return text || undefined;
}

function rememberMessageText(messageID, partID, content) {
  if (!messageID || !partID || !content) return undefined;
  remember(messageTextParts, `${messageID}:${partID}`, { messageID, content });
  const combined = [...messageTextParts.values()]
    .filter((part) => part.messageID === messageID)
    .map((part) => part.content)
    .join("\n")
    .trim();
  if (combined) remember(messageTexts, messageID, combined);
  return combined || undefined;
}

function assistantMessageEvent(sessionID, messageID, content) {
  if (!sessionID || !messageID || !content) return undefined;
  if (emittedAssistantMessages.get(messageID) === content) return undefined;
  remember(emittedAssistantMessages, messageID, content);
  return {
    type: "message.assistant",
    properties: {
      sessionID,
      session_title: sessions.get(sessionID),
      message_content: content,
      diagnostic: messageDiagnostics.get(messageID) === true,
    },
  };
}

function rememberAssistantMessage(sessionID, messageID) {
  if (!sessionID || !messageID) return;
  remember(messageSessions, messageID, sessionID);
  remember(latestAssistantMessages, sessionID, messageID);
}

function pendingAssistantEvent(sessionID) {
  const messageID = latestAssistantMessages.get(sessionID);
  if (!messageID) return undefined;
  return assistantMessageEvent(sessionID, messageID, messageTexts.get(messageID));
}

function compatibleEvent(event) {
  const type = event?.type;
  const properties = event?.properties ?? {};
  const id = rememberSession(properties);

  if (type === "session.updated") return undefined;
  if (type === "message.updated") {
    const info = properties?.info ?? {};
    const messageID = info?.id;
    if (messageID && typeof info?.role === "string") remember(messageRoles, messageID, info.role);
    if (messageID && info?.diagnostic === true) remember(messageDiagnostics, messageID, true);
    if (info?.role === "assistant") rememberAssistantMessage(info?.sessionID ?? id, messageID);
    if (info?.role === "assistant" && info?.time?.completed != null) {
      remember(completedAssistantMessages, messageID, true);
      return assistantMessageEvent(info?.sessionID ?? id, messageID, messageTexts.get(messageID));
    }
    return undefined;
  }
  if (type === "message.part.updated") {
    const part = properties?.part ?? {};
    if (part?.type !== "text" || typeof part?.text !== "string" || part?.synthetic === true) {
      return undefined;
    }
    const content = rememberMessageText(part.messageID, part.id, part.text.trim());
    if (properties?.diagnostic === true || part?.diagnostic === true) {
      remember(messageDiagnostics, part.messageID, true);
    }
    const partSessionID = part?.sessionID ?? messageSessions.get(part.messageID) ?? id;
    if (messageRoles.get(part.messageID) === "assistant") {
      rememberAssistantMessage(partSessionID, part.messageID);
    }
    if (messageRoles.get(part.messageID) === "assistant"
      && (part?.time?.end != null || completedAssistantMessages.get(part.messageID) === true)) {
      return assistantMessageEvent(partSessionID, part.messageID, content);
    }
    return undefined;
  }

  if (![
    "session.created", "session.deleted", "session.status", "session.idle", "session.error",
    "permission.asked", "permission.updated", "permission.replied",
    "question.asked", "question.replied", "question.rejected",
  ].includes(type)) {
    return undefined;
  }
  return {
    type,
    properties: {
      sessionID: id,
      session_title: sessions.get(id),
      status: properties?.status?.type,
      response: properties?.response ?? properties?.reply,
      diagnostic: properties?.diagnostic === true || properties?.info?.diagnostic === true,
    },
  };
}

export const AgentPetCompanion = async () => ({
  event: async ({ event }) => {
    if (event?.type === "session.idle"
      || (event?.type === "session.status" && event?.properties?.status?.type === "idle")) {
      const finalMessage = pendingAssistantEvent(sessionID(event?.properties ?? {}));
      if (finalMessage) forward(finalMessage);
    }
    const allowlisted = compatibleEvent(event);
    if (allowlisted) forward(allowlisted);
  },

  "chat.message": async (input, output) => {
    const content = textParts(output?.parts);
    if (!content) return;
    forward({
      type: "message.user",
      properties: {
        sessionID: input?.sessionID,
        session_title: sessions.get(input?.sessionID),
        message_content: content,
        diagnostic: input?.diagnostic === true,
      },
    });
  },

  "tool.execute.before": async (input, output) => {
    const args = output?.args;
    forward({
      type: "tool.execute.before",
      input: {
        tool: input?.tool,
        sessionID: input?.sessionID,
        callID: input?.callID,
      },
      outcome: args === undefined ? "started_without_args" : "started",
      diagnostic: input?.diagnostic === true,
    });
  },

  "tool.execute.after": async (input) => {
    forward({
      type: "tool.execute.after",
      input: {
        tool: input?.tool,
        sessionID: input?.sessionID,
        callID: input?.callID,
      },
      outcome: "completed",
      diagnostic: input?.diagnostic === true,
    });
  },
});
