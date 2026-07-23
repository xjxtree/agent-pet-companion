# macOS Release Procedure / macOS 发布流程

An Agent Pet Companion GitHub Release is one versioned runtime set published as two architecture-specific archives: one for Apple silicon (`arm64`) and one for Intel (`x86_64`). Both archives come from the same commit, version, build number, and shared runtime build ID. Each archive contains the macOS App, PetCore, `petcore-cli`, runtime manifest, bundled Skills, and bundled pets; the manifest binds the schema and connector-contract versions implemented by those components.

Agent Pet Companion 的 GitHub Release 是同一版本运行时集合，分别提供 Apple 芯片（`arm64`）与 Intel（`x86_64`）两个架构专用归档。两个归档必须来自同一 commit、版本号、build number 与共享 runtime build ID。每个归档包含 macOS App、PetCore、`petcore-cli`、runtime manifest、内置 Skills 与内置宠物；runtime manifest 绑定这些组件实际实现的 schema 与连接器契约版本。

During the current development stage, release Apps use ad-hoc signatures for bundle-integrity checks. A Developer ID certificate, Apple notarization, stapling, Gatekeeper assessment, a universal binary, and acceptance on separate physical Macs are not release gates. Release notes and installation guidance must clearly state that the archives are ad-hoc signed and not notarized.

当前开发阶段的 Release App 使用 ad-hoc 签名校验包完整性。Developer ID 证书、Apple 公证、staple、Gatekeeper 评估、universal 二进制以及分别使用不同实机验收，都不是发布门槛。Release notes 与安装指引必须明确说明归档采用 ad-hoc 签名且未公证。

## 1. Freeze version and changelog / 冻结版本与变更记录

Choose a semantic version `X.Y.Z` and positive build number. The Git tag must be `vX.Y.Z`.

Before the release build:

1. confirm every user-visible change is under `[Unreleased]` in [CHANGELOG.md](../../CHANGELOG.md);
2. rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`;
3. add a new empty `[Unreleased]` section above it;
4. verify no other changelog section, tag, or GitHub Release uses the same version;
5. keep validation logs and pending work out of the changelog.

发布前选择语义版本 `X.Y.Z` 和正整数 build，tag 必须为 `vX.Y.Z`；将 CHANGELOG 的 `[Unreleased]` 改为 `[X.Y.Z] - YYYY-MM-DD`，在上方新建空的 `[Unreleased]`，并确认版本唯一。CHANGELOG 只记录用户可见变化，不保存测试日志或待办。

The generated `apc.runtime-manifest.v1` binds the App version/build/shared build ID, PetCore RPC and component build IDs, SQLite range, event schema, `.petpack` read/write versions, and connector contracts. See [Runtime and IPC](../architecture/runtime-and-ipc.md).

## 2. Prepare the build environment / 准备构建环境

Required:

- macOS 14 or later;
- Apple Command Line Tools with Swift 6 and a macOS SDK;
- Rust 1.96.0 with `aarch64-apple-darwin` and `x86_64-apple-darwin` targets;
- Python 3, `rg`, `ditto`, `codesign`, `lipo`, and `shasum`.

Install the Rust targets once:

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

Full Xcode is optional. Without it, contributors cannot use the Xcode GUI or Xcode Archive/Export workflows, and this project does not attempt Developer ID signing or Apple's notarization workflow. Those limitations do not block the Swift Package Manager build, architecture-specific App assembly, ad-hoc signing, ZIP creation, or packaged functional validation used by this release process.

完整 Xcode 为可选项。没有完整 Xcode 时，无法使用 Xcode GUI 或 Xcode Archive/Export 流程，本项目也不会尝试 Developer ID 签名和 Apple 公证流程；但这不影响当前发布流程所需的 Swift Package Manager 构建、架构专用 App 组装、ad-hoc 签名、ZIP 生成与包内功能校验。

## 3. Run the source gate / 运行源码门禁

Run fresh checks for the release commit:

```bash
./script/validate_test_isolation.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --locked
(cd apps/macos && swift test)
./script/validate_schema_fixtures.sh
./script/validate_source_syntax.sh
./script/validate_build_scripts_safety.sh
./script/validate_security_boundaries.sh
```

The default gate uses isolated state and does not launch the GUI or invoke real Agents. Real connectors, real Codex App Server generation, and visible App behavior are checked separately when those dependencies are available. The [validation profiles](../development/validation.md) define what each result proves.

默认门禁使用隔离状态，不启动 GUI，也不调用真实 Agent。真实连接器、真实 Codex App Server 制作和可见 App 行为在对应依赖可用时单独验收；每层结果的证明范围以[验证层级](../development/validation.md)为准。

## 4. Build and validate both archives / 构建并校验两个归档

Build both architecture-specific archives from the exact release commit:

```bash
export APC_RELEASE_VERSION='X.Y.Z'
export APC_RELEASE_BUILD='1'
./script/build_release.sh
```

To diagnose one architecture independently, use `--arch arm64` or `--arch x86_64`. The complete release command writes:

- `dist/AgentPetCompanion-X.Y.Z-macos-arm64.zip`
- `dist/AgentPetCompanion-X.Y.Z-macos-x86_64.zip`
- `dist/AgentPetCompanion-X.Y.Z-SHA256SUMS.txt`

Each archive is extracted into a clean temporary directory and validated again. The release validator checks:

- the exact requested thin architecture for the App, PetCore, and `petcore-cli`;
- strict ad-hoc signature validity for nested executables and the outer App;
- matching App version, build number, release channel, and runtime-manifest identity;
- required resources, bundled Skills and petpacks, plus schema and connector-contract versions in the runtime manifest;
- headless App UI validation plus packaged PetCore and CLI operations;
- bundled-pet seeding, package validation, and connector-contract checks.

On a build host whose architecture matches the archive, the validator executes the packaged App, PetCore, and CLI. A cross-architecture archive receives the same static package, manifest, resource, architecture, and signature validation but is not launched: running an Intel App on Apple silicon invokes Rosetta and can present Apple's Intel-app support warning described in [Apple's Rosetta guidance](https://support.apple.com/102527). The native archive supplies the shared runtime functional proof; separate physical-device acceptance is not required at this stage.

每个 ZIP 都会解压到新的临时目录再次校验。与构建机架构相同的归档会执行包内 App、PetCore 与 CLI；跨架构归档继续校验包内容、runtime manifest、资源、准确切片与签名，但不会启动，以免在 Apple 芯片机器上调用 Rosetta 并触发 [Apple 官方说明](https://support.apple.com/zh-cn/102527)中的 Intel App 支持终止提示。原生架构包提供共享运行时的功能证据，当前阶段不要求另一架构实机验收。任一架构失败都必须停止发布。

## 5. Functional acceptance / 功能验收

The packaged functional validator is the repeatable acceptance baseline. On the available compatible Mac, also use Computer Use to verify the visible App and desktop pet without taking over user input:

- the App opens and the five navigation entries appear in the documented order;
- both bundled pets appear and a valid pet can be enabled;
- the desktop pet body remains hoverable and draggable during launch, state transitions, and frame-mask refresh;
- resize, context menu, session bubble, and Control Center reopen actions work;
- Pet Library, AI Pet Maker, Pet Configuration, Agent Connections, and Service & Diagnostics expose their expected primary actions;
- useful diagnostic status and actionable errors remain visible, while credentials are not collected.

包内功能校验是可重复的验收基线。在当前可用的兼容 Mac 上，再通过 Computer Use 验证 App 能打开、五个导航项顺序正确、两只内置宠物可见且可启用、桌宠本体始终可悬停和拖动，并抽查缩放、右键菜单、会话气泡、控制中心及各主要页面功能。当前阶段不要求在另一台物理架构设备上重复验收。

Use [System architecture](../architecture/overview.md), [Data model](../architecture/data-model.md), [Agent connectors](../integrations/agent-connectors.md), and the [`.petpack` specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md) as the acceptance contracts rather than copying their full rules into release notes.

## 6. Publish the GitHub Release / 发布 GitHub Release

After the release commit, CI, both archives, and functional acceptance pass:

1. create and push tag `vX.Y.Z` for the exact release commit;
2. create one GitHub Release for `vX.Y.Z`;
3. attach both architecture ZIPs and the shared `SHA256SUMS.txt`;
4. summarize the matching changelog section;
5. record the commit, supported macOS baseline, archive hashes, validation scope, and CI link;
6. state that the Apps are ad-hoc signed and not Apple-notarized, with first-launch guidance;
7. verify the Release version, tag, App/runtime version, and changelog version agree.

发布完成后，每个 GitHub Release、tag 与 CHANGELOG 版本段必须一一对应。只附加公开构建产物与校验和，不附加用户诊断包、凭据或包含用户数据的验收产物。
