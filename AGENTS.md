# Agent Instructions

This repository is the workspace for Agent Pet Companion, a planned native macOS desktop pet app that combines an AI pet studio, a local pet library, a desktop overlay, and multi-agent event responses.

## Source Of Truth

Before changing product or architecture behavior, read the relevant design docs:

- Product design: `docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md`
- Technical design: `docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md`
- Current implementation and validation status: `docs/PROJECT_STATUS.md`

The V1 scope is intentionally narrow. Do not add public galleries, sharing/community features, Petdex import, Codex built-in pet asset export, Windows UI, cloud accounts, or a full agent mission-control platform unless the user explicitly changes scope.

## Planned Architecture

- macOS app: SwiftUI for app UI, AppKit/NSPanel for the desktop overlay, Metal-backed rendering for pet frames.
- Core service: Rust PetCore daemon with Unix Domain Socket JSON-RPC and SQLite.
- Pet format: app-owned `.petpack`, not a Codex built-in pet compatibility package.
- AI generation: Codex App Server plus an internal Pet Studio Skill.
- Portable generation/editing: the provider-neutral `agent-pet-maker` Skill for image-capable external Agent hosts; import/activation requires explicit user authorization.
- Agent integrations: Codex, Claude Code, Pi Coding Agent, and OpenCode via their supported hooks, plugins, extensions, or event streams.

## Repository Layout

Use the planned repository layout below unless the codebase establishes a better local pattern:

```text
apps/macos/
crates/petcore/
crates/petcore-cli/
crates/petcore-types/
plugins/codex/
plugins/claude-code/
plugins/pi/
plugins/opencode/
skills/agent-pet-studio/
skills/agent-pet-maker/
schemas/
docs/
```

## Development Guidelines

- Keep changes scoped to the user's request, the product baseline, and the architecture already present in the repo.
- Prefer typed schemas and structured parsers over ad hoc string parsing.
- Keep user-facing text bilingual when it belongs in public documentation or product onboarding.
- Avoid committing generated build output, local credentials, `.env` files, DerivedData, or temporary pet assets.
- Do not read agent auth, token, cookie, API key, or secret files. The app should only consume explicit local event channels and capability tokens designed for this project.
- When adding code, include the smallest useful tests or validation steps for the changed behavior.

## macOS UI Verification And Input Safety

- Use non-interactive command-line checks for builds, unit tests, protocol tests, and other validations that do not require the live macOS UI.
- For any live App, menu bar, desktop pet, bubble, window lifecycle, or other macOS UI inspection and interaction, use Computer Use first. Prefer Accessibility state reads and element-based actions so verification does not take over the user's mouse, keyboard, or active input focus.
- Do not default to `open -n`, AppleScript/System Events, CGEvent synthesis, `cliclick`, `pyautogui`, or similar direct GUI and input-control automation for UI verification.
- If Computer Use cannot cover a required UI test and the remaining method may activate an app, steal focus, move the pointer, inject keyboard input, or otherwise interrupt the user, explain the limitation and obtain explicit user approval immediately before using that method.
- Apply these rules to real-device lifecycle testing as well, including launch, close and reopen, quit, update handoff, menu commands, and multi-instance scenarios.

## Product Constraints

- Main navigation has three entries: Pet Studio, Enable & Behavior, Agent Connections.
- Pet Studio has two tabs: New and Pet Library.
- Display size is adjusted on the overlay with a bottom-right resize handle, not through a settings field.
- The fixed pet states are `idle`, `thinking`/`start`, `working`/`tool`, `waiting`, `review`, `done`, and `failed`; keep naming consistent with the active schema once implemented.
- Performance budgets and frame-rate choices should follow the technical plan: 12 FPS standard animation and 20 FPS smooth animation.
