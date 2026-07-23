@AGENTS.md

# Claude Code Notes

Shared project rules live in `AGENTS.md`, included above via `@AGENTS.md`. Do not duplicate shared scope, architecture, safety, or workflow rules here.

Use this context order: user request, `AGENTS.md`, implementation/schemas/manifests/tests in the touched area, then the owning document indexed by `docs/README.md`.

Claude Code connector changes belong in `plugins/claude-code/` and must follow the shared event contracts in the active implementation, schemas, and tests.
