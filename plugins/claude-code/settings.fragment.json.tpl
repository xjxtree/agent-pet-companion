{
  "contract_version": "claude-hooks-2026-07-10",
  "hooks": {
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PreToolUse": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PermissionRequest": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PostToolUse": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PostToolUseFailure": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "Stop": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "StopFailure": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}]
  }
}
