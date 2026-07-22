<p align="center">
  <img src="logo/transparent/agent-pet-mark-transparent-1024.png" width="160" alt="Agent Pet Companion mark">
</p>

# Agent Pet Companion

[简体中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop companion for people who work with coding agents. It keeps pets local, shows them in a lightweight desktop overlay, and turns agent activity into visible pet states and session bubbles.

## Highlight Features

- **Ready out of the box** — includes two built-in pets with complete animations and interactions, so the full desktop-pet experience is available immediately after launch.
- **AI Pet Maker** — create highly customizable pets in virtually any visual style, choose higher-resolution quality when needed, and use AI to modify pets you already own.
- **Multi-agent sessions** — displays sessions and synchronizes status for Claude Code, ChatGPT Codex, Pi Coding Agent, and OpenCode. Click a pet message to jump directly to the corresponding session.
- **Rich pet configuration** — customize message-bubble transparency, session response rules, multi-session stacking, appearance, interaction, and other pet behavior.

## Features

- **Pet Library** — use the bundled `星雾团子` and `Bytebud 字节芽`, or import, preview, enable, export, and manage your own `.petpack` pets.
- **AI Pet Maker** — describe a pet, choose its style and quality, add reference images, then create or refine it through Codex.
- **Pet Configuration** — control visibility, bubbles, appearance, interaction, session grouping, and animation profile.
- **Agent Connections** — check, repair, test, or remove integrations for Codex, Claude Code, Pi Coding Agent, and OpenCode.
- **Service & Diagnostics** — inspect PetCore, local RPC, event-channel, and renderer health, then export a privacy-filtered diagnostics ZIP when needed.
- **Desktop overlay** — drag the pet, resize it from the bottom-right handle, use the right-click menu, and open active agent sessions from native bubbles.

The app is local-first: pets, settings, normalized agent events, and diagnostics remain on the Mac unless the user explicitly exports a file. It does not read agent credentials, tokens, cookies, or API keys.

## Installation

### GitHub Release

When a signed release is available:

1. Open [GitHub Releases](https://github.com/xjxtree/agent-pet-companion/releases).
2. Download the signed, notarized `AgentPetCompanion-macos-universal.zip` and its SHA-256 file for the version you want.
3. In the download directory, run `shasum -a 256 -c AgentPetCompanion-macos-universal.zip.sha256`.
4. Extract the archive and move `AgentPetCompanion.app` to `/Applications`.
5. Open the app and complete the checks under **Agent Connections**.

Only a Developer ID-signed, Apple-notarized package published on GitHub Releases is a supported public release. A development ZIP is for informal handoff only.
If the Releases page has no signed package, use the source-build workflow below.

### Build from source

Requirements: macOS 14+, Xcode 16+ with Swift 6, the Rust toolchain pinned by `rust-toolchain.toml`, and Python 3.

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

1. Open **Pet Library** and enable one of the bundled pets, or import your own `.petpack`.
2. Open **AI Pet Maker** to create a pet. This in-app workflow requires the ChatGPT desktop app to be installed and signed in, with Codex available to the current user.
3. Use **Pet Configuration** to choose the appearance, bubbles, input behavior, grouping, and frame-rate profile.
4. Use **Agent Connections** to install or verify the integrations you use.
5. Keep the app running while working with an agent. The pet reacts to start, tool, waiting, review, done, and failed events.
6. If something goes wrong, open **Service & Diagnostics**, export a diagnostics ZIP, and attach it to the issue.

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

The macOS App owns the control center, menu-bar entry, desktop overlay, and rendering. PetCore owns durable state, pet validation and revision commits, generation jobs, normalized agent events, connector operations, and diagnostics. The two components are released as one versioned runtime set; quitting the UI closes the pet and windows while the PetCore LaunchAgent can continue preserving local event and data continuity.

## Documentation

| Document | Purpose |
|---|---|
| [Documentation index](docs/README.md) | Durable technical documentation and maintenance rules |
| [Architecture overview](docs/architecture/overview.md) | Components, boundaries, data flow, and repository map |
| [Runtime and IPC](docs/architecture/runtime-and-ipc.md) | Process lifecycle, runtime compatibility, transports, RPC, and diagnostics |
| [Data model](docs/architecture/data-model.md) | SQLite entities, file-backed revisions, schemas, and invariants |
| [Agent integrations](docs/integrations/agent-connectors.md) | Connector installation, event normalization, trust, and privacy boundaries |
| [`.petpack` V1 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md) | Portable pet format and producer contract |
| [Validation profiles](docs/development/validation.md) | What each automated or real-runtime gate proves |
| [macOS release procedure](docs/release/macos-release.md) | Signing, notarization, acceptance, and GitHub Release workflow |
| [Changelog](CHANGELOG.md) | Versioned user-visible changes for every GitHub Release |

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) before changing behavior or architecture. Keep changes focused, add the smallest useful test, update the durable document that owns the changed contract, and add user-visible changes to the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

## License

Agent Pet Companion is available under the [MIT License](LICENSE).
