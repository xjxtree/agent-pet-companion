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

test("Pi, OpenCode, and dsh expose bounded local activity without leaking host-private context", async () => {
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
    assert.equal(pi.APC_PI_CONTRACT_VERSION, "pi-extension-0.80.10-events-v15");
    assert.equal(pi.APC_PI_EVENT_INVENTORY.length, 33);
    const piActivity = await importTemplate(
      "./pi/agent-pet-companion.ts.tpl",
      "semantic-activity",
      ["activityText"],
    );
    const encodedAndDumpActivityCases = [
      {
        name: "encoded safe object",
        value: JSON.stringify({ path: "README.md", headers: { Authorization: "Bearer private" } }),
        expected: "README.md",
      },
      {
        name: "encoded safe array",
        value: JSON.stringify([{ file_path: "Sources/App.swift" }]),
        expected: "Sources/App.swift",
      },
      {
        name: "double encoded safe object",
        value: JSON.stringify(JSON.stringify({ path: "README.md" })),
        expected: "README.md",
      },
      {
        name: "encoded credential object",
        value: JSON.stringify({ headers: { message: "secret-header" } }),
        expected: undefined,
      },
      {
        name: "encoded credential array",
        value: JSON.stringify([{ credentials: { output: "secret-credential" } }]),
        expected: undefined,
      },
      {
        name: "double encoded credentials",
        value: JSON.stringify(JSON.stringify({ client_secret: { content: "secret-client" } })),
        expected: undefined,
      },
      {
        name: "triple encoded credentials",
        value: JSON.stringify(JSON.stringify(JSON.stringify({
          client_secret: { content: "secret-client-triple" },
        }))),
        expected: undefined,
      },
      {
        name: "oversized encoded object",
        value: JSON.stringify({ headers: { message: "x".repeat(32 * 1024) } }),
        expected: undefined,
      },
      {
        name: "oversized double encoded object",
        value: JSON.stringify(JSON.stringify({
          credentials: { output: "x".repeat(32 * 1024) },
        })),
        expected: undefined,
      },
      {
        name: "authorization header dump",
        value: "Authorization: Bearer private",
        expected: undefined,
      },
      {
        name: "environment dump",
        value: "API_KEY=private\nPATH=/usr/bin",
        expected: undefined,
      },
      {
        name: "truncated object",
        value: "  {\"path\":\"README.md\"",
        expected: undefined,
      },
      {
        name: "truncated array",
        value: " \n [{\"path\":\"README.md\"}",
        expected: undefined,
      },
      {
        name: "malformed quoted encoded object",
        value: "  \"{\\\"headers\\\":{\\\"message\\\":\\\"secret\\\"}",
        expected: undefined,
      },
      {
        name: "double encoded truncated object",
        value: JSON.stringify("{\"headers\":{\"message\":\"secret\"}"),
        expected: undefined,
      },
      {
        name: "ordinary prose with braces",
        value: "Planning includes {draft} markers",
        expected: "Planning includes {draft} markers",
      },
      {
        name: "valid quoted prose",
        value: JSON.stringify("Planning includes {draft} markers"),
        expected: "Planning includes {draft} markers",
      },
      {
        name: "same-line environment dump",
        value: "PATH=/usr/bin API_KEY=private",
        expected: undefined,
      },
      {
        name: "same-line header dump",
        value: "Content-Type: text/plain Authorization: Bearer private",
        expected: undefined,
      },
      {
        name: "control-separated environment dump",
        value: "PATH=/usr/bin\u0000API_KEY=private",
        expected: undefined,
      },
    ];
    for (const { name, value, expected } of encodedAndDumpActivityCases) {
      assert.equal(
        piActivity.activityText({ type: "tool_execution_end", result: value }),
        expected,
        `Pi ${name}`,
      );
    }
    assert.equal(
      piActivity.activityText({
        type: "tool_call",
        input: { command: "TOKEN=secret-command" },
      }),
      "TOKEN=secret-command",
      "Pi explicit command context must retain environment assignments",
    );
    assert.equal(
      piActivity.activityText({
        type: "tool_call",
        input: { command: "PATH=/usr/bin API_KEY=secret-command" },
      }),
      "PATH=/usr/bin API_KEY=secret-command",
      "Pi explicit command context must retain same-line environment assignments",
    );
    assert.equal(
      piActivity.activityText({
        type: "tool_execution_start",
        args: { path: "Sources/App.swift" },
      }),
      "Sources/App.swift",
      "Pi tool_execution_start must read the host's args field",
    );
    assert.equal(
      piActivity.activityText({
        type: "message_end",
        message: {
          role: "assistant",
          content: [{ type: "thinking", thinking: "Inspecting the Swift view" }],
        },
      }),
      "Inspecting the Swift view",
      "Pi finalized thinking blocks must read ThinkingContent.thinking",
    );
    const sensitiveIdentifierTokens = [
      "env", "environment", "header", "headers", "auth", "oauth", "authentication",
      "authorization", "secret", "password", "passphrase", "credential", "credentials",
      "cookie", "cookies", "token", "tokens", "keychain", "keystore", "pem",
    ];
    const capitalizedIdentifier = (value) => value[0].toUpperCase() + value.slice(1);
    const sensitiveIdentifierMatrix = sensitiveIdentifierTokens.flatMap((sensitive) => [
      ...["_", "-", ".", " "].flatMap((separator) => [
        `${sensitive}${separator}value`,
        `value${separator}${sensitive}`,
      ]),
      `${sensitive}Value`,
      `value${capitalizedIdentifier(sensitive)}`,
    ]);
    const sensitiveKeyMatrix = [
      "private", "api", "ssh", "signing", "encryption", "access", "client",
    ].flatMap((qualifier) => [
      `${qualifier}_key`,
      `key-${qualifier}`,
      `${qualifier}Key`,
      `key${capitalizedIdentifier(qualifier)}`,
    ]);
    const credentialContainerVariants = [
      { headers: { content: "secret-header-content" } },
      { environment: { message: "secret-environment-message" } },
      { tokens: { output: "secret-token-output" } },
      { client_secret: { message: "secret-client-message" } },
      { sessionToken: { output: "secret-session-output" } },
      { privateKey: { content: "secret-private-key" } },
      { Authorization: { message: "secret-authorization" } },
      { customBearerToken: { result: "secret-bearer-token" } },
      { processEnv: { message: "secret-process-environment" } },
      { requestHeader: { content: "secret-request-header" } },
      { requestHeaders: { content: "secret-request-headers" } },
      { clientAuth: { output: "secret-client-auth" } },
      { oauth: { result: "secret-oauth" } },
      { processEnvironment: { message: "secret-process-environment-long" } },
      { clientAuthentication: { content: "secret-client-authentication" } },
      { authConfig: { output: "secret-auth-config" } },
      { token_value: { message: "secret-token-underscore" } },
      { "token-value": { output: "secret-token-hyphen" } },
      { tokenValue: { content: "secret-token-camel-case" } },
      ...sensitiveIdentifierMatrix.map((key) => ({
        [key]: { message: `secret identifier ${key}` },
      })),
      ...sensitiveKeyMatrix.map((key) => ({
        [key]: { output: `secret key identifier ${key}` },
      })),
    ];
    for (const input of credentialContainerVariants) {
      assert.equal(
        piActivity.activityText({ type: "tool_call", input }),
        undefined,
        "Pi activity must not recurse through credential containers",
      );
    }
    assert.equal(
      piActivity.activityText({ type: "tool_call", input: { file_path: "Sources/App.swift" } }),
      "Sources/App.swift",
    );
    assert.equal(
      piActivity.activityText({
        type: "tool_call",
        input: { token_count: { message: "42 tokens processed" } },
      }),
      "42 tokens processed",
      "Pi token statistics must not be mistaken for credential containers",
    );
    assert.equal(
      piActivity.activityText({
        type: "tool_call",
        input: { token_counts: { message: "42 input, 17 output" } },
      }),
      "42 input, 17 output",
      "Pi token statistics plural must remain allowlisted",
    );
    assert.equal(
      piActivity.activityText({
        type: "tool_call",
        input: { authorMetadata: { message: "Ada Lovelace" } },
      }),
      "Ada Lovelace",
      "Pi author metadata must not be mistaken for auth credentials",
    );
    assert.equal(
      piActivity.activityText({
        type: "tool_call",
        input: { envelope: { message: "ordinary transport envelope" } },
      }),
      "ordinary transport envelope",
      "Pi envelope metadata must not be mistaken for environment credentials",
    );

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
      model: { provider: "fixture", id: "fixture-model" },
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
    await piHandlers.get("session_info_changed")(
      {
        type: "session_info_changed",
        name: "Generated Pi title",
        privateMetadata: "secret-session-metadata",
      },
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
    await piHandlers.get("tool_execution_start")(
      {
        type: "tool_execution_start",
        toolName: "read",
        toolCallId: "opaque-pi-read",
        args: { path: "Sources/App.swift" },
      },
      piContext,
    );
    await piHandlers.get("tool_execution_start")(
      {
        type: "tool_execution_start",
        toolName: "read",
        toolCallId: "opaque-pi-malformed",
      },
      piContext,
    );
    await piHandlers.get("message_end")(
      {
        type: "message_end",
        message: {
          role: "assistant",
          content: [{ type: "thinking", thinking: "Inspecting the Swift view" }],
        },
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
      "secret-session-metadata",
      "secret-reasoning",
      "secret-partial-output",
      "secret-system-prompt",
      "secret-agent-tool-result",
      "/secret/project",
    ]) {
      assert.equal(serializedPi.includes(secret), false, `Pi leaked ${secret}`);
    }
    assert.ok(piPayloads.every((payload) => payload.diagnostic === true));
    assert.equal(piPayloads.at(-1).type, "agent_settled");
    assert.equal(piPayloads.at(-1).message_content, "Visible Pi answer");
    assert.ok(piPayloads.some((payload) => (
      payload.type === "tool_call"
      && payload.activity_content === "TOKEN=secret-command"
    )));
    assert.ok(piPayloads.some((payload) => (
      payload.type === "tool_execution_end"
      && payload.activity_content === "secret-tool-output"
    )));
    assert.ok(piPayloads.some((payload) => (
      payload.type === "tool_execution_start"
      && payload.activity_content === "Sources/App.swift"
      && payload.parse_warnings === undefined
    )));
    assert.ok(piPayloads.some((payload) => (
      payload.type === "tool_execution_start"
      && payload.tool_call_id === "opaque-pi-malformed"
      && payload.parse_warnings?.some((warning) => (
        warning.field === "tool_arguments"
        && warning.failure === "missing_required"
      ))
    )));
    assert.ok(piPayloads.some((payload) => (
      payload.type === "message_end"
      && payload.activity_kind === "thinking"
      && payload.activity_content === "Inspecting the Swift view"
    )));
    assert.ok(piPayloads.some((payload) => (
      payload.type === "session_info_changed"
      && payload.session_title === "Generated Pi title"
      && payload.message_content === undefined
    )));

    const piNoModelStart = captured.length;
    const piNoModelContext = {
      sessionManager: {
        getSessionId: () => "pi-no-model-session",
        getSessionName: () => "No model session",
      },
      model: undefined,
    };
    await piHandlers.get("input")(
      { type: "input", text: "Prompt without a selected model" },
      piNoModelContext,
    );
    const piNoModelPayloads = captured
      .slice(piNoModelStart)
      .filter((item) => item.source === "pi")
      .map((item) => item.payload);
    assert.deepEqual(piNoModelPayloads.map((payload) => payload.type), ["input"]);
    assert.equal(piNoModelPayloads[0].agent_error, true);
    assert.equal(piNoModelPayloads[0].reason, "model_unavailable");

    const piChildStart = captured.length;
    const piChildContext = {
      sessionManager: {
        getSessionId: () => "pi-child-session",
        getSessionName: () => "must-not-cross-child-title",
        getHeader: () => ({ parentSession: "/private/root-session.jsonl" }),
      },
    };
    await piHandlers.get("input")(
      { type: "input", text: "must-not-cross-child-prompt" },
      piChildContext,
    );
    await piHandlers.get("tool_call")(
      { type: "tool_call", toolName: "bash", input: { command: "must-not-cross-child-tool" } },
      piChildContext,
    );
    const piChildPayloads = captured
      .slice(piChildStart)
      .filter((item) => item.source === "pi")
      .map((item) => item.payload);
    assert.equal(piChildPayloads.length, 1);
    assert.equal(piChildPayloads[0].type, "session.child");
    assert.equal(piChildPayloads[0].session_id, "pi-child-session");
    assert.equal(JSON.stringify(piChildPayloads).includes("/private/root-session.jsonl"), false);
    assert.equal(JSON.stringify(piChildPayloads).includes("must-not-cross"), false);

    const piReservedChildStart = captured.length;
    const piReservedChildContext = {
      sessionManager: {
        getSessionId: () => "pi-reserved-child-session",
        getSessionName: () => "subagent-reviewer-security",
        getHeader: () => ({}),
      },
      model: { provider: "fixture", id: "fixture-model" },
    };
    await piHandlers.get("input")(
      { type: "input", text: "must-not-cross-reserved-child-prompt" },
      piReservedChildContext,
    );
    await piHandlers.get("tool_call")(
      { type: "tool_call", toolName: "bash", input: { command: "must-not-cross-reserved-child-tool" } },
      piReservedChildContext,
    );
    const piReservedChildPayloads = captured
      .slice(piReservedChildStart)
      .filter((item) => item.source === "pi")
      .map((item) => item.payload);
    assert.equal(piReservedChildPayloads.length, 1);
    assert.equal(piReservedChildPayloads[0].type, "session.child");
    assert.equal(piReservedChildPayloads[0].session_id, "pi-reserved-child-session");
    assert.equal(JSON.stringify(piReservedChildPayloads).includes("subagent-reviewer"), false);
    assert.equal(JSON.stringify(piReservedChildPayloads).includes("must-not-cross"), false);

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
        "boundedActivity",
      ],
    );
    assert.equal(opencode.APC_OPENCODE_CONTRACT_VERSION, "opencode-v1.18.4-events-v16");
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
    for (const { name, value, expected } of encodedAndDumpActivityCases) {
      assert.equal(opencode.boundedActivity(value), expected, `OpenCode ${name}`);
    }
    assert.equal(
      opencode.boundedActivity({ command: "TOKEN=secret-command" }),
      "TOKEN=secret-command",
      "OpenCode explicit command context must retain environment assignments",
    );
    assert.equal(
      opencode.boundedActivity({ command: "PATH=/usr/bin API_KEY=secret-command" }),
      "PATH=/usr/bin API_KEY=secret-command",
      "OpenCode explicit command context must retain same-line environment assignments",
    );
    for (const value of credentialContainerVariants) {
      assert.equal(
        opencode.boundedActivity(value),
        undefined,
        "OpenCode activity must not recurse through credential containers",
      );
    }
    assert.equal(opencode.boundedActivity({ path: "README.md" }), "README.md");
    assert.equal(
      opencode.boundedActivity({ token_count: { message: "42 tokens processed" } }),
      "42 tokens processed",
      "OpenCode token statistics must not be mistaken for credential containers",
    );
    assert.equal(
      opencode.boundedActivity({ token_counts: { message: "42 input, 17 output" } }),
      "42 input, 17 output",
      "OpenCode token statistics plural must remain allowlisted",
    );
    assert.equal(
      opencode.boundedActivity({ authorMetadata: { message: "Ada Lovelace" } }),
      "Ada Lovelace",
      "OpenCode author metadata must not be mistaken for auth credentials",
    );
    assert.equal(
      opencode.boundedActivity({ envelope: { message: "ordinary transport envelope" } }),
      "ordinary transport envelope",
      "OpenCode envelope metadata must not be mistaken for environment credentials",
    );

    let releaseExistingSessionList;
    let existingSessionListRequested = false;
    const hooksPromise = opencode.AgentPetCompanion({
      directory: "/secret/project",
      worktree: "/secret/worktree",
      client: {
        session: {
          list: () => new Promise((resolve) => {
            existingSessionListRequested = true;
            releaseExistingSessionList = () => resolve({
              data: [{
                id: "opencode-existing-child",
                parentID: "opencode-root",
                title: "must-not-cross-existing-child-title",
              }],
            });
          }),
        },
      },
    });
    let hooksResolvedBeforeLineage = false;
    void hooksPromise.then(() => { hooksResolvedBeforeLineage = true; });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(hooksResolvedBeforeLineage, true);
    const hooks = await hooksPromise;
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(existingSessionListRequested, true);
    let eventResolvedBeforeLineage = false;
    const gatedExistingChildEvent = hooks.event({
      event: {
        type: "session.status",
        properties: {
          sessionID: "opencode-existing-child",
          status: { type: "busy" },
        },
      },
    });
    void gatedExistingChildEvent.then(() => { eventResolvedBeforeLineage = true; });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(eventResolvedBeforeLineage, false);
    releaseExistingSessionList();
    await gatedExistingChildEvent;
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
        type: "session.updated",
        properties: {
          info: {
            id: "opencode-session",
            title: "Generated OpenCode title",
            privateMetadata: "secret-opencode-session-metadata",
          },
        },
      },
    });
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
        properties: { sessionID: "opencode-reasoning-session", delta: "secret-hidden-reasoning" },
      },
    });
    await hooks.event({
      event: {
        type: "session.next.reasoning.ended",
        properties: {
          sessionID: "opencode-reasoning-session",
          summary: "Stable reasoning checkpoint",
        },
      },
    });
    await hooks.event({
      event: {
        type: "message.part.updated",
        properties: {
          part: {
            id: "reasoning-growing",
            messageID: "reasoning-message",
            sessionID: "opencode-reasoning-session",
            type: "reasoning",
            text: "Transient growing reasoning",
          },
        },
      },
    });
    await hooks.event({
      event: {
        type: "message.part.updated",
        properties: {
          part: {
            id: "reasoning-finished",
            messageID: "reasoning-message",
            sessionID: "opencode-reasoning-session",
            type: "reasoning",
            text: "Stable v1 reasoning checkpoint",
            time: { end: 1 },
          },
        },
      },
    });
    await hooks.event({
      event: {
        type: "todo.updated",
        properties: {
          sessionID: "opencode-plan-session",
          todos: [{ content: "Stable plan checkpoint" }],
        },
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
    await hooks.event({
      event: {
        type: "session.created",
        properties: {
          info: {
            id: "opencode-live-child",
            parentID: "opencode-root",
            title: "must-not-cross-live-child-title",
          },
        },
      },
    });
    await hooks["chat.message"](
      { sessionID: "opencode-live-child", messageID: "child-message" },
      { parts: [{ type: "text", text: "must-not-cross-live-child-prompt" }] },
    );
    await hooks.event({
      event: {
        type: "session.status",
        properties: { sessionID: "opencode-live-child", status: { type: "busy" } },
      },
    });
    await hooks.dispose();

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
      "secret-opencode-session-metadata",
      "secret-chat-message-id",
      "secret-response-body",
      "secret-hidden-reasoning",
      "secret-tool-input",
      "secret-provider-metadata",
      "secret-v2-tool-error",
      "opaque-open-call",
      "secret-compaction-text",
      "secret-direct-permission",
      "secret-direct-metadata",
      "secret-command-arguments",
      "secret-command-parts",
      "opaque-direct-call",
      "secret-tool-metadata",
      "secret-compact-context",
      "secret-compact-prompt",
      "must-not-cross-existing-child-title",
      "must-not-cross-live-child-title",
      "must-not-cross-live-child-prompt",
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
      payload.type === "session.error"
      && payload.properties?.activity_content === "secret-provider-error"
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "tool.execute.before"
      && payload.activity_content?.includes("TOKEN=secret-direct-command")
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "tool.execute.after"
      && payload.activity_content?.includes("secret-direct-output")
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "command.execute.before"
      && payload.activity_content?.includes("secret-command-name")
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
      payload.type === "session.next.reasoning.ended"
      && payload.properties?.activity_content === "Stable reasoning checkpoint"
    )));
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "session.next.reasoning.ended"
      && payload.properties?.activity_content === "Stable v1 reasoning checkpoint"
    )));
    assert.equal(opencodePayloads.some((payload) => (
      payload.properties?.activity_content === "Transient growing reasoning"
    )), false);
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "session.plan.updated"
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
    assert.ok(opencodePayloads.some((payload) => (
      payload.type === "session.updated"
      && payload.properties?.session_title === "Generated OpenCode title"
      && payload.properties?.privateMetadata === undefined
    )));
    assert.ok(opencodePayloads.filter((payload) => payload.input?.callID).every((payload) => (
      /^[0-9a-f]{64}$/.test(payload.input.callID)
    )));
    for (const childID of ["opencode-existing-child", "opencode-live-child"]) {
      const childPayloads = opencodePayloads.filter((payload) => (
        payload.properties?.sessionID === childID
      ));
      assert.equal(childPayloads.length, 1);
      assert.equal(childPayloads[0].type, "session.child");
    }

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
      properties: { info: { id: "pending-error-answer", sessionID: "opencode-error-order", parentID: "error-user", role: "assistant" } },
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
    assert.equal(JSON.stringify(errorPayloads).includes("raw-error-must-not-cross"), true);
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
    assert.equal(JSON.stringify(adversarialPayloads).includes("raw-step-error"), true);
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
    await new Promise((resolve) => setImmediate(resolve));
    assert.ok(captured.some((item) => (
      item.source === "pi"
      && item.payload.type === "connector.probe"
      && item.payload.diagnostic === true
      && item.payload.session_id === process.env.APC_CONNECTOR_PROBE_ID
    )), "Pi must emit its load canary before model validation can end the host");
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

    // --- DeepSeek Harness (dsh) template privacy and filtering tests ---
    delete process.env.APC_CONNECTOR_PROBE_ID;
    const dsh = await importTemplate("./dsh/agent-pet-companion.js.tpl", "dsh-privacy");
    assert.equal(dsh.APC_DSH_CONTRACT_VERSION, "dsh-v0.1.0-rc.7-events-v3");
    assert.equal(dsh.APC_DSH_AUDITED_EVENTS.length, 5);

    const dshListeners = new Map();
    const fakeCtx = {
      on: (event, handler) => {
        dshListeners.set(event, handler);
      },
    };
    dsh.apply(fakeCtx);
    assert.ok(dshListeners.has("session/event"), "dsh must listen to session/event");
    assert.ok(dshListeners.has("subagent/start"), "dsh must listen to subagent/start");
    assert.ok(dshListeners.has("subagent/end"), "dsh must listen to subagent/end");
    assert.ok(dshListeners.has("session/disposed"), "dsh must listen to session/disposed");
    assert.ok(!dshListeners.has("agent/status"), "unattributed agent/status must remain audit-only");
    assert.ok(captured.some((item) => (
      item.source === "dsh"
      && item.payload.type === "connector.probe"
      && item.payload.session_id.startsWith("apc-dsh-probe-")
      && item.payload.session_id !== "probe"
      && /^[0-9a-f]{64}$/.test(item.payload.eventID)
    )), "fallback dsh probes must use fresh content-free identities");

    // Test 1: session.child emission on child session first sight
    const childSession = {
      id: "child-sess-1",
      header: { origin: "subagent", parentSession: "parent-sess-1", delegationDepth: 1 },
    };
    dshListeners.get("session/event")(childSession, { type: "turn/start", data: { turn: 1 } });
    await new Promise((r) => setTimeout(r, 20));
    assert.ok(captured.some((item) => (
      item.source === "dsh"
      && item.payload.type === "session.child"
      && item.payload.session_id === "child-sess-1"
    )), "dsh must emit session.child on child session detection");

    // Subsequent events from child are dropped locally
    const countBefore = captured.length;
    dshListeners.get("session/event")(childSession, {
      type: "assistant/chunk",
      data: { turn: 1, step: 1, chunk: { type: "block-start", blockType: "reasoning" } },
    });
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(captured.length, countBefore, "child events after first sight must be dropped");

    // Test 2: parent turn/end with active background fence emits background_active
    const parentSession = {
      id: "parent-sess-1",
      header: { origin: undefined, parentSession: undefined },
    };
    // subagent/start puts run in parent's fence
    dshListeners.get("subagent/start")({ runId: "run-1", id: "child-sess-1", local: true });
    // parent completes turn while fence has active run
    dshListeners.get("session/event")(parentSession, {
      type: "turn/end",
      data: { turn: 1, reason: { kind: "completed" } },
    });
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(captured.some((item) => (
      item.source === "dsh"
      && item.payload.type === "turn/end"
      && item.payload.session_id === "parent-sess-1"
      && item.payload.background_active === true
    )), "parent turn/end with active fence must emit background_active");

    // subagent/end drains fence -> emits deferred completed turn/end
    dshListeners.get("subagent/end")({ runId: "run-1" });
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(captured.some((item) => (
      item.source === "dsh"
      && item.payload.type === "turn/end"
      && item.payload.session_id === "parent-sess-1"
      && item.payload.background_active === undefined
      && item.payload.reason?.kind === "completed"
    )), "subagent/end fence drain must emit deferred completed turn/end");

    // Test 3: delta chunks dropped (zero churn)
    const countBeforeDelta = captured.length;
    dshListeners.get("session/event")(parentSession, {
      type: "assistant/chunk",
      data: { turn: 2, step: 1, chunk: { type: "text-delta", text: "churn" } },
    });
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(captured.length, countBeforeDelta, "text-delta chunks must be dropped");

    // Test 4: bounded display context travels on semantic edges, not private envelopes.
    // Real rc.7 shape: `user/message` data IS the UserMessage directly.
    dshListeners.get("session/event")(parentSession, {
      type: "session/title",
      seq: 20,
      data: { title: "DSH acceptance" },
    });
    dshListeners.get("session/event")(parentSession, {
      type: "user/message",
      seq: 21,
      data: { source: { kind: "user" }, content: [{ type: "text", text: "Review DSH" }] },
    });
    dshListeners.get("session/event")(parentSession, {
      type: "turn/start",
      seq: 22,
      data: { turn: 2 },
    });
    dshListeners.get("session/event")(parentSession, {
      type: "assistant/message",
      seq: 23,
      data: { turn: 2, step: 1, message: { content: [{ type: "text", text: "DSH is ready" }] } },
    });
    dshListeners.get("session/event")(parentSession, {
      type: "turn/end",
      seq: 24,
      data: { turn: 2, reason: { kind: "completed" } },
    });
    await new Promise((r) => setTimeout(r, 50));
    const startPayload = captured.find((item) => (
      item.source === "dsh" && item.payload.type === "turn/start" && item.payload.turn_id === "2"
    ))?.payload;
    assert.equal(startPayload?.message_role, "user");
    assert.equal(startPayload?.message_content, "Review DSH");
    assert.equal(startPayload?.session_title, "DSH acceptance");
    // The final assistant/message now delivers its visible text immediately at
    // the message boundary, not only via a later terminal edge.
    const assistantPayload = captured.find((item) => (
      item.source === "dsh" && item.payload.type === "assistant/message" && item.payload.turn_id === "2"
    ))?.payload;
    assert.equal(assistantPayload?.message_role, "assistant");
    assert.equal(assistantPayload?.message_content, "DSH is ready");
    assert.equal(assistantPayload?.session_title, "DSH acceptance");
    const donePayload = captured.find((item) => (
      item.source === "dsh" && item.payload.type === "turn/end" && item.payload.turn_id === "2"
    ))?.payload;
    assert.equal(donePayload?.message_role, "assistant");
    assert.equal(donePayload?.message_content, "DSH is ready");
    assert.equal(donePayload?.session_title, "DSH acceptance");

    // Test 4b: reasoning-only final message projects explicit thinking content.
    const reasoningBefore = captured.length;
    dshListeners.get("session/event")(parentSession, {
      type: "assistant/message",
      seq: 27,
      data: { turn: 3, step: 1, message: { content: [{ type: "reasoning", text: "internal plan" }] } },
    });
    await new Promise((r) => setTimeout(r, 30));
    const reasoningPayload = captured.slice(reasoningBefore).find((item) => (
      item.source === "dsh" && item.payload.type === "assistant/message" && item.payload.turn_id === "3"
    ))?.payload;
    assert.equal(reasoningPayload?.activity_kind, "thinking");
    assert.equal(reasoningPayload?.activity_content, "internal plan");
    assert.equal(reasoningPayload?.message_content, undefined);

    // Test 4c: a final message with both text and reasoning projects text as the
    // Agent body and keeps reasoning as the thinking content on the same event.
    dshListeners.get("session/event")(parentSession, {
      type: "assistant/message",
      seq: 28,
      data: { turn: 4, step: 1, message: { content: [
        { type: "reasoning", text: "thinking text" },
        { type: "text", text: "visible text" },
      ] } },
    });
    await new Promise((r) => setTimeout(r, 30));
    const bothPayload = captured.find((item) => (
      item.source === "dsh" && item.payload.type === "assistant/message" && item.payload.turn_id === "4"
    ))?.payload;
    assert.equal(bothPayload?.message_content, "visible text");
    assert.equal(bothPayload?.activity_content, "thinking text");

    // Test 4d: a text-less final assistant/message emits nothing and clears the
    // cached assistant text so a terminal edge cannot resurrect stale body copy.
    const emptyBefore = captured.length;
    dshListeners.get("session/event")(parentSession, {
      type: "assistant/message",
      seq: 29,
      data: { turn: 5, step: 1, message: { content: [{ type: "reasoning", text: "" }] } },
    });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(
      captured.slice(emptyBefore).filter((item) => item.payload?.type === "assistant/message").length,
      0,
      "an assistant/message with no text or reasoning must not be delivered",
    );

    // Test 4e: historical nested user/message shape still projects; a non-user
    // source kind is ignored as user context.
    dshListeners.get("session/event")(parentSession, {
      type: "user/message",
      seq: 30,
      data: { message: { source: { kind: "user" }, content: [{ type: "text", text: "legacy nested" }] } },
    });
    dshListeners.get("session/event")(parentSession, {
      type: "user/message",
      seq: 31,
      data: { source: { kind: "plugin", plugin: "skill" }, content: [{ type: "text", text: "injected" }] },
    });
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(captured.some((item) => (
      item.source === "dsh"
      && item.payload.type === "user/message"
      && item.payload.message_content === "legacy nested"
    )), "historical nested user/message shape must remain bounded-compatible");
    assert.ok(!captured.some((item) => (
      item.payload?.type === "user/message" && item.payload?.message_content === "injected"
    )), "non-user source kinds must never project as user context");

    // Test 4f: todo/write projects one bounded plan line and never the array.
    dshListeners.get("session/event")(parentSession, {
      type: "todo/write",
      seq: 32,
      data: { todos: [
        { content: "done step", status: "completed" },
        { content: "current step", status: "in_progress" },
        { content: "later step", status: "pending" },
      ] },
    });
    await new Promise((r) => setTimeout(r, 30));
    const todoPayload = captured.find((item) => (
      item.source === "dsh" && item.payload.type === "todo/write"
    ))?.payload;
    assert.equal(todoPayload?.activity_kind, "plan");
    assert.equal(todoPayload?.activity_content, "current step");
    assert.equal(typeof todoPayload?.activity_content, "string");
    // Empty / malformed todo shapes project no plan body.
    const todoEmptyBefore = captured.length;
    dshListeners.get("session/event")(parentSession, { type: "todo/write", seq: 33, data: { todos: [] } });
    dshListeners.get("session/event")(parentSession, { type: "todo/write", seq: 34, data: { todos: [{ content: 42, status: "in_progress" }] } });
    dshListeners.get("session/event")(parentSession, { type: "todo/write", seq: 35, data: { todos: "not-an-array" } });
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(captured.slice(todoEmptyBefore).every((item) => (
      item.payload?.type !== "todo/write" || item.payload?.activity_content === undefined
    )), "empty, non-string-content, and non-array todos must project no plan body");

    // Test 5: durable host sequence differentiates otherwise identical tool events.
    dshListeners.get("session/event")(parentSession, {
      type: "tool/call", seq: 25, data: { turn: 3, name: "read" },
    });
    dshListeners.get("session/event")(parentSession, {
      type: "tool/call", seq: 26, data: { turn: 3, name: "read" },
    });
    await new Promise((r) => setTimeout(r, 30));
    const repeatedTools = captured.filter((item) => (
      item.source === "dsh" && item.payload.type === "tool/call" && item.payload.turn_id === "3"
    ));
    assert.equal(repeatedTools.length, 2);
    assert.notEqual(repeatedTools[0].payload.eventID, repeatedTools[1].payload.eventID);
    assert.ok(repeatedTools.every((item) => /^[0-9a-f]{64}$/.test(item.payload.eventID)));

    // Test 6: root disposal emits an explicit close; child disposal stays suppressed.
    dshListeners.get("session/disposed")(parentSession);
    dshListeners.get("session/disposed")(childSession);
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(captured.filter((item) => (
      item.source === "dsh"
      && item.payload.type === "session/disposed"
      && item.payload.session_id === "parent-sess-1"
    )).length, 1);
    assert.equal(captured.filter((item) => (
      item.source === "dsh"
      && item.payload.type === "session/disposed"
      && item.payload.session_id === "child-sess-1"
    )).length, 0);

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
