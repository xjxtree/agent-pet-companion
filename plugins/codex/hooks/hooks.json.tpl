{
  "hooks": {
    "SessionStart": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source codex --event-type auto >/dev/null 2>&1"}]}],
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source codex --event-type auto >/dev/null 2>&1"}]}],
    "PreToolUse": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source codex --event-type auto >/dev/null 2>&1"}]}],
    "PermissionRequest": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source codex --event-type auto >/dev/null 2>&1"}]}],
    "PostToolUse": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source codex --event-type auto >/dev/null 2>&1"}]}],
    "Stop": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source codex --event-type auto >/dev/null 2>&1"}]}]
  }
}
