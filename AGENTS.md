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

Before a cross-component change, read the current [system architecture](docs/architecture/overview.md), [runtime and IPC](docs/architecture/runtime-and-ipc.md), and [data model](docs/architecture/data-model.md). Connector work also uses [Agent connector contracts](docs/integrations/agent-connectors.md); pet format work uses the [`.petpack` V3 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md).

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
- Treat local `main` as read-only. Choose either a direct PR to `main` for a hotfix/small isolated change or a task PR to the main Agent's shared `gd-ops/train/*` for parallel/cross-component work; the train then opens one final PR to `main`. Follow [parallel development](docs/development/parallel-development.md).
- Give every Agent/session an independent `gd-ops/task/*` or `gd-ops/fix/*` branch and worktree. One Agent owns each write path; sub-Agents hand work off by PR and never write directly into the train or another Agent's branch.
- The main Agent coordinates a shared train, shared schemas/manifests/version files, changelog-fragment consolidation, dependency order, and the final train PR. Train tasks record user-visible changes under `changes/unreleased/`; direct and final train PRs consume them into root `CHANGELOG.md`.
- Before any handoff, explicitly stage the intended paths, audit the cached diff, commit, require a clean worktree, then push/open and verify the PR. After merge, the coordinator audits every worktree and local branch, fast-forwards local `main` only in a dedicated clean worktree, and removes only owned clean branches whose merged PR and deleted remote ref are proven. Follow the complete [commit and cleanup checklist](docs/development/parallel-development.md).
- Prefer typed schemas and structured parsers over ad hoc string parsing.
- Keep user-facing text bilingual when it belongs in public documentation or product onboarding.
- Record user-visible changes under `[Unreleased]` in root `CHANGELOG.md`; every GitHub Release, tag, and changelog version must match one-to-one.
- Avoid committing generated build output, local credentials, `.env` files, DerivedData, or temporary pet assets.
- Do not read agent auth, token, cookie, API key, or secret files. The app should only consume explicit local event channels and capability tokens designed for this project.
- When adding code, include the smallest useful tests or validation steps for the changed behavior.

## macOS UI Verification And Input Safety

- Use non-interactive command-line checks for builds, unit tests, protocol tests, and other validations that do not require the live macOS UI.
- For live App, menu bar, desktop pet, bubble, window lifecycle, and other macOS UI behavior, Computer Use is recommended when it is available and useful. The executing agent may choose another suitable verification method based on the task and environment.
- Before dispatching any GitHub Release, check out the exact clean `main` commit, launch its test App through `script/build_and_run.sh --run`, and use Computer Use to complete the basic-function acceptance checklist in `docs/release/macos-release.md`. Dispatch only with the same full commit in `commit` and `host_ui_tested_commit` plus `host_ui_result=passed`. If any check fails or cannot be observed, do not publish or claim success: report the evidence and stop so the next action is 交由用户决定.
- Launch verification builds through the project's `script/build_and_run.sh` entry points. Keep host-affecting checks scoped to the intended App or an owned validation runtime, and distinguish directly observed UI behavior from conclusions based only on structural or automated checks.
- Apply these practices to real-device lifecycle testing as well, including launch, close and reopen, quit, update handoff, menu commands, and multi-instance scenarios.

## Product Constraints

- Main navigation has five entries in this order: Pet Library, AI Pet Maker, Pet Configuration, Agent Connections, Service & Diagnostics.
- First run is a resumable three-scene root presentation, not a sixth navigation entry. PetCore settings own only the versioned scene progress; pet choice and Agent actions reuse ordinary product operations, while demo phases remain View-local and never enter Agent events or diagnostics.
- AI Pet Maker contains only new/edit briefs and their AI creation sessions. Pet Library and Service & Diagnostics remain separate top-level pages.
- Agent Connections and desktop bubbles use `Agent → session` across all projects. Project directories and paths are not connection settings, display filters, or user-facing session identities.
- Every projected session uses its latest bounded explicit title when available; until then, its bounded first user message is the display-title fallback. The bounded latest user message and current-turn Agent message remain separate display context. Anonymous-session fallback identity must be stable and content-free, never synthetic display-order numbering or project data.
- Release bundles seed the local library with the validated `星雾团子`, `Bytebud 字节芽`, and `桃蕾` petpacks. Bundled and user pets are identified by stable manifest ID, not display name: same-name/different-ID pets coexist, and seeding never overwrites an existing same-ID local pet.
- Bundled pets are read-only defaults: they can be previewed, enabled, and exported, but not deleted or modified in place. Customization must use a new pet ID.
- Display size is a logical width in points, adjusted only in Pet Configuration → Appearance with a 100–300 pt slider (default 112 pt, 1 pt step, numeric readout, restore-default, keyboard and VoiceOver adjustable). Height derives from the fixed 208/192 canvas ratio. The overlay itself exposes no resize handle, hit region, or hover control; dragging the pet only moves it.
- The pet body remains mouse-interactive and draggable whenever the overlay is visible, including while a frame alpha mask is unavailable during launch or a state transition. A valid mask may pass transparent pixels through, but a missing mask must fall back to the geometric pet region instead of disabling pet interaction.
- Overlay placement has exactly one presentation owner. Dragging uses absolute screen coordinates from a captured start anchor, never accumulated event deltas; every presented frame, including each auxiliary panel, is derived from that anchor rather than from the previous frame, and no other layout pass repositions the composition mid-gesture. Release commits the presented position once with no momentum, projection, or rubber-band. A stale remote snapshot, a late or out-of-order acknowledgement, and a failed save must never change the presented position. The pet and its attached bubble/menu surfaces move as one composition root.
- The session bubble attaches to the pet's top or bottom edge only, never to its left or right, and always at the same authored vertical gap. The side flips when the current one no longer fits; a screen edge changes only the horizontal attachment. Vertical distance is never clamped, shortened, or traded for fit.
- The normalized Agent session events are `start`, `thinking`, `plan`, `tool`, `waiting`, `done`, and `failed`; badge copy may refine `tool` with a closed stable activity subtype, but must never infer thinking from start or generic timestamp churn. The portable package has six semantic actions (`idle`, `thinking`, `tool`, `waiting`, `done`, `failed`) plus three local-only interactions (`acknowledge`, `drag_left`, `drag_right`). Event `start` has no pet reaction and renders idle, while `thinking` and `plan` both use the package `thinking` action. Only an idle primary click selects `acknowledge`; pointer-down without bubble content adds a 160 ms low-amplitude press response and dragging cancels it. Local interactions never emit Agent events, alter or persist semantic state, or add gaze behavior.
- Animation timing is per-frame, not a global rate. Each action declares `frame_durations_ms[]`, one of the V3 playback modes (`loop`, `periodic`, `burst_then_settle`, `burst_then_idle`, `once_then_return`), and a `reduced_motion_frame_index`. Thinking, tool, and done use bounded `burst_then_idle` entries so a long semantic lease returns visually to idle instead of freezing on the final action frame; waiting and failed use `burst_then_settle`. There are no Standard/Smooth playback profiles, package-wide native FPS, or `once_hold`. The runtime plays authored durations directly: it never resamples, retimes, subsamples, restarts an unchanged semantic state, or catches up missed frames after a stall. Final combined producer QA emits an 8–12 second presence preview bound to all nine actions and rejects semantic activity that freezes in under one second or loops mechanically.
- Render resolution has three exact runtime tiers, all 12:13 and independent of display size: `low` 192×208, `standard` 384×416 (default), and `high` 576×624. 192×208 is the hard floor and every width is a multiple of 192, which keeps sheet edges on 16-pixel boundaries. One package uses one tier for every frame. An image model is not required or trusted to return those exact dimensions: every newly generated frame starts as a fully opaque flat-background 12:13 source crop at least as large as its selected target, the shared transparent-frame script retains that source-resolution transparent master, and it may perform one direct linear-light premultiplied-Alpha downscale to the runtime tier. Model-native transparency, upscaling, super-resolution, padding a smaller crop to a target canvas, independent per-pose fit/recentering, cascaded or post-process resizing, ad hoc matte/edge filters, and substituting multiple batches for missing source capacity are invalid. Downscaling never relaxes runtime-size identity, action, distinct-pose, anatomy, prop, crop, continuity, or playback QA. Package/runtime support is broader than producer capability: external source-capable workflows may build `high`, while ChatGPT/Codex built-in `imagegen` and the App's Codex-backed Studio support creation only at `low` and `standard` and must reject `high` before attempting generation.
