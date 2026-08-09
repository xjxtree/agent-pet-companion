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

The Codex plugin keeps an independent semantic version. Any change under `plugins/codex`, `skills/agent-pet-studio`, or `skills/agent-pet-maker` requires a greater plugin version than the previous release. A Studio change also requires the previous shipped Skill digest in the append-only retired-Skill history. If an App-managed pre-release Skill reached local installations without a Git release baseline, its recovery digest must be pinned explicitly in the release validator; arbitrary additional history digests remain invalid.

The previous release baseline is the current latest stable GitHub Release, not merely the nearest semantic-version Git tag. A protected candidate tag whose workflow fails before publication remains an immutable audit marker, but it is not a shipped upgrade or retired-Skill ownership baseline. The next candidate uses a new semantic version and continues from the actual latest stable Release. / 上一版本基线取 GitHub 当前 latest stable Release，而不是距离最近的语义版本 Git tag。若受保护的候选标签在公开发布前失败，该标签会作为不可变审计标记保留，但不会成为已发布升级或退役 Skill 所有权基线；下一候选使用新的语义版本，并继续以实际 latest stable Release 为基线。

## Prerequisites and gates / 环境与门禁

Build hosts need macOS 14+, Swift 6 with a macOS SDK, the pinned Rust toolchain and both Apple targets, Python 3 with the pinned visual-validation dependencies, `rg`, `ditto`, `codesign`, `lipo`, and `shasum`.

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

No Apple account, certificate, private key, notarization profile, release Variable, or release Secret is used.

Run the host-safe source gate on the exact candidate commit:

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

Then run the environment-dependent connector, App Server, visible-UI, renderer, and profiling gates required by [Validation profiles](../development/validation.md). The executing Agent selects a suitable live-App inspection method. A gate not run is skipped, never passed. / 随后按发布范围运行环境门禁；可见 App 的验收方法由执行 Agent 选择，未运行的门禁只能标记为 skipped。

The overlay suites generate a build-bound interaction attestation. Bundle validation requires the final App to contain and successfully consume the attestation for its own build ID.

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

Official mode accepts only `--arch all`, applies ad-hoc signatures, and produces exactly:

```text
dist/AgentPetCompanion-X.Y.Z-macos-arm64.zip
dist/AgentPetCompanion-X.Y.Z-macos-x86_64.zip
dist/AgentPetCompanion-X.Y.Z-SHA256SUMS.txt
```

`SHA256SUMS.txt` contains exactly the two ZIP entries. No signature or notarization sidecar belongs in the asset set.

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
2. runs the host-safe source gate and builds the exact three assets;
3. records trusted digests before artifact upload;
4. validates the matching archive on native arm64 and x86_64 runners;
5. revalidates all three assets in a clean publish job and rechecks the protected tag;
6. creates a non-prerelease draft with bilingual installation and first-open guidance;
7. downloads and revalidates the draft assets;
8. publishes it as latest stable only after all checks pass; and
9. verifies through GitHub's API that the tag Release and `/releases/latest` are the same public stable Release with the trusted assets and digests.

Native validation is a hard dependency; cross-building or testing on the other architecture is not a substitute. Existing Releases are never overwritten. / 原生双架构验收是硬门禁，交叉构建不能替代；已有 Release 不会被覆盖。

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
