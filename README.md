<p align="center">
  <img src="logo/transparent/agent-pet-mark-transparent-1024.png" width="160" alt="Agent Pet Companion mark">
</p>

# Agent Pet Companion

[简体中文](README.zh-CN.md) | English

**Know what your coding agents are doing without constantly watching the terminal.**

Agent Pet Companion is a native macOS desktop pet for people who work with one or more coding agents. Pet animations and message bubbles show whether an Agent is thinking, using tools, waiting for you, or finished. When it is time to return, an available session destination appears right in the bubble.

[Download the latest release](https://github.com/xjxtree/agent-pet-companion/releases) · macOS 14 or later · Apple silicon and Intel Macs

## What it does for you

- **Switch windows less often** — see Agent activity on your desktop without repeatedly opening a terminal or Agent app.
- **Notice tasks that need you** — get a clear visual response when an Agent needs input, finishes, or fails.
- **Follow several Agents together** — bring activity from Codex, Claude Code, Pi Coding Agent, and OpenCode into one place.
- **Get back to work quickly** — when routing is available, open the relevant session, Agent app, or terminal from the bubble.
- **Make the pet yours** — use one of three bundled pets, import a `.petpack`, or create and edit your own pet with AI Pet Maker.
- **Keep data centered on your Mac** — pets, settings, limited session summaries, and diagnostics remain local. The App does not read Agent credentials, tokens, cookies, or API keys.

## Get started in three steps

1. Download and install the App from [GitHub Releases](https://github.com/xjxtree/agent-pet-companion/releases).
2. Follow the first-run guide to choose a pet and set up the Agents you use.
3. Start a task in your Agent as usual. The pet will automatically show its status and any available return destination.

On first launch, choose `星雾团子`, `Bytebud 字节芽`, or `桃蕾`. After setup, the pet stays on your desktop even when the control center is closed.

## Everyday use

| What you want to do | Where to do it |
|---|---|
| View tasks or expand and collapse messages | Click the pet |
| Move the pet and its bubble | Drag the pet |
| Switch, import, or export pets | Pet Library |
| Create or edit your own pet | AI Pet Maker |
| Change pet size, bubble text, or attention behavior | Pet Configuration |
| Check, install, or repair Agent integrations | Agent Connections |
| Inspect status or troubleshoot a problem | Service & Diagnostics |

Agent Connections is organized by Agent and session, so you do not need to configure every project directory. The App manages only the connection components it installed and leaves custom configuration it cannot safely attribute untouched.

## Create your own pet

In **AI Pet Maker**, describe the appearance, style, and important traits you want to keep. The App uses locally available Codex capabilities to create a new pet or edit an existing one.

- In-App creation supports low and standard resolution.
- Creation progress is retained, and you can answer questions inside the App when a task needs your input.
- You can also import compatible `.petpack` V3 packages, including high-resolution packages made by external workflows.
- The three bundled pets are read-only defaults. Customizing one creates a new pet instead of replacing the original.

## Install a release

1. Open [GitHub Releases](https://github.com/xjxtree/agent-pet-companion/releases).
2. Download the ZIP for your Mac:
   - Apple silicon Mac: `macos-arm64`
   - Intel Mac: `macos-x86_64`
3. Extract the ZIP and move the App to `/Applications`.
4. On first launch, Control-click or right-click the App in Finder and choose **Open**, or use **System Settings → Privacy & Security → Open Anyway**.

Official releases are currently ad-hoc signed rather than Developer ID signed or Apple-notarized, so macOS asks you to approve the first launch. You do not need to disable Gatekeeper or remove quarantine from the command line.

<details>
<summary>Optional: verify your download</summary>

Download the release's `SHA256SUMS.txt`, then run:

```bash
grep 'macos-arm64.zip' AgentPetCompanion-*-SHA256SUMS.txt | shasum -a 256 -c -
```

For an Intel build, replace `macos-arm64.zip` with `macos-x86_64.zip`.

</details>

After a healthy launch, the App checks for the latest stable release at most once per day. It only notifies you; it never downloads or installs updates automatically. Quit the old version and replace the App in `/Applications` to update.

## Privacy

Everyday activity display accepts only bounded task status, titles, and message summaries. It does not copy full conversations or read Agent sign-in credentials. When you use AI Pet Maker, the descriptions and reference images you submit are passed to the locally available Codex workflow for generation; everyday Agent activity and AI creation remain separate flows.

## For developers

Building from source requires macOS 14+, Apple Command Line Tools with Swift 6 and a macOS SDK, the Rust toolchain pinned by `rust-toolchain.toml`, and Python 3. Full Xcode is optional.

```bash
git clone https://github.com/xjxtree/agent-pet-companion.git
cd agent-pet-companion
./script/build_app_bundle.sh
```

The development App is written to `dist/`. To rebuild and launch it:

```bash
./script/build_and_run.sh --run
```

The SwiftUI/AppKit App owns the control center, menu bar, desktop overlay, and rendering. Rust PetCore owns pets, settings, Agent events, connections, creation tasks, and diagnostics. They communicate through local JSON-RPC.

- [Documentation index](docs/README.md)
- [`.petpack` V3 specification](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Agent Pet Companion is available under the [MIT License](LICENSE).
