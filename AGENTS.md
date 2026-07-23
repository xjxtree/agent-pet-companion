# Agent Instructions

This repository is the workspace for Agent Pet Companion, a native macOS desktop pet app that combines an AI pet studio, a local pet library, a desktop overlay, and multi-agent event responses.

## Sources Of Truth

Use sources in this order when changing behavior or architecture:

1. The current user request.
2. The implementation, typed schemas, runtime manifests, and tests in the touched area.
3. The target [product experience contract](docs/product/experience-contract.md) and, for that refactor, the ordered [product refactor execution](docs/development/product-refactor-execution.md).
4. Durable current-state implementation documentation indexed by `docs/README.md`, including architecture, data, integration, validation, format, and release contracts when relevant.
5. `README.md` / `README.zh-CN.md` for the supported public product surface.

The repository keeps exactly one durable target product contract and one dependency-ordered implementation task document for the current product refactor. Neither document is a progress ledger: do not add dates, milestones, completion percentages, checked task states, transient pass counts, or validation logs. Fresh command output, CI artifacts, commits, issues, and release notes are the evidence for a particular task, commit, or build. If current-state prose disagrees with code, schemas, or tests, investigate the implementation and update the owning durable document instead of recording the discrepancy as status.

The V1 scope is intentionally narrow. Do not add public galleries, sharing/community features, Petdex import, Codex built-in pet asset export, Windows UI, cloud accounts, or a full agent mission-control platform unless the user explicitly changes scope.

## Architecture And Data

Before a product-refactor task, read the [product experience contract](docs/product/experience-contract.md) and execute the matching task from [product refactor execution](docs/development/product-refactor-execution.md). Before a cross-component change, also read the current [system architecture](docs/architecture/overview.md), [runtime and IPC](docs/architecture/runtime-and-ipc.md), and [data model](docs/architecture/data-model.md). Connector work also uses [Agent connector contracts](docs/integrations/agent-connectors.md); pet format work uses the [`.petpack` V1 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md).

PetCore is the normal online state owner. Keep App/PetCore/CLI runtime identities synchronized, route external data through bounded typed validation, preserve ID-based immutable pet revisions, and do not read Agent credential stores. Do not restate the complete architecture in this instruction file; update the owning document and source together.

## Product Refactor Execution

- Execute `R01` through `R14` in the dependency order defined by `docs/development/product-refactor-execution.md`.
- Before changing a task, compare its acceptance contract with the current implementation. If the implementation already satisfies it, run the relevant gate and continue without a no-op rewrite or status-only commit.
- Work on one coherent task slice at a time. Parallel branches are allowed only when the task dependency graph permits them; merge order must preserve the graph.
- Do not mark task progress in the execution document. Use issues, commits, pull requests, CI, and release evidence.
- A task is not complete until implementation, typed contracts, migrations, fixtures, Swift/Rust mirrors, localization, tests, changelog, and the owning current-state document agree where applicable.
- Current implementation and tests remain the runtime truth until a task is actually implemented; do not rewrite current-state architecture documents as if a future task had already shipped.

## Repository Layout

Use the repository layout below unless the codebase establishes a better local pattern:

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
- Record user-visible changes under `[Unreleased]` in root `CHANGELOG.md`; every GitHub Release, tag, and changelog version must match one-to-one.
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

- Main navigation has five entries in this order: Pet Library, AI Pet Maker, Pet Configuration, Agent Connections, Service & Diagnostics.
- AI Pet Maker contains only new/edit briefs and their AI creation sessions. Pet Library and Service & Diagnostics remain separate top-level pages.
- Agent Connections and desktop bubbles use `Agent → session` across all projects. Project directories and paths are not connection settings, display filters, or user-facing session identities.
- Every projected session may show its bounded explicit title or latest user context plus its bounded current-turn Agent message. Anonymous-session fallback identity must be stable and content-free, never synthetic display-order numbering or project data.
- Release bundles seed the local library with the validated `星雾团子` and `Bytebud 字节芽` petpacks. Bundled and user pets are identified by stable manifest ID, not display name: same-name/different-ID pets coexist, and seeding never overwrites an existing same-ID local pet.
- Bundled pets are read-only defaults: they can be previewed, enabled, and exported, but not deleted or modified in place. Customization must use a new pet ID.
- Display size is adjusted on the overlay with a bottom-right resize handle, not through a settings field.
- The pet body remains mouse-interactive and draggable whenever the overlay is visible, including while a frame alpha mask is unavailable during launch or a state transition. A valid mask may pass transparent pixels through, but a missing mask must fall back to the geometric pet region instead of disabling pet interaction.
- The fixed protocol and package states are `idle`, `start`, `tool`, `waiting`, `review`, `done`, and `failed`; UI copy may describe `start` as thinking and `tool` as working without changing the stored names.
- Animation playback has two fixed profiles: 10 FPS standard and 20 FPS smooth. A pet declares a package-wide native rate of 10 or 20 FPS; only a 20 FPS pet may use both playback profiles. Every state declares a fixed 1,000 or 2,000 ms duration, and runtime configuration must never retime the authored action.
