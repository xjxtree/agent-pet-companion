{
  "contract_version": "claude-hooks-2026-07-14-activity-v3",
  "hooks": {
    "SessionStart": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PreToolUse": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PermissionRequest": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PostToolUse": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PostToolUseFailure": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PostToolBatch": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PermissionDenied": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PreCompact": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "PostCompact": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "SubagentStart": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "SubagentStop": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "TaskCreated": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "TaskCompleted": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "Notification": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "Elicitation": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "ElicitationResult": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "Stop": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "StopFailure": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}],
    "SessionEnd": [{"hooks":[{"type":"command","command":"__APC_CLI__ agent hook --source claude_code --event-type auto >/dev/null 2>&1","async":true,"timeout":5}]}]
  }
}
