import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";

const CLI_PATH = __APC_CLI_JSON__;
export const APC_DSH_CONNECTOR_RELEASE_VERSION = "__APC_CONNECTOR_RELEASE_VERSION__";
export const APC_DSH_CONTRACT_VERSION = "dsh-v0.1.0-rc.6-events-v2";

// Audited dsh broadcast events. Agent Pet Companion subscribes ONLY to emit/
// broadcast events. Waterfall/interception events (agent/pre-step,
// agent/turn-stopping, tools/pre-execute, tools/post-execute, agent/request-error)
// MUST NEVER be subscribed by a pure observer -- an observer that swallows
// the decision chain crashes the driver with "Cannot read properties of
// undefined (reading 'kind')".
export const APC_DSH_AUDITED_EVENTS = Object.freeze([
  "session/event",
  "session/disposed",
  "subagent/start",
  "subagent/end",
  "agent/status",
]);

export const name = "agent-pet-companion";

const connectorDiagnostic = process.env.APC_CONNECTOR_DIAGNOSTIC === "1"
  || process.env.APC_CONNECTOR_PROBE === "1";
const connectorProbe = process.env.APC_CONNECTOR_PROBE === "1";
const connectorProbeID = /^apc-probe-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  .test(process.env.APC_CONNECTOR_PROBE_ID ?? "")
  ? process.env.APC_CONNECTOR_PROBE_ID
  : undefined;

// Maximum bounds mirrored from the APC connector contract
const MAX_TRACKED_ITEMS = 256;
const MAX_PENDING_DELIVERIES = 96;
const DELIVERY_TIMEOUT_MS = 3000;
const TERMINAL_PRELUDE_TIMEOUT_MS = 500;
const BOUND_STRING_BYTES = 200;
const BOUND_MESSAGE_BYTES = 4096;

// Local state tracking
const childSessions = new Set();
const childParents = new Map();
const pendingStartRuns = new Map();
const parentFences = new Map();
const pendingCompletedTurns = new Set();
const latestUserMessages = new Map();
const latestAssistantMessages = new Map();
const sessionTitles = new Map();

const deliveryItems = [];
let deliveryWorker;
let inFlightAbort;

function remember(map, key, value) {
  if (!key) return;
  if (!map.has(key) && map.size >= MAX_TRACKED_ITEMS) {
    map.delete(map.keys().next().value);
  }
  map.set(key, value);
}

function boundString(value, maxBytes = BOUND_STRING_BYTES) {
  if (typeof value !== "string" || !value.trim()) return undefined;
  const trimmed = value.trim();
  const buf = Buffer.from(trimmed, "utf8");
  return buf.length <= maxBytes
    ? trimmed
    : `${buf.subarray(0, maxBytes).toString("utf8")}...`;
}

function cleanText(value) {
  if (typeof value !== "string") return undefined;
  const stripped = value.trim();
  return stripped.length > 0 ? stripped : undefined;
}

function opaqueEventID(sessionID, sequence, discriminator = "event") {
  if (!sessionID) return undefined;
  const durableSequence = typeof sequence === "number" || typeof sequence === "string"
    ? String(sequence)
    : randomUUID();
  return createHash("sha256")
    .update("apc.dsh.event.v2\0")
    .update(String(sessionID))
    .update("\0")
    .update(discriminator)
    .update("\0")
    .update(durableSequence)
    .digest("hex");
}

function displayContext(sessionID, role) {
  const message = role === "user"
    ? latestUserMessages.get(sessionID)
    : latestAssistantMessages.get(sessionID);
  return {
    session_title: sessionTitles.get(sessionID),
    message_role: message ? role : undefined,
    message_content: message,
  };
}

function sendEvent(allowlisted) {
  return new Promise((resolve) => {
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      resolve();
    };
    let child;
    const controller = new AbortController();
    const terminalWaiting = deliveryItems.some((item) => isCriticalDelivery(item.event));
    const timeout = setTimeout(
      () => controller.abort(),
      terminalWaiting ? TERMINAL_PRELUDE_TIMEOUT_MS : DELIVERY_TIMEOUT_MS,
    );
    const abortDelivery = () => controller.abort();
    inFlightAbort = abortDelivery;
    try {
      child = spawn(
        CLI_PATH,
        ["agent", "hook", "--source", "dsh", "--event-type", "auto"],
        {
          stdio: ["pipe", "ignore", "ignore"],
          signal: controller.signal,
          windowsHide: true,
        },
      );
    } catch {
      clearTimeout(timeout);
      if (inFlightAbort === abortDelivery) inFlightAbort = undefined;
      finish();
      return;
    }
    const finishDelivery = () => {
      clearTimeout(timeout);
      if (inFlightAbort === abortDelivery) inFlightAbort = undefined;
      finish();
    };
    child.once("error", finishDelivery);
    child.once("close", finishDelivery);
    child.stdin?.once("error", finishDelivery);
    child.stdin?.end(JSON.stringify({
      ...allowlisted,
      contract_version: APC_DSH_CONTRACT_VERSION,
    }));
  });
}

function isCriticalDelivery(event) {
  return event?.type === "turn/end"
    || event?.type === "session/disposed"
    || event?.type === "session.child";
}

function enqueueDelivery(event) {
  if (!event || typeof event !== "object") return;
  if (deliveryItems.length >= MAX_PENDING_DELIVERIES) {
    const expendableIndex = deliveryItems.findIndex((item) => !isCriticalDelivery(item.event));
    if (expendableIndex >= 0) {
      deliveryItems.splice(expendableIndex, 1);
    } else if (!isCriticalDelivery(event)) {
      return;
    } else {
      deliveryItems.shift();
    }
  }
  deliveryItems.push({ event });
  scheduleDrain();
}

function scheduleDrain() {
  if (deliveryWorker) return;
  deliveryWorker = (async () => {
    while (deliveryItems.length > 0) {
      const item = deliveryItems.shift();
      if (!item) continue;
      await sendEvent(item.event);
    }
    deliveryWorker = undefined;
  })().catch(() => {
    deliveryWorker = undefined;
  });
}

function extractAssistantText(message) {
  if (!message || !Array.isArray(message.content)) return undefined;
  const parts = [];
  for (const block of message.content) {
    if (block?.type === "text" && typeof block.text === "string") {
      parts.push(block.text);
    }
  }
  return cleanText(parts.join(""));
}

export function apply(ctx) {
  if (connectorProbe || connectorDiagnostic) {
    enqueueDelivery({
      type: "connector.probe",
      session_id: connectorProbeID ?? `apc-dsh-probe-${randomUUID()}`,
      eventID: opaqueEventID(connectorProbeID ?? "diagnostic", randomUUID(), "probe"),
      diagnostic: true,
    });
  }

  ctx.on("session/event", (session, event) => {
    try {
      if (!session || !event || typeof event !== "object") return;
      const sid = session.id;
      if (!sid) return;

      const header = session.header ?? {};
      const isChild = header.origin === "subagent" || header.parentSession !== undefined;

      if (isChild) {
        if (!childSessions.has(sid)) {
          childSessions.add(sid);
          if (header.parentSession) {
            remember(childParents, sid, header.parentSession);
            for (const [runId, info] of pendingStartRuns.entries()) {
              if (info.id === sid) {
                pendingStartRuns.delete(runId);
                addRunToParentFence(header.parentSession, runId);
              }
            }
          }
          enqueueDelivery({
            type: "session.child",
            session_id: sid,
            eventID: opaqueEventID(sid, event.seq, "session.child"),
          });
        }
        return;
      }

      const type = event.type;
      const data = event.data ?? {};
      const eventID = opaqueEventID(sid, event.seq, type);

      switch (type) {
        case "turn/start": {
          enqueueDelivery({
            type: "turn/start",
            session_id: sid,
            eventID,
            turn_id: typeof data.turn === "number" ? String(data.turn) : undefined,
            ...displayContext(sid, "user"),
          });
          break;
        }
        case "assistant/chunk": {
          const chunk = data.chunk;
          if (chunk?.type === "block-start" && chunk.blockType === "reasoning") {
            enqueueDelivery({
              type: "assistant/chunk",
              session_id: sid,
              eventID,
              turn_id: typeof data.turn === "number" ? String(data.turn) : undefined,
              chunk: { type: "block-start", blockType: "reasoning" },
            });
          }
          break;
        }
        case "assistant/message": {
          const text = extractAssistantText(data.message);
          if (text) {
            remember(latestAssistantMessages, sid, boundString(text, BOUND_MESSAGE_BYTES));
          }
          break;
        }
        case "user/message": {
          const sourceKind = data.message?.source?.kind;
          if (sourceKind === "user") {
            const text = extractAssistantText(data.message);
            if (text) {
              const message = boundString(text, BOUND_MESSAGE_BYTES);
              remember(latestUserMessages, sid, message);
              latestAssistantMessages.delete(sid);
              enqueueDelivery({
                type: "user/message",
                session_id: sid,
                eventID,
                session_title: sessionTitles.get(sid),
                message_role: "user",
                message_content: message,
              });
            }
          }
          break;
        }
        case "session/title": {
          const title = boundString(data.title);
          if (title) {
            remember(sessionTitles, sid, title);
            enqueueDelivery({
              type: "session/title",
              session_id: sid,
              eventID,
              session_title: title,
            });
          }
          break;
        }
        case "plan/mode": {
          if (data.active === true) {
            enqueueDelivery({
              type: "plan/mode",
              session_id: sid,
              eventID,
              active: true,
            });
          }
          break;
        }
        case "todo/write": {
          enqueueDelivery({
            type: "todo/write",
            session_id: sid,
            eventID,
          });
          break;
        }
        case "tool/call": {
          const toolName = boundString(data.name);
          enqueueDelivery({
            type: "tool/call",
            session_id: sid,
            eventID,
            tool_name: toolName,
            turn_id: typeof data.turn === "number" ? String(data.turn) : undefined,
          });
          break;
        }
        case "tool/result": {
          const toolName = boundString(data.name);
          const hasError = data.error && typeof data.error === "object";
          enqueueDelivery({
            type: "tool/result",
            session_id: sid,
            eventID,
            tool_name: toolName,
            turn_id: typeof data.turn === "number" ? String(data.turn) : undefined,
            error: hasError ? { code: boundString(data.error.code) ?? "unknown" } : undefined,
          });
          break;
        }
        case "approval/asked": {
          enqueueDelivery({
            type: "approval/asked",
            session_id: sid,
            eventID,
            tool_name: boundString(data.toolName),
          });
          break;
        }
        case "approval/decided": {
          const outcome = boundString(data.outcome);
          enqueueDelivery({
            type: "approval/decided",
            session_id: sid,
            eventID,
            outcome,
          });
          break;
        }
        case "turn/end": {
          const reason = data.reason ?? {};
          const reasonKind = typeof reason === "object" ? reason.kind : reason;
          const fence = parentFences.get(sid);
          const hasActiveChildren = fence !== undefined && fence.size > 0;

          if (reasonKind === "completed" && hasActiveChildren) {
            pendingCompletedTurns.add(sid);
            enqueueDelivery({
              type: "turn/end",
              session_id: sid,
              eventID,
              turn_id: typeof data.turn === "number" ? String(data.turn) : undefined,
              reason: { kind: "completed" },
              background_active: true,
              ...displayContext(sid, "assistant"),
            });
          } else {
            enqueueDelivery({
              type: "turn/end",
              session_id: sid,
              eventID,
              turn_id: typeof data.turn === "number" ? String(data.turn) : undefined,
              reason: typeof reason === "object"
                ? {
                    kind: boundString(reason.kind),
                    error: reason.error ? { code: boundString(reason.error.code) } : undefined,
                  }
                : { kind: boundString(reason) },
              ...displayContext(sid, "assistant"),
            });
          }
          break;
        }
        default:
          break;
      }
    } catch (err) {
      if (connectorDiagnostic) {
        console.error("[apc-dsh] session/event listener error:", err?.message ?? err);
      }
    }
  });

  ctx.on("subagent/start", (info) => {
    try {
      if (!info || !info.runId) return;
      const runId = info.runId;

      if (info.local === false) {
        if (connectorDiagnostic) {
          console.log("[apc-dsh] remote subagent started outside fence:", runId);
        }
        return;
      }

      let parentId;
      try {
        const childAgent = ctx.agents?.get(info.id);
        parentId = childAgent?.session?.header?.parentSession;
      } catch (_) {}

      if (!parentId && info.id) {
        parentId = childParents.get(info.id);
      }

      if (parentId) {
        addRunToParentFence(parentId, runId);
      } else {
        remember(pendingStartRuns, runId, { id: info.id });
      }
    } catch (err) {
      if (connectorDiagnostic) {
        console.error("[apc-dsh] subagent/start listener error:", err?.message ?? err);
      }
    }
  });

  ctx.on("subagent/end", (info) => {
    try {
      if (!info || !info.runId) return;
      const runId = info.runId;
      removeRunFromAllFences(runId);
    } catch (err) {
      if (connectorDiagnostic) {
        console.error("[apc-dsh] subagent/end listener error:", err?.message ?? err);
      }
    }
  });

  ctx.on("session/disposed", (session) => {
    try {
      const sid = session?.id ?? session;
      if (!sid) return;

      if (childSessions.has(sid)) {
        childSessions.delete(sid);
        const parentId = childParents.get(sid);
        if (parentId) {
          childParents.delete(sid);
          checkFenceDrain(parentId);
        }
        return;
      }

      enqueueDelivery({
        type: "session/disposed",
        session_id: sid,
        eventID: opaqueEventID(sid, "disposed", "session/disposed"),
        session_title: sessionTitles.get(sid),
      });
      parentFences.delete(sid);
      pendingCompletedTurns.delete(sid);
      latestUserMessages.delete(sid);
      latestAssistantMessages.delete(sid);
      sessionTitles.delete(sid);
    } catch (err) {
      if (connectorDiagnostic) {
        console.error("[apc-dsh] session/disposed listener error:", err?.message ?? err);
      }
    }
  });
}

function addRunToParentFence(parentId, runId) {
  let fence = parentFences.get(parentId);
  if (!fence) {
    fence = new Set();
    parentFences.set(parentId, fence);
  }
  fence.add(runId);
}

function removeRunFromAllFences(runId) {
  for (const [parentId, fence] of parentFences.entries()) {
    if (fence.delete(runId)) {
      checkFenceDrain(parentId);
    }
  }
}

function checkFenceDrain(parentId) {
  const fence = parentFences.get(parentId);
  if (fence && fence.size === 0) {
    parentFences.delete(parentId);
    if (pendingCompletedTurns.delete(parentId)) {
      enqueueDelivery({
        type: "turn/end",
        session_id: parentId,
        eventID: opaqueEventID(parentId, randomUUID(), "fence-drained"),
        reason: { kind: "completed" },
        ...displayContext(parentId, "assistant"),
      });
    }
  }
}
