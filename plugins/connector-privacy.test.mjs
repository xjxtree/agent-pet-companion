import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { createRequire, syncBuiltinESMExports } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");

async function importTemplate(relativePath, cacheKey = "default", testExports = []) {
  let source = (await readFile(new URL(relativePath, import.meta.url), "utf8"))
    .replace("__APC_CLI_JSON__", JSON.stringify("/unused/petcore-cli"));
  if (testExports.length > 0) {
    source += `\nexport { ${testExports.join(", ")} };\n`;
  }
  const encoded = Buffer.from(source).toString("base64");
  return import(`data:text/javascript;base64,${encoded}#${cacheKey}`);
}

test("Pi and OpenCode connectors expose audited events without leaking raw payloads", async () => {
  const captured = [];
  const originalSpawn = childProcess.spawn;
  const originalDiagnostic = process.env.APC_CONNECTOR_DIAGNOSTIC;
  const originalProbe = process.env.APC_CONNECTOR_PROBE;
  const originalProbeID = process.env.APC_CONNECTOR_PROBE_ID;
  let spawnCloseDelayMs = 0;

  childProcess.spawn = (_command, args, options = {}) => {
    const child = new EventEmitter();
    const stdin = new EventEmitter();
    let closeTimer;
    stdin.end = (data) => {
      const sourceIndex = args.indexOf("--source");
      captured.push({
        source: sourceIndex >= 0 ? args[sourceIndex + 1] : undefined,
        payload: JSON.parse(String(data)),
      });
      if (spawnCloseDelayMs > 0) {
        closeTimer = setTimeout(() => child.emit("close", 0), spawnCloseDelayMs);
      } else {
        queueMicrotask(() => child.emit("close", 0));
      }
    };
    options.signal?.addEventListener("abort", () => {
      clearTimeout(closeTimer);
      queueMicrotask(() => child.emit("error", new Error("aborted")));
      setTimeout(() => child.emit("close", 1), 5);
    }, { once: true });
    child.stdin = stdin;
    return child;
  };
  syncBuiltinESMExports();
  process.env.APC_CONNECTOR_DIAGNOSTIC = "1";
  delete process.env.APC_CONNECTOR_PROBE;

  try {
    const pi = await importTemplate("./pi/agent-pet-companion.ts.tpl");
    assert.equal(pi.APC_PI_CONTRACT_VERSION, "pi-extension-0.80.10-activity-v7");
    assert.equal(pi.APC_PI_EVENT_INVENTORY.length, 33);

    const piHandlers = new Map();
    pi.default({ on: (name, handler) => piHandlers.set(name, handler) });
    assert.deepEqual(
      new Set(piHandlers.keys()),
      new Set(pi.APC_PI_EVENT_INVENTORY),
      "every Pi 0.80.10 ExtensionAPI event must be registered",
    );
    assert.deepEqual(
      await piHandlers.get("project_trust")(
        { type: "project_trust", cwd: "/secret/project" },
        { mode: "rpc" },
      ),
      { trusted: "undecided" },
    );

    const piContext = {
      sessionManager: {
        getSessionId: () => "pi-session",
        getSessionName: () => "Visible Pi session",
      },
      cwd: "/secret/project",
    };
    await piHandlers.get("context")(
      { type: "context", messages: [{ content: "secret-context" }] },
      piContext,
    );
    await piHandlers.get("before_provider_headers")(
      { type: "before_provider_headers", headers: { authorization: "secret-header" } },
      piContext,
    );
    await piHandlers.get("message_update")(
      { type: "message_update", assistantMessageEvent: { delta: "secret-reasoning" } },
      piContext,
    );
    await piHandlers.get("tool_execution_update")(
      { type: "tool_execution_update", partialResult: "secret-partial-output" },
      piContext,
    );
    await piHandlers.get("input")(
      { type: "input", text: "Visible Pi prompt" },
      piContext,
    );
    await piHandlers.get("before_agent_start")(
      {
        type: "before_agent_start",
        prompt: "Visible Pi prompt",
        systemPrompt: "secret-system-prompt",
      },
      piContext,
    );
    await piHandlers.get("tool_call")(
      {
        type: "tool_call",
        toolName: "bash",
        toolCallId: "opaque-pi-call",
        input: { command: "TOKEN=secret-command" },
      },
      piContext,
    );
    await piHandlers.get("tool_execution_end")(
      {
        type: "tool_execution_end",
        toolName: "bash",
        toolCallId: "opaque-pi-call",
        result: "secret-tool-output",
        isError: true,
      },
      piContext,
    );
    const beforeAgentEnd = captured.length;
    await piHandlers.get("agent_end")(
      {
        type: "agent_end",
        messages: [
          { role: "toolResult", content: "secret-agent-tool-result" },
          { role: "assistant", content: [{ type: "text", text: "Visible Pi answer" }] },
        ],
      },
      piContext,
    );
    assert.equal(captured.length, beforeAgentEnd, "Pi agent_end must not be terminal or forwarded");
    await piHandlers.get("agent_settled")({ type: "agent_settled" }, piContext);

    const piPayloads = captured.filter((item) => item.source === "pi").map((item) => item.payload);
    const serializedPi = JSON.stringify(piPayloads);
    for (const secret of [
      "secret-context",
      "secret-header",
      "secret-reasoning",
      "secret-partial-output",
      "secret-system-prompt",
      "TOKEN=secret-command",
      "secret-tool-output",
      "secret-agent-tool-result",
      "/secret/project",
    ]) {
      assert.equal(serializedPi.includes(secret), false, `Pi leaked ${secret}`);
    }
    assert.ok(piPayloads.every((payload) => payload.diagnostic === true));
    assert.equal(piPayloads.at(-1).type, "agent_settled");
    assert.equal(piPayloads.at(-1).message_content, "Visible Pi answer");

    const productionOpenCode = await importTemplate(
      "./opencode/agent-pet-companion.js.tpl",
      "production-exports",
    );
    assert.deepEqual(
      Object.keys(productionOpenCode),
      ["AgentPetCompanion"],
      "OpenCode treats every named export as a Plugin factory",
    );

    const opencode = await importTemplate(
      "./opencode/agent-pet-companion.js.tpl",
      "test-inventory-exports",
      [
        "APC_OPENCODE_CONTRACT_VERSION",
        "APC_OPENCODE_PLUGIN_HOOK_INVENTORY",
        "APC_OPENCODE_EVENT_INVENTORY",
      ],
    );
    assert.equal(opencode.APC_OPENCODE_CONTRACT_VERSION, "opencode-v1.18.0-activity-v8");
    assert.equal(opencode.APC_OPENCODE_PLUGIN_HOOK_INVENTORY.length, 21);
    assert.ok(opencode.APC_OPENCODE_PLUGIN_HOOK_INVENTORY.includes("tool.definition"));
    assert.ok(opencode.APC_OPENCODE_PLUGIN_HOOK_INVENTORY.includes("dispose"));
    assert.ok(opencode.APC_OPENCODE_PLUGIN_HOOK_INVENTORY.includes("provider"));
    assert.equal(opencode.APC_OPENCODE_EVENT_INVENTORY.length, 91);
    for (const eventName of [
      "permission.asked",
      "permission.v2.asked",
      "question.v2.replied",
      "catalog.updated",
      "session.compacted",
      "session.next.prompt.admitted",
      "session.next.reasoning.delta",
      "session.next.tool.input.delta",
      "session.next.tool.failed",
      "session.next.compaction.ended",
    ]) {
      assert.ok(opencode.APC_OPENCODE_EVENT_INVENTORY.includes(eventName));
    }
    assert.equal(opencode.APC_OPENCODE_EVENT_INVENTORY.includes("catalog.model.updated"), false);

    const hooks = await opencode.AgentPetCompanion({
      directory: "/secret/project",
      worktree: "/secret/worktree",
    });
    const expectedOpenCodeHooks = [
      "event",
      "dispose",
      "chat.message",
      "permission.ask",
      "command.execute.before",
      "tool.execute.before",
      "tool.execute.after",
      "experimental.session.compacting",
      "experimental.text.complete",
    ];
    for (const hookName of expectedOpenCodeHooks) {
      assert.equal(typeof hooks[hookName], "function", `OpenCode ${hookName} hook missing`);
    }
    assert.deepEqual(new Set(Object.keys(hooks)), new Set(expectedOpenCodeHooks));
    assert.equal(hooks["tool.definition"], undefined, "tool.definition must remain unregistered");

    await hooks.event({
      event: {
        type: "permission.asked",
        properties: {
          sessionID: "opencode-session",
          patterns: ["secret-permission-pattern"],
          metadata: { token: "secret-permission-metadata" },
        },
      },
    });
    await hooks.event({
      event: {
        id: "secret-v2-permission-event-id",
        type: "permission.v2.asked",
        properties: {
          sessionID: "opencode-session",
          permission: "secret-permission-name",
          resources: ["secret-permission-resource"],
        },
      },
    });
    await hooks.event({
      event: {
        id: "secret-v2-permission-reply-event-id",
        type: "permission.v2.replied",
        properties: {
          sessionID: "opencode-session",
          reply: "once",
          resources: ["secret-replied-resource"],
        },
      },
    });
    await hooks.event({
      event: {
        id: "secret-v2-question-event-id",
        type: "question.v2.asked",
        properties: {
          sessionID: "opencode-session",
          questions: [{ question: "secret-question", options: ["secret-option"] }],
        },
      },
    });
    await hooks.event({
      event: {
        type: "question.v2.replied",
        properties: {
          sessionID: "opencode-session",
          answers: [["secret-answer"]],
        },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.prompt.admitted",
        id: "secret-prompt-admitted-event-id",
        properties: {
          sessionID: "opencode-session",
          messageID: "secret-prompt-message-id",
          prompt: "secret-admitted-prompt",
          delivery: { metadata: "secret-delivery" },
        },
      },
    });
    await hooks.event({
      event: {
        type: "session.error",
        properties: {
          sessionID: "opencode-session",
          error: { message: "secret-provider-error", responseBody: "secret-response-body" },
        },
      },
    });
    await hooks.event({
      event: {
        type: "todo.updated",
        properties: {
          sessionID: "opencode-session",
          todos: [{ content: "secret-todo-content" }],
        },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.reasoning.delta",
        properties: { sessionID: "opencode-session", delta: "secret-hidden-reasoning" },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.tool.input.delta",
        properties: { sessionID: "opencode-session", callID: "opaque-open-call", delta: "secret-tool-input" },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.tool.called",
        properties: {
          sessionID: "opencode-session",
          callID: "opaque-open-call",
          tool: "bash",
          input: { command: "TOKEN=secret-v2-command" },
          provider: { metadata: { token: "secret-provider-metadata" } },
        },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.tool.failed",
        properties: {
          sessionID: "opencode-session",
          callID: "opaque-open-call",
          error: { message: "secret-v2-tool-error" },
          content: [{ type: "text", text: "secret-v2-tool-output" }],
        },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.compaction.delta",
        properties: { sessionID: "opencode-session", text: "secret-compaction-text" },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.text.ended",
        properties: { sessionID: "opencode-session", text: "Visible OpenCode answer" },
      },
    });
    await hooks["permission.ask"](
      {
        sessionID: "opencode-session",
        patterns: ["secret-direct-permission"],
        metadata: { token: "secret-direct-metadata" },
      },
      { status: "ask" },
    );
    await hooks["chat.message"](
      { sessionID: "opencode-session", messageID: "secret-chat-message-id" },
      { parts: [{ type: "text", text: "Visible OpenCode prompt" }] },
    );
    await hooks["command.execute.before"](
      { sessionID: "opencode-session", command: "secret-command-name", arguments: "secret-command-arguments" },
      { parts: [{ type: "text", text: "secret-command-parts" }] },
    );
    await hooks["tool.execute.before"](
      { sessionID: "opencode-session", callID: "opaque-direct-call", tool: "bash" },
      { args: { command: "TOKEN=secret-direct-command" } },
    );
    await hooks["tool.execute.after"](
      { sessionID: "opencode-session", callID: "opaque-direct-call", tool: "bash" },
      { output: "secret-direct-output", metadata: { token: "secret-tool-metadata" } },
    );
    await hooks["experimental.session.compacting"](
      { sessionID: "opencode-session" },
      { context: ["secret-compact-context"], prompt: "secret-compact-prompt" },
    );
    await hooks["experimental.text.complete"](
      { sessionID: "opencode-session", messageID: "message", partID: "part" },
      { text: "Visible direct OpenCode answer" },
    );

    const opencodePayloads = captured
      .filter((item) => item.source === "opencode")
      .map((item) => item.payload);
    const serializedOpenCode = JSON.stringify(opencodePayloads);
    for (const secret of [
      "secret-permission-pattern",
      "secret-permission-metadata",
      "secret-permission-name",
      "secret-permission-resource",
      "secret-replied-resource",
      "secret-question",
      "secret-option",
      "secret-answer",
      "secret-admitted-prompt",
      "secret-delivery",
      "secret-v2-permission-event-id",
      "secret-v2-permission-reply-event-id",
      "secret-v2-question-event-id",
      "secret-prompt-admitted-event-id",
      "secret-prompt-message-id",
      "secret-chat-message-id",
      "secret-provider-error",
      "secret-response-body",
      "secret-todo-content",
      "secret-hidden-reasoning",
      "secret-tool-input",
      "TOKEN=secret-v2-command",
      "secret-provider-metadata",
      "secret-v2-tool-error",
      "secret-v2-tool-output",
      "opaque-open-call",
      "secret-compaction-text",
      "secret-direct-permission",
      "secret-direct-metadata",
      "secret-command-name",
      "secret-command-arguments",
      "secret-command-parts",
      "TOKEN=secret-direct-command",
      "secret-direct-output",
      "opaque-direct-call",
      "secret-tool-metadata",
      "secret-compact-context",
      "secret-compact-prompt",
      "/secret/project",
      "/secret/worktree",
    ]) {
      assert.equal(serializedOpenCode.includes(secret), false, `OpenCode leaked ${secret}`);
    }
    assert.ok(opencodePayloads.every((payload) => (
      payload.diagnostic === true || payload.properties?.diagnostic === true
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "tool.execute.after" && payload.is_error === true
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "session.compaction.started"
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "session.next.prompt.admitted"
      && /^[0-9a-f]{64}$/.test(payload.turn_id)
      && /^[0-9a-f]{64}$/.test(payload.eventID)
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "permission.v2.replied"
      && payload.properties?.response === "once"
      && /^[0-9a-f]{64}$/.test(payload.eventID)
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "message.user"
      && /^[0-9a-f]{64}$/.test(payload.turn_id)
    )));
    assert.ok(opencodePayloads.filter((payload) => payload.input?.callID).every((payload) => (
      /^[0-9a-f]{64}$/.test(payload.input.callID)
    )));

    const adversarial = await importTemplate(
      "./opencode/agent-pet-companion.js.tpl",
      "adversarial-runtime",
    );
    const adversarialHooks = await adversarial.AgentPetCompanion({});
    const adversarialStart = captured.length;
    await adversarialHooks["chat.message"](
      { sessionID: "opencode-error-order", messageID: "error-user" },
      { parts: [{ type: "text", text: "Trigger failure" }] },
    );
    await adversarialHooks.event({ event: {
      type: "message.updated",
      properties: { info: { id: "pending-error-answer", sessionID: "opencode-error-order", role: "assistant" } },
    } });
    await adversarialHooks.event({ event: {
      type: "message.part.updated",
      properties: { part: { id: "pending-error-part", messageID: "pending-error-answer", sessionID: "opencode-error-order", type: "text", text: "must-not-flush-after-error" } },
    } });
    await adversarialHooks.event({ event: {
      type: "session.error",
      properties: { sessionID: "opencode-error-order", error: { message: "raw-error-must-not-cross" } },
    } });
    await adversarialHooks.event({ event: {
      type: "session.status",
      properties: { sessionID: "opencode-error-order", status: { type: "idle" } },
    } });
    await adversarialHooks.event({ event: {
      type: "session.idle",
      properties: { sessionID: "opencode-error-order" },
    } });
    await adversarialHooks["tool.execute.after"]({
      sessionID: "opencode-error-order", tool: "bash", callID: "error-tail-call",
    });
    await adversarialHooks["experimental.text.complete"](
      { sessionID: "opencode-error-order", messageID: "error-tail-message" },
      { text: "must-not-forward-direct-tail" },
    );

    const cancelledFinal = adversarialHooks.event({ event: {
      type: "session.next.step.ended",
      properties: { sessionID: "opencode-steered", assistantMessageID: "step-one", finish: "stop" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.started",
      properties: { sessionID: "opencode-steered", assistantMessageID: "step-two" },
    } });
    await cancelledFinal;

    await adversarialHooks.event({ event: {
      type: "session.next.step.started",
      properties: { sessionID: "opencode-late-failure", assistantMessageID: "old-step" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.started",
      properties: { sessionID: "opencode-late-failure", assistantMessageID: "current-step" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.failed",
      properties: { sessionID: "opencode-late-failure", assistantMessageID: "old-step" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.ended",
      properties: { sessionID: "opencode-late-failure", assistantMessageID: "current-step", finish: "stop" },
    } });

    await adversarialHooks.event({ event: {
      type: "session.next.step.started",
      properties: { sessionID: "opencode-local-step", assistantMessageID: "local-step" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.tool.called",
      properties: {
        sessionID: "opencode-local-step",
        assistantMessageID: "local-step",
        callID: "local-call",
        tool: "bash",
        providerExecuted: false,
      },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.ended",
      properties: { sessionID: "opencode-local-step", assistantMessageID: "local-step", finish: "stop" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.started",
      properties: { sessionID: "opencode-hosted-step", assistantMessageID: "hosted-step" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.tool.called",
      properties: {
        sessionID: "opencode-hosted-step",
        assistantMessageID: "hosted-step",
        callID: "hosted-call",
        tool: "hosted",
        provider: { executed: true },
      },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.ended",
      properties: { sessionID: "opencode-hosted-step", assistantMessageID: "hosted-step", finish: "tool-calls" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.ended",
      properties: { sessionID: "opencode-final-step", assistantMessageID: "final-step", finish: "stop" },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.failed",
      properties: { sessionID: "opencode-failed-step", error: { message: "raw-step-error" } },
    } });
    await adversarialHooks.event({ event: {
      type: "session.next.step.failed",
      properties: { error: { message: "unattributed-step-error" } },
    } });
    await adversarialHooks["experimental.text.complete"](
      { sessionID: "opencode-assistant-dedup", messageID: "assistant-dedup" },
      { text: "One visible answer" },
    );
    await adversarialHooks.event({ event: {
      type: "session.next.text.ended",
      properties: {
        sessionID: "opencode-assistant-dedup",
        assistantMessageID: "assistant-dedup",
        text: "One visible answer",
      },
    } });
    await adversarialHooks.dispose();

    const adversarialPayloads = captured.slice(adversarialStart).map((item) => item.payload);
    const errorPayloads = adversarialPayloads.filter((payload) => (
      payload.properties?.sessionID === "opencode-error-order"
      || payload.input?.sessionID === "opencode-error-order"
    ));
    assert.deepEqual(errorPayloads.map((payload) => payload.type), ["message.user", "session.error"]);
    assert.equal(JSON.stringify(errorPayloads).includes("raw-error-must-not-cross"), false);
    assert.equal(JSON.stringify(errorPayloads).includes("must-not-flush-after-error"), false);
    assert.equal(JSON.stringify(errorPayloads).includes("must-not-forward-direct-tail"), false);
    assert.equal(adversarialPayloads.some((payload) => (
      payload.type === "session.next.step.ended"
      && payload.properties?.sessionID === "opencode-steered"
    )), false);
    assert.equal(adversarialPayloads.some((payload) => (
      payload.type === "session.next.step.failed"
      && payload.properties?.sessionID === "opencode-late-failure"
    )), false);
    assert.equal(adversarialPayloads.filter((payload) => (
      payload.type === "session.next.step.ended"
      && payload.properties?.sessionID === "opencode-late-failure"
      && payload.outcome === "completed"
    )).length, 1);
    assert.equal(adversarialPayloads.filter((payload) => (
      payload.type === "session.next.step.ended"
      && payload.properties?.sessionID === "opencode-local-step"
      && payload.outcome === "continued"
    )).length, 1);
    assert.equal(adversarialPayloads.filter((payload) => (
      payload.type === "session.next.step.ended"
      && payload.properties?.sessionID === "opencode-hosted-step"
      && payload.outcome === "completed"
    )).length, 1);
    assert.equal(adversarialPayloads.filter((payload) => (
      payload.type === "session.next.step.ended"
      && payload.properties?.sessionID === "opencode-final-step"
      && payload.outcome === "completed"
    )).length, 1);
    assert.equal(adversarialPayloads.filter((payload) => (
      payload.type === "session.next.step.failed"
    )).length, 1);
    assert.equal(JSON.stringify(adversarialPayloads).includes("raw-step-error"), false);
    assert.equal(adversarialPayloads.filter((payload) => (
      payload.type === "message.assistant"
      && payload.properties?.sessionID === "opencode-assistant-dedup"
    )).length, 1);

    const epochQueueModule = await importTemplate(
      "./opencode/agent-pet-companion.js.tpl",
      "queued-terminal-cancellation",
    );
    const epochQueueHooks = await epochQueueModule.AgentPetCompanion({});
    spawnCloseDelayMs = 200;
    const epochQueueStart = captured.length;
    const queuedCalls = [epochQueueHooks.event({ event: {
      type: "session.status",
      properties: { sessionID: "queue-blocker", status: { type: "busy" } },
    } })];
    queuedCalls.push(epochQueueHooks.event({ event: {
      type: "session.error",
      properties: { sessionID: "queued-error-retry" },
    } }));
    queuedCalls.push(epochQueueHooks.event({ event: {
      type: "session.status",
      properties: { sessionID: "queued-error-retry", status: { type: "retry" } },
    } }));
    queuedCalls.push(epochQueueHooks.event({ event: {
      type: "session.idle",
      properties: { sessionID: "queued-idle-tool" },
    } }));
    queuedCalls.push(epochQueueHooks["tool.execute.before"]({
      sessionID: "queued-idle-tool", tool: "bash", callID: "queued-tool-call",
    }));
    await epochQueueHooks.dispose();
    await Promise.all(queuedCalls);
    spawnCloseDelayMs = 0;
    const epochQueuePayloads = captured.slice(epochQueueStart).map((item) => item.payload);
    assert.equal(epochQueuePayloads.some((payload) => (
      payload.type === "session.error"
      && payload.properties?.sessionID === "queued-error-retry"
    )), false);
    assert.equal(epochQueuePayloads.some((payload) => (
      payload.type === "session.status"
      && payload.properties?.sessionID === "queued-error-retry"
      && payload.properties?.status === "retry"
    )), true);
    assert.equal(epochQueuePayloads.some((payload) => (
      payload.type === "session.idle"
      && payload.properties?.sessionID === "queued-idle-tool"
    )), false);
    assert.equal(epochQueuePayloads.some((payload) => (
      payload.type === "tool.execute.before"
      && payload.input?.sessionID === "queued-idle-tool"
    )), true);

    const stormModule = await importTemplate(
      "./opencode/agent-pet-companion.js.tpl",
      "bounded-offline-storm",
    );
    const stormHooks = await stormModule.AgentPetCompanion({});
    spawnCloseDelayMs = 10_000;
    const stormStart = captured.length;
    const stormCalls = [];
    stormCalls.push(stormHooks["chat.message"](
      { sessionID: "opencode-storm", messageID: "storm-user" },
      { parts: [{ type: "text", text: "Storm prompt" }] },
    ));
    stormCalls.push(stormHooks["chat.message"](
      { sessionID: "opencode-full-assistant", messageID: "full-user" },
      { parts: [{ type: "text", text: "Full queue prompt" }] },
    ));
    stormCalls.push(stormHooks.event({ event: {
      type: "message.updated",
      properties: { info: { id: "full-answer", sessionID: "opencode-full-assistant", role: "assistant" } },
    } }));
    stormCalls.push(stormHooks.event({ event: {
      type: "message.part.updated",
      properties: { part: { id: "full-part", messageID: "full-answer", sessionID: "opencode-full-assistant", type: "text", text: "Latest answer survives capacity" } },
    } }));
    for (let index = 0; index < 300; index += 1) {
      stormCalls.push(stormHooks.event({ event: {
        type: "session.status",
        properties: { sessionID: `other-${index}`, status: { type: "busy" } },
      } }));
    }
    stormCalls.push(stormHooks.event({ event: {
      type: "session.idle",
      properties: { sessionID: "opencode-full-assistant" },
    } }));
    stormCalls.push(stormHooks.event({ event: {
      type: "session.error",
      properties: { sessionID: "opencode-storm", error: { message: "offline-secret" } },
    } }));
    stormCalls.push(stormHooks.event({ event: {
      type: "session.error",
      properties: { sessionID: "opencode-storm-two", error: { message: "offline-secret-two" } },
    } }));
    const disposeStarted = Date.now();
    await stormHooks.dispose();
    await Promise.all(stormCalls);
    const disposeElapsed = Date.now() - disposeStarted;
    spawnCloseDelayMs = 0;
    const stormPayloads = captured.slice(stormStart).map((item) => item.payload);
    const stormSessionPayloads = stormPayloads.filter((payload) => (
      payload.properties?.sessionID === "opencode-storm"
      || payload.input?.sessionID === "opencode-storm"
    ));
    assert.deepEqual(stormSessionPayloads.map((payload) => payload.type), ["message.user", "session.error"]);
    assert.equal(stormPayloads.some((payload) => (
      payload.type === "session.error"
      && payload.properties?.sessionID === "opencode-storm-two"
    )), true);
    const capacitySessionTypes = stormPayloads.filter((payload) => (
      payload.properties?.sessionID === "opencode-full-assistant"
      || payload.input?.sessionID === "opencode-full-assistant"
    )).map((payload) => payload.type);
    assert.deepEqual(capacitySessionTypes, ["message.user", "message.assistant", "session.idle"]);
    assert.ok(stormPayloads.length <= 100, `bounded queue spawned ${stormPayloads.length} deliveries`);
    assert.ok(disposeElapsed < 4200, `dispose took ${disposeElapsed}ms`);

    process.env.APC_CONNECTOR_PROBE = "1";
    process.env.APC_CONNECTOR_PROBE_ID = "apc-probe-018f47d2-6f9d-7b1a-8d31-12f447f59f01";
    const piProbe = await importTemplate("./pi/agent-pet-companion.ts.tpl", "probe");
    const piProbeHandlers = new Map();
    piProbe.default({ on: (name, handler) => piProbeHandlers.set(name, handler) });
    await piProbeHandlers.get("session_start")(
      { type: "session_start" },
      { sessionManager: { getSessionId: () => "pi-probe-session" } },
    );
    await piProbeHandlers.get("session_shutdown")(
      { type: "session_shutdown" },
      { sessionManager: { getSessionId: () => "pi-probe-session" } },
    );
    const opencodeProbe = await importTemplate("./opencode/agent-pet-companion.js.tpl", "probe");
    await opencodeProbe.AgentPetCompanion({});
    await new Promise((resolve) => setImmediate(resolve));
    assert.ok(captured.some((item) => (
      item.source === "pi"
      && item.payload.type === "connector.probe"
      && item.payload.diagnostic === true
      && item.payload.session_id === process.env.APC_CONNECTOR_PROBE_ID
    )));
    assert.equal(captured.filter((item) => (
      item.source === "pi" && item.payload.type === "connector.probe"
    )).length, 1);
    assert.ok(captured.some((item) => (
      item.source === "opencode"
      && item.payload.type === "connector.probe"
      && item.payload.properties?.diagnostic === true
      && item.payload.properties?.sessionID === process.env.APC_CONNECTOR_PROBE_ID
    )));
  } finally {
    childProcess.spawn = originalSpawn;
    syncBuiltinESMExports();
    if (originalDiagnostic === undefined) delete process.env.APC_CONNECTOR_DIAGNOSTIC;
    else process.env.APC_CONNECTOR_DIAGNOSTIC = originalDiagnostic;
    if (originalProbe === undefined) delete process.env.APC_CONNECTOR_PROBE;
    else process.env.APC_CONNECTOR_PROBE = originalProbe;
    if (originalProbeID === undefined) delete process.env.APC_CONNECTOR_PROBE_ID;
    else process.env.APC_CONNECTOR_PROBE_ID = originalProbeID;
  }
});
