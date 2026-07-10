import { spawn } from "node:child_process";

const CLI_PATH = __APC_CLI_JSON__;
export const APC_PI_CONTRACT_VERSION = "pi-extension-34582ef3";
export const APC_PI_WAITING_CAPABILITY = "requires-interactive-extension-ui-bridge";

function sessionId(ctx) {
  return ctx?.sessionManager?.getSessionId?.() ?? ctx?.sessionManager?.sessionId;
}

function forward(event, ctx) {
  const allowlisted = {
    type: event?.type,
    session_id: sessionId(ctx),
    tool_name: event?.toolName,
    is_error: event?.isError === true,
    reason: event?.reason,
  };
  const child = spawn(
    CLI_PATH,
    ["agent", "hook", "--source", "pi", "--event-type", "auto"],
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

export default function agentPetCompanion(pi) {
  if (!pi?.on) return;
  pi.on("session_start", async (event, ctx) => forward(event, ctx));
  pi.on("before_agent_start", async (event, ctx) => forward(event, ctx));
  pi.on("agent_start", async (event, ctx) => forward(event, ctx));
  pi.on("tool_call", async (event, ctx) => forward(event, ctx));
  pi.on("tool_execution_start", async (event, ctx) => forward(event, ctx));
  pi.on("tool_execution_end", async (event, ctx) => forward(event, ctx));
  pi.on("agent_settled", async (event, ctx) => forward(event, ctx));
  pi.on("session_shutdown", async (event, ctx) => forward(event, ctx));
}
