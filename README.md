<p align="center">
  <img src="logo/transparent/agent-pet-mark-transparent-1024.png" width="160" alt="Agent Pet Companion mark">
</p>

# Agent Pet Companion

[简体中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop companion for coding-agent users. A local desktop pet shows whether an Agent is working, waiting for you, or finished, and its message bubble returns you to the relevant session when a validated route is available.

## Highlights

- **Ready to use** — includes `星雾团子`, `Bytebud 字节芽`, and `桃蕾`, each with complete authored animations.
- **AI Pet Maker** — creates or edits low 192×208 and standard 384×416 pets through Codex. The portable V3 format also accepts high 576×624 packages from an external source-capable workflow.
- **Multi-Agent sessions** — supports Codex, Claude Code, Pi Coding Agent, and OpenCode across projects. Bubbles can group sessions by Agent or show one stable cross-Agent card list that does not reshuffle on every thinking/tool update.
- **Native desktop experience** — the pet, menu, and Liquid Glass session bubble move as one overlay composition. Pet size, bubble text size, attention behavior, and grouping live in Pet Configuration.
- **Local first** — pets, settings, bounded session context, and diagnostics stay on the Mac unless explicitly exported. The App does not read Agent credentials, tokens, cookies, or API keys.

## Product areas

The control center contains five pages: Pet Library, AI Pet Maker, Pet Configuration, Agent Connections, and Service & Diagnostics. First launch uses a resumable three-scene setup instead of adding another navigation page.

The desktop pet stays available after the control-center window closes. Click the pet to expand or collapse its bubble, drag it to move the complete overlay, and click a concrete session row to open its validated destination. Bundled pets are read-only; custom and imported pets can be managed through the library according to their V3 capabilities.

## Install a release

1. Open [GitHub Releases](https://github.com/xjxtree/agent-pet-companion/releases).
2. Download the ZIP for your Mac (`macos-arm64` for Apple silicon or `macos-x86_64` for Intel) and that release's `SHA256SUMS.txt`.
3. Verify the ZIP, for example:

   ```bash
   grep 'macos-arm64.zip' AgentPetCompanion-*-SHA256SUMS.txt | shasum -a 256 -c -
   ```

4. Extract the App and move it to `/Applications`.
5. On first launch, Control-click or right-click the App in Finder and choose **Open**, or use **System Settings → Privacy & Security → Open Anyway**.

Official archives are ad-hoc signed, not Developer ID signed or notarized, so macOS requires that explicit first-open approval. Installation needs no source toolchain and does not require disabling Gatekeeper or removing quarantine from the command line.

The App checks the latest stable GitHub Release after a healthy launch and at most once per 24 hours. It reports an available update but never downloads or installs it automatically; verify the new ZIP, quit the App, replace it in `/Applications`, and open the replacement.

## Build from source

Requirements: macOS 14+, Apple Command Line Tools with Swift 6 and a macOS SDK, the Rust toolchain pinned by `rust-toolchain.toml`, and Python 3. Full Xcode is optional.

```bash
git clone https://github.com/xjxtree/agent-pet-companion.git
cd agent-pet-companion
./script/build_app_bundle.sh
```

The development App is written to `dist/`. To rebuild, launch, and verify App/PetCore build identity during development:

```bash
./script/build_and_run.sh --run
```

## Architecture and documentation

The SwiftUI/AppKit App owns the control center, menu bar, overlay, and rendering. PetCore is the Rust state authority for pets, settings, normalized Agent events, connectors, generation jobs, and diagnostics. They communicate through local JSON-RPC; managed Agent integrations send bounded events through `petcore-cli` or the token-protected local ingress.

- [Documentation index](docs/README.md)
- [`.petpack` V3 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Agent Pet Companion is available under the [MIT License](LICENSE).
