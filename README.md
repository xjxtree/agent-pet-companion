# Agent Pet Companion

[中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop pet app for people who work with coding agents. Use an AI-assisted Studio workflow to design a local pet, place it on your desktop, and let it react to what your agents are doing.

The project is open source and currently in local V1 development. A public installable release is not available yet, but the repository now contains a runnable SwiftPM macOS app, Rust PetCore daemon, CLI, schemas, and phase validation scripts. See the dated [project status](docs/PROJECT_STATUS.md) for the exact validation results and release blockers.

> **AI Pet Studio requirement:** AI pet creation currently supports **Codex only**. The supported end-user setup requires the ChatGPT desktop app to be installed and signed in on this Mac, with Codex available for use. PetCore launches the Codex App Server bundled with ChatGPT to create and resume Studio generation sessions. Claude Code, Pi Coding Agent, and OpenCode integrations provide agent-session activity to the desktop pet, but they are not Pet Studio generation backends.

## What It Does

- Creates personalized desktop pets from your description, style preference, image quality choice, and optional reference images.
- Displays a high-quality floating pet overlay on macOS.
- Lets the pet react to coding-agent activity such as start, tool execution, waiting for confirmation, review needed, completion, and failure.
- Groups active sessions into one native message bubble per agent, showing each session title, current activity or reply, status, and an Open action.
- Keeps pets in a local library so you can enable, remove, inspect, or export them.
- Provides connection checks for Codex, Claude Code, Pi Coding Agent, and OpenCode.

## Core Features

### Pet Studio

Start from a short form, then continue in a Codex App Server conversation to refine the pet's look, motion, and behavior. This is a Codex-only creation workflow: installing or connecting Claude Code, Pi Coding Agent, or OpenCode does not enable Pet Studio generation. Production Studio runs require an image-capable tool to create a complete `skill-full-source`; PetCore accepts it only after provenance, transparent assets, seven states, per-state frame differences, manifest, preview, and build validation all pass. The deterministic materializer remains available only to explicitly simulated validation and is never presented as AI image generation. Verified pets use the local `.petpack` format.

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

Your generated pets stay on your Mac. The library is designed for enabling a pet, checking its asset information, deleting local pets, and exporting `.petpack` files.

## Supported Platforms

- macOS 14 or newer
- Apple Silicon is the primary V1 performance target; a distributable release must also contain a validated `x86_64` slice
- To create pets with AI: the ChatGPT desktop app must be installed and signed in, and Codex must be available to the current user

Windows, cloud accounts, public pet sharing, and public asset galleries are not part of the initial release scope.

## Local Development

No public build is available yet.

Local development requires Xcode 16 or newer with Swift 6, the Rust 1.96.0 toolchain pinned by `rust-toolchain.toml`, and Python 3 for validation helpers. Then run:

```bash
./script/test_all.sh
./script/build_and_run.sh --build-only
./script/build_app_bundle.sh
```

As of 2026-07-15, the default `test_all.sh`, Rust fmt/clippy/tests, and all 79 Swift tests are green. Real connector, real App Server, renderer-budget, packaged-App Studio, and Computer Use seven-state desktop-rendering checks have also been completed. See [project status](docs/PROJECT_STATUS.md) for the exact evidence and user-controlled confirmation items.

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
6. Use Agent Connections to check Codex, Claude Code, Pi Coding Agent, or OpenCode integration.
7. Keep the pet on your desktop while you work with supported agents.

## Privacy And Safety

Agent Pet Companion is designed as a local-first app. It should not read agent auth files, tokens, cookies, API keys, or other secrets. Agent reactions are based on explicit local event channels and project-owned capability tokens.

## License

Agent Pet Companion is released under the [MIT License](LICENSE).
