# Agent Instructions

This repository is the workspace for Agent Pet Companion, a native macOS desktop pet app that combines an AI pet studio, a local pet library, a desktop overlay, and multi-agent event responses.

## Sources Of Truth

Use sources in this order when changing behavior or architecture:

1. The current user request.
2. The implementation, typed schemas, runtime manifests, and tests in the touched area.
3. Durable current-state implementation documentation indexed by `docs/README.md`, including architecture, data, integration, validation, format, and release contracts when relevant.
4. `README.md` / `README.zh-CN.md` for the supported public product surface.

The repository keeps durable current-state documentation, not completed design proposals, task plans, progress ledgers, dated audits, or implementation diaries. Fresh command output, CI artifacts, commits, issues, and release notes are the evidence for a particular task, commit, or build. If current-state prose disagrees with code, schemas, or tests, investigate the implementation and update the owning durable document instead of recording the discrepancy as status.

The V1 scope is intentionally narrow. Do not add public galleries, sharing/community features, Petdex import, Codex built-in pet asset export, Windows UI, cloud accounts, or a full agent mission-control platform unless the user explicitly changes scope.

## Architecture And Data

Before a cross-component change, read the current [system architecture](docs/architecture/overview.md), [runtime and IPC](docs/architecture/runtime-and-ipc.md), and [data model](docs/architecture/data-model.md). Connector work also uses [Agent connector contracts](docs/integrations/agent-connectors.md); pet format work uses the [`.petpack` V2 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V2.md).

PetCore is the normal online state owner. Keep App/PetCore/CLI runtime identities synchronized, route external data through bounded typed validation, preserve ID-based immutable pet revisions, and do not read Agent credential stores. Do not restate the complete architecture in this instruction file; update the owning document and source together.

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
- First run is a resumable three-scene root presentation, not a sixth navigation entry. PetCore settings own only the versioned scene progress; pet choice and Agent actions reuse ordinary product operations, while demo phases remain View-local and never enter Agent events or diagnostics.
- AI Pet Maker contains only new/edit briefs and their AI creation sessions. Pet Library and Service & Diagnostics remain separate top-level pages.
- Agent Connections and desktop bubbles use `Agent → session` across all projects. Project directories and paths are not connection settings, display filters, or user-facing session identities.
- Every projected session uses its latest bounded explicit title when available; until then, its bounded first user message is the display-title fallback. The bounded latest user message and current-turn Agent message remain separate display context. Anonymous-session fallback identity must be stable and content-free, never synthetic display-order numbering or project data.
- Release bundles seed the local library with the validated `星雾团子` and `Bytebud 字节芽` petpacks. Bundled and user pets are identified by stable manifest ID, not display name: same-name/different-ID pets coexist, and seeding never overwrites an existing same-ID local pet.
- Bundled pets are read-only defaults: they can be previewed, enabled, and exported, but not deleted or modified in place. Customization must use a new pet ID.
- Display size is a logical width in points, adjusted only in Pet Configuration → Appearance with an 80–224 pt slider (default 112 pt, 1 pt step, numeric readout, restore-default, keyboard and VoiceOver adjustable). Height derives from the fixed 208/192 canvas ratio. The overlay itself exposes no resize handle, hit region, or hover control; dragging the pet only moves it.
- The pet body remains mouse-interactive and draggable whenever the overlay is visible, including while a frame alpha mask is unavailable during launch or a state transition. A valid mask may pass transparent pixels through, but a missing mask must fall back to the geometric pet region instead of disabling pet interaction.
- Overlay placement has exactly one presentation owner. Dragging uses absolute screen coordinates from a captured start anchor, never accumulated event deltas; release commits the presented position once with no momentum, projection, or rubber-band. A stale remote snapshot, a late or out-of-order acknowledgement, and a failed save must never change the presented position. The pet and its attached bubble/menu surfaces move as one composition root.
- The fixed protocol and package states are `idle`, `start`, `tool`, `waiting`, `review`, `done`, and `failed`; UI copy may describe `start` as thinking and `tool` as working without changing the stored names.
- Animation timing is per-frame, not a global rate. Each state declares `frame_durations_ms[]`, a playback mode (`loop`, `once_hold`, `periodic`, `burst_then_settle`), and a `reduced_motion_frame_index`. There are no Standard/Smooth playback profiles and no package-wide native FPS. The runtime plays the authored durations directly: it never resamples, retimes, subsamples, restarts an unchanged semantic state, or catches up missed frames after a stall.
- Render resolution has two tiers, both 12:13 and independent of display size: `low` 192×208 and `standard` 384×416 (default). 192×208 is the hard floor and both widths are multiples of 192, which keeps both sheet edges on 16-pixel boundaries for the image generator. One package uses one tier for every frame; upscaling, super-resolution, padding a smaller crop to a target canvas, or substituting multiple batches for missing native single-batch capacity is invalid. The qualified image path does not preserve native 576×624 cells, so do not reintroduce `high` or any larger tier without a new source-capacity qualification and a contract revision.
