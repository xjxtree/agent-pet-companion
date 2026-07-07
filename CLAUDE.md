@AGENTS.md

# Claude Code Notes

This file provides Claude Code-specific guidance for this repository. Shared project rules live in `AGENTS.md`, which is included above via `@AGENTS.md`.

## Required Baseline

Treat `AGENTS.md` as the canonical shared instruction entrypoint. Do not duplicate or reinterpret its product scope, architecture, repository layout, safety boundaries, or development guidelines here.

## Claude-Specific Context Order

When starting a task, use this reading order:

1. The user request
2. The relevant design document under `docs/design/`
3. Existing code in the touched area

If a rule should apply to every agent, update `AGENTS.md` instead of adding it to this file.

## Claude-Specific Notes

- Keep responses explicit about whether a requested behavior is planned, implemented, or not yet available.
- For docs-only changes, verify Markdown links and referenced assets when practical.
- For future code changes, report the exact Swift, Rust, or integration checks that were run. If the project skeleton needed for a check does not exist yet, say that directly.
- When working on Claude Code integration later, keep it in `plugins/claude-code/` and follow the shared event model defined by the active schemas and design docs.
