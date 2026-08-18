// Agent Pet Companion - DeepSeek Harness (dsh) connector plugin template
export const APC_DSH_CONTRACT_VERSION = "dsh-v0.1.0-rc.6-events-v1";
export const APC_DSH_CONNECTOR_RELEASE_VERSION = "__APC_CONNECTOR_RELEASE_VERSION__";
export const APC_CLI_PATH = __APC_CLI_JSON__;
export const name = "agent-pet-companion";

export function apply(ctx) {
  // Probe event on startup
  try {
    const { spawn } = require("node:child_process");
    const child = spawn(APC_CLI_PATH, ["agent", "hook", "--source", "dsh", "--event-type", "auto"], {
      stdio: ["pipe", "ignore", "ignore"],
    });
    child.stdin.end(JSON.stringify({ type: "connector.probe", session_id: "probe" }));
  } catch (_) {}
}
