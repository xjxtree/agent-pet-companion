# Agent Pet Companion

[中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop pet app for people who work with coding agents. Use an AI-assisted Studio workflow to design a local pet, place it on your desktop, and let it react to what your agents are doing.

The project is open source and currently in local V1 development. A public installable release is not available yet, but the repository now contains a runnable SwiftPM macOS app, Rust PetCore daemon, CLI, schemas, and phase validation scripts.

## What It Does

- Creates personalized desktop pets from your description, style preference, image quality choice, and optional reference images.
- Displays a high-quality floating pet overlay on macOS.
- Lets the pet react to coding-agent activity such as start, tool execution, waiting for confirmation, review needed, completion, and failure.
- Keeps pets in a local library so you can enable, remove, inspect, or export them.
- Provides connection checks for Codex, Claude Code, Pi Coding Agent, and OpenCode.

## Core Features

### Pet Studio

Start from a short form, then continue in an AI conversation to refine the pet's look, motion, and behavior. The current built-in materializer produces a deterministic animated preview; it is not presented as AI image generation. A source is labeled `skill-full-source` only when an image-capable App Server tool created visibly distinct frame sequences and passed semantic validation. Saved previews and verified sources both use the local `.petpack` format.

### Desktop Overlay

The pet appears as a floating macOS overlay. You can drag it around, resize it from the bottom-right handle, and open a quick menu from the pet itself.

### Agent Reactions

Agent Pet Companion listens to supported local agent event channels and maps agent states to pet animations:

- Started work: start
- Running tools: tool
- Waiting for confirmation: waiting
- Needs review: review
- Completed: done
- Failed: failed

### Local Pet Library

Your generated pets stay on your Mac. The library is designed for enabling a pet, checking its asset information, deleting local pets, and exporting `.petpack` files.

## Supported Platforms

- macOS 14 or newer
- Apple Silicon is the primary V1 performance target; a distributable release must also contain a validated `x86_64` slice

Windows, cloud accounts, public pet sharing, and public asset galleries are not part of the initial release scope.

## Local Development

No public build is available yet.

Local development requires Xcode 16 or newer with Swift 6, the Rust 1.96.0 toolchain pinned by `rust-toolchain.toml`, and Python 3 for validation helpers. Then run:

```bash
./script/test_all.sh
./script/build_and_run.sh --build-only
./script/build_app_bundle.sh
```

The default commands are isolated and never launch the GUI, mutate LaunchAgents, invoke real agents, or read credentials. Host UI checks require `APC_VALIDATE_HOST_UI=1`; real connector and real App Server checks each have their own explicit opt-in gate.

`script/build_and_run.sh` builds the Rust workspace, builds the SwiftPM GUI app, stages `dist/AgentPetCompanion.app`, bundles `petcore` and `petcore-cli`, and—only with the explicit host-UI verification gate—launches an owned process against an isolated temporary app home.

Validation is split into `fast/core`, `simulated integration`, `macos runtime`, `real agent connectors`, `real app server`, and `perf/nightly` profiles; see [script/validate_profiles.md](script/validate_profiles.md). `script/test_all.sh` labels simulated checks explicitly and prints skip reasons for real runtime gates.

Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md). The exact universal signing/notarization procedure is documented in [docs/release/macos-release.md](docs/release/macos-release.md); an unsigned development bundle is not a distributable release.

When the first signed release is ready, installation will be provided through GitHub Releases:

1. Download the signed macOS release package.
2. Move Agent Pet Companion to `Applications`.
3. Open the app and follow the in-app connection checks.

Current simulated AI validation uses a deterministic local Pet Studio preview only when the validation script explicitly enables it. If `CODEX_APP_SERVER_CMD` is unavailable, the probe reports an action/skip reason. `script/validate_real_app_server.sh` verifies the real stdio boundary; strict external-source mode additionally rejects the deterministic helper and requires image-generation/reference-derived provenance plus visible frame and state differences.

For current-machine agent connector acceptance, run the packaged app first, then use:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
```

This sends diagnostic-only events through the installed Codex, Claude Code, Pi, and OpenCode connector files and reads them back from the current app. It does not read agent auth, token, or cookie files.

## Basic Usage

1. Open Agent Pet Companion.
2. Go to Pet Studio and describe the pet you want.
3. Choose a style preset, image quality, and optional reference image.
4. Start the AI-assisted session and refine the preview or verified source through conversation.
5. Enable the generated pet from the local library.
6. Use Agent Connections to check Codex, Claude Code, Pi Coding Agent, or OpenCode integration.
7. Keep the pet on your desktop while you work with supported agents.

## Privacy And Safety

Agent Pet Companion is designed as a local-first app. It should not read agent auth files, tokens, cookies, API keys, or other secrets. Agent reactions are based on explicit local event channels and project-owned capability tokens.

## License

Agent Pet Companion is released under the [MIT License](LICENSE).
