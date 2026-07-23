# macOS Release and Distribution Procedure / macOS 发布与分发流程

Agent Pet Companion publishes one versioned runtime as two thin archives:
`arm64` for Apple silicon and `x86_64` for Intel. Both archives must come from
the same commit, semantic version, positive build number, and shared runtime
build ID. The App, PetCore, `petcore-cli`, runtime manifest, bundled Skills, and
bundled pets are one release unit.

Agent Pet Companion 将同一版本运行时发布为两个 thin 归档：Apple 芯片使用
`arm64`，Intel 使用 `x86_64`。两个归档必须来自同一 commit、语义版本、正整数
build number 与共享 runtime build ID；App、PetCore、`petcore-cli`、runtime
manifest、内置 Skills 和内置宠物共同构成一个不可拆分的发布单元。

The tooling has two explicit modes:

- `--preview` creates ad-hoc-signed development-preview archives. Their
  filenames end in `-preview.zip`; they are never supported public packages.
- `--public` creates supported public archives only after Developer ID signing,
  hardened-runtime and entitlement verification, Apple notarization, stapling,
  Gatekeeper assessment, and final-archive revalidation. It never falls back to
  preview output. Public mode always builds and validates the arm64 and x86_64
  pair together; a single-architecture public invocation is rejected.

工具提供两种明确模式：`--preview` 只生成文件名带 `-preview.zip` 的 ad-hoc
开发预览；`--public` 只有在 Developer ID 签名、Hardened Runtime 与
entitlements 校验、Apple 公证、staple、Gatekeeper 评估及最终归档复验全部成功后
才生成受支持公开包，任何失败都不会降级为预览版。

## 1. Freeze one release identity / 冻结唯一发布身份

Choose `X.Y.Z` and a positive build number. The exact candidate commit must:

1. use source version `X.Y.Z`;
2. contain a frozen `## [X.Y.Z] - YYYY-MM-DD` changelog section;
3. be the target of tag `vX.Y.Z`;
4. have a clean worktree;
5. have passed the required product, source, packaged runtime, accessibility,
   integration, and performance gates.

选择 `X.Y.Z` 与正整数 build number。候选 commit 必须使用相同源码版本，包含唯一
`[X.Y.Z]` CHANGELOG 段，由 `vX.Y.Z` tag 精确指向，工作区干净，并通过产品合同
要求的源码、包内运行时、无障碍、集成与性能门禁。发布证据进入 CI artifact 与
GitHub Release，不写入长期文档。

The generated `apc.runtime-manifest.v1` binds the App version/build/shared build
ID to the PetCore/CLI identities and supported data contracts. Public mode also
rejects `APC_BUILD_ID` overrides; the build ID is derived from the version,
build number, and candidate commit.

## 2. Build host and external provisioning / 构建机与外部配置

Both modes require macOS 14 or later, Apple Command Line Tools with Swift 6,
Rust 1.96.0 with both Apple targets, Python 3, `rg`, `ditto`, `codesign`,
`lipo`, and `shasum`.

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

Supported public distribution additionally requires full notarization tooling
and these externally provisioned values:

```text
APC_CODESIGN_IDENTITY    exact Developer ID Application identity
APC_DEVELOPER_TEAM_ID    ten-character Apple Developer Team ID
APC_NOTARY_PROFILE       notarytool keychain profile name
APC_NOTARY_KEYCHAIN      optional absolute path to that Keychain
```

`APC_NOTARY_KEYCHAIN` is required when the profile lives in a non-default,
ephemeral CI Keychain and may be omitted for a profile in the user's ordinary
Keychain search path. The certificate private key and Apple notarization
credentials remain Keychain-managed; repository files, scripts, logs, and
artifacts never contain or print them. Missing or invalid provisioning makes
`--public` exit unavailable. Use `--preview` explicitly for a local handoff.

正式公开分发还需要完整公证工具及以上外部配置。profile 位于非默认临时 Keychain
时必须传入 `APC_NOTARY_KEYCHAIN`；位于用户常规 Keychain 搜索路径时可省略。证书
私钥与 Apple 公证凭据始终由 Keychain 管理，仓库文件、脚本、日志和 artifact
不保存也不输出。缺少或无效配置时，`--public` 以 unavailable 状态失败；本地
交接应显式运行 `--preview`。

The repository entitlement allowlist is
[`config/distribution/AgentPetCompanion.entitlements`](../../config/distribution/AgentPetCompanion.entitlements).
It is intentionally empty: the App is not sandboxed and needs no exceptional
hardened-runtime entitlement. Adding an entitlement requires a product and
security review plus an updated validation contract.

## 3. Run the candidate gates / 运行候选门禁

Run the host-safe gate for the exact commit:

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
不读取凭据。真实连接器、App Server、可见 UI、渲染和分析门禁只在环境与授权具备
时运行；跳过必须明确写为 skipped。

## 4. Build a development preview / 构建开发预览

Preview mode is available without Developer ID or notarization credentials:

```bash
export APC_RELEASE_VERSION='X.Y.Z'
export APC_RELEASE_BUILD='1'
./script/build_release.sh --preview --arch all
```

It produces:

```text
dist/AgentPetCompanion-X.Y.Z-macos-arm64-preview.zip
dist/AgentPetCompanion-X.Y.Z-macos-x86_64-preview.zip
dist/AgentPetCompanion-X.Y.Z-SHA256SUMS.txt
```

Each preview ZIP is extracted and revalidated for exact thin architecture,
strict ad-hoc signature integrity, App/PetCore/CLI runtime identity, bundled
resources, and compatible-host packaged functionality. Preview archives must
remain labeled Development Preview wherever they are shared.

Every release ZIP receives a bounded structural safety preflight before
extraction. The preflight rejects absolute or non-canonical paths, zip-slip,
duplicate normalized/case-folded paths, symlinks, special filesystem entries,
extra top-level entries, unsupported compression, excessive entry count,
per-entry or total expanded size, and excessive compression ratio. CRC is also
checked before `ditto` sees the archive.

预览包会再次解压并校验准确架构、ad-hoc 签名完整性、运行时身份、资源与本机兼容
功能；任何公开位置都必须明确标为 Development Preview，不能描述为普通用户可直接
安装的受支持公开包。

## 5. Build supported public archives / 构建受支持公开归档

On the exact tagged commit:

```bash
export APC_RELEASE_VERSION='X.Y.Z'
export APC_RELEASE_BUILD='1'
export APC_CODESIGN_IDENTITY='Developer ID Application: … (TEAMID)'
export APC_DEVELOPER_TEAM_ID='TEAMID'
export APC_NOTARY_PROFILE='agent-pet-companion-release'
./script/build_release.sh --public --arch all
```

For each architecture the pipeline:

1. assembles an unsigned Release App with the exact runtime identity;
2. signs every nested Mach-O and code container deepest-first with
   `--options runtime --timestamp`;
3. signs the outer App last with the repository entitlement allowlist;
4. verifies Authority, Team ID, hardened-runtime flags, designated
   requirements, embedded entitlements, and exact architecture;
5. creates a pre-staple notarization-submission ZIP;
6. runs `xcrun notarytool submit --keychain-profile … --wait` and requires
   `Accepted`;
7. staples the accepted ticket to the App and validates it;
8. requires `spctl --assess --type execute` to accept the stapled App;
9. creates a new final ZIP from the stapled App;
10. extracts that final ZIP and repeats signature, ticket, Gatekeeper,
    architecture, package, and runtime-identity validation.

每个架构都按“内层 Mach-O/代码容器 → 外层 App”的顺序签名，使用安全时间戳和
Hardened Runtime；随后校验 Authority、Team ID、designated requirement、
entitlements、架构与运行时身份。只有公证状态为 `Accepted`、staple 校验与
Gatekeeper 评估成功后，才从已 staple 的 App 重新生成最终 ZIP，并对解压后的
实际发布内容重复全部门禁。

The final artifact set is:

```text
dist/AgentPetCompanion-X.Y.Z-macos-arm64.zip
dist/AgentPetCompanion-X.Y.Z-macos-x86_64.zip
dist/AgentPetCompanion-X.Y.Z-macos-arm64-distribution.json
dist/AgentPetCompanion-X.Y.Z-macos-x86_64-distribution.json
dist/AgentPetCompanion-X.Y.Z-SHA256SUMS.txt
```

Each `apc.public-distribution-evidence.v1` sidecar records two distinct
digests: `notarization.submission_archive_sha256` identifies the pre-staple ZIP
submitted to Apple, while `published_artifact.sha256` identifies the final
stapled ZIP. Stapling changes the App, so the submission digest must never be
reported as the downloadable artifact digest. `SHA256SUMS.txt` covers the final
ZIPs and their evidence sidecars.

每个 evidence sidecar 分别记录“提交 Apple 的 pre-staple ZIP 摘要”和“最终
stapled 下载 ZIP 摘要”；两者语义与值都不可混用。共享校验和文件覆盖最终 ZIP 与
对应 evidence sidecar。

Revalidate any local or downloaded set with:

```bash
./script/validate_public_release_artifacts.sh \
  --directory /path/to/artifacts \
  --version X.Y.Z \
  --build BUILD_NUMBER \
  --commit FULL_40_CHARACTER_COMMIT
```

The validator accepts only the exact five-file inventory above. The checksum
file contains exactly four entries—the two final ZIPs and two evidence
sidecars—and never attempts to checksum itself. The required commit and build
bind both evidence files, both App `Info.plist` files, both runtime manifests,
and their shared build ID. Each App is checked for exact thin architecture
across every contained Mach-O, including code unknown to the expected
App/PetCore/CLI inventory.

## 6. GitHub Release automation / GitHub Release 自动化

.github/workflows/release.yml runs for a `vX.Y.Z` tag or an explicit manual
dispatch referencing an existing tag. It uses the protected `public-release`
environment and GitHub-hosted native macOS runners. The signing job runs on
`macos-15` (Apple silicon); packaged acceptance runs independently on
`macos-15` (arm64) and `macos-15-intel` (x86_64), with an explicit `uname -m`
assertion before either native gate. Every third-party workflow action is
pinned to a full commit and checkout never persists Git credentials.

工作流由 `vX.Y.Z` tag 或引用既有 tag 的手动触发启动，使用受保护的
`public-release` environment 与 GitHub 托管原生 macOS runner。签名任务运行于
Apple silicon `macos-15`；包内验收分别运行于 arm64 `macos-15` 与 x86_64
`macos-15-intel`，并在原生门禁前显式断言 `uname -m`。所有第三方 Action 固定到
完整 commit，checkout 不保存 Git 凭据。

Configure these environment values:

```text
Variables:
  APC_CODESIGN_IDENTITY
  APC_DEVELOPER_TEAM_ID

Secrets:
  APC_DEVELOPER_ID_P12_BASE64
  APC_DEVELOPER_ID_P12_PASSWORD
  APC_NOTARY_API_KEY_P8_BASE64
  APC_NOTARY_API_KEY_ID
  APC_NOTARY_API_ISSUER_ID
```

The environment must require an explicit release-maintainer review and use
custom deployment policies that allow only the `main` branch for manual
dispatches and `v*.*.*` tags for tag-triggered releases. Keep credential
variables and secrets only in this environment; do not define same-name
repository or organization fallbacks.

该 environment 必须要求发布维护者显式审核，并通过自定义 deployment policy
只允许 `main` 分支发起手动发布、`v*.*.*` tag 发起标签发布。上述变量与 secrets
必须只保存在该 environment，不得在仓库或组织层配置同名回退。

After the host-safe source gate, the signing job decodes the P12 certificate
and App Store Connect API key into mode-`0600` temporary files, imports the
Developer ID identity and a validated `agent-pet-companion-ci` notary profile
into a random-password ephemeral Keychain, and passes that exact Keychain to
`notarytool`. An `always()` cleanup step deletes the Keychain and both files.
Secrets are scoped only to this provisioning step; native validation and
publication receive public identity and Team ID metadata but no private key,
certificate password, API key, or notary profile.

在 host-safe 源码门禁之后，签名任务才会将 P12 证书与 App Store Connect API key
解码到权限为 `0600` 的临时文件，把 Developer ID 身份和已验证的
`agent-pet-companion-ci` 公证 profile 导入随机密码临时 Keychain，并将该 Keychain
显式传给 `notarytool`。`always()` 清理步骤会删除 Keychain 与两个临时文件。
Secrets 仅进入凭据配置步骤；原生验证与发布任务只接收公开 identity 与 Team ID，
不接触私钥、证书密码、API key 或公证 profile。

The repository must protect `v*.*.*` with a GitHub tag ruleset that permits
controlled creation but rejects tag updates and deletions. After the build job
proves the initial tag target, every downstream job checks out the resulting
full commit instead of the tag name. The publish job peels and compares the
remote tag with that commit before draft creation, immediately before
publication, and immediately after publication; a mismatch fails closed and
removes the Release.

仓库必须用 GitHub tag ruleset 保护 `v*.*.*`：允许受控创建，但禁止更新或删除。
构建任务证明首次 tag 指向后，所有下游任务都按完整 commit 检出，不再按 tag 名检出；
发布任务会在创建草稿前、正式公开前和公开后立即再次解析远端 tag 并与该 commit
比对，任何不一致都会失败并删除 Release。

The workflow:

1. proves tag, source version, changelog version, and commit equality;
2. runs the host-safe candidate gate;
3. builds and validates both public archives;
4. emits a trusted SHA-256 digest for each of the five candidate files before
   storing the bounded CI artifact;
5. downloads the candidate into separate private-key-free native arm64 and
   x86_64 validation jobs checked out at that exact commit, compares all five
   trusted digests before archive inspection, and runs packaged functional
   acceptance on the matching native architecture;
6. waits for both native jobs, then uses a clean GitHub-hosted macOS job with
   only Release write permission;
7. compares all five trusted digests before archive inspection, repeats the
   complete artifact gates, rechecks the immutable remote tag, and creates one
   draft GitHub Release;
8. downloads every draft asset into another fresh directory, compares the five
   trusted digests first, then repeats the complete gates;
9. rechecks the remote tag, publishes only after all checks succeed, and checks
   the tag once more before retaining the Release.

Native validation is a hard dependency of publication. If either hosted native
job is unavailable, mismatches its asserted architecture, or fails packaged
acceptance, the workflow remains incomplete and cannot publish. A cross-built
archive or a run on the other architecture never substitutes for the matching
native gate.

原生双架构验证是发布的硬依赖。任一 GitHub 托管原生任务不可用、架构断言不匹配或
包内验收失败，工作流都保持未完成且不能发布；交叉编译归档或另一架构上的执行不能
代替对应原生门禁。

An existing Release is never overwritten. If download verification fails, the
draft is removed and no supported public Release is published. One tag, one
changelog version, and one GitHub Release remain a one-to-one contract.

## 7. User installation contract / 用户安装合同

A supported public user downloads the ZIP matching the Mac architecture plus
the versioned checksum file, verifies the SHA-256 digest, extracts the App,
moves it to `/Applications`, and launches it normally. No source toolchain,
quarantine bypass, or unsigned first-launch workaround is part of the supported
path.

普通用户只需下载与 Mac 架构匹配的 ZIP 和版本化校验和文件，核对 SHA-256，解压后
将 App 移入 `/Applications` 并正常启动。源码工具链、quarantine 绕过或未签名首启
处理都不属于受支持安装路径。
