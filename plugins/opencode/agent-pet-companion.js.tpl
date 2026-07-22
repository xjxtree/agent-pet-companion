import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";

const CLI_PATH = __APC_CLI_JSON__;
const APC_OPENCODE_CONTRACT_VERSION = "opencode-v1.18.0-activity-v8";

// OpenCode 1.18 plugin hooks. Agent Pet Companion implements only observation
// hooks; configuration, auth, headers, environment, prompts, and tool payloads
// are intentionally never inspected or modified.
const APC_OPENCODE_PLUGIN_HOOK_INVENTORY = Object.freeze([
  "event",
  "dispose",
  "config",
  "tool",
  "tool.definition",
  "auth",
  "provider",
  "chat.message",
  "chat.params",
  "chat.headers",
  "permission.ask",
  "command.execute.before",
  "tool.execute.before",
  "shell.env",
  "tool.execute.after",
  "experimental.chat.messages.transform",
  "experimental.chat.system.transform",
  "experimental.provider.small_model",
  "experimental.session.compacting",
  "experimental.compaction.autocontinue",
  "experimental.text.complete",
]);

// Union of the standard v1 event bus and the current v2/host lifecycle bus.
// The generic `event` hook receives this surface, but compatibleEvent() only
// serializes the small safe subset needed for pet activity.
const APC_OPENCODE_EVENT_INVENTORY = Object.freeze([
  "server.connected",
  "server.instance.disposed",
  "global.disposed",
  "installation.updated",
  "installation.update-available",
  "project.updated",
  "project.directories.updated",
  "plugin.added",
  "integration.updated",
  "integration.connection.updated",
  "reference.updated",
  "catalog.updated",
  "models-dev.refreshed",
  "lsp.client.diagnostics",
  "lsp.updated",
  "file.edited",
  "file.watcher.updated",
  "message.updated",
  "message.removed",
  "message.part.updated",
  "message.part.delta",
  "message.part.removed",
  "permission.asked",
  "permission.updated",
  "permission.replied",
  "permission.v2.asked",
  "permission.v2.replied",
  "session.status",
  "session.idle",
  "session.compacted",
  "session.created",
  "session.updated",
  "session.deleted",
  "session.diff",
  "session.error",
  "question.asked",
  "question.replied",
  "question.rejected",
  "question.v2.asked",
  "question.v2.replied",
  "question.v2.rejected",
  "todo.updated",
  "command.executed",
  "tui.prompt.append",
  "tui.command.execute",
  "tui.toast.show",
  "tui.session.select",
  "mcp.tools.changed",
  "mcp.browser.open.failed",
  "vcs.branch.updated",
  "workspace.ready",
  "workspace.failed",
  "workspace.status",
  "worktree.ready",
  "worktree.failed",
  "pty.created",
  "pty.updated",
  "pty.exited",
  "pty.deleted",
  "session.next.agent.switched",
  "session.next.model.switched",
  "session.next.prompted",
  "session.next.prompt.admitted",
  "session.next.synthetic",
  "session.next.moved",
  "session.next.context.updated",
  "session.next.revert.staged",
  "session.next.revert.committed",
  "session.next.revert.cleared",
  "session.next.shell.started",
  "session.next.shell.ended",
  "session.next.step.started",
  "session.next.step.ended",
  "session.next.step.failed",
  "session.next.text.started",
  "session.next.text.delta",
  "session.next.text.ended",
  "session.next.reasoning.started",
  "session.next.reasoning.delta",
  "session.next.reasoning.ended",
  "session.next.tool.input.started",
  "session.next.tool.input.delta",
  "session.next.tool.input.ended",
  "session.next.tool.called",
  "session.next.tool.progress",
  "session.next.tool.success",
  "session.next.tool.failed",
  "session.next.retried",
  "session.next.compaction.started",
  "session.next.compaction.delta",
  "session.next.compaction.ended",
]);

const connectorDiagnostic = process.env.APC_CONNECTOR_DIAGNOSTIC === "1"
  || process.env.APC_CONNECTOR_PROBE === "1";
const connectorProbe = process.env.APC_CONNECTOR_PROBE === "1";
const connectorProbeID = /^apc-probe-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  .test(process.env.APC_CONNECTOR_PROBE_ID ?? "")
  ? process.env.APC_CONNECTOR_PROBE_ID
  : undefined;
const sessions = new Map();
const messageRoles = new Map();
const messageTexts = new Map();
const messageTextParts = new Map();
const messageSessions = new Map();
const messageDiagnostics = new Map();
const completedAssistantMessages = new Map();
const latestAssistantMessages = new Map();
const emittedAssistantMessages = new Map();
const emittedAssistantContentBySession = new Map();
const toolNames = new Map();
const terminalStates = new Map();
const stepStates = new Map();
const activeStepKeys = new Map();
const pendingStepCompletions = new Map();
const MAX_TRACKED_ITEMS = 256;
const MAX_PENDING_DELIVERIES = 96;
const DELIVERY_TIMEOUT_MS = 3000;
const TERMINAL_PRELUDE_TIMEOUT_MS = 500;
const STEP_COMPLETION_DEBOUNCE_MS = 75;
const DISPOSE_DRAIN_TIMEOUT_MS = 4000;
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

function diagnostic(...values) {
  return connectorDiagnostic || values.some((value) => value === true);
}

function opaqueIdentity(value) {
  if (typeof value !== "string" || !value.trim()) return undefined;
  return createHash("sha256")
    .update("apc.opencode.opaque.v1\0")
    .update(value.trim())
    .digest("hex");
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
    const terminalWaiting = deliveryItems.some((item) => isTerminalDelivery(item.event));
    const timeout = setTimeout(
      () => controller.abort(),
      terminalWaiting ? TERMINAL_PRELUDE_TIMEOUT_MS : DELIVERY_TIMEOUT_MS,
    );
    const abortDelivery = () => controller.abort();
    inFlightAbort = abortDelivery;
    try {
      child = spawn(
        CLI_PATH,
        ["agent", "hook", "--source", "opencode", "--event-type", "auto"],
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
      contract_version: APC_OPENCODE_CONTRACT_VERSION,
    }));
  });
}

function deliverySessionID(event) {
  return sessionID(event?.properties ?? event?.input ?? {});
}

function isTerminalDelivery(event) {
  return event?.type === "session.error"
    || event?.type === "session.deleted"
    || event?.type === "session.idle"
    || event?.type === "session.next.step.failed"
    || (event?.type === "session.status" && event?.properties?.status === "idle")
    || (event?.type === "session.next.step.ended"
      && ["completed", "session_failure"].includes(event?.outcome));
}

function isActiveChurn(event) {
  return (event?.type === "session.status"
      && ["busy", "retry"].includes(event?.properties?.status))
    || event?.type === "session.plan.updated"
    || event?.type === "session.compaction.started"
    || event?.type === "session.compaction.ended"
    || (event?.type === "session.next.step.ended" && event?.outcome === "continued");
}

function deliveryPriority(event) {
  if (event?.type === "session.error" || event?.type === "session.next.step.failed"
    || (event?.type === "session.next.step.ended" && event?.outcome === "session_failure")) {
    return 110;
  }
  if (isTerminalDelivery(event)) return 100;
  if (["message.user", "session.next.prompt.admitted"].includes(event?.type)) return 95;
  if ([
    "tool.execute.before", "tool.execute.after",
    "command.execute.before", "command.execute.after",
  ].includes(event?.type)) return 80;
  if (event?.type === "message.assistant") return 90;
  if (isActiveChurn(event)) return 10;
  return 50;
}

function isUserActivationDelivery(event) {
  return event?.type === "message.user" || event?.type === "session.next.prompt.admitted";
}

function compactQueuedSessionForTerminal(id) {
  const sessionItems = deliveryItems
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => deliverySessionID(item.event) === id && !isTerminalDelivery(item.event));
  const lastIndexFor = (predicate) => sessionItems.findLast(({ item }) => predicate(item.event))?.index;
  const keep = new Set([
    lastIndexFor(isUserActivationDelivery),
    lastIndexFor((event) => ["tool.execute.before", "command.execute.before"].includes(event?.type)),
    lastIndexFor((event) => ["tool.execute.after", "command.execute.after"].includes(event?.type)),
    lastIndexFor((event) => event?.type === "message.assistant"),
  ].filter((index) => index !== undefined));
  for (let index = deliveryItems.length - 1; index >= 0; index -= 1) {
    const event = deliveryItems[index].event;
    if (deliverySessionID(event) === id && !isTerminalDelivery(event) && !keep.has(index)) {
      removeQueuedItem(index);
    }
  }
}

function deliveryCoalesceKey(event) {
  const id = deliverySessionID(event);
  if (!id) return undefined;
  if (isActiveChurn(event)) return `${id}:churn:${event.type}:${event?.properties?.status ?? event?.outcome ?? ""}`;
  if (event?.type === "message.assistant") return `${id}:assistant`;
  return undefined;
}

function removeQueuedItem(index) {
  const [item] = deliveryItems.splice(index, 1);
  item?.resolve();
}

function ensureDeliveryWorker() {
  if (deliveryWorker) return deliveryWorker;
  deliveryWorker = (async () => {
    while (deliveryItems.length > 0) {
      const item = deliveryItems.splice(nextDeliveryIndex(), 1)[0];
      try {
        await sendEvent(item.event);
      } catch {
        // Connector delivery is best-effort and never blocks the Agent host.
      } finally {
        item.resolve();
      }
    }
  })().finally(() => {
    deliveryWorker = undefined;
    if (deliveryItems.length > 0) ensureDeliveryWorker();
  });
  return deliveryWorker;
}

function nextDeliveryIndex() {
  let terminalIndex = -1;
  let terminalPriority = -1;
  for (let index = 0; index < deliveryItems.length; index += 1) {
    const event = deliveryItems[index].event;
    const priority = deliveryPriority(event);
    if (isTerminalDelivery(event) && priority > terminalPriority) {
      terminalPriority = priority;
      terminalIndex = index;
    }
  }
  if (terminalIndex < 0) return 0;
  const terminalSession = deliverySessionID(deliveryItems[terminalIndex].event);
  const preludeIndex = deliveryItems.findIndex((item, index) => (
    index < terminalIndex
      && deliverySessionID(item.event) === terminalSession
      && !isTerminalDelivery(item.event)
  ));
  return preludeIndex >= 0 ? preludeIndex : terminalIndex;
}

function forward(allowlisted, options = {}) {
  const id = deliverySessionID(allowlisted);
  if (id
    && options.allowTerminalPrelude !== true
    && ["failed", "idle", "deleted"].includes(terminalStates.get(id))
    && isPassiveCompletionTail(allowlisted)) {
    return Promise.resolve();
  }
  const key = deliveryCoalesceKey(allowlisted);
  if (id && isUserActivationDelivery(allowlisted)) {
    for (let index = deliveryItems.length - 1; index >= 0; index -= 1) {
      if (deliverySessionID(deliveryItems[index].event) === id) {
        removeQueuedItem(index);
      }
    }
  } else if (id && isExplicitActivation(allowlisted)) {
    for (let index = deliveryItems.length - 1; index >= 0; index -= 1) {
      const queued = deliveryItems[index].event;
      if (deliverySessionID(queued) === id
        && (isTerminalDelivery(queued)
          || isPassiveCompletionTail(queued)
          || isActiveChurn(queued))) {
        removeQueuedItem(index);
      }
    }
  }
  if (key) {
    const existing = deliveryItems.find((item) => item.key === key);
    if (existing) {
      existing.event = allowlisted;
      return existing.promise;
    }
  }

  if (id && isTerminalDelivery(allowlisted)) {
    if (deliveryPriority(allowlisted) >= 110) {
      for (let index = deliveryItems.length - 1; index >= 0; index -= 1) {
        const queued = deliveryItems[index].event;
        if (deliverySessionID(queued) === id
          && isTerminalDelivery(queued)
          && queued?.type !== "session.deleted"
          && deliveryPriority(queued) < 110) {
          removeQueuedItem(index);
        }
      }
    }
    compactQueuedSessionForTerminal(id);
    const pendingAbort = inFlightAbort;
    if (pendingAbort) {
      setTimeout(() => {
        if (inFlightAbort === pendingAbort) pendingAbort();
      }, TERMINAL_PRELUDE_TIMEOUT_MS);
    }
  }

  if (deliveryItems.length >= MAX_PENDING_DELIVERIES) {
    const priority = deliveryPriority(allowlisted);
    const evictable = deliveryItems.findIndex((item) => isActiveChurn(item.event));
    if (evictable >= 0) {
      removeQueuedItem(evictable);
    } else {
      let lowerPriorityIndex = -1;
      let lowerPriority = priority;
      for (let index = 0; index < deliveryItems.length; index += 1) {
        if (isTerminalDelivery(allowlisted)
          && deliverySessionID(deliveryItems[index].event) === id) {
          continue;
        }
        const queuedPriority = deliveryPriority(deliveryItems[index].event);
        if (queuedPriority < lowerPriority) {
          lowerPriority = queuedPriority;
          lowerPriorityIndex = index;
        }
      }
      if (lowerPriorityIndex < 0) return Promise.resolve();
      removeQueuedItem(lowerPriorityIndex);
    }
  }

  let resolveDelivery;
  const promise = new Promise((resolve) => { resolveDelivery = resolve; });
  deliveryItems.push({ event: allowlisted, key, promise, resolve: resolveDelivery });
  ensureDeliveryWorker();
  return promise;
}

function scheduleStepCompletion(id, event) {
  cancelStepCompletion(id);
  let resolvePending;
  const promise = new Promise((resolve) => { resolvePending = resolve; });
  const timer = setTimeout(() => {
    pendingStepCompletions.delete(id);
    forward(event);
    resolvePending();
  }, STEP_COMPLETION_DEBOUNCE_MS);
  pendingStepCompletions.set(id, { timer, promise, resolve: resolvePending });
  return promise;
}

async function drainDeliveriesForDispose() {
  let timeout;
  const drained = (async () => {
    await Promise.all([...pendingStepCompletions.values()].map((pending) => pending.promise));
    while (deliveryWorker || deliveryItems.length > 0) {
      await (deliveryWorker ?? ensureDeliveryWorker());
    }
  })();
  const deadline = new Promise((resolve) => {
    timeout = setTimeout(() => {
      inFlightAbort?.();
      while (deliveryItems.length > 0) removeQueuedItem(deliveryItems.length - 1);
      resolve();
    }, DISPOSE_DRAIN_TIMEOUT_MS);
  });
  await Promise.race([drained, deadline]);
  clearTimeout(timeout);
}

function sessionID(properties) {
  const info = properties?.info;
  return properties?.sessionID
    ?? info?.sessionID
    ?? properties?.part?.sessionID
    ?? (info?.role === undefined ? info?.id : undefined);
}

function cancelStepCompletion(id) {
  const pending = id ? pendingStepCompletions.get(id) : undefined;
  if (!pending) return;
  clearTimeout(pending.timer);
  pendingStepCompletions.delete(id);
  pending.resolve();
}

function clearStepTracking(id) {
  if (!id) return;
  cancelStepCompletion(id);
  const key = activeStepKeys.get(id);
  if (key) stepStates.delete(key);
  activeStepKeys.delete(id);
}

function clearPendingAssistant(id, clearVisibleContent = false) {
  if (!id) return;
  latestAssistantMessages.delete(id);
  if (clearVisibleContent) emittedAssistantContentBySession.delete(id);
}

function markSessionActive(id) {
  if (!id) return;
  cancelStepCompletion(id);
  terminalStates.delete(id);
  clearPendingAssistant(id, true);
}

function isExplicitActivation(event) {
  const type = event?.type;
  return type === "message.user"
    || type === "session.next.prompt.admitted"
    || type === "tool.execute.before"
    || type === "command.execute.before"
    || type === "session.compaction.started"
    || type === "permission.asked"
    || type === "permission.updated"
    || type === "permission.v2.asked"
    || type === "question.asked"
    || type === "question.v2.asked"
    || (type === "session.status"
      && ["busy", "retry"].includes(event?.properties?.status));
}

function isPassiveCompletionTail(event) {
  return event?.type === "message.assistant"
    || event?.type === "tool.execute.after"
    || event?.type === "command.execute.after"
    || event?.type === "session.compaction.ended"
    || event?.type === "session.plan.updated"
    || event?.type === "session.created"
    || event?.type === "permission.replied"
    || event?.type === "permission.v2.replied"
    || event?.type === "question.replied"
    || event?.type === "question.rejected"
    || event?.type === "question.v2.replied"
    || event?.type === "question.v2.rejected";
}

function sessionEventDisposition(event) {
  const type = event?.type;
  const id = sessionID(event?.properties ?? event?.input ?? {});
  const isIdle = type === "session.idle"
    || (type === "session.status" && event?.properties?.status === "idle");
  if (!id) {
    return "drop";
  }

  if (type === "session.error"
    || type === "session.next.step.failed"
    || (type === "session.next.step.ended" && event?.outcome === "session_failure")) {
    clearStepTracking(id);
    clearPendingAssistant(id);
    remember(terminalStates, id, "failed");
    return "forward";
  }
  if (isIdle) {
    if (["failed", "idle"].includes(terminalStates.get(id))) return "drop";
    if (pendingStepCompletions.has(id)) return "drop";
    clearStepTracking(id);
    remember(terminalStates, id, "idle");
    return "idle";
  }
  if (type === "session.deleted") {
    clearStepTracking(id);
    clearPendingAssistant(id);
    if (terminalStates.get(id) !== "failed") remember(terminalStates, id, "deleted");
    return "forward";
  }
  if (type === "session.next.step.ended") {
    if (event?.outcome === "continued") {
      return terminalStates.get(id) === "failed" ? "drop" : "forward";
    }
    if (event?.outcome === "completed") {
      if (["failed", "idle"].includes(terminalStates.get(id))) return "drop";
      remember(terminalStates, id, "idle");
      return "debounce";
    }
  }
  if (terminalStates.get(id) === "failed" && isPassiveCompletionTail(event)) return "drop";
  if (isExplicitActivation(event)) markSessionActive(id);
  return "forward";
}

function rememberSession(properties) {
  const id = sessionID(properties);
  const title = properties?.info?.title;
  if (id && typeof title === "string" && title.trim()) {
    remember(sessions, id, title.trim());
  }
  return id;
}

function toolKey(session, callID) {
  return session && callID ? `${session}:${callID}` : undefined;
}

function rememberTool(session, callID, name) {
  if (typeof name !== "string" || !name.trim()) return;
  remember(toolNames, toolKey(session, callID), name.trim());
}

function knownTool(session, callID, fallback) {
  return fallback ?? toolNames.get(toolKey(session, callID));
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

function assistantMessageEvent(id, messageID, content) {
  if (!id || !messageID || !content) return undefined;
  if (emittedAssistantMessages.get(messageID) === content) return undefined;
  if (emittedAssistantContentBySession.get(id) === content) return undefined;
  remember(emittedAssistantMessages, messageID, content);
  remember(emittedAssistantContentBySession, id, content);
  return {
    type: "message.assistant",
    properties: {
      sessionID: id,
      session_title: sessions.get(id),
      message_content: content,
      diagnostic: diagnostic(messageDiagnostics.get(messageID)),
    },
  };
}

function rememberAssistantMessage(id, messageID) {
  if (!id || !messageID) return;
  remember(messageSessions, messageID, id);
  remember(latestAssistantMessages, id, messageID);
}

function pendingAssistantEvent(id) {
  const messageID = latestAssistantMessages.get(id);
  if (!messageID) return undefined;
  return assistantMessageEvent(id, messageID, messageTexts.get(messageID));
}

function safeResponse(properties) {
  const response = properties?.response ?? properties?.reply;
  return ["once", "always", "allow", "deny", "reject"].includes(response)
    ? response
    : undefined;
}

function statusEvent(id, status, properties) {
  return {
    type: "session.status",
    properties: {
      sessionID: id,
      session_title: sessions.get(id),
      status,
      diagnostic: diagnostic(properties?.diagnostic, properties?.info?.diagnostic),
    },
  };
}

function stepFinish(properties) {
  const finish = properties?.finish;
  return typeof finish === "string" ? finish : undefined;
}

function stepKey(id, properties) {
  const assistantMessageID = properties?.assistantMessageID;
  return assistantMessageID ? `${id}:${assistantMessageID}` : undefined;
}

function compatibleStepEnded(properties, id) {
  const finish = stepFinish(properties);
  const declaredKey = stepKey(id, properties);
  const activeKey = activeStepKeys.get(id);
  if (declaredKey && activeKey && declaredKey !== activeKey) return undefined;
  const key = declaredKey ?? activeKey;
  const state = key ? stepStates.get(key) : undefined;
  if (key) stepStates.delete(key);
  if (!declaredKey || declaredKey === activeKey) activeStepKeys.delete(id);
  let outcome;
  if (["content-filter", "error"].includes(finish)) {
    outcome = "session_failure";
  } else if (state?.hasLocalToolCall === true) {
    outcome = "continued";
  } else if (["tool-calls", "tool_calls", "tool_use"].includes(finish)) {
    // A local tool call continues the step loop. When the plugin was loaded
    // mid-step and has no call evidence, staying active is the safe choice.
    outcome = state?.seenToolCall === true && state?.hasLocalToolCall === false
      ? "completed"
      : "continued";
  } else if (["stop", "length", "other"].includes(finish)) {
    outcome = "completed";
  } else if (finish === "unknown") {
    outcome = "completed";
  } else {
    return undefined;
  }
  return {
    type: "session.next.step.ended",
    properties: {
      sessionID: id,
      session_title: sessions.get(id),
      finish,
      diagnostic: diagnostic(properties?.diagnostic),
    },
    outcome,
  };
}

function rememberStepToolCall(id, properties) {
  if (!id) return;
  const declaredKey = stepKey(id, properties);
  const key = declaredKey ?? activeStepKeys.get(id);
  if (!key || key !== activeStepKeys.get(id)) return;
  const state = stepStates.get(key) ?? { seenToolCall: false, hasLocalToolCall: false };
  state.seenToolCall = true;
  const providerExecuted = properties?.providerExecuted ?? properties?.provider?.executed;
  if (providerExecuted !== true) state.hasLocalToolCall = true;
  remember(stepStates, key, state);
}

function toolEvent(type, id, callID, name, properties, isError = false) {
  const tool = knownTool(id, callID, name);
  rememberTool(id, callID, tool);
  return {
    type,
    input: {
      tool,
      sessionID: id,
      callID: opaqueIdentity(callID),
    },
    outcome: isError ? "tool_failure" : type === "tool.execute.before" ? "started" : "completed",
    is_error: isError,
    diagnostic: diagnostic(properties?.diagnostic, properties?.info?.diagnostic),
  };
}

function compatibleNextEvent(type, properties, id) {
  if (!id) return undefined;
  switch (type) {
    case "session.next.prompt.admitted":
      return {
        type,
        properties: {
          sessionID: id,
          session_title: sessions.get(id),
          diagnostic: diagnostic(properties?.diagnostic),
        },
        turn_id: opaqueIdentity(properties?.messageID),
      };
    case "session.next.step.started":
      clearStepTracking(id);
      {
        const key = stepKey(id, properties) ?? `${id}:current`;
        remember(activeStepKeys, id, key);
        remember(stepStates, key, { seenToolCall: false, hasLocalToolCall: false });
      }
      return statusEvent(id, "busy", properties);
    case "session.next.retried":
      return statusEvent(id, "retry", properties);
    case "session.next.step.ended":
      return compatibleStepEnded(properties, id);
    case "session.next.step.failed":
      {
        const declaredKey = stepKey(id, properties);
        const activeKey = activeStepKeys.get(id);
        if (declaredKey && activeKey && declaredKey !== activeKey) return undefined;
      }
      clearStepTracking(id);
      return {
        type,
        properties: {
          sessionID: id,
          session_title: sessions.get(id),
          diagnostic: diagnostic(properties?.diagnostic),
        },
        outcome: "session_failure",
      };
    case "session.next.text.ended":
      return assistantMessageEvent(
        id,
        properties?.assistantMessageID
          ?? properties?.messageID
          ?? `${id}:session.next.text.ended`,
        typeof properties?.text === "string" ? properties.text.trim() : undefined,
      );
    case "session.next.shell.started":
      return toolEvent("tool.execute.before", id, properties?.callID, "shell", properties);
    case "session.next.shell.ended":
      return toolEvent("tool.execute.after", id, properties?.callID, "shell", properties);
    case "session.next.tool.input.started":
      return toolEvent("tool.execute.before", id, properties?.callID, properties?.name, properties);
    case "session.next.tool.called":
      rememberStepToolCall(id, properties);
      return toolEvent("tool.execute.before", id, properties?.callID, properties?.tool, properties);
    case "session.next.tool.success":
      return toolEvent("tool.execute.after", id, properties?.callID, undefined, properties);
    case "session.next.tool.failed":
      return toolEvent("tool.execute.after", id, properties?.callID, undefined, properties, true);
    case "session.next.compaction.started":
      return {
        type: "session.compaction.started",
        properties: {
          sessionID: id,
          diagnostic: diagnostic(properties?.diagnostic),
        },
      };
    case "session.next.compaction.ended":
      return {
        type: "session.compaction.ended",
        properties: {
          sessionID: id,
          diagnostic: diagnostic(properties?.diagnostic),
        },
      };
    default:
      // Prompt/synthetic metadata, token deltas, reasoning text, tool
      // input/progress/output, model data, and compaction text are
      // intentionally not serialized or disguised as a busy status.
      return undefined;
  }
}

function compatibleEvent(event) {
  const type = event?.type;
  const properties = event?.properties ?? {};
  const id = rememberSession(properties);

  if (typeof type === "string" && type.startsWith("session.next.")) {
    return compatibleNextEvent(type, properties, id);
  }
  if (type === "session.updated") return undefined;
  if (type === "message.updated") {
    const info = properties?.info ?? {};
    const messageID = info?.id;
    if (messageID && typeof info?.role === "string") remember(messageRoles, messageID, info.role);
    if (messageID && diagnostic(info?.diagnostic)) remember(messageDiagnostics, messageID, true);
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
    if (diagnostic(properties?.diagnostic, part?.diagnostic)) {
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
  if (type === "session.compacted") {
    if (!id) return undefined;
    return {
      type: "session.compaction.ended",
      properties: { sessionID: id, diagnostic: diagnostic(properties?.diagnostic) },
    };
  }
  if (type === "todo.updated") {
    if (!id) return undefined;
    return {
      type: "session.plan.updated",
      properties: { sessionID: id, diagnostic: diagnostic(properties?.diagnostic) },
    };
  }
  if (type === "command.executed") {
    if (!id) return undefined;
    return {
      type: "command.execute.after",
      input: { sessionID: id, tool: "command" },
      outcome: "completed",
      diagnostic: diagnostic(properties?.diagnostic),
    };
  }

  // Host/global disposal events intentionally stay outside this session-safe
  // allowlist: they carry no session identity and must not fan out synthetic
  // closes. OpenCode's session.deleted edge is forwarded for its one session.
  if (![
    "session.created", "session.deleted", "session.status", "session.idle", "session.error",
    "permission.asked", "permission.updated", "permission.replied",
    "permission.v2.asked", "permission.v2.replied",
    "question.asked", "question.replied", "question.rejected",
    "question.v2.asked", "question.v2.replied", "question.v2.rejected",
  ].includes(type)) {
    return undefined;
  }
  if (!id) return undefined;
  return {
    type,
    properties: {
      sessionID: id,
      session_title: sessions.get(id),
      status: properties?.status?.type
        ?? (typeof properties?.status === "string" ? properties.status : undefined),
      response: safeResponse(properties),
      diagnostic: diagnostic(properties?.diagnostic, properties?.info?.diagnostic),
    },
  };
}

export const AgentPetCompanion = async () => {
  const hooks = {
    event: async ({ event }) => {
      const allowlisted = compatibleEvent(event);
      if (!allowlisted) return;
      const normalized = {
        ...allowlisted,
        eventID: opaqueIdentity(event?.id),
      };
      const disposition = sessionEventDisposition(normalized);
      if (disposition === "drop") return;
      const id = deliverySessionID(normalized);
      if (disposition === "debounce") {
        await scheduleStepCompletion(id, normalized);
        return;
      }
      if (disposition === "idle") {
        // OpenCode's generic event hook is fire-and-forget. Enqueue both
        // records synchronously before the first await so completion cannot
        // disappear when the host advances immediately after this callback.
        const deliveries = [];
        const finalMessage = pendingAssistantEvent(id);
        if (finalMessage) deliveries.push(forward(finalMessage, { allowTerminalPrelude: true }));
        deliveries.push(forward(normalized));
        await Promise.all(deliveries);
        return;
      }
      await forward(normalized);
    },

    dispose: async () => {
      await drainDeliveriesForDispose();
    },

    "chat.message": async (input, output) => {
      const content = textParts(output?.parts);
      if (!input?.sessionID || !content) return;
      markSessionActive(input?.sessionID);
      await forward({
        type: "message.user",
        turn_id: opaqueIdentity(input?.messageID),
        properties: {
          sessionID: input?.sessionID,
          session_title: sessions.get(input?.sessionID),
          message_content: content,
          diagnostic: diagnostic(input?.diagnostic),
        },
      });
    },

    "permission.ask": async (input, output) => {
      if (!input?.sessionID) return;
      const response = ["allow", "deny"].includes(output?.status) ? output.status : undefined;
      markSessionActive(input?.sessionID);
      await forward({
        type: response ? "permission.replied" : "permission.asked",
        properties: {
          sessionID: input?.sessionID,
          response,
          diagnostic: diagnostic(input?.diagnostic),
        },
      });
    },

    "command.execute.before": async (input) => {
      if (!input?.sessionID) return;
      markSessionActive(input?.sessionID);
      await forward({
        type: "command.execute.before",
        input: { sessionID: input?.sessionID, tool: "command" },
        outcome: "started",
        diagnostic: diagnostic(input?.diagnostic),
      });
    },

    "tool.execute.before": async (input) => {
      if (!input?.sessionID) return;
      markSessionActive(input?.sessionID);
      if (activeStepKeys.has(input.sessionID)) {
        rememberStepToolCall(input.sessionID, { providerExecuted: false });
      }
      rememberTool(input?.sessionID, input?.callID, input?.tool);
      await forward(toolEvent(
        "tool.execute.before",
        input?.sessionID,
        input?.callID,
        input?.tool,
        input,
      ));
    },

    "tool.execute.after": async (input) => {
      if (!input?.sessionID) return;
      await forward(toolEvent(
        "tool.execute.after",
        input?.sessionID,
        input?.callID,
        input?.tool,
        input,
      ));
    },

    "experimental.session.compacting": async (input) => {
      if (!input?.sessionID) return;
      markSessionActive(input?.sessionID);
      await forward({
        type: "session.compaction.started",
        properties: {
          sessionID: input?.sessionID,
          diagnostic: diagnostic(input?.diagnostic),
        },
      });
    },

    "experimental.text.complete": async (input, output) => {
      if (!input?.sessionID || typeof output?.text !== "string" || !output.text.trim()) return;
      const message = assistantMessageEvent(
        input.sessionID,
        input?.messageID ?? `${input.sessionID}:${input?.partID ?? "experimental.text.complete"}`,
        output.text.trim(),
      );
      if (message) await forward(message);
    },
  };

  if (connectorProbe) {
    await forward({
      type: "connector.probe",
      properties: {
        sessionID: connectorProbeID ?? `apc-opencode-probe-${randomUUID()}`,
        diagnostic: true,
      },
    });
  }
  return hooks;
};
