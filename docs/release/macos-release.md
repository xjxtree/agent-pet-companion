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
and these externally provisioned names:

```text
APC_CODESIGN_IDENTITY    exact Developer ID Application identity
APC_DEVELOPER_TEAM_ID    ten-character Apple Developer Team ID
APC_NOTARY_PROFILE       pre-provisioned notarytool keychain profile name
```

正式公开分发还需要完整公证工具及以上三个外部注入值。证书私钥与 Apple 公证凭据
由发布机 Keychain 管理；仓库、脚本、CI 日志和 artifact 不保存、不发现也不输出
这些凭据。`APC_NOTARY_PROFILE` 只是已配置 profile 的名称。缺少任何外部配置时，
`--public` 以 unavailable 状态失败；如只需本地交接，应显式运行 `--preview`。

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
dispatch referencing an existing tag. Signing and notarization use a protected,
externally provisioned `apc-public-release` macOS runner and the
`public-release` environment. The workflow does not import certificates or
create notary credentials; the runner Keychain already owns them, while
repository environment variables provide only the identity, Team ID, and
profile names. Every third-party workflow action is pinned to a full commit and
checkout never persists Git credentials.

工作流由 `vX.Y.Z` tag 或引用既有 tag 的手动触发启动，运行于受保护且已外部配置的
macOS 发布 runner 与 `public-release` environment。工作流不导入证书、不创建
公证凭据，只接收身份、Team ID 与 profile 名称。

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

The required native validation runner labels are
`self-hosted, macOS, ARM64, apc-public-validation` and
`self-hosted, macOS, X64, apc-public-validation`. These jobs receive public
signature metadata but no signing identity private key and no notary profile.
If either native runner is not externally provisioned, the workflow remains
incomplete and cannot reach publication; it must never describe the candidate
as having passed native two-architecture acceptance.

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
