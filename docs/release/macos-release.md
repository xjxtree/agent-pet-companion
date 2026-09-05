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

Release preparation begins from a frozen `changes/unreleased/` inventory on an explicitly registered `release_preparation` branch. That branch alone consumes the globally unique typed fragments into the matching changelog section; ordinary direct, task, and train PRs leave root `CHANGELOG.md` untouched. The release source checks reject missing fragments before preparation and reject leftover fragments after consumption. / 发布准备从显式登记的 `release_preparation` 分支冻结变更片段清单开始；只有该分支可将全局唯一的类型化片段汇总到匹配版本段。普通开发 PR 不修改根变更日志；源码门禁会在准备前拒绝缺失片段，并在汇总后拒绝残留片段。

The runtime build ID is `X.Y.Z.BUILD.FULL_40_CHARACTER_COMMIT`. App, PetCore, CLI, manifest, and both archives must agree. One version maps to one tag, one changelog section, and one GitHub Release. / 版本、tag、CHANGELOG、完整 commit、build ID 与两个架构产物必须一一对应。

The Codex plugin keeps an independent semantic version. Any change under `plugins/codex`, `skills/agent-pet-studio`, or `skills/agent-pet-maker` requires a greater plugin version than the previous release. Every bundled Skill front matter must declare that same version, while the hooks template is restricted to Codex-supported top-level fields. Hook version presentation binds an exact current rendered template to the plugin manifest; current source/cache digests prove convergence and are never a historical ownership registry. / Codex 插件独立版本必须递增；所有内置 Skill 的 front matter 必须声明同一版本；hooks 模板只能使用 Codex 支持的顶层字段。Hook 的版本展示通过当前完整渲染模板与插件清单绑定；当前源与缓存摘要只用于证明收敛，绝不是历史归属注册表。

The previous release baseline is the current latest stable GitHub Release, not merely the nearest semantic-version Git tag. A protected candidate tag whose workflow fails before publication remains an immutable audit marker, but it is not a shipped upgrade or retired-Skill ownership baseline. The next candidate uses a new semantic version and continues from the actual latest stable Release. / 上一版本基线取 GitHub 当前 latest stable Release，而不是距离最近的语义版本 Git tag。若受保护的候选标签在公开发布前失败，该标签会作为不可变审计标记保留，但不会成为已发布升级或退役 Skill 所有权基线；下一候选使用新的语义版本，并继续以实际 latest stable Release 为基线。

## Prerequisites and gates / 环境与门禁

Build hosts need Apple Swift 6.2 or newer with the macOS 26 SDK or newer, the pinned Rust toolchain and both Apple targets, Python 3 with the pinned visual-validation dependencies, `rg`, `ditto`, `codesign`, `lipo`, `nm`, `otool`, and `shasum`. The App remains deployed to macOS 14: official App binaries must report `minos 14.0`, an SDK of at least 26, and weak-linked SwiftUI/AppKit Liquid Glass symbols. This lets one archive render native Liquid Glass on macOS 26 while running the authored system-material fallback on macOS 14 and 15. / 构建主机必须提供 Apple Swift 6.2+ 与 macOS 26+ SDK；App 的最低运行版本仍为 macOS 14。正式 App 二进制必须同时证明 `minos 14.0`、SDK 至少为 26，且 SwiftUI/AppKit Liquid Glass 符号保持弱链接，因此同一归档可在 macOS 26 呈现原生液态玻璃，并在 macOS 14、15 运行既定的系统材质回退。

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

No Apple account, certificate, private key, notarization profile, release Variable, or release Secret is used.

Merge the exact candidate commit to protected `main` and wait for the post-merge required CI check. The main-bound PR has already passed the complete gate before auto-merge; a successful same-repository `.github/workflows/ci.yml` run on the exact immutable `main` commit—either a protected `push` or an exact-SHA `workflow_dispatch`—binds the release-grade inventory and uploads its source proof. The trusted post-CI merger uses the dispatch form because GitHub suppresses ordinary follow-on workflow events created with `GITHUB_TOKEN`. A manual Release dispatch may create the release tag only after validating that proof. The one-time ruleset migration procedure is owned by [Validation profiles](../development/validation.md). / 将精确候选 commit 合并到受保护的 `main` 并等待合并后的必选 CI。面向 main 的 PR 已在自动合并前通过完整门禁；同仓库 `.github/workflows/ci.yml` 在精确且不可变的 main commit 上成功执行的受信任验证——受保护 `push` 或精确 SHA 的 `workflow_dispatch`——会绑定 Release 级清单并上传源码证明。CI 后合并器使用显式派发，因为 GitHub 会抑制由 `GITHUB_TOKEN` 产生的普通后续 workflow 事件。Release 手动派发只有在验证该证明后才能创建发布 tag。一次性 ruleset 迁移步骤由验证文档维护。

The complete local command remains available only for diagnosis; it is not a release prerequisite when the exact remote proof exists:

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh --source-only --include-stress
```

Then run the environment-dependent connector, App Server, renderer, and profiling gates required by [Validation profiles](../development/validation.md). Visible-UI acceptance is never optional for a GitHub Release and must use the local Computer Use checklist below. Any other gate not run is skipped, never passed. / 随后按发布范围运行连接器、App Server、渲染与性能环境门禁。GitHub Release 的可见 UI 验收不可跳过，且必须使用下方本地 Computer Use 清单；其他未运行的门禁只能标记为 skipped。

The complete Swift CI shard generates a source-build interaction attestation. `source-proof.json` binds its bytes to the repository, full commit/tree, latest stable baseline, trusted exact-commit `main` issuer run (`push` or `workflow_dispatch`), complete gate inventory, and toolchain contract. Release downloads it only from that successful exact-commit CI run, validates it, and rebinds the interaction attestation to the final release build ID before supplying it to both architecture builds. / 完整 Swift CI 分片会生成源码 build 的交互证明；`source-proof.json` 将其字节绑定到仓库、完整 commit/tree、latest stable 基线、受信任的同 commit `main` 签发 run（`push` 或 `workflow_dispatch`）、完整门禁清单与工具链合同。Release 只从该成功的同 commit CI run 下载并校验，再将交互证明重新绑定到最终发布 build ID，供两个架构构建复用。

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

The GitHub workflow runs `--arch arm64` and `--arch x86_64` in parallel. It adds the internal `--source-gate-proven` handoff only after reusing and validating the successful exact-commit main proof. Each command produces one source-proven ZIP component; neither component is publishable alone. The assemble job downloads both, creates the shared checksum, rejects any extra file, and emits the three trusted digests. / GitHub workflow 仅在复用并校验成功的同 commit main 证明后，才使用内部 `--source-gate-proven` 交接并行构建两个架构；单件不可单独发布。

Validate a clean local or downloaded three-file directory with:

```bash
./script/validate_github_release_artifacts.sh \
  --directory /path/to/artifacts \
  --version X.Y.Z \
  --build BUILD_NUMBER \
  --commit FULL_40_CHARACTER_COMMIT
```

Validation rejects missing/extra assets, unsafe or malformed ZIPs, checksum/identity disagreement, invalid ad-hoc signatures, mixed/universal binaries, unexpected Mach-O content, and architecture mismatch. Native packaged acceptance also starts the bundled runtime in an isolated home and proves all three included pets, canonical covers, and every authored frame for all nine actions.

## Mandatory local Computer Use acceptance / 必需的本地 Computer Use 验收

Before any GitHub Release dispatch, check out the exact clean `main` commit that will be released and launch its test App through the normal product path:

在触发任何 GitHub Release 之前，必须检出将要发布的精确、干净 `main` commit，并通过正常产品路径启动其测试 App：

```bash
git switch main
git pull --ff-only
test -z "$(git status --porcelain)"
git rev-parse HEAD
APC_VALIDATE_HOST_UI=1 \
APC_MAIN_UI_COLD_LAUNCH_ITERATIONS=20 \
./script/validate_main_window_ui.sh
./script/build_and_run.sh --run
```

The stress command is a fail-closed Release prerequisite, not a substitute for Computer Use. It runs twenty real foreground cold launches with deterministic timing jitter and requires the exact singleton Control Center to be visible, opaque, on layer 0, pixel-nonblank, and still key after the overlay is ordered. A ScreenCaptureKit or Accessibility observation that cannot be completed is a failed gate. / 冷启动压力命令是 fail-closed 的发布前置条件，不能替代 Computer Use。它以确定性时序扰动执行二十次真实前台冷启动，并要求精确的单例控制中心可见、不透明、位于 layer 0、像素非空，且桌宠浮层完成排序后仍保持 key window；ScreenCaptureKit 或辅助功能观察无法完成时按失败处理。

Use Computer Use—not `--run-ui-validation`, a hidden `NSHostingView`, AX-only validation, or source inspection—to observe and operate the running App. The acceptance is one bounded basic-function pass:

必须使用 Computer Use 直接观察并操作正在运行的 App；`--run-ui-validation`、隐藏的 `NSHostingView`、仅 AX 验证或源码检查都不能替代。验收只需完成一次有界的基础功能检查：

1. Launch reaches a visible, nonblank first-run onboarding or returning-user Control Center window. / 启动后能看到非空白的首次引导或普通控制中心窗口。
2. The five navigation entries appear in the required order, and each destination visibly renders after selection. / 五个导航入口按规定顺序出现，逐一选择后页面均能实际显示。
3. Pet Library visibly presents the three bundled pets and a working action preview. / 宠物库能看到三只内置宠物，动作预览可正常工作。
4. The desktop pet can be hidden and shown from the Control Center. / 可从控制中心隐藏并重新显示桌宠。
5. Closing and reopening the Control Center, then quitting and relaunching the App twice consecutively, restores a visible usable window after each cold launch. / 关闭并重新打开控制中心后，连续两次退出并重启 App；每次冷启动都必须恢复可见且可用的窗口。

Record the full tested commit and the combined stress plus Computer Use result. Enter `host_ui_result=passed` only when both gates passed on the same exact clean commit; that pass authorizes one dispatch for that commit. If any item fails or cannot be directly observed, do not dispatch, do not enter `passed`, and do not autonomously waive the failure; preserve the evidence and stop so the next action is 交由用户决定. After any source change, even a release-only fix, repeat both gates against the new commit.

记录完整的被测 commit，以及压力门禁与 Computer Use 的组合结果。只有两项门禁都在同一个精确且干净的 commit 上通过，才能填写 `host_ui_result=passed`，且该结果只授权发布这个 commit。若任一检查失败或无法直接观察，不得触发发布、不得填写 `passed`、也不得由 Agent 自行豁免；应保留证据并停止，后续动作交由用户决定。任何源码变化（包括仅用于发布的修复）都会使旧结果失效，必须针对新 commit 重新执行两项门禁。

## GitHub automation / GitHub 自动化

`.github/workflows/release.yml` runs only by explicit dispatch after the mandatory local Computer Use acceptance. A tag push cannot start publication. The workflow requires the tested full commit and a passed result before it can validate or create the protected tag. / `.github/workflows/release.yml` 仅能在完成必需的本地 Computer Use 验收后显式触发；推送 tag 不能启动发布。workflow 会先要求被测完整 commit 与通过结果，再继续验证或创建受保护 tag。

```bash
gh workflow run release.yml \
  -f tag=vX.Y.Z \
  -f build=BUILD_NUMBER \
  -f commit=FULL_40_CHARACTER_MAIN_COMMIT \
  -f host_ui_tested_commit=FULL_40_CHARACTER_MAIN_COMMIT \
  -f host_ui_result=passed
```

`host_ui_tested_commit` must be the same full commit resolved by `commit` (or current `main` when `commit` is omitted), and `host_ui_result` defaults to `failed`. A missing, failed, malformed, or mismatched declaration blocks the workflow before tag creation or archive builds. Dispatch then verifies source version, changelog, ancestry, latest stable baseline, and the successful exact-commit main proof before it creates a missing lightweight tag through GitHub's API. An existing tag must already target the same commit. Tag creation cannot make an unproven commit releasable, and any later job rechecks the remote identity. / `host_ui_tested_commit` 必须与 `commit` 解析出的完整 commit 相同（省略 `commit` 时即当前 `main`），`host_ui_result` 默认是 `failed`。声明缺失、失败、格式错误或 commit 不一致时，workflow 会在创建 tag 或构建归档前阻断。之后 dispatch 才会验证源码版本、CHANGELOG、祖先关系、latest stable 基线及同 commit 的成功 main 证明，再通过 GitHub API 创建缺失的轻量 tag；已有 tag 必须已指向同一 commit。创建 tag 不能让未经证明的 commit 进入发布，后续任务仍会复核远端身份。

In order the workflow:

1. rejects any missing, failed, malformed, or commit-mismatched local Computer Use acceptance declaration;
2. verifies source version, changelog, full main commit, latest stable baseline, and Codex plugin/Skill version discipline;
3. resolves the successful same-repository `main` CI `push` or exact-SHA `workflow_dispatch` run for that exact commit, rejects PR/fork/failed or ambiguous runs and artifacts, validates the two-file source proof, then rebinds its interaction attestation to the final release build ID;
4. creates a missing tag only after proof validation, or verifies the existing tag, then rechecks its remote commit;
5. restores dependency/build caches and builds `arm64` and `x86_64` ZIP components in parallel on macOS 26 from the proven commit and rebound proof;
6. assembles the exact three-file candidate once and records trusted digests;
7. validates the exact SDK/deployment/weak-link contract in every App archive;
8. runs the matching ZIP on macOS 15 arm64 and Intel hosts to prove the compatibility path, then runs the arm64 ZIP again on macOS 26 to prove the packaged modern-system path;
9. creates a non-prerelease draft whose bilingual version summary is rendered from the exact `CHANGELOG.md` release section, followed by concise installation and first-open guidance, after exact-inventory and digest checks;
10. downloads the draft assets and verifies exact inventory plus byte-for-byte equality with all three trusted digests, without rerunning the already completed native package suites;
11. publishes it as latest stable only after all checks pass; and
12. verifies through GitHub's API that the tag Release and `/releases/latest` are the same public stable Release with the trusted assets and digests.

Native compatibility validation on both architectures and packaged macOS 26 validation are hard dependencies; cross-building or static symbol inspection is not a substitute for runtime acceptance. Existing Releases are never overwritten. / 双架构原生兼容验收与 macOS 26 打包产物验收都是硬门禁；交叉构建或静态符号检查不能替代运行时验收，已有 Release 不会被覆盖。

Release bundles include the validated `星雾团子`, `Bytebud 字节芽`, and `桃蕾` petpacks. Seeding uses the stable manifest-ID and bundled-authority rules in [Data model](../architecture/data-model.md#pet-identity-and-revisions). / 发布包包含上述三只已验证内置宠物；初始化遵循数据模型中的稳定 manifest ID 与内置来源权限规则。

## User installation contract / 用户安装合同

The App, README, and Release notes use the same replacement flow. README may present it as numbered setup steps; each GitHub Release instead leads with the exact version's categorized bilingual `CHANGELOG.md` summary and then gives this flow as a short installation note. / App、README 与 Release notes 使用同一套替换流程；README 可以按编号步骤说明，而每个 GitHub Release 必须先展示从该版本 `CHANGELOG.md` 精确生成的分类双语变更摘要，再用简短安装说明呈现以下流程：

1. download the architecture ZIP and `SHA256SUMS.txt`, then verify the ZIP;
2. quit Agent Pet Companion, move the new App to `/Applications`, and choose **Replace**;
3. open it from Applications and complete the macOS first-open approval if requested.

Installation requires no source toolchain. The App may open validated asset/Release URLs and Finder locations, but it never downloads or installs the App itself. A browser-open failure keeps the verified release available with retry and Release-page actions.

## In-App update and replacement / App 内更新与替换

Automatic and manual checks use GitHub's public `/releases/latest` response and accept only a newer stable Release with the exact asset contract. Automatic checks are ETag-aware and run at most once per 24 hours after healthy startup; App menu and About actions bypass the interval.

After manual replacement, the bundled identity drives the existing runtime transaction. It converges PetCore, CLI, runtime manifest, missing/updated trusted bundled pets, and only integrations already managed by Agent Pet Companion. Core failure restores a compatible last-known-good runtime; an individual Agent failure remains isolated and repairable.

If the old App is still running, handoff waits for protected user mutations and convergence work, then revalidates the canonical replacement immediately before quit/relaunch. Invalid, changed, or ambiguous candidates leave the old App running with manual recovery. See [Runtime and IPC](../architecture/runtime-and-ipc.md).
