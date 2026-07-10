import { spawn } from "node:child_process";

const CLI_PATH = __APC_CLI_JSON__;
export const APC_OPENCODE_CONTRACT_VERSION = "opencode-v1.17.18";

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

function compatibleEvent(event) {
  const type = event?.type;
  const properties = event?.properties ?? {};
  if (!["session.created", "session.status", "session.idle", "session.error", "permission.asked", "permission.updated", "permission.replied"].includes(type)) {
    return undefined;
  }
  return {
    type,
    properties: {
      sessionID: properties?.sessionID ?? properties?.info?.id,
      status: properties?.status?.type,
      response: properties?.response,
    },
  };
}

export const AgentPetCompanion = async () => ({
  event: async ({ event }) => {
    const allowlisted = compatibleEvent(event);
    if (allowlisted) forward(allowlisted);
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
    });
  },
});
