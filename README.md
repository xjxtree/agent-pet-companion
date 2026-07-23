<p align="center">
  <img src="logo/transparent/agent-pet-mark-transparent-1024.png" width="160" alt="Agent Pet Companion mark">
</p>

# Agent Pet Companion

[简体中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop companion for people who work with coding agents. You can step away from the chat while a local desktop pet quietly shows whether an Agent is working, needs attention, or has a result ready—and jump back to the relevant session from its bubble.

## Highlight Features

- **Ready out of the box** — includes two built-in pets with complete animations and interactions, so the full desktop-pet experience is available immediately after launch.
- **AI Pet Maker** — create highly customizable pets in virtually any visual style, choose higher-resolution quality when needed, and use AI to modify pets you already own.
- **Multi-agent sessions** — groups Codex, Claude Code, Pi Coding Agent, and OpenCode sessions by Agent across all projects. Each supported concurrent session can appear in its Agent bubble, and a click opens the corresponding host or session when available.
- **Local by design** — pets, settings, bounded session context, and diagnostics stay on the Mac unless you explicitly export a file. AI Pet Maker contacts your configured Codex provider only when you start a creation or edit.

## Features

- **Pet Library** — use the bundled `星雾团子` and `Bytebud 字节芽`, or import, preview, enable, export, and manage your own `.petpack` pets.
- **AI Pet Maker** — describe a pet, choose its style and quality, add reference images, then create or refine it through Codex.
- **Pet Configuration** — choose visibility, appearance, Standard/Smooth motion, and a message-attention preset; source, event, timeout, grouping, and interaction controls remain available under Advanced Settings.
- **Agent Connections** — check, repair, test, or remove integrations for Codex, Claude Code, Pi Coding Agent, and OpenCode.
- **Service & Diagnostics** — confirm that the companion is working, recover unhealthy services, and export a privacy-filtered diagnostics ZIP when support needs more detail.
- **Desktop overlay** — the pet body stays draggable during launch and state changes; resize it from the bottom-right handle, use the right-click menu, and open active agent sessions from native bubbles.

The app is local-first: pets, settings, normalized agent events, and diagnostics remain on the Mac unless the user explicitly exports a file. AI Pet Maker uses the current user's configured Codex provider only after the user starts a creation or edit. The app does not read agent credentials, tokens, cookies, or API keys.

## Installation

### Supported GitHub Release

When a Release is explicitly published as a supported public version:

1. Open [GitHub Releases](https://github.com/xjxtree/agent-pet-companion/releases).
2. Download the ZIP matching your Mac—`macos-arm64` for Apple silicon or `macos-x86_64` for Intel—plus that version's `SHA256SUMS.txt`.
3. In the download directory, verify the selected ZIP, for example: `grep 'macos-arm64.zip' AgentPetCompanion-*-SHA256SUMS.txt | shasum -a 256 -c -`.
4. Extract the archive and move `AgentPetCompanion.app` to `/Applications`.
5. Open the app and follow the three-scene setup: choose an included companion, connect the Agents you use, and watch the clearly labeled local demo.

Supported archives use Developer ID signing, Apple notarization and stapling, and Gatekeeper validation. The published checksum covers the exact downloadable ZIP. No source toolchain or quarantine workaround is part of the supported installation path. Do not run the `x86_64` archive on an Apple silicon Mac: use `arm64` instead, without Rosetta.

Files ending in `-preview.zip` are explicitly ad-hoc-signed **Development Previews**. They are not notarized supported packages and are intended only for informed development handoff; their Release notes must state the narrower validation scope.

### Build from source

Requirements: macOS 14+, Apple Command Line Tools with Swift 6 and a macOS SDK, the Rust toolchain pinned by `rust-toolchain.toml`, and Python 3. Full Xcode is optional for this SwiftPM project.

```bash
git clone https://github.com/xjxtree/agent-pet-companion.git
cd agent-pet-companion
./script/build_app_bundle.sh
```

The ad-hoc-signed development app is written to `dist/`. Add `--archive` only when a separately verified handoff ZIP is needed. During development, this command explicitly quits the old UI host, rebuilds the bundle, opens the new one, and waits for the App/PetCore build identities to match:

```bash
./script/build_and_run.sh --run
```

## Usage

On first launch, the App resumes a short setup until you finish or explicitly skip it. The demo shows thinking, working, needs-attention, and completion using only local presentation state; it does not create Agent activity or diagnostics records. Closing the setup preserves the current scene for the next launch.

After setup, leave the App running and work normally in your Agent. The pet shows working, attention, and result states. A bubble action returns to the exact session when a validated route is available, opens the Agent host when only host-level navigation is safe, and stays unavailable when neither destination is valid.

Open the five management pages only when you want to switch or import a pet, create or edit one, adjust the ambient experience, connect an Agent, or recover and export diagnostics. AI creation requires a working Codex App Server and access through the current user's configured provider. Standard/Smooth playback never changes authored action duration, and Smooth appears only for validated native-20 pets.

Bundled pets are read-only defaults: they can be previewed, enabled, and exported, but not deleted or modified in place. App-created and imported pets can be revised; imported pets without a previous creation conversation start a new edit session from their validated package.

## Architecture

```mermaid
flowchart LR
    User["User"] --> App["macOS App<br/>SwiftUI · AppKit/NSPanel · Metal"]
    App <-->|"JSON-RPC v2 over Unix socket"| Core["PetCore<br/>Rust LaunchAgent"]
    Agents["Codex · Claude Code · Pi · OpenCode"] --> Adapters["Hooks · Plugins · Extensions"]
    Adapters --> CLI["petcore-cli"]
    CLI -->|"Unix socket or capability-token loopback"| Core
    Core --> DB["SQLite"]
    Core --> Store["Local pet revisions · settings · logs"]
    Core --> Codex["Codex App Server"]
    Codex --> Skill["Pet Studio Skill"]
    Skill --> Source["Validated pet source"]
    Source --> Core
```

The macOS App owns the control center, menu-bar entry, desktop overlay, and rendering. PetCore owns durable state, pet validation and revision commits, generation jobs, normalized agent events, connector operations, and diagnostics. The App, PetCore, and `petcore-cli` are released as one versioned runtime set; quitting the UI closes the pet and windows while the PetCore LaunchAgent can continue preserving local event and data continuity.

## Documentation

| Document | Purpose |
|---|---|
| [Documentation index](docs/README.md) | Durable technical documentation and maintenance rules |
| [Product experience contract](docs/product/experience-contract.md) | Target product model and non-negotiable experience decisions |
| [Product refactor execution](docs/development/product-refactor-execution.md) | Dependency-ordered implementation tasks without schedules or milestones |
| [`.petpack` V1 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md) | Portable pet format and producer contract |
| [Contributing](CONTRIBUTING.md) | Development workflow and validation entrypoints |
| [Changelog](CHANGELOG.md) | Versioned user-visible changes for every GitHub Release |

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) before changing behavior or architecture. Keep changes focused, add the smallest useful test, update the durable document that owns the changed contract, and add user-visible changes to the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

## License

Agent Pet Companion is available under the [MIT License](LICENSE).
