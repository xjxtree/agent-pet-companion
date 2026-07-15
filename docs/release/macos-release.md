# macOS release procedure / macOS 发布流程

Agent Pet Companion has no public V1 release yet. A distributable build is complete only after the universal Release app is signed with Developer ID, submitted to Apple notarization, stapled, and accepted by the local validation gate. An ad-hoc-signed or unsigned development bundle must never be described as a public release.

Agent Pet Companion 尚未发布公开 V1。只有 universal Release App 完成 Developer ID 签名、Apple notarization、staple，并通过本地门禁后，才是可分发构建。ad-hoc 签名或未签名开发 bundle 不能称为公开发布版本。

The dated [project status](../PROJECT_STATUS.md) is the release-readiness ledger. Do not start a distribution release while it lists a failing default gate, blocked Swift tests, an unverified runtime migration, or pending current-build host acceptance.

带日期的[项目状态](../PROJECT_STATUS.md)是发布就绪账本。只要其中仍记录默认门禁失败、Swift tests 阻塞、运行时迁移未验证或当前候选实机验收未完成，就不得开始分发发布。

## 0. Freeze the runtime release set / 冻结运行时版本集

Before building a candidate, freeze one manifest that binds all components that can affect persisted data or desktop-pet behavior:

- App semantic version, bundle build and `APCBuildID`;
- PetCore RPC protocol/build and PetCore CLI build;
- SQLite schema and Agent event schema versions;
- Codex, Claude Code, Pi and OpenCode connector contract versions;
- minimum/maximum compatible runtime and downgrade policy;
- last-known-good artifact identity and rollback procedure.

构建候选版本前，必须冻结一份统一 manifest，绑定 App version/build/`APCBuildID`、PetCore RPC/build、CLI、数据库与事件 schema、四个 connector contract、兼容范围、降级策略和 last-known-good 回滚目标。当前 develop 实现已通过 `apc.runtime-manifest.v1`、候选预检、exact health 和 LKG 回滚满足这一工程门禁；正式分发还必须让该 manifest 处于 Developer ID 签名范围内并完成安装器级演练。

Exercise the update path with both an older and a newer installed runtime. The candidate Core must pass build/schema/read-only data checks before the old Core is retired; a failed candidate must restore the last-known-good runtime without leaving the pet connected to an incompatible or empty service.

发布演练必须覆盖旧版升级和新版误开旧 App 两个方向。候选 Core 需要在旧 Core 退役前通过构建、schema 与只读数据检查；候选失败后应自动恢复 last-known-good，不能让桌宠继续连接不兼容或空服务。

## Develop package / 非正式开发包

The current requested delivery is an informal, ad-hoc-signed develop package:

```bash
./script/test_all.sh
./script/build_app_bundle.sh
```

The build produces `dist/AgentPetCompanion.app` and `dist/AgentPetCompanion-develop.zip`. Assembly, ad-hoc signing, and archive creation happen outside the File Provider workspace. The ZIP is the supported develop handoff: it excludes resource-fork/xattr metadata and is extracted into a second temporary directory for `codesign --verify --deep --strict`. If the repository is under a File Provider-managed Documents directory, Finder metadata may later change strict verification of the naked `.app`; this does not alter the already verified ZIP contents.

当前要求的交付物是非正式 ad-hoc develop 包。脚本会先在 File Provider 工作区外完成 App 组装、签名和归档，再生成裸 `.app` 和 `AgentPetCompanion-develop.zip`；ZIP 才是支持的 develop 交接物，会排除资源 fork/xattr，并在另一临时目录解压后做严格签名校验。该包未使用 Developer ID、未公证、未 staple，也不承诺 Gatekeeper 或正式自动更新。

## Requirements / 前置条件

- macOS 14+ and Xcode 16+ with command-line tools
- Rust 1.96.0 and both `aarch64-apple-darwin` and `x86_64-apple-darwin` targets
- a Developer ID Application certificate available to `codesign`
- a notarytool keychain profile created by the release operator

The scripts consume only explicit environment values. They do not enumerate certificates, inspect the keychain, read `.env` files, or discover credentials.

脚本只使用显式环境变量，不枚举证书、不检查 keychain、不读取 `.env`，也不自动发现凭据。

## 1. Run the delivery gate / 运行交付门禁

```bash
./script/validate_test_isolation.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --locked
(cd apps/macos && swift test)
./script/validate_schema_fixtures.sh
./script/validate_source_syntax.sh
./script/validate_build_scripts_safety.sh
```

Real connector and App Server checks remain separate explicit acceptance gates and must not be folded into the release script.

真实 connector 与 App Server 检查仍是独立的显式验收门禁，不得被发布脚本自动触发。

If `swift test` cannot import Swift `Testing`, select the complete supported Xcode toolchain and rerun it. Executable Swift validators do not replace the unit-test gate. Likewise, a field-allowlist assertion failure in `test_all.sh` is a release failure until the validator and canonical schema are synchronized.

如果 `swift test` 无法导入 Swift `Testing`，应切换到受支持的完整 Xcode 工具链后重跑；Swift executable validator 不能替代单元测试。`test_all.sh` 中字段 allowlist 断言失败同样属于发布失败，必须同步 validator 与规范 schema，不能按环境跳过处理。

## 2. Build an unsigned universal candidate / 构建未签名 universal 候选

```bash
./script/build_release.sh --unsigned
```

This creates `dist/AgentPetCompanion.app` from Release binaries and verifies both architectures. It is useful for local inspection only.

该命令生成使用 Release 二进制的 `dist/AgentPetCompanion.app` 并验证双架构，仅用于本地检查。

## 3. Sign, notarize and staple / 签名、公证与装订

Set the values explicitly in the current shell. Do not commit them:

```bash
export APC_CODESIGN_IDENTITY='Developer ID Application: Example Team (TEAMID)'
export APC_NOTARY_PROFILE='agent-pet-companion-notary'
./script/build_release.sh --distribution
```

The script performs these exact stages:

1. build universal Rust and Swift Release binaries;
2. sign nested executables with hardened runtime and a trusted timestamp;
3. sign the outer app bundle;
4. verify the signature and universal slices;
5. create a temporary ZIP with `ditto`;
6. submit it with `xcrun notarytool --keychain-profile ... --wait`;
7. staple and validate the ticket;
8. require `spctl` acceptance;
9. create `dist/AgentPetCompanion-macos-universal.zip` and its SHA-256 file.

脚本依次完成 universal Release 构建、嵌套二进制与 App hardened runtime 签名、签名/架构验证、notarytool 提交、staple、`spctl` 验收，以及最终 ZIP 和 SHA-256 生成。

Missing identity/profile values fail with a clear instruction. A failed or unavailable notarization is never reported as success.

缺少签名 identity/profile 会明确失败；notarization 失败或不可用时绝不会伪报成功。

## 4. Final evidence / 最终证据

Record the commit, runtime manifest, toolchain versions, validation output, notarization request ID, archive hash, update/rollback drill, and macOS 14+ launch/accessibility check in the release notes. The host pass must also cover closing and reopening the singleton control center, standard Quit, PetCore survival after UI exit, duplicate-open rejection, message-bubble expand/open behavior, and the applicable Liquid Glass/fallback appearance. Use Computer Use first with Accessibility reads and element-based actions; any fallback that can take over the user's input requires explicit approval immediately before use. Never include credential values or private notary logs.

发布记录需包含 commit、runtime manifest、toolchain 版本、门禁输出、notarization request ID、归档 hash、升级/回滚演练和 macOS 14+ 启动/无障碍检查；实机检查还必须覆盖单例控制中心关闭与重开、标准 Quit、UI 退出后 PetCore 继续存活、重复打开不会产生第二实例、消息气泡展开/打开，以及适用的 Liquid Glass/回退外观。检查必须优先使用 Computer Use 的 Accessibility 读取和元素级操作；任何可能接管用户输入的替代方法都需要在执行前取得明确授权。不得记录凭据值或私有公证日志。
