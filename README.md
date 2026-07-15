# Agent Pet Companion

[中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop pet app for people who work with coding agents. Use an AI-assisted Studio workflow to design a local pet, place it on your desktop, and let it react to what your agents are doing.

The project is open source and currently in local V1 development. A public installable release is not available yet, but the repository now contains a runnable SwiftPM macOS app, Rust PetCore daemon, CLI, schemas, and phase validation scripts. See the dated [project status](docs/PROJECT_STATUS.md) for the exact validation results and release blockers.

> **In-app AI Pet Studio requirement:** the Studio built into the macOS app currently uses **Codex only**. The supported end-user setup requires the ChatGPT desktop app to be installed and signed in on this Mac, with Codex available for use. PetCore launches the Codex App Server bundled with ChatGPT to create, modify, and resume Studio sessions. Image-capable Claude Code, Pi, Hermes, OpenCode, and other Agent Skills hosts can instead use the portable `agent-pet-maker` skill to create or revise a `.petpack` outside the app and then import it; they are not in-app Studio backends.

## What It Does

- Creates personalized desktop pets from your description, style preference, image quality choice, and optional reference images.
- Displays a high-quality floating pet overlay on macOS.
- Lets the pet react to coding-agent activity such as start, tool execution, waiting for confirmation, review needed, completion, and failure.
- Groups active sessions into one native message bubble per agent, showing each session title, current activity or reply, status, and an Open action.
- Keeps pets in a local library so you can enable, remove, inspect, atomically export, reimport, or revise them through Codex.
- Provides connection checks for Codex, Claude Code, Pi Coding Agent, and OpenCode.

## Core Features

### Pet Studio

Start from a short form, then continue in a Codex App Server conversation to refine the pet's look, motion, and behavior. The app can also start a new Codex edit conversation for any library pet, including an externally imported one. Edits use the current package as an untrusted, validated baseline, preserve its pet ID, commit as an immutable revision, and reject a stale result if the base changed while Codex was working. This is the in-app Codex workflow; connecting another Agent does not turn it into an in-app Studio backend. Production Studio runs require an image-capable tool to create a complete `skill-full-source`; PetCore accepts it only after provenance, transparent assets, seven states, per-state frame differences, manifest, preview, and build validation all pass. The deterministic materializer remains available only to explicitly simulated validation and is never presented as AI image generation.

### Desktop Overlay

The pet appears as a floating macOS overlay. Drag with the primary button to move it, resize it from the bottom-right handle, and use right-click to open the native quick menu; a primary-button click has no extra UI response.

### Agent Reactions

Agent Pet Companion listens to supported local agent event channels and maps agent states to pet animations:

- Started work: start
- Running tools: tool
- Waiting for confirmation: waiting
- Needs review: review
- Completed: done
- Failed: failed

The macOS app is a lightweight single-instance UI host for the control center, menu-bar item, desktop pet, and message bubbles. Closing the control-center window keeps the host and pet running; standard Quit exits all UI while the independent PetCore LaunchAgent remains available for event and data continuity.

### Local Pet Library

Your generated pets stay on your Mac. Every imported package crosses the same PetCore validator. The library supports enabling, inspecting, deleting, atomic `.petpack` export, lossless reimport, and starting a same-ID Codex revision for both app-created and imported pets.

### Portable `.petpack` workflow

The complete v1 format and compatibility policy are documented in the [Petpack v1 whitepaper](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md). A package conforming to that contract can be imported and run regardless of which tool produced it.

The provider-neutral [`agent-pet-maker`](skills/agent-pet-maker/SKILL.md) skill is bundled with development app packages and can be given to Claude Code, Pi, Hermes, OpenCode, or another Agent Skills host that has real image understanding and image generation/editing. It supports `create` and `modify`, uses `petcore-cli` as the final validator/builder, preserves IDs during modification, verifies unchanged state hashes, and returns `capability_missing` rather than fabricating images when the host lacks a real image tool. Creating or finalizing a package never changes the library. The separate online `install` command is available only when the user explicitly asks to import it; activation requires a second explicit `--activate` choice and never enables global desktop-pet behavior.

Copy the **entire** `agent-pet-maker` directory, including `references/`, `scripts/`, and `tests/`; copying only `SKILL.md` is not sufficient. In this repository it lives at `skills/agent-pet-maker/`; in a built app it lives under `AgentPetCompanion.app/Contents/Resources/skills/agent-pet-maker/`. Current host locations are:

| Host | Personal skill location | Invocation |
|---|---|---|
| [Claude Code](https://code.claude.com/docs/en/skills) | `~/.claude/skills/agent-pet-maker/` | Ask naturally or run `/agent-pet-maker`. |
| [Pi](https://pi.dev/docs/latest/skills) | `~/.pi/agent/skills/agent-pet-maker/` or `~/.agents/skills/agent-pet-maker/` | Ask naturally or run `/skill:agent-pet-maker`. Pi also accepts `--skill <path>`. |
| [Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills) | `~/.hermes/skills/agent-pet-maker/` | Ask naturally or run `/agent-pet-maker`. |
| [OpenCode](https://opencode.ai/docs/skills/) | `~/.config/opencode/skills/agent-pet-maker/` or `~/.agents/skills/agent-pet-maker/` | Ask naturally; OpenCode loads it through its native `skill` tool. |

Project-local locations documented by each host also work. Review the skill before installing it: it executes its bundled Python helper and the App-provided `petcore-cli`, but it must not read Agent credentials or silently mutate the pet library.

## Supported Platforms

- macOS 14 or newer
- Apple Silicon is the primary V1 performance target; a distributable release must also contain a validated `x86_64` slice
- For the in-app AI Studio: the ChatGPT desktop app must be installed and signed in, and Codex must be available to the current user. The external portable Skill instead requires a supported Agent host with real image capabilities plus the App-provided `petcore-cli`.

Windows, cloud accounts, public pet sharing, and public asset galleries are not part of the initial release scope.

## Local Development

No public build is available yet.

Local development requires Xcode 16 or newer with Swift 6, the Rust 1.96.0 toolchain pinned by `rust-toolchain.toml`, and Python 3 for validation helpers. Then run:

```bash
./script/test_all.sh
./script/build_and_run.sh --build-only
./script/build_app_bundle.sh
```

As of 2026-07-16, the default validation, Rust fmt/clippy/tests, and all 95 Swift tests across 10 suites are green. Real connector, real App Server, renderer-budget, packaged-App Studio, and Computer Use seven-state desktop-rendering checks have also been completed. See [project status](docs/PROJECT_STATUS.md) for the exact evidence and user-controlled confirmation items.

The default commands are isolated and never launch the GUI, mutate LaunchAgents, invoke real agents, or read credentials. Host UI checks require `APC_VALIDATE_HOST_UI=1`; real connector and real App Server checks each have their own explicit opt-in gate.

`script/build_and_run.sh` builds the Rust workspace, builds the SwiftPM GUI app, stages `dist/AgentPetCompanion.app`, bundles `petcore` and `petcore-cli`, and—only with the explicit host-UI verification gate—launches an owned process against an isolated temporary app home.

Validation is split into `fast/core`, `simulated integration`, `macos runtime`, `real agent connectors`, `real app server`, and `perf/nightly` profiles; see [script/validate_profiles.md](script/validate_profiles.md). `script/test_all.sh` labels simulated checks explicitly and prints skip reasons for real runtime gates.

Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md). `script/build_app_bundle.sh` now also creates the ad-hoc-signed `dist/AgentPetCompanion-develop.zip` for informal development handoff; it is not a public release. The universal Developer ID signing/notarization procedure is documented in [docs/release/macos-release.md](docs/release/macos-release.md).

When the first signed release is ready, installation will be provided through GitHub Releases:

1. Download the signed macOS release package.
2. Move Agent Pet Companion to `Applications`.
3. Open the app and follow the in-app connection checks.

Current simulated AI validation uses a deterministic local Pet Studio preview only when the validation script explicitly enables it. If `CODEX_APP_SERVER_CMD` is unavailable, the probe reports an action/skip reason. `script/validate_real_app_server.sh` verifies the real stdio boundary; strict external-source mode additionally rejects the deterministic helper and requires image-generation/reference-derived provenance plus visible frame and state differences.

For development and validation, PetCore can fall back to a standalone `codex` executable on `PATH` or an explicit `CODEX_APP_SERVER_CMD`. These are developer overrides; the supported end-user Pet Studio path is the Codex App Server bundled with the ChatGPT desktop app.

The packaged-App acceptance has also completed one exact real artifact end to end: `星雾团子` was image-generated by Codex, validated and imported, enabled in the library, and rendered through all seven pet states. Pet Studio's internal Codex generation task is excluded from normal Agent conversation bubbles.

For current-machine agent connector acceptance, run the packaged app first, then use:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
```

This sends diagnostic-only events through the installed Codex, Claude Code, Pi, and OpenCode connector files and reads them back from the current app. It does not read agent auth, token, or cookie files.

## Basic Usage

1. Open Agent Pet Companion.
2. Go to Pet Studio and describe the pet you want.
3. Choose a style preset, image quality, and optional reference image.
4. Start the AI-assisted session and refine the verified source through conversation.
5. Enable the generated pet from the local library.
6. Use **AI Modify** on any library pet, or export a `.petpack` for a portable Agent Skill workflow and reimport the result.
7. Use Agent Connections to check Codex, Claude Code, Pi Coding Agent, or OpenCode integration.
8. Keep the pet on your desktop while you work with supported agents.

## Privacy And Safety

Agent Pet Companion is designed as a local-first app. It should not read agent auth files, tokens, cookies, API keys, or other secrets. Agent reactions are based on explicit local event channels and project-owned capability tokens.

## License

Agent Pet Companion is released under the [MIT License](LICENSE).
