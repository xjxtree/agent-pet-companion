# macOS GitHub Release Procedure / macOS GitHub Release 流程

Agent Pet Companion publishes one versioned runtime as two thin archives:
`arm64` for Apple silicon and `x86_64` for Intel. The App, PetCore,
`petcore-cli`, runtime manifest, bundled Skills, and bundled pets are one
release unit.

Agent Pet Companion 将同一版本运行时发布为两个 thin 归档：Apple 芯片使用
`arm64`，Intel 使用 `x86_64`。App、PetCore、`petcore-cli`、runtime manifest、
内置 Skills 与内置宠物共同构成一个发布单元。

## 1. Distribution boundary / 分发边界

The only official V1 distribution channel is GitHub Releases. It does not
create a Mac App Store record, submit an App for review, upload to TestFlight,
or use Apple distribution credentials.

Official V1 archives are ad-hoc signed. They are not Developer ID signed or
Apple-notarized, have no stapled ticket, and must not be described as trusted by
Gatekeeper by default. The user explicitly allows the App on first launch:

1. in Finder, Control-click or right-click `AgentPetCompanion.app`, choose
   **Open**, then confirm **Open**; or
2. after macOS blocks a normal first launch, open **System Settings → Privacy &
   Security**, choose **Open Anyway** for Agent Pet Companion, and confirm.

V1 的唯一正式分发渠道是 GitHub Releases，不创建 Mac App Store 记录、不提交审核、
不上传 TestFlight，也不使用 Apple 分发凭据。正式归档采用 ad-hoc 签名，没有
Developer ID 签名、Apple 公证或 stapled ticket，不得声称默认受到 Gatekeeper
信任。首次启动需要用户在 Finder 中按住 Control 点击或右键选择**打开**并确认，
或在普通打开被阻止后前往**系统设置 → 隐私与安全性 → 仍要打开**并确认。

These are explicit macOS user-consent paths, not command-line quarantine
bypasses. No source toolchain is required to install a published archive.

## 2. Release identity / 发布身份

Choose semantic version `X.Y.Z` and a positive build number. The exact release
commit must:

1. use source version `X.Y.Z`;
2. contain exactly one `## [X.Y.Z] - YYYY-MM-DD` changelog section;
3. be the target of protected tag `vX.Y.Z`, which the published Release uses
   as its commit identity;
4. have a clean worktree when the release build starts; and
5. satisfy the product, source, packaged-runtime, accessibility, integration,
   and performance gates required for that release.

The runtime build ID is `X.Y.Z.BUILD.FULL_40_CHARACTER_COMMIT`. The App,
PetCore, CLI, and runtime manifest must agree on the full identity. Both
architecture archives are built from that same tag, commit, version, build
number, and build ID.

选择语义版本 `X.Y.Z` 与正整数 build number。候选 commit 的源码版本、CHANGELOG
版本段与 `vX.Y.Z` tag 必须一致，工作区必须干净。Runtime build ID 使用
`X.Y.Z.BUILD.完整40位commit`，App、PetCore、CLI、runtime manifest 与两个架构
归档必须共享这一完整身份。

The Codex plugin has an internal strict `X.Y.Z` version. It does not have to
equal the App version, but any change under `plugins/codex`,
`skills/agent-pet-studio`, or `skills/agent-pet-maker` must strictly increase
the plugin version from the previous release. The release workflow compares
the candidate with the previous version tag and fails otherwise.

Codex 插件使用独立的严格 `X.Y.Z` 内部版本，不要求与 App 版本相同；但
`plugins/codex`、`skills/agent-pet-studio` 或 `skills/agent-pet-maker`
任意内容发生变化时，插件版本都必须高于上一正式版本。发布 workflow 会与上一版本
tag 比较，不满足时直接失败。

One version maps to exactly one tag, one changelog section, and one GitHub
Release. Release evidence belongs in CI artifacts and Release notes, not in
durable documentation.

## 3. Build requirements and pre-release gates / 构建要求与发布前门禁

The build host requires macOS 14 or later, Apple Command Line Tools with Swift
6 and a macOS SDK, the Rust toolchain pinned by `rust-toolchain.toml` with both
Apple targets, Python 3 with Pillow 11.3.0 for portable pet visual validation,
`rg`, `ditto`, `codesign`, `lipo`, and `shasum`. The GitHub workflow installs
Pillow into an isolated validation virtual environment; it is a build-time test
dependency, not an App runtime dependency.

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

构建主机还需要 Python 3 与 Pillow 11.3.0，用于可移植宠物视觉校验。GitHub
工作流会将 Pillow 安装到隔离的校验虚拟环境；它只是构建期测试依赖，不会进入 App
运行环境。

No Apple account, certificate, private key, notarization profile, manually
configured GitHub release Variable, or release Secret is required. The
workflow must not reference a `public-release` environment.

V1 不需要 Apple 账户、证书、私钥、公证 profile，也不需要手动配置 GitHub release
Variables 或 Secrets；工作流不得引用 `public-release` environment。

GitHub **Immutable releases** is intentionally not required. The protected
`v*.*.*` tag ruleset remains the commit-identity boundary, and release
automation refuses to replace an existing Release for the same tag. Because a
repository administrator could still edit Release assets, users verify the
downloaded ZIP against the published checksum before replacing the App.

本项目明确不要求开启 GitHub **Immutable releases**。受保护的 `v*.*.*` tag
ruleset 继续作为 commit 身份边界，发布自动化也会拒绝替换同一 tag 的既有 Release。
由于仓库管理员仍可修改 Release 资产，用户在替换 App 前必须使用发布的校验和核对
下载的 ZIP。

Run the host-safe candidate gate for the exact commit:

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_OVERLAY_INTERACTION=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

Then run only the explicitly authorized real connector, App Server, visible UI,
renderer, and profiling gates required by
[Validation Profiles](../development/validation.md). Live App verification
uses Computer Use first. A skipped environment-dependent gate is reported as
skipped, never passed.

默认门禁使用隔离目录，不启动 GUI、不修改用户 LaunchAgent、不调用真实 Agent、
不读取凭据。真实连接器、App Server、可见 UI、渲染与分析门禁只在环境和授权具备
时运行；跳过必须明确记录为 skipped。

## 4. Development archives / 开发归档

Local development builds and handoff archives use:

```bash
./script/build_app_bundle.sh
./script/build_app_bundle.sh --archive
```

They are development artifacts, not tag-bound GitHub Release candidates. Do
not publish or rename one as an official archive.

本地开发 App 与交接归档由 `build_app_bundle.sh` 生成，不受正式 tag 约束，不能通过
改名或直接上传替代正式 GitHub Release 产物。

## 5. Build the official candidate / 构建正式候选产物

On the exact tagged commit:

```bash
export APC_RELEASE_VERSION='X.Y.Z'
export APC_RELEASE_BUILD='1'
./script/build_release.sh --github-release --arch all
```

`--github-release` is explicit and accepts only `--arch all`. It builds both
thin architectures together, applies ad-hoc signatures, and never asks for or
falls back to Developer ID or notarization credentials.

The exact output inventory is:

```text
dist/AgentPetCompanion-X.Y.Z-macos-arm64.zip
dist/AgentPetCompanion-X.Y.Z-macos-x86_64.zip
dist/AgentPetCompanion-X.Y.Z-SHA256SUMS.txt
```

`SHA256SUMS.txt` contains exactly two entries: the two ZIP filenames above. It
does not checksum itself, and no signing/notarization sidecar is part of the
official asset set.

`SHA256SUMS.txt` 只包含上述两个 ZIP 的两行摘要，不校验自身，也不存在签名、公证
sidecar。正式 GitHub Release 的资产清单必须恰好是这三个文件。

The validator's input directory itself must contain exactly those three regular
files. The workflow moves them from `dist/` into a fresh `release-assets/`
directory before final validation, so development Apps produced by earlier
gates cannot enter or invalidate the release candidate. For local revalidation,
copy only the three named files into a clean directory and validate that
directory.

校验目录本身必须只包含这三个普通文件。工作流会在最终校验前将它们从 `dist/`
移动到全新的 `release-assets/`，因此前序门禁生成的开发 App 不会进入或干扰正式
候选。本地复验时，也应只把上述三个文件放入一个干净目录后再校验。

For each archive, the build and validation path verifies:

- the expected App-only top-level ZIP structure before extraction;
- canonical relative paths, no path traversal, duplicates, symlinks, special
  entries, unsupported compression, or configured size/ratio limit breaches;
- CRC integrity before extraction;
- strict ad-hoc signature integrity for nested executables and the outer App;
- exact thin architecture for every contained Mach-O, including unexpected
  executable content;
- App/PetCore/CLI/runtime-manifest version, build, full commit, and shared
  build-ID agreement;
- bundled resources and packaged behavior.

Revalidate a local or downloaded set with:

```bash
./script/validate_github_release_artifacts.sh \
  --directory /path/to/artifacts \
  --version X.Y.Z \
  --build BUILD_NUMBER \
  --commit FULL_40_CHARACTER_COMMIT
```

The validator rejects missing or extra files, an incorrectly ordered or
expanded checksum inventory, identity mismatches, unsafe ZIPs, non-ad-hoc
signature state, mixed/universal binaries, or any Mach-O whose architecture
does not match its archive.

## 6. GitHub Release automation / GitHub Release 自动化

`.github/workflows/release.yml` runs for a protected `vX.Y.Z` tag or an
explicit manual dispatch referencing an existing tag. It uses GitHub-hosted
macOS runners and the workflow's built-in GitHub Release permission; it does
not use a protected environment or repository Apple credentials.

The workflow:

1. proves tag, source version, changelog version, and full commit equality,
   and requires a Codex plugin version increase when its bundled content
   differs from the previous version tag;
2. runs the host-safe candidate gate;
3. builds the exact three-file candidate with `--github-release --arch all`;
4. records a trusted SHA-256 digest for each candidate file before artifact
   upload;
5. downloads the candidate into separate native `arm64` and `x86_64` jobs,
   compares all three trusted digests before inspection, asserts `uname -m`,
   and runs packaged-functional validation for the matching archive;
6. after both native jobs pass, downloads the candidate into a clean publish
   job, compares all three digests, repeats the complete artifact gates, and
   rechecks the protected remote tag;
7. creates a non-prerelease draft GitHub Release whose notes lead with the
   bilingual three-step manual replacement guide, architecture choice,
   ad-hoc-signing disclosure, and both first-open approval paths;
8. downloads all three draft assets into a fresh directory, compares their
   trusted digests, and repeats complete validation; and
9. publishes it explicitly as the latest stable Release only after the final
   tag check and downloaded-asset validation succeed; and
10. reads the tag Release and `/releases/latest` through GitHub's API, requires
    the same Release ID with `draft == false` and `prerelease == false`, and
    matches each API asset digest and URL to the trusted build outputs.

Native validation is a hard publication dependency. A cross-built archive or
execution on the other architecture cannot substitute for the matching native
gate. An existing Release is never overwritten; if draft download or
revalidation fails, no official Release is published.

工作流先绑定 tag、版本、CHANGELOG 与完整 commit，再生成三个候选文件。候选文件在
原生 arm64 与 x86_64 GitHub 托管 runner 上分别执行包内验收；两者通过后，发布任务
才会在干净目录中复验。草稿 Release 的三个资产还会重新下载、比对可信摘要并完整
复验，最后再次确认远端 tag 后才公开为 latest stable Release；公开后还会通过
GitHub API 验证它不是草稿或预发布，且三项资产、URL 与摘要完全一致。

Keep the tag ruleset that allows controlled `v*.*.*` creation but rejects tag
updates and deletions. Downstream jobs check out the proven full commit rather
than trusting a mutable tag name.

## 7. User installation contract / 用户安装合同

The App's update result and the top of every GitHub Release use the same three
steps:

1. download and unzip the ZIP matching the Mac architecture, along with that
   version's `SHA256SUMS.txt`, and verify the selected ZIP;
2. quit Agent Pet Companion, move the new App to `/Applications`, and choose
   **Replace**;
3. open the new App from Applications. If macOS blocks it, explicitly approve
   the first launch through Finder Control-click/right-click **Open**, or
   **System Settings → Privacy & Security → Open Anyway**.

App 的更新结果与每个 GitHub Release 顶部使用同样的三步：

1. 下载并解压适用于这台 Mac 的 ZIP，同时下载同版本 `SHA256SUMS.txt` 并核对所选
   ZIP；
2. 退出 Agent Pet Companion，将新版移入 `/Applications` 并选择**替换**；
3. 从“应用程序”打开新版。若 macOS 阻止打开，在 Finder 中按住 Control 点击或
   右键选择**打开**，或前往**系统设置 → 隐私与安全性 → 仍要打开**。

This flow needs no source toolchain and never asks the user to run `xattr`,
disable Gatekeeper, or use another command-line bypass. The App may open the
exact architecture asset, Downloads, Applications, or the matching Release
page, but it does not download or install the App itself. A browser-open
failure keeps the already verified release available with retry and Release
page actions.

此流程不需要源码工具链，也不会要求执行 `xattr`、关闭 Gatekeeper 或使用其他命令行
绕过。App 可以打开当前架构的精确资产、下载文件夹、应用程序文件夹或对应 Release
页面，但不会自行下载或安装 App。若浏览器打开失败，App 会保留已经校验的 Release，
并提供重试与打开 Release 页面操作。

## 8. In-App check and post-replacement behavior / App 检查与替换后行为

Automatic and manual checks use GitHub's public `/releases/latest` endpoint and
accept only the latest stable Release described above. Automatic checks are
quiet, ETag-aware, and limited to once per 24 hours after healthy startup.
Manual **Check for Updates…** actions in the App menu and About window bypass
that interval and always report their result.

After the user replaces and opens the App, the new bundled identity drives the
existing runtime replacement transaction. The App validates and converges
PetCore, `petcore-cli`, the runtime manifest, missing bundled pets, and only
the Agent integrations already managed by Agent Pet Companion. Codex
convergence includes the plugin manifest version, both bundled Skills, and
active-cache content. Core failure restores the last-known-good compatible
runtime; one Agent failure remains isolated and repairable. See
[Runtime and IPC](../architecture/runtime-and-ipc.md) and
[Agent connectors](../integrations/agent-connectors.md).

If replacement occurs while the old process remains alive, handoff waits for
pending user mutations and convergence work, then revalidates the canonical
bundle's own identifier and runtime manifest immediately before scheduling
quit and relaunch. An invalid or changed candidate leaves the old App running
with the manual recovery guide. A legacy PetCore without the typed active
connection flag is probed through its bounded connection-operation admission
gate; conflict or ambiguity defers replacement.

自动与手动检查都读取 GitHub 公共 `/releases/latest`，并且只接受上述 latest
stable Release。自动检查在健康启动后安静执行、使用 ETag、每 24 小时至多一次；
App 菜单和“关于”窗口中的“检查更新…”会绕过间隔并明确返回结果。

用户替换并打开 App 后，新版随包身份驱动现有运行时替换事务，收敛 PetCore、
`petcore-cli`、runtime manifest、缺失的内置宠物以及此前已受管的 Agent 集成。
Codex 还必须验证插件 manifest 版本、两个 Skills 与实际缓存内容。核心失败恢复上一
兼容运行时；单个 Agent 失败保持隔离且可修复。

若旧进程仍运行，交接会等待用户写入与收敛任务结束，并在安排退出和重启前再次校验
正式安装位置中候选 App 自己的 identifier 与 runtime manifest；候选包失效或变化
时，旧版继续运行并显示手动恢复引导。旧 PetCore 若没有类型化的连接操作状态，
App 会通过其有界连接操作入口进行兼容探测；冲突或不确定结果都会推迟替换。
