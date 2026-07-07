# Claude Code Notes

Claude Code agents should treat `AGENTS.md` as the primary repository instruction file. This file only records Claude-specific additions and differences.

## Required Baseline

Read `AGENTS.md` before making changes. Its product scope, architecture, repository layout, safety boundaries, and development guidelines apply to Claude Code work in this repo.

## Claude-Specific Context Order

When starting a task, use this reading order:

1. `AGENTS.md`
2. The user request
3. The relevant design document under `docs/design/`
4. Existing code in the touched area

Do not duplicate or reinterpret the general rules from `AGENTS.md` here. If a rule should apply to every agent, update `AGENTS.md` instead.

## Claude-Specific Notes

- Keep responses explicit about whether a requested behavior is planned, implemented, or not yet available.
- For docs-only changes, verify Markdown links and referenced assets when practical.
- For future code changes, report the exact Swift, Rust, or integration checks that were run. If the project skeleton needed for a check does not exist yet, say that directly.
- When working on Claude Code integration later, keep it in `plugins/claude-code/` and follow the shared event model defined by the active schemas and design docs.
