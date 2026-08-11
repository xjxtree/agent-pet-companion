# macOS GitHub Release / macOS GitHub Release 流程

One release contains the App, PetCore, CLI, runtime manifest, bundled Skills, and bundled pets. It publishes two thin archives (`arm64`, `x86_64`) plus one checksum file. / 一个版本将 App、PetCore、CLI、runtime manifest、内置 Skills 和宠物作为同一发布单元，生成两个 thin 归档和一份校验和文件。

## Distribution boundary / 分发边界

GitHub Releases is the only official V1 channel. Archives are ad-hoc signed, not Developer ID signed or notarized, and have no stapled ticket. The project does not use Mac App Store, TestFlight, Apple distribution credentials, or a protected GitHub release environment.

Published Apps therefore require explicit first-open consent through Finder **Open** or **System Settings → Privacy & Security → Open Anyway**. Do not instruct users to disable Gatekeeper or remove quarantine from the command line. / 正式 App 首次打开需要通过 Finder 的**打开**或**系统设置 → 隐私与安全性 → 仍要打开**确认；不得要求用户关闭 Gatekeeper 或通过命令行绕过。

GitHub Immutable Releases is not required. Protected `v*.*.*` tags and fail-closed automation provide commit identity, while users verify downloaded ZIPs against the published checksum before replacement.

## Release identity / 发布身份

Choose semantic version `X.Y.Z` and a positive build number. The exact release commit must have:

- source version `X.Y.Z`;
- one matching `## [X.Y.Z] - YYYY-MM-DD` changelog section;
- protected tag `vX.Y.Z` pointing to the full commit;
- a clean worktree;
- the validation required for that release.

The runtime build ID is `X.Y.Z.BUILD.FULL_40_CHARACTER_COMMIT`. App, PetCore, CLI, manifest, and both archives must agree. One version maps to one tag, one changelog section, and one GitHub Release. / 版本、tag、CHANGELOG、完整 commit、build ID 与两个架构产物必须一一对应。

The Codex plugin keeps an independent semantic version. Any change under `plugins/codex`, `skills/agent-pet-studio`, or `skills/agent-pet-maker` requires a greater plugin version than the previous release. Every bundled Skill front matter must declare that same version, while the hooks template is restricted to Codex-supported top-level fields. Hook version presentation binds an exact current rendered template to the plugin manifest; current source/cache digests prove convergence and are never a historical ownership registry. / Codex 插件独立版本必须递增；所有内置 Skill 的 front matter 必须声明同一版本；hooks 模板只能使用 Codex 支持的顶层字段。Hook 的版本展示通过当前完整渲染模板与插件清单绑定；当前源与缓存摘要只用于证明收敛，绝不是历史归属注册表。

The previous release baseline is the current latest stable GitHub Release, not merely the nearest semantic-version Git tag. A protected candidate tag whose workflow fails before publication remains an immutable audit marker, but it is not a shipped upgrade or retired-Skill ownership baseline. The next candidate uses a new semantic version and continues from the actual latest stable Release. / 上一版本基线取 GitHub 当前 latest stable Release，而不是距离最近的语义版本 Git tag。若受保护的候选标签在公开发布前失败，该标签会作为不可变审计标记保留，但不会成为已发布升级或退役 Skill 所有权基线；下一候选使用新的语义版本，并继续以实际 latest stable Release 为基线。

## Prerequisites and gates / 环境与门禁

Build hosts need Apple Swift 6.2 or newer with the macOS 26 SDK or newer, the pinned Rust toolchain and both Apple targets, Python 3 with the pinned visual-validation dependencies, `rg`, `ditto`, `codesign`, `lipo`, `nm`, `otool`, and `shasum`. The App remains deployed to macOS 14: official App binaries must report `minos 14.0`, an SDK of at least 26, and weak-linked SwiftUI/AppKit Liquid Glass symbols. This lets one archive render native Liquid Glass on macOS 26 while running the authored system-material fallback on macOS 14 and 15. / 构建主机必须提供 Apple Swift 6.2+ 与 macOS 26+ SDK；App 的最低运行版本仍为 macOS 14。正式 App 二进制必须同时证明 `minos 14.0`、SDK 至少为 26，且 SwiftUI/AppKit Liquid Glass 符号保持弱链接，因此同一归档可在 macOS 26 呈现原生液态玻璃，并在 macOS 14、15 运行既定的系统材质回退。

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

No Apple account, certificate, private key, notarization profile, release Variable, or release Secret is used.

Run the host-safe source gate on the exact candidate commit:

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh --source-only --include-stress
```

Then run the environment-dependent connector, App Server, visible-UI, renderer, and profiling gates required by [Validation profiles](../development/validation.md). The executing Agent selects a suitable live-App inspection method. A gate not run is skipped, never passed. / 随后按发布范围运行环境门禁；可见 App 的验收方法由执行 Agent 选择，未运行的门禁只能标记为 skipped。

The complete Swift run generates a build-bound interaction attestation in the same invocation. Bundle validation requires the final App to contain and successfully consume the attestation for its own build ID. GitHub automation persists that proof once and supplies it to both architecture builds. / 完整 Swift 测试在同一次调用中生成交互证明；自动化只生成一次，并复用于两个架构构建。

## Development artifacts / 开发产物

```bash
./script/build_app_bundle.sh
./script/build_app_bundle.sh --archive
```

These produce development Apps or handoff archives. Renaming or uploading them does not make them official release artifacts. / 这些命令只生成开发或交接产物，不能通过改名替代正式发布。

## Build the candidate / 构建候选产物

On the tagged commit:

```bash
export APC_RELEASE_VERSION='X.Y.Z'
export APC_RELEASE_BUILD='1'
./script/build_release.sh --github-release --arch all
```

Normally the previous baseline is inferred from Git history for local builds. If an intervening protected candidate tag never became a GitHub Release, set `APC_PREVIOUS_RELEASE_TAG` to the actual latest stable Release tag; GitHub automation resolves and supplies this value from `/releases/latest` automatically. / 本地构建通常从 Git 历史推断上一基线；若中间存在从未成为 GitHub Release 的受保护失败候选标签，请将 `APC_PREVIOUS_RELEASE_TAG` 设为实际 latest stable Release 标签。GitHub 自动化会从 `/releases/latest` 解析并传入该值。

Local complete mode uses `--arch all`, applies ad-hoc signatures, performs native packaged acceptance for the host architecture, and produces exactly:

```text
dist/AgentPetCompanion-X.Y.Z-macos-arm64.zip
dist/AgentPetCompanion-X.Y.Z-macos-x86_64.zip
dist/AgentPetCompanion-X.Y.Z-SHA256SUMS.txt
```

`SHA256SUMS.txt` contains exactly the two ZIP entries. No signature or notarization sidecar belongs in the asset set.

The GitHub workflow instead runs `--arch arm64` and `--arch x86_64` in parallel. It adds the internal `--source-gate-proven` handoff only after the required source job succeeded and supplied its attestation, avoiding two repeated script-contract passes. Each command produces one source-proven ZIP component; neither component is publishable alone. The assemble job downloads both, creates the shared checksum, rejects any extra file, and emits the three trusted digests. / GitHub workflow 在源码任务成功并提供证明后，使用内部 `--source-gate-proven` 交接并行构建两个架构，避免重复两次脚本契约门禁；单件不可单独发布。

Validate a clean local or downloaded three-file directory with:

```bash
./script/validate_github_release_artifacts.sh \
  --directory /path/to/artifacts \
  --version X.Y.Z \
  --build BUILD_NUMBER \
  --commit FULL_40_CHARACTER_COMMIT
```

Validation rejects missing/extra assets, unsafe or malformed ZIPs, checksum/identity disagreement, invalid ad-hoc signatures, mixed/universal binaries, unexpected Mach-O content, and architecture mismatch. Native packaged acceptance also starts the bundled runtime in an isolated home and proves all three included pets, canonical covers, and every authored frame for all nine actions.

## GitHub automation / GitHub 自动化

`.github/workflows/release.yml` runs from a protected `vX.Y.Z` tag or explicit dispatch of an existing tag. In order it:

1. verifies tag, source version, changelog, full commit, and Codex plugin/Skill version discipline;
2. runs the host-safe source, complete Swift interaction, integration, and explicit stress gates once, then uploads the source-bound interaction proof;
3. restores dependency/build caches and builds `arm64` and `x86_64` ZIP components in parallel on macOS 26 from the proven commit and proof;
4. assembles the exact three-file candidate once and records trusted digests;
5. validates the exact SDK/deployment/weak-link contract in every App archive;
6. runs the matching ZIP on macOS 15 arm64 and Intel hosts to prove the compatibility path, then runs the arm64 ZIP again on macOS 26 to prove the packaged modern-system path;
7. creates a non-prerelease draft with bilingual installation and first-open guidance after exact-inventory and digest checks;
8. downloads the draft assets and verifies exact inventory plus byte-for-byte equality with all three trusted digests, without rerunning the already completed native package suites;
9. publishes it as latest stable only after all checks pass; and
10. verifies through GitHub's API that the tag Release and `/releases/latest` are the same public stable Release with the trusted assets and digests.

Native compatibility validation on both architectures and packaged macOS 26 validation are hard dependencies; cross-building or static symbol inspection is not a substitute for runtime acceptance. Existing Releases are never overwritten. / 双架构原生兼容验收与 macOS 26 打包产物验收都是硬门禁；交叉构建或静态符号检查不能替代运行时验收，已有 Release 不会被覆盖。

## User installation contract / 用户安装合同

The App, README, and Release notes use the same flow:

1. download the architecture ZIP and `SHA256SUMS.txt`, then verify the ZIP;
2. quit Agent Pet Companion, move the new App to `/Applications`, and choose **Replace**;
3. open it from Applications and complete the macOS first-open approval if requested.

Installation requires no source toolchain. The App may open validated asset/Release URLs and Finder locations, but it never downloads or installs the App itself. A browser-open failure keeps the verified release available with retry and Release-page actions.

## In-App update and replacement / App 内更新与替换

Automatic and manual checks use GitHub's public `/releases/latest` response and accept only a newer stable Release with the exact asset contract. Automatic checks are ETag-aware and run at most once per 24 hours after healthy startup; App menu and About actions bypass the interval.

After manual replacement, the bundled identity drives the existing runtime transaction. It converges PetCore, CLI, runtime manifest, missing/updated trusted bundled pets, and only integrations already managed by Agent Pet Companion. Core failure restores a compatible last-known-good runtime; an individual Agent failure remains isolated and repairable.

If the old App is still running, handoff waits for protected user mutations and convergence work, then revalidates the canonical replacement immediately before quit/relaunch. Invalid, changed, or ambiguous candidates leave the old App running with manual recovery. See [Runtime and IPC](../architecture/runtime-and-ipc.md).
