# Agent Instructions

Agent Pet Companion is a native macOS desktop pet app with an AI pet studio, local pet library, desktop overlay, and Agent session responses.

## Sources And Scope

Use the current user request, then the touched implementation/typed contracts/tests, then the owning document in [docs/README.md](docs/README.md), then the public README. Investigate prose/code disagreements and update the owning document. Keep durable current-state contracts in the repository; task plans, audits, progress logs, and command evidence belong in PRs, CI, issues, or release notes.

Keep the existing V1 scope: no public galleries, sharing/community features, Petdex import, Codex built-in pet asset export, Windows UI, cloud accounts, or full mission-control platform unless the user changes scope. DeepSeek Harness is supported.

## Required Boundaries

- Keep local `main` read-only. Before editing, follow the [development workflow](docs/development/parallel-development.md): use an independent `gd-ops/task/*` or `gd-ops/fix/*` branch/worktree, register ownership, and use one writer per path. Choose a direct PR for small isolated work or the shared train for parallel/cross-component work. Sub-Agents hand off through PRs.
- Complete the workflow's explicit staging, cached-diff audit, clean commit, push/PR verification, and post-merge audit. Remove only owned clean worktrees/branches with proven merged PRs and absent remote refs; fast-forward `main` only in its dedicated clean worktree.
- Record user-visible changes once as unique typed fragments in `changes/unreleased/`. Only an explicit release-preparation branch consumes them into root `CHANGELOG.md`.
- PetCore owns normal online state. Keep App/PetCore/CLI runtime identities synchronized; use bounded typed validation for external data and ID-based immutable pet revisions.
- Do not read Agent auth, token, cookie, API-key, or secret files. Integrations consume only explicit local event channels and project capability tokens. Never commit credentials, `.env`, generated builds, DerivedData, or temporary pet assets.
- Keep public documentation and product onboarding bilingual. Use existing focused checks and add the smallest useful regression coverage for changed behavior; complete the required local and CI gates.

## Read For The Task

Read the applicable entries before changing that area; do not load unrelated procedures. Cross-component behavior changes require all three architecture documents. Read-only questions use only the relevant contracts.

| Task | Required reference and what it owns |
|---|---|
| Codex model/configuration | [Project defaults](docs/development/parallel-development.md#codex-project-defaults--codex-项目默认设置): GPT-6 Astra, explicit user choices, inherited reasoning, and the separate PetCore Studio default; [project config](.codex/config.toml) owns the setting |
| Product/UI/component ownership | [Architecture overview](docs/architecture/overview.md): product boundaries, five-page navigation, first run, component and repository maps |
| Startup, windows, overlay, dragging, bubbles, rendering, runtime replacement | [Runtime and IPC](docs/architecture/runtime-and-ipc.md): lifecycle, placement, pointer ownership, attachment geometry, and process contracts |
| Persistence, settings, session projections, pet library/revisions | [Data model](docs/architecture/data-model.md): state ownership, display size, stable identity, bundled pets, and immutable publication |
| Agent connectors, event mapping, session titles, routing | [Agent connectors](docs/integrations/agent-connectors.md): explicit semantic events, bounded session context, navigation, and managed operations |
| Pet format, animation, timing, resolution, generation, or production QA | [Petpack V3](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md): nine actions, authored playback, source capacity, transparent frames, and production gates; use the applicable Maker/Studio Skill for execution |
| Validation or live macOS checks | [Validation profiles](docs/development/validation.md) and [contributor validation](CONTRIBUTING.md#validation--验证): focused checks, build entrypoints, scoped host effects, and evidence boundaries |
| Branches, shared paths, PR delivery, merge, or cleanup | [Development workflow](docs/development/parallel-development.md): direct/train procedures, ownership, commit checklist, and repository audit |
| Official GitHub Release | [macOS release](docs/release/macos-release.md): exact-commit acceptance, dispatch, assets, and installation |

## Release Gate

Before any GitHub Release dispatch, use the exact clean `main` commit, launch its test App through `script/build_and_run.sh --run`, and complete the release document's stress and Computer Use acceptance. Dispatch only with that same full `commit` and `host_ui_tested_commit` plus `host_ui_result=passed`. If a check fails or cannot be observed, do not publish or claim success: preserve the evidence and stop; the next action is 交由用户决定.
