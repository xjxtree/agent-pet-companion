# macOS release procedure / macOS 发布流程

Agent Pet Companion has no public V1 release yet. A distributable build is complete only after the universal Release app is signed with Developer ID, submitted to Apple notarization, stapled, and accepted by the local validation gate. An unsigned development bundle must never be described as a release.

Agent Pet Companion 尚未发布公开 V1。只有 universal Release App 完成 Developer ID 签名、Apple notarization、staple，并通过本地门禁后，才是可分发构建。未签名的开发 bundle 不能称为发布版本。

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

Record the commit, toolchain versions, validation output, notarization request ID, archive hash, and manual macOS 14+ launch/accessibility check in the release notes. Never include credential values or private notary logs.

发布记录需包含 commit、toolchain 版本、门禁输出、notarization request ID、归档 hash 及 macOS 14+ 启动/无障碍人工检查；不得记录凭据值或私有公证日志。
